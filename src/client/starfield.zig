const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const star_count = 180;
const Star = struct { x: f32, y: f32, z: f32 };

pub const Engine = struct {
    width: u16 = 0,
    height: u16 = 0,
    frame: u64 = 0,
    random_state: u64,
    stars: [star_count]Star = undefined,

    pub fn init(_: std.mem.Allocator, seed: u64) Engine {
        return .{ .random_state = normalizedSeed(seed) };
    }

    pub fn deinit(self: *Engine) void {
        self.* = undefined;
    }

    pub fn reset(self: *Engine, width: u16, height: u16, seed: u64) !void {
        self.width = width;
        self.height = height;
        self.frame = 0;
        self.random_state = normalizedSeed(seed);
        for (&self.stars, 0..) |*star, index| self.respawn(star, @as(f32, @floatFromInt(index + 1)) / star_count);
    }

    pub fn resize(self: *Engine, width: u16, height: u16) !void {
        self.width = width;
        self.height = height;
    }

    pub fn tick(self: *Engine) void {
        self.frame +%= 1;
        for (&self.stars) |*star| {
            star.z -= 0.018;
            if (star.z <= 0.04) self.respawn(star, 1.0);
        }
    }

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        if (win.width == 0 or win.height == 0 or opacity == 0) return;
        effect.prepare(win, mode);
        const center_x = @as(f32, @floatFromInt(win.width)) * 0.5;
        const center_y = @as(f32, @floatFromInt(win.height)) * 0.5;
        const scale = @min(
            @as(f32, @floatFromInt(win.width)),
            @as(f32, @floatFromInt(win.height)) * 2.0,
        ) * 0.42;
        for (self.stars) |star| {
            const col: i32 = @intFromFloat(@round(center_x + star.x / star.z * scale));
            const row: i32 = @intFromFloat(@round(center_y + star.y / star.z * scale * 0.5));
            if (col < 0 or row < 0 or col >= win.width or row >= win.height) continue;
            const closeness = 1.0 - @min(star.z, 1.0);
            const glyph: []const u8 = if (closeness > 0.78) "✦" else if (closeness > 0.5) "*" else if (closeness > 0.25) "+" else "·";
            const intensity: u8 = @intFromFloat((0.28 + closeness * 0.72) * @as(f32, @floatFromInt(opacity)));
            const tint: [3]u8 = if (star.x > 0.2) .{ 0x9e, 0xc9, 0xff } else if (star.x < -0.2) .{ 0xf2, 0xb0, 0xff } else .{ 0xee, 0xf6, 0xff };
            effect.writeGlyph(win, @intCast(col), @intCast(row), glyph, effect.scaledColor(tint, intensity), mode, closeness > 0.65, closeness < 0.18);
        }
    }

    fn respawn(self: *Engine, star: *Star, z: f32) void {
        star.* = .{
            .x = randomSigned(self.random()),
            .y = randomSigned(self.random()),
            .z = @max(z, 0.08),
        };
    }

    fn random(self: *Engine) u64 {
        self.random_state +%= 0x9e3779b97f4a7c15;
        return effect.hash(self.random_state);
    }
};

fn randomSigned(value: u64) f32 {
    return @as(f32, @floatFromInt(value & 0xffff)) / 32767.5 - 1.0;
}

fn normalizedSeed(seed: u64) u64 {
    return if (seed == 0) 0x13198a2e03707344 else seed;
}

test "starfield is deterministic and recycles near stars" {
    var one = Engine.init(std.testing.allocator, 99);
    defer one.deinit();
    var two = Engine.init(std.testing.allocator, 99);
    defer two.deinit();
    try one.reset(80, 24, 99);
    try two.reset(80, 24, 99);
    try std.testing.expectEqualSlices(Star, &one.stars, &two.stars);
    one.stars[0].z = 0.01;
    two.stars[0].z = 0.01;
    one.tick();
    two.tick();
    try std.testing.expect(one.stars[0].z > 0.9);
    try std.testing.expectEqualSlices(Star, &one.stars, &two.stars);
}
