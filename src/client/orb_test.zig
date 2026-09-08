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

test "orb is deterministic, animated, pixelated, and leaves corners unchanged" {
    const gpa = std.testing.allocator;
    const width: u16 = 160;
    const height: u16 = 100;
    const len = @as(usize, width) * height * 3;
    const background = try gpa.alloc(u8, len);
    defer gpa.free(background);
    @memset(background, 12);
    const a = try gpa.alloc(u8, len);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, len);
    defer gpa.free(b);
    const later = try gpa.alloc(u8, len);
    defer gpa.free(later);

    orb.render(a, background, width, height, 17, 9);
    orb.render(b, background, width, height, 17, 9);
    orb.render(later, background, width, height, 47, 9);

    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expect(!std.mem.eql(u8, a, later));
    try std.testing.expectEqual([3]u8{ 12, 12, 12 }, pixel(a, width, 0, 0));
    const center = pixel(a, width, width / 2, height / 2);
    try std.testing.expect(@as(u16, center[0]) > @as(u16, center[1]) * 2);
    const block = pixel(a, width, 78, 48);
    try std.testing.expectEqual(block, pixel(a, width, 79, 48));
    try std.testing.expectEqual(block, pixel(a, width, 78, 49));
    try std.testing.expectEqual(block, pixel(a, width, 79, 49));
    for (block) |value| try std.testing.expectEqual(@as(u8, 0), value % 32);
    const adjacent = pixel(a, width, 80, 48);
    try std.testing.expect(!std.mem.eql(u8, &adjacent, &block));

    var red_armor: usize = 0;
    var gold_panels: usize = 0;
    var cyan_energy: usize = 0;
    var changed: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const color = pixel(a, width, x, y);
            if (!std.mem.eql(u8, &color, &[3]u8{ 12, 12, 12 })) changed += 1;
            const red: u16 = color[0];
            const green: u16 = color[1];
            const blue: u16 = color[2];
            if (red > 70 and red > green * 2 and red > blue * 2) red_armor += 1;
            if (red > 110 and green > 45 and red > green and green > blue * 2) gold_panels += 1;
            if (color[1] > 90 and color[2] > 110 and color[2] > color[0]) cyan_energy += 1;
        }
    }
    try std.testing.expect(changed > 1500 and changed < 9000);
    try std.testing.expect(red_armor > 250);
    try std.testing.expect(gold_panels > 30);
    try std.testing.expect(cyan_energy > 20);
}
