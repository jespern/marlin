//! Provider registry: model string → dialect + endpoint + credentials.
//!
//! "openrouter/anthropic/claude-sonnet-4.5" →
//!   { dialect: openai_compat, base: https://openrouter.ai/api/v1,
//!     key_env: OPENROUTER_API_KEY, model: "anthropic/claude-sonnet-4.5" }
//!
//! Built-in entries: openrouter (default). config.toml [providers.*] adds
//! any OpenAI-compatible endpoint with zero code (base_url + api_key_env).

const std = @import("std");

// TODO(M0): openrouter hardcoded. TODO(M1): config-driven table + anthropic.

test {
    std.testing.refAllDecls(@This());
}
