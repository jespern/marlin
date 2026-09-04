const std = @import("std");
const vaxis = @import("vaxis");

pub const DrawMode = enum {
    interleaved,
    full_screen,
};

pub fn prepare(win: vaxis.Window, mode: DrawMode) void {
    if (mode == .full_screen) win.fill(.{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .fg = .{ .rgb = .{ 0, 0, 0 } }, .bg = .{ .rgb = .{ 0, 0, 0 } } },
    });
}

pub fn cellIsOpen(win: vaxis.Window, col: u16, row: u16) bool {
    const cell = win.readCell(col, row) orelse return false;
    if (!std.mem.eql(u8, cell.char.grapheme, " ")) return false;
    if (col == 0) return true;
    const previous = win.readCell(col - 1, row) orelse return true;
    const previous_width = if (previous.char.width > 0) previous.char.width else win.gwidth(previous.char.grapheme);
    return previous_width <= 1;
}

pub fn scaledColor(base: [3]u8, opacity: u8) vaxis.Color {
    return .{ .rgb = .{
        @intCast(@as(u16, base[0]) * opacity / 255),
        @intCast(@as(u16, base[1]) * opacity / 255),
        @intCast(@as(u16, base[2]) * opacity / 255),
    } };
}

pub fn hash(value: u64) u64 {
    var x = value;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

pub fn writeGlyph(
    win: vaxis.Window,
    col: u16,
    row: u16,
    glyph: []const u8,
    color: vaxis.Color,
    mode: DrawMode,
    bold: bool,
    dim: bool,
) void {
    if (mode == .interleaved and !cellIsOpen(win, col, row)) return;
    var cell = win.readCell(col, row) orelse return;
    cell.char = .{ .grapheme = glyph, .width = 1 };
    cell.style.fg = color;
    if (mode == .full_screen) cell.style.bg = .{ .rgb = .{ 0, 0, 0 } };
    cell.style.bold = bold;
    cell.style.dim = dim;
    cell.link = .{};
    cell.image = null;
    cell.default = false;
    win.writeCell(col, row, cell);
}
