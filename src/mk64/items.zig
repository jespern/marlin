//! Race-only roulette, four-item inventory and shared box respawns.
const std = @import("std");
const Game = @import("game.zig").Game;
pub const positions = @import("item_positions.zig").positions;
pub const Kind = enum { mushroom, banana, shell, red_shell };
pub const Items = struct {
    trailing: [8]bool = .{false} ** 8,
    armed: [8]bool = .{false} ** 8,
    block_flash: [8]u8 = .{0} ** 8,
    use_flash: [8]u8 = .{0} ** 8,
    backward: [8]bool = .{false} ** 8,
    kind: [8]Kind = .{.mushroom} ** 8,
    roulette: [8]u8 = .{0} ** 8,
    random: u32 = 0x64c0ffee,
    world: @import("projectiles.zig").World = .{},
    held: [8]bool = .{false} ** 8,
    age: [8]u16 = .{0} ** 8,
    cooldown: [positions.len]u16 = .{0} ** positions.len,
    pickups: u32 = 0,
    uses: u32 = 0,
    pub fn tick(self: *Items) void {
        for (&self.block_flash) |*ticks| ticks.* -|= 1;
        for (&self.use_flash) |*ticks| ticks.* -|= 1;
        for (&self.roulette) |*ticks| ticks.* -|= 1;
        for (&self.cooldown) |*ticks| ticks.* -|= 1;
        for (&self.age, self.held) |*ticks, held| if (held) {
            ticks.* +|= 1;
        };
    }
    pub fn collect(self: *Items, id: usize, g: Game) void {
        if (g.finished or self.held[id]) return;
        for (positions, &self.cooldown) |p, *cooldown| {
            if (cooldown.* != 0) continue;
            const d = p.sub(g.pos);
            if (@abs(d.y) < 12 and d.x * d.x + d.z * d.z < 14 * 14) {
                self.held[id] = true;
                self.random ^= self.random << 13;
                self.random ^= self.random >> 17;
                self.random ^= self.random << 5;
                const roll = self.random % 20;
                self.kind[id] = if (roll < 10) .mushroom else if (roll < 15) .banana else if (roll < 18) .shell else .red_shell;
                self.roulette[id] = 45;
                self.age[id] = 0;
                cooldown.* = 180;
                self.pickups += 1;
                return;
            }
        }
    }
    pub fn use(self: *Items, id: usize, g: *Game) void {
        self.useDirected(id, g, false);
    }
    pub fn useDirected(self: *Items, id: usize, g: *Game, backward: bool) void {
        if (!self.held[id] or self.roulette[id] > 0 or g.paused or g.finished or g.controller.spin_ticks > 0) return;
        switch (self.kind[id]) {
            .mushroom => {
                if (g.controller.mushroom_ticks > 0 or g.controller.mushroom_force > 1) return;
                g.controller.mushroom_ticks = 80;
            },
            .banana, .shell, .red_shell => {
                if (!self.world.spawn(if (self.kind[id] == .banana) .banana else if (self.kind[id] == .shell) .shell else .red_shell, id, g.*, backward)) return;
            },
        }
        self.cancelHold(id);
        self.use_flash[id] = 12;
        self.backward[id] = backward;
        self.held[id] = false;
        self.uses += 1;
    }
    pub fn beginHold(self: *Items, id: usize, g: Game) void {
        if (g.paused or g.finished or g.controller.spin_ticks > 0 or !self.held[id] or self.roulette[id] > 0) return;
        self.armed[id] = true;
        self.trailing[id] = self.kind[id] != .mushroom;
    }
    pub fn releaseHold(self: *Items, id: usize, g: *Game, backward: bool) void {
        const use_item = self.armed[id];
        self.cancelHold(id);
        if (use_item) self.useDirected(id, g, backward);
    }
    pub fn cancelHold(self: *Items, id: usize) void {
        self.armed[id] = false;
        self.trailing[id] = false;
        self.world.shields[id] = null;
    }
    pub fn prepareDefense(self: *Items, track: *const @import("course.zig").Course, racers: [8]*Game) void {
        self.world.shields = .{null} ** 8;
        for (racers, 0..) |g, id| {
            if (!self.held[id] or g.finished or g.controller.spin_ticks > 0) {
                self.cancelHold(id);
                continue;
            }
            if (!self.trailing[id] or g.paused) continue;
            const behind = g.pos.add(.{ .x = -@sin(g.yaw) * 14, .y = 0, .z = @cos(g.yaw) * 14 });
            var previous = g.pos;
            var clear = true;
            for (1..6) |step| {
                const point = g.pos.add(behind.sub(g.pos).scale(@as(f32, @floatFromInt(step)) / 5));
                if (@import("game.zig").wallHit(track, previous, point)) {
                    clear = false;
                    break;
                }
                previous = point;
            }
            if (!clear) continue;
            if (@import("game.zig").floorAt(track, behind, g.pos.y)) |floor| self.world.shields[id] = .{ .x = behind.x, .y = floor.height + 3 + g.controller.drift.height, .z = behind.z };
        }
    }
    pub fn finishDefense(self: *Items) void {
        for (self.world.blocked, 0..) |blocked, id| if (blocked) {
            self.held[id] = false;
            self.cancelHold(id);
            self.block_flash[id] = 45;
        };
    }
    pub fn incoming(self: *const Items, id: usize, g: Game) bool {
        if (g.finished) return false;
        for (self.world.actors) |actor| {
            if (!actor.active or actor.kind != .red_shell or actor.target != id) continue;
            const delta = actor.pos.sub(g.pos);
            if (delta.dot(delta) < 350 * 350 and @abs(delta.y) < 20) return true;
        }
        return false;
    }
    pub fn autoUse(self: *Items, id: usize, g: *Game) void {
        if (g.paused or g.finished) return;
        if (id <= 2 and self.held[id] and self.kind[id] != .mushroom and self.roulette[id] == 0 and self.age[id] > 90 + id * 30 and self.incoming(id, g.*)) {
            self.beginHold(id, g.*);
            return;
        }
        if (self.trailing[id]) self.cancelHold(id);
        // Weaker drivers wait longer; no perfect instantaneous chain boosts.
        if (self.age[id] < (if (self.kind[id] == .mushroom) @as(usize, 60) else if (self.kind[id] == .red_shell) @as(usize, 240) else 150) + id * 30 or g.controller.drift.drifting or g.controller.drift.hopping or @abs(g.controller.yaw_step) > 25 or g.speed < 2) return;
        self.useDirected(id, g, self.kind[id] == .banana);
    }
};
test "box inventory cannot stack; respawn and consumption are bounded" {
    var items = Items{};
    var g = Game{ .pos = positions[0], .yaw = 0 };
    items.collect(0, g);
    items.collect(0, g);
    try std.testing.expectEqual(@as(u32, 1), items.pickups);
    items.use(0, &g);
    try std.testing.expectEqual(@as(u32, 0), items.uses);
    for (0..45) |_| items.tick();
    items.kind[0] = .mushroom;
    g.paused = true;
    items.use(0, &g);
    try std.testing.expect(items.held[0]);
    g.paused = false;
    items.use(0, &g);
    items.use(0, &g);
    try std.testing.expectEqual(@as(u32, 1), items.uses);
    try std.testing.expectEqual(@as(u8, 80), g.controller.mushroom_ticks);
    for (0..180) |_| items.tick();
    try std.testing.expectEqual(@as(u16, 0), items.cooldown[0]);
}

test "hold release and cancellation do not spend an unarmed or replacement item" {
    var items = Items{};
    var g = Game{ .pos = positions[0], .yaw = 0 };
    items.beginHold(0, g);
    items.held[0] = true;
    items.kind[0] = .shell;
    items.releaseHold(0, &g, false);
    try std.testing.expect(items.held[0]);
    items.beginHold(0, g);
    try std.testing.expect(items.trailing[0]);
    items.cancelHold(0);
    items.releaseHold(0, &g, false);
    try std.testing.expect(items.held[0]);
    items.beginHold(0, g);
    items.releaseHold(0, &g, true);
    try std.testing.expect(!items.held[0] and !items.trailing[0]);
    try std.testing.expect(items.world.actors[0].velocity.z > 0);
}
test "incoming warning requires a live red shell targeting this racer" {
    var items = Items{};
    const g = Game{ .pos = positions[0], .yaw = 0 };
    _ = items.world.spawn(.red_shell, 1, g, false);
    try std.testing.expect(!items.incoming(0, g));
    items.world.actors[0].target = 0;
    try std.testing.expect(items.incoming(0, g));
    items.world.actors[0].active = false;
    try std.testing.expect(!items.incoming(0, g));
}
