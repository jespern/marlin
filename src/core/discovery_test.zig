const std = @import("std");
const discovery = @import("discovery.zig");

test "TXT records round-trip: length-prefixed key=value, lookups by key" {
    var buf: [128]u8 = undefined;
    const txt = try discovery.buildTxt(&buf, &.{
        .{ .key = "v", .value = "0.1.4" },
        .{ .key = "user", .value = "jespern" },
        .{ .key = "sessions", .value = "3" },
    });
    try std.testing.expectEqualStrings("\x07v=0.1.4\x0cuser=jespern\x0asessions=3", txt);
    try std.testing.expectEqualStrings("0.1.4", discovery.txtValue(txt, "v").?);
    try std.testing.expectEqualStrings("jespern", discovery.txtValue(txt, "user").?);
    try std.testing.expectEqualStrings("3", discovery.txtValue(txt, "sessions").?);
    try std.testing.expect(discovery.txtValue(txt, "port") == null);
    try std.testing.expect(discovery.txtValue(txt, "") == null);
}

test "TXT edge cases: empty value, truncated record, entry without '=', too long" {
    var buf: [16]u8 = undefined;
    const txt = try discovery.buildTxt(&buf, &.{.{ .key = "user", .value = "" }});
    try std.testing.expectEqualStrings("", discovery.txtValue(txt, "user").?);
    try std.testing.expect(discovery.txtValue("\x09v=0.1", "v") == null); // claims 9 bytes, has 5
    try std.testing.expect(discovery.txtValue("\x04flag\x03v=1", "v") != null); // boolean-style entry skipped
    try std.testing.expectError(error.NoSpaceLeft, discovery.buildTxt(&buf, &.{.{ .key = "sessions", .value = "1234567890" }}));
    var big: [300]u8 = undefined;
    try std.testing.expectError(error.TxtEntryTooLong, discovery.buildTxt(&big, &.{.{ .key = "k", .value = "x" ** 255 }}));
}

test "remote targets: user@host, host alone, trailing dot stripped" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("jespern@victory.local", try discovery.remoteTarget(&buf, "jespern", discovery.stripTrailingDot("victory.local.")));
    try std.testing.expectEqualStrings("victory.local", try discovery.remoteTarget(&buf, "", "victory.local"));
    try std.testing.expectEqualStrings("", discovery.stripTrailingDot(""));
}

test "the table sorts by name, widens to content, and ends each row with the --remote line" {
    var peers = [_]discovery.Peer{
        .{ .name = "victory", .host = "victory.local", .port = 22, .version = "0.1.4", .user = "jespern", .sessions = "3" },
        .{ .name = "living-room", .host = "living-room.local", .port = 22, .version = "0.1.3", .user = "", .sessions = "12" },
    };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try discovery.renderTable(&w, &peers);
    const out = w.buffered();
    var lines = std.mem.splitScalar(u8, out, '\n');
    const header = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, header, "NAME         HOST               SESSIONS  VERSION  ATTACH"));
    const first = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, first, "living-room  living-room.local  12        0.1.3    marlin --remote living-room.local"));
    const second = lines.next().?;
    try std.testing.expect(std.mem.startsWith(u8, second, "victory      victory.local      3         0.1.4    marlin --remote jespern@victory.local"));
    try std.testing.expectEqualStrings("", lines.next().?);
    try std.testing.expect(lines.next() == null);
}
