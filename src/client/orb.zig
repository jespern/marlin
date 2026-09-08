//! Floating orb pixel effect. The first frame rasterizes Marlin's cell grid
//! into a softened backdrop; later frames keep that snapshot still while a
//! procedural luminous sphere rotates above it.

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

pub fn render(rgb: []u8, background: []const u8, width: u16, height: u16, frame: u64, seed: u64) void {
    @memcpy(rgb, background);
    if (width == 0 or height == 0) return;

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const radius = @min(w, h) * 0.245;
    const cx = w * 0.5 + @sin(seconds(frame) * 0.23 + seedPhase(seed)) * w * 0.018;
    const cy = h * 0.47 + @sin(seconds(frame) * 0.41 + 1.7) * h * 0.012;
    const time = seconds(frame);
    const pixel_size = pixelBlockSize(width, height);

    // The sphere is sampled on a coarse virtual framebuffer. Keeping the
    // output canvas full-size preserves Kitty placement while making the
    // shading read like a late-90s software renderer.
    var y: u16 = 0;
    while (y < height) : (y += pixel_size) {
        const sample_y = y + pixel_size / 2;
        const yf: f32 = @floatFromInt(@min(sample_y, height - 1));
        var x: u16 = 0;
        while (x < width) : (x += pixel_size) {
            const sample_x = x + pixel_size / 2;
            const xf: f32 = @floatFromInt(@min(sample_x, width - 1));
            const shadow_x = (xf - cx) / (radius * 1.25);
            const shadow_y = (yf - (cy + radius * 1.16)) / (radius * 0.25);
            const shadow_d = shadow_x * shadow_x + shadow_y * shadow_y;
            if (shadow_d < 1.0)
                blendBlock(rgb, width, height, x, y, pixel_size, .{ 0, 0, 0 }, (1.0 - shadow_d) * 0.42, false);

            const dx = (xf - cx) / radius;
            const dy = (yf - cy) / radius;
            const d2 = dx * dx + dy * dy;
            if (d2 > 1.34) continue;
            if (d2 > 1.0) {
                const glow = (1.34 - d2) / 0.34;
                const glow_color = retroColor(.{ 32, 174, 214 }, sample_x, sample_y, frame, seed, pixel_size);
                blendBlock(rgb, width, height, x, y, pixel_size, glow_color, glow * glow * 0.18, true);
                continue;
            }

            const z = @sqrt(@max(1.0 - d2, 0.0));
            const angle = time * 0.52;
            const ca = @cos(angle);
            const sa = @sin(angle);
            const px = dx * ca + z * sa;
            const pz = -dx * sa + z * ca;
            const py = dy;

            const longitude = std.math.atan2(pz, px);
            const latitude = std.math.asin(std.math.clamp(py, -1.0, 1.0));
            const panel_wave = @sin(longitude * 6.0 + time * 0.38) * @sin(latitude * 7.0 - time * 0.16);
            const panel_edge = smoothstep(0.72, 0.96, @abs(panel_wave));
            const gold_band = smoothstep(0.82, 0.98, @abs(@sin(longitude * 3.0 - latitude * 5.0 + time * 0.22)));
            const reactor_seam = smoothstep(0.90, 0.995, @abs(@sin(longitude * 9.0 + latitude * 11.0 - time * 0.7)));
            const light = std.math.clamp(px * -0.28 + py * -0.46 + z * 0.96, 0.0, 1.0);
            const specular = std.math.pow(f32, std.math.clamp(px * -0.42 + py * -0.55 + z * 0.78, 0.0, 1.0), 18.0);
            const rim = std.math.pow(f32, 1.0 - z, 2.1);
            const pulse = 0.88 + 0.12 * @sin(time * 2.4 + longitude * 2.0);

            var color = [3]f32{
                50.0 + light * 105.0,
                5.0 + light * 22.0,
                8.0 + light * 18.0,
            };
            color[0] += panel_edge * 66.0 + gold_band * 105.0;
            color[1] += panel_edge * 8.0 + gold_band * 64.0;
            color[2] += panel_edge * 5.0 + gold_band * 10.0;
            color[0] += reactor_seam * 82.0 * pulse;
            color[1] += reactor_seam * 218.0 * pulse;
            color[2] += reactor_seam * 255.0 * pulse;
            color[0] += specular * 165.0 + rim * 48.0;
            color[1] += specular * 150.0 + rim * 12.0;
            color[2] += specular * 118.0 + rim * 16.0;

            const edge = smoothstep(0.0, 0.055, 1.0 - d2);
            const shaded = retroColor(.{ channel(color[0]), channel(color[1]), channel(color[2]) }, sample_x, sample_y, frame, seed, pixel_size);
            blendBlock(rgb, width, height, x, y, pixel_size, shaded, edge, true);
        }
    }
}

fn pixelBlockSize(width: u16, height: u16) u16 {
    return std.math.clamp(@min(width, height) / 72, 3, 8);
}

fn retroColor(color: [3]u8, x: u16, y: u16, frame: u64, seed: u64, pixel_size: u16) [3]u8 {
    const block_x = x / pixel_size;
    const block_y = y / pixel_size;
    const noise = hash(block_x, block_y, frame / 4, seed);
    const scanline: u16 = if (block_y % 3 == 2) 76 else 100;
    const flicker: i16 = @as(i16, @intCast(noise % 17)) - 8;
    var result: [3]u8 = undefined;
    for (color, 0..) |value, i| {
        const scaled = @as(i16, @intCast(@as(u16, value) * scanline / 100)) + flicker + @as(i16, @intCast(i)) * 2;
        result[i] = quantize(@intCast(std.math.clamp(scaled, 0, 255)));
    }
    return result;
}

fn blendBlock(rgb: []u8, width: u16, height: u16, x: u16, y: u16, size: u16, color: [3]u8, alpha: f32, grid: bool) void {
    const x_end = @min(x + size, width);
    const y_end = @min(y + size, height);
    var py = y;
    while (py < y_end) : (py += 1) {
        var px = x;
        while (px < x_end) : (px += 1) {
            blend(rgb, width, px, py, color, alpha);
            if (grid and (px + 1 == x_end or py + 1 == y_end))
                blend(rgb, width, px, py, .{ 0, 3, 5 }, 0.34);
        }
    }
}

fn hash(x: u16, y: u16, frame: u64, seed: u64) u64 {
    var value = seed ^ (@as(u64, x) *% 0x9e3779b185ebca87) ^ (@as(u64, y) *% 0xc2b2ae3d27d4eb4f) ^ (frame *% 0x165667b19e3779f9);
    value ^= value >> 30;
    value *%= 0xbf58476d1ce4e5b9;
    value ^= value >> 27;
    return value;
}

fn quantize(value: u8) u8 {
    return value / 32 * 32;
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
