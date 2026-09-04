//! Unit tests for fetch.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in fetch.zig.

const std = @import("std");
const http = @import("../provider/http.zig");
const network_policy = @import("../network_policy.zig");

const fetch_mod = @import("fetch.zig");
const fetch = fetch_mod.fetch;
const htmlToText = fetch_mod.htmlToText;
const resolveRedirect = fetch_mod.resolveRedirect;

test {
    std.testing.refAllDecls(fetch_mod);
}

test "htmlToText strips tags, keeps links, decodes entities" {
    const gpa = std.testing.allocator;
    const html =
        \\<!doctype html><html><head><title>T</title><style>.x{}</style></head>
        \\<body><h1>Hello &amp; welcome</h1><script>var x = "<p>";</script>
        \\<p>See <a href="https://example.com">the docs</a> now.</p></body></html>
    ;
    const text = try htmlToText(gpa, html);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hello & welcome") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "the docs (https://example.com)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "var x") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".x{}") == null);
}

test "fetch rejects non-http urls" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const out = try fetch(gpa, threaded.io(), null, .{ .url = "file:///etc/passwd" }, null, null, null);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "error:"));
}

test "fetch blocks an explicit denied hostname before network I/O" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var policy = network_policy.Policy.init(gpa, io, &environ, .{ .deny = "blocked.test" });
    defer policy.deinit();

    const out = try fetch(gpa, io, &environ, .{ .url = "https://sub.blocked.test/secret" }, &policy, null, null);
    defer gpa.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "error: network policy blocked"));
    try std.testing.expect(std.mem.indexOf(u8, out, "explicit deny") != null);
}

test "relative redirect resolution preserves authority" {
    const gpa = std.testing.allocator;
    const resolved = try resolveRedirect(gpa, "https://example.com/a/b", "../next?q=1");
    defer gpa.free(resolved);
    try std.testing.expectEqualStrings("https://example.com/next?q=1", resolved);
}
