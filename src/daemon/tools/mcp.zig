//! MCP client over stdio (JSON-RPC over child process pipes) or Streamable
//! HTTP (one POST per message, answered as JSON or an SSE stream, with OAuth
//! bearer tokens from mcp_oauth). Config lists servers; their tools register
//! under provider-safe `mcp__<server>__<tool>` names with the same approval
//! policy machinery.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;

const block = @import("../../core/block.zig");
const registry = @import("registry.zig");
const http = @import("../provider/http.zig");
const sse = @import("../provider/sse.zig");
const oauth = @import("mcp_oauth.zig");

pub const current_protocol = "2026-07-28";
pub const legacy_protocol = "2025-11-25";
pub const request_timeout_ms: u32 = 15_000;
/// A remote exchange crosses the network and may run a slow tool.
pub const http_timeout_ms: i64 = 120_000;
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
    /// Arguments the schema marks `x-mcp-header`, mirrored as
    /// `Mcp-Param-<header>` on HTTP calls.
    header_params: []HeaderParam = &.{},

    fn deinit(self: *Tool, gpa: std.mem.Allocator) void {
        gpa.free(self.public_name);
        gpa.free(self.remote_name);
        gpa.free(self.description);
        gpa.free(self.schema_json);
        for (self.header_params) |param| {
            gpa.free(param.argument);
            gpa.free(param.header);
        }
        gpa.free(self.header_params);
    }
};

pub const HeaderParam = struct { argument: []u8, header: []u8 };

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

    // Streamable HTTP. `url` set means a remote server: no child process.
    url: ?[]u8 = null,
    /// Configured extra headers, as `Name: value` lines.
    headers: [][]u8 = &.{},
    pool: ?*http.Pool = null,
    /// Where OAuth credentials live; null disables bearer auth.
    auth_path: ?[]u8 = null,
    /// 2025-11-25 servers only: the session from `initialize`, the version
    /// it negotiated, and whether the handshake has completed.
    session_id: ?[]u8 = null,
    legacy_version: [32]u8 = undefined,
    legacy_version_len: usize = 0,
    http_ready: bool = false,
    http_timeout_ms: i64 = http_timeout_ms,
    /// The last 401/403 `WWW-Authenticate`, for `/mcp login`.
    challenge: ?[]u8 = null,
    /// Human words for the last failure, shown in `/mcp` status.
    detail_buf: [200]u8 = undefined,
    detail_len: usize = 0,

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

    /// A remote server. Nothing connects until discovery.
    pub fn initHttp(
        gpa: std.mem.Allocator,
        io: Io,
        name: []const u8,
        url: []const u8,
        headers: []const []const u8,
        environ: ?*const std.process.Environ.Map,
        auth_path: ?[]const u8,
    ) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .name = try gpa.dupe(u8, name),
            .argv = &.{},
            .environ = environ,
        };
        errdefer self.deinit();
        self.url = try gpa.dupe(u8, url);
        self.headers = try gpa.alloc([]u8, headers.len);
        for (self.headers) |*line| line.* = &.{};
        for (headers, 0..) |line, i| self.headers[i] = try gpa.dupe(u8, line);
        if (auth_path) |path| self.auth_path = try gpa.dupe(u8, path);
        const pool = try gpa.create(http.Pool);
        errdefer gpa.destroy(pool);
        pool.* = try http.Pool.init(gpa, io, environ);
        self.pool = pool;
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.reset();
        for (self.tools.items) |*tool| tool.deinit(self.gpa);
        self.tools.deinit(self.gpa);
        for (self.argv) |arg| self.gpa.free(arg);
        self.gpa.free(self.argv);
        if (self.url) |url| self.gpa.free(url);
        for (self.headers) |line| self.gpa.free(line);
        if (self.headers.len > 0) self.gpa.free(self.headers);
        if (self.auth_path) |path| self.gpa.free(path);
        if (self.challenge) |value| self.gpa.free(value);
        if (self.pool) |pool| {
            pool.deinit();
            self.gpa.destroy(pool);
        }
        self.gpa.free(self.name);
        self.gpa.destroy(self);
    }

    pub fn isRemote(self: *const Server) bool {
        return self.url != null;
    }

    /// The last failure in words, empty when there is none to add.
    pub fn detail(self: *const Server) []const u8 {
        return self.detail_buf[0..self.detail_len];
    }

    fn setDetail(self: *Server, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.bufPrint(&self.detail_buf, fmt, args) catch self.detail_buf[0..];
        self.detail_len = text.len;
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

        self.detail_len = 0;
        try self.start();
        self.mode = .modern;
        self.listAllTools() catch |err| {
            // A login is the fix, not an older protocol.
            if (err == error.McpUnauthorized or err == error.Cancelled) return err;
            // Most deployed servers still implement the 2025 lifecycle. A
            // fresh process avoids carrying any pre-initialize error state.
            self.reset();
            try self.start();
            self.mode = .legacy;
            try self.initializeLegacy();
            try self.listAllTools();
        };
        std.sort.insertion(Tool, self.tools.items, {}, struct {
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
        if (self.url != null) return;
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
        if (self.url != null) {
            if (self.session_id) |id| self.gpa.free(id);
            self.session_id = null;
            self.http_ready = false;
            return;
        }
        self.reader = null;
        self.writer = null;
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
    }

    fn ensureReady(self: *Server) !void {
        if (self.url != null) {
            if (self.mode == .legacy and !self.http_ready) try self.initializeLegacy();
            return;
        }
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
        const response = try self.request(arena_state.allocator(), "initialize", params);
        if (self.url != null) {
            // Later requests carry the version the server chose.
            const version = if (resultObject(response)) |result| stringField(result, "protocolVersion") orelse legacy_protocol else legacy_protocol;
            self.legacy_version_len = @min(version.len, self.legacy_version.len);
            @memcpy(self.legacy_version[0..self.legacy_version_len], version[0..self.legacy_version_len]);
        }
        try self.notify(
            \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        );
        if (self.url != null) self.http_ready = true;
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
        const header_params = try headerParams(self.gpa, schema_value);
        errdefer {
            for (header_params) |param| {
                self.gpa.free(param.argument);
                self.gpa.free(param.header);
            }
            self.gpa.free(header_params);
        }
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
            .header_params = header_params,
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
        if (self.url != null) return self.httpRequest(arena, method, params_json, cancel);
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
        if (self.url != null) {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const method = blk: {
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), line, .{}) catch break :blk "";
                break :blk if (parsed == .object) stringField(parsed.object, "method") orelse "" else "";
            };
            _ = try self.httpPost(arena_state.allocator(), method, null, line, null, null);
            return;
        }
        try self.writeMessage(line);
    }

    // ------------------------------------------------- Streamable HTTP --

    const HttpOutcome = union(enum) { response: std.json.Value, accepted, unauthorized, session_expired };

    fn httpRequest(
        self: *Server,
        arena: std.mem.Allocator,
        method: []const u8,
        params_json: []const u8,
        cancel: ?*const std.atomic.Value(bool),
    ) !std.json.Value {
        const id = self.next_id;
        self.next_id +%= 1;
        const body = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params_json });
        var retried = false;
        while (true) {
            switch (try self.httpPost(arena, method, params_json, body, id, cancel)) {
                .response => |value| return value,
                .accepted => return error.InvalidMcpResponse,
                .unauthorized => {
                    // One refresh, then the user has to log in again.
                    if (!retried and self.forceRefresh(arena)) {
                        retried = true;
                        continue;
                    }
                    self.setDetail("needs login: /mcp login {s}", .{self.name});
                    return error.McpUnauthorized;
                },
                .session_expired => {
                    if (retried or std.mem.eql(u8, method, "initialize")) return error.McpSessionExpired;
                    retried = true;
                    self.reset();
                    try self.initializeLegacy();
                },
            }
        }
    }

    /// One POST. `id` null means a notification, answered 202.
    fn httpPost(
        self: *Server,
        arena: std.mem.Allocator,
        method: []const u8,
        params_json: ?[]const u8,
        body: []const u8,
        id: ?u64,
        cancel: ?*const std.atomic.Value(bool),
    ) !HttpOutcome {
        var headers: std.ArrayList(std.http.Header) = .empty;
        for (self.headers) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            try headers.append(arena, .{
                .name = std.mem.trim(u8, line[0..colon], " \t"),
                .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
            });
        }
        if (self.mode == .modern) {
            try headers.append(arena, .{ .name = "MCP-Protocol-Version", .value = current_protocol });
            try headers.append(arena, .{ .name = "Mcp-Method", .value = try encodeHeaderValue(arena, method) });
            if (params_json) |params| try self.appendRoutingHeaders(arena, &headers, method, params);
        } else if (!std.mem.eql(u8, method, "initialize")) {
            const version = if (self.legacy_version_len > 0) self.legacy_version[0..self.legacy_version_len] else legacy_protocol;
            try headers.append(arena, .{ .name = "MCP-Protocol-Version", .value = version });
            if (self.session_id) |session| try headers.append(arena, .{ .name = "Mcp-Session-Id", .value = session });
        }

        var sink: ResponseSink = .{ .gpa = self.gpa, .arena = arena, .id = id, .parser = .init(self.gpa) };
        defer sink.deinit();
        const pool = self.pool orelse return error.McpServerNotRunning;
        const result = http.exchange(&pool.client, self.gpa, .{
            .method = .POST,
            .url = self.url.?,
            .headers = headers.items,
            .bearer = self.bearerToken(arena),
            .content_type = "application/json",
            .accept = "application/json, text/event-stream",
            .body = body,
            .max_bytes = max_message_bytes,
            .timeout_ms = self.http_timeout_ms,
            .cancel = @constCast(cancel),
            .capture = &.{ "Mcp-Session-Id", "WWW-Authenticate" },
            .sink = .{ .ctx = &sink, .func = ResponseSink.write },
        }) catch |err| {
            if (err == error.Cancelled) return error.Cancelled;
            self.setDetail("{s}", .{http.lastTransportDetail() orelse @errorName(err)});
            return err;
        };
        defer result.deinit(self.gpa);

        switch (result.status) {
            401 => {
                self.setChallenge(result.captured[1]);
                return .unauthorized;
            },
            403 => {
                const header = result.captured[1] orelse "";
                if (std.mem.indexOf(u8, header, "insufficient_scope") != null) {
                    self.setChallenge(header);
                    return .unauthorized;
                }
                self.setDetail("HTTP 403 forbidden", .{});
                return error.McpHttpStatus;
            },
            404 => if (self.mode == .legacy and self.session_id != null) return .session_expired,
            202, 204 => if (id == null) return .accepted,
            else => {},
        }
        if (result.status != 200) {
            self.setDetail("HTTP {d} from {s}", .{ result.status, method });
            return error.McpHttpStatus;
        }
        if (id == null) return .accepted;
        if (std.mem.eql(u8, method, "initialize")) if (result.captured[0]) |session| {
            if (self.session_id) |old| self.gpa.free(old);
            self.session_id = try self.gpa.dupe(u8, session);
        };
        const value = sink.found orelse blk: {
            // A plain JSON body; an SSE stream that ended without our answer
            // parses as nothing here and fails below.
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, sink.raw.items, .{ .allocate = .alloc_always }) catch
                return error.InvalidMcpResponse;
            break :blk parsed;
        };
        if (!responseMatches(value, id.?)) return error.InvalidMcpResponse;
        if (value.object.get("error")) |rpc_error| {
            if (rpc_error == .object) if (stringField(rpc_error.object, "message")) |message| self.setDetail("{s}", .{message});
            return error.McpRpcError;
        }
        if (value.object.get("result") == null) return error.InvalidMcpResponse;
        return .{ .response = value };
    }

    /// Modern requests mirror routing facts into headers: the tool or
    /// resource name, and schema-marked arguments as Mcp-Param-*.
    fn appendRoutingHeaders(
        self: *Server,
        arena: std.mem.Allocator,
        headers: *std.ArrayList(std.http.Header),
        method: []const u8,
        params_json: []const u8,
    ) !void {
        const named = std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "prompts/get") or
            std.mem.eql(u8, method, "resources/read");
        if (!named) return;
        const params = std.json.parseFromSliceLeaky(std.json.Value, arena, params_json, .{ .allocate = .alloc_always }) catch return;
        if (params != .object) return;
        const name = stringField(params.object, "name") orelse stringField(params.object, "uri") orelse return;
        try headers.append(arena, .{ .name = "Mcp-Name", .value = try encodeHeaderValue(arena, name) });
        if (!std.mem.eql(u8, method, "tools/call")) return;
        const tool = for (self.tools.items) |*candidate| {
            if (std.mem.eql(u8, candidate.remote_name, name)) break candidate;
        } else return;
        const args = params.object.get("arguments") orelse return;
        if (args != .object) return;
        for (tool.header_params) |param| {
            const value = args.object.get(param.argument) orelse continue;
            const text = switch (value) {
                .string => |v| v,
                .integer => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
                .float => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
                .number_string => |v| v,
                .bool => |v| if (v) "true" else "false",
                else => continue,
            };
            try headers.append(arena, .{
                .name = try std.fmt.allocPrint(arena, "Mcp-Param-{s}", .{param.header}),
                .value = try encodeHeaderValue(arena, text),
            });
        }
    }

    fn setChallenge(self: *Server, header: ?[]const u8) void {
        if (self.challenge) |old| self.gpa.free(old);
        self.challenge = if (header) |value| self.gpa.dupe(u8, value) catch null else null;
    }

    /// The stored access token, refreshed first when it has expired.
    fn bearerToken(self: *Server, arena: std.mem.Allocator) ?[]const u8 {
        const path = self.auth_path orelse return null;
        const creds = oauth.load(arena, self.io, path, self.name, self.url.?) orelse return null;
        if (!creds.expired(nowMs(self.io))) return creds.access_token;
        const refreshed = self.refreshWith(arena, creds) orelse return null;
        return refreshed.access_token;
    }

    /// After a 401: refresh whatever is stored, if it can be refreshed.
    fn forceRefresh(self: *Server, arena: std.mem.Allocator) bool {
        const path = self.auth_path orelse return false;
        const creds = oauth.load(arena, self.io, path, self.name, self.url.?) orelse return false;
        return self.refreshWith(arena, creds) != null;
    }

    fn refreshWith(self: *Server, arena: std.mem.Allocator, creds: oauth.Credentials) ?oauth.Credentials {
        if (creds.refresh_token == null) return null;
        const pool = self.pool orelse return null;
        const refreshed = oauth.refresh(&pool.client, self.gpa, arena, nowMs(self.io), creds) catch |err| {
            std.log.warn("MCP server '{s}' token refresh failed: {t} {s}", .{ self.name, err, oauth.failureDetail() });
            return null;
        };
        oauth.save(self.gpa, self.io, self.auth_path.?, self.name, refreshed) catch |err|
            std.log.warn("MCP server '{s}' could not store refreshed token: {t}", .{ self.name, err });
        return refreshed;
    }

    /// The challenge from the last 401/403, for starting a login.
    pub fn lastChallenge(self: *const Server) ?[]const u8 {
        return self.challenge;
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

/// Collects an HTTP response body and, when it is an SSE stream, stops at
/// the event carrying the response to `id`: a server may keep the stream
/// open after answering.
const ResponseSink = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    id: ?u64,
    parser: sse.Parser,
    raw: std.ArrayList(u8) = .empty,
    found: ?std.json.Value = null,

    fn deinit(self: *ResponseSink) void {
        self.parser.deinit();
        self.raw.deinit(self.gpa);
    }

    fn write(ctx: *anyopaque, bytes: []const u8) bool {
        const self: *ResponseSink = @ptrCast(@alignCast(ctx));
        self.raw.appendSlice(self.gpa, bytes) catch return false;
        if (self.id == null) return true;
        self.parser.feed(bytes, self, onEvent) catch return true;
        return self.found == null;
    }

    fn onEvent(self: *ResponseSink, event: sse.Event) void {
        if (self.found != null or self.id == null) return;
        const value = std.json.parseFromSliceLeaky(std.json.Value, self.arena, event.data, .{ .allocate = .alloc_always }) catch return;
        if (responseMatches(value, self.id.?)) self.found = value;
    }
};

fn responseMatches(value: std.json.Value, id: u64) bool {
    if (value != .object) return false;
    const response_id = value.object.get("id") orelse return false;
    return response_id == .integer and response_id.integer >= 0 and @as(u64, @intCast(response_id.integer)) == id;
}

/// Header values that are not plain visible ASCII (or that look like the
/// sentinel itself, or carry edge whitespace) travel as `=?base64?…?=`.
pub fn encodeHeaderValue(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    var plain = true;
    for (value) |c| if (c < 0x20 or c > 0x7e) {
        plain = false;
    };
    if (value.len > 0 and (value[0] == ' ' or value[value.len - 1] == ' ')) plain = false;
    if (std.mem.startsWith(u8, value, "=?base64?") and std.mem.endsWith(u8, value, "?=")) plain = false;
    if (plain) return value;
    const encoder = std.base64.standard.Encoder;
    const out = try arena.alloc(u8, "=?base64?".len + encoder.calcSize(value.len) + "?=".len);
    @memcpy(out[0.."=?base64?".len], "=?base64?");
    _ = encoder.encode(out["=?base64?".len .. out.len - 2], value);
    @memcpy(out[out.len - 2 ..], "?=");
    return out;
}

/// `x-mcp-header` markers on top-level schema properties. Header names must
/// be HTTP tokens; anything else is ignored rather than sent malformed.
fn headerParams(gpa: std.mem.Allocator, schema: std.json.Value) ![]HeaderParam {
    var out: std.ArrayList(HeaderParam) = .empty;
    errdefer {
        for (out.items) |param| {
            gpa.free(param.argument);
            gpa.free(param.header);
        }
        out.deinit(gpa);
    }
    if (schema != .object) return out.toOwnedSlice(gpa);
    const properties = schema.object.get("properties") orelse return out.toOwnedSlice(gpa);
    if (properties != .object) return out.toOwnedSlice(gpa);
    var it = properties.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const marker = entry.value_ptr.object.get("x-mcp-header") orelse continue;
        if (marker != .string or marker.string.len == 0) continue;
        const valid = for (marker.string) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') break false;
        } else true;
        if (!valid) continue;
        const argument = try gpa.dupe(u8, entry.key_ptr.*);
        errdefer gpa.free(argument);
        const header = try gpa.dupe(u8, marker.string);
        errdefer gpa.free(header);
        try out.append(gpa, .{ .argument = argument, .header = header });
    }
    return out.toOwnedSlice(gpa);
}

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

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
