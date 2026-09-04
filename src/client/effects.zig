const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");
const visual_effect = @import("../core/visual_effect.zig");
const matrix = @import("matrix.zig");
const plasma = @import("plasma.zig");
const starfield = @import("starfield.zig");
const strings = @import("strings.zig");

pub const Kind = visual_effect.Kind;
pub const kinds = visual_effect.kinds;

pub const Engine = union(Kind) {
    matrix: matrix.Engine,
    strings: strings.Engine,
    stars: starfield.Engine,
    plasma: plasma.Engine,

    pub fn init(gpa: std.mem.Allocator, kind: Kind, seed: u64) Engine {
        return switch (kind) {
            .matrix => .{ .matrix = matrix.Engine.init(gpa, seed) },
            .strings => .{ .strings = strings.Engine.init(gpa, seed) },
            .stars => .{ .stars = starfield.Engine.init(gpa, seed) },
            .plasma => .{ .plasma = plasma.Engine.init(gpa, seed) },
        };
    }

    pub fn deinit(self: *Engine) void {
        switch (self.*) {
            inline else => |*engine| engine.deinit(),
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

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        switch (self.*) {
            inline else => |*engine| engine.draw(win, mode, opacity),
        }
    }
};
