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
    provider_name: []const u8,
    backend: provider.Backend,

    pub fn deinit(self: Endpoint, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        if (self.bearer) |b| gpa.free(b);
        gpa.free(self.model);
        gpa.free(self.provider_name);
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
            .provider_name = try gpa.dupe(u8, "anthropic"),
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
            .provider_name = try gpa.dupe(u8, "openai"),
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
        return makeNativeEndpoint(gpa, base, key, model, "local", .openai_compatible);
    }
    if (configured) |entry| {
        var env_key_buf: [128]u8 = undefined;
        const base = dynamicBaseUrlOverride(environ, provider_name, &env_key_buf) orelse
            entry.base_url orelse return error.MissingBaseUrl;
        const key = if (entry.api_key_env) |env_name|
            try readApiKey(environ, env_name, true)
        else
            null;
        return makeNativeEndpoint(gpa, base, key, model, provider_name, .openai_compatible);
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
    return makeNativeEndpoint(gpa, base, key, model, preset.name, preset.dialect);
}

fn makeNativeEndpoint(
    gpa: std.mem.Allocator,
    base: []const u8,
    key: ?[]const u8,
    model: []const u8,
    provider_name: []const u8,
    dialect: provider.Dialect,
) Error!Endpoint {
    const url = if (dialect == .anthropic) try joinMessagesUrl(gpa, base) else try joinChatUrl(gpa, base);
    errdefer gpa.free(url);
    const bearer = if (key) |value| try gpa.dupe(u8, value) else null;
    errdefer if (bearer) |value| gpa.free(value);
    const owned_model = try gpa.dupe(u8, model);
    errdefer gpa.free(owned_model);
    const owned_provider_name = try gpa.dupe(u8, provider_name);
    return .{
        .url = url,
        .bearer = bearer,
        .model = owned_model,
        .provider_name = owned_provider_name,
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
pub fn joinChatUrl(gpa: std.mem.Allocator, base: []const u8) Error![:0]u8 {
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
