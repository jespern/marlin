//! Unit tests for process_io.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in process_io.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const process_io = @import("process_io.zig");
const run = process_io.run;
const terminateProcessGroup = process_io.terminateProcessGroup;

test {
    std.testing.refAllDecls(process_io);
}

/// TMPDIR-derived scratch dir for the process tests below (the house rule in
/// src/testing/temp_dir.zig: marlin's Seatbelt profile grants writes under
/// the session's TMPDIR, not under a cwd-relative .zig-cache/tmp). Mirrors
/// temp_dir.Dir locally because the e2e runner compiles this file as its
/// own module, and a file may belong to only one module.
const TestScratch = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []u8,

    fn init(gpa: std.mem.Allocator, io: Io, prefix: []const u8) !TestScratch {
        const env: ?[]const u8 = if (std.c.getenv("TMPDIR")) |raw| std.mem.span(raw) else null;
        const root: []const u8 = if (env != null and env.?.len > 0)
            env.?
        else if (builtin.os.tag == .macos)
            "/private/tmp"
        else
            "/tmp";
        var random: [8]u8 = undefined;
        io.random(&random);
        const leaf = try std.fmt.allocPrint(gpa, "{s}-{x}", .{ prefix, std.mem.readInt(u64, &random, .little) });
        defer gpa.free(leaf);
        const path = try std.fs.path.join(gpa, &.{ root, leaf });
        errdefer gpa.free(path);
        try Io.Dir.cwd().createDirPath(io, path);
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    fn deinit(self: *TestScratch) void {
        Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.gpa.free(self.path);
    }
};

// Longer than every timeout/assertion in these tests, but finite even when
// the test runner itself is killed and its defers cannot execute.
inline fn stubbornLoop(comptime seconds: u32) []const u8 {
    return std.fmt.comptimePrint(
        "remaining={d}; while [ \"$remaining\" -gt 0 ]; do sleep 1; remaining=$((remaining - 1)); done",
        .{seconds},
    );
}

/// Register before spawning, not after reading the PID or asserting success.
/// This is independent of the process-tree cleanup under test, and only runs
/// after assertions have had a chance to detect a surviving fixture.
const FixtureCleanup = struct {
    io: Io,
    pid_path: []const u8,
    owns_group: bool = false,

    fn deinit(self: FixtureCleanup) void {
        const gpa = std.heap.page_allocator;
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, self.pid_path, gpa, .limited(64)) catch return;
        defer gpa.free(bytes);
        const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, " \t\r\n"), 10) catch return;
        if (pid <= 1) return;
        std.posix.kill(if (self.owns_group) -pid else pid, .KILL) catch {};
    }
};

fn readFixturePid(gpa: std.mem.Allocator, io: Io, path: []const u8) !std.posix.pid_t {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64));
    defer gpa.free(bytes);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, bytes, " \t\r\n"), 10);
    if (pid <= 1) return error.InvalidFixturePid;
    return pid;
}

test "fixture cleanup removes an escaped process group after an early test failure" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try TestScratch.init(gpa, io, "marlin-process-io-guard");
    defer temp.deinit();
    const pid_path = try std.fs.path.join(gpa, &.{ temp.path, "escapee.pid" });
    defer gpa.free(pid_path);

    const Exercise = struct {
        fn fail(allocator: std.mem.Allocator, test_io: Io, path: []const u8, pid_out: *std.posix.pid_t) !void {
            defer (FixtureCleanup{ .io = test_io, .pid_path = path, .owns_group = true }).deinit();
            var child = try std.process.spawn(test_io, .{
                .argv = &.{ "bash", "-c", "set -m\n(trap '' TERM; " ++ stubbornLoop(30) ++ ") &\nprintf '%s' \"$!\" > \"$1\"\nwait", "--", path },
                .stdout = .ignore,
                .stderr = .ignore,
                .pgid = 0,
            });
            // Deliberately only kill the direct child. The independent guard
            // must remove the escaped group without process_io or ps.
            defer child.kill(test_io);
            var attempts: usize = 0;
            while (attempts < 100) : (attempts += 1) {
                const pid = readFixturePid(allocator, test_io, path) catch {
                    try test_io.sleep(.fromMilliseconds(10), .awake);
                    continue;
                };
                pid_out.* = pid;
                return error.DeliberateTestFailure;
            }
            return error.FixtureDidNotStart;
        }
    };
    var pid: std.posix.pid_t = 0;
    try std.testing.expectError(error.DeliberateTestFailure, Exercise.fail(gpa, io, pid_path, &pid));
    try std.testing.expect(pid > 1);
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        std.posix.kill(-pid, .CONT) catch |err| switch (err) {
            error.ProcessNotFound => return,
            else => return err,
        };
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.FixtureSurvivedTestFailure;
}

test "stubborn fixtures expire even without supervisor cleanup" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const result = try run(gpa, threaded.io(), .{
        .argv = &.{ "sh", "-c", "trap '' TERM; " ++ stubbornLoop(2) },
        .timeout_ms = 5_000,
    });
    defer result.deinit(gpa);
    try std.testing.expect(!result.timed_out);
    try std.testing.expectEqual(@as(u8, 0), result.term.exited);
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

test "run uses one absolute deadline and salvages partial output" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const result = try run(gpa, threaded.io(), .{
        .argv = &.{ "sh", "-c", "printf before-hang; sleep 30" },
        .timeout_ms = 300,
    });
    defer result.deinit(gpa);
    try std.testing.expect(result.timed_out);
    try std.testing.expectEqualStrings("before-hang", result.stdout);
}

test "forced kill sweeps descendants that escaped the process group" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The production escapee sweep needs a process-table snapshot. Some
    // sandboxes deny ps entirely; do not spawn an escapee when that part of
    // the contract cannot be exercised. The independent guard test above
    // still runs in those environments.
    const probe = std.process.run(gpa, io, .{
        .argv = &.{ "ps", "-axo", "pid=,ppid=,pgid=" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(4096),
    }) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(probe.stdout);
    defer gpa.free(probe.stderr);
    if (probe.term != .exited or probe.term.exited != 0) return error.SkipZigTest;

    var temp = try TestScratch.init(gpa, io, "marlin-process-io-escapee");
    defer temp.deinit();
    const pid_path = try std.fs.path.join(gpa, &.{ temp.path, "escapee.pid" });
    defer gpa.free(pid_path);
    defer (FixtureCleanup{ .io = io, .pid_path = pid_path, .owns_group = true }).deinit();

    // set -m gives the background job its own process group (what timeout(1)
    // does via setpgid), so a group-only kill would miss it; the TERM trap
    // additionally forces the sweep's KILL escalation to be what lands.
    const script = "set -m\n(trap '' TERM; " ++ stubbornLoop(30) ++ ") &\n" ++
        "printf '%s' \"$!\" > \"$1\"\nwait";
    const result = try run(gpa, io, .{
        .argv = &.{ "bash", "-c", script, "--", pid_path },
        .timeout_ms = 500,
        .termination_grace_ms = 50,
    });
    defer result.deinit(gpa);
    try std.testing.expect(result.timed_out);

    const pid_text = try Io.Dir.cwd().readFileAlloc(io, pid_path, gpa, .limited(64));
    defer gpa.free(pid_text);
    const escapee_pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    var attempts: u8 = 0;
    while (attempts < 50) : (attempts += 1) {
        std.posix.kill(escapee_pid, .CONT) catch |err| switch (err) {
            error.ProcessNotFound => break,
            else => return err,
        };
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    } else return error.EscapeeSurvivedForcedKill;
}

test "cancellation terminates and reaps the complete process tree" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try TestScratch.init(gpa, io, "marlin-process-io-descendant");
    defer temp.deinit();
    const pid_path = try std.fs.path.join(gpa, &.{ temp.path, "descendant.pid" });
    defer gpa.free(pid_path);
    defer (FixtureCleanup{ .io = io, .pid_path = pid_path }).deinit();

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

    const script = "(trap '' TERM; " ++ stubbornLoop(30) ++ ") &\n" ++
        "descendant=$!\nprintf '%s' \"$descendant\" > \"$1\"\nwait";
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

    var temp = try TestScratch.init(gpa, io, "marlin-process-io-daemon");
    defer temp.deinit();
    const pid_path = try std.fs.path.join(gpa, &.{ temp.path, "daemon.pid" });
    defer gpa.free(pid_path);
    defer (FixtureCleanup{ .io = io, .pid_path = pid_path }).deinit();

    const script = "(trap '' HUP TERM; " ++ stubbornLoop(30) ++ ") >/dev/null 2>&1 &\n" ++
        "printf '%s' \"$!\" > \"$1\"\nexit 0";
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

test "a closed stdin alone ends a stdio child that flushes on the way out" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try TestScratch.init(gpa, io, "marlin-process-io-stdin-eof");
    defer temp.deinit();
    const out_path = try std.fs.path.join(gpa, &.{ temp.path, "flushed" });
    defer gpa.free(out_path);

    // Stands in for a guest that batches work and only ships it on the clean
    // exit path: signalling it loses the file, closing stdin produces it.
    const script =
        \\while IFS= read -r line; do :; done
        \\printf flushed > "$1"
    ;
    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", script, "--", out_path },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const group: std.posix.pid_t = child.id.?;
    defer {
        terminateProcessGroup(io, group, 0);
        child.kill(io);
    }

    try std.testing.expect(process_io.closeStdinAndReap(&child, io, 2_000));
    process_io.releaseReapedChild(&child, io);

    const flushed = try Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .limited(64));
    defer gpa.free(flushed);
    try std.testing.expectEqualStrings("flushed", flushed);
}

test "a child that ignores the closed stdin is left for the caller to signal" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", "trap '' TERM; " ++ stubbornLoop(30) },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    });
    const group: std.posix.pid_t = child.id.?;
    defer {
        terminateProcessGroup(io, group, 0);
        child.kill(io);
    }

    try std.testing.expect(!process_io.closeStdinAndReap(&child, io, 150));
    try std.testing.expect(child.stdin == null);

    terminateProcessGroup(io, group, 0);
    _ = child.wait(io) catch {};
}
