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

test "stderr drain retains the latest bytes" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();

    var drain = shared.CcStderrDrain{
        .io = threaded.io(),
        .file = undefined,
    };
    drain.append("old");
    var padding: [4096]u8 = undefined;
    @memset(&padding, 'x');
    drain.append(&padding);
    drain.append("latest");

    try std.testing.expectEqual(@as(usize, drain.tail.len), drain.len);
    try std.testing.expect(std.mem.endsWith(u8, drain.tail[0..drain.len], "latest"));
    try std.testing.expect(std.mem.indexOf(u8, drain.tail[0..drain.len], "old") == null);
}

test "guest deadline excludes only time parked on the user during this run" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const approval = @import("../approval.zig");
    var clock: approval.ParkClock = .{};
    // Parking from an earlier run must not extend this one.
    clock.begin(io, 1);
    clock.end(io, 1 + 30 * 60 * 1000);
    var watcher = shared.CcWatcher.init(io, null, 0, &clock);
    const start = watcher.deadline_at - shared.guest_deadline_ms;
    try std.testing.expect(!watcher.deadlineHit(watcher.deadline_at - 1));
    try std.testing.expect(watcher.deadlineHit(watcher.deadline_at));
    // An hour on an ask_user question pushes the deadline out by an hour.
    clock.begin(io, start + 10);
    clock.end(io, start + 10 + 60 * 60 * 1000);
    try std.testing.expect(!watcher.deadlineHit(watcher.deadline_at));
    try std.testing.expect(watcher.deadlineHit(watcher.deadline_at + 60 * 60 * 1000));
    // Without a clock the ceiling is plain wall time.
    const bare = shared.CcWatcher.init(io, null, 0, null);
    try std.testing.expect(bare.deadlineHit(bare.deadline_at));
    try std.testing.expect(shared.guest_deadline_ms >= 4 * 60 * 60 * 1000);
}
