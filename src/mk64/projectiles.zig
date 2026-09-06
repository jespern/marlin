//! Bounded item actors. Terrain response and hit recovery are prototype adapters.
const std = @import("std");
const game = @import("game.zig");
const Vec3 = @import("course.zig").Vec3;
pub const Kind = enum { banana, shell, red_shell };
pub const Actor = struct {
    active: bool = false,
    kind: Kind = .banana,
    pos: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    owner: usize = 0,
    grace: u8 = 30,
    life: u16 = 1800,
    bounces: u8 = 0,
    target: ?usize = null,
    seeking: bool = false,
    acquired: bool = false,
    nearest: usize = 0,
    launch_progress: i32 = 0,
};
pub const World = struct {
    shields: [8]?Vec3 = .{null} ** 8,
    blocked: [8]bool = .{false} ** 8,
    blocks: u32 = 0,
    actors: [32]Actor = .{Actor{}} ** 32,
    hits: u32 = 0,
    pub fn spawn(self: *World, kind: Kind, owner: usize, g: game.Game, backward: bool) bool {
        for (&self.actors) |*a| if (!a.active) {
            const speed: f32 = (if (backward) @as(f32, -1) else 1) * @as(f32, if (kind != .banana) 10 else if (backward) 2 else 6);
            a.* = .{ .active = true, .kind = kind, .owner = owner, .pos = g.pos.add(.{ .x = 0, .y = 3, .z = 0 }), .velocity = .{ .x = @sin(g.yaw) * speed, .y = if (kind == .banana and !backward) 1.6 else 0, .z = -@cos(g.yaw) * speed }, .life = if (kind != .banana) 600 else 1800, .seeking = kind == .red_shell and !backward, .nearest = g.nearest, .launch_progress = g.path_progress };
            return true;
        };
        return false;
    }
    pub fn tick(self: *World, track: *const @import("course.zig").Course, racers: [8]*game.Game) void {
        self.blocked = .{false} ** 8;
        for (&self.actors) |*a| {
            if (!a.active) continue;
            a.life -|= 1;
            a.grace -|= 1;
            if (a.life == 0) {
                a.active = false;
                continue;
            }
            if (a.seeking) guide(a, track, racers);
            if (!a.active) continue;
            if (a.kind == .banana) a.velocity.y -= 0.18;
            for (0..4) |_| {
                const next = a.pos.add(a.velocity.scale(0.25));
                if (game.wallHit(track, a.pos, next)) {
                    if (a.kind == .shell) {
                        a.velocity.x = -a.velocity.x;
                        a.velocity.z = -a.velocity.z;
                        a.bounces += 1;
                        if (a.bounces >= 6) a.active = false;
                    } else if (a.kind == .red_shell) {
                        a.active = false;
                    } else {
                        a.velocity.x = 0;
                        a.velocity.z = 0;
                    }
                    break;
                }
                if (game.floorAt(track, next, a.pos.y)) |floor| {
                    a.pos = next;
                    if (a.kind != .banana or a.pos.y <= floor.height + 3) {
                        a.pos.y = floor.height + 3;
                        a.velocity.y = 0;
                        if (a.kind == .banana) {
                            a.velocity.x *= 0.8;
                            a.velocity.z *= 0.8;
                        }
                    }
                } else {
                    a.active = false;
                    break;
                }
                // Interception precedes kart collision, so a rear guard absorbs
                // one shell rather than allowing damage in the same substep.
                if (a.kind != .banana) for (self.shields, 0..) |shield, id| {
                    if (id == a.owner and a.grace > 0) continue;
                    if (shield) |position| {
                        const d = position.sub(a.pos);
                        if (d.dot(d) < 9 * 9) {
                            self.shields[id] = null;
                            self.blocked[id] = true;
                            self.blocks += 1;
                            a.active = false;
                            break;
                        }
                    }
                };
                if (!a.active) break;
                for (racers, 0..) |g, id| {
                    if (id == a.owner and a.grace > 0) continue;
                    const body = g.pos.add(.{ .x = 0, .y = 3 + g.controller.drift.height, .z = 0 });
                    const d = body.sub(a.pos);
                    if (d.dot(d) < 8 * 8 and hit(g)) {
                        self.hits += 1;
                        a.active = false;
                        break;
                    }
                }
                if (!a.active) break;
            }
        }
    }
};
// Acquire once: nearest eligible kart ahead in course progress, within a local
// 600-unit cone. Lock is never transferred to another racer mid-flight.
fn acquire(a: *const Actor, racers: [8]*game.Game) ?usize {
    var best: f32 = 600 * 600;
    var result: ?usize = null;
    for (racers, 0..) |g, id| {
        if (id == a.owner or g.finished or g.controller.hit_immunity > 0 or g.path_progress < a.launch_progress or g.path_progress - a.launch_progress > 64) continue;
        const delta = g.pos.sub(a.pos);
        if (@abs(delta.y) > 20 or delta.dot(a.velocity) <= 0) continue;
        const distance = delta.dot(delta);
        if (distance < best) {
            best = distance;
            result = id;
        }
    }
    return result;
}
fn clearSight(track: *const @import("course.zig").Course, start: Vec3, end: Vec3) bool {
    const delta = end.sub(start);
    const steps: usize = @intFromFloat(@ceil(@max(delta.length() / 3, 1)));
    var previous = start;
    for (1..steps + 1) |i| {
        const next = start.add(delta.scale(@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps))));
        if (game.wallHit(track, previous, next)) return false;
        previous = next;
    }
    return true;
}
fn guide(a: *Actor, track: *const @import("course.zig").Course, racers: [8]*game.Game) void {
    if (!a.acquired) {
        a.target = acquire(a, racers);
        a.acquired = true;
    }
    const id = a.target orelse return;
    const target = racers[id];
    if (target.finished) {
        a.target = null;
        return;
    }
    var distance: f32 = std.math.inf(f32);
    const start = a.nearest;
    for (0..49) |offset| {
        const i = (start + track.path.len + offset - 24) % track.path.len;
        const d = track.path[i].pos.sub(a.pos).dot(track.path[i].pos.sub(a.pos));
        if (d < distance) {
            distance = d;
            a.nearest = i;
        }
    }
    const body = target.pos.add(.{ .x = 0, .y = 3, .z = 0 });
    const delta = body.sub(a.pos);
    const close = delta.dot(delta) < 100 * 100 and @abs(delta.y) < 12;
    if (close and delta.dot(a.velocity) < 0) {
        a.active = false;
        return;
    }
    const aim = if (close and clearSight(track, a.pos, body)) body else track.path[(a.nearest + 4) % track.path.len].pos;
    const direction = aim.sub(a.pos);
    const yaw = std.math.atan2(a.velocity.x, -a.velocity.z);
    const desired = std.math.atan2(direction.x, -direction.z);
    const diff = @mod(desired - yaw + std.math.pi, 2 * std.math.pi) - std.math.pi;
    const turned = yaw + std.math.clamp(diff, -0.055, 0.055);
    a.velocity.x = @sin(turned) * 10;
    a.velocity.z = -@cos(turned) * 10;
}
test "red shell locks ahead, excludes finished/immune karts, and backward has no homing" {
    const owner = game.Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0 };
    var ahead = owner;
    ahead.pos.z = -60;
    ahead.path_progress = 2;
    var behind = owner;
    behind.pos.z = 20;
    var finished = ahead;
    finished.finished = true;
    var w = World{};
    try std.testing.expect(w.spawn(.red_shell, 0, owner, false));
    try std.testing.expect(w.spawn(.red_shell, 0, owner, true));
    try std.testing.expect(w.actors[0].seeking and !w.actors[1].seeking);
    const racers = [8]*game.Game{ &behind, &ahead, &finished, &finished, &finished, &finished, &finished, &finished };
    try std.testing.expectEqual(@as(?usize, 1), acquire(&w.actors[0], racers));
    ahead.controller.hit_immunity = 1;
    try std.testing.expectEqual(@as(?usize, null), acquire(&w.actors[0], racers));
}
pub fn hit(g: *game.Game) bool {
    if (g.finished or g.paused or g.controller.hit_immunity > 0) return false;
    g.controller.spin_ticks = 45;
    g.controller.hit_immunity = 150;
    g.controller.velocity = g.controller.velocity.scale(0.45);
    g.controller.throttle *= 0.45;
    g.controller.mushroom_ticks = 0;
    g.controller.mushroom_force = 0;
    g.controller.drift = .{};
    return true;
}
test "hit grants recovery immunity and cancels boosts without moving kart" {
    var g = game.Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0 };
    g.controller.mushroom_ticks = 80;
    try std.testing.expect(hit(&g));
    try std.testing.expect(!hit(&g));
    try std.testing.expectEqual(@as(u8, 0), g.controller.mushroom_ticks);
    for (0..150) |_| g.controller.tick(&g.yaw, .{ .accelerate = true }, .{});
    try std.testing.expectEqual(@as(u8, 0), g.controller.spin_ticks);
    try std.testing.expect(hit(&g));
}
test "forward and backward launch directions and bounded actor capacity" {
    var w = World{};
    const g = game.Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0 };
    try std.testing.expect(w.spawn(.shell, 0, g, false));
    try std.testing.expect(w.spawn(.shell, 0, g, true));
    try std.testing.expect(w.actors[0].velocity.z < 0 and w.actors[1].velocity.z > 0);
    for (0..30) |_| try std.testing.expect(w.spawn(.banana, 0, g, true));
    try std.testing.expect(!w.spawn(.shell, 0, g, false));
}
test "red shell breaks at wall where green shell bounces" {
    const course = @import("course.zig");
    const vertices = [3]course.Vertex{
        .{ .pos = .{ .x = -100, .y = -20, .z = 5 }, .u = 0, .v = 0, .color = .{ 255, 255, 255 }, .flag = 0 },
        .{ .pos = .{ .x = 100, .y = -20, .z = 5 }, .u = 0, .v = 0, .color = .{ 255, 255, 255 }, .flag = 0 },
        .{ .pos = .{ .x = 0, .y = 20, .z = 5 }, .u = 0, .v = 0, .color = .{ 255, 255, 255 }, .flag = 0 },
    };
    var triangles = [_]course.Triangle{.{ .vertices = vertices, .style = .{} }};
    var track: course.Course = undefined;
    track.collision = &triangles;
    var g = game.Game{ .pos = .{ .x = 0, .y = 0, .z = 0 }, .yaw = 0, .finished = true };
    var world = World{};
    try std.testing.expect(world.spawn(.red_shell, 0, g, true));
    try std.testing.expect(world.spawn(.shell, 0, g, true));
    world.tick(&track, .{ &g, &g, &g, &g, &g, &g, &g, &g });
    try std.testing.expect(!world.actors[0].active);
    try std.testing.expect(world.actors[1].active and world.actors[1].bounces == 1);
}
