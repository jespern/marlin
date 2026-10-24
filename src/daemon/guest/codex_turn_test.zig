//! Unit tests for codex_turn.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in codex_turn.zig.

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

const codex_turn = @import("codex_turn.zig");

test {
    std.testing.refAllDecls(codex_turn);
}

test "child turn completion is not the root turn boundary" {
    var child = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"threadId":"child-thread","turn":{"rootTurnId":"root-turn","status":"completed"}}
    , .{});
    defer child.deinit();
    try std.testing.expect(!codex_turn.isPrimaryCodexThread(child.value, "root-thread"));

    var root = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"threadId":"root-thread","turn":{"status":"completed"}}
    , .{});
    defer root.deinit();
    try std.testing.expect(codex_turn.isPrimaryCodexThread(root.value, "root-thread"));
}

test "codex permission modes reach new and resumed threads" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const loop = @import("../loop.zig");
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-codex-permissions");
    defer temp.deinit();
    const script =
        \\#!/bin/sh
        \\read -r sandbox approval method < expected
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
        \\    *'"method":"account/read"'*) echo '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
        \\    *'"method":"thread/start"'*|*'"method":"thread/resume"'*)
        \\      case "$line" in *\"method\":\"$method\"*) ;; *) exit 10 ;; esac
        \\      case "$line" in *\"sandbox\":\"$sandbox\"*) ;; *) exit 11 ;; esac
        \\      case "$line" in *\"approvalPolicy\":\"$approval\"*) ;; *) exit 12 ;; esac
        \\      echo '{"id":3,"result":{"thread":{"id":"permissions-thread"}}}' ;;
        \\    *'"method":"turn/start"'*)
        \\      case "$line" in *\"approvalPolicy\":\"$approval\"*) ;; *) exit 13 ;; esac
        \\      echo '{"id":4,"result":{"turn":{"id":"permissions-turn"}}}'
        \\      echo '{"method":"item/completed","params":{"item":{"id":"reply","type":"agentMessage","text":"OK","phase":"final_answer"}}}'
        \\      echo '{"method":"turn/completed","params":{"turn":{"id":"permissions-turn","status":"completed"}}}' ;;
        \\  esac
        \\done
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-codex" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);
    const expected_path = try std.fs.path.join(gpa, &.{ temp.path, "expected" });
    defer gpa.free(expected_path);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(codex.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");
    var store = try Store.open(gpa, null);
    defer store.close();
    // Exercise both fresh threads and permission changes on existing threads.
    for ([_]loop.ToolProfile{ .full, .read_only, .plan }, 1..) |profile, session_id| {
        try store.createSession(session_id, 0, temp.path, "codex/default", .auto);
        var live = std.atomic.Value(u8).init(@intFromEnum(approval.Mode.auto));
        const opts: loop.RunOpts = .{
            .session_id = session_id,
            .cwd = temp.path,
            .endpoint = .{ .url = "", .bearer = null, .model = "default", .backend = .{ .guest = .codex } },
            .cfg = config.defaults(),
            .tool_environ = &env,
            .tool_profile = profile,
            .approval_mode = .default,
            .approval_mode_live = &live,
        };
        for ([_]approval.Mode{ .auto, .default, .auto }, 0..) |mode, turn| {
            live.store(@intFromEnum(mode), .release);
            const expected = try std.fmt.allocPrint(gpa, "{s} {s} {s}\n", .{
                if (profile != .full) "read-only" else if (mode == .auto) "danger-full-access" else "workspace-write",
                if (profile != .full or mode == .auto) "never" else "on-request",
                if (turn == 0) "thread/start" else "thread/resume",
            });
            defer gpa.free(expected);
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = expected_path, .data = expected });
            const result = try loop.runTurn(gpa, io, &store, opts, "check permissions", &.{});
            defer gpa.free(result.text);
            try std.testing.expectEqualStrings("OK", result.text);
        }
    }
}

test "codex otel overrides stand down for an operator-configured collector" {
    const OtelGuest = @import("../loop.zig").OtelGuest;
    const guest: OtelGuest = .{
        .base_endpoint = "https://otel.mirador.org",
        .headers = "Authorization=Bearer%20marlin",
        .capture_content = true,
    };

    // No collector configured by the operator: Marlin's pass-down applies.
    const applied = codex_turn.otelOverrides(guest, false).?;
    try std.testing.expectEqualStrings("https://otel.mirador.org", applied.base_endpoint);
    try std.testing.expectEqualStrings("Authorization=Bearer%20marlin", applied.headers);
    try std.testing.expect(applied.capture_content);

    // The operator's own [otel] exporter wins outright: overriding just the
    // endpoint would pair Marlin's collector with their Authorization header.
    try std.testing.expect(codex_turn.otelOverrides(guest, true) == null);
    // Marlin not exporting: nothing to pass down either way.
    try std.testing.expect(codex_turn.otelOverrides(null, false) == null);
    try std.testing.expect(codex_turn.otelOverrides(null, true) == null);
}

test "codex app-server requests carry the turn's W3C trace context" {
    const gpa = std.testing.allocator;
    const traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    // Request bodies are arena-owned in production; here too.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var traced_out: std.Io.Writer.Allocating = .init(gpa);
    defer traced_out.deinit();
    try codex_turn.codexRequest(
        arena,
        &traced_out.writer,
        "turn/start",
        7,
        codex.traceFor(traceparent),
        .{ .threadId = "thread-1" },
    );

    const traced = try std.json.parseFromSlice(std.json.Value, gpa, traced_out.written(), .{});
    defer traced.deinit();
    try std.testing.expectEqual(@as(i64, 7), traced.value.object.get("id").?.integer);
    // The app-server reads the JSON-RPC field, not the TRACEPARENT env var:
    // env-only runs produced parentless spans in unrelated trace ids, while
    // this field nests its spans under Marlin's turn span.
    const sent = traced.value.object.get("trace").?.object.get("traceparent").?;
    try std.testing.expectEqualStrings(traceparent, sent.string);
    try std.testing.expectEqualStrings(
        "thread-1",
        traced.value.object.get("params").?.object.get("threadId").?.string,
    );

    // No turn trace: the wire keeps exactly its pre-telemetry shape.
    var untraced_out: std.Io.Writer.Allocating = .init(gpa);
    defer untraced_out.deinit();
    try codex_turn.codexRequest(
        arena,
        &untraced_out.writer,
        "turn/start",
        7,
        codex.traceFor(null),
        .{ .threadId = "thread-1" },
    );
    const untraced = try std.json.parseFromSlice(std.json.Value, gpa, untraced_out.written(), .{});
    defer untraced.deinit();
    try std.testing.expect(untraced.value.object.get("trace") == null);
}

test "Codex failure classification keeps permanent errors terminal and preserves details" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_]struct { json: []const u8, recoverable: bool, text: []const u8 }{
        .{ .json = "{\"message\":\"{\\\"detail\\\":\\\"Bad Request\\\"}\",\"codexErrorInfo\":\"other\"}", .recoverable = true, .text = "Bad Request (the backend supplied no further explanation)" },
        .{ .json = "{\"message\":\"connection lost\",\"codexErrorInfo\":{\"responseStreamDisconnected\":{\"httpStatusCode\":503}},\"additionalDetails\":\"request id abc\"}", .recoverable = true, .text = "connection lost (Codex: responseStreamDisconnected) (HTTP 503): request id abc" },
        .{ .json = "{\"message\":\"Unauthorized\",\"codexErrorInfo\":{\"httpConnectionFailed\":{\"httpStatusCode\":401}}}", .recoverable = false, .text = "Unauthorized (Codex: httpConnectionFailed) (HTTP 401)" },
    }) |case| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, case.json, .{});
        const failure = try codex_turn.turnFailure(arena, value);
        try std.testing.expectEqual(case.recoverable, failure.recoverable);
        try std.testing.expectEqualStrings(case.text, failure.text);
    }
    for ([_][]const u8{ "unauthorized", "badRequest", "contextWindowExceeded", "usageLimitExceeded", "rateLimitExceeded", "cyberPolicy", "misalignmentPolicyViolation", "sandboxError" }) |kind| {
        const raw = try std.fmt.allocPrint(arena, "{{\"message\":\"Bad Request\",\"codexErrorInfo\":\"{s}\"}}", .{kind});
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
        try std.testing.expect(!(try codex_turn.turnFailure(arena, value)).recoverable);
    }
}

test "Codex terminal failure continues the same thread with bounded attempts and cancellation" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const loop = @import("../loop.zig");
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-codex-recovery");
    defer temp.deinit();
    const script =
        \\#!/bin/sh
        \\read -r mode < mode
        \\n=0
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) echo '{"id":1,"result":{}}' ;;
        \\    *'"method":"account/read"'*) echo '{"id":2,"result":{"account":{"type":"chatgpt"}}}' ;;
        \\    *'"method":"thread/start"'*) echo '{"id":3,"result":{"thread":{"id":"saved-thread"}}}' ;;
        \\    *'"method":"turn/start"'*)
        \\      n=$((n+1))
        \\      echo "$n" > attempts
        \\      case "$line" in *'"threadId":"saved-thread"'*) ;; *) exit 10 ;; esac
        \\      if [ "$n" -gt 1 ]; then
        \\        case "$line" in *'Continue the interrupted task from the current saved state.'*) ;; *) exit 11 ;; esac
        \\        case "$line" in *ORIGINAL_REQUEST*) exit 12 ;; esac
        \\      fi
        \\      id=$((n+3))
        \\      if [ "$mode" = rpc ] && [ "$n" -gt 1 ]; then
        \\        echo '{"id":5,"error":{"code":-32602,"message":"invalid continuation"}}'
        \\        continue
        \\      fi
        \\      echo "{\"id\":$id,\"result\":{\"turn\":{\"id\":\"turn-$n\"}}}"
        \\      if [ "$n" -eq 1 ]; then
        \\        echo '{"method":"item/started","params":{"threadId":"saved-thread","item":{"type":"commandExecution","id":"only-once","command":"completed action"}}}'
        \\        echo '{"method":"item/completed","params":{"threadId":"saved-thread","item":{"type":"commandExecution","id":"only-once","status":"completed","aggregatedOutput":"done"}}}'
        \\      fi
        \\      echo '{"method":"thread/tokenUsage/updated","params":{"threadId":"saved-thread","tokenUsage":{"last":{"inputTokens":12,"outputTokens":4}}}}'
        \\      if [ "$mode" = vendor ] || { [ "$mode" = recover ] && [ "$n" -gt 1 ]; }; then
        \\        echo '{"method":"error","params":{"threadId":"child","turnId":"child-turn","willRetry":false,"error":{"message":"child failure"}}}'
        \\        echo '{"method":"turn/completed","params":{"threadId":"child","turn":{"id":"child-turn","status":"failed","error":{"message":"child failure"}}}}'
        \\        echo '{"method":"turn/completed","params":{"threadId":"saved-thread","turn":{"id":"stale-turn","status":"failed","error":{"message":"stale failure"}}}}'
        \\        echo '{"method":"error","params":{"threadId":"saved-thread","willRetry":true,"error":{"message":"vendor is retrying","codexErrorInfo":"internalServerError"}}}'
        \\        echo '{"method":"item/completed","params":{"threadId":"saved-thread","item":{"type":"agentMessage","id":"reply","text":"RECOVERED","phase":"final_answer"}}}'
        \\        echo "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"saved-thread\",\"turn\":{\"id\":\"turn-$n\",\"status\":\"completed\"}}}"
        \\      else
        \\        kind=other
        \\        [ "$mode" != permanent ] || kind=unauthorized
        \\        echo "{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"saved-thread\",\"turn\":{\"id\":\"turn-$n\",\"status\":\"failed\",\"error\":{\"message\":\"{\\\"detail\\\":\\\"Bad Request\\\"}\",\"codexErrorInfo\":\"$kind\"}}}}"
        \\      fi ;;
        \\  esac
        \\done
    ;
    const script_path = try std.fs.path.joinZ(gpa, &.{ temp.path, "fake-codex" });
    defer gpa.free(script_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    _ = std.c.chmod(script_path, 0o755);
    const mode_path = try std.fs.path.join(gpa, &.{ temp.path, "mode" });
    defer gpa.free(mode_path);
    const attempts_path = try std.fs.path.join(gpa, &.{ temp.path, "attempts" });
    defer gpa.free(attempts_path);
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put(codex.binary_env, script_path);
    try env.put("PATH", "/usr/bin:/bin");
    const Probe = struct {
        cancel: std.atomic.Value(bool) = .init(false),
        cancel_recovery: bool,
        recovery_notes: usize = 0,

        fn onBlock(ctx: ?*anyopaque, b: block.Block) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (b.body != .system_note) return;
            if (std.mem.indexOf(u8, b.body.system_note.text, "Continuing the existing thread automatically") == null) return;
            self.recovery_notes += 1;
            if (self.cancel_recovery) self.cancel.store(true, .release);
        }
    };
    for ([_][]const u8{ "recover", "repeat", "permanent", "cancel", "deadline", "vendor", "rpc" }) |mode| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = mode_path, .data = mode });
        var store = try Store.open(gpa, null);
        defer store.close();
        try store.createSession(1, 0, temp.path, "codex/default", .auto);
        var probe = Probe{ .cancel_recovery = std.mem.eql(u8, mode, "cancel") };
        var cfg = config.defaults();
        const deadline = std.mem.eql(u8, mode, "deadline");
        cfg.guest_max_runtime_ms = if (deadline) 2_000 else 10_000;
        const opts: loop.RunOpts = .{
            .session_id = 1,
            .cwd = temp.path,
            .endpoint = .{ .url = "", .bearer = null, .model = "default", .backend = .{ .guest = .codex } },
            .cfg = cfg,
            .tool_environ = &env,
            .cancel = &probe.cancel,
            .on_block = Probe.onBlock,
            .on_delta_ctx = &probe,
        };
        const expected_attempts: usize = if (std.mem.eql(u8, mode, "repeat")) 3 else if (std.mem.eql(u8, mode, "recover") or std.mem.eql(u8, mode, "rpc") or deadline) 2 else 1;
        if (std.mem.eql(u8, mode, "recover") or std.mem.eql(u8, mode, "vendor") or std.mem.eql(u8, mode, "cancel")) {
            const result = try loop.runTurn(gpa, io, &store, opts, "ORIGINAL_REQUEST", &.{});
            defer gpa.free(result.text);
            try std.testing.expectEqual(probe.cancel_recovery, result.interrupted);
            if (!probe.cancel_recovery) try std.testing.expectEqualStrings("RECOVERED", result.text);
            try std.testing.expectEqual(@as(u64, expected_attempts * 12), result.tokens_in);
            try std.testing.expectEqual(@as(u64, expected_attempts * 4), result.tokens_out);
        } else if (deadline) {
            try std.testing.expectError(error.DelegateTimeout, loop.runTurn(gpa, io, &store, opts, "ORIGINAL_REQUEST", &.{}));
        } else {
            try std.testing.expectError(error.DelegateFailed, loop.runTurn(gpa, io, &store, opts, "ORIGINAL_REQUEST", &.{}));
            const detail = @import("shared.zig").lastDelegateErrorNote().?;
            try std.testing.expect(std.mem.indexOf(u8, detail, if (std.mem.eql(u8, mode, "repeat")) "Stopped after 2" else if (std.mem.eql(u8, mode, "rpc")) "invalid continuation" else "unauthorized") != null);
        }
        const attempts = try Io.Dir.cwd().readFileAlloc(io, attempts_path, gpa, .limited(100));
        defer gpa.free(attempts);
        try std.testing.expectEqual(expected_attempts, try std.fmt.parseInt(usize, std.mem.trim(u8, attempts, "\n"), 10));
        try std.testing.expectEqual(if (probe.cancel_recovery or deadline) expected_attempts else expected_attempts - 1, probe.recovery_notes);
        const blocks = try store.getBlocks(1, 1, 100);
        defer {
            for (blocks) |*b| b.deinit();
            gpa.free(blocks);
        }
        var calls: usize = 0;
        var results: usize = 0;
        for (blocks) |b| {
            if (b.blk.body == .tool_call) calls += 1;
            if (b.blk.body == .tool_result) results += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), calls);
        try std.testing.expectEqual(@as(usize, 1), results);
    }
}
