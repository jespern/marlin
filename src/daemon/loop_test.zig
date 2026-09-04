//! Unit tests for loop.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in loop.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const block = @import("../core/block.zig");
const proto = @import("../core/proto.zig");
const ids = @import("../core/ids.zig");
const telemetry_ids = @import("../core/telemetry.zig");
const jsonx = @import("../core/jsonx.zig");
const config = @import("../core/config.zig");
const Store = @import("store.zig").Store;
const process_io = @import("process_io.zig");
const context = @import("context.zig");
const approval = @import("approval.zig");
const permissions = @import("permissions.zig");
const sandbox = @import("sandbox.zig");
const network_policy = @import("network_policy.zig");
const extensions = @import("extensions.zig");
const provider = @import("provider/provider.zig");
const openai = @import("provider/openai_compat.zig");
const anthropic = @import("provider/anthropic.zig");
const claude_code = @import("provider/claude_code.zig");
const codex = @import("provider/codex.zig");
const http = @import("provider/http.zig");
const sse = @import("provider/sse.zig");
const tools_registry = @import("tools/registry.zig");
const task_tool = @import("tools/task.zig");
const bash_tool = @import("tools/bash.zig");
const files_tool = @import("tools/files.zig");
const Effort = @import("../core/effort.zig").Effort;
const build_options = @import("build_options");

const loop = @import("loop.zig");
const AnthropicWireChecks = loop.AnthropicWireChecks;
const RunOpts = loop.RunOpts;
const SteeringWireChecks = loop.SteeringWireChecks;
const codex_turn = loop.codex_turn;
const enforcePlanTransitions = loop.enforcePlanTransitions;
const environmentBlock = loop.environmentBlock;
const max_parallel_tool_workers = loop.max_parallel_tool_workers;
const openrouter_web_search_prompt = loop.openrouter_web_search_prompt;
const parallelChunkEnd = loop.parallelChunkEnd;
const projectInstructions = loop.projectInstructions;
const providerErrorNote = loop.providerErrorNote;
const runTaskBatch = loop.runTaskBatch;
const runTurn = loop.runTurn;
const skippedPlanCompletion = loop.skippedPlanCompletion;
const stampPlanTimings = loop.stampPlanTimings;
const summarize = loop.summarize;
const toolAllowed = loop.toolAllowed;

test {
    std.testing.refAllDecls(loop);
}

const codexAccountError = codex_turn.codexAccountError;

fn serveSteeringCompletions(io: Io, server: *Io.net.Server, checks: *SteeringWireChecks) void {
    const responses = [_][]const u8{ "FIRST", "SECOND", "THIRD" };
    for (responses, 0..) |response_text, request_index| {
        var stream = server.accept(io) catch return;
        defer stream.close(io);
        var read_buffer: [65536]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, io, &read_buffer);
        var content_length: usize = 0;
        while (reader.interface.takeDelimiterInclusive('\n') catch null) |line| {
            const trimmed = std.mem.trim(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                content_length = std.fmt.parseInt(usize, std.mem.trim(u8, trimmed[15..], " "), 10) catch 0;
            }
        }
        var body_buf: [65536]u8 = undefined;
        var got: usize = 0;
        while (got < @min(content_length, body_buf.len)) {
            const n = reader.interface.readSliceShort(body_buf[got..@min(content_length, body_buf.len)]) catch break;
            if (n == 0) break;
            got += n;
        }
        const body = body_buf[0..got];
        checks.requests += 1;
        if (request_index == 1)
            checks.second_saw_first_steer = std.mem.indexOf(u8, body, "steer after first response") != null;
        if (request_index == 2)
            checks.third_saw_raced_steer = std.mem.indexOf(u8, body, "steer from close race") != null;

        var write_buffer: [4096]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, io, &write_buffer);
        writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n") catch return;
        writer.interface.print(
            "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"content\":\"{s}\"}}}}]}}\n\n" ++
                "data: {{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"stop\"}}],\"usage\":{{\"prompt_tokens\":1,\"completion_tokens\":1}}}}\n\n" ++
                "data: [DONE]\n\n",
            .{response_text},
        ) catch return;
        writer.interface.flush() catch return;
    }
}

fn serveAnthropicMessages(io: Io, server: *Io.net.Server, checks: *AnthropicWireChecks) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    var read_buffer: [16384]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buffer);
    var content_length: usize = 0;
    while (reader.interface.takeDelimiterInclusive('\n') catch null) |line| {
        const trimmed = std.mem.trim(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "x-api-key: sk-ant-test")) checks.saw_api_key = true;
        if (std.ascii.startsWithIgnoreCase(trimmed, "anthropic-version:")) checks.saw_version = true;
        if (std.ascii.startsWithIgnoreCase(trimmed, "authorization:")) checks.saw_authorization = true;
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            content_length = std.fmt.parseInt(usize, std.mem.trim(u8, trimmed[15..], " "), 10) catch 0;
        }
    }
    var body_buf: [16384]u8 = undefined;
    var got: usize = 0;
    while (got < @min(content_length, body_buf.len)) {
        const n = reader.interface.readSliceShort(body_buf[got..@min(content_length, body_buf.len)]) catch break;
        if (n == 0) break;
        got += n;
    }
    const body = body_buf[0..got];
    checks.body_ok = std.mem.indexOf(u8, body, "\"max_tokens\":8192") != null and
        std.mem.indexOf(u8, body, "\"system\":[{\"type\":\"text\"") != null and
        std.mem.indexOf(u8, body, "\"stream\":true") != null;

    var write_buffer: [4096]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buffer);
    writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n" ++
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_t\",\"usage\":{\"input_tokens\":10}}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"SUMMARY-OK\"}}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n") catch return;
    writer.interface.flush() catch return;
}

test "plan timing survives revisions without counting idle gaps" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);
    try store.appendBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 10,
        .seq = 1,
        .ts = 900,
        .body = .{ .user_msg = .{ .text = "start" } },
    });

    var first = [_]block.PlanItem{.{ .step = "Inspect", .status = .in_progress }};
    try stampPlanTimings(&store, 1, 10, &first, &.{}, 1_000);
    try std.testing.expectEqual(@as(i64, 1_000), first[0].started_at_ms);

    const first_history = [_]block.Block{.{
        .id = 2,
        .session_id = 1,
        .turn_id = 10,
        .seq = 2,
        .ts = 1_000,
        .body = .{ .plan = .{ .items = &first } },
    }};
    var completed = [_]block.PlanItem{.{ .step = "Inspect", .status = .completed }};
    try stampPlanTimings(&store, 1, 10, &completed, &first_history, 4_250);
    try std.testing.expectEqual(@as(u64, 3_250), completed[0].duration_ms);

    // An old untimed active plan ended at 4s. Resuming at 5s and completing
    // at 5.5s counts 2s + 0.5s, not the idle second between turns.
    const old_active = [_]block.PlanItem{.{ .step = "Legacy", .status = .in_progress }};
    const old_plan = block.Block{
        .id = 3,
        .session_id = 1,
        .turn_id = 20,
        .seq = 3,
        .ts = 2_000,
        .body = .{ .plan = .{ .items = &old_active } },
    };
    try store.appendBlock(old_plan);
    try store.appendBlock(.{
        .id = 4,
        .session_id = 1,
        .turn_id = 20,
        .seq = 4,
        .ts = 4_000,
        .body = .{ .assistant_msg = .{ .text = "pause" } },
    });
    try store.appendBlock(.{
        .id = 5,
        .session_id = 1,
        .turn_id = 21,
        .seq = 5,
        .ts = 5_000,
        .body = .{ .user_msg = .{ .text = "continue" } },
    });
    var legacy_done = [_]block.PlanItem{.{ .step = "Legacy", .status = .completed }};
    try stampPlanTimings(&store, 1, 21, &legacy_done, &.{old_plan}, 5_500);
    try std.testing.expectEqual(@as(u64, 2_500), legacy_done[0].duration_ms);

    const completed_history = [_]block.Block{.{
        .id = 6,
        .session_id = 1,
        .turn_id = 10,
        .seq = 6,
        .ts = 4_250,
        .body = .{ .plan = .{ .items = &completed } },
    }};
    var unchanged = [_]block.PlanItem{.{ .step = "Inspect", .status = .completed }};
    try stampPlanTimings(&store, 1, 30, &unchanged, &completed_history, 9_000);
    try std.testing.expectEqual(@as(u64, 3_250), unchanged[0].duration_ms);
}

test "plan completion requires a preceding in-progress revision" {
    const prior_items = [_]block.PlanItem{
        .{ .step = "Inspect", .status = .completed },
        .{ .step = "Implement", .status = .in_progress },
        .{ .step = "Verify", .status = .pending },
    };
    const history = [_]block.Block{.{
        .id = 1,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 1_000,
        .body = .{ .plan = .{ .items = &prior_items } },
    }};

    const valid = [_]block.PlanItem{
        .{ .step = "Inspect", .status = .completed },
        .{ .step = "Implement", .status = .completed },
        .{ .step = "Verify", .status = .in_progress },
    };
    try std.testing.expect(skippedPlanCompletion(&valid, &history) == null);

    const skipped = [_]block.PlanItem{
        .{ .step = "Inspect", .status = .completed },
        .{ .step = "Implement", .status = .completed },
        .{ .step = "Verify", .status = .completed },
    };
    try std.testing.expectEqualStrings("Verify", skippedPlanCompletion(&skipped, &history).?);

    const retrospective = [_]block.PlanItem{.{ .step = "Already done", .status = .completed }};
    try std.testing.expectEqualStrings("Already done", skippedPlanCompletion(&retrospective, &.{}).?);

    const gpa = std.testing.allocator;
    const owned_items = try gpa.alloc(block.PlanItem, 1);
    owned_items[0] = .{ .step = try gpa.dupe(u8, "Verify"), .status = .completed };
    var exec = tools_registry.ExecOut{
        .output = try gpa.dupe(u8, "plan updated: 3/3 completed"),
        .status = .ok,
        .plan_items = owned_items,
    };
    defer exec.deinit(gpa);
    try enforcePlanTransitions(gpa, &exec, &history);
    try std.testing.expectEqual(block.ToolStatus.err, exec.status);
    try std.testing.expect(exec.plan_items == null);
    try std.testing.expect(std.mem.indexOf(u8, exec.output, "was not in_progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, exec.output, "omit work completed before planning") != null);
}

test "plan tool profile permits investigation and denies execution mutations" {
    const Probe = struct {
        fn task(_: ?*anyopaque, _: u64, _: []const u8) tools_registry.ExecOut {
            unreachable;
        }
    };
    const opts = RunOpts{
        .session_id = 1,
        .cwd = "/tmp",
        .endpoint = .{ .url = "http://unused", .bearer = null, .model = "m", .backend = .{ .native = .openai_compatible } },
        .cfg = config.defaults(),
        .tool_profile = .plan,
        .on_task = Probe.task,
    };
    try std.testing.expect(toolAllowed(opts, tools_registry.find("read_file").?));
    try std.testing.expect(toolAllowed(opts, tools_registry.find("grep").?));
    try std.testing.expect(toolAllowed(opts, tools_registry.find("fetch").?));
    try std.testing.expect(toolAllowed(opts, tools_registry.find("task").?));
    try std.testing.expect(!toolAllowed(opts, tools_registry.find("bash").?));
    try std.testing.expect(!toolAllowed(opts, tools_registry.find("write_file").?));
    try std.testing.expect(!toolAllowed(opts, tools_registry.find("edit").?));
    try std.testing.expect(!toolAllowed(opts, tools_registry.find("plan_update").?));
}

test "OpenRouter web search requires visible progress" {
    try std.testing.expect(std.mem.indexOf(u8, openrouter_web_search_prompt, "user-visible progress note") != null);
    try std.testing.expect(std.mem.indexOf(u8, openrouter_web_search_prompt, "Never search silently") != null);
}

test "environment block reports cwd, git absence, and inactive regimes" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-envblock-test");
    defer temp.deinit();
    const dir = temp.path;

    const opts = RunOpts{
        .session_id = 1,
        .cwd = dir,
        .endpoint = .{ .url = "http://unused", .bearer = null, .model = "m", .backend = .{ .native = .openai_compatible } },
        .cfg = config.defaults(),
    };
    const env = try environmentBlock(gpa, io, &opts);
    defer gpa.free(env);

    try std.testing.expect(std.mem.indexOf(u8, env, "ENVIRONMENT") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, dir) != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "not a git repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "Shell sandbox: inactive") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "Network filtering: off") != null);
    // A plausible date, not the epoch: the year has four digits and 20xx.
    try std.testing.expect(std.mem.indexOf(u8, env, "date: 20") != null);

    // No MARLIN.md/AGENTS.md in the fresh dir → no instructions.
    try std.testing.expect(projectInstructions(gpa, io, dir) == null);
    const agents_path = try std.fs.path.join(gpa, &.{ dir, "AGENTS.md" });
    defer gpa.free(agents_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = agents_path, .data = "Use spaces, not tabs." });
    const instructions = projectInstructions(gpa, io, dir);
    defer if (instructions) |text| gpa.free(text);
    try std.testing.expectEqualStrings("Use spaces, not tabs.", instructions.?);
}

test "root round budget becomes an automatic continuation checkpoint" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-round-checkpoint-test");
    defer temp.deinit();
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, temp.path, "m", .auto);

    const result = try runTurn(gpa, io, &store, .{
        .session_id = 1,
        .cwd = temp.path,
        .endpoint = .{ .url = "http://unused", .bearer = null, .model = "m", .backend = .{ .native = .openai_compatible } },
        .cfg = config.defaults(),
        .max_rounds = 0,
        .auto_continue_round_budget = true,
    }, "work", &.{});
    defer gpa.free(result.text);

    try std.testing.expect(result.round_budget_reached);
    try std.testing.expect(!result.interrupted);
    const loaded = try store.getBlocks(1, 1, 10);
    defer {
        for (loaded) |*item| item.deinit();
        gpa.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("internal round checkpoint reached", loaded[1].blk.body.system_note.text);
}

test "delegated claude code turn persists the event stream as blocks" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cc-turn-test");
    defer temp.deinit();

    // Fixture `claude`: validates the sanctioned invocation shape, then
    // emits a canned stream-json transcript (one tool round + result).
    const script =
        \\#!/bin/sh
        \\case "$*" in *"--output-format stream-json"*) ;; *) exit 9 ;; esac
        \\case "$*" in *"--session-id "*) ;; *) exit 9 ;; esac
        \\case "$*" in *"--dangerously-skip-permissions"*) ;; *) exit 9 ;; esac
        \\case "$*" in *"--model fable-5"*) ;; *) exit 9 ;; esac
        \\echo '{"type":"system","subtype":"init","session_id":"x"}'
        \\echo '{"type":"assistant","message":{"content":[{"type":"text","text":"scanning repo"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}'
        \\echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt"}]}}'
        \\echo '{"type":"result","subtype":"success","result":"DELEGATE-OK","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":90}}'
        \\
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-claude" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(claude_code.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");

    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, temp.path, "claudecode/fable-5", .auto);

    const result = try runTurn(gpa, io, &store, .{
        .session_id = 1,
        .cwd = temp.path,
        .endpoint = .{ .url = "", .bearer = null, .model = "fable-5", .backend = .{ .guest = .claude_code } },
        .cfg = .{},
        .tool_environ = &env,
        .approval_mode = .auto,
    }, "do the thing", &.{});
    defer gpa.free(result.text);

    try std.testing.expectEqualStrings("DELEGATE-OK", result.text);
    try std.testing.expectEqual(@as(u64, 100), result.tokens_in);
    try std.testing.expectEqual(@as(u64, 5), result.tokens_out);

    const loaded = try store.getBlocks(1, 1, 1000);
    defer {
        for (loaded) |*lb| lb.deinit();
        gpa.free(loaded);
    }
    const expected_kinds = [_][]const u8{ "user_msg", "reasoning", "tool_call", "tool_result", "assistant_msg" };
    try std.testing.expectEqual(expected_kinds.len, loaded.len);
    for (expected_kinds, loaded) |want, lb| {
        try std.testing.expectEqualStrings(want, @tagName(lb.blk.body));
    }
    // The between-rounds prose became visible commentary, not raw reasoning.
    try std.testing.expect(loaded[1].blk.body.reasoning.commentary);
    try std.testing.expectEqualStrings("scanning repo", loaded[1].blk.body.reasoning.text);
    try std.testing.expectEqualStrings("Bash", loaded[2].blk.body.tool_call.name);
    try std.testing.expectEqualStrings("file.txt", loaded[3].blk.body.tool_result.inline_body);
}

test "delegated claude code turn consumes a steer racing finalization" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cc-steer-test");
    defer temp.deinit();
    const script =
        \\#!/bin/sh
        \\echo '{"type":"system","subtype":"init","session_id":"x"}'
        \\case "$*" in
        \\  *"guest steer"*) result=STEERED ;;
        \\  *) result=FIRST ;;
        \\esac
        \\printf '{"type":"result","subtype":"success","result":"%s","usage":{"input_tokens":1,"output_tokens":1}}\n' "$result"
        \\
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-claude" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(claude_code.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, temp.path, "claudecode/fable-5", .auto);

    const Probe = struct {
        pending: bool = false,
        closes: usize = 0,

        fn poll(ctx: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (!self.pending) return null;
            self.pending = false;
            return allocator.dupe(u8, "guest steer") catch null;
        }

        fn tryClose(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.closes += 1;
            if (self.closes == 1) {
                self.pending = true;
                return false;
            }
            return true;
        }
    };
    var probe = Probe{};
    const result = try runTurn(gpa, io, &store, .{
        .session_id = 1,
        .cwd = temp.path,
        .endpoint = .{ .url = "", .bearer = null, .model = "fable-5", .backend = .{ .guest = .claude_code } },
        .cfg = config.defaults(),
        .tool_environ = &env,
        .approval_mode = .auto,
        .on_delta_ctx = &probe,
        .poll_steer = Probe.poll,
        .try_close_steer = Probe.tryClose,
    }, "start", &.{});
    defer gpa.free(result.text);

    try std.testing.expectEqualStrings("STEERED", result.text);
    try std.testing.expectEqual(@as(usize, 2), probe.closes);
    const loaded = try store.getBlocks(1, 1, 1000);
    defer {
        for (loaded) |*lb| lb.deinit();
        gpa.free(loaded);
    }
    const expected = [_]block.BlockKind{ .user_msg, .assistant_msg, .steer, .assistant_msg };
    try std.testing.expectEqual(expected.len, loaded.len);
    for (expected, loaded) |kind, lb| try std.testing.expectEqual(kind, std.meta.activeTag(lb.blk.body));
}

test "delegated turn recovers when claude has never seen the derived session" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cc-resume-test");
    defer temp.deinit();

    // The observed live behavior: `--resume <unknown>` exits 0 with an
    // is_error result and NO init event; `--session-id` then works.
    const script =
        \\#!/bin/sh
        \\case "$*" in
        \\*"--resume "*)
        \\  echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"","usage":{"input_tokens":0,"output_tokens":0},"errors":["No conversation found with session ID: x"]}'
        \\  exit 0 ;;
        \\esac
        \\echo '{"type":"system","subtype":"init","session_id":"x"}'
        \\echo '{"type":"result","subtype":"success","result":"RECOVERED-OK","usage":{"input_tokens":3,"output_tokens":2}}'
        \\
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-claude" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(claude_code.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");

    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, temp.path, "claudecode/claude-fable-5", .auto);

    const opts = RunOpts{
        .session_id = 1,
        .cwd = temp.path,
        .endpoint = .{ .url = "", .bearer = null, .model = "claude-fable-5", .backend = .{ .guest = .claude_code } },
        .cfg = .{},
        .tool_environ = &env,
        .approval_mode = .auto,
    };
    // A prior turn makes the session look resumable on the marlin side.
    const first = try runTurn(gpa, io, &store, opts, "first turn", &.{});
    gpa.free(first.text);

    // Second turn: --resume fails the way the real binary does; the retry
    // must flip to --session-id and succeed instead of persisting "".
    const second = try runTurn(gpa, io, &store, opts, "hello fable", &.{});
    defer gpa.free(second.text);
    try std.testing.expectEqualStrings("RECOVERED-OK", second.text);
}

test "codex guest never silently falls back to API-key billing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const api_key = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"account":{"type":"apiKey"},"requiresOpenaiAuth":true}
    , .{});
    try std.testing.expect(std.mem.indexOf(u8, codexAccountError(api_key).?, "using an API key") != null);

    const chatgpt = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(),
        \\{"account":{"type":"chatgpt","email":"test@example.com","planType":"plus"},"requiresOpenaiAuth":true}
    , .{});
    try std.testing.expect(codexAccountError(chatgpt) == null);
}

test "codex guest persists app-server items and resumes its durable thread" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-codex-turn-test");
    defer temp.deinit();
    const script =
        \\#!/bin/sh
        \\case "$*" in "app-server --listen stdio://") ;; *) exit 9 ;; esac
        \\[ -z "$OPENAI_API_KEY" ] || exit 7
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*)
        \\      echo '{"id":1,"result":{"userAgent":"fake"}}' ;;
        \\    *'"method":"account/read"'*)
        \\      echo '{"id":2,"result":{"account":{"type":"chatgpt","email":"test@example.com","planType":"plus"},"requiresOpenaiAuth":true}}' ;;
        \\    *'"method":"thread/start"'*)
        \\      echo '{"id":3,"result":{"thread":{"id":"thread_marlin_test"}}}' ;;
        \\    *'"method":"thread/resume"'*)
        \\      echo '{"id":3,"result":{"thread":{"id":"thread_marlin_test"}}}' ;;
        \\    *'"method":"turn/start"'*)
        \\      echo '{"id":4,"result":{"turn":{"id":"turn_test","items":[],"status":"inProgress"}}}'
        \\      echo '{"method":"item/completed","params":{"threadId":"thread_marlin_test","turnId":"turn_test","completedAtMs":1,"item":{"id":"msg_0","type":"agentMessage","text":"checking workspace","phase":"commentary"}}}'
        \\      echo '{"method":"item/started","params":{"threadId":"thread_marlin_test","turnId":"turn_test","startedAtMs":2,"item":{"id":"cmd_1","type":"commandExecution","command":"pwd","commandActions":[],"cwd":"/tmp","status":"inProgress"}}}'
        \\      echo '{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"threadId":"thread_marlin_test","turnId":"turn_test","itemId":"cmd_1","command":"pwd","cwd":"/tmp","startedAtMs":2}}'
        \\      IFS= read -r approval
        \\      case "$approval" in *'"decision":"accept"'*) ;; *) exit 8 ;; esac
        \\      echo '{"method":"item/completed","params":{"threadId":"thread_marlin_test","turnId":"turn_test","completedAtMs":3,"item":{"id":"cmd_1","type":"commandExecution","command":"pwd","commandActions":[],"cwd":"/tmp","status":"completed","aggregatedOutput":"/tmp\\n","exitCode":0}}}'
        \\      echo '{"method":"item/agentMessage/delta","params":{"threadId":"thread_marlin_test","turnId":"turn_test","itemId":"msg_1","delta":"CODEX-OK"}}'
        \\      echo '{"method":"item/completed","params":{"threadId":"thread_marlin_test","turnId":"turn_test","completedAtMs":4,"item":{"id":"msg_1","type":"agentMessage","text":"CODEX-OK","phase":"final_answer"}}}'
        \\      echo '{"method":"thread/tokenUsage/updated","params":{"threadId":"thread_marlin_test","turnId":"turn_test","tokenUsage":{"last":{"inputTokens":12,"cachedInputTokens":3,"outputTokens":4,"reasoningOutputTokens":1,"totalTokens":16},"total":{"inputTokens":12,"cachedInputTokens":3,"outputTokens":4,"reasoningOutputTokens":1,"totalTokens":16},"modelContextWindow":200000}}}'
        \\      echo '{"method":"turn/completed","params":{"threadId":"thread_marlin_test","turn":{"id":"turn_test","items":[],"status":"completed"}}}' ;;
        \\  esac
        \\done
        \\
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-codex" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(codex.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("OPENAI_API_KEY", "must-not-reach-guest-tools");
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, temp.path, "codex/default", .auto);

    const opts = RunOpts{
        .session_id = 1,
        .cwd = temp.path,
        .endpoint = .{ .url = "", .bearer = null, .model = "default", .backend = .{ .guest = .codex } },
        .cfg = config.defaults(),
        .tool_environ = &env,
        .approval_mode = .default,
    };
    const first = try runTurn(gpa, io, &store, opts, "inspect", &.{});
    defer gpa.free(first.text);
    try std.testing.expectEqualStrings("CODEX-OK", first.text);
    try std.testing.expectEqual(@as(u64, 12), first.tokens_in);
    try std.testing.expectEqual(@as(u64, 4), first.tokens_out);
    const thread_id = (try store.getCodexThreadId(1)).?;
    defer gpa.free(thread_id);
    try std.testing.expectEqualStrings("thread_marlin_test", thread_id);

    const second = try runTurn(gpa, io, &store, opts, "continue", &.{});
    defer gpa.free(second.text);
    try std.testing.expectEqualStrings("CODEX-OK", second.text);

    const loaded = try store.getBlocks(1, 1, 1000);
    defer {
        for (loaded) |*item| item.deinit();
        gpa.free(loaded);
    }
    const expected = [_]block.BlockKind{
        .user_msg, .reasoning, .tool_call, .approval, .tool_result, .assistant_msg,
        .user_msg, .reasoning, .tool_call, .approval, .tool_result, .assistant_msg,
    };
    try std.testing.expectEqual(expected.len, loaded.len);
    for (expected, loaded) |kind, item| try std.testing.expectEqual(kind, item.blk.kind());
    try std.testing.expect(loaded[1].blk.body.reasoning.commentary);
    try std.testing.expectEqualStrings("Bash", loaded[2].blk.body.tool_call.name);
    try std.testing.expectEqualStrings("/tmp\n", loaded[4].blk.body.tool_result.inline_body);
}

test "tool-free responses consume steering and close the final-poll race" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var checks = SteeringWireChecks{};
    const server_thread = try std.Thread.spawn(.{}, serveSteeringCompletions, .{ io, &server, &checks });

    const url = try std.fmt.allocPrintSentinel(gpa, "http://127.0.0.1:{d}/v1/chat/completions", .{server.socket.address.getPort()}, 0);
    defer gpa.free(url);
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-steering-test");
    defer temp.deinit();
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, temp.path, "test/model", .auto);

    const SteerProbe = struct {
        polls: usize = 0,
        close_calls: usize = 0,
        raced_pending: bool = false,

        fn poll(ctx: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.polls += 1;
            if (self.polls == 2)
                return allocator.dupe(u8, "steer after first response") catch null;
            if (self.raced_pending) {
                self.raced_pending = false;
                return allocator.dupe(u8, "steer from close race") catch null;
            }
            return null;
        }

        fn tryClose(ctx: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.close_calls += 1;
            if (self.close_calls == 1) {
                self.raced_pending = true;
                return false;
            }
            return true;
        }
    };
    var probe = SteerProbe{};
    const result = try runTurn(gpa, io, &store, .{
        .session_id = 1,
        .cwd = temp.path,
        .endpoint = .{ .url = url, .bearer = null, .model = "test/model", .backend = .{ .native = .openai_compatible } },
        .cfg = config.defaults(),
        .approval_mode = .auto,
        .on_delta_ctx = &probe,
        .poll_steer = SteerProbe.poll,
        .try_close_steer = SteerProbe.tryClose,
    }, "initial request", &.{});
    defer gpa.free(result.text);
    server_thread.join();

    try std.testing.expectEqualStrings("THIRD", result.text);
    try std.testing.expectEqual(@as(usize, 3), checks.requests);
    try std.testing.expect(checks.second_saw_first_steer);
    try std.testing.expect(checks.third_saw_raced_steer);
    try std.testing.expectEqual(@as(usize, 2), probe.close_calls);

    const loaded = try store.getBlocks(1, 1, 1000);
    defer {
        for (loaded) |*lb| lb.deinit();
        gpa.free(loaded);
    }
    const expected = [_]block.BlockKind{
        .user_msg,
        .assistant_msg,
        .steer,
        .assistant_msg,
        .steer,
        .assistant_msg,
    };
    try std.testing.expectEqual(expected.len, loaded.len);
    for (expected, loaded) |kind, lb| try std.testing.expectEqual(kind, std.meta.activeTag(lb.blk.body));
}

test "anthropic dialect end-to-end: headers, body shape, and SSE decode" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var checks = AnthropicWireChecks{};
    const server_thread = try std.Thread.spawn(.{}, serveAnthropicMessages, .{ io, &server, &checks });
    defer server_thread.join();

    const url = try std.fmt.allocPrintSentinel(gpa, "http://127.0.0.1:{d}/v1/messages", .{server.socket.address.getPort()}, 0);
    defer gpa.free(url);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var http_client = try http.Client.init(gpa, io);
    defer http_client.deinit();

    const summary = try summarize(gpa, arena_state.allocator(), &http_client, .{
        .url = url,
        .bearer = "sk-ant-test",
        .model = "claude-sonnet-4-5",
        .backend = .{ .native = .anthropic },
    }, "transcript to summarize", null, .{}, context.compaction_prompt, null);

    try std.testing.expectEqualStrings("SUMMARY-OK", summary);
    try std.testing.expect(checks.saw_api_key);
    try std.testing.expect(checks.saw_version);
    // The Messages API authenticates via x-api-key; a stray bearer would be
    // sent to Anthropic's servers as a foreign credential.
    try std.testing.expect(!checks.saw_authorization);
    try std.testing.expect(checks.body_ok);
}

test "provider error note extracts direct message" {
    const note = try providerErrorNote(
        std.testing.allocator,
        429,
        "{\"error\":{\"message\":\"rate limit reached\"}}",
    );
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings("provider HTTP 429: rate limit reached", note);
}

test "provider error note unwraps OpenRouter upstream error" {
    const body =
        \\{"error":{"message":"Provider returned error","metadata":{"raw":"{\"error\":{\"message\":\"Invalid input name\"}}","provider_name":"Azure","attempts":[{"status":400},{"status":400}]}}}
    ;
    const note = try providerErrorNote(std.testing.allocator, 400, body);
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings("provider HTTP 400 via Azure: Invalid input name", note);
    try std.testing.expect(std.mem.indexOf(u8, note, "attempts") == null);
    try std.testing.expect(std.mem.indexOf(u8, note, "metadata") == null);
}

test "provider error note clips malformed response bodies" {
    const body = ("gateway dump\n" ** 80);
    const note = try providerErrorNote(std.testing.allocator, 502, body);
    defer std.testing.allocator.free(note);
    try std.testing.expect(note.len < 540);
    try std.testing.expect(std.mem.indexOfScalar(u8, note, '\n') == null);
}

test "parallel-safe groups are chunked at the worker cap" {
    var start: usize = 0;
    var chunks: usize = 0;
    var largest: usize = 0;
    while (start < 20) {
        const end = parallelChunkEnd(start, 20);
        const width = end - start;
        try std.testing.expect(width > 0);
        try std.testing.expect(width <= max_parallel_tool_workers);
        largest = @max(largest, width);
        chunks += 1;
        start = end;
    }
    try std.testing.expectEqual(@as(usize, 8), max_parallel_tool_workers);
    try std.testing.expectEqual(@as(usize, 3), chunks);
    try std.testing.expectEqual(max_parallel_tool_workers, largest);
}

test "task_batch runs bounded children concurrently and preserves result order" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const BatchProbe = struct {
        gpa: std.mem.Allocator,
        io: Io,
        live: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),

        fn call(ctx: ?*anyopaque, _: u64, args_json: []const u8) tools_registry.ExecOut {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const live = self.live.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak.fetchMax(live, .acq_rel);
            self.io.sleep(.fromMilliseconds(40), .awake) catch {};
            _ = self.live.fetchSub(1, .acq_rel);
            return .{
                .output = self.gpa.dupe(u8, args_json) catch @panic("oom"),
                .status = .ok,
            };
        }
    };
    var probe = BatchProbe{ .gpa = gpa, .io = io };
    const result = runTaskBatch(gpa, io, .{
        .session_id = 1,
        .cwd = "/tmp",
        .endpoint = .{ .url = "", .bearer = null, .model = "test", .backend = .{ .native = .openai_compatible } },
        .cfg = config.defaults(),
        .on_delta_ctx = &probe,
    }, 9,
        \\{"tasks":[{"prompt":"first"},{"prompt":"second"},{"prompt":"third"}]}
    , BatchProbe.call);
    defer gpa.free(result.output);

    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expect(probe.peak.load(.acquire) > 1);
    try std.testing.expect(probe.peak.load(.acquire) <= task_tool.max_batch_tasks);
    const first = std.mem.indexOf(u8, result.output, "first").?;
    const second = std.mem.indexOf(u8, result.output, "second").?;
    const third = std.mem.indexOf(u8, result.output, "third").?;
    try std.testing.expect(first < second and second < third);
}
