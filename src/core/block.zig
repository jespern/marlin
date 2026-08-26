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
    plan,
    compaction,
    system_note,
};

pub const ToolStatus = enum { ok, err, denied, interrupted };

pub const ApprovalDecision = enum { granted, denied, timeout };

pub const PlanStatus = enum { pending, in_progress, completed };

pub const PlanItem = struct {
    step: []const u8,
    status: PlanStatus,
    /// Daemon-owned timing metadata. The model-facing plan tool never sets
    /// these; defaults keep old blocks and clients wire-compatible.
    started_at_ms: i64 = 0,
    duration_ms: u64 = 0,
};

/// Durable reference to binary media stored in the content-addressed blob
/// table. Blocks carry only metadata; replay never inflates the transcript
/// with base64 image bodies.
pub const MediaRef = struct {
    hash: []const u8,
    mime: []const u8,
    name: []const u8,
    byte_len: u64,
};

/// Kind-specific payloads. Serialized as JSON into blocks.body_json;
/// unknown fields are ignored on read (forward compat, see MILESTONES open Q3).
pub const Body = union(BlockKind) {
    user_msg: struct {
        text: []const u8,
        attachments: []const MediaRef = &.{},
        /// Internal context injected after compaction. It remains model-visible
        /// but clients must not present it as authored user input or history.
        synthetic: bool = false,
    },
    assistant_msg: struct { text: []const u8 },
    reasoning: struct {
        text: []const u8,
        /// True for the model's deliberate mid-turn narration (content
        /// emitted alongside tool calls); false for the provider's raw
        /// reasoning stream, which some models (grok) fill with drafted
        /// replies and summarizer fragments. Clients fold raw reasoning out
        /// of the default view; narration stays. Old blocks decode as false.
        commentary: bool = false,
    },
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
        /// Binary tool output (currently MCP images), stored in the same
        /// content-addressed blob table as user-authored attachments.
        attachments: []const MediaRef = &.{},
    },
    approval: struct {
        approval_id: []const u8,
        call_id: []const u8,
        decision: ?ApprovalDecision, // null while pending
        decided_by: ?[]const u8, // client id
    },
    steer: struct { text: []const u8 },
    /// One immutable plan revision. The newest revision is the current plan;
    /// completed revisions remain in the log as execution history.
    plan: struct { items: []const PlanItem },
    compaction: struct {
        /// Reconstruction-grade summary (see context.zig contract).
        summary: []const u8,
        /// Range of block seqs this summary replaces in context assembly.
        covers_from_seq: u64,
        covers_to_seq: u64,
    },
    system_note: struct { text: []const u8 },
};

/// Native→guest handover body. Clients render this in full (not the usual
/// clipped system_note). The guest adapter prepends the latest one to the
/// first `claude -p` prompt.
pub const handover_prefix = "[handover]\n";
pub const handover_announce_prefix = "Switching to Claude Code";

pub fn isHandoverNote(text: []const u8) bool {
    return std.mem.startsWith(u8, text, handover_prefix);
}

pub fn isHandoverAnnounce(text: []const u8) bool {
    return std.mem.startsWith(u8, text, handover_announce_prefix);
}

pub fn handoverBody(text: []const u8) []const u8 {
    return if (isHandoverNote(text)) text[handover_prefix.len..] else text;
}

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

test "older plan items decode without timing metadata" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const item = try std.json.parseFromSliceLeaky(
        PlanItem,
        arena_state.allocator(),
        "{\"step\":\"Inspect\",\"status\":\"completed\"}",
        .{ .ignore_unknown_fields = true },
    );
    try std.testing.expectEqual(@as(i64, 0), item.started_at_ms);
    try std.testing.expectEqual(@as(u64, 0), item.duration_ms);
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

test "user message attachments round trip as durable blob references" {
    const gpa = std.testing.allocator;
    const body: Body = .{ .user_msg = .{
        .text = "inspect this",
        .attachments = &.{.{
            .hash = "abc123",
            .mime = "image/png",
            .name = "shot.png",
            .byte_len = 42,
        }},
    } };
    const encoded = try std.json.Stringify.valueAlloc(gpa, body, .{});
    defer gpa.free(encoded);
    const parsed = try std.json.parseFromSlice(Body, gpa, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.user_msg.attachments.len);
    try std.testing.expectEqualStrings("abc123", parsed.value.user_msg.attachments[0].hash);
    try std.testing.expectEqualStrings("image/png", parsed.value.user_msg.attachments[0].mime);
}

test "handover note prefix splits body from marker" {
    try std.testing.expect(isHandoverNote("[handover]\n## Goal\nship it"));
    try std.testing.expect(!isHandoverNote("Switching to Claude Code (claudecode/fable)."));
    try std.testing.expect(isHandoverAnnounce("Switching to Claude Code (claudecode/fable). Generating a handover summary…"));
    try std.testing.expectEqualStrings("## Goal\nship it", handoverBody("[handover]\n## Goal\nship it"));
}
