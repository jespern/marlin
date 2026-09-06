//! Race harness around the ported grounded controller. Contact resolution,
//! camera and lap tracking remain adapters; see handling.zig for fidelity limits.
const std = @import("std");
const course = @import("course.zig");
const render = @import("render.zig");
const Vec3 = course.Vec3;
const handling = @import("handling.zig");
pub const Input = handling.Input;
pub const tick_hz = 60;
pub const Game = struct {
    pos: Vec3,
    yaw: f32,
    speed: f32 = 0,
    controller: handling.Controller = .{},
    presentation: @import("presentation.zig").State = .{},
    nearest: usize = 0,
    path_progress: i32 = 0,
    laps: u8 = 0,
    ticks: u64 = 0,
    finished: bool = false,
    time_trial: bool = false,
    paused: bool = false,

    pub fn init(track: *const course.Course) Game {
        const cam = render.Camera.along(track.path, 0);
        return .{ .pos = track.path[0].pos, .yaw = cam.yaw };
    }

    /// Fixed 60 Hz. Geometry-based floor/wall checks; no centerline steering constraint.
    pub fn tick(self: *Game, track: *const course.Course, input: Input) void {
        if (self.paused or self.finished) return;
        self.ticks += 1;
        const contact = sampleContact(track, self.pos, self.yaw);
        self.controller.tick(&self.yaw, input, contact);
        for (0..4) |_| {
            const step = self.controller.velocity.scale(0.25);
            const next = self.pos.add(step);
            if (floorAt(track, next, self.pos.y)) |floor| {
                if (!wallHit(track, self.pos, next)) self.pos = .{ .x = next.x, .y = floor.height, .z = next.z } else self.controller.velocity = self.controller.velocity.scale(0.75);
            } else self.controller.velocity = self.controller.velocity.scale(0.75);
        }
        self.speed = self.controller.speed();
        self.presentation.tick(self.pos, self.yaw, self.controller);
        // Mesh adapter for the original camera collision correction: shorten
        // the sight line when a wall obstructs it, then keep the eye above ground.
        const body = self.pos.add(.{ .x = 0, .y = 6 + self.controller.drift.height, .z = 0 });
        const camera_delta = self.presentation.eye.sub(body);
        var clear = body;
        for (1..17) |sample| {
            const candidate = body.add(camera_delta.scale(@as(f32, @floatFromInt(sample)) / 16));
            if (wallHit(track, clear.sub(.{ .x = 0, .y = 6, .z = 0 }), candidate.sub(.{ .x = 0, .y = 6, .z = 0 }))) {
                self.presentation.eye = clear;
                break;
            }
            clear = candidate;
        }
        if (floorAt(track, self.presentation.eye, self.pos.y)) |floor| {
            self.presentation.eye.y = @max(self.presentation.eye.y, floor.height + 3);
        }
        var best: f32 = std.math.inf(f32);
        var nearest = self.nearest;
        // Keep path tracking local so nearby sections above a tunnel cannot steal progress.
        for (0..49) |offset| {
            const i = (self.nearest + track.path.len + offset - 24) % track.path.len;
            const p = track.path[i];
            const delta = p.pos.sub(self.pos);
            const distance = delta.dot(delta);
            if (distance < best) {
                best = distance;
                nearest = i;
            }
        }
        self.advancePath(nearest, track.path.len);
    }

    fn advancePath(self: *Game, nearest: usize, count: usize) void {
        const length: i32 = @intCast(count);
        var delta = @as(i32, @intCast(nearest)) - @as(i32, @intCast(self.nearest));
        if (delta > @divTrunc(length, 2)) delta -= length;
        if (delta < -@divTrunc(length, 2)) delta += length;
        // A discontinuous jump is not racing progress. Backtracking subtracts progress.
        if (@abs(delta) <= 30) self.path_progress += delta;
        self.nearest = nearest;
        self.laps = @intCast(std.math.clamp(@divFloor(self.path_progress, length), 0, 3));
        if (self.laps == 3 and !self.time_trial) self.finished = true;
    }

    pub fn camera(self: Game) render.Camera {
        const state = if (self.presentation.initialized) self.presentation else @import("presentation.zig").State.init(self.pos, self.yaw);
        return state.camera();
    }
    pub fn spriteAngle(self: Game) i32 {
        return @as(i32, @import("presentation.zig").angleUnits(self.yaw - self.camera().yaw)) + self.controller.drift_slip;
    }
};

pub const Floor = struct { height: f32, surface: u8, normal: Vec3 };
pub fn floorAt(track: *const course.Course, p: Vec3, previous_y: f32) ?Floor {
    var found: ?Floor = null;
    var best: f32 = 24;
    for (track.collision) |tri| {
        const a = tri.vertices[0].pos;
        const b = tri.vertices[1].pos;
        const c = tri.vertices[2].pos;
        const det = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z);
        if (@abs(det) < 1) continue;
        const u = ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.z - c.z)) / det;
        const v = ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.z - c.z)) / det;
        if (u < -0.001 or v < -0.001 or u + v > 1.001) continue;
        const y = u * a.y + v * b.y + (1 - u - v) * c.y;
        const distance = @abs(y - previous_y);
        if (distance < best) {
            const ab = b.sub(a);
            const ac = c.sub(a);
            var normal = Vec3{ .x = ab.y * ac.z - ab.z * ac.y, .y = ab.z * ac.x - ab.x * ac.z, .z = ab.x * ac.y - ab.y * ac.x };
            if (normal.y < 0) normal = normal.scale(-1);
            found = .{ .height = y, .surface = tri.surface, .normal = normal };
            best = distance;
        }
    }
    return found;
}

pub fn sampleContact(track: *const course.Course, pos: Vec3, yaw: f32) handling.Contact {
    const forward = Vec3{ .x = @sin(yaw), .y = 0, .z = -@cos(yaw) };
    const right = Vec3{ .x = @cos(yaw), .y = 0, .z = @sin(yaw) };
    var contact = handling.Contact{};
    const corners = [4][2]f32{ .{ 4, -5 }, .{ -4, -5 }, .{ 4, 5 }, .{ -4, 5 } };
    for (corners, 0..) |corner, i| {
        const p = pos.add(right.scale(corner[0])).add(forward.scale(corner[1]));
        if (floorAt(track, p, pos.y)) |floor| contact.surfaces[i] = floor.surface;
    }
    if (floorAt(track, pos, pos.y)) |floor| {
        const downhill = std.math.atan2(floor.normal.x * forward.x + floor.normal.z * forward.z, floor.normal.y) * 180 / std.math.pi;
        contact.slope_degrees = @intFromFloat(std.math.clamp(downhill, -45, 45));
    }
    return contact;
}

pub fn wallHit(track: *const course.Course, previous: Vec3, p: Vec3) bool {
    for (track.collision) |tri| {
        const a = tri.vertices[0].pos;
        const b = tri.vertices[1].pos;
        const c = tri.vertices[2].pos;
        if (p.y + 3 > @max(a.y, @max(b.y, c.y)) or p.y + 8 < @min(a.y, @min(b.y, c.y))) continue;
        const ab = b.sub(a);
        const ac = c.sub(a);
        const normal = Vec3{ .x = ab.y * ac.z - ab.z * ac.y, .y = ab.z * ac.x - ab.x * ac.z, .z = ab.x * ac.y - ab.y * ac.x };
        const normal_length = normal.length();
        if (normal_length < 1 or @abs(normal.y) > normal_length * 0.25) continue;
        const points = [3]Vec3{ a, b, c };
        for (0..3) |i| {
            const s = points[i];
            const e = points[(i + 1) % 3];
            const dx = e.x - s.x;
            const dz = e.z - s.z;
            const length_sq = dx * dx + dz * dz;
            if (length_sq < 1) continue;
            const t = std.math.clamp(((p.x - s.x) * dx + (p.z - s.z) * dz) / length_sq, 0, 1);
            const qx = s.x + t * dx;
            const qz = s.z + t * dz;
            const distance = (p.x - qx) * (p.x - qx) + (p.z - qz) * (p.z - qz);
            const old_distance = (previous.x - qx) * (previous.x - qx) + (previous.z - qz) * (previous.z - qz);
            if (distance < 16 and distance < old_distance) return true;
        }
    }
    return false;
}

test "pause and finish freeze the drive harness" {
    var g = Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0, .paused = true };
    g.tick(undefined, .{ .accelerate = true });
    try std.testing.expectEqual(@as(u64, 0), g.ticks);
    g.paused = false;
    g.finished = true;
    g.tick(undefined, .{ .accelerate = true });
    try std.testing.expectEqual(@as(f32, 0), g.speed);
}

test "finish-line oscillation and reverse travel cannot earn a lap" {
    var game = Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0 };
    for (0..100) |_| {
        game.advancePath(729, 730);
        game.advancePath(0, 730);
    }
    try std.testing.expectEqual(@as(u8, 0), game.laps);
    for (0..3) |_| for (1..731) |i| {
        game.advancePath(i % 730, 730);
    };
    try std.testing.expect(game.finished);
    try std.testing.expectEqual(@as(u8, 3), game.laps);
}
