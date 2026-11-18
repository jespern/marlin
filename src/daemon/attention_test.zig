const std = @import("std");
const attention = @import("attention.zig");

test "a pending approval or question becomes a moment with its id and detail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const approval = attention.pending(arena,
        \\{"approval_request":{"sid":7,"approval_id":"42","call_id":"c","tool":"Bash","args_json":"{\"command\":\"make\"}"}}
    ).?;
    try std.testing.expectEqual(attention.Kind.approval, approval.kind);
    try std.testing.expectEqualStrings("42", approval.id);
    try std.testing.expectEqualStrings("{\"approval_id\":\"42\",\"tool\":\"Bash\",\"args\":{\"command\":\"make\"}}", approval.detail);
    try std.testing.expectEqualStrings("{\"approval_id\":\"42\"}", try attention.resolvedDetail(arena, approval));

    const question = attention.pending(arena,
        \\{"question_request":{"sid":7,"question_id":"9","question":"Which?","options":["a","b"]}}
    ).?;
    try std.testing.expectEqual(attention.Kind.question, question.kind);
    try std.testing.expectEqualStrings("{\"question_id\":\"9\",\"question\":\"Which?\",\"options\":[\"a\",\"b\"]}", question.detail);
    try std.testing.expectEqualStrings("{\"question_id\":\"9\"}", try attention.resolvedDetail(arena, question));

    try std.testing.expect(attention.pending(arena, "{\"status\":{}}") == null);
    try std.testing.expect(attention.pending(arena, "not json") == null);
}

test "a finished turn carries its last reply, clipped on a character, and its error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("{\"reply\":\"done\"}", try attention.finishedDetail(arena, "done", null));
    try std.testing.expectEqualStrings("{\"error\":\"boom\"}", try attention.finishedDetail(arena, null, "boom"));
    var long: std.ArrayList(u8) = .empty; // 3000 bytes, two per character
    for (0..1500) |_| try long.appendSlice(arena, "é");
    const detail = try std.json.parseFromSliceLeaky(struct { reply: []const u8 }, arena, try attention.finishedDetail(arena, long.items, null), .{});
    try std.testing.expectEqual(attention.max_reply_bytes, detail.reply.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(detail.reply));
}

test "the log's JSON puts each moment's detail beside its own fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try attention.eventsJson(arena, 5, &.{.{ .seq = 5, .at_ms = 1, .handle = "abcd1234", .title = "t", .kind = "approval", .detail = "{\"approval_id\":\"42\",\"tool\":\"Bash\"}" }});
    try std.testing.expectEqualStrings("{\"latest\":5,\"events\":[{\"seq\":5,\"at_ms\":1,\"handle\":\"abcd1234\",\"title\":\"t\",\"kind\":\"approval\",\"approval_id\":\"42\",\"tool\":\"Bash\"}]}", text);
}
