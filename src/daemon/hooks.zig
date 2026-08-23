//! Hook runner: daemon events → user scripts (docs/ARCHITECTURE.md §7).
//!
//! Events: on_session_done, on_approval_needed, on_error, on_turn_done.
//! Contract: run the configured script with the JSON event on stdin, 10s
//! timeout, exit code logged but never fatal. This is the notification story
//! (ntfy/Telegram/say) without a gateway in the core.

const std = @import("std");

// TODO(M5).

test {
    std.testing.refAllDecls(@This());
}
