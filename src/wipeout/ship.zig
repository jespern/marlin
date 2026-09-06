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

// Scalar constants stay f64: the reference applies them in double
// expressions and narrows to float only on assignment.
const pitch_accel: f64 = defs.ntscAcceleration(defs.angleNormToRadian(defs.fixedToFloat(30.0 * (1.0 / 16.0))));
const thrust_rate: f64 = defs.ntscVelocity(16);
const thrust_falloff: f64 = defs.ntscVelocity(8);
const brake_rate: f64 = defs.ntscVelocity(32);
/// Pitch correction applied while the nose is clear of the track.
const nose_up_accel: f64 = defs.ntscAcceleration(defs.angleNormToRadian(defs.fixedToFloat(-50.0 / 16.0)));

inline fn f(x: f64) f32 {
    return @floatCast(x);
}

/// Sum-of-angles threshold that decides whether a projected point lies on
/// a track face (a full turn less a safety margin).
const on_face_angle: f64 = 0.91552734375 * math.pi64 * 2.0;

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

pub const Mode = enum(u8) { intro, race, rescue, ai_intro, ai_race };

/// How an AI ship positions itself across the track this decision period.
pub const Strategy = enum(u8) { hold_center, hold_left, hold_right, block, avoid, avoid_other, zig_zag };

const update_time_just_front: f32 = 150.0 / 30.0;
const update_time_just_behind: f32 = 200.0 / 30.0;
const update_time_in_sight: f32 = 200.0 / 30.0;

/// Everything the flight model needs from outside the ship for one step.
pub const Context = struct {
    track: *const Track,
    input: *const input.State,
    rng: *Rng,
    /// Step length in seconds. f64 like the reference's `system_tick()`.
    tick: f64,
    start_line_pos: u16,
    /// Exponent applied to analog steering; 1 for digital input.
    analog_response: f32 = 1.0,
    /// Every ship in the race (including this one) and the player's index;
    /// the AI reads the others' positions and flags.
    ships: []const Ship = &.{},
    player: u8 = 0,
    /// Circuit tuning for the AI's catch-up speed.
    behind_speed: f32 = 300,
};

pub const Ship = extern struct {
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

    // AI ("remote") attributes; the player's are used after the race ends,
    // when the original hands the ship to the AI.
    remote_thrust_max: f32,
    remote_thrust_mag: f32,
    fight_back: u8,
    start_accelerate_timer: f32,
    position_rank: i32,
    strategy: Strategy,

    weapon_type: defs.WeaponType,
    /// Pilot index of the current weapon target, or -1.
    weapon_target: i32,
    ebolt_timer: f32,
    ebolt_effect_timer: f32,

    /// Place the ship on the start grid: `inv_start_rank` 0 is the back row
    /// (where the player always starts); odd ranks take the right-hand
    /// face of the grid section.
    /// `ai` is null for the player. `strength` scales the opponent tuning
    /// (1 = the original); `circuit` supplies the start-line stagger.
    pub fn init(track: *const Track, section_index: u32, pilot: u8, inv_start_rank: u8, class: defs.RaceClass, ai: ?defs.AiSetting, circuit: defs.CircuitSettings, strength: f32) Ship {
        const attributes = defs.shipAttributes(defs.pilot_team[pilot], class);
        const section = &track.sections[section_index];
        const p: f32 = @as(f32, @floatFromInt(inv_start_rank)) - 1;
        const stagger: f32 = p * (circuit.spread_base + p * circuit.spread_factor) * (1.0 / 30.0);

        var face_index: usize = @as(usize, section.face_start) + 1;
        if ((inv_start_rank % 2) != 0) face_index += 1;
        const face = &track.faces[@min(face_index, track.faces.len - 1)];
        const face_point = face.tris[0].vertices[0].pos.add(face.tris[0].vertices[2].pos).scale(0.5);

        const next = &track.sections[section.next];
        const direction = next.center.sub(section.center);

        return .{
            .pilot = pilot,
            .flags = .{ .racing = true, .visible = true, .direction_forward = true },
            .mode = if (ai != null) .ai_intro else .intro,
            .section = section_index,
            .prev_section = section_index,
            .position = face_point.add(face.normal.scale(200)),
            .velocity = Vec3.zero,
            .acceleration = Vec3.zero,
            .thrust = Vec3.zero,
            .angle = Vec3.init(0, f(-std.math.atan2(@as(f64, direction.x), @as(f64, direction.z))), 0),
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
            .remote_thrust_max = if (ai) |a| a.thrust_max * strength else 2900,
            .remote_thrust_mag = if (ai) |a| a.thrust_magnitude * strength else 46,
            .fight_back = if (ai) |a| @intFromBool(a.fight_back) else 0,
            .start_accelerate_timer = if (ai != null) stagger else 0,
            .position_rank = @as(i32, defs.num_pilots) - inv_start_rank,
            .strategy = .hold_center,
            .weapon_type = .none,
            .weapon_target = -1,
            .ebolt_timer = 0,
            .ebolt_effect_timer = 0,
        };
    }

    /// Begin racing immediately instead of hovering through the countdown.
    pub fn skipIntro(self: *Ship) void {
        self.mode = .race;
        self.update_timer = 0;
        self.current_thrust_max = self.thrust_max;
        self.temp_target = self.position;
    }

    pub fn finished(self: *const Ship) bool {
        return !self.flags.racing;
    }

    /// Sum of the recorded lap times.
    pub fn raceTime(self: *const Ship) f32 {
        var total: f32 = 0;
        for (self.lap_times) |t| total += t;
        return total;
    }

    pub fn bestLap(self: *const Ship) f32 {
        var best: f32 = 0;
        for (self.lap_times) |t| {
            if (t > 0 and (best == 0 or t < best)) best = t;
        }
        return best;
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

        self.last_impact_time = f(self.last_impact_time + ctx.tick);

        switch (self.mode) {
            .intro => self.updateIntro(ctx),
            .race => self.updateRace(ctx),
            .rescue => self.updateRescue(ctx),
            .ai_intro => self.updateAiIntro(ctx),
            .ai_race => self.updateAiRace(ctx),
        }

        self.mat = Mat4.identity;
        self.mat.setTranslation(self.position);
        self.mat.setYawPitchRoll(self.angle);

        self.updateLap(ctx);
    }

    fn updateLap(self: *Ship, ctx: Context) void {
        const track = ctx.track;
        self.lap_time = f(self.lap_time + ctx.tick);
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
                // Final lap complete for the player: the race is over and the
                // original hands the ship to the AI at a gentle cruise.
                if (self.lap == defs.num_laps and self.pilot == ctx.player and self.flags.racing) {
                    self.flags.racing = false;
                    self.remote_thrust_max = 3160;
                    self.remote_thrust_mag = 32;
                    self.speed = 3160;
                    self.mode = .ai_race;
                }
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
        self.update_timer = f(self.update_timer - ctx.tick);
        self.position.y = self.temp_target.y + @sin(f(@as(f64, self.update_timer) * 80.0 * 30.0 * math.pi64 * 2.0 / 4096.0)) * 32;

        const thrust_input: f64 = ctx.input.state(.thrust);
        if (thrust_input != 0) {
            self.thrust_mag = f(self.thrust_mag + thrust_input * thrust_rate * ctx.tick);
        } else {
            self.thrust_mag = f(self.thrust_mag - thrust_rate * ctx.tick);
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
        if (!self.flags.racing) {
            self.mode = .ai_race;
            return;
        }
        const track = ctx.track;
        const in: *const input.State = ctx.input;
        const tick = ctx.tick;
        const dt32: f32 = f(tick);
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

        self.angular_acceleration.x = f(self.angular_acceleration.x + @as(f64, in.state(.down)) * pitch_accel);
        self.angular_acceleration.x = f(self.angular_acceleration.x - @as(f64, in.state(.up)) * pitch_accel);

        // Stall or boost after the start, then normal thrust ceiling.
        if (self.update_timer > 0) {
            if (self.current_thrust_max < 500) {
                self.current_thrust_max = f(self.current_thrust_max + @as(f64, ctx.rng.float(0, 165)) * tick);
            }
            self.update_timer = f(self.update_timer - tick);
        } else {
            self.current_thrust_max = self.thrust_max;
        }

        const thrust_input: f64 = in.state(.thrust);
        if (thrust_input != 0) {
            self.thrust_mag = f(self.thrust_mag + thrust_input * thrust_rate * tick);
        } else {
            self.thrust_mag = f(self.thrust_mag - thrust_falloff * tick);
        }
        self.thrust_mag = std.math.clamp(self.thrust_mag, 0, self.current_thrust_max);

        if (in.state(.brake_right) != 0) {
            self.brake_right = f(self.brake_right + brake_rate * tick);
        } else if (self.brake_right > 0) {
            self.brake_right = f(self.brake_right - brake_rate * tick);
        }
        self.brake_right = std.math.clamp(self.brake_right, 0, 256);

        if (in.state(.brake_left) != 0) {
            self.brake_left = f(self.brake_left + brake_rate * tick);
        } else if (self.brake_left > 0) {
            self.brake_left = f(self.brake_left - brake_rate * tick);
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
            if (@as(f64, angle) < on_face_angle) self.flags.flying = true;
        }

        if (!self.flags.flying) {
            const base = track.baseFaceIndex(section);
            self.collideWithTrack(ctx, base);

            var face_index = base;
            if (!self.flags.left_side) face_index = @min(base + 1, track.faces.len - 1);
            const face = &track.faces[face_index];

            if (!self.flags.specialed and (face.flags & FaceFlags.boost) != 0) {
                const track_direction = track.sections[section.next].center.sub(section.center);
                self.velocity = self.velocity.add(track_direction.scale(f(30.0 * tick)));
            }

            const face_point = face.tris[0].vertices[0].pos;
            var height = self.position.distanceToPlane(face_point, face.normal);

            if (height <= 0) {
                if (self.last_impact_time > 0.2) self.last_impact_time = 0;
                self.velocity = self.velocity.reflect(face.normal, 2).scale(0.875);
                self.velocity = self.velocity.sub(face.normal.scale(f(64.0 * 30.0 * tick)));
            } else if (height < 30) {
                self.velocity = self.velocity.add(face.normal.scale(f(64.0 * 30.0 * tick)));
            }
            height = @max(height, 50);

            const brake = self.brake_left + self.brake_right;
            const resistance: f32 = f((@as(f64, self.resistance) * (max_resistance - (@as(f64, brake) * 0.125))) * 0.0078125);
            const track_repulsion: f32 = 4096 * ((track_magnet * track_float) / height - track_magnet);

            var force = on_track_gravity;
            force = force.add(face.normal.scale(track_repulsion));
            force = force.add(self.thrust);

            self.acceleration = forward_velocity.sub(self.velocity).div(f(@as(f64, self.skid) + @as(f64, brake) * 0.25));
            self.acceleration = self.acceleration.add(force.div(self.mass));
            self.acceleration = self.acceleration.sub(self.velocity.div(resistance));

            // Lift the nose when it dips towards the track.
            const nose_pos = Vec3.init(0, 0, 128).transform(&self.mat);
            const nose_height = nose_pos.distanceToPlane(face_point, face.normal);
            if (nose_height < 600) {
                const dip: f32 = height - nose_height + 5;
                self.angular_acceleration.x = f(self.angular_acceleration.x + defs.ntscAcceleration(defs.angleNormToRadian(defs.fixedToFloat(@as(f64, dip) * (1.0 / 16.0)))));
            } else {
                self.angular_acceleration.x = f(self.angular_acceleration.x + nose_up_accel);
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
                const resistance: f32 = f((@as(f64, self.resistance) * (max_resistance - (@as(f64, brake) * 0.125))) * 0.0078125);
                const force = flying_gravity.add(self.thrust);
                self.acceleration = forward_velocity.sub(self.velocity).div(min_resistance + brake * 4);
                self.acceleration = self.acceleration.add(force.div(self.mass));
                self.acceleration = self.acceleration.sub(self.velocity.div(resistance));
                self.angular_acceleration.x = f(self.angular_acceleration.x + nose_up_accel);
            }
        }

        // Integrate. Velocity is in units per PSX frame scaled by 64, which
        // is where the 0.015625 (1/64) and 30 factors come from.
        self.velocity = self.velocity.add(self.acceleration.scale(f(30.0 * tick)));
        self.position = self.position.add(self.velocity.scale(f(0.015625 * 30.0 * tick)));

        self.angular_acceleration.x = f(self.angular_acceleration.x - @as(f64, self.angular_velocity.x) * 0.25 * 30.0);
        self.angular_acceleration.z = f(self.angular_acceleration.z + (@as(f64, self.angular_velocity.y) - (0.5 * @as(f64, self.angular_velocity.z))) * 30.0);

        // Without steering input, bleed yaw rate off at the turn rate.
        if (self.angular_acceleration.y == 0) {
            if (self.angular_velocity.y > 0) {
                self.angular_acceleration.y = f(self.angular_acceleration.y - @min(@as(f64, self.turn_rate), @as(f64, self.angular_velocity.y) / tick));
            } else if (self.angular_velocity.y < 0) {
                self.angular_acceleration.y = f(self.angular_acceleration.y + @min(@as(f64, self.turn_rate), -@as(f64, self.angular_velocity.y) / tick));
            }
        }

        self.angular_velocity = self.angular_velocity.add(self.angular_acceleration.scale(dt32));
        self.angular_velocity.y = std.math.clamp(self.angular_velocity.y, -self.turn_rate_max, self.turn_rate_max);

        const brake_dir: f32 = f(@as(f64, self.brake_left - self.brake_right) * (0.125 / 4096.0));
        self.angle.y = f(self.angle.y + @as(f64, brake_dir) * @as(f64, self.speed) * 0.000030517578125 * math.pi64 * 2.0 * 30.0 * tick);

        self.angle = self.angle.add(self.angular_velocity.scale(dt32));
        self.angle.z = f(self.angle.z - @as(f64, self.angle.z) * 0.125 * 30.0 * tick);
        self.angle = self.angle.wrapAngles();

        // Going backwards onto a jump landing pushes the ship forward again.
        if (!self.flags.direction_forward and (track.sections[section.prev].flags & SectionFlags.jump) != 0) {
            const repulse = track.sections[section.next].center.sub(section.center);
            self.velocity = self.velocity.add(repulse.scale(2));
        }
    }

    // -- AI -----------------------------------------------------------------

    fn updateAiIntro(self: *Ship, ctx: Context) void {
        if (self.update_timer >= update_time_initial) self.temp_target = self.position;
        const rate: f64 = 80.0 + @as(f64, @floatFromInt(self.pilot)) * 3.0;
        self.position.y = self.temp_target.y + @sin(f(@as(f64, self.update_timer) * rate * 30.0 * math.pi64 * 2.0 / 4096.0)) * 32;
        self.update_timer = f(self.update_timer - ctx.tick);
        if (self.update_timer <= 0) self.mode = .ai_race;
    }

    fn holdLeft(face: *const Face) Vec3 {
        return face.tris[0].vertices[1].pos.sub(face.tris[0].vertices[0].pos).scale(0.5);
    }

    fn holdRight(face: *const Face) Vec3 {
        return face.tris[0].vertices[0].pos.sub(face.tris[0].vertices[1].pos).scale(0.5);
    }

    /// Lateral offset from the centre line for the current strategy.
    fn strategyOffset(self: *const Ship, ctx: Context, face: *const Face) Vec3 {
        const player_left = ctx.ships[ctx.player].flags.left_side;
        return switch (self.strategy) {
            .hold_center => Vec3.zero,
            .hold_left => holdLeft(face),
            .hold_right => holdRight(face),
            .block => if (player_left) holdLeft(face) else holdRight(face),
            .avoid => if (player_left) holdRight(face) else holdLeft(face),
            // The original's avoid-other never finds a ship to avoid (its
            // search threshold starts above its acceptance window), so it
            // holds the centre.
            .avoid_other => Vec3.zero,
            .zig_zag => blk: {
                const count: i32 = @intFromFloat(@floor(self.update_timer * 30.0 / 50.0));
                break :blk if (@mod(count, 2) == 1) holdRight(face) else holdLeft(face);
            },
        };
    }

    fn accelerateTowards(self: *Ship, ceiling: f32, magnitude: f32, dt: f32) void {
        if (ceiling > self.speed) self.speed += magnitude * 30 * dt;
    }

    /// The original's opponent controller: pick a lateral strategy and a
    /// target speed from the ship's relation to the player, then steer the
    /// craft along the section centre line plus that offset. Also drives
    /// the player's ship after the race is over.
    fn updateAiRace(self: *Ship, ctx: Context) void {
        const track = ctx.track;
        const dt: f32 = f(ctx.tick);
        const sections = track.sections;
        const player = &ctx.ships[ctx.player];
        const is_player = self.pilot == ctx.player;
        const behind_speed = ctx.behind_speed;

        if (self.ebolt_timer > 0) {
            self.ebolt_timer -= dt;
        } else {
            self.flags.electroed = false;
        }

        if (!self.flags.flying) {
            const section = &sections[self.section];
            const base = track.baseFaceIndex(section);
            const face = &track.faces[base];
            const section_diff: i32 = self.total_section_num - player.total_section_num;
            self.flags.just_in_front = false;

            if (is_player) {
                self.strategy = .avoid_other;
                self.accelerateTowards(self.remote_thrust_max, self.remote_thrust_mag, dt);
            } else if (self.start_accelerate_timer > 0) {
                // Staggered launch off the grid.
                self.start_accelerate_timer -= dt;
                self.update_timer = 0;
                self.strategy = .avoid;
                self.accelerateTowards(self.remote_thrust_max + 1200, self.remote_thrust_mag + 150, dt);
            } else if (section_diff < -10) {
                // Well behind: get out of the way and catch up.
                self.update_timer = 0;
                self.strategy = .avoid;
                self.accelerateTowards(self.remote_thrust_max + behind_speed, self.remote_thrust_mag, dt);
            } else if (section_diff <= 4 and section_diff > 0) {
                // Just ahead of the player.
                self.flags.just_in_front = true;
                if (self.update_timer <= 0) {
                    const chance = ctx.rng.int(0, 64);
                    self.update_timer = update_time_just_front;
                    if (self.fight_back != 0) {
                        // Block, mine, or shield: the latter two need the
                        // weapon systems and fall back to blocking for now.
                        self.strategy = .block;
                        _ = chance;
                    } else {
                        self.strategy = .avoid;
                    }
                }
                self.update_timer -= dt;
                if (self.flags.overtaken) {
                    self.accelerateTowards(self.remote_thrust_max + behind_speed, self.remote_thrust_mag, dt);
                } else {
                    self.accelerateTowards(self.remote_thrust_max + behind_speed * 0.5, self.remote_thrust_mag, dt);
                }
            } else if (section_diff >= -10 and section_diff <= 0) {
                // Just behind: decide whether to have a go back.
                if (self.update_timer <= 0) {
                    self.update_timer = update_time_just_behind;
                    if (self.fight_back != 0) {
                        if (self.weapon_type == .none) {
                            self.strategy = .avoid;
                            self.flags.overtaken = true;
                        } else {
                            const chance = ctx.rng.int(0, 64);
                            if (chance < 48) {
                                self.strategy = .block;
                            } else {
                                self.strategy = .avoid;
                                self.flags.overtaken = false;
                            }
                        }
                    } else {
                        self.remote_thrust_max = 2100;
                        self.remote_thrust_mag = 25;
                        self.speed = 2100;
                        self.strategy = .avoid;
                        self.flags.overtaken = false;
                    }
                }
                for (ctx.ships) |*other| {
                    if (other.flags.just_in_front) {
                        self.strategy = .avoid;
                        self.flags.overtaken = false;
                    }
                }
                self.update_timer -= dt;
                if (self.flags.overtaken) {
                    self.accelerateTowards(self.remote_thrust_max + 700, self.remote_thrust_mag * 2, dt);
                } else {
                    self.accelerateTowards(self.remote_thrust_max + behind_speed, self.remote_thrust_mag, dt);
                }
            } else if (section_diff > (@as(i32, defs.num_pilots) - self.position_rank) * 15 and section_diff < 150) {
                // Well ahead: ease off so the player can catch up.
                self.speed += self.remote_thrust_mag * 0.5 * 30 * dt;
                if (self.speed > self.remote_thrust_max * 0.5) self.speed = self.remote_thrust_max * 0.5;
                self.update_timer = 0;
                self.strategy = .hold_center;
            } else if (section_diff >= 150) {
                self.update_timer = 0;
                self.strategy = .avoid;
                self.accelerateTowards(self.remote_thrust_max, self.remote_thrust_mag, dt);
            } else if (section_diff <= 10 and section_diff > 4) {
                // In sight ahead: pick a line at random for a while.
                if (self.update_timer <= 0) {
                    self.update_timer = update_time_in_sight;
                    self.strategy = switch (ctx.rng.int(0, 5)) {
                        0 => .hold_center,
                        1 => .hold_left,
                        2 => .hold_right,
                        3 => .block,
                        else => .zig_zag,
                    };
                }
                self.update_timer -= dt;
                self.accelerateTowards(self.remote_thrust_max, self.remote_thrust_mag, dt);
            } else {
                self.update_timer = 0;
                self.strategy = .hold_center;
                self.accelerateTowards(self.remote_thrust_max, self.remote_thrust_mag, dt);
            }

            const offset = self.strategyOffset(ctx, face);

            // Junction choice, made a few sections ahead of one.
            var probe = sections[section.prev].next;
            var i: usize = 0;
            while (i < 3) : (i += 1) probe = sections[probe].next;
            if (sections[probe].junction != track_mod.none) {
                const junction = &sections[@intCast(sections[probe].junction)];
                if ((junction.flags & SectionFlags.junction_start) != 0) {
                    self.flags.junction_left = ctx.rng.int(0, 2) == 0;
                }
            }
            var ahead = section.prev;
            i = 0;
            while (i < 4) : (i += 1) {
                const s = &sections[ahead];
                if (s.junction != track_mod.none and
                    (sections[@intCast(s.junction)].flags & SectionFlags.junction_start) != 0 and
                    self.flags.junction_left)
                {
                    ahead = @intCast(s.junction);
                } else {
                    ahead = s.next;
                }
            }
            const next = &sections[sections[ahead].next];

            // Bleed speed while turning; boosts add some back.
            self.speed -= @abs(self.speed * self.angular_velocity.y) * 4 / (math.pi * 2) * dt;
            self.speed -= @abs(self.speed * self.angular_velocity.x) * 4 / (math.pi * 2) * dt;
            if ((face.flags & FaceFlags.boost) != 0 and (self.strategy == .hold_left or self.strategy == .hold_center)) {
                self.speed += 200 * 30 * dt;
            }
            const face2 = &track.faces[@min(base + 1, track.faces.len - 1)];
            if ((face2.flags & FaceFlags.boost) != 0 and (self.strategy == .hold_right or self.strategy == .hold_center)) {
                self.speed += 200 * 30 * dt;
            }

            var track_target = if ((section.flags & SectionFlags.jump) != 0)
                section.center.sub(sections[section.prev].center)
            else
                next.center.sub(section.center);
            const gap_length = track_target.len();
            track_target = track_target.scale(self.speed / gap_length);

            const path1 = section.center.add(offset);
            const path2 = next.center.add(offset);
            const best_path = self.position.projectToRay(path2, path1);
            self.acceleration = track_target.add(best_path.sub(self.position).scale(0.5));

            const face_point = face2.tris[0].vertices[0].pos;
            var height = self.position.distanceToPlane(face_point, face2.normal);
            height = @max(height, 50);
            const lift = face2.normal.scale((track_float * track_magnet) / height).sub(face2.normal.scale(track_magnet)).scale(16.0);
            self.acceleration = self.acceleration.add(lift);
            self.velocity = self.velocity.add(self.acceleration.scale(30 * dt));

            const xy_dist = track_target.mul(Vec3.init(1, 0, 1)).len();
            self.angular_velocity.x = math.wrapAngle(f(-std.math.atan2(@as(f64, track_target.y), @as(f64, xy_dist)) - @as(f64, self.angle.x))) * (1.0 / 16.0) * 30;
            self.angular_velocity.y = math.wrapAngle(f(-std.math.atan2(@as(f64, track_target.x), @as(f64, track_target.z)) - @as(f64, self.angle.y))) * (1.0 / 16.0) * 30 + self.turn_rate_from_hit;
        } else {
            // Airborne: aim two sections ahead and fall.
            const section = &sections[sections[sections[self.section].next].next];
            const next = &sections[section.next];
            self.strategy = .hold_center;
            if (self.remote_thrust_max > self.speed) self.speed += self.remote_thrust_mag;
            self.speed -= @abs(self.speed * self.angular_velocity.y) * (4 * math.pi * 2) * dt;

            var track_target = next.center.sub(section.center);
            const gap_length = track_target.len();
            track_target.x = (track_target.x * self.speed) / gap_length;
            track_target.z = (track_target.z * self.speed) / gap_length;
            track_target.y = 500;

            const best_path = self.position.projectToRay(next.center, sections[self.section].center);
            self.acceleration = Vec3.init(
                track_target.x + ((best_path.x - self.position.x) * 0.5),
                track_target.y,
                track_target.z + ((best_path.z - self.position.z) * 0.5),
            );
            self.velocity = self.velocity.add(self.acceleration.scale(30 * dt));
            self.angular_velocity.x = -0.3 - self.angle.x * 30;
            self.angular_velocity.y = math.wrapAngle(f(-std.math.atan2(@as(f64, track_target.x), @as(f64, track_target.z)) - @as(f64, self.angle.y))) * (1.0 / 16.0) * 30;
        }

        self.angular_velocity.z += (self.angular_velocity.y * 2.0 - self.angular_velocity.z * 0.5) * 30 * dt;
        self.turn_rate_from_hit -= self.turn_rate_from_hit * 0.125 * 30 * dt;

        self.angle = self.angle.add(self.angular_velocity.scale(dt));
        self.angle.z -= self.angle.z * 0.125 * 30 * dt;
        self.angle = self.angle.wrapAngles();

        self.velocity = self.velocity.sub(self.velocity.scale(0.125 * 30 * dt));
        self.position = self.position.add(self.velocity.scale(0.015625 * 30 * dt));

        if (self.flags.electroed) {
            self.ebolt_effect_timer += dt;
            if (self.ebolt_effect_timer > 0.1) {
                self.ebolt_effect_timer -= 0.1;
                self.position = self.position.add(Vec3.init(ctx.rng.float(-20, 20), ctx.rng.float(-20, 20), ctx.rng.float(-20, 20)));
                if (ctx.rng.int(0, 10) == 0) self.speed -= self.speed * 0.5;
            }
        }
    }

    // -- ship-to-ship collision --------------------------------------------

    /// Tetrahedral collision hulls: does any edge of `other`'s hull pass
    /// through a face of ours?
    fn intersects(self: *const Ship, other: *const Ship, models: *const Models) bool {
        const om = &models.collision[defs.pilotToModel(other.pilot)];
        const sm = &models.collision[defs.pilotToModel(self.pilot)];
        if (om.vertices.len < 4 or sm.vertices.len < 4) return false;
        const a = om.vertices[0].transform(&other.mat);
        const b = om.vertices[1].transform(&other.mat);
        const c = om.vertices[2].transform(&other.mat);
        const d = om.vertices[3].transform(&other.mat);
        const other_points = [6]Vec3{ b, a, d, a, a, b };
        const other_lines = [6]Vec3{ c.sub(b), c.sub(a), c.sub(d), b.sub(a), d.sub(a), d.sub(b) };

        for (sm.primitives) |prim| {
            switch (prim.kind) {
                .f3, .g3, .ft3, .gt3 => {},
                else => continue,
            }
            const p1 = sm.vertices[prim.coords[0]].transform(&self.mat);
            const p2 = sm.vertices[prim.coords[1]].transform(&self.mat);
            const p3 = sm.vertices[prim.coords[2]].transform(&self.mat);
            const plane = p2.sub(p1).cross(p3.sub(p1));
            for (other_points, other_lines) |point, line| {
                const dp1 = p1.sub(point).dot(plane);
                const dp2 = line.dot(plane);
                if (dp2 == 0) continue;
                const norm = dp1 / dp2;
                if (norm < 0 or norm > 1) continue;
                const hit = point.add(line.scale(norm));
                const v0 = p1.sub(hit);
                const v1 = p2.sub(hit);
                const v2 = p3.sub(hit);
                const angle = v0.angleBetween(v1) + v1.angleBetween(v2) + v2.angleBetween(v0);
                if (angle >= math.pi * 2 - math.pi * 0.1) return true;
            }
        }
        return false;
    }

    /// Resolve a collision between two ships as the original does: move to
    /// the common velocity, back both out, and push them apart.
    pub fn collideWithShip(self: *Ship, other: *Ship, models: *const Models) void {
        const distance = self.position.sub(other.position).len();
        if (distance > 960) {
            self.flags.coll = false;
            other.flags.coll = false;
            return;
        }
        if (!self.intersects(other, models)) return;

        const vc = self.velocity.scale(self.mass).add(other.velocity.scale(other.mass)).div(self.mass + other.mass);
        const self_react = vc.sub(self.velocity).scale(0.5);
        const other_react = vc.sub(other.velocity).scale(0.5);
        self.position = self.position.sub(self.velocity.scale(0.015625));
        other.position = other.position.sub(other.velocity.scale(0.015625));
        self.velocity = vc.add(self_react);
        other.velocity = vc.add(other_react);

        const res = self.position.sub(other.position);
        self.velocity = self.velocity.add(res.scale(4));
        self.position = self.position.add(self.velocity.scale(0.015625));
        other.velocity = other.velocity.sub(res.scale(4));
        other.position = other.position.add(other.velocity.scale(0.015625));

        if (!self.flags.coll and !other.flags.coll and self.last_impact_time > 0.2) self.last_impact_time = 0;
        self.flags.coll = true;
        other.flags.coll = true;
    }

    /// Towed back onto the track. The original has the rescue droid fly to
    /// the ship first and set `in_tow` on arrival; without the droid the
    /// tow starts immediately.
    fn updateRescue(self: *Ship, ctx: Context) void {
        const track = ctx.track;
        const tick = ctx.tick;
        const section = &track.sections[self.section];
        const next = &track.sections[section.next];

        if (self.flags.in_tow) {
            self.temp_target = self.temp_target.add(next.center.sub(self.temp_target).scale(0.0078125));
            self.velocity = self.temp_target.sub(self.position);
            const target_dir = next.center.sub(section.center);
            const heading = -std.math.atan2(@as(f64, target_dir.x), @as(f64, target_dir.z));
            self.angular_velocity.y = f(@as(f64, math.wrapAngle(f(heading - @as(f64, self.angle.y)))) * 0.015625 * 30.0);
            self.angle.y = math.wrapAngle(f(@as(f64, self.angle.y) + @as(f64, self.angular_velocity.y) * tick));
        }

        self.angle.x = f(self.angle.x - @as(f64, self.angle.x) * 0.125 * 30.0 * tick);
        self.angle.z = f(self.angle.z - @as(f64, self.angle.z) * 0.03125 * 30.0 * tick);

        self.velocity = self.velocity.sub(self.velocity.scale(f(0.0625 * 30.0 * tick)));
        self.position = self.position.add(self.velocity.scale(f(0.03125 * 30.0 * tick)));

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
            distance.y = f(@as(f64, distance.y) * 0.0001);
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
        return @as(f64, angle) > on_face_angle;
    }

    fn resolveWingCollision(self: *Ship, track: *const Track, face: *const Face, direction: f32) void {
        const section = &track.sections[self.section];
        const collision_vector = section.center.sub(face.tris[0].vertices[2].pos);
        const angle = collision_vector.angleBetween(self.forward());
        self.velocity = self.velocity.reflect(face.normal, 2);
        self.position = self.position.sub(self.velocity.scale(0.015625));
        self.velocity = self.velocity.sub(self.velocity.scale(0.5));
        self.velocity = self.velocity.add(face.normal.scale(4096.0));

        const magnitude: f32 = f(@as(f64, (@abs(angle) * self.speed) * 2) * math.pi64 / 4096.0);
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

        const magnitude: f32 = f(((@as(f64, self.speed) * 0.0625) + 400.0) * 2.0 * math.pi64 / 4096.0);
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
    /// Four-vertex collision hulls in the same pilot order as `objects`.
    collision: []object.Object,
    shadow_texture_start: u16,

    pub fn deinit(self: *Models, gpa: std.mem.Allocator) void {
        object.free(gpa, self.objects);
        object.free(gpa, self.collision);
    }
};

const exhaust_plume_color = Rgba.init(180, 97, 120, 140);

pub fn loadModels(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer) !Models {
    const objects = try scene.loadModel(gpa, assets, r, "wipeout/common", "allsh.cmp", "allsh.prm");
    errdefer object.free(gpa, objects);
    if (objects.len < defs.num_pilots) return error.MissingShipModels;
    const collision = try scene.loadModel(gpa, assets, r, "wipeout/common", "alcol.cmp", "alcol.prm");
    errdefer object.free(gpa, collision);
    if (collision.len < defs.num_pilots) return error.MissingShipModels;

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

    return .{ .objects = objects, .collision = collision, .shadow_texture_start = shadow_start };
}
