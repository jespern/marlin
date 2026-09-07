//! Self-playing terminal Tetris. Each piece spawns centered and unrotated,
//! searches the reachable movement graph for its best landing, then visibly
//! executes that route while falling before it locks.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

pub const board_cols: usize = 10;
pub const board_rows: usize = 20;
pub const drop_frames: u8 = 3;
const game_over_frames: u8 = 45;
const max_route_actions: usize = 64;
const min_state_x: i8 = -3;
const max_state_x: i8 = @intCast(board_cols - 1);
const min_state_y: i8 = -3;
const max_state_y: i8 = @intCast(board_rows - 1);
const state_x_count: usize = @intCast(max_state_x - min_state_x + 1);
const state_y_count: usize = @intCast(max_state_y - min_state_y + 1);
const state_count: usize = 4 * state_x_count * state_y_count;

pub const Piece = enum(u8) { i, o, t, s, z, j, l };

const Point = struct { x: i8, y: i8 };
const Shape = [4]Point;

const shapes = [7][4]Shape{
    // I
    .{
        .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 } },
        .{ .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 2 }, .{ .x = 2, .y = 3 } },
        .{ .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 2 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 3 } },
    },
    // O
    .{
        .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
    },
    // T
    .{
        .{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 2 } },
        .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 2 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } },
    },
    // S
    .{
        .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 2 } },
        .{ .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } },
    },
    // Z
    .{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
        .{ .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 1, .y = 2 } },
        .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 2 } },
    },
    // J
    .{
        .{ .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } },
        .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 2, .y = 2 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 2 }, .{ .x = 1, .y = 2 } },
    },
    // L
    .{
        .{ .{ .x = 2, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 } },
        .{ .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 } },
        .{ .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 0, .y = 2 } },
        .{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 1, .y = 2 } },
    },
};

pub const Action = enum(u2) { left, right, rotate, down };

const State = struct {
    rotation: u2,
    x: i8,
    y: i8,
};

const SearchNode = struct {
    state: State,
    parent: u16,
    action: Action,
};

pub const Active = struct {
    piece: Piece,
    rotation: u2,
    x: i8,
    y: i8,
    route: [max_route_actions]Action = undefined,
    route_len: u8 = 0,
    route_index: u8 = 0,
};

pub const Game = struct {
    board: [board_rows][board_cols]u8 = @splat(@splat(0)),
    active: Active = undefined,
    next: Piece = undefined,
    bag: [7]Piece = .{ .i, .o, .t, .s, .z, .j, .l },
    bag_index: u8 = 7,
    rng: u64,
    frame: u64 = 0,
    score: u32 = 0,
    lines: u32 = 0,
    pieces: u32 = 0,
    game_over: u8 = 0,

    pub fn init(seed: u64) Game {
        var game = Game{ .rng = seedOrDefault(seed) };
        game.next = game.nextPiece();
        game.spawn();
        return game;
    }

    pub fn reset(self: *Game, seed: u64) void {
        self.* = .{ .rng = seedOrDefault(seed) };
        self.next = self.nextPiece();
        self.spawn();
    }

    pub fn level(self: *const Game) u32 {
        return self.lines / 10 + 1;
    }

    pub fn tick(self: *Game) void {
        self.frame +%= 1;
        if (self.game_over > 0) {
            self.game_over -= 1;
            if (self.game_over == 0) self.reset(self.random());
            return;
        }
        if (self.frame % drop_frames != 0) return;
        if (self.active.route_index < self.active.route_len) {
            self.applyAction(self.active.route[self.active.route_index]);
            self.active.route_index += 1;
            return;
        }
        self.lock();
        const cleared = self.clearLines();
        self.score +|= lineScore(cleared) *| self.level();
        self.lines +|= cleared;
        self.pieces +|= 1;
        self.spawn();
    }

    fn spawn(self: *Game) void {
        const piece = self.next;
        self.next = self.nextPiece();
        const bounds = shapeBounds(piece, 0);
        const width = bounds[1] - bounds[0] + 1;
        const start = State{
            .rotation = 0,
            .x = @divTrunc(@as(i8, @intCast(board_cols)) - width, 2) - bounds[0],
            .y = -bounds[2],
        };
        self.active = .{
            .piece = piece,
            .rotation = start.rotation,
            .x = start.x,
            .y = start.y,
        };
        if (!self.fits(piece, start.rotation, start.x, start.y) or !self.replan())
            self.game_over = game_over_frames;
    }

    pub fn replan(self: *Game) bool {
        self.active.route_len = 0;
        self.active.route_index = 0;
        return self.planRoute(.{
            .rotation = self.active.rotation,
            .x = self.active.x,
            .y = self.active.y,
        });
    }

    fn planRoute(self: *Game, start: State) bool {
        var nodes: [state_count]SearchNode = undefined;
        var visited: [state_count]bool = @splat(false);
        nodes[0] = .{
            .state = start,
            .parent = std.math.maxInt(u16),
            .action = .down,
        };
        visited[stateIndex(start)] = true;
        var head: usize = 0;
        var tail: usize = 1;
        var best_index: ?usize = null;
        var best_score: i32 = std.math.minInt(i32);

        while (head < tail) : (head += 1) {
            const node = nodes[head];
            if (!self.fits(self.active.piece, node.state.rotation, node.state.x, node.state.y + 1) and
                stateVisible(self.active.piece, node.state))
            {
                var board = self.board;
                place(&board, self.active.piece, node.state.rotation, node.state.x, node.state.y);
                const cleared = clearBoardLines(&board);
                const score = evaluate(board, cleared);
                if (score > best_score or (score == best_score and self.random() & 1 == 0)) {
                    best_score = score;
                    best_index = head;
                }
            }

            const actions = [_]Action{ .rotate, .left, .right, .down };
            for (actions) |action| {
                const next = movedState(node.state, action);
                if (!stateInBounds(next) or !self.fits(self.active.piece, next.rotation, next.x, next.y)) continue;
                const index = stateIndex(next);
                if (visited[index]) continue;
                visited[index] = true;
                nodes[tail] = .{
                    .state = next,
                    .parent = @intCast(head),
                    .action = action,
                };
                tail += 1;
            }
        }

        const landing_index = best_index orelse return false;
        var reverse: [max_route_actions]Action = undefined;
        var route_len: usize = 0;
        var index = landing_index;
        while (nodes[index].parent != std.math.maxInt(u16)) {
            if (route_len == reverse.len) return false;
            reverse[route_len] = nodes[index].action;
            route_len += 1;
            index = nodes[index].parent;
        }
        for (0..route_len) |route_index| {
            self.active.route[route_index] = reverse[route_len - route_index - 1];
        }
        self.active.route_len = @intCast(route_len);
        self.active.route_index = 0;
        return true;
    }

    fn applyAction(self: *Game, action: Action) void {
        const next = movedState(.{
            .rotation = self.active.rotation,
            .x = self.active.x,
            .y = self.active.y,
        }, action);
        if (!self.fits(self.active.piece, next.rotation, next.x, next.y)) return;
        self.active.rotation = next.rotation;
        self.active.x = next.x;
        self.active.y = next.y;
    }

    fn nextPiece(self: *Game) Piece {
        if (self.bag_index >= self.bag.len) {
            self.bag = .{ .i, .o, .t, .s, .z, .j, .l };
            var i: usize = self.bag.len;
            while (i > 1) {
                i -= 1;
                const j: usize = @intCast(self.random() % (i + 1));
                std.mem.swap(Piece, &self.bag[i], &self.bag[j]);
            }
            self.bag_index = 0;
        }
        const piece = self.bag[self.bag_index];
        self.bag_index += 1;
        return piece;
    }

    pub fn fits(self: *const Game, piece: Piece, rotation: u2, x: i8, y: i8) bool {
        for (shape(piece, rotation)) |point| {
            const bx = x + point.x;
            const by = y + point.y;
            if (bx < 0 or bx >= board_cols or by >= board_rows) return false;
            if (by >= 0 and self.board[@intCast(by)][@intCast(bx)] != 0) return false;
        }
        return true;
    }

    fn lock(self: *Game) void {
        place(&self.board, self.active.piece, self.active.rotation, self.active.x, self.active.y);
    }

    pub fn clearLines(self: *Game) u32 {
        return clearBoardLines(&self.board);
    }

    fn random(self: *Game) u64 {
        self.rng +%= 0x9e3779b97f4a7c15;
        return effect.hash(self.rng);
    }
};

fn movedState(state: State, action: Action) State {
    return switch (action) {
        .left => .{ .rotation = state.rotation, .x = state.x - 1, .y = state.y },
        .right => .{ .rotation = state.rotation, .x = state.x + 1, .y = state.y },
        .rotate => .{ .rotation = state.rotation +% 1, .x = state.x, .y = state.y },
        .down => .{ .rotation = state.rotation, .x = state.x, .y = state.y + 1 },
    };
}

fn stateInBounds(state: State) bool {
    return state.x >= min_state_x and state.x <= max_state_x and
        state.y >= min_state_y and state.y <= max_state_y;
}

fn stateIndex(state: State) usize {
    const rotation: usize = state.rotation;
    const y: usize = @intCast(state.y - min_state_y);
    const x: usize = @intCast(state.x - min_state_x);
    return (rotation * state_y_count + y) * state_x_count + x;
}

fn stateVisible(piece: Piece, state: State) bool {
    for (shape(piece, state.rotation)) |point| {
        if (state.y + point.y >= 0) return true;
    }
    return false;
}

fn shape(piece: Piece, rotation: u2) Shape {
    return shapes[@intFromEnum(piece)][rotation];
}

/// min x, max x, min y, max y.
fn shapeBounds(piece: Piece, rotation: u2) [4]i8 {
    var result = [4]i8{ 4, 0, 4, 0 };
    for (shape(piece, rotation)) |point| {
        result[0] = @min(result[0], point.x);
        result[1] = @max(result[1], point.x);
        result[2] = @min(result[2], point.y);
        result[3] = @max(result[3], point.y);
    }
    return result;
}

fn place(board: *[board_rows][board_cols]u8, piece: Piece, rotation: u2, x: i8, y: i8) void {
    for (shape(piece, rotation)) |point| {
        const by = y + point.y;
        if (by < 0) continue;
        board[@intCast(by)][@intCast(x + point.x)] = @intFromEnum(piece) + 1;
    }
}

fn clearBoardLines(board: *[board_rows][board_cols]u8) u32 {
    var write: i32 = board_rows - 1;
    var cleared: u32 = 0;
    var read: i32 = board_rows - 1;
    while (read >= 0) : (read -= 1) {
        var full = true;
        for (board[@intCast(read)]) |cell| full = full and cell != 0;
        if (full) {
            cleared += 1;
            continue;
        }
        if (write != read) board[@intCast(write)] = board[@intCast(read)];
        write -= 1;
    }
    while (write >= 0) : (write -= 1) board[@intCast(write)] = @splat(0);
    return cleared;
}

fn evaluate(board: [board_rows][board_cols]u8, cleared: u32) i32 {
    var heights: [board_cols]i32 = @splat(0);
    var holes: i32 = 0;
    for (0..board_cols) |x| {
        var found = false;
        for (0..board_rows) |y| {
            if (board[y][x] != 0) {
                if (!found) heights[x] = @intCast(board_rows - y);
                found = true;
            } else if (found) holes += 1;
        }
    }
    var aggregate: i32 = 0;
    var bumpiness: i32 = 0;
    for (heights, 0..) |height, x| {
        aggregate += height;
        if (x + 1 < heights.len) bumpiness += @intCast(@abs(height - heights[x + 1]));
    }
    return @as(i32, @intCast(cleared)) * 760 - aggregate * 51 - holes * 356 - bumpiness * 18;
}

fn lineScore(cleared: u32) u32 {
    return switch (cleared) {
        1 => 100,
        2 => 300,
        3 => 500,
        4 => 800,
        else => 0,
    };
}

fn seedOrDefault(seed: u64) u64 {
    return if (seed == 0) 0x243f6a8885a308d3 else seed;
}

pub const colors = [7][3]u8{
    .{ 0x28, 0xd7, 0xe5 },
    .{ 0xf5, 0xd5, 0x47 },
    .{ 0xa8, 0x5c, 0xe8 },
    .{ 0x55, 0xd6, 0x68 },
    .{ 0xee, 0x52, 0x55 },
    .{ 0x4c, 0x72, 0xe8 },
    .{ 0xf0, 0x94, 0x3d },
};

const PixelBuffer = struct {
    rgb: []u8,
    width: i32,
    height: i32,

    fn set(self: PixelBuffer, x: i32, y: i32, color: [3]u8) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const offset = (@as(usize, @intCast(y)) * @as(usize, @intCast(self.width)) + @as(usize, @intCast(x))) * 3;
        self.rgb[offset..][0..3].* = color;
    }

    fn fill(self: PixelBuffer, x: i32, y: i32, width: i32, height: i32, color: [3]u8) void {
        var yy = @max(y, 0);
        const bottom = @min(y + height, self.height);
        while (yy < bottom) : (yy += 1) {
            var xx = @max(x, 0);
            const right = @min(x + width, self.width);
            while (xx < right) : (xx += 1) self.set(xx, yy, color);
        }
    }

    fn frame(self: PixelBuffer, x: i32, y: i32, width: i32, height: i32, thickness: i32, color: [3]u8) void {
        self.fill(x, y, width, thickness, color);
        self.fill(x, y + height - thickness, width, thickness, color);
        self.fill(x, y, thickness, height, color);
        self.fill(x + width - thickness, y, thickness, height, color);
    }
};

const arcade_bg = [3]u8{ 0x05, 0x07, 0x18 };
const panel_bg = [3]u8{ 0x0c, 0x12, 0x2b };
const well_bg = [3]u8{ 0x03, 0x05, 0x0d };
const cyan = [3]u8{ 0x39, 0xe7, 0xff };
const magenta = [3]u8{ 0xff, 0x42, 0xc6 };
const white = [3]u8{ 0xee, 0xf7, 0xff };

pub fn renderPixels(game: *const Game, rgb: []u8, width: u16, height: u16) void {
    if (width == 0 or height == 0 or rgb.len < @as(usize, width) * height * 3) return;
    const fb = PixelBuffer{ .rgb = rgb, .width = width, .height = height };
    drawBackdrop(fb, game.frame);

    const margin = @max(@divTrunc(@as(i32, @intCast(@min(width, height))), 28), 8);
    const title_h = @max(@divTrunc(@as(i32, height), 9), 28);
    const footer_h = @max(@divTrunc(@as(i32, height), 14), 18);
    const available_h = @as(i32, height) - title_h - footer_h - margin * 2;
    const side_units: i32 = if (width >= height) 15 else 3;
    const board_cols_i: i32 = board_cols;
    const board_rows_i: i32 = board_rows;
    const tile_by_width = @divTrunc(@as(i32, width) - margin * 4, board_cols_i + side_units);
    const tile = @max(3, @min(@divTrunc(available_h, board_rows_i), tile_by_width));
    const board_w = board_cols_i * tile;
    const board_h = board_rows_i * tile;
    const board_x = @divTrunc(@as(i32, width) - board_w, 2);
    const board_y = title_h + @divTrunc(@max(available_h - board_h, 0), 2) + margin;
    const frame_t = @max(2, @divTrunc(tile, 5));

    drawTitle(fb, width, title_h);
    drawWell(fb, board_x, board_y, board_w, board_h, frame_t);
    drawBoard(fb, game, board_x, board_y, tile);

    const panel_w = @max(tile * 5, 72);
    if (board_x - margin - panel_w >= margin) {
        drawStatsPanel(fb, margin, board_y, panel_w, board_h, game, tile);
        drawNextPanel(fb, board_x + board_w + margin, board_y, @as(i32, width) - (board_x + board_w + margin * 2), @min(board_h, tile * 8), game, tile);
    } else {
        const strip_y = @min(board_y + board_h + margin, @as(i32, height) - footer_h);
        drawCompactStats(fb, margin, strip_y, @as(i32, width) - margin * 2, game);
    }

    if (game.game_over > 0) drawGameOver(fb, board_x, board_y, board_w, board_h);
    drawScanlines(fb);
}

fn drawBackdrop(fb: PixelBuffer, frame: u64) void {
    var y: i32 = 0;
    while (y < fb.height) : (y += 1) {
        const glow: u8 = @intCast(@min(18, @divTrunc(y * 18, @max(fb.height, 1))));
        fb.fill(0, y, fb.width, 1, .{ arcade_bg[0] + glow / 4, arcade_bg[1] + glow / 3, arcade_bg[2] + glow });
    }
    const spacing = @max(18, @divTrunc(fb.width, 28));
    var x: i32 = @intCast(frame % @as(u64, @intCast(spacing)));
    while (x < fb.width) : (x += spacing) fb.fill(x, 0, 1, fb.height, .{ 0x0b, 0x18, 0x35 });
    y = @intCast((frame / 2) % @as(u64, @intCast(spacing)));
    while (y < fb.height) : (y += spacing) fb.fill(0, y, fb.width, 1, .{ 0x0b, 0x18, 0x35 });
    var star: u64 = effect.hash(frame / 8 + 0x544554524953);
    for (0..36) |_| {
        star = effect.hash(star);
        const sx: i32 = @intCast(star % @as(u64, @intCast(@max(fb.width, 1))));
        const sy: i32 = @intCast((star >> 24) % @as(u64, @intCast(@max(fb.height, 1))));
        fb.set(sx, sy, if (star & 1 == 0) cyan else magenta);
    }
}

fn drawTitle(fb: PixelBuffer, width: u16, title_h: i32) void {
    const scale = @max(2, @min(@divTrunc(@as(i32, width), 90), @divTrunc(title_h, 8)));
    const title_w = textWidth("MARLIN TETRIS", scale);
    const x = @divTrunc(@as(i32, width) - title_w, 2);
    drawText(fb, x + scale, @max(3, @divTrunc(title_h - 5 * scale, 2)) + scale, "MARLIN TETRIS", scale, .{ 0x35, 0x0c, 0x48 });
    drawText(fb, x, @max(3, @divTrunc(title_h - 5 * scale, 2)), "MARLIN TETRIS", scale, cyan);
    fb.fill(@divTrunc(@as(i32, width), 8), title_h - 3, @divTrunc(@as(i32, width) * 3, 4), 1, magenta);
}

fn drawWell(fb: PixelBuffer, x: i32, y: i32, width: i32, height: i32, thickness: i32) void {
    fb.fill(x - thickness * 3, y - thickness * 3, width + thickness * 6, height + thickness * 6, .{ 0x18, 0x06, 0x2d });
    fb.frame(x - thickness * 3, y - thickness * 3, width + thickness * 6, height + thickness * 6, thickness, magenta);
    fb.frame(x - thickness, y - thickness, width + thickness * 2, height + thickness * 2, thickness, cyan);
    fb.fill(x, y, width, height, well_bg);
    var row: i32 = 1;
    while (row < @as(i32, board_rows)) : (row += 1) fb.fill(x, y + @divTrunc(row * height, @as(i32, board_rows)), width, 1, .{ 0x09, 0x10, 0x24 });
    var col: i32 = 1;
    while (col < @as(i32, board_cols)) : (col += 1) fb.fill(x + @divTrunc(col * width, @as(i32, board_cols)), y, 1, height, .{ 0x09, 0x10, 0x24 });
}

fn drawBoard(fb: PixelBuffer, game: *const Game, ox: i32, oy: i32, tile: i32) void {
    for (0..board_rows) |y| {
        for (0..board_cols) |x| {
            const value = game.board[y][x];
            if (value != 0) drawPixelBlock(fb, ox + @as(i32, @intCast(x)) * tile, oy + @as(i32, @intCast(y)) * tile, tile, colors[value - 1], false);
        }
    }
    if (game.game_over > 0) return;

    var ghost_y = game.active.y;
    while (game.fits(game.active.piece, game.active.rotation, game.active.x, ghost_y + 1)) ghost_y += 1;
    if (ghost_y != game.active.y) {
        for (shape(game.active.piece, game.active.rotation)) |point| {
            const x = game.active.x + point.x;
            const y = ghost_y + point.y;
            if (x < 0 or y < 0 or x >= board_cols or y >= board_rows) continue;
            drawGhostBlock(fb, ox + @as(i32, x) * tile, oy + @as(i32, y) * tile, tile, colors[@intFromEnum(game.active.piece)]);
        }
    }

    const next_is_down = game.active.route_index < game.active.route_len and
        game.active.route[game.active.route_index] == .down;
    const phase: i32 = if (next_is_down) @intCast(game.frame % drop_frames) else 0;
    const offset = @divTrunc(phase * tile, drop_frames);
    for (shape(game.active.piece, game.active.rotation)) |point| {
        const x = game.active.x + point.x;
        const y = game.active.y + point.y;
        if (x < 0 or y < 0 or x >= board_cols or y >= board_rows) continue;
        drawPixelBlock(fb, ox + @as(i32, x) * tile, oy + @as(i32, y) * tile + offset, tile, colors[@intFromEnum(game.active.piece)], true);
    }
}

fn drawPixelBlock(fb: PixelBuffer, x: i32, y: i32, size: i32, color: [3]u8, bright: bool) void {
    const gap = @max(1, @divTrunc(size, 14));
    const bevel = @max(1, @divTrunc(size, 7));
    const base = if (bright) lighten(color, 18) else color;
    fb.fill(x + gap, y + gap, size - gap * 2, size - gap * 2, base);
    fb.fill(x + gap, y + gap, size - gap * 2, bevel, lighten(base, 72));
    fb.fill(x + gap, y + gap, bevel, size - gap * 2, lighten(base, 48));
    fb.fill(x + gap, y + size - gap - bevel, size - gap * 2, bevel, darken(base, 72));
    fb.fill(x + size - gap - bevel, y + gap, bevel, size - gap * 2, darken(base, 58));
    if (size >= 10) fb.frame(x + bevel * 2, y + bevel * 2, size - bevel * 4, size - bevel * 4, 1, lighten(base, 28));
}

fn drawGhostBlock(fb: PixelBuffer, x: i32, y: i32, size: i32, color: [3]u8) void {
    const inset = @max(2, @divTrunc(size, 5));
    fb.frame(x + inset, y + inset, size - inset * 2, size - inset * 2, @max(1, @divTrunc(size, 10)), darken(color, 90));
}

fn drawStatsPanel(fb: PixelBuffer, x: i32, y: i32, width: i32, height: i32, game: *const Game, tile: i32) void {
    const panel_h = @min(height, tile * 13);
    drawPanel(fb, x, y, width, panel_h, magenta);
    const scale = @max(1, @min(3, @divTrunc(width, 48)));
    var line_y = y + tile;
    drawText(fb, x + @divTrunc(tile, 2), line_y, "SCORE", scale, magenta);
    line_y += scale * 7;
    drawNumber(fb, x + @divTrunc(tile, 2), line_y, game.score, 7, scale, white);
    line_y += scale * 9;
    drawText(fb, x + @divTrunc(tile, 2), line_y, "LINES", scale, cyan);
    line_y += scale * 7;
    drawNumber(fb, x + @divTrunc(tile, 2), line_y, game.lines, 4, scale, white);
    line_y += scale * 9;
    drawText(fb, x + @divTrunc(tile, 2), line_y, "LEVEL", scale, .{ 0xff, 0xd1, 0x45 });
    line_y += scale * 7;
    drawNumber(fb, x + @divTrunc(tile, 2), line_y, game.level(), 2, scale, white);
}

fn drawNextPanel(fb: PixelBuffer, x: i32, y: i32, width: i32, height: i32, game: *const Game, tile: i32) void {
    if (width < 32) return;
    drawPanel(fb, x, y, width, height, cyan);
    const scale = @max(1, @min(3, @divTrunc(width, 48)));
    drawText(fb, x + @divTrunc(tile, 2), y + @divTrunc(tile, 2), "NEXT", scale, cyan);
    const preview_tile = @max(4, @min(tile, @min(@divTrunc(width, 6), @divTrunc(height - tile * 2, 5))));
    const bounds = shapeBounds(game.next, 0);
    const piece_w = @as(i32, bounds[1] - bounds[0] + 1) * preview_tile;
    const piece_h = @as(i32, bounds[3] - bounds[2] + 1) * preview_tile;
    const px = x + @divTrunc(width - piece_w, 2) - @as(i32, bounds[0]) * preview_tile;
    const py = y + @divTrunc(height - piece_h, 2) - @as(i32, bounds[2]) * preview_tile + @divTrunc(tile, 2);
    for (shape(game.next, 0)) |point| drawPixelBlock(fb, px + @as(i32, point.x) * preview_tile, py + @as(i32, point.y) * preview_tile, preview_tile, colors[@intFromEnum(game.next)], true);
}

fn drawCompactStats(fb: PixelBuffer, x: i32, y: i32, width: i32, game: *const Game) void {
    if (y >= fb.height - 6) return;
    drawPanel(fb, x, y, width, fb.height - y - 4, cyan);
    const scale = @max(1, @min(2, @divTrunc(width, 100)));
    var buf: [96]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "SCORE {d}  LINES {d}  LEVEL {d}  NEXT {s}", .{ game.score, game.lines, game.level(), @tagName(game.next) }) catch return;
    drawText(fb, x + 8, y + 7, label, scale, white);
}

fn drawPanel(fb: PixelBuffer, x: i32, y: i32, width: i32, height: i32, accent: [3]u8) void {
    if (width <= 0 or height <= 0) return;
    fb.fill(x, y, width, height, panel_bg);
    fb.frame(x, y, width, height, 2, darken(accent, 72));
    fb.fill(x + 4, y + 4, width - 8, 1, accent);
}

fn drawGameOver(fb: PixelBuffer, x: i32, y: i32, width: i32, height: i32) void {
    const banner_h = @max(30, @divTrunc(height, 5));
    const banner_y = y + @divTrunc(height - banner_h, 2);
    fb.fill(x, banner_y, width, banner_h, .{ 0x18, 0x02, 0x18 });
    fb.frame(x, banner_y, width, banner_h, 3, magenta);
    const scale = @max(1, @min(4, @divTrunc(width, 52)));
    drawText(fb, x + @divTrunc(width - textWidth("GAME OVER", scale), 2), banner_y + @divTrunc(banner_h - 5 * scale, 2), "GAME OVER", scale, white);
}

fn drawScanlines(fb: PixelBuffer) void {
    var y: i32 = 1;
    while (y < fb.height) : (y += 3) {
        var x: i32 = 0;
        while (x < fb.width) : (x += 1) {
            const offset = (@as(usize, @intCast(y)) * @as(usize, @intCast(fb.width)) + @as(usize, @intCast(x))) * 3;
            inline for (0..3) |channel| fb.rgb[offset + channel] = @intCast(@as(u16, fb.rgb[offset + channel]) * 88 / 100);
        }
    }
}

fn lighten(color: [3]u8, amount: u8) [3]u8 {
    return .{ color[0] +| amount, color[1] +| amount, color[2] +| amount };
}

fn darken(color: [3]u8, amount: u8) [3]u8 {
    return .{ color[0] -| amount, color[1] -| amount, color[2] -| amount };
}

fn drawNumber(fb: PixelBuffer, x: i32, y: i32, value: u32, digits: usize, scale: i32, color: [3]u8) void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return;
    const padding = digits -| text.len;
    var xx = x;
    for (0..padding) |_| {
        drawGlyph(fb, xx, y, '0', scale, darken(color, 150));
        xx += 4 * scale;
    }
    drawText(fb, xx, y, text, scale, color);
}

fn textWidth(text: []const u8, scale: i32) i32 {
    return if (text.len == 0) 0 else @as(i32, @intCast(text.len * 4 - 1)) * scale;
}

fn drawText(fb: PixelBuffer, x: i32, y: i32, text: []const u8, scale: i32, color: [3]u8) void {
    var xx = x;
    for (text) |char| {
        drawGlyph(fb, xx, y, std.ascii.toUpper(char), scale, color);
        xx += 4 * scale;
    }
}

fn drawGlyph(fb: PixelBuffer, x: i32, y: i32, char: u8, scale: i32, color: [3]u8) void {
    const bits = glyph(char);
    for (0..5) |row| {
        for (0..3) |col| {
            const shift: u4 = @intCast(14 - (row * 3 + col));
            if ((bits >> shift) & 1 != 0) fb.fill(x + @as(i32, @intCast(col)) * scale, y + @as(i32, @intCast(row)) * scale, scale, scale, color);
        }
    }
}

fn glyph(char: u8) u15 {
    return switch (char) {
        '0' => 0b111_101_101_101_111,
        '1' => 0b010_110_010_010_111,
        '2' => 0b111_001_111_100_111,
        '3' => 0b111_001_111_001_111,
        '4' => 0b101_101_111_001_001,
        '5' => 0b111_100_111_001_111,
        '6' => 0b111_100_111_101_111,
        '7' => 0b111_001_010_010_010,
        '8' => 0b111_101_111_101_111,
        '9' => 0b111_101_111_001_111,
        'A' => 0b010_101_111_101_101,
        'C' => 0b111_100_100_100_111,
        'E' => 0b111_100_110_100_111,
        'G' => 0b111_100_101_101_111,
        'I' => 0b111_010_010_010_111,
        'L' => 0b100_100_100_100_111,
        'M' => 0b101_111_111_101_101,
        'N' => 0b101_111_111_111_101,
        'O' => 0b111_101_101_101_111,
        'R' => 0b110_101_110_101_101,
        'S' => 0b111_100_111_001_111,
        'T' => 0b111_010_010_010_010,
        'V' => 0b101_101_101_101_010,
        'X' => 0b101_101_010_101_101,
        'Z' => 0b111_001_010_100_111,
        else => 0,
    };
}

/// Terminal-cell fallback for terminals without Kitty graphics.
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
        self.width = width;
        self.height = height;
        self.game.reset(seed);
    }

    pub fn resize(self: *Engine, width: u16, height: u16) !void {
        self.width = width;
        self.height = height;
    }

    pub fn tick(self: *Engine) void {
        self.game.tick();
    }

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        _ = mode;
        if (win.width == 0 or win.height == 0 or opacity == 0) return;
        effect.prepare(win, .full_screen);
        win.hideCursor();

        const cell_w: u16 = if (win.width >= board_cols * 2 + 2) 2 else 1;
        const board_w: u16 = @intCast(board_cols * cell_w);
        const visible_rows: u16 = @intCast(@min(board_rows, win.height));
        if (win.width < board_w) return;
        const ox = (win.width - board_w) / 2;
        const oy = (win.height - visible_rows) / 2;
        const first_row: usize = board_rows - visible_rows;

        for (first_row..board_rows) |y| {
            for (0..board_cols) |x| {
                const value = self.game.board[y][x];
                if (value == 0) continue;
                paintBlock(win, ox + @as(u16, @intCast(x)) * cell_w, oy + @as(u16, @intCast(y - first_row)), cell_w, colors[value - 1], opacity);
            }
        }
        if (self.game.game_over == 0) {
            for (shape(self.game.active.piece, self.game.active.rotation)) |point| {
                const x = self.game.active.x + point.x;
                const y = self.game.active.y + point.y;
                if (x < 0 or y < @as(i8, @intCast(first_row)) or y >= board_rows) continue;
                const screen_y: usize = @intCast(y);
                paintBlock(win, ox + @as(u16, @intCast(x)) * cell_w, oy + @as(u16, @intCast(screen_y - first_row)), cell_w, colors[@intFromEnum(self.game.active.piece)], opacity);
            }
        }
    }
};

fn paintBlock(win: vaxis.Window, col: u16, row: u16, width: u16, color: [3]u8, opacity: u8) void {
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        var cell = win.readCell(col + i, row) orelse continue;
        const scaled = effect.scaledColor(color, opacity);
        cell.char = .{ .grapheme = if (width == 2 and i == 0) "▐" else " ", .width = 1 };
        cell.style.fg = scaled;
        cell.style.bg = scaled;
        cell.style.bold = false;
        cell.style.dim = false;
        cell.link = .{};
        cell.image = null;
        cell.default = false;
        win.writeCell(col + i, row, cell);
    }
}
