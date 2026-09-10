const std = @import("std");
const guest_models = @import("guest_models.zig");

test "Codex's own cache yields codex/<slug> for listed models only, deduplicated" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(arena, "codex/default");
    try guest_models.appendFromCodexCache(arena, &list,
        \\{"fetched_at":"2026-08-25T06:07:41Z","models":[
        \\ {"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","visibility":"list","priority":1},
        \\ {"slug":"codex-auto-review","visibility":"hide"},
        \\ {"slug":"gpt-5.5"},
        \\ {"slug":"gpt-5.6-sol","visibility":"list"},
        \\ {"slug":"","visibility":"list"}]}
    );
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("codex/gpt-5.6-sol", list.items[1]);
    try std.testing.expectEqualStrings("codex/gpt-5.5", list.items[2]);
}

test "a malformed or empty cache contributes nothing and is not an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    try guest_models.appendFromCodexCache(arena, &list, "{not json");
    try guest_models.appendFromCodexCache(arena, &list, "{}");
    try guest_models.appendFromCodexCache(arena, &list, "");
    try std.testing.expectEqual(@as(usize, 0), list.items.len);
}

test "the cache path honours CODEX_HOME, then HOME/.codex" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var buf: [512]u8 = undefined;
    try std.testing.expect(guest_models.codexCachePath(&buf, &env) == null);
    try env.put("HOME", "/Users/j");
    try std.testing.expectEqualStrings("/Users/j/.codex/models_cache.json", guest_models.codexCachePath(&buf, &env).?);
    try env.put("CODEX_HOME", "/opt/codex");
    try std.testing.expectEqualStrings("/opt/codex/models_cache.json", guest_models.codexCachePath(&buf, &env).?);
}
