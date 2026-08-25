//! Provider registry: model string → dialect + endpoint + credentials.
//!
//! "openrouter/anthropic/claude-sonnet-4.5" →
//!   { url: https://openrouter.ai/api/v1/chat/completions,
//!     bearer: $OPENROUTER_API_KEY, model: "anthropic/claude-sonnet-4.5" }
//!
//! Built-in providers (M0):
//!   openrouter/<model>          — needs OPENROUTER_API_KEY
//!   local/<model>               — any OpenAI-compatible endpoint; base URL
//!                                 from MARLIN_LOCAL_BASE_URL, key optional
//!                                 from MARLIN_LOCAL_API_KEY. Also the e2e
//!                                 test seam (fake provider on localhost).
//!
//! Env override (all providers): MARLIN_BASE_URL_<PROVIDER> replaces the
//! base URL — e2e tests use MARLIN_BASE_URL_OPENROUTER to hit the fake
//! provider with production model strings.
//!
//! M1: config-driven [providers.*] table + the anthropic dialect.

const std = @import("std");
const provider = @import("provider.zig");

pub const Endpoint = struct {
    url: [:0]const u8,
    bearer: ?[]const u8,
    model: []const u8,
    dialect: provider.Dialect,

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
    model_str: []const u8,
) Error!Endpoint {
    const slash = std.mem.indexOfScalar(u8, model_str, '/') orelse return error.UnknownProvider;
    const provider_name = model_str[0..slash];
    const model = model_str[slash + 1 ..];
    if (model.len == 0) return error.UnknownProvider;

    if (std.mem.eql(u8, provider_name, "openrouter")) {
        const base = overrideBaseUrl(environ, "OPENROUTER") orelse "https://openrouter.ai/api/v1";
        const key = environ.get("OPENROUTER_API_KEY") orelse return error.MissingApiKey;
        if (key.len == 0) return error.MissingApiKey;
        return .{
            .url = try joinChatUrl(gpa, base),
            .bearer = try gpa.dupe(u8, key),
            .model = try gpa.dupe(u8, model),
            .dialect = .openrouter,
        };
    }
    if (std.mem.eql(u8, provider_name, "anthropic")) {
        const base = overrideBaseUrl(environ, "ANTHROPIC") orelse "https://api.anthropic.com/v1";
        const key = environ.get("ANTHROPIC_API_KEY") orelse return error.MissingApiKey;
        if (key.len == 0) return error.MissingApiKey;
        return .{
            .url = try joinMessagesUrl(gpa, base),
            // Carried as `bearer` but sent as x-api-key: the loop routes it
            // into headers for this dialect (Messages API has no bearer auth).
            .bearer = try gpa.dupe(u8, key),
            .model = try gpa.dupe(u8, model),
            .dialect = .anthropic,
        };
    }
    if (std.mem.eql(u8, provider_name, "local")) {
        const base = overrideBaseUrl(environ, "LOCAL") orelse
            (environ.get("MARLIN_LOCAL_BASE_URL") orelse return error.MissingBaseUrl);
        const key: ?[]const u8 = blk: {
            const k = environ.get("MARLIN_LOCAL_API_KEY") orelse break :blk null;
            break :blk if (k.len == 0) null else k;
        };
        return .{
            .url = try joinChatUrl(gpa, base),
            .bearer = if (key) |k| try gpa.dupe(u8, k) else null,
            .model = try gpa.dupe(u8, model),
            .dialect = .openai_compatible,
        };
    }
    return error.UnknownProvider;
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
pub fn openrouterModelsUrl(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) Error![:0]u8 {
    const base = overrideBaseUrl(environ, "OPENROUTER") orelse "https://openrouter.ai/api/v1";
    const trimmed = std.mem.trimEnd(u8, base, "/");
    return std.fmt.allocPrintSentinel(gpa, "{s}/models", .{trimmed}, 0) catch error.OutOfMemory;
}

test "anthropic models resolve to the Messages endpoint with x-api-key material" {
    const gpa = std.testing.allocator;
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("ANTHROPIC_API_KEY", "sk-ant-test");
    const ep = try resolve(gpa, &env, "anthropic/claude-sonnet-4-5");
    defer ep.deinit(gpa);
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ep.url);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", ep.model);
    try std.testing.expectEqual(provider.Dialect.anthropic, ep.dialect);
    try std.testing.expectEqualStrings("sk-ant-test", ep.bearer.?);

    var empty = std.process.Environ.Map.init(gpa);
    defer empty.deinit();
    try std.testing.expectError(error.MissingApiKey, resolve(gpa, &empty, "anthropic/claude-sonnet-4-5"));
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
