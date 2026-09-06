//! US retail ROM reader. Assets remain in the user's ROM; nothing is bundled.
const std = @import("std");

pub const us_sha1 = [_]u8{ 0x57, 0x9c, 0x48, 0xe2, 0x11, 0xae, 0x95, 0x25, 0x30, 0xff, 0xc8, 0x73, 0x87, 0x09, 0xf0, 0x78, 0xd5, 0xdd, 0x21, 0x5e };

pub fn validate(bytes: []const u8) !void {
    if (bytes.len != 8 * 1024 * 1024 and bytes.len != 12 * 1024 * 1024) return error.UnsupportedRom;
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &us_sha1)) return error.UnsupportedRom;
}

pub fn slice(bytes: []const u8, offset: usize, length: usize) ![]const u8 {
    if (offset > bytes.len or length > bytes.len - offset) return error.TruncatedAsset;
    return bytes[offset..][0..length];
}

pub fn u16be(bytes: []const u8, offset: usize) !u16 {
    return std.mem.readInt(u16, (try slice(bytes, offset, 2))[0..2], .big);
}

pub fn i16be(bytes: []const u8, offset: usize) !i16 {
    return @bitCast(try u16be(bytes, offset));
}

pub fn u32be(bytes: []const u8, offset: usize) !u32 {
    return std.mem.readInt(u32, (try slice(bytes, offset, 4))[0..4], .big);
}

/// MIO0: MSB-first literal mask, big-endian backreferences, separate raw stream.
/// Overlapping copies are intentional. Reject malformed references and expansion bombs.
pub fn mio0(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (!std.mem.eql(u8, try slice(bytes, 0, 4), "MIO0")) return error.InvalidMio0;
    const size = try u32be(bytes, 4);
    var compressed: usize = try u32be(bytes, 8);
    var raw: usize = try u32be(bytes, 12);
    if (size > 16 * 1024 * 1024 or compressed < 16 or raw < compressed or raw > bytes.len) return error.InvalidMio0;
    const mask_end = compressed;
    const compressed_end = raw;
    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    var mask_pos: usize = 16;
    var mask: u8 = 0;
    var bit: u8 = 0;
    var written: usize = 0;
    while (written < size) {
        if (bit == 0) {
            if (mask_pos >= mask_end) return error.InvalidMio0;
            mask = bytes[mask_pos];
            mask_pos += 1;
            bit = 128;
        }
        if (mask & bit != 0) {
            out[written] = (try slice(bytes, raw, 1))[0];
            raw += 1;
            written += 1;
        } else {
            if (compressed + 2 > compressed_end) return error.InvalidMio0;
            const code = try u16be(bytes, compressed);
            compressed += 2;
            const distance: usize = (code & 0xfff) + 1;
            const length: usize = (code >> 12) + 3;
            if (distance > written or length > size - written) return error.InvalidMio0;
            for (0..length) |_| {
                out[written] = out[written - distance];
                written += 1;
            }
        }
        bit >>= 1;
    }
    return out;
}

test "MIO0 literal and overlapping backreference" {
    const encoded = "MIO0" ++ "\x00\x00\x00\x06" ++ "\x00\x00\x00\x11" ++ "\x00\x00\x00\x13" ++ "\x80\x20\x00A";
    const out = try mio0(std.testing.allocator, encoded);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("AAAAAA", out);
    var broken: [encoded.len]u8 = encoded.*;
    broken[16] = 0;
    try std.testing.expectError(error.InvalidMio0, mio0(std.testing.allocator, &broken));
    try std.testing.expectError(error.TruncatedAsset, mio0(std.testing.allocator, encoded[0..12]));
}

test "unsupported ROM fails before loading assets" {
    try std.testing.expectError(error.UnsupportedRom, validate("not a ROM"));
}
