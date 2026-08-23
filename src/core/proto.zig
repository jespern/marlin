//! Wire protocol between clients and the daemon.
//!
//! Transport: NDJSON over a unix socket (optionally TCP, token-authed).
//! Every message is one JSON object per line with a `t` discriminator.
//! See docs/ARCHITECTURE.md §3 and docs/PROTOCOL.md.
//!
//! Disciplines:
//!   - Deltas are ephemeral; blocks are truth. Clients render deltas for
//!     liveness, then replace them with the finalized block.
//!   - Subscriptions carry `from_seq`; the daemon replays the gap, then goes
//!     live. Reconnect is therefore trivial.

const std = @import("std");
const block = @import("block.zig");

pub const proto_version: u32 = 1;

pub const SessionState = enum { idle, running, awaiting_approval, err, done };

/// Client → daemon.
pub const ClientMsg = union(enum) {
    hello: struct { proto_version: u32, client_kind: []const u8 },
    session_create: struct { cwd: []const u8, model: ?[]const u8, title: ?[]const u8 },
    session_list: struct {},
    session_kill: struct { sid: u64 },
    session_rename: struct { sid: u64, title: []const u8 },
    sub: struct { sid: u64, from_seq: u64 },
    unsub: struct { sid: u64 },
    input: struct { sid: u64, text: []const u8 },
    approve: struct { sid: u64, approval_id: []const u8, decision: block.ApprovalDecision },
    interrupt: struct { sid: u64 },
    compact: struct { sid: u64, instructions: ?[]const u8 },
    copy_query: struct { sid: u64, what: CopyWhat },
    blocks_get: struct { sid: u64, before_seq: u64, limit: u32 },
};

pub const CopyWhat = enum { last_tool_result, last_msg, last_code, last_cmd, all };

/// Daemon → client.
pub const DaemonMsg = union(enum) {
    hello_ok: struct { proto_version: u32, daemon_version: []const u8 },
    block: struct { sid: u64, blk: block.Block },
    delta: struct { sid: u64, turn_id: u64, text: []const u8 },
    status: struct { sid: u64, state: SessionState },
    approval_request: struct {
        sid: u64,
        approval_id: []const u8,
        tool: []const u8,
        args_preview: []const u8,
    },
    session_meta: struct {
        sid: u64,
        title: []const u8,
        model: []const u8,
        state: SessionState,
        tokens_in: u64,
        tokens_out: u64,
    },
    copy_result: struct { sid: u64, text: []const u8 },
    err: struct { code: []const u8, msg: []const u8 },
};

// TODO(M1): encode/decode via std.json with ignore_unknown_fields, plus a
// fuzz-ish golden test replaying recorded NDJSON transcripts (testing/fixtures).

test "protocol types compile" {
    const m: ClientMsg = .{ .sub = .{ .sid = 1, .from_seq = 0 } };
    try std.testing.expect(std.meta.activeTag(m) == .sub);
}
