//! Mario CI8 rear-view frame and its split body/wheel RGBA16 palette.
const std = @import("std");
const rom = @import("rom.zig");
const render = @import("render.zig");
// Bank 0 retains the prototype camera pitch. Angular spacing follows
// func_8002934C's near-rear 0x208-unit bins; full pitch selection remains pending.
const characters = @import("characters.zig").characters;
const frames = characters[0].frames;
pub const Sprite = struct {
    indices: [frames.len][4096]u8,
    palettes: [frames.len][4][256][4]u8,
    spark_small: [256]u8,
    spark_large: [1024]u8,
    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Sprite {
        return loadCharacter(gpa, bytes, 0);
    }
    pub fn loadCharacter(gpa: std.mem.Allocator, bytes: []const u8, character: usize) !Sprite {
        if (character >= characters.len) return error.InvalidCharacter;
        var self: Sprite = undefined;
        for (characters[character].frames, 0..) |frame, f| {
            const indices = try rom.mio0(gpa, bytes[frame.pixels..]);
            defer gpa.free(indices);
            if (indices.len != 4096) return error.InvalidKart;
            @memcpy(&self.indices[f], indices);
            for (0..4) |phase| for (0..256) |index| {
                const offset: usize = if (index < 192) characters[character].palette + index * 2 else frame.wheels + phase * 128 + (index - 192) * 2;
                self.palettes[f][phase][index] = render.rgba16(try rom.u16be(bytes, offset));
            };
        }
        const small = try rom.mio0(gpa, bytes[0x69b03c..]);
        defer gpa.free(small);
        const large = try rom.mio0(gpa, bytes[0x69b140..]);
        defer gpa.free(large);
        if (small.len != 256 or large.len != 1024) return error.InvalidParticleTexture;
        @memcpy(&self.spark_small, small);
        @memcpy(&self.spark_large, large);
        return self;
    }
    pub fn draw(self: *const Sprite, renderer: *render.Renderer) void {
        self.drawAngle(renderer, 0);
    }
    pub fn drawAngle(self: *const Sprite, renderer: *render.Renderer, slip: i32) void {
        self.drawAt(renderer, slip, 0, 128, 153, 0, 255);
    }
    pub fn drawGame(self: *const Sprite, renderer: *render.Renderer, g: *const @import("game.zig").Game) void {
        if (g.controller.hit_immunity > 0 and g.controller.hit_immunity % 12 < 4) return;
        const camera = g.camera();
        for (g.presentation.particles) |p| if (p.alive) self.drawParticle(renderer, camera, p);
        const body = g.pos.add(.{ .x = 0, .y = 6 + g.controller.drift.height, .z = 0 });
        const screen = camera.project(body) orelse return;
        if (screen.x < -64 or screen.x > render.width + 64 or screen.y < -64 or screen.y > render.height + 64) return;
        self.drawAt(renderer, g.spriteAngle() + spinAngle(g.*), @intCast(g.presentation.wheel >> 8), @as(i32, @intFromFloat(screen.x)) - 32, @as(i32, @intFromFloat(screen.y)) - 32, 1 / screen.z, 255);
    }
    pub fn drawOpponent(self: *const Sprite, r: *render.Renderer, camera: render.Camera, g: @import("game.zig").Game) void {
        if (g.controller.hit_immunity > 0 and g.controller.hit_immunity % 12 < 4) return;
        for (g.presentation.particles) |p| if (p.alive) self.drawParticle(r, camera, p);
        const pose = @import("ghost.zig").pose(g);
        const screen = camera.project(pose.body) orelse return;
        if (screen.x < -128 or screen.x > 448 or screen.y < -128 or screen.y > 368) return;
        const size: i32 = @intFromFloat(std.math.clamp(3200 / screen.z, 2, 128));
        self.drawScaled(r, @import("presentation.zig").angleUnits(pose.yaw - camera.yaw) + spinAngle(g), @intCast(pose.wheel), @as(i32, @intFromFloat(screen.x)) - @divTrunc(size, 2), @as(i32, @intFromFloat(screen.y)) - @divTrunc(size, 2), 1 / screen.z, 255, @intCast(size));
    }
    pub fn drawGhost(self: *const Sprite, r: *render.Renderer, camera: render.Camera, pose: @import("ghost.zig").Pose) void {
        const screen = camera.project(pose.body) orelse return;
        if (screen.x < -64 or screen.x > 384 or screen.y < -64 or screen.y > 304) return;
        const angle = @import("presentation.zig").angleUnits(pose.yaw - camera.yaw);
        self.drawScaled(r, angle, @intCast(pose.wheel), @as(i32, @intFromFloat(screen.x)) - @divTrunc(@as(i32, @intFromFloat(std.math.clamp(3200 / screen.z, 2, 128))), 2), @as(i32, @intFromFloat(screen.y)) - @divTrunc(@as(i32, @intFromFloat(std.math.clamp(3200 / screen.z, 2, 128))), 2), 1 / screen.z, 90, @intFromFloat(std.math.clamp(3200 / screen.z, 2, 128)));
    }
    fn drawAt(self: *const Sprite, renderer: *render.Renderer, slip: i32, phase: usize, left: i32, top: i32, depth: f32, opacity: u8) void {
        self.drawScaled(renderer, slip, phase, left, top, depth, opacity, 64);
    }
    fn drawScaled(self: *const Sprite, renderer: *render.Renderer, slip: i32, phase: usize, left: i32, top: i32, depth: f32, opacity: u8, size: usize) void {
        const frame = frameIndex(slip);
        for (0..size) |y| for (0..size) |x| {
            const sx = left + @as(i32, @intCast(x));
            const sy = top + @as(i32, @intCast(y));
            if (sx < 0 or sy < 0 or sx >= render.width or sy >= render.height) continue;
            const source_x = if (slip > 0) 63 - x * 64 / size else x * 64 / size;
            const pixel = self.palettes[frame][phase][self.indices[frame][(y * 64 / size) * 64 + source_x]];
            if (pixel[3] == 0) continue;
            const i = @as(usize, @intCast(sy)) * render.width + @as(usize, @intCast(sx));
            if (depth > 0 and depth < renderer.depth[i]) continue;
            if (opacity == 255) {
                renderer.rgb[i * 3 ..][0..3].* = pixel[0..3].*;
                if (depth > 0) renderer.depth[i] = depth;
            } else {
                for (0..3) |c| renderer.rgb[i * 3 + c] = @intCast((@as(u32, renderer.rgb[i * 3 + c]) * (255 - @as(u32, opacity)) + @as(u32, pixel[c]) * opacity) / 255);
            }
        };
    }
    fn drawParticle(self: *const Sprite, renderer: *render.Renderer, camera: render.Camera, p: @import("presentation.zig").Particle) void {
        const screen = camera.project(p.pos) orelse return;
        if (screen.x < -64 or screen.x > render.width + 64 or screen.y < -64 or screen.y > render.height + 64) return;
        const dim: usize = if (p.large) 32 else 16;
        const texture: []const u8 = if (p.large) &self.spark_large else &self.spark_small;
        const size: i32 = @intFromFloat(std.math.clamp(230 * @as(f32, if (p.large) 16 else 8) * p.scale / screen.z, 1, 64));
        const left = @as(i32, @intFromFloat(screen.x)) - @divTrunc(size, 2);
        const top = @as(i32, @intFromFloat(screen.y)) - @divTrunc(size, 2);
        for (0..@intCast(size)) |y| for (0..@intCast(size)) |x| {
            const sx = left + @as(i32, @intCast(x));
            const sy = top + @as(i32, @intCast(y));
            if (sx < 0 or sy < 0 or sx >= render.width or sy >= render.height) continue;
            const i = @as(usize, @intCast(sy)) * render.width + @as(usize, @intCast(sx));
            if (1 / screen.z < renderer.depth[i]) continue;
            const intensity = texture[(y * dim / @as(usize, @intCast(size))) * dim + x * dim / @as(usize, @intCast(size))];
            const alpha = @as(u32, intensity) * p.alpha / 255;
            for (0..3) |c| renderer.rgb[i * 3 + c] = @intCast((@as(u32, renderer.rgb[i * 3 + c]) * (255 - alpha) + @as(u32, p.color[c]) * alpha) / 255);
        };
    }
};
fn frameIndex(slip: i32) usize {
    return @min(frames.len - 1, @abs(slip) / 0x208);
}
test "rear-view frame bins match original spacing and clamp" {
    try std.testing.expectEqual(@as(usize, 0), frameIndex(519));
    try std.testing.expectEqual(@as(usize, 1), frameIndex(520));
    try std.testing.expectEqual(frameIndex(5200), frameIndex(-5200));
    try std.testing.expectEqual(@as(usize, 14), frameIndex(32768));
}

fn spinAngle(g: @import("game.zig").Game) i32 {
    return if (g.controller.spin_ticks > 0) @intFromFloat(@sin(@as(f32, @floatFromInt(g.controller.spin_ticks)) * 0.6) * 6000) else 0;
}
