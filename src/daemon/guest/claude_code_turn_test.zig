//! Unit tests for claude_code_turn.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in claude_code_turn.zig.

const std = @import("std");
const Io = std.Io;
const block = @import("../../core/block.zig");
const proto = @import("../../core/proto.zig");
const ids = @import("../../core/ids.zig");
const telemetry_ids = @import("../../core/telemetry.zig");
const config = @import("../../core/config.zig");
const Store = @import("../store.zig").Store;
const process_io = @import("../process_io.zig");
const context = @import("../context.zig");
const approval = @import("../approval.zig");
const permissions = @import("../permissions.zig");
const sandbox = @import("../sandbox.zig");
const provider = @import("../provider/provider.zig");
const anthropic = @import("../provider/anthropic.zig");
const claude_code = @import("../provider/claude_code.zig");
const codex = @import("../provider/codex.zig");
const http = @import("../provider/http.zig");
const build_options = @import("build_options");

const claude_code_turn = @import("claude_code_turn.zig");

test {
    std.testing.refAllDecls(claude_code_turn);
}

test "generic Claude connection errors name the missing detail" {
    const note = try claude_code_turn.claudeErrorNote(
        std.testing.allocator,
        "ConnectFailed",
        "",
    );
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "claude code connection failed: ConnectFailed (no transport detail reported by Claude Code)",
        note,
    );
}

test "generic Claude connection errors include captured stderr" {
    const note = try claude_code_turn.claudeErrorNote(
        std.testing.allocator,
        "SocketUnconnected",
        "  network changed\nwhile connecting\n",
    );
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "claude code connection failed: SocketUnconnected (stderr: network changed while connecting)",
        note,
    );
}

test "Claude login errors explain how to authenticate on the daemon host" {
    const note = try claude_code_turn.claudeErrorNote(
        std.testing.allocator,
        "Not logged in · Please run /login",
        "ignored",
    );
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        @import("../../core/guest.zig").loginRequiredNote(.claude_code),
        note,
    );
}

test "usage credit notifications describe both transitions" {
    try std.testing.expectEqualStrings(
        "Claude Code is now using API credits",
        claude_code_turn.usageCreditsTransitionNote(true),
    );
    try std.testing.expectEqualStrings(
        "Claude Code returned to subscription usage",
        claude_code_turn.usageCreditsTransitionNote(false),
    );
}

test "guest tool phase remains tool until every parallel call finishes" {
    try std.testing.expectEqual(proto.TurnPhase.provider, claude_code_turn.guestToolPhase(0));
    try std.testing.expectEqual(proto.TurnPhase.tool, claude_code_turn.guestToolPhase(1));
    try std.testing.expectEqual(proto.TurnPhase.tool, claude_code_turn.guestToolPhase(3));
}

test "background Claude agents remain agents, not generic processes" {
    try std.testing.expectEqual(proto.GuestActivityKind.agent, claude_code_turn.backgroundActivityKind("local_agent"));
    try std.testing.expectEqual(proto.GuestActivityKind.process, claude_code_turn.backgroundActivityKind("local_bash"));
    try std.testing.expectEqual(proto.GuestActivityKind.agent, claude_code_turn.toolActivityKind("Agent"));
    try std.testing.expectEqual(proto.GuestActivityKind.process, claude_code_turn.toolActivityKind("Bash"));
    try std.testing.expectEqual(proto.GuestActivityKind.tool, claude_code_turn.toolActivityKind("Read"));
}

test "the context gauge takes the session's own model window, not a helper's" {
    var used: std.atomic.Value(u64) = .init(0);
    var limit: std.atomic.Value(u64) = .init(0);
    var outcome: claude_code_turn.CcOutcome = .{};
    defer outcome.final_text.deinit(std.testing.allocator);
    outcome.noteContextUsed("claude-opus-5-5", 42_000, &used);
    outcome.noteContextWindow("claude-haiku-5-5", 200_000, &limit);
    try std.testing.expectEqual(@as(u64, 0), limit.load(.acquire));
    outcome.noteContextWindow("claude-opus-5-5", 1_000_000, &limit);
    try std.testing.expectEqual(@as(u64, 42_000), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1_000_000), limit.load(.acquire));
}

test "compaction notes say who compacted, how, and by how much" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "≡ Claude Code compacted its context: 25.6k → 10.7k tokens",
        try claude_code_turn.compactionNote(arena, "Claude Code", "manual", 25_646, 10_741),
    );
    try std.testing.expectEqualStrings(
        "≡ Claude Code compacted its context automatically (180.0k tokens before)",
        try claude_code_turn.compactionNote(arena, "Claude Code", "auto", 180_000, null),
    );
    try std.testing.expectEqualStrings(
        "≡ Codex compacted its context",
        try claude_code_turn.compactionNote(arena, "Codex", "manual", 0, null),
    );
}

test "Claude Code /compact resumes the conversation with the focus and never starts one" {
    const loop = @import("../loop.zig");
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-claude-compact");
    defer temp.deinit();
    // Events as claude -p 2.1.314 sends them for /compact; "missing" mode is
    // a --resume of a conversation Claude Code never had.
    const script =
        \\#!/bin/sh
        \\echo x >> invocations
        \\case "$*" in *"--resume "*) ;; *) exit 9 ;; esac
        \\read -r mode < mode
        \\if [ "$mode" = missing ]; then
        \\  echo '{"type":"result","subtype":"error_during_execution","is_error":true,"errors":["No conversation found with session ID: x"]}'
        \\  exit 0
        \\fi
        \\IFS= read -r line
        \\case "$line" in *'/compact keep the API decisions'*) ;; *) exit 8 ;; esac
        \\echo '{"type":"system","subtype":"init","session_id":"x"}'
        \\echo '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":25646,"post_tokens":10741}}'
        \\echo '{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation that ran out of context."}}'
        \\echo '{"type":"user","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"},"isReplay":true}'
        \\echo '{"type":"result","subtype":"success","is_error":false,"result":"","usage":{"input_tokens":0,"output_tokens":0}}'
        \\# Like claude -p with stream-json input: it waits for more until stdin closes.
        \\cat > /dev/null
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-claude" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);
    const mode_path = try std.fs.path.join(gpa, &.{ temp.path, "mode" });
    defer gpa.free(mode_path);
    const invocations_path = try std.fs.path.join(gpa, &.{ temp.path, "invocations" });
    defer gpa.free(invocations_path);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(claude_code.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");
    var used: std.atomic.Value(u64) = .init(0);

    for ([_][]const u8{ "present", "missing" }) |mode| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = mode_path, .data = mode });
        Io.Dir.cwd().deleteFile(io, invocations_path) catch {};
        var store = try Store.open(gpa, null);
        defer store.close();
        try store.createSession(1, 0, temp.path, "claudecode/fable-5", .auto);
        const result = try loop.runTurn(gpa, io, &store, .{
            .session_id = 1,
            .cwd = temp.path,
            .endpoint = .{ .url = "", .bearer = null, .model = "fable-5", .backend = .{ .guest = .claude_code } },
            // A hang (stdin never closed) fails fast instead of stalling.
            .cfg = .{ .guest_max_runtime_ms = 5_000 },
            .tool_environ = &env,
            .approval_mode = .auto,
            .context_used_out = &used,
            .guest_compact = "keep the API decisions",
        }, "keep the API decisions", &.{});
        defer gpa.free(result.text);

        const blocks = try store.getBlocks(1, 1, 100);
        defer {
            for (blocks) |*b| b.deinit();
            gpa.free(blocks);
        }
        // Only the note: no user message, no empty reply, no replayed summary.
        try std.testing.expectEqual(@as(usize, 1), blocks.len);
        const note = blocks[0].blk.body.system_note.text;
        if (std.mem.eql(u8, mode, "present")) {
            try std.testing.expectEqualStrings("≡ Claude Code compacted its context: 25.6k → 10.7k tokens", note);
            try std.testing.expectEqual(@as(u64, 10741), used.load(.acquire));
        } else {
            try std.testing.expect(std.mem.startsWith(u8, note, "nothing to compact yet"));
        }
        // One invocation: a missing conversation is not retried as a new one.
        const invocations = try Io.Dir.cwd().readFileAlloc(io, invocations_path, gpa, .limited(100));
        defer gpa.free(invocations);
        try std.testing.expectEqualStrings("x\n", invocations);
    }
}
