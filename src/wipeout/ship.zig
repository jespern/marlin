//! Ship state and the player's flight model.
//!
//! This is a translation of the reference implementation's ship update:
//! nearest-section tracking, hover force against the track base face,
//! wall collisions at nose and wing tips, jump detection, flying, and the
//! rescue that tows a ship back after it leaves the course. All rates are
//! per second, scaled by the step `dt`, exactly as the original scales by
//! its frame time, so a fixed step reproduces the original at that rate.
//!
//! The struct is plain data referencing the track by section and face
//! index; it can be copied bytewise into a snapshot.

const std = @import("std");
const math = @import("math.zig");
const defs = @import("defs.zig");
const input = @import("input.zig");
const object = @import("object.zig");
const render = @import("render.zig");
const scene = @import("scene.zig");
const image = @import("image.zig");
const assets_mod = @import("assets.zig");
const track_mod = @import("track.zig");
const Rng = @import("rng.zig").Rng;
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Rgba = math.Rgba;
const Track = track_mod.Track;
const Face = track_mod.Face;
const FaceFlags = track_mod.FaceFlags;
const SectionFlags = track_mod.SectionFlags;

// Timings, in seconds (the original counts PSX frames at 30 Hz).
pub const update_time_initial: f32 = 200.0 / 30.0;
pub const update_time_stall: f32 = 90.0 / 30.0;
pub const update_time_rescue: f32 = 500.0 / 30.0;

const flying_gravity = Vec3.init(0, 80000.0, 0);
const on_track_gravity = Vec3.init(0, 30000.0, 0);
const min_resistance: f32 = 20;
const max_resistance: f32 = 74;
const track_magnet: f32 = 64;
const track_float: f32 = 256;

const pitch_accel: f32 = defs.ntscAcceleration(defs.angleNormToRadian(defs.fixedToFloat(30.0 / 16.0)));
const thrust_rate: f32 = defs.ntscVelocity(16);
const thrust_falloff: f32 = defs.ntscVelocity(8);
const brake_rate: f32 = defs.ntscVelocity(32);
/// Pitch correction applied while the nose is clear of the track.
const nose_up_accel: f32 = defs.ntscAcceleration(defs.angleNormToRadian(defs.fixedToFloat(-50.0 / 16.0)));

/// Sum-of-angles threshold that decides whether a projected point lies on
/// a track face (a full turn less a safety margin).
const on_face_angle: f32 = 0.91552734375 * math.pi * 2.0;

pub const Flags = packed struct(u32) {
    in_tow: bool = false,
    view_remote: bool = false,
    view_internal: bool = false,
    direction_forward: bool = false,
    flying: bool = false,
    left_side: bool = false,
    racing: bool = false,
    coll: bool = false,
    on_junction: bool = false,
    visible: bool = false,
    in_rescue: bool = false,
    overtaken: bool = false,
    just_in_front: bool = false,
    junction_left: bool = false,
    shielded: bool = false,
    electroed: bool = false,
    revconned: bool = false,
    specialed: bool = false,
    _pad: u14 = 0,
};

pub const Mode = enum(u8) { intro, race, rescue };

/// Everything the flight model needs from outside the ship for one step.
pub const Context = struct {
    track: *const Track,
    input: *const input.State,
    rng: *Rng,
    dt: f32,
    start_line_pos: u16,
    /// Exponent applied to analog steering; 1 for digital input.
    analog_response: f32 = 1.0,
};

pub const Ship = struct {
    pilot: u8,
    flags: Flags,
    mode: Mode,

    section: u32,
    prev_section: u32,

    position: Vec3,
    velocity: Vec3,
    acceleration: Vec3,
    thrust: Vec3,

    angle: Vec3,
    angular_velocity: Vec3,
    angular_acceleration: Vec3,

    /// Start hover anchor and rescue target.
    temp_target: Vec3,

    turn_rate: f32,
    turn_rate_max: f32,
    turn_rate_from_hit: f32,

    mass: f32,
    thrust_mag: f32,
    thrust_max: f32,
    current_thrust_max: f32,
    speed: f32,
    brake_left: f32,
    brake_right: f32,
    resistance: f32,
    skid: f32,

    lap: i32,
    max_lap: i32,
    lap_time: f32,
    lap_times: [defs.num_laps]f32,

    section_num: i32,
    prev_section_num: i32,
    total_section_num: i32,

    update_timer: f32,
    last_impact_time: f32,

    mat: Mat4,

    /// Place the ship on the start grid: `inv_start_rank` 0 is the back row
    /// (where the player always starts); odd ranks take the right-hand
    /// face of the grid section.
    pub fn init(track: *const Track, section_index: u32, pilot: u8, inv_start_rank: u8, class: defs.RaceClass) Ship {
        const attributes = defs.shipAttributes(defs.pilot_team[pilot], class);
        const section = &track.sections[section_index];

        var face_index: usize = @as(usize, section.face_start) + 1;
        if ((inv_start_rank % 2) != 0) face_index += 1;
        const face = &track.faces[@min(face_index, track.faces.len - 1)];
        const face_point = face.tris[0].vertices[0].pos.add(face.tris[0].vertices[2].pos).scale(0.5);

        const next = &track.sections[section.next];
        const direction = next.center.sub(section.center);

        return .{
            .pilot = pilot,
            .flags = .{ .racing = true, .visible = true, .direction_forward = true },
            .mode = .intro,
            .section = section_index,
            .prev_section = section_index,
            .position = face_point.add(face.normal.scale(200)),
            .velocity = Vec3.zero,
            .acceleration = Vec3.zero,
            .thrust = Vec3.zero,
            .angle = Vec3.init(0, -std.math.atan2(direction.x, direction.z), 0),
            .angular_velocity = Vec3.zero,
            .angular_acceleration = Vec3.zero,
            .temp_target = Vec3.zero,
            .turn_rate = attributes.turn_rate,
            .turn_rate_max = attributes.turn_rate_max,
            .turn_rate_from_hit = 0,
            .mass = attributes.mass,
            .thrust_mag = 0,
            .thrust_max = attributes.thrust_max,
            .current_thrust_max = 0,
            .speed = 0,
            .brake_left = 0,
            .brake_right = 0,
            .resistance = attributes.resistance,
            .skid = attributes.skid,
            .lap = -1,
            .max_lap = -1,
            .lap_time = 0,
            .lap_times = .{ 0, 0, 0 },
            .section_num = section.num,
            .prev_section_num = section.num,
            .total_section_num = section.num,
            .update_timer = update_time_initial,
            .last_impact_time = 0,
            .mat = Mat4.identity,
        };
    }

    /// Begin racing immediately instead of hovering through the countdown.
    pub fn skipIntro(self: *Ship) void {
        self.mode = .race;
        self.update_timer = 0;
        self.current_thrust_max = self.thrust_max;
        self.temp_target = self.position;
    }

    pub fn forward(self: *const Ship) Vec3 {
        return self.mat.forward();
    }
    pub fn cockpit(self: *const Ship) Vec3 {
        return Vec3.init(0, -128, 0).transform(&self.mat);
    }
    pub fn nose(self: *const Ship) Vec3 {
        return Vec3.init(0, 0, 512).transform(&self.mat);
    }
    pub fn wingLeft(self: *const Ship) Vec3 {
        return Vec3.init(-256, 0, -256).transform(&self.mat);
    }
    pub fn wingRight(self: *const Ship) Vec3 {
        return Vec3.init(256, 0, -256).transform(&self.mat);
    }

    // -- per-step update -----------------------------------------------------

    pub fn update(self: *Ship, ctx: Context) void {
        const track = ctx.track;
        self.prev_section = self.section;

        // The original de-emphasises height when picking the section under
        // the ship, so a ship high above the track still tracks the section
        // below it rather than a nearer one on a different level.
        var distance: f32 = 0;
        self.section = track.nearestSection(self.position, Vec3.init(1, 0.25, 1), self.section, &distance);
        self.flags.flying = distance > 3700;

        self.prev_section_num = track.sections[self.prev_section].num;
        self.section_num = track.sections[self.section].num;

        const section = &track.sections[self.section];
        const base = track.baseFaceIndex(section);
        const base_face = &track.faces[base];
        const to_face_vector = base_face.tris[0].vertices[0].pos.sub(base_face.tris[0].vertices[1].pos);
        const direction = section.center.sub(self.position);
        self.flags.left_side = direction.dot(to_face_vector) > 0;
        // (Pickup collection happens here in the original.)

        self.last_impact_time += ctx.dt;

        switch (self.mode) {
            .intro => self.updateIntro(ctx),
            .race => self.updateRace(ctx),
            .rescue => self.updateRescue(ctx),
        }

        self.mat = Mat4.identity;
        self.mat.setTranslation(self.position);
        self.mat.setYawPitchRoll(self.angle);

        self.updateLap(ctx);
    }

    fn updateLap(self: *Ship, ctx: Context) void {
        const track = ctx.track;
        self.lap_time += ctx.dt;
        const start: i32 = ctx.start_line_pos;

        if (self.prev_section_num == start + 1 and self.section_num <= start) {
            self.lap -= 1;
        } else if (self.prev_section_num == start and self.section_num > start) {
            self.lap += 1;
            if (self.lap > self.max_lap) {
                self.max_lap = self.lap;
                if (self.lap > 0 and self.lap <= defs.num_laps) {
                    self.lap_times[@intCast(self.lap - 1)] = self.lap_time;
                }
                self.lap_time = 0;
            }
        }

        var from_line = self.section_num - (start + 1);
        const count: i32 = @intCast(track.sections.len);
        if (from_line < 0) from_line += count;
        self.total_section_num = self.lap * count + from_line;
    }

    fn toggleView(self: *Ship, ctx: Context) void {
        if (ctx.input.isPressed(.change_view)) self.flags.view_internal = !self.flags.view_internal;
    }

    /// Hovering on the grid while the countdown runs; thrust can be built
    /// up but the ship does not move. The stall check at "go" punishes
    /// holding full thrust and rewards a narrow band just below it.
    fn updateIntro(self: *Ship, ctx: Context) void {
        if (self.update_timer >= update_time_initial) self.temp_target = self.position;
        self.update_timer -= ctx.dt;
        self.position.y = self.temp_target.y + @sin(self.update_timer * 80.0 * 30.0 * math.pi * 2.0 / 4096.0) * 32;

        const thrust_input = ctx.input.state(.thrust);
        if (thrust_input != 0) {
            self.thrust_mag += thrust_input * thrust_rate * ctx.dt;
        } else {
            self.thrust_mag -= thrust_rate * ctx.dt;
        }
        self.thrust_mag = std.math.clamp(self.thrust_mag, 0, self.thrust_max);
        self.toggleView(ctx);

        if (self.update_timer <= 0) {
            if (self.thrust_mag >= 680 and self.thrust_mag <= 700) {
                self.thrust_mag = 1800;
                self.current_thrust_max = 1800;
            } else if (self.thrust_mag < 680) {
                self.current_thrust_max = self.thrust_max;
            } else {
                self.current_thrust_max = 200;
            }
            self.update_timer = update_time_stall;
            self.mode = .race;
        }
    }

    fn updateRace(self: *Ship, ctx: Context) void {
        const track = ctx.track;
        const in = ctx.input;
        const dt = ctx.dt;
        const section = &track.sections[self.section];

        // Steering. Reversing direction gets double acceleration; otherwise
        // accelerate until the (analog) target rate is reached.
        self.angular_acceleration = Vec3.zero;
        const left = in.state(.left);
        const right = in.state(.right);
        if (left != 0) {
            if (self.angular_velocity.y < 0) {
                self.angular_acceleration.y += self.turn_rate * 2;
            } else {
                const target = std.math.pow(f32, left, ctx.analog_response);
                if (target * self.turn_rate_max > self.angular_velocity.y) self.angular_acceleration.y += self.turn_rate;
            }
        } else if (right != 0) {
            if (self.angular_velocity.y > 0) {
                self.angular_acceleration.y -= self.turn_rate * 2;
            } else {
                const target = std.math.pow(f32, right, ctx.analog_response);
                if (target * -self.turn_rate_max < self.angular_velocity.y) self.angular_acceleration.y -= self.turn_rate;
            }
        }

        self.angular_acceleration.x += in.state(.down) * pitch_accel;
        self.angular_acceleration.x -= in.state(.up) * pitch_accel;

        // Stall or boost after the start, then normal thrust ceiling.
        if (self.update_timer > 0) {
            if (self.current_thrust_max < 500) self.current_thrust_max += ctx.rng.float(0, 165) * dt;
            self.update_timer -= dt;
        } else {
            self.current_thrust_max = self.thrust_max;
        }

        const thrust_input = in.state(.thrust);
        if (thrust_input != 0) {
            self.thrust_mag += thrust_input * thrust_rate * dt;
        } else {
            self.thrust_mag -= thrust_falloff * dt;
        }
        self.thrust_mag = std.math.clamp(self.thrust_mag, 0, self.current_thrust_max);

        if (in.state(.brake_right) != 0) {
            self.brake_right += brake_rate * dt;
        } else if (self.brake_right > 0) {
            self.brake_right -= brake_rate * dt;
        }
        self.brake_right = std.math.clamp(self.brake_right, 0, 256);

        if (in.state(.brake_left) != 0) {
            self.brake_left += brake_rate * dt;
        } else if (self.brake_left > 0) {
            self.brake_left -= brake_rate * dt;
        }
        self.brake_left = std.math.clamp(self.brake_left, 0, 256);

        self.toggleView(ctx);

        // Thrust acts along the ship's own forward axis.
        const fwd = self.forward();
        self.thrust = fwd.scale(self.thrust_mag * 64);
        self.speed = self.velocity.len();
        const forward_velocity = fwd.scale(self.speed);

        // On a jump section, project the position onto the base face plane
        // and test whether it still lies within the face; if not, we left
        // the ramp and are airborne.
        if ((section.flags & SectionFlags.jump) != 0) {
            const base = track.baseFaceIndex(section);
            const f0 = &track.faces[base];
            const f1 = &track.faces[@min(base + 1, track.faces.len - 1)];
            const face_point = f0.tris[0].vertices[0].pos;
            const height = self.position.distanceToPlane(face_point, f0.normal);
            const plane_point = self.position.sub(f0.normal.scale(height));
            const v0 = plane_point.sub(f0.tris[0].vertices[1].pos);
            const v1 = plane_point.sub(f0.tris[0].vertices[2].pos);
            const v2 = plane_point.sub(f1.tris[0].vertices[0].pos);
            const v3 = plane_point.sub(f1.tris[1].vertices[0].pos);
            const angle = v0.angleBetween(v2) + v2.angleBetween(v3) + v3.angleBetween(v1) + v1.angleBetween(v0);
            if (angle < on_face_angle) self.flags.flying = true;
        }

        if (!self.flags.flying) {
            const base = track.baseFaceIndex(section);
            self.collideWithTrack(ctx, base);

            var face_index = base;
            if (!self.flags.left_side) face_index = @min(base + 1, track.faces.len - 1);
            const face = &track.faces[face_index];

            if (!self.flags.specialed and (face.flags & FaceFlags.boost) != 0) {
                const track_direction = track.sections[section.next].center.sub(section.center);
                self.velocity = self.velocity.add(track_direction.scale(30 * dt));
            }

            const face_point = face.tris[0].vertices[0].pos;
            var height = self.position.distanceToPlane(face_point, face.normal);

            if (height <= 0) {
                if (self.last_impact_time > 0.2) self.last_impact_time = 0;
                self.velocity = self.velocity.reflect(face.normal, 2).scale(0.875);
                self.velocity = self.velocity.sub(face.normal.scale(64.0 * 30 * dt));
            } else if (height < 30) {
                self.velocity = self.velocity.add(face.normal.scale(64.0 * 30 * dt));
            }
            height = @max(height, 50);

            const brake = self.brake_left + self.brake_right;
            const resistance = (self.resistance * (max_resistance - (brake * 0.125))) * 0.0078125;
            const track_repulsion = 4096 * (track_magnet * track_float / height - track_magnet);

            var force = on_track_gravity;
            force = force.add(face.normal.scale(track_repulsion));
            force = force.add(self.thrust);

            self.acceleration = forward_velocity.sub(self.velocity).div(self.skid + brake * 0.25);
            self.acceleration = self.acceleration.add(force.div(self.mass));
            self.acceleration = self.acceleration.sub(self.velocity.div(resistance));

            // Lift the nose when it dips towards the track.
            const nose_pos = Vec3.init(0, 0, 128).transform(&self.mat);
            const nose_height = nose_pos.distanceToPlane(face_point, face.normal);
            if (nose_height < 600) {
                self.angular_acceleration.x += defs.ntscAcceleration(defs.angleNormToRadian(defs.fixedToFloat((height - nose_height + 5) * (1.0 / 16.0))));
            } else {
                self.angular_acceleration.x += nose_up_accel;
            }
        } else {
            const distance = self.distanceFromTrack(track);
            if (distance > 8000 and (section.flags & SectionFlags.jump) != 0) {
                // Fell short of a jump: tow to the landing side.
                var landing = section.prev;
                var guard: usize = 0;
                while ((track.sections[landing].flags & SectionFlags.jump) == 0 and guard < track.sections.len) : (guard += 1) {
                    landing = track.sections[landing].next;
                }
                landing = track.sections[landing].next;
                self.beginRescue(track, landing);
            } else if (distance > 10000) {
                self.beginRescue(track, section.prev);
            } else {
                const brake = self.brake_left + self.brake_right;
                const resistance = (self.resistance * (max_resistance - (brake * 0.125))) * 0.0078125;
                const force = flying_gravity.add(self.thrust);
                self.acceleration = forward_velocity.sub(self.velocity).div(min_resistance + brake * 4);
                self.acceleration = self.acceleration.add(force.div(self.mass));
                self.acceleration = self.acceleration.sub(self.velocity.div(resistance));
                self.angular_acceleration.x += nose_up_accel;
            }
        }

        // Integrate. Velocity is in units per PSX frame scaled by 64, which
        // is where the 0.015625 (1/64) and 30 factors come from.
        self.velocity = self.velocity.add(self.acceleration.scale(30 * dt));
        self.position = self.position.add(self.velocity.scale(0.015625 * 30 * dt));

        self.angular_acceleration.x -= self.angular_velocity.x * 0.25 * 30;
        self.angular_acceleration.z += (self.angular_velocity.y - (0.5 * self.angular_velocity.z)) * 30;

        // Without steering input, bleed yaw rate off at the turn rate.
        if (self.angular_acceleration.y == 0) {
            if (self.angular_velocity.y > 0) {
                self.angular_acceleration.y -= @min(self.turn_rate, self.angular_velocity.y / dt);
            } else if (self.angular_velocity.y < 0) {
                self.angular_acceleration.y += @min(self.turn_rate, -self.angular_velocity.y / dt);
            }
        }

        self.angular_velocity = self.angular_velocity.add(self.angular_acceleration.scale(dt));
        self.angular_velocity.y = std.math.clamp(self.angular_velocity.y, -self.turn_rate_max, self.turn_rate_max);

        const brake_dir = (self.brake_left - self.brake_right) * (0.125 / 4096.0);
        self.angle.y += brake_dir * self.speed * 0.000030517578125 * math.pi * 2 * 30 * dt;

        self.angle = self.angle.add(self.angular_velocity.scale(dt));
        self.angle.z -= self.angle.z * 0.125 * 30 * dt;
        self.angle = self.angle.wrapAngles();

        // Going backwards onto a jump landing pushes the ship forward again.
        if (!self.flags.direction_forward and (track.sections[section.prev].flags & SectionFlags.jump) != 0) {
            const repulse = track.sections[section.next].center.sub(section.center);
            self.velocity = self.velocity.add(repulse.scale(2));
        }
    }

    /// Towed back onto the track. The original has the rescue droid fly to
    /// the ship first and set `in_tow` on arrival; without the droid the
    /// tow starts immediately.
    fn updateRescue(self: *Ship, ctx: Context) void {
        const track = ctx.track;
        const dt = ctx.dt;
        const section = &track.sections[self.section];
        const next = &track.sections[section.next];

        if (self.flags.in_tow) {
            self.temp_target = self.temp_target.add(next.center.sub(self.temp_target).scale(0.0078125));
            self.velocity = self.temp_target.sub(self.position);
            const target_dir = next.center.sub(section.center);
            self.angular_velocity.y = math.wrapAngle(-std.math.atan2(target_dir.x, target_dir.z) - self.angle.y) * 0.015625 * 30;
            self.angle.y = math.wrapAngle(self.angle.y + self.angular_velocity.y * dt);
        }

        self.angle.x -= self.angle.x * 0.125 * 30 * dt;
        self.angle.z -= self.angle.z * 0.03125 * 30 * dt;

        self.velocity = self.velocity.sub(self.velocity.scale(0.0625 * 30 * dt));
        self.position = self.position.add(self.velocity.scale(0.03125 * 30 * dt));

        if (self.flags.in_tow and self.distanceFromTrack(track) < 300) {
            self.mode = .race;
            self.update_timer = 0;
            self.flags.in_rescue = false;
            self.flags.view_remote = false;
            self.flags.in_tow = false;
        }
    }

    fn beginRescue(self: *Ship, track: *const Track, section_index: u32) void {
        self.mode = .rescue;
        self.update_timer = update_time_rescue;
        self.flags.in_rescue = true;
        self.flags.flying = true;
        self.flags.in_tow = true;
        self.section = section_index;
        const section = &track.sections[section_index];
        self.temp_target = section.center.add(track.sections[section.next].center).scale(0.55);
        self.temp_target.y -= 2000;
        self.velocity = Vec3.zero;
    }

    /// Distance from the section centre line, with height above the track
    /// nearly ignored and height below it amplified.
    pub fn distanceFromTrack(self: *const Ship, track: *const Track) f32 {
        const section = &track.sections[self.section];
        const next = &track.sections[section.next];
        const best_path = self.position.projectToRay(next.center, section.center);
        var distance = best_path.sub(self.position);
        if (distance.y > -512) {
            distance.y = distance.y * 0.0001;
        } else {
            distance = distance.scale(8);
        }
        return distance.len();
    }

    // -- track collision -----------------------------------------------------

    fn isOnFace(pos: Vec3, face: *const Face, alpha: f32) bool {
        const plane_point = pos.sub(face.normal.scale(alpha));
        const v0 = plane_point.sub(face.tris[0].vertices[1].pos);
        const v1 = plane_point.sub(face.tris[0].vertices[2].pos);
        const v2 = plane_point.sub(face.tris[0].vertices[0].pos);
        const v3 = plane_point.sub(face.tris[1].vertices[0].pos);
        const angle = v0.angleBetween(v2) + v2.angleBetween(v3) + v3.angleBetween(v1) + v1.angleBetween(v0);
        return angle > on_face_angle;
    }

    fn resolveWingCollision(self: *Ship, track: *const Track, face: *const Face, direction: f32) void {
        const section = &track.sections[self.section];
        const collision_vector = section.center.sub(face.tris[0].vertices[2].pos);
        const angle = collision_vector.angleBetween(self.forward());
        self.velocity = self.velocity.reflect(face.normal, 2);
        self.position = self.position.sub(self.velocity.scale(0.015625));
        self.velocity = self.velocity.sub(self.velocity.scale(0.5));
        self.velocity = self.velocity.add(face.normal.scale(4096.0));

        const magnitude = (@abs(angle) * self.speed) * 2 * math.pi / 4096.0;
        if (direction > 0) {
            self.angular_velocity.z += magnitude;
        } else {
            self.angular_velocity.z -= magnitude;
        }
        if (self.last_impact_time > 0.2) self.last_impact_time = 0;
    }

    fn resolveNoseCollision(self: *Ship, face: *const Face, direction: f32) void {
        self.velocity = self.velocity.reflect(face.normal, 2);
        self.position = self.position.sub(self.velocity.scale(0.015625));
        self.velocity = self.velocity.sub(self.velocity.scale(0.5));
        self.velocity = self.velocity.add(face.normal.scale(4096));

        const magnitude = ((self.speed * 0.0625) + 400) * 2 * math.pi / 4096.0;
        if (direction > 0) {
            self.angular_velocity.y += magnitude;
        } else {
            self.angular_velocity.y -= magnitude;
        }
        if (self.last_impact_time > 0.2) self.last_impact_time = 0;
    }

    /// Test nose and wing tips against the wall face on the ship's side of
    /// the section. Faces are addressed relative to the base face exactly
    /// as the original walks its face pointer, including the junction
    /// special cases that look at the neighbouring section's faces.
    fn collideWithTrack(self: *Ship, ctx: Context, base: usize) void {
        const track = ctx.track;
        const faces = track.faces;
        const section = &track.sections[self.section];
        const next = &track.sections[section.next];

        var direction = next.center.sub(section.center);
        const down_track = direction.dot(self.forward());
        self.flags.direction_forward = down_track >= 0;

        const base_face = &faces[base];
        const to_face_vector = base_face.tris[0].vertices[0].pos.sub(base_face.tris[0].vertices[1].pos);
        direction = section.center.sub(self.position);
        const to_face = direction.dot(to_face_vector);

        const junction_start = (section.flags & SectionFlags.junction_start) != 0;
        const junction_end = (section.flags & SectionFlags.junction_end) != 0;
        const next_faces: usize = next.face_start;
        const prev_faces: usize = track.sections[section.prev].face_start;

        if (to_face > 0) {
            self.flags.left_side = true;
            if (base == 0) return;
            const face = &faces[base - 1];
            const face_point = face.tris[0].vertices[0].pos;

            var alpha = self.nose().distanceToPlane(face_point, face.normal);
            if (alpha <= 0) {
                if (junction_start) {
                    if (isOnFace(self.nose(), face, alpha)) {
                        self.resolveNoseCollision(face, -down_track);
                    } else if (isOnFace(self.nose(), &faces[next_faces], alpha)) {
                        self.resolveNoseCollision(face, -down_track);
                    }
                } else if (junction_end) {
                    if (isOnFace(self.nose(), face, alpha)) {
                        self.resolveNoseCollision(face, -down_track);
                    } else if (isOnFace(self.nose(), &faces[prev_faces], alpha)) {
                        self.resolveNoseCollision(face, -down_track);
                    }
                } else {
                    self.resolveNoseCollision(face, -down_track);
                }
                return;
            }

            alpha = self.wingLeft().distanceToPlane(face_point, face.normal);
            if (alpha <= 0) {
                if (junction_start or junction_end) {
                    if (isOnFace(self.wingLeft(), face, alpha)) self.resolveNoseCollision(face, -down_track);
                } else {
                    self.resolveWingCollision(track, face, -down_track);
                }
                return;
            }

            alpha = self.wingRight().distanceToPlane(face_point, face.normal);
            if (alpha <= 0) {
                if (junction_start or junction_end) {
                    if (isOnFace(self.wingRight(), face, alpha)) self.resolveNoseCollision(face, -down_track);
                } else {
                    self.resolveWingCollision(track, face, -down_track);
                }
                return;
            }
        } else {
            self.flags.left_side = false;
            var face_index = base + 1;
            while (face_index + 1 < faces.len and (faces[face_index].flags & FaceFlags.track_base) != 0) face_index += 1;
            const face = &faces[face_index];
            const face_point = face.tris[0].vertices[0].pos;

            var alpha = self.nose().distanceToPlane(face_point, face.normal);
            if (alpha <= 0) {
                if (junction_start) {
                    if (isOnFace(self.nose(), face, alpha)) {
                        self.resolveNoseCollision(face, down_track);
                    } else if (isOnFace(self.nose(), &faces[@min(next_faces + 3, faces.len - 1)], alpha)) {
                        self.resolveNoseCollision(face, -down_track);
                    }
                } else if (junction_end) {
                    if (isOnFace(self.nose(), face, alpha)) {
                        self.resolveNoseCollision(face, -down_track);
                    } else {
                        const face2 = &faces[@min(prev_faces + 3, faces.len - 1)];
                        if (isOnFace(self.nose(), face2, alpha)) self.resolveNoseCollision(face2, -down_track);
                    }
                } else {
                    self.resolveNoseCollision(face, down_track);
                }
                return;
            }

            alpha = self.wingLeft().distanceToPlane(face_point, face.normal);
            if (alpha <= 0) {
                if (junction_start or junction_end) {
                    if (isOnFace(self.wingLeft(), face, alpha)) self.resolveNoseCollision(face, down_track);
                } else {
                    self.resolveWingCollision(track, face, down_track);
                }
                return;
            }

            alpha = self.wingRight().distanceToPlane(face_point, face.normal);
            if (alpha <= 0) {
                if (junction_start or junction_end) {
                    if (isOnFace(self.wingRight(), face, alpha)) self.resolveNoseCollision(face, down_track);
                } else {
                    self.resolveWingCollision(track, face, down_track);
                }
                return;
            }
        }
    }

    // -- drawing -------------------------------------------------------------

    pub fn draw(self: *const Ship, r: *render.Renderer, models: *const Models) void {
        const model = &models.objects[defs.pilotToModel(self.pilot)];
        model.draw(r, &self.mat);
    }

    /// Project a triangle under the ship onto the base face and draw it as
    /// a translucent shadow. Caller sets depth write off and depth offset.
    pub fn drawShadow(self: *const Ship, r: *render.Renderer, track: *const Track, models: *const Models) void {
        const face = track.baseFace(&track.sections[self.section]);
        const face_point = face.tris[0].vertices[0].pos;
        var nose_p = Vec3.init(0, 0, 384).transform(&self.mat);
        var wngl = Vec3.init(-256, 0, -384).transform(&self.mat);
        var wngr = Vec3.init(256, 0, -384).transform(&self.mat);
        nose_p = nose_p.sub(face.normal.scale(nose_p.distanceToPlane(face_point, face.normal)));
        wngl = wngl.sub(face.normal.scale(wngl.distanceToPlane(face_point, face.normal)));
        wngr = wngr.sub(face.normal.scale(wngr.distanceToPlane(face_point, face.normal)));

        const color = Rgba.init(0, 0, 0, 128);
        r.pushTris(.{ .vertices = .{
            .{ .pos = wngl, .uv = Vec2.init(0, 256), .color = color },
            .{ .pos = wngr, .uv = Vec2.init(128, 256), .color = color },
            .{ .pos = nose_p, .uv = Vec2.init(64, 0), .color = color },
        } }, models.shadow_texture_start + (self.pilot >> 1));
    }
};

/// Ship meshes and shadow textures shared by all ships.
pub const Models = struct {
    objects: []object.Object,
    shadow_texture_start: u16,

    pub fn deinit(self: *Models, gpa: std.mem.Allocator) void {
        object.free(gpa, self.objects);
    }
};

const exhaust_plume_color = Rgba.init(180, 97, 120, 140);

pub fn loadModels(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer) !Models {
    const objects = try scene.loadModel(gpa, assets, r, "wipeout/common", "allsh.cmp", "allsh.prm");
    errdefer object.free(gpa, objects);
    if (objects.len < defs.num_pilots) return error.MissingShipModels;

    // Engine polygons render translucent in the exhaust colour.
    for (objects) |*obj| {
        for (obj.primitives) |*prim| {
            if ((prim.flag & object.Flags.ship_engine) != 0) {
                prim.flag |= object.Flags.translucent;
                prim.color = .{ exhaust_plume_color, exhaust_plume_color, exhaust_plume_color, exhaust_plume_color };
            }
        }
    }

    const shadow_start = r.texturesLen();
    const names = [_][]const u8{ "wipeout/textures/shad1.tim", "wipeout/textures/shad2.tim", "wipeout/textures/shad3.tim", "wipeout/textures/shad4.tim" };
    for (names) |name| {
        const data = try assets.load(name);
        defer gpa.free(data);
        const img = try image.decodeTim(gpa, data, true);
        defer img.deinit(gpa);
        _ = try r.createTexture(img.width, img.height, img.pixels);
    }

    return .{ .objects = objects, .shadow_texture_start = shadow_start };
}
