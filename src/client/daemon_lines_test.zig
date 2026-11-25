//! Unit tests for daemon_lines.zig.
const std = @import("std");
const daemon_lines = @import("daemon_lines.zig");
const DaemonLines = daemon_lines.DaemonLines;
const Item = daemon_lines.Item;

/// The main loop's side: keys waiting in its own queue, lines handled.
const Loop = struct {
    lines: *DaemonLines,
    keys: std.ArrayList(u8) = .empty,
    log: std.ArrayList(u8) = .empty,
    quit_after: ?usize = null,

    pub fn others(self: *Loop) !void {
        for (self.keys.items) |k| try self.log.appendSlice(std.testing.allocator, &.{ 'k', k, ' ' });
        self.keys.clearRetainingCapacity();
    }

    pub fn stop(self: *Loop) bool {
        return if (self.quit_after) |n| std.mem.count(u8, self.log.items, "l") >= n else false;
    }

    pub fn item(self: *Loop, it: Item) !void {
        switch (it) {
            .line => |line| {
                defer std.testing.allocator.free(line);
                try self.log.appendSlice(std.testing.allocator, "l");
                try self.log.appendSlice(std.testing.allocator, line);
                try self.log.append(std.testing.allocator, ' ');
                // A key pressed while this line was handled.
                if (std.mem.eql(u8, line, "1")) try self.keys.append(std.testing.allocator, 'C');
            },
            .gone => |reason| {
                try self.log.appendSlice(std.testing.allocator, "gone:");
                try self.log.appendSlice(std.testing.allocator, reason);
            },
        }
    }

    fn deinit(self: *Loop) void {
        self.keys.deinit(std.testing.allocator);
        self.log.deinit(std.testing.allocator);
    }
};

fn pushLine(lines: *DaemonLines, io: std.Io, text: []const u8) !bool {
    return lines.push(io, .{ .line = try std.testing.allocator.dupe(u8, text) });
}

fn far(io: std.Io) std.Io.Timestamp {
    return .{ .nanoseconds = std.Io.Timestamp.now(io, .awake).nanoseconds + std.time.ns_per_hour };
}

test "a key pressed behind a backlog of lines is handled before the next line" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var lines: DaemonLines = .{};
    for ([_][]const u8{ "0", "1", "2", "3" }) |text| _ = try pushLine(&lines, io, text);
    _ = try lines.push(io, .{ .gone = "EndOfStream" });
    var loop: Loop = .{ .lines = &lines };
    defer loop.deinit();
    try loop.keys.append(std.testing.allocator, 'a');

    try std.testing.expect(!try daemon_lines.pump(&lines, io, &loop, far(io)));
    // Ctrl+C ('C') pressed during line 1 goes before lines 2 and 3; the
    // reader's end comes after every line it read.
    try std.testing.expectEqualStrings("ka l0 l1 kC l2 l3 gone:EndOfStream", loop.log.items);
}

test "a burst of lines wakes the consumer once, and an empty queue rearms it" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var lines: DaemonLines = .{};
    try std.testing.expect(try pushLine(&lines, io, "0"));
    try std.testing.expect(!try pushLine(&lines, io, "1"));
    var loop: Loop = .{ .lines = &lines };
    defer loop.deinit();
    try std.testing.expect(!try daemon_lines.pump(&lines, io, &loop, far(io)));
    try std.testing.expect(try pushLine(&lines, io, "2"));
    try std.testing.expect(!try daemon_lines.pump(&lines, io, &loop, far(io)));
    try std.testing.expectEqualStrings("l0 l1 kC l2 ", loop.log.items);
}

test "past its deadline the pump yields with lines left, and stays woken for them" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var lines: DaemonLines = .{};
    for ([_][]const u8{ "0", "1", "2" }) |text| _ = try pushLine(&lines, io, text);
    var loop: Loop = .{ .lines = &lines };
    defer loop.deinit();
    try std.testing.expect(try daemon_lines.pump(&lines, io, &loop, .{ .nanoseconds = 0 }));
    try std.testing.expectEqualStrings("l0 ", loop.log.items);
    // The caller re-posts its own wake-up; a push must not post another.
    try std.testing.expect(!try pushLine(&lines, io, "3"));
    try std.testing.expect(!try daemon_lines.pump(&lines, io, &loop, far(io)));
    try std.testing.expectEqualStrings("l0 l1 kC l2 l3 ", loop.log.items);
}

test "close unblocks a reader waiting on a full queue, and what is queued still drains" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var lines: DaemonLines = .{};
    for (0..DaemonLines.capacity) |_| _ = try pushLine(&lines, io, "x");
    const Reader = struct {
        fn run(l: *DaemonLines, i: std.Io, result: *?anyerror) void {
            const extra = std.testing.allocator.dupe(u8, "y") catch unreachable;
            _ = l.push(i, .{ .line = extra }) catch |err| {
                std.testing.allocator.free(extra);
                result.* = err;
            };
        }
    };
    var result: ?anyerror = null;
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ &lines, io, &result });
    try io.sleep(.fromMilliseconds(50), .awake);
    lines.close(io);
    reader.join();
    try std.testing.expectEqual(@as(?anyerror, error.Closed), result);
    var drained: usize = 0;
    while (lines.pop(io)) |it| {
        std.testing.allocator.free(it.line);
        drained += 1;
    }
    try std.testing.expectEqual(@as(usize, DaemonLines.capacity), drained);
}
