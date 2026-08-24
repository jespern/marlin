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
    parent_sid: ?u64 = null,
    kind: proto.SessionKind = .root,
    parent_block_id: ?u64 = null,
    max_rounds: u32 = 32,
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

// The daemon's live Session adds synchronization-only fields (thread, cancel,
// approval gate, task rendezvous); this value documents durable state.

test {
    std.testing.refAllDecls(@This());
}
