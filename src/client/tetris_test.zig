//! Unit tests for tetris.zig. Tests live beside the module they cover.

const std = @import("std");
const vaxis = @import("vaxis");

const tetris = @import("tetris.zig");
const Engine = tetris.Engine;
const Game = tetris.Game;
const renderPixels = tetris.renderPixels;

test {
    std.testing.refAllDecls(tetris);
}

test "self-player is deterministic, places pieces, and keeps cells valid" {
    var one = Game.init(17);
    var two = Game.init(17);
    for (0..1200) |_| {
        one.tick();
        two.tick();
    }
    try std.testing.expectEqual(one.lines, two.lines);
    try std.testing.expectEqual(one.score, two.score);
    try std.testing.expectEqual(one.next, two.next);
    try std.testing.expectEqual(one.pieces, two.pieces);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&one.board), std.mem.asBytes(&two.board));
    try std.testing.expect(one.pieces > 10);
    try std.testing.expect(one.lines > 0);
    for (one.board) |row| {
        for (row) |cell| try std.testing.expect(cell <= 7);
    }
}

test "line clearing compacts the board" {
    var game = Game.init(3);
    game.board = @splat(@splat(0));
    game.board[tetris.board_rows - 1] = @splat(1);
    game.board[tetris.board_rows - 2][4] = 2;
    try std.testing.expectEqual(@as(u32, 1), game.clearLines());
    try std.testing.expectEqual(@as(u8, 2), game.board[tetris.board_rows - 1][4]);
    for (game.board[0]) |cell| try std.testing.expectEqual(@as(u8, 0), cell);
}

test "pixel renderer fills the viewport with arcade framing, board, and HUD" {
    const gpa = std.testing.allocator;
    var game = Game.init(9);
    game.board = @splat(@splat(0));
    game.board[tetris.board_rows - 1][0] = 1;
    game.score = 12_345;
    game.lines = 17;
    const width: u16 = 640;
    const height: u16 = 384;
    const rgb = try gpa.alloc(u8, @as(usize, width) * height * 3);
    defer gpa.free(rgb);
    renderPixels(&game, rgb, width, height);

    var nonzero: usize = 0;
    var cyan_pixels: usize = 0;
    var magenta_pixels: usize = 0;
    var i: usize = 0;
    while (i < rgb.len) : (i += 3) {
        if (rgb[i] != 0 or rgb[i + 1] != 0 or rgb[i + 2] != 0) nonzero += 1;
        if (rgb[i] < 80 and rgb[i + 1] > 150 and rgb[i + 2] > 180) cyan_pixels += 1;
        if (rgb[i] > 160 and rgb[i + 1] < 100 and rgb[i + 2] > 100) magenta_pixels += 1;
    }
    try std.testing.expect(nonzero > @as(usize, width) * height * 3 / 4);
    try std.testing.expect(cyan_pixels > 100);
    try std.testing.expect(magenta_pixels > 100);

    const copy = try gpa.dupe(u8, rgb);
    defer gpa.free(copy);
    renderPixels(&game, rgb, width, height);
    try std.testing.expectEqualSlices(u8, copy, rgb);
}

test "cell fallback centers a colored ten-column board" {
    const gpa = std.testing.allocator;
    var engine = Engine.init(gpa, 9);
    defer engine.deinit();
    try engine.reset(80, 24, 9);
    engine.game.board = @splat(@splat(0));
    engine.game.board[tetris.board_rows - 1][0] = 1;

    var screen = try vaxis.Screen.init(gpa, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 24, .screen = &screen };
    engine.draw(win, .full_screen, 255);

    const origin_x: u16 = (80 - tetris.board_cols * 2) / 2;
    const origin_y: u16 = (24 - tetris.board_rows) / 2;
    const cell = win.readCell(origin_x, origin_y + tetris.board_rows - 1).?;
    try std.testing.expectEqualStrings("▐", cell.char.grapheme);
    try std.testing.expect(cell.style.bg != .default);
}
