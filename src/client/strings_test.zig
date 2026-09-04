//! Unit tests for strings.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in strings.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const strings = @import("strings.zig");
const Engine = strings.Engine;
const StringState = strings.StringState;

test {
    std.testing.refAllDecls(strings);
}

test "dancing strings are deterministic and phases advance" {
    var one = Engine.init(std.testing.allocator, 42);
    defer one.deinit();
    var two = Engine.init(std.testing.allocator, 42);
    defer two.deinit();
    try one.reset(80, 24, 42);
    try two.reset(80, 24, 42);
    try std.testing.expectEqualSlices(StringState, &one.strings, &two.strings);
    const phase = one.strings[0].phase;
    one.tick();
    two.tick();
    try std.testing.expect(one.strings[0].phase != phase);
    try std.testing.expectEqualSlices(StringState, &one.strings, &two.strings);
    const advanced_phase = one.strings[0].phase;
    try one.resize(120, 40);
    try std.testing.expectEqual(advanced_phase, one.strings[0].phase);
    try std.testing.expect(one.strings[0].baseline > 0);
}
