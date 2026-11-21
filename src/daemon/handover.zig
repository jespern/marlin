//! Graceful daemon handover (`reboot{handover:true}`). The running daemon,
//! once its sessions are paused, starts its own executable as a successor
//! and hands it what cannot be reopened: the listening socket, the instance
//! lock, and every running shell's PTY. They are inherited file descriptors;
//! the numbers, plus each shell's terminal snapshot, travel as one JSON line
//! over a socketpair that stays open as the control channel. The successor
//! reports `ready`, then `arrived` for each client token presented to it;
//! the predecessor exits only once every client it moved has arrived (or the
//! deadline passes), so no connection is dropped on the floor. Before
//! `ready`, any failure leaves the predecessor in charge as if nothing
//! happened.
//!
//! The predecessor never writes the store after the successor starts: it
//! paused every session first and rejects client requests from then on.
const std = @import("std");
const Io = std.Io;
const block = @import("../core/block.zig");

pub const version: u32 = 1;

/// Largest state line: shell snapshots carry scrollback (16 MiB each at most).
pub const max_state_bytes: usize = 512 * 1024 * 1024;
const max_report_bytes: usize = 64 * 1024;

/// One running shell, as the successor adopts it.
pub const ShellState = struct {
    id: u64,
    sid: u64,
    pid: i32,
    master_fd: i32,
    cols: u16,
    rows: u16,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    cwd: []const u8,
    created_at_ms: i64,
    ran: ?[]const u8 = null,
    commands: []const block.ShellCommand = &.{},
    /// The whole terminal (shell_host.Host.snapshot), base64.
    snapshot_base64: []const u8,
};

pub const State = struct {
    version: u32 = version,
    listen_fd: i32,
    lock_fd: i32,
    predecessor_pid: i32,
    next_shell_id: u64,
    shells: []const ShellState = &.{},
};

/// Successor → predecessor.
pub const Report = union(enum) {
    /// Store open and migrated, listener and shells adopted: send clients.
    ready: struct {},
    /// A client presented this token (handover_arrived) after resubscribing.
    arrived: struct { token: []const u8 },
    /// Startup failed before `ready`; the predecessor stays in charge.
    failed: struct { msg: []const u8 },
};

/// Predecessor → successor, after the state line.
pub const Command = union(enum) {
    /// The predecessor's web companion has exited: the port is free.
    web_released: struct {},
    /// Every moved client arrived (or the deadline passed); exiting now.
    done: struct {},
};

/// A fresh client token: 16 random bytes, hex.
pub fn newToken(io: Io) [32]u8 {
    var raw: [16]u8 = undefined;
    io.random(&raw);
    return std.fmt.bytesToHex(raw, .lower);
}

/// A connected pair of stream sockets, both close-on-exec: one end stays,
/// the other is inherited by the successor alone.
pub fn controlPair() ![2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SocketpairFailed;
    for (fds) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    return fds;
}

pub fn file(fd: std.posix.fd_t) Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Start `exe` as the successor daemon. `control_fd` and `inherit` cross
/// exec at their current numbers; everything else this process holds stays
/// behind (close-on-exec). The successor gets its own process group, so the
/// predecessor's exit does not take it along.
pub fn spawnSuccessor(
    gpa: std.mem.Allocator,
    io: Io,
    exe: []const u8,
    environ: *const std.process.Environ.Map,
    control_fd: std.posix.fd_t,
    inherit: []const std.posix.fd_t,
) !std.process.Child {
    var files: std.ArrayList(Io.File) = .empty;
    defer files.deinit(gpa);
    try files.append(gpa, file(control_fd));
    for (inherit) |fd| try files.append(gpa, file(fd));
    var fd_buf: [16]u8 = undefined;
    const fd_text = try std.fmt.bufPrint(&fd_buf, "{d}", .{control_fd});
    return std.process.spawn(io, .{
        .argv = &.{ exe, "daemon", "--handover-fd", fd_text },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
        .inherit_files = files.items,
        .pgid = 0,
    });
}

/// Encode `value` as one JSON line and write it whole.
pub fn send(gpa: std.mem.Allocator, fd: std.posix.fd_t, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(json);
    try writeAll(fd, json);
    try writeAll(fd, "\n");
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return error.ControlWriteFailed;
        }
        if (n == 0) return error.ControlWriteFailed;
        rest = rest[@intCast(n)..];
    }
}

/// Reads newline-delimited messages from a control socket. Blocking; one
/// reader per channel.
pub const LineReader = struct {
    fd: std.posix.fd_t,
    buf: std.ArrayList(u8) = .empty,
    /// Bytes already returned, dropped on the next call.
    consumed: usize = 0,

    pub fn deinit(self: *LineReader, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
    }

    /// The next complete line already buffered, without its newline (valid
    /// until the next call); null when none is.
    pub fn take(self: *LineReader) ?[]const u8 {
        if (self.consumed > 0) {
            const remaining = self.buf.items.len - self.consumed;
            std.mem.copyForwards(u8, self.buf.items[0..remaining], self.buf.items[self.consumed..]);
            self.buf.shrinkRetainingCapacity(remaining);
            self.consumed = 0;
        }
        const nl = std.mem.indexOfScalar(u8, self.buf.items, '\n') orelse return null;
        self.consumed = nl + 1;
        return self.buf.items[0..nl];
    }

    /// One read into the buffer; false at EOF.
    pub fn fill(self: *LineReader, gpa: std.mem.Allocator, limit: usize) !bool {
        if (self.buf.items.len >= limit) return error.ControlLineTooLong;
        try self.buf.ensureUnusedCapacity(gpa, 64 * 1024);
        while (true) {
            const spare = self.buf.unusedCapacitySlice();
            const n = std.c.read(self.fd, spare.ptr, spare.len);
            if (n < 0) {
                if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
                return error.ControlReadFailed;
            }
            if (n == 0) return false;
            self.buf.items.len += @intCast(n);
            return true;
        }
    }

    /// The next line, reading as needed (blocking); null at EOF.
    pub fn next(self: *LineReader, gpa: std.mem.Allocator, limit: usize) !?[]const u8 {
        while (true) {
            if (self.take()) |line| return line;
            if (!try self.fill(gpa, limit)) return null;
        }
    }
};

pub fn parseReport(arena: std.mem.Allocator, line: []const u8) !Report {
    return std.json.parseFromSliceLeaky(Report, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn parseCommand(arena: std.mem.Allocator, line: []const u8) !Command {
    return std.json.parseFromSliceLeaky(Command, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// The successor's first read: the state line from its predecessor.
pub fn readState(gpa: std.mem.Allocator, reader: *LineReader) !std.json.Parsed(State) {
    const line = (try reader.next(gpa, max_state_bytes)) orelse return error.HandoverStateMissing;
    const parsed = try std.json.parseFromSlice(State, gpa, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value.version != version) return error.HandoverVersionMismatch;
    return parsed;
}

/// Which tokens a predecessor still waits for.
pub const Pending = struct {
    tokens: std.ArrayList([32]u8) = .empty,

    pub fn deinit(self: *Pending, gpa: std.mem.Allocator) void {
        self.tokens.deinit(gpa);
    }

    pub fn add(self: *Pending, gpa: std.mem.Allocator, token: [32]u8) !void {
        try self.tokens.append(gpa, token);
    }

    /// True when `token` was pending (and no longer is).
    pub fn arrive(self: *Pending, token: []const u8) bool {
        for (self.tokens.items, 0..) |pending, i| if (std.mem.eql(u8, &pending, token)) {
            _ = self.tokens.swapRemove(i);
            return true;
        };
        return false;
    }

    pub fn empty(self: *const Pending) bool {
        return self.tokens.items.len == 0;
    }
};
