//! Pac-Man attract mode. The rules and the ghosts follow feiss' 1024-byte
//! js1k 2019 entry "PAC-MAN" (https://js1k.com/2019-x/demo/4122): ghosts run
//! straight until a wall and then turn pseudo-randomly, a catch resets the
//! board, no score. The maze is generated to fit the screen along the lines
//! of the arcade original: left-right symmetric, one-tile corridors between
//! chunky wall pieces, no dead ends, a ghost house in the middle with a door
//! only ghosts may pass, and side tunnels that wrap around. Where the
//! original read the cursor keys, this drives Pac-Man itself: breadth-first
//! toward the nearest dot, steering away when a ghost is close.
//!
//! Added over the original, after the arcade: four energizers near the
//! corners that turn the ghosts outside the house blue and reverse them —
//! while it lasts Pac-Man hunts them, and a ghost he catches is reduced to a
//! pair of eyes that heads back to the house before coming out again, with
//! the fright flashing before it ends. Scoring (10 a dot, 50 an energizer,
//! 200/400/800/1600 for successive ghosts, the level's fruit for the bonus
//! that shows up twice a board below the house), a "1UP" / "HIGH SCORE" header
//! and a footer of spare lives and level fruit, "READY!" before each life,
//! three lives, and "GAME OVER" before a fresh game.
//!
//! Generation works on a half-map of cells, each a 2×2 wall block with a
//! corridor along its top and left. Adjacent cells joined into one piece
//! lose the corridor between them; the corridors that remain are exactly the
//! seams between different pieces. Around any lattice node the four seams
//! are pairwise equalities on a 4-cycle, so three closed and one open is
//! impossible — no dead ends, by construction. Pieces touching the center
//! column may join their mirror image (the arcade's T shapes).
//!
//! `Game` is the board and its rules. `renderBackground`/`renderPixels`
//! draw it into an RGB framebuffer (the Kitty graphics screensaver: an
//! outlined maze, anti-aliased sprites gliding between tiles), and `Engine`
//! draws it on terminal cells for terminals without graphics.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

/// Tile grid bounds (12 cells per half + 3, 15 cells tall + 3).
pub const max_cols: u16 = 80;
pub const max_rows: u16 = 48;
const max_bw: u32 = 12;
const max_bh: u32 = 15;
const max_tiles: usize = @as(usize, max_cols) * max_rows;

pub const Tile = enum(u8) {
    wall,
    path,
    /// The ghost house door: ghosts leave through it, nobody enters.
    door,
    /// Ghost house interior.
    house,
};

/// The original's direction encoding: 1 down, 2 right, 3 up, 4 left.
pub const Dir = enum(u8) {
    down = 1,
    right = 2,
    up = 3,
    left = 4,

    pub fn dx(self: Dir) i32 {
        return switch (self) {
            .right => 1,
            .left => -1,
            else => 0,
        };
    }

    pub fn dy(self: Dir) i32 {
        return switch (self) {
            .down => 1,
            .up => -1,
            else => 0,
        };
    }

    fn reverse(self: Dir) Dir {
        return switch (self) {
            .down => .up,
            .up => .down,
            .right => .left,
            .left => .right,
        };
    }

    fn fromIndex(i: usize) Dir {
        return @enumFromInt(@as(u8, @intCast(i % 4)) + 1);
    }
};

const all_dirs = [_]Dir{ .down, .right, .up, .left };

pub const Actor = struct {
    x: i32,
    y: i32,
    /// Tile before the last step; the pixel renderer glides from it.
    px: i32,
    py: i32,
    dir: Dir,

    pub fn at(x: i32, y: i32, dir: Dir) Actor {
        return .{ .x = x, .y = y, .px = x, .py = y, .dir = dir };
    }
};

pub const Ghost = struct {
    actor: Actor,
    /// Still in the house (heading for the door).
    inside: bool,
    /// Steps to wait before leaving; ghosts are released one by one.
    wait: u8,
    /// Blue and edible after an energizer; cleared when the fright ends,
    /// when it is eaten, or when it gets back into the house.
    frightened: bool = false,
    /// Eaten: a pair of eyes heading back to the house.
    eyes: bool = false,

    /// Can catch Pac-Man.
    pub fn dangerous(self: Ghost) bool {
        return !self.inside and !self.eyes and !self.frightened;
    }

    /// Can be caught by Pac-Man.
    pub fn edible(self: Ghost) bool {
        return !self.inside and !self.eyes and self.frightened;
    }
};

/// Ticks per board step (~200 ms at the 33 ms screensaver tick — the
/// original crossed a tile in ten 22 ms frames).
pub const step_ticks: u64 = 6;
const mouth_ticks: u64 = 4;
/// Pause after a catch or a cleared board before everything resets.
pub const freeze_ticks: u16 = 30;
/// Ghosts this close (BFS steps) make Pac-Man run instead of eat.
const danger_distance: u16 = 3;
/// Board steps an energizer keeps the ghosts frightened (~6 s), and how many
/// of the last ones they flash.
pub const fright_steps: u16 = 30;
pub const fright_flash_steps: u16 = 8;
/// A frightened ghost this close is worth chasing.
const chase_distance: u16 = 6;
/// Cornered, Pac-Man dashes for an energizer this close instead of fleeing.
const energizer_dash: u16 = 5;
/// Bonus fruit this close beats the nearest dot.
const fruit_dash: u16 = 10;

/// HUD rows around the board: "1UP" / "HIGH SCORE" and their values above,
/// spare lives and the level's fruit below. Renderers reserve them.
pub const hud_rows_top: u16 = 2;
pub const hud_rows_bottom: u16 = 1;
pub const hud_rows: u16 = hud_rows_top + hud_rows_bottom;

/// "READY!" before each life (~2 s), the pause on an eaten ghost (~1 s),
/// "GAME OVER" before a new game (~3 s), how long fruit stays (~9 s), and how
/// long a fruit's score shows (~2 s).
pub const ready_ticks: u16 = 60;
pub const hold_ticks: u16 = 30;
pub const game_over_ticks: u16 = 90;
pub const fruit_steps: u16 = 45;
pub const popup_ticks: u16 = 60;
/// Spare lives at the start (the arcade's three, one in play).
pub const start_lives: u8 = 2;
pub const dot_points: u32 = 10;
pub const energizer_points: u32 = 50;
pub const ghost_points: u32 = 200;
pub const extra_life_points: u32 = 10_000;

/// The arcade's bonus fruit by level, with its points.
pub const FruitKind = enum(u8) {
    cherry,
    strawberry,
    orange,
    apple,
    melon,
    galaxian,
    bell,
    key,

    pub fn forLevel(level: u8) FruitKind {
        return switch (level) {
            0, 1 => .cherry,
            2 => .strawberry,
            3, 4 => .orange,
            5, 6 => .apple,
            7, 8 => .melon,
            9, 10 => .galaxian,
            11, 12 => .bell,
            else => .key,
        };
    }

    pub fn points(self: FruitKind) u32 {
        return switch (self) {
            .cherry => 100,
            .strawberry => 300,
            .orange => 500,
            .apple => 700,
            .melon => 1000,
            .galaxian => 2000,
            .bell => 3000,
            .key => 5000,
        };
    }

    pub fn color(self: FruitKind) [3]u8 {
        return switch (self) {
            .cherry, .strawberry, .apple => .{ 0xff, 0x00, 0x00 },
            .orange => .{ 0xff, 0xb8, 0x51 },
            .melon => .{ 0x6f, 0xd6, 0x4f },
            .galaxian => .{ 0x47, 0xb8, 0xff },
            .bell => .{ 0xff, 0xff, 0x00 },
            .key => .{ 0xde, 0xde, 0xff },
        };
    }
};

pub const Fruit = struct {
    kind: FruitKind,
    x: i32,
    y: i32,
    /// Board steps before it disappears.
    steps: u16,
};

/// Points shown in place for a moment: a ghost's (cyan, the board holds)
/// or a fruit's (pink, play goes on).
pub const Popup = struct {
    x: i32,
    y: i32,
    points: u32,
    ticks: u16,
    /// The eaten ghost, hidden behind its score while the board holds.
    ghost: ?u8,
};

// Arcade palette.
pub const ghost_colors = [4][3]u8{
    .{ 0xff, 0x00, 0x00 }, // Blinky
    .{ 0xff, 0xb8, 0xff }, // Pinky
    .{ 0x00, 0xff, 0xff }, // Inky
    .{ 0xff, 0xb8, 0x52 }, // Clyde
};
pub const wall_color = [3]u8{ 0x21, 0x21, 0xff };
pub const wall_flash = [3]u8{ 0xf0, 0xf0, 0xff };
pub const door_color = [3]u8{ 0xff, 0xb8, 0xff };
pub const dot_color = [3]u8{ 0xff, 0xb8, 0xae };
pub const pac_color = [3]u8{ 0xff, 0xff, 0x00 };
/// Frightened ghosts: the arcade's blue, flashing pale before it wears off;
/// their face is drawn in `dot_color`.
pub const fright_color = [3]u8{ 0x21, 0x21, 0xde };
pub const fright_flash = [3]u8{ 0xde, 0xde, 0xde };
/// HUD text, ghost-score and fruit-score popups, "GAME OVER".
pub const text_color = [3]u8{ 0xde, 0xde, 0xde };
pub const ghost_popup_color = [3]u8{ 0x00, 0xff, 0xff };
pub const fruit_popup_color = [3]u8{ 0xff, 0xb8, 0xff };
pub const game_over_color = [3]u8{ 0xff, 0x00, 0x00 };
const stem_color = [3]u8{ 0xde, 0x9c, 0x4a };
const leaf_color = [3]u8{ 0x00, 0xc8, 0x40 };
const eye_white = [3]u8{ 0xff, 0xff, 0xff };
const eye_pupil = [3]u8{ 0x10, 0x20, 0xa0 };
pub const black = [3]u8{ 0, 0, 0 };

pub const Layout = struct { cols: u16, rows: u16 };

/// A maze shaped for a window of the given pixel aspect: landscape windows
/// get wider mazes, portrait ones taller, both around the arcade's 28×31.
/// The HUD rows above and below the board count toward the height.
pub fn layoutForAspect(win_w: u32, win_h: u32) Layout {
    const aspect = @as(f32, @floatFromInt(@max(win_w, 1))) / @as(f32, @floatFromInt(@max(win_h, 1)));
    var bw: u32 = 3;
    var bh: u32 = 8;
    if (aspect >= 0.9) {
        const rows: f32 = @floatFromInt(3 * bh + 3 + hud_rows);
        bw = @intFromFloat(@round((rows * aspect - 3.0) / 6.0));
    } else {
        const cols: f32 = @floatFromInt(6 * bw + 3);
        bh = @intFromFloat(@round((cols / aspect - 3.0 - @as(f32, @floatFromInt(hud_rows))) / 3.0));
    }
    bw = std.math.clamp(bw, 2, max_bw);
    bh = std.math.clamp(bh, 4, max_bh);
    return .{ .cols = @intCast(6 * bw + 3), .rows = @intCast(3 * bh + 3) };
}

pub const Game = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    /// Half-map size in cells; see the module doc.
    bw: u32 = 0,
    bh: u32 = 0,
    /// Ghost house: half-width in cells and top cell row.
    hw: u32 = 1,
    jh: u32 = 0,
    /// Bumped on every new maze; renderers cache the background per generation.
    generation: u64 = 0,
    map: [max_rows][max_cols]Tile = undefined,
    dots: [max_rows][max_cols]bool = undefined,
    /// Energizers sit on dot tiles (`dots` is true there too, so they count
    /// toward clearing the board).
    energizers: [max_rows][max_cols]bool = undefined,
    dots_left: u32 = 0,
    frame: u64 = 0,
    rng: u64,
    ghosts: [4]Ghost = undefined,
    pac: Actor = undefined,
    /// Row whose left and right edge tiles wrap around, if any.
    tunnel_row: ?i32 = null,
    /// Non-zero while the board holds still after a catch/clear.
    freeze: u16 = 0,
    caught: bool = false,
    /// Board steps of fright left after an energizer.
    fright: u16 = 0,
    /// "READY!" countdown before a life starts; nothing moves.
    ready: u16 = 0,
    /// Pause after a ghost is eaten, its score shown in its place.
    hold: u16 = 0,
    /// "GAME OVER" countdown; then a new game.
    game_over: u16 = 0,
    score: u32 = 0,
    high_score: u32 = 0,
    /// Spare lives, shown along the bottom.
    lives: u8 = start_lives,
    level: u8 = 1,
    extra_life_awarded: bool = false,
    /// Ghosts eaten during the current fright, for the 200/400/800/1600 run.
    ghost_combo: u8 = 0,
    /// The bonus fruit on the board, if any, and how many this level has had.
    fruit: ?Fruit = null,
    fruit_shown: u8 = 0,
    /// Dots the board started with; fruit appears at 29% and 70% eaten.
    dots_total: u32 = 0,
    popup: ?Popup = null,

    /// An arcade-sized board (28×31 → 27×30 tiles).
    pub fn init(seed: u64) Game {
        var self: Game = .{ .rng = seedOrDefault(seed) };
        self.configure(28, 31);
        return self;
    }

    /// Size the maze to a tile budget and build it. Every later `reset`
    /// keeps the size and builds a new maze. Score, lives, and level carry
    /// over — only "GAME OVER" starts a new game.
    pub fn configure(self: *Game, target_cols: u16, target_rows: u16) void {
        const bw: u32 = @intCast((@max(@as(i32, target_cols) - 3, 0)) / 6);
        const bh: u32 = @intCast((@max(@as(i32, target_rows) - 3, 0)) / 3);
        self.bw = std.math.clamp(bw, 2, max_bw);
        self.bh = std.math.clamp(bh, 4, max_bh);
        self.cols = @intCast(6 * self.bw + 3);
        self.rows = @intCast(3 * self.bh + 3);
        self.hw = if (self.bw >= 5) 2 else 1;
        self.jh = (self.bh - 2) / 2;
        self.frame = 0;
        self.resetBoard();
    }

    pub fn reset(self: *Game, seed: u64) void {
        self.rng = seedOrDefault(seed);
        self.frame = 0;
        self.resetBoard();
    }

    fn random(self: *Game) usize {
        self.rng = effect.hash(self.rng +% 0x9e3779b97f4a7c15);
        return @intCast(self.rng >> 33);
    }

    // ------------------------------------------------------------ geometry --

    pub fn centerX(self: *const Game) i32 {
        return @intCast(3 * self.bw + 1);
    }

    pub fn doorY(self: *const Game) i32 {
        return @intCast(3 * self.jh + 2);
    }

    fn houseInteriorRows(self: *const Game) [2]i32 {
        return .{ self.doorY() + 1, self.doorY() + 3 };
    }

    fn houseInteriorCols(self: *const Game) [2]i32 {
        const half: i32 = @intCast(3 * self.hw - 2);
        return .{ self.centerX() - half, self.centerX() + half };
    }

    pub fn pacStart(self: *const Game) [2]i32 {
        return .{ self.centerX(), self.doorY() + 5 };
    }

    pub fn tile(self: *const Game, x: i32, y: i32) Tile {
        if (x < 0 or y < 0 or x >= self.cols or y >= self.rows) return .wall;
        return self.map[@intCast(y)][@intCast(x)];
    }

    /// The tile one step from (x, y), wrapping through a tunnel.
    pub fn neighbor(self: *const Game, x: i32, y: i32, dir: Dir) ?[2]i32 {
        var nx = x + dir.dx();
        const ny = y + dir.dy();
        if (self.tunnel_row) |t| {
            if (ny == t and nx < 0) nx = self.cols - 1;
            if (ny == t and nx >= self.cols) nx = 0;
        }
        if (nx < 0 or ny < 0 or nx >= self.cols or ny >= self.rows) return null;
        return .{ nx, ny };
    }

    /// Who is moving: eaten ghosts (eyes) are the only ones allowed back in
    /// through the door.
    pub const Mover = enum { pac, ghost_inside, ghost_outside, ghost_eyes };

    pub fn passable(self: *const Game, x: i32, y: i32, mover: Mover) bool {
        return switch (self.tile(x, y)) {
            .wall => false,
            .path => true,
            .door => mover == .ghost_inside or mover == .ghost_eyes,
            .house => mover == .ghost_inside or mover == .ghost_eyes,
        };
    }

    pub fn moverFor(g: Ghost) Mover {
        if (g.inside) return .ghost_inside;
        if (g.eyes) return .ghost_eyes;
        return .ghost_outside;
    }

    /// Where a ghost's eyes go after Pac-Man eats it: the house's middle.
    fn houseTarget(self: *const Game) [2]i32 {
        return .{ self.centerX(), self.houseInteriorRows()[0] + 1 };
    }

    fn openNeighbors(self: *const Game, x: i32, y: i32, mover: Mover) u8 {
        var n: u8 = 0;
        for (all_dirs) |d| {
            const next = self.neighbor(x, y, d) orelse continue;
            if (self.passable(next[0], next[1], mover)) n += 1;
        }
        return n;
    }

    // ---------------------------------------------------------- generation --

    /// A new maze with all its dots, and everyone back at the start.
    fn resetBoard(self: *Game) void {
        self.buildBoard();
        self.resetActors();
    }

    /// Score, lives and level from scratch, on a fresh board.
    fn newGame(self: *Game) void {
        self.score = 0;
        self.lives = start_lives;
        self.level = 1;
        self.extra_life_awarded = false;
        self.resetBoard();
    }

    fn buildBoard(self: *Game) void {
        var attempt: usize = 0;
        while (attempt < 40) : (attempt += 1) {
            self.buildMaze(false);
            if (self.mazeIsSound()) break;
        } else self.buildMaze(true); // the plain lattice is always sound
        self.generation +%= 1;

        // Dots on every corridor tile but Pac-Man's start and the tunnel mouths.
        self.dots_left = 0;
        const start = self.pacStart();
        var y: i32 = 0;
        while (y < self.rows) : (y += 1) {
            var x: i32 = 0;
            while (x < self.cols) : (x += 1) {
                const dot = self.tile(x, y) == .path and
                    !(x == start[0] and y == start[1]) and
                    !(self.tunnel_row == y and (x == 0 or x == self.cols - 1));
                self.dots[@intCast(y)][@intCast(x)] = dot;
                self.energizers[@intCast(y)][@intCast(x)] = false;
                if (dot) self.dots_left += 1;
            }
        }
        // Energizers a few tiles down from the top corners and up from the
        // bottom ones, like the arcade's. The lattice nodes on the outer
        // corridor are always open, so these land on dots.
        for (self.energizerSpots()) |spot| {
            if (self.dots[@intCast(spot[1])][@intCast(spot[0])]) self.energizers[@intCast(spot[1])][@intCast(spot[0])] = true;
        }
        self.dots_total = self.dots_left;
        self.fruit_shown = 0;
    }

    /// Ghosts back in the house, Pac-Man at his start, "READY!". The dots
    /// stay as they are (a lost life keeps the board).
    fn resetActors(self: *Game) void {
        const start = self.pacStart();
        // Blinky waits above the door; the others file out of the house.
        const cx = self.centerX();
        const interior = self.houseInteriorRows();
        const mid = interior[0] + 1;
        self.ghosts[0] = .{ .actor = Actor.at(cx, self.doorY() - 1, Dir.fromIndex(self.random())), .inside = false, .wait = 0 };
        self.ghosts[1] = .{ .actor = Actor.at(cx, mid, .up), .inside = true, .wait = 2 };
        self.ghosts[2] = .{ .actor = Actor.at(cx - 1, mid, .up), .inside = true, .wait = 8 };
        self.ghosts[3] = .{ .actor = Actor.at(cx + 1, mid, .up), .inside = true, .wait = 14 };
        self.pac = Actor.at(start[0], start[1], .left);
        self.freeze = 0;
        self.caught = false;
        self.fright = 0;
        self.hold = 0;
        self.ghost_combo = 0;
        self.fruit = null;
        self.popup = null;
        self.ready = ready_ticks;
    }

    /// The four energizer tiles: the outer corridor's second lattice node
    /// from the top and from the bottom, on both sides.
    pub fn energizerSpots(self: *const Game) [4][2]i32 {
        const top: i32 = 4;
        const bottom: i32 = @as(i32, self.rows) - 5;
        const right: i32 = @as(i32, self.cols) - 2;
        return .{ .{ 1, top }, .{ right, top }, .{ 1, bottom }, .{ right, bottom } };
    }

    /// Pieces on the half-map, then tiles. `plain` makes every cell its own
    /// piece: the full lattice, used only if random pieces keep failing.
    fn buildMaze(self: *Game, plain: bool) void {
        const bw = self.bw;
        const bh = self.bh;
        var piece: [max_bh][max_bw]u8 = @splat(@splat(0));
        var joins: [256]bool = @splat(false);
        var next_id: u8 = 2;

        // The house is piece 1 and always joins its mirror.
        const house_id: u8 = 1;
        joins[house_id] = true;
        var hj: u32 = self.jh;
        while (hj < self.jh + 2) : (hj += 1) {
            var hi: u32 = bw - self.hw;
            while (hi < bw) : (hi += 1) piece[hj][hi] = house_id;
        }

        // Visit cells in random order; grow a small piece from each free one.
        var order: [max_bw * max_bh]u16 = undefined;
        const n_cells: usize = bw * bh;
        for (0..n_cells) |k| order[k] = @intCast(k);
        var k: usize = n_cells;
        while (k > 1) : (k -= 1) {
            const swap = self.random() % k;
            std.mem.swap(u16, &order[k - 1], &order[swap]);
        }
        for (order[0..n_cells]) |cell| {
            const ci: u32 = cell % bw;
            const cj: u32 = cell / bw;
            if (piece[cj][ci] != 0) continue;
            const id = next_id;
            next_id +%= 1;
            if (next_id < 2) next_id = 2;
            piece[cj][ci] = id;
            var members: [5][2]u32 = undefined;
            members[0] = .{ ci, cj };
            var size: usize = 1;
            const target: usize = if (plain) 1 else pieceSize(self.random());
            while (size < target) {
                // Free neighbors of the piece so far.
                var options: [20][2]u32 = undefined;
                var count: usize = 0;
                for (members[0..size]) |m| {
                    for (all_dirs) |d| {
                        const nx = @as(i32, @intCast(m[0])) + d.dx();
                        const ny = @as(i32, @intCast(m[1])) + d.dy();
                        if (nx < 0 or ny < 0 or nx >= bw or ny >= bh) continue;
                        if (piece[@intCast(ny)][@intCast(nx)] != 0) continue;
                        var dup = false;
                        for (options[0..count]) |o| dup = dup or (o[0] == nx and o[1] == ny);
                        if (!dup and count < options.len) {
                            options[count] = .{ @intCast(nx), @intCast(ny) };
                            count += 1;
                        }
                    }
                }
                if (count == 0) break;
                const pick = options[self.random() % count];
                piece[pick[1]][pick[0]] = id;
                members[size] = pick;
                size += 1;
            }
            var touches_center = false;
            for (members[0..size]) |m| touches_center = touches_center or m[0] == bw - 1;
            joins[id] = !plain and touches_center and self.random() % 100 < 45;
        }

        // Tiles: a wall border around the mirrored half-map.
        var y: i32 = 0;
        while (y < self.rows) : (y += 1) {
            var x: i32 = 0;
            while (x < self.cols) : (x += 1) {
                const on_border = x == 0 or y == 0 or x == self.cols - 1 or y == self.rows - 1;
                self.map[@intCast(y)][@intCast(x)] = if (on_border) .wall else interiorTile(&piece, &joins, bw, bh, x - 1, y - 1);
            }
        }

        // Carve the house: interior and door.
        const rows_i = self.houseInteriorRows();
        const cols_i = self.houseInteriorCols();
        var yy = rows_i[0];
        while (yy <= rows_i[1]) : (yy += 1) {
            var xx = cols_i[0];
            while (xx <= cols_i[1]) : (xx += 1) self.map[@intCast(yy)][@intCast(xx)] = .house;
        }
        self.map[@intCast(self.doorY())][@intCast(self.centerX())] = .door;

        // Side tunnels at the house's middle row, on mazes wide enough.
        self.tunnel_row = null;
        if (bw >= 3) {
            const t: i32 = @intCast(3 * (self.jh + 1) + 1);
            self.map[@intCast(t)][0] = .path;
            self.map[@intCast(t)][@intCast(self.cols - 1)] = .path;
            self.tunnel_row = t;
        }
    }

    fn pieceSize(r: usize) usize {
        // 1:2:4:4:2 — mostly threes and fours, few lone blocks, few fives.
        const v = r % 13;
        if (v < 1) return 1;
        if (v < 3) return 2;
        if (v < 7) return 3;
        if (v < 11) return 4;
        return 5;
    }

    /// One tile of the half-map lattice (interior coordinates, mirrored).
    fn interiorTile(piece: *const [max_bh][max_bw]u8, joins: *const [256]bool, bw: u32, bh: u32, ix_in: i32, iy: i32) Tile {
        const center: i32 = @intCast(3 * bw);
        const ix = if (ix_in > center) 2 * center - ix_in else ix_in;
        const mx = @mod(ix, 3);
        const my = @mod(iy, 3);
        if (mx != 0 and my != 0) return .wall; // inside a block
        if (mx != 0) return if (horizontalSeamClosed(piece, bw, bh, ix, iy)) .wall else .path;
        if (my != 0) return if (verticalSeamClosed(piece, joins, bw, bh, ix, iy)) .wall else .path;
        // A node: closed only when every seam around it is.
        const open = @as(u8, @intFromBool(!horizontalSeamClosed(piece, bw, bh, ix - 1, iy))) +
            @as(u8, @intFromBool(!horizontalSeamClosed(piece, bw, bh, ix + 1, iy))) +
            @as(u8, @intFromBool(!verticalSeamClosed(piece, joins, bw, bh, ix, iy - 1))) +
            @as(u8, @intFromBool(!verticalSeamClosed(piece, joins, bw, bh, ix, iy + 1)));
        return if (open == 0) .wall else .path;
    }

    /// Corridor tile on a horizontal lattice line (between the cell above
    /// and the cell below): closed when both belong to one piece.
    fn horizontalSeamClosed(piece: *const [max_bh][max_bw]u8, bw: u32, bh: u32, ix: i32, iy: i32) bool {
        if (iy <= 0 or iy >= 3 * @as(i32, @intCast(bh))) return false; // boundary loop
        const center: i32 = @intCast(3 * bw);
        const mx = if (ix > center) 2 * center - ix else ix;
        if (mx < 0 or mx > center) return false;
        const i: usize = @intCast(@divTrunc(@min(mx, center - 1), 3));
        const j: usize = @intCast(@divTrunc(iy, 3));
        return piece[j - 1][i] == piece[j][i];
    }

    /// Corridor tile on a vertical lattice line (between the cell to the
    /// left and the cell to the right). The center line closes where the
    /// piece beside it joins its mirror.
    fn verticalSeamClosed(piece: *const [max_bh][max_bw]u8, joins: *const [256]bool, bw: u32, bh: u32, ix: i32, iy: i32) bool {
        if (iy < 0 or iy > 3 * @as(i32, @intCast(bh))) return false;
        const center: i32 = @intCast(3 * bw);
        const mx = if (ix > center) 2 * center - ix else ix;
        if (mx <= 0) return false; // boundary loop
        const j: usize = @intCast(@divTrunc(iy, 3));
        if (mx == center) return joins[piece[j][bw - 1]];
        const i: usize = @intCast(@divTrunc(mx, 3));
        return piece[j][i - 1] == piece[j][i];
    }

    /// Every corridor reachable from Pac-Man's start, and no dead ends.
    pub fn mazeIsSound(self: *const Game) bool {
        var dist: [max_tiles]u16 = undefined;
        var parent: [max_tiles]u16 = undefined;
        const start = self.pacStart();
        if (self.tile(start[0], start[1]) != .path) return false;
        self.bfs(start[0], start[1], .pac, &dist, &parent);
        var y: i32 = 0;
        while (y < self.rows) : (y += 1) {
            var x: i32 = 0;
            while (x < self.cols) : (x += 1) {
                if (self.tile(x, y) != .path) continue;
                if (dist[self.index(x, y)] == std.math.maxInt(u16)) return false;
                if (self.openNeighbors(x, y, .pac) < 2) return false;
            }
        }
        return true;
    }

    fn index(self: *const Game, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * self.cols + @as(usize, @intCast(x));
    }

    fn bfs(self: *const Game, from_x: i32, from_y: i32, mover: Mover, dist: *[max_tiles]u16, parent: *[max_tiles]u16) void {
        @memset(dist, std.math.maxInt(u16));
        var queue: [max_tiles]u16 = undefined;
        var head: usize = 0;
        var tail: usize = 0;
        const start = self.index(from_x, from_y);
        dist[start] = 0;
        parent[start] = @intCast(start);
        queue[tail] = @intCast(start);
        tail += 1;
        while (head < tail) : (head += 1) {
            const cur = queue[head];
            const cx: i32 = @intCast(cur % self.cols);
            const cy: i32 = @intCast(cur / self.cols);
            for (all_dirs) |d| {
                const next = self.neighbor(cx, cy, d) orelse continue;
                if (!self.passable(next[0], next[1], mover)) continue;
                const ni = self.index(next[0], next[1]);
                if (dist[ni] == std.math.maxInt(u16)) {
                    dist[ni] = dist[cur] + 1;
                    parent[ni] = cur;
                    queue[tail] = @intCast(ni);
                    tail += 1;
                }
            }
        }
    }

    // ---------------------------------------------------------------- play --

    /// One screensaver frame. The board holds still through "GAME OVER",
    /// the death / level-clear freeze, "READY!", and the ghost-eaten pause,
    /// in that order of precedence; otherwise it steps every `step_ticks`.
    pub fn tick(self: *Game) void {
        self.frame +%= 1;
        if (self.popup) |*p| {
            p.ticks -|= 1;
            if (p.ticks == 0) self.popup = null;
        }
        if (self.game_over > 0) {
            self.game_over -= 1;
            if (self.game_over == 0) self.newGame();
            return;
        }
        if (self.freeze > 0) {
            self.freeze -= 1;
            if (self.freeze == 0) {
                if (self.caught) {
                    if (self.lives > 0) {
                        self.lives -= 1;
                        self.resetActors();
                    } else {
                        self.game_over = game_over_ticks;
                    }
                } else {
                    // Board cleared: the next level on a new maze.
                    self.level +|= 1;
                    self.resetBoard();
                }
            }
            return;
        }
        if (self.ready > 0) {
            self.ready -= 1;
            return;
        }
        if (self.hold > 0) {
            self.hold -= 1;
            return;
        }
        if (self.frame % step_ticks != 0) return;
        self.step();
    }

    /// True while nothing on the board moves (no gliding between tiles).
    pub fn holdingStill(self: *const Game) bool {
        return self.freeze > 0 or self.ready > 0 or self.hold > 0 or self.game_over > 0;
    }

    /// Pac-Man is off the board during "READY!", "GAME OVER", and while an
    /// eaten ghost's score shows.
    pub fn pacVisible(self: *const Game) bool {
        return self.ready == 0 and self.game_over == 0 and self.hold == 0;
    }

    /// Ghosts vanish for the death animation and "GAME OVER"; the eaten
    /// one hides behind its score.
    pub fn ghostVisible(self: *const Game, ghost: usize) bool {
        if (self.game_over > 0 or (self.freeze > 0 and self.caught)) return false;
        if (self.popup) |p| {
            if (p.ghost) |eaten| {
                if (eaten == ghost and self.hold > 0) return false;
            }
        }
        return true;
    }

    /// 0..1 progress of the current step, for gliding between tiles.
    pub fn stepPhase(self: *const Game) f32 {
        if (self.holdingStill()) return 1.0;
        return @as(f32, @floatFromInt((self.frame % step_ticks) + 1)) / @as(f32, @floatFromInt(step_ticks));
    }

    /// Half-angle of the mouth in radians: 0 closed, chomping while moving,
    /// opening all the way round during the death pause.
    pub fn mouthAngle(self: *const Game) f32 {
        if (self.caught) {
            const t = 1.0 - @as(f32, @floatFromInt(self.freeze)) / @as(f32, @floatFromInt(freeze_ticks));
            return 0.6 + t * (std.math.pi - 0.6);
        }
        if (self.freeze > 0) return 0.0;
        const period = 2 * mouth_ticks;
        const t = @as(f32, @floatFromInt(self.frame % period)) / @as(f32, @floatFromInt(period));
        return 0.9 * @abs(@sin(t * std.math.pi));
    }

    pub fn step(self: *Game) void {
        if (self.fright > 0) {
            self.fright -= 1;
            if (self.fright == 0) {
                for (&self.ghosts) |*g| g.frightened = false;
            }
        }
        if (self.fruit) |*f| {
            f.steps -= 1;
            if (f.steps == 0) self.fruit = null;
        }

        // Ghosts first, like the original's loop order.
        var ghosts_before: [4][2]i32 = undefined;
        for (self.ghosts, 0..) |g, i| ghosts_before[i] = .{ g.actor.x, g.actor.y };
        for (&self.ghosts) |*g| self.stepGhost(g);

        const pac_before = [2]i32{ self.pac.x, self.pac.y };
        self.pac.px = self.pac.x;
        self.pac.py = self.pac.y;
        if (self.choosePacDir()) |dir| self.pac.dir = dir;
        if (self.neighbor(self.pac.x, self.pac.y, self.pac.dir)) |next| {
            if (self.passable(next[0], next[1], .pac)) {
                self.pac.x = next[0];
                self.pac.y = next[1];
                const ate_energizer = self.energizers[@intCast(next[1])][@intCast(next[0])];
                if (self.dots[@intCast(next[1])][@intCast(next[0])]) {
                    self.dots[@intCast(next[1])][@intCast(next[0])] = false;
                    self.dots_left -= 1;
                    self.addPoints(if (ate_energizer) energizer_points else dot_points);
                }
                if (ate_energizer) {
                    self.energizers[@intCast(next[1])][@intCast(next[0])] = false;
                    self.frightenGhosts();
                }
                if (self.fruit) |f| {
                    if (f.x == next[0] and f.y == next[1]) {
                        self.addPoints(f.kind.points());
                        self.popup = .{ .x = f.x, .y = f.y, .points = f.kind.points(), .ticks = popup_ticks, .ghost = null };
                        self.fruit = null;
                    }
                }
                self.maybeSpawnFruit();
            }
        }
        // Same tile, or the two traded tiles this step (at tile granularity a
        // pass-through would otherwise read as a miss).
        for (&self.ghosts, ghosts_before, 0..) |*g, was, i| {
            if (g.inside or g.eyes) continue;
            const same = g.actor.x == self.pac.x and g.actor.y == self.pac.y;
            const swapped = was[0] == self.pac.x and was[1] == self.pac.y and
                g.actor.x == pac_before[0] and g.actor.y == pac_before[1];
            if (!(same or swapped)) continue;
            if (g.frightened) {
                // Eaten: only the eyes remain, and they head home. The board
                // holds a moment with the score where the ghost was.
                g.frightened = false;
                g.eyes = true;
                const points = ghost_points << @intCast(@min(self.ghost_combo, 3));
                self.ghost_combo +|= 1;
                self.addPoints(points);
                self.popup = .{ .x = g.actor.x, .y = g.actor.y, .points = points, .ticks = hold_ticks, .ghost = @intCast(i) };
                self.hold = hold_ticks;
                continue;
            }
            self.caught = true;
            self.freeze = freeze_ticks;
            return;
        }
        if (self.dots_left == 0) self.freeze = freeze_ticks;
    }

    fn addPoints(self: *Game, points: u32) void {
        self.score +|= points;
        if (self.score > self.high_score) self.high_score = self.score;
        if (!self.extra_life_awarded and self.score >= extra_life_points) {
            self.extra_life_awarded = true;
            self.lives +|= 1;
        }
    }

    /// The level's fruit appears below the house twice a board, once 29% of
    /// the dots are gone and again at 70%, as in the arcade.
    fn maybeSpawnFruit(self: *Game) void {
        if (self.fruit != null or self.fruit_shown >= 2 or self.dots_total == 0) return;
        const eaten = self.dots_total - self.dots_left;
        const threshold = if (self.fruit_shown == 0) self.dots_total * 29 / 100 else self.dots_total * 70 / 100;
        if (eaten < threshold) return;
        const start = self.pacStart();
        self.fruit = .{ .kind = FruitKind.forLevel(self.level), .x = start[0], .y = start[1], .steps = fruit_steps };
        self.fruit_shown += 1;
    }

    /// An energizer: every ghost out on the board turns blue and about-faces.
    /// Ghosts still in the house (or already eaten) are unaffected, as in the
    /// arcade. A second energizer restarts the clock and the score run.
    fn frightenGhosts(self: *Game) void {
        self.fright = fright_steps;
        self.ghost_combo = 0;
        for (&self.ghosts) |*g| {
            if (g.inside or g.eyes) continue;
            if (!g.frightened) g.actor.dir = g.actor.dir.reverse();
            g.frightened = true;
        }
    }

    /// In the house: line up under the door and leave. Outside, the
    /// original: run straight; on a wall, pick another direction with a
    /// pseudo-random turn. Added: an occasional turn at open junctions so
    /// four ghosts do not settle into one loop. Frightened ghosts move every
    /// other step (the arcade slows them); eyes take the shortest way home.
    fn stepGhost(self: *Game, g: *Ghost) void {
        const a = &g.actor;
        a.px = a.x;
        a.py = a.y;
        if (g.inside) {
            if (g.wait > 0) {
                g.wait -= 1;
                return;
            }
            const cx = self.centerX();
            if (a.x != cx) {
                a.dir = if (a.x < cx) .right else .left;
                a.x += a.dir.dx();
            } else {
                a.dir = .up;
                a.y -= 1;
                if (a.y < self.doorY()) {
                    g.inside = false;
                    a.dir = if (self.random() % 2 == 0) .left else .right;
                }
            }
            return;
        }
        if (g.eyes) {
            const home = self.houseTarget();
            if (a.x == home[0] and a.y == home[1]) {
                // Back in the house: whole again, out after a short pause.
                g.eyes = false;
                g.inside = true;
                g.wait = 4;
                a.dir = .up;
                return;
            }
            if (self.stepToward(a.x, a.y, home[0], home[1], .ghost_eyes)) |dir| {
                a.dir = dir;
                if (self.neighbor(a.x, a.y, dir)) |next| {
                    a.x = next[0];
                    a.y = next[1];
                }
            }
            return;
        }
        if (g.frightened and self.fright % 2 == 0) return;
        if (self.openNeighbors(a.x, a.y, .ghost_outside) >= 3 and self.random() % 100 < 30) {
            if (self.randomTurn(a, .ghost_outside, false)) |dir| a.dir = dir;
        }
        var tries: u8 = 0;
        while (tries < 5) : (tries += 1) {
            if (self.neighbor(a.x, a.y, a.dir)) |next| {
                if (self.passable(next[0], next[1], .ghost_outside)) {
                    a.x = next[0];
                    a.y = next[1];
                    return;
                }
            }
            a.dir = self.randomTurn(a, .ghost_outside, tries >= 3) orelse a.dir.reverse();
        }
    }

    /// A random passable direction, avoiding the reverse unless allowed.
    fn randomTurn(self: *Game, actor: *const Actor, mover: Mover, allow_reverse: bool) ?Dir {
        var options: [4]Dir = undefined;
        var count: usize = 0;
        for (all_dirs) |d| {
            if (!allow_reverse and d == actor.dir.reverse()) continue;
            const next = self.neighbor(actor.x, actor.y, d) orelse continue;
            if (self.passable(next[0], next[1], mover)) {
                options[count] = d;
                count += 1;
            }
        }
        if (count == 0) return null;
        return options[self.random() % count];
    }

    /// Chase a frightened ghost that is close; otherwise eat the nearest dot
    /// unless a dangerous ghost is close, then dash for a nearby energizer
    /// or, failing that, flee.
    fn choosePacDir(self: *Game) ?Dir {
        var dist: [max_tiles]u16 = undefined;
        var parent: [max_tiles]u16 = undefined;
        self.bfs(self.pac.x, self.pac.y, .pac, &dist, &parent);
        const here = self.index(self.pac.x, self.pac.y);

        var nearest_threat: u16 = std.math.maxInt(u16);
        var prey: ?usize = null;
        var prey_dist: u16 = std.math.maxInt(u16);
        for (self.ghosts) |g| {
            const gi = self.index(g.actor.x, g.actor.y);
            if (g.dangerous()) nearest_threat = @min(nearest_threat, dist[gi]);
            if (g.edible() and dist[gi] < prey_dist) {
                prey_dist = dist[gi];
                prey = gi;
            }
        }

        if (prey != null and prey_dist <= chase_distance and prey.? != here) {
            return self.firstStep(here, prey.?, &parent);
        }

        if (nearest_threat <= danger_distance) {
            // An energizer within reach turns the tables.
            var pellet: ?usize = null;
            var pellet_dist: u16 = energizer_dash + 1;
            for (self.energizerSpots()) |spot| {
                if (!self.energizers[@intCast(spot[1])][@intCast(spot[0])]) continue;
                const pi = self.index(spot[0], spot[1]);
                if (dist[pi] < pellet_dist) {
                    pellet_dist = dist[pi];
                    pellet = pi;
                }
            }
            if (pellet) |p| return self.firstStep(here, p, &parent);

            // Flee: the passable neighbor farthest (Manhattan) from the closest ghost.
            var best: ?Dir = null;
            var best_score: i32 = -1;
            for (all_dirs) |d| {
                const next = self.neighbor(self.pac.x, self.pac.y, d) orelse continue;
                if (!self.passable(next[0], next[1], .pac)) continue;
                var score: i32 = std.math.maxInt(i32);
                for (self.ghosts) |g| {
                    if (!g.dangerous()) continue;
                    const m = @as(i32, @intCast(@abs(next[0] - g.actor.x))) + @as(i32, @intCast(@abs(next[1] - g.actor.y)));
                    score = @min(score, m);
                }
                if (score > best_score) {
                    best_score = score;
                    best = d;
                }
            }
            return best;
        }

        // Fruit within reach is worth more than any dot.
        if (self.fruit) |f| {
            const fi = self.index(f.x, f.y);
            if (dist[fi] <= fruit_dash) return self.firstStep(here, fi, &parent);
        }

        // Nearest dot by BFS distance, then the first step toward it.
        var target: ?usize = null;
        var target_dist: u16 = std.math.maxInt(u16);
        const total: usize = @as(usize, self.cols) * self.rows;
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (dist[i] == std.math.maxInt(u16) or i == here) continue;
            if (self.dots[i / self.cols][i % self.cols] and dist[i] < target_dist) {
                target_dist = dist[i];
                target = i;
            }
        }
        const t = target orelse return self.randomTurn(&self.pac, .pac, true);
        return self.firstStep(here, t, &parent);
    }

    /// The direction of the first step from `here` toward `target`, reading
    /// the BFS parent chain back; null when the target is unreachable.
    fn firstStep(self: *const Game, here: usize, target: usize, parent: *const [max_tiles]u16) ?Dir {
        if (target == here) return null;
        var cur = target;
        while (parent[cur] != here) {
            if (parent[cur] == cur) return null; // walked back to another root: unreachable
            cur = parent[cur];
        }
        const sx: i32 = @intCast(cur % self.cols);
        const sy: i32 = @intCast(cur / self.cols);
        const hx: i32 = @intCast(here % self.cols);
        const hy: i32 = @intCast(here / self.cols);
        // Through a tunnel the first step is the far edge.
        for (all_dirs) |d| {
            const next = self.neighbor(hx, hy, d) orelse continue;
            if (next[0] == sx and next[1] == sy) return d;
        }
        return null;
    }

    /// Shortest-path first step for `mover` from (x, y) to (tx, ty).
    fn stepToward(self: *const Game, x: i32, y: i32, tx: i32, ty: i32, mover: Mover) ?Dir {
        var dist: [max_tiles]u16 = undefined;
        var parent: [max_tiles]u16 = undefined;
        self.bfs(x, y, mover, &dist, &parent);
        const target = self.index(tx, ty);
        if (dist[target] == std.math.maxInt(u16)) return null;
        return self.firstStep(self.index(x, y), target, &parent);
    }
};

fn seedOrDefault(seed: u64) u64 {
    return if (seed == 0) 0x243f6a8885a308d3 else seed;
}

// ------------------------------------------------------ pixel renderer --

pub const Geometry = struct {
    /// Tile side in pixels.
    t: u32,
    /// Top-left of the board (tile 0,0); the HUD's top rows sit above it
    /// and its bottom row below.
    ox: i32,
    oy: i32,

    pub fn forBoard(game: *const Game, width: u16, height: u16) Geometry {
        const total_rows: u32 = @as(u32, game.rows) + hud_rows;
        const t: u32 = @max(2, @min(width / @max(game.cols, 1), height / total_rows));
        const top: u32 = (@as(u32, height) -| total_rows * t) / 2;
        return .{
            .t = t,
            .ox = @intCast((@as(u32, width) -| game.cols * t) / 2),
            .oy = @intCast(top + hud_rows_top * t),
        };
    }
};

// ----------------------------------------------------------- pixel font --

/// A 5×7 font for the HUD and the board's messages: digits, capitals, "!".
fn glyphRows(ch: u8) [7]u8 {
    return switch (ch) {
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 },
        'D' => .{ 0b11100, 0b10010, 0b10001, 0b10001, 0b10001, 0b10010, 0b11100 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '!' => .{ 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00000, 0b00100 },
        else => @splat(0),
    };
}

/// Pixel width of `text` at `scale` (5 wide, 1 gap; no trailing gap).
fn textWidth(text: []const u8, scale: i32) i32 {
    if (text.len == 0) return 0;
    return @as(i32, @intCast(text.len)) * 6 * scale - scale;
}

fn drawText(fb: Framebuffer, x: i32, y: i32, scale: i32, text: []const u8, color: [3]u8) void {
    var pen = x;
    for (text) |ch| {
        const rows = glyphRows(ch);
        for (rows, 0..) |bits, row| {
            var col: i32 = 0;
            while (col < 5) : (col += 1) {
                if (bits & (@as(u8, 0b10000) >> @intCast(col)) != 0) {
                    fb.fillRect(pen + col * scale, y + @as(i32, @intCast(row)) * scale, scale, scale, color);
                }
            }
        }
        pen += 6 * scale;
    }
}

/// Text scale for a tile side: the arcade's 8-pixel tiles held one glyph.
fn hudScale(t: u32) i32 {
    return @max(1, @as(i32, @intCast(t / 8)));
}

/// The arcade shows at least two digits.
pub fn formatScore(buf: *[12]u8, score: u32) []const u8 {
    if (score == 0) return "00";
    return std.fmt.bufPrint(buf, "{d}", .{score}) catch "0";
}

/// "1UP" with the score under it, "HIGH SCORE" with its value, across the
/// two rows above the board. The arcade blinked "1UP" and the energizers;
/// as a screensaver both stay lit — the blinking pulls the eye.
fn drawHud(fb: Framebuffer, game: *const Game, geo: Geometry) void {
    const ti: i32 = @intCast(geo.t);
    const s = hudScale(geo.t);
    const cw = 6 * s;
    const text_h = 7 * s;
    const row0 = geo.oy - 2 * ti + @divTrunc(ti - text_h, 2);
    const row1 = geo.oy - ti + @divTrunc(ti - text_h, 2);
    var buf: [12]u8 = undefined;

    const one_up_x = geo.ox + ti;
    drawText(fb, one_up_x, row0, s, "1UP", text_color);
    const score = formatScore(&buf, game.score);
    drawText(fb, one_up_x + 7 * cw - textWidth(score, s), row1, s, score, text_color);

    const board_w: i32 = @as(i32, game.cols) * ti;
    const hs_label = "HIGH SCORE";
    const hs_x = geo.ox + @divTrunc(board_w - textWidth(hs_label, s), 2);
    drawText(fb, hs_x, row0, s, hs_label, text_color);
    var hbuf: [12]u8 = undefined;
    const high = formatScore(&hbuf, game.high_score);
    drawText(fb, hs_x + 8 * cw - textWidth(high, s), row1, s, high, text_color);

    // Footer: spare lives on the left, the fruit of the levels so far on
    // the right (the arcade's last seven).
    const foot_cy = @as(f32, @floatFromInt(geo.oy + @as(i32, game.rows) * ti)) + @as(f32, @floatFromInt(ti)) * 0.5;
    const tf: f32 = @floatFromInt(geo.t);
    var i: u8 = 0;
    while (i < game.lives) : (i += 1) {
        const cx = @as(f32, @floatFromInt(geo.ox)) + tf * (1.5 + 1.5 * @as(f32, @floatFromInt(i)));
        drawPac(fb, cx, foot_cy, tf * 0.5, .left, 0.7);
    }
    const first_level: u8 = if (game.level > 7) game.level - 6 else 1;
    var lv = game.level;
    var k: f32 = 0;
    while (lv >= first_level) : (lv -= 1) {
        const cx = @as(f32, @floatFromInt(geo.ox + board_w)) - tf * (1.5 + 1.5 * k);
        drawFruit(fb, cx, foot_cy, tf * 0.5, FruitKind.forLevel(lv));
        k += 1;
    }
}

/// A message on the corridor below the house — "READY!" in yellow before a
/// life, "GAME OVER" in red — on a black strip so the dots don't show through.
fn drawBoardMessage(fb: Framebuffer, game: *const Game, geo: Geometry, text: []const u8, color: [3]u8) void {
    const ti: i32 = @intCast(geo.t);
    const s = hudScale(geo.t);
    const w = textWidth(text, s);
    const row = game.doorY() + 5;
    const cx = geo.ox + game.centerX() * ti + @divTrunc(ti, 2);
    const top = geo.oy + row * ti;
    fb.fillRect(cx - @divTrunc(w, 2) - s, top, w + 2 * s, ti, black);
    drawText(fb, cx - @divTrunc(w, 2), top + @divTrunc(ti - 7 * s, 2), s, text, color);
}

/// Points where a ghost or fruit was eaten, centered on its tile.
fn drawPopup(fb: Framebuffer, popup: Popup, geo: Geometry) void {
    const ti: i32 = @intCast(geo.t);
    const s: i32 = @max(1, @as(i32, @intCast(geo.t / 10)));
    var buf: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{popup.points}) catch return;
    const w = textWidth(text, s);
    const cx = geo.ox + popup.x * ti + @divTrunc(ti, 2);
    const cy = geo.oy + popup.y * ti + @divTrunc(ti, 2);
    drawText(fb, cx - @divTrunc(w, 2), cy - @divTrunc(7 * s, 2), s, text, if (popup.ghost != null) ghost_popup_color else fruit_popup_color);
}

const Framebuffer = struct {
    rgb: []u8,
    width: u16,
    height: u16,

    fn set(self: Framebuffer, x: i32, y: i32, color: [3]u8) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const i = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 3;
        self.rgb[i] = color[0];
        self.rgb[i + 1] = color[1];
        self.rgb[i + 2] = color[2];
    }

    /// Alpha-blend `color` over the pixel (anti-aliased edges).
    fn blend(self: Framebuffer, x: i32, y: i32, color: [3]u8, alpha: f32) void {
        if (alpha <= 0) return;
        if (alpha >= 1) return self.set(x, y, color);
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const i = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 3;
        inline for (0..3) |c| {
            const under: f32 = @floatFromInt(self.rgb[i + c]);
            const over: f32 = @floatFromInt(color[c]);
            self.rgb[i + c] = @intFromFloat(@round(under + (over - under) * alpha));
        }
    }

    fn fillRect(self: Framebuffer, x: i32, y: i32, w: i32, h: i32, color: [3]u8) void {
        var yy = y;
        while (yy < y + h) : (yy += 1) {
            var xx = x;
            while (xx < x + w) : (xx += 1) self.set(xx, yy, color);
        }
    }
};

/// The static part of a board — black corridors, walls drawn as an outline
/// following the wall shape with rounded corners (the arcade look), the
/// house door — rendered once per maze into `rgb`.
pub fn renderBackground(game: *const Game, rgb: []u8, width: u16, height: u16) void {
    @memset(rgb, 0);
    if (width == 0 or height == 0 or game.cols == 0) return;
    const fb = Framebuffer{ .rgb = rgb, .width = width, .height = height };
    const geo = Geometry.forBoard(game, width, height);
    const t: f32 = @floatFromInt(geo.t);
    const inset = 0.24 * t;
    const line = @max(1.2, 0.1 * t);
    const soft = 0.7; // anti-aliasing width in pixels

    var y: i32 = 0;
    while (y < game.rows) : (y += 1) {
        var x: i32 = 0;
        while (x < game.cols) : (x += 1) {
            if (game.tile(x, y) != .wall) continue;
            // Open tiles around this wall tile (outside the map counts as open
            // so the border gets its outer line).
            var open_rects: [8][4]f32 = undefined;
            var n_open: usize = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) continue;
                    const nx = x + dx;
                    const ny = y + dy;
                    const outside = nx < 0 or ny < 0 or nx >= game.cols or ny >= game.rows;
                    if (!outside and game.tile(nx, ny) == .wall) continue;
                    open_rects[n_open] = .{
                        @as(f32, @floatFromInt(geo.ox + nx * @as(i32, @intCast(geo.t)))),
                        @as(f32, @floatFromInt(geo.oy + ny * @as(i32, @intCast(geo.t)))),
                        t,
                        t,
                    };
                    n_open += 1;
                }
            }
            if (n_open == 0) continue; // deep inside a wall: stays black
            const px0 = geo.ox + x * @as(i32, @intCast(geo.t));
            const py0 = geo.oy + y * @as(i32, @intCast(geo.t));
            var py = py0;
            while (py < py0 + @as(i32, @intCast(geo.t))) : (py += 1) {
                var px = px0;
                while (px < px0 + @as(i32, @intCast(geo.t))) : (px += 1) {
                    const cx = @as(f32, @floatFromInt(px)) + 0.5;
                    const cy = @as(f32, @floatFromInt(py)) + 0.5;
                    var d: f32 = std.math.floatMax(f32);
                    for (open_rects[0..n_open]) |rect| d = @min(d, rectDistance(cx, cy, rect));
                    // A band [inset, inset + line] from the corridor, soft-edged.
                    const a = @min((d - inset) / soft + 0.5, (inset + line - d) / soft + 0.5);
                    fb.blend(px, py, wall_color, std.math.clamp(a, 0.0, 1.0));
                }
            }
        }
    }

    // The door: a bar across the gap.
    const dx0 = geo.ox + game.centerX() * @as(i32, @intCast(geo.t));
    const dy0 = geo.oy + game.doorY() * @as(i32, @intCast(geo.t));
    const ti: i32 = @intCast(geo.t);
    fb.fillRect(dx0, dy0 + @divTrunc(ti * 2, 5), ti, @max(1, @divTrunc(ti, 5)), door_color);
}

/// Distance from a point to an axis-aligned rectangle {x, y, w, h}.
fn rectDistance(px: f32, py: f32, rect: [4]f32) f32 {
    const dx = @max(rect[0] - px, 0, px - (rect[0] + rect[2]));
    const dy = @max(rect[1] - py, 0, py - (rect[1] + rect[3]));
    return @sqrt(dx * dx + dy * dy);
}

/// One frame: the cached background, then dots and sprites.
pub fn renderPixels(game: *const Game, rgb: []u8, background: []const u8, width: u16, height: u16) void {
    @memcpy(rgb, background);
    if (width == 0 or height == 0 or game.cols == 0) return;
    const fb = Framebuffer{ .rgb = rgb, .width = width, .height = height };
    const geo = Geometry.forBoard(game, width, height);
    const ti: i32 = @intCast(geo.t);
    const tf: f32 = @floatFromInt(geo.t);

    // A cleared board flashes its walls.
    const level_clear = game.freeze > 0 and !game.caught;
    if (level_clear and (game.frame / 4) % 2 == 0) {
        var i: usize = 0;
        while (i + 2 < rgb.len) : (i += 3) {
            if (rgb[i] == wall_color[0] and rgb[i + 1] == wall_color[1] and rgb[i + 2] == wall_color[2]) {
                rgb[i] = wall_flash[0];
                rgb[i + 1] = wall_flash[1];
                rgb[i + 2] = wall_flash[2];
            }
        }
    }

    const dot: i32 = @max(2, @divTrunc(ti, 4));
    var y: i32 = 0;
    while (y < game.rows) : (y += 1) {
        var x: i32 = 0;
        while (x < game.cols) : (x += 1) {
            if (game.energizers[@intCast(y)][@intCast(x)]) {
                // A big pellet.
                const cx = @as(f32, @floatFromInt(geo.ox + x * ti)) + tf * 0.5;
                const cy = @as(f32, @floatFromInt(geo.oy + y * ti)) + tf * 0.5;
                drawDisc(fb, cx, cy, tf * 0.34, dot_color);
                continue;
            }
            if (!game.dots[@intCast(y)][@intCast(x)]) continue;
            fb.fillRect(geo.ox + x * ti + @divTrunc(ti - dot, 2), geo.oy + y * ti + @divTrunc(ti - dot, 2), dot, dot, dot_color);
        }
    }

    if (game.fruit) |f| {
        const fx = @as(f32, @floatFromInt(geo.ox + f.x * ti)) + tf * 0.5;
        const fy = @as(f32, @floatFromInt(geo.oy + f.y * ti)) + tf * 0.5;
        drawFruit(fb, fx, fy, tf * 0.62, f.kind);
    }

    const phase = game.stepPhase();
    const radius = tf * 0.68;
    const wave = (game.frame / 4) % 2 == 1;
    const flash = frightFlashing(game);
    for (game.ghosts, ghost_colors, 0..) |g, color, i| {
        if (!game.ghostVisible(i)) continue;
        const c = actorCenter(g.actor, phase, geo);
        if (g.eyes) {
            drawGhost(fb, c[0], c[1], radius, color, g.actor.dir, wave, .eyes);
        } else if (g.frightened) {
            drawGhost(fb, c[0], c[1], radius, if (flash) fright_flash else fright_color, g.actor.dir, wave, .frightened);
        } else {
            drawGhost(fb, c[0], c[1], radius, color, g.actor.dir, wave, .normal);
        }
    }
    if (game.pacVisible()) {
        const c = actorCenter(game.pac, phase, geo);
        drawPac(fb, c[0], c[1], radius, game.pac.dir, game.mouthAngle());
    }

    if (game.popup) |p| drawPopup(fb, p, geo);
    if (game.game_over > 0) {
        drawBoardMessage(fb, game, geo, "GAME OVER", game_over_color);
    } else if (game.ready > 0) {
        drawBoardMessage(fb, game, geo, "READY!", pac_color);
    }
    drawHud(fb, game, geo);
}

// ---------------------------------------------------------------- fruit --

fn drawLine(fb: Framebuffer, x0: f32, y0: f32, x1: f32, y1: f32, thickness: i32, color: [3]u8) void {
    const steps: usize = @intFromFloat(@ceil(@max(@abs(x1 - x0), @abs(y1 - y0))) + 1);
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const x: i32 = @intFromFloat(@round(x0 + (x1 - x0) * u - @as(f32, @floatFromInt(thickness)) * 0.5));
        const y: i32 = @intFromFloat(@round(y0 + (y1 - y0) * u - @as(f32, @floatFromInt(thickness)) * 0.5));
        fb.fillRect(x, y, thickness, thickness, color);
    }
}

fn fillTriangle(fb: Framebuffer, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, color: [3]u8) void {
    const x0: i32 = @intFromFloat(@floor(@min(ax, bx, cx)));
    const x1: i32 = @intFromFloat(@ceil(@max(ax, bx, cx)));
    const y0: i32 = @intFromFloat(@floor(@min(ay, by, cy)));
    const y1: i32 = @intFromFloat(@ceil(@max(ay, by, cy)));
    const area = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay);
    if (@abs(area) < 0.001) return;
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const w0 = ((bx - px) * (cy - py) - (cx - px) * (by - py)) / area;
            const w1 = ((cx - px) * (ay - py) - (ax - px) * (cy - py)) / area;
            const w2 = 1.0 - w0 - w1;
            if (w0 >= 0 and w1 >= 0 and w2 >= 0) fb.set(x, y, color);
        }
    }
}

/// The arcade's eight fruit as simple shapes in a box of radius `r`:
/// discs with stems and leaves, and the Galaxian flagship, bell, and key.
fn drawFruit(fb: Framebuffer, cx: f32, cy: f32, r: f32, kind: FruitKind) void {
    const s: i32 = @max(1, @as(i32, @intFromFloat(r / 8)));
    const color = kind.color();
    switch (kind) {
        .cherry => {
            drawLine(fb, cx - 0.35 * r, cy + 0.05 * r, cx + 0.15 * r, cy - 0.8 * r, s, stem_color);
            drawLine(fb, cx + 0.4 * r, cy + 0.1 * r, cx + 0.15 * r, cy - 0.8 * r, s, stem_color);
            drawDisc(fb, cx + 0.3 * r, cy - 0.75 * r, 0.18 * r, leaf_color);
            drawDisc(fb, cx - 0.38 * r, cy + 0.35 * r, 0.4 * r, color);
            drawDisc(fb, cx + 0.42 * r, cy + 0.42 * r, 0.4 * r, color);
            drawDisc(fb, cx - 0.5 * r, cy + 0.22 * r, 0.1 * r, eye_white);
            drawDisc(fb, cx + 0.3 * r, cy + 0.3 * r, 0.1 * r, eye_white);
        },
        .strawberry => {
            drawDisc(fb, cx, cy + 0.15 * r, 0.6 * r, color);
            fillTriangle(fb, cx - 0.62 * r, cy + 0.05 * r, cx + 0.62 * r, cy + 0.05 * r, cx, cy + 0.9 * r, color);
            drawDisc(fb, cx, cy - 0.45 * r, 0.32 * r, leaf_color);
            fb.fillRect(@intFromFloat(cx - 0.5 * @as(f32, @floatFromInt(s))), @intFromFloat(cy - 0.95 * r), s, @intFromFloat(0.3 * r), stem_color);
            const seeds = [_][2]f32{ .{ -0.25, 0.0 }, .{ 0.25, 0.05 }, .{ 0.0, 0.3 }, .{ -0.2, 0.5 }, .{ 0.22, 0.5 } };
            for (seeds) |sd| fb.fillRect(@intFromFloat(cx + sd[0] * r), @intFromFloat(cy + sd[1] * r), s, s, pac_color);
        },
        .orange => {
            drawDisc(fb, cx, cy + 0.1 * r, 0.62 * r, color);
            fb.fillRect(@intFromFloat(cx - 0.5 * @as(f32, @floatFromInt(s))), @intFromFloat(cy - 0.85 * r), s, @intFromFloat(0.35 * r), stem_color);
            drawDisc(fb, cx + 0.28 * r, cy - 0.62 * r, 0.2 * r, leaf_color);
        },
        .apple => {
            drawDisc(fb, cx - 0.2 * r, cy + 0.12 * r, 0.52 * r, color);
            drawDisc(fb, cx + 0.2 * r, cy + 0.12 * r, 0.52 * r, color);
            fb.fillRect(@intFromFloat(cx - 0.5 * @as(f32, @floatFromInt(s))), @intFromFloat(cy - 0.85 * r), s, @intFromFloat(0.4 * r), stem_color);
            drawDisc(fb, cx + 0.3 * r, cy - 0.6 * r, 0.18 * r, leaf_color);
            drawDisc(fb, cx - 0.35 * r, cy - 0.1 * r, 0.1 * r, eye_white);
        },
        .melon => {
            drawDisc(fb, cx, cy + 0.08 * r, 0.65 * r, color);
            const stripe = [3]u8{ 0x1e, 0x8c, 0x2e };
            drawLine(fb, cx - 0.3 * r, cy - 0.45 * r, cx - 0.3 * r, cy + 0.6 * r, s, stripe);
            drawLine(fb, cx, cy - 0.55 * r, cx, cy + 0.7 * r, s, stripe);
            drawLine(fb, cx + 0.3 * r, cy - 0.45 * r, cx + 0.3 * r, cy + 0.6 * r, s, stripe);
            fb.fillRect(@intFromFloat(cx - 0.5 * @as(f32, @floatFromInt(s))), @intFromFloat(cy - 0.85 * r), s, @intFromFloat(0.3 * r), stem_color);
        },
        .galaxian => {
            // The flagship: yellow wings, blue hull, red keel.
            fillTriangle(fb, cx - 0.7 * r, cy - 0.5 * r, cx + 0.7 * r, cy - 0.5 * r, cx, cy + 0.15 * r, pac_color);
            fillTriangle(fb, cx - 0.42 * r, cy - 0.15 * r, cx + 0.42 * r, cy - 0.15 * r, cx, cy + 0.7 * r, color);
            fillTriangle(fb, cx - 0.12 * r, cy - 0.5 * r, cx + 0.12 * r, cy - 0.5 * r, cx, cy + 0.55 * r, game_over_color);
        },
        .bell => {
            fillTriangle(fb, cx - 0.62 * r, cy + 0.4 * r, cx + 0.62 * r, cy + 0.4 * r, cx, cy - 0.75 * r, color);
            drawDisc(fb, cx, cy - 0.15 * r, 0.42 * r, color);
            fb.fillRect(@intFromFloat(cx - 0.62 * r), @intFromFloat(cy + 0.4 * r), @intFromFloat(1.24 * r), @max(s, @as(i32, @intFromFloat(0.16 * r))), FruitKind.galaxian.color());
            drawDisc(fb, cx, cy + 0.62 * r, 0.14 * r, eye_white);
        },
        .key => {
            drawDisc(fb, cx, cy - 0.42 * r, 0.3 * r, color);
            drawDisc(fb, cx, cy - 0.42 * r, 0.13 * r, black);
            const shaft: i32 = @max(s, @as(i32, @intFromFloat(0.16 * r)));
            fb.fillRect(@intFromFloat(cx - @as(f32, @floatFromInt(shaft)) * 0.5), @intFromFloat(cy - 0.15 * r), shaft, @intFromFloat(0.85 * r), color);
            fb.fillRect(@intFromFloat(cx), @intFromFloat(cy + 0.3 * r), @intFromFloat(0.3 * r), shaft, color);
            fb.fillRect(@intFromFloat(cx), @intFromFloat(cy + 0.58 * r), @intFromFloat(0.3 * r), shaft, color);
        },
    }
}

/// Frightened ghosts flash pale during the last steps of the fright.
pub fn frightFlashing(game: *const Game) bool {
    return game.fright > 0 and game.fright <= fright_flash_steps and (game.frame / 4) % 2 == 1;
}

fn drawDisc(fb: Framebuffer, cx: f32, cy: f32, r: f32, color: [3]u8) void {
    const x0: i32 = @intFromFloat(@floor(cx - r - 1));
    const x1: i32 = @intFromFloat(@ceil(cx + r + 1));
    const y0: i32 = @intFromFloat(@floor(cy - r - 1));
    const y1: i32 = @intFromFloat(@ceil(cy + r + 1));
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const vx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const vy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(vx * vx + vy * vy);
            fb.blend(x, y, color, std.math.clamp(r - d + 0.5, 0.0, 1.0));
        }
    }
}

fn actorCenter(actor: Actor, phase: f32, geo: Geometry) [2]f32 {
    const tf: f32 = @floatFromInt(geo.t);
    // Through a tunnel the actor jumps rather than glides across the map.
    const glide = @abs(actor.x - actor.px) <= 1 and @abs(actor.y - actor.py) <= 1;
    const fx = if (glide) @as(f32, @floatFromInt(actor.px)) + @as(f32, @floatFromInt(actor.x - actor.px)) * phase else @as(f32, @floatFromInt(actor.x));
    const fy = if (glide) @as(f32, @floatFromInt(actor.py)) + @as(f32, @floatFromInt(actor.y - actor.py)) * phase else @as(f32, @floatFromInt(actor.y));
    return .{
        @as(f32, @floatFromInt(geo.ox)) + (fx + 0.5) * tf,
        @as(f32, @floatFromInt(geo.oy)) + (fy + 0.5) * tf,
    };
}

/// A disc with a wedge cut out toward `dir`; `mouth` is the wedge half-angle.
fn drawPac(fb: Framebuffer, cx: f32, cy: f32, r: f32, dir: Dir, mouth: f32) void {
    const dxd: f32 = @floatFromInt(dir.dx());
    const dyd: f32 = @floatFromInt(dir.dy());
    const cos_mouth = @cos(mouth);
    const x0: i32 = @intFromFloat(@floor(cx - r - 1));
    const x1: i32 = @intFromFloat(@ceil(cx + r + 1));
    const y0: i32 = @intFromFloat(@floor(cy - r - 1));
    const y1: i32 = @intFromFloat(@ceil(cy + r + 1));
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const vx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const vy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const d = @sqrt(vx * vx + vy * vy);
            const alpha = std.math.clamp(r - d + 0.5, 0.0, 1.0);
            if (alpha <= 0) continue;
            if (mouth > 0 and d > 0.01 and (vx * dxd + vy * dyd) / d > cos_mouth) continue;
            fb.blend(x, y, pac_color, alpha);
        }
    }
}

const GhostLook = enum {
    /// Body in its own color, eyes looking the way it runs.
    normal,
    /// Blue body, small blank eyes and a wavy mouth, no pupils.
    frightened,
    /// Eaten: just the eyes, heading home.
    eyes,
};

/// Dome, skirt with three teeth that alternate, eyes looking the way it runs.
fn drawGhost(fb: Framebuffer, cx: f32, cy: f32, r: f32, color: [3]u8, dir: Dir, wave: bool, look: GhostLook) void {
    if (look != .eyes) {
        const x0: i32 = @intFromFloat(@floor(cx - r - 1));
        const x1: i32 = @intFromFloat(@ceil(cx + r + 1));
        const y0: i32 = @intFromFloat(@floor(cy - r - 1));
        const y1: i32 = @intFromFloat(@ceil(cy + r));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const vx = px - cx;
                var alpha: f32 = 0;
                if (py < cy) {
                    const vy = py - cy;
                    alpha = std.math.clamp(r - @sqrt(vx * vx + vy * vy) + 0.5, 0.0, 1.0);
                } else if (py <= cy + r) {
                    alpha = std.math.clamp(r - @abs(vx) + 0.5, 0.0, 1.0);
                    if (py > cy + r * 0.72) {
                        // Three teeth: gaps between them, shifting as it walks.
                        const u = (px - (cx - r)) / (2.0 * r) * 3.0 + (if (wave) @as(f32, 0.5) else 0.0);
                        if (u - @floor(u) > 0.62) alpha = 0;
                    }
                }
                fb.blend(x, y, color, alpha);
            }
        }
    }
    const eye_y: i32 = @intFromFloat(cy - r * 0.6);
    if (look == .frightened) {
        // Blank eyes and a zigzag mouth in the arcade's pinkish face color.
        const eye: i32 = @max(1, @as(i32, @intFromFloat(r * 0.22)));
        inline for (.{ -1.0, 1.0 }) |side| {
            const eye_x: i32 = @intFromFloat(cx + side * r * 0.38 - @as(f32, @floatFromInt(eye)) * 0.5);
            fb.fillRect(eye_x, eye_y, eye, eye, dot_color);
        }
        const mouth_y: i32 = @intFromFloat(cy + r * 0.12);
        const tooth: i32 = @max(1, @as(i32, @intFromFloat(r * 0.16)));
        var k: i32 = -2;
        while (k <= 2) : (k += 1) {
            const mx: i32 = @as(i32, @intFromFloat(cx)) + k * tooth - @divTrunc(tooth, 2);
            const my: i32 = mouth_y + (if (@mod(k, 2) == 0) tooth else 0);
            fb.fillRect(mx, my, tooth, @max(1, @divTrunc(tooth, 2)), dot_color);
        }
        return;
    }
    // Eyes.
    const eye_w: i32 = @max(1, @as(i32, @intFromFloat(r * 0.36)));
    const eye_h: i32 = @max(1, @as(i32, @intFromFloat(r * 0.46)));
    const pupil: i32 = @max(1, @as(i32, @intFromFloat(r * 0.2)));
    const look_x: i32 = @intFromFloat(@as(f32, @floatFromInt(dir.dx())) * r * 0.14);
    const look_y: i32 = @intFromFloat(@as(f32, @floatFromInt(dir.dy())) * r * 0.14);
    inline for (.{ -1.0, 1.0 }) |side| {
        const eye_x: i32 = @intFromFloat(cx + side * r * 0.42 - @as(f32, @floatFromInt(eye_w)) * 0.5);
        fb.fillRect(eye_x, eye_y, eye_w, eye_h, eye_white);
        fb.fillRect(eye_x + @divTrunc(eye_w - pupil, 2) + look_x, eye_y + @divTrunc(eye_h - pupil, 2) + look_y, pupil, pupil, eye_pupil);
    }
}

// ------------------------------------------------------- cell renderer --

/// The text-mode fallback: a maze sized to the terminal, two columns per
/// tile when they fit, glyph actors.
pub const Engine = struct {
    width: u16 = 0,
    height: u16 = 0,
    game: Game,

    pub fn init(_: std.mem.Allocator, seed: u64) Engine {
        return .{ .game = Game.init(seed) };
    }

    pub fn deinit(self: *Engine) void {
        self.* = undefined;
    }

    pub fn reset(self: *Engine, width: u16, height: u16, seed: u64) !void {
        self.game.rng = seedOrDefault(seed);
        try self.resize(width, height);
    }

    pub fn resize(self: *Engine, width: u16, height: u16) !void {
        self.width = width;
        self.height = height;
        // Two columns per tile keeps tiles square-ish; one when space is short.
        // The HUD takes two rows above the board and one below.
        const cols: u16 = if (width >= 2 * 15) width / 2 else width;
        self.game.configure(cols, height -| hud_rows);
    }

    pub fn tick(self: *Engine) void {
        self.game.tick();
    }

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        _ = mode; // a maze has no interleaved form
        if (win.width == 0 or win.height == 0 or opacity == 0) return;
        effect.prepare(win, .full_screen);
        win.hideCursor();
        const game = &self.game;
        if (game.cols == 0) return;

        if (win.height <= hud_rows) return;
        const cell_w: u16 = if (win.width >= game.cols * 2) 2 else 1;
        const board_w: u16 = game.cols * cell_w;
        if (win.width < board_w) return;
        const origin_x: u16 = (win.width - board_w) / 2;
        // The HUD's two rows sit at the very top and its one row at the very
        // bottom. Tall enough in between: center the board. Otherwise a
        // viewport that follows Pac-Man.
        var view = CellView{ .origin_x = origin_x, .origin_y = hud_rows_top, .view_top = 0, .view_h = win.height - hud_rows, .cell_w = cell_w };
        if (view.view_h >= game.rows) {
            view.origin_y = hud_rows_top + (view.view_h - game.rows) / 2;
            view.view_h = game.rows;
        } else {
            view.view_top = std.math.clamp(game.pac.y - @divTrunc(@as(i32, view.view_h), 2), 0, @as(i32, game.rows) - @as(i32, view.view_h));
        }
        const bottom_row: u16 = view.origin_y + view.view_h;

        const wall = effect.scaledColor(wall_color, opacity);
        const bg: vaxis.Color = .{ .rgb = .{ 0, 0, 0 } };
        var r: i32 = 0;
        while (r < game.rows) : (r += 1) {
            const screen_row = view.row(r) orelse continue;
            var c: i32 = 0;
            while (c < game.cols) : (c += 1) {
                const base: u16 = origin_x + @as(u16, @intCast(c)) * cell_w;
                const t = game.tile(c, r);
                const energizer = t == .path and game.energizers[@intCast(r)][@intCast(c)];
                var k: u16 = 0;
                while (k < cell_w) : (k += 1) {
                    const glyph: []const u8 = switch (t) {
                        .path => if (k != 0)
                            " "
                        else if (energizer)
                            "●"
                        else if (game.dots[@intCast(r)][@intCast(c)])
                            "·"
                        else
                            " ",
                        .door => "─",
                        else => " ",
                    };
                    const fg = if (t == .door) effect.scaledColor(door_color, opacity) else effect.scaledColor(dot_color, opacity);
                    paint(win, base + k, screen_row, glyph, fg, if (t == .wall) wall else bg, energizer);
                }
            }
        }

        if (game.fruit) |f| {
            if (view.at(f.x, f.y)) |pos| paint(win, pos[0], pos[1], fruitGlyph(f.kind), effect.scaledColor(f.kind.color(), opacity), bg, true);
        }

        const flash = frightFlashing(game);
        for (game.ghosts, ghost_colors, 0..) |g, color, i| {
            if (!game.ghostVisible(i)) continue;
            const pos = view.at(g.actor.x, g.actor.y) orelse continue;
            if (g.eyes) {
                paint(win, pos[0], pos[1], "¨", effect.scaledColor(color, opacity), bg, true);
            } else if (g.frightened) {
                paint(win, pos[0], pos[1], "M", effect.scaledColor(if (flash) fright_flash else fright_color, opacity), bg, true);
            } else {
                paint(win, pos[0], pos[1], "M", effect.scaledColor(color, opacity), bg, true);
            }
        }
        if (game.pacVisible()) {
            if (view.at(game.pac.x, game.pac.y)) |pos| {
                const mouth_open = game.mouthAngle() > 0.45 and !game.caught;
                const glyph: []const u8 = if (game.caught)
                    "✕"
                else if (!mouth_open)
                    "●"
                else switch (game.pac.dir) {
                    .right => "◖",
                    .left => "◗",
                    .up => "◒",
                    .down => "◓",
                };
                paint(win, pos[0], pos[1], glyph, effect.scaledColor(pac_color, opacity), bg, true);
            }
        }

        // Points where something was eaten, and the board's messages.
        var buf: [12]u8 = undefined;
        if (game.popup) |p| {
            if (view.at(p.x, p.y)) |pos| {
                const text = std.fmt.bufPrint(&buf, "{d}", .{p.points}) catch "";
                const color = if (p.ghost != null) ghost_popup_color else fruit_popup_color;
                paintText(win, @as(i32, pos[0]) + @divTrunc(@as(i32, cell_w), 2) - @divTrunc(@as(i32, @intCast(text.len)), 2), pos[1], text, effect.scaledColor(color, opacity), bg, true);
            }
        }
        const message: ?struct { text: []const u8, color: [3]u8 } = if (game.game_over > 0)
            .{ .text = "GAME OVER", .color = game_over_color }
        else if (game.ready > 0)
            .{ .text = "READY!", .color = pac_color }
        else
            null;
        if (message) |m| {
            if (view.at(game.centerX(), game.doorY() + 5)) |pos| {
                const col = @as(i32, pos[0]) + @divTrunc(@as(i32, cell_w), 2) - @divTrunc(@as(i32, @intCast(m.text.len)), 2);
                paintText(win, col, pos[1], m.text, effect.scaledColor(m.color, opacity), bg, true);
            }
        }

        // HUD: "1UP" and the score, "HIGH SCORE" and its value up top; spare
        // lives and the levels' fruit along the bottom.
        const text = effect.scaledColor(text_color, opacity);
        const ox: i32 = origin_x;
        paintText(win, ox + 3, 0, "1UP", text, bg, false);
        const score = formatScore(&buf, game.score);
        paintText(win, ox + 3 + 7 - @as(i32, @intCast(score.len)), 1, score, text, bg, false);
        const hs_label = "HIGH SCORE";
        const hs_col = ox + @divTrunc(@as(i32, board_w) - @as(i32, hs_label.len), 2);
        paintText(win, hs_col, 0, hs_label, text, bg, false);
        var hbuf: [12]u8 = undefined;
        const high = formatScore(&hbuf, game.high_score);
        paintText(win, hs_col + 8 - @as(i32, @intCast(high.len)), 1, high, text, bg, false);
        if (bottom_row < win.height) {
            var i: u8 = 0;
            while (i < game.lives) : (i += 1) {
                paint(win, @intCast(ox + 2 + 2 * @as(i32, i)), bottom_row, "◗", effect.scaledColor(pac_color, opacity), bg, true);
            }
            const first_level: u8 = if (game.level > 7) game.level - 6 else 1;
            var lv = game.level;
            var k: i32 = 0;
            while (lv >= first_level) : (lv -= 1) {
                const kind = FruitKind.forLevel(lv);
                const col = ox + @as(i32, board_w) - 3 - 2 * k;
                if (col >= 0) paint(win, @intCast(col), bottom_row, fruitGlyph(kind), effect.scaledColor(kind.color(), opacity), bg, true);
                k += 1;
            }
        }
    }
};

/// Where the board lands on the terminal grid.
const CellView = struct {
    origin_x: u16,
    origin_y: u16,
    /// First board row shown (non-zero only when the window is too short).
    view_top: i32,
    view_h: u16,
    cell_w: u16,

    fn row(self: CellView, y: i32) ?u16 {
        const row_i = @as(i32, self.origin_y) + y - self.view_top;
        if (row_i < self.origin_y or row_i >= @as(i32, self.origin_y) + self.view_h) return null;
        return @intCast(row_i);
    }

    fn at(self: CellView, x: i32, y: i32) ?[2]u16 {
        const r = self.row(y) orelse return null;
        return .{ self.origin_x + @as(u16, @intCast(x)) * self.cell_w, r };
    }
};

fn fruitGlyph(kind: FruitKind) []const u8 {
    return switch (kind) {
        .cherry, .orange, .apple => "●",
        .strawberry => "♥",
        .melon => "◍",
        .galaxian => "▲",
        .bell => "♪",
        .key => "K",
    };
}

/// ASCII text on the grid, one glyph per cell, clipped to the window. Cells
/// keep a pointer to their grapheme, so each character maps to a static
/// string rather than a slice of the caller's buffer.
fn paintText(win: vaxis.Window, col: i32, row: u16, text: []const u8, fg: vaxis.Color, bg: vaxis.Color, bold: bool) void {
    for (text, 0..) |ch, i| {
        const c = col + @as(i32, @intCast(i));
        if (c < 0 or c >= win.width) continue;
        paint(win, @intCast(c), row, staticGlyph(ch), fg, bg, bold);
    }
}

fn staticGlyph(ch: u8) []const u8 {
    const table = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ! ";
    for (table, 0..) |t, i| {
        if (t == ch) return table[i .. i + 1];
    }
    return "?";
}

fn paint(win: vaxis.Window, col: u16, row: u16, glyph: []const u8, fg: vaxis.Color, bg: vaxis.Color, bold: bool) void {
    var cell = win.readCell(col, row) orelse return;
    cell.char = .{ .grapheme = glyph, .width = 1 };
    cell.style.fg = fg;
    cell.style.bg = bg;
    cell.style.bold = bold;
    cell.style.dim = false;
    cell.link = .{};
    cell.image = null;
    cell.default = false;
    win.writeCell(col, row, cell);
}

// ---------------------------------------------------------------- tests --
