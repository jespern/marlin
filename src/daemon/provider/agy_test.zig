//! Unit tests for agy.zig: Antigravity's ACP sessions, tool calls, and
//! permission options. Payloads are as `agy acp` 1.5.14 sent them.
const std = @import("std");
const agy = @import("agy.zig");

fn parse(arena: std.mem.Allocator, json: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{});
}

const config_options =
    \\[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"gemini-4-neon","options":[{"value":"gemini-4-neon","name":"Gemini 4 Neon"},{"value":"gemini-4-argon","name":"Gemini 4 Argon"},{"value":"claude-opus-5-5","name":"Claude Opus 5.5"}]},
    \\ {"id":"thought_level","name":"Thinking Level","category":"thought_level","type":"select","currentValue":"high","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"},{"value":"xhigh","name":"Extra"}]},
    \\ {"id":"mode","name":"Mode","category":"mode","type":"select","currentValue":"default","options":[{"value":"default","name":"Default"},{"value":"auto","name":"Auto"}]}]
;

test "a session's config options: current values, offered values, and the model list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try parse(arena, config_options);
    try std.testing.expectEqualStrings("gemini-4-neon", agy.currentValue(options, "model").?);
    try std.testing.expectEqualStrings("high", agy.currentValue(options, "thought_level").?);
    try std.testing.expect(agy.offers(options, "thought_level", "xhigh"));
    try std.testing.expect(!agy.offers(options, "thought_level", "max"));
    try std.testing.expect(!agy.offers(null, "model", "gemini-4-neon"));
    try std.testing.expectEqual(@as(?[]const u8, null), agy.currentValue(options, "absent"));

    const models = try agy.modelList(arena, options);
    try std.testing.expectEqualStrings("gemini-4-neon\ngemini-4-argon\nclaude-opus-5-5", models);
    var ids: std.ArrayList([]const u8) = .empty;
    try ids.append(arena, "agy/default");
    try ids.append(arena, "agy/gemini-4-neon");
    try agy.appendModelIds(arena, &ids, models);
    try std.testing.expectEqual(@as(usize, 4), ids.items.len);
    try std.testing.expectEqualStrings("agy/claude-opus-5-5", ids.items[3]);
}

test "Marlin's model and effort map onto agy's, and defaults stay agy's" {
    try std.testing.expectEqual(@as(?[]const u8, null), agy.modelValue("default"));
    try std.testing.expectEqualStrings("gemini-4-neon", agy.modelValue("gemini-4-neon").?);
    try std.testing.expectEqual(@as(?[]const u8, null), agy.thoughtLevel(.auto));
    try std.testing.expectEqualStrings("low", agy.thoughtLevel(.minimal).?);
    try std.testing.expectEqualStrings("xhigh", agy.thoughtLevel(.max).?);
}

test "the bridge is Marlin's own tools without approve, with what finds the daemon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(usize, 0), (try agy.mcpServers(arena, null, null)).len);
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("HOME", "/home/me");
    try environ.put("MARLIN_SOCKET", "/tmp/m.sock");
    try environ.put("SECRET_TOKEN", "x");
    const servers = try agy.mcpServers(arena, .{ .marlin_exe = "/bin/marlin", .sid = 7 }, &environ);
    const json = try std.json.Stringify.valueAlloc(arena, servers, .{});
    try std.testing.expectEqualStrings(
        \\[{"name":"marlin","command":"/bin/marlin","args":["cc_approve","--sid","7","--no-approve"],"env":[{"name":"HOME","value":"/home/me"},{"name":"MARLIN_SOCKET","value":"/tmp/m.sock"}]}]
    , json);
    const child_servers = try agy.mcpServers(arena, .{ .marlin_exe = "/bin/marlin", .sid = 8, .allow_tasks = false }, &environ);
    const child_json = try std.json.Stringify.valueAlloc(arena, child_servers, .{});
    try std.testing.expectEqualStrings(
        \\[{"name":"marlin","command":"/bin/marlin","args":["cc_approve","--sid","8","--no-approve","--no-tasks"],"env":[{"name":"HOME","value":"/home/me"},{"name":"MARLIN_SOCKET","value":"/tmp/m.sock"}]}]
    , child_json);
}

test "tool calls become Marlin tools with the arguments its transcript reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command = try parse(arena,
        \\{"sessionUpdate":"tool_call","toolCallId":"call_1","name":"run_command","status":"in_progress","kind":"execute","title":"echo hi > probe.txt","rawInput":{"CommandLine":"echo hi > probe.txt","WaitMsBeforeAsync":5000}}
    );
    try std.testing.expectEqualStrings("Bash", agy.toolName(command));
    const command_args = try parse(arena, try agy.toolArgs(arena, command));
    try std.testing.expectEqualStrings("echo hi > probe.txt", agy.strField(command_args, "command").?);
    try std.testing.expectEqual(@as(i64, 5000), agy.intField(agy.field(command_args, "input").?, "WaitMsBeforeAsync").?);

    const edit = try parse(arena,
        \\{"sessionUpdate":"tool_call","toolCallId":"call_2","name":"edit_file","kind":"edit","title":"File lines.txt","locations":[{"path":"/w/lines.txt"}],"rawInput":{"Path":"/w/lines.txt","Replacement":"FOUR","Target":"four"}}
    );
    try std.testing.expectEqualStrings("Edit", agy.toolName(edit));
    const edit_args = try parse(arena, try agy.toolArgs(arena, edit));
    try std.testing.expectEqualStrings("/w/lines.txt", agy.strField(edit_args, "path").?);

    // Without a kind it keeps the agent's own name.
    const other = try parse(arena,
        \\{"sessionUpdate":"tool_call","toolCallId":"call_3","name":"mcp_marlin_ask_user","title":"ask_user"}
    );
    try std.testing.expectEqualStrings("mcp_marlin_ask_user", agy.toolName(other));
}

test "a finished edit shows as a unified diff, a new file as all additions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const edit = try parse(arena,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call_2","status":"completed","kind":"edit","rawOutput":{},"content":[{"type":"diff","path":"/w/lines.txt","newText":"one\ntwo\nthree\nFOUR\nfive\nsix\nseven\n","oldText":"one\ntwo\nthree\nfour\nfive\nsix\nseven\n"}]}
    );
    const body = try agy.toolBody(arena, edit);
    try std.testing.expect(std.mem.startsWith(u8, body, "--- /w/lines.txt\n+++ /w/lines.txt\n@@ -1,7 +1,7 @@"));
    try std.testing.expect(std.mem.indexOf(u8, body, "\n-four\n+FOUR\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\n three\n") != null);

    const created = try parse(arena,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call_4","status":"completed","kind":"edit","content":[{"type":"diff","path":"/w/note.txt","newText":"neon"}]}
    );
    try std.testing.expectEqualStrings("--- /dev/null\n+++ /w/note.txt\n@@ -0,0 +1,1 @@\n+neon\n", try agy.toolBody(arena, created));

    // A hunk over unifiedDiff's 80-line cap falls back to a note instead of aborting the turn.
    var old_big: std.ArrayList(u8) = .empty;
    var new_big: std.ArrayList(u8) = .empty;
    for (0..50) |idx| {
        try old_big.print(arena, "old line {d}\n", .{idx});
        try new_big.print(arena, "new line {d}\n", .{idx});
    }
    var out: std.ArrayList(u8) = .empty;
    try agy.appendDiff(arena, &out, "/w/huge.zig", old_big.items, new_big.items);
    try std.testing.expectEqualStrings("edited /w/huge.zig (change too large for an inline diff)\n", out.items);
}

test "a finished command shows its text, or its raw output when it has none" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ran = try parse(arena,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","rawOutput":{"output":"raw","exit_code":0},"content":[{"type":"content","content":{"type":"text","text":"Command exited with code 0."}}]}
    );
    try std.testing.expectEqualStrings("Command exited with code 0.", try agy.toolBody(arena, ran));
    const bare = try parse(arena,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","rawOutput":{"output":"raw","exit_code":0}}
    );
    try std.testing.expectEqualStrings("raw", try agy.toolBody(arena, bare));
    const empty = try parse(arena,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"call_1","status":"completed","rawOutput":{}}
    );
    try std.testing.expectEqualStrings("", try agy.toolBody(arena, empty));
}

test "permission answers pick a one-off option, and nothing fitting is a cancel" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const options = try parse(arena,
        \\[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"always","name":"Always","kind":"allow_always"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]
    );
    try std.testing.expectEqualStrings("allow", agy.permissionOption(options, true).?);
    try std.testing.expectEqualStrings("deny", agy.permissionOption(options, false).?);
    const only_always = try parse(arena,
        \\[{"optionId":"always","name":"Always","kind":"allow_always"}]
    );
    try std.testing.expectEqualStrings("always", agy.permissionOption(only_always, true).?);
    try std.testing.expectEqual(@as(?[]const u8, null), agy.permissionOption(only_always, false));
}

test "usage counts cached input, and unusual stops are worth a note" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const result = try parse(arena,
        \\{"stopReason":"end_turn","usage":{"inputTokens":2285,"outputTokens":48,"cachedReadTokens":6999,"cachedWriteTokens":0,"thoughtTokens":46,"totalTokens":9332}}
    );
    const usage = agy.promptUsage(result);
    try std.testing.expectEqual(@as(u64, 9284), usage.input);
    try std.testing.expectEqual(@as(u64, 48), usage.output);
    try std.testing.expectEqual(@as(u64, 0), agy.promptUsage(null).input);
    try std.testing.expectEqual(@as(?[]const u8, null), agy.stopNote("end_turn"));
    try std.testing.expect(agy.stopNote("refusal") != null);
}

test "fetchModels probes agy acp with session/new and closes it" {
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
        \\printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"probe-1","configOptions":[{"id":"model","type":"select","currentValue":"gemini-4-neon","options":[{"value":"gemini-4-neon","name":"Gemini 4 Neon"},{"value":"gemini-4-argon","name":"Gemini 4 Argon"}]}]}}'
        \\IFS= read -r close_req
        \\case "$close_req" in *'"session/close"'*'"probe-1"'*) ;; *) exit 9 ;; esac
        \\printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{}}'
        \\printf 'closed' > "$TMPDIR/closed"
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ root, "fake-agy-catalog" });
    defer gpa.free(script_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(agy.binary_env, script_path);
    try env.put("TMPDIR", root);
    try env.put("PATH", "/usr/bin:/bin");

    const models = try agy.fetchModels(gpa, io, &env, null);
    defer {
        for (models) |m| gpa.free(m.id);
        gpa.free(models);
    }
    try std.testing.expectEqual(@as(usize, 2), models.len);
    try std.testing.expectEqualStrings("agy/gemini-4-neon", models[0].id);
    try std.testing.expectEqualStrings("agy/gemini-4-argon", models[1].id);
    const closed_path = try std.fs.path.join(gpa, &.{ root, "closed" });
    defer gpa.free(closed_path);
    const marker = try std.Io.Dir.cwd().readFileAlloc(io, closed_path, gpa, .limited(32));
    defer gpa.free(marker);
    try std.testing.expectEqualStrings("closed", marker);
}
