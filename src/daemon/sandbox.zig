//! Platform sandbox adapters for permission-mode tool execution.
//!
//! macOS Seatbelt (`sandbox-exec` + SBPL) is a deprecated/private interface,
//! so presence of the binary is not enough. `verifySeatbelt` performs a live
//! canary: a write below WORKSPACE must succeed, a sibling write must fail,
//! and reads of the protected parameters (a directory and a single file) must
//! fail. Only a successful probe may enable sandboxed-yolo execution.
//!
//! Seatbelt `subpath` filters match fully resolved paths. On macOS both
//! /tmp and /var are symlinks into /private, so a parameter built from an
//! environment spelling silently never matches and the write it was meant to
//! allow fails. Every path that becomes a profile parameter must therefore be
//! symlink-resolved first; `verifySeatbelt` and the bash adapter both do this.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const permissions = @import("permissions.zig");
const credentials = @import("../core/credentials.zig");

pub const Backend = enum { unavailable, seatbelt };

/// Credential roots denied to sandboxed shells. Owned, symlink-resolved
/// where the path exists; nonexistent roots keep their lexical spelling so
/// a later plain mkdir is still covered.
pub const ProtectedRoots = struct {
    ssh: []const u8,
    aws: []const u8,
    gnupg: []const u8,
    marlin_credentials: []const u8,

    pub fn deinit(self: *ProtectedRoots, gpa: std.mem.Allocator) void {
        gpa.free(self.ssh);
        gpa.free(self.aws);
        gpa.free(self.gnupg);
        gpa.free(self.marlin_credentials);
        self.* = undefined;
    }

    /// True when `real_path` (already symlink-resolved) sits at or below
    /// any protected root.
    pub fn contains(self: ProtectedRoots, real_path: []const u8) bool {
        return permissions.isWithin(self.ssh, real_path) or
            permissions.isWithin(self.aws, real_path) or
            permissions.isWithin(self.gnupg, real_path) or
            permissions.isWithin(self.marlin_credentials, real_path);
    }
};

pub const Options = struct {
    backend: Backend = .unavailable,
    /// Existing Marlin-owned directory. Sandboxed tools receive this as
    /// TMPDIR and may write there in addition to the workspace.
    temp_root: ?[]const u8 = null,
    /// Required when backend is .seatbelt: the profile's read denials are
    /// parameterized on these roots and the profile does not compile with
    /// an unbound parameter.
    protected: ?ProtectedRoots = null,
};

/// Every path a sandboxed shell receives arrives through this struct so the
/// canary and real invocations cannot drift. All fields are symlink-resolved.
pub const Paths = struct {
    workspace: []const u8,
    temp_root: []const u8,
    protected: ProtectedRoots,
};

/// Parameters avoid interpolating paths into private SBPL syntax. Ordinary
/// reads and network remain available; writes are limited to the selected
/// workspace and a Marlin-owned temporary root; reads of the protected
/// credential roots are denied. Rule order matters: SBPL resolves conflicts
/// last-match-wins, so the protected denial must FOLLOW the broad read
/// allow (the canary proves this ordering on the running OS).
pub const seatbelt_profile =
    \\(version 1)
    \\(deny default)
    \\(import "system.sb")
    \\(allow file-read*)
    \\(allow process*)
    \\(allow network*)
    \\(allow file-write*
    \\    (subpath (param "WORKSPACE"))
    \\    (subpath (param "TEMP_ROOT")))
    \\(deny file-read*
    \\    (subpath (param "PROTECTED_SSH"))
    \\    (subpath (param "PROTECTED_AWS"))
    \\    (subpath (param "PROTECTED_GNUPG"))
    \\    (subpath (param "PROTECTED_MARLIN")))
;

/// Build the complete `sandbox-exec` argv for one `/bin/bash -c` call.
/// `extra_args` follow `--` and appear as `$1…` in the command. Returned
/// slices are allocated from `arena` or borrowed from the inputs.
pub fn seatbeltArgv(
    arena: std.mem.Allocator,
    paths: Paths,
    shell_command: []const u8,
    extra_args: []const []const u8,
) ![]const []const u8 {
    const defs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "WORKSPACE", .value = paths.workspace },
        .{ .name = "TEMP_ROOT", .value = paths.temp_root },
        .{ .name = "PROTECTED_SSH", .value = paths.protected.ssh },
        .{ .name = "PROTECTED_AWS", .value = paths.protected.aws },
        .{ .name = "PROTECTED_GNUPG", .value = paths.protected.gnupg },
        .{ .name = "PROTECTED_MARLIN", .value = paths.protected.marlin_credentials },
    };
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "/usr/bin/sandbox-exec", "-p", seatbelt_profile });
    for (defs) |def| {
        try argv.append(arena, "-D");
        try argv.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ def.name, def.value }));
    }
    try argv.appendSlice(arena, &.{ "/bin/bash", "-c", shell_command, "--" });
    try argv.appendSlice(arena, extra_args);
    return argv.toOwnedSlice(arena);
}

/// Resolve the protected roots for this daemon: ~/.ssh, ~/.aws, ~/.gnupg,
/// and the Marlin credentials file (XDG-aware). Requires HOME; without it
/// the sandbox must not claim the protected-path contract.
pub fn resolveProtectedRoots(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !ProtectedRoots {
    const home = environ.get("HOME") orelse return error.NoHome;
    const real_home = try Io.Dir.realPathFileAbsoluteAlloc(io, home, gpa);
    defer gpa.free(real_home);

    const ssh = try resolveUnder(gpa, io, real_home, ".ssh");
    errdefer gpa.free(ssh);
    const aws = try resolveUnder(gpa, io, real_home, ".aws");
    errdefer gpa.free(aws);
    const gnupg = try resolveUnder(gpa, io, real_home, ".gnupg");
    errdefer gpa.free(gnupg);

    const cred_lexical = try credentials.credentialsPath(gpa, environ);
    const cred: []const u8 = blk: {
        const real = Io.Dir.realPathFileAbsoluteAlloc(io, cred_lexical, gpa) catch
            break :blk cred_lexical;
        gpa.free(cred_lexical);
        break :blk real;
    };
    return .{ .ssh = ssh, .aws = aws, .gnupg = gnupg, .marlin_credentials = cred };
}

fn resolveUnder(
    gpa: std.mem.Allocator,
    io: Io,
    real_home: []const u8,
    name: []const u8,
) ![]const u8 {
    const lexical = try std.fs.path.join(gpa, &.{ real_home, name });
    const real = Io.Dir.realPathFileAbsoluteAlloc(io, lexical, gpa) catch return lexical;
    gpa.free(lexical);
    return real;
}

/// Verify the Seatbelt contract on this exact OS installation. This creates
/// and removes a private probe directory beneath TMPDIR (or /private/tmp).
/// Any setup, spawn, or cleanup-adjacent uncertainty returns `unavailable`;
/// permission mode must then retain legacy shell approvals.
pub fn verifySeatbelt(
    gpa: std.mem.Allocator,
    io: Io,
    child_environ: ?*const std.process.Environ.Map,
) Backend {
    if (builtin.os.tag != .macos) return .unavailable;
    return runCanary(gpa, io, child_environ) catch .unavailable;
}

fn runCanary(
    gpa: std.mem.Allocator,
    io: Io,
    child_environ: ?*const std.process.Environ.Map,
) !Backend {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tmp_root = if (child_environ) |env|
        env.get("TMPDIR") orelse "/private/tmp"
    else
        "/private/tmp";

    var random: [8]u8 = undefined;
    io.random(&random);
    const nonce = std.mem.readInt(u64, &random, .little);
    const base = try std.fmt.allocPrint(arena, "{s}{c}marlin-seatbelt-probe-{x}", .{
        std.mem.trimEnd(u8, tmp_root, std.fs.path.sep_str),
        std.fs.path.sep,
        nonce,
    });

    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, base);
    defer cwd.deleteTree(io, base) catch {};

    // TMPDIR lives behind the /var → /private/var symlink; profile
    // parameters must be built from the resolved spelling (see module doc).
    const real_base = try Io.Dir.realPathFileAbsoluteAlloc(io, base, arena);
    const inside = try std.fs.path.join(arena, &.{ real_base, "inside" });
    const outside = try std.fs.path.join(arena, &.{ real_base, "outside" });
    const secret_dir = try std.fs.path.join(arena, &.{ real_base, "secret" });
    const secret_marker = try std.fs.path.join(arena, &.{ secret_dir, "marker" });
    const secret_file = try std.fs.path.join(arena, &.{ real_base, "secret.key" });
    const inside_marker = try std.fs.path.join(arena, &.{ inside, "ok" });
    const outside_marker = try std.fs.path.join(arena, &.{ outside, "blocked" });

    try cwd.createDirPath(io, inside);
    try cwd.createDirPath(io, outside);
    try cwd.createDirPath(io, secret_dir);
    try cwd.writeFile(io, .{ .sub_path = secret_marker, .data = "canary" });
    try cwd.writeFile(io, .{ .sub_path = secret_file, .data = "canary" });

    // The canary deliberately gives temporary-write authority only to the
    // inside directory, so it cannot mask a broken workspace restriction.
    // Protected params cover a directory and a bare file: both subpath
    // shapes are used by real invocations.
    const argv = try seatbeltArgv(arena, .{
        .workspace = inside,
        .temp_root = inside,
        .protected = .{
            .ssh = secret_dir,
            .aws = secret_dir,
            .gnupg = secret_dir,
            .marlin_credentials = secret_file,
        },
    },
        \\printf inside > "$1/inside/ok" || exit 10
        \\cat "$1/inside/ok" > /dev/null || exit 11
        \\if printf outside > "$1/outside/blocked"; then exit 12; fi
        \\if cat "$1/secret/marker" > /dev/null; then exit 13; fi
        \\if cat "$1/secret.key" > /dev/null; then exit 14; fi
        \\exit 0
    , &.{real_base});

    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .environ_map = child_environ,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });

    const exited_ok = result.term == .exited and result.term.exited == 0;
    if (!exited_ok) return error.CanaryFailed;
    _ = try cwd.statFile(io, inside_marker, .{});
    if (cwd.statFile(io, outside_marker, .{})) |_| return error.CanaryFailed else |_| {}
    return .seatbelt;
}

test "Seatbelt profile grants parameterized write roots and denies protected reads" {
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(deny default)") != null);
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(param \"WORKSPACE\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(param \"TEMP_ROOT\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(param \"PROTECTED_SSH\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(param \"PROTECTED_AWS\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(param \"PROTECTED_GNUPG\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(param \"PROTECTED_MARLIN\")") != null);
    // No unscoped write grant anywhere.
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(allow file-write*)") == null);
    // SBPL is last-match-wins: the protected denial must follow the broad
    // read allow or it is dead text.
    const allow_read = std.mem.indexOf(u8, seatbelt_profile, "(allow file-read*)").?;
    const deny_read = std.mem.indexOf(u8, seatbelt_profile, "(deny file-read*").?;
    try std.testing.expect(deny_read > allow_read);
}

test "protected roots containment matches exact roots and children only" {
    const roots = ProtectedRoots{
        .ssh = "/Users/example/.ssh",
        .aws = "/Users/example/.aws",
        .gnupg = "/Users/example/.gnupg",
        .marlin_credentials = "/Users/example/.config/marlin/credentials",
    };
    try std.testing.expect(roots.contains("/Users/example/.ssh"));
    try std.testing.expect(roots.contains("/Users/example/.ssh/id_ed25519"));
    try std.testing.expect(roots.contains("/Users/example/.config/marlin/credentials"));
    try std.testing.expect(!roots.contains("/Users/example/.sshfs"));
    try std.testing.expect(!roots.contains("/Users/example/work/api"));
}

test "Seatbelt canary passes on this macOS installation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectEqual(Backend.seatbelt, verifySeatbelt(gpa, io, null));
}
