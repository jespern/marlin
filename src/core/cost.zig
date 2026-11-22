//! What guest agents cost, read from their own request logs (Claude Code's
//! ~/.claude/projects, Codex's ~/.codex/sessions): per backend, client and
//! model, and per Marlin session. Shared by the daemon (daemon/cost_report.zig
//! scans) and the client (`marlin diagnostics --cost` prints).
const std = @import("std");

pub const Group = struct {
    /// "claude_code" or "codex".
    backend: []const u8,
    /// "marlin" (a Marlin session's guest), "interactive" (the vendor's own
    /// terminal UI), or "other" (any other headless use).
    client: []const u8,
    model: []const u8,
    requests: u64 = 0,
    /// Input not served from the cache.
    input: u64 = 0,
    cache_read: u64 = 0,
    cache_write_5m: u64 = 0,
    cache_write_1h: u64 = 0,
    output: u64 = 0,
    /// Requests that wrote (Claude) or sent uncached (Codex) most of a
    /// context over 100K tokens: the cache had expired or the prefix changed.
    rewrites: u64 = 0,
    rewrite_tokens: u64 = 0,

    pub fn context(g: Group) u64 {
        return g.input + g.cache_read + g.cache_write_5m + g.cache_write_1h;
    }

    pub fn cachedPercent(g: Group) f64 {
        const total = g.context();
        if (total == 0) return 0;
        return @as(f64, @floatFromInt(g.cache_read)) * 100 / @as(f64, @floatFromInt(total));
    }
};

/// One Marlin session's Claude Code requests.
pub const Session = struct {
    sid: u64,
    handle: []const u8,
    title: []const u8,
    model: []const u8,
    requests: u64 = 0,
    context: u64 = 0,
    cost_units: u64 = 0,
    rewrites: u64 = 0,
    rewrite_tokens: u64 = 0,
};

pub const Report = struct {
    since_ms: i64,
    files: u64 = 0,
    groups: []const Group = &.{},
    sessions: []const Session = &.{},
};

/// Claude prices relative to fresh input: a cache read is 0.1, a write 1.25
/// (five-minute cache) or 2 (one hour), output 5.
pub const claude_weights = "fresh input 1 · cache read 0.1 · cache write 1.25 (5 min) or 2 (1 h) · output 5";

pub fn claudeCostUnits(input: u64, read: u64, write_5m: u64, write_1h: u64, output: u64) u64 {
    const units = @as(f64, @floatFromInt(input)) +
        @as(f64, @floatFromInt(read)) * 0.1 +
        @as(f64, @floatFromInt(write_5m)) * 1.25 +
        @as(f64, @floatFromInt(write_1h)) * 2 +
        @as(f64, @floatFromInt(output)) * 5;
    return @intFromFloat(units);
}

pub fn groupCostUnits(g: Group) u64 {
    return claudeCostUnits(g.input, g.cache_read, g.cache_write_5m, g.cache_write_1h, g.output);
}

/// A request that wrote or sent uncached most of a context over 100K tokens.
pub fn isRewrite(context: u64, fresh: u64) bool {
    return context > 100_000 and fresh * 2 > context;
}

/// "412K", "1.2M", "830".
pub fn formatTokens(buf: []u8, tokens: u64) []const u8 {
    if (tokens >= 10_000_000) return std.fmt.bufPrint(buf, "{d}M", .{tokens / 1_000_000}) catch "?";
    if (tokens >= 1_000_000) return std.fmt.bufPrint(buf, "{d}.{d}M", .{ tokens / 1_000_000, (tokens % 1_000_000) / 100_000 }) catch "?";
    if (tokens >= 1_000) return std.fmt.bufPrint(buf, "{d}K", .{tokens / 1_000}) catch "?";
    return std.fmt.bufPrint(buf, "{d}", .{tokens}) catch "?";
}
