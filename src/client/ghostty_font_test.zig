//! Tests for the Ghostty font code screenshots build on (ghostty_font in
//! build.zig): the sprite font, drawn through Marlin, must match Ghostty's
//! own reference renderings pixel for pixel.
const std = @import("std");
const ghostty_font = @import("ghostty_font");
const zigimg = @import("vaxis").zigimg;

/// Ghostty's testDrawRanges for U+2500...U+25FF: every sprite in the range,
/// padded canvas and all, in a 16x16 atlas, compared with the reference.
fn expectMatchesReference(comptime size: []const u8, width: u32, ascent: u32, descent: u32, thickness: u32) !void {
    const gpa = std.testing.allocator;
    const metrics: ghostty_font.Metrics = .calc(.{
        .px_per_em = 16,
        .cell_width = @floatFromInt(width),
        .ascent = @floatFromInt(ascent),
        .descent = -@as(f64, @floatFromInt(descent)),
        .line_gap = 0.0,
        .underline_thickness = @floatFromInt(thickness),
        .strikethrough_thickness = @floatFromInt(thickness),
    });
    const height = ascent + descent;
    const stride_x = width + 2 * (width / 4);
    const stride_y = height + 2 * (height / 4);
    const atlas_width = stride_x * 16;
    const atlas = try gpa.alloc(u8, atlas_width * stride_y * 16);
    defer gpa.free(atlas);
    @memset(atlas, 0);

    var cp: u32 = 0x2500;
    while (cp <= 0x25FF) : (cp += 1) {
        if (!ghostty_font.hasSprite(cp)) continue;
        const mask = try ghostty_font.drawSprite(gpa, cp, 1, metrics);
        defer mask.deinit(gpa);
        try std.testing.expectEqual(stride_x, mask.width);
        try std.testing.expectEqual(stride_y, mask.height);
        const slot_x = stride_x * ((cp - 0x2500) % 16);
        const slot_y = stride_y * ((cp - 0x2500) / 16);
        for (0..mask.height) |y| {
            const row = atlas[(slot_y + y) * atlas_width + slot_x ..][0..mask.width];
            @memcpy(row, mask.data[y * mask.width ..][0..mask.width]);
        }
    }

    var reference = try zigimg.Image.fromMemory(gpa, @embedFile("sprite_reference_" ++ size));
    defer reference.deinit(gpa);
    try std.testing.expectEqual(@as(usize, atlas_width), reference.width);
    const expected = reference.pixels.grayscale8;
    var differing: usize = 0;
    for (atlas, expected) |got, want| {
        if (got != want.value) differing += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), differing);
}

test "box drawing and block sprites match Ghostty's references exactly" {
    ghostty_font.setIo(std.testing.io);
    // Ghostty's four reference sizes: even and odd cells and thicknesses.
    try expectMatchesReference("18x36+4", 18, 30, 6, 4);
    try expectMatchesReference("12x24+3", 12, 20, 4, 3);
    try expectMatchesReference("11x21+2", 11, 19, 2, 2);
    try expectMatchesReference("9x17+1", 9, 15, 2, 1);
}

test "symbols spread into a following blank cell as Ghostty's do" {
    // ✓ is a dingbat: a symbol. Box drawing is a graphics element.
    const row = [_]u21{ 0x2713, 0, 'a', 0x2713, 'b', 0x2500, 0x2713, 0 };
    try std.testing.expectEqual(@as(u2, 2), ghostty_font.constraintWidth(&row, 1, 0));
    try std.testing.expectEqual(@as(u2, 1), ghostty_font.constraintWidth(&row, 1, 2));
    try std.testing.expectEqual(@as(u2, 1), ghostty_font.constraintWidth(&row, 1, 3));
    // After a graphics element a symbol may still spread.
    try std.testing.expectEqual(@as(u2, 2), ghostty_font.constraintWidth(&row, 1, 6));
    try std.testing.expectEqual(@as(u2, 2), ghostty_font.constraintWidth(&row, 2, 2));
}
