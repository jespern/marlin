const std = @import("std");
const transcript_images = @import("transcript_images.zig");
const shell_images = @import("shell_images.zig");

test "PNG passes through with its header size; other formats stay a label" {
    const gpa = std.testing.allocator;
    const png = @embedFile("png_sample_rgba");
    const encoded_png = try transcript_images.encode(gpa, png);
    defer gpa.free(encoded_png.data);
    try std.testing.expectEqual(@as(u32, 16), encoded_png.width);
    try std.testing.expectEqual(@as(u32, 16), encoded_png.height);
    try std.testing.expectEqualSlices(u8, png, encoded_png.data);
    try std.testing.expectError(error.UnsupportedImage, transcript_images.encode(gpa, "\xff\xd8\xff\xe0 a jpeg"));
    try std.testing.expect(!transcript_images.isImageMime("image/jpeg"));
}

test "images fit the cell box without upscaling and keep their aspect" {
    // 800×400 px in 10×20 px cells: 80×20 cells natively.
    try std.testing.expectEqual(transcript_images.Cells{ .cols = 80, .rows = 20 }, transcript_images.fit(800, 400, 10, 20, 100, 24));
    // Wider than the view: halved to 40 columns, 10 rows.
    try std.testing.expectEqual(transcript_images.Cells{ .cols = 40, .rows = 10 }, transcript_images.fit(800, 400, 10, 20, 40, 24));
    // Taller than the cap: 12 rows, width scaled to match.
    try std.testing.expectEqual(transcript_images.Cells{ .cols = 24, .rows = 12 }, transcript_images.fit(400, 400, 10, 20, 100, 12));
    // A tiny icon stays tiny.
    try std.testing.expectEqual(transcript_images.Cells{ .cols = 2, .rows = 1 }, transcript_images.fit(16, 16, 10, 20, 100, 24));
    // Unknown cell size falls back to 8×16.
    try std.testing.expectEqual(transcript_images.Cells{ .cols = 10, .rows = 5 }, transcript_images.fit(80, 80, 0, 0, 100, 24));
}

test "the cache requests an image once and reports whether it can draw" {
    const gpa = std.testing.allocator;
    var cache: transcript_images.Cache = .{};
    defer cache.deinit(gpa);
    try std.testing.expect(cache.want(gpa, "abc"));
    try std.testing.expect(!cache.want(gpa, "abc"));
    try std.testing.expect(cache.awaiting("abc"));
    try std.testing.expect(cache.deliver(gpa, "abc", @embedFile("png_sample_rgba")));
    try std.testing.expect(cache.get("abc").?.state == .ready);
    try std.testing.expect(!cache.deliver(gpa, "abc", "again"));
    // Undecodable bytes stay a label.
    try std.testing.expect(cache.want(gpa, "bad"));
    try std.testing.expect(!cache.deliver(gpa, "bad", "not an image"));
    try std.testing.expect(cache.get("bad").?.state == .failed);
    try std.testing.expect(cache.want(gpa, "gone"));
    cache.fail("gone");
    try std.testing.expect(cache.get("gone").?.state == .failed);
}

test "an encoded PNG is sent once with f=100 and placed with a crop" {
    const gpa = std.testing.allocator;
    var display = shell_images.Display.withBase(shell_images.transcript_first_id);
    defer display.deinit(gpa);
    const image: shell_images.Encoded = .{ .format = .png, .width = 16, .height = 16, .data = "PNGDATA" };
    const want: shell_images.Want = .{
        .image = .{ .encoded = &image },
        .key = .{ .owner = 1, .image_id = 0, .data = 2, .len = 7 },
        .placement = 1,
        .col = 4,
        .row = 10,
        .cols = 2,
        .rows = 1,
        .source = .{ .x = 0, .y = 8, .width = 16, .height = 8 },
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try display.update(gpa, &out.writer, &.{want});
    const first = out.written();
    try std.testing.expect(std.mem.indexOf(u8, first, "a=t,f=100,i=1297350656,q=2,m=0;UE5HREFUQQ==") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[11;5H") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "a=p,i=1297350656,p=1,c=2,r=1,x=0,y=8,w=16,h=8") != null);
    // The next frame only re-places it.
    out.clearRetainingCapacity();
    try display.update(gpa, &out.writer, &.{want});
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=t") == null);
    // Scrolled away: its placement is removed.
    out.clearRetainingCapacity();
    try display.update(gpa, &out.writer, &.{});
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=d,d=i,i=1297350656,p=1") != null);
}
