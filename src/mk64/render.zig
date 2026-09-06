//! CPU-only perspective rasterizer for the MK64 course display-list subset.
//! N64 texture addressing is distinct from the PSX renderer: UVs wrap/mirror/clamp.
const std = @import("std");
const course = @import("course.zig");
const Vec3 = course.Vec3;
pub const width = 320;
pub const height = 240;
const near: f32 = 3;
const focal: f32 = 230;
const CV = struct { pos: Vec3, u: f32, v: f32, color: [3]f32 };
const SV = struct { x: f32, y: f32, q: f32, u: f32, v: f32, color: [3]f32 };

pub const Camera = struct {
    pos: Vec3,
    yaw: f32,
    pitch: f32 = -0.12,
    pub fn project(self: Camera, p: Vec3) ?Vec3 {
        const v = self.transform(p);
        if (v.z < near) return null;
        return .{ .x = width / 2 + focal * v.x / v.z, .y = height / 2 - focal * v.y / v.z, .z = v.z };
    }
    pub fn along(path: []const course.PathPoint, progress: f32) Camera {
        const index: usize = @intFromFloat(@mod(progress, @as(f32, @floatFromInt(path.len))));
        const pos = path[index].pos;
        const target = path[(index + 8) % path.len].pos;
        const d = target.sub(pos);
        return .{ .pos = pos.add(.{ .x = 0, .y = 28, .z = 0 }), .yaw = std.math.atan2(d.x, -d.z), .pitch = std.math.atan2(d.y - 12, @sqrt(d.x * d.x + d.z * d.z)) };
    }
    pub fn transform(self: Camera, p: Vec3) Vec3 {
        const d = p.sub(self.pos);
        const sy = @sin(self.yaw);
        const cy = @cos(self.yaw);
        const forward = d.x * sy - d.z * cy;
        return .{ .x = d.x * cy + d.z * sy, .y = d.y * @cos(self.pitch) - forward * @sin(self.pitch), .z = d.y * @sin(self.pitch) + forward * @cos(self.pitch) };
    }
};

pub const Renderer = struct {
    rgb: [width * height * 3]u8 = undefined,
    depth: [width * height]f32 = undefined,
    triangles: usize = 0,
    pub fn draw(self: *Renderer, track: *const course.Course, camera: Camera) void {
        @memset(&self.depth, 0);
        self.triangles = 0;
        for (0..height) |y| for (0..width) |x| {
            const i = (y * width + x) * 3;
            self.rgb[i..][0..3].* = .{ @intCast(90 + y / 3), @intCast(155 + y / 4), 235 };
        };
        for (track.triangles) |tri| {
            var vertices: [3]CV = undefined;
            for (tri.vertices, 0..) |v, i| vertices[i] = .{ .pos = camera.transform(v.pos), .u = v.u, .v = v.v, .color = .{ @floatFromInt(v.color[0]), @floatFromInt(v.color[1]), @floatFromInt(v.color[2]) } };
            var clipped: [4]CV = undefined;
            var n: usize = 0;
            var prev = vertices[2];
            for (vertices) |v| {
                if ((prev.pos.z >= near) != (v.pos.z >= near)) {
                    const t = (near - prev.pos.z) / (v.pos.z - prev.pos.z);
                    clipped[n] = mix(prev, v, t);
                    n += 1;
                }
                if (v.pos.z >= near) {
                    clipped[n] = v;
                    n += 1;
                }
                prev = v;
            }
            if (n < 3) continue;
            for (1..n - 1) |j| self.triangle(.{ project(clipped[0]), project(clipped[j]), project(clipped[j + 1]) }, tri.style, track.textures);
        }
    }
    fn triangle(self: *Renderer, v: [3]SV, style: course.Style, textures: []const u8) void {
        const area = edge(v[0], v[1], v[2].x, v[2].y);
        if (@abs(area) < 0.001) return;
        const xmin = @max(0, @floor(@min(v[0].x, @min(v[1].x, v[2].x))));
        const xmax = @min(width - 1, @ceil(@max(v[0].x, @max(v[1].x, v[2].x))));
        const ymin = @max(0, @floor(@min(v[0].y, @min(v[1].y, v[2].y))));
        const ymax = @min(height - 1, @ceil(@max(v[0].y, @max(v[1].y, v[2].y))));
        if (xmin > xmax or ymin > ymax) return;
        self.triangles += 1;
        const x0: usize = @intFromFloat(xmin);
        const x1: usize = @intFromFloat(xmax);
        const y0: usize = @intFromFloat(ymin);
        const y1: usize = @intFromFloat(ymax);
        for (y0..y1 + 1) |y| for (x0..x1 + 1) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const a = edge(v[1], v[2], px, py) / area;
            const b = edge(v[2], v[0], px, py) / area;
            const c = 1 - a - b;
            if (a < -0.00001 or b < -0.00001 or c < -0.00001) continue;
            const q = a * v[0].q + b * v[1].q + c * v[2].q;
            const i = y * width + x;
            if (q <= self.depth[i]) continue;
            var texel: [4]u8 = .{ 255, 255, 255, 255 };
            if (style.textured) {
                const u = (a * v[0].u + b * v[1].u + c * v[2].u) / q;
                const t = (a * v[0].v + b * v[1].v + c * v[2].v) / q;
                const tx = address(u, style.width, style.cms);
                const ty = address(t, style.height, style.cmt);
                const offset = style.offset + (ty * @as(usize, style.width) + tx) * 2;
                if (offset + 2 > textures.len) continue;
                const value = std.mem.readInt(u16, textures[offset..][0..2], .big);
                texel = if (style.fmt == 3) .{ @truncate(value >> 8), @truncate(value >> 8), @truncate(value >> 8), @truncate(value) } else rgba16(value);
                if (texel[3] < 128) continue;
            }
            self.depth[i] = q;
            for (0..3) |ch| {
                const shade = if (style.decal) 255 else (a * v[0].color[ch] + b * v[1].color[ch] + c * v[2].color[ch]) / q;
                self.rgb[i * 3 + ch] = @intFromFloat(std.math.clamp(@as(f32, @floatFromInt(texel[ch])) * shade / 255, 0, 255));
            }
        };
    }
};

fn edge(a: SV, b: SV, x: f32, y: f32) f32 {
    return (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x);
}
fn project(v: CV) SV {
    const q = 1 / v.pos.z;
    return .{ .x = width / 2 + v.pos.x * focal * q, .y = height / 2 - v.pos.y * focal * q, .q = q, .u = v.u * q, .v = v.v * q, .color = .{ v.color[0] * q, v.color[1] * q, v.color[2] * q } };
}
fn mix(a: CV, b: CV, t: f32) CV {
    return .{ .pos = a.pos.add(b.pos.sub(a.pos).scale(t)), .u = a.u + (b.u - a.u) * t, .v = a.v + (b.v - a.v) * t, .color = .{ a.color[0] + (b.color[0] - a.color[0]) * t, a.color[1] + (b.color[1] - a.color[1]) * t, a.color[2] + (b.color[2] - a.color[2]) * t } };
}
fn address(value: f32, size: u16, mode: u8) usize {
    const n: f32 = @floatFromInt(size);
    if (mode & 2 != 0) return @intFromFloat(std.math.clamp(@floor(value), 0, n - 1));
    if (mode & 1 != 0) {
        const v = @mod(@floor(value), n * 2);
        return @intFromFloat(if (v >= n) n * 2 - 1 - v else v);
    }
    return @intFromFloat(@mod(@floor(value), n));
}
pub fn rgba16(value: u16) [4]u8 {
    const r: u8 = @intCast(value >> 11);
    const g: u8 = @intCast((value >> 6) & 31);
    const b: u8 = @intCast((value >> 1) & 31);
    return .{ (r << 3) | (r >> 2), (g << 3) | (g >> 2), (b << 3) | (b >> 2), if (value & 1 != 0) 255 else 0 };
}

test "N64 texture wrap mirror clamp and RGBA5551" {
    try std.testing.expectEqual(@as(usize, 31), address(-1, 32, 0));
    try std.testing.expectEqual(@as(usize, 31), address(32, 32, 1));
    try std.testing.expectEqual(@as(usize, 0), address(-1, 32, 2));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, rgba16(0xf801));
}
