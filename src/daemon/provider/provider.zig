//! Provider interface (docs/ARCHITECTURE.md §5).
//!
//! One internal chat representation (blocks → Message list), two native wire
//! dialects. A provider takes (messages, tool specs, model params) and yields
//! a stream of events; the native agent loop is dialect-agnostic.
//!
//! `claude_code` is listed on Dialect today because registry.resolve still
//! returns an Endpoint. That is a leak: guest sessions are not a wire
//! dialect (docs/ARCHITECTURE.md, Native vs guest). Do not add a fifth tag.

const std = @import("std");

/// Reasoning-effort fields differ between OpenRouter and the OpenAI Chat
/// Completions-compatible endpoints used for local models; `anthropic` is
/// the Messages API (anthropic.zig), the one non-OpenAI wire shape shipped.
/// `claude_code` is not a wire dialect at all: turns are delegated to the
/// official `claude` binary (claude_code.zig) so subscription inference
/// stays inside Anthropic's sanctioned surface.
pub const Dialect = enum { openrouter, openai_compatible, anthropic, claude_code };

pub const Role = enum { system, user, assistant, tool };

pub const ToolCall = struct {
    call_id: []const u8,
    name: []const u8,
    /// Raw JSON arguments string.
    args_json: []const u8,
};

pub const Media = struct {
    name: []const u8,
    mime: []const u8,
    data_base64: []const u8,
};

pub const Message = struct {
    role: Role,
    payload: Payload,
    /// OpenRouter explicit provider-cache breakpoint. Ignored by generic
    /// OpenAI-compatible endpoints and models with implicit caching.
    cache_breakpoint: bool = false,

    pub const Payload = union(enum) {
        /// Plain text content (system/user/assistant text messages).
        text: []const u8,
        /// User-authored text plus durable binary attachments resolved from
        /// the blob store for this provider request.
        user_content: struct {
            text: []const u8,
            media: []const Media,
        },
        /// Assistant turn that requested tool calls (text may be empty).
        assistant_tool_calls: struct {
            text: []const u8,
            calls: []const ToolCall,
        },
        /// Result of one tool call, echoed back to the model.
        tool_result: struct {
            call_id: []const u8,
            text: []const u8,
            media: []const Media = &.{},
        },
    };
};

pub const Usage = struct {
    tokens_in: u64,
    tokens_out: u64,
    cached_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    web_search_requests: u64 = 0,
};

test {
    std.testing.refAllDecls(@This());
}
