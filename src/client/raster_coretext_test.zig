//! Tests for raster_coretext.zig: Ghostty's font setup and shaping through
//! CoreText. macOS only.
const std = @import("std");
const builtin = @import("builtin");
const raster = @import("raster.zig");
const ghostty_font = @import("ghostty_font");
const coretext = if (builtin.os.tag == .macos) @import("raster_coretext.zig") else struct {};

/// Ghostty's default font, as screenshots download it.
const default_font = if (builtin.os.tag == .macos) coretext.DefaultFont{
    .regular = @embedFile("jetbrains_mono_variable"),
    .italic = @embedFile("jetbrains_mono_variable_italic"),
} else {};

fn cell(text: []const u8, width: u2) raster.Cell {
    return .{ .text = text, .width = width, .fg = .{ 255, 255, 255 }, .bg = .{ 0, 0, 0 } };
}

test "Ghostty's default font gives Ghostty's 13pt Retina grid exactly" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fonts = try coretext.Fonts.init(std.testing.allocator, .{ .default_font = default_font }, 16, 34);
    defer fonts.deinit();
    try std.testing.expect(fonts.exact_grid);
    try std.testing.expectEqual(@as(f64, 2), fonts.scale);
    try std.testing.expectEqual(@as(u32, 16), fonts.metrics.cell_width);
    try std.testing.expectEqual(@as(u32, 34), fonts.metrics.cell_height);
}

test "a cell grid the font cannot make is forced, baseline centered" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fonts = try coretext.Fonts.init(std.testing.allocator, .{ .default_font = default_font }, 16, 40);
    defer fonts.deinit();
    try std.testing.expect(!fonts.exact_grid);
    try std.testing.expectEqual(@as(u32, 40), fonts.metrics.cell_height);
}

test "text shapes to one glyph per cell, ligatures included" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var fonts = try coretext.Fonts.init(gpa, .{ .default_font = default_font }, 16, 34);
    defer fonts.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const plain = [_]raster.Cell{ cell("a", 1), cell("b", 1) };
    const glyphs = try fonts.shapeRow(arena.allocator(), &plain, null);
    try std.testing.expectEqual(@as(usize, 2), glyphs.len);
    try std.testing.expectEqual(@as(u16, 0), glyphs[0].col);
    try std.testing.expectEqual(@as(u16, 1), glyphs[1].col);
    var covered: usize = 0;
    for (glyphs[0].data) |c| covered += @intFromBool(c > 0);
    try std.testing.expect(covered > 20);
    // Glyphs sit inside their cell.
    try std.testing.expect(glyphs[0].y >= 0 and glyphs[0].y < 34);

    // JetBrains Mono joins "!=": its "!" is not the lone "!".
    const alone = [_]raster.Cell{ cell("!", 1), cell("x", 1) };
    const joined = [_]raster.Cell{ cell("!", 1), cell("=", 1) };
    const a = try fonts.shapeRow(arena.allocator(), &alone, null);
    const j = try fonts.shapeRow(arena.allocator(), &joined, null);
    try std.testing.expect(a[0].width != j[0].width or !std.mem.eql(u8, a[0].data, j[0].data));
}

test "emoji fall back to a color font across two cells" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var fonts = try coretext.Fonts.init(gpa, .{ .default_font = default_font }, 16, 34);
    defer fonts.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const row = [_]raster.Cell{ cell("😀", 2), cell("", 0), cell("a", 1) };
    const glyphs = try fonts.shapeRow(arena.allocator(), &row, null);
    try std.testing.expectEqual(@as(usize, 2), glyphs.len);
    try std.testing.expect(glyphs[0].color);
    try std.testing.expect(glyphs[0].width > 16 and glyphs[0].width <= 32);
    try std.testing.expectEqual(@as(u16, 2), glyphs[1].col);
}

test "font-feature parses Ghostty's syntaxes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Feature = coretext.Feature;
    try std.testing.expectEqual(Feature{ .tag = "calt".*, .value = 0 }, Feature.parse("-calt").?);
    try std.testing.expectEqual(Feature{ .tag = "ss01".*, .value = 1 }, Feature.parse("ss01").?);
    try std.testing.expectEqual(Feature{ .tag = "cv01".*, .value = 2 }, Feature.parse("cv01=2").?);
    try std.testing.expectEqual(Feature{ .tag = "liga".*, .value = 0 }, Feature.parse("liga off").?);
    try std.testing.expect(Feature.parse("toolong") == null);
}

test "without Ghostty's default font, Menlo stands in" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fonts = try coretext.Fonts.init(std.testing.allocator, .{}, 16, 34);
    defer fonts.deinit();
    try std.testing.expectEqual(@as(u32, 34), fonts.metrics.cell_height);
}
