//! Session state machine.
//!
//! States: idle → running → (awaiting_approval ⇄ running) → idle | err | done.
//! One session = one block log + one optional in-flight turn (thread).
//! The daemon thread owns Session structs exclusively; agent threads only
//! communicate via the event queue.

const std = @import("std");
const proto = @import("../core/proto.zig");

pub const Session = struct {
    id: u64,
    title: []const u8,
    cwd: []const u8,
    model: []const u8,
    effort: proto.ReasoningEffort = .auto,
    state: proto.SessionState = .idle,
    /// Highest block seq persisted; next block gets last_seq + 1.
    last_seq: u64 = 0,
    /// Provider-reported usage, updated every turn (no tokenizers).
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
};

// TODO(M1): steer queue, pending approval set, in-flight turn handle
// (thread + cancel flag), parent/child links for subagents (M6).

test {
    std.testing.refAllDecls(@This());
}
