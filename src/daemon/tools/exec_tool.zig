//! Exec tools: config-declared executables as tools (docs/ARCHITECTURE.md §7).
//! marlin passes args as JSON on stdin; stdout is the result. A shell script
//! is a tool. Extensibility at process boundaries.

const std = @import("std");
const Io = std.Io;

const block = @import("../../core/block.zig");
const process_io = @import("../process_io.zig");

pub const max_output_bytes: usize = 4 * 1024 * 1024;

pub const Result = struct {
    output: []u8,
    status: block.ToolStatus,
};

/// Run a config-declared executable. `argv` is never interpreted by a shell;
/// users who want shell syntax opt into it explicitly with `sh -c` in config.
/// The repaired JSON argument object is the complete stdin payload.
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    args_json: []const u8,
    cwd: []const u8,
    child_environ: ?*const std.process.Environ.Map,
    timeout_ms: u32,
) Result {
    if (argv.len == 0) return failure(gpa, "exec tool has no command", .{});
    const result = process_io.run(gpa, io, .{
        .argv = argv,
        .stdin = args_json,
        .cwd = .{ .path = cwd },
        .environ_map = child_environ,
        .stdout_limit = max_output_bytes,
        .stderr_limit = 256 * 1024,
        .timeout_ms = timeout_ms,
    }) catch |err| return failure(gpa, "exec tool failed: {t}", .{err});
    defer result.deinit(gpa);

    const exit_code: i64 = switch (result.term) {
        .exited => |code| code,
        .signal => |signal| -@as(i64, @intFromEnum(signal)),
        else => -1,
    };
    var output: []u8 = undefined;
    if (result.stderr.len == 0) {
        output = gpa.dupe(u8, result.stdout) catch @panic("oom");
    } else {
        output = std.fmt.allocPrint(gpa, "{s}{s}[stderr]\n{s}", .{
            result.stdout,
            if (result.stdout.len > 0) "\n" else "",
            result.stderr,
        }) catch @panic("oom");
    }
    if (exit_code == 0) return .{ .output = output, .status = .ok };

    const with_code = std.fmt.allocPrint(gpa, "{s}\n[exit code: {d}]", .{ output, exit_code }) catch
        return .{ .output = output, .status = .err };
    gpa.free(output);
    return .{ .output = with_code, .status = .err };
}

fn failure(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    return .{
        .output = std.fmt.allocPrint(gpa, "error: " ++ fmt, args) catch @panic("oom"),
        .status = .err,
    };
}

test "exec tool receives JSON on stdin" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const result = run(
        gpa,
        threaded.io(),
        &.{ "sh", "-c", "input=$(cat); printf 'seen:%s' \"$input\"" },
        "{\"value\":42}",
        "/tmp",
        null,
        2_000,
    );
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expectEqualStrings("seen:{\"value\":42}", result.output);
}

test "exec tool makes nonzero exit model-visible" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const result = run(gpa, threaded.io(), &.{ "sh", "-c", "printf nope; exit 7" }, "{}", "/tmp", null, 2_000);
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.err, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exit code: 7") != null);
}

test {
    std.testing.refAllDecls(@This());
}
