const std = @import("std");
const recap = @import("recap.zig");
const limits = @import("../core/recap.zig");

test {
    std.testing.refAllDecls(recap);
}

test "recaps wait for completion and three minutes without user activity" {
    var state = recap.State{};
    try std.testing.expect(!state.due(.idle, 0, 1_000_000));
    state.changed(1000);
    try std.testing.expect(!state.due(.running, 8, 1_000_000));
    try std.testing.expect(!state.due(.awaiting_approval, 8, 1_000_000));
    try std.testing.expect(!state.due(.idle, 8, 1000 + limits.idle_ms - 1));
    try std.testing.expect(state.due(.idle, 8, 1000 + limits.idle_ms));
    state.last_activity_ms = 2000;
    try std.testing.expect(!state.due(.idle, 8, 1000 + limits.idle_ms));
    try std.testing.expect(state.due(.err, 8, 2000 + limits.idle_ms));
    state.attempted_seq = 8;
    try std.testing.expect(!state.due(.idle, 8, 1_000_000));
    try std.testing.expect(state.due(.idle, 9, 1_000_000));
}

test "recaps discard stale results, retry busy workers, and avoid duplicate scrollback entries" {
    var state = recap.State{ .last_change_ms = 1, .pending_seq = 8, .attempted_seq = 8 };
    try std.testing.expect(!state.accept(9, 8, false, 200_000));
    state.pending_seq = 9;
    state.attempted_seq = 9;
    try std.testing.expect(!state.accept(9, 9, true, 200_000));
    try std.testing.expect(!state.due(.idle, 9, 214_999));
    try std.testing.expect(state.due(.idle, 9, 215_000));
    state.pending_seq = 9;
    state.attempted_seq = 9;
    try std.testing.expect(state.accept(9, 9, false, 215_000));
    state.shown_seq = 9;
    state.pending_seq = 9;
    try std.testing.expect(!state.accept(9, 9, false, 220_000));
    try std.testing.expect(!state.due(.idle, 9, 1_000_000));
    state.changed(1_000_000);
    try std.testing.expect(!state.due(.idle, 10, 1_000_001));
}

test "recap clipping keeps Unicode intact and collapses line breaks" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("a", limits.clipped("a😀b", 3));
    const text = try limits.plainText(gpa, "  Work\n\nfinished.\tReview next.  ");
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Work finished. Review next.", text);
    const long = try limits.plainText(gpa, "😀 " ** 300);
    defer gpa.free(long);
    try std.testing.expect(long.len <= limits.max_text_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(long));
}
