//! Unit tests for effort.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in effort.zig.

const std = @import("std");

const effort = @import("effort.zig");
const Effort = effort.Effort;

test {
    std.testing.refAllDecls(effort);
}

test "reasoning effort parses case-insensitively and auto omits provider value" {
    try std.testing.expectEqual(Effort.high, Effort.parse("HIGH").?);
    try std.testing.expect(Effort.parse("turbo") == null);
    try std.testing.expect(Effort.auto.providerValue() == null);
    try std.testing.expectEqualStrings("xhigh", Effort.xhigh.providerValue().?);
}
