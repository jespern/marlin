//! `marlin _keep <dir> -- <argv…>`: the keeper of one guest invocation
//! (`claude -p`, `codex app-server`). It starts the guest and outlives the
//! daemon that asked for it, so a daemon restart (graceful handover) or a
//! daemon crash does not end the guest's turn.
//!
//! Everything the guest says is journaled in `dir`, and everything said to it:
//!
//!   out   the guest's stdout, byte for byte
//!   err   its stderr
//!   in    what the daemon sent, as protocol lines (tag byte, payload)
//!   exit  its exit status ("exited N" or "signal N"), once it has ended
//!
//! and its socket, for one daemon at a time, is `socketPath(dir)`.
//!
//! A daemon reads `out` from the start and follows it; the socket only tells
//! it when there is more (`d`) and when the guest has ended (`x`), so a
//! successor rebuilds its view by replaying the journal, then follows live.
//! On connect the keeper sends `p<guest pid>\n` first.
//!
//! Daemon → keeper, one line each: `w<bytes>\n` writes `<bytes>\n` to the
//! guest's stdin (`s` the same, marking a steering message, which a
//! replaying daemon must not send again); `c\n` closes the guest's stdin.
//! A daemon that disconnects without `c` leaves stdin open for the next.
//!
//! The keeper exits once the guest has ended and its output is journaled.
//! It never deletes `dir`: the daemon that finishes the turn does.
const std = @import("std");
const Io = std.Io;

pub const out_name = "out";
pub const err_name = "err";
pub const in_name = "in";
pub const exit_name = "exit";
pub const socket_name = "s";

pub const tag_write: u8 = 'w';
pub const tag_steer: u8 = 's';
pub const tag_close: u8 = 'c';
pub const note_data: u8 = 'd';
pub const note_exit: u8 = 'x';

/// Most bytes of one daemon → keeper line.
const max_line_bytes: usize = 64 * 1024 * 1024;

const Keeper = struct {
    io: Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    /// The connected daemon's socket, or -1.
    client: std.atomic.Value(i32) = .init(-1),
    stdin_fd: std.atomic.Value(i32) = .init(-1),
    in_journal: std.posix.fd_t = -1,
    ended: std.atomic.Value(bool) = .init(false),
    pid: std.posix.pid_t = 0,

    /// One byte to the daemon, if one is listening; a full or closed socket
    /// loses nothing, since the daemon reads the journal itself.
    fn note(self: *Keeper, byte: u8) void {
        const fd = self.client.load(.acquire);
        if (fd < 0) return;
        _ = std.c.write(fd, @ptrCast(&byte), 1);
    }

    fn closeStdin(self: *Keeper) void {
        const fd = self.stdin_fd.swap(-1, .acq_rel);
        if (fd >= 0) _ = std.c.close(fd);
    }
};

const Copy = struct {
    keeper: *Keeper,
    from: std.posix.fd_t,
    to: std.posix.fd_t,

    fn run(c: *Copy) void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = std.c.read(c.from, &buf, buf.len);
            if (n < 0) {
                if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
                return;
            }
            if (n == 0) return;
            writeAll(c.to, buf[0..@intCast(n)]) catch return;
            c.keeper.note(note_data);
        }
    }
};

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

fn openJournal(dir: []const u8, name: []const u8) !std.posix.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "{s}/{s}", .{ dir, name }, 0);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.JournalOpenFailed;
    return fd;
}

/// The keeper's socket: `/tmp/marlin-<uid>/k-<journal dir name>`. Sockets
/// live apart from the journals because a Unix socket path is short (104
/// bytes on macOS) and a state directory need not be. The folder is the
/// user's alone (0700, owned by them), as tmux keeps its sockets.
pub fn socketPath(buf: []u8, dir: []const u8) ![:0]const u8 {
    const uid = std.c.getuid();
    var folder_buf: [64]u8 = undefined;
    const folder = try std.fmt.bufPrintSentinel(&folder_buf, "/tmp/marlin-{d}", .{uid}, 0);
    if (std.c.mkdir(folder, 0o700) != 0 and std.c._errno().* != @backingInt(std.c.E.EXIST)) return error.SocketDirUnavailable;
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, folder, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return error.SocketDirUnavailable;
    if ((st.mode & std.c.S.IFMT) != std.c.S.IFDIR or st.uid != uid or (st.mode & 0o077) != 0) return error.SocketDirUnsafe;
    const path = try std.fmt.bufPrintSentinel(buf, "{s}/k-{s}", .{ folder, std.fs.path.basename(dir) }, 0);
    if (path.len >= @typeInfo(@FieldType(std.c.sockaddr.un, "path")).array.len) return error.NameTooLong;
    return path;
}

fn listen(dir: []const u8) !std.posix.fd_t {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try socketPath(&path_buf, dir);
    _ = std.c.unlink(path);
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
    var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) return error.BindFailed;
    if (std.c.listen(fd, 4) != 0) return error.ListenFailed;
    return fd;
}

/// Serve one daemon connection: greet with the pid, then forward its lines.
fn serve(k: *Keeper, fd: std.posix.fd_t) void {
    var greet_buf: [32]u8 = undefined;
    const greet = std.fmt.bufPrint(&greet_buf, "p{d}\n", .{k.pid}) catch return;
    writeAll(fd, greet) catch return;
    k.client.store(fd, .release);
    defer {
        _ = k.client.cmpxchgStrong(fd, -1, .acq_rel, .acquire);
        _ = std.c.close(fd);
    }
    // Ended while it connected: say so now, it may have missed the note.
    if (k.ended.load(.acquire)) k.note(note_exit);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(k.gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
            return;
        }
        if (n == 0) return;
        var rest = buf[0..@intCast(n)];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            line.appendSlice(k.gpa, rest[0 .. nl + 1]) catch return;
            rest = rest[nl + 1 ..];
            command(k, line.items);
            line.clearRetainingCapacity();
        }
        if (line.items.len + rest.len > max_line_bytes) return;
        line.appendSlice(k.gpa, rest) catch return;
    }
}

fn command(k: *Keeper, line: []const u8) void {
    if (line.len < 2) return;
    writeAll(k.in_journal, line) catch {};
    switch (line[0]) {
        tag_write, tag_steer => {
            const fd = k.stdin_fd.load(.acquire);
            if (fd >= 0) writeAll(fd, line[1..]) catch k.closeStdin();
        },
        tag_close => k.closeStdin(),
        else => {},
    }
}

const Accept = struct {
    keeper: *Keeper,
    listen_fd: std.posix.fd_t,

    fn run(a: *Accept) void {
        while (!a.keeper.ended.load(.acquire)) {
            const fd = std.c.accept(a.listen_fd, null, null);
            if (fd < 0) {
                if (std.c._errno().* == @backingInt(std.c.E.INTR)) continue;
                return;
            }
            _ = std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, std.c.FD_CLOEXEC));
            // One daemon at a time: a newer connection is the successor.
            const prior = a.keeper.client.load(.acquire);
            if (prior >= 0) _ = std.c.shutdown(prior, std.c.SHUT.RDWR);
            const t = std.Thread.spawn(.{}, serve, .{ a.keeper, fd }) catch {
                _ = std.c.close(fd);
                continue;
            };
            t.detach();
        }
    }
};

pub fn run(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    if (args.len < 3 or !std.mem.eql(u8, args[1], "--")) {
        std.log.err("usage: marlin _keep <dir> -- <argv…> (internal)", .{});
        return 2;
    }
    const dir = args[0];
    const argv = args[2..];
    // Its own session: the daemon's terminal, process group and exit are
    // not this process's business.
    _ = std.c.setsid();

    var k = Keeper{ .io = io, .gpa = gpa, .dir = dir };
    const out_fd = try openJournal(dir, out_name);
    const err_fd = try openJournal(dir, err_name);
    k.in_journal = try openJournal(dir, in_name);
    const listen_fd = try listen(dir);

    const argv_owned = try gpa.alloc([]const u8, argv.len);
    defer gpa.free(argv_owned);
    for (argv, argv_owned) |a, *o| o.* = a;
    var child = std.process.spawn(io, .{
        .argv = argv_owned,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        const text = std.fmt.allocPrint(gpa, "spawn failed: {t}\n", .{err}) catch "spawn failed\n";
        writeAll(err_fd, text) catch {};
        writeExit(dir, "exited 127");
        // Readiness after the journals say why: the daemon reads them.
        _ = std.c.write(1, "R", 1);
        return 1;
    };
    k.pid = child.id.?;
    k.stdin_fd.store(child.stdin.?.handle, .release);
    child.stdin = null;

    var out_copy = Copy{ .keeper = &k, .from = child.stdout.?.handle, .to = out_fd };
    var err_copy = Copy{ .keeper = &k, .from = child.stderr.?.handle, .to = err_fd };
    const out_thread = try std.Thread.spawn(.{}, Copy.run, .{&out_copy});
    const err_thread = try std.Thread.spawn(.{}, Copy.run, .{&err_copy});
    var acceptor = Accept{ .keeper = &k, .listen_fd = listen_fd };
    const accept_thread = try std.Thread.spawn(.{}, Accept.run, .{&acceptor});
    accept_thread.detach();

    // Ready: the socket listens and the guest runs. Nothing more goes to
    // stdout, which the daemon closes after this byte.
    _ = std.c.write(1, "R", 1);
    _ = std.c.close(1);

    out_thread.join();
    err_thread.join();
    const term = child.wait(io) catch std.process.Child.Term{ .unknown = 0 };
    var status_buf: [32]u8 = undefined;
    const status = switch (term) {
        .exited => |code| std.fmt.bufPrint(&status_buf, "exited {d}", .{code}) catch "exited 255",
        .signal => |sig| std.fmt.bufPrint(&status_buf, "signal {d}", .{@backingInt(sig)}) catch "signal 0",
        else => "exited 255",
    };
    writeExit(dir, status);
    k.closeStdin();
    k.ended.store(true, .release);
    k.note(note_exit);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (socketPath(&path_buf, dir)) |path| _ = std.c.unlink(path) else |_| {}
    _ = std.c.close(listen_fd);
    // The connected daemon reads `x` and the rest of the journal itself.
    return 0;
}

/// `exit` appears whole (written aside, renamed into place).
fn writeExit(dir: []const u8, status: []const u8) void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}/{s}.tmp", .{ dir, exit_name }, 0) catch return;
    const path = std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}", .{ dir, exit_name }, 0) catch return;
    const fd = std.c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    writeAll(fd, status) catch {};
    _ = std.c.close(fd);
    _ = std.c.rename(tmp, path);
}

/// Parse an `exit` file: the exit code, or null for a signal or garbage.
pub fn parseExit(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \n");
    if (!std.mem.startsWith(u8, trimmed, "exited ")) return null;
    return std.fmt.parseInt(i64, trimmed["exited ".len..], 10) catch null;
}
