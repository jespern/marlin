//! Guest-session adapter for the official `codex app-server` protocol.
//!
//! The app-server owns inference, context, and tools using the user's existing
//! ChatGPT login. Marlin owns process lifecycle, transcript projection, and
//! approval presentation. This module deliberately contains only the stable
//! stdio JSONL boundary; the turn driver lives in loop.zig.

const std = @import("std");

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

test "otel overrides compose per-signal URLs and gate the content-bearing log exporter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try buildArgv(arena, null, null);
    try std.testing.expectEqual(@as(usize, 4), plain.len);
    try std.testing.expectEqualStrings("app-server", plain[1]);

    const structural = try buildArgv(arena, null, .{
        .base_endpoint = "https://otel.example/",
        .headers = "Authorization=Bearer%20secret",
    });
    try std.testing.expectEqual(@as(usize, 6), structural.len);
    try std.testing.expectEqualStrings("-c", structural[1]);
    try std.testing.expectEqualStrings(
        "otel.trace_exporter={ otlp-http = { endpoint = \"https://otel.example/v1/traces\", protocol = \"json\", headers = { \"Authorization\" = \"Bearer secret\" } } }",
        structural[2],
    );
    for (structural) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "log_user_prompt") == null);

    const content = try buildArgv(arena, null, .{
        .base_endpoint = "https://otel.example",
        .capture_content = true,
    });
    try std.testing.expectEqual(@as(usize, 10), content.len);
    try std.testing.expectEqualStrings(
        "otel.exporter={ otlp-http = { endpoint = \"https://otel.example/v1/logs\", protocol = \"json\" } }",
        content[4],
    );
    try std.testing.expectEqualStrings("otel.log_user_prompt=true", content[6]);

    // A traces-only collector cannot compose the logs URL: structural spans
    // still flow, the content-bearing log exporter stays off even when the
    // operator opted into content.
    const traces_only = try buildArgv(arena, null, .{
        .traces_endpoint = "https://otel.example/custom/traces",
        .capture_content = true,
    });
    try std.testing.expectEqual(@as(usize, 6), traces_only.len);
    try std.testing.expect(std.mem.indexOf(u8, traces_only[2], "custom/traces") != null);
}

test "app-server records distinguish responses, requests, and notifications" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const response = try decodeLine(arena,
        \\{"id":3,"result":{"thread":{"id":"thr_1"}}}
    );
    try std.testing.expectEqual(@as(i64, 3), response.response.id);
    try std.testing.expectEqualStrings("thr_1", strField(field(response.response.result.?, "thread").?, "id").?);

    const request = try decodeLine(arena,
        \\{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"itemId":"item-1"}}
    );
    try std.testing.expectEqualStrings("\"approval-1\"", request.request.id_json);
    try std.testing.expectEqualStrings("item-1", strField(request.request.params, "itemId").?);

    const notification = try decodeLine(arena,
        \\{"method":"item/agentMessage/delta","params":{"delta":"hello"}}
    );
    try std.testing.expectEqualStrings("hello", strField(notification.notification.params, "delta").?);
}
