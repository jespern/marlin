const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const Column = struct {
    head: i32,
    trail: u16,
    step_frames: u8,
    phase: u8,
    generation: u32,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    columns: []Column = &.{},
    width: u16 = 0,
    height: u16 = 0,
    frame: u64 = 0,
    random_state: u64,

    pub fn init(gpa: std.mem.Allocator, seed: u64) Engine {
        return .{
            .gpa = gpa,
            .random_state = if (seed == 0) 0x6a09e667f3bcc909 else seed,
        };
    }

    pub fn deinit(self: *Engine) void {
        if (self.columns.len > 0) self.gpa.free(self.columns);
        self.* = undefined;
    }

    pub fn reset(self: *Engine, width: u16, height: u16, seed: u64) !void {
        self.random_state = if (seed == 0) 0x6a09e667f3bcc909 else seed;
        self.frame = 0;
        try self.resize(width, height);
        for (self.columns, 0..) |*column, col| self.seedColumn(column, col, true);
    }

    pub fn resize(self: *Engine, width: u16, height: u16) !void {
        if (self.width == width and self.height == height) return;
        const old = self.columns;
        const next = try self.gpa.alloc(Column, width);
        const retained = @min(old.len, next.len);
        if (retained > 0) @memcpy(next[0..retained], old[0..retained]);
        self.columns = next;
        self.width = width;
        self.height = height;
        if (old.len > 0) self.gpa.free(old);
        for (next[retained..], retained..) |*column, col| self.seedColumn(column, col, true);
    }

    pub fn tick(self: *Engine) void {
        self.frame +%= 1;
        if (self.height == 0) return;
        for (self.columns, 0..) |*column, col| {
            if ((self.frame + column.phase) % column.step_frames != 0) continue;
            column.head += 1;
            if (@as(i64, column.head) - column.trail > self.height)
                self.seedColumn(column, col, false);
        }
    }

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        if (win.width == 0 or win.height == 0 or opacity == 0) return;
        effect.prepare(win, mode);

        const width = @min(win.width, self.width);
        var col: u16 = 0;
        while (col < width) : (col += 1) {
            const column = self.columns[col];
            var distance: u16 = 0;
            while (distance < column.trail) : (distance += 1) {
                const row = @as(i64, column.head) - distance;
                if (row < 0 or row >= win.height) continue;
                if (mode == .interleaved and !effect.cellIsOpen(win, col, @intCast(row))) continue;

                const visible = hash(self.frame / 3 +% @as(u64, col) *% 0x9e3779b97f4a7c15 +%
                    @as(u64, distance) *% 0xbf58476d1ce4e5b9 +% column.generation);
                if (distance > 1 and visible % 13 == 0) continue;

                const glyph_hash = hash(self.frame / 2 +% @as(u64, col) *% 0xd1b54a32d192ed03 +%
                    @as(u64, @intCast(row)) *% 0x94d049bb133111eb +% column.generation);
                const fade = @as(u16, column.trail - distance) * 255 / @max(column.trail, 1);
                const alpha: u8 = @intCast(@as(u16, opacity) * fade / 255);
                const base: [3]u8 = if (distance == 0)
                    .{ 0xe8, 0xff, 0xec }
                else if (distance < 3)
                    .{ 0x72, 0xff, 0x91 }
                else
                    .{ 0x16, 0xb8, 0x49 };

                var cell = win.readCell(col, @intCast(row)) orelse continue;
                cell.char = .{ .grapheme = glyphs[glyph_hash % glyphs.len], .width = 1 };
                cell.style.fg = effect.scaledColor(base, alpha);
                if (mode == .full_screen) cell.style.bg = .{ .rgb = .{ 0, 0, 0 } };
                cell.style.bold = distance <= 1;
                cell.style.dim = distance > column.trail / 2;
                cell.link = .{};
                cell.image = null;
                cell.default = false;
                win.writeCell(col, @intCast(row), cell);
            }
        }
    }

    fn seedColumn(self: *Engine, column: *Column, col: usize, initial: bool) void {
        const height = @max(@as(u16, self.height), 1);
        const trail_min = @max(height / 3, 5);
        const trail_span = @max(height / 2, 1);
        const gap_span = @max(@as(u32, height) * 2, 8);
        const a = self.random();
        const b = self.random();
        column.* = .{
            .head = -@as(i32, @intCast(1 + (a % gap_span))),
            .trail = trail_min + @as(u16, @intCast((a >> 24) % trail_span)),
            .step_frames = 1 + @as(u8, @intCast((b >> 8) % 4)),
            .phase = @intCast((b >> 20) % 4),
            .generation = @truncate(hash(b +% col)),
        };
        if (initial) {
            const spread = @as(u64, height) * 2 + 8;
            column.head = @as(i32, @intCast((a +% col * 7) % spread)) - @divTrunc(@as(i32, height), 2);
        }
    }

    fn random(self: *Engine) u64 {
        self.random_state +%= 0x9e3779b97f4a7c15;
        return hash(self.random_state);
    }
};

const hash = effect.hash;

const glyphs = [_][]const u8{
    "ｱ",
    "ｲ",
    "ｳ",
    "ｴ",
    "ｵ",
    "ｶ",
    "ｷ",
    "ｸ",
    "ｹ",
    "ｺ",
    "ｻ",
    "ｼ",
    "ｽ",
    "ｾ",
    "ｿ",
    "ﾀ",
    "ﾁ",
    "ﾂ",
    "ﾃ",
    "ﾄ",
    "ﾅ",
    "ﾆ",
    "ﾇ",
    "ﾈ",
    "ﾉ",
    "ﾊ",
    "ﾋ",
    "ﾌ",
    "ﾍ",
    "ﾎ",
    "ﾏ",
    "ﾐ",
    "ﾑ",
    "ﾒ",
    "ﾓ",
    "ﾔ",
    "ﾕ",
    "ﾖ",
    "ﾗ",
    "ﾘ",
    "ﾙ",
    "ﾚ",
    "ﾛ",
    "ﾜ",
    "ｦ",
    "ﾝ",
    "0",
    "1",
    "2",
    "3",
    "4",
    "5",
    "6",
    "7",
    "8",
    "9",
    "◦",
    "·",
    "¦",
    "┊",
    "╎",
    "╌",
    "⌁",
    "⟡",
};

test "engine is deterministic and advances independent columns" {
    const gpa = std.testing.allocator;
    var one = Engine.init(gpa, 42);
    defer one.deinit();
    var two = Engine.init(gpa, 42);
    defer two.deinit();
    try one.reset(20, 12, 42);
    try two.reset(20, 12, 42);
    try std.testing.expectEqualSlices(Column, one.columns, two.columns);
    for (0..12) |_| {
        one.tick();
        two.tick();
    }
    try std.testing.expectEqualSlices(Column, one.columns, two.columns);
    var differing = false;
    for (one.columns[1..], one.columns[0 .. one.columns.len - 1]) |a, b| {
        if (a.head != b.head or a.trail != b.trail or a.step_frames != b.step_frames) differing = true;
    }
    try std.testing.expect(differing);
}

test "resize preserves existing columns" {
    const gpa = std.testing.allocator;
    var engine = Engine.init(gpa, 7);
    defer engine.deinit();
    try engine.reset(4, 10, 7);
    const first = engine.columns[0];
    try engine.resize(8, 14);
    try std.testing.expectEqual(first, engine.columns[0]);
    try std.testing.expectEqual(@as(usize, 8), engine.columns.len);
}
