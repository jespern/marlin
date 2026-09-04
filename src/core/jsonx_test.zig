//! Unit tests for jsonx.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in jsonx.zig.

const std = @import("std");

const jsonx = @import("jsonx.zig");
const repairObject = jsonx.repairObject;

test {
    std.testing.refAllDecls(jsonx);
}

test "valid json passes through untouched" {
    const out = try repairObject(std.testing.allocator, "{\"a\":1}");
    try std.testing.expectEqualStrings("{\"a\":1}", out);
}

test "prose around the object is trimmed" {
    const gpa = std.testing.allocator;
    const out = try repairObject(gpa, "Sure! Here are the args: {\"cmd\":\"ls\"} Hope that helps.");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", out);
}

test "trailing comma removed" {
    const gpa = std.testing.allocator;
    const out = try repairObject(gpa, "{\"a\":1,\"b\":2,}");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":2}", out);
}

test "unclosed braces and dangling string closed" {
    const gpa = std.testing.allocator;
    const out = try repairObject(gpa, "{\"cmd\":\"echo hi");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"cmd\":\"echo hi\"}", out);
}

test "raw newline inside string escaped" {
    const gpa = std.testing.allocator;
    const out = try repairObject(gpa, "{\"text\":\"line1\nline2\"}");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("{\"text\":\"line1\\nline2\"}", out);
}

test "hopeless input is Unrecoverable" {
    try std.testing.expectError(error.Unrecoverable, repairObject(std.testing.allocator, "no json here at all"));
}
