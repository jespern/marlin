//! Deterministic demonstration driver; not original MK64 opponent AI.
const std = @import("std");
const game = @import("game.zig");
const course = @import("course.zig");
const render = @import("render.zig");
pub const Mode = enum { off, race, drift_demo };
pub const Driver = struct {
    mode: Mode = .off,
    demo_tick: usize = 0,

    pub fn input(self: *Driver, g: game.Game, track: *const course.Course) game.Input {
        if (g.paused or g.finished or self.mode == .off) return .{};
        if (self.mode == .drift_demo) {
            const tick = self.demo_tick;
            self.demo_tick += 1;
            if (tick < 90) return driftInput(tick, false);
        }
        return follow(g, track);
    }
};

pub fn follow(g: game.Game, track: *const course.Course) game.Input {
    const target = track.path[(g.nearest + 6) % track.path.len].pos.sub(g.pos);
    const angle = std.math.atan2(target.x, -target.z);
    const diff = @mod(angle - g.yaw + std.math.pi, 2 * std.math.pi) - std.math.pi;
    return .{ .accelerate = true, .left = diff < -0.02, .right = diff > 0.02 };
}

/// Fixed sequence: 20 ticks in, 25 out, 10 in, 25 out, 10 in.
/// Caller releases hop and recovers with ordinary steering after tick 89.
pub fn driftInput(tick: usize, right: bool) game.Input {
    if (tick >= 90) return .{ .accelerate = true };
    const outside = (tick >= 20 and tick < 45) or (tick >= 55 and tick < 80);
    const turn_right = if (outside) !right else right;
    return .{ .accelerate = true, .hop = true, .right = turn_right, .left = !turn_right };
}

/// A rolling entry on the course for a short, reproducible demonstration.
pub fn rollingStart(track: *const course.Course, start: usize) game.Game {
    var g = game.Game.init(track);
    g.pos = track.path[start].pos;
    g.yaw = render.Camera.along(track.path, @floatFromInt(start)).yaw;
    g.nearest = start;
    g.controller.throttle = 310;
    g.controller.velocity = .{ .x = @sin(g.yaw) * 5.52, .y = 0, .z = -@cos(g.yaw) * 5.52 };
    return g;
}

test "paused demonstration does not consume inputs" {
    var d = Driver{ .mode = .drift_demo };
    const g = game.Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0, .paused = true };
    const input = d.input(g, undefined);
    try std.testing.expect(!input.accelerate and !input.hop);
    try std.testing.expectEqual(@as(usize, 0), d.demo_tick);
}
