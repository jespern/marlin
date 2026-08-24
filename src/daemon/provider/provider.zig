//! Provider interface (docs/ARCHITECTURE.md §5).
//!
//! One internal chat representation (blocks → Message list), N wire dialects.
//! A provider takes (messages, tool specs, model params) and yields a stream
//! of events; the agent loop is dialect-agnostic.

const std = @import("std");

/// Reasoning-effort fields differ between OpenRouter and the OpenAI Chat
/// Completions-compatible endpoints used for local models.
pub const Dialect = enum { openrouter, openai_compatible };

pub const Role = enum { system, user, assistant, tool };

pub const ToolCall = struct {
    call_id: []const u8,
    name: []const u8,
    /// Raw JSON arguments string.
    args_json: []const u8,
};

pub const Message = struct {
    role: Role,
    payload: Payload,

    pub const Payload = union(enum) {
        /// Plain text content (system/user/assistant text messages).
        text: []const u8,
        /// Assistant turn that requested tool calls (text may be empty).
        assistant_tool_calls: struct {
            text: []const u8,
            calls: []const ToolCall,
        },
        /// Result of one tool call, echoed back to the model.
        tool_result: struct {
            call_id: []const u8,
            text: []const u8,
        },
    };
};

pub const Usage = struct {
    tokens_in: u64,
    tokens_out: u64,
};

test {
    std.testing.refAllDecls(@This());
}
