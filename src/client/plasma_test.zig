//! Unit tests for plasma.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in plasma.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const plasma = @import("plasma.zig");
const Engine = plasma.Engine;

test {
    std.testing.refAllDecls(plasma);
}

test "plasma advances deterministically" {
    var one = Engine.init(std.testing.allocator, 7);
    defer one.deinit();
    var two = Engine.init(std.testing.allocator, 7);
    defer two.deinit();
    try one.reset(80, 24, 7);
    try two.reset(80, 24, 7);
    one.tick();
    two.tick();
    try std.testing.expectEqual(one.frame, two.frame);
    try std.testing.expectEqual(one.seed_phase, two.seed_phase);
}
