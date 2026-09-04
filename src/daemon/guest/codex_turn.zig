//! GUEST turn: Codex. Drives `codex app-server` over its JSON-RPC stdio
//! protocol using the user's existing ChatGPT login, persists items as
//! blocks, and refuses API-key billing. Same wall as claude_code_turn.zig:
//! loop.zig is the native agent turn; this file hosts a vendor agent.

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

// The native loop owns the block appender, turn options, phase publication,
// steer handling, and approval resolution; guests borrow exactly these.
const loop = @import("../loop.zig");
const Appender = loop.Appender;
const RunOpts = loop.RunOpts;
const TurnResult = loop.TurnResult;
const cancelled = loop.cancelled;
const effectiveApprovalMode = loop.effectiveApprovalMode;
const nowMs = loop.nowMs;
const publishPhase = loop.publishPhase;
const resolveGuestApproval = loop.resolveGuestApproval;
const tryCloseSteering = loop.tryCloseSteering;

const shared = @import("shared.zig");
const setDelegateError = shared.setDelegateError;
const lastDelegateErrorNote = shared.lastDelegateErrorNote;
const putEnvDefault = shared.putEnvDefault;
const CcWatcher = shared.CcWatcher;
const CcStderrDrain = shared.CcStderrDrain;

const codex_deadline_ms: i64 = 60 * 60 * 1000;
const codex_line_bytes: usize = 4 * 1024 * 1024;

fn codexWriteLine(writer: *Io.Writer, line: []const u8) !void {
    try writer.writeAll(line);
    try writer.writeByte('\n');
    try writer.flush();
}

fn codexWriteValue(arena: std.mem.Allocator, writer: *Io.Writer, value: anytype) !void {
    const encoded = try std.json.Stringify.valueAlloc(arena, value, .{});
    try codexWriteLine(writer, encoded);
}

fn codexWaitResponse(
    arena: std.mem.Allocator,
    reader: *Io.Reader,
    request_id: i64,
) !codex.Response {
    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch return error.CodexAppServerExited;
        const inbound = codex.decodeLine(arena, line) catch continue;
        switch (inbound) {
            .response => |response| if (response.id == request_id) return response,
            else => {},
        }
    }
}

fn codexRpcError(arena: std.mem.Allocator, response: codex.Response) ?[]const u8 {
    const value = response.err orelse return null;
    if (codex.strField(value, "message")) |message| return message;
    return codex.stringify(arena, value) catch "app-server request failed";
}

fn codexToolName(arena: std.mem.Allocator, item: std.json.Value) !?[]const u8 {
    const kind = codex.strField(item, "type") orelse return null;
    if (std.mem.eql(u8, kind, "commandExecution")) return "Bash";
    if (std.mem.eql(u8, kind, "fileChange")) return "Edit";
    if (std.mem.eql(u8, kind, "webSearch")) return "WebSearch";
    if (std.mem.eql(u8, kind, "imageView")) return "ImageView";
    if (std.mem.eql(u8, kind, "imageGeneration")) return "ImageGeneration";
    if (std.mem.eql(u8, kind, "sleep")) return "Sleep";
    if (std.mem.eql(u8, kind, "mcpToolCall")) {
        return try std.fmt.allocPrint(arena, "MCP {s}/{s}", .{
            codex.strField(item, "server") orelse "server",
            codex.strField(item, "tool") orelse "tool",
        });
    }
    if (std.mem.eql(u8, kind, "dynamicToolCall") or
        std.mem.eql(u8, kind, "collabAgentToolCall"))
    {
        return codex.strField(item, "tool") orelse kind;
    }
    return null;
}

fn codexToolBody(arena: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    const kind = codex.strField(item, "type") orelse return codex.stringify(arena, item);
    if (std.mem.eql(u8, kind, "commandExecution"))
        return codex.strField(item, "aggregatedOutput") orelse "";
    if (std.mem.eql(u8, kind, "fileChange")) {
        const changes = codex.field(item, "changes") orelse return "file change completed";
        if (changes != .array) return "file change completed";
        var joined: std.ArrayList(u8) = .empty;
        for (changes.array.items) |change| {
            const diff = codex.strField(change, "diff") orelse continue;
            if (joined.items.len > 0) try joined.append(arena, '\n');
            try joined.appendSlice(arena, diff);
        }
        return if (joined.items.len > 0) joined.items else "file change completed";
    }
    if (codex.field(item, "result")) |result| return codex.stringify(arena, result);
    if (codex.field(item, "error")) |err_value| {
        if (err_value != .null) return codex.stringify(arena, err_value);
    }
    return codex.stringify(arena, item);
}

fn codexStatus(item: std.json.Value) block.ToolStatus {
    const status = codex.strField(item, "status") orelse return .ok;
    return if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "declined")) .err else .ok;
}

fn appendCodexItemStarted(
    arena: std.mem.Allocator,
    ap: *Appender,
    opts: RunOpts,
    item: std.json.Value,
) !void {
    const name = (try codexToolName(arena, item)) orelse return;
    const call_id = codex.strField(item, "id") orelse return;
    const args = try codex.stringify(arena, item);
    // Same redaction discipline as the native tool_call append.
    const persisted_args = (try permissions.redactSecrets(arena, opts.secrets, args)) orelse args;
    _ = try ap.append(.{ .tool_call = .{
        .call_id = call_id,
        .name = name,
        .args_json = persisted_args,
    } });
    if (opts.on_tool) |callback| callback(opts.on_delta_ctx, name, .start);
}

fn appendCodexToolCompleted(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ap: *Appender,
    opts: RunOpts,
    item: std.json.Value,
) !bool {
    const name = (try codexToolName(arena, item)) orelse return false;
    const call_id = codex.strField(item, "id") orelse return false;
    const raw_body = try codexToolBody(arena, item);
    const redacted = try permissions.redactSecrets(gpa, opts.secrets, raw_body);
    defer if (redacted) |value| gpa.free(value);
    const body = redacted orelse raw_body;
    _ = try ap.append(.{ .tool_result = .{
        .call_id = call_id,
        .status = codexStatus(item),
        .inline_body = body[0..@min(body.len, opts.cfg.inline_tool_cap_bytes)],
        .full_body_ref = null,
    } });
    if (opts.on_tool) |callback| callback(opts.on_delta_ctx, name, .done);
    return true;
}

fn appendCodexReasoning(arena: std.mem.Allocator, ap: *Appender, item: std.json.Value) !void {
    const summary = codex.field(item, "summary") orelse return;
    if (summary != .array) return;
    var joined: std.ArrayList(u8) = .empty;
    for (summary.array.items) |part| {
        if (part != .string) continue;
        if (joined.items.len > 0) try joined.append(arena, '\n');
        try joined.appendSlice(arena, part.string);
    }
    if (joined.items.len > 0)
        _ = try ap.append(.{ .reasoning = .{ .text = joined.items } });
}

fn codexApprovalPolicy(opts: RunOpts) []const u8 {
    if (opts.tool_profile != .full) return "never";
    return if (effectiveApprovalMode(opts) == .auto) "never" else "on-request";
}

fn codexSandbox(opts: RunOpts) []const u8 {
    return if (opts.tool_profile == .full) "workspace-write" else "read-only";
}

fn codexModel(opts: RunOpts) ?[]const u8 {
    return if (std.mem.eql(u8, opts.endpoint.model, "default")) null else opts.endpoint.model;
}

pub fn codexAccountError(account_result: std.json.Value) ?[]const u8 {
    const account = codex.field(account_result, "account");
    const account_type = if (account) |value| codex.strField(value, "type") else null;
    if (account_type != null and std.mem.eql(u8, account_type.?, "chatgpt")) return null;
    if (account_type != null and std.mem.eql(u8, account_type.?, "apiKey"))
        return "Codex guest requires a ChatGPT login, but Codex is using an API key — run `codex logout`, then `codex login` without `--with-api-key`";
    return "Codex guest requires a ChatGPT login — run `codex login`, then retry";
}

fn codexSendTurnStart(
    arena: std.mem.Allocator,
    writer: *Io.Writer,
    reader: *Io.Reader,
    request_id: i64,
    thread_id: []const u8,
    opts: RunOpts,
    text: []const u8,
) ![]const u8 {
    try codexWriteValue(arena, writer, .{
        .method = "turn/start",
        .id = request_id,
        .params = .{
            .threadId = thread_id,
            .input = .{.{ .type = "text", .text = text }},
            .cwd = opts.cwd,
            .model = codexModel(opts),
            .effort = opts.effort.providerValue(),
            .approvalPolicy = codexApprovalPolicy(opts),
            .approvalsReviewer = "user",
        },
    });
    const response = try codexWaitResponse(arena, reader, request_id);
    if (codexRpcError(arena, response)) |message| {
        setDelegateError(message);
        return error.DelegateFailed;
    }
    const result = response.result orelse return error.BadCodexResponse;
    const turn = codex.field(result, "turn") orelse return error.BadCodexResponse;
    return codex.strField(turn, "id") orelse error.BadCodexResponse;
}

fn sendCodexSteers(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    writer: *Io.Writer,
    opts: RunOpts,
    ap: *Appender,
    thread_id: []const u8,
    turn_id: []const u8,
    next_request_id: *i64,
) !usize {
    const poll = opts.poll_steer orelse return 0;
    var count: usize = 0;
    while (poll(opts.on_delta_ctx, gpa)) |text| {
        defer gpa.free(text);
        _ = try ap.append(.{ .steer = .{ .text = text } });
        try codexWriteValue(arena, writer, .{
            .method = "turn/steer",
            .id = next_request_id.*,
            .params = .{
                .threadId = thread_id,
                .expectedTurnId = turn_id,
                .input = .{.{ .type = "text", .text = text }},
            },
        });
        next_request_id.* += 1;
        count += 1;
    }
    return count;
}

pub fn runCodexTurn(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    opts: RunOpts,
    ap: *Appender,
    first_text: []const u8,
) !TurnResult {
    shared.clearDelegateError();
    publishPhase(opts, .provider);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = try codex.buildArgv(arena, opts.tool_environ, if (opts.otel_guest) |guest| .{
        .base_endpoint = guest.base_endpoint,
        .traces_endpoint = guest.traces_endpoint,
        .headers = guest.headers,
        .capture_content = guest.capture_content,
    } else null);
    var guest_environ: ?std.process.Environ.Map = if (opts.tool_environ) |source|
        try permissions.toolEnvironment(gpa, source)
    else
        null;
    defer if (guest_environ) |*map| map.deinit();
    // Codex reads its collector from config overrides above; TRACEPARENT
    // still travels via the environment so subprocesses it spawns (and any
    // future inbound-context support) can nest under Marlin's turn trace.
    var codex_traceparent_buf: [64]u8 = undefined;
    if (opts.otel_guest != null) {
        if (guest_environ) |*map| {
            const trace_id = telemetry_ids.traceId(opts.session_id, ap.turn_id);
            const root_span = telemetry_ids.spanId(ap.turn_id);
            const traceparent = std.fmt.bufPrint(
                &codex_traceparent_buf,
                "00-{s}-{s}-01",
                .{ trace_id[0..], root_span[0..] },
            ) catch unreachable;
            _ = putEnvDefault(map, "TRACEPARENT", traceparent);
        }
    }
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = if (guest_environ) |*map| map else null,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        const note: []const u8 = if (err == error.FileNotFound)
            "codex binary not found — install Codex (or set MARLIN_CODEX_BIN)"
        else
            "failed to spawn codex app-server";
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateSpawnFailed;
    };

    var watcher = CcWatcher{
        .io = io,
        .cancel = opts.cancel,
        .group = child.id.?,
        .deadline_at = nowMs(io) + codex_deadline_ms,
    };
    const watcher_thread = try std.Thread.spawn(.{}, CcWatcher.run, .{&watcher});
    var drain = CcStderrDrain{ .io = io, .file = child.stderr.? };
    const drain_thread = std.Thread.spawn(.{}, CcStderrDrain.run, .{&drain}) catch null;
    defer {
        watcher.done.store(true, .release);
        watcher_thread.join();
        // The app-server is per turn. Its foreground work has completed; reap
        // the whole owned group immediately so background descendants cannot
        // outlive the Marlin turn or add half a second of teardown latency.
        process_io.terminateProcessGroup(io, child.id.?, 0);
        if (drain_thread) |thread| thread.join();
        _ = child.wait(io) catch {};
    }

    var writer_buffer: [64 * 1024]u8 = undefined;
    var writer_file = child.stdin.?.writer(io, &writer_buffer);
    const writer = &writer_file.interface;
    const line_buffer = try gpa.alloc(u8, codex_line_bytes);
    defer gpa.free(line_buffer);
    var reader_file = child.stdout.?.reader(io, line_buffer);
    const reader = &reader_file.interface;

    try codexWriteValue(arena, writer, .{
        .method = "initialize",
        .id = 1,
        .params = .{ .clientInfo = .{
            .name = "marlin",
            .title = "Marlin",
            .version = build_options.version,
        } },
    });
    const initialized = try codexWaitResponse(arena, reader, 1);
    if (codexRpcError(arena, initialized)) |message| {
        setDelegateError(message);
        _ = try ap.append(.{ .system_note = .{ .text = message } });
        return error.DelegateFailed;
    }
    try codexWriteValue(arena, writer, .{ .method = "initialized" });

    // Fail early with a useful login instruction instead of letting a null
    // account decay into an opaque failed turn.
    try codexWriteValue(arena, writer, .{
        .method = "account/read",
        .id = 2,
        .params = .{ .refreshToken = true },
    });
    const account_response = try codexWaitResponse(arena, reader, 2);
    if (codexRpcError(arena, account_response)) |message| {
        setDelegateError(message);
        _ = try ap.append(.{ .system_note = .{ .text = message } });
        return error.DelegateFailed;
    }
    const account_result = account_response.result orelse return error.BadCodexResponse;
    if (codexAccountError(account_result)) |note| {
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateFailed;
    }

    var next_request_id: i64 = 3;
    var thread_id: []const u8 = undefined;
    const saved_thread_id = try store.getCodexThreadId(opts.session_id);
    defer if (saved_thread_id) |saved| gpa.free(saved);
    if (saved_thread_id) |saved| {
        try codexWriteValue(arena, writer, .{
            .method = "thread/resume",
            .id = next_request_id,
            .params = .{
                .threadId = saved,
                .cwd = opts.cwd,
                .model = codexModel(opts),
                .approvalPolicy = codexApprovalPolicy(opts),
                .approvalsReviewer = "user",
                .sandbox = codexSandbox(opts),
            },
        });
        const resumed = try codexWaitResponse(arena, reader, next_request_id);
        next_request_id += 1;
        if (resumed.err == null) {
            const result = resumed.result orelse return error.BadCodexResponse;
            const thread = codex.field(result, "thread") orelse return error.BadCodexResponse;
            thread_id = codex.strField(thread, "id") orelse return error.BadCodexResponse;
        } else {
            // The rollout may have been removed outside Marlin. Recreate it
            // and atomically replace the stale mapping.
            try store.setCodexThreadId(opts.session_id, null);
            thread_id = "";
        }
    } else {
        thread_id = "";
    }
    if (thread_id.len == 0) {
        try codexWriteValue(arena, writer, .{
            .method = "thread/start",
            .id = next_request_id,
            .params = .{
                .cwd = opts.cwd,
                .model = codexModel(opts),
                .approvalPolicy = codexApprovalPolicy(opts),
                .approvalsReviewer = "user",
                .sandbox = codexSandbox(opts),
                .ephemeral = false,
            },
        });
        const started = try codexWaitResponse(arena, reader, next_request_id);
        next_request_id += 1;
        if (codexRpcError(arena, started)) |message| {
            setDelegateError(message);
            _ = try ap.append(.{ .system_note = .{ .text = message } });
            return error.DelegateFailed;
        }
        const result = started.result orelse return error.BadCodexResponse;
        const thread = codex.field(result, "thread") orelse return error.BadCodexResponse;
        thread_id = codex.strField(thread, "id") orelse return error.BadCodexResponse;
        try store.setCodexThreadId(opts.session_id, thread_id);
    }

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(gpa);
    try prompt.appendSlice(gpa, first_text);
    {
        var history: std.ArrayList(block.Block) = .empty;
        var history_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer history_arena_state.deinit();
        store.loadContextBlocksInto(history_arena_state.allocator(), &history, opts.session_id, 1_000_000) catch {};
        if (context.latestHandover(history.items)) |briefing| {
            prompt.clearRetainingCapacity();
            try prompt.print(gpa, "HANDOVER FROM MARLIN (previous agent in this session). Continue from this briefing; you will not see its block log.\n\n{s}\n\n---\n\nUSER\n{s}", .{ briefing, first_text });
        }
    }

    var active_turn_id = try codexSendTurnStart(arena, writer, reader, next_request_id, thread_id, opts, prompt.items);
    next_request_id += 1;
    var rounds: u32 = 1;
    var tokens_in: u64 = 0;
    var tokens_out: u64 = 0;
    var current_tokens_in: u64 = 0;
    var current_tokens_out: u64 = 0;
    var final_text: std.ArrayList(u8) = .empty;
    defer final_text.deinit(gpa);
    var done = false;
    var interrupted = false;
    var failed = false;
    var failure_text: []const u8 = "codex turn failed";

    var line_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer line_arena_state.deinit();
    var line_acc: std.ArrayList(u8) = .empty;
    defer line_acc.deinit(gpa);
    while (!done) {
        const line = shared.takeEventLine(reader, gpa, &line_acc, shared.max_event_line_bytes) catch |err| switch (err) {
            error.LineTooLong => {
                _ = try ap.append(.{ .system_note = .{ .text = "codex: one event line exceeded 64 MiB and was dropped" } });
                continue;
            },
            error.ReadFailed => break,
            error.OutOfMemory => return error.OutOfMemory,
        } orelse break;
        _ = line_arena_state.reset(.retain_capacity);
        const line_arena = line_arena_state.allocator();
        const inbound = codex.decodeLine(line_arena, line) catch continue;
        switch (inbound) {
            .response => |response| {
                if (response.err) |err_value| {
                    if (codex.strField(err_value, "message")) |message| {
                        setDelegateError(message);
                        failure_text = lastDelegateErrorNote().?;
                    }
                }
            },
            .request => |request| {
                const is_command = std.mem.eql(u8, request.method, "item/commandExecution/requestApproval");
                const is_file = std.mem.eql(u8, request.method, "item/fileChange/requestApproval");
                if (is_command or is_file) {
                    const args = try codex.stringify(line_arena, request.params);
                    const call_id = codex.strField(request.params, "itemId") orelse request.id_json;
                    const tool = if (is_command) "Bash" else "Edit";
                    const verdict = try resolveGuestApproval(gpa, io, opts, ap, call_id, tool, args);
                    const response = try std.fmt.allocPrint(line_arena, "{{\"id\":{s},\"result\":{{\"decision\":\"{s}\"}}}}", .{ request.id_json, if (verdict == .approved) "accept" else "decline" });
                    try codexWriteLine(writer, response);
                } else {
                    const response = try std.fmt.allocPrint(line_arena, "{{\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"unsupported app-server request\"}}}}", .{request.id_json});
                    try codexWriteLine(writer, response);
                }
            },
            .notification => |notification| {
                const params = notification.params;
                if (std.mem.eql(u8, notification.method, "item/agentMessage/delta")) {
                    if (codex.strField(params, "delta")) |delta|
                        if (opts.on_delta) |callback| callback(opts.on_delta_ctx, delta);
                } else if (std.mem.eql(u8, notification.method, "item/reasoning/summaryTextDelta")) {
                    if (codex.strField(params, "delta")) |delta|
                        if (opts.on_reasoning_delta) |callback| callback(opts.on_delta_ctx, delta);
                } else if (std.mem.eql(u8, notification.method, "item/started")) {
                    if (codex.field(params, "item")) |item| try appendCodexItemStarted(line_arena, ap, opts, item);
                } else if (std.mem.eql(u8, notification.method, "item/completed")) {
                    if (codex.field(params, "item")) |item| {
                        const kind = codex.strField(item, "type") orelse "";
                        if (std.mem.eql(u8, kind, "agentMessage")) {
                            const text = codex.strField(item, "text") orelse "";
                            const phase = codex.strField(item, "phase");
                            if (phase != null and std.mem.eql(u8, phase.?, "commentary")) {
                                if (text.len > 0) _ = try ap.append(.{ .reasoning = .{ .text = text, .commentary = true } });
                            } else if (text.len > 0) {
                                _ = try ap.append(.{ .assistant_msg = .{ .text = text } });
                                final_text.clearRetainingCapacity();
                                try final_text.appendSlice(gpa, text);
                            }
                        } else if (std.mem.eql(u8, kind, "reasoning")) {
                            try appendCodexReasoning(line_arena, ap, item);
                        } else {
                            _ = try appendCodexToolCompleted(gpa, line_arena, ap, opts, item);
                        }
                    }
                } else if (std.mem.eql(u8, notification.method, "thread/tokenUsage/updated")) {
                    if (codex.field(params, "tokenUsage")) |usage|
                        if (codex.field(usage, "last")) |last| {
                            current_tokens_in = @intCast(@max(0, codex.intField(last, "inputTokens") orelse 0));
                            current_tokens_out = @intCast(@max(0, codex.intField(last, "outputTokens") orelse 0));
                        };
                } else if (std.mem.eql(u8, notification.method, "error")) {
                    if (!(codex.boolField(params, "willRetry") orelse false)) {
                        if (codex.field(params, "error")) |err_value| {
                            if (codex.strField(err_value, "message")) |message| {
                                setDelegateError(message);
                                failure_text = lastDelegateErrorNote().?;
                            }
                        }
                    }
                } else if (std.mem.eql(u8, notification.method, "turn/completed")) {
                    tokens_in += current_tokens_in;
                    tokens_out += current_tokens_out;
                    current_tokens_in = 0;
                    current_tokens_out = 0;
                    const turn = codex.field(params, "turn") orelse continue;
                    const status = codex.strField(turn, "status") orelse "failed";
                    interrupted = std.mem.eql(u8, status, "interrupted");
                    failed = std.mem.eql(u8, status, "failed");
                    if (codex.field(turn, "error")) |err_value| {
                        if (err_value != .null) {
                            if (codex.strField(err_value, "message")) |message| {
                                setDelegateError(message);
                                failure_text = lastDelegateErrorNote().?;
                            }
                        }
                    }

                    var follow_up: ?[]u8 = if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
                    if (follow_up == null and !tryCloseSteering(opts))
                        follow_up = if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
                    if (!interrupted and !failed and follow_up != null) {
                        const text = follow_up.?;
                        defer gpa.free(text);
                        _ = try ap.append(.{ .steer = .{ .text = text } });
                        final_text.clearRetainingCapacity();
                        active_turn_id = try codexSendTurnStart(arena, writer, reader, next_request_id, thread_id, opts, text);
                        next_request_id += 1;
                        rounds += 1;
                    } else {
                        if (follow_up) |text| gpa.free(text);
                        done = true;
                    }
                }
            },
        }
        if (!done)
            _ = try sendCodexSteers(gpa, line_arena, writer, opts, ap, thread_id, active_turn_id, &next_request_id);
    }

    // A killed/interrupted rollout can publish usage without reaching its
    // turn/completed notification.
    tokens_in += current_tokens_in;
    tokens_out += current_tokens_out;

    if (watcher.cancelled.load(.acquire) or interrupted or cancelled(opts.cancel)) {
        _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
        try store.updateSessionUsage(opts.session_id, tokens_in, tokens_out);
        return .{
            .text = try gpa.dupe(u8, final_text.items),
            .rounds = rounds,
            .tokens_in = tokens_in,
            .tokens_out = tokens_out,
            .interrupted = true,
        };
    }
    if (watcher.timed_out.load(.acquire)) {
        const note = "codex run exceeded the 60-minute ceiling and was terminated";
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateTimeout;
    }
    if (!done or failed) {
        const note = try std.fmt.allocPrint(gpa, "codex error: {s}", .{failure_text});
        defer gpa.free(note);
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateFailed;
    }

    publishPhase(opts, .finishing);
    try store.updateSessionUsage(opts.session_id, tokens_in, tokens_out);
    return .{
        .text = try gpa.dupe(u8, final_text.items),
        .rounds = rounds,
        .tokens_in = tokens_in,
        .tokens_out = tokens_out,
    };
}

test {
    std.testing.refAllDecls(@This());
}
