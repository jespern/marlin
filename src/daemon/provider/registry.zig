//! Provider registry: model string → native endpoint or guest backend.
//!
//! "openrouter/anthropic/claude-sonnet-4.5" →
//!   { url: https://openrouter.ai/api/v1/chat/completions,
//!     bearer: $OPENROUTER_API_KEY, model: "anthropic/claude-sonnet-4.5" }
//!
//! Built-in providers:
//!   openrouter/<model>          — needs OPENROUTER_API_KEY
//!   codex/<model>               — official app-server; ChatGPT login
//!   claudecode/<model>          — official claude binary; subscription login
//!   vercel/<model>              — Vercel AI Gateway; needs
//!                                 AI_GATEWAY_API_KEY
//!   litellm/<model>             — LiteLLM on 127.0.0.1:4000; key optional
//!   local/<model>               — any OpenAI-compatible endpoint; base URL
//!                                 from MARLIN_LOCAL_BASE_URL, key optional
//!                                 from MARLIN_LOCAL_API_KEY. local/testing
//!                                 defaults to the loopback fake-model port.
//!
//! Env override (all providers): MARLIN_BASE_URL_<PROVIDER> replaces the
//! base URL — e2e uses it privately to route local/testing and provider-
//! specific scenarios to a random-port fake server.
//!
//! Any `[providers.<name>]` table adds an OpenAI-compatible provider or
//! overrides a built-in provider's base URL / credential environment name.

const std = @import("std");
const provider = @import("provider.zig");
const config = @import("../../core/config.zig");

pub const testing_base_url = "http://127.0.0.1:5757/v1";

pub const Endpoint = struct {
    url: [:0]const u8,
    bearer: ?[]const u8,
    model: []const u8,
    backend: provider.Backend,

    pub fn deinit(self: Endpoint, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        if (self.bearer) |b| gpa.free(b);
        gpa.free(self.model);
    }
};

pub const Error = error{ UnknownProvider, MissingApiKey, MissingBaseUrl, OutOfMemory };

pub fn resolve(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    cfg: config.Config,
    model_str: []const u8,
) Error!Endpoint {
    const slash = std.mem.indexOfScalar(u8, model_str, '/') orelse return error.UnknownProvider;
    const provider_name = model_str[0..slash];
    const model = model_str[slash + 1 ..];
    if (model.len == 0) return error.UnknownProvider;

    if (std.mem.eql(u8, provider_name, "claudecode")) {
        // No wire endpoint: turns run through the official `claude` binary
        // under the user's own subscription login. "claudecode/default"
        // keeps Claude Code's configured model.
        return .{
            .url = std.fmt.allocPrintSentinel(gpa, "", .{}, 0) catch return error.OutOfMemory,
            .bearer = null,
            .model = try gpa.dupe(u8, model),
            .backend = .{ .guest = .claude_code },
        };
    }
    if (std.mem.eql(u8, provider_name, "codex")) {
        // No wire endpoint or API key: app-server uses the installed Codex
        // binary and its existing ChatGPT account session.
        return .{
            .url = std.fmt.allocPrintSentinel(gpa, "", .{}, 0) catch return error.OutOfMemory,
            .bearer = null,
            .model = try gpa.dupe(u8, model),
            .backend = .{ .guest = .codex },
        };
    }

    const configured = findConfigured(cfg, provider_name);

    if (std.mem.eql(u8, provider_name, "openrouter"))
        return resolveNative(gpa, environ, configured, .{
            .name = "openrouter",
            .base_url = "https://openrouter.ai/api/v1",
            .api_key_env = "OPENROUTER_API_KEY",
            .key_required = true,
            .dialect = .openrouter,
        }, model);
    if (std.mem.eql(u8, provider_name, "anthropic"))
        return resolveNative(gpa, environ, configured, .{
            .name = "anthropic",
            .base_url = "https://api.anthropic.com/v1",
            .api_key_env = "ANTHROPIC_API_KEY",
            .key_required = true,
            .dialect = .anthropic,
        }, model);
    if (std.mem.eql(u8, provider_name, "vercel"))
        return resolveNative(gpa, environ, configured, .{
            .name = "vercel",
            .base_url = "https://ai-gateway.vercel.sh/v1",
            .api_key_env = "AI_GATEWAY_API_KEY",
            .key_required = true,
        }, model);
    if (std.mem.eql(u8, provider_name, "litellm"))
        return resolveNative(gpa, environ, configured, .{
            .name = "litellm",
            .base_url = "http://127.0.0.1:4000/v1",
            .api_key_env = "LITELLM_API_KEY",
        }, model);
    if (std.mem.eql(u8, provider_name, "local")) {
        const base = overrideBaseUrl(environ, "LOCAL") orelse
            configuredBaseUrl(configured) orelse
            environ.get("MARLIN_LOCAL_BASE_URL") orelse
            if (std.mem.eql(u8, model, "testing")) testing_base_url else return error.MissingBaseUrl;
        const key = if (configuredApiKeyEnv(configured)) |env_name|
            try readApiKey(environ, env_name, true)
        else blk: {
            const value = environ.get("MARLIN_LOCAL_API_KEY") orelse break :blk null;
            break :blk if (value.len == 0) null else value;
        };
        return makeNativeEndpoint(gpa, base, key, model, .openai_compatible);
    }
    if (configured) |entry| {
        var env_key_buf: [128]u8 = undefined;
        const base = dynamicBaseUrlOverride(environ, provider_name, &env_key_buf) orelse
            entry.base_url orelse return error.MissingBaseUrl;
        const key = if (entry.api_key_env) |env_name|
            try readApiKey(environ, env_name, true)
        else
            null;
        return makeNativeEndpoint(gpa, base, key, model, .openai_compatible);
    }
    return error.UnknownProvider;
}

const NativePreset = struct {
    name: []const u8,
    base_url: []const u8,
    api_key_env: ?[]const u8 = null,
    key_required: bool = false,
    dialect: provider.Dialect = .openai_compatible,
};

fn resolveNative(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    configured: ?config.Provider,
    preset: NativePreset,
    model: []const u8,
) Error!Endpoint {
    var env_key_buf: [128]u8 = undefined;
    const base = dynamicBaseUrlOverride(environ, preset.name, &env_key_buf) orelse
        configuredBaseUrl(configured) orelse preset.base_url;
    const env_name = configuredApiKeyEnv(configured) orelse preset.api_key_env;
    const key = if (env_name) |name|
        try readApiKey(environ, name, preset.key_required or configuredApiKeyEnv(configured) != null)
    else
        null;
    return makeNativeEndpoint(gpa, base, key, model, preset.dialect);
}

fn makeNativeEndpoint(
    gpa: std.mem.Allocator,
    base: []const u8,
    key: ?[]const u8,
    model: []const u8,
    dialect: provider.Dialect,
) Error!Endpoint {
    const url = if (dialect == .anthropic) try joinMessagesUrl(gpa, base) else try joinChatUrl(gpa, base);
    errdefer gpa.free(url);
    const bearer = if (key) |value| try gpa.dupe(u8, value) else null;
    errdefer if (bearer) |value| gpa.free(value);
    const owned_model = try gpa.dupe(u8, model);
    return .{
        .url = url,
        .bearer = bearer,
        .model = owned_model,
        .backend = .{ .native = dialect },
    };
}

fn findConfigured(cfg: config.Config, name: []const u8) ?config.Provider {
    for (cfg.providers) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

fn configuredBaseUrl(entry: ?config.Provider) ?[]const u8 {
    return if (entry) |value| value.base_url else null;
}

fn configuredApiKeyEnv(entry: ?config.Provider) ?[]const u8 {
    return if (entry) |value| value.api_key_env else null;
}

fn readApiKey(environ: *const std.process.Environ.Map, env_name: []const u8, required: bool) Error!?[]const u8 {
    if (std.mem.eql(u8, env_name, "NONE")) return null;
    const value = environ.get(env_name) orelse {
        if (required) return error.MissingApiKey;
        return null;
    };
    if (value.len == 0) {
        if (required) return error.MissingApiKey;
        return null;
    }
    return value;
}

fn dynamicBaseUrlOverride(
    environ: *const std.process.Environ.Map,
    provider_name: []const u8,
    buf: *[128]u8,
) ?[]const u8 {
    const prefix = "MARLIN_BASE_URL_";
    if (provider_name.len > buf.len - prefix.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    for (provider_name, prefix.len..) |byte, i| {
        buf[i] = if (byte == '-') '_' else std.ascii.toUpper(byte);
    }
    const value = environ.get(buf[0 .. prefix.len + provider_name.len]) orelse return null;
    return if (value.len == 0) null else value;
}

fn overrideBaseUrl(environ: *const std.process.Environ.Map, comptime provider_name: []const u8) ?[]const u8 {
    const v = environ.get("MARLIN_BASE_URL_" ++ provider_name) orelse return null;
    return if (v.len == 0) null else v;
}

/// base ("https://host/api/v1" or with trailing slash) → ".../chat/completions"
fn joinChatUrl(gpa: std.mem.Allocator, base: []const u8) Error![:0]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrintSentinel(gpa, "{s}/chat/completions", .{trimmed}, 0) catch error.OutOfMemory;
}

/// base ("https://api.anthropic.com/v1") → ".../messages"
fn joinMessagesUrl(gpa: std.mem.Allocator, base: []const u8) Error![:0]u8 {
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrintSentinel(gpa, "{s}/messages", .{trimmed}, 0) catch error.OutOfMemory;
}

/// The OpenRouter models-catalog endpoint (honors the same base-url
/// override the chat endpoint uses, so e2e can fake it). Caller frees.
pub fn openrouterModelsUrl(
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    cfg: config.Config,
) Error![:0]u8 {
    const base = overrideBaseUrl(environ, "OPENROUTER") orelse
        configuredBaseUrl(findConfigured(cfg, "openrouter")) orelse
        "https://openrouter.ai/api/v1";
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrintSentinel(gpa, "{s}/models", .{trimmed}, 0) catch error.OutOfMemory;
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
