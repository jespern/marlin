//! Unit tests for web.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in web.zig.

const std = @import("std");
const Io = std.Io;
const config = @import("../core/config.zig");
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

const web = @import("web.zig");
const hostAllowed = web.hostAllowed;
const originAllowed = web.originAllowed;
const queryU64 = web.queryU64;
const sidFromQuery = web.sidFromQuery;

test {
    std.testing.refAllDecls(web);
}

test "sid query parsing accepts u64 and rejects garbage" {
    try std.testing.expectEqual(@as(?u64, 42), sidFromQuery("/events?sid=42"));
    try std.testing.expectEqual(
        @as(?u64, 1874397504305914847),
        sidFromQuery("/events?a=b&sid=1874397504305914847"),
    );
    try std.testing.expectEqual(@as(?u64, null), sidFromQuery("/events"));
    try std.testing.expectEqual(@as(?u64, null), sidFromQuery("/events?sid=abc"));
    try std.testing.expectEqual(@as(?u64, null), sidFromQuery("/events?side=1"));
    try std.testing.expectEqual(@as(?u64, 99), queryU64("/history?sid=42&before=99", "before"));
    try std.testing.expectEqual(@as(?u64, null), queryU64("/history?sid=42&before=nope", "before"));
}

test "host gate: loopback and tailnet pass, rebinding shapes do not" {
    const tail: ?[]const u8 = "box.tail1234.ts.net";
    try std.testing.expect(hostAllowed(tail, "localhost:8377"));
    try std.testing.expect(hostAllowed(tail, "localhost"));
    try std.testing.expect(hostAllowed(tail, "127.0.0.1:8377"));
    try std.testing.expect(hostAllowed(tail, "box.tail1234.ts.net"));
    try std.testing.expect(hostAllowed(tail, "BOX.tail1234.ts.net:443"));
    try std.testing.expect(hostAllowed(tail, "box.tail1234.ts.net."));
    try std.testing.expect(!hostAllowed(tail, "attacker.example"));
    try std.testing.expect(!hostAllowed(tail, "evil.box.tail1234.ts.net"));
    try std.testing.expect(!hostAllowed(tail, null));
    try std.testing.expect(!hostAllowed(null, "box.tail1234.ts.net"));
    try std.testing.expect(hostAllowed(null, "127.0.0.1:9000"));
}

test "origin gate: absent or same-host origins pass, cross-site does not" {
    const tail: ?[]const u8 = "box.tail1234.ts.net";
    try std.testing.expect(originAllowed(tail, null)); // same-origin / curl
    try std.testing.expect(originAllowed(tail, "http://localhost:8377"));
    try std.testing.expect(originAllowed(tail, "https://box.tail1234.ts.net"));
    try std.testing.expect(!originAllowed(tail, "https://attacker.example"));
    try std.testing.expect(!originAllowed(tail, "null"));
    try std.testing.expect(!originAllowed(tail, "file://x"));
    try std.testing.expect(!originAllowed(null, "https://box.tail1234.ts.net"));
}
