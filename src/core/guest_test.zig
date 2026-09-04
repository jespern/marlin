//! Unit tests for guest.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in guest.zig.

const std = @import("std");

const guest = @import("guest.zig");
const Backend = guest.Backend;
const backend = guest.backend;
const modelName = guest.modelName;

test {
    std.testing.refAllDecls(guest);
}

test "guest backends are explicit model namespaces" {
    try std.testing.expectEqual(Backend.claude_code, backend("claudecode/sonnet").?);
    try std.testing.expectEqual(Backend.codex, backend("codex/default").?);
    try std.testing.expectEqualStrings("default", modelName("codex/default").?);
    try std.testing.expect(backend("openrouter/openai/gpt-5") == null);
    try std.testing.expect(backend("codex") == null);
    try std.testing.expect(modelName("codex/") == null);
}
