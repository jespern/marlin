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
