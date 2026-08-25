//! Bounded subprocess execution with a caller-provided stdin payload.
//!
//! `std.process.run` deliberately connects stdin to /dev/null. Exec tools and
//! hooks need the same bounded stdout/stderr collection while streaming JSON
//! into the child. The stdin writer runs beside the multi-reader so neither a
//! chatty child nor a large input can deadlock the other pipe.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Options = struct {
    argv: []const []const u8,
    stdin: []const u8 = "",
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    stdout_limit: usize = 4 * 1024 * 1024,
    stderr_limit: usize = 256 * 1024,
    /// Null disables the wall-clock timeout. Cancellation is still observed.
    timeout_ms: ?u32 = 10_000,
    cancel: ?*const std.atomic.Value(bool) = null,
    termination_grace_ms: u32 = 150,
};

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    /// POSIX process group owned by this invocation. Descendants may outlive
    /// the direct child (notably test daemons), so supervisors can perform a
    /// final defensive sweep after graceful shutdown.
    process_group_id: ?std.posix.pid_t,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub const Error = std.process.SpawnError ||
    Io.File.MultiReader.UnendingError ||
    Io.Timeout.Error ||
    std.mem.Allocator.Error ||
    error{ StreamTooLong, InputThreadFailed, Cancelled };

const InputJob = struct {
    io: Io,
    file: Io.File,
    bytes: []const u8,

    fn run(job: InputJob) void {
        defer job.file.close(job.io);
        var buf: [4096]u8 = undefined;
        var writer = job.file.writer(job.io, &buf);
        writer.interface.writeAll(job.bytes) catch return;
        writer.interface.flush() catch {};
    }
};

/// Terminate a child and every descendant still in its owned process group,
/// then reap the direct child. Safe to call after `wait` and from error defers.
///
/// POSIX children launched by `run` use their pid as a fresh process-group id.
/// Windows currently falls back to the standard direct-child termination.
pub fn terminateProcessTree(child: *std.process.Child, io: Io, grace_ms: u32) void {
    if (child.id == null) return;
    if (builtin.os.tag == .windows) {
        child.kill(io);
        return;
    }

    const group_id = -child.id.?;
    std.posix.kill(group_id, .TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {
            child.kill(io);
            return;
        },
    };
    if (grace_ms > 0) io.sleep(.fromMilliseconds(grace_ms), .awake) catch {};
    std.posix.kill(group_id, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => {
            child.kill(io);
            return;
        },
    };
    _ = child.wait(io) catch {
        child.kill(io);
        return;
    };
}

/// Terminate any processes still belonging to a group previously returned by
/// `run`. There is no direct child to reap at this point; this is a supervisor
/// cleanup primitive for intentionally daemonizing descendants.
pub fn terminateProcessGroup(io: Io, group_id: std.posix.pid_t, grace_ms: u32) void {
    if (builtin.os.tag == .windows) return;
    std.posix.kill(-group_id, .TERM) catch |err| switch (err) {
        error.ProcessNotFound => return,
        else => return,
    };
    if (grace_ms > 0) io.sleep(.fromMilliseconds(grace_ms), .awake) catch {};
    std.posix.kill(-group_id, .KILL) catch {};
}

fn cancelled(flag: ?*const std.atomic.Value(bool)) bool {
    return if (flag) |f| f.load(.acquire) else false;
}

/// Spawn, write all stdin, collect both output streams, and enforce one
/// wall-clock deadline while observing cooperative cancellation. The returned
/// output buffers are caller-owned.
pub fn run(gpa: std.mem.Allocator, io: Io, options: Options) Error!Result {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        // Descendants inherit this group, allowing timeout/cancel cleanup to
        // remove pipelines and grandchildren rather than only the shell.
        .pgid = if (builtin.os.tag == .windows) null else 0,
    });
    const process_group_id: ?std.posix.pid_t = if (builtin.os.tag == .windows) null else child.id.?;

    const stdin_file = child.stdin.?;
    child.stdin = null;
    const input_thread = std.Thread.spawn(.{}, InputJob.run, .{InputJob{
        .io = io,
        .file = stdin_file,
        .bytes = options.stdin,
    }}) catch {
        stdin_file.close(io);
        terminateProcessTree(&child, io, options.termination_grace_ms);
        return error.InputThreadFailed;
    };
    // On an error, stop the child before waiting for a possibly blocked input
    // writer. On success wait() makes kill() an idempotent no-op.
    defer input_thread.join();
    defer terminateProcessTree(&child, io, options.termination_grace_ms);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const deadline_ns: ?i96 = if (options.timeout_ms) |timeout_ms|
        Io.Timestamp.now(io, .awake).nanoseconds +
            @as(i96, timeout_ms) * std.time.ns_per_ms
    else
        null;
    while (true) {
        if (cancelled(options.cancel)) return error.Cancelled;
        // MultiReader's timeout is a wait timeout, not a wall-clock budget:
        // one chatty stream can keep satisfying the wait forever while a
        // quiet sibling remains open. Check the absolute deadline before
        // every wait so continuous output cannot starve timeout handling.
        if (deadline_ns) |deadline| {
            if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline)
                return error.Timeout;
        }
        multi_reader.fill(64, .{ .duration = .{
            .raw = .fromMilliseconds(50),
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.EndOfStream => break,
            error.Timeout => {
                if (cancelled(options.cancel)) return error.Cancelled;
                if (deadline_ns) |deadline| {
                    if (Io.Timestamp.now(io, .awake).nanoseconds >= deadline)
                        return error.Timeout;
                }
                continue;
            },
            else => |e| return e,
        };
        if (stdout_reader.buffered().len > options.stdout_limit or
            stderr_reader.buffered().len > options.stderr_limit)
        {
            return error.StreamTooLong;
        }
    }
    if (cancelled(options.cancel)) return error.Cancelled;
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{
        .term = term,
        .stdout = stdout,
        .stderr = stderr,
        .process_group_id = process_group_id,
    };
}

test "run writes stdin and collects both output streams" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const result = try run(gpa, threaded.io(), .{
        .argv = &.{ "sh", "-c", "read line; printf 'out:%s' \"$line\"; printf err >&2" },
        .stdin = "hello\n",
    });
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("out:hello", result.stdout);
    try std.testing.expectEqualStrings("err", result.stderr);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
}

test "run enforces its output cap" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.StreamTooLong, run(gpa, threaded.io(), .{
        .argv = &.{ "sh", "-c", "printf 123456789" },
        .stdout_limit = 4,
    }));
}

test "run uses one absolute deadline" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.Timeout, run(gpa, threaded.io(), .{
        .argv = &.{ "sh", "-c", "while true; do printf x; sleep 0.02; done" },
        .timeout_ms = 80,
    }));
}

test "cancellation terminates and reaps the complete process tree" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const pid_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &temp.sub_path, "descendant.pid" });
    defer gpa.free(pid_path);

    var cancel = std.atomic.Value(bool).init(false);
    const CancelJob = struct {
        flag: *std.atomic.Value(bool),
        io: Io,
        fn fire(job: @This()) void {
            job.io.sleep(.fromMilliseconds(100), .awake) catch {};
            job.flag.store(true, .release);
        }
    };
    const cancel_thread = try std.Thread.spawn(.{}, CancelJob.fire, .{CancelJob{ .flag = &cancel, .io = io }});
    defer cancel_thread.join();

    const script =
        \\(trap '' TERM; while :; do sleep 1; done) &
        \\descendant=$!
        \\printf '%s' "$descendant" > "$1"
        \\wait
    ;
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    try std.testing.expectError(error.Cancelled, run(gpa, io, .{
        .argv = &.{ "sh", "-c", script, "--", pid_path },
        .timeout_ms = 3_000,
        .cancel = &cancel,
        .termination_grace_ms = 50,
    }));
    const elapsed_ms = @divTrunc(
        Io.Timestamp.now(io, .awake).nanoseconds - started,
        std.time.ns_per_ms,
    );
    try std.testing.expect(elapsed_ms < 2_000);

    const pid_text = try Io.Dir.cwd().readFileAlloc(io, pid_path, gpa, .limited(64));
    defer gpa.free(pid_text);
    const descendant_pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    var attempts: u8 = 0;
    while (attempts < 50) : (attempts += 1) {
        std.posix.kill(descendant_pid, .CONT) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    } else return error.DescendantSurvivedCancellation;
}

test "returned process group sweeps a daemonized descendant after parent exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const pid_path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &temp.sub_path, "daemon.pid" });
    defer gpa.free(pid_path);

    const script =
        \\(trap '' HUP TERM; while :; do sleep 1; done) >/dev/null 2>&1 &
        \\printf '%s' "$!" > "$1"
        \\exit 0
    ;
    const result = try run(gpa, io, .{
        .argv = &.{ "sh", "-c", script, "--", pid_path },
        .timeout_ms = 2_000,
        .termination_grace_ms = 50,
    });
    defer result.deinit(gpa);
    const group_id = result.process_group_id orelse return error.MissingProcessGroup;
    defer terminateProcessGroup(io, group_id, 0);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);

    const pid_text = try Io.Dir.cwd().readFileAlloc(io, pid_path, gpa, .limited(64));
    defer gpa.free(pid_text);
    const descendant_pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    terminateProcessGroup(io, group_id, 50);

    var attempts: u8 = 0;
    while (attempts < 50) : (attempts += 1) {
        std.posix.kill(descendant_pid, .CONT) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    } else return error.DaemonizedDescendantSurvivedCleanup;
}
