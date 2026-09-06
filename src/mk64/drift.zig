//! Hop and mini-turbo state from player_controller.c. Height is a floor-relative
//! adapter using the original hop impulse and grounded vertical integration;
//! full suspension, orientation and airborne terrain collision remain unported.
const std = @import("std");
pub const State = struct {
    held: bool = false,
    hopping: bool = false,
    drifting: bool = false,
    height: f32 = 0,
    vertical_velocity: f32 = 0,
    hop_velocity: f32 = 0,
    hop_acceleration: f32 = 0,
    counter: u8 = 0,
    charge: u8 = 0,
    turbo_ticks: u8 = 0,
    boost_force: f32 = 0,

    pub fn begin(self: *State, pressed: bool, kmh: f32, slip: i32) void {
        if (pressed and !self.held and !self.hopping and !self.drifting) {
            self.hopping = true;
            self.hop_velocity = 0.93;
            self.hop_acceleration = 0;
            self.vertical_velocity = 0;
            self.drifting = kmh > 20;
        }
        self.held = pressed;
        if (kmh <= 20 or (!self.hopping and (!pressed or @abs(slip) <= 6))) self.drifting = false;
        // func_8002A79C: release a completed charge, then expire after 31 ticks.
        if (self.turbo_ticks > 0) {
            self.turbo_ticks -= 1;
            if (self.turbo_ticks == 0) {
                self.charge = 0;
                self.counter = 0;
            }
        } else if (!self.drifting and self.charge >= 2) {
            self.turbo_ticks = 31;
            self.charge = 0;
            self.counter = 0;
        }
        const target: f32 = if (self.turbo_ticks > 0 and !self.drifting) 580 else 0;
        self.boost_force += (target - self.boost_force) * @as(f32, if (target > 0) 0.2 else 0.01);
    }

    /// update_drift_state_counter: countersteer, then steer back into the slide.
    pub fn chargeStep(self: *State, stick: i32, slip: i32) void {
        if (if (slip > 0) stick <= -10 else stick >= 10) {
            if (self.counter <= 100) self.counter += 1;
        } else {
            if (self.counter >= 18 and self.counter < 100) self.charge = @min(3, self.charge + 1);
            if (self.counter >= 10 and self.counter < 100) self.counter = 10 else {
                self.counter = 0;
                self.charge = 0;
            }
        }
    }

    pub fn verticalStep(self: *State) void {
        if (!self.hopping) return;
        // func_8002AAC0. The impulse stops at zero; gravity handles descent.
        if (self.hop_velocity > 0) {
            self.hop_acceleration = std.math.clamp(self.hop_acceleration - 0.03, -9, 9);
            self.hop_velocity = std.math.clamp(self.hop_velocity + self.hop_acceleration, 0, 15);
            if (self.hop_velocity == 0) self.hop_acceleration = 0;
        }
        self.height += self.vertical_velocity + self.hop_velocity - 0.02;
        self.vertical_velocity += @floatCast((-500.0 - @as(f64, self.vertical_velocity) * (0.12 * 5800)) / 6000 / 3);
        if (self.height <= 0) {
            self.height = 0;
            self.vertical_velocity = 0;
            self.hop_velocity = 0;
            self.hopping = false;
        }
    }
};

test "held hop lands without retriggering; release rearms" {
    var s = State{};
    s.begin(true, 0, 0);
    s.verticalStep();
    try std.testing.expect(s.height > 0);
    for (0..120) |_| {
        s.begin(true, 0, 0);
        s.verticalStep();
    }
    try std.testing.expect(!s.hopping);
    try std.testing.expectEqual(@as(f32, 0), s.height);
    s.begin(false, 0, 0);
    s.begin(true, 0, 0);
    try std.testing.expect(s.hopping);
}

test "two countersteer cycles charge turbo; release starts 31 tick boost" {
    for ([_]i32{ -1, 1 }) |side| {
        var s = State{ .drifting = true, .held = true };
        for (0..2) |_| {
            for (0..18) |_| s.chargeStep(-side * 53, side * 20);
            s.chargeStep(side * 53, side * 20);
        }
        try std.testing.expectEqual(@as(u8, 2), s.charge);
        s.begin(false, 60, side * 20);
        try std.testing.expectEqual(@as(u8, 31), s.turbo_ticks);
        try std.testing.expect(s.boost_force > 0);
        for (0..31) |_| s.begin(false, 60, 0);
        try std.testing.expectEqual(@as(u8, 0), s.turbo_ticks);
    }
}

test "holding countersteer too long loses charge" {
    var s = State{ .charge = 1 };
    for (0..110) |_| s.chargeStep(-53, 20);
    s.chargeStep(53, 20);
    try std.testing.expectEqual(@as(u8, 0), s.charge);
}
