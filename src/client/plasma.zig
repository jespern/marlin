const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

pub const Engine = struct {
    width: u16 = 0,
    height: u16 = 0,
    frame: u64 = 0,
    seed_phase: f32,

    pub fn init(_: std.mem.Allocator, seed: u64) Engine {
        return .{ .seed_phase = phaseFromSeed(seed) };
    }

    pub fn deinit(self: *Engine) void {
        self.* = undefined;
    }

    pub fn reset(self: *Engine, width: u16, height: u16, seed: u64) !void {
        self.width = width;
        self.height = height;
        self.frame = 0;
        self.seed_phase = phaseFromSeed(seed);
    }

    pub fn resize(self: *Engine, width: u16, height: u16) !void {
        self.width = width;
        self.height = height;
    }

    pub fn tick(self: *Engine) void {
        self.frame +%= 1;
    }

    pub fn draw(self: *const Engine, win: vaxis.Window, mode: effect.DrawMode, opacity: u8) void {
        if (win.width == 0 or win.height == 0 or opacity == 0) return;
        effect.prepare(win, mode);
        const time = @as(f32, @floatFromInt(self.frame)) * 0.055 + self.seed_phase;
        const width: u16 = @intCast(@min(win.width, self.width));
        const height: u16 = @intCast(@min(win.height, self.height));
        var row: u16 = 0;
        while (row < height) : (row += 1) {
            var col: u16 = 0;
            while (col < width) : (col += 1) {
                if (mode == .interleaved and !effect.cellIsOpen(win, col, row)) continue;
                const x: f32 = @floatFromInt(col);
                const y: f32 = @floatFromInt(row);
                const value = @sin(x * 0.17 + time) +
                    @sin(y * 0.31 - time * 0.83) +
                    @sin((x + y * 1.7) * 0.11 + time * 0.57) +
                    @sin(@sqrt((x - @as(f32, @floatFromInt(width)) * 0.5) * (x - @as(f32, @floatFromInt(width)) * 0.5) +
                        (y * 2.0 - @as(f32, @floatFromInt(height))) * (y * 2.0 - @as(f32, @floatFromInt(height)))) * 0.14 - time);
                const normalized = (value + 4.0) / 8.0;
                const color = plasmaColor(normalized, opacity);
                var cell = win.readCell(col, row) orelse continue;
                cell.char = .{ .grapheme = " ", .width = 1 };
                cell.style.bg = color;
                cell.style.fg = color;
                cell.style.bold = false;
                cell.style.dim = false;
                cell.link = .{};
                cell.image = null;
                cell.default = false;
                win.writeCell(col, row, cell);
            }
        }
    }
};

fn phaseFromSeed(seed: u64) f32 {
    return @as(f32, @floatFromInt(effect.hash(seed) & 0xffff)) / 10430.0;
}

fn plasmaColor(value: f32, opacity: u8) vaxis.Color {
    const tau: f32 = std.math.tau;
    const red = (@sin(value * tau) * 0.5 + 0.5) * 210.0 + 25.0;
    const green = (@sin(value * tau + 2.094) * 0.5 + 0.5) * 170.0 + 18.0;
    const blue = (@sin(value * tau + 4.188) * 0.5 + 0.5) * 225.0 + 25.0;
    return effect.scaledColor(.{ @intFromFloat(red), @intFromFloat(green), @intFromFloat(blue) }, opacity);
}
