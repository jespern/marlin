//! Unit tests for task.zig. Tests live beside the module they cover.

const std = @import("std");
const task = @import("task.zig");

test {
    std.testing.refAllDecls(task);
}

test "provider-native task model inherits the parent's outer registry provider" {
    const gpa = std.testing.allocator;
    const qualified = try task.qualifyModel(gpa, "openrouter/anthropic/claude-sonnet-4.5", "openai/gpt-5.2");
    defer gpa.free(qualified);
    try std.testing.expectEqualStrings("openrouter/openai/gpt-5.2", qualified);
}

test "task model qualification supports configured gateway providers" {
    const gpa = std.testing.allocator;
    const qualified = try task.qualifyModel(gpa, "acme/vendor/parent", "vendor/child");
    defer gpa.free(qualified);
    try std.testing.expectEqualStrings("acme/vendor/child", qualified);
}

test "task model qualification refuses parents without a provider-native model" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NoParentGateway, task.qualifyModel(gpa, "codex/default", "openai/gpt-5.2"));
    try std.testing.expectError(error.NoParentGateway, task.qualifyModel(gpa, "claudecode/sonnet", "anthropic/claude-opus-4.5"));
    try std.testing.expectError(error.NoParentGateway, task.qualifyModel(gpa, "anthropic/claude-sonnet-4-5", "openai/gpt-5.2"));
}

test "task model qualification requires a provider-native id" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidModel, task.qualifyModel(gpa, "openrouter/openai/gpt-5.2", "gpt-5.2"));
}

test "task schemas explain gateway inheritance" {
    try std.testing.expect(std.mem.indexOf(u8, task.spec_schema, "provider-native ids") != null);
    try std.testing.expect(std.mem.indexOf(u8, task.spec_schema, "inherit the parent's gateway") != null);
    try std.testing.expect(std.mem.indexOf(u8, task.batch_spec_schema, "inherits the parent's gateway") != null);
}
