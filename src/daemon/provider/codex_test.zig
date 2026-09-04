//! Unit tests for codex.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in codex.zig.

const std = @import("std");

const codex = @import("codex.zig");
const buildArgv = codex.buildArgv;
const decodeLine = codex.decodeLine;
const field = codex.field;
const strField = codex.strField;

test {
    std.testing.refAllDecls(codex);
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
