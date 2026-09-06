//! Normal single-player camera and drift particle presentation slice.
//! Camera equations: camera.c func_8001E45C/func_8001CCEC; original collision
//! volumes, camera shake and status-effect branches are still separate work.
const std = @import("std");
const Vec3 = @import("course.zig").Vec3;
const render = @import("render.zig");
const handling = @import("handling.zig");
const turn: f32 = 65536.0 / (2 * std.math.pi);
pub const Particle = struct {
    alive: bool = false,
    age: u8 = 0,
    pos: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    heading: f32 = 0,
    side: f32 = 0,
    scale: f32 = 0.35,
    alpha: u8 = 112,
    color: [3]u8 = .{ 255, 255, 255 },
    large: bool = false,
};
pub const State = struct {
    initialized: bool = false,
    angle: i16 = 0,
    offset: i16 = 0,
    eye: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    target: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    wheel: u16 = 0,
    ticks: u64 = 0,
    duration: u8 = 0,
    particles: [10]Particle = .{Particle{}} ** 10,
    next_particle: usize = 0,

    pub fn init(pos: Vec3, yaw: f32) State {
        const body = pos.add(.{ .x = 0, .y = 6, .z = 0 });
        const forward = Vec3{ .x = @sin(yaw), .y = 0, .z = -@cos(yaw) };
        return .{ .initialized = true, .angle = angleUnits(yaw), .eye = body.sub(forward.scale(50)).add(.{ .x = 0, .y = 9.5, .z = 0 }), .target = body.add(forward.scale(70)) };
    }
    pub fn tick(self: *State, pos: Vec3, yaw: f32, c: handling.Controller) void {
        if (!self.initialized) self.* = init(pos, yaw);
        self.ticks += 1;
        var step: i32 = 100;
        if (c.drift.drifting) {
            if (c.yaw_step == 0) self.offset = 0 else {
                step = 165 + @divTrunc(@as(i32, @intCast(@abs(c.yaw_step))), 2);
                const desired: i32 = @as(i32, if (c.yaw_step > 0) 1 else -1) * @as(i32, if (c.drift_outside) 0xb60 else 12 * 182);
                self.offset = @intFromFloat(@as(f32, @floatFromInt(self.offset)) - @as(f32, @floatFromInt(@as(i32, self.offset) - desired)) * 0.1);
            }
        } else {
            self.offset = @intFromFloat(@as(f32, @floatFromInt(self.offset)) - @as(f32, @floatFromInt(self.offset)) * 0.05);
            const delta = @as(i32, self.angle -% angleUnits(yaw));
            step = if (c.yaw_step == 0) 500 else if (@abs(delta) >= 70 * 182) 180 + @as(i32, @intCast(@abs(c.yaw_step))) else 165 + @divTrunc(@as(i32, @intCast(@abs(c.yaw_step))), 2);
        }
        const desired = angleUnits(yaw) +% self.offset;
        const delta: i32 = desired -% self.angle;
        self.angle +%= @intCast(std.math.clamp(delta, -step, step));
        const camera_yaw = @as(f32, @floatFromInt(self.angle)) / turn;
        const forward = Vec3{ .x = @sin(camera_yaw), .y = 0, .z = -@cos(camera_yaw) };
        const body = pos.add(.{ .x = 0, .y = 6 + c.drift.height, .z = 0 });
        const eye = body.sub(forward.scale(50)).add(.{ .x = 0, .y = 9.5, .z = 0 });
        const target = body.add(forward.scale(70));
        self.eye.x += (eye.x - self.eye.x) * 0.4;
        self.eye.z += (eye.z - self.eye.z) * 0.4;
        self.eye.y += (eye.y - self.eye.y) * @as(f32, if (c.speed() * 12 <= 5 and c.drift.hopping) 0.01 else 0.15);
        self.target.x += (target.x - self.target.x) * 0.4;
        self.target.z += (target.z - self.target.z) * 0.4;
        self.target.y += (target.y - self.target.y) * @as(f32, if (c.speed() * 12 <= 5 and c.drift.hopping) 0.02 else 0.5);
        // func_80026A48 is a render-side 30 Hz wheel palette clock.
        if (self.ticks % 2 == 0) {
            const kmh = c.speed() * (1 + c.force_loss) / 18 * 216;
            const rates = [_]u16{ 96, 128, 192, 256, 288, 384, 512, 544, 576 };
            if (kmh <= 1) self.wheel = 0 else {
                self.wheel += rates[@intFromFloat(std.math.clamp(kmh / 12, 0, 8))];
                if (self.wheel >= 0x400) self.wheel = 0;
            }
        }
        // Drift particle state: set_drift_particles / func_80063408.
        self.duration = if (c.drift.drifting) @min(100, self.duration + 1) else self.duration -| 1;
        for (&self.particles) |*p| if (p.alive) {
            const rear = pos.add(.{ .x = @cos(yaw) * p.side - @sin(yaw) * 5, .y = 0, .z = @sin(yaw) * p.side + @cos(yaw) * 5 });
            const distance = @as(f32, @floatFromInt(p.age)) * 7;
            p.pos.x = rear.x - @sin(p.heading) * distance;
            p.pos.z = rear.z + @cos(p.heading) * distance;
            p.pos.y += 1;
            p.age += 1;
            p.scale += 0.08;
            if (p.age >= 4) p.alpha -|= 16;
            if (p.age >= 8) p.alive = false;
        };
        if (c.drift.drifting and !c.drift.hopping and @abs(c.drift_slip) >= 7 * 182 and self.ticks % 3 == 0) {
            const side: f32 = if (c.drift_slip >= 0) -4 else 4;
            self.particles[self.next_particle] = .{ .alive = true, .heading = yaw, .side = side, .pos = pos.add(.{ .x = @cos(yaw) * side - @sin(yaw) * 5, .y = 2, .z = @sin(yaw) * side + @cos(yaw) * 5 }), .color = chargeColor(c.drift.charge), .large = self.duration >= 50 };
            self.next_particle = (self.next_particle + 1) % self.particles.len;
        }
    }
    pub fn camera(self: State) render.Camera {
        const d = self.target.sub(self.eye);
        return .{ .pos = self.eye, .yaw = std.math.atan2(d.x, -d.z), .pitch = std.math.atan2(d.y, @sqrt(d.x * d.x + d.z * d.z)) };
    }
};
pub fn angleUnits(yaw: f32) i16 {
    return @truncate(@as(i32, @intFromFloat(@round((@mod(yaw + std.math.pi, 2 * std.math.pi) - std.math.pi) * turn))));
}
pub fn chargeColor(charge: u8) [3]u8 {
    return if (charge == 0) .{ 255, 255, 255 } else if (charge == 1) .{ 255, 255, 0 } else .{ 255, 150, 0 };
}
test "camera follows wrapped angles and drift offset relaxes" {
    var s = State.init(.{ .x = 0, .y = 0, .z = 0 }, 3.13);
    var c = handling.Controller{};
    c.drift.drifting = true;
    c.yaw_step = 200;
    s.tick(.{ .x = 0, .y = 0, .z = 0 }, -3.13, c);
    try std.testing.expect(@abs(@as(i32, s.angle -% angleUnits(3.13))) <= 265);
    const offset = s.offset;
    c.drift.drifting = false;
    s.tick(.{ .x = 0, .y = 0, .z = 0 }, -3.13, c);
    try std.testing.expect(@abs(s.offset) < @abs(offset));
}
test "drift colors, particle expiry and stopped wheels" {
    try std.testing.expectEqual([3]u8{ 255, 150, 0 }, chargeColor(2));
    var s = State.init(.{ .x = 0, .y = 0, .z = 0 }, 0);
    var c = handling.Controller{};
    c.drift.drifting = true;
    c.drift_slip = 2000;
    for (0..3) |_| s.tick(.{ .x = 0, .y = 0, .z = 0 }, 0, c);
    try std.testing.expect(s.particles[0].alive);
    c.drift.drifting = false;
    for (0..8) |_| s.tick(.{ .x = 0, .y = 0, .z = 0 }, 0, c);
    for (s.particles) |p| try std.testing.expect(!p.alive);
    try std.testing.expectEqual(@as(u16, 0), s.wheel);
}

test "camera angles match compiled original C drift entry and recovery" {
    var s = State.init(.{ .x = 0, .y = 0, .z = 0 }, 3000 / turn);
    var c = handling.Controller{ .yaw_step = 265 };
    const checkpoints = [_]usize{ 0, 9, 10, 19 };
    const angles = [_]i16{ 3297, 5894, 5799, 5130 };
    const offsets = [_]i16{ 291, 1894, 1799, 1130 };
    var check: usize = 0;
    for (0..20) |t| {
        c.drift.drifting = t < 10;
        c.drift_outside = t < 10;
        s.tick(.{ .x = 0, .y = 0, .z = 0 }, 4000 / turn, c);
        if (t == checkpoints[check]) {
            try std.testing.expectEqual(angles[check], s.angle);
            try std.testing.expectEqual(offsets[check], s.offset);
            check += 1;
        }
    }
}
test "wheel palette uses original speed table at 30 Hz" {
    var s = State.init(.{ .x = 0, .y = 0, .z = 0 }, 0);
    const c = handling.Controller{ .velocity = .{ .x = 0, .y = 0, .z = -5.5 } };
    for ([_]u16{ 0, 384, 384, 768, 768, 0 }) |expected| {
        s.tick(.{ .x = 0, .y = 0, .z = 0 }, 0, c);
        try std.testing.expectEqual(expected, s.wheel);
    }
}
