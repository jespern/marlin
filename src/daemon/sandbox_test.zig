//! Unit tests for sandbox.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in sandbox.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const permissions = @import("permissions.zig");
const credentials = @import("../core/credentials.zig");

const sandbox = @import("sandbox.zig");
const Backend = sandbox.Backend;
const ProtectedRoots = sandbox.ProtectedRoots;
const seatbelt_profile = sandbox.seatbelt_profile;
const verifySeatbelt = sandbox.verifySeatbelt;

test {
    std.testing.refAllDecls(sandbox);
}

test "Seatbelt profile grants parameterized write roots and denies protected reads" {
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(deny default)") != null);
    // signal is its own SBPL operation (process* does not cover it); without
    // this rule, timeout/kill inside the sandbox get EPERM and hang forever.
    try std.testing.expect(std.mem.indexOf(u8, seatbelt_profile, "(allow signal (target same-sandbox))") != null);
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

test "remembered roots allow a shared cache without permitting a sibling or protected read" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-scoped-sandbox");
    defer temp.deinit();
    var memory = std.heap.ArenaAllocator.init(gpa);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, temp.path, arena);
    const workspace = try std.fs.path.join(arena, &.{ base, "workspace" });
    const scratch = try std.fs.path.join(arena, &.{ base, "scratch" });
    const cache = try std.fs.path.join(arena, &.{ base, "cache" });
    const outside = try std.fs.path.join(arena, &.{ base, "outside" });
    const secret = try std.fs.path.join(arena, &.{ base, "secret" });
    for ([_][]const u8{ workspace, scratch, cache, outside, secret }) |path| try Io.Dir.cwd().createDirPath(io, path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ secret, "key" }), .data = "synthetic" });
    const paths: sandbox.Paths = .{
        .workspace = workspace,
        .temp_root = scratch,
        .write_roots = &.{cache},
        .protected = .{ .ssh = secret, .aws = secret, .gnupg = secret, .marlin_credentials = secret },
    };
    const argv = try sandbox.seatbeltArgv(arena, paths, "printf local > \"$1/local\" && printf shared > \"$2/shared\" && if printf bad > \"$3/blocked\" 2>/dev/null; then exit 11; fi; if cat \"$4/key\" 2>/dev/null; then exit 12; fi", &.{ workspace, cache, outside, secret });
    const result = try std.process.run(gpa, io, .{ .argv = argv });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    const shared = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ cache, "shared" }), arena, .limited(64));
    try std.testing.expectEqualStrings("shared", shared);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, try std.fs.path.join(arena, &.{ outside, "blocked" }), .{}));
    // The turn's snapshot is not permission to follow a replacement symlink
    // when a later shell invocation constructs its kernel rules.
    try Io.Dir.cwd().deleteTree(io, cache);
    const link = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/ln", "-s", outside, cache } });
    defer gpa.free(link.stdout);
    defer gpa.free(link.stderr);
    try std.testing.expectError(error.SandboxWriteRootChanged, @import("tools/bash.zig").run(gpa, io, .{ .command = "true" }, workspace, null, .{
        .backend = .seatbelt,
        .temp_root = scratch,
        .protected = paths.protected,
        .write_roots = paths.write_roots,
    }, null));
}
