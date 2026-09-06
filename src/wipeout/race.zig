//! The race: eight ships, the camera, pickups, weapons, particles and the
//! rescue droid, updated each step in the original's order. Plain data so
//! it snapshots bytewise; assets are referenced by index.

const std = @import("std");
const math = @import("math.zig");
const defs = @import("defs.zig");
const input = @import("input.zig");
const ship_mod = @import("ship.zig");
const track_mod = @import("track.zig");
const camera_mod = @import("camera.zig");
const weapon_mod = @import("weapon.zig");
const particle_mod = @import("particle.zig");
const droid_mod = @import("droid.zig");
const object = @import("object.zig");
const image = @import("image.zig");
const scene = @import("scene.zig");
const render = @import("render.zig");
const assets_mod = @import("assets.zig");
const Rng = @import("rng.zig").Rng;
const Ship = ship_mod.Ship;
const Track = track_mod.Track;
const Rgba = math.Rgba;

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

/// Pickup pad state; the face colours are derived from it every step.
pub const Pickup = extern struct {
    face: u32,
    cooldown: f32,
    active: u8 = 0,
    collected: u8 = 0,
    _pad: u16 = 0,
};

/// Everything loaded from disk that a race draws with.
pub const Assets = struct {
    ships: ship_mod.Models,
    weapons: weapon_mod.Models,
    droid: []object.Object,
    particle_textures: object.TextureList,
    weapon_icons: object.TextureList,
    reticle: u16,

    pub fn deinit(self: *Assets, gpa: std.mem.Allocator) void {
        self.ships.deinit(gpa);
        self.weapons.deinit(gpa);
        object.free(gpa, self.droid);
    }
};

pub fn loadAssets(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer) !Assets {
    var ships = try ship_mod.loadModels(gpa, assets, r);
    errdefer ships.deinit(gpa);

    const weapon_textures = try scene.loadCompressedTextures(gpa, assets, r, "wipeout/common", "mine.cmp");
    const rocket = try loadPrm(gpa, assets, "wipeout/common/rock.prm", weapon_textures);
    errdefer object.free(gpa, rocket);
    const mine = try loadPrm(gpa, assets, "wipeout/common/mine.prm", weapon_textures);
    errdefer object.free(gpa, mine);
    const missile = try loadPrm(gpa, assets, "wipeout/common/miss.prm", weapon_textures);
    errdefer object.free(gpa, missile);
    const shield = try loadPrm(gpa, assets, "wipeout/common/shld.prm", weapon_textures);
    errdefer object.free(gpa, shield);
    const shield_internal = try loadPrm(gpa, assets, "wipeout/common/shld.prm", weapon_textures);
    errdefer object.free(gpa, shield_internal);
    weapon_mod.invertShield(shield_internal);
    const ebolt = try loadPrm(gpa, assets, "wipeout/common/ebolt.prm", weapon_textures);
    errdefer object.free(gpa, ebolt);

    const droid = try scene.loadModel(gpa, assets, r, "wipeout/common", "rescu.cmp", "rescu.prm");
    errdefer object.free(gpa, droid);
    const particle_textures = try scene.loadCompressedTextures(gpa, assets, r, "wipeout/common", "effects.cmp");
    const weapon_icons = try scene.loadCompressedTextures(gpa, assets, r, "wipeout/common", "wicons.cmp");

    const reticle_data = try assets.load("wipeout/textures/target2.tim");
    defer gpa.free(reticle_data);
    const reticle_img = try image.decodeTim(gpa, reticle_data, true);
    defer reticle_img.deinit(gpa);
    const reticle = try r.createTexture(reticle_img.width, reticle_img.height, reticle_img.pixels);

    return .{
        .ships = ships,
        .weapons = .{ .rocket = rocket, .mine = mine, .missile = missile, .shield = shield, .shield_internal = shield_internal, .ebolt = ebolt },
        .droid = droid,
        .particle_textures = particle_textures,
        .weapon_icons = weapon_icons,
        .reticle = reticle,
    };
}

fn loadPrm(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, path: []const u8, textures: object.TextureList) ![]object.Object {
    const data = try assets.load(path);
    defer gpa.free(data);
    return object.load(gpa, data, textures);
}

pub const Race = extern struct {
    ships: [defs.num_pilots]Ship,
    /// Pilot indices ordered by race position (best first).
    ranks: [defs.num_pilots]u8,
    player: u8,
    race_type: Type,
    class: defs.RaceClass,
    difficulty: Difficulty,
    track_number: u8,
    pickup_count: u8,
    _pad: [2]u8 = .{ 0, 0 },
    start_line_pos: u16,
    _pad2: u16 = 0,
    behind_speed: f32,
    /// Simulated seconds since the race began; drives cyclic animation.
    cycle_time: f32,
    camera: camera_mod.Camera,
    droid: droid_mod.Droid,
    pickups: [track_mod.max_pickups]Pickup,
    weapons: weapon_mod.Weapons,
    particles: particle_mod.Particles,

    pub fn init(track: *const Track, options: Options, rng: *Rng, particle_texture_start: u16) Race {
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
            .pickup_count = track.pickup_count,
            .start_line_pos = circuit.start_line_pos,
            .behind_speed = circuit.behind_speed,
            .cycle_time = 0,
            .camera = camera_mod.Camera.init(track, 0),
            .droid = undefined,
            .pickups = undefined,
            .weapons = weapon_mod.Weapons.init(),
            .particles = particle_mod.Particles.init(particle_texture_start),
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
        race.droid = droid_mod.Droid.init(track, &race.ships[options.pilot]);
        i = 0;
        while (i < track.pickup_count) : (i += 1) {
            race.pickups[i] = .{ .face = track.pickup_faces[i], .cooldown = 0 };
        }
        return race;
    }

    pub fn playerShip(self: *Race) *Ship {
        return &self.ships[self.player];
    }

    pub fn playerShipConst(self: *const Race) *const Ship {
        return &self.ships[self.player];
    }

    /// One fixed step in the original's order: ships, droid, camera,
    /// weapons, particles, pickups.
    pub fn update(self: *Race, track: *Track, player_input: *const input.State, rng: *Rng, tick: f64, assets: *const Assets) void {
        const dt: f32 = @floatCast(tick);
        self.cycle_time += dt;
        const ctx = ship_mod.Context{
            .track = track,
            .input = player_input,
            .rng = rng,
            .tick = tick,
            .start_line_pos = self.start_line_pos,
            .ships = &self.ships,
            .player = self.player,
            .behind_speed = self.behind_speed,
            .weapons = &self.weapons,
        };
        if (self.race_type == .time_trial) {
            self.ships[self.player].update(ctx);
        } else {
            for (&self.ships) |*s| s.update(ctx);
            for (&self.ships) |*s| self.collectPickup(track, s, rng);
            var j: usize = 0;
            while (j + 1 < self.ships.len) : (j += 1) {
                var i: usize = j + 1;
                while (i < self.ships.len) : (i += 1) self.ships[i].collideWithShip(&self.ships[j], &assets.ships);
            }
            if (self.ships[self.player].flags.racing) self.sortRanks(track);
        }

        const player = &self.ships[self.player];
        if (self.droid.update(track, player, dt)) {
            self.camera.mode = .rescue;
            self.camera.section = droid_mod.Droid.rescueCameraSection(track, player);
        }
        if (!player.flags.view_remote) {
            self.camera.mode = if (player.flags.view_internal) .internal else .external;
        }
        self.camera.update(track, player, self.droid.position, rng, dt);

        self.weapons.update(.{
            .track = track,
            .ships = &self.ships,
            .player = self.player,
            .particles = &self.particles,
            .camera = &self.camera,
            .rng = rng,
            .dt = dt,
        });
        self.particles.update(dt);
        if (self.race_type != .time_trial) self.cyclePickups(track, dt);
    }

    /// The original's per-frame pickup pass: collected pads go dark for a
    /// cooldown, then rearm with a colour that cycles with time.
    fn cyclePickups(self: *Race, track: *Track, dt: f32) void {
        const t = 1.5 * self.cycle_time;
        for (self.pickups[0..self.pickup_count], 0..) |*p, i| {
            const face = &track.faces[p.face];
            const fi: f32 = @floatFromInt(i);
            if (p.collected != 0) {
                p.collected = 0;
                p.cooldown = track_mod.pickup_cooldown_time;
            } else if (p.cooldown <= 0) {
                p.active = 1;
                face.setColor(Rgba.init(
                    @intFromFloat(std.math.clamp(@sin(t + fi) * 127 + 128, 0, 255)),
                    @intFromFloat(std.math.clamp(@cos(t + fi) * 127 + 128, 0, 255)),
                    @intFromFloat(std.math.clamp(@sin(-t - fi) * 127 + 128, 0, 255)),
                    255,
                ));
            } else {
                p.cooldown -= dt;
            }
        }
    }

    fn collectPickup(self: *Race, track: *Track, ship: *Ship, rng: *Rng) void {
        if (ship.flags.specialed or ship.weapon_type != .none) return;
        for (self.pickups[0..self.pickup_count]) |*p| {
            if (p.face != ship.over_face or p.active == 0) continue;
            p.active = 0;
            p.collected = 1;
            track.faces[p.face].setColor(Rgba.init(255, 255, 255, 255));
            if (ship.pilot == self.player) {
                ship.weapon_type = weapon_mod.randomType(rng, ship.flags.shielded);
            } else {
                ship.weapon_type = .mine;
            }
            return;
        }
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

    /// Ships, droid, weapons and particles, in the original's draw order.
    /// Call after the scene and track with back-face culling on.
    pub fn draw(self: *Race, r: *render.Renderer, track: *const Track, assets: *Assets, dt: f32) void {
        for (&self.ships, 0..) |*s, i| {
            if (self.race_type == .time_trial and i != self.player) continue;
            if (s.flags.view_internal and !s.flags.in_rescue) continue;
            s.draw(r, &assets.ships);
        }
        r.setModelMat(&math.Mat4.identity);
        r.setDepthWrite(false);
        r.setDepthOffset(-32.0);
        for (&self.ships, 0..) |*s, i| {
            if (self.race_type == .time_trial and i != self.player) continue;
            if (!s.flags.visible or s.flags.flying) continue;
            s.drawShadow(r, track, &assets.ships);
        }
        r.setDepthOffset(0);
        r.setDepthWrite(true);

        if (assets.droid.len > 0) self.droid.draw(r, &assets.droid[0], dt);
        self.weapons.draw(r, &assets.weapons, self.cycle_time);
        self.particles.draw(r);
    }
};
