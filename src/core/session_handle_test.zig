//! Unit tests for session_handle.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in session_handle.zig.

const std = @import("std");

const session_handle = @import("session_handle.zig");
const Full = session_handle.Full;
const default_len = session_handle.default_len;
const display = session_handle.display;
const full = session_handle.full;
const min_prefix_len = session_handle.min_prefix_len;
const resolve = session_handle.resolve;

test {
    std.testing.refAllDecls(session_handle);
}

test "session handles are stable, opaque, and distinct" {
    try std.testing.expectEqualStrings("be4719c63bf340496d2547fd913f84dfa9c1ad54589e9c9ecb922f4588d32d08", &full(42));
    try std.testing.expect(!std.mem.eql(u8, &full(42), &full(43)));
}

test "resolve accepts unique prefixes, uppercase, and legacy decimal ids" {
    const known = [_]u64{ 42, 43, 1_874_397_504_305_914_847 };
    const handle = full(42);
    var upper: [default_len]u8 = undefined;
    for (handle[0..default_len], 0..) |c, i| upper[i] = std.ascii.toUpper(c);

    try std.testing.expectEqual(@as(u64, 42), try resolve(handle[0..min_prefix_len], &known));
    try std.testing.expectEqual(@as(u64, 42), try resolve(&upper, &known));
    try std.testing.expectEqual(@as(u64, 42), try resolve("42", &known));
    try std.testing.expectEqual(@as(u64, 43), try resolve("@43", &known));
    try std.testing.expectError(error.PrefixTooShort, resolve("abc", &known));
    try std.testing.expectError(error.InvalidHandle, resolve("nope", &known));
    try std.testing.expectError(error.NotFound, resolve("ffffffff", &known));
}

test "ambiguous prefixes are rejected and display handles extend" {
    // This deterministic pair shares `71dbabd7` and differs at character 9.
    const display_known = [_]u64{ 62_757, 64_176 };
    const handle = full(display_known[0]);
    try std.testing.expectEqualStrings("71dbabd7", handle[0..default_len]);
    try std.testing.expectError(error.Ambiguous, resolve(handle[0..4], &display_known));
    try std.testing.expectError(error.Ambiguous, resolve(handle[0..default_len], &display_known));
    var buf: Full = undefined;
    try std.testing.expectEqual(@as(usize, default_len + 1), display(&buf, display_known[0], &display_known).len);
}
