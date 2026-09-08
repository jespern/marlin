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

/// A thinking orb: a globe of scattered nodes turning slowly, with pulses
/// firing along edges between neighbouring nodes now and then, like a brain
/// lighting up. Stateless: every frame is a pure function of (frame, seed),
/// so the engine can skip or replay frames freely.
pub fn render(rgb: []u8, background: []const u8, width: u16, height: u16, frame: u64, seed: u64) void {
    @memcpy(rgb, background);
    if (width == 0 or height == 0) return;

    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const radius = @min(w, h) * 0.27;
    const time = seconds(frame);
    const cx = w * 0.5 + @sin(time * 0.23 + seedPhase(seed)) * w * 0.018;
    const cy = h * 0.47 + @sin(time * 0.41 + 1.7) * h * 0.012;
    const pixel_size = pixelBlockSize(width, height);

    // Faint body: a barely-there navy disc and rim so the scatter reads as a
    // sphere, not confetti. Blocks keep the retro grid.
    var by: u16 = 0;
    while (by < height) : (by += pixel_size) {
        const yf: f32 = @floatFromInt(@min(by + pixel_size / 2, height - 1));
        var bx: u16 = 0;
        while (bx < width) : (bx += pixel_size) {
            const xf: f32 = @floatFromInt(@min(bx + pixel_size / 2, width - 1));
            const dx = (xf - cx) / radius;
            const dy = (yf - cy) / radius;
            const d2 = dx * dx + dy * dy;
            if (d2 > 1.25) continue;
            if (d2 > 1.0) {
                const glow = (1.25 - d2) / 0.25;
                blendBlock(rgb, width, height, bx, by, pixel_size, .{ 24, 90, 140 }, glow * glow * 0.10, false);
                continue;
            }
            const depth = @sqrt(1.0 - d2);
            const rim = std.math.pow(f32, 1.0 - depth, 3.0);
            blendBlock(rgb, width, height, bx, by, pixel_size, .{ 6, 18, 38 }, 0.34, true);
            blendBlock(rgb, width, height, bx, by, pixel_size, .{ 30, 110, 170 }, rim * 0.30, false);
        }
    }

    // Nodes on a Fibonacci sphere, turning about a tilted axis.
    var nodes: [node_count]Node = undefined;
    const spin = time * 0.31 + seedPhase(seed);
    const tilt: f32 = 0.42;
    const ct = @cos(tilt);
    const st = @sin(tilt);
    const cs = @cos(spin);
    const ss = @sin(spin);
    for (&nodes, 0..) |*node, i| {
        const fi: f32 = @floatFromInt(i);
        const y0 = 1.0 - (fi + 0.5) * 2.0 / @as(f32, @floatFromInt(node_count));
        const r0 = @sqrt(@max(0.0, 1.0 - y0 * y0));
        const theta = fi * golden_angle;
        const x0 = @cos(theta) * r0;
        const z0 = @sin(theta) * r0;
        // spin about Y, then tilt about X
        const x1 = x0 * cs + z0 * ss;
        const z1 = -x0 * ss + z0 * cs;
        const y2 = y0 * ct - z1 * st;
        const z2 = y0 * st + z1 * ct;
        node.* = .{
            .sx = cx + x1 * radius,
            .sy = cy + y2 * radius,
            .z = z2,
            .flash = 0,
        };
    }

    // Edges between near neighbours. Only some ever fire, and each on its own
    // slow, hashed clock, so the lines are sporadic rather than a wireframe.
    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        var j: usize = i + 1;
        while (j < node_count) : (j += 1) {
            const a = nodes[i];
            const b = nodes[j];
            const ddx = (a.sx - b.sx) / radius;
            const ddy = (a.sy - b.sy) / radius;
            const ddz = a.z - b.z;
            const chord2 = ddx * ddx + ddy * ddy + ddz * ddz;
            const key = hash(@intCast(i), @intCast(j), 0, seed);
            // Near neighbours: about one pair in six is a synapse. Distant
            // pairs: a rare long arc across the globe, an "insight".
            const long_arc = chord2 > 1.1 and chord2 < 2.6 and key % 97 == 0;
            if (!long_arc and (chord2 > 0.55 or key % 6 != 0)) continue;
            const period = 2.5 + @as(f32, @floatFromInt((key >> 8) % 700)) / 100.0 + (if (long_arc) @as(f32, 6.0) else 0.0); // 2.5..15.5 s
            const phase = @as(f32, @floatFromInt((key >> 20) % 1000)) / 1000.0 * period;
            const t = @mod(time + phase, period);
            const duration: f32 = if (long_arc) 2.2 else 1.3;
            if (t > duration) continue;
            const progress = t / duration;
            // direction alternates per firing so pulses go both ways over time
            const flip = (@as(u64, @intFromFloat((time + phase) / period)) + (key >> 40)) % 2 == 1;
            const from = if (flip) b else a;
            const to = if (flip) a else b;
            const depth = (@max(from.z, to.z) + 1.0) * 0.5; // 0 back .. 1 front
            const vis = 0.25 + 0.75 * depth;
            drawPulse(rgb, width, height, pixel_size, from, to, progress, vis);
            if (progress > 0.82) {
                const target = if (flip) &nodes[i] else &nodes[j];
                target.flash = @max(target.flash, (progress - 0.82) / 0.18);
            }
        }
    }

    // Nodes last so they sit on top of their edges. Back nodes are dim and
    // small; front nodes bright, with a soft flash when a pulse arrives.
    for (nodes, 0..) |node, k| {
        const depth = (node.z + 1.0) * 0.5;
        const twinkle = 0.85 + 0.15 * @sin(time * 1.7 + @as(f32, @floatFromInt(k)) * 0.61);
        const base_alpha = (0.18 + 0.72 * depth * depth) * twinkle;
        var color = [3]f32{ 90.0 + 60.0 * depth, 170.0 + 60.0 * depth, 230.0 + 25.0 * depth };
        if (node.flash > 0) {
            color[0] += 165.0 * node.flash;
            color[1] += 85.0 * node.flash;
            color[2] += 25.0 * node.flash;
        }
        const alpha = @min(1.0, base_alpha + node.flash * 0.6);
        const size: u16 = if (depth > 0.72 or node.flash > 0.3) pixel_size * 2 else pixel_size;
        const bx = snap(node.sx - @as(f32, @floatFromInt(size)) * 0.5, pixel_size);
        const byy = snap(node.sy - @as(f32, @floatFromInt(size)) * 0.5, pixel_size);
        if (bx >= width or byy >= height) continue;
        blendBlock(rgb, width, height, bx, byy, size, .{ channel(color[0]), channel(color[1]), channel(color[2]) }, alpha, false);
        if (node.flash > 0.2) {
            // halo one block wide around a flashing node
            const hx = bx -| pixel_size;
            const hy = byy -| pixel_size;
            blendBlock(rgb, width, height, hx, hy, size + pixel_size * 2, .{ 255, 200, 120 }, node.flash * 0.12, false);
        }
    }
}

const node_count = 168;
const golden_angle: f32 = 2.39996323;

const Node = struct { sx: f32, sy: f32, z: f32, flash: f32 };

fn snap(value: f32, pixel_size: u16) u16 {
    const v = @max(value, 0.0);
    const block: u16 = @intFromFloat(@min(v / @as(f32, @floatFromInt(pixel_size)), 60000.0));
    return block * pixel_size;
}

/// A pulse running from `from` to `to`: the whole edge faintly lit while the
/// firing lasts, a bright head at `progress` with a short fading tail behind.
fn drawPulse(rgb: []u8, width: u16, height: u16, pixel_size: u16, from: Node, to: Node, progress: f32, vis: f32) void {
    const ex = to.sx - from.sx;
    const ey = to.sy - from.sy;
    const length = @max(@sqrt(ex * ex + ey * ey), 1.0);
    const steps: usize = @intFromFloat(@min(length / @as(f32, @floatFromInt(pixel_size)) + 1.0, 400.0));
    var k: usize = 0;
    while (k <= steps) : (k += 1) {
        const f = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(@max(steps, 1)));
        const px = from.sx + ex * f;
        const py = from.sy + ey * f;
        const bx = snap(px - @as(f32, @floatFromInt(pixel_size)) * 0.5, pixel_size);
        const by = snap(py - @as(f32, @floatFromInt(pixel_size)) * 0.5, pixel_size);
        if (bx >= width or by >= height) continue;
        const behind = progress - f; // >0 means the head has passed this point
        var alpha: f32 = 0.26 * vis;
        var color = [3]u8{ 50, 150, 210 };
        if (behind >= 0.0 and behind < 0.28) {
            const tail = 1.0 - behind / 0.28;
            alpha = (0.3 + 0.7 * tail * tail) * vis;
            color = .{ channel(140.0 + 115.0 * tail), channel(210.0 + 45.0 * tail), 255 };
        }
        blendBlock(rgb, width, height, bx, by, pixel_size, color, alpha, false);
    }
}

fn pixelBlockSize(width: u16, height: u16) u16 {
    return std.math.clamp(@min(width, height) / 72, 3, 8);
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
