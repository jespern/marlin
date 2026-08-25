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
    "literal destinations used by common network commands are screened before execution.";
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

    if (sandbox_options.backend == .seatbelt) {
        const arena = arena_state.allocator();
        const temp_root = sandbox_options.temp_root orelse return error.SandboxTempUnavailable;
        const protected = sandbox_options.protected orelse return error.SandboxProtectedUnavailable;
        // Seatbelt subpath parameters match real paths only; the env
        // spellings of cwd/temp may sit behind symlinks (/tmp, /var).
        const real_workspace = try Io.Dir.realPathFileAbsoluteAlloc(io, cwd, arena);
        const real_temp = try Io.Dir.realPathFileAbsoluteAlloc(io, temp_root, arena);
        // A workspace under a protected root cannot receive both its write
        // grant and the read denial; refuse rather than run half-enforced.
        if (protected.contains(real_workspace)) return error.SandboxWorkspaceProtected;
        argv = try sandbox.seatbeltArgv(arena, .{
            .workspace = real_workspace,
            .temp_root = real_temp,
            .protected = protected,
        }, args.command, &.{});
    }
    const res = process_io.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = child_environ,
        .stdout_limit = max_capture_bytes,
        .stderr_limit = max_capture_bytes,
        .timeout_ms = null,
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

test "sandboxed bash enforces write scope and protected reads (macOS)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-bash-sandbox-test");
    defer temp.deinit();
    const base = temp.path;

    const workspace = try std.fs.path.join(gpa, &.{ base, "ws" });
    defer gpa.free(workspace);
    const temp_root = try std.fs.path.join(gpa, &.{ base, "tmp" });
    defer gpa.free(temp_root);
    const secret_dir = try std.fs.path.join(gpa, &.{ base, "ssh" });
    defer gpa.free(secret_dir);
    const secret_file = try std.fs.path.join(gpa, &.{ secret_dir, "id_ed25519" });
    defer gpa.free(secret_file);

    const cwd_dir = Io.Dir.cwd();
    try cwd_dir.createDirPath(io, workspace);
    try cwd_dir.createDirPath(io, temp_root);
    try cwd_dir.createDirPath(io, secret_dir);
    try cwd_dir.writeFile(io, .{ .sub_path = secret_file, .data = "canary" });

    // Options carry the resolved spelling (as the daemon does); the script
    // below deliberately probes via the caller-visible spelling to prove the
    // kernel matches the resolved target, not the requested string.
    const real_secret = try Io.Dir.realPathFileAbsoluteAlloc(io, secret_dir, gpa);
    defer gpa.free(real_secret);

    const options = sandbox.Options{
        .backend = .seatbelt,
        .temp_root = temp_root,
        .protected = .{
            .ssh = real_secret,
            .aws = real_secret,
            .gnupg = real_secret,
            .marlin_credentials = real_secret,
        },
    };

    const script = try std.fmt.allocPrint(gpa,
        \\printf ok > marker || exit 10
        \\if printf out > "{s}/blocked"; then exit 12; fi
        \\if cat "{s}" > /dev/null; then exit 13; fi
        \\exit 0
    , .{ base, secret_file });
    defer gpa.free(script);

    const r = try run(gpa, io, .{ .command = script }, workspace, null, options, null);
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 0), r.exit_code);

    // A workspace inside a protected root is refused, not run half-enforced.
    try std.testing.expectError(
        error.SandboxWorkspaceProtected,
        run(gpa, io, .{ .command = "true" }, secret_dir, null, options, null),
    );
}

test {
    std.testing.refAllDecls(@This());
}
