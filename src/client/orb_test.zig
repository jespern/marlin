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
    try std.testing.expectEqual([3]u8{ 12, 12, 12 }, pixel(a, width, width - 1, height - 1));

    // Everything the orb paints lands on the 3-px block grid at this size:
    // inside a block every pixel matches its top-left. (The last row and
    // column of a block may carry the grid's dark edge line, so skip them.)
    var off_grid: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            if (x % 3 == 2 or y % 3 == 2) continue;
            const color = pixel(a, width, x, y);
            if (std.mem.eql(u8, &color, &[3]u8{ 12, 12, 12 })) continue;
            const origin = pixel(a, width, x / 3 * 3, y / 3 * 3);
            if (!std.mem.eql(u8, &color, &origin)) off_grid += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), off_grid);
}

test "orb is a cool-toned globe of nodes with sporadic pulses, not a planet" {
    const gpa = std.testing.allocator;
    const width: u16 = 320;
    const height: u16 = 200;
    const len = @as(usize, width) * height * 3;
    const background = try gpa.alloc(u8, len);
    defer gpa.free(background);
    @memset(background, 12);
    const rgb = try gpa.alloc(u8, len);
    defer gpa.free(rgb);

    var warm_total: usize = 0;
    var cool_total: usize = 0;
    var bright_total: usize = 0;
    var changed_min: usize = std.math.maxInt(usize);
    var changed_max: usize = 0;
    var flashes: usize = 0;
    const frames = [_]u64{ 0, 90, 300, 777, 1500 };
    for (frames) |frame| {
        orb.render(rgb, background, width, height, frame, 9);
        var changed: usize = 0;
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const c = pixel(rgb, width, x, y);
                if (std.mem.eql(u8, &c, &[3]u8{ 12, 12, 12 })) continue;
                changed += 1;
                if (c[2] >= c[0]) cool_total += 1 else warm_total += 1;
                if (c[1] > 150 and c[2] > 200) bright_total += 1;
                if (c[0] > 200 and c[1] > 180) flashes += 1;
            }
        }
        changed_min = @min(changed_min, changed);
        changed_max = @max(changed_max, changed);
    }
    // The body plus its glow stays a compact orb, roughly the same footprint
    // every frame, and the palette is blue-first: red never dominates.
    try std.testing.expect(changed_min > 6_000 and changed_max < 22_000);
    try std.testing.expect(changed_max - changed_min < 4_000);
    try std.testing.expect(cool_total > warm_total * 20);
    // Bright node/pulse pixels exist every frame, and at least one pulse
    // landed on a node somewhere in the sample (the warm-white flash).
    try std.testing.expect(bright_total > 400);
    try std.testing.expect(flashes > 0);
}
