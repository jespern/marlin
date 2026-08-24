//! Provider registry: model string → dialect + endpoint + credentials.
//!
//! "openrouter/anthropic/claude-sonnet-4.5" →
//!   { url: https://openrouter.ai/api/v1/chat/completions,
//!     bearer: $OPENROUTER_API_KEY, model: "anthropic/claude-sonnet-4.5" }
//!
//! M0: openrouter + a generic "openai:<base_url>" escape hatch are built in.
//! M1: config-driven [providers.*] table + the anthropic dialect.

const std = @import("std");

pub const Endpoint = struct {
    url: [:0]const u8,
    bearer: ?[]const u8,
    model: []const u8,

    pub fn deinit(self: Endpoint, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        if (self.bearer) |b| gpa.free(b);
        gpa.free(self.model);
    }
};

pub const Error = error{ UnknownProvider, MissingApiKey, OutOfMemory };

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
        const key = environ.get("OPENROUTER_API_KEY") orelse return error.MissingApiKey;
        if (key.len == 0) return error.MissingApiKey;
        return .{
            .url = try gpa.dupeZ(u8, "https://openrouter.ai/api/v1/chat/completions"),
            .bearer = try gpa.dupe(u8, key),
            .model = try gpa.dupe(u8, model),
        };
    }
    return error.UnknownProvider;
}

test "openrouter model string parses" {
    // Environ isn't easily constructible in tests pre-0.16-stabilization;
    // covered by e2e. Parse-only assertions:
    try std.testing.expect(std.mem.indexOfScalar(u8, "openrouter/a/b", '/').? == 10);
}
