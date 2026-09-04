//! bash tool: subprocess execution with capture caps.
//!
//! Foreground execution uses an owned process group, bounded capture, and
//! cooperative cancellation. Cancellation sends SIGTERM to the complete tree,
//! follows with SIGKILL after a short grace period, and reaps the direct child.
//! The FULL output goes to the caller (which blobs it); the inline context cap
//! is applied by the loop via context.zig.
//! M3.5: subprocess environment is scrubbed at the registry boundary;
//! macOS Seatbelt wraps execution when the daemon's canary verified it.
//! TODO: Landlock adapter for Linux.

const std = @import("std");
const Io = std.Io;
const sandbox = @import("../sandbox.zig");
const process_io = @import("../process_io.zig");

pub const spec_name = "bash";
pub const spec_description =
    "Run a shell command with bash -c. Returns interleaved stdout/stderr and the exit code. " ++
    "The working directory is the session's cwd. When network filtering is enabled, " ++
    "literal destinations used by common network commands are screened before execution. " ++
    "Commands are killed after timeout_seconds (default 600, max 3600); raise it for long builds.";
pub const spec_schema =
    \\{"type":"object","properties":{"command":{"type":"string","description":"The shell command to run"},"timeout_seconds":{"type":"integer","description":"Wall-clock limit in seconds (default 600, max 3600)"}},"required":["command"]}
;

pub const Args = struct { command: []const u8, timeout_seconds: ?u32 = null };

pub const default_timeout_seconds: u32 = 600;
pub const max_timeout_seconds: u32 = 3600;

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

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    args: Args,
    cwd: []const u8,
    child_environ: ?*const std.process.Environ.Map,
    sandbox_options: sandbox.Options,
    cancel: ?*const std.atomic.Value(bool),
) !Result {
    const direct_argv = [_][]const u8{ "bash", "-c", args.command };
    var argv: []const []const u8 = &direct_argv;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    if (sandbox_options.backend != .unavailable) {
        const arena = arena_state.allocator();
        const temp_root = sandbox_options.temp_root orelse return error.SandboxTempUnavailable;
        const protected = sandbox_options.protected orelse return error.SandboxProtectedUnavailable;
        // Both backends match real paths only (Seatbelt subpath parameters,
        // Landlock beneath-fd rules); the env spellings of cwd/temp may sit
        // behind symlinks (/tmp, /var).
        const real_workspace = try Io.Dir.realPathFileAbsoluteAlloc(io, cwd, arena);
        const real_temp = try Io.Dir.realPathFileAbsoluteAlloc(io, temp_root, arena);
        // A workspace under a protected root cannot receive both its write
        // grant and the read denial; refuse rather than run half-enforced.
        if (protected.contains(real_workspace)) return error.SandboxWorkspaceProtected;
        const paths = sandbox.Paths{
            .workspace = real_workspace,
            .temp_root = real_temp,
            .protected = protected,
        };
        argv = switch (sandbox_options.backend) {
            .seatbelt => try sandbox.seatbeltArgv(arena, paths, args.command, &.{}),
            .landlock => try sandbox.landlockArgv(
                arena,
                sandbox_options.marlin_exe orelse return error.SandboxExeUnavailable,
                paths,
                args.command,
                &.{},
            ),
            .unavailable => unreachable,
        };
    }
    // Explicit type: @min with a comptime-known bound narrows to u12,
    // which the *1000 below would overflow.
    const timeout_s: u32 = @min(args.timeout_seconds orelse default_timeout_seconds, max_timeout_seconds);
    const res = process_io.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = child_environ,
        .stdout_limit = max_capture_bytes,
        .stderr_limit = max_capture_bytes,
        .timeout_ms = timeout_s * std.time.ms_per_s,
        .cancel = cancel,
    }) catch |e| {
        if (e == error.Cancelled) return e;
        const msg = try std.fmt.allocPrint(gpa, "failed to spawn bash: {t}", .{e});
        return .{ .output = msg, .exit_code = -1, .truncated = false };
    };
    defer res.deinit(gpa);

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
    if (res.timed_out) {
        const note = try std.fmt.allocPrint(
            gpa,
            "{s}[command timed out after {d}s; its process tree was killed. " ++
                "Output above is everything captured before the deadline. " ++
                "Pass timeout_seconds (max {d}) for longer-running commands.]",
            .{ if (out.items.len > 0) "\n" else "", timeout_s, max_timeout_seconds },
        );
        defer gpa.free(note);
        try out.appendSlice(gpa, note);
        return .{ .output = try out.toOwnedSlice(gpa), .exit_code = -1, .truncated = truncated };
    }

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
