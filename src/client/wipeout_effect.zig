//! wipEout as a client-side game: a `wipeout.session.Session` (assets,
//! circuit, state machine, clock) plus the terminal key mapping. The game
//! object lives on the App, not on the effect engine, so hiding the effect
//! keeps the game exactly where it was; `!wipeout` resumes it. Only the
//! engine's framebuffer and the terminal-side image are recreated.

const std = @import("std");
const vaxis = @import("vaxis");
const wipeout = @import("../wipeout/root.zig");
const Io = std.Io;

pub const snapshot = wipeout.snapshot;
pub const parzlib = wipeout.parzlib;
pub const Session = wipeout.session.Session;
pub const Options = wipeout.session.StartOptions;
pub const OutputSize = wipeout.session.OutputSize;
pub const render_width = wipeout.session.render_width;
pub const render_height = wipeout.session.render_height;
pub const step_seconds = wipeout.session.step_seconds;

pub const Game = struct {
    session: *Session,
    gpa: std.mem.Allocator,

    pub fn create(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, options: Options) !*Game {
        const self = try gpa.create(Game);
        errdefer gpa.destroy(self);
        self.* = .{ .session = try Session.create(gpa, io, environ, options), .gpa = gpa };
        return self;
    }

    pub fn destroy(self: *Game) void {
        self.session.destroy();
        self.gpa.destroy(self);
    }

    /// Capture the game for `snapshot.write`.
    pub fn snapshot(self: *const Game) wipeout.snapshot.Snapshot {
        const s = self.session;
        return .{
            .autopilot = @intFromBool(s.autopilot),
            .steps = s.steps,
            .state = s.state,
            .rng = s.rng,
        };
    }

    /// Rebuild a game from a snapshot: assets reload, state is copied in.
    pub fn restore(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, snap: *const wipeout.snapshot.Snapshot) !*Game {
        const self = try create(gpa, io, environ, .{});
        errdefer self.destroy();
        try self.session.restoreState(&snap.state, snap.rng, snap.steps, snap.autopilot != 0);
        return self;
    }

    pub fn matches(self: *const Game, options: Options) bool {
        return self.session.matches(options);
    }

    pub fn resume_(self: *Game) void {
        self.session.resume_();
    }

    pub fn pause(self: *Game) void {
        self.session.pause();
    }

    pub fn tick(self: *Game) void {
        self.session.tick();
    }

    pub fn outputSize(self: *const Game) OutputSize {
        return self.session.outputSize();
    }

    pub fn render(self: *Game, rgb: []u8, out_w: usize, out_h: usize) void {
        self.session.render(rgb, out_w, out_h);
    }

    pub fn toggleCrt(self: *Game) void {
        self.session.toggleCrt();
    }

    /// Map a terminal key to game actions. Arrows steer and pitch and move
    /// the menu cursor; `x` or space thrusts and selects; `z`/`c` are the
    /// airbrakes; `v` toggles the view; `f` fires; Enter starts and pauses;
    /// Backspace goes back a menu page.
    pub fn actionsForKey(key: vaxis.Key) [2]?wipeout.input.Action {
        return switch (key.codepoint) {
            vaxis.Key.left => .{ .left, .menu_left },
            vaxis.Key.right => .{ .right, .menu_right },
            vaxis.Key.up => .{ .up, .menu_up },
            vaxis.Key.down => .{ .down, .menu_down },
            'x', 'X', vaxis.Key.space => .{ .thrust, .menu_select },
            'w', 'W' => .{ .thrust, null },
            'z', 'Z' => .{ .brake_left, null },
            'c', 'C' => .{ .brake_right, null },
            'a', 'A' => .{ .left, .menu_left },
            'd', 'D' => .{ .right, .menu_right },
            'v', 'V' => .{ .change_view, null },
            'f', 'F' => .{ .fire, null },
            vaxis.Key.enter => .{ .menu_start, null },
            vaxis.Key.backspace => .{ .menu_back, null },
            else => .{ null, null },
        };
    }

    pub fn setKey(self: *Game, key: vaxis.Key, down: bool) bool {
        if (key.codepoint == 'p' or key.codepoint == 'P') {
            if (down) self.toggleCrt();
            return true;
        }
        if (key.codepoint == vaxis.Key.tab) {
            if (down) self.session.autopilot = !self.session.autopilot;
            return true;
        }
        const actions = actionsForKey(key);
        if (actions[0] == null) return false;
        for (actions) |maybe| {
            if (maybe) |action| self.session.input.set(action, down);
        }
        return true;
    }
};
