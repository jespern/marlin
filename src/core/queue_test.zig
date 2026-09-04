//! Unit tests for queue.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in queue.zig.

const std = @import("std");
const Io = std.Io;

const queue_mod = @import("queue.zig");
const Mpsc = queue_mod.Mpsc;

test {
    std.testing.refAllDecls(queue_mod);
}

test "fifo order, close drains" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var q = Mpsc(u32).init(std.testing.allocator);
    defer q.deinit();
    try q.push(io, 1);
    try q.push(io, 2);
    q.close(io);
    try std.testing.expectEqual(@as(?u32, 1), q.pop(io));
    try std.testing.expectEqual(@as(?u32, 2), q.pop(io));
    try std.testing.expectEqual(@as(?u32, null), q.pop(io));
    try std.testing.expectError(error.Closed, q.push(io, 3));
}

test "cross-thread produce/consume" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var q = Mpsc(u64).init(std.testing.allocator);
    defer q.deinit();

    const Producer = struct {
        fn run(queue: *Mpsc(u64), pio: Io, base: u64) void {
            var i: u64 = 0;
            while (i < 100) : (i += 1) queue.push(pio, base + i) catch return;
        }
    };
    const t1 = try std.Thread.spawn(.{}, Producer.run, .{ &q, io, 0 });
    const t2 = try std.Thread.spawn(.{}, Producer.run, .{ &q, io, 1000 });
    t1.join();
    t2.join();
    q.close(io);

    var count: usize = 0;
    var sum: u64 = 0;
    while (q.pop(io)) |v| {
        count += 1;
        sum += v;
    }
    try std.testing.expectEqual(@as(usize, 200), count);
    try std.testing.expectEqual(@as(u64, 4950 + 104950), sum);
}

test "large backlog drains in FIFO order without shifting each pop" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var q = Mpsc(u32).init(std.testing.allocator);
    defer q.deinit();

    for (0..20_000) |i| try q.push(io, @intCast(i));
    for (0..20_000) |i| try std.testing.expectEqual(@as(?u32, @intCast(i)), q.pop(io));
    try std.testing.expectEqual(@as(usize, 0), q.head);
    try std.testing.expectEqual(@as(usize, 0), q.items.items.len);
}
