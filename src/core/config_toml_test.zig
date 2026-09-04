//! Unit tests for config_toml.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in config_toml.zig.

const std = @import("std");

const config_toml = @import("config_toml.zig");
const Policy = config_toml.Policy;
const parse = config_toml.parse;

test {
    std.testing.refAllDecls(config_toml);
}

test "parse Marlin config surface" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\[model]
        \\default = "local/qwen"
        \\favorites = ["local/qwen", "openrouter/anthropic/claude"]
        \\[approval]
        \\default_mutating = "auto"
        \\[[tools.exec]]
        \\name = "status"
        \\cmd = ["status-tool", "--json"]
        \\schema = '{"type":"object"}'
        \\mutating = false
        \\[[mcp]]
        \\name = "files"
        \\cmd = "mcp-files"
        \\readonly_tools = ["read", "list"]
        \\mutating_tools = ["write"]
        \\[hooks]
        \\on_turn_done = "/tmp/notify"
        \\[skills]
        \\directories = ["/tmp/skills"]
        \\[providers.openrouter]
        \\sort = "latency"
        \\[providers.acme]
        \\base_url = "https://models.acme.test/v1/"
        \\api_key_env = "ACME_API_KEY"
    );
    try std.testing.expectEqualStrings("local/qwen", doc.model_default.?);
    try std.testing.expectEqual(@as(usize, 2), doc.model_favorites.?.len);
    try std.testing.expectEqual(Policy.auto, doc.mutating_tools_policy.?);
    try std.testing.expectEqual(@as(usize, 1), doc.exec_tools.len);
    try std.testing.expectEqualStrings("status-tool", doc.exec_tools[0].cmd[0]);
    try std.testing.expect(!doc.exec_tools[0].mutating);
    try std.testing.expectEqualStrings("mcp-files", doc.mcp_servers[0].cmd[0]);
    try std.testing.expectEqualStrings("read", doc.mcp_servers[0].readonly_tools[0]);
    try std.testing.expectEqualStrings("write", doc.mcp_servers[0].mutating_tools[0]);
    try std.testing.expectEqualStrings("/tmp/notify", doc.hooks.on_turn_done.?);
    try std.testing.expectEqualStrings("latency", doc.openrouter_sort.?.?);
    try std.testing.expectEqual(@as(usize, 2), doc.providers.len);
    try std.testing.expectEqualStrings("openrouter", doc.providers[0].name);
    try std.testing.expect(doc.providers[0].base_url == null);
    try std.testing.expectEqualStrings("acme", doc.providers[1].name);
    try std.testing.expectEqualStrings("https://models.acme.test/v1/", doc.providers[1].base_url.?);
    try std.testing.expectEqualStrings("ACME_API_KEY", doc.providers[1].api_key_env.?);
}

test "known malformed values fail" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.ExpectedBoolean, parse(arena_state.allocator(),
        \\[permissions]
        \\enabled = "perhaps"
    ));
    try std.testing.expectError(error.ExecToolMissingCommand, parse(arena_state.allocator(),
        \\[[tools.exec]]
        \\name = "broken"
    ));
    try std.testing.expectError(error.ExpectedDuration, parse(arena_state.allocator(),
        \\[ui]
        \\screensaver_after = "eventually"
    ));
}

test "web tailscale and ui tab_bar flags parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\[web]
        \\enabled = true
        \\tailscale = false
        \\[ui]
        \\tab_bar = false
        \\bell = false
        \\screensaver_after = "10m"
        \\screensaver_effect = "strings"
        \\[model]
        \\default = "local/qwen"
    );
    try std.testing.expect(doc.web_enabled.?);
    try std.testing.expect(!doc.web_tailscale.?);
    try std.testing.expect(!doc.ui_tab_bar.?);
    try std.testing.expect(!doc.ui_bell.?);
    try std.testing.expectEqual(@as(u64, 600_000), doc.ui_screensaver_after_ms.?);
    try std.testing.expectEqualStrings("strings", doc.ui_screensaver_effect.?);
    try std.testing.expectEqualStrings("local/qwen", doc.model_default.?);
}

test "council tables parse name and roster" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\[[council]]
        \\name = "core"
        \\models = ["openrouter/x-ai/grok-4.6", "openrouter/z-ai/glm-5.3"]
        \\
        \\[[council]]
        \\name = "cheap"
        \\models = ["openrouter/z-ai/glm-5.3"]
        \\
    );
    try std.testing.expectEqual(@as(usize, 2), doc.councils.len);
    try std.testing.expectEqualStrings("core", doc.councils[0].name);
    try std.testing.expectEqual(@as(usize, 2), doc.councils[0].models.len);
    try std.testing.expectEqualStrings("openrouter/z-ai/glm-5.3", doc.councils[1].models[0]);

    // A council without models is a config error, not a silent empty roster.
    try std.testing.expectError(error.CouncilMissingModels, parse(
        arena_state.allocator(),
        "[[council]]\nname = \"empty\"\n",
    ));
}
