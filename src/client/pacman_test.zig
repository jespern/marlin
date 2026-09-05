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
    // 640×384 shows 27 board rows plus the 3 HUD rows: 30 rows at 5:3 is
    // 50 tiles wide, so eight cells a half.
    const wide = layoutForAspect(640, 384);
    try std.testing.expectEqual(@as(u16, 51), wide.cols);
    try std.testing.expectEqual(@as(u16, 27), wide.rows);
    const tall = layoutForAspect(400, 800);
    try std.testing.expect(tall.rows > tall.cols);
}

test "ghosts leave the house, pac-man eats and stays on corridors, a catch costs a life and keeps the board" {
    var game = Game.init(5);
    const dots_at_start = game.dots_left;
    // "READY!" first: nothing moves, Pac-Man is off the board.
    try std.testing.expectEqual(pacman.ready_ticks, game.ready);
    try std.testing.expect(!game.pacVisible());
    try std.testing.expect(game.holdingStill());
    var ticks: usize = 0;
    while (ticks < pacman.ready_ticks) : (ticks += 1) game.tick();
    try std.testing.expectEqual(dots_at_start, game.dots_left);
    try std.testing.expect(game.pacVisible());
    ticks = 0;
    while (ticks < step_ticks * 60) : (ticks += 1) {
        game.tick();
        try std.testing.expect(game.passable(game.pac.x, game.pac.y, .pac));
        for (game.ghosts) |g| {
            try std.testing.expect(game.passable(g.actor.x, g.actor.y, Game.moverFor(g)) or g.inside);
        }
    }
    try std.testing.expect(game.dots_left < dots_at_start or game.freeze > 0);
    try std.testing.expect(game.score >= pacman.dot_points * (dots_at_start - game.dots_left) or game.freeze > 0);
    try std.testing.expectEqual(game.score, game.high_score);
    if (game.freeze == 0 and game.ready == 0) {
        for (game.ghosts) |g| try std.testing.expect(!g.inside);
    }

    // Force a catch on the top corridor: tile (2,1) has walls above and
    // below, so ghosts closing in from both sides leave only a tile trade.
    game.freeze = 0;
    game.caught = false;
    game.ready = 0;
    try std.testing.expectEqual(Tile.path, game.tile(1, 1));
    try std.testing.expectEqual(Tile.path, game.tile(3, 1));
    try std.testing.expectEqual(Tile.wall, game.tile(2, 2));
    game.pac = Actor.at(2, 1, .right);
    game.ghosts[0] = .{ .actor = Actor.at(1, 1, .right), .inside = false, .wait = 0 };
    game.ghosts[1] = .{ .actor = Actor.at(3, 1, .left), .inside = false, .wait = 0 };
    game.ghosts[2].inside = true;
    game.ghosts[3].inside = true;
    const dots_before_death = game.dots_left;
    const score_before_death = game.score;
    const gen = game.generation;
    game.step();
    try std.testing.expect(game.caught);
    try std.testing.expect(game.freeze > 0);
    try std.testing.expect(game.mouthAngle() > 0.5); // the death yawn has begun
    try std.testing.expect(!game.ghostVisible(0)); // the ghosts clear off for it
    var wait: usize = 0;
    while (game.freeze > 0 and wait < 1000) : (wait += 1) game.tick();
    // A life lost: same maze and dots, everyone back at the start, "READY!".
    try std.testing.expect(!game.caught);
    try std.testing.expectEqual(pacman.start_lives - 1, game.lives);
    try std.testing.expectEqual(gen, game.generation);
    try std.testing.expectEqual(dots_before_death, game.dots_left);
    try std.testing.expectEqual(score_before_death, game.score);
    try std.testing.expectEqual(pacman.ready_ticks, game.ready);
    try std.testing.expectEqual(game.pacStart()[0], game.pac.x);
    for (game.ghosts[1..]) |g| try std.testing.expect(g.inside);

    // Out of spare lives, a catch means "GAME OVER", then a new game with
    // the score reset and the high score kept.
    game.ready = 0;
    game.lives = 0;
    game.pac = Actor.at(2, 1, .right);
    game.ghosts[0] = .{ .actor = Actor.at(1, 1, .right), .inside = false, .wait = 0 };
    game.ghosts[1] = .{ .actor = Actor.at(3, 1, .left), .inside = false, .wait = 0 };
    game.ghosts[2].inside = true;
    game.ghosts[3].inside = true;
    game.step();
    try std.testing.expect(game.caught);
    const high = game.high_score;
    try std.testing.expect(high > 0);
    wait = 0;
    while (game.freeze > 0 and wait < 1000) : (wait += 1) game.tick();
    try std.testing.expectEqual(pacman.game_over_ticks, game.game_over);
    try std.testing.expect(!game.pacVisible());
    try std.testing.expect(!game.ghostVisible(0));
    try std.testing.expectEqual(score_before_death, game.score); // still on the board
    wait = 0;
    while (game.game_over > 0 and wait < 1000) : (wait += 1) game.tick();
    try std.testing.expectEqual(@as(u32, 0), game.score);
    try std.testing.expectEqual(high, game.high_score);
    try std.testing.expectEqual(pacman.start_lives, game.lives);
    try std.testing.expectEqual(@as(u8, 1), game.level);
    try std.testing.expectEqual(gen + 1, game.generation);
    try std.testing.expectEqual(pacman.ready_ticks, game.ready);
    try std.testing.expect(game.dots_left > 20);
}

test "clearing the board flashes the maze, then the next level on a new maze keeps the score" {
    var game = Game.init(5);
    game.ready = 0;
    for (game.ghosts[1..]) |*g| {
        g.inside = true;
        g.wait = 200;
    }
    game.ghosts[0] = .{ .actor = Actor.at(game.cols - 2, game.rows - 2, .left), .inside = false, .wait = 0 };
    // Leave a single dot next to Pac-Man.
    for (&game.dots) |*row| @memset(row, false);
    for (&game.energizers) |*row| @memset(row, false);
    game.pac = Actor.at(1, 3, .down);
    game.dots[4][1] = true;
    game.dots_left = 1;
    game.score = 1230;
    game.step();
    try std.testing.expectEqual(@as(u32, 0), game.dots_left);
    try std.testing.expectEqual(pacman.freeze_ticks, game.freeze);
    try std.testing.expect(!game.caught);
    try std.testing.expect(game.ghostVisible(0)); // the ghosts stay for the flash
    const gen = game.generation;
    var wait: usize = 0;
    while (game.freeze > 0 and wait < 1000) : (wait += 1) game.tick();
    try std.testing.expectEqual(@as(u8, 2), game.level);
    try std.testing.expectEqual(gen + 1, game.generation);
    try std.testing.expectEqual(@as(u32, 1240), game.score);
    try std.testing.expectEqual(pacman.ready_ticks, game.ready);
    try std.testing.expect(game.dots_left > 20);
    try std.testing.expectEqual(pacman.FruitKind.strawberry, pacman.FruitKind.forLevel(game.level));
}

test "fruit shows up below the house at 29% and 70% of the dots, pays its level's points, and leaves" {
    var game = Game.init(5);
    game.ready = 0;
    for (game.ghosts[1..]) |*g| {
        g.inside = true;
        g.wait = 200;
    }
    game.ghosts[0] = .{ .actor = Actor.at(game.cols - 2, game.rows - 2, .left), .inside = false, .wait = 0 };
    try std.testing.expectEqual(game.dots_left, game.dots_total);
    try std.testing.expect(game.fruit == null);

    // Pretend most of a third of the dots are gone; the next dot brings the cherry.
    game.dots_left = game.dots_total - game.dots_total * 29 / 100;
    game.pac = Actor.at(1, 3, .down);
    game.dots[3][1] = false;
    game.dots[2][1] = false;
    game.dots[4][2] = false;
    game.energizers[4][1] = false;
    game.step();
    const fruit = game.fruit.?;
    try std.testing.expectEqual(pacman.FruitKind.cherry, fruit.kind);
    try std.testing.expectEqual(game.pacStart(), [2]i32{ fruit.x, fruit.y });
    try std.testing.expectEqual(pacman.fruit_steps, fruit.steps);
    try std.testing.expectEqual(@as(u8, 1), game.fruit_shown);

    // Pac-Man next to it goes for it and banks 100.
    const start = game.pacStart();
    try std.testing.expectEqual(Tile.path, game.tile(start[0] - 1, start[1]));
    game.pac = Actor.at(start[0] - 1, start[1], .left);
    const score_before = game.score;
    game.step();
    try std.testing.expect(game.fruit == null);
    try std.testing.expectEqual(score_before + 100, game.score);
    const popup = game.popup.?;
    try std.testing.expectEqual(@as(u32, 100), popup.points);
    try std.testing.expect(popup.ghost == null);
    try std.testing.expectEqual(pacman.popup_ticks, popup.ticks);
    try std.testing.expect(game.pacVisible()); // fruit does not pause play
    game.tick();
    try std.testing.expectEqual(pacman.popup_ticks - 1, game.popup.?.ticks);

    // Not before 70% for the second one; then it goes uneaten and times out.
    game.step();
    try std.testing.expect(game.fruit == null);
    game.dots_left = game.dots_total - game.dots_total * 70 / 100 - 1;
    game.pac = Actor.at(1, 3, .down);
    game.dots[4][1] = true;
    game.dots[3][1] = false;
    game.dots[2][1] = false;
    game.step();
    try std.testing.expectEqual(@as(u8, 2), game.fruit_shown);
    try std.testing.expect(game.fruit != null);
    game.fruit.?.steps = 1;
    game.pac = Actor.at(1, 3, .down); // far from the fruit: not eaten
    game.step();
    try std.testing.expect(game.fruit == null);
    // Third time is never.
    game.dots_left = 1;
    game.dots[4][1] = true;
    game.pac = Actor.at(1, 3, .down);
    game.step();
    try std.testing.expect(game.fruit == null);

    // Level table.
    try std.testing.expectEqual(pacman.FruitKind.orange, pacman.FruitKind.forLevel(4));
    try std.testing.expectEqual(pacman.FruitKind.key, pacman.FruitKind.forLevel(20));
    try std.testing.expectEqual(@as(u32, 5000), pacman.FruitKind.key.points());
}

test "four energizers sit on corner corridor dots, mirrored left to right" {
    const sizes = [_][2]u16{ .{ 28, 31 }, .{ 45, 27 }, .{ 15, 15 }, .{ 75, 48 } };
    for (sizes, 0..) |size, n| {
        var game = Game.init(21 + n);
        game.configure(size[0], size[1]);
        var count: u32 = 0;
        var y: i32 = 0;
        while (y < game.rows) : (y += 1) {
            var x: i32 = 0;
            while (x < game.cols) : (x += 1) {
                if (!game.energizers[@intCast(y)][@intCast(x)]) continue;
                count += 1;
                try std.testing.expectEqual(Tile.path, game.tile(x, y));
                try std.testing.expect(game.dots[@intCast(y)][@intCast(x)]);
                try std.testing.expect(game.energizers[@intCast(y)][@intCast(game.cols - 1 - x)]);
            }
        }
        try std.testing.expectEqual(@as(u32, 4), count);
        for (game.energizerSpots()) |spot| try std.testing.expect(game.energizers[@intCast(spot[1])][@intCast(spot[0])]);
    }
}

test "an energizer frightens the ghosts; a frightened ghost is eaten and its eyes walk home" {
    var game = Game.init(5);
    // The top-left energizer sits at (1,4) on the outer corridor.
    try std.testing.expect(game.energizers[4][1]);
    try std.testing.expectEqual(Tile.path, game.tile(1, 3));
    try std.testing.expectEqual(Tile.path, game.tile(1, 5));
    // Pac-Man just above it with nothing nearer to eat; one ghost far away
    // in the bottom-right corner, the rest kept in the house.
    game.pac = Actor.at(1, 3, .down);
    game.dots[3][1] = false;
    game.dots[2][1] = false;
    game.dots[4][2] = false; // so (1,5) is the only dot one step from the pellet
    game.ghosts[0] = .{ .actor = Actor.at(game.cols - 2, game.rows - 2, .left), .inside = false, .wait = 0 };
    for (game.ghosts[1..]) |*g| {
        g.inside = true;
        g.wait = 200;
    }
    const dots_before = game.dots_left;
    game.ready = 0;
    game.step();
    try std.testing.expectEqual([2]i32{ 1, 4 }, [2]i32{ game.pac.x, game.pac.y });
    try std.testing.expect(!game.energizers[4][1]);
    try std.testing.expectEqual(dots_before - 1, game.dots_left); // energizers count toward the clear
    try std.testing.expectEqual(pacman.energizer_points, game.score);
    try std.testing.expectEqual(pacman.fright_steps, game.fright);
    try std.testing.expect(game.ghosts[0].frightened);
    try std.testing.expect(game.ghosts[0].edible());
    try std.testing.expect(!game.ghosts[0].dangerous());
    for (game.ghosts[1..]) |g| try std.testing.expect(!g.frightened); // the house is out of reach

    // The frightened ghost runs into Pac-Man from below: eaten, not caught.
    game.ghosts[0].actor = Actor.at(1, 5, .up);
    game.step();
    try std.testing.expect(!game.caught);
    try std.testing.expectEqual(@as(u16, 0), game.freeze);
    try std.testing.expect(game.ghosts[0].eyes);
    try std.testing.expect(!game.ghosts[0].frightened);
    try std.testing.expect(!game.ghosts[0].dangerous());
    // 200 for the first ghost (plus the dot on the tile he stepped to), shown
    // in its place while the board holds; Pac-Man and the eaten ghost are
    // hidden behind it.
    try std.testing.expectEqual(pacman.energizer_points + pacman.dot_points + pacman.ghost_points, game.score);
    try std.testing.expectEqual(@as(u8, 1), game.ghost_combo);
    try std.testing.expectEqual(pacman.hold_ticks, game.hold);
    try std.testing.expect(game.holdingStill());
    try std.testing.expect(!game.pacVisible());
    try std.testing.expect(!game.ghostVisible(0));
    try std.testing.expect(game.ghostVisible(1));
    const popup = game.popup.?;
    try std.testing.expectEqual(@as(u32, 200), popup.points);
    try std.testing.expectEqual(@as(?u8, 0), popup.ghost);
    try std.testing.expectEqual([2]i32{ 1, 4 }, [2]i32{ popup.x, popup.y }); // where the ghost ended up
    // The hold runs out with the popup; ticks meanwhile don't step the board.
    const pac_during_hold = game.pac;
    var t: usize = 0;
    while (t < pacman.hold_ticks) : (t += 1) game.tick();
    try std.testing.expectEqual(@as(u16, 0), game.hold);
    try std.testing.expect(game.popup == null);
    try std.testing.expect(game.pacVisible());
    try std.testing.expectEqual(pac_during_hold.x, game.pac.x);
    // A second ghost in the same fright is worth 400.
    game.ghosts[1] = .{ .actor = Actor.at(1, 4, .down), .inside = false, .wait = 0, .frightened = true };
    game.pac = Actor.at(1, 5, .up);
    game.dots[4][1] = false;
    game.dots[5][1] = false;
    game.dots[6][1] = false;
    game.fright = 3; // odd next step: the ghost moves into Pac-Man
    game.step();
    try std.testing.expect(game.ghosts[1].eyes);
    try std.testing.expectEqual(pacman.energizer_points + pacman.dot_points + 200 + 400, game.score);
    try std.testing.expectEqual(@as(u8, 2), game.ghost_combo);
    game.hold = 0;

    // The eyes cross the board, pass the door, and turn back into a ghost
    // inside the house, harmless the whole way.
    var steps: usize = 0;
    while (!game.ghosts[0].inside and steps < 500) : (steps += 1) {
        game.step();
        try std.testing.expect(!game.caught);
        const g = game.ghosts[0];
        try std.testing.expect(g.inside or game.passable(g.actor.x, g.actor.y, .ghost_eyes));
        game.hold = 0; // step() directly; ignore any pause from a further catch
    }
    try std.testing.expect(game.ghosts[0].inside);
    try std.testing.expect(!game.ghosts[0].eyes);
    try std.testing.expectEqual(Tile.house, game.tile(game.ghosts[0].actor.x, game.ghosts[0].actor.y));

    // The fright wears off on schedule.
    steps = 0;
    while (game.fright > 0 and steps < pacman.fright_steps + 1) : (steps += 1) game.step();
    try std.testing.expectEqual(@as(u16, 0), game.fright);
    for (game.ghosts) |g| try std.testing.expect(!g.frightened);

    // A fresh board has its energizers back and no fright; the score stays.
    const score = game.score;
    game.reset(6);
    try std.testing.expectEqual(@as(u16, 0), game.fright);
    try std.testing.expectEqual(@as(u8, 0), game.ghost_combo);
    try std.testing.expectEqual(score, game.score);
    for (game.energizerSpots()) |spot| try std.testing.expect(game.energizers[@intCast(spot[1])][@intCast(spot[0])]);
    for (game.ghosts) |g| try std.testing.expect(!g.frightened and !g.eyes);
}

test "score text: at least two digits, and 10000 points buys an extra life once" {
    var buf: [12]u8 = undefined;
    try std.testing.expectEqualStrings("00", pacman.formatScore(&buf, 0));
    try std.testing.expectEqualStrings("10", pacman.formatScore(&buf, 10));
    try std.testing.expectEqualStrings("123450", pacman.formatScore(&buf, 123450));

    var game = Game.init(5);
    game.ready = 0;
    for (game.ghosts[1..]) |*g| {
        g.inside = true;
        g.wait = 200;
    }
    game.ghosts[0] = .{ .actor = Actor.at(game.cols - 2, game.rows - 2, .left), .inside = false, .wait = 0 };
    game.score = 9990;
    game.high_score = 20000;
    game.pac = Actor.at(1, 3, .down);
    game.dots[3][1] = false;
    game.dots[2][1] = false;
    game.dots[4][2] = false;
    game.energizers[4][1] = false;
    game.step(); // one dot: 10000
    try std.testing.expectEqual(@as(u32, 10000), game.score);
    try std.testing.expectEqual(pacman.start_lives + 1, game.lives);
    try std.testing.expectEqual(@as(u32, 20000), game.high_score); // not beaten
    game.step();
    try std.testing.expectEqual(pacman.start_lives + 1, game.lives); // once only
}

test "tunnels wrap around" {
    var game = Game.init(3);
    game.configure(45, 27);
    const t = game.tunnel_row.?;
    try std.testing.expectEqual([2]i32{ game.cols - 1, t }, game.neighbor(0, t, .left).?);
    try std.testing.expectEqual([2]i32{ 0, t }, game.neighbor(game.cols - 1, t, .right).?);
    try std.testing.expect(game.neighbor(0, t + 3, .left) == null);
}

test "cell renderer draws the HUD, the maze, dots, and Pac-Man on the terminal grid" {
    const gpa = std.testing.allocator;
    var engine = Engine.init(gpa, 9);
    defer engine.deinit();
    try engine.reset(80, 30, 9);
    // 80 columns → a 39-wide maze at two columns per tile; 30 rows → 27 board
    // rows between the two HUD rows above and the one below.
    try std.testing.expectEqual(@as(u16, 39), engine.game.cols);
    try std.testing.expectEqual(@as(u16, 27), engine.game.rows);
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 30, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 80, .height = 30, .screen = &screen };
    const origin_x: u16 = (80 - 39 * 2) / 2;
    const origin_y: u16 = 2;

    // "READY!" first: the message on the corridor below the house, no Pac-Man.
    engine.draw(win, .full_screen, 255);
    const start = engine.game.pacStart();
    const px: u16 = origin_x + @as(u16, @intCast(start[0])) * 2;
    const py: u16 = origin_y + @as(u16, @intCast(start[1]));
    try std.testing.expectEqualStrings("A", win.readCell(px, py).?.char.grapheme); // RE[A]DY! centered on Pac-Man's start
    try std.testing.expectEqualStrings("R", win.readCell(px - 2, py).?.char.grapheme);
    try std.testing.expectEqualStrings("!", win.readCell(px + 3, py).?.char.grapheme);

    engine.game.ready = 0;
    engine.draw(win, .full_screen, 255);
    const wall = win.readCell(origin_x, origin_y).?; // top-left border tile
    try std.testing.expect(std.meta.eql(wall.style.bg, effect.scaledColor(wall_color, 255)));
    // (1,1) is the top-left corridor node and holds a dot.
    try std.testing.expectEqualStrings("·", win.readCell(origin_x + 2, origin_y + 1).?.char.grapheme);
    try std.testing.expectEqualStrings("●", win.readCell(px, py).?.char.grapheme);
    // The door is drawn as a bar.
    const door_x: u16 = origin_x + @as(u16, @intCast(engine.game.centerX())) * 2;
    const door_y: u16 = origin_y + @as(u16, @intCast(engine.game.doorY()));
    try std.testing.expectEqualStrings("─", win.readCell(door_x, door_y).?.char.grapheme);

    // Header: "1UP" over a two-digit score, "HIGH SCORE" centered over its value.
    try std.testing.expectEqualStrings("1", win.readCell(origin_x + 3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("U", win.readCell(origin_x + 4, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("P", win.readCell(origin_x + 5, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("0", win.readCell(origin_x + 8, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("0", win.readCell(origin_x + 9, 1).?.char.grapheme);
    const hs_col: u16 = origin_x + (78 - 10) / 2;
    try std.testing.expectEqualStrings("H", win.readCell(hs_col, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("E", win.readCell(hs_col + 9, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("0", win.readCell(hs_col + 7, 1).?.char.grapheme);
    // Footer: two spare lives on the left, the level's cherry on the right.
    const foot: u16 = origin_y + 27;
    try std.testing.expectEqualStrings("◗", win.readCell(origin_x + 2, foot).?.char.grapheme);
    try std.testing.expectEqualStrings("◗", win.readCell(origin_x + 4, foot).?.char.grapheme);
    try std.testing.expect(!std.mem.eql(u8, "◗", win.readCell(origin_x + 6, foot).?.char.grapheme)); // no third
    const cherry = win.readCell(origin_x + 78 - 3, foot).?;
    try std.testing.expectEqualStrings("●", cherry.char.grapheme);
    try std.testing.expect(std.meta.eql(cherry.style.fg, effect.scaledColor(pacman.FruitKind.cherry.color(), 255)));

    // A score on the board; "1UP" and the energizers stay lit on any frame
    // (the arcade blinked them; a screensaver shouldn't).
    engine.game.score = 1230;
    engine.game.high_score = 45670;
    engine.game.frame = 8;
    engine.draw(win, .full_screen, 255);
    try std.testing.expectEqualStrings("1", win.readCell(origin_x + 3, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("1", win.readCell(origin_x + 6, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("0", win.readCell(origin_x + 9, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("4", win.readCell(hs_col + 3, 1).?.char.grapheme);
    try std.testing.expectEqualStrings("●", win.readCell(origin_x + 2, origin_y + 4).?.char.grapheme);
    engine.game.frame = 0;
    engine.draw(win, .full_screen, 255);
    // The top-left energizer (1,4) is a big pellet.
    try std.testing.expectEqualStrings("●", win.readCell(origin_x + 2, origin_y + 4).?.char.grapheme);
    try std.testing.expect(win.readCell(origin_x + 2, origin_y + 4).?.style.bold);

    // Frightened ghosts turn blue; eaten ones are drawn as eyes.
    engine.game.fright = pacman.fright_steps;
    engine.game.ghosts[0].frightened = true;
    engine.game.ghosts[1] = .{ .actor = Actor.at(1, 5, .down), .inside = false, .wait = 0, .eyes = true };
    engine.draw(win, .full_screen, 255);
    const g0 = engine.game.ghosts[0].actor;
    const blue = win.readCell(origin_x + @as(u16, @intCast(g0.x)) * 2, origin_y + @as(u16, @intCast(g0.y))).?;
    try std.testing.expectEqualStrings("M", blue.char.grapheme);
    try std.testing.expect(std.meta.eql(blue.style.fg, effect.scaledColor(pacman.fright_color, 255)));
    try std.testing.expectEqualStrings("¨", win.readCell(origin_x + 2, origin_y + 5).?.char.grapheme);

    // Fruit on the board, and a ghost's score in its place while the board holds.
    engine.game.fruit = .{ .kind = .strawberry, .x = 3, .y = 1, .steps = 10 };
    engine.game.popup = .{ .x = 1, .y = 5, .points = 400, .ticks = 10, .ghost = 1 };
    engine.game.hold = 10;
    engine.draw(win, .full_screen, 255);
    const berry = win.readCell(origin_x + 6, origin_y + 1).?;
    try std.testing.expectEqualStrings("♥", berry.char.grapheme);
    try std.testing.expect(std.meta.eql(berry.style.fg, effect.scaledColor(pacman.FruitKind.strawberry.color(), 255)));
    const four = win.readCell(origin_x + 2, origin_y + 5).?; // "400" centered on the eyes' tile, eyes hidden
    try std.testing.expectEqualStrings("4", four.char.grapheme);
    try std.testing.expect(std.meta.eql(four.style.fg, effect.scaledColor(pacman.ghost_popup_color, 255)));
    try std.testing.expect(!std.mem.eql(u8, "●", win.readCell(px, py).?.char.grapheme)); // Pac-Man hidden for the pause

    // "GAME OVER" in red.
    engine.game.hold = 0;
    engine.game.popup = null;
    engine.game.game_over = 10;
    engine.draw(win, .full_screen, 255);
    const over = win.readCell(px - 3, py).?; // [G]AME OVER, nine cells centered on the start
    try std.testing.expectEqualStrings("G", over.char.grapheme);
    try std.testing.expect(std.meta.eql(over.style.fg, effect.scaledColor(pacman.game_over_color, 255)));
}

test "pixel renderer: HUD, outlined walls, a pink door, dots, a yellow Pac-Man, ghosts in their colors" {
    const gpa = std.testing.allocator;
    var game = Game.init(7);
    game.configure(45, 27);
    const t: u16 = 16;
    const width: u16 = game.cols * t;
    // Two HUD rows above the board, one below.
    const height: u16 = (game.rows + pacman.hud_rows) * t;
    const oy: usize = 2 * t;
    const background = try gpa.alloc(u8, @as(usize, width) * height * 3);
    defer gpa.free(background);
    const rgb = try gpa.alloc(u8, background.len);
    defer gpa.free(rgb);
    renderBackground(&game, background, width, height);
    const px = struct {
        fn at(buf: []const u8, w: u16, x: usize, y: usize) [3]u8 {
            const i = (y * w + x) * 3;
            return .{ buf[i], buf[i + 1], buf[i + 2] };
        }
    };

    // "READY!" in yellow on the corridor below the house.
    renderPixels(&game, rgb, background, width, height);
    const ready_x: usize = @intCast(game.centerX() * t + 8 - 35); // 6 glyphs at scale 2: 70 px wide
    const ready_y: usize = oy + @as(usize, @intCast((game.doorY() + 5) * t)) + 1;
    try std.testing.expectEqual(pac_color, px.at(rgb, width, ready_x, ready_y)); // top-left of the R
    game.ready = 0;
    renderPixels(&game, rgb, background, width, height);
    try std.testing.expectEqual(black, px.at(rgb, width, ready_x, ready_y));

    // Corridor tile (1,1): black corner, dot in the middle.
    try std.testing.expectEqual(black, px.at(rgb, width, 16, oy + 16));
    try std.testing.expectEqual(dot_color, px.at(rgb, width, 16 + 8, oy + 16 + 8));
    // The border wall tile (1,0) carries the outline band 4 px in from the
    // corridor below it (inset 0.24·16 ≈ 3.8, line 1.6): row 16 - 5 is blue,
    // the tile's own middle is black.
    try std.testing.expectEqual(wall_color, px.at(rgb, width, 16 + 8, oy + 16 - 5));
    try std.testing.expectEqual(black, px.at(rgb, width, 16 + 8, oy + 16 - 9));
    // Door bar.
    const dx: usize = @intCast(game.centerX() * t + 8);
    const dy: usize = oy + @as(usize, @intCast(game.doorY() * t + 7));
    try std.testing.expectEqual(door_color, px.at(rgb, width, dx, dy));
    // Pac-Man's center.
    const start = game.pacStart();
    try std.testing.expectEqual(pac_color, px.at(rgb, width, @intCast(start[0] * t + 8), oy + @as(usize, @intCast(start[1] * t + 8))));
    // Each ghost paints its color low in its tile (under the eyes).
    for (game.ghosts, ghost_colors) |g, color| {
        try std.testing.expectEqual(color, px.at(rgb, width, @intCast(g.actor.x * t + 8), oy + @as(usize, @intCast(g.actor.y * t + 12))));
    }
    // The energizer at (1,4) is a disc wider than a dot: its center and a
    // pixel 4 in from the tile edge are both pellet-colored, where a dot
    // (4 px wide, centered) would leave the latter black.
    try std.testing.expectEqual(dot_color, px.at(rgb, width, 1 * t + 8, oy + 4 * t + 8));
    try std.testing.expectEqual(dot_color, px.at(rgb, width, 1 * t + 4, oy + 4 * t + 8));
    try std.testing.expectEqual(black, px.at(rgb, width, 16 + 4, oy + 16 + 8));

    // Header: the "1" of "1UP" one tile in, at scale 2 (rows 0-1 of the glyph
    // are its stem, columns 2 of 5); "HIGH SCORE" centered; the footer holds
    // two yellow lives and a red cherry.
    try std.testing.expectEqual(pacman.text_color, px.at(rgb, width, 16 + 4, 1));
    try std.testing.expectEqual(black, px.at(rgb, width, 16, 1));
    const hs_x: usize = (@as(usize, width) - (10 * 12 - 2)) / 2; // "HIGH SCORE" is 118 px at scale 2
    try std.testing.expectEqual(pacman.text_color, px.at(rgb, width, hs_x, 1)); // the H's left stem
    const foot_cy: usize = oy + @as(usize, game.rows) * t + 8;
    try std.testing.expectEqual(pac_color, px.at(rgb, width, 24 + 2, foot_cy)); // first life, just right of its center (the mouth faces left)
    try std.testing.expectEqual(pac_color, px.at(rgb, width, 48 + 2, foot_cy)); // second life
    try std.testing.expectEqual(black, px.at(rgb, width, 72 + 2, foot_cy)); // no third
    const cherry_cx: usize = @as(usize, width) - 24;
    try std.testing.expectEqual(pacman.FruitKind.cherry.color(), px.at(rgb, width, cherry_cx + 3, foot_cy + 3));

    // Frightened: blue body. Eaten: no body, only eyes.
    game.fright = pacman.fright_steps;
    game.ghosts[0].frightened = true;
    game.ghosts[1] = .{ .actor = Actor.at(1, 5, .down), .inside = false, .wait = 0, .eyes = true };
    renderPixels(&game, rgb, background, width, height);
    const g0 = game.ghosts[0].actor;
    try std.testing.expectEqual(pacman.fright_color, px.at(rgb, width, @intCast(g0.x * t + 8), oy + @as(usize, @intCast(g0.y * t + 12))));
    try std.testing.expectEqual(black, px.at(rgb, width, 1 * t + 8, oy + 5 * t + 12));
    // The flash near the end of the fright turns the body pale.
    game.fright = 2;
    game.frame = 4;
    try std.testing.expect(pacman.frightFlashing(&game));
    renderPixels(&game, rgb, background, width, height);
    try std.testing.expectEqual(pacman.fright_flash, px.at(rgb, width, @intCast(g0.x * t + 8), oy + @as(usize, @intCast(g0.y * t + 12))));
    game.fright = 0;
    game.frame = 0;
    game.ghosts[0].frightened = false;
    game.ghosts[1] = .{ .actor = Actor.at(game.centerX(), game.doorY() + 2, .up), .inside = true, .wait = 8 };

    // A cherry below the house (its right cherry is solid red), a cyan ghost
    // score at (3,1), and Pac-Man gone while the board holds for it.
    game.fruit = .{ .kind = .cherry, .x = start[0], .y = start[1], .steps = 10 };
    game.popup = .{ .x = 3, .y = 1, .points = 200, .ticks = 10, .ghost = 0 };
    game.hold = 10;
    renderPixels(&game, rgb, background, width, height);
    const fcx: usize = @intCast(start[0] * t + 8);
    const fcy: usize = oy + @as(usize, @intCast(start[1] * t + 8));
    try std.testing.expectEqual([3]u8{ 0xff, 0x00, 0x00 }, px.at(rgb, width, fcx + 4, fcy + 4));
    try std.testing.expectEqual(pacman.ghost_popup_color, px.at(rgb, width, 3 * t + 8 - 8 + 1, oy + t + 8 - 3)); // top bar of the 2
    try std.testing.expect(!game.ghostVisible(0)); // Blinky hides behind his score
    try std.testing.expectEqual(black, px.at(rgb, width, @intCast(g0.x * t + 8), oy + @as(usize, @intCast(g0.y * t + 12))));
    game.fruit = null;
    game.popup = null;
    game.hold = 0;
    // Deterministic for a given state.
    var i: usize = 0;
    while (i < step_ticks + 1) : (i += 1) game.tick();
    renderPixels(&game, rgb, background, width, height);
    const copy = try gpa.dupe(u8, rgb);
    defer gpa.free(copy);
    renderPixels(&game, rgb, background, width, height);
    try std.testing.expectEqualSlices(u8, copy, rgb);
}
