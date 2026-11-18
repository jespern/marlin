const std = @import("std");
const mcp_server = @import("mcp_server.zig");

const both: mcp_server.Grant = .{ .name = "robin", .read = true, .act = true };
const reader: mcp_server.Grant = .{ .name = "robin", .read = true, .act = false };
const actor: mcp_server.Grant = .{ .name = "robin", .read = false, .act = true };

/// Records the call and answers like the daemon would.
const Fake = struct {
    caller: []const u8 = "",
    name: []const u8 = "",
    args: []const u8 = "",
    reachable: bool = true,
    text: []const u8 = "ok",

    fn backend(self: *Fake) mcp_server.Backend {
        return .{ .ctx = self, .call = call };
    }
    fn call(ctx: ?*anyopaque, arena: std.mem.Allocator, caller: []const u8, name: []const u8, args_json: []const u8) ?mcp_server.ToolResult {
        const self: *Fake = @ptrCast(@alignCast(ctx.?));
        if (!self.reachable) return null;
        self.caller = arena.dupe(u8, caller) catch return null;
        self.name = arena.dupe(u8, name) catch return null;
        self.args = arena.dupe(u8, args_json) catch return null;
        return .{ .text = self.text, .ok = true };
    }
};

const meta =
    \\"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}
;

/// A well-formed 2026-07-28 request: body with _meta, matching headers.
fn modern(arena: std.mem.Allocator, fake: *Fake, grant: mcp_server.Grant, method: []const u8, name: ?[]const u8, extra: []const u8) !mcp_server.Response {
    const body = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"{s}\",\"params\":{{{s}{s}}}}}", .{ method, meta, extra });
    return mcp_server.handle(arena, .{ .body = body, .version_header = "2026-07-28", .method_header = method, .name_header = name, .grant = grant }, fake.backend());
}

fn legacy(arena: std.mem.Allocator, fake: *Fake, grant: mcp_server.Grant, body: []const u8) !mcp_server.Response {
    return mcp_server.handle(arena, .{ .body = body, .version_header = "2025-11-25", .grant = grant }, fake.backend());
}

fn json(arena: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    return (try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{})).object;
}

fn errorCode(arena: std.mem.Allocator, body: []const u8) !i64 {
    return (try json(arena, body)).get("error").?.object.get("code").?.integer;
}

test "server/discover names both versions, objects for capabilities, and a complete result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{};
    const response = try modern(arena, &fake, both, "server/discover", null, "");
    try std.testing.expectEqual(@as(u16, 200), response.status);
    const result = (try json(arena, response.body)).get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expectEqualStrings("2026-07-28", result.get("supportedVersions").?.array.items[0].string);
    try std.testing.expectEqualStrings("2025-11-25", result.get("supportedVersions").?.array.items[1].string);
    // `{}`, not `[]`: an empty Zig struct literal serializes as an array.
    try std.testing.expect(result.get("capabilities").?.object.get("tools").? == .object);
    try std.testing.expect(result.get("capabilities").?.object.get("resources").?.object.get("subscribe").?.bool);
    try std.testing.expectEqualStrings("marlin", result.get("_meta").?.object.get("io.modelcontextprotocol/serverInfo").?.object.get("name").?.string);
}

test "a 2026-07-28 request must carry its _meta and repeat it in headers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{};

    // No capabilities in _meta: malformed.
    const no_caps = try mcp_server.handle(arena, .{
        .body =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}
        ,
        .version_header = "2026-07-28",
        .method_header = "tools/list",
        .grant = both,
    }, fake.backend());
    try std.testing.expectEqual(@as(u16, 400), no_caps.status);
    try std.testing.expectEqual(mcp_server.code_invalid_params, try errorCode(arena, no_caps.body));

    // The version header says modern but the body has no _meta.
    const no_meta = try mcp_server.handle(arena, .{ .body =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    , .version_header = "2026-07-28", .method_header = "tools/list", .grant = both }, fake.backend());
    try std.testing.expectEqual(@as(u16, 400), no_meta.status);

    // Headers that disagree with the body, or are missing.
    const body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{" ++ meta ++ ",\"name\":\"sessions\"}}";
    for ([_]mcp_server.Request{
        .{ .body = body, .version_header = "2025-11-25", .method_header = "tools/call", .name_header = "sessions", .grant = both },
        .{ .body = body, .version_header = "2026-07-28", .method_header = "tools/list", .name_header = "sessions", .grant = both },
        .{ .body = body, .version_header = "2026-07-28", .method_header = "tools/call", .name_header = "attention", .grant = both },
        .{ .body = body, .version_header = "2026-07-28", .method_header = null, .name_header = "sessions", .grant = both },
        .{ .body = body, .version_header = "2026-07-28", .method_header = "tools/call", .name_header = null, .grant = both },
    }) |req| {
        const response = try mcp_server.handle(arena, req, fake.backend());
        try std.testing.expectEqual(@as(u16, 400), response.status);
        try std.testing.expectEqual(mcp_server.code_header_mismatch, try errorCode(arena, response.body));
    }
    // A non-ASCII value travels base64-encoded.
    const encoded = try mcp_server.handle(arena, .{ .body = body, .version_header = "2026-07-28", .method_header = "tools/call", .name_header = "=?base64?c2Vzc2lvbnM=?=", .grant = both }, fake.backend());
    try std.testing.expectEqual(@as(u16, 200), encoded.status);
}

test "an unknown version is refused with the supported ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{};
    const response = try mcp_server.handle(arena, .{ .body =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2030-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}
    , .version_header = "2030-01-01", .method_header = "tools/list", .grant = both }, fake.backend());
    try std.testing.expectEqual(@as(u16, 400), response.status);
    const err = (try json(arena, response.body)).get("error").?.object;
    try std.testing.expectEqual(mcp_server.code_unsupported_version, err.get("code").?.integer);
    try std.testing.expectEqualStrings("2030-01-01", err.get("data").?.object.get("requested").?.string);
    try std.testing.expectEqual(@as(usize, 2), err.get("data").?.object.get("supported").?.array.items.len);
}

test "older clients initialize without a session and use the same tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{};
    const init = try mcp_server.handle(arena, .{ .body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}
    , .grant = both }, fake.backend());
    const result = (try json(arena, init.body)).get("result").?.object;
    try std.testing.expectEqualStrings("2025-06-18", result.get("protocolVersion").?.string);
    try std.testing.expect(result.get("capabilities").?.object.get("tools").? == .object);
    // No subscriptions for them: there is no GET stream.
    try std.testing.expect(result.get("capabilities").?.object.get("resources").?.object.get("subscribe") == null);
    try std.testing.expect(result.get("resultType") == null);

    // A version this server never spoke gets the newest older one back.
    const odd = try mcp_server.handle(arena, .{ .body =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-01-01"}}
    , .grant = both }, fake.backend());
    try std.testing.expectEqualStrings("2025-11-25", (try json(arena, odd.body)).get("result").?.object.get("protocolVersion").?.string);

    // Notifications and stray responses are accepted with no body.
    try std.testing.expectEqual(@as(u16, 202), (try legacy(arena, &fake, both,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )).status);
    try std.testing.expectEqual(@as(u16, 202), (try legacy(arena, &fake, both,
        \\{"jsonrpc":"2.0","id":3,"result":{}}
    )).status);
    // ping still answers for them; 2026-07-28 removed it.
    try std.testing.expectEqual(@as(u16, 200), (try legacy(arena, &fake, both,
        \\{"jsonrpc":"2.0","id":4,"method":"ping"}
    )).status);
    try std.testing.expectEqual(@as(u16, 404), (try modern(arena, &fake, both, "ping", null, "")).status);
    // Batches went away in 2025-06-18.
    try std.testing.expectEqual(@as(u16, 400), (try legacy(arena, &fake, both, "[]")).status);
    // Unsupported legacy header.
    try std.testing.expectEqual(@as(u16, 400), (try mcp_server.handle(arena, .{ .body =
        \\{"jsonrpc":"2.0","id":5,"method":"tools/list"}
    , .version_header = "1999-01-01", .grant = both }, fake.backend())).status);
}

test "a token sees and calls only the tools its scopes allow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{};
    const Names = struct {
        fn of(a: std.mem.Allocator, f: *Fake, grant: mcp_server.Grant) ![]const u8 {
            const response = try modern(a, f, grant, "tools/list", null, "");
            var out: std.ArrayList(u8) = .empty;
            for ((try json(a, response.body)).get("result").?.object.get("tools").?.array.items) |tool| {
                try out.appendSlice(a, tool.object.get("name").?.string);
                try out.append(a, ' ');
            }
            return out.items;
        }
    };
    try std.testing.expectEqualStrings("sessions read_session wait_for_session attention ", try Names.of(arena, &fake, reader));
    try std.testing.expectEqualStrings("message_session approve answer ", try Names.of(arena, &fake, actor));
    try std.testing.expectEqualStrings("sessions read_session wait_for_session attention message_session approve answer ", try Names.of(arena, &fake, both));

    const denied = try modern(arena, &fake, reader, "tools/call", "approve", ",\"name\":\"approve\",\"arguments\":{}");
    try std.testing.expectEqual(@as(u16, 403), denied.status);
    try std.testing.expectEqual(mcp_server.Scope.act, denied.insufficient_scope.?);
    try std.testing.expectEqualStrings("", fake.name); // never reached the daemon
    const blind = try modern(arena, &fake, actor, "tools/call", "sessions", ",\"name\":\"sessions\"");
    try std.testing.expectEqual(mcp_server.Scope.read, blind.insufficient_scope.?);
    try std.testing.expectEqual(@as(usize, 0), (try json(arena, (try modern(arena, &fake, actor, "resources/list", null, "")).body)).get("result").?.object.get("resources").?.array.items.len);
}

test "tools/call reaches the daemon as the token's holder; the log comes back structured" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .text = "{\"latest\":3,\"events\":[]}" };
    const response = try modern(arena, &fake, both, "tools/call", "attention", ",\"name\":\"attention\",\"arguments\":{\"after\":2}");
    try std.testing.expectEqualStrings("robin", fake.caller);
    try std.testing.expectEqualStrings("attention", fake.name);
    try std.testing.expectEqualStrings("{\"after\":2}", fake.args);
    const result = (try json(arena, response.body)).get("result").?.object;
    try std.testing.expectEqual(@as(i64, 3), result.get("structuredContent").?.object.get("latest").?.integer);
    try std.testing.expectEqualStrings(fake.text, result.get("content").?.array.items[0].object.get("text").?.string);
    try std.testing.expect(!result.get("isError").?.bool);

    // Unknown tool: a protocol error. No daemon: a tool error.
    try std.testing.expectEqual(mcp_server.code_invalid_params, try errorCode(arena, (try modern(arena, &fake, both, "tools/call", "nope", ",\"name\":\"nope\"")).body));
    fake.reachable = false;
    const offline = try modern(arena, &fake, both, "tools/call", "sessions", ",\"name\":\"sessions\"");
    try std.testing.expect((try json(arena, offline.body)).get("result").?.object.get("isError").?.bool);
}

test "the attention resource reads the newest moments; others are not found" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{ .text = "{\"latest\":0,\"events\":[]}" };
    const read = try modern(arena, &fake, reader, "resources/read", mcp_server.resource_uri, ",\"uri\":\"marlin://attention\"");
    try std.testing.expectEqualStrings("attention", fake.name);
    try std.testing.expectEqualStrings("{\"last\":50}", fake.args);
    const contents = (try json(arena, read.body)).get("result").?.object.get("contents").?.array.items[0].object;
    try std.testing.expectEqualStrings("application/json", contents.get("mimeType").?.string);
    try std.testing.expectEqualStrings(fake.text, contents.get("text").?.string);

    const missing = try modern(arena, &fake, reader, "resources/read", "marlin://nope", ",\"uri\":\"marlin://nope\"");
    try std.testing.expectEqual(mcp_server.code_invalid_params, try errorCode(arena, missing.body));
    const old_missing = try legacy(arena, &fake, reader,
        \\{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"marlin://nope"}}
    );
    try std.testing.expectEqual(mcp_server.code_resource_not_found, try errorCode(arena, old_missing.body));
}

test "subscriptions/listen acknowledges only the attention resource and tags each update" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake: Fake = .{};
    const response = try modern(arena, &fake, reader, "subscriptions/listen", null, ",\"notifications\":{\"toolsListChanged\":true,\"resourceSubscriptions\":[\"marlin://attention\",\"file:///x\"]}");
    const listen = response.listen.?;
    const ack = try json(arena, response.body);
    try std.testing.expectEqualStrings("notifications/subscriptions/acknowledged", ack.get("method").?.string);
    const params = ack.get("params").?.object;
    try std.testing.expectEqual(@as(i64, 7), params.get("_meta").?.object.get("io.modelcontextprotocol/subscriptionId").?.integer);
    const granted = params.get("notifications").?.object;
    try std.testing.expect(granted.get("toolsListChanged") == null);
    try std.testing.expectEqual(@as(usize, 1), granted.get("resourceSubscriptions").?.array.items.len);
    const updated = try json(arena, listen.updated.?);
    try std.testing.expectEqualStrings("notifications/resources/updated", updated.get("method").?.string);
    try std.testing.expectEqualStrings("marlin://attention", updated.get("params").?.object.get("uri").?.string);
    try std.testing.expectEqual(@as(i64, 7), updated.get("params").?.object.get("_meta").?.object.get("io.modelcontextprotocol/subscriptionId").?.integer);
    const end = try json(arena, listen.end);
    try std.testing.expectEqualStrings("complete", end.get("result").?.object.get("resultType").?.string);

    // Asking for nothing this server sends: acknowledged, then done.
    const nothing = try modern(arena, &fake, reader, "subscriptions/listen", null, ",\"notifications\":{\"toolsListChanged\":true}");
    try std.testing.expect(nothing.listen.?.updated == null);
    // Listening needs the read scope.
    try std.testing.expectEqual(@as(u16, 403), (try modern(arena, &fake, actor, "subscriptions/listen", null, ",\"notifications\":{}")).status);
}
