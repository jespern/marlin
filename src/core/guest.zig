//! Guest-agent model routing shared by the wire protocol and daemon.
//!
//! A guest owns its inference loop, tools, and context. Marlin hosts its
//! process, persists the visible transcript, and mediates approvals.

const std = @import("std");

pub const Backend = enum {
    claude_code,
    codex,
};

pub fn backend(model: []const u8) ?Backend {
    if (std.mem.startsWith(u8, model, "claudecode/")) return .claude_code;
    if (std.mem.startsWith(u8, model, "codex/")) return .codex;
    return null;
}

pub fn isGuest(model: []const u8) bool {
    return backend(model) != null;
}

/// Provider-native model name. `default` asks the guest to retain its own
/// configured default rather than Marlin naming a concrete model.
pub fn modelName(model: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, model, '/') orelse return null;
    if (backend(model) == null or slash + 1 == model.len) return null;
    return model[slash + 1 ..];
}

test "guest backends are explicit model namespaces" {
    try std.testing.expectEqual(Backend.claude_code, backend("claudecode/sonnet").?);
    try std.testing.expectEqual(Backend.codex, backend("codex/default").?);
    try std.testing.expectEqualStrings("default", modelName("codex/default").?);
    try std.testing.expect(backend("openrouter/openai/gpt-5") == null);
    try std.testing.expect(backend("codex") == null);
    try std.testing.expect(modelName("codex/") == null);
}
