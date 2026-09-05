const std = @import("std");
const views = @import("session_view.zig");
const Editor = @import("editor.zig");

test {
    std.testing.refAllDecls(views);
}

test "settling one view releases provisional text and preserves another view" {
    const gpa = std.testing.allocator;
    var first: views.SessionView = .{ .sid = 1, .editor = Editor.init(gpa) };
    defer first.deinit(gpa);
    var second: views.SessionView = .{ .sid = 2, .editor = Editor.init(gpa) };
    defer second.deinit(gpa);
    try first.delta.appendSlice(gpa, "partial answer");
    try first.reasoning_delta.appendSlice(gpa, "partial reasoning");
    try first.model.appendSlice(gpa, "local/testing");
    try first.plan.append(gpa, .{ .step = try gpa.dupe(u8, "finish"), .status = .in_progress });
    try second.delta.appendSlice(gpa, "still streaming");
    first.releaseStreamingBuffers(gpa);
    try std.testing.expectEqual(@as(usize, 0), first.delta.capacity);
    try std.testing.expectEqual(@as(usize, 0), first.reasoning_delta.capacity);
    try std.testing.expectEqualStrings("local/testing", first.model.items);
    try std.testing.expect(views.hasUnfinishedPlan(first.plan.items));
    try std.testing.expectEqualStrings("still streaming", second.delta.items);
}
