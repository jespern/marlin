//! Unit tests for shared.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in shared.zig.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_io = @import("../process_io.zig");
const nowMs = @import("../loop.zig").nowMs;

const shared = @import("shared.zig");
const max_event_line_bytes = shared.max_event_line_bytes;
const takeEventLine = shared.takeEventLine;

test {
    std.testing.refAllDecls(shared);
}

test "takeEventLine returns lines longer than the reader buffer intact" {
    const gpa = std.testing.allocator;
    const long = "{" ++ "x" ** 100 ++ "}\n";
    var buffer: [16]u8 = undefined;
    var tr: std.testing.Reader = .init(&buffer, &.{
        .{ .buffer = "short\n" },
        .{ .buffer = long },
        .{ .buffer = "tail-without-newline" },
    });
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    try std.testing.expectEqualStrings("short\n", (try takeEventLine(&tr.interface, gpa, &acc, max_event_line_bytes)).?);
    try std.testing.expectEqualStrings(long, (try takeEventLine(&tr.interface, gpa, &acc, max_event_line_bytes)).?);
    try std.testing.expectEqualStrings("tail-without-newline", (try takeEventLine(&tr.interface, gpa, &acc, max_event_line_bytes)).?);
    try std.testing.expect((try takeEventLine(&tr.interface, gpa, &acc, max_event_line_bytes)) == null);
}

test "takeEventLine drops one over-limit line and keeps reading" {
    const gpa = std.testing.allocator;
    const huge = "y" ** 200 ++ "\n";
    var buffer: [16]u8 = undefined;
    var tr: std.testing.Reader = .init(&buffer, &.{
        .{ .buffer = huge },
        .{ .buffer = "after\n" },
    });
    var acc: std.ArrayList(u8) = .empty;
    defer acc.deinit(gpa);
    try std.testing.expectError(error.LineTooLong, takeEventLine(&tr.interface, gpa, &acc, 64));
    try std.testing.expectEqualStrings("after\n", (try takeEventLine(&tr.interface, gpa, &acc, 64)).?);
    try std.testing.expect((try takeEventLine(&tr.interface, gpa, &acc, 64)) == null);
}
