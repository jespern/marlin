const std = @import("std");
const block = @import("../../core/block.zig");
const sessions = @import("sessions.zig");

fn b(seq: u64, body: block.Body) block.Block {
    return .{ .id = seq, .session_id = 1, .turn_id = 1, .seq = seq, .ts = 0, .body = body };
}

test "the four tools are known by name, and only they" {
    for (sessions.names) |name| try std.testing.expect(sessions.isTool(name));
    try std.testing.expect(!sessions.isTool("bash"));
    try std.testing.expectEqual(@as(usize, 4), sessions.specs.len);
    for (sessions.specs) |spec| {
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, spec.schema, .{});
        parsed.deinit();
    }
}

test "a message says who sent it and how to answer" {
    const text = try sessions.messageText(std.testing.allocator, "5588ce26", "fix the parser", "claudecode/opus", "Is the lexer done?");
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "[Message from another Marlin session: \"fix the parser\" (claudecode/opus), handle 5588ce26."));
    try std.testing.expect(std.mem.endsWith(u8, text, "\n\nIs the lexer done?"));
}

test "the transcript tail reads as who said what, tools as one line, failures only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const blocks = [_]block.Block{
        b(1, .{ .user_msg = .{ .text = "[rehydrated]", .synthetic = true } }),
        b(2, .{ .user_msg = .{ .text = "  fix the lexer  " } }),
        b(3, .{ .reasoning = .{ .text = "raw thinking" } }),
        b(4, .{ .reasoning = .{ .text = "Looking at it.", .commentary = true } }),
        b(5, .{ .tool_call = .{ .call_id = "c", .name = "bash", .args_json = "{\"command\":\"zig build\"}" } }),
        b(6, .{ .tool_result = .{ .call_id = "c", .status = .ok, .inline_body = "fine", .full_body_ref = null } }),
        b(7, .{ .tool_result = .{ .call_id = "d", .status = .err, .inline_body = "boom", .full_body_ref = null } }),
        b(8, .{ .assistant_msg = .{ .text = "Done." } }),
    };
    const tail = try sessions.transcriptTail(arena.allocator(), &blocks);
    try std.testing.expectEqualStrings(
        "user: fix the lexer\n\nagent (note): Looking at it.\n\ntool: bash {\"command\":\"zig build\"}\n\ntool failed: boom\n\nagent: Done.",
        tail,
    );
    try std.testing.expectEqualStrings("Done.", sessions.lastReply(&blocks).?);
    try std.testing.expect(sessions.lastReply(blocks[0..2]) == null);
}

test "a long tail keeps the newest entries and says how many it left out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var blocks: std.ArrayList(block.Block) = .empty;
    const big = try a.alloc(u8, 1500);
    @memset(big, 'x');
    for (0..40) |i| try blocks.append(a, b(i + 1, .{ .assistant_msg = .{ .text = big } }));
    try blocks.append(a, b(41, .{ .assistant_msg = .{ .text = "newest" } }));
    const tail = try sessions.transcriptTail(a, blocks.items);
    try std.testing.expect(tail.len <= sessions.max_read_bytes + 64);
    try std.testing.expect(std.mem.startsWith(u8, tail, "["));
    try std.testing.expect(std.mem.indexOf(u8, tail, "earlier entries left out]") != null);
    try std.testing.expect(std.mem.endsWith(u8, tail, "agent: newest"));
}
