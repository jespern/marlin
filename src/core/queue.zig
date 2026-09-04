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
        head: usize = 0,
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
            while (self.head == self.items.items.len) {
                if (self.closed) return null;
                self.cond.waitUncancelable(io, &self.mutex);
            }
            return self.popLocked();
        }

        /// Non-blocking pop; null when empty (regardless of closed state).
        pub fn tryPop(self: *Self, io: Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.head == self.items.items.len) return null;
            return self.popLocked();
        }

        fn popLocked(self: *Self) T {
            const item = self.items.items[self.head];
            self.head += 1;
            if (self.head == self.items.items.len) {
                self.items.clearRetainingCapacity();
                self.head = 0;
            } else if (self.head >= 1024 and self.head * 2 >= self.items.items.len) {
                const remaining = self.items.items.len - self.head;
                std.mem.copyForwards(T, self.items.items[0..remaining], self.items.items[self.head..]);
                self.items.shrinkRetainingCapacity(remaining);
                self.head = 0;
            }
            return item;
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
