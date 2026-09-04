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

    var temp = try TestScratch.init(gpa, io, "marlin-process-io-escapee");
    defer temp.deinit();
    const pid_path = try std.fs.path.join(gpa, &.{ temp.path, "escapee.pid" });
    defer gpa.free(pid_path);

    // set -m gives the background job its own process group (what timeout(1)
    // does via setpgid), so a group-only kill would miss it; the TERM trap
    // additionally forces the sweep's KILL escalation to be what lands.
    const script =
        \\set -m
        \\(trap '' TERM; while :; do sleep 1; done) &
        \\printf '%s' "$!" > "$1"
        \\wait
    ;
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

    var temp = try TestScratch.init(gpa, io, "marlin-process-io-daemon");
    defer temp.deinit();
    const pid_path = try std.fs.path.join(gpa, &.{ temp.path, "daemon.pid" });
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
