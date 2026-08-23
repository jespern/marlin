//! bash tool: subprocess execution with cancellation.
//!
//! - SIGTERM → grace period → SIGKILL on interrupt.
//! - Output captured with a hard byte limit at CAPTURE (the full output goes
//!   to the blob store; the inline cap is applied by context.zig L0).
//! - cwd = session cwd. Env passthrough minus obvious secrets (M6 hardening).
//! - Sandboxing (M6): seatbelt profile (macOS) / Landlock+seccomp (Linux),
//!   deny-by-default on ~/.ssh, key files, browser profiles. (zag's pattern)

const std = @import("std");

// TODO(M0): run(argv=["bash","-lc",cmd], cwd, cancel_flag) → {stdout+stderr
//           interleaved, exit_code, duration_ms}.

test {
    std.testing.refAllDecls(@This());
}
