//! Unit tests for power.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in power.zig.

const std = @import("std");
const builtin = @import("builtin");
const power = @import("power.zig");

test "the idle-sleep assertion is scoped and idempotent" {
    var assertion = power.SleepAssertion{};
    try std.testing.expect(!assertion.held);

    // Taking the assertion can legitimately fail in a sandboxed test run;
    // the contract under test is the held/released bookkeeping, not powerd.
    assertion.sync(true);
    assertion.sync(true);
    if (builtin.os.tag != .macos) try std.testing.expect(!assertion.held);

    assertion.sync(false);
    assertion.sync(false);
    try std.testing.expect(!assertion.held);
    try std.testing.expectEqual(@as(u32, 0), assertion.id);
}
