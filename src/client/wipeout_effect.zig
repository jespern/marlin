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

pub const width: u16 = 320;
pub const height: u16 = 240;
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
};

pub const Game = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: Options,
    renderer: wipeout.render.Renderer,
    track: wipeout.track.Track,
    scene: wipeout.scene.Scene,
    models: wipeout.ship.Models,
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

    pub fn create(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, options: Options) !*Game {
        const root = try wipeout.assets.defaultRoot(gpa, environ);
        defer gpa.free(root);
        const assets = wipeout.assets.Assets.init(io, gpa, root);

        var dir_buf: [32]u8 = undefined;
        const dir = try std.fmt.bufPrint(&dir_buf, "wipeout/track{d:0>2}", .{options.track});
        const circuit = wipeout.defs.circuitSettings(options.track);

        const self = try gpa.create(Game);
        errdefer gpa.destroy(self);

        var renderer = try wipeout.render.Renderer.init(gpa, width, height);
        errdefer renderer.deinit();
        var track = try wipeout.track.load(gpa, &assets, &renderer, dir);
        errdefer track.deinit(gpa);
        var scene = try wipeout.scene.load(gpa, &assets, &renderer, dir, circuit.sky_y_offset);
        errdefer scene.deinit(gpa);
        var models = try wipeout.ship.loadModels(gpa, &assets, &renderer);
        errdefer models.deinit(gpa);

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
            .ship = ship,
            .camera = wipeout.camera.Camera.init(&track, 0),
            .rng = wipeout.rng.Rng.seed(std.mem.readInt(u32, &seed_bytes, .little)),
            .start_line_pos = circuit.start_line_pos,
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
    }

    /// Render the current state into a packed RGB buffer of `width`×`height`.
    pub fn render(self: *Game, rgb: []u8) void {
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
        r.writeRgb(rgb);
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
        const action = actionForKey(key) orelse return false;
        self.input.set(action, down);
        return true;
    }
};
