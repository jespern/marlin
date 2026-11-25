//! What the daemon sent, waiting for the TUI's main loop. It waits here
//! rather than in the vaxis event queue so that keys never queue behind a
//! backlog of output: the main loop handles everything else waiting (keys
//! first) before each line (`pump`). Ctrl+C under a flood of shell output
//! is the case this is for.
//!
//! Bounded like the vaxis queue it replaces: a full queue blocks the reader
//! thread, which leaves the rest in the socket and the daemon's flow control.
const std = @import("std");
const Io = std.Io;

pub const Item = union(enum) {
    /// One raw NDJSON line (gpa-owned; the consumer frees it).
    line: []u8,
    /// The reader stopped: a stable error name, after every line it read.
    gone: []const u8,
};

pub const DaemonLines = struct {
    pub const capacity = 512;

    mutex: Io.Mutex = .init,
    not_full: Io.Condition = .init,
    ring: [capacity]Item = undefined,
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,
    /// The consumer has been woken for what is queued: a burst of lines
    /// costs one wake-up. Cleared when the consumer finds the queue empty.
    woken: std.atomic.Value(bool) = .init(false),

    /// Reader thread: queue `item`, blocking while the queue is full.
    /// Returns true when the consumer must be woken for it.
    pub fn push(self: *DaemonLines, io: Io, item: Item) error{Closed}!bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (self.len == capacity and !self.closed) self.not_full.waitUncancelable(io, &self.mutex);
        if (self.closed) return error.Closed;
        self.ring[(self.head + self.len) % capacity] = item;
        self.len += 1;
        return !self.woken.swap(true, .acq_rel);
    }

    pub fn pop(self: *DaemonLines, io: Io) ?Item {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.popLocked(io);
    }

    /// Consumer: the next item, or null and the next push wakes it again.
    /// Both under one lock, so an item cannot arrive unannounced between.
    pub fn popOrRearm(self: *DaemonLines, io: Io) ?Item {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.popLocked(io) orelse {
            self.woken.store(false, .release);
            return null;
        };
    }

    /// Consumer, stopping early: true when items remain, which it must
    /// wake itself for; otherwise the next push wakes it.
    pub fn yield(self: *DaemonLines, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.len > 0) return true;
        self.woken.store(false, .release);
        return false;
    }

    fn popLocked(self: *DaemonLines, io: Io) ?Item {
        if (self.len == 0) return null;
        const item = self.ring[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        self.not_full.signal(io);
        return item;
    }

    /// Unblock and refuse the reader (shutdown); what is queued stays for
    /// `pop` to drain and free.
    pub fn close(self: *DaemonLines, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.closed = true;
        self.not_full.broadcast(io);
    }
};

/// Hand queued items to `ctx.item`, each after `ctx.others()` has handled
/// every other event waiting, until the queue is empty, `ctx.stop()`, or
/// `deadline` (so a flood still lets frames draw). Returns true when items
/// remain; the caller wakes itself again for them.
pub fn pump(lines: *DaemonLines, io: Io, ctx: anytype, deadline: Io.Timestamp) !bool {
    while (true) {
        try ctx.others();
        if (ctx.stop()) return lines.yield(io);
        const item = lines.popOrRearm(io) orelse return false;
        try ctx.item(item);
        if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline.nanoseconds) return lines.yield(io);
    }
}
