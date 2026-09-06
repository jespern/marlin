//! Weapons: mines, missiles, rockets, electro-bolts, shields and turbo,
//! with the original's timings, trajectories, homing and hit effects.
//! A fixed pool of in-flight weapons, swap-removed when they expire.

const std = @import("std");
const math = @import("math.zig");
const defs = @import("defs.zig");
const object = @import("object.zig");
const render = @import("render.zig");
const ship_mod = @import("ship.zig");
const track_mod = @import("track.zig");
const particle = @import("particle.zig");
const camera_mod = @import("camera.zig");
const Rng = @import("rng.zig").Rng;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Rgba = math.Rgba;
const Ship = ship_mod.Ship;
const WeaponType = defs.WeaponType;

pub const max_weapons = 64;

const mine_duration: f32 = 450.0 / 30.0;
const rocket_duration: f32 = 200.0 / 30.0;
const ebolt_duration: f32 = 140.0 / 30.0;
const missile_duration: f32 = 200.0 / 30.0;
const shield_duration: f32 = 200.0 / 30.0;
const mine_release_rate: f32 = 3.0 / 30.0;
const mine_count = 5;
const particle_spawn_rate: f32 = 0.011;
/// AI weapons fire this long after the decision.
pub const ai_delay: f32 = 1.1;

pub const Kind = enum(u8) { delayed, mine_wait, mine, missile, rocket, ebolt, shield };
pub const ModelKind = enum(u8) { none, mine, missile, rocket, shield, shield_internal, ebolt };

const no_particle: i16 = -1;

pub const Weapon = extern struct {
    timer: f32,
    owner: u8,
    kind: Kind,
    model: ModelKind,
    active: u8,
    /// Pilot index or -1.
    target: i32,
    section: u32,
    trail_particle: i16,
    track_hit_particle: i16,
    ship_hit_particle: i16,
    _pad: i16 = 0,
    trail_spawn_timer: f32,
    /// For `.delayed`: the weapon to fire when the timer runs out.
    pending: WeaponType,
    _pad2: [3]u8 = .{ 0, 0, 0 },
    acceleration: Vec3,
    velocity: Vec3,
    position: Vec3,
    angle: Vec3,
    drag: f32,
};

/// Models shared by all weapons. The shield's colours and the mines'
/// lights are animated on the model at draw time.
pub const Models = struct {
    rocket: []object.Object,
    mine: []object.Object,
    missile: []object.Object,
    shield: []object.Object,
    shield_internal: []object.Object,
    ebolt: []object.Object,

    pub fn deinit(self: *Models, gpa: std.mem.Allocator) void {
        object.free(gpa, self.rocket);
        object.free(gpa, self.mine);
        object.free(gpa, self.missile);
        object.free(gpa, self.shield);
        object.free(gpa, self.shield_internal);
        object.free(gpa, self.ebolt);
    }

    fn get(self: *Models, kind: ModelKind) ?*object.Object {
        const list = switch (kind) {
            .none => return null,
            .mine => self.mine,
            .missile => self.missile,
            .rocket => self.rocket,
            .shield => self.shield,
            .shield_internal => self.shield_internal,
            .ebolt => self.ebolt,
        };
        return if (list.len > 0) &list[0] else null;
    }
};

/// Everything a weapon step touches besides the pool itself.
pub const Context = struct {
    track: *const track_mod.Track,
    ships: []Ship,
    player: u8,
    particles: *particle.Particles,
    camera: *camera_mod.Camera,
    rng: *Rng,
    dt: f32,
};

pub const Weapons = extern struct {
    items: [max_weapons]Weapon,
    active: u32,

    pub fn init() Weapons {
        return .{ .items = undefined, .active = 0 };
    }

    fn alloc(self: *Weapons, ship: *const Ship) ?*Weapon {
        if (self.active >= max_weapons) return null;
        const w = &self.items[self.active];
        self.active += 1;
        w.* = .{
            .timer = 0,
            .owner = ship.pilot,
            .kind = .delayed,
            .model = .none,
            .active = 1,
            .target = -1,
            .section = ship.section,
            .trail_particle = no_particle,
            .track_hit_particle = no_particle,
            .ship_hit_particle = no_particle,
            .trail_spawn_timer = 0,
            .pending = .none,
            .acceleration = Vec3.zero,
            .velocity = Vec3.zero,
            .position = ship.position,
            .angle = ship.angle,
            .drag = 0,
        };
        return w;
    }

    /// Fire the ship's weapon now and clear its slot.
    pub fn fire(self: *Weapons, ship: *Ship, weapon_type: WeaponType, track: *const track_mod.Track) void {
        switch (weapon_type) {
            .mine => self.fireMine(ship),
            .missile => self.fireProjectile(ship, track, .missile),
            .rocket => self.fireProjectile(ship, track, .rocket),
            .ebolt => self.fireProjectile(ship, track, .ebolt),
            .shield => self.fireShield(ship),
            .turbo => ship.velocity = ship.velocity.add(ship.forward().scale(39321)),
            else => {},
        }
        ship.weapon_type = .none;
    }

    /// AI: fire after the standard delay.
    pub fn fireDelayed(self: *Weapons, ship: *const Ship, weapon_type: WeaponType) void {
        const w = self.alloc(ship) orelse return;
        w.kind = .delayed;
        w.pending = weapon_type;
        w.timer = ai_delay;
    }

    fn fireMine(self: *Weapons, ship: *const Ship) void {
        var timer: f32 = 0;
        var i: usize = 0;
        while (i < mine_count) : (i += 1) {
            const w = self.alloc(ship) orelse return;
            timer += mine_release_rate;
            w.timer = timer;
            w.kind = .mine_wait;
        }
    }

    fn fireProjectile(self: *Weapons, ship: *const Ship, track: *const track_mod.Track, kind: Kind) void {
        const w = self.alloc(ship) orelse return;
        switch (kind) {
            .missile => {
                w.timer = missile_duration;
                w.model = .missile;
                w.trail_particle = @intFromEnum(particle.Kind.smoke);
                w.track_hit_particle = @intFromEnum(particle.Kind.fire_white);
                w.ship_hit_particle = @intFromEnum(particle.Kind.fire);
                w.target = ship.weapon_target;
                w.drag = 0.25;
            },
            .rocket => {
                w.timer = rocket_duration;
                w.model = .rocket;
                w.trail_particle = @intFromEnum(particle.Kind.smoke);
                w.track_hit_particle = @intFromEnum(particle.Kind.fire_white);
                w.ship_hit_particle = @intFromEnum(particle.Kind.fire);
                w.drag = 0.03125;
            },
            .ebolt => {
                w.timer = ebolt_duration;
                w.model = .ebolt;
                w.trail_particle = @intFromEnum(particle.Kind.ebolt);
                w.track_hit_particle = @intFromEnum(particle.Kind.ebolt);
                w.ship_hit_particle = @intFromEnum(particle.Kind.greeny);
                w.target = ship.weapon_target;
                w.drag = 0.25;
            },
            else => unreachable,
        }
        w.kind = kind;
        setTrajectory(w, ship, track);
    }

    fn fireShield(self: *Weapons, ship: *Ship) void {
        const w = self.alloc(ship) orelse return;
        w.timer = shield_duration;
        w.model = .shield;
        w.kind = .shield;
        ship.flags.shielded = true;
    }

    fn setTrajectory(w: *Weapon, ship: *const Ship, track: *const track_mod.Track) void {
        const face = track.baseFace(&track.sections[ship.section]);
        const face_point = face.tris[0].vertices[0].pos;
        const target = Vec3.init(0, 0, 64).transform(&ship.mat);
        // The original measures both heights at the same point, so the
        // nudge is 5% of it; kept as written.
        const target_height = target.distanceToPlane(face_point, face.normal);
        const ship_height = target.distanceToPlane(face_point, face.normal);
        const nudge = target_height * 0.95 - ship_height;
        w.acceleration = target.sub(face.normal.scale(nudge)).sub(ship.position);
        w.velocity = ship.velocity.scale(0.015625);
        w.angle = ship.angle;
    }

    fn followTarget(w: *Weapon, ctx: Context) void {
        var angular = Vec3.zero;
        if (w.target >= 0) {
            const target = &ctx.ships[@intCast(w.target)];
            const dir = target.position.sub(w.position).scale(0.125 * 30 * ctx.dt);
            const height = dir.mul(Vec3.init(1, 0, 1)).len();
            angular.y = @as(f32, @floatCast(-std.math.atan2(@as(f64, dir.x), @as(f64, dir.z)))) - w.angle.y;
            angular.x = @as(f32, @floatCast(-std.math.atan2(@as(f64, dir.y), @as(f64, height)))) - w.angle.x;
        }
        angular = angular.wrapAngles();
        w.angle = w.angle.add(angular.scale(30 * ctx.dt * 0.25)).wrapAngles();
        var rotation = Mat4.identity;
        rotation.setYawPitchRoll(w.angle);
        w.acceleration = rotation.forward().scale(256);
    }

    /// The first other ship within 512 units, with an impact burst.
    fn collidesWithShip(w: *Weapon, ctx: Context) ?*Ship {
        for (ctx.ships) |*ship| {
            if (ship.pilot == w.owner) continue;
            if (ship.position.sub(w.position).len() >= 512) continue;
            const base_vel = ship.velocity.scale(0.25);
            var p: usize = 0;
            while (p < 32) : (p += 1) {
                if (w.ship_hit_particle >= 0) {
                    ctx.particles.spawn(w.position, @enumFromInt(w.ship_hit_particle), base_vel.add(particle.randomVector(ctx.rng, 512)), 256, ctx.rng);
                }
            }
            return ship;
        }
        return null;
    }

    fn collidesWithTrack(w: *const Weapon, track: *const track_mod.Track) bool {
        const section = &track.sections[w.section];
        if ((section.flags & track_mod.SectionFlags.jump) != 0) return false;
        const start: usize = section.face_start;
        const end = @min(start + section.face_count, track.faces.len);
        for (track.faces[start..end]) |face| {
            if (w.position.distanceToPlane(face.tris[0].vertices[0].pos, face.normal) < 0) return true;
        }
        return false;
    }

    fn hitShip(w: *Weapon, ship: *Ship, ctx: Context) void {
        w.active = 0;
        if (ship.flags.shielded) return;
        const is_player = ship.pilot == ctx.player;
        switch (w.kind) {
            .mine => if (is_player) {
                ship.velocity = ship.velocity.sub(ship.velocity.scale(0.125));
                ctx.camera.setShake(camera_mod.shake_long);
            } else {
                ship.speed = ship.speed * 0.125;
            },
            .missile, .rocket => if (is_player) {
                ship.velocity = if (w.kind == .missile) ship.velocity.sub(ship.velocity.scale(0.75)) else ship.velocity.scale(0.25);
                ship.angular_velocity.z += ctx.rng.float(-0.1, 0.1);
                ship.turn_rate_from_hit = ctx.rng.float(-0.1, 0.1);
                ctx.camera.setShake(camera_mod.shake_long);
            } else {
                ship.speed = ship.speed * 0.03125;
                ship.angular_velocity.z += 10 * math.pi;
                ship.turn_rate_from_hit = ctx.rng.float(-math.pi, math.pi);
            },
            .ebolt => {
                ship.flags.electroed = true;
                ship.ebolt_timer = ebolt_duration;
            },
            else => {},
        }
    }

    pub fn update(self: *Weapons, ctx: Context) void {
        const track = ctx.track;
        var i: u32 = 0;
        while (i < self.active) {
            const w = &self.items[i];
            w.timer -= ctx.dt;
            const owner = &ctx.ships[w.owner];

            switch (w.kind) {
                .delayed => if (w.timer <= 0) {
                    self.fire(owner, w.pending, track);
                    // `fire` may have grown the pool; `w` still points at
                    // this slot.
                    w.active = 0;
                },
                .mine_wait => if (w.timer <= 0) {
                    w.timer = mine_duration;
                    w.kind = .mine;
                    w.model = .mine;
                    w.position = owner.position;
                    w.angle.y = ctx.rng.float(0, math.pi * 2);
                    w.trail_particle = no_particle;
                    w.track_hit_particle = no_particle;
                    w.ship_hit_particle = @intFromEnum(particle.Kind.fire);
                },
                .mine => if (w.timer <= 0) {
                    w.active = 0;
                } else {
                    w.angle.y += ctx.dt;
                    if (collidesWithShip(w, ctx)) |ship| hitShip(w, ship, ctx);
                },
                .missile, .ebolt => if (w.timer <= 0) {
                    w.active = 0;
                } else {
                    followTarget(w, ctx);
                    if (collidesWithShip(w, ctx)) |ship| hitShip(w, ship, ctx);
                },
                .rocket => if (w.timer <= 0) {
                    w.active = 0;
                } else if (collidesWithShip(w, ctx)) |ship| {
                    hitShip(w, ship, ctx);
                },
                .shield => if (w.timer <= 0) {
                    w.active = 0;
                    owner.flags.shielded = false;
                } else {
                    w.position = if (owner.flags.view_internal) owner.cockpit() else owner.position;
                    w.model = if (owner.flags.view_internal) .shield_internal else .shield;
                    w.angle = owner.angle;
                },
            }

            // Projectiles move, hug the track, leave a trail, and explode
            // against it.
            if (w.active != 0 and (w.acceleration.x != 0 or w.acceleration.z != 0)) {
                w.velocity = w.velocity.add(w.acceleration.scale(30 * ctx.dt));
                w.velocity = w.velocity.sub(w.velocity.scale(w.drag * 30 * ctx.dt));
                w.position = w.position.add(w.velocity.scale(30 * ctx.dt));

                const face = track.baseFace(&track.sections[w.section]);
                const height = w.position.distanceToPlane(face.tris[0].vertices[0].pos, face.normal);
                if (height < 2000) w.position = w.position.add(face.normal.scale((200 - height) * 30 * ctx.dt));

                if (w.trail_particle >= 0) {
                    w.trail_spawn_timer += ctx.dt;
                    while (w.trail_spawn_timer > 0) {
                        const pos = w.position.sub(w.velocity.scale(30 * ctx.dt * w.trail_spawn_timer));
                        ctx.particles.spawn(pos, @enumFromInt(w.trail_particle), particle.randomVector(ctx.rng, 128), 128, ctx.rng);
                        w.trail_spawn_timer -= particle_spawn_rate;
                    }
                }

                w.section = track.nearestSection(w.position, Vec3.init(1, 1, 1), w.section, null);
                if (collidesWithTrack(w, track)) {
                    var p: usize = 0;
                    while (p < 32) : (p += 1) {
                        if (w.track_hit_particle >= 0) {
                            ctx.particles.spawn(w.position, @enumFromInt(w.track_hit_particle), particle.randomVector(ctx.rng, 512), 256, ctx.rng);
                        }
                    }
                    w.active = 0;
                }
            }

            if (w.active == 0) {
                self.active -= 1;
                self.items[i] = self.items[self.active];
                continue;
            }
            i += 1;
        }
    }

    pub fn draw(self: *const Weapons, r: *render.Renderer, models: *Models, cycle_time: f32) void {
        var mat = Mat4.identity;
        for (self.items[0..self.active], 0..) |*w, index| {
            const model = models.get(w.model) orelse continue;
            mat.setTranslation(w.position);
            mat.setYawPitchRoll(w.angle);
            switch (w.model) {
                .mine => animateMineLights(model, cycle_time, index),
                .shield, .shield_internal => animateShield(model, w.timer),
                else => {},
            }
            model.draw(r, &mat);
        }
    }
};

fn animateMineLights(model: *object.Object, cycle_time: f32, index: usize) void {
    const r: u8 = @intFromFloat(std.math.clamp(@sin(cycle_time * math.pi * 2 + @as(f32, @floatFromInt(index)) * 0.66) * 128 + 128, 0, 255));
    var count: usize = 0;
    for (model.primitives) |*prim| {
        if (count >= 8) break;
        if (prim.kind != .gt3) continue;
        prim.color[0] = Rgba.init(230, 0, 0, 255);
        prim.color[1] = Rgba.init(r, 0x40, 0, 255);
        prim.color[2] = Rgba.init(r, 0x40, 0, 255);
        count += 1;
    }
}

fn animateShield(model: *object.Object, timer: f32) void {
    const alpha: u8 = 48;
    const color_timer = timer * 0.05;
    for (model.primitives) |*prim| {
        const n: usize = switch (prim.kind) {
            .g3 => 3,
            .g4 => 4,
            else => continue,
        };
        var v: usize = 0;
        while (v < n) : (v += 1) {
            const col: u8 = @intFromFloat(std.math.clamp(@sin(color_timer * @as(f32, @floatFromInt(prim.coords[v]))) * 127 + 128, 0, 255));
            prim.color[v] = Rgba.init(col, col, 255, alpha);
        }
    }
}

/// The original's weighted random pickup.
pub fn randomType(rng: *Rng, projectile_only: bool) WeaponType {
    if (!projectile_only) {
        const index = rng.int(0, 65);
        if (index < 17) return .rocket;
        if (index < 35) return .mine;
        if (index < 45) return .shield;
        if (index < 53) return .missile;
        if (index < 59) return .turbo;
        return .ebolt;
    }
    const index = rng.int(0, 60);
    if (index < 27) return .rocket;
    if (index < 40) return .missile;
    if (index < 50) return .turbo;
    return .ebolt;
}

/// Mirror the shield's winding so it reads from inside the cockpit.
pub fn invertShield(shield: []object.Object) void {
    for (shield) |*obj| {
        for (obj.primitives) |*prim| {
            switch (prim.kind) {
                .g3 => std.mem.swap(u16, &prim.coords[0], &prim.coords[2]),
                .g4 => std.mem.swap(u16, &prim.coords[0], &prim.coords[3]),
                else => {},
            }
        }
    }
}
