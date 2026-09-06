//! Track geometry: the TRV/TRF/TRS trio plus the TTF tile map that assembles
//! 128×128 track textures from 32×32 library tiles.
//!
//! Sections link by index rather than pointer so the whole track, and any
//! runtime state referring to it, can be snapshotted bytewise.

const std = @import("std");
const bytes = @import("bytes.zig");
const image = @import("image.zig");
const math = @import("math.zig");
const render = @import("render.zig");
const assets_mod = @import("assets.zig");
const Vec2 = math.Vec2;
const Vec3 = math.Vec3;
const Rgba = math.Rgba;
const Tris = math.Tris;

pub const track_version: i16 = 8;
pub const section_cull_behind: f32 = 6144;
pub const search_look_back = 3;
pub const search_look_ahead = 6;
pub const none: i32 = -1;

pub const FaceFlags = struct {
    pub const track_base: u8 = 1 << 0;
    pub const pickup_left: u8 = 1 << 1;
    pub const flip_texture: u8 = 1 << 2;
    pub const pickup_right: u8 = 1 << 3;
    pub const start_grid: u8 = 1 << 4;
    pub const boost: u8 = 1 << 5;
    pub const pickup_collected: u8 = 1 << 6;
    pub const pickup_active: u8 = 1 << 7;
};

pub const SectionFlags = struct {
    pub const jump: i16 = 1;
    pub const junction_end: i16 = 8;
    pub const junction_start: i16 = 16;
    pub const junction: i16 = 32;
};

pub const Face = struct {
    tris: [2]Tris,
    normal: Vec3,
    flags: u8,
    texture: u8,

    pub fn setColor(self: *Face, color: Rgba) void {
        for (&self.tris) |*t| {
            for (&t.vertices) |*v| v.color = color;
        }
    }
};

pub const Section = struct {
    /// Index of the junction branch starting here, or `none`.
    junction: i32,
    prev: u32,
    next: u32,
    center: Vec3,
    face_start: u16,
    face_count: u16,
    flags: i16,
    num: i16,
};

pub const Error = error{
    BadTrackVersion,
    BadTileIndex,
    BadVertexIndex,
    BadSectionIndex,
    CorruptTrack,
} || bytes.Error || image.Error || render.Error || std.mem.Allocator.Error;

pub const Track = struct {
    faces: []Face,
    sections: []Section,
    texture_start: u16,
    texture_len: u16,
    total_section_nums: i32,

    pub fn deinit(self: *Track, gpa: std.mem.Allocator) void {
        gpa.free(self.faces);
        gpa.free(self.sections);
    }

    pub fn textureIndex(self: *const Track, face: *const Face) u16 {
        const local: u16 = @min(face.texture, self.texture_len -| 1);
        return self.texture_start + local;
    }

    /// Index of the first face flagged as track base in `section`.
    pub fn baseFaceIndex(self: *const Track, section: *const Section) usize {
        var i: usize = section.face_start;
        while (i + 1 < self.faces.len and (self.faces[i].flags & FaceFlags.track_base) == 0) i += 1;
        return i;
    }

    /// The original's nearest-section search: look a few sections back and
    /// several ahead from `start`, plus down any junction branch found on
    /// the way. `bias` scales the difference per axis before measuring.
    pub fn nearestSection(self: *const Track, pos: Vec3, bias: Vec3, start: u32, distance_out: ?*f32) u32 {
        const sections = self.sections;
        var section = start;
        var i: usize = 0;
        while (i < search_look_back) : (i += 1) section = sections[section].prev;

        var shortest: f32 = 1_000_000_000.0;
        var nearest = section;
        var junction: i32 = none;
        i = 0;
        while (i < search_look_ahead) : (i += 1) {
            if (sections[section].junction != none) junction = sections[section].junction;
            const d = pos.sub(sections[section].center).mul(bias).len();
            if (d < shortest) {
                shortest = d;
                nearest = section;
            }
            section = sections[section].next;
        }

        if (junction != none) {
            const junction_index: u32 = @intCast(junction);
            section = junction_index;
            i = 0;
            while (i < search_look_ahead) : (i += 1) {
                const d = pos.sub(sections[section].center).mul(bias).len();
                if (d < shortest) {
                    shortest = d;
                    nearest = section;
                }
                if ((sections[junction_index].flags & SectionFlags.junction_start) != 0) {
                    section = sections[section].next;
                } else {
                    section = sections[section].prev;
                }
            }
        }

        if (distance_out) |out| out.* = shortest;
        return nearest;
    }

    pub fn baseFace(self: *const Track, section: *const Section) *Face {
        var i: usize = section.face_start;
        while (i + 1 < self.faces.len and (self.faces[i].flags & FaceFlags.track_base) == 0) i += 1;
        return &self.faces[i];
    }

    /// Draw every section in front of the camera and within fade distance.
    /// Diagnostic owner tag used for every track face.
    pub const draw_id: u16 = 0xfffe;

    pub fn draw(self: *const Track, r: *render.Renderer, cam_pos: Vec3, cam_dir: Vec3) void {
        r.setModelMat(&math.Mat4.identity);
        r.draw_id = draw_id;
        for (self.sections) |*s| {
            const diff = cam_pos.sub(s.center);
            const cam_dot = diff.dot(cam_dir);
            const dist_sq = diff.dot(diff);
            // The original culls sections whose centre is more than 2048
            // units behind the camera plane; with a camera that rides higher
            // than the ship's, faces of the section underneath still reach
            // into view, so allow a few sections more.
            if (cam_dot < section_cull_behind and dist_sq < render.fadeout_far * render.fadeout_far) {
                self.drawSection(r, s);
            }
        }
    }

    pub fn drawSection(self: *const Track, r: *render.Renderer, section: *const Section) void {
        const start: usize = section.face_start;
        const end: usize = @min(start + section.face_count, self.faces.len);
        for (self.faces[start..end]) |*face| {
            const tex = self.textureIndex(face);
            r.pushTris(face.tris[0], tex);
            r.pushTris(face.tris[1], tex);
        }
    }
};

const track_uv = [2][4]Vec2{
    .{ Vec2.init(128, 0), Vec2.init(0, 0), Vec2.init(0, 128), Vec2.init(128, 128) },
    .{ Vec2.init(0, 0), Vec2.init(128, 0), Vec2.init(128, 128), Vec2.init(0, 128) },
};

/// Load `<dir>/track.*` and `<dir>/library.*`, registering textures with `r`.
pub fn load(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer, dir: []const u8) !Track {
    var track = Track{
        .faces = &.{},
        .sections = &.{},
        .texture_start = r.texturesLen(),
        .texture_len = 0,
        .total_section_nums = 0,
    };

    try loadTextures(gpa, assets, r, dir, &track);

    const vertices = try loadVertices(gpa, assets, dir);
    defer gpa.free(vertices);
    track.faces = try loadFaces(gpa, assets, dir, vertices);
    errdefer gpa.free(track.faces);
    track.sections = try loadSections(gpa, assets, dir, track.faces.len);
    errdefer gpa.free(track.sections);

    try numberSections(&track);

    for (track.sections) |*section| {
        const base = track.baseFace(section);
        const base_index = (@intFromPtr(base) - @intFromPtr(track.faces.ptr)) / @sizeOf(Face);
        var f: usize = 0;
        while (f < 2 and base_index + f < track.faces.len) : (f += 1) {
            const face = &track.faces[base_index + f];
            if ((face.flags & FaceFlags.boost) != 0) face.setColor(Rgba.init(0, 0, 255, 255));
        }
    }
    return track;
}

fn loadTextures(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, r: *render.Renderer, dir: []const u8, track: *Track) !void {
    const ttf_path = try assets.path(dir, "library.ttf");
    defer gpa.free(ttf_path);
    const ttf = try assets.load(ttf_path);
    defer gpa.free(ttf);

    const cmp_path = try assets.path(dir, "library.cmp");
    defer gpa.free(cmp_path);
    const cmp_bytes = try assets.load(cmp_path);
    defer gpa.free(cmp_bytes);
    const cmp = try image.decodeCmp(gpa, cmp_bytes);
    defer cmp.deinit(gpa);

    var tile = try image.Image.alloc(gpa, 128, 128);
    defer tile.deinit(gpa);

    const tile_count = ttf.len / 42;
    var reader = bytes.Reader.init(ttf);
    var i: usize = 0;
    while (i < tile_count) : (i += 1) {
        var near: [16]u16 = undefined;
        for (&near) |*n| n.* = try reader.u16Be();
        try reader.skip(4 * 2 + 2); // medium and far LOD tiles

        var ty: u32 = 0;
        while (ty < 4) : (ty += 1) {
            var tx: u32 = 0;
            while (tx < 4) : (tx += 1) {
                const sub_index = near[ty * 4 + tx];
                if (sub_index >= cmp.entries.len) return error.BadTileIndex;
                const sub = try image.decodeTim(gpa, cmp.entries[sub_index], false);
                defer sub.deinit(gpa);
                if (sub.width < 32 or sub.height < 32) return error.CorruptTrack;
                tile.blit(&sub, 0, 0, 32, 32, tx * 32, ty * 32);
            }
        }
        _ = try r.createTexture(tile.width, tile.height, tile.pixels);
        track.texture_len += 1;
    }
}

fn loadVertices(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, dir: []const u8) ![]Vec3 {
    const path = try assets.path(dir, "track.trv");
    defer gpa.free(path);
    const data = try assets.load(path);
    defer gpa.free(data);

    const count = data.len / 16;
    const vertices = try gpa.alloc(Vec3, count);
    errdefer gpa.free(vertices);
    var reader = bytes.Reader.init(data);
    for (vertices) |*v| {
        v.x = @floatFromInt(try reader.i32Be());
        v.y = @floatFromInt(try reader.i32Be());
        v.z = @floatFromInt(try reader.i32Be());
        try reader.skip(4);
    }
    return vertices;
}

fn loadFaces(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, dir: []const u8, vertices: []const Vec3) ![]Face {
    const path = try assets.path(dir, "track.trf");
    defer gpa.free(path);
    const data = try assets.load(path);
    defer gpa.free(data);

    const count = data.len / 20;
    const faces = try gpa.alloc(Face, count);
    errdefer gpa.free(faces);
    var reader = bytes.Reader.init(data);
    for (faces) |*face| {
        var v: [4]Vec3 = undefined;
        for (&v) |*p| {
            const index = try reader.i16Be();
            if (index < 0 or @as(usize, @intCast(index)) >= vertices.len) return error.BadVertexIndex;
            p.* = vertices[@intCast(index)];
        }
        face.normal = Vec3.init(
            @as(f32, @floatFromInt(try reader.i16Be())) / 4096.0,
            @as(f32, @floatFromInt(try reader.i16Be())) / 4096.0,
            @as(f32, @floatFromInt(try reader.i16Be())) / 4096.0,
        );
        face.texture = try reader.u8At();
        face.flags = try reader.u8At();
        const color = Rgba.fromU32(try reader.u32Be());
        const uv = &track_uv[if ((face.flags & FaceFlags.flip_texture) != 0) 1 else 0];
        face.tris[0] = .{ .vertices = .{
            .{ .pos = v[0], .uv = uv[0], .color = color },
            .{ .pos = v[1], .uv = uv[1], .color = color },
            .{ .pos = v[2], .uv = uv[2], .color = color },
        } };
        face.tris[1] = .{ .vertices = .{
            .{ .pos = v[3], .uv = uv[3], .color = color },
            .{ .pos = v[0], .uv = uv[0], .color = color },
            .{ .pos = v[2], .uv = uv[2], .color = color },
        } };
    }
    return faces;
}

fn loadSections(gpa: std.mem.Allocator, assets: *const assets_mod.Assets, dir: []const u8, face_count: usize) ![]Section {
    const path = try assets.path(dir, "track.trs");
    defer gpa.free(path);
    const data = try assets.load(path);
    defer gpa.free(data);

    const count = data.len / 156;
    const sections = try gpa.alloc(Section, count);
    errdefer gpa.free(sections);
    var reader = bytes.Reader.init(data);
    for (sections) |*s| {
        const junction = try reader.i32Be();
        if (junction != none and (junction < 0 or @as(usize, @intCast(junction)) >= count)) return error.BadSectionIndex;
        s.junction = junction;
        s.prev = try sectionIndex(try reader.i32Be(), count);
        s.next = try sectionIndex(try reader.i32Be(), count);
        s.center = Vec3.init(
            @floatFromInt(try reader.i32Be()),
            @floatFromInt(try reader.i32Be()),
            @floatFromInt(try reader.i32Be()),
        );
        const version = try reader.i16Be();
        if (version != track_version) return error.BadTrackVersion;
        try reader.skip(2); // padding
        try reader.skip(4 + 4); // object list pointer + count
        try reader.skip(5 * 3 * 4); // view section pointers
        try reader.skip(5 * 3 * 2); // view section counts
        try reader.skip(4 * 2); // high LOD list
        try reader.skip(4 * 2); // medium LOD list
        const face_start = try reader.i16Be();
        const face_len = try reader.i16Be();
        if (face_start < 0 or face_len < 0 or @as(usize, @intCast(face_start)) + @as(usize, @intCast(face_len)) > face_count) return error.CorruptTrack;
        s.face_start = @intCast(face_start);
        s.face_count = @intCast(face_len);
        try reader.skip(2 * 2); // global / local radius
        s.flags = try reader.i16Be();
        s.num = try reader.i16Be();
        try reader.skip(2); // padding
    }
    return sections;
}

fn sectionIndex(raw: i32, count: usize) Error!u32 {
    if (raw < 0 or @as(usize, @intCast(raw)) >= count) return error.BadSectionIndex;
    return @intCast(raw);
}

/// Number sections along the main loop; a junction branch reuses the numbers
/// of the stretch it bypasses so lap progress is comparable on both routes.
fn numberSections(track: *Track) Error!void {
    const sections = track.sections;
    if (sections.len == 0) return error.CorruptTrack;
    var num: i16 = 0;
    var index: u32 = 0;
    var guard: usize = 0;
    while (true) {
        const s = &sections[index];
        s.num = num;
        num += 1;
        if (s.junction != none) {
            var j: u32 = @intCast(s.junction);
            var branch_guard: usize = 0;
            while (true) {
                sections[j].num = num;
                num += 1;
                j = sections[j].next;
                branch_guard += 1;
                if (sections[j].junction != none or branch_guard > sections.len) break;
            }
            num = s.num;
        }
        index = s.next;
        guard += 1;
        if (index == 0 or guard > sections.len) break;
    }
    track.total_section_nums = num;
}
