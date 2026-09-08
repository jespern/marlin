//! Unit tests for orb.zig. Tests live beside the module they cover.

const std = @import("std");
const vaxis = @import("vaxis");
const orb = @import("orb.zig");

fn pixel(rgb: []const u8, width: u16, x: usize, y: usize) [3]u8 {
    const i = (y * width + x) * 3;
    return .{ rgb[i], rgb[i + 1], rgb[i + 2] };
}

test "capture preserves a softened trace of the cell grid" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 4, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 8,
        .height = 4,
        .screen = &screen,
    };
    win.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = .{ .bg = .{ .rgb = .{ 10, 20, 30 } } } });
    win.writeCell(3, 1, .{
        .char = .{ .grapheme = "M", .width = 1 },
        .style = .{ .fg = .{ .rgb = .{ 240, 180, 120 } }, .bg = .{ .rgb = .{ 10, 20, 30 } } },
    });

    const width: u16 = 80;
    const height: u16 = 40;
    const background = try gpa.alloc(u8, @as(usize, width) * height * 3);
    defer gpa.free(background);
    const scratch = try gpa.alloc(u8, background.len);
    defer gpa.free(scratch);
    orb.capture(background, scratch, width, height, win, orb.default_fg, orb.default_bg);

    const plain = pixel(background, width, 5, 35);
    const text = pixel(background, width, 35, 15);
    try std.testing.expect(text[0] > plain[0]);
    try std.testing.expect(text[1] > plain[1]);
    try std.testing.expect(plain[2] > plain[0]);
}

test "orb is deterministic, animated, and leaves the backdrop untouched away from the sphere" {
    const gpa = std.testing.allocator;
    const width: u16 = 160;
    const height: u16 = 100;
    const len = @as(usize, width) * height * 3;
    const background = try gpa.alloc(u8, len);
    defer gpa.free(background);
    @memset(background, 12);
    const scratch = try gpa.alloc(u8, len * 2);
    defer gpa.free(scratch);
    const a = try gpa.alloc(u8, len);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, len);
    defer gpa.free(b);
    const later = try gpa.alloc(u8, len);
    defer gpa.free(later);

    orb.render(a, scratch, background, width, height, 17, 9);
    orb.render(b, scratch, background, width, height, 17, 9);
    orb.render(later, scratch, background, width, height, 47, 9);

    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expect(!std.mem.eql(u8, a, later));
    try std.testing.expectEqual([3]u8{ 12, 12, 12 }, pixel(a, width, 0, 0));
    try std.testing.expectEqual([3]u8{ 12, 12, 12 }, pixel(a, width, width - 1, height - 1));

    // A particle sphere: a compact footprint, blue-first everywhere, with a
    // bright limb where the projection stacks particles.
    var changed: usize = 0;
    var blue_first: usize = 0;
    var bright: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const color = pixel(a, width, x, y);
            if (std.mem.eql(u8, &color, &[3]u8{ 12, 12, 12 })) continue;
            changed += 1;
            if (color[2] >= color[0] and color[2] >= color[1]) blue_first += 1;
            if (color[2] > 200 and color[1] > 120) bright += 1;
        }
    }
    try std.testing.expect(changed > len / 3 / 20 and changed < len / 3 / 2);
    try std.testing.expect(blue_first * 100 >= changed * 92);
    try std.testing.expect(bright > 40);
}
