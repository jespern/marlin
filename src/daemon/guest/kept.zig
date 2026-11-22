//! The daemon's side of a kept guest (keeper.zig): start one, or attach to
//! one a previous daemon started; read its stdout journal as a stream that
//! waits for more instead of ending; write its stdin; stop following it
//! (detach) when this daemon hands over, leaving the guest running.
const std = @import("std");
const Io = std.Io;
const keeper = @import("keeper.zig");

pub const Error = error{ KeeperFailed, KeeperUnavailable, OutOfMemory, NameTooLong };

/// A kept turn the daemon follows again after a restart.
pub const Attach = struct {
    /// The keeper's journal directory.
    dir: []const u8,
    /// Journal bytes the previous daemon had acted on: replayed silently.
    replay_until: u64,
    /// User messages already sent to the guest (prompt and steers).
    inputs_sent: u32,
    /// The turn's invocation round the guest runs in.
    round: u32,
};

/// Where a running kept turn is published, so the daemon can detach it.
/// A detach asked before the turn registers applies when it does.
pub const Slot = struct {
    mutex: Io.Mutex = .init,
    kept: ?*Kept = null,
    detach_pending: bool = false,

    pub fn set(self: *Slot, io: Io, k: ?*Kept) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.kept = k;
        if (k) |live| if (self.detach_pending) live.detach();
    }

    /// Detach the kept turn, now or when it registers. True when one runs.
    pub fn detach(self: *Slot, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.detach_pending = true;
        if (self.kept) |k| {
            k.detach();
            return true;
        }
        return false;
    }

    /// Detach the kept turn if one runs now; false (and nothing pending)
    /// when none does, or it is `parked` on a prompt it cannot leave.
    pub fn detachIfRunning(self: *Slot, io: Io, parked: bool) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const k = self.kept orelse return false;
        if (parked and !k.parked_detachable) return false;
        self.detach_pending = true;
        k.detach();
        return true;
    }

    pub fn running(self: *Slot, io: Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.kept != null;
    }
};

/// What a detached turn leaves for its successor, beside its journals.
pub const detach_name = "detach.json";
/// What the turn is, written when its keeper starts.
pub const turn_name = "turn.json";

pub const TurnFile = struct {
    sid: u64,
    turn_id: u64,
    backend: []const u8,
    round: u32,
    started_at_ms: i64,
};

pub const DetachFile = struct {
    consumed: u64,
    inputs_sent: u32,
};

/// Write `name` in `dir` whole (aside, then renamed into place).
pub fn writeJson(gpa: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(json);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}/{s}.tmp", .{ dir, name });
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = json });
    try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
}

/// The journal reader's buffer: the most of one event line read at once.
const read_buffer_bytes: usize = 512 * 1024;

pub const Kept = struct {
    gpa: std.mem.Allocator,
    io: Io,
    /// The turn's journal directory (owned).
    dir: []u8,
    /// The keeper's socket, -1 once it is gone.
    sock: std.posix.fd_t = -1,
    out_fd: std.posix.fd_t = -1,
    /// detach() writes here to wake a reader waiting for output.
    wake: [2]std.posix.fd_t = .{ -1, -1 },
    /// The guest's pid, which is also its process group.
    pid: std.posix.pid_t = 0,
    /// Set when this daemon started the keeper: reaped after the guest ends.
    keeper_child: ?std.process.Child = null,
    write_mutex: Io.Mutex = .init,
    detach_requested: std.atomic.Value(bool) = .init(false),
    /// The reader stopped because of detach(), not because the guest ended.
    detached: bool = false,
    /// The keeper said the guest ended (or vanished).
    exited: bool = false,
    /// The turn can be detached while parked on a user prompt (its guest
    /// asks through a bridge that retries), not only while running.
    parked_detachable: bool = false,
    reader: JournalReader = undefined,

    /// Start `argv` under a keeper writing its journals into `dir`, which is
    /// created. `cwd` and `environ_map` are the guest's.
    pub fn spawn(
        gpa: std.mem.Allocator,
        io: Io,
        marlin_exe: []const u8,
        dir: []const u8,
        argv: []const []const u8,
        cwd: []const u8,
        environ_map: ?*const std.process.Environ.Map,
    ) !*Kept {
        try Io.Dir.cwd().createDirPath(io, dir);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        _ = try keeper.socketPath(&path_buf, dir);
        const full = try gpa.alloc([]const u8, argv.len + 4);
        defer gpa.free(full);
        full[0] = marlin_exe;
        full[1] = "_keep";
        full[2] = dir;
        full[3] = "--";
        @memcpy(full[4..], argv);
        var child = std.process.spawn(io, .{
            .argv = full,
            .cwd = .{ .path = cwd },
            .environ_map = environ_map,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .inherit,
            .pgid = 0,
        }) catch return error.KeeperFailed;
        // Ready byte: the keeper listens and its guest runs.
        var ready: [1]u8 = undefined;
        const n = std.c.read(child.stdout.?.handle, &ready, 1);
        child.stdout.?.close(io);
        child.stdout = null;
        if (n != 1) {
            _ = child.wait(io) catch {};
            return error.KeeperFailed;
        }
        const self = try attachInner(gpa, io, dir);
        self.keeper_child = child;
        return self;
    }

    /// Follow a keeper a previous daemon started. A keeper that already
    /// ended leaves its journals: they are read to the end.
    pub fn attach(gpa: std.mem.Allocator, io: Io, dir: []const u8) !*Kept {
        return attachInner(gpa, io, dir);
    }

    fn attachInner(gpa: std.mem.Allocator, io: Io, dir: []const u8) !*Kept {
        const self = try gpa.create(Kept);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .dir = try gpa.dupe(u8, dir) };
        errdefer gpa.free(self.dir);
        const buffer = try gpa.alloc(u8, read_buffer_bytes);
        errdefer gpa.free(buffer);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const out_path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dir, keeper.out_name }, 0);
        self.out_fd = std.c.open(out_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (self.out_fd < 0) return error.KeeperUnavailable;
        errdefer _ = std.c.close(self.out_fd);
        var pipe: [2]std.posix.fd_t = undefined;
        if (std.c.pipe(&pipe) != 0) return error.KeeperFailed;
        for (pipe) |fd| _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        self.wake = pipe;
        self.connect() catch {
            // No keeper: the guest ended while no daemon followed it.
            self.exited = true;
        };
        if (self.pid == 0) self.pid = self.readPid();
        self.reader = .{ .kept = self, .interface = .{
            .vtable = &.{ .stream = JournalReader.stream, .readVec = JournalReader.readVec },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        } };
        return self;
    }

    fn connect(self: *Kept) !void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try keeper.socketPath(&path_buf, self.dir);
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.KeeperUnavailable;
        errdefer _ = std.c.close(fd);
        _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
        var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
        @memcpy(addr.path[0..path.len], path);
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) return error.KeeperUnavailable;
        // Greeting: `p<pid>\n`. Notes may follow in the same read.
        var greet: [64]u8 = undefined;
        var len: usize = 0;
        while (std.mem.indexOfScalar(u8, greet[0..len], '\n') == null) {
            if (len == greet.len) return error.KeeperUnavailable;
            const n = std.c.read(fd, greet[len..].ptr, greet.len - len);
            if (n < 0 and std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            if (n <= 0) return error.KeeperUnavailable;
            len += @intCast(n);
        }
        const nl = std.mem.indexOfScalar(u8, greet[0..len], '\n').?;
        if (nl < 2 or greet[0] != 'p') return error.KeeperUnavailable;
        self.pid = std.fmt.parseInt(std.posix.pid_t, greet[1..nl], 10) catch return error.KeeperUnavailable;
        for (greet[nl + 1 .. len]) |note| if (note == keeper.note_exit) {
            self.exited = true;
        };
        self.sock = fd;
    }

    /// A keeper that is gone left no pid; a guest's pid is only needed to
    /// signal it, and a gone keeper's guest has ended.
    fn readPid(_: *Kept) std.posix.pid_t {
        return 0;
    }

    /// One line to the guest's stdin. `bytes` holds no newline.
    pub fn writeLine(self: *Kept, tag: u8, bytes: []const u8) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.sock < 0) return error.KeeperUnavailable;
        try sendAll(self.sock, &.{tag});
        try sendAll(self.sock, bytes);
        try sendAll(self.sock, "\n");
    }

    pub fn closeStdin(self: *Kept) void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        if (self.sock >= 0) sendAll(self.sock, &.{ keeper.tag_close, '\n' }) catch {};
    }

    /// Stop following the guest at the next line boundary, leaving it
    /// running for whichever daemon attaches next.
    pub fn detach(self: *Kept) void {
        self.detach_requested.store(true, .release);
        _ = std.c.write(self.wake[1], "!", 1);
    }

    pub fn detachRequested(self: *const Kept) bool {
        return self.detach_requested.load(.acquire);
    }

    /// Journal bytes handed out by the reader: the offset a successor
    /// replays to before it acts on what it reads.
    pub fn consumed(self: *const Kept) u64 {
        const r = &self.reader.interface;
        return self.reader.file_pos - (r.end - r.seek);
    }

    /// The guest's exit code from the journal, null when it was signalled
    /// or has not ended.
    pub fn exitCode(self: *Kept) ?i64 {
        var buf: [64]u8 = undefined;
        const text = readSmall(self.dir, keeper.exit_name, &buf) orelse return null;
        return keeper.parseExit(text);
    }

    /// The last bytes the guest wrote to stderr.
    pub fn stderrTail(self: *Kept, buf: []u8) []const u8 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ self.dir, keeper.err_name }, 0) catch return "";
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return "";
        defer _ = std.c.close(fd);
        const size = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (size <= 0) return "";
        const start: i64 = @max(0, size - @as(i64, @intCast(buf.len)));
        const n = std.c.pread(fd, buf.ptr, buf.len, start);
        return if (n > 0) buf[0..@intCast(n)] else "";
    }

    /// SIGTERM the guest's group, give it `grace_ms` to end, then SIGKILL.
    /// True once the keeper reported the end.
    pub fn terminate(self: *Kept, grace_ms: u32) bool {
        if (self.exited) return true;
        if (self.pid > 0) _ = std.c.kill(-self.pid, .TERM);
        if (self.waitExit(grace_ms)) return true;
        if (self.pid > 0) _ = std.c.kill(-self.pid, .KILL);
        return self.waitExit(5000);
    }

    /// Wait up to `timeout_ms` for the keeper to report the guest's end.
    pub fn waitExit(self: *Kept, timeout_ms: u32) bool {
        const deadline = nowMs(self.io) + timeout_ms;
        while (!self.exited) {
            const left = deadline - nowMs(self.io);
            if (left <= 0) return false;
            self.waitNote(@intCast(left)) catch return self.exited;
        }
        return true;
    }

    /// One wait on the keeper's socket (and the wake pipe). error.Detached
    /// when detach() woke it.
    fn waitNote(self: *Kept, timeout_ms: i32) error{Detached}!void {
        if (self.sock < 0) {
            self.exited = true;
            return;
        }
        var fds = [_]std.c.pollfd{
            .{ .fd = self.sock, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = self.wake[0], .events = std.c.POLL.IN, .revents = 0 },
        };
        const n = std.c.poll(&fds, fds.len, timeout_ms);
        if (n <= 0) return;
        if (fds[1].revents != 0 and self.detachRequested()) return error.Detached;
        if (fds[0].revents == 0) return;
        var notes: [256]u8 = undefined;
        const got = std.c.read(self.sock, &notes, notes.len);
        if (got < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) return;
            self.exited = true;
            return;
        }
        if (got == 0) {
            // The keeper is gone: whatever it journaled is all there is.
            self.exited = true;
            return;
        }
        for (notes[0..@intCast(got)]) |note| if (note == keeper.note_exit) {
            self.exited = true;
        };
    }

    /// Reap a keeper this daemon started, once it has reported the end.
    pub fn reap(self: *Kept) void {
        if (self.keeper_child) |*child| {
            _ = child.wait(self.io) catch {};
            self.keeper_child = null;
        }
    }

    pub fn deinit(self: *Kept) void {
        if (self.sock >= 0) _ = std.c.close(self.sock);
        if (self.out_fd >= 0) _ = std.c.close(self.out_fd);
        for (self.wake) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        // A keeper still running belongs to the next daemon; one that
        // ended is reaped so it leaves no zombie.
        if (self.exited) self.reap();
        self.gpa.free(self.reader.interface.buffer);
        self.gpa.free(self.dir);
        self.gpa.destroy(self);
    }
};

/// `out`, read as a stream that waits for the keeper instead of ending
/// while the guest runs.
pub const JournalReader = struct {
    kept: *Kept,
    interface: Io.Reader,
    file_pos: u64 = 0,

    /// Straight into `w`, as a file reader does. A line longer than the
    /// buffer comes here with a writer that refuses: that refusal is how
    /// the caller learns to take the line in pieces (takeEventLine), so it
    /// must not turn into a failed read.
    fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *JournalReader = @fieldParentPtr("interface", r);
        const dest = limit.slice(try w.writableSliceGreedy(1));
        const n = try self.readSome(dest);
        w.advance(n);
        return n;
    }

    fn readVec(r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        _ = data;
        const self: *JournalReader = @fieldParentPtr("interface", r);
        if (r.end == r.buffer.len) {
            if (r.seek == 0) return 0; // full: the caller streams instead
            const len = r.end - r.seek;
            std.mem.copyForwards(u8, r.buffer[0..len], r.buffer[r.seek..r.end]);
            r.seek = 0;
            r.end = len;
        }
        r.end += try self.readSome(r.buffer[r.end..]);
        return 0;
    }

    /// Some journal bytes into `dest`, waiting for the guest to write them.
    fn readSome(self: *JournalReader, dest: []u8) Io.Reader.Error!usize {
        const k = self.kept;
        if (dest.len == 0) return 0;
        while (true) {
            const n = std.c.pread(k.out_fd, dest.ptr, dest.len, @intCast(self.file_pos));
            if (n < 0) {
                if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
                return error.ReadFailed;
            }
            if (n > 0) {
                self.file_pos += @intCast(n);
                return @intCast(n);
            }
            // Caught up. The keeper notes its end only after journaling
            // everything, so one more read above has already seen the rest.
            if (k.exited) return error.EndOfStream;
            if (k.detachRequested()) {
                k.detached = true;
                return error.ReadFailed;
            }
            k.waitNote(-1) catch {
                k.detached = true;
                return error.ReadFailed;
            };
        }
    }
};

fn sendAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return error.KeeperUnavailable;
        }
        if (n == 0) return error.KeeperUnavailable;
        rest = rest[@intCast(n)..];
    }
}

fn readSmall(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dir, name }, 0) catch return null;
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf.ptr, buf.len);
    return if (n > 0) buf[0..@intCast(n)] else null;
}

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

/// Remove a finished turn's journal directory.
pub fn removeDir(io: Io, dir: []const u8) void {
    Io.Dir.cwd().deleteTree(io, dir) catch {};
}

/// An Io.Writer onto a kept guest's stdin: each complete line goes to the
/// keeper. While `replaying`, lines are dropped: the daemon that read the
/// journal first already sent them.
pub const LineWriter = struct {
    gpa: std.mem.Allocator,
    kept: *Kept,
    replaying: bool,
    pending: std.ArrayList(u8) = .empty,
    writer: Io.Writer,

    pub fn init(k: *Kept, replaying: bool, buffer: []u8) LineWriter {
        return .{ .gpa = k.gpa, .kept = k, .replaying = replaying, .writer = .{
            .vtable = &.{ .drain = drain },
            .buffer = buffer,
        } };
    }

    /// Safe after the Kept is gone (a detached turn frees it first).
    pub fn deinit(self: *LineWriter) void {
        self.pending.deinit(self.gpa);
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *LineWriter = @alignCast(@fieldParentPtr("writer", w));
        const gpa = self.gpa;
        self.pending.appendSlice(gpa, w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.pending.appendSlice(gpa, bytes) catch return error.WriteFailed;
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| self.pending.appendSlice(gpa, pattern) catch return error.WriteFailed;
        written += pattern.len * splat;
        while (std.mem.indexOfScalar(u8, self.pending.items, '\n')) |nl| {
            if (!self.replaying)
                self.kept.writeLine(keeper.tag_write, self.pending.items[0..nl]) catch return error.WriteFailed;
            const rest = self.pending.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.pending.items[0..rest], self.pending.items[nl + 1 ..]);
            self.pending.shrinkRetainingCapacity(rest);
        }
        return written;
    }
};
