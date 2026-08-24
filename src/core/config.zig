//! Configuration: ~/.config/marlin/config.toml → Config struct.
//!
//! v1 keys are documented in docs/ARCHITECTURE.md §9. Until the TOML dep
//! lands (M1), M0 runs on defaults + environment (OPENROUTER_API_KEY).

const std = @import("std");

pub const Config = struct {
    model_default: []const u8 = "openrouter/anthropic/claude-sonnet-4.5",
    model_compaction: ?[]const u8 = null, // null → use model_default

    /// Context engine (docs/ARCHITECTURE.md §6).
    output_headroom_tokens: u32 = 16_000,
    compaction_headroom_tokens: u32 = 8_000,
    inline_tool_cap_bytes: u32 = 8_000,
    prune_protect_tokens: u32 = 40_000, // OpenCode constants
    prune_min_reclaim_tokens: u32 = 20_000,

    /// Approval defaults (docs/ARCHITECTURE.md §7).
    mutating_tools_policy: Policy = .ask,
    readonly_tools_policy: Policy = .auto,

    /// Workspace layer (docs/WORKSPACE.md): shadow snapshots, write leases,
    /// sandbox escalations. Master switch — OFF until M3.5 lands; M2
    /// approval semantics hold while false.
    workspace_enabled: bool = false,

    pub const Policy = enum { auto, ask, deny };
};

pub fn defaults() Config {
    return .{};
}

// TODO(M1): TOML loading (zig-toml), provider table, exec tools, MCP servers,
// hooks. Config file is read once by the daemon at startup + on SIGHUP.

test "defaults are sane" {
    const c = defaults();
    try std.testing.expect(c.output_headroom_tokens > 0);
    try std.testing.expect(c.prune_protect_tokens > c.prune_min_reclaim_tokens);
}
