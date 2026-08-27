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

pub fn buildArgv(arena: std.mem.Allocator, environ: ?*const std.process.Environ.Map) ![]const []const u8 {
    return arena.dupe([]const u8, &.{ binaryPath(environ), "app-server", "--listen", "stdio://" });
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
