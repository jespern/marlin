//! What both guest runtimes share and the native loop does not need: the
//! per-thread delegate error detail, the environment pass-down helper, and
//! the subprocess supervision pair (wall-clock/cancel watcher, stderr drain).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const process_io = @import("../process_io.zig");
const nowMs = @import("../loop.zig").nowMs;

/// Failure detail for the most recent Delegate* error on THIS thread,
/// mirroring http.lastTransportCause: Zig errors carry no payload, and a
/// bare "DelegateFailed" reaching the user is a shrug where a diagnosis
/// ("claude code error: Not logged in · Please run /login") exists.
threadlocal var delegate_error_buf: [256]u8 = undefined;
threadlocal var delegate_error_len: usize = 0;

pub fn lastDelegateErrorNote() ?[]const u8 {
    return if (delegate_error_len == 0) null else delegate_error_buf[0..delegate_error_len];
}

/// Called at the start of every guest turn: no stale detail from an earlier
/// turn on this thread may explain a new failure.
pub fn clearDelegateError() void {
    delegate_error_len = 0;
}

pub fn setDelegateError(text: []const u8) void {
    delegate_error_len = @min(text.len, delegate_error_buf.len);
    @memcpy(delegate_error_buf[0..delegate_error_len], text[0..delegate_error_len]);
}

/// Put a key only when the parent environment didn't set it — the operator's
/// own value always wins over Marlin's pass-down defaults.
pub fn putEnvDefault(map: *std.process.Environ.Map, key: []const u8, value: []const u8) bool {
    if (map.get(key) != null) return true;
    map.put(key, value) catch return false;
    return true;
}

pub const CcWatcher = struct {
    io: Io,
    cancel: ?*const std.atomic.Value(bool),
    group: std.posix.pid_t,
    deadline_at: i64,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    pub fn run(w: *CcWatcher) void {
        while (!w.done.load(.acquire)) {
            const cancel_hit = if (w.cancel) |c| c.load(.acquire) else false;
            const deadline_hit = nowMs(w.io) >= w.deadline_at;
            if (cancel_hit or deadline_hit) {
                if (cancel_hit) w.cancelled.store(true, .release);
                if (deadline_hit) w.timed_out.store(true, .release);
                process_io.terminateProcessGroup(w.io, w.group, 500);
                return;
            }
            w.io.sleep(.fromMilliseconds(200), .awake) catch return;
        }
    }
};

pub const CcStderrDrain = struct {
    io: Io,
    file: Io.File,
    tail: [4096]u8 = undefined,
    len: usize = 0,

    pub fn run(d: *CcStderrDrain) void {
        var buf: [4096]u8 = undefined;
        var reader = d.file.reader(d.io, &buf);
        while (true) {
            // A line longer than `buf` is not the end of the stream: keep
            // its head for the tail buffer and carry on, or the child blocks
            // on a full stderr pipe once this thread stops draining it.
            const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    const head = reader.interface.buffered();
                    const room = d.tail.len - d.len;
                    const n = @min(room, head.len);
                    @memcpy(d.tail[d.len .. d.len + n], head[0..n]);
                    d.len += n;
                    reader.interface.toss(head.len);
                    continue;
                },
                else => return,
            };
            const room = d.tail.len - d.len;
            const n = @min(room, line.len);
            @memcpy(d.tail[d.len .. d.len + n], line[0..n]);
            d.len += n;
        }
    }
};

/// Upper bound for one guest stdout event line. Claude Code's stream-json
/// embeds whole-file contents in Edit results, so a single line is routinely
/// larger than the edited file; this only stops a runaway stream from
/// exhausting memory.
pub const max_event_line_bytes: usize = 64 * 1024 * 1024;

pub const EventLineError = error{
    ReadFailed,
    OutOfMemory,
    /// One line exceeded the limit and was discarded; the stream continues.
    LineTooLong,
};

/// Take the next newline-terminated stdout line from a guest, however long.
///
/// `takeDelimiterInclusive` fails with StreamTooLong as soon as a line
/// outgrows the reader's buffer. Treating that as end of stream (the old
/// behaviour) silently stopped consuming Claude Code's events the first time
/// it edited a file larger than the buffer: the child kept working blind
/// for minutes and the turn ended as "exited without a result". Instead the
/// overflow is accumulated in `acc` and the complete line returned.
///
/// Returns null at end of stream. A trailing unterminated line is returned
/// as-is. On LineTooLong the offending line has been consumed through its
/// newline so the caller can simply continue.
pub fn takeEventLine(
    reader: *Io.Reader,
    gpa: Allocator,
    acc: *std.ArrayList(u8),
    limit: usize,
) EventLineError!?[]const u8 {
    acc.clearRetainingCapacity();
    while (true) {
        const chunk = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                const full = reader.buffered();
                if (acc.items.len + full.len > limit) {
                    reader.toss(full.len);
                    _ = reader.discardDelimiterInclusive('\n') catch {};
                    return error.LineTooLong;
                }
                try acc.appendSlice(gpa, full);
                reader.toss(full.len);
                continue;
            },
            error.EndOfStream => {
                const rest = reader.buffered();
                if (acc.items.len == 0 and rest.len == 0) return null;
                try acc.appendSlice(gpa, rest);
                reader.toss(rest.len);
                return acc.items;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        if (acc.items.len == 0) return chunk;
        if (acc.items.len + chunk.len > limit) return error.LineTooLong;
        try acc.appendSlice(gpa, chunk);
        return acc.items;
    }
}
