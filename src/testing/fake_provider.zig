//! Scripted OpenAI-compatible fake provider for e2e tests
//! (docs/ARCHITECTURE.md §11): a localhost HTTP server that replays
//! scripted SSE responses, letting `marlin run` be tested end to end —
//! tools, approvals, compaction triggers, resume — with zero network and
//! zero LLM mocks inside the binary under test.

const std = @import("std");

// TODO(M1): tiny std.net HTTP server, script format (request N → fixture
//           file), chunked SSE replay w/ deliberate pathological chunking.

test {
    std.testing.refAllDecls(@This());
}
