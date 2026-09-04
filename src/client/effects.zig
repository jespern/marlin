//! One engine union over every screen effect. Cell effects paint the grid;
//! pixel effects (Kitty graphics) render a framebuffer that the TUI ships
//! with `transmit` before each draw. The caller handles capability: a pixel
//! kind on a terminal without graphics is started as its `fallback()`.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");
const visual_effect = @import("../core/visual_effect.zig");
const matrix = @import("matrix.zig");
const plasma = @import("plasma.zig");
const starfield = @import("starfield.zig");
const strings = @import("strings.zig");
const pacman = @import("pacman.zig");
const pixel_effects = @import("pixel_effects.zig");
const shadowbox = @import("shadowbox.zig");

pub const Kind = visual_effect.Kind;
pub const Backend = visual_effect.Backend;
pub const kinds = visual_effect.kinds;
pub const usage_list = visual_effect.usage_list;
/// The sky model the shadow-box follows; the TUI resolves it from the clock.
pub const Sky = shadowbox.Sky;

pub const Engine = union(enum) {
    matrix: matrix.Engine,
    strings: strings.Engine,
    stars: starfield.Engine,
    plasma: plasma.Engine,
    pacman: pacman.Engine,
    pixel: pixel_effects.Engine,

    /// `backend` is what the terminal can do: with `.pixel`, pixel kinds get
    /// the pixel engine; with `.cell`, every kind runs as its `fallback()`
    /// (Pac-Man on cells, the demoscene kinds as a cell sibling).
    pub fn init(gpa: std.mem.Allocator, which: Kind, seed: u64, backend: Backend) Engine {
        if (backend == .pixel and which.backend() == .pixel)
            return .{ .pixel = pixel_effects.Engine.init(gpa, which, seed) };
        return switch (which.fallback()) {
            .matrix => .{ .matrix = matrix.Engine.init(gpa, seed) },
            .strings => .{ .strings = strings.Engine.init(gpa, seed) },
            .stars => .{ .stars = starfield.Engine.init(gpa, seed) },
            .pacman => .{ .pacman = pacman.Engine.init(gpa, seed) },
            // fallback() never names the pixel-only kinds; plasma is the safe cell default.
            .plasma, .tunnel, .metaballs, .horizon, .demo, .shadowbox => .{ .plasma = plasma.Engine.init(gpa, seed) },
        };
    }

    pub fn kind(self: *const Engine) Kind {
        return switch (self.*) {
            .matrix => .matrix,
            .strings => .strings,
            .stars => .stars,
            .plasma => .plasma,
            .pacman => .pacman,
            .pixel => |*engine| engine.kind,
        };
    }

    pub fn isPixel(self: *const Engine) bool {
        return self.* == .pixel;
    }

    pub fn deinit(self: *Engine) void {
        switch (self.*) {
            inline else => |*engine| engine.deinit(),
        }
    }

    /// Where the sun and moon stand, for effects that follow them (the shadow-box).
    pub fn setSky(self: *Engine, sky: Sky) void {
        switch (self.*) {
            .pixel => |*engine| engine.setSky(sky),
            else => {},
        }
    }

    /// Terminal cell size in pixels (from the winsize report); pixel effects
    /// use it to match the framebuffer aspect. Cell effects ignore it.
    pub fn setCellPixels(self: *Engine, w: u32, h: u32) void {
        switch (self.*) {
            .pixel => |*engine| engine.setCellPixels(w, h),
            else => {},
        }
    }

    pub fn reset(self: *Engine, width: u16, height: u16, seed: u64) !void {
        switch (self.*) {
            inline else => |*engine| try engine.reset(width, height, seed),
        }
    }

    pub fn resize(self: *Engine, width: u16, height: u16) !void {
        switch (self.*) {
            inline else => |*engine| try engine.resize(width, height),
        }
    }

    pub fn tick(self: *Engine) void {
        switch (self.*) {
            inline else => |*engine| engine.tick(),
        }
    }

    /// Pixel effects: render and ship the current frame (before draw).
    /// Cell effects: nothing to do.
    pub fn transmit(self: *Engine, vx: *vaxis.Vaxis, tty: *std.Io.Writer) !void {
        switch (self.*) {
            .pixel => |*engine| try engine.transmit(vx, tty),
            else => {},
        }
    }

    /// Pixel effects: free the terminal-side image when the effect ends.
    pub fn release(self: *Engine, vx: *vaxis.Vaxis, tty: *std.Io.Writer) void {
        switch (self.*) {
            .pixel => |*engine| engine.release(vx, tty),
            else => {},
        }
    }

    pub fn hasImage(self: *const Engine) bool {
        return switch (self.*) {
            .pixel => |*engine| engine.hasImage(),
            else => false,
        };
    }

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        switch (self.*) {
            inline else => |*engine| engine.draw(win, mode, opacity),
        }
    }
};
