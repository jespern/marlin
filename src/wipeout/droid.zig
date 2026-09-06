//! The rescue droid: flies its intro over the grid, idles above the jump,
//! and comes to tow the player back after a fall. Colour cycling on the
//! model is render-time animation, recomputed every frame.

const std = @import("std");
const math = @import("math.zig");
const object = @import("object.zig");
const render = @import("render.zig");
const ship_mod = @import("ship.zig");
const track_mod = @import("track.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Rgba = math.Rgba;

pub const update_time_initial: f32 = 800.0 / 30.0;
const update_time_intro_1: f32 = 770.0 / 30.0;
const update_time_intro_2: f32 = 710.0 / 30.0;
const update_time_intro_3: f32 = 400.0 / 30.0;

pub const Mode = enum(u8) { intro, idle, rescue, nothing };

pub const Droid = extern struct {
    /// Jump section the droid idles above, or -1 on a course without one.
    section: i32,
    position: Vec3,
    velocity: Vec3,
    acceleration: Vec3,
    angle: Vec3,
    angular_velocity: Vec3,
    cycle_timer: f32,
    update_timer: f32,
    mode: Mode,
    _pad: [3]u8 = .{ 0, 0, 0 },
    mat: Mat4,

    pub fn init(track: *const track_mod.Track, ship: *const ship_mod.Ship) Droid {
        var section: i32 = -1;
        for (track.sections, 0..) |s, i| {
            if ((s.flags & track_mod.SectionFlags.jump) != 0) {
                section = @intCast(i);
                break;
            }
        }
        return .{
            .section = section,
            .position = ship.position.add(Vec3.init(0, -200, 0)),
            .velocity = Vec3.zero,
            .acceleration = Vec3.zero,
            .angle = Vec3.zero,
            .angular_velocity = Vec3.zero,
            .cycle_timer = 0,
            .update_timer = update_time_initial,
            .mode = .intro,
            .mat = Mat4.identity,
        };
    }

    /// Where the camera should look from during a rescue: the section the
    /// droid was called to, or the next one when the ship fell off a jump.
    pub fn rescueCameraSection(track: *const track_mod.Track, ship: *const ship_mod.Ship) u32 {
        const s = &track.sections[ship.section];
        return if ((s.flags & track_mod.SectionFlags.jump) != 0) s.next else ship.section;
    }

    /// Returns true on the step the rescue begins (the caller switches the
    /// camera).
    pub fn update(self: *Droid, track: *const track_mod.Track, ship: *ship_mod.Ship, dt: f32) bool {
        var rescue_started = false;
        switch (self.mode) {
            .intro => self.updateIntro(track, dt),
            .idle => rescue_started = self.updateIdle(track, ship),
            .rescue => self.updateRescue(track, ship),
            .nothing => {},
        }
        self.velocity = self.velocity.add(self.acceleration.scale(30 * dt));
        self.velocity = self.velocity.sub(self.velocity.scale(0.125 * 30 * dt));
        self.position = self.position.add(self.velocity.scale(0.015625 * 30 * dt));
        self.angle = self.angle.add(self.angular_velocity.scale(dt)).wrapAngles();
        return rescue_started;
    }

    fn updateIntro(self: *Droid, track: *const track_mod.Track, dt: f32) void {
        self.update_timer -= dt;
        if (self.update_timer < update_time_intro_3) {
            self.acceleration = self.mat.forward().scale(0.25 * 4096.0);
            self.acceleration.y = 0;
            self.angular_velocity.y = 0;
        } else if (self.update_timer < update_time_intro_2) {
            self.acceleration = self.mat.forward().scale(0.125 * 4096.0);
            self.acceleration.y = -140;
            self.angular_velocity.y = (-8.0 / 4096.0) * math.pi * 2 * 30;
        } else if (self.update_timer < update_time_intro_1) {
            self.acceleration.y -= 90 * dt;
            self.angular_velocity.y = (8.0 / 4096.0) * math.pi * 2 * 30;
        }
        if (self.update_timer <= 0) {
            if (self.section < 0) {
                self.velocity = Vec3.zero;
                self.acceleration = Vec3.zero;
                self.angular_velocity = Vec3.zero;
                self.mode = .nothing;
                return;
            }
            self.update_timer = update_time_initial;
            self.mode = .idle;
            const c = track.sections[@intCast(self.section)].center;
            self.position = Vec3.init(c.x, -3000, c.z);
        }
    }

    fn idleTarget(self: *const Droid, track: *const track_mod.Track) Vec3 {
        const s = &track.sections[@intCast(self.section)];
        const next = &track.sections[s.next];
        return Vec3.init((s.center.x + next.center.x) * 0.5, s.center.y - 3000, (s.center.z + next.center.z) * 0.5);
    }

    fn updateIdle(self: *Droid, track: *const track_mod.Track, ship: *ship_mod.Ship) bool {
        const target_vector = self.idleTarget(track).sub(self.position);
        const target_heading: f32 = @floatCast(-std.math.atan2(@as(f64, target_vector.x), @as(f64, target_vector.z)));
        const quickest = target_heading - self.angle.y;
        const turn = if (self.angle.y < 0) target_heading - (self.angle.y + math.pi * 2) else target_heading - (self.angle.y - math.pi * 2);
        self.angular_velocity.y = if (@abs(turn) < @abs(quickest)) turn * 30 / 64.0 else quickest * 30.0 / 64.0;

        self.acceleration = self.mat.forward().scale(0.125 * 4096.0);
        self.acceleration.y = target_vector.y / 64.0;

        if (ship.flags.in_rescue) {
            self.mode = .rescue;
            self.update_timer = update_time_initial;
            ship.flags.view_remote = true;
            // Teleport in unless already next to the rescue position.
            const ship_prev = track.sections[ship.section].prev;
            if (self.section != @as(i32, @intCast(ship.section)) and self.section != @as(i32, @intCast(ship_prev))) {
                self.section = @intCast(ship.section);
                self.position = self.idleTarget(track);
            }
            ship.flags.in_tow = false;
            self.velocity = Vec3.zero;
            self.acceleration = Vec3.zero;
            return true;
        }
        return false;
    }

    fn updateRescue(self: *Droid, track: *const track_mod.Track, ship: *ship_mod.Ship) void {
        self.angular_velocity.y = 0;
        self.angle.y = ship.angle.y;
        const target = Vec3.init(ship.position.x, ship.position.y - 350, ship.position.z);
        const distance = target.sub(self.position);
        if (ship.flags.in_tow) {
            self.velocity = Vec3.zero;
            self.acceleration = Vec3.zero;
            self.position = target;
        } else if (distance.len() < 8) {
            ship.flags.in_tow = true;
            self.velocity = Vec3.zero;
            self.acceleration = Vec3.zero;
            self.position = target;
        } else {
            self.velocity = distance.scale(16);
        }

        if (!ship.flags.in_rescue) {
            self.mode = .idle;
            self.update_timer = update_time_initial;
            // Back to the jump section behind us.
            var s: u32 = @intCast(@max(self.section, 0));
            var guard: usize = 0;
            while ((track.sections[s].flags & track_mod.SectionFlags.jump) == 0 and guard < track.sections.len) : (guard += 1) {
                s = track.sections[s].prev;
            }
            self.section = @intCast(s);
        }
    }

    pub fn draw(self: *Droid, r: *render.Renderer, model: *object.Object, dt: f32) void {
        self.cycle_timer += dt * math.pi * 2;
        const rf: u8 = @intFromFloat(@sin(self.cycle_timer) * 127 + 128);
        const gf: u8 = @intFromFloat(@sin(self.cycle_timer + 0.2) * 127 + 128);
        const bf: u8 = @intFromFloat(@sin(self.cycle_timer * 0.5 + 0.1) * 127 + 128);
        for (model.primitives[0..@min(11, model.primitives.len)], 0..) |*prim, i| {
            const color = if (i < 2) Rgba.init(40, gf, 40, 255) else if (i < 6) Rgba.init(bf >> 1, bf, bf >> 1, 255) else Rgba.init(rf, 40, 40, 255);
            switch (prim.kind) {
                .gt3 => prim.color = .{ color, color, color, color },
                .gt4 => prim.color = .{ color, color, color, Rgba.init(40, 40, 40, 255) },
                else => {},
            }
        }
        self.mat.setTranslation(self.position);
        self.mat.setYawPitchRoll(self.angle);
        model.draw(r, &self.mat);
    }
};
