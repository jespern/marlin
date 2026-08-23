//! OpenAI-compatible dialect: OpenRouter (default), OpenAI, DeepSeek, Groq,
//! local llama.cpp/vLLM — anything speaking /chat/completions.
//!
//! Relies on implicit prefix caching server-side; our append-only assembly
//! discipline maximizes hits automatically. Usage comes from the final SSE
//! `usage` object (OpenRouter sends it on every response).

const std = @import("std");

// TODO(M0): request body build (messages, tools, stream:true,
//           stream_options.include_usage), SSE event parse → provider.Event,
//           tool_call fragment reassembly (arguments arrive in pieces!),
//           finish_reason handling.

test {
    std.testing.refAllDecls(@This());
}
