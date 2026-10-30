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

test "guest authentication failures have actionable host-specific login instructions" {
    for ([_][]const u8{ "OAuth token expired", "API Error: 401", "authentication_failed", "refresh_token_reused", "Your session has expired", "Not logged in · Please run /login" }) |message|
        try std.testing.expect(guest.isAuthFailure(message));
    for ([_][]const u8{ "HTTP 403 permission denied", "HTTP 429 rate limited", "HTTP 500 Internal Server Error", "request timeout", "No conversation found with session ID: x" }) |message|
        try std.testing.expect(!guest.isAuthFailure(message));
    for ([_]Backend{ .claude_code, .codex }) |which| {
        const note = guest.loginRequiredNote(which);
        try std.testing.expectEqual(which, guest.loginRequiredBackend(note).?);
        try std.testing.expect(guest.isAuthFailure(note));
        try std.testing.expect(std.mem.indexOf(u8, note, "daemon host") != null);
    }
}
