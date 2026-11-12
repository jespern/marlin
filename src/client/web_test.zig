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

const hosts: []const []const u8 = &.{ "marlin.example.com", "victory.local." };

fn ip(text: []const u8, port: u16) Io.net.IpAddress {
    return Io.net.IpAddress.parse(text, port) catch unreachable;
}

test "host gate: loopback and configured hosts pass, rebinding shapes do not" {
    try std.testing.expect(hostAllowed(hosts, "localhost:8377"));
    try std.testing.expect(hostAllowed(hosts, "localhost"));
    try std.testing.expect(hostAllowed(hosts, "127.0.0.1:8377"));
    try std.testing.expect(hostAllowed(hosts, "marlin.example.com"));
    try std.testing.expect(hostAllowed(hosts, "MARLIN.example.com:443"));
    try std.testing.expect(hostAllowed(hosts, "marlin.example.com."));
    try std.testing.expect(hostAllowed(hosts, "victory.local:8377"));
    try std.testing.expect(!hostAllowed(hosts, "attacker.example"));
    try std.testing.expect(!hostAllowed(hosts, "evil.marlin.example.com"));
    try std.testing.expect(!hostAllowed(hosts, "192.168.1.20:8377"));
    try std.testing.expect(!hostAllowed(hosts, null));
    try std.testing.expect(!hostAllowed(&.{}, "marlin.example.com"));
    try std.testing.expect(hostAllowed(&.{}, "127.0.0.1:9000"));
}

test "a configured host may carry the proxy's port; only the name is matched" {
    const with_port: []const []const u8 = &.{"marlin.example.com:8443"};
    try std.testing.expect(hostAllowed(with_port, "marlin.example.com:8443"));
    try std.testing.expect(hostAllowed(with_port, "marlin.example.com"));
    try std.testing.expect(!hostAllowed(with_port, "evil.example.com:8443"));
    try std.testing.expect(originAllowed(with_port, "https://marlin.example.com:8443"));
    try std.testing.expect(!originAllowed(with_port, "https://evil.example.com:8443"));
}

test "origin gate: absent or same-host origins pass, cross-site does not" {
    try std.testing.expect(originAllowed(hosts, null)); // same-origin / curl
    try std.testing.expect(originAllowed(hosts, "http://localhost:8377"));
    try std.testing.expect(originAllowed(hosts, "https://marlin.example.com"));
    try std.testing.expect(!originAllowed(hosts, "https://attacker.example"));
    try std.testing.expect(!originAllowed(hosts, "null"));
    try std.testing.expect(!originAllowed(hosts, "file://x"));
    try std.testing.expect(!originAllowed(&.{}, "https://marlin.example.com"));
}

test "only loopback asking for a loopback name skips pairing" {
    try std.testing.expect(web.isLocal(ip("127.0.0.1", 50000), "127.0.0.1:8377"));
    try std.testing.expect(web.isLocal(ip("::1", 50000), "localhost:8377"));
    // A LAN peer claiming a loopback Host is still remote.
    try std.testing.expect(!web.isLocal(ip("192.168.1.30", 50000), "localhost"));
    // A proxy on this machine forwarding a phone's request is remote too.
    try std.testing.expect(!web.isLocal(ip("127.0.0.1", 50000), "marlin.example.com"));
    try std.testing.expect(!web.isLocal(ip("127.0.0.1", 50000), null));
}

test "with a proxy configured, only it and loopback may connect" {
    const proxy = ip("192.168.1.1", 0);
    try std.testing.expect(web.peerAllowed(proxy, ip("192.168.1.1", 41000)));
    try std.testing.expect(web.peerAllowed(proxy, ip("::ffff:192.168.1.1", 41000)));
    try std.testing.expect(web.peerAllowed(proxy, ip("127.0.0.1", 41000)));
    try std.testing.expect(web.peerAllowed(proxy, ip("::1", 41000)));
    try std.testing.expect(!web.peerAllowed(proxy, ip("192.168.1.30", 41000)));
    try std.testing.expect(!web.peerAllowed(proxy, ip("fe80::1", 41000)));
    try std.testing.expect(web.peerAllowed(null, ip("192.168.1.30", 41000)));
}

test "access log names the forwarded client only when the proxy says so" {
    var buf: [64]u8 = undefined;
    const proxy = ip("192.168.1.1", 0);
    try std.testing.expectEqualStrings("100.101.1.2", web.clientAddress(&buf, proxy, ip("192.168.1.1", 41000), "100.101.1.2, 192.168.1.1"));
    // Anyone else's X-Forwarded-For is ignored.
    try std.testing.expectEqualStrings("192.168.1.30", web.clientAddress(&buf, proxy, ip("192.168.1.30", 41000), "1.2.3.4"));
    try std.testing.expectEqualStrings("127.0.0.1", web.clientAddress(&buf, null, ip("127.0.0.1", 41000), "1.2.3.4"));
    try std.testing.expectEqualStrings("192.168.1.1", web.clientAddress(&buf, proxy, ip("192.168.1.1", 41000), null));
    try std.testing.expectEqualStrings("::1", web.clientAddress(&buf, null, ip("::1", 41000), null));
}

test "device cookie is read from any position and set long-lived" {
    try std.testing.expectEqualStrings("abc", web.cookieValue("marlin_device=abc", "marlin_device").?);
    try std.testing.expectEqualStrings("abc", web.cookieValue("x=1; marlin_device=abc; y=2", "marlin_device").?);
    try std.testing.expect(web.cookieValue("xmarlin_device=abc", "marlin_device") == null);
    try std.testing.expect(web.cookieValue(null, "marlin_device") == null);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "marlin_device=t0k; Path=/; Max-Age=34560000; HttpOnly; SameSite=Lax; Secure",
        web.deviceCookie(&buf, "t0k", true),
    );
    try std.testing.expect(std.mem.indexOf(u8, web.deviceCookie(&buf, "t0k", false), "Secure") == null);
}

test "unpaired devices reach only the app shell and the pairing route" {
    for ([_][]const u8{ "/", "/index.html", "/manifest.webmanifest", "/icon-180.png", "/sw.js", "/connection" }) |path| {
        try std.testing.expect(web.publicRoute(.GET, path));
    }
    try std.testing.expect(web.publicRoute(.POST, "/pair"));
    for ([_][]const u8{ "/events", "/history", "/push/info" }) |path| {
        try std.testing.expect(!web.publicRoute(.GET, path));
    }
    try std.testing.expect(!web.publicRoute(.POST, "/send"));
    try std.testing.expect(!web.publicRoute(.POST, "/push/subscribe"));
    try std.testing.expect(!web.publicRoute(.GET, "/pair"));
}

test "access log timestamps are Common Log Format in UTC" {
    var buf: [40]u8 = undefined;
    // 2026-09-08 13:07:05 UTC
    try std.testing.expectEqualStrings("08/Sep/2026:13:07:05 +0000", web.clfTime(&buf, 1788872825));
    // Epoch zero and negative inputs stay well-formed.
    try std.testing.expectEqualStrings("01/Jan/1970:00:00:00 +0000", web.clfTime(&buf, 0));
    try std.testing.expectEqualStrings("01/Jan/1970:00:00:00 +0000", web.clfTime(&buf, -5));
}

test "the web bridge refuses every shell message, attaching and listing too" {
    const refused = [_]proto.ClientMsg{
        .{ .shell_open = .{ .cols = 80, .rows = 24 } },
        .{ .shell_attach = .{ .shell_id = 1, .cols = 80, .rows = 24 } },
        .{ .shell_detach = .{ .shell_id = 1 } },
        .{ .shell_list = .{} },
        .{ .shell_input = .{ .shell_id = 1, .data_base64 = "" } },
        .{ .shell_resize = .{ .shell_id = 1, .cols = 80, .rows = 24 } },
        .{ .shell_ack = .{ .shell_id = 1, .bytes = 0 } },
        .{ .shell_close = .{ .shell_id = 1 } },
    };
    for (refused) |msg| try std.testing.expect(!web.allowedOverWeb(msg));
    try std.testing.expect(web.allowedOverWeb(.{ .session_list = .{} }));
}
