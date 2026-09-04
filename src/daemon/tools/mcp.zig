//! MCP client: stdio transport first (JSON-RPC over child process pipes),
//! HTTP later. Config lists servers; their tools register under provider-safe
//! `mcp__<server>__<tool>` names with the same approval policy machinery.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const block = @import("../../core/block.zig");
const registry = @import("registry.zig");

pub const current_protocol = "2026-07-28";
pub const legacy_protocol = "2025-11-25";
pub const request_timeout_ms: u32 = 15_000;
pub const max_message_bytes: usize = 8 * 1024 * 1024;
pub const max_media_items: usize = 4;
pub const max_media_bytes: usize = 10 * 1024 * 1024;

pub const Tool = struct {
    public_name: []u8,
    remote_name: []u8,
    description: []u8,
    schema_json: []u8,
    /// MCP's optional ToolAnnotations.readOnlyHint. Null means the server did
    /// not classify the tool and Marlin should use configured policy.
    read_only_hint: ?bool = null,

    fn deinit(self: *Tool, gpa: std.mem.Allocator) void {
        gpa.free(self.public_name);
        gpa.free(self.remote_name);
        gpa.free(self.description);
        gpa.free(self.schema_json);
    }
};

pub const CallResult = struct {
    output: []u8,
    status: block.ToolStatus,
    media: []registry.MediaOutput = &.{},

    pub fn deinit(self: CallResult, gpa: std.mem.Allocator) void {
        gpa.free(self.output);
        for (self.media) |item| item.deinit(gpa);
        if (self.media.len > 0) gpa.free(self.media);
    }
};

pub const ProtocolMode = enum { modern, legacy };

/// One persistent stdio MCP subprocess. Calls from concurrent Marlin sessions
/// serialize through `mutex`; if the child exits, the next call restarts it
/// using the protocol mode established during discovery.
pub const Server = struct {
    gpa: std.mem.Allocator,
    io: Io,
    name: []u8,
    argv: [][]u8,
    environ: ?*const std.process.Environ.Map,
    child: ?std.process.Child = null,
    reader_buffer: [8192]u8 = undefined,
    writer_buffer: [8192]u8 = undefined,
    reader: ?Io.File.Reader = null,
    writer: ?Io.File.Writer = null,
    next_id: u64 = 1,
    mode: ProtocolMode = .modern,
    mutex: Io.Mutex = .init,
    tools: std.ArrayList(Tool) = .empty,
    /// Absolute budget for one complete JSON-RPC exchange, including a
    /// blocked stdin write and any unrelated stdout records. Kept as a field
    /// so the failure paths can be exercised without 15-second tests.
    timeout_ms: u32 = request_timeout_ms,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        name: []const u8,
        argv: []const []const u8,
        environ: ?*const std.process.Environ.Map,
    ) !*Server {
        if (argv.len == 0) return error.EmptyMcpCommand;
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .name = try gpa.dupe(u8, name),
            .argv = try gpa.alloc([]u8, argv.len),
            .environ = environ,
        };
        errdefer gpa.free(self.name);
        var copied: usize = 0;
        errdefer {
            for (self.argv[0..copied]) |arg| gpa.free(arg);
            gpa.free(self.argv);
        }
        for (argv, 0..) |arg, i| {
            self.argv[i] = try gpa.dupe(u8, arg);
            copied += 1;
        }
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.reset();
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        for (self.argv) |arg| self.gpa.free(arg);
        self.gpa.free(self.argv);
        self.gpa.free(self.name);
        self.gpa.destroy(self);
    }

    /// Start the server and cache a deterministic tools/list snapshot.
    pub fn discover(self: *Server) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.discoverLocked() catch |err| {
            self.reset();
            return err;
        };
    }

    fn discoverLocked(self: *Server) !void {
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.clearRetainingCapacity();

        try self.start();
        self.mode = .modern;
        self.listAllTools() catch {
            // Most deployed servers still implement the 2025 lifecycle. A
            // fresh process avoids carrying any pre-initialize error state.
            self.reset();
            try self.start();
            self.mode = .legacy;
            try self.initializeLegacy();
            try self.listAllTools();
        };
        std.mem.sort(Tool, self.tools.items, {}, struct {
            fn less(_: void, a: Tool, b: Tool) bool {
                return std.mem.lessThan(u8, a.public_name, b.public_name);
            }
        }.less);
    }

    pub fn call(
        self: *Server,
        public_name: []const u8,
        args_json: []const u8,
        cancel: ?*const std.atomic.Value(bool),
    ) CallResult {
        if (!self.lockForCall(cancel)) return self.interrupted();
        defer self.mutex.unlock(self.io);
        if (isCancelled(cancel)) return self.interrupted();
        const tool = self.findTool(public_name) orelse return self.fail("unknown MCP tool '{s}'", .{public_name});
        self.ensureReady() catch |err| return self.fail("MCP server '{s}' failed to start: {t}", .{ self.name, err });

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const params = self.callParams(arena, tool.remote_name, args_json) catch |err|
            return self.fail("could not encode MCP call: {t}", .{err});
        const response = self.requestCancelable(arena, "tools/call", params, cancel) catch |err| {
            self.reset();
            if (err == error.Cancelled) return self.interrupted();
            return self.fail("MCP call failed: {t}", .{err});
        };
        return self.renderCallResult(response) catch |err|
            self.fail("invalid MCP tool result: {t}", .{err});
    }

    /// A session queued behind another call must remain interruptible. The
    /// active holder has its own absolute deadline, so polling here cannot
    /// leave the server mutex permanently wedged.
    fn lockForCall(self: *Server, cancel: ?*const std.atomic.Value(bool)) bool {
        while (!self.mutex.tryLock()) {
            if (isCancelled(cancel)) return false;
            self.io.sleep(.fromMilliseconds(25), .awake) catch return false;
        }
        return true;
    }

    fn start(self: *Server) !void {
        if (self.child != null) return;
        self.child = try std.process.spawn(self.io, .{
            .argv = @ptrCast(self.argv),
            .environ_map = self.environ,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        self.reader = self.child.?.stdout.?.reader(self.io, &self.reader_buffer);
        self.writer = self.child.?.stdin.?.writer(self.io, &self.writer_buffer);
    }

    fn reset(self: *Server) void {
        self.reader = null;
        self.writer = null;
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
    }

    fn ensureReady(self: *Server) !void {
        if (self.child != null) return;
        try self.start();
        if (self.mode == .legacy) try self.initializeLegacy();
    }

    fn initializeLegacy(self: *Server) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const params = try std.fmt.allocPrint(arena_state.allocator(),
            \\{{"protocolVersion":"2025-11-25","capabilities":{{}},"clientInfo":{{"name":"marlin","version":"{s}"}}}}
        , .{build_options.version});
        _ = try self.request(arena_state.allocator(), "initialize", params);
        try self.notify(
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );
    }

    fn listAllTools(self: *Server) !void {
        var cursor: ?[]u8 = null;
        defer if (cursor) |value| self.gpa.free(value);
        while (true) {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const params = try self.listParams(arena, cursor);
            const response = try self.request(arena, "tools/list", params);
            const result = resultObject(response) orelse return error.InvalidMcpResponse;
            const tools_value = result.get("tools") orelse return error.InvalidMcpResponse;
            if (tools_value != .array) return error.InvalidMcpResponse;
            for (tools_value.array.items) |value| try self.appendTool(value);

            const next = result.get("nextCursor") orelse break;
            if (next != .string or next.string.len == 0) break;
            if (cursor) |old| self.gpa.free(old);
            cursor = try self.gpa.dupe(u8, next.string);
        }
    }

    fn appendTool(self: *Server, value: std.json.Value) !void {
        if (value != .object) return error.InvalidMcpTool;
        const remote = stringField(value.object, "name") orelse return error.InvalidMcpTool;
        const description = stringField(value.object, "description") orelse "MCP tool";
        const schema_value = value.object.get("inputSchema") orelse return error.InvalidMcpTool;
        if (schema_value != .object) return error.InvalidMcpTool;
        const schema = try std.json.Stringify.valueAlloc(self.gpa, schema_value, .{});
        errdefer self.gpa.free(schema);
        const public = try publicToolName(self.gpa, self.name, remote);
        errdefer self.gpa.free(public);
        const remote_owned = try self.gpa.dupe(u8, remote);
        errdefer self.gpa.free(remote_owned);
        const description_owned = try self.gpa.dupe(u8, description);
        errdefer self.gpa.free(description_owned);
        const read_only_hint: ?bool = if (value.object.get("annotations")) |annotations|
            if (annotations == .object)
                if (annotations.object.get("readOnlyHint")) |hint|
                    if (hint == .bool) hint.bool else null
                else
                    null
            else
                null
        else
            null;
        try self.tools.append(self.gpa, .{
            .public_name = public,
            .remote_name = remote_owned,
            .description = description_owned,
            .schema_json = schema,
            .read_only_hint = read_only_hint,
        });
    }

    fn findTool(self: *const Server, public_name: []const u8) ?*const Tool {
        for (self.tools.items) |*tool| {
            if (std.mem.eql(u8, tool.public_name, public_name)) return tool;
        }
        return null;
    }

    pub fn findPublicTool(self: *const Server, public_name: []const u8) bool {
        return self.findTool(public_name) != null;
    }

    fn listParams(self: *const Server, arena: std.mem.Allocator, cursor: ?[]const u8) ![]const u8 {
        if (self.mode == .legacy) {
            if (cursor) |value| return std.json.Stringify.valueAlloc(arena, .{ .cursor = value }, .{});
            return "{}";
        }
        if (cursor) |value| return std.json.Stringify.valueAlloc(arena, .{
            ._meta = modernMeta(),
            .cursor = value,
        }, .{});
        return std.json.Stringify.valueAlloc(arena, .{ ._meta = modernMeta() }, .{});
    }

    fn callParams(self: *const Server, arena: std.mem.Allocator, remote_name: []const u8, args_json: []const u8) ![]const u8 {
        var parsed_state = std.heap.ArenaAllocator.init(self.gpa);
        defer parsed_state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, parsed_state.allocator(), args_json, .{});
        if (parsed != .object) return error.McpArgumentsMustBeObject;
        if (self.mode == .modern) return std.json.Stringify.valueAlloc(arena, .{
            .name = remote_name,
            .arguments = parsed,
            ._meta = modernMeta(),
        }, .{});
        return std.json.Stringify.valueAlloc(arena, .{ .name = remote_name, .arguments = parsed }, .{});
    }

    fn request(self: *Server, arena: std.mem.Allocator, method: []const u8, params_json: []const u8) !std.json.Value {
        return self.requestCancelable(arena, method, params_json, null);
    }

    fn requestCancelable(
        self: *Server,
        arena: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        cancel: ?*const std.atomic.Value(bool),
    ) !std.json.Value {
        const id = self.next_id;
        self.next_id +%= 1;
        const line = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
        // One watchdog covers the complete exchange. In particular, chatty
        // notifications cannot reset it and a server that stops consuming
        // stdin cannot trap the caller in flush forever.
        var deadline = Deadline{ .server = self, .cancel = cancel, .thread = undefined };
        try deadline.start();
        defer deadline.finish();

        self.writeMessage(line) catch |err| return deadline.mapFailure(err);

        while (true) {
            const response_line = self.readMessage(self.gpa) catch |err| return deadline.mapFailure(err);
            defer self.gpa.free(response_line);
            const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, response_line, .{
                .allocate = .alloc_always,
            });
            if (value != .object) continue;
            const response_id = value.object.get("id") orelse continue;
            if (response_id != .integer or response_id.integer < 0 or @as(u64, @intCast(response_id.integer)) != id) continue;
            if (value.object.get("error") != null) return error.McpRpcError;
            if (value.object.get("result") == null) return error.InvalidMcpResponse;
            return value;
        }
    }

    fn notify(self: *Server, line: []const u8) !void {
        try self.writeMessage(line);
    }

    fn writeMessage(self: *Server, line: []const u8) !void {
        const writer = if (self.writer) |*value| value else return error.McpServerNotRunning;
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }

    fn readMessage(self: *Server, gpa: std.mem.Allocator) ![]u8 {
        const reader = if (self.reader) |*value| value else return error.McpServerNotRunning;
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        _ = try reader.interface.streamDelimiterLimit(&output.writer, '\n', .limited(max_message_bytes));
        const delimiter = reader.interface.takeByte() catch return error.McpServerExited;
        if (delimiter != '\n') return error.InvalidMcpResponse;
        return output.toOwnedSlice();
    }

    fn renderCallResult(self: *Server, response: std.json.Value) !CallResult {
        const result = resultObject(response) orelse return error.InvalidMcpResponse;
        if (stringField(result, "resultType")) |kind| {
            if (!std.mem.eql(u8, kind, "complete")) return self.fail("MCP tool requires unsupported follow-up input", .{});
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.gpa);
        var media: std.ArrayList(registry.MediaOutput) = .empty;
        errdefer {
            for (media.items) |item| item.deinit(self.gpa);
            media.deinit(self.gpa);
        }
        if (result.get("content")) |content| {
            if (content != .array) return error.InvalidMcpResponse;
            for (content.array.items) |item| {
                if (item != .object) continue;
                const kind = stringField(item.object, "type") orelse continue;
                if (std.mem.eql(u8, kind, "text")) {
                    const text = stringField(item.object, "text") orelse continue;
                    if (out.items.len > 0) try out.append(self.gpa, '\n');
                    try out.appendSlice(self.gpa, text);
                } else if (std.mem.eql(u8, kind, "resource_link")) {
                    const uri = stringField(item.object, "uri") orelse "resource";
                    try out.print(self.gpa, "[MCP resource: {s}]", .{uri});
                } else if (std.mem.eql(u8, kind, "resource")) {
                    const resource = item.object.get("resource") orelse continue;
                    if (resource != .object) continue;
                    if (stringField(resource.object, "text")) |text| {
                        if (out.items.len > 0) try out.append(self.gpa, '\n');
                        try out.appendSlice(self.gpa, text);
                    } else {
                        const uri = stringField(resource.object, "uri") orelse "resource";
                        try out.print(self.gpa, "[MCP resource: {s}]", .{uri});
                    }
                } else if (std.mem.eql(u8, kind, "image")) {
                    if (media.items.len >= max_media_items) {
                        try appendResultText(self.gpa, &out, "[additional MCP image omitted: four-image limit]");
                        continue;
                    }
                    const encoded = stringField(item.object, "data") orelse {
                        try appendResultText(self.gpa, &out, "[invalid MCP image: missing data]");
                        continue;
                    };
                    const mime = stringField(item.object, "mimeType") orelse "application/octet-stream";
                    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch {
                        try appendResultText(self.gpa, &out, "[invalid MCP image: malformed base64]");
                        continue;
                    };
                    if (decoded_len == 0 or decoded_len > max_media_bytes) {
                        try appendResultText(self.gpa, &out, "[MCP image omitted: invalid size]");
                        continue;
                    }
                    const media_item = decodeImage(self.gpa, self.name, media.items.len + 1, mime, encoded, decoded_len) catch |err| switch (err) {
                        error.InvalidBase64 => {
                            try appendResultText(self.gpa, &out, "[invalid MCP image: malformed base64]");
                            continue;
                        },
                        error.UnsupportedImage => {
                            try appendResultText(self.gpa, &out, "[unsupported MCP image format]");
                            continue;
                        },
                        else => return err,
                    };
                    media.append(self.gpa, media_item) catch |err| {
                        media_item.deinit(self.gpa);
                        return err;
                    };
                } else if (std.mem.eql(u8, kind, "audio")) {
                    try appendResultText(self.gpa, &out, "[MCP audio content is not yet provider-compatible]");
                }
            }
        }
        if (out.items.len == 0) {
            if (result.get("structuredContent")) |structured| {
                const encoded = try std.json.Stringify.valueAlloc(self.gpa, structured, .{});
                defer self.gpa.free(encoded);
                try out.appendSlice(self.gpa, encoded);
            }
        }
        if (out.items.len == 0) {
            if (media.items.len > 0)
                try out.print(self.gpa, "MCP tool returned {d} image(s)", .{media.items.len})
            else
                try out.appendSlice(self.gpa, "MCP tool completed with no text output");
        }
        const is_error = if (result.get("isError")) |flag| flag == .bool and flag.bool else false;
        return .{
            .output = try out.toOwnedSlice(self.gpa),
            .status = if (is_error) .err else .ok,
            .media = try media.toOwnedSlice(self.gpa),
        };
    }

    fn fail(self: *Server, comptime fmt: []const u8, args: anytype) CallResult {
        return .{
            .output = std.fmt.allocPrint(self.gpa, "error: " ++ fmt, args) catch @panic("oom"),
            .status = .err,
        };
    }

    fn interrupted(self: *Server) CallResult {
        return .{
            .output = self.gpa.dupe(u8, "error: MCP call interrupted by user") catch @panic("oom"),
            .status = .interrupted,
        };
    }
};

fn appendResultText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    if (out.items.len > 0) try out.append(gpa, '\n');
    try out.appendSlice(gpa, text);
}

fn decodeImage(
    gpa: std.mem.Allocator,
    server_name: []const u8,
    index: usize,
    mime: []const u8,
    encoded: []const u8,
    decoded_len: usize,
) !registry.MediaOutput {
    const bytes = try gpa.alloc(u8, decoded_len);
    errdefer gpa.free(bytes);
    std.base64.standard.Decoder.decode(bytes, encoded) catch return error.InvalidBase64;
    if (!validImage(mime, bytes)) return error.UnsupportedImage;
    const mime_owned = try gpa.dupe(u8, mime);
    errdefer gpa.free(mime_owned);
    const name = try std.fmt.allocPrint(gpa, "{s}-image-{d}{s}", .{ server_name, index, imageExtension(mime) });
    return .{ .bytes = bytes, .mime = mime_owned, .name = name };
}

fn validImage(mime: []const u8, bytes: []const u8) bool {
    if (std.mem.eql(u8, mime, "image/png"))
        return bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n");
    if (std.mem.eql(u8, mime, "image/jpeg"))
        return bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xff\xd8\xff");
    if (std.mem.eql(u8, mime, "image/gif"))
        return bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"));
    if (std.mem.eql(u8, mime, "image/webp"))
        return bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP");
    return false;
}

fn imageExtension(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return ".png";
    if (std.mem.eql(u8, mime, "image/jpeg")) return ".jpg";
    if (std.mem.eql(u8, mime, "image/gif")) return ".gif";
    if (std.mem.eql(u8, mime, "image/webp")) return ".webp";
    return ".img";
}

const ModernMeta = struct {
    @"io.modelcontextprotocol/protocolVersion": []const u8,
    @"io.modelcontextprotocol/clientInfo": struct { name: []const u8, version: []const u8 },
    @"io.modelcontextprotocol/clientCapabilities": struct {},
};

fn modernMeta() ModernMeta {
    return .{
        .@"io.modelcontextprotocol/protocolVersion" = current_protocol,
        .@"io.modelcontextprotocol/clientInfo" = .{ .name = "marlin", .version = build_options.version },
        .@"io.modelcontextprotocol/clientCapabilities" = .{},
    };
}

/// Deadline watchdog for blocking stdio reads. Killing the child closes its
/// stdout pipe, which unblocks the reader; finish() always joins before the
/// Server mutates the child again.
const DeadlineReason = enum(u8) { none, timed_out, cancelled };

const Deadline = struct {
    server: *Server,
    cancel: ?*const std.atomic.Value(bool) = null,
    done: std.atomic.Value(bool) = .init(false),
    reason: std.atomic.Value(DeadlineReason) = .init(.none),
    thread: std.Thread,

    fn start(self: *Deadline) !void {
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn finish(self: *Deadline) void {
        self.done.store(true, .release);
        self.thread.join();
    }

    fn watch(self: *Deadline) void {
        var elapsed: u32 = 0;
        while (elapsed < self.server.timeout_ms) : (elapsed += 25) {
            if (self.done.load(.acquire)) return;
            if (isCancelled(self.cancel)) return self.abort(.cancelled);
            self.server.io.sleep(.fromMilliseconds(25), .awake) catch return;
        }
        if (self.done.load(.acquire)) return;
        if (isCancelled(self.cancel)) return self.abort(.cancelled);
        self.abort(.timed_out);
    }

    fn abort(self: *Deadline, reason: DeadlineReason) void {
        self.reason.store(reason, .release);
        if (self.server.child) |*child| child.kill(self.server.io);
    }

    fn mapFailure(self: *Deadline, fallback: anyerror) anyerror {
        return switch (self.reason.load(.acquire)) {
            .none => fallback,
            .timed_out => error.Timeout,
            .cancelled => error.Cancelled,
        };
    }
};

fn isCancelled(cancel: ?*const std.atomic.Value(bool)) bool {
    return if (cancel) |flag| flag.load(.acquire) else false;
}

fn resultObject(response: std.json.Value) ?std.json.ObjectMap {
    if (response != .object) return null;
    const result = response.object.get("result") orelse return null;
    if (result != .object) return null;
    return result.object;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

pub fn publicToolName(gpa: std.mem.Allocator, server: []const u8, tool: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(gpa, "mcp__{s}__{s}", .{ server, tool });
    defer gpa.free(raw);
    for (raw) |*ch| {
        if (!std.ascii.isAlphanumeric(ch.*) and ch.* != '_' and ch.* != '-') ch.* = '_';
    }
    // OpenAI-compatible providers commonly cap function names at 64 bytes.
    // Retain a readable prefix and a stable collision-resistant suffix.
    if (raw.len <= 64) return gpa.dupe(u8, raw);
    const digest = std.hash.Wyhash.hash(0, raw);
    return std.fmt.allocPrint(gpa, "{s}__{x:0>16}", .{ raw[0..46], digest });
}
