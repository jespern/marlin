//! Time-trial harness. Uses the ROM start-Z plane and original +/-20 path-point
//! finish region; ordered quarter-path gates are an additional harness safeguard.
const std = @import("std");
const game = @import("game.zig");
const course = @import("course.zig");
pub const Phase = enum { countdown, racing, finished, practice };
pub const Trial = struct {
    phase: Phase = .countdown,
    countdown: u16 = 180,
    elapsed: u32 = 0,
    lap_start: u32 = 0,
    splits: [3]u32 = .{ 0, 0, 0 },
    laps: u8 = 0,
    gate: u8 = 1,
    lap_progress: i32 = 0,
    assisted: bool = false,
    valid: bool = true,
    saved: bool = false,
    settled: bool = false,
    save_failed: bool = false,

    pub fn grid(track: *const course.Course) game.Game {
        var g = game.Game.init(track);
        g.pos = g.pos.add(.{ .x = -@sin(g.yaw) * 20, .y = 0, .z = @cos(g.yaw) * 20 });
        g.time_trial = true;
        return g;
    }
    pub fn practice() Trial {
        return .{ .phase = .practice, .assisted = true };
    }
    pub fn tick(self: *Trial, g: *game.Game, track: *const course.Course, input: game.Input, auto: bool) void {
        if (auto) self.assisted = true;
        if (g.paused or self.phase == .finished) return;
        if (self.phase == .practice) {
            g.tick(track, input);
            return;
        }
        if (self.phase == .countdown) {
            self.countdown -= 1;
            if (self.countdown == 0) self.phase = .racing;
            return;
        }
        const previous = g.pos;
        const previous_index = g.nearest;
        self.elapsed += 1;
        g.tick(track, input);
        self.progress(g, track.path.len, previous_index, previous.z, track.path[0].pos.z);
    }
    fn progress(self: *Trial, g: *game.Game, count: usize, previous_index: usize, previous_z: f32, start_z: f32) void {
        const length: @TypeOf(g.path_progress) = @intCast(count);
        var delta = @as(i32, @intCast(g.nearest)) - @as(i32, @intCast(previous_index));
        if (delta > @divTrunc(length, 2)) delta -= length;
        if (delta < -@divTrunc(length, 2)) delta += length;
        if (@abs(delta) > 30) {
            self.valid = false;
            return;
        }
        if (delta > 0 and self.gate <= 3) {
            const target = count * self.gate / 4;
            if (previous_index < target and g.nearest >= target) self.gate += 1;
        }
        const at_line = g.nearest < 20 or g.nearest > count - 20;
        const crossed = previous_z > start_z and g.pos.z <= start_z;
        if (at_line and crossed and self.gate == 4 and g.path_progress - self.lap_progress >= length - 20) {
            self.splits[self.laps] = self.elapsed - self.lap_start;
            self.lap_start = self.elapsed;
            self.lap_progress = g.path_progress;
            self.laps += 1;
            self.gate = 1;
            if (self.laps == 3) {
                self.phase = .finished;
                g.finished = true;
            }
        }
    }
    pub fn eligible(self: Trial) bool {
        return self.phase == .finished and self.valid and !self.assisted;
    }
};
test "countdown holds car and race clock; pause freezes countdown" {
    var t = Trial{};
    var g = game.Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0 };
    g.paused = true;
    t.tick(&g, undefined, .{ .accelerate = true }, false);
    try std.testing.expectEqual(@as(u16, 180), t.countdown);
    g.paused = false;
    for (0..180) |_| t.tick(&g, undefined, .{ .accelerate = true }, false);
    try std.testing.expectEqual(Phase.racing, t.phase);
    try std.testing.expectEqual(@as(u32, 0), t.elapsed);
    try std.testing.expectEqual(@as(f32, 0), g.speed);
}
test "finish crossing requires full ordered circuit and disqualifies assistance" {
    var t = Trial{ .phase = .racing };
    var g = game.Game{ .pos = .{ .x = 0, .y = 0, .z = -1 }, .yaw = 0 };
    for (0..5) |_| {
        g.nearest = 0;
        t.progress(&g, 100, 99, 1, 0);
    }
    try std.testing.expectEqual(@as(u8, 0), t.laps);
    for (0..3) |lap| {
        for ([_]usize{ 25, 50, 75 }) |point| {
            g.nearest = point;
            t.progress(&g, 100, point - 1, -1, 0);
        }
        g.nearest = 0;
        g.path_progress = @intCast((lap + 1) * 100);
        t.elapsed = @intCast((lap + 1) * 1000);
        t.progress(&g, 100, 99, 1, 0);
    }
    try std.testing.expectEqual([3]u32{ 1000, 1000, 1000 }, t.splits);
    try std.testing.expect(t.eligible());
    t.assisted = true;
    try std.testing.expect(!t.eligible());
}
