//! Unit tests for registry.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in registry.zig.

const std = @import("std");
const provider = @import("provider.zig");
const config = @import("../../core/config.zig");

const registry = @import("registry.zig");
const joinChatUrl = registry.joinChatUrl;
const openrouterModelsUrl = registry.openrouterModelsUrl;
const resolve = registry.resolve;

test {
    std.testing.refAllDecls(registry);
}

test "anthropic models resolve to the Messages endpoint with x-api-key material" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("ANTHROPIC_API_KEY", "sk-ant-test");
    const ep = try resolve(gpa, &env, config.defaults(), "anthropic/claude-sonnet-4-5");
    defer ep.deinit(gpa);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ep.url);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", ep.model);
    try std.testing.expectEqualStrings("anthropic", ep.provider_name);
    try std.testing.expectEqual(provider.Dialect.anthropic, ep.backend.native);
    try std.testing.expectEqualStrings("sk-ant-test", ep.bearer.?);

    var empty = std.process.Environ.Map.init(gpa);
    defer empty.deinit();
    try std.testing.expectError(error.MissingApiKey, resolve(gpa, &empty, config.defaults(), "anthropic/claude-sonnet-4-5"));
}

test "joinChatUrl normalizes trailing slash" {
    const gpa = std.testing.allocator;
    const a = try joinChatUrl(gpa, "http://127.0.0.1:9999/v1/");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("http://127.0.0.1:9999/v1/chat/completions", a);
    const b = try joinChatUrl(gpa, "http://127.0.0.1:9999/v1");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("http://127.0.0.1:9999/v1/chat/completions", b);
}

test "local testing resolves to the keyless loopback fake model by default" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const ep = try resolve(gpa, &env, config.defaults(), "local/testing");
    defer ep.deinit(gpa);
    try std.testing.expectEqualStrings("http://127.0.0.1:5757/v1/chat/completions", ep.url);
    try std.testing.expectEqualStrings("testing", ep.model);
    try std.testing.expectEqualStrings("local", ep.provider_name);
    try std.testing.expect(ep.bearer == null);
    try std.testing.expectEqual(provider.Dialect.openai_compatible, ep.backend.native);

    try std.testing.expectError(error.MissingBaseUrl, resolve(gpa, &env, config.defaults(), "local/other"));
}

test "configured OpenAI-compatible provider resolves its endpoint and credential" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("ACME_API_KEY", "acme-secret");
    const cfg = config.Config{ .providers = &.{.{
        .name = "acme",
        .base_url = "https://gateway.acme.test/v1/",
        .api_key_env = "ACME_API_KEY",
    }} };

    const ep = try resolve(gpa, &env, cfg, "acme/vendor/model");
    defer ep.deinit(gpa);
    try std.testing.expectEqualStrings("https://gateway.acme.test/v1/chat/completions", ep.url);
    try std.testing.expectEqualStrings("vendor/model", ep.model);
    try std.testing.expectEqualStrings("acme-secret", ep.bearer.?);
    try std.testing.expectEqual(provider.Dialect.openai_compatible, ep.backend.native);

    var empty = std.process.Environ.Map.init(gpa);
    defer empty.deinit();
    try std.testing.expectError(error.MissingApiKey, resolve(gpa, &empty, cfg, "acme/vendor/model"));
}

test "Vercel and LiteLLM presets need no provider table" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("AI_GATEWAY_API_KEY", "vercel-secret");

    const vercel = try resolve(gpa, &env, config.defaults(), "vercel/anthropic/claude-sonnet-4");
    defer vercel.deinit(gpa);
    try std.testing.expectEqualStrings("https://ai-gateway.vercel.sh/v1/chat/completions", vercel.url);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", vercel.model);
    try std.testing.expectEqualStrings("vercel-secret", vercel.bearer.?);

    const litellm = try resolve(gpa, &env, config.defaults(), "litellm/fast-code");
    defer litellm.deinit(gpa);
    try std.testing.expectEqualStrings("http://127.0.0.1:4000/v1/chat/completions", litellm.url);
    try std.testing.expectEqualStrings("fast-code", litellm.model);
    try std.testing.expect(litellm.bearer == null);
}

test "provider tables override presets and NONE deliberately disables auth" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    const cfg = config.Config{ .providers = &.{.{
        .name = "vercel",
        .base_url = "http://127.0.0.1:9000/v1",
        .api_key_env = "NONE",
    }} };

    const ep = try resolve(gpa, &env, cfg, "vercel/test-model");
    defer ep.deinit(gpa);
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/v1/chat/completions", ep.url);
    try std.testing.expect(ep.bearer == null);

    const catalog_url = try openrouterModelsUrl(gpa, &env, .{ .providers = &.{.{
        .name = "openrouter",
        .base_url = "http://127.0.0.1:9100/v1",
    }} });
    defer gpa.free(catalog_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:9100/v1/models", catalog_url);
}

test "guest agents resolve without API credentials" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    const cc = try resolve(gpa, &env, config.defaults(), "claudecode/default");
    defer cc.deinit(gpa);
    try std.testing.expectEqual(provider.Guest.claude_code, cc.backend.guest);

    const codex = try resolve(gpa, &env, config.defaults(), "codex/default");
    defer codex.deinit(gpa);
    try std.testing.expectEqual(provider.Guest.codex, codex.backend.guest);
    try std.testing.expect(codex.bearer == null);
}
