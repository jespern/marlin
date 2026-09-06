//! The field: eight ships, their grid order and race positions, and the
//! per-step update that the original runs over all of them (or only the
//! player, in a time trial). Plain data so it snapshots bytewise.

const std = @import("std");
const math = @import("math.zig");
const defs = @import("defs.zig");
const input = @import("input.zig");
const ship_mod = @import("ship.zig");
const track_mod = @import("track.zig");
const Rng = @import("rng.zig").Rng;
const render = @import("render.zig");
const Ship = ship_mod.Ship;
const Track = track_mod.Track;

/// Draw every ship, then the shadows of those on the track. A ship in the
/// cockpit view is skipped; a time trial draws only the player.
pub fn drawShips(race: *const Race, r: *render.Renderer, track: *const Track, models: *const ship_mod.Models) void {
    for (&race.ships, 0..) |*s, i| {
        if (race.race_type == .time_trial and i != race.player) continue;
        if (s.flags.view_internal and !s.flags.in_rescue) continue;
        s.draw(r, models);
    }
    r.setModelMat(&math.Mat4.identity);
    r.setDepthWrite(false);
    r.setDepthOffset(-32.0);
    for (&race.ships, 0..) |*s, i| {
        if (race.race_type == .time_trial and i != race.player) continue;
        if (!s.flags.visible or s.flags.flying) continue;
        s.drawShadow(r, track, models);
    }
    r.setDepthOffset(0);
    r.setDepthWrite(true);
}

pub const Type = enum(u8) { single, time_trial };

/// Multiplier on the original opponent tuning.
pub const Difficulty = enum(u8) {
    easy,
    normal,
    hard,

    pub fn strength(self: Difficulty) f32 {
        return switch (self) {
            .easy => 0.75,
            .normal => 0.88,
            .hard => 1.0,
        };
    }
};

pub const Options = struct {
    track: u8,
    pilot: u8,
    class: defs.RaceClass,
    race_type: Type,
    difficulty: Difficulty,
    intro: bool,
};

pub const Race = extern struct {
    ships: [defs.num_pilots]Ship,
    /// Pilot indices ordered by race position (best first).
    ranks: [defs.num_pilots]u8,
    player: u8,
    race_type: Type,
    class: defs.RaceClass,
    difficulty: Difficulty,
    track_number: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    start_line_pos: u16,
    _pad2: u16 = 0,
    behind_speed: f32,

    pub fn init(track: *const Track, options: Options, rng: *Rng) Race {
        const circuit = defs.circuitSettings(options.track);

        // Grid order: shuffled for a single race, player always at the back.
        var order: [defs.num_pilots]u8 = undefined;
        for (&order, 0..) |*o, i| o.* = @intCast(i);
        if (options.race_type == .single) {
            var i: usize = order.len - 1;
            while (i > 0) : (i -= 1) {
                const j: usize = @intCast(rng.int(0, @intCast(i + 1)));
                std.mem.swap(u8, &order[i], &order[j]);
            }
        }
        var i: usize = 0;
        while (i + 1 < order.len) : (i += 1) {
            if (order[i] == options.pilot) std.mem.swap(u8, &order[i], &order[i + 1]);
        }

        // Grid slots: two ships per row, rows two sections apart, starting
        // start_line_pos - 15 sections in.
        var section: u32 = 0;
        i = 0;
        while (i + 15 < circuit.start_line_pos) : (i += 1) section = track.sections[section].next;
        var slots: [defs.num_pilots]u32 = undefined;
        i = 0;
        while (i < slots.len) : (i += 1) {
            slots[i] = section;
            section = track.sections[section].next;
            if (i % 2 == 0) section = track.sections[section].next;
        }

        var race = Race{
            .ships = undefined,
            .ranks = order,
            .player = options.pilot,
            .race_type = options.race_type,
            .class = options.class,
            .difficulty = options.difficulty,
            .track_number = options.track,
            .start_line_pos = circuit.start_line_pos,
            .behind_speed = circuit.behind_speed,
        };
        const strength = options.difficulty.strength();
        i = 0;
        while (i < order.len) : (i += 1) {
            const rank_inv: u8 = @intCast(order.len - 1 - i);
            const pilot = order[i];
            const ai: ?defs.AiSetting = if (pilot == options.pilot) null else defs.aiSetting(options.class, rank_inv);
            race.ships[pilot] = Ship.init(track, slots[rank_inv], pilot, rank_inv, options.class, ai, circuit, strength);
            if (!options.intro) race.ships[pilot].skipIntro();
        }
        return race;
    }

    pub fn playerShip(self: *Race) *Ship {
        return &self.ships[self.player];
    }

    pub fn playerShipConst(self: *const Race) *const Ship {
        return &self.ships[self.player];
    }

    pub fn update(self: *Race, track: *const Track, player_input: *const input.State, rng: *Rng, tick: f64, models: *const ship_mod.Models) void {
        const ctx = ship_mod.Context{
            .track = track,
            .input = player_input,
            .rng = rng,
            .tick = tick,
            .start_line_pos = self.start_line_pos,
            .ships = &self.ships,
            .player = self.player,
            .behind_speed = self.behind_speed,
        };
        if (self.race_type == .time_trial) {
            self.ships[self.player].update(ctx);
            return;
        }
        for (&self.ships) |*s| s.update(ctx);
        var j: usize = 0;
        while (j + 1 < self.ships.len) : (j += 1) {
            var i: usize = j + 1;
            while (i < self.ships.len) : (i += 1) self.ships[i].collideWithShip(&self.ships[j], models);
        }
        if (self.ships[self.player].flags.racing) self.sortRanks(track);
    }

    fn aheadOf(self: *const Race, track: *const Track, a: u8, b: u8) bool {
        const sa = &self.ships[a];
        const sb = &self.ships[b];
        if (sa.total_section_num != sb.total_section_num) return sa.total_section_num > sb.total_section_num;
        const c0 = track.sections[sa.section].center;
        const c1 = track.sections[track.sections[sa.section].next].center;
        const dir = c1.sub(c0);
        return sa.position.sub(c0).dot(dir) > sb.position.sub(c0).dot(dir);
    }

    /// Insertion sort of the eight pilots by progress; writes position_rank.
    fn sortRanks(self: *Race, track: *const Track) void {
        var i: usize = 1;
        while (i < self.ranks.len) : (i += 1) {
            const pilot = self.ranks[i];
            var j = i;
            while (j > 0 and self.aheadOf(track, pilot, self.ranks[j - 1])) : (j -= 1) self.ranks[j] = self.ranks[j - 1];
            self.ranks[j] = pilot;
        }
        for (self.ranks, 0..) |pilot, rank| self.ships[pilot].position_rank = @intCast(rank + 1);
    }
};
