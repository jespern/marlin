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
