//! Unit tests for effects.zig. Tests live beside the module they cover
//! (docs/TESTING.md).

const std = @import("std");

const effects = @import("effects.zig");
const Engine = effects.Engine;
const kinds = effects.kinds;

test {
    std.testing.refAllDecls(effects);
}

test "every kind constructs an engine for either backend" {
    const gpa = std.testing.allocator;
    inline for (kinds) |kind| {
        var pixel = Engine.init(gpa, kind, 3, .pixel);
        defer pixel.deinit();
        try std.testing.expectEqual(kind, pixel.kind());
        try std.testing.expectEqual(kind.backend() == .pixel, pixel.isPixel());
        try pixel.reset(80, 24, 3);
        pixel.tick();

        var cell = Engine.init(gpa, kind, 3, .cell);
        defer cell.deinit();
        try std.testing.expectEqual(kind.fallback(), cell.kind());
        try std.testing.expect(!cell.isPixel());
        try cell.reset(80, 24, 3);
        cell.tick();
    }
}
