//! Unit tests for pacman.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in pacman.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const pacman = @import("pacman.zig");
const Actor = pacman.Actor;
const Engine = pacman.Engine;
const Game = pacman.Game;
const Tile = pacman.Tile;
const black = pacman.black;
const door_color = pacman.door_color;
const dot_color = pacman.dot_color;
const ghost_colors = pacman.ghost_colors;
const layoutForAspect = pacman.layoutForAspect;
const max_cols = pacman.max_cols;
const max_rows = pacman.max_rows;
const pac_color = pacman.pac_color;
const renderBackground = pacman.renderBackground;
const renderPixels = pacman.renderPixels;
const step_ticks = pacman.step_ticks;
const wall_color = pacman.wall_color;

test {
    std.testing.refAllDecls(pacman);
}

fn expectSoundMaze(game: *const Game) !void {
    // Border is wall, except tunnel mouths.
    var x: i32 = 0;
    while (x < game.cols) : (x += 1) {
        try std.testing.expectEqual(Tile.wall, game.tile(x, 0));
        try std.testing.expectEqual(Tile.wall, game.tile(x, game.rows - 1));
    }
    var y: i32 = 0;
    while (y < game.rows) : (y += 1) {
        const mouth = game.tunnel_row == y;
        try std.testing.expectEqual(if (mouth) Tile.path else Tile.wall, game.tile(0, y));
        try std.testing.expectEqual(if (mouth) Tile.path else Tile.wall, game.tile(game.cols - 1, y));
    }
    // Mirror symmetry.
    y = 0;
    while (y < game.rows) : (y += 1) {
        x = 0;
        while (x < game.cols) : (x += 1) try std.testing.expectEqual(game.tile(x, y), game.tile(game.cols - 1 - x, y));
    }
    // Sound: connected and without dead ends (the generator's own check).
    try std.testing.expect(game.mazeIsSound());
    // House: a door with corridor above and interior below.
    try std.testing.expectEqual(Tile.door, game.tile(game.centerX(), game.doorY()));
    try std.testing.expectEqual(Tile.path, game.tile(game.centerX(), game.doorY() - 1));
    try std.testing.expectEqual(Tile.house, game.tile(game.centerX(), game.doorY() + 1));
    try std.testing.expect(!game.passable(game.centerX(), game.doorY(), .pac));
    try std.testing.expect(game.passable(game.centerX(), game.doorY(), .ghost_inside));
    const start = game.pacStart();
    try std.testing.expectEqual(Tile.path, game.tile(start[0], start[1]));
}

test "generated mazes are symmetric, connected, dead-end free, and fit their budget" {
    const sizes = [_][2]u16{ .{ 28, 31 }, .{ 45, 27 }, .{ 15, 15 }, .{ 75, 48 }, .{ 40, 20 } };
    for (sizes, 0..) |size, n| {
        var game = Game.init(11 + n);
        game.configure(size[0], size[1]);
        try std.testing.expect(game.cols <= size[0] or size[0] < 15);
        try std.testing.expect(game.rows <= size[1] or size[1] < 15);
        try std.testing.expect(game.cols <= max_cols and game.rows <= max_rows);
        try expectSoundMaze(&game);
        try std.testing.expect(game.dots_left > 20);
        // The next board is a different maze of the same size.
        const before = game.map;
        const gen = game.generation;
        game.reset(99 + n);
        try std.testing.expectEqual(gen + 1, game.generation);
        try std.testing.expectEqual(game.cols, @as(u16, @intCast(6 * game.bw + 3)));
        try expectSoundMaze(&game);
        var same = true;
        var y: usize = 0;
        while (y < game.rows) : (y += 1) same = same and std.mem.eql(Tile, &before[y], &game.map[y]);
        try std.testing.expect(!same);
    }
    const wide = layoutForAspect(640, 384);
    try std.testing.expectEqual(@as(u16, 45), wide.cols);
    try std.testing.expectEqual(@as(u16, 27), wide.rows);
    const tall = layoutForAspect(400, 800);
    try std.testing.expect(tall.rows > tall.cols);
}

test "ghosts leave the house, pac-man eats and stays on corridors, a catch resets the board" {
    var game = Game.init(5);
    const dots_at_start = game.dots_left;
    var ticks: usize = 0;
    while (ticks < step_ticks * 60) : (ticks += 1) {
        game.tick();
        try std.testing.expect(game.passable(game.pac.x, game.pac.y, .pac));
        for (game.ghosts) |g| {
            const mover: Game.Mover = if (g.inside) .ghost_inside else .ghost_outside;
            try std.testing.expect(game.passable(g.actor.x, g.actor.y, mover) or g.inside);
        }
    }
    try std.testing.expect(game.dots_left < dots_at_start or game.freeze > 0);
    if (game.freeze == 0) {
        for (game.ghosts) |g| try std.testing.expect(!g.inside);
    }

    // Force a catch on the top corridor: tile (2,1) has walls above and
    // below, so ghosts closing in from both sides leave only a tile trade.
    game.freeze = 0;
    game.caught = false;
    try std.testing.expectEqual(Tile.path, game.tile(1, 1));
    try std.testing.expectEqual(Tile.path, game.tile(3, 1));
    try std.testing.expectEqual(Tile.wall, game.tile(2, 2));
    game.pac = Actor.at(2, 1, .right);
    game.ghosts[0] = .{ .actor = Actor.at(1, 1, .right), .inside = false, .wait = 0 };
    game.ghosts[1] = .{ .actor = Actor.at(3, 1, .left), .inside = false, .wait = 0 };
    game.ghosts[2].inside = true;
    game.ghosts[3].inside = true;
    game.step();
    try std.testing.expect(game.caught);
    try std.testing.expect(game.freeze > 0);
    try std.testing.expect(game.mouthAngle() > 0.5); // the death yawn has begun
    var wait: usize = 0;
    while (game.freeze > 0 and wait < 1000) : (wait += 1) game.tick();
    try std.testing.expect(!game.caught);
    try std.testing.expect(game.dots_left > 20);
    try std.testing.expectEqual(game.pacStart()[0], game.pac.x);
}

test "tunnels wrap around" {
    var game = Game.init(3);
    game.configure(45, 27);
    const t = game.tunnel_row.?;
    try std.testing.expectEqual([2]i32{ game.cols - 1, t }, game.neighbor(0, t, .left).?);
    try std.testing.expectEqual([2]i32{ 0, t }, game.neighbor(game.cols - 1, t, .right).?);
    try std.testing.expect(game.neighbor(0, t + 3, .left) == null);
}

test "cell renderer draws the maze, dots, and Pac-Man on the terminal grid" {
    const gpa = std.testing.allocator;
    var engine = Engine.init(gpa, 9);
    defer engine.deinit();
    try engine.reset(80, 30, 9);
    // 80 columns → a 39-wide maze at two columns per tile; 30 rows → 30 rows.
    try std.testing.expectEqual(@as(u16, 39), engine.game.cols);
    try std.testing.expectEqual(@as(u16, 30), engine.game.rows);
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 30, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 30, .screen = &screen };
    engine.draw(win, .full_screen, 255);
    const origin_x: u16 = (80 - 39 * 2) / 2;
    const origin_y: u16 = 0;
    const wall = win.readCell(origin_x, origin_y).?; // top-left border tile
    try std.testing.expect(std.meta.eql(wall.style.bg, effect.scaledColor(wall_color, 255)));
    // (1,1) is the top-left corridor node and holds a dot.
    try std.testing.expectEqualStrings("·", win.readCell(origin_x + 2, origin_y + 1).?.char.grapheme);
    const start = engine.game.pacStart();
    const px: u16 = origin_x + @as(u16, @intCast(start[0])) * 2;
    const py: u16 = origin_y + @as(u16, @intCast(start[1]));
    try std.testing.expectEqualStrings("●", win.readCell(px, py).?.char.grapheme);
    // The door is drawn as a bar.
    const door_x: u16 = origin_x + @as(u16, @intCast(engine.game.centerX())) * 2;
    const door_y: u16 = origin_y + @as(u16, @intCast(engine.game.doorY()));
    try std.testing.expectEqualStrings("─", win.readCell(door_x, door_y).?.char.grapheme);
}

test "pixel renderer: outlined walls, a pink door, dots, a yellow Pac-Man, ghosts in their colors" {
    const gpa = std.testing.allocator;
    var game = Game.init(7);
    game.configure(45, 27);
    const t: u16 = 16;
    const width: u16 = game.cols * t;
    const height: u16 = game.rows * t;
    const background = try gpa.alloc(u8, @as(usize, width) * height * 3);
    defer gpa.free(background);
    const rgb = try gpa.alloc(u8, background.len);
    defer gpa.free(rgb);
    renderBackground(&game, background, width, height);
    renderPixels(&game, rgb, background, width, height);
    const px = struct {
        fn at(buf: []const u8, w: u16, x: usize, y: usize) [3]u8 {
            const i = (y * w + x) * 3;
            return .{ buf[i], buf[i + 1], buf[i + 2] };
        }
    };
    // Corridor tile (1,1): black corner, dot in the middle.
    try std.testing.expectEqual(black, px.at(rgb, width, 16, 16));
    try std.testing.expectEqual(dot_color, px.at(rgb, width, 16 + 8, 16 + 8));
    // The border wall tile (1,0) carries the outline band 4 px in from the
    // corridor below it (inset 0.24·16 ≈ 3.8, line 1.6): row 16 - 5 is blue,
    // the tile's own middle is black.
    try std.testing.expectEqual(wall_color, px.at(rgb, width, 16 + 8, 16 - 5));
    try std.testing.expectEqual(black, px.at(rgb, width, 16 + 8, 16 - 9));
    // Door bar.
    const dx: usize = @intCast(game.centerX() * t + 8);
    const dy: usize = @intCast(game.doorY() * t + 7);
    try std.testing.expectEqual(door_color, px.at(rgb, width, dx, dy));
    // Pac-Man's center.
    const start = game.pacStart();
    try std.testing.expectEqual(pac_color, px.at(rgb, width, @intCast(start[0] * t + 8), @intCast(start[1] * t + 8)));
    // Each ghost paints its color low in its tile (under the eyes).
    for (game.ghosts, ghost_colors) |g, color| {
        try std.testing.expectEqual(color, px.at(rgb, width, @intCast(g.actor.x * t + 8), @intCast(g.actor.y * t + 12)));
    }
    // Deterministic for a given state.
    var i: usize = 0;
    while (i < step_ticks + 1) : (i += 1) game.tick();
    renderPixels(&game, rgb, background, width, height);
    const copy = try gpa.dupe(u8, rgb);
    defer gpa.free(copy);
    renderPixels(&game, rgb, background, width, height);
    try std.testing.expectEqualSlices(u8, copy, rgb);
}
