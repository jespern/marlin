//! Concrete model ids the guest agents accept, for the model picker.
//!
//! Claude Code's ids are derived from the OpenRouter catalog's anthropic
//! slugs (daemon.appendNativeAnthropicIds). Codex's live account list comes
//! from its app-server (provider/codex.fetchModels) into the catalog; this
//! module reads the list Codex itself keeps in `models_cache.json` (what
//! its own picker shows) so the picker has concrete Codex models even when
//! that fetch is unavailable. Anything no list knows can still be typed
//! into the picker (tui.typedModelFallback).
const std = @import("std");

pub const prefix = "codex/";

const Cache = struct {
    models: []const struct {
        slug: []const u8,
        visibility: []const u8 = "list",
    } = &.{},
};

/// `codex/<slug>` for every model Codex lists (visibility "list"). Malformed
/// JSON is an empty contribution, not an error: the file is Codex's, not ours.
pub fn appendFromCodexCache(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), json: []const u8) !void {
    const cache = std.json.parseFromSliceLeaky(Cache, arena, json, .{ .ignore_unknown_fields = true }) catch return;
    for (cache.models) |m| {
        if (!std.mem.eql(u8, m.visibility, "list") or m.slug.len == 0) continue;
        try appendUnique(arena, list, try std.fmt.allocPrint(arena, prefix ++ "{s}", .{m.slug}));
    }
}

pub fn appendUnique(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), id: []const u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, id)) return;
    try list.append(arena, id);
}

/// Where Codex keeps its model cache: `$CODEX_HOME`, else `$HOME/.codex`.
pub fn codexCachePath(buf: []u8, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("CODEX_HOME")) |home| if (home.len > 0)
        return std.fmt.bufPrint(buf, "{s}/models_cache.json", .{home}) catch null;
    const home = environ.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/.codex/models_cache.json", .{home}) catch null;
}
