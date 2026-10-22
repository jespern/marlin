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
    const runtime: u64 = 12 * 60 * 60 * 1000;
    var watcher = shared.CcWatcher.init(io, null, 0, &clock, runtime);
    const start = watcher.started_at;
    const deadline = start + @as(i64, @intCast(runtime));
    try std.testing.expect(!watcher.deadlineHit(deadline - 1));
    try std.testing.expect(watcher.deadlineHit(deadline));
    // An hour on an ask_user question pushes the deadline out by an hour.
    clock.begin(io, start + 10);
    clock.end(io, start + 10 + 60 * 60 * 1000);
    try std.testing.expect(!watcher.deadlineHit(deadline));
    try std.testing.expect(watcher.deadlineHit(deadline + 60 * 60 * 1000));
    // Without a clock the ceiling is plain wall time.
    const bare = shared.CcWatcher.init(io, null, 0, null, runtime);
    try std.testing.expect(bare.deadlineHit(bare.started_at + @as(i64, @intCast(runtime))));
}

test "guest runtime changes live and default restores the original allowance" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var live = std.atomic.Value(u64).init(shared.default_runtime);
    var watcher = shared.CcWatcher.init(threaded.io(), null, 0, null, 1000);
    watcher.max_runtime_live = &live;
    const later = watcher.started_at + 2000;
    try std.testing.expect(watcher.deadlineHit(later));
    live.store(12 * 60 * 60 * 1000, .release);
    try std.testing.expect(!watcher.deadlineHit(later));
    live.store(0, .release);
    try std.testing.expect(!watcher.deadlineHit(std.math.maxInt(i64)));
    live.store(shared.default_runtime, .release);
    try std.testing.expect(watcher.deadlineHit(later));
    const note = try shared.deadlineNote(std.testing.allocator, "claude code", 43_200_000);
    defer std.testing.allocator.free(note);
    try std.testing.expect(std.mem.indexOf(u8, note, "12h") != null);
}

test "disabled guest deadline still cancels its subprocess" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sleep", "5" }, .pgid = 0 });
    defer child.kill(io);
    var cancel = std.atomic.Value(bool).init(true);
    var watcher = shared.CcWatcher.init(io, &cancel, child.id.?, null, 0);
    shared.CcWatcher.run(&watcher);
    const term = try child.wait(io);
    try std.testing.expect(term == .signal);
    try std.testing.expect(watcher.cancelled.load(.acquire));
    try std.testing.expect(!watcher.timed_out.load(.acquire));
}
