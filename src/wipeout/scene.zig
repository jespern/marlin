//! Per-track scenery: the sky dome that follows the camera and the static
//! objects placed around the circuit.

const std = @import("std");
const math = @import("math.zig");
const image = @import("image.zig");
const object = @import("object.zig");
const render = @import("render.zig");
const assets_mod = @import("assets.zig");
const Vec3 = math.Vec3;

pub const Scene = struct {
    sky: []object.Object,
    objects: []object.Object,
    sky_offset: Vec3,

    pub fn deinit(self: *Scene, gpa: std.mem.Allocator) void {
        object.free(gpa, self.sky);
        object.free(gpa, self.objects);
    }

    pub fn draw(self: *Scene, r: *render.Renderer, cam_pos: Vec3, cam_dir: Vec3) void {
        r.setDepthWrite(false);
        for (self.sky) |*sky| {
            sky.mat.setTranslation(cam_pos.add(self.sky_offset));
            sky.draw(r, &sky.mat);
        }
        r.setDepthWrite(true);

        for (self.objects, 0..) |*obj, index| {
            r.draw_id = @intCast(index);
            const diff = cam_pos.sub(obj.origin);
            const cam_dot = diff.dot(cam_dir);
            const dist_sq = diff.dot(diff);
            if (cam_dot < obj.radius and dist_sq < render.fadeout_far * render.fadeout_far) {
                obj.draw(r, &obj.mat);
            }
        }
    }
};

pub fn load(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer, dir: []const u8, sky_y_offset: f32) !Scene {
    const sky = try loadModel(gpa, assets, r, dir, "sky.cmp", "sky.prm");
    errdefer object.free(gpa, sky);
    const objects = try loadModel(gpa, assets, r, dir, "scene.cmp", "scene.prm");
    errdefer object.free(gpa, objects);

    for (objects) |*obj| obj.mat.setTranslation(obj.origin);

    return .{ .sky = sky, .objects = objects, .sky_offset = Vec3.init(0, sky_y_offset, 0) };
}

/// Register every TIM in `<dir>/<cmp_name>` as a texture, then parse
/// `<dir>/<prm_name>` against that texture range.
pub fn loadModel(
    gpa: std.mem.Allocator,
    assets: *const assets_mod.Assets,
    r: *render.Renderer,
    dir: []const u8,
    cmp_name: []const u8,
    prm_name: []const u8,
) ![]object.Object {
    const textures = try loadCompressedTextures(gpa, assets, r, dir, cmp_name);
    const prm_path = try assets.path(dir, prm_name);
    defer gpa.free(prm_path);
    const prm = try assets.load(prm_path);
    defer gpa.free(prm);
    return object.load(gpa, prm, textures);
}

pub fn loadCompressedTextures(
    gpa: std.mem.Allocator,
    assets: *const assets_mod.Assets,
    r: *render.Renderer,
    dir: []const u8,
    cmp_name: []const u8,
) !object.TextureList {
    const cmp_path = try assets.path(dir, cmp_name);
    defer gpa.free(cmp_path);
    const cmp_bytes = try assets.load(cmp_path);
    defer gpa.free(cmp_bytes);
    const cmp = try image.decodeCmp(gpa, cmp_bytes);
    defer cmp.deinit(gpa);

    const list = object.TextureList{ .start = r.texturesLen(), .len = @intCast(cmp.entries.len) };
    for (cmp.entries) |entry| {
        const img = try image.decodeTim(gpa, entry, false);
        defer img.deinit(gpa);
        _ = try r.createTexture(img.width, img.height, img.pixels);
    }
    return list;
}
