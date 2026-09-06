//! Versioned, deterministic asset import. No Zig ABI layouts are stored on disk.
const std = @import("std");
const course = @import("course.zig");
const kart = @import("kart.zig");
const hud = @import("hud.zig");
const rom = @import("rom.zig");
const render = @import("render.zig");
const magic = "MKAS0001";
const limit = 8 * 1024 * 1024;
const Vertex = struct { pos: course.Vec3, u: f32, v: f32, color: [3]u8 };
const Triangle = struct { vertices: [3]Vertex, style: course.Style };
const Collision = struct { positions: [3]course.Vec3, surface: u8 };
const Colour = struct { index: u8, phases: [4]u16 };
const Frame = struct { indices: [4096]u8, colours: []Colour };
const Kart = struct { frames: [15]Frame };
// Changing this wire schema requires a new magic/version and regeneration.
const Data = struct {
    source_sha1: [20]u8,
    triangles: []Triangle,
    collision: []Collision,
    textures: []u8,
    path: []course.PathPoint,
    karts: [8]Kart,
    spark_small: [256]u8,
    spark_large: [1024]u8,
    font: [4096]u16,
    icons: [4][1280]u16,
    box: [2048]u16,
    labels: [4][512]u16,
};
pub const Set = struct {
    track: course.Course,
    sprites: []kart.Sprite,
    hud: hud.Hud,
    pub fn deinit(self: *Set) void {
        self.track.deinit();
    }
};
fn colour(c: [4]u8) u16 {
    return (@as(u16, c[0] >> 3) << 11) | (@as(u16, c[1] >> 3) << 6) | (@as(u16, c[2] >> 3) << 1) | @intFromBool(c[3] != 0);
}
// Explicit recursive field encoding: little-endian numbers, u32 slice lengths,
// declaration-order structs, no padding. Bounds are enforced before allocation.
fn write(w: *std.Io.Writer, value: anytype) anyerror!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try w.writeInt(T, value, .little),
        .float => try w.writeInt(u32, @bitCast(value), .little),
        .bool => try w.writeByte(@intFromBool(value)),
        .array => for (value) |v| try write(w, v),
        .pointer => {
            try w.writeInt(u32, @intCast(value.len), .little);
            for (value) |v| try write(w, v);
        },
        .@"struct" => inline for (std.meta.fields(T)) |f| try write(w, @field(value, f.name)),
        else => @compileError("unsupported asset field"),
    }
}
const Decoder = struct {
    bytes: []const u8,
    a: std.mem.Allocator,
    budget: usize = limit * 4,
    fn take(self: *Decoder, n: usize) ![]const u8 {
        if (n > self.bytes.len) return error.TruncatedAssets;
        const result = self.bytes[0..n];
        self.bytes = self.bytes[n..];
        return result;
    }
    fn read(self: *Decoder, comptime T: type) anyerror!T {
        switch (@typeInfo(T)) {
            .int => return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .little),
            .float => {
                const v: f32 = @bitCast(try self.read(u32));
                if (!std.math.isFinite(v) or @abs(v) > 1e6) return error.InvalidAssets;
                return v;
            },
            .bool => return switch (try self.read(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidAssets,
            },
            .array => |info| {
                var result: T = undefined;
                for (&result) |*v| v.* = try self.read(info.child);
                return result;
            },
            .pointer => |info| {
                const n = try self.read(u32);
                if (n > 65536 * 4 or n > self.bytes.len or n > self.budget / @sizeOf(info.child)) return error.InvalidAssets;
                self.budget -= n * @sizeOf(info.child);
                const result = try self.a.alloc(info.child, n);
                for (result) |*v| v.* = try self.read(info.child);
                return result;
            },
            .@"struct" => {
                var result: T = undefined;
                inline for (std.meta.fields(T)) |f| @field(result, f.name) = try self.read(f.type);
                return result;
            },
            else => @compileError("unsupported asset field"),
        }
    }
};
pub fn importRom(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    try rom.validate(bytes);
    var track = try course.Course.load(gpa, bytes);
    defer track.deinit();
    const a = track.arena.allocator();
    const data = try a.create(Data);
    data.source_sha1 = rom.us_sha1;
    data.triangles = try a.alloc(Triangle, track.triangles.len);
    data.collision = try a.alloc(Collision, track.collision.len);
    data.path = track.path;
    // Retain only bytes within complete referenced texture tiles.
    const used = try a.alloc(bool, track.textures.len);
    @memset(used, false);
    for (track.triangles) |t| if (t.style.textured) {
        const end = t.style.offset + @as(usize, t.style.width) * t.style.height * 2;
        if (end > used.len) return error.InvalidAssets;
        @memset(used[t.style.offset..end], true);
    };
    const offsets = try a.alloc(u32, used.len);
    var tex: std.ArrayList(u8) = .empty;
    for (used, 0..) |keep, i| {
        offsets[i] = @intCast(tex.items.len);
        if (keep) try tex.append(a, track.textures[i]);
    }
    data.textures = tex.items;
    for (track.triangles, data.triangles) |t, *out| {
        out.style = t.style;
        out.style.offset = if (t.style.textured) offsets[t.style.offset] else 0;
        for (t.vertices, &out.vertices) |v, *o| o.* = .{ .pos = v.pos, .u = v.u, .v = v.v, .color = v.color };
    }
    for (track.collision, data.collision) |t, *out| {
        out.surface = t.surface;
        for (t.vertices, &out.positions) |v, *o| o.* = v.pos;
    }
    const sprite = try a.create(kart.Sprite);
    for (&data.karts, 0..) |*k, c| {
        sprite.* = try kart.Sprite.loadCharacter(gpa, bytes, c);
        for (&k.frames, 0..) |*f, fi| {
            f.indices = sprite.indices[fi];
            var used_colours = [_]bool{false} ** 256;
            for (f.indices) |idx| used_colours[idx] = true;
            var colours: std.ArrayList(Colour) = .empty;
            for (used_colours, 0..) |keep, idx| if (keep) {
                var entry = Colour{ .index = @intCast(idx), .phases = undefined };
                for (&entry.phases, 0..) |*p, phase| p.* = colour(sprite.palettes[fi][phase][idx]);
                try colours.append(a, entry);
            };
            f.colours = colours.items;
        }
    }
    data.spark_small = sprite.spark_small;
    data.spark_large = sprite.spark_large;
    const h = try hud.Hud.load(gpa, bytes);
    for (h.font, &data.font) |v, *o| o.* = colour(v);
    for (h.box, &data.box) |v, *o| o.* = colour(v);
    for (h.icons, &data.icons) |row, *out| for (row, out) |v, *o| {
        o.* = colour(v);
    };
    for (h.labels, &data.labels) |row, *out| for (row, out) |v, *o| {
        o.* = colour(v);
    };
    var raw: std.Io.Writer.Allocating = .init(gpa);
    defer raw.deinit();
    try write(&raw.writer, data.*);
    var encoded: std.Io.Writer.Allocating = .init(gpa);
    defer encoded.deinit();
    try encoded.writer.writeAll(magic);
    try encoded.writer.writeInt(u32, @intCast(raw.written().len), .little);
    const window = try a.alloc(u8, 2 * std.compress.flate.max_window_len);
    var compressor = try std.compress.flate.Compress.init(&encoded.writer, window, .zlib, .best);
    try compressor.writer.writeAll(raw.written());
    try compressor.finish();
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded.written(), &digest, .{});
    try encoded.writer.writeAll(&digest);
    return gpa.dupe(u8, encoded.written());
}
pub fn load(gpa: std.mem.Allocator, bytes: []const u8) !Set {
    if (bytes.len < 44 or bytes.len > limit) return error.InvalidAssets;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.UnsupportedAssetVersion;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0 .. bytes.len - 32], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[bytes.len - 32 ..])) return error.AssetChecksumMismatch;
    const size = std.mem.readInt(u32, bytes[8..12], .little);
    if (size > limit) return error.InvalidAssets;
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    var input: std.Io.Reader = .fixed(bytes[12 .. bytes.len - 32]);
    const window = try a.alloc(u8, std.compress.flate.max_window_len);
    var dec = std.compress.flate.Decompress.init(&input, .zlib, window);
    const raw = try dec.reader.allocRemaining(a, .limited(@as(usize, size) + 1));
    if (raw.len != size) return error.InvalidAssets;
    var reader = Decoder{ .bytes = raw, .a = a };
    const d = try a.create(Data);
    d.* = try reader.read(Data);
    if (reader.bytes.len != 0 or !std.mem.eql(u8, &d.source_sha1, &rom.us_sha1) or d.path.len < 3 or d.triangles.len == 0 or d.collision.len == 0) return error.InvalidAssets;
    const triangles = try a.alloc(course.Triangle, d.triangles.len);
    for (d.triangles, triangles) |t, *o| {
        if (t.style.textured and (t.style.width == 0 or t.style.height == 0 or @as(u64, t.style.offset) + @as(u64, t.style.width) * t.style.height * 2 > d.textures.len)) return error.InvalidAssets;
        if (t.style.fmt != 0 and t.style.fmt != 3) return error.InvalidAssets;
        o.* = .{ .vertices = undefined, .style = t.style };
        for (t.vertices, &o.vertices) |v, *out| out.* = .{ .pos = v.pos, .u = v.u, .v = v.v, .color = v.color };
    }
    const collision = try a.alloc(course.Triangle, d.collision.len);
    for (d.collision, collision) |t, *o| {
        o.* = .{ .vertices = undefined, .style = .{}, .surface = t.surface };
        for (t.positions, &o.vertices) |p, *v| v.* = .{ .pos = p, .u = 0, .v = 0, .color = .{ 0, 0, 0 } };
    }
    const sprites = try a.alloc(kart.Sprite, 8);
    for (d.karts, sprites) |k, *s| {
        s.* = std.mem.zeroes(kart.Sprite);
        s.spark_small = d.spark_small;
        s.spark_large = d.spark_large;
        for (k.frames, 0..) |f, fi| {
            s.indices[fi] = f.indices;
            var seen = [_]bool{false} ** 256;
            for (f.colours) |c| {
                if (seen[c.index]) return error.InvalidAssets;
                seen[c.index] = true;
                for (c.phases, 0..) |p, phase| s.palettes[fi][phase][c.index] = render.rgba16(p);
            }
            for (f.indices) |idx| if (!seen[idx]) return error.InvalidAssets;
        }
    }
    var h: hud.Hud = undefined;
    for (d.font, &h.font) |v, *o| o.* = render.rgba16(v);
    for (d.box, &h.box) |v, *o| o.* = render.rgba16(v);
    for (d.icons, &h.icons) |row, *out| for (row, out) |v, *o| {
        o.* = render.rgba16(v);
    };
    for (d.labels, &h.labels) |row, *out| for (row, out) |v, *o| {
        o.* = render.rgba16(v);
    };
    return .{ .track = .{ .arena = arena, .vertices = &.{}, .triangles = triangles, .collision = collision, .textures = d.textures, .path = d.path }, .sprites = sprites, .hud = h };
}

/// Compare every value consumed by the renderer and collision/AI against ROM
/// loading. Used by regeneration so newly referenced assets cannot silently drop.
pub fn verifyRom(gpa: std.mem.Allocator, bytes: []const u8, set: *const Set) !void {
    var original = try course.Course.load(gpa, bytes);
    defer original.deinit();
    try std.testing.expectEqualDeep(original.path, set.track.path);
    try std.testing.expectEqual(original.triangles.len, set.track.triangles.len);
    for (original.triangles, set.track.triangles) |src, dst| {
        for (src.vertices, dst.vertices) |v, w| {
            try std.testing.expectEqualDeep(v.pos, w.pos);
            try std.testing.expectEqual(v.u, w.u);
            try std.testing.expectEqual(v.v, w.v);
            try std.testing.expectEqualDeep(v.color, w.color);
        }
        var style = src.style;
        style.offset = dst.style.offset;
        try std.testing.expectEqualDeep(style, dst.style);
        if (src.style.textured) {
            const n = @as(usize, style.width) * style.height * 2;
            try std.testing.expectEqualSlices(u8, original.textures[src.style.offset..][0..n], set.track.textures[dst.style.offset..][0..n]);
        }
    }
    try std.testing.expectEqual(original.collision.len, set.track.collision.len);
    for (original.collision, set.track.collision) |src, dst| {
        try std.testing.expectEqual(src.surface, dst.surface);
        for (src.vertices, dst.vertices) |v, w| try std.testing.expectEqualDeep(v.pos, w.pos);
    }
    const sprite = try gpa.create(kart.Sprite);
    defer gpa.destroy(sprite);
    for (set.sprites, 0..) |s, c| {
        sprite.* = try kart.Sprite.loadCharacter(gpa, bytes, c);
        try std.testing.expectEqualDeep(sprite.indices, s.indices);
        try std.testing.expectEqualDeep(sprite.spark_small, s.spark_small);
        try std.testing.expectEqualDeep(sprite.spark_large, s.spark_large);
        for (s.indices, 0..) |frame, fi| for (frame) |idx| {
            for (0..4) |phase| try std.testing.expectEqualDeep(sprite.palettes[fi][phase][idx], s.palettes[fi][phase][idx]);
        };
    }
    try std.testing.expectEqualDeep(try hud.Hud.load(gpa, bytes), set.hud);
}

test "repository bundle loads without ROM and rejects damaged files" {
    const a = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const embedded = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), @import("cache.zig").repository_path, a, .limited(limit));
    defer a.free(embedded);
    var set = try load(a, embedded);
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 3014), set.track.triangles.len);
    try std.testing.expectEqual(@as(usize, 8), set.sprites.len);
    for ([_]usize{ 0, 8, 43, embedded.len - 1 }) |n| try std.testing.expectError(if (n < 44) error.InvalidAssets else error.AssetChecksumMismatch, load(a, embedded[0..n]));
    const bad = try a.dupe(u8, embedded);
    defer a.free(bad);
    bad[0] ^= 1;
    try std.testing.expectError(error.UnsupportedAssetVersion, load(a, bad));
    bad[0] ^= 1;
    bad[100] ^= 1;
    try std.testing.expectError(error.AssetChecksumMismatch, load(a, bad));
    bad[100] ^= 1;
    std.mem.writeInt(u32, bad[8..12], limit + 1, .little);
    std.crypto.hash.sha2.Sha256.hash(bad[0 .. bad.len - 32], bad[bad.len - 32 ..][0..32], .{});
    try std.testing.expectError(error.InvalidAssets, load(a, bad));
}

test "decoder rejects oversized slices and non-finite geometry before use" {
    var decoder = Decoder{ .bytes = &.{ 255, 255, 255, 255 }, .a = std.testing.allocator };
    try std.testing.expectError(error.InvalidAssets, decoder.read([]Triangle));
    decoder.bytes = &.{ 0, 0, 128, 127 };
    try std.testing.expectError(error.InvalidAssets, decoder.read(f32));
    decoder.bytes = &.{2};
    try std.testing.expectError(error.InvalidAssets, decoder.read(bool));
}
