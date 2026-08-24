//! Bounded subprocess execution with a caller-provided stdin payload.
//!
//! `std.process.run` deliberately connects stdin to /dev/null. Exec tools and
//! hooks need the same bounded stdout/stderr collection while streaming JSON
//! into the child. The stdin writer runs beside the multi-reader so neither a
//! chatty child nor a large input can deadlock the other pipe.

const std = @import("std");
const Io = std.Io;

pub const Options = struct {
    argv: []const []const u8,
    stdin: []const u8 = "",
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    stdout_limit: usize = 4 * 1024 * 1024,
    stderr_limit: usize = 256 * 1024,
    timeout_ms: u32 = 10_000,
};

pub const Result = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.stdout);
        gpa.free(self.stderr);
    }
};

pub const Error = std.process.SpawnError ||
    Io.File.MultiReader.UnendingError ||
    Io.Timeout.Error ||
    std.mem.Allocator.Error ||
    error{ StreamTooLong, InputThreadFailed };

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

/// Spawn, write all stdin, collect both output streams, and enforce one
/// wall-clock deadline. The returned output buffers are caller-owned.
pub fn run(gpa: std.mem.Allocator, io: Io, options: Options) Error!Result {
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    const stdin_file = child.stdin.?;
    child.stdin = null;
    const input_thread = std.Thread.spawn(.{}, InputJob.run, .{InputJob{
        .io = io,
        .file = stdin_file,
        .bytes = options.stdin,
    }}) catch {
        stdin_file.close(io);
        child.kill(io);
        return error.InputThreadFailed;
    };
    // On an error, stop the child before waiting for a possibly blocked input
    // writer. On success wait() makes kill() an idempotent no-op.
    defer input_thread.join();
    defer child.kill(io);

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(gpa, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    const timeout: Io.Timeout = (Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(options.timeout_ms),
        .clock = .awake,
    } }).toDeadline(io);
    while (multi_reader.fill(64, timeout)) |_| {
        if (stdout_reader.buffered().len > options.stdout_limit or
            stderr_reader.buffered().len > options.stderr_limit)
        {
            return error.StreamTooLong;
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try multi_reader.checkAnyError();

    const term = try child.wait(io);
    const stdout = try multi_reader.toOwnedSlice(0);
    errdefer gpa.free(stdout);
    const stderr = try multi_reader.toOwnedSlice(1);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
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
