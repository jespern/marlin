//! Unit tests for starfield.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in starfield.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const starfield = @import("starfield.zig");
const Engine = starfield.Engine;
const Star = starfield.Star;

test {
    std.testing.refAllDecls(starfield);
}

test "starfield is deterministic and recycles near stars" {
    var one = Engine.init(std.testing.allocator, 99);
    defer one.deinit();
    var two = Engine.init(std.testing.allocator, 99);
    defer two.deinit();
    try one.reset(80, 24, 99);
    try two.reset(80, 24, 99);
    try std.testing.expectEqualSlices(Star, &one.stars, &two.stars);
    one.stars[0].z = 0.01;
    two.stars[0].z = 0.01;
    one.tick();
    two.tick();
    try std.testing.expect(one.stars[0].z > 0.9);
    try std.testing.expectEqualSlices(Star, &one.stars, &two.stars);
}
