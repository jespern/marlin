//! Unit tests for shell_pty.zig: real shells on real PTYs.
const std = @import("std");
const shell_pty = @import("shell_pty.zig");
const Shell = shell_pty.Shell;

/// Collects what a shell's reader thread reports.
const Recorder = struct {
    mutex: std.Io.Mutex = .init,
    output: std.ArrayList(u8) = .empty,
    status: ?shell_pty.Status = null,
    io: std.Io,

    fn sink(self: *Recorder) shell_pty.Sink {
        return .{ .ctx = self, .output = onOutput, .exited = onExited };
    }

    fn onOutput(ctx: *anyopaque, _: *Shell, bytes: []const u8) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.output.appendSlice(std.testing.allocator, bytes) catch @panic("OOM");
    }

    fn onExited(ctx: *anyopaque, _: *Shell, status: shell_pty.Status) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.status = status;
    }

    fn deinit(self: *Recorder) void {
        self.output.deinit(std.testing.allocator);
    }

    const Snapshot = struct { len: usize, contains: bool, exited: ?shell_pty.Status };

    fn snapshot(self: *Recorder) Snapshot {
        return self.snapshotFor("");
    }

    fn snapshotFor(self: *Recorder, needle: []const u8) Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .len = self.output.items.len,
            .contains = needle.len > 0 and std.mem.indexOf(u8, self.output.items, needle) != null,
            .exited = self.status,
        };
    }

    /// Wait until the shell exits (or `needle` appears), up to five seconds.
    fn wait(self: *Recorder, needle: []const u8) !void {
        for (0..500) |_| {
            const now = self.snapshotFor(needle);
            if (now.exited != null or now.contains) return;
            try self.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.Timeout;
    }
};

fn shEnviron() !std.process.Environ.Map {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    errdefer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("TERM", "xterm-256color");
    return environ;
}

fn spawnSh(io: std.Io, environ: *const std.process.Environ.Map, script: []const u8, recorder: *Recorder, cols: u16, rows: u16) !*Shell {
    return Shell.spawn(std.testing.allocator, io, 1, 7, .{
        .path = "/bin/sh",
        .argv = &.{ "sh", "-c", script },
        .cwd = "/",
        .environ = environ,
        .cols = cols,
        .rows = rows,
    }, recorder.sink());
}

test "a shell sees its window size and TERM, and reports its exit code" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = try shEnviron();
    defer environ.deinit();
    var recorder: Recorder = .{ .io = io };
    defer recorder.deinit();

    const shell = try spawnSh(io, &environ, "printf '%s|%s|%s' \"$(stty size)\" \"$TERM\" \"$(pwd)\"; exit 3", &recorder, 100, 30);
    defer shell.destroy();
    try recorder.wait("");
    try std.testing.expectEqual(@as(?i32, 3), recorder.status.?.code);
    try std.testing.expect(std.mem.indexOf(u8, recorder.output.items, "30 100|xterm-256color|/") != null);
}

test "input reaches the shell through the PTY" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = try shEnviron();
    defer environ.deinit();
    var recorder: Recorder = .{ .io = io };
    defer recorder.deinit();

    const shell = try spawnSh(io, &environ, "read line; printf 'got:%s' \"$line\"", &recorder, 80, 24);
    defer shell.destroy();
    try shell.write("hello\r");
    try recorder.wait("");
    try std.testing.expect(std.mem.indexOf(u8, recorder.output.items, "got:hello") != null);
}

test "pipelines see default SIGPIPE handling, not the daemon's" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = try shEnviron();
    defer environ.deinit();
    var recorder: Recorder = .{ .io = io };
    defer recorder.deinit();

    const shell = try spawnSh(io, &environ, "yes | head -1 2>&1; echo done", &recorder, 80, 24);
    defer shell.destroy();
    try recorder.wait("");
    try std.testing.expect(std.mem.indexOf(u8, recorder.output.items, "done") != null);
    try std.testing.expect(std.mem.indexOf(u8, recorder.output.items, "Broken pipe") == null);
}

test "closing a running shell hangs it up promptly without an exit report" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = try shEnviron();
    defer environ.deinit();
    var recorder: Recorder = .{ .io = io };
    defer recorder.deinit();

    const shell = try spawnSh(io, &environ, "trap '' HUP; sleep 30", &recorder, 80, 24);
    try io.sleep(.fromMilliseconds(100), .awake);
    const started = std.Io.Timestamp.now(io, .awake);
    shell.destroy();
    const elapsed_ms = @divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds - started.nanoseconds, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 2000);
    try std.testing.expect(recorder.snapshot().exited == null);
}

test "unacknowledged output pauses the reader until the client catches up" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = try shEnviron();
    defer environ.deinit();
    var recorder: Recorder = .{ .io = io };
    defer recorder.deinit();

    const total = 3 * shell_pty.ack_window;
    var script_buf: [128]u8 = undefined;
    const script = try std.fmt.bufPrint(&script_buf, "head -c {d} /dev/zero | tr '\\000' x; printf END", .{total});
    const shell = try spawnSh(io, &environ, script, &recorder, 80, 24);
    defer shell.destroy();

    // Fill the window (however long a loaded machine takes), then check the
    // reader stays stalled rather than racing past it.
    for (0..1000) |_| {
        if (recorder.snapshot().len >= shell_pty.ack_window) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    try io.sleep(.fromMilliseconds(300), .awake);
    try std.testing.expect(recorder.snapshot().len < shell_pty.ack_window + 64 * 1024);

    for (0..1000) |_| {
        shell.acknowledge(std.math.maxInt(u64));
        if (recorder.snapshotFor("END").contains) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    } else return error.Timeout;
    try std.testing.expect(recorder.snapshot().len >= total);
}
