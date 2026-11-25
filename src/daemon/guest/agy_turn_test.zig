//! Unit tests for agy_turn.zig: background task wait and reactive wakeup state
//! transitions.
const std = @import("std");
const Io = std.Io;
const agy_turn = @import("agy_turn.zig");
const agy = @import("../provider/agy.zig");
const loop = @import("../loop.zig");
const Store = @import("../store.zig").Store;

test "prompt end with open background task parks in waiting_background then finishes after reactive settle" {
    var state = agy_turn.TurnState{};

    // Prompt ends with 1 open background run_command.
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_background, state.onPromptEnd(1, false));
    try std.testing.expectEqual(agy_turn.TurnPhase.waiting_background, state.phase);

    // Waiting polls while background command is still open keep waiting.
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onWaitTimeout(1, false, false, 1000));
    try std.testing.expectEqual(agy_turn.TurnPhase.waiting_background, state.phase);

    // Background command completes -> reactive wakeup begins.
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_provider, state.onUpdate(false, true, 0));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_active, state.phase);

    // Reactive wakeup calls another tool: usage_update arrives right before tool_call.
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onUpdate(true, false, 0));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_settling, state.phase);
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onUpdate(false, true, 1));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_active, state.phase);

    // Tool finishes, final answer arrives, then usage_update -> settling -> timeout finishes turn.
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onUpdate(false, true, 0));
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onUpdate(true, false, 0));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_settling, state.phase);
    try std.testing.expectEqual(agy_turn.TurnState.Action.finish_turn, state.onWaitTimeout(0, false, false, 5000));
}

test "subagent completion on disk transitions to reactive_active with bounded wakeup window" {
    var state = agy_turn.TurnState{};
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_background, state.onPromptEnd(1, false));

    // Subagent message lands on disk before agy emits a reactive ACP notification.
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_provider, state.onWaitTimeout(0, false, true, 1000));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_active, state.phase);
    try std.testing.expect(state.awaiting_wakeup);

    // Before the wakeup deadline, keep waiting.
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onWaitTimeout(0, false, false, 3000));
    // Once the deadline passes with no reactive event (e.g. killed subagent), finish cleanly.
    try std.testing.expectEqual(
        agy_turn.TurnState.Action.finish_turn,
        state.onWaitTimeout(0, false, false, 1000 + agy_turn.follow_up_wait_ms),
    );
}

test "reactive wakeup that spawns a second background task returns to waiting_background" {
    var state = agy_turn.TurnState{};
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_background, state.onPromptEnd(1, false));
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_provider, state.onUpdate(false, true, 0));
    // Second background task launched during reactive turn; usage_update arrives with open_bg == 1.
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_background, state.onUpdate(true, false, 1));
    try std.testing.expectEqual(agy_turn.TurnPhase.waiting_background, state.phase);
}

test "background task finishing mid-step stays alive across long reactive TTFT when parent is busy" {
    var state = agy_turn.TurnState{};
    // Prompt ends after a background task already finished mid-step (open_bg == 0, pending_wakeup == true).
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onPromptEnd(0, true));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_settling, state.phase);

    // Settle window expires while agy's transcript shows SYSTEM_MESSAGE (parent_busy == true).
    try std.testing.expectEqual(agy_turn.TurnState.Action.enter_provider, state.onWaitTimeout(0, true, false, 1000));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_active, state.phase);
    try std.testing.expect(state.awaiting_wakeup);

    // LLM takes 25s (> follow_up_wait_ms) to emit its first token; parent_busy keeps extending.
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onWaitTimeout(0, true, false, 10_000));
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onWaitTimeout(0, true, false, 25_000));

    // First token arrives, then usage_update -> settling -> parent_busy false -> finish_turn.
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onUpdate(false, true, 0));
    try std.testing.expect(!state.awaiting_wakeup);
    try std.testing.expectEqual(agy_turn.TurnState.Action.keep_reading, state.onUpdate(true, false, 0));
    try std.testing.expectEqual(agy_turn.TurnPhase.reactive_settling, state.phase);
    try std.testing.expectEqual(agy_turn.TurnState.Action.finish_turn, state.onWaitTimeout(0, false, false, 27_000));
}

test "runAgyTurn stays alive across early end_turn until background command and reactive wakeup finish" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const script =
        \\#!/bin/sh
        \\set -eu
        \\# initialize, session/new, session/prompt
        \\IFS= read -r _
        \\echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        \\IFS= read -r _
        \\echo '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-bg","configOptions":[]}}'
        \\IFS= read -r _
        \\echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-bg","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","name":"run_command","status":"in_progress","kind":"execute","title":"build project","rawInput":{"CommandLine":"zig build"}}}}'
        \\mkdir -p "$HOME/.gemini/antigravity-cli/brain/s-bg/.system_generated/tasks"
        \\echo 'compiling...' > "$HOME/.gemini/antigravity-cli/brain/s-bg/.system_generated/tasks/task-2.log"
        \\echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-bg","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"waiting"}}}}'
        \\echo '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":2}}}'
        \\sleep 0.2
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-bg","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1","name":"run_command","status":"completed","kind":"execute","title":"build project","content":[{"type":"content","content":{"type":"text","text":"ok"}}]}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-bg","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\n\nall done"}}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-bg","update":{"sessionUpdate":"usage_update","used":42,"size":1000}}}'
        \\cat > /dev/null
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ root, "fake-agy" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(agy.binary_env, script_path);
    try env.put("HOME", root);
    try env.put("PATH", "/usr/bin:/bin");

    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, root, "agy/default", .auto);
    const result = try loop.runTurn(gpa, io, &store, .{
        .session_id = 1,
        .cwd = root,
        .endpoint = .{ .url = "", .bearer = null, .model = "default", .backend = .{ .guest = .agy } },
        .cfg = .{ .guest_max_runtime_ms = 10_000 },
        .tool_environ = &env,
        .approval_mode = .auto,
    }, "build it", &.{});
    defer gpa.free(result.text);

    try std.testing.expectEqualStrings("all done", result.text);
    const blocks = try store.getBlocks(1, 1, 100);
    defer {
        for (blocks) |*b| b.deinit();
        gpa.free(blocks);
    }
    var saw_wait_note = false;
    var saw_final = false;
    for (blocks) |entry| switch (entry.blk.body) {
        .system_note => |n| if (std.mem.indexOf(u8, n.text, "waiting on background task: build project") != null) {
            saw_wait_note = true;
        },
        .assistant_msg => |m| if (std.mem.eql(u8, m.text, "all done")) {
            saw_final = true;
        },
        else => {},
    };
    try std.testing.expect(saw_wait_note);
    try std.testing.expect(saw_final);
}

test "runAgyTurn waits for .system_generated subagent reply after early end_turn" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const script =
        \\#!/bin/sh
        \\set -eu
        \\IFS= read -r _
        \\printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        \\IFS= read -r _
        \\printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-sub","configOptions":[]}}'
        \\IFS= read -r _
        \\mkdir -p "$HOME/.gemini/antigravity-cli/brain/s-sub/.system_generated/subagents"
        \\mkdir -p "$HOME/.gemini/antigravity-cli/brain/s-sub/.system_generated/messages"
        \\printf '%s' '{"conversationId":"sub-1","subagentDescriptor":{"typeName":"self","role":"Sleeper"},"state":"SUBAGENT_STATE_ALIVE"}' > "$HOME/.gemini/antigravity-cli/brain/s-sub/.system_generated/subagents/sub-1.json"
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-sub","update":{"sessionUpdate":"tool_call","toolCallId":"call_sub","name":"invoke_subagent","status":"in_progress","kind":"other","title":"Run invoke_subagent"}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-sub","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_sub","name":"invoke_subagent","status":"completed","kind":"other","title":"Run invoke_subagent"}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-sub","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"waiting_sub"}}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":2}}}'
        \\sleep 0.2
        \\printf '%s' '{"id":"msg-1","sender":"sub-1","recipient":"s-sub","content":"SUB_DONE"}' > "$HOME/.gemini/antigravity-cli/brain/s-sub/.system_generated/messages/msg-1.json"
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-sub","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\n\nsubagent finished"}}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-sub","update":{"sessionUpdate":"usage_update","used":55,"size":1000}}}'
        \\cat > /dev/null
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ root, "fake-agy-sub" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(agy.binary_env, script_path);
    try env.put("HOME", root);
    try env.put("PATH", "/usr/bin:/bin");

    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, root, "agy/default", .auto);
    const result = try loop.runTurn(gpa, io, &store, .{
        .session_id = 1,
        .cwd = root,
        .endpoint = .{ .url = "", .bearer = null, .model = "default", .backend = .{ .guest = .agy } },
        .cfg = .{ .guest_max_runtime_ms = 10_000 },
        .tool_environ = &env,
        .approval_mode = .auto,
    }, "spawn sleeper", &.{});
    defer gpa.free(result.text);

    try std.testing.expectEqualStrings("subagent finished", result.text);
}

test "runAgyTurn waits when background command finishes mid-step before usage_update and reactive TTFT exceeds settle window" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    // Reproduces the task-669 race:
    // 1. Prompt ends with task-1 open -> waiting_background.
    // 2. task-1 completes -> reactive_active; model launches task-2 (git commit).
    // 3. task-2 completes BEFORE the model's "waiting on commit" reply finishes
    //    (open_bg drops to 0, message + SYSTEM_MESSAGE written to disk).
    // 4. Model's "waiting on commit" reply finishes with usage_update (open_bg == 0).
    // 5. Reactive LLM step takes 2.2s (> 1.5s reactive_settle_ms) before emitting
    //    the final answer and writing PLANNER_RESPONSE (DONE) to transcript.jsonl.
    const script =
        \\#!/bin/sh
        \\set -eu
        \\IFS= read -r _
        \\printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        \\IFS= read -r _
        \\printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s-race","configOptions":[]}}'
        \\IFS= read -r _
        \\BRAIN="$HOME/.gemini/antigravity-cli/brain/s-race/.system_generated"
        \\mkdir -p "$BRAIN/logs" "$BRAIN/messages/undelivered" "$BRAIN/tasks"
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"tool_call","toolCallId":"call_1","name":"run_command","status":"in_progress","kind":"execute","title":"zig build test"}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"waiting tests"}}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"inputTokens":10,"outputTokens":2}}}'
        \\sleep 0.1
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_1","name":"run_command","status":"completed","kind":"execute","title":"zig build test","content":[{"type":"content","content":{"type":"text","text":"ok"}}]}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"tool_call","toolCallId":"call_2","name":"run_command","status":"in_progress","kind":"execute","title":"git commit"}}}'
        \\# task-2 finishes while the model is still generating "waiting commit"
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"tool_call_update","toolCallId":"call_2","name":"run_command","status":"completed","kind":"execute","title":"git commit","content":[{"type":"content","content":{"type":"text","text":"[branch abc1234] ok"}}]}}}'
        \\printf '%s' '{"id":"msg-669","sender":"s-race/task-2","priority":"MESSAGE_PRIORITY_HIGH","content":"git commit finished"}' > "$BRAIN/messages/msg-669.json"
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"waiting commit"}}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"usage_update","used":50,"size":1000}}}'
        \\printf '%s' '{"msg-669":true}' > "$BRAIN/messages/read.json"
        \\printf '%s\n' '{"step_index":670,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"waiting commit"}' >> "$BRAIN/logs/transcript.jsonl"
        \\printf '%s\n' '{"step_index":671,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"task-2 finished"}' >> "$BRAIN/logs/transcript.jsonl"
        \\# Simulate LLM TTFT longer than reactive_settle_ms (1.5s)
        \\sleep 2.2
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"commit abc1234 landed"}}}}'
        \\printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-race","update":{"sessionUpdate":"usage_update","used":60,"size":1000}}}'
        \\printf '%s\n' '{"step_index":672,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"commit abc1234 landed"}' >> "$BRAIN/logs/transcript.jsonl"
        \\cat > /dev/null
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ root, "fake-agy-race" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(agy.binary_env, script_path);
    try env.put("HOME", root);
    try env.put("PATH", "/usr/bin:/bin");

    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, root, "agy/default", .auto);
    const result = try loop.runTurn(gpa, io, &store, .{
        .session_id = 1,
        .cwd = root,
        .endpoint = .{ .url = "", .bearer = null, .model = "default", .backend = .{ .guest = .agy } },
        .cfg = .{ .guest_max_runtime_ms = 15_000 },
        .tool_environ = &env,
        .approval_mode = .auto,
    }, "test and commit", &.{});
    defer gpa.free(result.text);

    try std.testing.expectEqualStrings("commit abc1234 landed", result.text);
}
