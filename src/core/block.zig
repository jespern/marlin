//! The block log: marlin's atom of state.
//!
//! A session is an append-only sequence of immutable Blocks. Every feature
//! (rendering, scrollback, copy, compaction, resume, search) is a view over
//! this log. See docs/ARCHITECTURE.md §2.
//!
//! Invariants:
//!   - Blocks are never mutated or deleted once appended.
//!   - `seq` is contiguous and strictly increasing per session.
//!   - Context assembly derives from blocks; it never feeds back into them
//!     (compaction adds a `compaction` block, it rewrites nothing).

const std = @import("std");

pub const BlockKind = enum {
    user_msg,
    assistant_msg,
    reasoning,
    tool_call,
    tool_result,
    approval,
    steer,
    compaction,
    system_note,
};

pub const ToolStatus = enum { ok, err, denied, interrupted };

pub const ApprovalDecision = enum { granted, denied, timeout };

/// Kind-specific payloads. Serialized as JSON into blocks.body_json;
/// unknown fields are ignored on read (forward compat, see MILESTONES open Q3).
pub const Body = union(BlockKind) {
    user_msg: struct {
        text: []const u8,
        /// Internal context injected after compaction. It remains model-visible
        /// but clients must not present it as authored user input or history.
        synthetic: bool = false,
    },
    assistant_msg: struct { text: []const u8 },
    reasoning: struct { text: []const u8 },
    tool_call: struct {
        call_id: []const u8,
        name: []const u8,
        /// Raw JSON arguments as sent to the tool (post lenient-repair).
        args_json: []const u8,
    },
    tool_result: struct {
        call_id: []const u8,
        status: ToolStatus,
        /// Capped head+tail copy eligible for model context (L0 cap).
        inline_body: []const u8,
        /// Content hash into the blobs table for the FULL output; null when
        /// the output fit inline uncapped. `!c` and scrollback prefer this.
        full_body_ref: ?[]const u8,
    },
    approval: struct {
        approval_id: []const u8,
        call_id: []const u8,
        decision: ?ApprovalDecision, // null while pending
        decided_by: ?[]const u8, // client id
    },
    steer: struct { text: []const u8 },
    compaction: struct {
        /// Reconstruction-grade summary (see context.zig contract).
        summary: []const u8,
        /// Range of block seqs this summary replaces in context assembly.
        covers_from_seq: u64,
        covers_to_seq: u64,
    },
    system_note: struct { text: []const u8 },
};

pub const Block = struct {
    /// Globally unique block id.
    id: u64,
    session_id: u64,
    /// Groups the blocks of one agent turn (user msg → ... → assistant msg).
    turn_id: u64,
    /// Position in the session log; contiguous, starts at 1.
    seq: u64,
    /// Unix millis.
    ts: i64,
    body: Body,

    pub fn kind(self: Block) BlockKind {
        return std.meta.activeTag(self.body);
    }
};

test "block kind follows body tag" {
    const b = Block{
        .id = 1,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "hi" } },
    };
    try std.testing.expectEqual(BlockKind.user_msg, b.kind());
}

test "older user blocks decode with synthetic disabled" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const body = try std.json.parseFromSliceLeaky(
        Body,
        arena_state.allocator(),
        "{\"user_msg\":{\"text\":\"hello\"}}",
        .{ .ignore_unknown_fields = true },
    );
    try std.testing.expectEqualStrings("hello", body.user_msg.text);
    try std.testing.expect(!body.user_msg.synthetic);
}
