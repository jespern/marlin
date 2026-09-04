const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const StringState = struct {
    amplitude: f32,
    wavelength: f32,
    phase: f32,
    speed: f32,
    baseline: f32,
    color: [3]u8,
};

const palette = [_][3]u8{
    .{ 0x59, 0xc3, 0xff },
    .{ 0xb5, 0x74, 0xff },
    .{ 0xff, 0x58, 0xa8 },
    .{ 0xff, 0xb8, 0x45 },
    .{ 0x54, 0xf0, 0xb0 },
    .{ 0xf4, 0xf0, 0x66 },
};

pub const Engine = struct {
    width: u16 = 0,
    height: u16 = 0,
    frame: u64 = 0,
    seed: u64,
    strings: [palette.len]StringState = undefined,

    pub fn init(_: std.mem.Allocator, seed: u64) Engine {
        return .{ .seed = normalizedSeed(seed) };
    }

    pub fn deinit(self: *Engine) void {
        self.* = undefined;
    }

    pub fn reset(self: *Engine, width: u16, height: u16, seed: u64) !void {
        self.seed = normalizedSeed(seed);
        self.frame = 0;
        self.width = width;
        self.height = height;
        self.seedStrings();
    }

    pub fn resize(self: *Engine, width: u16, height: u16) !void {
        var phases: [palette.len]f32 = undefined;
        for (self.strings, 0..) |string, index| phases[index] = string.phase;
        self.width = width;
        self.height = height;
        self.seedStrings();
        for (&self.strings, phases) |*string, phase| string.phase = phase;
    }

    pub fn tick(self: *Engine) void {
        self.frame +%= 1;
        for (&self.strings) |*string| string.phase += string.speed;
    }

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        if (win.width == 0 or win.height == 0 or opacity == 0) return;
        effect.prepare(win, mode);
        const width: u16 = @intCast(@min(win.width, self.width));
        for (self.strings, 0..) |string, index| {
            var previous_row: ?i32 = null;
            var col: u16 = 0;
            while (col < width) : (col += 1) {
                const x: f32 = @floatFromInt(col);
                const secondary = @sin(x / (string.wavelength * 0.47) - string.phase * 0.61) * string.amplitude * 0.22;
                const y = string.baseline + @sin(x / string.wavelength + string.phase) * string.amplitude + secondary;
                const row: i32 = @intFromFloat(@round(y));
                if (row < 0 or row >= win.height) {
                    previous_row = row;
                    continue;
                }
                const glyph: []const u8 = if (previous_row) |previous|
                    if (row < previous) "╱" else if (row > previous) "╲" else "─"
                else
                    "─";
                const pulse = @sin(@as(f32, @floatFromInt(self.frame)) * 0.035 + @as(f32, @floatFromInt(index))) * 0.15 + 0.85;
                const alpha: u8 = @intFromFloat(@as(f32, @floatFromInt(opacity)) * pulse);
                effect.writeGlyph(win, col, @intCast(row), glyph, effect.scaledColor(string.color, alpha), mode, true, false);
                previous_row = row;
            }
        }
    }

    fn seedStrings(self: *Engine) void {
        const height: f32 = @floatFromInt(@max(self.height, 1));
        for (&self.strings, 0..) |*string, index| {
            const mixed = effect.hash(self.seed +% @as(u64, index) *% 0x9e3779b97f4a7c15);
            const slot = (@as(f32, @floatFromInt(index)) + 0.5) / @as(f32, @floatFromInt(self.strings.len));
            string.* = .{
                .amplitude = @max(1.5, height * (0.07 + @as(f32, @floatFromInt(mixed & 0xff)) / 2550.0)),
                .wavelength = 4.5 + @as(f32, @floatFromInt((mixed >> 8) & 0xff)) / 28.0,
                .phase = @as(f32, @floatFromInt((mixed >> 16) & 0xffff)) / 10430.0,
                .speed = (0.025 + @as(f32, @floatFromInt((mixed >> 32) & 0xff)) / 4200.0) * @as(f32, if (index % 2 == 0) 1.0 else -1.0),
                .baseline = height * slot,
                .color = palette[index],
            };
        }
    }
};

fn normalizedSeed(seed: u64) u64 {
    return if (seed == 0) 0x243f6a8885a308d3 else seed;
}

test "dancing strings are deterministic and phases advance" {
    var one = Engine.init(std.testing.allocator, 42);
    defer one.deinit();
    var two = Engine.init(std.testing.allocator, 42);
    defer two.deinit();
    try one.reset(80, 24, 42);
    try two.reset(80, 24, 42);
    try std.testing.expectEqualSlices(StringState, &one.strings, &two.strings);
    const phase = one.strings[0].phase;
    one.tick();
    two.tick();
    try std.testing.expect(one.strings[0].phase != phase);
    try std.testing.expectEqualSlices(StringState, &one.strings, &two.strings);
    const advanced_phase = one.strings[0].phase;
    try one.resize(120, 40);
    try std.testing.expectEqual(advanced_phase, one.strings[0].phase);
    try std.testing.expect(one.strings[0].baseline > 0);
}
