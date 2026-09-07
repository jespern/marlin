//! Race cameras: the external chase view that trails the ship on a spring
//! along the section centre line, and the cockpit view.

const std = @import("std");
const math = @import("math.zig");
const track_mod = @import("track.zig");
const ship_mod = @import("ship.zig");
const Rng = @import("rng.zig").Rng;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const Mode = enum(u8) { external, internal, rescue };

pub const shake_long: f32 = 20.0 * (1.0 / 30.0);
pub const shake_short: f32 = 2.0 * (1.0 / 30.0);

pub const Camera = extern struct {
    position: Vec3 = Vec3.zero,
    velocity: Vec3 = Vec3.zero,
    angle: Vec3 = Vec3.zero,
    section: u32 = 0,
    mode: Mode = .external,
    /// How much of the ship's roll the cockpit view shows (a user option
    /// in the original; 0 keeps the horizon level).
    internal_roll: f32 = 0,
    /// Screen shake from weapon hits, as an NDC offset.
    shake: Vec2 = Vec2.init(0, 0),
    shake_timer: f32 = 0,
    /// User option in the original (0.5 default).
    screen_shake: f32 = 0.5,

    pub fn init(track: *const track_mod.Track, section: u32) Camera {
        var s = section;
        var i: usize = 0;
        while (i < 10) : (i += 1) s = track.sections[s].next;
        return .{ .section = s, .position = track.sections[s].center };
    }

    pub fn forward(self: *const Camera) Vec3 {
        var m = Mat4.identity;
        m.setYawPitchRoll(self.angle);
        return m.forward();
    }

    pub fn update(self: *Camera, track: *const track_mod.Track, ship: *const ship_mod.Ship, droid_position: Vec3, rng: *Rng, dt: f32) void {
        switch (self.mode) {
            .external => self.updateExternal(track, ship, dt),
            .internal => self.updateInternal(ship),
            .rescue => self.updateRescue(track, droid_position),
        }
        self.updateShake(rng, dt);
    }

    pub fn setShake(self: *Camera, duration: f32) void {
        self.shake_timer = duration;
    }

    fn updateShake(self: *Camera, rng: *Rng, dt: f32) void {
        if (self.shake_timer > 0) {
            const s = 0.25 * self.screen_shake * self.shake_timer;
            self.shake = Vec2.init(rng.float(-s, s), rng.float(-s, s));
            self.shake_timer -= dt;
        } else {
            self.shake = Vec2.init(0, 0);
            self.shake_timer = 0;
        }
    }

    /// Fixed viewpoint above the rescue section, tracking the droid.
    fn updateRescue(self: *Camera, track: *const track_mod.Track, droid_position: Vec3) void {
        self.position = track.sections[self.section].center.add(Vec3.init(300, -1500, 300));
        const target = droid_position.sub(self.position);
        const height = target.mul(Vec3.init(1, 0, 1)).len();
        self.angle.x = -std.math.atan2(target.y, height);
        self.angle.y = -std.math.atan2(target.x, target.z);
    }

    fn updateExternal(self: *Camera, track: *const track_mod.Track, ship: *const ship_mod.Ship, dt: f32) void {
        var pos = Vec3.init(0, 0, -1024).transform(&ship.mat);
        pos.y -= 200;
        self.section = track.nearestSection(pos, Vec3.init(1, 1, 1), self.section, null);
        const section = &track.sections[self.section];
        const next = &track.sections[section.next];

        const target = pos.projectToRay(next.center, section.center);
        const diff_from_center = pos.sub(target);
        var acc = diff_from_center;
        acc.y += diff_from_center.len() * 0.5;

        self.velocity = self.velocity.sub(acc.scale(0.015625 * 30 * dt));
        self.velocity = self.velocity.sub(self.velocity.scale(0.125 * 30 * dt));
        pos = pos.add(self.velocity);

        self.position = pos;
        self.angle = Vec3.init(ship.angle.x, ship.angle.y, 0);
    }

    fn updateInternal(self: *Camera, ship: *const ship_mod.Ship) void {
        self.section = ship.section;
        self.position = ship.cockpit();
        self.angle = Vec3.init(ship.angle.x, ship.angle.y, ship.angle.z * self.internal_roll);
    }
};
