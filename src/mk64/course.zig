//! Luigi Raceway extraction and encoded display-list interpretation.
//! Reference: mk64/src/racing/memory.c and courses/luigi_raceway.
const std = @import("std");
const rom = @import("rom.zig");

pub const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn scale(a: Vec3, s: f32) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn length(a: Vec3) f32 {
        return @sqrt(a.dot(a));
    }
};
pub const Vertex = struct { pos: Vec3, u: f32, v: f32, color: [3]u8, flag: u8 = 0 };
pub const Style = struct {
    offset: u32 = 0,
    width: u16 = 32,
    height: u16 = 32,
    cms: u8 = 0,
    cmt: u8 = 0,
    fmt: u8 = 0,
    textured: bool = true,
    decal: bool = false,
};
pub const Triangle = struct { vertices: [3]Vertex, style: Style, surface: u8 = 0 };
pub const PathPoint = struct { pos: Vec3, section: u16 };
const Command = struct { op: u8 = 0xfe, args: [4]u8 = .{ 0, 0, 0, 0 } };

pub const Course = struct {
    arena: std.heap.ArenaAllocator,
    vertices: []Vertex,
    triangles: []Triangle,
    collision: []Triangle,
    textures: []u8,
    path: []PathPoint,

    pub fn deinit(self: *Course) void {
        self.arena.deinit();
    }

    pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Course {
        try rom.validate(bytes);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        // gCourseTable[COURSE_LUIGI_RACEWAY], US ROM.
        const table = try rom.slice(bytes, 0x122390 + 8 * 48, 48);
        const start = try rom.u32be(table, 8);
        const end = try rom.u32be(table, 12);
        if (end < start) return error.InvalidCourse;
        const geography = try rom.slice(bytes, start, end - start);
        const packed_vertices = try rom.mio0(a, geography);
        const count = try rom.u32be(table, 28);
        if (packed_vertices.len != count * 14) return error.InvalidCourse;
        const vertices = try a.alloc(Vertex, count);
        for (vertices, 0..) |*v, i| {
            const off = i * 14;
            v.* = .{ .pos = .{ .x = @floatFromInt(try rom.i16be(packed_vertices, off)), .y = @floatFromInt(try rom.i16be(packed_vertices, off + 2)), .z = @floatFromInt(try rom.i16be(packed_vertices, off + 4)) }, .u = @as(f32, @floatFromInt(try rom.i16be(packed_vertices, off + 6))) / 32, .v = @as(f32, @floatFromInt(try rom.i16be(packed_vertices, off + 8))) / 32, .color = .{ packed_vertices[off + 10] & 0xfc, packed_vertices[off + 11] & 0xfc, packed_vertices[off + 12] } };
            v.flag = (packed_vertices[off + 10] & 3) | ((packed_vertices[off + 11] << 2) & 12);
        }
        var textures: std.ArrayList(u8) = .empty;
        const offsets_start = try rom.u32be(table, 16);
        const offsets_end = try rom.u32be(table, 20);
        if (offsets_end < offsets_start) return error.InvalidCourse;
        const offsets = try rom.slice(bytes, offsets_start, offsets_end - offsets_start);
        var off: usize = (try rom.u32be(table, 40)) & 0xffffff;
        while (true) : (off += 16) {
            const address = try rom.u32be(offsets, off);
            if (address == 0) break;
            const compressed_size = try rom.u32be(offsets, off + 4);
            const size = try rom.u32be(offsets, off + 8);
            const texture = try rom.mio0(a, try rom.slice(bytes, 0x641f70 + (address & 0xffffff), compressed_size));
            if (texture.len != size) return error.InvalidCourse;
            try textures.appendSlice(a, texture);
        }
        const data_start = try rom.u32be(table, 0);
        const data_end = try rom.u32be(table, 4);
        if (data_end < data_start) return error.InvalidCourse;
        const data = try rom.mio0(a, try rom.slice(bytes, data_start, data_end - data_start));
        // The metadata's 730 is reserved capacity. The ROM path ends at x=-32768.
        const path = try readPath(a, data[0xa6d0..]);
        const packed_offset = (try rom.u32be(table, 32)) & 0xffffff;
        if (packed_offset >= geography.len) return error.InvalidCourse;
        const commands = try unpack(a, geography[packed_offset..]);
        var builder = Builder{ .a = a, .vertices = vertices, .commands = commands };
        // Whole-course root; later switch to the game's section visibility tables.
        try builder.run(0xc730 / 8, 0);
        var collision_builder = Builder{ .a = a, .vertices = vertices, .commands = commands };
        // d_course_luigi_raceway_addr: original collision display lists and surface tags.
        var section_offset: usize = 0xff28;
        while (true) : (section_offset += 8) {
            const address = try rom.u32be(data, section_offset);
            if (address == 0) break;
            if (address >> 24 != 7) return error.InvalidCourse;
            collision_builder.surface = data[section_offset + 4];
            try collision_builder.run((address & 0xffffff) / 8, 0);
        }
        var collision: std.ArrayList(Triangle) = .empty;
        for (collision_builder.triangles.items) |tri| {
            // add_collision_triangle rejects vertices marked non-collidable (flag 4).
            if (tri.vertices[0].flag == 4 and tri.vertices[1].flag == 4 and tri.vertices[2].flag == 4) continue;
            try collision.append(a, tri);
        }
        return .{ .arena = arena, .vertices = vertices, .triangles = try builder.triangles.toOwnedSlice(a), .collision = try collision.toOwnedSlice(a), .textures = try textures.toOwnedSlice(a), .path = path };
    }
};

fn readPath(a: std.mem.Allocator, data: []const u8) ![]PathPoint {
    var path: std.ArrayList(PathPoint) = .empty;
    var off: usize = 0;
    while (off < 8192 * 8) : (off += 8) {
        const x = try rom.i16be(data, off);
        if (x == std.math.minInt(i16)) {
            if (path.items.len < 2) return error.InvalidCourse;
            return path.toOwnedSlice(a);
        }
        try path.append(a, .{ .pos = .{ .x = @floatFromInt(x), .y = @floatFromInt(try rom.i16be(data, off + 2)), .z = @floatFromInt(try rom.i16be(data, off + 4)) }, .section = try rom.u16be(data, off + 6) });
    }
    return error.InvalidCourse;
}

test "path sentinel excludes reserved capacity and subsequent asset data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try readPath(arena.allocator(), "\x00\x01\x00\x02\x00\x03\x00\x01" ++ "\x00\x02\x00\x03\x00\x04\x00\x01" ++ "\x80\x00\x80\x00\x80\x00\x00\x00" ++ "other asset");
    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expectError(error.TruncatedAsset, readPath(arena.allocator(), "\x00\x01"));
}

fn unpack(a: std.mem.Allocator, encoded: []const u8) ![]Command {
    var list: std.ArrayList(Command) = .empty;
    var p: usize = 0;
    while (p < encoded.len) {
        const op = encoded[p];
        p += 1;
        if (op == 0xff) return list.toOwnedSlice(a);
        const argc: usize = switch (op) {
            0x1a...0x1f, 0x2c, 0x29, 0x2b, 0x33...0x52 => 2,
            0x20...0x25, 0x30 => 3,
            0x28, 0x58 => 4,
            0...0x19, 0x26, 0x27, 0x2a, 0x2d...0x2f, 0x53...0x57 => 0,
            else => return error.UnknownPackedOpcode,
        };
        var command = Command{ .op = op };
        @memcpy(command.args[0..argc], try rom.slice(encoded, p, argc));
        p += argc;
        try list.append(a, command);
        // Calls address the expanded N64 stream, so preserve its command indices.
        const slots: usize = switch (op) {
            0...0x14, 0x1a...0x1f, 0x2c => 3,
            0x20...0x25 => 5,
            else => 1,
        };
        for (1..slots) |_| try list.append(a, .{});
        if (list.items.len > 100000) return error.InvalidCourse;
    }
    return error.TruncatedAsset;
}

const Builder = struct {
    a: std.mem.Allocator,
    vertices: []Vertex,
    commands: []Command,
    triangles: std.ArrayList(Triangle) = .empty,
    cache: [32]?Vertex = .{null} ** 32,
    style: Style = .{},
    surface: u8 = 0,
    steps: usize = 0,
    fn run(self: *Builder, start: usize, depth: usize) anyerror!void {
        if (depth > 32) return error.DisplayListRecursion;
        var pc = start;
        while (pc < self.commands.len) : (pc += 1) {
            self.steps += 1;
            if (self.steps > 100000) return error.DisplayListBudget;
            const c = self.commands[pc];
            const op = c.op;
            const b = c.args;
            switch (op) {
                0x2a => return,
                0x2b => try self.run(@as(usize, b[0]) | (@as(usize, b[1]) << 8), depth + 1),
                0x28, 0x33...0x52 => {
                    const index = @as(usize, b[0]) | (@as(usize, b[1]) << 8);
                    const n: usize = if (op == 0x28) b[2] & 63 else op - 0x32;
                    const dest: usize = if (op == 0x28) b[3] & 63 else 0;
                    if (dest + n > 32 or index + n > self.vertices.len) return error.InvalidVertex;
                    for (0..n) |i| self.cache[dest + i] = self.vertices[index + i];
                },
                0x29, 0x58 => {
                    try self.triangle(b[0] & 31, (b[0] >> 5) | ((b[1] & 3) << 3), (b[1] >> 2) & 31);
                    if (op == 0x58) try self.triangle(b[2] & 31, (b[2] >> 5) | ((b[3] & 3) << 3), (b[3] >> 2) & 31);
                },
                0x30 => {
                    const idx0 = b[0] & 31;
                    const idx1 = (b[0] >> 5) | ((b[1] & 3) << 3);
                    const idx2 = (b[1] >> 2) & 31;
                    const idx3 = (b[1] >> 7) | ((b[2] & 15) << 1);
                    try self.triangle(idx0, idx1, idx2);
                    try self.triangle(idx0, idx2, idx3);
                },
                0x1a...0x1f, 0x2c => {
                    const variant: u8 = if (op == 0x2c) 0 else (op - 0x1a) % 3;
                    self.style.width = if (variant == 1) 64 else 32;
                    self.style.height = if (variant == 2) 64 else 32;
                    self.style.cms = b[0] & 15;
                    self.style.cmt = b[1] & 15;
                    self.style.fmt = if (op >= 0x1d and op <= 0x1f) 3 else 0;
                },
                0x20...0x25 => self.style.offset = @as(u32, b[0]) << 11,
                0x26 => self.style.textured = true,
                0x27, 0x17 => self.style.textured = false,
                0x15, 0x16, 0x2e => {
                    self.style.textured = true;
                    self.style.decal = false;
                },
                0x53 => {
                    self.style.textured = true;
                    self.style.decal = true;
                },
                else => {}, // sync, lighting, render mode, culling: no vertex output
            }
        }
        return error.UnterminatedDisplayList;
    }
    fn triangle(self: *Builder, a: u8, b: u8, c: u8) !void {
        try self.triangles.append(self.a, .{ .vertices = .{ self.cache[a] orelse return error.InvalidVertex, self.cache[b] orelse return error.InvalidVertex, self.cache[c] orelse return error.InvalidVertex }, .style = self.style, .surface = self.surface });
    }
};

test "encoded commands preserve expanded display-list offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try unpack(arena.allocator(), &.{ 0x1a, 0x50, 0x50, 0x20, 0, 0, 0, 0x2a, 0xff });
    try std.testing.expectEqual(@as(usize, 9), c.len);
    try std.testing.expectEqual(@as(u8, 0x20), c[3].op);
    try std.testing.expectEqual(@as(u8, 0x2a), c[8].op);
    try std.testing.expectError(error.UnknownPackedOpcode, unpack(arena.allocator(), &.{0xab}));
}
