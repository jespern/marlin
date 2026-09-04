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
    /// The wall-clock deadline expired: the tree was killed and stdout/stderr
    /// hold everything captured up to that point (term is the kill signal).
    timed_out: bool = false,
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

/// Salvage captured output when the deadline expires. The caller's deferred
/// cleanup (running after this return value is built) kills the tree and
/// sweeps setpgid escapees; the buffers hold everything read so far.
fn timedOutResult(
    gpa: std.mem.Allocator,
    multi_reader: *Io.File.MultiReader,
    process_group_id: ?std.posix.pid_t,
) Error!Result {
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{
        .term = .{ .signal = .KILL },
        .timed_out = true,
        .stdout = stdout,
        .stderr = stderr,
        .process_group_id = process_group_id,
    };
}

/// Descendants that escaped the owned process group (setpgid), snapshotted
/// while their parent chain is still alive so they stay attributable. A
/// fixed cap keeps this allocation-free for the caller; more than 32
/// escapees is a pathology we accept leaking rather than tracking.
const Escapees = struct {
    pids: [32]std.posix.pid_t = undefined,
    len: usize = 0,
};

/// Enumerate live descendants of `root` whose pgid differs from the owned
/// group, via one `ps` snapshot. Best-effort: any failure returns an empty
/// set and the group kill proceeds as before. Guard: if `root` is no longer
/// our child (pid reuse), return empty rather than sweep innocents.
fn snapshotEscapees(io: Io, root: ?std.posix.pid_t, group: std.posix.pid_t) Escapees {
    const empty: Escapees = .{};
    const root_pid = root orelse return empty;
    const gpa = std.heap.page_allocator;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "ps", "-axo", "pid=,ppid=,pgid=" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(4096),
    }) catch return empty;
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }

    const Proc = struct { pid: i64, ppid: i64, pgid: i64 };
    var procs: [4096]Proc = undefined;
    var n: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (n >= procs.len) break;
        var cols = std.mem.tokenizeAny(u8, line, " \t");
        const pid = std.fmt.parseInt(i64, cols.next() orelse continue, 10) catch continue;
        const ppid = std.fmt.parseInt(i64, cols.next() orelse continue, 10) catch continue;
        const pgid = std.fmt.parseInt(i64, cols.next() orelse continue, 10) catch continue;
        procs[n] = .{ .pid = pid, .ppid = ppid, .pgid = pgid };
        n += 1;
    }

    // The direct child must still be ours; a recycled pid must not seed a BFS.
    const self_pid: i64 = @intCast(std.c.getpid());
    var root_ok = false;
    for (procs[0..n]) |proc| {
        if (proc.pid == root_pid) root_ok = proc.ppid == self_pid;
    }
    if (!root_ok) return empty;

    // Transitive descendant closure by fixpoint (few passes in practice).
    var descendant: [4096]bool = @splat(false);
    var changed = true;
    while (changed) {
        changed = false;
        for (procs[0..n], 0..) |proc, i| {
            if (descendant[i]) continue;
            if (proc.ppid == root_pid) {
                descendant[i] = true;
                changed = true;
                continue;
            }
            for (procs[0..n], 0..) |parent, j| {
                if (descendant[j] and parent.pid == proc.ppid) {
                    descendant[i] = true;
                    changed = true;
                    break;
                }
            }
        }
    }

    var out: Escapees = .{};
    for (procs[0..n], 0..) |proc, i| {
        if (!descendant[i] or proc.pgid == group) continue;
        if (out.len >= out.pids.len) break;
        out.pids[out.len] = @intCast(proc.pid);
        out.len += 1;
    }
    return out;
}

fn killEscapees(io: Io, escapees: Escapees, grace_ms: u32) void {
    if (escapees.len == 0) return;
    for (escapees.pids[0..escapees.len]) |pid| std.posix.kill(pid, .TERM) catch {};
    if (grace_ms > 0) io.sleep(.fromMilliseconds(grace_ms), .awake) catch {};
    for (escapees.pids[0..escapees.len]) |pid| std.posix.kill(pid, .KILL) catch {};
}

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
    // Forced exits (timeout/cancel/error) first snapshot live descendants:
    // anything that left the owned group via setpgid — timeout(1) is the
    // canonical case — would survive a group-only kill and orphan.
    var forced_kill = true;
    defer input_thread.join();
    defer {
        const escapees: Escapees = if (forced_kill and builtin.os.tag != .windows)
            snapshotEscapees(io, child.id, process_group_id.?)
        else
            .{};
        terminateProcessTree(&child, io, options.termination_grace_ms);
        killEscapees(io, escapees, options.termination_grace_ms);
    }

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
                return timedOutResult(gpa, &multi_reader, process_group_id);
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
                        return timedOutResult(gpa, &multi_reader, process_group_id);
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
    forced_kill = false;
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
