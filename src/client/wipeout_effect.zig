//! wipEout as a client-side game: owns the loaded circuit, the player ship,
//! the chase camera and the input state, steps the simulation on the
//! animation ticker, and renders into the pixel effect's framebuffer.
//!
//! The game object lives on the App, not on the effect engine, so hiding
//! the effect (or running a different screensaver in between) keeps the
//! race exactly where it was; `!wipeout` resumes it. Only the engine's
//! framebuffer and the terminal-side image are recreated.

const std = @import("std");
const vaxis = @import("vaxis");
const wipeout = @import("../wipeout/root.zig");
const Io = std.Io;

pub const snapshot = wipeout.snapshot;

/// The simulation renders at PSX-native 240p and, without the CRT pass,
/// ships that at 60 fps. The CRT pass needs room for its scanlines and
/// column mask (the original evaluates it at window resolution over the
/// low-res image), so with it on the effect outputs 2x and ships at 30 fps:
/// a 640x480 CRT frame deflates poorly and would not fit a 16 ms budget.
pub const render_width: u16 = 320;
pub const render_height: u16 = 240;
pub const crt_scale: u16 = 2;

pub const OutputSize = struct { width: u16, height: u16, ship_every: u8 };
/// Fixed physics step; presentation may run at any rate.
pub const step_hz: u32 = 60;
pub const step_seconds: f64 = 1.0 / @as(f64, @floatFromInt(step_hz));
/// Never simulate more than this many steps per tick after a stall.
const max_steps_per_tick: u32 = 4;

pub const Options = struct {
    track: u8 = 1,
    pilot: u8 = 0,
    rapier: bool = false,
    intro: bool = true,
    crt: bool = false,
    /// Set when the user named a track/pilot/class explicitly; a bare
    /// `!wipeout` prefers a saved race over these defaults.
    explicit: bool = false,
};

pub const Game = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    renderer: wipeout.render.Renderer,
    track: wipeout.track.Track,
    scene: wipeout.scene.Scene,
    models: wipeout.ship.Models,
    ui: wipeout.ui.Ui,
    hud: wipeout.hud.Hud,
    ship: wipeout.ship.Ship,
    camera: wipeout.camera.Camera,
    input: wipeout.input.State = .{},
    rng: wipeout.rng.Rng,
    start_line_pos: u16,
    /// Wall-clock accumulator for fixed-step simulation, in nanoseconds.
    accumulator_ns: i128 = 0,
    last_tick_ns: ?i128 = null,
    paused: bool = true,
    steps: u64 = 0,
    /// Simulated seconds, drives the CRT pass's animation.
    cycle_time: f32 = 0,
    crt: bool = false,

    pub fn create(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, options: Options) !*Game {
        const root = try wipeout.assets.defaultRoot(gpa, environ);
        defer gpa.free(root);
        const assets = wipeout.assets.Assets.init(io, gpa, root);

        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "wipeout/track{d:0>2}", .{options.track});
        const circuit = wipeout.defs.circuitSettings(options.track);

        const self = try gpa.create(Game);
        errdefer gpa.destroy(self);

        var renderer = try wipeout.render.Renderer.init(gpa, render_width, render_height);
        errdefer renderer.deinit();
        var track = try wipeout.track.load(gpa, &assets, &renderer, dir);
        errdefer track.deinit(gpa);
        var scene = try wipeout.scene.load(gpa, &assets, &renderer, dir, circuit.sky_y_offset);
        errdefer scene.deinit(gpa);
        var models = try wipeout.ship.loadModels(gpa, &assets, &renderer);
        errdefer models.deinit(gpa);
        const ui = try wipeout.ui.Ui.load(gpa, &assets, &renderer);
        const hud = try wipeout.hud.Hud.load(gpa, &assets, &renderer);

        // The player takes the rear grid slot, start_line_pos - 15 sections in.
        var start: u32 = 0;
        var i: usize = 0;
        while (i + 15 < circuit.start_line_pos) : (i += 1) start = track.sections[start].next;
        var ship = wipeout.ship.Ship.init(&track, start, options.pilot, 0, if (options.rapier) .rapier else .venom);
        if (!options.intro) ship.skipIntro();

        var seed_bytes: [4]u8 = undefined;
        io.random(&seed_bytes);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .options = options,
            .renderer = renderer,
            .track = track,
            .scene = scene,
            .models = models,
            .ui = ui,
            .hud = hud,
            .ship = ship,
            .camera = wipeout.camera.Camera.init(&track, 0),
            .rng = wipeout.rng.Rng.seed(std.mem.readInt(u32, &seed_bytes, .little)),
            .start_line_pos = circuit.start_line_pos,
            .crt = options.crt,
        };
        // The track and scene slices were moved into the struct; the local
        // copies must not be freed twice.
        return self;
    }

    pub fn destroy(self: *Game) void {
        const gpa = self.gpa;
        self.models.deinit(gpa);
        self.scene.deinit(gpa);
        self.track.deinit(gpa);
        self.renderer.deinit();
        gpa.destroy(self);
    }

    /// Capture the race for `snapshot.write`.
    pub fn snapshot(self: *const Game) wipeout.snapshot.Snapshot {
        return .{
            .track = self.options.track,
            .pilot = self.options.pilot,
            .rapier = @intFromBool(self.options.rapier),
            .crt = @intFromBool(self.crt),
            .steps = self.steps,
            .ship = self.ship,
            .camera = self.camera,
            .rng = self.rng,
        };
    }

    /// Rebuild a game from a snapshot: assets reload, state is copied in.
    pub fn restore(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, snap: *const wipeout.snapshot.Snapshot) !*Game {
        const options = Options{
            .track = snap.track,
            .pilot = snap.pilot,
            .rapier = snap.rapier != 0,
            .crt = snap.crt != 0,
        };
        if (options.track < 1 or options.track > 14 or options.pilot >= wipeout.defs.num_pilots) return error.BadSnapshot;
        const self = try create(gpa, io, environ, options);
        if (snap.ship.section >= self.track.sections.len or snap.camera.section >= self.track.sections.len) {
            self.destroy();
            return error.BadSnapshot;
        }
        self.ship = snap.ship;
        self.camera = snap.camera;
        self.rng = snap.rng;
        self.steps = snap.steps;
        self.cycle_time = @as(f32, @floatFromInt(snap.steps)) * @as(f32, @floatCast(step_seconds));
        return self;
    }

    pub fn matches(self: *const Game, options: Options) bool {
        return self.options.track == options.track and self.options.pilot == options.pilot and self.options.rapier == options.rapier;
    }

    /// Begin or continue play; the clock restarts so a pause never turns
    /// into a burst of catch-up steps.
    pub fn resume_(self: *Game) void {
        self.paused = false;
        self.last_tick_ns = null;
        self.accumulator_ns = 0;
        self.input = .{};
    }

    pub fn pause(self: *Game) void {
        self.paused = true;
        self.input = .{};
    }

    /// Advance by however much wall time passed since the previous tick,
    /// in fixed steps.
    pub fn tick(self: *Game) void {
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

    fn step(self: *Game) void {
        self.ship.update(.{
            .track = &self.track,
            .input = &self.input,
            .rng = &self.rng,
            .tick = step_seconds,
            .start_line_pos = self.start_line_pos,
        });
        self.camera.mode = if (self.ship.flags.view_internal) .internal else .external;
        self.camera.update(&self.track, &self.ship, @floatCast(step_seconds));
        self.input.endFrame();
        self.steps += 1;
        self.cycle_time += @floatCast(step_seconds);
    }

    pub fn outputSize(self: *const Game) OutputSize {
        return if (self.crt)
            .{ .width = render_width * crt_scale, .height = render_height * crt_scale, .ship_every = 2 }
        else
            .{ .width = render_width, .height = render_height, .ship_every = 1 };
    }

    /// Render the current state into a packed RGB buffer of `out_w`×`out_h`
    /// (see `outputSize`).
    pub fn render(self: *Game, rgb: []u8, out_w: usize, out_h: usize) void {
        const r = &self.renderer;
        r.framePrepare();
        r.setView(self.camera.position, self.camera.angle);
        const forward = self.camera.forward();
        r.setCullBackface(false);
        self.scene.draw(r, self.camera.position, forward);
        self.track.draw(r, self.camera.position, forward);
        r.setCullBackface(true);
        if (!(self.ship.flags.view_internal and !self.ship.flags.in_rescue)) self.ship.draw(r, &self.models);
        if (self.ship.flags.visible and !self.ship.flags.flying) {
            r.setModelMat(&wipeout.math.Mat4.identity);
            r.setDepthWrite(false);
            r.setDepthOffset(-32.0);
            self.ship.drawShadow(r, &self.track, &self.models);
            r.setDepthOffset(0);
            r.setDepthWrite(true);
        }
        self.hud.draw(r, &self.ui, &self.ship);
        if (self.crt) {
            wipeout.post.crt(r.color, r.width, r.height, rgb, out_w, out_h, self.cycle_time);
        } else if (out_w == r.width and out_h == r.height) {
            r.writeRgb(rgb);
        } else {
            wipeout.post.upscale(r.color, r.width, r.height, rgb, out_w, out_h);
        }
    }

    pub fn toggleCrt(self: *Game) void {
        self.crt = !self.crt;
    }

    /// Map a terminal key to a game action. Arrows steer and pitch; `x` or
    /// space thrusts; `z`/`c` are the airbrakes; `v` toggles the view.
    pub fn actionForKey(key: vaxis.Key) ?wipeout.input.Action {
        return switch (key.codepoint) {
            vaxis.Key.left => .left,
            vaxis.Key.right => .right,
            vaxis.Key.up => .up,
            vaxis.Key.down => .down,
            'x', 'X', vaxis.Key.space, 'w', 'W' => .thrust,
            'z', 'Z' => .brake_left,
            'c', 'C' => .brake_right,
            'a', 'A' => .left,
            'd', 'D' => .right,
            'v', 'V' => .change_view,
            else => null,
        };
    }

    pub fn setKey(self: *Game, key: vaxis.Key, down: bool) bool {
        if (key.codepoint == 'p' or key.codepoint == 'P') {
            if (down) self.toggleCrt();
            return true;
        }
        const action = actionForKey(key) orelse return false;
        self.input.set(action, down);
        return true;
    }
};
