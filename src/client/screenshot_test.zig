//! Unit tests for screenshot.zig: window screenshots.
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const screenshot = @import("screenshot.zig");
const asset_store = @import("asset_store");

fn put(screen: *vaxis.Screen, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    for (text, 0..) |_, i| screen.writeCell(col + @as(u16, @intCast(i)), row, .{ .char = .{ .grapheme = text[i .. i + 1], .width = 1 }, .style = style });
}

test "the frame becomes cells in the terminal's colors, styled as Ghostty styles them" {
    const gpa = std.testing.allocator;
    var screen: vaxis.Screen = try .init(gpa, .{ .rows = 3, .cols = 8, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    put(&screen, 0, 0, "ok", .{});
    put(&screen, 3, 0, "r", .{ .fg = .{ .index = 1 }, .bold = true, .ul_style = .curly, .ul = .{ .rgb = .{ 9, 8, 7 } } });
    put(&screen, 0, 1, "X", .{ .reverse = true });
    screen.writeCell(2, 1, .{ .char = .{ .grapheme = "日", .width = 2 }, .style = .{} });
    put(&screen, 4, 1, "z", .{ .dim = true });
    put(&screen, 0, 2, "ab", .{ .bg = .{ .rgb = .{ 1, 2, 3 } } });
    screen.cursor_vis = true;
    screen.cursor = .{ .row = 2, .col = 1 };
    screen.cursor_shape = .beam;

    var reported: [16]?[3]u8 = @splat(null);
    reported[1] = .{ 200, 10, 10 };
    const colors = screenshot.colorsFrom(.{ 220, 220, 220 }, .{ 0, 0, 0 }, reported);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const frame = try screenshot.frameFrom(arena.allocator(), &screen, 0, 3, colors, .{});
    try std.testing.expectEqual(@as(u16, 8), frame.cols);
    try std.testing.expectEqual(@as(u16, 3), frame.rows);
    try std.testing.expectEqualStrings("o", frame.row(0)[0].text);
    try std.testing.expectEqualStrings("", frame.row(0)[2].text); // blank
    const red = frame.row(0)[3];
    try std.testing.expectEqual([3]u8{ 200, 10, 10 }, red.fg);
    try std.testing.expect(red.bold);
    try std.testing.expectEqual(.curly, red.underline);
    try std.testing.expectEqual([3]u8{ 9, 8, 7 }, red.underline_color.?);

    const reversed = frame.row(1)[0];
    try std.testing.expectEqual([3]u8{ 0, 0, 0 }, reversed.fg);
    try std.testing.expectEqual([3]u8{ 220, 220, 220 }, reversed.bg);
    try std.testing.expectEqualStrings("日", frame.row(1)[2].text);
    try std.testing.expectEqual(@as(u2, 2), frame.row(1)[2].width);
    try std.testing.expectEqual(@as(u2, 0), frame.row(1)[3].width);
    // Faint is Ghostty's faint-opacity, 0.5 by default.
    try std.testing.expectEqual(@as(u8, 128), frame.row(1)[4].alpha);
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, frame.row(2)[0].bg);

    const cursor = frame.cursor.?;
    try std.testing.expectEqual(@as(u16, 2), cursor.row);
    try std.testing.expectEqual(@as(u16, 1), cursor.col);
    try std.testing.expectEqual(.bar, cursor.style);

    // Slim: a range of rows, renumbered from zero; the cursor goes with it.
    const slim = try screenshot.frameFrom(arena.allocator(), &screen, 1, 2, colors, .{});
    try std.testing.expectEqual(@as(u16, 1), slim.rows);
    try std.testing.expectEqualStrings("X", slim.row(0)[0].text);
    try std.testing.expect(slim.cursor == null);
}

test "Ghostty's config: fonts accumulate and reset, colors and cursor parse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const config = screenshot.parseGhosttyConfig(arena.allocator(),
        \\# a comment
        \\font-family = Old
        \\font-family = ""
        \\font-family = "JetBrains Mono"
        \\font-family = Symbols
        \\font-size = 14.5
        \\font-feature = -calt
        \\faint-opacity = 0.7
        \\cursor-color = #ff8800
        \\cursor-style = bar
    );
    try std.testing.expectEqual(@as(f64, 0.7), config.faint_opacity);
    try std.testing.expectEqual([3]u8{ 0xff, 0x88, 0x00 }, config.cursor_color.?);
    try std.testing.expectEqual(.bar, config.cursor_style);
    if (builtin.os.tag == .macos) {
        try std.testing.expectEqual(@as(usize, 2), config.font.family.len);
        try std.testing.expectEqualStrings("JetBrains Mono", config.font.family[0]);
        try std.testing.expectEqual(@as(f64, 14.5), config.font.size);
        try std.testing.expectEqualStrings("-calt", config.font.features[0]);
    }
}

test "Alt+S is the screenshot key" {
    try std.testing.expect(screenshot.isKey(.{ .codepoint = 's', .mods = .{ .alt = true } }));
    try std.testing.expect(!screenshot.isKey(.{ .codepoint = 's' }));
}

test "the default font download is the font Ghostty pins" {
    const gpa = std.testing.allocator;
    try asset_store.verify(gpa, screenshot.default_font[0], @embedFile("jetbrains_mono_variable"));
    try asset_store.verify(gpa, screenshot.default_font[1], @embedFile("jetbrains_mono_variable_italic"));
}
