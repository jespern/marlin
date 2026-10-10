//! Unit tests for claude_code.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in claude_code.zig.

const std = @import("std");
const Effort = @import("../../core/effort.zig").Effort;

const claude_code = @import("claude_code.zig");
const Bridge = claude_code.Bridge;
const Event = claude_code.Event;
const buildArgv = claude_code.buildArgv;
const decodeLine = claude_code.decodeLine;
const effortFlag = claude_code.effortFlag;
const sessionUuid = claude_code.sessionUuid;

test {
    std.testing.refAllDecls(claude_code);
}

test "session uuid is stable, v4-shaped, and sid-distinct" {
    var a: [36]u8 = undefined;
    var b: [36]u8 = undefined;
    var c: [36]u8 = undefined;
    const ua = sessionUuid(&a, 42);
    const ub = sessionUuid(&b, 42);
    const uc = sessionUuid(&c, 43);
    try std.testing.expectEqualStrings(ua, ub);
    try std.testing.expect(!std.mem.eql(u8, ua, uc));
    try std.testing.expectEqual(@as(usize, 36), ua.len);
    try std.testing.expectEqual(@as(u8, '4'), ua[14]);
    try std.testing.expect(ua[8] == '-' and ua[13] == '-' and ua[18] == '-' and ua[23] == '-');
}

test "argv: fresh vs resume, model passthrough, permission mapping" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fresh = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "hi",
        .model = "fable-5",
        .session_uuid = "u-u-i-d",
        .fresh = true,
        .permissions = .accept_edits,
        .max_turns = 32,
    });
    try std.testing.expectEqualStrings("--include-partial-messages", fresh[6]);
    try std.testing.expectEqualStrings("--forward-subagent-text", fresh[7]);
    try std.testing.expectEqualStrings("--model", fresh[8]);
    try std.testing.expectEqualStrings("fable-5", fresh[9]);
    try std.testing.expectEqualStrings("--session-id", fresh[10]);
    try std.testing.expectEqualStrings("--permission-mode", fresh[12]);
    try std.testing.expectEqualStrings("acceptEdits", fresh[13]);
    for (fresh) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--effort"));

    const high = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "hi",
        .model = "fable-5",
        .session_uuid = "u-u-i-d",
        .fresh = true,
        .permissions = .bypass,
        .max_turns = 8,
        .effort = .high,
    });
    try std.testing.expectEqualStrings("--effort", high[high.len - 2]);
    try std.testing.expectEqualStrings("high", high[high.len - 1]);
    try std.testing.expectEqualStrings("low", effortFlag(.none).?);
    try std.testing.expectEqualStrings("low", effortFlag(.minimal).?);
    try std.testing.expect(effortFlag(.auto) == null);

    const resumed = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "hi",
        .model = "default",
        .session_uuid = "u-u-i-d",
        .fresh = false,
        .permissions = .bypass,
        .max_turns = 8,
    });
    // "default" model omits --model entirely.
    for (resumed) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--model"));
    try std.testing.expectEqualStrings("--include-partial-messages", resumed[6]);
    try std.testing.expectEqualStrings("--forward-subagent-text", resumed[7]);
    try std.testing.expectEqualStrings("--resume", resumed[8]);
    try std.testing.expectEqualStrings("--dangerously-skip-permissions", resumed[10]);

    const planned = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "design it",
        .model = "default",
        .session_uuid = "u-u-i-d",
        .fresh = false,
        .permissions = .plan,
        .max_turns = 8,
    });
    try std.testing.expectEqualStrings("--permission-mode", planned[10]);
    try std.testing.expectEqualStrings("plan", planned[11]);
    for (planned) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--dangerously-skip-permissions"));

    const bridged = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "hi",
        .model = "default",
        .session_uuid = "u-u-i-d",
        .fresh = true,
        .permissions = .accept_edits,
        .bridge = .{ .marlin_exe = "/opt/marlin", .sid = 42 },
        .max_turns = 8,
    });
    // The MCP server (approve + ask_user) leads, then permission routing.
    try std.testing.expectEqualStrings("--mcp-config", bridged[10]);
    try std.testing.expect(std.mem.indexOf(u8, bridged[11], "\"command\":\"/opt/marlin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridged[11], "\"--sid\",\"42\"") != null);
    try std.testing.expectEqualStrings("--append-system-prompt", bridged[12]);
    try std.testing.expect(std.mem.indexOf(u8, bridged[13], "mcp__marlin__ask_user") != null);
    try std.testing.expectEqualStrings("--permission-mode", bridged[14]);
    try std.testing.expectEqualStrings("default", bridged[15]);
    try std.testing.expectEqualStrings("--permission-prompt-tool", bridged[16]);
    try std.testing.expectEqualStrings("mcp__marlin__approve", bridged[17]);

    // Bridge wiring never overrides an explicit bypass: no prompt routing,
    // but the MCP server (and its ask_user picker) still rides along.
    const yolo = try buildArgv(arena, .{
        .binary = "claude",
        .prompt = "hi",
        .model = "default",
        .session_uuid = "u-u-i-d",
        .fresh = true,
        .permissions = .bypass,
        .bridge = .{ .marlin_exe = "/opt/marlin", .sid = 42 },
        .max_turns = 8,
    });
    for (yolo) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--permission-prompt-tool"));
    var saw_mcp = false;
    var saw_bypass = false;
    for (yolo) |arg| {
        if (std.mem.eql(u8, arg, "--mcp-config")) saw_mcp = true;
        if (std.mem.eql(u8, arg, "--dangerously-skip-permissions")) saw_bypass = true;
    }
    try std.testing.expect(saw_mcp);
    try std.testing.expect(saw_bypass);
}

test "decode: init, assistant blocks, tool_result shapes, result usage" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var events: std.ArrayList(Event) = .empty;

    try decodeLine(arena, "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\"}", &events);
    try decodeLine(arena,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"checking"}}}
    , &events);
    try decodeLine(arena,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"work"}}}
    , &events);
    try decodeLine(arena,
        \\{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"checked"},{"type":"text","text":"working"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
    , &events);
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}],"is_error":false}]}}
    , &events);
    try decodeLine(arena,
        \\{"type":"result","subtype":"success","result":"done","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":90}}
    , &events);
    // Unknown types are ignored, not errors.
    try decodeLine(arena, "{\"type\":\"stream_event\",\"event\":{}}", &events);

    try std.testing.expectEqual(@as(usize, 8), events.items.len);
    try std.testing.expect(events.items[0] == .init);
    try std.testing.expectEqualStrings("checking", events.items[1].reasoning_delta);
    try std.testing.expectEqualStrings("work", events.items[2].text_delta);
    try std.testing.expectEqualStrings("checked", events.items[3].reasoning);
    try std.testing.expectEqualStrings("working", events.items[4].text);
    try std.testing.expectEqualStrings("Bash", events.items[5].tool_use.name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", events.items[5].tool_use.input_json);
    try std.testing.expectEqualStrings("a\nb", events.items[6].tool_result.text);
    const result = events.items[7].result;
    try std.testing.expectEqualStrings("done", result.text);
    try std.testing.expectEqual(@as(u64, 100), result.tokens_in);
    try std.testing.expectEqual(@as(u64, 5), result.tokens_out);
    try std.testing.expectEqual(@as(u64, 90), result.cached_tokens);
    try std.testing.expect(!result.is_error);
}

test "decode: forwarded subagent prose stays nested while its tools remain visible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var events: std.ArrayList(Event) = .empty;

    try decodeLine(arena,
        \\{"type":"assistant","parent_tool_use_id":"agent-1","message":{"content":[{"type":"thinking","thinking":"child thought"},{"type":"text","text":"child prose"},{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"zig build test"}}]}}
    , &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("tool-1", events.items[0].tool_use.id);
    try std.testing.expectEqualStrings("agent-1", events.items[0].tool_use.parent_tool_use_id);

    try decodeLine(arena,
        \\{"type":"stream_event","parent_tool_use_id":"agent-1","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ignored child delta"}}}
    , &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);

    try decodeLine(arena,
        \\{"type":"user","parent_tool_use_id":"agent-1","message":{"content":[{"type":"tool_result","tool_use_id":"tool-1","content":"done"}]}}
    , &events);
    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("agent-1", events.items[1].tool_result.parent_tool_use_id);
}

test "decode: rate limit event reports usage credit state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var events: std.ArrayList(Event) = .empty;

    try decodeLine(arena,
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","isUsingOverage":true,"overageInUse":true}}
    , &events);
    try decodeLine(arena,
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","isUsingOverage":false,"overageInUse":false}}
    , &events);
    try decodeLine(arena,
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","isUsingOverage":true}}
    , &events);
    try decodeLine(arena,
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
    , &events);

    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expect(events.items[0].usage_credits);
    try std.testing.expect(!events.items[1].usage_credits);
    try std.testing.expect(events.items[2].usage_credits);
}

test "decode: logged-out result is an error despite subtype success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var events: std.ArrayList(Event) = .empty;

    // Captured live from `claude -p` with no login: the auth failure ships
    // subtype "success" WITH is_error true, so subtype alone lies.
    try decodeLine(arena,
        \\{"is_error":true,"session_id":"s","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"terminal_reason":"api_error","subtype":"success","result":"Not logged in · Please run /login","type":"result","duration_ms":58}
    , &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0].result.is_error);
    try std.testing.expectEqualStrings("Not logged in · Please run /login", events.items[0].result.text);
}

test "decode: tool_result adopts the structuredPatch diff when present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var events: std.ArrayList(Event) = .empty;

    // -p stream-json stdout spells the metadata field tool_use_result. The
    // reconstruction speaks the native file tools' dialect: "… in <path>"
    // intro plus bare @@ hunks — no ---/+++ headers.
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"The file /tmp/a.zig has been updated successfully."}]},"tool_use_result":{"filePath":"/tmp/a.zig","structuredPatch":[{"oldStart":3,"oldLines":2,"newStart":3,"newLines":2,"lines":[" ctx","-old","+new"]}]}}
    , &events);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings(
        "edited 1 hunk in /tmp/a.zig\n@@ -3,2 +3,2 @@\n ctx\n-old\n+new",
        events.items[0].tool_result.text,
    );

    // The on-disk transcript spelling (toolUseResult) is accepted too.
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1b","content":"updated"}]},"toolUseResult":{"filePath":"/tmp/a.zig","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["+x"]}]}}
    , &events);
    try std.testing.expect(std.mem.startsWith(u8, events.items[1].tool_result.text, "edited 1 hunk in /tmp/a.zig"));

    // Fail soft: a shape surprise inside the patch keeps the flat text.
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"flat"}]},"tool_use_result":{"filePath":"/tmp/a.zig","structuredPatch":[{"oldStart":1,"lines":"not-an-array"}]}}
    , &events);
    try std.testing.expectEqualStrings("flat", events.items[2].tool_result.text);

    // Write creating a new file: no hunks, but type/content are enough to
    // render the native creation preview (all-additions pseudo-diff).
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","content":"File created successfully"}]},"tool_use_result":{"type":"create","filePath":"/tmp/b.zig","content":"one\ntwo\n","structuredPatch":[]}}
    , &events);
    try std.testing.expectEqualStrings(
        "created /tmp/b.zig (8 bytes)\n@@ -0,0 +1,2 @@\n+one\n+two",
        events.items[3].tool_result.text,
    );

    // An empty patch WITHOUT creation content keeps the flat text.
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3b","content":"created"}]},"tool_use_result":{"filePath":"/tmp/b.zig","structuredPatch":[]}}
    , &events);
    try std.testing.expectEqualStrings("created", events.items[4].tool_result.text);

    // Error results always keep their error text.
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t4","content":"nope","is_error":true}]},"tool_use_result":{"filePath":"/tmp/a.zig","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["+x"]}]}}
    , &events);
    try std.testing.expect(events.items[5].tool_result.is_error);
    try std.testing.expectEqualStrings("nope", events.items[5].tool_result.text);

    // Two results in one event: ambiguous mapping, nobody adopts the diff.
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t5","content":"one"},{"type":"tool_result","tool_use_id":"t6","content":"two"}]},"tool_use_result":{"filePath":"/tmp/a.zig","structuredPatch":[{"oldStart":1,"oldLines":1,"newStart":1,"newLines":1,"lines":["+x"]}]}}
    , &events);
    try std.testing.expectEqualStrings("one", events.items[6].tool_result.text);
    try std.testing.expectEqualStrings("two", events.items[7].tool_result.text);

    // With originalFile present, the hunk header carries the enclosing
    // declaration, exactly like the native unifiedDiff.
    try decodeLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t7","content":"ok"}]},"tool_use_result":{"filePath":"/tmp/a.zig","originalFile":"const a = 1;\n\npub fn greet() void {\n    old();\n}\n","structuredPatch":[{"oldStart":3,"oldLines":3,"newStart":3,"newLines":3,"lines":[" pub fn greet() void {","-    old();","+    new();"," }"]}]}}
    , &events);
    try std.testing.expectEqualStrings(
        "edited 1 hunk in /tmp/a.zig\n@@ -3,3 +3,3 @@ pub fn greet() void {\n pub fn greet() void {\n-    old();\n+    new();\n }",
        events.items[8].tool_result.text,
    );
}

test "decode: background task lifecycle (captured from claude -p 2.1.x)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var events: std.ArrayList(Event) = .empty;

    try decodeLine(arena,
        \\{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b0y87bkk9","run_id":"r","task_type":"local_bash","description":"Sleep 8 seconds then echo done-bg"}],"uuid":"u","session_id":"s"}
    , &events);
    try decodeLine(arena,
        \\{"type":"system","subtype":"task_started","task_id":"b0y87bkk9","is_backgrounded":true,"task_type":"local_bash","uuid":"u","session_id":"s"}
    , &events);
    try decodeLine(arena,
        \\{"type":"system","subtype":"task_notification","task_id":"b0y87bkk9","status":"completed","summary":"Background command \"Sleep 8 seconds then echo done-bg\" completed (exit code 0)","uuid":"u","session_id":"s"}
    , &events);
    try decodeLine(arena,
        \\{"type":"system","subtype":"background_tasks_changed","tasks":[],"uuid":"u","session_id":"s"}
    , &events);

    try std.testing.expectEqual(@as(usize, 3), events.items.len); // task_started is not surfaced
    try std.testing.expectEqual(@as(usize, 1), events.items[0].background_tasks.len);
    try std.testing.expectEqualStrings("b0y87bkk9", events.items[0].background_tasks[0].task_id);
    try std.testing.expectEqualStrings("Sleep 8 seconds then echo done-bg", events.items[0].background_tasks[0].description);
    try std.testing.expectEqualStrings("b0y87bkk9", events.items[1].task_notification.task_id);
    try std.testing.expectEqualStrings("Background command \"Sleep 8 seconds then echo done-bg\" completed (exit code 0)", events.items[1].task_notification.summary);
    try std.testing.expectEqual(@as(usize, 0), events.items[2].background_tasks.len);
}
