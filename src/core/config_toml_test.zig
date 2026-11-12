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

test "web exposure and ui tab_bar flags parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const doc = try parse(arena_state.allocator(),
        \\[web]
        \\enabled = true
        \\listen = "0.0.0.0"
        \\hosts = ["marlin.example.com", "victory.local"]
        \\proxy = "192.168.1.1"
        \\push = true
        \\[ui]
        \\tab_bar = false
        \\bell = false
        \\stream_pacing = true
        \\screensaver_after = "10m"
        \\screensaver_effect = "strings"
        \\shell_prefix = "ctrl+b"
        \\[model]
        \\default = "local/qwen"
    );
    try std.testing.expect(doc.web_enabled.?);
    try std.testing.expectEqualStrings("0.0.0.0", doc.web_listen.?);
    try std.testing.expectEqual(@as(usize, 2), doc.web_hosts.?.len);
    try std.testing.expectEqualStrings("victory.local", doc.web_hosts.?[1]);
    try std.testing.expectEqualStrings("192.168.1.1", doc.web_proxy.?);
    try std.testing.expect(doc.web_push.?);
    try std.testing.expect(!doc.ui_tab_bar.?);
    try std.testing.expect(!doc.ui_bell.?);
    try std.testing.expect(doc.ui_stream_pacing.?);
    try std.testing.expectEqual(@as(u64, 600_000), doc.ui_screensaver_after_ms.?);
    try std.testing.expectEqualStrings("strings", doc.ui_screensaver_effect.?);
    try std.testing.expectEqualStrings("ctrl+b", doc.ui_shell_prefix.?);
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

test "companion port accepts explicit ports and rejects zero or overflow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parse(arena.allocator(), "[web]\nport = 8378\n");
    try std.testing.expectEqual(@as(?u16, 8378), doc.web_port);
    try std.testing.expectError(error.InvalidValue, parse(arena.allocator(), "[web]\nport = 0\n"));
    try std.testing.expectError(error.ExpectedUnsigned, parse(arena.allocator(), "[web]\nport = 65536\n"));
}

test "[discovery] enabled parses; absent stays null so the default (on) applies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const off = try parse(arena.allocator(), "[discovery]\nenabled = false\n");
    try std.testing.expect(!off.discovery_enabled.?);
    const on = try parse(arena.allocator(), "[discovery]\nenabled = true\n");
    try std.testing.expect(on.discovery_enabled.?);
    const absent = try parse(arena.allocator(), "[web]\nport = 8378\n");
    try std.testing.expect(absent.discovery_enabled == null);
}

test "remote MCP servers parse url, headers, and env, and need exactly one of cmd/url" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const doc = try parse(arena,
        \\[[mcp]]
        \\name = "linear"
        \\url = "https://mcp.linear.app/mcp"
        \\headers = ["X-Team: core"]
        \\mutating = false
        \\
        \\[[mcp]]
        \\name = "files"
        \\cmd = ["mcp-files"]
        \\env = ["ROOT=/srv"]
    );
    try std.testing.expectEqual(@as(usize, 2), doc.mcp_servers.len);
    try std.testing.expectEqualStrings("https://mcp.linear.app/mcp", doc.mcp_servers[0].url.?);
    try std.testing.expectEqualStrings("X-Team: core", doc.mcp_servers[0].headers[0]);
    try std.testing.expect(!doc.mcp_servers[0].mutating);
    try std.testing.expectEqual(@as(usize, 0), doc.mcp_servers[0].cmd.len);
    try std.testing.expectEqualStrings("ROOT=/srv", doc.mcp_servers[1].env[0]);
    try std.testing.expectError(error.McpServerMissingCommand, parse(arena,
        \\[[mcp]]
        \\name = "both"
        \\cmd = ["x"]
        \\url = "https://example.com/mcp"
    ));
}
