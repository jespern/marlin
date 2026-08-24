//! bash tool: subprocess execution with capture caps.
//!
//! M0: foreground execution via std.process.run with a byte cap on captured
//! output. The FULL output goes to the caller (which blobs it); the inline
//! context cap is applied by the loop via context.zig.
//! TODO(M1): cancellation flag → SIGTERM → grace → SIGKILL (needs spawn API
//! + poll loop instead of the blocking run helper).
//! TODO(M6): seatbelt / Landlock sandboxing.

const std = @import("std");
const Io = std.Io;

pub const spec_name = "bash";
pub const spec_description =
    "Run a shell command with bash -c. Returns interleaved stdout/stderr and the exit code. " ++
    "The working directory is the session's cwd.";
pub const spec_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to run"}},"required":["command"]}
;

pub const Args = struct { command: []const u8 };

pub const Result = struct {
    /// Combined output (stdout then stderr), possibly truncated at max_bytes.
    output: []u8,
    exit_code: i64,
    truncated: bool,

    pub fn deinit(self: Result, gpa: std.mem.Allocator) void {
        gpa.free(self.output);
    }
};

/// Hard cap on captured bytes per stream (full output beyond this is LOST —
/// deliberately generous; the *context* cap is much smaller and lossless
/// because the capture is blobbed first).
pub const max_capture_bytes: usize = 4 * 1024 * 1024;

pub fn run(gpa: std.mem.Allocator, io: Io, args: Args, cwd: []const u8) !Result {
    const argv = [_][]const u8{ "bash", "-c", args.command };
    const res = std.process.run(gpa, io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(max_capture_bytes),
        .stderr_limit = .limited(max_capture_bytes),
    }) catch |e| {
        const msg = try std.fmt.allocPrint(gpa, "failed to spawn bash: {t}", .{e});
        return .{ .output = msg, .exit_code = -1, .truncated = false };
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, res.stdout);
    if (res.stderr.len > 0) {
        if (out.items.len > 0) try out.appendSlice(gpa, "\n");
        try out.appendSlice(gpa, "[stderr]\n");
        try out.appendSlice(gpa, res.stderr);
    }
    const truncated = res.stdout.len >= max_capture_bytes or res.stderr.len >= max_capture_bytes;
    if (truncated) try out.appendSlice(gpa, "\n[output truncated at capture cap]");

    const exit_code: i64 = switch (res.term) {
        .exited => |code| code,
        .signal => |sig| -@as(i64, @intFromEnum(sig)),
        else => -1,
    };
    return .{
        .output = try out.toOwnedSlice(gpa),
        .exit_code = exit_code,
        .truncated = truncated,
    };
}

test {
    std.testing.refAllDecls(@This());
}
