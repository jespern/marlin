//! PRM model files: a chain of named objects, each with vertices, normals,
//! and a list of variably sized primitives. Only the primitive kinds the
//! original renders are kept; lights, splines, and light-sourced polygons
//! are parsed to advance the cursor and then dropped.

const std = @import("std");
const bytes = @import("bytes.zig");
const math = @import("math.zig");
const render = @import("render.zig");
const Vec2 = math.Vec2;
const Vec2i = math.Vec2i;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Rgba = math.Rgba;

pub const Flags = struct {
    pub const single_sided: i16 = 0x0001;
    pub const ship_engine: i16 = 0x0002;
    pub const translucent: i16 = 0x0004;
};

const PrimType = enum(i16) {
    f3 = 1,
    ft3,
    f4,
    ft4,
    g3,
    gt3,
    g4,
    gt4,
    lf2,
    tspr,
    bspr,
    lsf3,
    lsft3,
    lsf4,
    lsft4,
    lsg3,
    lsgt3,
    lsg4,
    lsgt4,
    spline,
    infinite_light,
    point_light,
    spot_light,
    _,
};

pub const Kind = enum(u8) { f3, ft3, f4, ft4, g3, gt3, g4, gt4, tspr, bspr, other };

pub const Prim = struct {
    kind: Kind,
    flag: i16,
    coords: [4]u16 = .{ 0, 0, 0, 0 },
    uv: [4]Vec2 = .{ Vec2.init(0, 0), Vec2.init(0, 0), Vec2.init(0, 0), Vec2.init(0, 0) },
    color: [4]Rgba = .{ Rgba.white, Rgba.white, Rgba.white, Rgba.white },
    texture: u16 = 0,
    width: i16 = 0,
    height: i16 = 0,
};

pub const Object = struct {
    name: [16]u8,
    mat: Mat4,
    vertices: []Vec3,
    normals: []Vec3,
    primitives: []Prim,
    origin: Vec3,
    extent: i32,
    flags: i16,
    radius: f32,

    pub fn nameSlice(self: *const Object) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.name, 0) orelse self.name.len;
        return self.name[0..end];
    }

    pub fn nameStartsWith(self: *const Object, prefix: []const u8) bool {
        return std.mem.startsWith(u8, self.nameSlice(), prefix);
    }

    pub fn draw(self: *const Object, r: *render.Renderer, mat: *const Mat4) void {
        r.setModelMat(mat);
        const v = self.vertices;
        for (self.primitives, 0..) |p, index| {
            if (r.debug_prim_ids) r.draw_id = @intCast(0x4000 + (index & 0x3fff));
            switch (p.kind) {
                .f3, .ft3, .g3, .gt3 => {
                    const tex = if (p.kind == .f3 or p.kind == .g3) r.no_texture else p.texture;
                    r.pushTris(.{ .vertices = .{
                        .{ .pos = v[p.coords[2]], .uv = p.uv[2], .color = p.color[2] },
                        .{ .pos = v[p.coords[1]], .uv = p.uv[1], .color = p.color[1] },
                        .{ .pos = v[p.coords[0]], .uv = p.uv[0], .color = p.color[0] },
                    } }, tex);
                },
                .f4, .ft4, .g4, .gt4 => {
                    const tex = if (p.kind == .f4 or p.kind == .g4) r.no_texture else p.texture;
                    r.pushTris(.{ .vertices = .{
                        .{ .pos = v[p.coords[2]], .uv = p.uv[2], .color = p.color[2] },
                        .{ .pos = v[p.coords[1]], .uv = p.uv[1], .color = p.color[1] },
                        .{ .pos = v[p.coords[0]], .uv = p.uv[0], .color = p.color[0] },
                    } }, tex);
                    r.pushTris(.{ .vertices = .{
                        .{ .pos = v[p.coords[2]], .uv = p.uv[2], .color = p.color[2] },
                        .{ .pos = v[p.coords[3]], .uv = p.uv[3], .color = p.color[3] },
                        .{ .pos = v[p.coords[1]], .uv = p.uv[1], .color = p.color[1] },
                    } }, tex);
                },
                .tspr, .bspr => {
                    const anchor = v[p.coords[0]];
                    const half: f32 = @floatFromInt(@divTrunc(p.height, 2));
                    const y_offset: f32 = if (p.kind == .tspr) half else -half;
                    r.pushSprite(
                        Vec3.init(anchor.x, anchor.y + y_offset, anchor.z),
                        Vec2i.init(p.width, p.height),
                        p.color[0],
                        p.texture,
                    );
                },
                .other => {},
            }
        }
    }
};

pub const Error = error{
    BadPrimitiveType,
    BadTextureIndex,
    BadCoordIndex,
} || bytes.Error || std.mem.Allocator.Error;

pub const TextureList = struct {
    start: u16,
    len: u16,

    pub fn resolve(self: TextureList, index: i16) Error!u16 {
        if (index < 0 or @as(u16, @intCast(index)) >= self.len) return error.BadTextureIndex;
        return self.start + @as(u16, @intCast(index));
    }
};

/// Parse every object in a PRM blob. Slices are allocated from `gpa`.
pub fn load(gpa: std.mem.Allocator, data: []const u8, textures: TextureList) Error![]Object {
    var list: std.ArrayList(Object) = .empty;
    errdefer list.deinit(gpa);
    var reader = bytes.Reader.init(data);

    while (!reader.atEnd()) {
        var obj: Object = undefined;
        for (&obj.name) |*c| c.* = try reader.u8At();
        obj.mat = Mat4.identity;
        const vertices_len: usize = @intCast(@max(try reader.i16Be(), 0));
        try reader.skip(2 + 4);
        const normals_len: usize = @intCast(@max(try reader.i16Be(), 0));
        try reader.skip(2 + 4);
        const primitives_len: usize = @intCast(@max(try reader.i16Be(), 0));
        try reader.skip(2 + 4);
        try reader.skip(4 + 4 + 4); // unknown, unknown, skeleton
        obj.extent = try reader.i32Be();
        obj.flags = try reader.i16Be();
        try reader.skip(2 + 4); // padding, next pointer
        try reader.skip(3 * 3 * 2 + 2); // relative rotation + padding
        obj.origin = Vec3.init(
            @floatFromInt(try reader.i32Be()),
            @floatFromInt(try reader.i32Be()),
            @floatFromInt(try reader.i32Be()),
        );
        try reader.skip(3 * 3 * 2 + 2); // absolute rotation + padding
        try reader.skip(3 * 4); // absolute translation
        try reader.skip(2 + 2); // skeleton update flag + padding
        try reader.skip(4 + 4 + 4); // skeleton super/sub/next

        obj.vertices = try gpa.alloc(Vec3, vertices_len);
        errdefer gpa.free(obj.vertices);
        var radius_sq: f32 = 0;
        for (obj.vertices) |*v| {
            v.* = Vec3.init(
                @floatFromInt(try reader.i16Be()),
                @floatFromInt(try reader.i16Be()),
                @floatFromInt(try reader.i16Be()),
            );
            try reader.skip(2);
            radius_sq = @max(radius_sq, v.lenSq());
        }
        obj.radius = @sqrt(radius_sq);

        obj.normals = try gpa.alloc(Vec3, normals_len);
        errdefer gpa.free(obj.normals);
        for (obj.normals) |*n| {
            n.* = Vec3.init(
                @floatFromInt(try reader.i16Be()),
                @floatFromInt(try reader.i16Be()),
                @floatFromInt(try reader.i16Be()),
            );
            try reader.skip(2);
        }

        obj.primitives = try gpa.alloc(Prim, primitives_len);
        errdefer gpa.free(obj.primitives);
        for (obj.primitives) |*prim| {
            prim.* = try readPrimitive(&reader, textures, vertices_len);
        }

        try list.append(gpa, obj);
    }
    return list.toOwnedSlice(gpa);
}

pub fn free(gpa: std.mem.Allocator, objects: []Object) void {
    for (objects) |o| {
        gpa.free(o.vertices);
        gpa.free(o.normals);
        gpa.free(o.primitives);
    }
    gpa.free(objects);
}

fn coord(reader: *bytes.Reader, vertex_count: usize) Error!u16 {
    const c = try reader.i16Be();
    if (c < 0 or @as(usize, @intCast(c)) >= vertex_count) return error.BadCoordIndex;
    return @intCast(c);
}

fn readUv(reader: *bytes.Reader) Error!Vec2 {
    const u = try reader.u8At();
    const v = try reader.u8At();
    return Vec2.init(@floatFromInt(u), @floatFromInt(v));
}

fn readColor(reader: *bytes.Reader) Error!Rgba {
    return Rgba.fromU32(try reader.u32Be());
}

fn readPrimitive(reader: *bytes.Reader, textures: TextureList, vertex_count: usize) Error!Prim {
    const raw_type = try reader.i16Be();
    const flag = try reader.i16Be();
    const kind: PrimType = @enumFromInt(raw_type);
    var p = Prim{ .kind = .other, .flag = flag };

    switch (kind) {
        .f3 => {
            p.kind = .f3;
            for (p.coords[0..3]) |*c| c.* = try coord(reader, vertex_count);
            try reader.skip(2);
            p.color[0] = try readColor(reader);
            p.color[1] = p.color[0];
            p.color[2] = p.color[0];
        },
        .f4 => {
            p.kind = .f4;
            for (p.coords[0..4]) |*c| c.* = try coord(reader, vertex_count);
            p.color[0] = try readColor(reader);
            p.color = .{ p.color[0], p.color[0], p.color[0], p.color[0] };
        },
        .ft3 => {
            p.kind = .ft3;
            for (p.coords[0..3]) |*c| c.* = try coord(reader, vertex_count);
            p.texture = try textures.resolve(try reader.i16Be());
            try reader.skip(2 + 2); // cba, tsb
            for (p.uv[0..3]) |*uv| uv.* = try readUv(reader);
            try reader.skip(2);
            p.color[0] = try readColor(reader);
            p.color = .{ p.color[0], p.color[0], p.color[0], p.color[0] };
        },
        .ft4 => {
            p.kind = .ft4;
            for (p.coords[0..4]) |*c| c.* = try coord(reader, vertex_count);
            p.texture = try textures.resolve(try reader.i16Be());
            try reader.skip(2 + 2);
            for (p.uv[0..4]) |*uv| uv.* = try readUv(reader);
            try reader.skip(2);
            p.color[0] = try readColor(reader);
            p.color = .{ p.color[0], p.color[0], p.color[0], p.color[0] };
        },
        .g3 => {
            p.kind = .g3;
            for (p.coords[0..3]) |*c| c.* = try coord(reader, vertex_count);
            try reader.skip(2);
            for (p.color[0..3]) |*c| c.* = try readColor(reader);
        },
        .g4 => {
            p.kind = .g4;
            for (p.coords[0..4]) |*c| c.* = try coord(reader, vertex_count);
            for (p.color[0..4]) |*c| c.* = try readColor(reader);
        },
        .gt3 => {
            p.kind = .gt3;
            for (p.coords[0..3]) |*c| c.* = try coord(reader, vertex_count);
            p.texture = try textures.resolve(try reader.i16Be());
            try reader.skip(2 + 2);
            for (p.uv[0..3]) |*uv| uv.* = try readUv(reader);
            try reader.skip(2);
            for (p.color[0..3]) |*c| c.* = try readColor(reader);
        },
        .gt4 => {
            p.kind = .gt4;
            for (p.coords[0..4]) |*c| c.* = try coord(reader, vertex_count);
            p.texture = try textures.resolve(try reader.i16Be());
            try reader.skip(2 + 2);
            for (p.uv[0..4]) |*uv| uv.* = try readUv(reader);
            try reader.skip(2);
            for (p.color[0..4]) |*c| c.* = try readColor(reader);
        },
        .lsf3 => try reader.skip(3 * 2 + 2 + 4),
        .lsf4 => try reader.skip(4 * 2 + 2 + 2 + 4),
        .lsft3 => try reader.skip(3 * 2 + 2 + 2 + 2 + 2 + 6 + 4),
        .lsft4 => try reader.skip(4 * 2 + 2 + 2 + 2 + 2 + 8 + 4),
        .lsg3 => try reader.skip(3 * 2 + 3 * 2 + 3 * 4),
        .lsg4 => try reader.skip(4 * 2 + 4 * 2 + 4 * 4),
        .lsgt3 => try reader.skip(3 * 2 + 3 * 2 + 2 + 2 + 2 + 6 + 3 * 4),
        .lsgt4 => try reader.skip(4 * 2 + 4 * 2 + 2 + 2 + 2 + 8 + 2 + 4 * 4),
        .tspr, .bspr => {
            p.kind = if (kind == .tspr) .tspr else .bspr;
            p.coords[0] = try coord(reader, vertex_count);
            p.width = try reader.i16Be();
            p.height = try reader.i16Be();
            p.texture = try textures.resolve(try reader.i16Be());
            p.color[0] = try readColor(reader);
        },
        .spline => try reader.skip(3 * (3 * 4 + 4) + 4),
        .point_light => try reader.skip(3 * 4 + 4 + 4 + 2 + 2),
        .spot_light => try reader.skip(3 * 4 + 4 + 3 * 2 + 2 + 4 + 4 * 2),
        .infinite_light => try reader.skip(3 * 2 + 2 + 4),
        .lf2, _ => return error.BadPrimitiveType,
    }
    return p;
}
