//! Eight-kart race adapter, deterministic input-driven CPUs and equal-mass contacts.
//! All racers currently use the Mario controller; original character stats/AI pending.
const std = @import("std");
const Game = @import("game.zig").Game;
const Trial = @import("trial.zig").Trial;
const Course = @import("course.zig").Course;
const Class = @import("engine.zig").Class;
const auto = @import("autopilot.zig");
const Profile = struct { pace: f32, delay: u32, lane: f32, caution: f32, drift_every: i32 };
// Luigi/Yoshi contest the front; Peach/DK midfield; Wario/Bowser/Toad forgiving.
// These affect decisions only, never controller stats or position.
const profiles = [_]Profile{
    .{ .pace = 0.985, .delay = 8, .lane = -14, .caution = 0.01, .drift_every = 2 },
    .{ .pace = 0.965, .delay = 17, .lane = 10, .caution = 0.02, .drift_every = 3 },
    .{ .pace = 0.86, .delay = 48, .lane = 0, .caution = 0.08, .drift_every = 0 },
    .{ .pace = 0.925, .delay = 28, .lane = -7, .caution = 0.04, .drift_every = 0 },
    .{ .pace = 0.90, .delay = 36, .lane = 15, .caution = 0.06, .drift_every = 0 },
    .{ .pace = 0.945, .delay = 22, .lane = 5, .caution = 0.03, .drift_every = 0 },
    .{ .pace = 0.88, .delay = 42, .lane = -16, .caution = 0.07, .drift_every = 0 },
};
pub const Race = struct {
    items: @import("items.zig").Items = .{},
    opponents: [7]Game,
    trials: [7]Trial = .{Trial{}} ** 7,
    drift_ticks: [7]?u8 = .{null} ** 7,
    drift_laps: [7]i32 = .{-1} ** 7,
    finish_order: [8]u8 = .{0} ** 8,
    finish_count: u8 = 0,
    finish_place: [8]u8 = .{0} ** 8,
    contacts: u32 = 0,
    boosts: u32 = 0,
    pub fn init(track: *const Course, engine: Class, player: *Game) Race {
        var self: Race = undefined;
        self = .{ .opponents = undefined };
        for (0..8) |slot| {
            var g = Trial.grid(track);
            // Player starts last; two columns with room for the kart contact diameter.
            const row = slot / 2;
            const side: f32 = if (slot % 2 == 0) -12 else 12;
            g.pos.x += @cos(g.yaw) * side - @sin(g.yaw) * (@as(f32, @floatFromInt(row)) * 22 + @as(f32, @floatFromInt(slot % 2)) * 8);
            g.pos.z += @sin(g.yaw) * side + @cos(g.yaw) * (@as(f32, @floatFromInt(row)) * 22 + @as(f32, @floatFromInt(slot % 2)) * 8);
            g.controller.engine = engine;
            g.controller.top_speed = engine.top();
            if (slot == 7) player.* = g else self.opponents[slot] = g;
        }
        return self;
    }
    pub fn tick(self: *Race, player: *Game, trial: Trial, track: *const Course) void {
        if (player.paused) return;
        var inputs: [7]@import("game.zig").Input = undefined;
        for (self.opponents, 0..) |g, i| inputs[i] = self.input(i, g, player.*, track);
        for (&self.opponents, &self.trials, 0..) |*g, *t, i| {
            const controls = inputs[i];
            const boosting = g.controller.drift.turbo_ticks > 0;
            t.tick(g, track, controls, true);
            if (!boosting and g.controller.drift.turbo_ticks > 0) self.boosts += 1;
        }
        if (trial.phase == .racing) {
            self.items.tick();
            var racers: [8]*Game = undefined;
            racers[0] = player;
            for (&self.opponents, 0..) |*g, i| racers[i + 1] = g;
            self.items.prepareDefense(track, racers);
            self.items.world.tick(track, racers);
            self.items.finishDefense();
            self.items.collect(0, player.*);
            for (&self.opponents, 0..) |*g, i| {
                self.items.collect(i + 1, g.*);
                self.items.autoUse(i + 1, g);
            }
            for (&self.opponents, 0..) |*a, i| {
                if (contact(player, a)) self.contacts += 1;
                for (self.opponents[i + 1 ..]) |*b| if (contact(a, b)) {
                    self.contacts += 1;
                };
            }
        }
        // Same-tick ties use stable character index, including Mario.
        if (trial.phase == .finished) self.finish(0);
        for (self.trials, 0..) |t, i| if (t.phase == .finished) {
            self.finish(i + 1);
        };
    }
    fn finish(self: *Race, id: usize) void {
        if (self.finish_place[id] != 0) return;
        self.finish_order[self.finish_count] = @intCast(id);
        self.finish_count += 1;
        self.finish_place[id] = self.finish_count;
    }
    fn input(self: *Race, i: usize, g: Game, player: Game, track: *const Course) @import("game.zig").Input {
        if (g.finished or self.trials[i].phase != .racing) return .{};
        const profile = profiles[i];
        if (self.trials[i].elapsed < profile.delay) return .{};
        // Known asphalt mini-turbo entry, only in the validated 100cc speed window.
        const lap = @divFloor(g.path_progress, @as(i32, @intCast(track.path.len)));
        if (profile.drift_every > 0 and @mod(lap, @max(profile.drift_every, 1)) == 0 and g.controller.engine == .cc100 and g.nearest >= 460 and g.nearest <= 462 and g.speed > 4.7 and g.speed < 5.8 and self.drift_laps[i] != lap) {
            self.drift_laps[i] = lap;
            self.drift_ticks[i] = 0;
        }
        if (self.drift_ticks[i]) |drift_tick| {
            if (drift_tick < 90) {
                self.drift_ticks[i] = drift_tick + 1;
                return auto.driftInput(drift_tick, false);
            }
            self.drift_ticks[i] = null;
        }
        // Slightly different racing lines allow passing without invisible speed bonuses.
        const ahead = (g.nearest + 6 + i % 2) % track.path.len;
        const p = track.path[ahead].pos;
        const tangent = track.path[(ahead + 1) % track.path.len].pos.sub(p);
        const length = @sqrt(tangent.x * tangent.x + tangent.z * tangent.z);
        var lane = profile.lane;
        var crowded = false;
        // Move to a passing line before contact, and lift if still too close.
        for (0..8) |id| {
            if (id == i + 1) continue;
            const other = if (id == 0) player else self.opponents[id - 1];
            if (other.finished or @abs(other.pos.y - g.pos.y) > 6) continue;
            const delta = other.pos.sub(g.pos);
            const forward = delta.x * @sin(g.yaw) - delta.z * @cos(g.yaw);
            const lateral = delta.x * @cos(g.yaw) + delta.z * @sin(g.yaw);
            if (forward > 0 and forward < 48 and @abs(lateral) < 13) {
                lane = if (lateral > 0 or (lateral == 0 and i % 2 == 0)) -22 else 22;
                if (forward < 20) crowded = true;
                break;
            }
        }
        const target = p.add(.{ .x = -tangent.z / @max(length, 1) * lane, .y = 0, .z = tangent.x / @max(length, 1) * lane }).sub(g.pos);
        const diff = @mod(std.math.atan2(target.x, -target.z) - g.yaw + std.math.pi, 2 * std.math.pi) - std.math.pi;
        const corner_lift: f32 = if (@abs(diff) > 0.08) profile.caution else 0;
        const desired = g.controller.top_speed * (profile.pace - corner_lift);
        return .{ .accelerate = !crowded and g.controller.throttle < desired, .left = diff < -0.02, .right = diff > 0.02 };
    }
    pub fn order(self: *const Race, player: Game, track: *const Course) [8]u8 {
        var ids = [8]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
        for (0..8) |i| for (i + 1..8) |j| {
            const a = ids[i];
            const b = ids[j];
            const ap = self.finish_place[a];
            const bp = self.finish_place[b];
            const swap = if (ap != 0 or bp != 0) bp != 0 and (ap == 0 or bp < ap) else progress(if (b == 0) player else self.opponents[b - 1], track) > progress(if (a == 0) player else self.opponents[a - 1], track);
            if (swap) std.mem.swap(u8, &ids[i], &ids[j]);
        };
        return ids;
    }
    pub fn place(self: *const Race, player: Game, track: *const Course) usize {
        for (self.order(player, track), 0..) |id, i| if (id == 0) return i + 1;
        unreachable;
    }
};
fn progress(g: Game, track: *const Course) f32 {
    const p = track.path[g.nearest].pos;
    const d = track.path[(g.nearest + 1) % track.path.len].pos.sub(p);
    return @as(f32, @floatFromInt(g.path_progress)) + g.pos.sub(p).dot(d) / @max(d.dot(d), 1);
}
fn contact(a: *Game, b: *Game) bool {
    if (a.finished or b.finished or @abs(a.pos.y - b.pos.y) > 6 or @abs(a.controller.drift.height - b.controller.drift.height) > 6) return false;
    const delta = b.pos.sub(a.pos);
    const distance = @sqrt(delta.x * delta.x + delta.z * delta.z);
    if (distance >= 11) return false;
    const normal = if (distance > 0.001) delta.scale(1 / distance) else @import("course.zig").Vec3{ .x = 1, .y = 0, .z = 0 };
    const relative = b.controller.velocity.sub(a.controller.velocity).dot(normal);
    const impulse = @min(1.5, @max(0, -relative * 0.55) + (11 - distance) * 0.08);
    // Velocity-only separation: the next Game.tick checks floor/walls before moving.
    a.controller.velocity = a.controller.velocity.sub(normal.scale(impulse));
    b.controller.velocity = b.controller.velocity.add(normal.scale(impulse));
    return true;
}
test "kart contact separates equal masses without teleporting through terrain" {
    var a = Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0 };
    var b = Game{ .pos = .{ .x = 8, .y = 0, .z = 0 }, .yaw = 0 };
    try std.testing.expect(contact(&a, &b));
    try std.testing.expect(a.controller.velocity.x < 0 and b.controller.velocity.x > 0);
    try std.testing.expectEqual(@as(f32, 0), a.controller.velocity.x + b.controller.velocity.x);
    try std.testing.expectEqual(@as(f32, 8), b.pos.x);
    b.finished = true;
    try std.testing.expect(!contact(&a, &b));
}
test "finish places are stable and only assigned once" {
    var r = Race{ .opponents = undefined };
    r.finish(3);
    r.finish(0);
    r.finish(3);
    try std.testing.expectEqual(@as(u8, 2), r.finish_count);
    try std.testing.expectEqual(@as(u8, 1), r.finish_place[3]);
    try std.testing.expectEqual(@as(u8, 2), r.finish_place[0]);
}
