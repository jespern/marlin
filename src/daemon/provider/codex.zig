//! Guest-session adapter for the official `codex app-server` protocol.
//!
//! The app-server owns inference, context, and tools using the user's existing
//! ChatGPT login. Marlin owns process lifecycle, transcript projection, and
//! approval presentation. This module contains the stable stdio JSONL boundary
//! and account-scoped model discovery; the turn driver lives in loop.zig.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const process_io = @import("../process_io.zig");

pub const binary_env = "MARLIN_CODEX_BIN";
pub const default_binary = "codex";

pub fn binaryPath(environ: ?*const std.process.Environ.Map) []const u8 {
    const env = environ orelse return default_binary;
    const override = env.get(binary_env) orelse return default_binary;
    return if (override.len == 0) default_binary else override;
}

/// Collector settings for codex's own [otel] config, passed as `-c` root
/// overrides. Codex has no OTEL_* environment interface, and its otlp-http
/// endpoint is used verbatim, so full per-signal URLs are composed here.
pub const Otel = struct {
    base_endpoint: []const u8 = "",
    traces_endpoint: []const u8 = "",
    /// Standard comma-separated, percent-encoded `name=value` form.
    headers: []const u8 = "",
    capture_content: bool = false,
};

pub fn buildArgv(
    arena: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    otel: ?Otel,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, binaryPath(environ));
    if (otel) |cfg| try appendOtelOverrides(arena, &argv, cfg);
    try argv.appendSlice(arena, &.{ "app-server", "--listen", "stdio://" });
    return argv.items;
}

pub const CatalogModel = struct {
    id: []u8,
};

fn writeJsonLine(arena: std.mem.Allocator, writer: *Io.Writer, value: anytype) !void {
    const encoded = try std.json.Stringify.valueAlloc(arena, value, .{});
    try writer.writeAll(encoded);
    try writer.writeByte('\n');
    try writer.flush();
}

const CatalogWatcher = struct {
    io: Io,
    cancel: ?*const std.atomic.Value(bool),
    group: std.posix.pid_t,
    done: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(watcher: *CatalogWatcher) void {
        const deadline = Io.Timestamp.now(watcher.io, .awake).nanoseconds + 10 * std.time.ns_per_s;
        while (!watcher.done.load(.acquire)) {
            const cancelled = if (watcher.cancel) |flag| flag.load(.acquire) else false;
            if (cancelled or Io.Timestamp.now(watcher.io, .awake).nanoseconds >= deadline) {
                if (!cancelled) watcher.timed_out.store(true, .release);
                process_io.terminateProcessGroup(watcher.io, watcher.group, 100);
                return;
            }
            watcher.io.sleep(.fromMilliseconds(50), .awake) catch return;
        }
    }
};

const StderrDrain = struct {
    io: Io,
    file: Io.File,

    fn run(drain: *StderrDrain) void {
        var buffer: [4096]u8 = undefined;
        var reader = drain.file.reader(drain.io, &buffer);
        while (true) {
            const available = reader.interface.peekGreedy(1) catch return;
            reader.interface.toss(available.len);
        }
    }
};

fn waitResponse(arena: std.mem.Allocator, reader: *Io.Reader, request_id: i64) !Response {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return error.CodexAppServerExited;
        const inbound = decodeLine(arena, line) catch continue;
        switch (inbound) {
            .response => |response| if (response.id == request_id) return response,
            else => {},
        }
    }
}

pub fn fetchModels(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    cancel: ?*const std.atomic.Value(bool),
) ![]CatalogModel {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var child = try std.process.spawn(io, .{
        .argv = try buildArgv(arena, environ, null),
        .environ_map = environ,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    });
    var watcher = CatalogWatcher{ .io = io, .cancel = cancel, .group = child.id.? };
    const watcher_thread = std.Thread.spawn(.{}, CatalogWatcher.run, .{&watcher}) catch |err| {
        process_io.terminateProcessTree(&child, io, 100);
        return err;
    };
    var drain = StderrDrain{ .io = io, .file = child.stderr.? };
    const drain_thread = std.Thread.spawn(.{}, StderrDrain.run, .{&drain}) catch |err| {
        watcher.done.store(true, .release);
        watcher_thread.join();
        process_io.terminateProcessTree(&child, io, 100);
        return err;
    };
    defer {
        watcher.done.store(true, .release);
        watcher_thread.join();
        process_io.terminateProcessGroup(io, child.id.?, 0);
        drain_thread.join();
        _ = child.wait(io) catch {};
    }

    var writer_buffer: [16 * 1024]u8 = undefined;
    var writer_file = child.stdin.?.writer(io, &writer_buffer);
    const writer = &writer_file.interface;
    const line_buffer = try gpa.alloc(u8, 4 * 1024 * 1024);
    defer gpa.free(line_buffer);
    var reader_file = child.stdout.?.reader(io, line_buffer);
    const reader = &reader_file.interface;

    try writeJsonLine(arena, writer, .{
        .method = "initialize",
        .id = 1,
        .params = .{ .clientInfo = .{
            .name = "marlin",
            .title = "Marlin",
            .version = build_options.version,
        } },
    });
    const initialized = try waitResponse(arena, reader, 1);
    if (initialized.err != null) return error.CodexCatalogRpc;
    try writeJsonLine(arena, writer, .{ .method = "initialized" });
    try writeJsonLine(arena, writer, .{
        .method = "model/list",
        .id = 2,
        .params = .{ .includeHidden = false, .limit = 1000 },
    });
    const response = waitResponse(arena, reader, 2) catch |err| {
        if (watcher.timed_out.load(.acquire)) return error.CodexCatalogTimeout;
        return err;
    };
    if (response.err != null) return error.CodexCatalogRpc;
    return parseModels(gpa, response.result orelse return error.BadCodexCatalog);
}

pub fn parseModels(gpa: std.mem.Allocator, result: std.json.Value) ![]CatalogModel {
    const data = field(result, "data") orelse return error.BadCodexCatalog;
    if (data != .array) return error.BadCodexCatalog;

    var out: std.ArrayList(CatalogModel) = .empty;
    errdefer {
        for (out.items) |model| gpa.free(model.id);
        out.deinit(gpa);
    }
    for (data.array.items) |entry| {
        if (entry != .object) continue;
        if (boolField(entry, "hidden") orelse false) continue;
        const model = strField(entry, "model") orelse strField(entry, "id") orelse continue;
        if (model.len == 0 or std.mem.eql(u8, model, "default") or std.mem.indexOfScalar(u8, model, '/') != null) continue;
        const id = try std.fmt.allocPrint(gpa, "codex/{s}", .{model});
        errdefer gpa.free(id);
        var duplicate = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.id, id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            gpa.free(id);
            continue;
        }
        try out.append(gpa, .{ .id = id });
    }
    std.mem.sort(CatalogModel, out.items, {}, struct {
        fn lessThan(_: void, a: CatalogModel, b: CatalogModel) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
    return out.toOwnedSlice(gpa);
}

/// Trace spans are structural (names, timings, counts) and follow whenever a
/// collector is configured. The log-event exporter additionally carries tool
/// arguments and output previews with no redaction switch of its own, so it
/// is tied to the operator's explicit content opt-in, as is log_user_prompt.
fn appendOtelOverrides(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), cfg: Otel) !void {
    const base = std.mem.trimEnd(u8, cfg.base_endpoint, "/");
    const traces_url = if (cfg.traces_endpoint.len > 0)
        cfg.traces_endpoint
    else if (base.len > 0)
        try std.fmt.allocPrint(arena, "{s}/v1/traces", .{base})
    else
        return;
    try argv.appendSlice(arena, &.{
        "-c",
        try std.fmt.allocPrint(arena, "otel.trace_exporter={s}", .{
            try otlpHttpExporterToml(arena, traces_url, cfg.headers),
        }),
    });
    if (cfg.capture_content and base.len > 0) {
        try argv.appendSlice(arena, &.{
            "-c",
            try std.fmt.allocPrint(arena, "otel.exporter={s}", .{
                try otlpHttpExporterToml(
                    arena,
                    try std.fmt.allocPrint(arena, "{s}/v1/logs", .{base}),
                    cfg.headers,
                ),
            }),
            "-c",
            "otel.log_user_prompt=true",
        });
    }
}

fn otlpHttpExporterToml(arena: std.mem.Allocator, url: []const u8, headers: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{ otlp-http = { endpoint = ");
    try appendTomlString(arena, &out, url);
    try out.appendSlice(arena, ", protocol = \"json\"");
    var wrote_header = false;
    var entries = std.mem.splitScalar(u8, headers, ',');
    while (entries.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;
        const equal = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = std.Uri.percentDecodeInPlace(try arena.dupe(u8, std.mem.trim(u8, entry[0..equal], " \t")));
        const value = std.Uri.percentDecodeInPlace(try arena.dupe(u8, std.mem.trim(u8, entry[equal + 1 ..], " \t")));
        if (name.len == 0) continue;
        try out.appendSlice(arena, if (wrote_header) ", " else ", headers = { ");
        try appendTomlString(arena, &out, name);
        try out.appendSlice(arena, " = ");
        try appendTomlString(arena, &out, value);
        wrote_header = true;
    }
    if (wrote_header) try out.appendSlice(arena, " }");
    try out.appendSlice(arena, " } }");
    return out.items;
}

fn appendTomlString(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '"');
    for (text) |byte| switch (byte) {
        '"', '\\' => {
            try out.append(arena, '\\');
            try out.append(arena, byte);
        },
        else => try out.append(arena, byte),
    };
    try out.append(arena, '"');
}

pub const Response = struct {
    id: i64,
    result: ?std.json.Value,
    err: ?std.json.Value,
};

pub const Request = struct {
    id_json: []const u8,
    method: []const u8,
    params: std.json.Value,
};

pub const Notification = struct {
    method: []const u8,
    params: std.json.Value,
};

pub const Inbound = union(enum) {
    response: Response,
    request: Request,
    notification: Notification,
};

/// Parse one app-server JSONL record. Payload slices and values are owned by
/// `arena`. Unknown fields remain available in the dynamic params object so
/// protocol additions do not require a synchronized Marlin release.
pub fn decodeLine(arena: std.mem.Allocator, line: []const u8) !Inbound {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return error.BadLine;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, trimmed, .{
        .allocate = .alloc_always,
    }) catch return error.BadLine;
    if (parsed != .object) return error.BadLine;
    const root = parsed.object;

    if (root.get("method")) |method_value| {
        if (method_value != .string) return error.BadLine;
        const params = root.get("params") orelse std.json.Value{ .null = {} };
        if (root.get("id")) |id| {
            return .{ .request = .{
                .id_json = try std.json.Stringify.valueAlloc(arena, id, .{}),
                .method = method_value.string,
                .params = params,
            } };
        }
        return .{ .notification = .{ .method = method_value.string, .params = params } };
    }

    const id_value = root.get("id") orelse return error.BadLine;
    const id: i64 = switch (id_value) {
        .integer => |value| value,
        else => return error.BadLine,
    };
    return .{ .response = .{
        .id = id,
        .result = root.get("result"),
        .err = root.get("error"),
    } };
}

pub fn stringify(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

pub fn strField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const item = value.object.get(key) orelse return null;
    return if (item == .string) item.string else null;
}

pub fn intField(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    const item = value.object.get(key) orelse return null;
    return switch (item) {
        .integer => |number| number,
        else => null,
    };
}

pub fn boolField(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const item = value.object.get(key) orelse return null;
    return if (item == .bool) item.bool else null;
}

pub fn field(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    return value.object.get(key);
}
