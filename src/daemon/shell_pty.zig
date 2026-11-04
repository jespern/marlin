//! Experimental shell tab (`!!`): interactive shells on pseudo-terminals,
//! each owned by one client connection.
//!
//! The dispatcher thread spawns and closes shells; one reader thread per
//! shell polls the PTY master, hands output to the sink, and reaps the shell
//! when it exits. Output past `ack_window` unacknowledged bytes pauses the
//! reader, so a runaway program can never fill a client's outbox.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const c = std.c;

/// Unacknowledged output after which the reader stops draining the PTY.
pub const ack_window: usize = 1024 * 1024;
const read_chunk: usize = 16 * 1024;
/// Poll timeout: how quickly the reader notices closing or a shell exit
/// that leaves the PTY held open by a background job.
const poll_ms: c_int = 100;

const tiocswinsz: c_ulong = if (builtin.os.tag == .linux) std.os.linux.T.IOCSWINSZ else 0x80087467;
const tiocsctty: c_ulong = if (builtin.os.tag == .linux) std.os.linux.T.IOCSCTTY else 0x20007461;

extern "c" fn posix_openpt(oflag: c.O) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn fork() c.pid_t;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

pub const Status = struct { code: ?i32 = null, signal: ?i32 = null };

/// Callbacks run on the shell's reader thread.
pub const Sink = struct {
    ctx: *anyopaque,
    output: *const fn (ctx: *anyopaque, shell: *Shell, bytes: []const u8) void,
    exited: *const fn (ctx: *anyopaque, shell: *Shell, status: Status) void,
};

pub const Options = struct {
    /// Executable to run, and its argv (argv[0] included).
    path: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    environ: *const std.process.Environ.Map,
    cols: u16,
    rows: u16,
};

pub const Shell = struct {
    gpa: std.mem.Allocator,
    io: Io,
    id: u64,
    client_id: u64,
    master: c_int,
    pid: c.pid_t,
    sink: Sink,
    thread: ?std.Thread = null,
    closing: std.atomic.Value(bool) = .init(false),
    reaped: std.atomic.Value(bool) = .init(false),
    unacked: std.atomic.Value(usize) = .init(0),

    pub fn spawn(gpa: std.mem.Allocator, io: Io, id: u64, client_id: u64, opts: Options, sink: Sink) !*Shell {
        // Everything the child needs is prepared before fork: between fork
        // and exec only async-signal-safe calls are allowed.
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path_z = try arena.dupeSentinel(u8, opts.path, 0);
        const cwd_z = try arena.dupeSentinel(u8, opts.cwd, 0);
        const argv_z = try arena.allocSentinel(?[*:0]const u8, opts.argv.len, null);
        for (opts.argv, argv_z) |arg, *slot| slot.* = try arena.dupeSentinel(u8, arg, 0);
        const envp_z = try environBlock(arena, opts.environ);

        const master = posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (master < 0) return error.PtyUnavailable;
        errdefer _ = c.close(master);
        if (grantpt(master) != 0 or unlockpt(master) != 0) return error.PtyUnavailable;
        _ = c.fcntl(master, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        // macOS rejects terminal ioctls on the master until a slave is open,
        // so the parent opens it, sizes the terminal, and hands it to the
        // child, which makes it its controlling terminal.
        const slave = c.open(ptsname(master) orelse return error.PtyUnavailable, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (slave < 0) return error.PtyUnavailable;
        defer _ = c.close(slave);
        setWinsize(master, opts.cols, opts.rows);

        const pid = fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) childExec(master, slave, cwd_z, path_z, argv_z, envp_z);

        const self = gpa.create(Shell) catch |err| {
            _ = c.kill(-pid, .KILL);
            _ = c.waitpid(pid, null, 0);
            return err;
        };
        self.* = .{ .gpa = gpa, .io = io, .id = id, .client_id = client_id, .master = master, .pid = pid, .sink = sink };
        self.thread = std.Thread.spawn(.{}, readLoop, .{self}) catch |err| {
            self.thread = null;
            self.destroy();
            return err;
        };
        return self;
    }

    /// Hang up the shell, stop the reader, reap, and free. Dispatcher only.
    pub fn destroy(self: *Shell) void {
        self.closing.store(true, .release);
        if (!self.reaped.load(.acquire)) _ = c.kill(-self.pid, .HUP);
        if (self.thread) |thread| thread.join();
        _ = c.close(self.master);
        if (!self.reaped.load(.acquire)) {
            // The reader is gone, so reaping here cannot race it. A shell
            // that ignores SIGHUP gets SIGKILL rather than a stuck daemon.
            if (c.waitpid(self.pid, null, c.W.NOHANG) != self.pid) {
                _ = c.kill(-self.pid, .KILL);
                _ = c.waitpid(self.pid, null, 0);
            }
        }
        self.gpa.destroy(self);
    }

    pub fn write(self: *Shell, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = c.write(self.master, rest.ptr, rest.len);
            if (n < 0) return error.PtyWriteFailed;
            rest = rest[@intCast(n)..];
        }
    }

    pub fn resize(self: *Shell, cols: u16, rows: u16) void {
        setWinsize(self.master, cols, rows);
    }

    pub fn acknowledge(self: *Shell, bytes: u64) void {
        const n: usize = @intCast(@min(bytes, std.math.maxInt(usize)));
        var current = self.unacked.load(.acquire);
        while (self.unacked.cmpxchgWeak(current, current -| n, .acq_rel, .acquire)) |seen| current = seen;
    }

    fn readLoop(self: *Shell) void {
        var buf: [read_chunk]u8 = undefined;
        while (!self.closing.load(.acquire)) {
            if (self.unacked.load(.acquire) >= ack_window) {
                self.io.sleep(.fromMilliseconds(5), .awake) catch {};
                continue;
            }
            var fds = [_]c.pollfd{.{ .fd = self.master, .events = c.POLL.IN, .revents = 0 }};
            const ready = c.poll(&fds, 1, poll_ms);
            if (ready > 0) {
                if (fds[0].revents & c.POLL.IN != 0) {
                    const n = c.read(self.master, &buf, buf.len);
                    if (n > 0) {
                        self.emit(buf[0..@intCast(n)]);
                        continue;
                    }
                }
                // EOF, or EIO once every slave descriptor closed (Linux).
                break;
            }
            // Idle: the shell may have exited while a background job holds
            // the PTY open, which never produces EOF.
            if (self.tryReap()) |status| return self.finish(status);
        }
        while (!self.closing.load(.acquire)) {
            if (self.tryReap()) |status| return self.finish(status);
            self.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
    }

    fn emit(self: *Shell, bytes: []const u8) void {
        _ = self.unacked.fetchAdd(bytes.len, .acq_rel);
        self.sink.output(self.sink.ctx, self, bytes);
    }

    fn finish(self: *Shell, status: Status) void {
        // Output written just before exit is still buffered in the master.
        var buf: [read_chunk]u8 = undefined;
        while (true) {
            var fds = [_]c.pollfd{.{ .fd = self.master, .events = c.POLL.IN, .revents = 0 }};
            if (c.poll(&fds, 1, 0) <= 0 or fds[0].revents & c.POLL.IN == 0) break;
            const n = c.read(self.master, &buf, buf.len);
            if (n <= 0) break;
            self.emit(buf[0..@intCast(n)]);
        }
        if (!self.closing.load(.acquire)) self.sink.exited(self.sink.ctx, self, status);
    }

    fn tryReap(self: *Shell) ?Status {
        var raw: c_int = 0;
        if (c.waitpid(self.pid, &raw, c.W.NOHANG) != self.pid) return null;
        self.reaped.store(true, .release);
        const status: u32 = @bitCast(raw);
        if (c.W.IFEXITED(status)) return .{ .code = c.W.EXITSTATUS(status) };
        if (c.W.IFSIGNALED(status)) return .{ .signal = @intCast(@backingInt(c.W.TERMSIG(status))) };
        return .{};
    }
};

fn setWinsize(fd: c_int, cols: u16, rows: u16) void {
    const ws: c.winsize = .{ .row = @max(rows, 1), .col = @max(cols, 1), .xpixel = 0, .ypixel = 0 };
    _ = ioctl(fd, tiocswinsz, &ws);
}

fn environBlock(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![:null]?[*:0]const u8 {
    var entries: std.ArrayList(?[*:0]const u8) = .empty;
    var it = environ.iterator();
    while (it.next()) |entry| {
        try entries.append(arena, try arena.printSentinel("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0));
    }
    return entries.toOwnedSliceSentinel(arena, null);
}

/// The forked child: become a session leader with the PTY as controlling
/// terminal, restore default signal handling, and exec. Never returns.
fn childExec(
    master: c_int,
    slave: c_int,
    cwd: [*:0]const u8,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    _ = c.setsid();
    if (ioctl(slave, tiocsctty, @as(c_int, 0)) != 0) c._exit(126);
    // dup2 clears close-on-exec on the standard descriptors.
    for ([_]c_int{ 0, 1, 2 }) |fd| _ = c.dup2(slave, fd);
    if (slave > 2) _ = c.close(slave);
    _ = c.close(master);

    // Ignored signals survive exec, and the daemon ignores SIGPIPE: without
    // this, `yes | head` in the shell fails with EPIPE instead of exiting.
    const default_action: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = std.posix.sigemptyset(), .flags = 0 };
    for ([_]c.SIG{ .PIPE, .INT, .QUIT, .TSTP, .TTIN, .TTOU, .CHLD, .HUP, .TERM }) |sig| std.posix.sigaction(sig, &default_action, null);
    const empty = std.posix.sigemptyset();
    std.posix.sigprocmask(c.SIG.SETMASK, &empty, null);

    if (c.chdir(cwd) != 0) _ = c.chdir("/");
    _ = c.execve(path, argv, envp);
    c._exit(127);
}
