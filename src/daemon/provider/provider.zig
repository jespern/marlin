//! Provider interface (docs/ARCHITECTURE.md §5).
//!
//! One internal chat representation (blocks → Message list), N wire dialects.
//! A provider takes (messages, tool specs, model params) and yields a stream
//! of events; the agent loop is dialect-agnostic.

const std = @import("std");

pub const Role = enum { system, user, assistant, tool };

pub const Message = struct {
    role: Role,
    text: []const u8,
    // TODO(M0): tool_call / tool_result payload variants; cache_control
    //           annotations consumed only by the anthropic dialect.
};

/// Events yielded while streaming one model response.
pub const Event = union(enum) {
    delta: []const u8, // assistant text fragment
    reasoning_delta: []const u8,
    tool_call: struct { call_id: []const u8, name: []const u8, args_json: []const u8 },
    usage: struct { tokens_in: u64, tokens_out: u64 },
    done: void,
    stream_error: struct { retryable: bool, msg: []const u8 },
};

// TODO(M0): the vtable iface + openai_compat implementation; retry/backoff
//           policy lives in http.zig, dialect parsing in sse.zig callbacks.

test {
    std.testing.refAllDecls(@This());
}
