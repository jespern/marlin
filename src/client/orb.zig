//! Thinking-orb pixel effect. The first frame rasterizes Marlin's cell grid
//! into a softened backdrop; later frames keep that snapshot still while a
//! globe of scattered nodes turns above it and pulses fire along edges
//! between neighbouring nodes, sporadically, like a brain lighting up.

const std = @import("std");
const vaxis = @import("vaxis");

pub const default_fg = [3]u8{ 184, 194, 214 };
pub const default_bg = [3]u8{ 8, 10, 16 };
const ansi = [16][3]u8{
    .{ 0, 0, 0 },       .{ 205, 49, 49 },   .{ 13, 188, 121 }, .{ 229, 229, 16 },
    .{ 36, 114, 200 },  .{ 188, 63, 188 },  .{ 17, 168, 205 }, .{ 229, 229, 229 },
    .{ 102, 102, 102 }, .{ 241, 76, 76 },   .{ 35, 209, 139 }, .{ 245, 245, 67 },
    .{ 59, 142, 234 },  .{ 214, 112, 214 }, .{ 41, 184, 219 }, .{ 255, 255, 255 },
};

pub fn capture(background: []u8, scratch: []u8, width: u16, height: u16, win: vaxis.Window, fallback_fg: [3]u8, fallback_bg: [3]u8) void {
    if (width == 0 or height == 0) return;
    @memset(background, 0);
    const cols = @max(win.width, 1);
    const rows = @max(win.height, 1);

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        const row: u16 = @intCast(@min(@as(u32, y) * rows / height, rows - 1));
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const col: u16 = @intCast(@min(@as(u32, x) * cols / width, cols - 1));
            const cell = win.readCell(col, row) orelse continue;
            var fg = colorRgb(cell.style.fg, fallback_fg);
            var bg = colorRgb(cell.style.bg, fallback_bg);
            if (cell.style.reverse) std.mem.swap([3]u8, &fg, &bg);
            const cell_x0 = @as(u32, col) * width / cols;
            const cell_y0 = @as(u32, row) * height / rows;
            const cell_x1 = @as(u32, col + 1) * width / cols;
            const cell_y1 = @as(u32, row + 1) * height / rows;
            const inside_x = @as(u32, x) - cell_x0;
            const inside_y = @as(u32, y) - cell_y0;
            const cell_w = @max(cell_x1 - cell_x0, 1);
            const cell_h = @max(cell_y1 - cell_y0, 1);
            const glyph = !std.mem.eql(u8, cell.char.grapheme, " ") and !cell.style.invisible;
            const ink = glyph and inside_x > cell_w / 7 and inside_x < cell_w * 6 / 7 and
                inside_y > cell_h / 6 and inside_y < cell_h * 5 / 6;
            const color = if (ink) fg else bg;
            const i = (@as(usize, y) * width + x) * 3;
            for (background[i..][0..3], color) |*dst, value| {
                const dimmed: u16 = if (ink) @as(u16, value) * 62 / 100 else @as(u16, value) * 48 / 100;
                dst.* = @intCast(dimmed);
            }
        }
    }

    boxBlur(background, scratch, width, height, 5);
    boxBlur(background, scratch, width, height, 5);
}

/// A thinking orb: a sphere of a few thousand tiny particles turning slowly,
/// dense and bright at the limb where the projection stacks them, dim and
/// sparse across the face, breathing and shimmering, with a faint drifting
/// halo and a slow low-frequency relief that gives the shell texture.
/// Particles are additive with a soft bloom, so where they crowd they glow.
/// Stateless: every frame is a pure function of (frame, seed). `scratch` is
/// a working buffer at least as large as `rgb`.
pub fn render(rgb: []u8, scratch: []u8, background: []const u8, width: u16, height: u16, frame: u64, seed: u64) void {
    @memcpy(rgb, background);
    if (width == 0 or height == 0) return;
    const light = scratch[0..rgb.len];
    @memset(light, 0);

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const time = seconds(frame);
    const radius = @min(w, h) * 0.30 * (1.0 + 0.012 * @sin(time * 0.9));
    const cx = w * 0.5 + @sin(time * 0.23 + seedPhase(seed)) * w * 0.015;
    const cy = h * 0.48 + @sin(time * 0.41 + 1.7) * h * 0.010;

    const spin = time * 0.22 + seedPhase(seed);
    const tilt: f32 = 0.38;
    const rot = Rotation.init(spin, tilt);

    // Surface shell: Fibonacci-distributed, each particle jittered slightly
    // off the sphere and shimmering along its normal so the surface looks
    // alive rather than machined.
    var i: usize = 0;
    while (i < shell_count) : (i += 1) {
        const key = hash(@intCast(i & 0xffff), @intCast(i >> 16), 0, seed);
        const dir = randomDirection(key);
        // Relief: a slow, low-frequency terrain fixed to the globe lifts some
        // regions a few percent and brightens their ridges, so the shell has
        // texture instead of a uniform skin. It drifts very slowly.
        const elev = relief(dir, time);
        const jitter = 0.985 + 0.02 * unit(key) + elev + 0.008 * @sin(time * 1.3 + unit(key >> 16) * 6.283);
        const p = rot.apply(dir.scale(jitter));
        const depth = (p.z + 1.0) * 0.5;
        const twinkle = 0.7 + 0.3 * @sin(time * (1.5 + unit(key >> 24) * 2.0) + unit(key >> 32) * 6.283);
        // face dim, limb bright: |z| small means we look at the edge
        const limb = 1.0 - @abs(p.z);
        const ridge = 1.0 + 12.0 * elev; // ±0.03 relief -> roughly ±35% brightness
        const intensity = (0.30 + 0.95 * depth * depth + 1.1 * limb * limb * limb) * twinkle * ridge;
        splat(light, width, height, cx + p.x * radius, cy + p.y * radius, intensity, depth);
    }

    // Sparse interior mist, dimmer, so the ball has volume without a solid body.
    i = 0;
    while (i < core_count) : (i += 1) {
        const key = hash(@intCast(i & 0xffff), 7, 0, seed);
        const dir = randomDirection(key >> 8);
        const r = 0.2 + 0.75 * std.math.cbrt(unit(key));
        const p = rot.apply(dir.scale(r));
        const depth = (p.z + 1.0) * 0.5;
        const twinkle = 0.6 + 0.4 * @sin(time * 0.9 + unit(key >> 20) * 6.283);
        splat(light, width, height, cx + p.x * radius, cy + p.y * radius, (0.12 + 0.45 * depth) * twinkle, depth);
    }

    // Drifting halo: a thin scatter loosening off the sphere, slowly orbiting
    // the other way, each grain fading as it drifts out and respawning.
    i = 0;
    while (i < halo_count) : (i += 1) {
        const key = hash(@intCast(i), 11, 0, seed);
        const life = @mod(time * (0.06 + 0.08 * unit(key >> 8)) + unit(key), 1.0);
        const dir = randomDirection(key >> 4);
        const r = 1.02 + 0.5 * life;
        const p = Rotation.init(-spin * 0.6 + life * 0.8, tilt).apply(dir.scale(r));
        const depth = (p.z + 1.0) * 0.5;
        const fade = (1.0 - life) * (1.0 - life);
        splat(light, width, height, cx + p.x * radius, cy + p.y * radius, 0.7 * fade * (0.4 + 0.6 * depth), depth);
    }

    // Bloom: the accumulated light, blurred once, glows around the sharp
    // particles; both are added over the backdrop.
    const glow = scratch[rgb.len .. rgb.len * 2];
    @memcpy(glow, light);
    boxBlur(glow, rgb, width, height, 3); // rgb is scratch space here; it is rewritten below
    @memcpy(rgb, background);
    var px: usize = 0;
    while (px < rgb.len) : (px += 3) {
        const l: f32 = @as(f32, @floatFromInt(light[px + 2])) / 255.0; // stored as intensity in blue channel
        const g: f32 = @as(f32, @floatFromInt(glow[px + 2])) / 255.0;
        const warm: f32 = @as(f32, @floatFromInt(light[px])) / 255.0; // arcs and near-white cores
        const v = @min(1.0, l + g * 1.6);
        if (v <= 0.002) continue;
        // deep blue -> electric blue -> cyan-white as intensity rises
        const r_add = 30.0 * v + 225.0 * v * v * v + 140.0 * warm;
        const g_add = 110.0 * v + 145.0 * v * v + 70.0 * warm;
        const b_add = 255.0 * v;
        rgb[px] = channel(@as(f32, @floatFromInt(rgb[px])) + r_add);
        rgb[px + 1] = channel(@as(f32, @floatFromInt(rgb[px + 1])) + g_add);
        rgb[px + 2] = channel(@as(f32, @floatFromInt(rgb[px + 2])) + b_add);
    }
}

const shell_count = 3200;
const core_count = 700;
const halo_count = 420;
const golden_angle: f32 = 2.39996323;

const Vec = struct {
    x: f32,
    y: f32,
    z: f32,
    fn scale(v: Vec, s: f32) Vec {
        return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
    }
};

const Rotation = struct {
    cs: f32,
    ss: f32,
    ct: f32,
    st: f32,
    fn init(spin: f32, tilt: f32) Rotation {
        return .{ .cs = @cos(spin), .ss = @sin(spin), .ct = @cos(tilt), .st = @sin(tilt) };
    }
    /// Spin about Y, then tilt about X. z > 0 faces the viewer.
    fn apply(r: Rotation, v: Vec) Vec {
        const x1 = v.x * r.cs + v.z * r.ss;
        const z1 = -v.x * r.ss + v.z * r.cs;
        return .{ .x = x1, .y = v.y * r.ct - z1 * r.st, .z = v.y * r.st + z1 * r.ct };
    }
};

fn fibonacciDirection(i: usize, n: usize) Vec {
    const fi: f32 = @floatFromInt(i);
    const y = 1.0 - (fi + 0.5) * 2.0 / @as(f32, @floatFromInt(n));
    const r = @sqrt(@max(0.0, 1.0 - y * y));
    const theta = fi * golden_angle;
    return .{ .x = @cos(theta) * r, .y = y, .z = @sin(theta) * r };
}

/// Uniform random unit vector from hash bits.
fn randomDirection(bits: u64) Vec {
    const z = 2.0 * unit(bits) - 1.0;
    const phi = unit(bits >> 16) * 6.2831853;
    const r = @sqrt(@max(0.0, 1.0 - z * z));
    return .{ .x = @cos(phi) * r, .y = z, .z = @sin(phi) * r };
}

/// Low-frequency relief on the unit sphere, in radius units (about ±0.03):
/// three crossed sine bands, so it reads as continents and ridges rather
/// than noise. Body-fixed, with a very slow drift.
fn relief(dir: Vec, time: f32) f32 {
    const t = time * 0.05;
    const a = @sin(3.1 * dir.x + 1.7 * dir.y + t) * @sin(2.3 * dir.z - 1.1 * dir.x - t * 0.7);
    const b = @sin(5.3 * dir.y + 2.9 * dir.z + 0.6 * dir.x + t * 1.3);
    return 0.022 * a + 0.011 * b;
}

fn unit(bits: u64) f32 {
    return @as(f32, @floatFromInt(bits & 0xffff)) / 65535.0;
}

/// Add one soft particle to the light buffer: a bright centre with a dim
/// cross around it. Intensity accumulates in the blue channel; `warmth`
/// (0..1, from depth) goes to red so the compositor can tint arc heads and
/// front-most cores toward white.
fn splat(light: []u8, width: u16, height: u16, fx: f32, fy: f32, intensity: f32, warmth: f32) void {
    if (fx < 1.0 or fy < 1.0 or fx >= @as(f32, @floatFromInt(width)) - 1.0 or fy >= @as(f32, @floatFromInt(height)) - 1.0) return;
    const x: usize = @intFromFloat(fx);
    const y: usize = @intFromFloat(fy);
    const w: usize = width;
    const centre = @min(1.0, intensity);
    addLight(light, (y * w + x) * 3, centre, if (intensity > 0.9) warmth * 0.5 else 0.0);
    const side = centre * 0.30;
    addLight(light, (y * w + x - 1) * 3, side, 0.0);
    addLight(light, (y * w + x + 1) * 3, side, 0.0);
    addLight(light, ((y - 1) * w + x) * 3, side, 0.0);
    addLight(light, ((y + 1) * w + x) * 3, side, 0.0);
}

fn addLight(light: []u8, i: usize, amount: f32, warm: f32) void {
    light[i + 2] = channel(@as(f32, @floatFromInt(light[i + 2])) + amount * 255.0);
    if (warm > 0.0) light[i] = channel(@as(f32, @floatFromInt(light[i])) + warm * 255.0);
}

fn hash(x: u16, y: u16, frame: u64, seed: u64) u64 {
    var value = seed ^ (@as(u64, x) *% 0x9e3779b185ebca87) ^ (@as(u64, y) *% 0xc2b2ae3d27d4eb4f) ^ (frame *% 0x165667b19e3779f9);
    value ^= value >> 30;
    value *%= 0xbf58476d1ce4e5b9;
    value ^= value >> 27;
    return value;
}

fn boxBlur(rgb: []u8, scratch: []u8, width: u16, height: u16, radius: u16) void {
    const w: usize = width;
    const h: usize = height;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const lo = x -| radius;
            const hi = @min(x + radius, w - 1);
            var sums = [3]u32{ 0, 0, 0 };
            var sx = lo;
            while (sx <= hi) : (sx += 1) {
                for (0..3) |c| sums[c] += rgb[(y * w + sx) * 3 + c];
            }
            const count: u32 = @intCast(hi - lo + 1);
            for (0..3) |c| scratch[(y * w + x) * 3 + c] = @intCast(sums[c] / count);
        }
    }
    var x: usize = 0;
    while (x < w) : (x += 1) {
        y = 0;
        while (y < h) : (y += 1) {
            const lo = y -| radius;
            const hi = @min(y + radius, h - 1);
            var sums = [3]u32{ 0, 0, 0 };
            var sy = lo;
            while (sy <= hi) : (sy += 1) {
                for (0..3) |c| sums[c] += scratch[(sy * w + x) * 3 + c];
            }
            const count: u32 = @intCast(hi - lo + 1);
            for (0..3) |c| rgb[(y * w + x) * 3 + c] = @intCast(sums[c] / count);
        }
    }
}

fn colorRgb(color: vaxis.Color, fallback: [3]u8) [3]u8 {
    return switch (color) {
        .default => fallback,
        .rgb => |rgb| rgb,
        .index => |index| indexedColor(index),
    };
}

fn indexedColor(index: u8) [3]u8 {
    if (index < 16) return ansi[index];
    if (index < 232) {
        const value = index - 16;
        const r = value / 36;
        const g = value / 6 % 6;
        const b = value % 6;
        return .{ cubeChannel(r), cubeChannel(g), cubeChannel(b) };
    }
    const gray: u8 = 8 + (index - 232) * 10;
    return .{ gray, gray, gray };
}

fn cubeChannel(value: u8) u8 {
    return if (value == 0) 0 else 55 + value * 40;
}

fn blend(rgb: []u8, width: u16, x: u16, y: u16, color: [3]u8, alpha: f32) void {
    const a = std.math.clamp(alpha, 0.0, 1.0);
    const i = (@as(usize, y) * width + x) * 3;
    for (rgb[i..][0..3], color) |*dst, src| {
        dst.* = channel(@as(f32, @floatFromInt(dst.*)) * (1.0 - a) + @as(f32, @floatFromInt(src)) * a);
    }
}

fn seconds(frame: u64) f32 {
    return @as(f32, @floatFromInt(frame)) / 60.0;
}

fn seedPhase(seed: u64) f32 {
    return @as(f32, @floatFromInt(seed % 1000)) * 0.0062831853;
}

fn smoothstep(low: f32, high: f32, value: f32) f32 {
    const t = std.math.clamp((value - low) / (high - low), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn channel(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0.0, 255.0));
}
