//! Software renderer that reproduces the original's GL pipeline on the CPU:
//! perspective projection with near-plane clipping, per-vertex distance
//! fade, nearest-neighbour texture sampling, vertex-colour modulation with
//! the PSX 2x brightness scale, normal/additive blending, a float depth
//! buffer, and back-face culling. Output is an RGBA framebuffer that the
//! Kitty transport ships as packed RGB.
//!
//! All per-frame work is allocation-free; textures are created at load time.

const std = @import("std");
const math = @import("math.zig");
const Vec2 = math.Vec2;
const Vec2i = math.Vec2i;
const Vec3 = math.Vec3;
const Vec4 = math.Vec4;
const Mat4 = math.Mat4;
const Rgba = math.Rgba;
const Tris = math.Tris;
const Vertex = math.Vertex;

pub const near_plane: f32 = 16.0;
pub const far_plane: f32 = 64000.0;
pub const fadeout_near: f32 = 48000.0;
pub const fadeout_far: f32 = 64000.0;
/// wipEout has a horizontal FOV of 90° at 4:3; fixing the vertical FOV at
/// 73.75° keeps that framing and lets wider buffers see more to the sides.
pub const fov_y: f32 = (73.75 / 180.0) * math.pi;
pub const textures_max = 1024;

pub const BlendMode = enum(u8) { normal, lighter };

pub const Texture = struct {
    width: u32,
    height: u32,
    pixels: []const Rgba,
};

pub const Stats = struct {
    tris: u32 = 0,
    /// Pixels that passed depth, alpha, and texture tests and were written.
    pixels: u32 = 0,
    /// Pixel positions visited by the rasterizer (bounding-box work).
    visited: u32 = 0,
};

pub const Error = error{TexturesExhausted} || std.mem.Allocator.Error;

const ClipVert = struct {
    pos: Vec4,
    uv: Vec2,
    color: Vec4,
};

const ScreenVert = struct {
    x: f32,
    y: f32,
    z: f32,
    q: f32,
    uv_q: Vec2,
    col_q: Vec4,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    color: []Rgba,
    depth: []f32,

    textures: [textures_max]Texture = undefined,
    textures_len: u16 = 0,
    no_texture: u16 = 0,

    projection_3d: Mat4 = Mat4.identity,
    projection_2d: Mat4 = Mat4.identity,
    view: Mat4 = Mat4.identity,
    view_projection: Mat4 = Mat4.identity,
    model: Mat4 = Mat4.identity,
    mvp: Mat4 = Mat4.identity,
    sprite_mat: Mat4 = Mat4.identity,
    camera_pos: Vec3 = Vec3.zero,
    fade_enabled: bool = true,

    depth_test: bool = true,
    depth_write: bool = true,
    depth_offset: f32 = 0,
    cull_backface: bool = true,
    blend: BlendMode = .normal,

    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) Error!Renderer {
        const pixel_count = @as(usize, width) * height;
        const color = try gpa.alloc(Rgba, pixel_count);
        errdefer gpa.free(color);
        const depth = try gpa.alloc(f32, pixel_count);
        errdefer gpa.free(depth);

        var self = Renderer{
            .gpa = gpa,
            .width = width,
            .height = height,
            .color = color,
            .depth = depth,
        };
        self.setScreenSize(width, height);
        const grey = [_]Rgba{Rgba.white} ** 4;
        self.no_texture = try self.createTexture(2, 2, &grey);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        var i: usize = 0;
        while (i < self.textures_len) : (i += 1) self.gpa.free(self.textures[i].pixels);
        self.gpa.free(self.color);
        self.gpa.free(self.depth);
    }

    fn setScreenSize(self: *Renderer, width: u32, height: u32) void {
        const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        self.projection_3d = Mat4.perspective(fov_y, aspect, near_plane, far_plane);
        self.projection_2d = Mat4.ortho2d(@floatFromInt(width), @floatFromInt(height));
    }

    // -- textures ------------------------------------------------------------

    pub fn createTexture(self: *Renderer, width: u32, height: u32, pixels: []const Rgba) Error!u16 {
        if (self.textures_len >= textures_max) return error.TexturesExhausted;
        const copy = try self.gpa.dupe(Rgba, pixels[0 .. @as(usize, width) * height]);
        const index = self.textures_len;
        self.textures[index] = .{ .width = width, .height = height, .pixels = copy };
        self.textures_len += 1;
        return index;
    }

    pub fn textureSize(self: *const Renderer, index: u16) Vec2i {
        const t = self.textures[index];
        return Vec2i.init(@intCast(t.width), @intCast(t.height));
    }

    pub fn texturesLen(self: *const Renderer) u16 {
        return self.textures_len;
    }

    // -- frame state ---------------------------------------------------------

    pub fn framePrepare(self: *Renderer) void {
        @memset(self.color, Rgba.init(0, 0, 0, 255));
        @memset(self.depth, 1.0);
        self.stats = .{};
    }

    pub fn setView(self: *Renderer, pos: Vec3, angles: Vec3) void {
        self.depth_write = true;
        self.depth_test = true;
        self.fade_enabled = true;
        self.camera_pos = pos;

        self.view = Mat4.identity;
        self.view.setRollPitchYaw(Vec3.init(angles.x, -angles.y + math.pi, angles.z + math.pi));
        self.view.translate(pos.neg());
        self.sprite_mat = Mat4.identity;
        self.sprite_mat.setYawPitchRoll(Vec3.init(-angles.x, angles.y - math.pi, 0));

        self.view_projection = self.projection_3d.mul(&self.view);
        self.setModelMat(&Mat4.identity);
    }

    pub fn setView2d(self: *Renderer) void {
        self.depth_test = false;
        self.depth_write = false;
        self.fade_enabled = false;
        self.view = Mat4.identity;
        self.view_projection = self.projection_2d;
        self.setModelMat(&Mat4.identity);
    }

    pub fn setModelMat(self: *Renderer, m: *const Mat4) void {
        self.model = m.*;
        self.mvp = self.view_projection.mul(&self.model);
    }

    pub fn setDepthWrite(self: *Renderer, enabled: bool) void {
        self.depth_write = enabled;
    }
    pub fn setDepthTest(self: *Renderer, enabled: bool) void {
        self.depth_test = enabled;
    }
    pub fn setDepthOffset(self: *Renderer, offset: f32) void {
        self.depth_offset = offset;
    }
    pub fn setBlendMode(self: *Renderer, mode: BlendMode) void {
        self.blend = mode;
    }
    pub fn setCullBackface(self: *Renderer, enabled: bool) void {
        self.cull_backface = enabled;
    }

    /// World position to NDC, as the HUD uses for target reticles.
    pub fn transform(self: *const Renderer, pos: Vec3) Vec3 {
        return pos.transform(&self.view).transformPerspective(&self.projection_3d).perspectiveDivide();
    }

    // -- geometry submission -------------------------------------------------

    fn vertexColor(self: *const Renderer, v: Vertex) Vec4 {
        var alpha = @as(f32, @floatFromInt(v.color.a)) / 255.0;
        if (self.fade_enabled) {
            const world = v.pos.transform(&self.model);
            const dist = world.sub(self.camera_pos).len();
            alpha *= math.smoothstep(fadeout_far, fadeout_near, dist);
        }
        return Vec4.init(
            @as(f32, @floatFromInt(v.color.r)) / 255.0,
            @as(f32, @floatFromInt(v.color.g)) / 255.0,
            @as(f32, @floatFromInt(v.color.b)) / 255.0,
            alpha,
        );
    }

    pub fn pushTris(self: *Renderer, tris: Tris, texture_index: u16) void {
        const texture = &self.textures[texture_index];
        var in: [3]ClipVert = undefined;
        for (tris.vertices, 0..) |v, i| {
            in[i] = .{
                .pos = v.pos.transformPerspective(&self.mvp),
                .uv = v.uv,
                .color = self.vertexColor(v),
            };
        }

        var clipped: [8]ClipVert = undefined;
        const n = clipNear(&in, &clipped);
        if (n < 3) return;

        var screen: [8]ScreenVert = undefined;
        const hw = @as(f32, @floatFromInt(self.width)) * 0.5;
        const hh = @as(f32, @floatFromInt(self.height)) * 0.5;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = clipped[i];
            const q = 1.0 / c.pos.w;
            screen[i] = .{
                .x = c.pos.x * q * hw + hw,
                .y = hh - c.pos.y * q * hh,
                .z = c.pos.z * q,
                .q = q,
                .uv_q = c.uv.scale(q),
                .col_q = c.color.scale(q),
            };
        }

        i = 1;
        while (i + 1 < n) : (i += 1) {
            self.rasterize(screen[0], screen[i], screen[i + 1], texture);
        }
    }

    pub fn pushSprite(self: *Renderer, pos: Vec3, size: Vec2i, color: Rgba, texture_index: u16) void {
        const w = @as(f32, @floatFromInt(size.x)) * 0.5;
        const h = @as(f32, @floatFromInt(size.y)) * 0.5;
        const p0 = pos.add(Vec3.init(-w, -h, 0).transform(&self.sprite_mat));
        const p1 = pos.add(Vec3.init(w, -h, 0).transform(&self.sprite_mat));
        const p2 = pos.add(Vec3.init(-w, h, 0).transform(&self.sprite_mat));
        const p3 = pos.add(Vec3.init(w, h, 0).transform(&self.sprite_mat));
        const t = self.textures[texture_index];
        const tw: f32 = @floatFromInt(t.width);
        const th: f32 = @floatFromInt(t.height);

        self.pushTris(.{ .vertices = .{
            .{ .pos = p0, .uv = Vec2.init(0, 0), .color = color },
            .{ .pos = p1, .uv = Vec2.init(tw, 0), .color = color },
            .{ .pos = p2, .uv = Vec2.init(0, th), .color = color },
        } }, texture_index);
        self.pushTris(.{ .vertices = .{
            .{ .pos = p2, .uv = Vec2.init(0, th), .color = color },
            .{ .pos = p1, .uv = Vec2.init(tw, 0), .color = color },
            .{ .pos = p3, .uv = Vec2.init(tw, th), .color = color },
        } }, texture_index);
    }

    pub fn push2d(self: *Renderer, pos: Vec2i, size: Vec2i, color: Rgba, texture_index: u16) void {
        self.push2dTile(pos, Vec2i.init(0, 0), self.textureSize(texture_index), size, color, texture_index);
    }

    pub fn push2dTile(self: *Renderer, pos: Vec2i, uv_offset: Vec2i, uv_size: Vec2i, size: Vec2i, color: Rgba, texture_index: u16) void {
        const x0: f32 = @floatFromInt(pos.x);
        const y0: f32 = @floatFromInt(pos.y);
        const x1: f32 = @floatFromInt(pos.x + size.x);
        const y1: f32 = @floatFromInt(pos.y + size.y);
        const tu0: f32 = @floatFromInt(uv_offset.x);
        const tv0: f32 = @floatFromInt(uv_offset.y);
        const tu1: f32 = @floatFromInt(uv_offset.x + uv_size.x);
        const tv1: f32 = @floatFromInt(uv_offset.y + uv_size.y);

        self.pushTris(.{ .vertices = .{
            .{ .pos = Vec3.init(x0, y1, 0), .uv = Vec2.init(tu0, tv1), .color = color },
            .{ .pos = Vec3.init(x1, y0, 0), .uv = Vec2.init(tu1, tv0), .color = color },
            .{ .pos = Vec3.init(x0, y0, 0), .uv = Vec2.init(tu0, tv0), .color = color },
        } }, texture_index);
        self.pushTris(.{ .vertices = .{
            .{ .pos = Vec3.init(x1, y1, 0), .uv = Vec2.init(tu1, tv1), .color = color },
            .{ .pos = Vec3.init(x1, y0, 0), .uv = Vec2.init(tu1, tv0), .color = color },
            .{ .pos = Vec3.init(x0, y1, 0), .uv = Vec2.init(tu0, tv1), .color = color },
        } }, texture_index);
    }

    // -- output --------------------------------------------------------------

    /// Pack the framebuffer as tightly packed 8-bit RGB (Kitty `f=24`).
    pub fn writeRgb(self: *const Renderer, out: []u8) void {
        std.debug.assert(out.len >= self.color.len * 3);
        for (self.color, 0..) |c, i| {
            out[i * 3] = c.r;
            out[i * 3 + 1] = c.g;
            out[i * 3 + 2] = c.b;
        }
    }

    // -- rasterizer ----------------------------------------------------------

    fn rasterize(self: *Renderer, a_in: ScreenVert, b_in: ScreenVert, c_in: ScreenVert, texture: *const Texture) void {
        var a = a_in;
        var b = b_in;
        const c = c_in;

        // Signed area in screen space (y down). Clip space was CCW-front in
        // GL's y-up convention, so a front face is clockwise here.
        var area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (area == 0) return;
        if (area > 0) {
            if (self.cull_backface) return;
            std.mem.swap(ScreenVert, &a, &b);
            area = -area;
        }
        // Barycentric weights are edge / |area|; edges are positive inside
        // for this (clockwise on screen) orientation.
        const inv_area = -1.0 / area;

        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);
        const min_x_f = @max(@floor(@min(a.x, @min(b.x, c.x))), 0);
        const max_x_f = @min(@ceil(@max(a.x, @max(b.x, c.x))), fw - 1);
        const min_y_f = @max(@floor(@min(a.y, @min(b.y, c.y))), 0);
        const max_y_f = @min(@ceil(@max(a.y, @max(b.y, c.y))), fh - 1);
        if (min_x_f > max_x_f or min_y_f > max_y_f) return;
        const min_x: u32 = @intFromFloat(min_x_f);
        const max_x: u32 = @intFromFloat(max_x_f);
        const min_y: u32 = @intFromFloat(min_y_f);
        const max_y: u32 = @intFromFloat(max_y_f);

        self.stats.tris += 1;
        self.stats.visited += (max_x - min_x + 1) * (max_y - min_y + 1);

        // Edge functions: e0 opposite a (edge b->c), e1 opposite b (c->a),
        // e2 opposite c (a->b). After the swap above the triangle is
        // oriented so that inside means all three are >= 0.
        const e0_dx = c.y - b.y;
        const e0_dy = -(c.x - b.x);
        const e1_dx = a.y - c.y;
        const e1_dy = -(a.x - c.x);
        const e2_dx = b.y - a.y;
        const e2_dy = -(b.x - a.x);

        const px0 = min_x_f + 0.5;
        const py0 = min_y_f + 0.5;
        var e0_row = (px0 - b.x) * e0_dx + (py0 - b.y) * e0_dy;
        var e1_row = (px0 - c.x) * e1_dx + (py0 - c.y) * e1_dy;
        var e2_row = (px0 - a.x) * e2_dx + (py0 - a.y) * e2_dy;

        const depth_bias = 0.5 - (self.depth_offset / far_plane);
        const tex_w: f32 = @floatFromInt(texture.width);
        const tex_h: f32 = @floatFromInt(texture.height);

        var y = min_y;
        while (y <= max_y) : (y += 1) {
            var e0 = e0_row;
            var e1 = e1_row;
            var e2 = e2_row;
            var x = min_x;
            while (x <= max_x) : (x += 1) {
                if (e0 >= 0 and e1 >= 0 and e2 >= 0) {
                    const l0 = e0 * inv_area;
                    const l1 = e1 * inv_area;
                    const l2 = e2 * inv_area;
                    self.shade(x, y, a, b, c, l0, l1, l2, depth_bias, texture, tex_w, tex_h);
                }
                e0 += e0_dx;
                e1 += e1_dx;
                e2 += e2_dx;
            }
            e0_row += e0_dy;
            e1_row += e1_dy;
            e2_row += e2_dy;
        }
    }

    inline fn shade(
        self: *Renderer,
        x: u32,
        y: u32,
        a: ScreenVert,
        b: ScreenVert,
        c: ScreenVert,
        l0: f32,
        l1: f32,
        l2: f32,
        depth_bias: f32,
        texture: *const Texture,
        tex_w: f32,
        tex_h: f32,
    ) void {
        const index = @as(usize, y) * self.width + x;
        const z = a.z * l0 + b.z * l1 + c.z * l2;
        const depth = math.clamp01(z * 0.5 + depth_bias);
        if (self.depth_test and depth >= self.depth[index]) return;

        const q = a.q * l0 + b.q * l1 + c.q * l2;
        if (q <= 1e-9) return;
        const iq = 1.0 / q;

        const u = (a.uv_q.x * l0 + b.uv_q.x * l1 + c.uv_q.x * l2) * iq;
        const v = (a.uv_q.y * l0 + b.uv_q.y * l1 + c.uv_q.y * l2) * iq;
        const tx: u32 = @intFromFloat(std.math.clamp(@floor(u), 0, tex_w - 1));
        const ty: u32 = @intFromFloat(std.math.clamp(@floor(v), 0, tex_h - 1));
        const texel = texture.pixels[@as(usize, ty) * texture.width + tx];
        if (texel.a == 0) return;

        const ca = (a.col_q.w * l0 + b.col_q.w * l1 + c.col_q.w * l2) * iq;
        const alpha = @as(f32, @floatFromInt(texel.a)) / 255.0 * ca;
        if (alpha <= 0) return;

        const cr = (a.col_q.x * l0 + b.col_q.x * l1 + c.col_q.x * l2) * iq;
        const cg = (a.col_q.y * l0 + b.col_q.y * l1 + c.col_q.y * l2) * iq;
        const cb = (a.col_q.z * l0 + b.col_q.z * l1 + c.col_q.z * l2) * iq;
        // Texture × vertex colour × 2 (PSX colours treat 128 as full bright).
        const sr = @min(@as(f32, @floatFromInt(texel.r)) / 255.0 * cr * 2.0, 1.0);
        const sg = @min(@as(f32, @floatFromInt(texel.g)) / 255.0 * cg * 2.0, 1.0);
        const sb = @min(@as(f32, @floatFromInt(texel.b)) / 255.0 * cb * 2.0, 1.0);

        const dst = self.color[index];
        const dr = @as(f32, @floatFromInt(dst.r)) / 255.0;
        const dg = @as(f32, @floatFromInt(dst.g)) / 255.0;
        const db = @as(f32, @floatFromInt(dst.b)) / 255.0;
        var out_r: f32 = undefined;
        var out_g: f32 = undefined;
        var out_b: f32 = undefined;
        switch (self.blend) {
            .normal => {
                out_r = sr * alpha + dr * (1.0 - alpha);
                out_g = sg * alpha + dg * (1.0 - alpha);
                out_b = sb * alpha + db * (1.0 - alpha);
            },
            .lighter => {
                out_r = @min(dr + sr * alpha, 1.0);
                out_g = @min(dg + sg * alpha, 1.0);
                out_b = @min(db + sb * alpha, 1.0);
            },
        }
        self.color[index] = Rgba.init(
            @intFromFloat(out_r * 255.0 + 0.5),
            @intFromFloat(out_g * 255.0 + 0.5),
            @intFromFloat(out_b * 255.0 + 0.5),
            255,
        );
        if (self.depth_write) self.depth[index] = depth;
        self.stats.pixels += 1;
    }
};

/// Sutherland–Hodgman against the near plane (z >= -w). Returns the vertex
/// count written to `out`, which needs room for in.len + 1 vertices.
fn clipNear(in: []const ClipVert, out: []ClipVert) usize {
    if (in.len < 3) return 0;
    var out_len: usize = 0;
    var prev = in[in.len - 1];
    var prev_in = prev.pos.z >= -prev.pos.w;
    for (in) |curr| {
        const curr_in = curr.pos.z >= -curr.pos.w;
        if (prev_in != curr_in) {
            const a = prev.pos.z + prev.pos.w;
            const b = curr.pos.z + curr.pos.w;
            const t = a / (a - b);
            out[out_len] = .{
                .pos = prev.pos.lerp(curr.pos, t),
                .uv = prev.uv.lerp(curr.uv, t),
                .color = prev.color.lerp(curr.color, t),
            };
            out_len += 1;
        }
        if (curr_in) {
            out[out_len] = curr;
            out_len += 1;
        }
        prev = curr;
        prev_in = curr_in;
    }
    return out_len;
}

test "2d quad fills its rectangle" {
    var r = try Renderer.init(std.testing.allocator, 32, 32);
    defer r.deinit();
    r.framePrepare();
    r.setView2d();
    r.setCullBackface(false);
    r.push2d(Vec2i.init(8, 8), Vec2i.init(16, 16), Rgba.white, r.no_texture);
    // Texture 128 grey × vertex 128 × 2 → 128/255 * 128/255 * 2 ≈ 0.504 → 129.
    try std.testing.expect(r.color[16 * 32 + 16].r > 100);
    try std.testing.expectEqual(@as(u8, 0), r.color[2 * 32 + 2].r);
    try std.testing.expectEqual(@as(u8, 0), r.color[30 * 32 + 30].r);
}

test "near clipping keeps a triangle straddling the camera" {
    var r = try Renderer.init(std.testing.allocator, 64, 48);
    defer r.deinit();
    r.framePrepare();
    r.setView(Vec3.zero, Vec3.zero);
    r.setCullBackface(false);
    // The camera looks down -z in view space after the pi yaw; place a big
    // floor quad that starts behind the camera and extends far ahead.
    r.pushTris(.{ .vertices = .{
        .{ .pos = Vec3.init(-2000, 200, -500), .uv = Vec2.init(0, 0), .color = Rgba.white },
        .{ .pos = Vec3.init(2000, 200, -500), .uv = Vec2.init(0, 0), .color = Rgba.white },
        .{ .pos = Vec3.init(0, 200, 8000), .uv = Vec2.init(0, 0), .color = Rgba.white },
    } }, r.no_texture);
    try std.testing.expect(r.stats.pixels > 0);
}
