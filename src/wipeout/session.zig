//! A running game: the renderer, the assets loaded once, the circuit loaded
//! on demand, the game state machine, the fixed-step clock and the save
//! file. Hosts (the marlin client, the probe) feed it input actions and
//! ask it to render into an RGB buffer; nothing here knows about terminals.

const std = @import("std");
const Io = std.Io;
const assets_mod = @import("assets.zig");
const render_mod = @import("render.zig");
const track_mod = @import("track.zig");
const scene_mod = @import("scene.zig");
const race_mod = @import("race.zig");
const ui_mod = @import("ui.zig");
const hud_mod = @import("hud.zig");
const game = @import("game.zig");
const input = @import("input.zig");
const autopilot = @import("autopilot.zig");
const save_mod = @import("save.zig");
const post = @import("post.zig");
const defs = @import("defs.zig");
const Rng = @import("rng.zig").Rng;

/// The simulation renders at PSX-native 240p. The CRT pass needs room for
/// its scanlines and column mask, so with it on the output is 2x.
pub const render_width: u16 = 320;
pub const render_height: u16 = 240;
pub const crt_scale: u16 = 2;

pub const OutputSize = struct { width: u16, height: u16, ship_every: u8 };
/// Fixed physics step; presentation may run at any rate.
pub const step_hz: u32 = 60;
pub const step_seconds: f64 = 1.0 / @as(f64, @floatFromInt(step_hz));
/// Never simulate more than this many steps per tick after a stall.
const max_steps_per_tick: u32 = 4;

/// How to start. Without `explicit` the game opens on the title screen;
/// with it a race starts directly on the given circuit.
pub const StartOptions = struct {
    track: u8 = 1,
    pilot: u8 = 0,
    rapier: bool = false,
    intro: bool = true,
    /// Overrides the saved CRT preference when set.
    crt: ?bool = null,
    time_trial: bool = false,
    difficulty: ?race_mod.Difficulty = null,
    explicit: bool = false,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    io: Io,
    root: []u8,
    /// Set when the assets come from the single-file bundle.
    bundle: ?*@import("bundle.zig").Bundle = null,
    assets: assets_mod.Assets,
    renderer: render_mod.Renderer,
    race_assets: race_mod.Assets,
    ui: ui_mod.Ui,
    hud: hud_mod.Hud,
    menu_assets: game.MenuAssets,
    /// Texture count after the shared assets; circuit textures sit above.
    texture_base: u16,
    track: ?track_mod.Track = null,
    scene: ?scene_mod.Scene = null,
    loaded_track: u8 = 0,
    state: game.State,
    /// What the keyboard says; the game sees this, or the autopilot's
    /// steering when it is on and no key is held.
    input: input.State = .{},
    autopilot: bool = false,
    rng: Rng,
    save_path: ?[]u8,
    /// Wall-clock accumulator for fixed-step simulation, in nanoseconds.
    accumulator_ns: i128 = 0,
    last_tick_ns: ?i128 = null,
    paused: bool = true,
    steps: u64 = 0,
    /// Simulated seconds, drives the CRT pass's animation.
    cycle_time: f32 = 0,
    /// The last circuit load failed; the state was sent back to the menu.
    load_error: ?anyerror = null,

    /// Fails with `error.AssetsMissing` when neither the extracted tree
    /// nor the bundle is under the data root; the host downloads then.
    pub fn create(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, options: StartOptions) !*Session {
        const root = try assets_mod.defaultRoot(gpa, environ);
        errdefer gpa.free(root);
        // Default downloads must be verified on every launch; custom extracted
        // roots retain their development behavior.
        if (if (environ.get("MARLIN_WIPEOUT_DATA")) |value| value.len == 0 else true) {
            const path = try assets_mod.bundlePath(gpa, root);
            defer gpa.free(path);
            try assets_mod.migrateLegacy(gpa, io, environ, path);
            const bytes = try @import("asset_store").readCached(gpa, io, assets_mod.spec, path) orelse return error.AssetsMissing;
            gpa.free(bytes);
        }
        const save_path: ?[]u8 = save_mod.defaultPath(gpa, environ) catch null;
        errdefer if (save_path) |p| gpa.free(p);
        const saved = if (save_path) |p| save_mod.read(io, gpa, p) else save_mod.defaults;
        return createWithRoot(gpa, io, root, save_path, saved, options);
    }

    /// `root` and `save_path` are owned by the session from here on.
    pub fn createWithRoot(gpa: std.mem.Allocator, io: Io, root: []u8, save_path: ?[]u8, saved: save_mod.SaveData, options: StartOptions) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.bundle = null;
        switch (try assets_mod.openSource(gpa, io, root)) {
            .tree => {},
            .bundle => |opened| {
                const owned = try gpa.create(@import("bundle.zig").Bundle);
                owned.* = opened;
                self.bundle = owned;
            },
        }
        errdefer if (self.bundle) |b| {
            b.deinit();
            gpa.destroy(b);
        };
        const assets = if (self.bundle) |b| assets_mod.Assets.initBundle(io, gpa, root, b) else assets_mod.Assets.init(io, gpa, root);

        var renderer = try render_mod.Renderer.init(gpa, render_width, render_height);
        errdefer renderer.deinit();
        var race_assets = try race_mod.loadAssets(gpa, &assets, &renderer);
        errdefer race_assets.deinit(gpa);
        const ui = try ui_mod.Ui.load(gpa, &assets, &renderer);
        const hud = try hud_mod.Hud.load(gpa, &assets, &renderer);
        var menu_assets = try game.loadMenuAssets(gpa, &assets, &renderer);
        errdefer menu_assets.deinit(gpa);

        var seed_bytes: [4]u8 = undefined;
        io.random(&seed_bytes);
        const rng = Rng.seed(std.mem.readInt(u32, &seed_bytes, .little));

        var state = game.State.init(saved);
        if (options.crt) |want_crt| state.save.crt = @intFromBool(want_crt);
        if (options.difficulty) |d| state.save.difficulty = @intFromEnum(d);
        state.skip_intro = @intFromBool(!options.intro);
        if (options.explicit) {
            if (options.rapier) state.save.has_rapier_class = 1;
            state.startRaceDirect(options.track, options.pilot, options.time_trial);
        }

        const bundle = self.bundle;
        self.* = .{
            .gpa = gpa,
            .io = io,
            .root = root,
            .bundle = bundle,
            .assets = assets,
            .renderer = renderer,
            .race_assets = race_assets,
            .ui = ui,
            .hud = hud,
            .menu_assets = menu_assets,
            .texture_base = renderer.texturesLen(),
            .state = state,
            .rng = rng,
            .save_path = save_path,
        };
        return self;
    }

    pub fn destroy(self: *Session) void {
        const gpa = self.gpa;
        self.flushSave();
        self.unloadTrack();
        self.menu_assets.deinit(gpa);
        self.race_assets.deinit(gpa);
        self.renderer.deinit();
        if (self.bundle) |b| {
            b.deinit();
            gpa.destroy(b);
        }
        if (self.save_path) |p| gpa.free(p);
        gpa.free(self.root);
        gpa.destroy(self);
    }

    fn unloadTrack(self: *Session) void {
        if (self.scene) |*s| s.deinit(self.gpa);
        if (self.track) |*t| t.deinit(self.gpa);
        self.scene = null;
        self.track = null;
        self.loaded_track = 0;
        self.renderer.resetTextures(self.texture_base);
    }

    /// Load the circuit the state wants, if it is not the loaded one.
    /// Failure sends the game back to the main menu.
    pub fn ensureTrack(self: *Session) void {
        const wanted = self.state.wantedTrack() orelse return;
        if (wanted == self.loaded_track and self.track != null) return;
        self.loadTrack(wanted) catch |err| {
            self.load_error = err;
            self.unloadTrack();
            self.state.goToMainMenu();
        };
    }

    fn loadTrack(self: *Session, number: u8) !void {
        self.unloadTrack();
        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "wipeout/track{d:0>2}", .{number});
        const circuit = defs.circuitSettings(number);
        var track = try track_mod.load(self.gpa, &self.assets, &self.renderer, dir);
        errdefer track.deinit(self.gpa);
        const scene = try scene_mod.load(self.gpa, &self.assets, &self.renderer, dir, circuit.sky_y_offset);
        self.track = track;
        self.scene = scene;
        self.loaded_track = number;
    }

    /// Begin or continue play; the clock restarts so a pause never turns
    /// into a burst of catch-up steps.
    pub fn resume_(self: *Session) void {
        self.paused = false;
        self.last_tick_ns = null;
        self.accumulator_ns = 0;
        self.input = .{};
    }

    pub fn pause(self: *Session) void {
        self.paused = true;
        self.input = .{};
        self.flushSave();
    }

    /// Advance by however much wall time passed since the previous tick,
    /// in fixed steps.
    pub fn tick(self: *Session) void {
        if (self.paused) return;
        const now = Io.Timestamp.now(self.io, .awake).nanoseconds;
        if (self.last_tick_ns) |last| {
            self.accumulator_ns += now - last;
        } else {
            self.accumulator_ns = @intFromFloat(step_seconds * std.time.ns_per_s);
        }
        self.last_tick_ns = now;

        const step_ns: i128 = @intFromFloat(step_seconds * std.time.ns_per_s);
        var steps: u32 = 0;
        while (self.accumulator_ns >= step_ns and steps < max_steps_per_tick) : (steps += 1) {
            self.accumulator_ns -= step_ns;
            self.step();
        }
        // Drop time we could not simulate rather than owe it.
        if (self.accumulator_ns > step_ns * 2) self.accumulator_ns = step_ns;
    }

    /// One fixed step of the whole game.
    pub fn step(self: *Session) void {
        self.ensureTrack();
        var effective = self.input;
        if (self.autopilot and self.state.inRace() and !self.input.anyHeld()) {
            if (self.track) |*t| autopilot.steer(self.state.race.playerShipConst(), t, &effective);
        }
        self.state.update(.{
            .input = &effective,
            .rng = &self.rng,
            .tick = step_seconds,
            .track = if (self.track) |*t| t else null,
            .track_number = self.loaded_track,
            .assets = &self.race_assets,
        });
        self.input.endFrame();
        self.steps += 1;
        self.cycle_time += @floatCast(step_seconds);
        if (self.state.save_dirty != 0) self.flushSave();
    }

    /// Write the options and best times when they changed.
    pub fn flushSave(self: *Session) void {
        if (self.state.save_dirty == 0) return;
        self.state.save_dirty = 0;
        const path = self.save_path orelse return;
        save_mod.write(self.io, path, &self.state.save) catch {};
    }

    pub fn crt(self: *const Session) bool {
        return self.state.crtEnabled();
    }

    pub fn toggleCrt(self: *Session) void {
        self.state.save.crt = @intFromBool(!self.crt());
        self.state.save_dirty = 1;
    }

    pub fn outputSize(self: *const Session) OutputSize {
        return if (self.crt())
            .{ .width = render_width * crt_scale, .height = render_height * crt_scale, .ship_every = 1 }
        else
            .{ .width = render_width, .height = render_height, .ship_every = 1 };
    }

    /// Render the current state into a packed RGB buffer of `out_w`×`out_h`
    /// (see `outputSize`).
    pub fn render(self: *Session, rgb: []u8, out_w: usize, out_h: usize) void {
        self.ensureTrack();
        const r = &self.renderer;
        self.state.draw(.{
            .renderer = r,
            .ui = &self.ui,
            .hud = &self.hud,
            .track = if (self.track) |*t| t else null,
            .scenery = if (self.scene) |*s| s else null,
            .assets = &self.race_assets,
            .menu_assets = &self.menu_assets,
            .dt = @floatCast(step_seconds),
            .autopilot = self.autopilot,
        });
        if (self.crt()) {
            post.crt(r.color, r.width, r.height, rgb, out_w, out_h, self.cycle_time);
        } else if (out_w == r.width and out_h == r.height) {
            r.writeRgb(rgb);
        } else {
            post.upscale(r.color, r.width, r.height, rgb, out_w, out_h);
        }
    }

    /// Whether this session is already what `options` asks for.
    pub fn matches(self: *const Session, options: StartOptions) bool {
        if (!options.explicit) return true;
        if (!self.state.inRace() and self.state.race_pending == 0) return false;
        const wanted = self.state.wantedTrack() orelse return false;
        const time_trial = self.state.race_type == .time_trial;
        const difficulty_ok = if (options.difficulty) |d| self.state.difficulty() == d else true;
        return wanted == options.track and self.state.pilot == options.pilot and time_trial == options.time_trial and difficulty_ok;
    }

    /// Copy a snapshot's state in. The circuit it needs loads on the next
    /// step; ships are checked against it here so a stale file cannot
    /// index past the track.
    pub fn restoreState(self: *Session, state: *const game.State, rng: Rng, steps: u64, on_autopilot: bool) !void {
        const saved = self.state.save;
        self.state = state.*;
        // The save file is written on every change, so it is at least as
        // new as the copy inside the snapshot.
        self.state.save = saved;
        self.state.save_dirty = 0;
        self.rng = rng;
        self.steps = steps;
        self.autopilot = on_autopilot;
        self.cycle_time = @as(f32, @floatFromInt(steps)) * @as(f32, @floatCast(step_seconds));
        if (self.state.scene == .race) {
            if (self.state.circuit >= defs.num_circuits or self.state.race_class > 1 or self.state.pilot >= defs.num_pilots) return error.BadSnapshot;
            self.ensureTrack();
            const track = self.track orelse return error.BadSnapshot;
            if (self.state.race_active != 0) {
                if (self.state.race.camera.section >= track.sections.len) return error.BadSnapshot;
                for (self.state.race.ships) |s| {
                    if (s.section >= track.sections.len) return error.BadSnapshot;
                }
            }
        }
    }
};
