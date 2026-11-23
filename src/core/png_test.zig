//! Unit tests for png.zig.
const std = @import("std");
const vt = @import("ghostty-vt");
const png = @import("png.zig");

test "PNG images decode to RGBA for libghostty-vt" {
    png.install();
    // 1x1 opaque red PNG.
    const red = [_]u8{
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41, 0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
        0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d, 0xb0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
        0x44, 0xae, 0x42, 0x60, 0x82,
    };
    const image = try vt.sys.decode_png.?(std.testing.allocator, &red);
    defer std.testing.allocator.free(image.data);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.data);
    try std.testing.expectError(error.InvalidData, vt.sys.decode_png.?(std.testing.allocator, "not a png"));
}

test "real PNGs decode to RGBA at the size their header gives" {
    // Alpha, a palette, gray with alpha and 16-bit channels. Their pixels
    // were checked against zigimg when wuffs replaced it; the box-drawing
    // references are also held pixel for pixel in ghostty_font_test.zig.
    const gpa = std.testing.allocator;
    png.install();
    const samples = [_][]const u8{
        @embedFile("../client/webui-icon-180.png"),
        @embedFile("sprite_reference_18x36+4"),
        @embedFile("sprite_reference_9x17+1"),
        @embedFile("png_sample_rgba"),
        @embedFile("png_sample_palette"),
        @embedFile("png_sample_gray_alpha"),
        @embedFile("png_sample_rgba16"),
    };
    for (samples) |bytes| {
        // IHDR follows the 8-byte signature and its own length and type.
        const width = std.mem.readInt(u32, bytes[16..20], .big);
        const height = std.mem.readInt(u32, bytes[20..24], .big);
        const image = try vt.sys.decode_png.?(gpa, bytes);
        defer gpa.free(image.data);
        try std.testing.expectEqual(width, image.width);
        try std.testing.expectEqual(height, image.height);
        try std.testing.expectEqual(@as(usize, width) * height * 4, image.data.len);
    }
}
