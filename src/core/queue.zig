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

        /// One FIFO; `head` skips popped items until the backing list is
        /// cleared or compacted.
        const Lane = struct {
            items: std.ArrayList(T) = .empty,
            head: usize = 0,

            fn empty(lane: *const Lane) bool {
                return lane.head == lane.items.items.len;
            }

            fn pop(lane: *Lane) T {
                const item = lane.items.items[lane.head];
                lane.head += 1;
                if (lane.head == lane.items.items.len) {
                    lane.items.clearRetainingCapacity();
                    lane.head = 0;
                } else if (lane.head >= 1024 and lane.head * 2 >= lane.items.items.len) {
                    const remaining = lane.items.items.len - lane.head;
                    std.mem.copyForwards(T, lane.items.items[0..remaining], lane.items.items[lane.head..]);
                    lane.items.shrinkRetainingCapacity(remaining);
                    lane.head = 0;
                }
                return item;
            }
        };

        mutex: Io.Mutex = .init,
        cond: Io.Condition = .init,
        lane: Lane = .{},
        /// Popped before `lane`: work a person is waiting on (their keys)
        /// must not queue behind a backlog. FIFO among itself.
        priority: Lane = .{},
        closed: bool = false,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.lane.items.deinit(self.gpa);
            self.priority.items.deinit(self.gpa);
        }

        /// Push from any thread. Returns error.Closed after close().
        pub fn push(self: *Self, io: Io, item: T) !void {
            return self.pushTo(io, &self.lane, item);
        }

        /// Push ahead of everything queued by `push`, after earlier
        /// priority items.
        pub fn pushPriority(self: *Self, io: Io, item: T) !void {
            return self.pushTo(io, &self.priority, item);
        }

        fn pushTo(self: *Self, io: Io, lane: *Lane, item: T) !void {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.closed) return error.Closed;
            try lane.items.append(self.gpa, item);
            self.cond.signal(io);
        }

        /// Blocking pop; null once closed AND drained.
        pub fn pop(self: *Self, io: Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            while (self.isEmpty()) {
                if (self.closed) return null;
                self.cond.waitUncancelable(io, &self.mutex);
            }
            return self.popLocked();
        }

        /// Non-blocking pop; null when empty (regardless of closed state).
        pub fn tryPop(self: *Self, io: Io) ?T {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (self.isEmpty()) return null;
            return self.popLocked();
        }

        fn isEmpty(self: *const Self) bool {
            return self.lane.empty() and self.priority.empty();
        }

        fn popLocked(self: *Self) T {
            return if (!self.priority.empty()) self.priority.pop() else self.lane.pop();
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
