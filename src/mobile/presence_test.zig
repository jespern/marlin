const std = @import("std");
const presence = @import("presence.zig");
const proto = @import("../core/proto.zig");
const config = @import("../core/config.zig");
test {
    std.testing.refAllDecls(presence);
}

test "terminal leases suppress all sessions, expire, and release independently" {
    var p: presence.Presence = .{};
    try std.testing.expect(!p.suppress(9, 100));
    try std.testing.expect(p.update(.terminal, 1, 0, true, 100));
    try std.testing.expect(p.update(.terminal, 2, 0, true, 200));
    try std.testing.expect(p.suppress(9, 30_099));
    try std.testing.expect(p.update(.terminal, 1, 0, false, 300));
    try std.testing.expect(p.suppress(9, 30_199));
    try std.testing.expect(!p.suppress(9, 30_200));
}
test "phone leases suppress only the visible session and release on hiding" {
    var p: presence.Presence = .{};
    try std.testing.expect(p.update(.phone, 1, 8, true, 10));
    try std.testing.expect(p.suppress(8, 20));
    try std.testing.expect(!p.suppress(9, 20));
    try std.testing.expect(p.update(.phone, 1, 9, true, 30));
    try std.testing.expect(!p.suppress(8, 40));
    try std.testing.expect(p.suppress(9, 40));
    try std.testing.expect(p.update(.phone, 1, 9, false, 50));
    try std.testing.expect(!p.suppress(9, 60));
}
test "lease table is bounded and expired slots can be reused" {
    var p: presence.Presence = .{};
    try std.testing.expect(!p.update(.phone, 0, 9, true, 1));
    for (1..129) |id| try std.testing.expect(p.update(.phone, id, 9, true, 1));
    try std.testing.expect(!p.update(.terminal, 129, 9, true, 1));
    try std.testing.expect(p.update(.terminal, 129, 9, true, 30_001));
    try std.testing.expect(p.suppress(10, 30_002));
}
test "presence wire roundtrip retains full width phone and session ids" {
    const wire = "{\"presence\":{\"kind\":\"phone\",\"active\":true,\"sid\":1874397504305914847,\"page_id\":9007199254740991}}";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try proto.decode(proto.ClientMsg, arena.allocator(), wire);
    const encoded = try proto.encode(arena.allocator(), decoded);
    try std.testing.expectEqualStrings(wire, std.mem.trimEnd(u8, encoded, "\n"));
}
test "web serves loopback by default; exposure beyond it and push stay opt in" {
    const cfg: config.Config = .{};
    try std.testing.expect(cfg.web_enabled);
    try std.testing.expect(!cfg.web_tailscale);
    try std.testing.expect(!cfg.web_push);
}
