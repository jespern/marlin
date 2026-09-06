//! Vector, matrix, and colour primitives for the wipEout port.
//!
//! Conventions follow the original PSX data: +y points down, angles are
//! radians, matrices are column-major 4x4 with the translation in m[12..15].
//! Everything here is plain data so game state can be snapshotted bytewise.

const std = @import("std");

pub const pi: f32 = std.math.pi;

pub const Rgba = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn init(r: u8, g: u8, b: u8, a: u8) Rgba {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// Asset colours are stored as 0xRRGGBBxx big-endian words; alpha is
    /// always opaque.
    pub fn fromU32(v: u32) Rgba {
        return .{
            .r = @truncate(v >> 24),
            .g = @truncate(v >> 16),
            .b = @truncate(v >> 8),
            .a = 255,
        };
    }

    pub const white: Rgba = .{ .r = 128, .g = 128, .b = 128, .a = 255 };
};

pub const Vec2 = extern struct {
    x: f32,
    y: f32,

    pub fn init(x: f32, y: f32) Vec2 {
        return .{ .x = x, .y = y };
    }
    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Vec2, f: f32) Vec2 {
        return .{ .x = a.x * f, .y = a.y * f };
    }
    pub fn lerp(a: Vec2, b: Vec2, t: f32) Vec2 {
        return .{ .x = a.x + t * (b.x - a.x), .y = a.y + t * (b.y - a.y) };
    }
};

pub const Vec2i = extern struct {
    x: i32,
    y: i32,

    pub fn init(x: i32, y: i32) Vec2i {
        return .{ .x = x, .y = y };
    }
};

pub const Vec3 = extern struct {
    x: f32,
    y: f32,
    z: f32,

    pub const zero: Vec3 = .{ .x = 0, .y = 0, .z = 0 };

    pub fn init(x: f32, y: f32, z: f32) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
    pub fn scale(a: Vec3, f: f32) Vec3 {
        return .{ .x = a.x * f, .y = a.y * f, .z = a.z * f };
    }
    pub fn div(a: Vec3, f: f32) Vec3 {
        return .{ .x = a.x / f, .y = a.y / f, .z = a.z / f };
    }
    pub fn neg(a: Vec3) Vec3 {
        return .{ .x = -a.x, .y = -a.y, .z = -a.z };
    }
    pub fn lenSq(a: Vec3) f32 {
        return a.x * a.x + a.y * a.y + a.z * a.z;
    }
    pub fn len(a: Vec3) f32 {
        return @sqrt(a.lenSq());
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
        return .{
            .x = a.x + t * (b.x - a.x),
            .y = a.y + t * (b.y - a.y),
            .z = a.z + t * (b.z - a.z),
        };
    }
    pub fn normalize(a: Vec3) Vec3 {
        const l = a.len();
        return .{ .x = a.x / l, .y = a.y / l, .z = a.z / l };
    }
    pub fn angleBetween(a: Vec3, b: Vec3) f32 {
        const magnitude = a.len() * b.len();
        const cosine: f32 = if (magnitude == 0) 1 else a.dot(b) / magnitude;
        return std.math.acos(std.math.clamp(cosine, -1, 1));
    }
    pub fn wrapAngles(a: Vec3) Vec3 {
        return .{ .x = wrapAngle(a.x), .y = wrapAngle(a.y), .z = wrapAngle(a.z) };
    }
    pub fn projectToRay(p: Vec3, r0: Vec3, r1: Vec3) Vec3 {
        const ray = r1.sub(r0).normalize();
        const dp = p.sub(r0).dot(ray);
        return r0.add(ray.scale(dp));
    }
    pub fn distanceToPlane(p: Vec3, plane_pos: Vec3, plane_normal: Vec3) f32 {
        return -plane_pos.sub(p).dot(plane_normal);
    }
    pub fn reflect(incidence: Vec3, normal: Vec3, f: f32) Vec3 {
        return incidence.add(normal.scale(normal.dot(incidence.scale(-1)) * f));
    }
    /// Apply the affine part of `m` (rotation + translation).
    pub fn transform(a: Vec3, m: *const Mat4) Vec3 {
        return .{
            .x = m.m[0] * a.x + m.m[4] * a.y + m.m[8] * a.z + m.m[12],
            .y = m.m[1] * a.x + m.m[5] * a.y + m.m[9] * a.z + m.m[13],
            .z = m.m[2] * a.x + m.m[6] * a.y + m.m[10] * a.z + m.m[14],
        };
    }
    /// Full homogeneous transform, keeping w for perspective division.
    pub fn transformPerspective(a: Vec3, m: *const Mat4) Vec4 {
        return .{
            .x = m.m[0] * a.x + m.m[4] * a.y + m.m[8] * a.z + m.m[12],
            .y = m.m[1] * a.x + m.m[5] * a.y + m.m[9] * a.z + m.m[13],
            .z = m.m[2] * a.x + m.m[6] * a.y + m.m[10] * a.z + m.m[14],
            .w = m.m[3] * a.x + m.m[7] * a.y + m.m[11] * a.z + m.m[15],
        };
    }
};

pub const Vec4 = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn init(x: f32, y: f32, z: f32, w: f32) Vec4 {
        return .{ .x = x, .y = y, .z = z, .w = w };
    }
    pub fn add(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z, .w = a.w + b.w };
    }
    pub fn sub(a: Vec4, b: Vec4) Vec4 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z, .w = a.w - b.w };
    }
    pub fn scale(a: Vec4, f: f32) Vec4 {
        return .{ .x = a.x * f, .y = a.y * f, .z = a.z * f, .w = a.w * f };
    }
    pub fn lerp(a: Vec4, b: Vec4, t: f32) Vec4 {
        return .{
            .x = a.x + t * (b.x - a.x),
            .y = a.y + t * (b.y - a.y),
            .z = a.z + t * (b.z - a.z),
            .w = a.w + t * (b.w - a.w),
        };
    }
    pub fn xyz(a: Vec4) Vec3 {
        return .{ .x = a.x, .y = a.y, .z = a.z };
    }
    pub fn perspectiveDivide(a: Vec4) Vec3 {
        const inv_w: f32 = if (a.w == 0) 1 else 1 / a.w;
        return a.xyz().scale(inv_w);
    }
};

/// Column-major 4x4. `m[c * 4 + r]` is row `r` of column `c`.
pub const Mat4 = extern struct {
    m: [16]f32,

    pub const identity: Mat4 = .{ .m = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    } };

    pub fn at(self: *const Mat4, col: usize, row: usize) f32 {
        return self.m[col * 4 + row];
    }
    pub fn set(self: *Mat4, col: usize, row: usize, v: f32) void {
        self.m[col * 4 + row] = v;
    }

    pub fn right(self: *const Mat4) Vec3 {
        return .{ .x = self.m[0], .y = self.m[1], .z = self.m[2] };
    }
    pub fn down(self: *const Mat4) Vec3 {
        return .{ .x = self.m[4], .y = self.m[5], .z = self.m[6] };
    }
    pub fn forward(self: *const Mat4) Vec3 {
        return .{ .x = self.m[8], .y = self.m[9], .z = self.m[10] };
    }
    pub fn translation(self: *const Mat4) Vec3 {
        return .{ .x = self.m[12], .y = self.m[13], .z = self.m[14] };
    }
    pub fn setTranslation(self: *Mat4, pos: Vec3) void {
        self.m[12] = pos.x;
        self.m[13] = pos.y;
        self.m[14] = pos.z;
    }

    /// Rotation applied as yaw (y), then pitch (x), then roll (z), matching
    /// the original's `mat4_set_yaw_pitch_roll`. Only the 3x3 block changes.
    pub fn setYawPitchRoll(self: *Mat4, rot: Vec3) void {
        const sx = @sin(rot.x);
        const sy = @sin(-rot.y);
        const sz = @sin(-rot.z);
        const cx = @cos(rot.x);
        const cy = @cos(-rot.y);
        const cz = @cos(-rot.z);

        self.set(0, 0, cy * cz + sx * sy * sz);
        self.set(1, 0, cz * sx * sy - cy * sz);
        self.set(2, 0, cx * sy);
        self.set(0, 1, cx * sz);
        self.set(1, 1, cx * cz);
        self.set(2, 1, -sx);
        self.set(0, 2, -cz * sy + cy * sx * sz);
        self.set(1, 2, cy * cz * sx + sy * sz);
        self.set(2, 2, cx * cy);
    }

    /// Inverse ordering of `setYawPitchRoll`, used for the view matrix.
    pub fn setRollPitchYaw(self: *Mat4, rot: Vec3) void {
        const sx = @sin(rot.x);
        const sy = @sin(-rot.y);
        const sz = @sin(-rot.z);
        const cx = @cos(rot.x);
        const cy = @cos(-rot.y);
        const cz = @cos(-rot.z);

        self.set(0, 0, cy * cz - sx * sy * sz);
        self.set(1, 0, -cx * sz);
        self.set(2, 0, cz * sy + cy * sx * sz);
        self.set(0, 1, cz * sx * sy + cy * sz);
        self.set(1, 1, cx * cz);
        self.set(2, 1, -cy * cz * sx + sy * sz);
        self.set(0, 2, -cx * sy);
        self.set(1, 2, sx);
        self.set(2, 2, cx * cy);
    }

    /// Post-multiply by a translation: `self = self * T(t)`.
    pub fn translate(self: *Mat4, t: Vec3) void {
        const m = &self.m;
        m[12] = m[0] * t.x + m[4] * t.y + m[8] * t.z + m[12];
        m[13] = m[1] * t.x + m[5] * t.y + m[9] * t.z + m[13];
        m[14] = m[2] * t.x + m[6] * t.y + m[10] * t.z + m[14];
        m[15] = m[3] * t.x + m[7] * t.y + m[11] * t.z + m[15];
    }

    /// `a * b` in column-major convention (apply `b` first, then `a`).
    pub fn mul(a: *const Mat4, b: *const Mat4) Mat4 {
        var r: Mat4 = undefined;
        var col: usize = 0;
        while (col < 4) : (col += 1) {
            var row: usize = 0;
            while (row < 4) : (row += 1) {
                var sum: f32 = 0;
                var k: usize = 0;
                while (k < 4) : (k += 1) sum += b.at(col, k) * a.at(k, row);
                r.set(col, row, sum);
            }
        }
        return r;
    }

    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1.0 / @tan(fov_y / 2);
        const nf = 1.0 / (near - far);
        return .{ .m = .{
            f / aspect, 0, 0,                     0,
            0,          f, 0,                     0,
            0,          0, (far + near) * nf,     -1,
            0,          0, 2.0 * far * near * nf, 0,
        } };
    }

    pub fn ortho2d(width: f32, height: f32) Mat4 {
        const near: f32 = -1;
        const far: f32 = 1;
        const lr = 1.0 / (0.0 - width);
        const bt = 1.0 / (height - 0.0);
        const nf = 1.0 / (near - far);
        return .{ .m = .{
            -2.0 * lr,  0,           0,                 0,
            0,          -2.0 * bt,   0,                 0,
            0,          0,           2.0 * nf,          0,
            width * lr, height * bt, (far + near) * nf, 1,
        } };
    }
};

pub const Vertex = extern struct {
    pos: Vec3,
    uv: Vec2,
    color: Rgba,
};

pub const Tris = extern struct {
    vertices: [3]Vertex,
};

pub fn wrapAngle(a_in: f32) f32 {
    var a = @mod(a_in + pi, pi * 2);
    if (a < 0) a += pi * 2;
    return a - pi;
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0.0, 1.0);
}

/// GLSL smoothstep, including the edge0 > edge1 ordering the fade shader
/// relies on (which GLSL leaves undefined but every GPU evaluates this way).
pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = clamp01((x - edge0) / (edge1 - edge0));
    return t * t * (3.0 - 2.0 * t);
}

test "yaw pitch roll forward matches expected basis" {
    var m = Mat4.identity;
    m.setYawPitchRoll(Vec3.init(0, 0, 0));
    const f = m.forward();
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.y, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), f.z, 1e-6);

    m.setYawPitchRoll(Vec3.init(0, pi / 2.0, 0));
    const f2 = m.forward();
    try std.testing.expectApproxEqAbs(@as(f32, -1), f2.x, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f2.z, 1e-6);
}

test "matrix multiply matches transform composition" {
    var t = Mat4.identity;
    t.setTranslation(Vec3.init(10, 20, 30));
    var r = Mat4.identity;
    r.setYawPitchRoll(Vec3.init(0.3, 0.7, 0.1));
    const tr = t.mul(&r);
    const p = Vec3.init(1, 2, 3);
    const via_mul = p.transform(&tr);
    const via_steps = p.transform(&r).transform(&t);
    try std.testing.expectApproxEqAbs(via_steps.x, via_mul.x, 1e-4);
    try std.testing.expectApproxEqAbs(via_steps.y, via_mul.y, 1e-4);
    try std.testing.expectApproxEqAbs(via_steps.z, via_mul.z, 1e-4);
}

test "smoothstep fade edges" {
    try std.testing.expectApproxEqAbs(@as(f32, 1), smoothstep(64000, 48000, 1000), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), smoothstep(64000, 48000, 70000), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), smoothstep(64000, 48000, 56000), 1e-6);
}
