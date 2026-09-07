const std = @import("std");
const kitty = @import("kitty_transport.zig");

test "a shipped frame: one sync update, cursor to the placement, one a=T under image id and placement id 1, 4 KiB chunks" {
    var buf: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const id: u32 = 0x4d61_7205;
    try kitty.shipFrame(&w, "A" ** 10_000, id, 320, 240, true, .{ .col = 4, .row = 2, .cols = 72, .rows = 20 });
    const out = w.buffered();
    var head: [128]u8 = undefined;
    const want = try std.fmt.bufPrint(&head, "\x1b[?2026h\x1b[3;5H\x1b_Ga=T,f=24,s=320,v=240,i={d},p=1,q=2,o=z,m=1,c=72,r=20,C=1;", .{id});
    try std.testing.expect(std.mem.startsWith(u8, out, want));
    try std.testing.expect(std.mem.endsWith(u8, out, "\x1b\\\x1b[?2026l"));
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\x1b_G")); // 4096 + 4096 + 1808
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b_Gm=1;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b_Gm=0;"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[?2026h"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[?2026l"));
    try std.testing.expect(std.mem.indexOf(u8, out, "a=d") == null); // never a delete: the placement id does the replacing
}

test "uncompressed frames carry no o=z; a small frame is one chunk" {
    var buf: [8 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try kitty.shipFrame(&w, "B" ** 100, 7, 10, 5, false, .{ .col = 0, .row = 0, .cols = 80, .rows = 24 });
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1H\x1b_Ga=T,f=24,s=10,v=5,i=7,p=1,q=2,m=0,c=80,r=24,C=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "o=z") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b_G"));
}

test "freeImage deletes the image with its placement; wireBytes counts chunk framing" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try kitty.freeImage(&w, 7);
    try std.testing.expectEqualStrings("\x1b_Ga=d,d=I,i=7,q=2;\x1b\\", w.buffered());
    try std.testing.expectEqual(@as(usize, 10_000 + 40 * 3), kitty.wireBytes(10_000));
    try std.testing.expectEqual(@as(usize, 40), kitty.wireBytes(0));
}
