const std = @import("std");
const recap = @import("recap.zig");
const block = @import("../core/block.zig");

test {
    std.testing.refAllDecls(recap);
}

test "recap snapshot keeps latest request and answer ahead of long tool output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var blocks: [30]block.Block = undefined;
    for (&blocks, 0..) |*b, i| b.* = .{
        .id = i + 1,
        .seq = i + 1,
        .session_id = 1,
        .turn_id = 1,
        .ts = 1,
        .body = .{ .tool_result = .{ .call_id = "c", .status = .ok, .inline_body = "x" ** 20_000, .full_body_ref = null } },
    };
    blocks[0].body = .{ .user_msg = .{ .text = "Fix login" } };
    blocks[29].body = .{ .assistant_msg = .{ .text = "Fixed login; tests pass. Deployment still pending." } };
    const result = try recap.snapshot(arena.allocator(), &blocks);
    try std.testing.expect(std.mem.startsWith(u8, result.transcript, "LATEST REQUEST: Fix login"));
    try std.testing.expect(std.mem.indexOf(u8, result.transcript, "Deployment still pending.") != null);
    try std.testing.expect(result.transcript.len < 20_000);
    try std.testing.expect(std.mem.indexOf(u8, result.fallback, "Fix login") != null);
    blocks[29].body = .{ .user_msg = .{ .text = "Now fix logout" } };
    const next = try recap.snapshot(arena.allocator(), &blocks);
    try std.testing.expect(std.mem.indexOf(u8, next.fallback, "Fixed login") == null);
}
