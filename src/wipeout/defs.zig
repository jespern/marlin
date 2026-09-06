//! Static game definitions: teams, pilots, ship handling attributes per
//! race class, and per-circuit settings. Values are the original's; the
//! turn constants are expressed through the same PSX fixed-point and
//! 30 Hz conversions so they can be cross-checked against the reference.

const std = @import("std");
const math = @import("math.zig");

pub const num_pilots = 8;
pub const num_laps = 3;

pub const RaceClass = enum(u8) { venom, rapier };
pub const Team = enum(u8) { ag_systems, auricom, qirex, feisar };

pub const pilot_names = [num_pilots][]const u8{
    "JOHN DEKKA",
    "DANIEL CHANG",
    "ARIAL TETSUO",
    "ANASTASIA CHEROVOSKI",
    "KEL SOLAAR",
    "ARIAN TETSUO",
    "SOFIA DE LA RENTE",
    "PAUL JACKSON",
};

pub const pilot_team = [num_pilots]Team{
    .ag_systems, .ag_systems,
    .auricom,    .auricom,
    .qirex,      .qirex,
    .feisar,     .feisar,
};

/// Object index in `allsh.prm` → pilot who flies that model.
pub const ship_model_to_pilot = [num_pilots]u8{ 6, 4, 7, 1, 5, 2, 3, 0 };

pub fn pilotToModel(pilot: u8) u8 {
    for (ship_model_to_pilot, 0..) |p, i| {
        if (p == pilot) return @intCast(i);
    }
    return 0;
}

// PSX fixed point and NTSC frame-rate conversions. These are evaluated in
// f64 with the reference's left-to-right macro order and narrowed to f32
// only where the reference assigns to a float, so the constants match the
// C build bit for bit.
pub fn fixedToFloat(v: f64) f64 {
    return v * (1.0 / 4096.0);
}
pub fn angleNormToRadian(v: f64) f64 {
    return v * math.pi64 * 2.0;
}
pub fn ntscVelocity(v: f64) f64 {
    return v * 30.0;
}
pub fn ntscAcceleration(v: f64) f64 {
    return ntscVelocity(ntscVelocity(v));
}
fn yawVelocity(v: f64) f64 {
    return v * (1.0 / 64.0);
}
fn turnAccel(v: f64) f32 {
    return @floatCast(ntscAcceleration(angleNormToRadian(fixedToFloat(yawVelocity(v)))));
}
fn turnVel(v: f64) f32 {
    return @floatCast(ntscVelocity(angleNormToRadian(fixedToFloat(yawVelocity(v)))));
}

pub const ShipAttributes = struct {
    mass: f32,
    thrust_max: f32,
    resistance: f32,
    turn_rate: f32,
    turn_rate_max: f32,
    skid: f32,
};

pub fn shipAttributes(team: Team, class: RaceClass) ShipAttributes {
    return switch (team) {
        .ag_systems => switch (class) {
            .venom => .{ .mass = 150, .thrust_max = 790, .resistance = 140, .turn_rate = turnAccel(160), .turn_rate_max = turnVel(2560), .skid = 12 },
            .rapier => .{ .mass = 150, .thrust_max = 1200, .resistance = 140, .turn_rate = turnAccel(160), .turn_rate_max = turnVel(2560), .skid = 10 },
        },
        .auricom => switch (class) {
            .venom => .{ .mass = 150, .thrust_max = 850, .resistance = 134, .turn_rate = turnAccel(140), .turn_rate_max = turnVel(1920), .skid = 20 },
            .rapier => .{ .mass = 150, .thrust_max = 1400, .resistance = 140, .turn_rate = turnAccel(120), .turn_rate_max = turnVel(1920), .skid = 14 },
        },
        .qirex => switch (class) {
            .venom => .{ .mass = 150, .thrust_max = 850, .resistance = 140, .turn_rate = turnAccel(120), .turn_rate_max = turnVel(1920), .skid = 24 },
            .rapier => .{ .mass = 150, .thrust_max = 1400, .resistance = 130, .turn_rate = turnAccel(140), .turn_rate_max = turnVel(1920), .skid = 16 },
        },
        .feisar => switch (class) {
            .venom => .{ .mass = 150, .thrust_max = 790, .resistance = 134, .turn_rate = turnAccel(180), .turn_rate_max = turnVel(2560), .skid = 12 },
            .rapier => .{ .mass = 150, .thrust_max = 1200, .resistance = 130, .turn_rate = turnAccel(180), .turn_rate_max = turnVel(2560), .skid = 8 },
        },
    };
}

pub const CircuitSettings = struct {
    start_line_pos: u16,
    sky_y_offset: f32,
};

/// Settings by PSX track directory number (1-14). Each circuit has a
/// Venom and a Rapier layout in separate directories.
pub fn circuitSettings(track_number: u8) CircuitSettings {
    return switch (track_number) {
        1 => .{ .start_line_pos = 27, .sky_y_offset = -820 },
        2 => .{ .start_line_pos = 27, .sky_y_offset = -2520 },
        3 => .{ .start_line_pos = 27, .sky_y_offset = -1930 },
        4 => .{ .start_line_pos = 16, .sky_y_offset = -5000 },
        5 => .{ .start_line_pos = 16, .sky_y_offset = -5000 },
        6 => .{ .start_line_pos = 27, .sky_y_offset = 0 },
        7 => .{ .start_line_pos = 16, .sky_y_offset = -2260 },
        8 => .{ .start_line_pos = 16, .sky_y_offset = -40 },
        9 => .{ .start_line_pos = 16, .sky_y_offset = -2700 },
        10 => .{ .start_line_pos = 27, .sky_y_offset = 0 },
        11 => .{ .start_line_pos = 16, .sky_y_offset = -240 },
        12 => .{ .start_line_pos = 16, .sky_y_offset = -2120 },
        13 => .{ .start_line_pos = 16, .sky_y_offset = -2700 },
        else => .{ .start_line_pos = 27, .sky_y_offset = 0 },
    };
}

test "turn constants match the reference formulas" {
    // TURN_VEL(2560) = 2560/64/4096 * 2π * 30
    const expected: f64 = 2560.0 / 64.0 / 4096.0 * math.pi64 * 2.0 * 30.0;
    try std.testing.expectApproxEqRel(@as(f32, @floatCast(expected)), shipAttributes(.feisar, .venom).turn_rate_max, 1e-6);
}
