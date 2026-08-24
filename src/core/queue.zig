//! A small blocking MPSC queue: agent turn threads (producers) push events;
//! the daemon dispatcher thread (consumer) pops them, persists, and fans out.
//! Io.Mutex + Io.Condition (Zig 0.16: sync primitives live on Io and take an
//! io instance; the default Threaded Io is threadsafe and shareable).
//! Items are values; convention: producer allocates, consumer frees.

const std = @import("std");
const Io = std.Io;

pub fn Mpsc(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        items: std.ArrayList(T) = .empty,
        closed: bool = false,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.gpa);
        }

        /// Push from any thread. Returns error.Closed after close().
        pub fn push(self: *Self, io: Io, item: T) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return error.Closed;
            try self.items.append(self.gpa, item);
            self.cond.signal(io);
        }

        /// Blocking pop; null once closed AND drained.
        pub fn pop(self: *Self, io: Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.items.items.len == 0) {
                if (self.closed) return null;
                self.cond.waitUncancelable(io, &self.mutex);
            }
            return self.items.orderedRemove(0);
        }

        /// Non-blocking pop; null when empty (regardless of closed state).
        pub fn tryPop(self: *Self, io: Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        /// Wake all waiters; subsequent pushes fail, pops drain then null.
        pub fn close(self: *Self, io: Io) void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            self.closed = true;
            self.cond.broadcast(io);
        }
    };
}

// ---------------------------------------------------------------- tests --

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
