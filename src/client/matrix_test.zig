//! Unit tests for matrix.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in matrix.zig.

const std = @import("std");
const vaxis = @import("vaxis");
const effect = @import("effect.zig");

const matrix = @import("matrix.zig");
const Column = matrix.Column;
const Engine = matrix.Engine;

test {
    std.testing.refAllDecls(matrix);
}

test "engine is deterministic and advances independent columns" {
    const gpa = std.testing.allocator;
    var one = Engine.init(gpa, 42);
    defer one.deinit();
    var two = Engine.init(gpa, 42);
    defer two.deinit();
    try one.reset(20, 12, 42);
    try two.reset(20, 12, 42);
    try std.testing.expectEqualSlices(Column, one.columns, two.columns);
    for (0..12) |_| {
        one.tick();
        two.tick();
    }
    try std.testing.expectEqualSlices(Column, one.columns, two.columns);
    var differing = false;
    for (one.columns[1..], one.columns[0 .. one.columns.len - 1]) |a, b| {
        if (a.head != b.head or a.trail != b.trail or a.step_frames != b.step_frames) differing = true;
    }
    try std.testing.expect(differing);
}

test "resize preserves existing columns" {
    const gpa = std.testing.allocator;
    var engine = Engine.init(gpa, 7);
    defer engine.deinit();
    try engine.reset(4, 10, 7);
    const first = engine.columns[0];
    try engine.resize(8, 14);
    try std.testing.expectEqual(first, engine.columns[0]);
    try std.testing.expectEqual(@as(usize, 8), engine.columns.len);
}
