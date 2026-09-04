//! Unit tests for ids.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in ids.zig.

const std = @import("std");
const Io = std.Io;

const ids = @import("ids.zig");

test {
    std.testing.refAllDecls(ids);
}

test "id layout leaves 20 random bits" {
    const millis: u64 = 1_700_000_000_000;
    const id = (millis << 20) | 0xABCDE;
    try std.testing.expectEqual(millis, id >> 20);
    try std.testing.expectEqual(@as(u64, 0xABCDE), id & 0xFFFFF);
}
