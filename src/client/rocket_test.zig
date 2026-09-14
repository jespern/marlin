const std = @import("std");
const rocket = @import("rocket.zig");

test "rocket timeline holds the pad through ignition then climbs and loops" {
    try std.testing.expectEqual(@as(f32, 0), rocket.flight(9 * 30).altitude);
    try std.testing.expect(rocket.flight(9 * 30).ignition > 0);
    try std.testing.expect(rocket.flight(20 * 30).altitude > rocket.flight(12 * 30).altitude);
    try std.testing.expectEqual(rocket.flight(0), rocket.flight(rocket.loop_frames));
}

test "rocket frames are deterministic, animate, and clip safely at every aspect" {
    const gpa = std.testing.allocator;
    for ([_][2]u16{ .{ 1, 1 }, .{ 80, 160 }, .{ 320, 180 }, .{ 720, 405 } }) |size| {
        const n = @as(usize, size[0]) * size[1] * 3;
        const a = try gpa.alloc(u8, n);
        defer gpa.free(a);
        const b = try gpa.alloc(u8, n);
        defer gpa.free(b);
        for ([_]u64{ 30, 210, 299, 330, 600, 1000, 1199 }) |frame| {
            rocket.render(a, size[0], size[1], frame, 42);
            rocket.render(b, size[0], size[1], frame + rocket.loop_frames, 42);
            try std.testing.expectEqualSlices(u8, a, b);
        }
        if (n > 3) {
            rocket.render(a, size[0], size[1], 30, 42);
            rocket.render(b, size[0], size[1], 360, 42);
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}
