//! Unit tests for bash.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in bash.zig.

const std = @import("std");
const Io = std.Io;
const sandbox = @import("../sandbox.zig");
const process_io = @import("../process_io.zig");

const bash = @import("bash.zig");
const run = bash.run;

test {
    std.testing.refAllDecls(bash);
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

test "bash tool enforces its wall-clock timeout and reports it" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const r = try run(
        gpa,
        threaded.io(),
        .{ .command = "printf progress-so-far; sleep 30", .timeout_seconds = 1 },
        ".",
        null,
        .{},
        null,
    );
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -1), r.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, r.output, "progress-so-far"));
    try std.testing.expect(std.mem.indexOf(u8, r.output, "timed out after 1s") != null);
}

test "sandboxed processes can signal within their own job (macOS)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-bash-signal-test");
    defer temp.deinit();
    const options = sandbox.Options{
        .backend = .seatbelt,
        .temp_root = temp.path,
        .protected = .{
            .ssh = temp.path,
            .aws = temp.path,
            .gnupg = temp.path,
            .marlin_credentials = temp.path,
        },
    };
    // The shape that hung a real session: a sandboxed supervisor (timeout,
    // kill) must be able to TERM its own child. Exit 0 proves it landed;
    // 15 is the guarded failure. (timeout(1) itself is not stock macOS.)
    const r = try run(
        gpa,
        io,
        .{ .command = "sleep 30 & if kill $! 2>/dev/null; then exit 0; else exit 15; fi", .timeout_seconds = 10 },
        temp.path,
        null,
        options,
        null,
    );
    defer r.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 0), r.exit_code);
}
