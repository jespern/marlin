//! Race cameras: the external chase view that trails the ship on a spring
//! along the section centre line, and the cockpit view.

const std = @import("std");
const math = @import("math.zig");
const track_mod = @import("track.zig");
const ship_mod = @import("ship.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pub const Mode = enum(u8) { external, internal };

pub const Camera = extern struct {
    position: Vec3 = Vec3.zero,
    velocity: Vec3 = Vec3.zero,
    angle: Vec3 = Vec3.zero,
    section: u32 = 0,
    mode: Mode = .external,
    /// How much of the ship's roll the cockpit view shows (a user option
    /// in the original; 0 keeps the horizon level).
    internal_roll: f32 = 0,

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

    pub fn update(self: *Camera, track: *const track_mod.Track, ship: *const ship_mod.Ship, dt: f32) void {
        switch (self.mode) {
            .external => self.updateExternal(track, ship, dt),
            .internal => self.updateInternal(ship),
        }
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
