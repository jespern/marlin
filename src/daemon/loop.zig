//! The agent turn loop (docs/ARCHITECTURE.md §4).
//!
//! Runs on its own thread per turn:
//!
//!   assemble context (context.zig)
//!   loop:
//!     stream POST to provider (SSE) → delta events; collect tool_calls
//!     if none → finalize assistant_msg block; done
//!     for each tool_call:
//!       approval gate (approval.zig) — may park in awaiting_approval
//!       execute (tools/registry.zig) → tool_result block
//!     drain steer queue → inject steer block as user-role message
//!     repeat
//!
//! Cancellation: atomic flag polled by the HTTP read loop and subprocess
//! waits. Retry: exponential backoff on 429/5xx/mid-stream drop; partial
//! deltas are discarded (they were never truth) and the request re-issued
//! against unchanged context — safe and cache-friendly.

const std = @import("std");

// TODO(M0): single-turn version, no daemon: run(store, session, user_text)
//           with auto-approved bash+read_file and stdout delta printing.
// TODO(M1): thread spawn, event queue emission, steer queue, interrupt flag.
// TODO(M1): parallel_safe tool batching (read-only tools concurrently).

test {
    std.testing.refAllDecls(@This());
}
