//! Unit tests for raster.zig: painting a frame the way Ghostty does.
const std = @import("std");
const raster = @import("raster.zig");
const ghostty_font = @import("ghostty_font");
const zigimg = @import("vaxis").zigimg;

const fg: raster.Rgb = .{ 200, 200, 200 };
const bg: raster.Rgb = .{ 0, 0, 0 };

/// 10 x 20 cells with 2 px lines.
fn testMetrics() raster.Metrics {
    return .calc(.{
        .px_per_em = 16,
        .cell_width = 10,
        .ascent = 16,
        .descent = -4,
        .line_gap = 0,
        .underline_thickness = 2,
        .strikethrough_thickness = 2,
    });
}

fn cell(text: []const u8) raster.Cell {
    return .{ .text = text, .fg = fg, .bg = bg };
}

/// A stand-in for CoreText: every non-blank cell gets one fully covered
/// pixel at its top left.
const SolidText = struct {
    const pixel = [1]u8{255};

    fn shapeRow(_: *anyopaque, arena: std.mem.Allocator, row: []const raster.Cell, _: ?u16) anyerror![]const raster.Glyph {
        var out: std.ArrayList(raster.Glyph) = .empty;
        for (row, 0..) |c, col| {
            if (c.text.len == 0 or raster.spriteCodepoint(c.text) != null) continue;
            try out.append(arena, .{ .col = @intCast(col), .data = &pixel, .width = 1, .height = 1, .x = 0, .y = 0, .color = false });
        }
        return out.items;
    }

    fn text() raster.Text {
        var unused: u8 = 0;
        return .{ .ctx = &unused, .shapeRow = shapeRow };
    }
};

test "backgrounds fill whole cells inside a margin of the terminal background" {
    ghostty_font.setIo(std.testing.io);
    const gpa = std.testing.allocator;
    var cells = [_]raster.Cell{ cell(""), cell("") };
    cells[1].bg = .{ 255, 0, 0 };
    const frame: raster.Frame = .{ .cols = 2, .rows = 1, .cells = &cells, .background = .{ 1, 2, 3 } };
    const picture = try raster.paint(gpa, frame, testMetrics(), null, .{ .padding = 4 });
    defer picture.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2 * 10 + 8), picture.width);
    try std.testing.expectEqual(@as(u32, 20 + 8), picture.height);
    // A default cell shows the terminal background; the red one is red
    // edge to edge.
    try std.testing.expectEqual(raster.Rgb{ 0, 0, 0 }, picture.pixel(4, 4));
    try std.testing.expectEqual(raster.Rgb{ 1, 2, 3 }, picture.pixel(0, 0));
    try std.testing.expectEqual(raster.Rgb{ 255, 0, 0 }, picture.pixel(4 + 10, 4));
    try std.testing.expectEqual(raster.Rgb{ 255, 0, 0 }, picture.pixel(4 + 19, 4 + 19));
}

test "box drawing joins across rows with no gap" {
    ghostty_font.setIo(std.testing.io);
    const gpa = std.testing.allocator;
    var cells = [_]raster.Cell{ cell("╭"), cell("─"), cell("│"), cell("") };
    const frame: raster.Frame = .{ .cols = 2, .rows = 2, .cells = &cells, .background = bg };
    const picture = try raster.paint(gpa, frame, testMetrics(), SolidText.text(), .{});
    defer picture.deinit(gpa);
    const metrics = testMetrics();
    // The vertical stroke of │ runs from the top of row 1 to its bottom,
    // and ╭ carries it down to the row boundary above.
    const x = (metrics.cell_width - metrics.box_thickness) / 2;
    for (metrics.cell_height..2 * metrics.cell_height) |y| {
        try std.testing.expectEqual(fg, picture.pixel(x, @intCast(y)));
    }
    try std.testing.expectEqual(fg, picture.pixel(x, metrics.cell_height - 1));
    // ─ meets ╭'s right edge on the same rows.
    const y = (metrics.cell_height - metrics.box_thickness) / 2;
    try std.testing.expectEqual(fg, picture.pixel(metrics.cell_width, y));
    try std.testing.expectEqual(fg, picture.pixel(metrics.cell_width - 1, y));
}

test "faint text blends at its alpha; a block cursor swaps the colors" {
    ghostty_font.setIo(std.testing.io);
    const gpa = std.testing.allocator;
    var cells = [_]raster.Cell{ cell("a"), cell("b") };
    cells[0].alpha = 128;
    const frame: raster.Frame = .{
        .cols = 2,
        .rows = 1,
        .cells = &cells,
        .background = bg,
        .cursor = .{ .col = 1, .row = 0, .style = .block, .color = .{ 0, 255, 0 } },
    };
    const picture = try raster.paint(gpa, frame, testMetrics(), SolidText.text(), .{});
    defer picture.deinit(gpa);
    try std.testing.expectEqual(raster.Rgb{ 100, 100, 100 }, picture.pixel(0, 0));
    try std.testing.expectEqual(raster.Rgb{ 0, 0, 0 }, picture.pixel(1, 1));
    // The cursor cell is the cursor color, with its text in the cell's
    // background (Ghostty's default cursor-text).
    try std.testing.expectEqual(raster.Rgb{ 0, 255, 0 }, picture.pixel(10 + 5, 10));
    try std.testing.expectEqual(bg, picture.pixel(10, 0));
}

test "an underline sits at Ghostty's underline position" {
    ghostty_font.setIo(std.testing.io);
    const gpa = std.testing.allocator;
    var cells = [_]raster.Cell{cell("")};
    cells[0].underline = .single;
    cells[0].underline_color = .{ 255, 0, 255 };
    const frame: raster.Frame = .{ .cols = 1, .rows = 1, .cells = &cells, .background = bg };
    const picture = try raster.paint(gpa, frame, testMetrics(), null, .{});
    defer picture.deinit(gpa);
    const metrics = testMetrics();
    const top = metrics.underline_position;
    try std.testing.expectEqual(raster.Rgb{ 255, 0, 255 }, picture.pixel(0, top));
    try std.testing.expectEqual(raster.Rgb{ 255, 0, 255 }, picture.pixel(9, top + metrics.underline_thickness - 1));
    try std.testing.expectEqual(bg, picture.pixel(0, top - 1));
}

test "an image is scaled into its cell box" {
    ghostty_font.setIo(std.testing.io);
    const gpa = std.testing.allocator;
    var cells = [_]raster.Cell{ cell(""), cell("") };
    // 2x1: red then blue, opaque.
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 255 };
    const images = [_]raster.Image{.{
        .pixels = &pixels,
        .width = 2,
        .height = 1,
        .src_width = 2,
        .src_height = 1,
        .x = 0,
        .y = 0,
        .dst_width = 20,
        .dst_height = 20,
    }};
    const frame: raster.Frame = .{ .cols = 2, .rows = 1, .cells = &cells, .background = bg, .images = &images };
    const picture = try raster.paint(gpa, frame, testMetrics(), null, .{});
    defer picture.deinit(gpa);
    try std.testing.expectEqual(raster.Rgb{ 255, 0, 0 }, picture.pixel(0, 10));
    try std.testing.expectEqual(raster.Rgb{ 0, 0, 255 }, picture.pixel(19, 10));
}

test "the PNG decodes to the picture, at the display's density" {
    ghostty_font.setIo(std.testing.io);
    const gpa = std.testing.allocator;
    var cells = [_]raster.Cell{ cell("╳"), cell("") };
    cells[1].bg = .{ 10, 200, 30 };
    const frame: raster.Frame = .{ .cols = 2, .rows = 1, .cells = &cells, .background = .{ 5, 6, 7 } };
    const picture = try raster.paint(gpa, frame, testMetrics(), null, .{ .padding = 3 });
    defer picture.deinit(gpa);
    const png = try raster.encodePng(gpa, picture, 2);
    defer gpa.free(png);
    // 144 dpi.
    try std.testing.expect(std.mem.indexOf(u8, png, "pHYs\x00\x00\x16\x25\x00\x00\x16\x25\x01") != null);

    var image = try zigimg.Image.fromMemory(gpa, png);
    defer image.deinit(gpa);
    try std.testing.expectEqual(@as(usize, picture.width), image.width);
    try std.testing.expectEqual(@as(usize, picture.height), image.height);
    const decoded = image.pixels.rgb24;
    for (0..picture.height) |y| for (0..picture.width) |x| {
        const want = picture.pixel(@intCast(x), @intCast(y));
        const got = decoded[y * picture.width + x];
        try std.testing.expectEqual(want, raster.Rgb{ got.r, got.g, got.b });
    };
}
