//! Unit tests for visual_effect.zig. Tests live beside the module they
//! cover (docs/TESTING.md).

const std = @import("std");

const visual_effect = @import("visual_effect.zig");
const Backend = visual_effect.Backend;
const Kind = visual_effect.Kind;
const usage_list = visual_effect.usage_list;

test {
    std.testing.refAllDecls(visual_effect);
}

test "visual effect names parse case-insensitively" {
    try std.testing.expectEqual(Kind.strings, Kind.parse("STRINGS").?);
    try std.testing.expectEqual(Kind.stars, Kind.parse("stars").?);
    try std.testing.expectEqual(Kind.tunnel, Kind.parse("Tunnel").?);
    try std.testing.expect(Kind.parse("nope") == null);
}

test "backends, fallbacks, and the generated usage list" {
    try std.testing.expectEqual(Backend.cell, Kind.matrix.backend());
    try std.testing.expectEqual(Backend.pixel, Kind.tunnel.backend());
    try std.testing.expectEqual(Backend.pixel, Kind.pacman.backend());
    try std.testing.expect(Kind.pacman.cellCapable() and Kind.matrix.cellCapable() and !Kind.tunnel.cellCapable());
    try std.testing.expectEqual(Kind.pacman, Kind.pacman.fallback());
    try std.testing.expect(Kind.pacman.fullScreenOnly());
    try std.testing.expect(!Kind.matrix.fullScreenOnly());
    try std.testing.expectEqual(Kind.plasma, Kind.tunnel.fallback());
    try std.testing.expectEqual(Kind.stars, Kind.horizon.fallback());
    try std.testing.expectEqual(Kind.stars, Kind.shadowbox.fallback());
    try std.testing.expectEqual(Kind.matrix, Kind.matrix.fallback());
    try std.testing.expectEqualStrings("matrix|strings|stars|plasma|pacman|tunnel|metaballs|horizon|demo|shadowbox", usage_list);
}
