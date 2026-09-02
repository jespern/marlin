//! What both guest runtimes share and the native loop does not need: the
//! per-thread delegate error detail, the environment pass-down helper, and
//! the subprocess supervision pair (wall-clock/cancel watcher, stderr drain).

const std = @import("std");
const Io = std.Io;
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
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            const room = d.tail.len - d.len;
            const n = @min(room, line.len);
            @memcpy(d.tail[d.len .. d.len + n], line[0..n]);
            d.len += n;
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
