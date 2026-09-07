//! The single-file asset bundle: every file the port loads, in one
//! xz-compressed container built by `scripts/wipeout_pack.py`. Opened
//! once into memory; lookups hand out slices of the decompressed image.
//!
//! Container (little endian), then xz over the whole thing:
//!
//!     "WPK1"            magic
//!     u32 count
//!     count × { u16 path_len, path bytes, u32 offset, u32 size }
//!     file data         offsets are relative to the end of the table

const std = @import("std");
const Io = std.Io;

pub const magic = "WPK1";
pub const file_name = "wipeout.pak";
/// Decompressed size guard; the real image is about 11 MiB.
pub const max_unpacked_bytes: usize = 64 * 1024 * 1024;

pub const Entry = struct {
    path: []const u8,
    data: []const u8,
};

pub const Error = error{ BadBundle, BundleTooLarge };

pub const Bundle = struct {
    gpa: std.mem.Allocator,
    image: []u8,
    entries: []Entry,

    /// Read and decompress `path`.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !Bundle {
        const packed_bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_unpacked_bytes));
        defer gpa.free(packed_bytes);
        return unpack(gpa, packed_bytes);
    }

    /// Decompress an xz stream holding the container.
    pub fn unpack(gpa: std.mem.Allocator, packed_bytes: []const u8) !Bundle {
        var input: Io.Reader = .fixed(packed_bytes);
        var decompress = try std.compress.xz.Decompress.init(&input, gpa, try gpa.alloc(u8, 256 * 1024));
        defer decompress.deinit();
        const image = decompress.reader.allocRemaining(gpa, .limited(max_unpacked_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.BundleTooLarge,
            else => return err,
        };
        errdefer gpa.free(image);
        return parse(gpa, image);
    }

    /// Take ownership of a decompressed container image and index it.
    pub fn parse(gpa: std.mem.Allocator, image: []u8) !Bundle {
        if (image.len < 8 or !std.mem.eql(u8, image[0..4], magic)) return error.BadBundle;
        const count = std.mem.readInt(u32, image[4..8], .little);
        if (count > 4096) return error.BadBundle;
        const entries = try gpa.alloc(Entry, count);
        errdefer gpa.free(entries);

        var pos: usize = 8;
        var table_end: usize = 8;
        // First pass sizes the table so offsets can be resolved.
        var i: usize = 0;
        while (i < count) : (i += 1) {
            if (table_end + 2 > image.len) return error.BadBundle;
            const len = std.mem.readInt(u16, image[table_end..][0..2], .little);
            table_end += 2 + len + 8;
            if (table_end > image.len) return error.BadBundle;
        }
        i = 0;
        while (i < count) : (i += 1) {
            const len = std.mem.readInt(u16, image[pos..][0..2], .little);
            pos += 2;
            const path = image[pos .. pos + len];
            pos += len;
            const offset = std.mem.readInt(u32, image[pos..][0..4], .little);
            const size = std.mem.readInt(u32, image[pos + 4 ..][0..4], .little);
            pos += 8;
            const start = table_end + @as(usize, offset);
            const end = start + @as(usize, size);
            if (end > image.len or end < start) return error.BadBundle;
            entries[i] = .{ .path = path, .data = image[start..end] };
        }
        return .{ .gpa = gpa, .image = image, .entries = entries };
    }

    pub fn deinit(self: *Bundle) void {
        self.gpa.free(self.entries);
        self.gpa.free(self.image);
    }

    /// Bytes of `path` ("wipeout/common/allsh.prm"), borrowed from the bundle.
    pub fn get(self: *const Bundle, path: []const u8) ?[]const u8 {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.data;
        }
        return null;
    }
};

fn appendInt(list: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try list.appendSlice(gpa, &buf);
}

test "container parses and serves files by path" {
    const gpa = std.testing.allocator;
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try image.appendSlice(gpa, magic);
    try appendInt(&image, gpa, u32, 2);
    try appendInt(&image, gpa, u16, 5);
    try image.appendSlice(gpa, "a/b.x");
    try appendInt(&image, gpa, u32, 0);
    try appendInt(&image, gpa, u32, 3);
    try appendInt(&image, gpa, u16, 3);
    try image.appendSlice(gpa, "c.y");
    try appendInt(&image, gpa, u32, 3);
    try appendInt(&image, gpa, u32, 2);
    try image.appendSlice(gpa, "ABCDE");

    var bundle = try Bundle.parse(gpa, try gpa.dupe(u8, image.items));
    defer bundle.deinit();
    try std.testing.expectEqualStrings("ABC", bundle.get("a/b.x").?);
    try std.testing.expectEqualStrings("DE", bundle.get("c.y").?);
    try std.testing.expect(bundle.get("missing") == null);
}

test "truncated containers are rejected" {
    const gpa = std.testing.allocator;
    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(gpa);
    try image.appendSlice(gpa, magic);
    try appendInt(&image, gpa, u32, 1);
    try appendInt(&image, gpa, u16, 3);
    try image.appendSlice(gpa, "c.y");
    try appendInt(&image, gpa, u32, 0);
    try appendInt(&image, gpa, u32, 10); // claims more data than present
    const owned = try gpa.dupe(u8, image.items);
    defer gpa.free(owned);
    try std.testing.expectError(error.BadBundle, Bundle.parse(gpa, owned));
}
