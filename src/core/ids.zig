//! Id generation for sessions, blocks, turns.
//!
//! Ids are u64: (unix_millis << 20) | random low bits — sortable by creation
//! time, unique enough for a single daemon, and cheap. The store enforces
//! uniqueness; on the astronomically unlikely collision, regenerate.
//!
//! Zig 0.16: both wall-clock time and randomness come from the `Io` instance.

const std = @import("std");
const Io = std.Io;

pub fn next(io: Io) u64 {
    const ts = Io.Timestamp.now(io, .real);
    const millis: u64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
    var buf: [4]u8 = undefined;
    io.random(&buf);
    const rand20: u64 = std.mem.readInt(u32, &buf, .little) & 0xFFFFF;
    return (millis << 20) | rand20;
}

test "id layout leaves 20 random bits" {
    const millis: u64 = 1_700_000_000_000;
    const id = (millis << 20) | 0xABCDE;
    try std.testing.expectEqual(millis, id >> 20);
    try std.testing.expectEqual(@as(u64, 0xABCDE), id & 0xFFFFF);
}
