//! Unit tests for block.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in block.zig.

const std = @import("std");

const block = @import("block.zig");
const Block = block.Block;
const BlockKind = block.BlockKind;
const Body = block.Body;
const PlanItem = block.PlanItem;
const handoverBody = block.handoverBody;
const isHandoverAnnounce = block.isHandoverAnnounce;
const isHandoverNote = block.isHandoverNote;

test {
    std.testing.refAllDecls(block);
}

test "block kind follows body tag" {
    const b = Block{
        .id = 1,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "hi" } },
    };
    try std.testing.expectEqual(BlockKind.user_msg, b.kind());
}

test "older plan items decode without timing metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const item = try std.json.parseFromSliceLeaky(
        PlanItem,
        arena_state.allocator(),
        "{\"step\":\"Inspect\",\"status\":\"completed\"}",
        .{ .ignore_unknown_fields = true },
    );
    try std.testing.expectEqual(@as(i64, 0), item.started_at_ms);
    try std.testing.expectEqual(@as(u64, 0), item.duration_ms);
}

test "older user blocks decode with synthetic disabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const body = try std.json.parseFromSliceLeaky(
        Body,
        arena_state.allocator(),
        "{\"user_msg\":{\"text\":\"hello\"}}",
        .{ .ignore_unknown_fields = true },
    );
    try std.testing.expectEqualStrings("hello", body.user_msg.text);
    try std.testing.expect(!body.user_msg.synthetic);
}

test "user message attachments round trip as durable blob references" {
    const gpa = std.testing.allocator;
    const body: Body = .{ .user_msg = .{
        .text = "inspect this",
        .attachments = &.{.{
            .hash = "abc123",
            .mime = "image/png",
            .name = "shot.png",
            .byte_len = 42,
        }},
    } };
    const encoded = try std.json.Stringify.valueAlloc(gpa, body, .{});
    defer gpa.free(encoded);
    const parsed = try std.json.parseFromSlice(Body, gpa, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.user_msg.attachments.len);
    try std.testing.expectEqualStrings("abc123", parsed.value.user_msg.attachments[0].hash);
    try std.testing.expectEqualStrings("image/png", parsed.value.user_msg.attachments[0].mime);
}

test "handover note prefix splits body from marker" {
    try std.testing.expect(isHandoverNote("[handover]\n## Goal\nship it"));
    try std.testing.expect(!isHandoverNote("Switching to Claude Code (claudecode/fable)."));
    try std.testing.expect(isHandoverAnnounce("Switching to Claude Code (claudecode/fable). Generating a handover summary…"));
    try std.testing.expectEqualStrings("## Goal\nship it", handoverBody("[handover]\n## Goal\nship it"));
}
