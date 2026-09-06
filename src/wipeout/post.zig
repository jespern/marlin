//! Post effects over the finished frame. The CRT pass reproduces the
//! original's fragment shader (curvature, colour fringing, vignette,
//! scanlines, flicker, alternate-column darkening) per pixel on the CPU.
//! Coordinates follow the shader's GL conventions (y up, texture row 0 at
//! the bottom) and are converted when sampling the top-down framebuffer.

const std = @import("std");
const math = @import("math.zig");
const Rgba = math.Rgba;

pub const Effect = enum(u8) { none, crt };

const Sampler = struct {
    src: []const Rgba,
    width: usize,
    height: usize,
    fw: f32,
    fh: f32,

    /// Nearest sample with clamp-to-edge, `v` measured bottom-up.
    inline fn at(self: *const Sampler, u: f32, v: f32) Rgba {
        const x: usize = @intFromFloat(std.math.clamp(@floor(u * self.fw), 0, self.fw - 1));
        const row_from_bottom: usize = @intFromFloat(std.math.clamp(@floor(v * self.fh), 0, self.fh - 1));
        return self.src[(self.height - 1 - row_from_bottom) * self.width + x];
    }
};

inline fn channel(c: u8) f32 {
    return @as(f32, @floatFromInt(c)) / 255.0;
}

inline fn toByte(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0 + 0.5);
}

const lut_size = 4096;

/// Per-frame tables over the curved v coordinate: the horizontal jitter
/// term (three sines) and the scanline gain including its power curve.
const Tables = struct {
    jitter: [lut_size]f32,
    line: [lut_size]f32,

    fn build(time: f32, screen_h: f32) Tables {
        var t: Tables = undefined;
        var i: usize = 0;
        while (i < lut_size) : (i += 1) {
            const uy = (@as(f32, @floatFromInt(i)) + 0.5) / lut_size;
            t.jitter[i] = @sin(0.3 * time + uy * 21.0) * @sin(0.7 * time + uy * 29.0) * @sin(0.3 + 0.33 * time + uy * 31.0) * 0.0017;
            const scan = std.math.clamp(0.35 + 0.35 * @sin(3.5 * time + uy * screen_h * 1.5), 0.0, 1.0);
            t.line[i] = 0.4 + 0.7 * std.math.pow(f32, scan, 1.7);
        }
        return t;
    }
};

/// Apply the CRT pass from `src` (width×height) into packed RGB `dst` of
/// `out_width`×`out_height`. The original evaluates this at window
/// resolution over the 240p image, so callers upscale (2x is plenty).
/// `time` is the game's cycle time in seconds.
/// Row bands the CRT pass is split across, each on its own thread; the
/// pass is embarrassingly parallel and the tables are shared read-only.
pub const crt_threads: usize = 6;

pub fn crt(src: []const Rgba, width: usize, height: usize, dst: []u8, out_width: usize, out_height: usize, time: f32) void {
    std.debug.assert(src.len >= width * height and dst.len >= out_width * out_height * 3);
    const tables = Tables.build(time, @floatFromInt(out_height));
    var threads: [crt_threads]?std.Thread = .{null} ** crt_threads;
    const rows_per = (out_height + crt_threads - 1) / crt_threads;
    var i: usize = 0;
    while (i < crt_threads) : (i += 1) {
        const y0 = i * rows_per;
        const y1 = @min(y0 + rows_per, out_height);
        if (y0 >= y1) break;
        if (y1 == out_height) {
            // The last band runs on the calling thread.
            crtRows(src, width, height, dst, out_width, out_height, time, &tables, y0, y1);
            break;
        }
        threads[i] = std.Thread.spawn(.{}, crtRows, .{ src, width, height, dst, out_width, out_height, time, &tables, y0, y1 }) catch blk: {
            crtRows(src, width, height, dst, out_width, out_height, time, &tables, y0, y1);
            break :blk null;
        };
    }
    for (threads) |maybe| {
        if (maybe) |th| th.join();
    }
}

fn crtRows(src: []const Rgba, width: usize, height: usize, dst: []u8, out_width: usize, out_height: usize, time: f32, tables: *const Tables, row_start: usize, row_end: usize) void {
    std.debug.assert(src.len >= width * height and dst.len >= out_width * out_height * 3);
    const sampler = Sampler{ .src = src, .width = width, .height = height, .fw = @floatFromInt(width), .fh = @floatFromInt(height) };
    const screen_w: f32 = @floatFromInt(out_width);
    const screen_h: f32 = @floatFromInt(out_height);
    const flicker = 1.0 + 0.01 * @sin(110.0 * time);

    var oy: usize = row_start;
    while (oy < row_end) : (oy += 1) {
        // Fragment y counts from the bottom in GL.
        const frag_y = (@as(f32, @floatFromInt(out_height - 1 - oy)) + 0.5) / screen_h;
        const base_uy = (frag_y - 0.5) * 2.0 * 1.1;
        const ky = @abs(base_uy) / 5.0;
        const x_stretch = 1.0 + ky * ky;
        var ox: usize = 0;
        while (ox < out_width) : (ox += 1) {
            const frag_x = (@as(f32, @floatFromInt(ox)) + 0.5) / screen_w;

            // Barrel curve.
            var ux = (frag_x - 0.5) * 2.0 * 1.1 * x_stretch;
            const kx = @abs(ux) / 4.0;
            var uy = base_uy * (1.0 + kx * kx);
            ux = (ux / 2.0 + 0.5) * 0.92 + 0.04;
            uy = (uy / 2.0 + 0.5) * 0.92 + 0.04;

            const out = oy * out_width * 3 + ox * 3;
            if (ux < 0 or ux > 1 or uy < 0 or uy > 1) {
                dst[out] = 0;
                dst[out + 1] = 0;
                dst[out + 2] = 0;
                continue;
            }

            const li: usize = @intFromFloat(uy * (lut_size - 1));
            const x = tables.jitter[li];

            var r = channel(sampler.at(x + ux + 0.001, uy + 0.001).r) + 0.05;
            var g = channel(sampler.at(x + ux, uy - 0.002).g) + 0.05;
            var b = channel(sampler.at(x + ux - 0.002, uy).b) + 0.05;
            r += 0.08 * channel(sampler.at(0.75 * (x + 0.025) + ux + 0.001, 0.75 * -0.027 + uy + 0.001).r);
            g += 0.05 * channel(sampler.at(0.75 * (x - 0.022) + ux, 0.75 * -0.02 + uy - 0.002).g);
            b += 0.08 * channel(sampler.at(0.75 * (x - 0.02) + ux - 0.002, 0.75 * -0.018 + uy).b);

            r = std.math.clamp(r * 0.6 + 0.4 * r * r, 0.0, 1.0);
            g = std.math.clamp(g * 0.6 + 0.4 * g * g, 0.0, 1.0);
            b = std.math.clamp(b * 0.6 + 0.4 * b * b, 0.0, 1.0);

            const vignette = 16.0 * ux * uy * (1.0 - ux) * (1.0 - uy);
            const vig = @sqrt(@sqrt(@max(vignette, 0.0)));
            var gain = tables.line[li] * flicker * vig * 2.8;
            // Every other fragment column is darkened (mod(x, 2) test).
            if (ox % 2 == 1) gain *= 0.35;

            dst[out] = toByte(r * 0.95 * gain);
            dst[out + 1] = toByte(g * 1.05 * gain);
            dst[out + 2] = toByte(b * 0.95 * gain);
        }
    }
}

/// Nearest-neighbour upscale of the framebuffer into packed RGB.
pub fn upscale(src: []const Rgba, width: usize, height: usize, dst: []u8, out_width: usize, out_height: usize) void {
    var oy: usize = 0;
    while (oy < out_height) : (oy += 1) {
        const sy = oy * height / out_height;
        var ox: usize = 0;
        while (ox < out_width) : (ox += 1) {
            const c = src[sy * width + ox * width / out_width];
            const out = (oy * out_width + ox) * 3;
            dst[out] = c.r;
            dst[out + 1] = c.g;
            dst[out + 2] = c.b;
        }
    }
}

test "crt keeps the corners black and the centre lit" {
    const w = 32;
    const h = 24;
    var src: [w * h]Rgba = undefined;
    @memset(&src, Rgba.init(200, 200, 200, 255));
    var dst: [w * h * 3]u8 = undefined;
    crt(&src, w, h, &dst, w, h, 0.0);
    try std.testing.expectEqual(@as(u8, 0), dst[0]);
    const centre = (h / 2) * w * 3 + (w / 2) * 3;
    try std.testing.expect(dst[centre] > 60);
    var big: [w * h * 4 * 3]u8 = undefined;
    upscale(&src, w, h, &big, w * 2, h * 2);
    try std.testing.expectEqual(@as(u8, 200), big[0]);
}
