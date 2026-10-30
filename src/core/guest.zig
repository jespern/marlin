//! Guest-agent model routing shared by the wire protocol and daemon.
//!
//! A guest owns its inference loop, tools, and context. Marlin hosts its
//! process, persists the visible transcript, and mediates approvals.

const std = @import("std");

/// User-facing narration supplements the structured tool/activity stream.
pub const progress_instructions =
    "Keep the user informed with brief progress updates in ordinary assistant text. " ++
    "Before substantial work, say what you are checking and why. During longer work, " ++
    "share a concise update when you learn something useful, change direction, or begin " ++
    "a long operation: what you found, what it means, and what comes next. " ++
    "Use one or two short sentences, with occasional updates between tool batches. " ++
    "Tool descriptions alone are not progress updates. Avoid narrating every tool call, " ++
    "repeating unchanged status, or exposing private chain-of-thought; give findings " ++
    "and brief decision summaries instead. Follow the user's preferences for verbosity.";

pub const Backend = enum {
    claude_code,
    codex,
};

/// Call only on vendor error fields/stderr, never ordinary assistant prose.
pub fn isAuthFailure(text: []const u8) bool {
    for ([_][]const u8{
        "authentication_failed", "authentication_error",               "unauthorized",
        "invalid_grant",         "refresh_token_reused",               "refresh token has expired",
        "token has expired",     "token is expired",                   "access token expired",
        "oauth token expired",   "invalid authentication credentials", "invalid api key",
        "not logged in",         "please log in",                      "please login",
        "login required",        "session expired",                    "session has expired",
        "http 401",              "api error: 401",
    }) |needle| {
        if (text.len < needle.len) continue;
        for (0..text.len - needle.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return true;
        }
    }
    return false;
}

pub fn loginRequiredNote(which: Backend) []const u8 {
    return switch (which) {
        .claude_code => "Claude login required: authentication expired or was rejected. Run `claude auth login` on the daemon host, then retry this session. Your transcript is saved.",
        .codex => "Codex login required: authentication expired or was rejected. Run `codex login` on the daemon host, then retry this session. Your transcript is saved.",
    };
}

pub fn loginRequiredBackend(text: []const u8) ?Backend {
    if (std.mem.startsWith(u8, text, "Claude login required:")) return .claude_code;
    if (std.mem.startsWith(u8, text, "Codex login required:")) return .codex;
    return null;
}

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
