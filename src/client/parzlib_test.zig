const std = @import("std");
const Io = std.Io;
const flate = std.compress.flate;
const parzlib = @import("parzlib.zig");

test "parallel zlib stream decodes to the input" {
    const gpa = std.testing.allocator;
    // Enough data for several bands, with structure so deflate has work.
    const len = 640 * 480 * 3;
    const src = try gpa.alloc(u8, len);
    defer gpa.free(src);
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (src, 0..) |*b, i| b.* = if (i % 7 == 0) random.int(u8) else @truncate(i / 640);

    var encoder = parzlib.Encoder.init(gpa, 6);
    defer encoder.deinit();
    const dst = try gpa.alloc(u8, len + 8192);
    defer gpa.free(dst);
    const compressed = encoder.compress(dst, src) orelse return error.CompressFailed;
    try std.testing.expect(compressed.len < len);

    var in: Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var decompress: flate.Decompress = .init(&in, .zlib, &window);
    const out = try gpa.alloc(u8, len);
    defer gpa.free(out);
    try decompress.reader.readSliceAll(out);
    try std.testing.expectEqualSlices(u8, src, out);
}
