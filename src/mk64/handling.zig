//! Grounded Mario/100cc controller slice, ported from player_controller.c.
//! Original throttle, braking, steering stages and longitudinal force equations.
//! The contact solver, orientation/slip integration and camera are still adapters;
//! this is not yet the complete original controller (full suspension/status effects omitted).
const std = @import("std");
const tables = @import("handling_tables.zig");
const Vec3 = @import("course.zig").Vec3;
pub const Input = struct { accelerate: bool = false, brake: bool = false, left: bool = false, right: bool = false, hop: bool = false };
const acceleration = [_]f32{ 2, 2, 2, 1.6, 1.4, 1.2, 1, 0.8, 0.6, 0.4 };
// D_800E2CB0 (rear and front-left), D_800E2AD0 (front-right), Mario.
const rear_loss = [_]f32{ 0, 0, 0, 0.03, 0, 0, 0, 0.09, 0.09, 0, 0, 0.09, 0, 0.09, 0.09 };
const front_loss = [_]f32{ 0, 0, 0, 0, 0, 0, 0, 0.03, 0.03, 0, 0, 0.03, 0, 0.03, 0.03 };
// D_800E2ED0 / D_800E3210, Mario rear-tyre brake loss.
const brake_loss = [_]f32{ 0, 0, 0.2, 0.2, 0, 0.4, 0.1, 0.2, 0.2, 0, 0, 0, 0, 0, 0 };
pub const Contact = struct {
    // Back right, back left, front right, front left (original accumulation order).
    surfaces: [4]u8 = .{ 1, 1, 1, 1 },
    slope_degrees: i16 = 0,
};

pub const Controller = struct {
    drift: @import("drift.zig").State = .{},
    throttle: f32 = 0, // currentSpeed, not world-space speed
    engine: @import("engine.zig").Class = .cc100,
    spin_ticks: u8 = 0,
    hit_immunity: u8 = 0,
    mushroom_ticks: u8 = 0,
    mushroom_force: f32 = 0,
    top_speed: f32 = 310, // Mario, 100cc
    velocity: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    previous_speed: f32 = 0,
    brake_ramp: f32 = 0, // unk_20C
    force_loss: f32 = 0, // unk_104
    steer_position: i32 = 0, // original signed 16.16 value
    steer_increment: u32 = 0,
    lateral_force: f32 = 0, // unk_090, preserved by original steering stage calls
    yaw_step: i16 = 0,
    drift_outside: bool = false,
    drift_slip: i32 = 0, // func_8002AE38 angle units, using planar displacement

    pub fn speed(self: Controller) f32 {
        return self.velocity.length();
    }

    /// player_accelerate_alternative, no triple-A boost or status effects.
    /// Separate ifs matter: crossing a band applies the next band in the SAME tick.
    pub fn accelerate(self: *Controller, slope_degrees: i16) void {
        for (acceleration, 0..) |amount, i| {
            const lower = @as(f64, self.top_speed) * (@as(f64, @floatFromInt(i)) / 10);
            const upper = @as(f64, self.top_speed) * (@as(f64, @floatFromInt(i + 1)) / 10);
            if (self.throttle >= lower and (self.throttle < upper or (i == 9 and self.throttle == upper)))
                self.throttle = @floatCast(@as(f64, self.throttle) + @as(f64, amount) + 0.05 * @as(f64, @floatFromInt(slope_degrees)));
        }
        self.throttle = std.math.clamp(self.throttle, 0, self.top_speed);
    }

    fn decelerate(self: *Controller, amount: f32) void {
        self.throttle = std.math.clamp(self.throttle - amount, 0, self.top_speed);
    }

    /// func_800323E4, normal B braking (no AB spin or triple-B combo).
    pub fn brake(self: *Controller, contact: Contact) void {
        const loss = lookup(&brake_loss, contact.surfaces[0]) + lookup(&brake_loss, contact.surfaces[1]);
        if (self.previous_speed - self.speed() <= 0) self.brake_ramp = 0 else self.brake_ramp = @min(2, @as(f32, @floatCast(@as(f64, self.brake_ramp) + 0.02)));
        if (self.speed() / 18 * 216 <= 20) self.decelerate((1 - loss) * 4);
        self.decelerate(if (self.brake_ramp >= 2) @floatCast(@as(f64, 1 - loss) * 2.5) else @floatCast(@as(f64, 1 - loss) * 1.2));
    }

    /// func_80033AE0 normal-ground steering branch, Mario. Input is the already
    /// deadzoned stick range [-53,53]; keyboard keys correspond to full deflection.
    pub fn steer(self: *Controller, desired: i32, braking: bool, slip_degrees: i32) void {
        const wanted = std.math.clamp(desired, -53, 53) * 65536;
        var position = self.steer_position;
        const delta = (position - wanted) >> 16;
        const kmh = self.speed() / 18 * 216;
        var large: i32 = 8;
        var small: i32 = 8;
        if (kmh >= 15) {
            // func_80033AE0 clears LEFT_TURN/RIGHT_TURN during hop/drift.
            if (self.drift.hopping or self.drift.drifting) {
                large = if (self.drift.drifting and !self.drift.hopping) 6 else 3;
                small = if (self.drift.drifting and !self.drift.hopping) 9 else 6;
            } else if ((slip_degrees > 5 and delta >= 0 and delta <= 35) or (slip_degrees < -5 and delta <= 0 and delta >= -35)) {
                large = 15;
                small = 15;
            } else if (@abs(slip_degrees) > 5) {
                large = 5;
                small = 9;
            } else {
                large = 3;
                small = 6;
            }
        }
        for (tables.steps) |step| {
            if (delta >= step.threshold or delta <= -step.threshold) {
                const old = self.steer_increment;
                self.steer_increment -%= 2048;
                if (self.steer_increment >= 0xf0000000) self.steer_increment = old;
                const minimum = @divTrunc(step.minimum, if (step.large) large else small);
                self.steer_increment = @max(self.steer_increment, @as(u32, @intCast(minimum)));
                const increment: i32 = @intCast(self.steer_increment);
                position = if (wanted < position) position - increment else position + increment;
                if (step.large) self.lateral_force = -step.lateral else self.lateral_force = @min(0, self.lateral_force + step.lateral);
            }
        }
        self.steer_position = position;
        const stick = position >> 16;
        var factor: f32 = if (self.drift.drifting) @floatFromInt(@divTrunc(stick, 8)) else if (kmh <= 25) @floatFromInt(@divTrunc(stick, 12)) else @as(f32, @floatFromInt(stick)) / (8 + self.throttle / 50);
        factor = @abs(factor) * tables.speed_turn[@intFromFloat(std.math.clamp(kmh, 0, 155))] * @as(f32, if (self.drift.drifting) 1 else 1.5);
        const turn: f64 = if (braking) @as(f64, @floatFromInt(stick)) * (@as(f64, factor) + (if (kmh < 8) @as(f64, 0) else if (kmh < 65) @as(f64, 1.5) else 1.6)) else @as(f64, @floatFromInt(stick)) * factor * (if (@abs(stick) >= 45) @as(f64, 1.4) else 1.25);
        self.yaw_step = @intFromFloat(turn);
        self.drift_outside = false;
        if (self.drift.hopping) {
            const air_stick: f32 = @floatFromInt(if (desired == 0) @as(i32, 0) else stick);
            self.yaw_step = @intFromFloat(air_stick * (factor + @as(f32, if (kmh <= 5) 6 else 1.5)));
        } else if (self.drift.drifting) {
            const mapped = @divTrunc(stick * 13 + 13 * 53, 106) + @as(i32, if (slip_degrees > 0) 40 else -53);
            const outside = if (slip_degrees > 0) stick <= -40 else stick >= 40;
            self.drift_outside = outside;
            const bonus: f64 = if (kmh < 8) 2 else if (kmh < 65) 3 else 3.5;
            const raw: i16 = @intFromFloat(@as(f64, @floatFromInt(mapped)) * (@as(f64, factor) + bonus));
            self.yaw_step = @intFromFloat(@as(f64, @floatFromInt(raw)) * @as(f64, if (outside) 0.9 else 0.65));
            self.drift.chargeStep(stick, slip_degrees);
        } else {
            self.drift.counter = 0;
            if (self.drift.charge < 2) self.drift.charge = 0;
        }
    }

    fn rotationStep(self: Controller) i16 {
        return if (self.drift_outside and self.drift.counter < 100) 0 else self.yaw_step;
    }

    fn driftForce(self: Controller) Vec3 {
        if (!self.drift.drifting or self.drift.hopping or self.yaw_step == 0) return .{ .x = 0, .y = 0, .z = 0 };
        const speed_now = self.speed();
        const kmh = speed_now / 18 * 216;
        const side: f32 = if (self.yaw_step > 0) 1 else -1;
        const lateral = self.lateral_force + self.engine.lateral() - kmh * 3 - self.brake_ramp * @as(f32, if (self.yaw_step > 0) 10 else 50);
        return .{ .x = side * lateral * speed_now, .y = 0, .z = speed_now * (self.engine.drag() - 30) };
    }

    /// One original 1/60-second simulation step. Single-player runs two per
    /// presentation frame (main.c: SCREEN_MODE_1P, gTickSpeed=2).
    pub fn tick(self: *Controller, yaw: *f32, controls: Input, contact: Contact) void {
        self.hit_immunity -|= 1;
        const input: Input = if (self.spin_ticks > 0) .{} else controls;
        self.spin_ticks -|= 1;
        const old_speed = self.speed();
        const heading = if (old_speed > 0.1) std.math.atan2(self.velocity.x, -self.velocity.z) else yaw.*;
        const slip = std.math.clamp(@mod(yaw.* - heading + std.math.pi, 2 * std.math.pi) - std.math.pi, -1.5, 1.5);
        // Drift branch of func_8002AE38: doubled displacement angle, +/-40
        // degree clamp and integer 1/12 smoothing. Full normal-slip logic remains
        // an adapter; drift uses the original filtered angle rather than raw yaw.
        const raw_slip: i32 = @intFromFloat(slip * 65536 / (2 * std.math.pi));
        if (self.drift.drifting) {
            const target = std.math.clamp(raw_slip * 2, -0x1c70, 0x1c70);
            self.drift_slip += @divTrunc(target - self.drift_slip, 12);
        } else self.drift_slip = raw_slip;
        const slip_degrees: i32 = @divTrunc(self.drift_slip, 182);
        const was_drifting = self.drift.drifting;
        self.drift.begin(input.hop, old_speed * 12, slip_degrees);
        // cancel_drift_effect preserves the slide's steering direction on release.
        if (was_drifting and !self.drift.drifting and slip_degrees != 0) {
            const mapped = @divTrunc((self.steer_position >> 16) * 13 + 13 * 53, 106) + @as(i32, if (slip_degrees > 0) 40 else -53);
            self.steer_position = mapped * 65536;
        }
        self.steer((@as(i32, if (input.right) 1 else 0) - @as(i32, if (input.left) 1 else 0)) * 53, input.brake, slip_degrees);
        if (input.accelerate) self.accelerate(contact.slope_degrees) else self.decelerate(1);
        if (input.brake) self.brake(contact) else self.brake_ramp = 0;
        // func_80037BB4: countersteering keeps lateral force but suppresses yaw.
        const rotation_step = self.rotationStep();
        yaw.* = @mod(yaw.* + @as(f32, @floatFromInt(rotation_step)) * (2 * std.math.pi / 65536.0) + std.math.pi, 2 * std.math.pi) - std.math.pi;
        var loss: f32 = 0;
        const kmh = old_speed / 18 * 216;
        if (kmh >= 8) {
            loss += lookup(&rear_loss, contact.surfaces[0]);
            loss += lookup(&rear_loss, contact.surfaces[1]);
            loss += lookup(&front_loss, contact.surfaces[2]);
            loss += lookup(&rear_loss, contact.surfaces[3]);
            if (kmh >= 20) {
                const slope: f64 = @floatFromInt(contact.slope_degrees);
                loss = @floatCast(@as(f64, loss) - slope * (if (@abs(contact.slope_degrees) > 17) @as(f64, 0.0126) else 0.026) / 3);
            } else loss = @floatCast(@as(f64, loss) - 0.2);
            loss = @floatCast(@as(f64, loss) + @as(f64, @floatFromInt(@abs(slip_degrees))) * @as(f64, if (self.drift.drifting) 0.004 else 0.01));
        } else if (contact.slope_degrees < 0) loss = -0.85;
        const outside = if (slip_degrees > 0) (self.steer_position >> 16) <= -40 else (self.steer_position >> 16) >= 40;
        if (self.drift.drifting and !self.drift.hopping and outside and self.drift.counter < 10)
            loss = @floatCast(@as(f64, loss) + @as(f64, @floatFromInt(@abs(slip_degrees))) * 0.008);
        self.force_loss = @floatCast(@as(f64, self.force_loss) + (@as(f64, loss) - self.force_loss) * 0.05);
        // effects.c apply_mushroom_effect: 80-tick timer, 400 power, .5/.1 ramp.
        if (self.mushroom_ticks > 0 or self.mushroom_force > 1) {
            self.throttle = self.top_speed;
            self.mushroom_ticks -|= 1;
            const target: f32 = if (self.mushroom_ticks > 0) 400 else 0;
            self.mushroom_force += (target - self.mushroom_force) * @as(f32, if (target > 0) 0.5 else 0.1);
            if (self.mushroom_ticks == 0 and self.mushroom_force <= 1) self.mushroom_force = 0;
        }
        var thrust = (1 - self.force_loss) * (self.throttle * self.throttle / 25 + self.drift.boost_force + self.mushroom_force);
        const forward = Vec3{ .x = @sin(yaw.*), .y = 0, .z = -@cos(yaw.*) };
        // Grounded no-status drift branches of func_80036DB4/func_800371F4.
        // Mario 100cc: unk_088=28, unk_084=-15. In this coordinate system
        // lateral force points outside the turn; longitudinal force is drag.
        const drift_force = self.driftForce();
        const sideways = drift_force.x;
        thrust += drift_force.z;
        const right = Vec3{ .x = @cos(yaw.*), .y = 0, .z = @sin(yaw.*) };
        // Grounded planar adapter: original force and friction integration;
        // full lateral/suspension forces will replace this projection in a later slice.
        const divisor: f64 = if (@abs(self.steer_position >> 16) >= 40) 1 + @as(f64, self.brake_ramp) * 0.6 else 1;
        self.velocity.x += @floatCast((@as(f64, thrust * forward.x + sideways * right.x) - @as(f64, self.velocity.x) * (0.12 * 5800)) / 6000 / divisor);
        self.velocity.z += @floatCast((@as(f64, thrust * forward.z + sideways * right.z) - @as(f64, self.velocity.z) * (0.12 * 5800)) / 6000 / divisor);
        if (self.speed() > 9) self.velocity = self.velocity.scale(9 / self.speed());
        self.previous_speed = old_speed;
        self.drift.verticalStep();
    }
};
fn lookup(table: []const f32, surface: u8) f32 {
    return if (surface < table.len) table[surface] else 0;
}

test "acceleration cascades across adjacent bands and clamps" {
    var c = Controller{ .throttle = 30 };
    c.accelerate(0);
    try std.testing.expectEqual(@as(f32, 34), c.throttle);
    c.throttle = 310;
    c.accelerate(0);
    try std.testing.expectEqual(@as(f32, 310), c.throttle);
}

test "longitudinal response builds velocity and grass reduces terminal speed" {
    var road = Controller{};
    var grass = Controller{};
    var yaw: f32 = 0;
    var gyaw: f32 = 0;
    for (0..1200) |_| {
        road.tick(&yaw, .{ .accelerate = true }, .{});
        grass.tick(&gyaw, .{ .accelerate = true }, .{ .surfaces = .{ 8, 8, 8, 8 } });
    }
    try std.testing.expectApproxEqAbs(@as(f32, 3844.0 / 696.0), road.speed(), 0.001);
    try std.testing.expect(grass.speed() < road.speed() * 0.8);
    const before = road.speed();
    road.tick(&yaw, .{ .brake = true }, .{});
    try std.testing.expect(road.throttle < 310);
    try std.testing.expect(road.speed() <= before);
}

// Golden float bits from the original normal acceleration C branch, compiled
// with host cc -O0; no C dependency is needed to run these regression cases.
test "acceleration matches original C traces across bands and slopes" {
    const Case = struct { start: f32, slope: i16, ticks: usize, bits: u32 };
    const cases = [_]Case{
        .{ .start = 0, .slope = 0, .ticks = 100, .bits = 0x432f998d },
        .{ .start = 0, .slope = 0, .ticks = 300, .bits = 0x439a665e },
        .{ .start = 30, .slope = 0, .ticks = 1, .bits = 0x42080000 },
        .{ .start = 92, .slope = 0, .ticks = 1, .bits = 0x42bf3333 },
        .{ .start = 278.9, .slope = 0, .ticks = 4, .bits = 0x438c8ccc },
        .{ .start = 0, .slope = 12, .ticks = 120, .bits = 0x437cfffc },
        .{ .start = 100, .slope = -12, .ticks = 120, .bits = 0x433d99b3 },
        .{ .start = 309, .slope = 5, .ticks = 10, .bits = 0x439b0000 },
        .{ .start = 1, .slope = -45, .ticks = 1, .bits = 0x3f400000 },
    };
    for (cases) |case| {
        var c = Controller{ .throttle = case.start };
        for (0..case.ticks) |_| c.accelerate(case.slope);
        try std.testing.expectEqual(case.bits, @as(u32, @bitCast(c.throttle)));
    }
}

test "keyboard hop sustains a slide and countersteering earns turbo both ways" {
    for ([_]bool{ false, true }) |right| {
        var c = Controller{};
        var yaw: f32 = 0;
        for (0..600) |_| c.tick(&yaw, .{ .accelerate = true }, .{});
        for (0..30) |_| c.tick(&yaw, .{ .accelerate = true, .hop = true, .right = right, .left = !right }, .{});
        try std.testing.expect(!c.drift.hopping);
        try std.testing.expect(c.drift.drifting);
        for (0..300) |_| {
            const outside = c.drift.counter < 18;
            c.tick(&yaw, .{ .accelerate = true, .hop = true, .right = if (outside) !right else right, .left = if (outside) right else !right }, .{});
            if (c.drift.charge >= 2) break;
        }
        try std.testing.expect(c.drift.charge >= 2);
        c.tick(&yaw, .{ .accelerate = true }, .{});
        try std.testing.expect(c.drift.turbo_ticks > 0);
        try std.testing.expect(!c.drift.drifting);
    }
}

// Original C outputs reproduced by scripts/mk64_drift_reference.py.
// Our yaw sign is reversed relative to the N64's +Z-forward convention.
test "original C drift force and countersteering yaw gate fixtures" {
    for ([_]i16{ -265, 265 }) |yaw| {
        var c = Controller{ .yaw_step = yaw, .velocity = .{ .x = 0, .y = 0, .z = -5.5 }, .lateral_force = -59.85 };
        c.drift.drifting = true;
        for ([_]bool{ false, true }) |outside| {
            c.drift_outside = outside;
            for ([_]u8{ 20, 100 }) |counter| {
                c.drift.counter = counter;
                try std.testing.expectEqual(if (outside and counter < 100) @as(i16, 0) else yaw, c.rotationStep());
                const force = c.driftForce();
                try std.testing.expectApproxEqAbs(@as(f32, if (yaw > 0) -1264.175049 else 1264.175049), force.x, 0.001);
                try std.testing.expectEqual(@as(f32, -247.5), force.z);
            }
        }
    }
}

test "drift steering stages match original C fixed input trace" {
    const checkpoints = [_]usize{ 0, 19, 44, 54, 79, 89 };
    const positions = [_]i32{ 931589, 3041556, -3072398, 2501641, -3076884, 2508533 };
    var c = Controller{ .velocity = .{ .x = 0, .y = 0, .z = -5.5 } };
    c.drift.drifting = true;
    var checkpoint: usize = 0;
    for (0..90) |tick| {
        const outside = (tick >= 20 and tick < 45) or (tick >= 55 and tick < 80);
        c.steer(if (outside) -53 else 53, false, 20);
        if (tick == checkpoints[checkpoint]) {
            try std.testing.expectEqual(positions[checkpoint], c.steer_position);
            try std.testing.expectEqual(@as(u32, 227), c.steer_increment);
            try std.testing.expectApproxEqAbs(@as(f32, if (tick == 0) -59.849991 else 0), c.lateral_force, 0.00001);
            checkpoint += 1;
        }
    }
}

test "mushroom accelerates from cruise and fully expires independently of drift" {
    var normal = Controller{};
    var yaw: f32 = 0;
    for (0..1000) |_| normal.tick(&yaw, .{ .accelerate = true }, .{});
    var boosted = normal;
    boosted.mushroom_ticks = 80;
    for (0..60) |_| boosted.tick(&yaw, .{ .accelerate = true }, .{});
    try std.testing.expect(boosted.speed() > normal.speed() + 0.4);
    try std.testing.expectEqual(@as(u8, 20), boosted.mushroom_ticks);
    for (0..100) |_| boosted.tick(&yaw, .{ .accelerate = true }, .{});
    try std.testing.expectEqual(@as(f32, 0), boosted.mushroom_force);
    try std.testing.expectEqual(@as(u8, 0), boosted.drift.turbo_ticks);
}
