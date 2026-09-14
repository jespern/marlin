//! Procedural moon-rocket launch, inspired by Artemis pad-camera views.
//! A 40-second, 30 Hz loop: countdown, ignition, ascent, fade to a new launch.
//! No assets or simulation history: resizing and skipped transport frames are safe.
const std = @import("std");
const Color = [3]u8;
const Vec = struct { x: f32, y: f32, z: f32 };
const Point = struct { x: f32, y: f32, scale: f32 };
pub const loop_frames = 40 * 30;

pub const Flight = struct {
    time: f32,
    altitude: f32,
    ignition: f32,
    fade: f32,
};
pub fn flight(frame: u64) Flight {
    const t = @as(f32, @floatFromInt(frame % loop_frames)) / 30;
    const ascent = @max(t - 10, 0);
    return .{ .time = t, .altitude = 0.32 * ascent * ascent, .ignition = std.math.clamp((t - 7) / 3, 0, 1), .fade = @min(std.math.clamp(t / 0.8, 0, 1), std.math.clamp((40 - t) / 2, 0, 1)) };
}
fn random(n: usize, seed: u64) f32 {
    var v = @as(u64, @intCast(n)) +% seed *% 0x9e3779b97f4a7c15;
    v = (v ^ (v >> 30)) *% 0xbf58476d1ce4e5b9;
    v = (v ^ (v >> 27)) *% 0x94d049bb133111eb;
    return @as(f32, @floatFromInt((v ^ (v >> 31)) & 65535)) / 65535;
}
const Canvas = struct {
    rgb: []u8,
    w: i32,
    h: i32,
    camera_y: f32,
    shake: f32,
    fn project(c: Canvas, p: Vec) Point {
        // Camera is close to the ground, looking up, and off to one side.
        const x = p.x * 0.94 - p.z * 0.342;
        const z = p.x * 0.342 + p.z * 0.94;
        const y = p.y - c.camera_y;
        const depth = @max(15, 112 - z + y * 0.24);
        const scale = @min(@as(f32, @floatFromInt(c.h)) * 1.35, @as(f32, @floatFromInt(c.w)) * 1.8) / depth;
        return .{ .x = @as(f32, @floatFromInt(c.w)) * 0.54 + x * scale + c.shake, .y = @as(f32, @floatFromInt(c.h)) * 0.78 - y * scale, .scale = scale };
    }
    fn pixel(c: Canvas, x: i32, y: i32, col: Color, alpha: f32) void {
        if (x < 0 or y < 0 or x >= c.w or y >= c.h) return;
        const i: usize = @intCast((y * c.w + x) * 3);
        const a = std.math.clamp(alpha, 0, 1);
        for (0..3) |k| c.rgb[i + k] = @intFromFloat(@as(f32, @floatFromInt(c.rgb[i + k])) * (1 - a) + @as(f32, @floatFromInt(col[k])) * a);
    }
    fn disc(c: Canvas, p: Point, radius: f32, col: Color, opacity: f32, soft: bool) void {
        const r = @max(radius, 0.5);
        const x0: i32 = @intFromFloat(@max(0, p.x - r));
        const x1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.w - 1)), p.x + r));
        const y0: i32 = @intFromFloat(@max(0, p.y - r));
        const y1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.h - 1)), p.y + r));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const dx = (@as(f32, @floatFromInt(x)) - p.x) / r;
                const dy = (@as(f32, @floatFromInt(y)) - p.y) / r;
                const d = dx * dx + dy * dy;
                if (d < 1) c.pixel(x, y, col, opacity * if (soft) (1 - d) * (1 - d) else @min(1, (1 - d) * r));
            }
        }
    }
    fn line(c: Canvas, a: Point, b: Point, col: Color, thick: f32) void {
        const steps: usize = @intFromFloat(@min(2000, @max(@abs(a.x - b.x), @abs(a.y - b.y)) + 1));
        for (0..steps + 1) |i| {
            const u = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(@max(steps, 1)));
            c.disc(.{ .x = a.x + (b.x - a.x) * u, .y = a.y + (b.y - a.y) * u, .scale = 1 }, thick, col, 1, false);
        }
    }
    fn triangle(c: Canvas, a: Point, b: Point, d: Point, col: Color) void {
        const area = edge(a, b, d.x, d.y);
        if (@abs(area) < 0.001) return;
        const x0: i32 = @intFromFloat(@max(0, @min(a.x, @min(b.x, d.x))));
        const x1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.w - 1)), @max(a.x, @max(b.x, d.x))));
        const y0: i32 = @intFromFloat(@max(0, @min(a.y, @min(b.y, d.y))));
        const y1: i32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.h - 1)), @max(a.y, @max(b.y, d.y))));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const xx = @as(f32, @floatFromInt(x)) + 0.5;
                const yy = @as(f32, @floatFromInt(y)) + 0.5;
                if (edge(a, b, xx, yy) / area >= 0 and edge(b, d, xx, yy) / area >= 0 and edge(d, a, xx, yy) / area >= 0) c.pixel(x, y, col, 1);
            }
        }
    }
    fn tube(c: Canvas, x: f32, z: f32, bottom: f32, top: f32, r0: f32, r1: f32, col: Color, ignition: f32) void {
        // Only the camera-facing half is visible. Ordered strips shade the cylinder.
        for (0..24) |i| {
            const a = -0.35 - std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 24.0;
            const b = a + std.math.pi / 24.0;
            const p0 = c.project(.{ .x = x + @sin(a) * r0, .y = bottom, .z = z + @cos(a) * r0 });
            const p1 = c.project(.{ .x = x + @sin(b) * r0, .y = bottom, .z = z + @cos(b) * r0 });
            const p2 = c.project(.{ .x = x + @sin(b) * r1, .y = top, .z = z + @cos(b) * r1 });
            const p3 = c.project(.{ .x = x + @sin(a) * r1, .y = top, .z = z + @cos(a) * r1 });
            const light = 0.27 + 0.7 * @max(0, @cos(a + 0.65));
            var shaded: Color = undefined;
            for (0..3) |k| shaded[k] = @intFromFloat(@min(255, @as(f32, @floatFromInt(col[k])) * light + ignition * @as(f32, @floatFromInt(([3]u8{ 35, 15, 3 })[k]))));
            c.triangle(p0, p1, p2, shaded);
            c.triangle(p0, p2, p3, shaded);
        }
    }
};
fn edge(a: Point, b: Point, x: f32, y: f32) f32 {
    return (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x);
}

pub fn render(rgb: []u8, width: u16, height: u16, frame: u64, seed: u64) void {
    if (width == 0 or height == 0) return;
    const f = flight(frame);
    const t = f.time;
    const lift = f.altitude;
    const c = Canvas{ .rgb = rgb, .w = width, .h = height, .camera_y = 2 + lift * 0.82, .shake = @sin(t * 47) * @sin(t * 33) * f.ignition * @exp(-@max(t - 13, 0) * 0.18) * 0.65 };
    const wf: f32 = @floatFromInt(width);
    const hf: f32 = @floatFromInt(height);
    // Midnight blue, horizon haze, subtle vignette. No random per-pixel flicker.
    for (0..height) |y| for (0..width) |x| {
        const v = @as(f32, @floatFromInt(y)) / hf;
        const u = @as(f32, @floatFromInt(x)) / wf - 0.5;
        const glow = @exp(-u * u * 8) * v * v;
        const i = (y * width + x) * 3;
        rgb[i] = @intFromFloat(3 + glow * 9);
        rgb[i + 1] = @intFromFloat(7 + glow * 16);
        rgb[i + 2] = @intFromFloat(17 + glow * 23);
    };
    for (0..95) |i| {
        const p = Point{ .x = random(i * 3, seed) * wf, .y = random(i * 3 + 1, seed) * hf * 0.8 + lift * 0.12, .scale = 1 };
        c.disc(p, 0.55 + random(i * 3 + 2, seed) * 0.55, .{ 176, 204, 231 }, 0.3 + random(i + 777, seed) * 0.5, false);
    }
    // Distant horizon and floodlights.
    for (0..38) |i| {
        const x = (@as(f32, @floatFromInt(i)) - 19) * 8;
        const p = c.project(.{ .x = x, .y = -1, .z = -35 });
        c.disc(p, 3, .{ 65, 118, 161 }, 0.5, true);
        c.disc(p, 0.6, .{ 183, 213, 224 }, 1, false);
    }
    // Lattice service tower, seen from beneath and behind the vehicle.
    for (0..10) |level| {
        const y = @as(f32, @floatFromInt(level)) * 6;
        const a = c.project(.{ .x = -18, .y = y, .z = -7 });
        const b = c.project(.{ .x = -10, .y = y, .z = -7 });
        const d = c.project(.{ .x = -18, .y = y + 6, .z = -7 });
        const e = c.project(.{ .x = -10, .y = y + 6, .z = -7 });
        c.line(a, d, .{ 64, 77, 89 }, 1.1);
        c.line(b, e, .{ 43, 56, 71 }, 1.1);
        c.line(a, e, .{ 44, 59, 75 }, 0.6);
        c.line(b, d, .{ 34, 45, 61 }, 0.6);
        c.line(a, b, .{ 76, 86, 94 }, 1);
        if (level % 2 == 0) c.disc(a, 2, .{ 251, 70, 38 }, 0.8, true);
        if (level == 7 or level == 9) c.line(b, c.project(.{ .x = -5 - @min(@max(t - 6, 0), 4), .y = y, .z = 0 }), .{ 103, 114, 122 }, 1.5);
    }
    // The pad catches the engine light.
    const pad = c.project(.{ .x = 0, .y = 0, .z = 0 });
    c.line(c.project(.{ .x = -25, .y = 0, .z = 0 }), c.project(.{ .x = 25, .y = 0, .z = 0 }), .{ 69, 77, 83 }, 3);
    c.disc(pad, hf * 0.42, .{ 246, 99, 23 }, f.ignition * 0.5 * @exp(-lift / 90), true);
    // Ground-hugging turbulent smoke rolls out in two directions.
    if (t > 6) for (0..100) |i| {
        const birth = 6 + random(i * 5, seed) * 10;
        const age = t - birth;
        if (age < 0 or age > 22) continue;
        const side: f32 = if (i % 2 == 0) -1 else 1;
        const x = side * (3 + age * (2 + random(i * 5 + 1, seed) * 3));
        const p = c.project(.{ .x = x, .y = 1 + age * 0.3 + random(i * 5 + 2, seed) * 3, .z = -8 + random(i * 5 + 3, seed) * 15 });
        const warm = f.ignition * @exp(-age * 0.09);
        const col = Color{ @intFromFloat(57 + warm * 138), @intFromFloat(66 + warm * 75), @intFromFloat(81 + warm * 12) };
        const radius = (2 + age * 0.85) * p.scale;
        const opacity = @min(age, 1) * @min((22 - age) / 4, 1);
        c.disc(p, radius, col, opacity * 0.6, true);
        // Overlapping, shaded lobes give the cloud an illuminated billowing rim.
        for (0..4) |lobe| {
            const angle = random(i * 19 + lobe, seed) * 6.28;
            const center = Point{ .x = p.x + @cos(angle) * radius * 0.45, .y = p.y + @sin(angle) * radius * 0.30, .scale = 1 };
            c.disc(center, radius * 0.57, col, opacity * 0.32, false);
            c.disc(.{ .x = center.x - radius * 0.13, .y = center.y - radius * 0.16, .scale = 1 }, radius * 0.43, .{ @intFromFloat(90 + warm * 125), @intFromFloat(95 + warm * 75), @intFromFloat(107 + warm * 12) }, opacity * 0.3, true);
        }
    };
    // Exhaust: thick, sustained incandescent columns with turbulent edges.
    if (f.ignition > 0) {
        for (0..3) |layer| {
            for (0..3) |engine| {
                const x = (@as(f32, @floatFromInt(engine)) - 1) * 6.4;
                const origin = c.project(.{ .x = x, .y = lift + 2, .z = 1 });
                if (layer == 0) c.disc(origin, hf * 0.20, .{ 255, 111, 20 }, f.ignition * 0.7, true);
                var j: usize = 72;
                while (j > 0) {
                    j -= 1;
                    const d = @as(f32, @floatFromInt(j)) / 72;
                    const pulse = 0.96 + 0.04 * @sin(t * 35 + d * 31 + @as(f32, @floatFromInt(engine)));
                    const length = (24 + @min(lift, 45)) * f.ignition;
                    const p = c.project(.{ .x = x + @sin(d * 24 - t * 13) * d * 0.35, .y = lift + 2 - d * length, .z = 2 });
                    const end_fade = 1 - std.math.clamp((d - 0.88) / 0.12, 0, 1);
                    const radius = (if (engine == 1) @as(f32, 4.0) else @as(f32, 3.0)) * p.scale * pulse * f.ignition;
                    if (layer == 0) c.disc(p, radius * 2.3, .{ 255, 89, 12 }, end_fade * 0.48, true);
                    if (layer == 1) c.disc(p, radius, .{ 255, @intFromFloat(238 - d * 127), @intFromFloat(183 - d * 171) }, end_fade * 0.95, true);
                    if (layer == 2) c.disc(p, radius * 0.72, .{ 255, 250, 213 }, end_fade * 0.96, true);
                }
            }
        }
    }
    // Orange core, white solid boosters with segment rings, upper stage and Orion.
    c.tube(0, 0, lift + 3, lift + 47, 4.1, 4.1, .{ 202, 106, 48 }, f.ignition);
    c.tube(0, 0, lift + 47, lift + 51, 4.1, 2.7, .{ 222, 218, 195 }, f.ignition);
    c.tube(0, 0, lift + 51, lift + 61, 2.7, 2.7, .{ 231, 237, 235 }, f.ignition);
    c.tube(0, 0, lift + 61, lift + 65, 2.7, 0.6, .{ 215, 226, 232 }, f.ignition);
    c.tube(0, 0, lift + 65, lift + 71, 0.38, 0.12, .{ 221, 229, 232 }, f.ignition);
    for ([_]f32{ -6.4, 6.4 }) |x| {
        c.tube(x, 1.8, lift + 2, lift + 37, 1.85, 1.85, .{ 219, 227, 229 }, f.ignition);
        c.tube(x, 1.8, lift + 37, lift + 42, 1.85, 0.1, .{ 229, 235, 237 }, f.ignition);
        c.tube(x, 1.8, lift + 1, lift + 3, 2.1, 1.85, .{ 59, 67, 78 }, f.ignition);
        for (0..5) |ring| {
            const y = lift + 7 + @as(f32, @floatFromInt(ring)) * 6;
            c.tube(x, 1.8, y, y + 0.5, 1.91, 1.91, .{ 88, 101, 110 }, f.ignition);
        }
    }
    // Countdown / mission clock: small, crisp flight-control typography.
    const scale: i32 = @max(1, @divTrunc(c.h, 180));
    text(c, 14, 14, "ARTEMIS / MOONBOUND", scale, .{ 169, 205, 225 });
    var buf: [32]u8 = undefined;
    const seconds: u32 = @intFromFloat(if (t < 10) @ceil(10 - t) else @floor(t - 10));
    const clock = std.fmt.bufPrint(&buf, "T{s}00:{d:0>2}", .{ if (t < 10) "-" else "+", seconds }) catch "";
    text(c, 14, 14 + 9 * scale, clock, scale * 2, .{ 255, 212, 145 });
    text(c, 14, c.h - 13 * scale, if (t < 7) "GO FOR LAUNCH" else if (t < 10) "ENGINE IGNITION" else if (t < 15) "LIFTOFF" else "TO THE MOON", scale, .{ 174, 213, 233 });
    // Smooth fade hides the loop reset, without a flash.
    if (f.fade < 1) for (rgb) |*v| {
        v.* = @intFromFloat(@as(f32, @floatFromInt(v.*)) * f.fade);
    };
}
fn text(c: Canvas, x: i32, y: i32, str: []const u8, scale: i32, color: Color) void {
    for (str, 0..) |ch, n| {
        const bits = glyph(ch);
        for (0..5) |row| for (0..3) |col| {
            const shift: u4 = @intCast(14 - (row * 3 + col));
            if ((bits >> shift) & 1 == 0) continue;
            for (0..@intCast(scale)) |dy| for (0..@intCast(scale)) |dx| c.pixel(x + @as(i32, @intCast(n * 4 + col)) * scale + @as(i32, @intCast(dx)), y + @as(i32, @intCast(row)) * scale + @as(i32, @intCast(dy)), color, 1);
        };
    }
}
fn glyph(ch: u8) u15 {
    return switch (ch) {
        'A' => 0b010_101_111_101_101,
        'B' => 0b110_101_110_101_110,
        'C' => 0b011_100_100_100_011,
        'D' => 0b110_101_101_101_110,
        'E' => 0b111_100_110_100_111,
        'F' => 0b111_100_110_100_100,
        'G' => 0b011_100_101_101_011,
        'H' => 0b101_101_111_101_101,
        'I' => 0b111_010_010_010_111,
        'L' => 0b100_100_100_100_111,
        'M' => 0b101_111_111_101_101,
        'N' => 0b101_111_111_111_101,
        'O' => 0b010_101_101_101_010,
        'R' => 0b110_101_110_101_101,
        'S' => 0b011_100_010_001_110,
        'T' => 0b111_010_010_010_010,
        'U' => 0b101_101_101_101_111,
        '+' => 0b000_010_111_010_000,
        '-' => 0b000_000_111_000_000,
        '/' => 0b001_001_010_100_100,
        ':' => 0b000_010_000_010_000,
        '0' => 0b111_101_101_101_111,
        '1' => 0b010_110_010_010_111,
        '2' => 0b110_001_010_100_111,
        '3' => 0b110_001_010_001_110,
        '4' => 0b101_101_111_001_001,
        '5' => 0b111_100_110_001_110,
        '6' => 0b011_100_111_101_111,
        '7' => 0b111_001_010_010_010,
        '8' => 0b111_101_111_101_111,
        '9' => 0b111_101_111_001_110,
        else => 0,
    };
}
