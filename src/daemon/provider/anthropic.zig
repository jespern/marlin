//! Anthropic Messages dialect — the one non-OpenAI-compat API worth having:
//! explicit cache_control breakpoints (system prompt + last stable message
//! before the tail) buy large real savings on long agent sessions.

const std = @import("std");

// TODO(M1.5/M3): Messages API request build, content-block SSE parse,
//                cache_control placement, usage mapping.

test {
    std.testing.refAllDecls(@This());
}
