const std = @import("std");
const mic = @import("mic.zig");

test "dictation wav is 16 kHz mono 16-bit PCM with a correct header" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "clip.wav" });
    defer gpa.free(path);

    const pcm = [_]u8{ 1, 0, 2, 0, 0xff, 0x7f, 0, 0x80 };
    try mic.writeWav(io, path, &pcm);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
    defer gpa.free(bytes);
    try std.testing.expectEqual(@as(usize, 44 + pcm.len), bytes.len);
    try std.testing.expectEqualStrings("RIFF", bytes[0..4]);
    try std.testing.expectEqual(@as(u32, 36 + pcm.len), std.mem.readInt(u32, bytes[4..8], .little));
    try std.testing.expectEqualStrings("WAVEfmt ", bytes[8..16]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[20..22], .little)); // PCM
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[22..24], .little)); // mono
    try std.testing.expectEqual(@as(u32, 16_000), std.mem.readInt(u32, bytes[24..28], .little));
    try std.testing.expectEqual(@as(u32, 32_000), std.mem.readInt(u32, bytes[28..32], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[34..36], .little));
    try std.testing.expectEqualStrings("data", bytes[36..40]);
    try std.testing.expectEqual(@as(u32, pcm.len), std.mem.readInt(u32, bytes[40..44], .little));
    try std.testing.expectEqualSlices(u8, &pcm, bytes[44..]);
}
