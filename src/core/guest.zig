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
