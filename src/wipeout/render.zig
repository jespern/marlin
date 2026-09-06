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
    /// Per-pixel count of fragments that passed coverage and depth, before
    /// the alpha discard. Diagnostic only; lets a crack detector tell "no
    /// triangle here" from "triangle here but its texel was transparent".
    covered: []u8,
    /// Diagnostic: which mesh last wrote each pixel (see `draw_id`).
    owner: []u16,
    /// Diagnostic tag callers set before submitting a mesh; recorded into
    /// `owner` on every depth write.
    draw_id: u16 = 0,
    /// Diagnostic: when set, every triangle whose bounding box touches this
    /// pixel prints its edge values there and whether the pixel was accepted.
    debug_pixel: ?[2]u32 = null,
    /// Diagnostic: when set, `Object.draw` tags each primitive with
    /// 0x4000 + its index so the owner map identifies individual polygons.
    debug_prim_ids: bool = false,

    textures: [textures_max]Texture = undefined,
    textures_len: u16 = 0,
    no_texture: u16 = 0,

    projection_3d: Mat4 = Mat4.identity,
    projection_2d: Mat4 = Mat4.identity,
    view: Mat4 = Mat4.identity,
    view_projection: Mat4 = Mat4.identity,
    model: Mat4 = Mat4.identity,
    sprite_mat: Mat4 = Mat4.identity,
    camera_pos: Vec3 = Vec3.zero,
    fade_enabled: bool = true,

    depth_test: bool = true,
    depth_write: bool = true,
    depth_offset: f32 = 0,
    cull_backface: bool = true,
    blend: BlendMode = .normal,
    /// Grow every triangle outwards by this many 1/16-pixel units. Scenery
    /// and track meshes in the data abut with sub-pixel gaps rather than
    /// sharing vertices; point sampling leaves single sky-coloured pixels in
    /// those slivers, and a small dilation closes them while the depth test
    /// resolves the resulting overlap. Zero gives exact point sampling.
    edge_dilation: i64 = default_edge_dilation,

    stats: Stats = .{},

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) Error!Renderer {
        const pixel_count = @as(usize, width) * height;
        const color = try gpa.alloc(Rgba, pixel_count);
        errdefer gpa.free(color);
        const depth = try gpa.alloc(f32, pixel_count);
        errdefer gpa.free(depth);
        const covered = try gpa.alloc(u8, pixel_count);
        errdefer gpa.free(covered);
        const owner = try gpa.alloc(u16, pixel_count);
        errdefer gpa.free(owner);

        var self = Renderer{
            .gpa = gpa,
            .width = width,
            .height = height,
            .color = color,
            .depth = depth,
            .covered = covered,
            .owner = owner,
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
        self.gpa.free(self.covered);
        self.gpa.free(self.owner);
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
        @memset(self.covered, 0);
        @memset(self.owner, 0xffff);
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

    fn vertexColor(self: *const Renderer, v: Vertex, world: Vec3) Vec4 {
        var alpha = @as(f32, @floatFromInt(v.color.a)) / 255.0;
        if (self.fade_enabled) {
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
        // Transform to world space first, then apply view-projection, as the
        // original's vertex shader does. The asset data is integer-valued,
        // so a boundary vertex shared by two meshes with different model
        // matrices lands on the identical world position and therefore the
        // identical clip position in both. Folding the model matrix into a
        // combined MVP first would round differently per mesh and open
        // 1/16-pixel cracks along every seam between abutting objects.
        var in: [3]ClipVert = undefined;
        for (tris.vertices, 0..) |v, i| {
            const world = v.pos.transform(&self.model);
            in[i] = .{
                .pos = world.transformPerspective(&self.view_projection),
                .uv = v.uv,
                .color = self.vertexColor(v, world),
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

    /// Sub-pixel precision of the fixed-point edge functions (1/16 pixel).
    const subpixel_bits = 4;
    pub const default_edge_dilation: i64 = 2;
    const subpixel: f32 = 1 << subpixel_bits;
    /// Guard band: screen coordinates beyond this are clamped before the
    /// fixed-point conversion so products stay far inside i64.
    const guard_band: f32 = 1 << 20;

    fn rasterize(self: *Renderer, a_in: ScreenVert, b_in: ScreenVert, c_in: ScreenVert, texture: *const Texture) void {
        var a = a_in;
        var b = b_in;
        const c = c_in;

        // Signed area in screen space (y down). Clip space was CCW-front in
        // GL's y-up convention, so a front face is clockwise here.
        const area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
        if (area == 0) return;
        if (area > 0) {
            if (self.cull_backface) return;
            std.mem.swap(ScreenVert, &a, &b);
        }

        // Snap vertices to a fixed-point grid so that an edge shared by two
        // triangles evaluates to exactly complementary values in both, and
        // apply the top-left fill rule: pixels on a shared edge belong to
        // exactly one triangle. Together these make meshes watertight.
        const ax = toFixed(a.x);
        const ay = toFixed(a.y);
        const bx = toFixed(b.x);
        const by = toFixed(b.y);
        const cx = toFixed(c.x);
        const cy = toFixed(c.y);

        // Twice the signed area in fixed units; positive for our orientation.
        const doubled = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax);
        if (doubled >= 0) return;
        const inv_area = -1.0 / @as(f32, @floatFromInt(doubled));

        const fw: i64 = @intCast(self.width);
        const fh: i64 = @intCast(self.height);
        const grow = self.edge_dilation;
        const min_x: i64 = @max(@divFloor(@min(ax, @min(bx, cx)) - grow, 1 << subpixel_bits), 0);
        const max_x: i64 = @min(@divFloor(@max(ax, @max(bx, cx)) + grow, 1 << subpixel_bits), fw - 1);
        const min_y: i64 = @max(@divFloor(@min(ay, @min(by, cy)) - grow, 1 << subpixel_bits), 0);
        const max_y: i64 = @min(@divFloor(@max(ay, @max(by, cy)) + grow, 1 << subpixel_bits), fh - 1);
        if (min_x > max_x or min_y > max_y) return;

        self.stats.tris += 1;
        self.stats.visited += @intCast((max_x - min_x + 1) * (max_y - min_y + 1));

        // Edge functions: e0 opposite a (edge b->c), e1 opposite b (c->a),
        // e2 opposite c (a->b). Inside means all three are >= 0, with
        // non-top-left edges tightened to > 0 through a -1 bias.
        const e0_dx = cy - by;
        const e0_dy = -(cx - bx);
        const e1_dx = ay - cy;
        const e1_dy = -(ax - cx);
        const e2_dx = by - ay;
        const e2_dy = -(bx - ax);
        // Edge values are distance × edge length, so a dilation in pixels
        // becomes dilation × length in edge units.
        const dilation = self.edge_dilation;
        const bias0: i64 = (if (isTopLeft(bx, by, cx, cy)) @as(i64, 0) else -1) + dilation * edgeLength(bx, by, cx, cy);
        const bias1: i64 = (if (isTopLeft(cx, cy, ax, ay)) @as(i64, 0) else -1) + dilation * edgeLength(cx, cy, ax, ay);
        const bias2: i64 = (if (isTopLeft(ax, ay, bx, by)) @as(i64, 0) else -1) + dilation * edgeLength(ax, ay, bx, by);

        const half: i64 = 1 << (subpixel_bits - 1);
        if (self.debug_pixel) |dp| {
            const dx: i64 = dp[0];
            const dy: i64 = dp[1];
            if (dx >= min_x and dx <= max_x and dy >= min_y and dy <= max_y) {
                const sx = (dx << subpixel_bits) + half;
                const sy = (dy << subpixel_bits) + half;
                const d0 = (sx - bx) * e0_dx + (sy - by) * e0_dy;
                const d1 = (sx - cx) * e1_dx + (sy - cy) * e1_dy;
                const d2 = (sx - ax) * e2_dx + (sy - ay) * e2_dy;
                const inside = (d0 + bias0) >= 0 and (d1 + bias1) >= 0 and (d2 + bias2) >= 0;
                std.debug.print(
                    "  mesh {d}: edges {d} {d} {d} (bias {d} {d} {d}) area2 {d} inside={} verts ({d:.2},{d:.2}) ({d:.2},{d:.2}) ({d:.2},{d:.2}) z {d:.5} {d:.5} {d:.5}\n",
                    .{ self.draw_id, d0, d1, d2, bias0, bias1, bias2, -doubled, inside, a.x, a.y, b.x, b.y, c.x, c.y, a.z, b.z, c.z },
                );
            }
        }
        const px0 = (min_x << subpixel_bits) + half;
        const py0 = (min_y << subpixel_bits) + half;
        var e0_row = (px0 - bx) * e0_dx + (py0 - by) * e0_dy;
        var e1_row = (px0 - cx) * e1_dx + (py0 - cy) * e1_dy;
        var e2_row = (px0 - ax) * e2_dx + (py0 - ay) * e2_dy;
        const step = @as(i64, 1) << subpixel_bits;

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
                if ((e0 + bias0) >= 0 and (e1 + bias1) >= 0 and (e2 + bias2) >= 0) {
                    const l0 = @as(f32, @floatFromInt(e0)) * inv_area;
                    const l1 = @as(f32, @floatFromInt(e1)) * inv_area;
                    const l2 = @as(f32, @floatFromInt(e2)) * inv_area;
                    self.shade(@intCast(x), @intCast(y), a, b, c, l0, l1, l2, depth_bias, texture, tex_w, tex_h);
                }
                e0 += e0_dx * step;
                e1 += e1_dx * step;
                e2 += e2_dx * step;
            }
            e0_row += e0_dy * step;
            e1_row += e1_dy * step;
            e2_row += e2_dy * step;
        }
    }

    fn edgeLength(x0: i64, y0: i64, x1: i64, y1: i64) i64 {
        const dx: f64 = @floatFromInt(x1 - x0);
        const dy: f64 = @floatFromInt(y1 - y0);
        return @intFromFloat(@ceil(@sqrt(dx * dx + dy * dy)));
    }

    fn toFixed(v: f32) i64 {
        const clamped = std.math.clamp(v, -guard_band, guard_band);
        return @intFromFloat(@round(clamped * subpixel));
    }

    /// For our on-screen orientation the interior lies on the positive side
    /// of each edge; a "top" edge is horizontal with the interior below it
    /// and a "left" edge runs downwards with the interior to its right.
    fn isTopLeft(x0: i64, y0: i64, x1: i64, y1: i64) bool {
        const dx = x1 - x0;
        const dy = y1 - y0;
        return dy > 0 or (dy == 0 and dx < 0);
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
        if (self.debug_pixel) |dp| {
            if (dp[0] == x and dp[1] == y) std.debug.print("    shade mesh {d}: depth {d:.6} vs buffer {d:.6} -> {s}\n", .{ self.draw_id, depth, self.depth[index], if (self.depth_test and depth >= self.depth[index]) "REJECT" else "pass" });
        }
        if (self.depth_test and depth >= self.depth[index]) return;

        const q = a.q * l0 + b.q * l1 + c.q * l2;
        if (q <= 1e-9) return;
        const iq = 1.0 / q;
        if (self.depth_write) self.covered[index] +|= 1;

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
        if (self.depth_write) {
            self.depth[index] = depth;
            self.owner[index] = self.draw_id;
        }
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
