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

pub const num_circuits = 7;
pub const num_non_bonus_circuits = 6;
pub const qualifying_rank = 3;
pub const num_lives = 3;
pub const race_points_for_rank = [num_pilots]i32{ 9, 7, 5, 3, 2, 1, 0, 0 };

pub const circuit_names = [num_circuits][]const u8{ "ALTIMA VII", "KARBONIS V", "TERRAMAX", "KORODERA", "ARRIDOS IV", "SILVERSTREAM", "FIRESTAR" };
pub const circuit_is_bonus = [num_circuits]bool{ false, false, false, false, false, false, true };
/// PSX track directory per circuit, Venom then Rapier layout.
pub const circuit_tracks = [num_circuits][2]u8{ .{ 2, 3 }, .{ 4, 5 }, .{ 1, 6 }, .{ 12, 7 }, .{ 8, 11 }, .{ 9, 13 }, .{ 10, 14 } };
pub const race_class_names = [2][]const u8{ "VENOM CLASS", "RAPIER CLASS" };
pub const race_type_names = [3][]const u8{ "CHAMPIONSHIP RACE", "SINGLE RACE", "TIME TRIAL" };
pub const team_names = [4][]const u8{ "AG SYSTEMS", "AURICOM", "QIREX", "FEISAR" };
pub const team_pilots = [4][2]u8{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 } };
/// Pilot logo model index in `pilot.prm`.
pub const pilot_logo_model = [num_pilots]u8{ 0, 4, 6, 7, 2, 5, 1, 3 };
pub const pilot_portraits = [num_pilots][]const u8{
    "wipeout/textures/dekka.cmp", "wipeout/textures/chang.cmp", "wipeout/textures/arial.cmp", "wipeout/textures/anast.cmp",
    "wipeout/textures/solar.cmp", "wipeout/textures/arian.cmp", "wipeout/textures/sophi.cmp", "wipeout/textures/paul.cmp",
};

pub fn trackNumber(circuit: u8, class: RaceClass) u8 {
    return circuit_tracks[circuit][@intFromEnum(class)];
}

pub const CircuitSettings = struct {
    start_line_pos: u16,
    sky_y_offset: f32,
    /// Extra speed granted to AI ships that have fallen behind the player.
    behind_speed: f32,
    /// Start-line stagger: the n-th AI ship waits n*(base + n*factor) frames.
    spread_base: f32,
    spread_factor: f32,
};

pub const AiSetting = struct {
    thrust_max: f32,
    thrust_magnitude: f32,
    fight_back: bool,
};

/// Opponent tuning by class, from the back of the grid forwards (the
/// original indexes it by inverse start rank minus one).
pub const ai_settings = [2][7]AiSetting{
    .{
        .{ .thrust_max = 2550, .thrust_magnitude = 44, .fight_back = true },
        .{ .thrust_max = 2600, .thrust_magnitude = 45, .fight_back = true },
        .{ .thrust_max = 2630, .thrust_magnitude = 45, .fight_back = true },
        .{ .thrust_max = 2660, .thrust_magnitude = 46, .fight_back = true },
        .{ .thrust_max = 2700, .thrust_magnitude = 47, .fight_back = true },
        .{ .thrust_max = 2720, .thrust_magnitude = 48, .fight_back = true },
        .{ .thrust_max = 2750, .thrust_magnitude = 49, .fight_back = true },
    },
    .{
        .{ .thrust_max = 3750, .thrust_magnitude = 50, .fight_back = true },
        .{ .thrust_max = 3780, .thrust_magnitude = 53, .fight_back = true },
        .{ .thrust_max = 3800, .thrust_magnitude = 55, .fight_back = true },
        .{ .thrust_max = 3850, .thrust_magnitude = 57, .fight_back = true },
        .{ .thrust_max = 3900, .thrust_magnitude = 60, .fight_back = true },
        .{ .thrust_max = 3950, .thrust_magnitude = 62, .fight_back = true },
        .{ .thrust_max = 4000, .thrust_magnitude = 65, .fight_back = true },
    },
};

pub fn aiSetting(class: RaceClass, inv_start_rank: u8) AiSetting {
    const index: usize = @min(@max(inv_start_rank, 1) - 1, 6);
    return ai_settings[@intFromEnum(class)][index];
}

pub const WeaponType = enum(u8) {
    none = 0,
    mine,
    missile,
    rocket,
    special,
    ebolt,
    flare,
    rev_con,
    shield,
    turbo,
};

/// Settings by PSX track directory number (1-14). Each circuit has a
/// Venom and a Rapier layout in separate directories.
pub fn circuitSettings(track_number: u8) CircuitSettings {
    return switch (track_number) {
        1 => .{ .start_line_pos = 27, .sky_y_offset = -820, .behind_speed = 350, .spread_base = 60, .spread_factor = 11 },
        2 => .{ .start_line_pos = 27, .sky_y_offset = -2520, .behind_speed = 300, .spread_base = 80, .spread_factor = 20 },
        3 => .{ .start_line_pos = 27, .sky_y_offset = -1930, .behind_speed = 500, .spread_base = 80, .spread_factor = 11 },
        4 => .{ .start_line_pos = 16, .sky_y_offset = -5000, .behind_speed = 200, .spread_base = 10, .spread_factor = 8 },
        5 => .{ .start_line_pos = 16, .sky_y_offset = -5000, .behind_speed = 500, .spread_base = 10, .spread_factor = 8 },
        6 => .{ .start_line_pos = 27, .sky_y_offset = 0, .behind_speed = 500, .spread_base = 10, .spread_factor = 8 },
        7 => .{ .start_line_pos = 16, .sky_y_offset = -2260, .behind_speed = 500, .spread_base = 30, .spread_factor = 11 },
        8 => .{ .start_line_pos = 16, .sky_y_offset = -40, .behind_speed = 350, .spread_base = 80, .spread_factor = 15 },
        9 => .{ .start_line_pos = 16, .sky_y_offset = -2700, .behind_speed = 150, .spread_base = 10, .spread_factor = 8 },
        10 => .{ .start_line_pos = 27, .sky_y_offset = 0, .behind_speed = 200, .spread_base = 40, .spread_factor = 11 },
        11 => .{ .start_line_pos = 16, .sky_y_offset = -240, .behind_speed = 450, .spread_base = 30, .spread_factor = 11 },
        12 => .{ .start_line_pos = 16, .sky_y_offset = -2120, .behind_speed = 450, .spread_base = 40, .spread_factor = 11 },
        13 => .{ .start_line_pos = 16, .sky_y_offset = -2700, .behind_speed = 150, .spread_base = 10, .spread_factor = 8 },
        else => .{ .start_line_pos = 27, .sky_y_offset = 0, .behind_speed = 500, .spread_base = 40, .spread_factor = 11 },
    };
}

test "turn constants match the reference formulas" {
    // TURN_VEL(2560) = 2560/64/4096 * 2π * 30
    const expected: f64 = 2560.0 / 64.0 / 4096.0 * math.pi64 * 2.0 * 30.0;
    try std.testing.expectApproxEqRel(@as(f32, @floatCast(expected)), shipAttributes(.feisar, .venom).turn_rate_max, 1e-6);
}
