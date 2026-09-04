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
};

/// Ticks per board step (~200 ms at the 33 ms screensaver tick — the
/// original crossed a tile in ten 22 ms frames).
pub const step_ticks: u64 = 6;
const mouth_ticks: u64 = 4;
/// Pause after a catch or a cleared board before everything resets.
pub const freeze_ticks: u16 = 30;
/// Ghosts this close (BFS steps) make Pac-Man run instead of eat.
const danger_distance: u16 = 3;

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
const eye_white = [3]u8{ 0xff, 0xff, 0xff };
const eye_pupil = [3]u8{ 0x10, 0x20, 0xa0 };
pub const black = [3]u8{ 0, 0, 0 };

pub const Layout = struct { cols: u16, rows: u16 };

/// A maze shaped for a window of the given pixel aspect: landscape windows
/// get wider mazes, portrait ones taller, both around the arcade's 28×31.
pub fn layoutForAspect(win_w: u32, win_h: u32) Layout {
    const aspect = @as(f32, @floatFromInt(@max(win_w, 1))) / @as(f32, @floatFromInt(@max(win_h, 1)));
    var bw: u32 = 3;
    var bh: u32 = 8;
    if (aspect >= 0.9) {
        const rows: f32 = @floatFromInt(3 * bh + 3);
        bw = @intFromFloat(@round((rows * aspect - 3.0) / 6.0));
    } else {
        const cols: f32 = @floatFromInt(6 * bw + 3);
        bh = @intFromFloat(@round((cols / aspect - 3.0) / 3.0));
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

    /// An arcade-sized board (28×31 → 27×30 tiles).
    pub fn init(seed: u64) Game {
        var self: Game = .{ .rng = seedOrDefault(seed) };
        self.configure(28, 31);
        return self;
    }

    /// Size the maze to a tile budget and build it. Every later `reset`
    /// keeps the size and builds a new maze.
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

    pub const Mover = enum { pac, ghost_inside, ghost_outside };

    pub fn passable(self: *const Game, x: i32, y: i32, mover: Mover) bool {
        return switch (self.tile(x, y)) {
            .wall => false,
            .path => true,
            .door => mover == .ghost_inside,
            .house => mover == .ghost_inside,
        };
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

    fn resetBoard(self: *Game) void {
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
                if (dot) self.dots_left += 1;
            }
        }

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

    pub fn tick(self: *Game) void {
        self.frame +%= 1;
        if (self.freeze > 0) {
            self.freeze -= 1;
            if (self.freeze == 0) self.resetBoard();
            return;
        }
        if (self.frame % step_ticks != 0) return;
        self.step();
    }

    /// 0..1 progress of the current step, for gliding between tiles.
    pub fn stepPhase(self: *const Game) f32 {
        if (self.freeze > 0) return 1.0;
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
                if (self.dots[@intCast(next[1])][@intCast(next[0])]) {
                    self.dots[@intCast(next[1])][@intCast(next[0])] = false;
                    self.dots_left -= 1;
                }
            }
        }
        // Same tile, or the two traded tiles this step (at tile granularity a
        // pass-through would otherwise read as a miss).
        for (self.ghosts, ghosts_before) |g, was| {
            if (g.inside) continue;
            const same = g.actor.x == self.pac.x and g.actor.y == self.pac.y;
            const swapped = was[0] == self.pac.x and was[1] == self.pac.y and
                g.actor.x == pac_before[0] and g.actor.y == pac_before[1];
            if (same or swapped) {
                self.caught = true;
                self.freeze = freeze_ticks;
                return;
            }
        }
        if (self.dots_left == 0) self.freeze = freeze_ticks;
    }

    /// In the house: line up under the door and leave. Outside, the
    /// original: run straight; on a wall, pick another direction with a
    /// pseudo-random turn. Added: an occasional turn at open junctions so
    /// four ghosts do not settle into one loop.
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

    /// Eat the nearest dot unless a ghost is close, then flee the ghosts.
    fn choosePacDir(self: *Game) ?Dir {
        var dist: [max_tiles]u16 = undefined;
        var parent: [max_tiles]u16 = undefined;
        self.bfs(self.pac.x, self.pac.y, .pac, &dist, &parent);
        const here = self.index(self.pac.x, self.pac.y);

        var nearest_ghost: u16 = std.math.maxInt(u16);
        for (self.ghosts) |g| {
            if (g.inside) continue;
            nearest_ghost = @min(nearest_ghost, dist[self.index(g.actor.x, g.actor.y)]);
        }

        if (nearest_ghost <= danger_distance) {
            // Flee: the passable neighbor farthest (Manhattan) from the closest ghost.
            var best: ?Dir = null;
            var best_score: i32 = -1;
            for (all_dirs) |d| {
                const next = self.neighbor(self.pac.x, self.pac.y, d) orelse continue;
                if (!self.passable(next[0], next[1], .pac)) continue;
                var score: i32 = std.math.maxInt(i32);
                for (self.ghosts) |g| {
                    if (g.inside) continue;
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
        var cur = target orelse return self.randomTurn(&self.pac, .pac, true);
        while (parent[cur] != here) cur = parent[cur];
        const sx: i32 = @intCast(cur % self.cols);
        const sy: i32 = @intCast(cur / self.cols);
        // Through a tunnel the first step is the far edge.
        for (all_dirs) |d| {
            const next = self.neighbor(self.pac.x, self.pac.y, d) orelse continue;
            if (next[0] == sx and next[1] == sy) return d;
        }
        return null;
    }
};

fn seedOrDefault(seed: u64) u64 {
    return if (seed == 0) 0x243f6a8885a308d3 else seed;
}

// ------------------------------------------------------ pixel renderer --

pub const Geometry = struct {
    /// Tile side in pixels.
    t: u32,
    ox: i32,
    oy: i32,

    pub fn forBoard(game: *const Game, width: u16, height: u16) Geometry {
        const t: u32 = @max(2, @min(width / @max(game.cols, 1), height / @max(game.rows, 1)));
        return .{
            .t = t,
            .ox = @intCast((width - game.cols * t) / 2),
            .oy = @intCast((height - game.rows * t) / 2),
        };
    }
};

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
            if (!game.dots[@intCast(y)][@intCast(x)]) continue;
            fb.fillRect(geo.ox + x * ti + @divTrunc(ti - dot, 2), geo.oy + y * ti + @divTrunc(ti - dot, 2), dot, dot, dot_color);
        }
    }

    const phase = game.stepPhase();
    const radius = tf * 0.68;
    const wave = (game.frame / 4) % 2 == 1;
    for (game.ghosts, ghost_colors) |g, color| {
        const c = actorCenter(g.actor, phase, geo);
        drawGhost(fb, c[0], c[1], radius, color, g.actor.dir, wave);
    }
    const c = actorCenter(game.pac, phase, geo);
    drawPac(fb, c[0], c[1], radius, game.pac.dir, game.mouthAngle());
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

/// Dome, skirt with three teeth that alternate, eyes looking the way it runs.
fn drawGhost(fb: Framebuffer, cx: f32, cy: f32, r: f32, color: [3]u8, dir: Dir, wave: bool) void {
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
    // Eyes.
    const eye_w: i32 = @max(1, @as(i32, @intFromFloat(r * 0.36)));
    const eye_h: i32 = @max(1, @as(i32, @intFromFloat(r * 0.46)));
    const pupil: i32 = @max(1, @as(i32, @intFromFloat(r * 0.2)));
    const look_x: i32 = @intFromFloat(@as(f32, @floatFromInt(dir.dx())) * r * 0.14);
    const look_y: i32 = @intFromFloat(@as(f32, @floatFromInt(dir.dy())) * r * 0.14);
    const eye_y: i32 = @intFromFloat(cy - r * 0.6);
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
        const cols: u16 = if (width >= 2 * 15) width / 2 else width;
        self.game.configure(cols, height);
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

        const cell_w: u16 = if (win.width >= game.cols * 2) 2 else 1;
        const board_w: u16 = game.cols * cell_w;
        if (win.width < board_w) return;
        const origin_x: u16 = (win.width - board_w) / 2;
        // Tall enough: center. Otherwise a viewport that follows Pac-Man.
        var view_top: i32 = 0;
        var origin_y: u16 = 0;
        if (win.height >= game.rows) {
            origin_y = (win.height - game.rows) / 2;
        } else {
            view_top = std.math.clamp(game.pac.y - @divTrunc(@as(i32, win.height), 2), 0, @as(i32, game.rows) - @as(i32, win.height));
        }

        const wall = effect.scaledColor(wall_color, opacity);
        const bg: vaxis.Color = .{ .rgb = .{ 0, 0, 0 } };
        var r: i32 = 0;
        while (r < game.rows) : (r += 1) {
            const screen_row_i = @as(i32, origin_y) + r - view_top;
            if (screen_row_i < 0 or screen_row_i >= win.height) continue;
            const screen_row: u16 = @intCast(screen_row_i);
            var c: i32 = 0;
            while (c < game.cols) : (c += 1) {
                const base: u16 = origin_x + @as(u16, @intCast(c)) * cell_w;
                const t = game.tile(c, r);
                var k: u16 = 0;
                while (k < cell_w) : (k += 1) {
                    const glyph: []const u8 = switch (t) {
                        .path => if (k == 0 and game.dots[@intCast(r)][@intCast(c)]) "·" else " ",
                        .door => "─",
                        else => " ",
                    };
                    const fg = if (t == .door) effect.scaledColor(door_color, opacity) else effect.scaledColor(dot_color, opacity);
                    paint(win, base + k, screen_row, glyph, fg, if (t == .wall) wall else bg, false);
                }
            }
        }

        for (game.ghosts, ghost_colors) |g, color| {
            const pos = boardToScreen(g.actor.x, g.actor.y, origin_x, origin_y, view_top, cell_w, win) orelse continue;
            paint(win, pos[0], pos[1], "M", effect.scaledColor(color, opacity), bg, true);
        }
        const pos = boardToScreen(game.pac.x, game.pac.y, origin_x, origin_y, view_top, cell_w, win) orelse return;
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
};

fn boardToScreen(x: i32, y: i32, origin_x: u16, origin_y: u16, view_top: i32, cell_w: u16, win: vaxis.Window) ?[2]u16 {
    const row_i = @as(i32, origin_y) + y - view_top;
    if (row_i < 0 or row_i >= win.height) return null;
    return .{ origin_x + @as(u16, @intCast(x)) * cell_w, @intCast(row_i) };
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
