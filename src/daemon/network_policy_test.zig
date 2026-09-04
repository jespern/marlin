//! Unit tests for network_policy.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in network_policy.zig.

const std = @import("std");
const Io = std.Io;
const http = @import("provider/http.zig");

const network_policy = @import("network_policy.zig");
const Policy = network_policy.Policy;
const catalog = network_policy.catalog;

test {
    std.testing.refAllDecls(network_policy);
}

test "domain rules cover subdomains and explicit allow overrides feeds" {
    const gpa = std.testing.allocator;
    var policy = Policy{ .gpa = gpa };
    defer policy.deinit();

    const feed = try gpa.dupe(u8,
        \\# sample
        \\bad.example
        \\0.0.0.0 malware.test
        \\
    );
    try policy.addFeedBuffer(0, feed);
    try policy.loaded_feeds.append(gpa, 0);
    try policy.addOverrides(&policy.explicit_allow, "safe.bad.example");
    try policy.addOverrides(&policy.explicit_deny, "always.blocked");

    try std.testing.expectEqualStrings("bad.example", policy.checkHost("BAD.EXAMPLE.").?.domain);
    try std.testing.expectEqualStrings("bad.example", policy.checkHost("deep.bad.example").?.domain);
    try std.testing.expect(policy.checkHost("safe.bad.example") == null);
    try std.testing.expectEqualStrings("explicit deny", policy.checkHost("x.always.blocked").?.source);
    try std.testing.expectEqualStrings("malware.test", policy.checkHost("malware.test").?.domain);
    try std.testing.expect(policy.checkHost("example.org") == null);
}

test "URL extraction checks only http hostnames" {
    const gpa = std.testing.allocator;
    var policy = Policy{ .gpa = gpa };
    defer policy.deinit();
    try policy.addOverrides(&policy.explicit_deny, "blocked.test");

    try std.testing.expect((try policy.checkUrl("https://sub.blocked.test/path?q=1")) != null);
    try std.testing.expect((try policy.checkUrl("http://allowed.test/")) == null);
    try std.testing.expectError(error.UnsupportedScheme, policy.checkUrl("file:///etc/passwd"));
}

test "catalog ids are unique and use https" {
    for (catalog, 0..) |feed, i| {
        try std.testing.expect(std.mem.startsWith(u8, feed.url, "https://"));
        for (catalog[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, feed.id, other.id));
    }
}
