//! GUEST turn: Claude Code. Spawns the official `claude -p` binary in
//! stream-json mode, persists its event stream as blocks, bridges its
//! permission prompts onto marlin's approval bar, and bounds it with a
//! wall-clock watcher. The adapter is frozen (docs/ARCHITECTURE.md, Native
//! vs guest); this file is the wall made into a boundary the compiler
//! enforces — loop.zig stays the native agent turn.

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

/// Wall-clock ceiling for one delegated invocation; Claude Code has its own
/// internal turn management, this only prevents an unkillable zombie run.
const claude_code_deadline_ms: i64 = 60 * 60 * 1000;

const CcOutcome = struct {
    got_init: bool = false,
    got_result: bool = false,
    result_is_error: bool = false,
    result_error: [512]u8 = undefined,
    result_error_len: usize = 0,
    cancelled: bool = false,
    timed_out: bool = false,
    exit_code: i64 = -1,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    /// gpa-owned final text (may be empty).
    final_text: std.ArrayList(u8) = .empty,
    stderr_tail: [4096]u8 = undefined,
    stderr_len: usize = 0,
};

/// One `claude -p` invocation: spawn, decode stream-json, persist blocks.
fn ccInvoke(
    gpa: std.mem.Allocator,
    io: Io,
    opts: RunOpts,
    ap: *Appender,
    prompt: []const u8,
    fresh: bool,
) !CcOutcome {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var uuid_buf: [36]u8 = undefined;
    // A read-only guest child is read-only ONLY through the bridge's deny
    // mode (daemon ccReadOnlyAllow). Without a resolvable marlin executable
    // the bridge cannot attach and the fallback would be an unenforced
    // acceptEdits/bypass child — so refuse to start rather than degrade, and
    // never let a yolo parent's approval mode strip the bridge from a child.
    const read_only_child = opts.tool_profile == .read_only;
    if (read_only_child and opts.marlin_exe == null) return error.GuestBridgeUnavailable;
    const bridge: ?claude_code.Bridge = if (opts.marlin_exe != null and (opts.approval_mode != .auto or read_only_child))
        .{ .marlin_exe = opts.marlin_exe.?, .sid = opts.session_id }
    else
        null;
    const argv = try claude_code.buildArgv(arena, .{
        .binary = claude_code.binaryPath(opts.tool_environ),
        .prompt = prompt,
        .model = opts.endpoint.model,
        .session_uuid = claude_code.sessionUuid(&uuid_buf, opts.session_id),
        .fresh = fresh,
        .permissions = if (opts.tool_profile == .plan)
            .plan
        else if (opts.approval_mode == .auto and !read_only_child)
            .bypass
        else
            .accept_edits,
        .bridge = bridge,
        .max_turns = opts.max_rounds,
        .effort = opts.effort,
    });

    // A bridged permission prompt can park on a human for a long time;
    // stretch Claude Code's MCP tool timeout so the call survives the wait
    // instead of decaying into a deny. When Marlin exports OTLP, the same
    // copy also switches on Claude Code's telemetry against the same
    // collector, with TRACEPARENT nesting its spans under Marlin's turn.
    // Existing values always win in both cases.
    var traceparent_buf: [64]u8 = undefined;
    var child_environ: ?std.process.Environ.Map = null;
    defer if (child_environ) |*map| map.deinit();
    if (bridge != null or opts.otel_guest != null) {
        if (opts.tool_environ) |source| {
            var map = std.process.Environ.Map.init(gpa);
            var ok = true;
            var it = source.iterator();
            while (it.next()) |entry| {
                map.put(entry.key_ptr.*, entry.value_ptr.*) catch {
                    ok = false;
                    break;
                };
            }
            if (bridge != null) {
                if (ok and map.get("MCP_TOOL_TIMEOUT") == null)
                    map.put("MCP_TOOL_TIMEOUT", "86400000") catch {
                        ok = false;
                    };
                if (ok and map.get("MCP_TIMEOUT") == null)
                    map.put("MCP_TIMEOUT", "30000") catch {
                        ok = false;
                    };
            }
            if (opts.otel_guest) |guest| {
                const trace_id = telemetry_ids.traceId(opts.session_id, ap.turn_id);
                const root_span = telemetry_ids.spanId(ap.turn_id);
                const traceparent = std.fmt.bufPrint(
                    &traceparent_buf,
                    "00-{s}-{s}-01",
                    .{ trace_id[0..], root_span[0..] },
                ) catch unreachable;
                ok = ok and putEnvDefault(&map, "TRACEPARENT", traceparent);
                ok = ok and putEnvDefault(&map, "CLAUDE_CODE_ENABLE_TELEMETRY", "1");
                ok = ok and putEnvDefault(&map, "CLAUDE_CODE_ENHANCED_TELEMETRY_BETA", "1");
                ok = ok and putEnvDefault(&map, "OTEL_TRACES_EXPORTER", "otlp");
                ok = ok and putEnvDefault(&map, "OTEL_EXPORTER_OTLP_PROTOCOL", "http/protobuf");
                if (guest.base_endpoint.len > 0) {
                    ok = ok and putEnvDefault(&map, "OTEL_EXPORTER_OTLP_ENDPOINT", guest.base_endpoint);
                    ok = ok and putEnvDefault(&map, "OTEL_METRICS_EXPORTER", "otlp");
                    ok = ok and putEnvDefault(&map, "OTEL_LOGS_EXPORTER", "otlp");
                } else if (guest.traces_endpoint.len > 0) {
                    ok = ok and putEnvDefault(&map, "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", guest.traces_endpoint);
                }
                if (guest.headers.len > 0)
                    ok = ok and putEnvDefault(&map, "OTEL_EXPORTER_OTLP_HEADERS", guest.headers);
                if (guest.capture_content) {
                    ok = ok and putEnvDefault(&map, "OTEL_LOG_USER_PROMPTS", "1");
                    ok = ok and putEnvDefault(&map, "OTEL_LOG_ASSISTANT_RESPONSES", "1");
                    ok = ok and putEnvDefault(&map, "OTEL_LOG_TOOL_DETAILS", "1");
                    ok = ok and putEnvDefault(&map, "OTEL_LOG_TOOL_CONTENT", "1");
                }
            }
            if (ok) child_environ = map else map.deinit();
        }
    }

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = if (child_environ) |*map| map else opts.tool_environ,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        const text: []const u8 = if (err == error.FileNotFound)
            "claude binary not found — install Claude Code (or set MARLIN_CLAUDE_CODE_BIN)"
        else
            "failed to spawn claude";
        setDelegateError(text);
        _ = try ap.append(.{ .system_note = .{ .text = text } });
        return error.DelegateSpawnFailed;
    };

    var outcome = CcOutcome{};
    errdefer outcome.final_text.deinit(gpa);

    var watcher = CcWatcher{
        .io = io,
        .cancel = opts.cancel,
        .group = child.id.?,
        .deadline_at = nowMs(io) + claude_code_deadline_ms,
    };
    const watcher_thread = try std.Thread.spawn(.{}, CcWatcher.run, .{&watcher});
    var drain = CcStderrDrain{ .io = io, .file = child.stderr.? };
    const drain_thread = std.Thread.spawn(.{}, CcStderrDrain.run, .{&drain}) catch null;

    // Commentary between tool rounds; flushed when the next tool begins so
    // the final prose is never double-persisted next to the assistant_msg.
    var pending_text: std.ArrayList(u8) = .empty;
    defer pending_text.deinit(gpa);

    {
        const line_buf = try gpa.alloc(u8, 512 * 1024);
        defer gpa.free(line_buf);
        var reader = child.stdout.?.reader(io, line_buf);
        var line_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer line_arena_state.deinit();
        var line_acc: std.ArrayList(u8) = .empty;
        defer line_acc.deinit(gpa);
        while (true) {
            const line = shared.takeEventLine(&reader.interface, gpa, &line_acc, shared.max_event_line_bytes) catch |err| switch (err) {
                error.LineTooLong => {
                    _ = try ap.append(.{ .system_note = .{ .text = "claude code: one event line exceeded 64 MiB and was dropped" } });
                    continue;
                },
                error.ReadFailed => break,
                error.OutOfMemory => return error.OutOfMemory,
            } orelse break;
            _ = line_arena_state.reset(.retain_capacity);
            const line_arena = line_arena_state.allocator();
            var events: std.ArrayList(claude_code.Event) = .empty;
            claude_code.decodeLine(line_arena, line, &events) catch continue;
            for (events.items) |ev| switch (ev) {
                .init => outcome.got_init = true,
                .text => |text| {
                    if (pending_text.items.len > 0) try pending_text.append(gpa, '\n');
                    try pending_text.appendSlice(gpa, text);
                },
                .tool_use => |tu| {
                    if (pending_text.items.len > 0) {
                        _ = try ap.append(.{ .reasoning = .{ .text = pending_text.items, .commentary = true } });
                        pending_text.clearRetainingCapacity();
                    }
                    _ = try ap.append(.{ .tool_call = .{
                        .call_id = tu.id,
                        .name = tu.name,
                        .args_json = tu.input_json,
                    } });
                    if (opts.on_tool) |cb| cb(opts.on_delta_ctx, tu.name, .start);
                },
                .tool_result => |tr| {
                    const cap = opts.cfg.inline_tool_cap_bytes;
                    // Same capture-time redaction as native tool results:
                    // the delegated binary can read a file containing a key
                    // the daemon also holds.
                    const redacted = try permissions.redactSecrets(gpa, opts.secrets, tr.text);
                    defer if (redacted) |r| gpa.free(r);
                    const body = redacted orelse tr.text;
                    _ = try ap.append(.{ .tool_result = .{
                        .call_id = tr.tool_use_id,
                        .status = if (tr.is_error) .err else .ok,
                        .inline_body = body[0..@min(body.len, cap)],
                        .full_body_ref = null,
                    } });
                    if (opts.on_tool) |cb| cb(opts.on_delta_ctx, "claude", .done);
                },
                .result => |r| {
                    outcome.got_result = true;
                    outcome.result_is_error = r.is_error;
                    outcome.result_error_len = @min(r.error_text.len, outcome.result_error.len);
                    @memcpy(outcome.result_error[0..outcome.result_error_len], r.error_text[0..outcome.result_error_len]);
                    outcome.tokens_in = r.tokens_in;
                    outcome.tokens_out = r.tokens_out;
                    outcome.final_text.clearRetainingCapacity();
                    try outcome.final_text.appendSlice(gpa, if (r.text.len > 0) r.text else pending_text.items);
                    pending_text.clearRetainingCapacity();
                },
            };
        }
    }

    watcher.done.store(true, .release);
    watcher_thread.join();
    if (drain_thread) |t| t.join();
    outcome.cancelled = watcher.cancelled.load(.acquire);
    outcome.timed_out = watcher.timed_out.load(.acquire);
    const term: std.process.Child.Term = child.wait(io) catch .{ .exited = 255 };
    outcome.exit_code = switch (term) {
        .exited => |code| code,
        else => -1,
    };
    @memcpy(outcome.stderr_tail[0..drain.len], drain.tail[0..drain.len]);
    outcome.stderr_len = drain.len;
    return outcome;
}

/// A delegated turn: one or more `claude -p` invocations (steers queued
/// mid-run become follow-up invocations against the same Claude Code
/// session), with marlin persisting the structured event stream as blocks.
pub fn runClaudeCodeTurn(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    opts: RunOpts,
    ap: *Appender,
    first_text: []const u8,
    fresh_first: bool,
) !TurnResult {
    shared.clearDelegateError();
    publishPhase(opts, .provider);
    var total_in: u64 = 0;
    var total_out: u64 = 0;
    var rounds: u32 = 0;
    var fresh = fresh_first;

    var prompt: std.ArrayList(u8) = .empty;
    defer prompt.deinit(gpa);
    try prompt.appendSlice(gpa, first_text);
    {
        var history: std.ArrayList(block.Block) = .empty;
        var history_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer history_arena_state.deinit();
        store.loadContextBlocksInto(history_arena_state.allocator(), &history, opts.session_id, 1_000_000) catch {};
        if (context.latestHandover(history.items)) |briefing| {
            const wrapped = try std.fmt.allocPrint(
                gpa,
                "HANDOVER FROM MARLIN (previous agent in this session). Continue from this briefing; you will not see its block log.\n\n{s}\n\n---\n\nUSER\n{s}",
                .{ briefing, first_text },
            );
            prompt.deinit(gpa);
            prompt = .empty;
            errdefer gpa.free(wrapped);
            try prompt.appendSlice(gpa, wrapped);
            gpa.free(wrapped);
        }
    }

    var final_text: std.ArrayList(u8) = .empty;
    defer final_text.deinit(gpa);

    while (true) {
        rounds += 1;
        var outcome = try ccInvoke(gpa, io, opts, ap, prompt.items, fresh);
        // Session-identity mismatch: an invocation that never INITIALIZED
        // didn't run at all — `--resume` of an id Claude Code has never seen
        // exits 0 with an is_error result and no init event (observed live),
        // and `--session-id` of an existing one is the converse. Retry once
        // in the opposite mode before declaring failure.
        if (!outcome.got_init and !outcome.cancelled and !outcome.timed_out) {
            outcome.final_text.deinit(gpa);
            fresh = !fresh;
            outcome = try ccInvoke(gpa, io, opts, ap, prompt.items, fresh);
        }
        defer outcome.final_text.deinit(gpa);

        total_in += outcome.tokens_in;
        total_out += outcome.tokens_out;

        if (outcome.cancelled) {
            _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{ .text = try gpa.dupe(u8, ""), .rounds = rounds, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
        }
        if (outcome.timed_out) {
            const note = "claude code run exceeded the 60-minute ceiling and was terminated";
            setDelegateError(note);
            _ = try ap.append(.{ .system_note = .{ .text = note } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return error.DelegateTimeout;
        }
        if (!outcome.got_result) {
            const note = try std.fmt.allocPrint(
                gpa,
                "claude code exited without a result (exit {d}){s}{s}",
                .{
                    outcome.exit_code,
                    if (outcome.stderr_len > 0) ": " else "",
                    outcome.stderr_tail[0..outcome.stderr_len],
                },
            );
            defer gpa.free(note);
            setDelegateError(note);
            _ = try ap.append(.{ .system_note = .{ .text = note } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return error.DelegateFailed;
        }
        if (outcome.result_is_error) {
            // An error result must never masquerade as an empty answer.
            const detail = if (outcome.result_error_len > 0)
                outcome.result_error[0..outcome.result_error_len]
            else if (outcome.final_text.items.len > 0)
                outcome.final_text.items
            else
                "no detail reported";
            const note = try std.fmt.allocPrint(gpa, "claude code error: {s}", .{detail});
            defer gpa.free(note);
            setDelegateError(note);
            _ = try ap.append(.{ .system_note = .{ .text = note } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return error.DelegateFailed;
        }

        fresh = false;
        _ = try ap.append(.{ .assistant_msg = .{ .text = outcome.final_text.items } });
        final_text.clearRetainingCapacity();
        try final_text.appendSlice(gpa, outcome.final_text.items);

        // Round budget. `--max-turns` bounds the subprocess, not this loop;
        // without a ceiling here a steady stream of steers runs forever. The
        // check sits BEFORE the steer poll so an unconsumed steer stays queued
        // for the next turn instead of vanishing into a round that never runs.
        if (rounds >= opts.max_rounds) break;

        // Steers queued while the subprocess ran become follow-up rounds.
        // `try_close_steer` closes the same last-poll race as the native
        // provider loop; false guarantees another poll can take the winner.
        var steer_text: ?[]u8 = if (opts.poll_steer) |poll|
            poll(opts.on_delta_ctx, gpa)
        else
            null;
        if (steer_text == null and !tryCloseSteering(opts)) {
            steer_text = if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
        }
        if (steer_text) |text| {
            defer gpa.free(text);
            _ = try ap.append(.{ .steer = .{ .text = text } });
            prompt.clearRetainingCapacity();
            try prompt.appendSlice(gpa, text);
            continue;
        }
        break;
    }

    publishPhase(opts, .finishing);
    try store.updateSessionUsage(opts.session_id, total_in, total_out);
    return .{
        .text = try gpa.dupe(u8, final_text.items),
        .rounds = rounds,
        .tokens_in = total_in,
        .tokens_out = total_out,
    };
}
