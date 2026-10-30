//! GUEST turn: Claude Code. Spawns the official `claude -p` binary in
//! stream-json mode, persists its event stream as blocks, bridges its
//! permission prompts onto marlin's approval bar, and bounds it with a
//! wall-clock watcher. The adapter is frozen (docs/ARCHITECTURE.md, Native
//! vs guest); this file is the wall made into a boundary the compiler
//! enforces — loop.zig stays the native agent turn.

const std = @import("std");
const guest_auth = @import("../../core/guest.zig");
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
const guest_activity = @import("activity.zig");
const setDelegateError = shared.setDelegateError;
const lastDelegateErrorNote = shared.lastDelegateErrorNote;
const putEnvDefault = shared.putEnvDefault;
const CcWatcher = shared.CcWatcher;
const CcStderrDrain = shared.CcStderrDrain;

/// How long a finalized Claude Code gets between SIGTERM and SIGKILL. Its
/// SIGTERM handler flushes OTLP for at most CLAUDE_CODE_OTEL_SHUTDOWN_TIMEOUT_MS
/// (2 s by default); the margin covers process exit after it.
const cc_shutdown_grace_ms: u32 = 2500;

pub fn usageCreditsTransitionNote(active: bool) []const u8 {
    return if (active)
        "Claude Code is now using API credits"
    else
        "Claude Code returned to subscription usage";
}

/// Claude Code owns execution of guest tools, so Marlin cannot observe the
/// child process directly. Keep the visible phase on `tool` while any tool
/// call reported by the stream is still awaiting its matching result.
pub fn guestToolPhase(open_tools: usize) proto.TurnPhase {
    return if (open_tools == 0) .provider else .tool;
}

fn activityDetail(arena: std.mem.Allocator, input_json: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, input_json, .{}) catch return "";
    if (parsed != .object) return "";
    inline for (.{ "description", "command", "prompt", "file_path", "pattern", "query" }) |key| {
        if (parsed.object.get(key)) |value| if (value == .string) return value.string;
    }
    return "";
}

const CcOutcome = struct {
    got_init: bool = false,
    got_result: bool = false,
    result_count: u32 = 0,
    input_count: u32 = 1,
    steering_finalized: bool = false,
    input_write_failed: bool = false,
    result_is_error: bool = false,
    result_error: [512]u8 = undefined,
    result_error_len: usize = 0,
    cancelled: bool = false,
    timed_out: bool = false,
    timed_out_runtime_ms: u64 = 0,
    exit_code: i64 = -1,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cached_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    /// gpa-owned final text (may be empty).
    final_text: std.ArrayList(u8) = .empty,
    /// The last successful result's text is already an assistant_msg block.
    /// A run with background tasks emits several results; each reply is
    /// persisted as it lands so a later kill cannot lose it.
    final_persisted: bool = false,
    stderr_tail: [4096]u8 = undefined,
    stderr_len: usize = 0,
};

fn writeCcUserInput(allocator: std.mem.Allocator, writer: *Io.Writer, text: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, .{
        .type = "user",
        .message = .{ .role = "user", .content = .{.{ .type = "text", .text = text }} },
        .parent_tool_use_id = @as(?[]const u8, null),
        .session_id = "",
    }, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
    try writer.writeByte('\n');
    try writer.flush();
}

/// Owns Claude Code's stdin while stdout is decoded on the turn thread.
/// Polling must be independent of stdout: a foreground shell command can
/// produce no events for minutes, which is exactly when steering matters.
const CcInputPump = struct {
    gpa: std.mem.Allocator,
    io: Io,
    opts: *const RunOpts,
    file: Io.File,
    writer: *Io.Writer,
    max_inputs: u32,
    mutex: Io.Mutex = .init,
    done: bool = false,
    finalized: bool = false,
    sent_total: u32 = 1,
    replayed_total: u32 = 0,
    pending_replays: std.ArrayList(block.Input) = .empty,
    write_failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *CcInputPump) void {
        defer self.file.close(self.io);
        while (true) {
            self.mutex.lockUncancelable(self.io);
            if (self.done) {
                self.mutex.unlock(self.io);
                return;
            }
            var next: ?block.Input = null;
            if (self.sent_total < self.max_inputs) {
                if (self.opts.poll_steer) |poll| next = poll(self.opts.on_delta_ctx, self.gpa);
            }
            if (next) |input| {
                self.pending_replays.append(self.gpa, input) catch {
                    input.deinit(self.gpa);
                    self.mutex.unlock(self.io);
                    self.write_failed.store(true, .release);
                    return;
                };
                self.sent_total += 1;
                self.mutex.unlock(self.io);
                writeCcUserInput(self.gpa, self.writer, input.text) catch {
                    self.write_failed.store(true, .release);
                    return;
                };
                continue;
            }
            self.mutex.unlock(self.io);
            self.io.sleep(.fromMilliseconds(25), .awake) catch return;
        }
    }

    /// Called for each result. Close stdin only after Claude has replayed
    /// (accepted) every message already handed to it and no background task is
    /// still keeping that result provisional. Claude may fold a steer into the
    /// current turn or emit a separate result for it, so result counts are not
    /// message counts. Holding this mutex across the daemon's atomic queue
    /// close prevents a poll/close race.
    fn result(self: *CcInputPump, background_open: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (background_open > 0 or self.replayed_total < self.sent_total) return;
        if (self.sent_total >= self.max_inputs or tryCloseSteering(self.opts.*)) {
            self.finalized = true;
            self.done = true;
        }
    }

    fn replayed(self: *CcInputPump) void {
        self.mutex.lockUncancelable(self.io);
        self.replayed_total += 1;
        self.mutex.unlock(self.io);
    }

    fn takeReplay(self: *CcInputPump) ?block.Input {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.pending_replays.items.len == 0) return null;
        return self.pending_replays.orderedRemove(0);
    }

    fn stop(self: *CcInputPump) void {
        self.mutex.lockUncancelable(self.io);
        self.done = true;
        self.mutex.unlock(self.io);
    }

    fn inputCount(self: *CcInputPump) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.sent_total;
    }

    fn isFinalized(self: *CcInputPump) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.finalized;
    }

    fn deinit(self: *CcInputPump) void {
        for (self.pending_replays.items) |input| input.deinit(self.gpa);
        self.pending_replays.deinit(self.gpa);
    }
};

pub fn backgroundActivityKind(task_type: []const u8) proto.GuestActivityKind {
    return if (std.mem.eql(u8, task_type, "local_agent")) .agent else .process;
}

pub fn toolActivityKind(name: []const u8) proto.GuestActivityKind {
    if (std.mem.eql(u8, name, "Agent")) return .agent;
    if (std.mem.eql(u8, name, "Bash") or std.mem.eql(u8, name, "Shell")) return .process;
    return .tool;
}

/// The reply landed but the run stays alive for its background tasks: say so
/// in the transcript and the phase, or "running" looks like a hang.
fn noteBackgroundWait(gpa: std.mem.Allocator, opts: RunOpts, ap: *Appender, open: usize, description: []const u8) !void {
    const note = if (description.len > 0 and open == 1)
        try std.fmt.allocPrint(gpa, "waiting on background task: {s}", .{description})
    else if (description.len > 0)
        try std.fmt.allocPrint(gpa, "waiting on {d} background tasks: {s}, …", .{ open, description })
    else
        try std.fmt.allocPrint(gpa, "waiting on {d} background task{s}", .{ open, if (open == 1) "" else "s" });
    defer gpa.free(note);
    _ = try ap.append(.{ .system_note = .{ .text = note } });
    publishPhase(opts, .background);
}

pub fn compactDiagnostic(allocator: std.mem.Allocator, text: []const u8, max: usize) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const clipped = trimmed[0..@min(trimmed.len, max)];
    const compact = try allocator.dupe(u8, clipped);
    for (compact) |*ch| ch.* = switch (ch.*) {
        '\r', '\n', '\t' => ' ',
        else => ch.*,
    };
    return compact;
}

fn isGenericConnectionError(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.eql(u8, trimmed, "ConnectFailed") or
        std.mem.eql(u8, trimmed, "SocketUnconnected") or
        std.mem.eql(u8, trimmed, "ReadFailed");
}

pub fn claudeErrorNote(
    allocator: std.mem.Allocator,
    detail: []const u8,
    stderr: []const u8,
) ![]u8 {
    if (guest_auth.isAuthFailure(detail) or guest_auth.isAuthFailure(stderr))
        return allocator.dupe(u8, guest_auth.loginRequiredNote(.claude_code));
    const trimmed_detail = std.mem.trim(u8, detail, " \t\r\n");
    const compact_stderr = try compactDiagnostic(allocator, stderr, 512);
    defer allocator.free(compact_stderr);
    if (isGenericConnectionError(trimmed_detail)) {
        if (compact_stderr.len > 0) {
            return std.fmt.allocPrint(
                allocator,
                "claude code connection failed: {s} (stderr: {s})",
                .{ trimmed_detail, compact_stderr },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "claude code connection failed: {s} (no transport detail reported by Claude Code)",
            .{trimmed_detail},
        );
    }
    return std.fmt.allocPrint(allocator, "claude code error: {s}", .{trimmed_detail});
}

/// One `claude -p` invocation: spawn, decode stream-json, persist blocks.
fn ccInvoke(
    gpa: std.mem.Allocator,
    io: Io,
    opts: RunOpts,
    ap: *Appender,
    usage_credits: *bool,
    prompt: []const u8,
    fresh: bool,
    round: u32,
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
    // The bridge attaches whenever marlin is resolvable — even in bypass
    // mode, where it routes no permission prompts, it still carries the
    // ask_user picker tool. Permission ROUTING stays mode-dependent in
    // buildArgv.
    const bridge: ?claude_code.Bridge = if (opts.marlin_exe != null)
        .{ .marlin_exe = opts.marlin_exe.?, .sid = opts.session_id }
    else
        null;
    const argv = try claude_code.buildArgv(arena, .{
        .binary = claude_code.binaryPath(opts.tool_environ),
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
        // A root's max_rounds is Marlin's native-loop checkpoint size, not a
        // reason to kill one long Claude Code invocation. Root guests are
        // already bounded by the supervised four-hour ceiling; child guests
        // preserve their explicit parent-facing tool budget.
        .max_turns = if (opts.auto_continue_round_budget) null else opts.max_rounds,
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
        .stdin = .pipe,
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

    var watcher = CcWatcher.init(io, opts.cancel, child.id.?, opts.park_clock, opts.cfg.guest_max_runtime_ms);
    watcher.max_runtime_live = opts.guest_max_runtime_live;
    const watcher_thread = try std.Thread.spawn(.{}, CcWatcher.run, .{&watcher});
    var drain = CcStderrDrain{ .io = io, .file = child.stderr.? };
    const drain_thread = std.Thread.spawn(.{}, CcStderrDrain.run, .{&drain}) catch null;
    // Both threads point into this frame. Any error return from here on must
    // stop them and reap the child before the frame unwinds; the success path
    // tears down the same way and clears this guard first.
    var threads_live = true;
    errdefer if (threads_live) {
        watcher.done.store(true, .release);
        watcher_thread.join();
        process_io.terminateProcessGroup(io, child.id.?, 0);
        if (drain_thread) |t| t.join();
        _ = child.wait(io) catch {};
    };

    // Stream-json input keeps this exact Claude process alive while a steer
    // arrives. The first message is synchronous; a pump owns the pipe after
    // that so a silent long-running tool cannot starve steering.
    var stdin_file = child.stdin.?;
    child.stdin = null;
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_writer_file = stdin_file.writer(io, &stdin_buffer);
    // A claude that exits before reading its prompt (an immediate error
    // result, e.g. an unknown --resume id) has already said why on stdout;
    // the broken pipe is not the outcome. Read that stdout as usual.
    const prompt_written = if (writeCcUserInput(gpa, &stdin_writer_file.interface, prompt)) |_|
        true
    else |err| switch (err) {
        error.OutOfMemory => {
            stdin_file.close(io);
            return error.OutOfMemory;
        },
        else => false,
    };
    var input_pump = CcInputPump{
        // An unwritable stdin gets no steering: the pump closes it and exits.
        .done = !prompt_written,
        .gpa = gpa,
        .io = io,
        .opts = &opts,
        .file = stdin_file,
        .writer = &stdin_writer_file.interface,
        .max_inputs = if (opts.max_rounds >= round) opts.max_rounds - round + 1 else 1,
    };
    defer input_pump.deinit();
    const input_thread = try std.Thread.spawn(.{}, CcInputPump.run, .{&input_pump});
    var input_joined = false;
    defer if (!input_joined) {
        input_pump.stop();
        input_thread.join();
    };

    // Commentary between tool rounds; flushed when the next tool begins so
    // the final prose is never double-persisted next to the assistant_msg.
    var pending_text: std.ArrayList(u8) = .empty;
    defer pending_text.deinit(gpa);
    // Open run_in_background tasks, per Claude Code's own task list.
    var background_open: usize = 0;
    // Between a reply (`result`) and the next sub-turn: the model is idle.
    var replied = false;
    var background_description: std.ArrayList(u8) = .empty;
    defer background_description.deinit(gpa);

    // Telemetry: one round row per invocation, one tool row per completed
    // tool call — the same tables the native loop fills, so guest turns get
    // real chat/execute_tool child spans instead of an empty aggregate.
    const invoke_started_ms = nowMs(io);
    var first_event_at_ms: i64 = 0;
    const PendingTool = struct { call_id: []u8, name: []u8, started_at_ms: i64 };
    var pending_tools: std.ArrayList(PendingTool) = .empty;
    defer {
        for (pending_tools.items) |tool| {
            gpa.free(tool.call_id);
            gpa.free(tool.name);
        }
        pending_tools.deinit(gpa);
    }
    var open_tools: usize = 0;
    var activity = guest_activity.Tracker.init(gpa, opts.on_guest_activity, opts.on_delta_ctx);
    defer activity.deinit();
    const BackgroundLink = struct { task_id: []u8, tool_use_id: []u8 };
    var background_links: std.ArrayList(BackgroundLink) = .empty;
    defer {
        for (background_links.items) |link| {
            gpa.free(link.task_id);
            gpa.free(link.tool_use_id);
        }
        background_links.deinit(gpa);
    }
    var replayed_users: usize = 0;

    {
        const line_buf = try gpa.alloc(u8, 512 * 1024);
        defer gpa.free(line_buf);
        var reader = child.stdout.?.reader(io, line_buf);
        var line_arena_state = std.heap.ArenaAllocator.init(gpa);
        defer line_arena_state.deinit();
        var line_acc: std.ArrayList(u8) = .empty;
        defer line_acc.deinit(gpa);
        read_events: while (true) {
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
            // Claude can emit an authentication failure as an assistant
            // envelope before (or without) a terminal result. Stop promptly.
            if (std.json.parseFromSliceLeaky(std.json.Value, line_arena, line, .{})) |value| {
                if (value == .object) if (value.object.get("error")) |failure| {
                    if (failure == .string and guest_auth.isAuthFailure(failure.string)) {
                        const note = guest_auth.loginRequiredNote(.claude_code);
                        setDelegateError(note);
                        _ = try ap.append(.{ .system_note = .{ .text = note } });
                        return error.DelegateFailed;
                    }
                };
            } else |_| {}
            var events: std.ArrayList(claude_code.Event) = .empty;
            claude_code.decodeLine(line_arena, line, &events) catch continue;
            if (first_event_at_ms == 0 and events.items.len > 0) first_event_at_ms = nowMs(io);
            for (events.items) |ev| switch (ev) {
                .init => outcome.got_init = true,
                .text_delta => |text| {
                    if (opts.on_delta) |cb| cb(opts.on_delta_ctx, text);
                },
                .reasoning_delta => |text| {
                    if (opts.on_reasoning_delta) |cb| cb(opts.on_delta_ctx, text);
                },
                .text => |text| {
                    if (pending_text.items.len > 0) try pending_text.append(gpa, '\n');
                    try pending_text.appendSlice(gpa, text);
                },
                .child_output => |nested_output| {
                    try activity.appendOutput(nested_output.parent_tool_use_id, nested_output.text);
                },
                .reasoning => |text| {
                    _ = try ap.append(.{ .reasoning = .{ .text = text } });
                },
                .tool_use => |tu| {
                    try activity.start(
                        tu.id,
                        tu.parent_tool_use_id,
                        toolActivityKind(tu.name),
                        tu.name,
                        activityDetail(line_arena, tu.input_json),
                        nowMs(io),
                    );
                    // Forwarded subagent tools exist to drive the live tree;
                    // persisting them would flatten child internals into the
                    // parent's transcript and duplicate the Agent result.
                    if (tu.parent_tool_use_id.len > 0) continue;
                    if (pending_text.items.len > 0) {
                        _ = try ap.append(.{ .reasoning = .{ .text = pending_text.items, .commentary = true } });
                        pending_text.clearRetainingCapacity();
                    }
                    _ = try ap.append(.{ .tool_call = .{
                        .call_id = tu.id,
                        .name = tu.name,
                        .args_json = tu.input_json,
                    } });
                    if (ap.turn_id != 0) track: {
                        // Event payloads are line-arena-owned; copy what the
                        // telemetry row will need at tool_result time.
                        const call_id = gpa.dupe(u8, tu.id) catch break :track;
                        const name = gpa.dupe(u8, tu.name) catch {
                            gpa.free(call_id);
                            break :track;
                        };
                        pending_tools.append(gpa, .{ .call_id = call_id, .name = name, .started_at_ms = nowMs(io) }) catch {
                            gpa.free(call_id);
                            gpa.free(name);
                        };
                    }
                    open_tools += 1;
                    if (open_tools == 1) publishPhase(opts, guestToolPhase(open_tools));
                    if (opts.on_tool) |cb| cb(opts.on_delta_ctx, tu.name, .start);
                },
                .tool_result => |tr| {
                    const nested = tr.parent_tool_use_id.len > 0 or activity.isNested(tr.tool_use_id);
                    try activity.appendOutput(tr.tool_use_id, tr.text);
                    var stays_open = false;
                    for (background_links.items) |link| if (std.mem.eql(u8, link.tool_use_id, tr.tool_use_id)) {
                        stays_open = true;
                        break;
                    };
                    if (!stays_open) activity.finish(tr.tool_use_id);
                    if (nested) continue;
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
                    if (ap.turn_id != 0) for (pending_tools.items, 0..) |tool, i| {
                        if (!std.mem.eql(u8, tool.call_id, tr.tool_use_id)) continue;
                        const span = telemetry_ids.spanId(ids.next(io));
                        ap.store.telemetryRecordTool(opts.session_id, ap.turn_id, .{
                            .round = round,
                            .call_id = tool.call_id,
                            .span_id = &span,
                            .name = tool.name,
                            .description = "",
                            .started_at_ms = tool.started_at_ms,
                            .ended_at_ms = nowMs(io),
                            .status = if (tr.is_error) "err" else "ok",
                        }) catch |err| std.log.warn("could not persist guest tool telemetry: {t}", .{err});
                        const removed = pending_tools.swapRemove(i);
                        gpa.free(removed.call_id);
                        gpa.free(removed.name);
                        break;
                    };
                    if (open_tools > 0) open_tools -= 1;
                    if (open_tools == 0) publishPhase(opts, guestToolPhase(open_tools));
                    if (opts.on_tool) |cb| cb(opts.on_delta_ctx, "claude", .done);
                },
                .usage_credits => |active| {
                    if (usage_credits.* == active) continue;
                    _ = try ap.append(.{ .system_note = .{ .text = usageCreditsTransitionNote(active) } });
                    usage_credits.* = active;
                    if (opts.usage_credits_live) |live| live.store(active, .release);
                    if (opts.on_usage_credits) |cb| cb(opts.on_delta_ctx, active);
                },
                .result => |r| {
                    outcome.got_result = true;
                    outcome.result_count += 1;
                    outcome.result_is_error = r.is_error;
                    outcome.result_error_len = @min(r.error_text.len, outcome.result_error.len);
                    @memcpy(outcome.result_error[0..outcome.result_error_len], r.error_text[0..outcome.result_error_len]);
                    // Usage is per sub-turn; a run that resumes after its
                    // background tasks reports one result per sub-turn.
                    outcome.tokens_in += r.tokens_in;
                    outcome.tokens_out += r.tokens_out;
                    outcome.cached_tokens += r.cached_tokens;
                    outcome.cache_write_tokens += r.cache_write_tokens;
                    outcome.final_text.clearRetainingCapacity();
                    try outcome.final_text.appendSlice(gpa, if (r.text.len > 0) r.text else pending_text.items);
                    pending_text.clearRetainingCapacity();
                    outcome.final_persisted = false;
                    if (!r.is_error) {
                        _ = try ap.append(.{ .assistant_msg = .{ .text = outcome.final_text.items } });
                        outcome.final_persisted = true;
                    }
                    replied = true;
                    if (background_open > 0) try noteBackgroundWait(gpa, opts, ap, background_open, background_description.items);
                    input_pump.result(background_open);
                },
                .background_tasks => |bg| {
                    const was_open = background_open;
                    background_open = bg.len;
                    background_description.clearRetainingCapacity();
                    if (bg.len > 0) try background_description.appendSlice(gpa, bg[0].description);
                    activity.clearKind(.process);
                    for (bg) |task| try activity.start(
                        task.task_id,
                        "",
                        backgroundActivityKind(task.task_type),
                        if (std.mem.eql(u8, task.task_type, "local_bash")) "Bash" else task.task_type,
                        task.description,
                        nowMs(io),
                    );
                    // Launched after the reply landed (rare): park visibly too.
                    if (was_open == 0 and bg.len > 0 and replied)
                        try noteBackgroundWait(gpa, opts, ap, background_open, background_description.items);
                },
                .task_started => |task| {
                    if (!task.is_backgrounded or task.tool_use_id.len == 0) continue;
                    // background_tasks_changed arrives first and uses task_id;
                    // replace that provisional node with the tool-use id that
                    // forwarded child events name as their parent.
                    activity.finish(task.task_id);
                    var parent_tool_use_id: []const u8 = "";
                    for (background_links.items) |link| {
                        if (!std.mem.eql(u8, link.task_id, task.parent_task_id)) continue;
                        parent_tool_use_id = link.tool_use_id;
                        break;
                    }
                    try activity.start(
                        task.tool_use_id,
                        parent_tool_use_id,
                        backgroundActivityKind(task.task_type),
                        if (std.mem.eql(u8, task.task_type, "local_bash")) "Bash" else "Agent",
                        task.description,
                        nowMs(io),
                    );
                    var known = false;
                    for (background_links.items) |link| if (std.mem.eql(u8, link.tool_use_id, task.tool_use_id)) {
                        known = true;
                        break;
                    };
                    if (!known) {
                        const owned_task = try gpa.dupe(u8, task.task_id);
                        const owned_tool = gpa.dupe(u8, task.tool_use_id) catch |err| {
                            gpa.free(owned_task);
                            return err;
                        };
                        background_links.append(gpa, .{ .task_id = owned_task, .tool_use_id = owned_tool }) catch |err| {
                            gpa.free(owned_task);
                            gpa.free(owned_tool);
                            return err;
                        };
                    }
                },
                .task_notification => |notification| {
                    replied = false;
                    const activity_id = if (notification.tool_use_id.len > 0) notification.tool_use_id else notification.task_id;
                    activity.finish(activity_id);
                    for (background_links.items, 0..) |link, i| {
                        if (!std.mem.eql(u8, link.tool_use_id, activity_id)) continue;
                        const removed = background_links.swapRemove(i);
                        gpa.free(removed.task_id);
                        gpa.free(removed.tool_use_id);
                        break;
                    }
                    _ = try ap.append(.{ .system_note = .{ .text = notification.summary } });
                    // The run resumes on its own: the model now reads the result.
                    publishPhase(opts, .provider);
                },
                .replayed_user => |text| {
                    input_pump.replayed();
                    replayed_users += 1;
                    if (replayed_users == 1) continue; // initial prompt
                    if (input_pump.takeReplay()) |input| {
                        defer input.deinit(gpa);
                        _ = try ap.append(.{ .steer = input });
                    } else {
                        _ = try ap.append(.{ .steer = .{ .text = text } });
                    }
                },
            };
            // Claude's SDK stream can remain resident waiting for more input
            // even after stdin is closed after a multi-message run. Once the
            // terminal result atomically closed steering, no later stdout is
            // part of this Marlin turn.
            if (input_pump.isFinalized()) break :read_events;
        }
    }

    input_pump.stop();
    input_thread.join();
    input_joined = true;
    outcome.input_count = input_pump.inputCount();
    outcome.steering_finalized = input_pump.isFinalized();
    outcome.input_write_failed = input_pump.write_failed.load(.acquire);

    // The watcher signals the group by id, so it stops before anything here
    // can reap the child and free that id for reuse.
    threads_live = false;
    watcher.done.store(true, .release);
    watcher_thread.join();
    // A finalized Claude can stay resident on a closed stdin, so it is
    // signalled, but given time to exit: its SIGTERM handler ships the turn's
    // last OTLP logs (the final api_request and the assistant_response), and
    // a kill 50 ms later used to throw exactly those away.
    const reaped = outcome.steering_finalized and
        process_io.terminateProcessGroupAndReap(&child, io, cc_shutdown_grace_ms);
    if (drain_thread) |t| t.join();
    outcome.cancelled = watcher.cancelled.load(.acquire);
    outcome.timed_out = watcher.timed_out.load(.acquire);
    outcome.timed_out_runtime_ms = watcher.timed_out_runtime_ms;
    if (reaped) {
        // A finalized run has its result, so its exit code is never read.
        process_io.releaseReapedChild(&child, io);
    } else {
        const term: std.process.Child.Term = child.wait(io) catch .{ .exited = 255 };
        outcome.exit_code = switch (term) {
            .exited => |code| code,
            else => -1,
        };
    }
    @memcpy(outcome.stderr_tail[0..drain.len], drain.tail[0..drain.len]);
    outcome.stderr_len = drain.len;

    // One model-call row per completed invocation. Claude Code's result
    // usage is the billed sum for this run (fresh + cache read + cache
    // write, split out), which is exactly what a chat span should carry.
    if (ap.turn_id != 0 and outcome.got_result) {
        const span = telemetry_ids.spanId(ids.next(io));
        ap.store.telemetryRecordRound(opts.session_id, ap.turn_id, .{
            .round = round,
            .span_id = &span,
            .started_at_ms = invoke_started_ms,
            .first_byte_at_ms = first_event_at_ms,
            .first_visible_at_ms = first_event_at_ms,
            .ended_at_ms = nowMs(io),
            .status = if (outcome.result_is_error) "err" else "ok",
            .http_status = 0,
            .response_bytes = 0,
            .provider = "claudecode",
            .provider_name = "anthropic",
            .request_model = opts.endpoint.model,
            .response_model = "",
            .server_address = "",
            .server_port = 0,
            .finish_reason = "",
            .reasoning_level = "",
            .max_tokens = 0,
            .generation_id = "",
            .usage_available = true,
            .tokens_in = outcome.tokens_in,
            .tokens_out = outcome.tokens_out,
            .cached_tokens = outcome.cached_tokens,
            .cache_write_tokens = outcome.cache_write_tokens,
            .reasoning_tokens = 0,
        }) catch |err| std.log.warn("could not persist guest round telemetry: {t}", .{err});
    }
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
        prompt.clearRetainingCapacity();
        try prompt.appendSlice(gpa, try context.guestPrompt(history_arena_state.allocator(), history.items, first_text));
    }

    var final_text: std.ArrayList(u8) = .empty;
    defer final_text.deinit(gpa);
    var usage_credits = if (opts.usage_credits_live) |live| live.load(.acquire) else false;

    while (true) {
        rounds += 1;
        var outcome = try ccInvoke(gpa, io, opts, ap, &usage_credits, prompt.items, fresh, rounds);
        if (!outcome.cancelled and (guest_auth.isAuthFailure(outcome.result_error[0..outcome.result_error_len]) or
            (outcome.result_is_error and guest_auth.isAuthFailure(outcome.final_text.items)) or
            guest_auth.isAuthFailure(outcome.stderr_tail[0..outcome.stderr_len])))
        {
            outcome.final_text.deinit(gpa);
            const note = guest_auth.loginRequiredNote(.claude_code);
            setDelegateError(note);
            _ = try ap.append(.{ .system_note = .{ .text = note } });
            return error.DelegateFailed;
        }
        // Session-identity mismatch: an invocation that never INITIALIZED
        // didn't run at all — `--resume` of an id Claude Code has never seen
        // exits 0 with an is_error result and no init event (observed live),
        // and `--session-id` of an existing one is the converse. Retry once
        // in the opposite mode before declaring failure.
        if (!outcome.got_init and !outcome.cancelled and !outcome.timed_out) {
            outcome.final_text.deinit(gpa);
            fresh = !fresh;
            outcome = try ccInvoke(gpa, io, opts, ap, &usage_credits, prompt.items, fresh, rounds);
        }
        defer outcome.final_text.deinit(gpa);

        // One long-lived stream-json process can now consume several user
        // messages; preserve the old round accounting/budget semantics.
        if (outcome.input_count > 1) rounds += outcome.input_count - 1;

        total_in += outcome.tokens_in;
        total_out += outcome.tokens_out;

        if (outcome.cancelled) {
            _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{ .text = try gpa.dupe(u8, ""), .rounds = rounds, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
        }
        if (outcome.timed_out) {
            const note = try shared.deadlineNote(gpa, "claude code", outcome.timed_out_runtime_ms);
            defer gpa.free(note);
            setDelegateError(note);
            _ = try ap.append(.{ .system_note = .{ .text = note } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return error.DelegateTimeout;
        }
        if (outcome.input_write_failed) {
            const note = "claude code closed its input before a steering message could be delivered";
            setDelegateError(note);
            _ = try ap.append(.{ .system_note = .{ .text = note } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return error.DelegateFailed;
        }
        if (!outcome.got_result) {
            const stderr = try compactDiagnostic(
                gpa,
                outcome.stderr_tail[0..outcome.stderr_len],
                512,
            );
            defer gpa.free(stderr);
            const note = try std.fmt.allocPrint(
                gpa,
                "claude code exited without a result (exit {d}){s}{s}",
                .{
                    outcome.exit_code,
                    if (stderr.len > 0) ": " else "",
                    stderr,
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
            const note = try claudeErrorNote(
                gpa,
                detail,
                outcome.stderr_tail[0..outcome.stderr_len],
            );
            defer gpa.free(note);
            setDelegateError(note);
            _ = try ap.append(.{ .system_note = .{ .text = note } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return error.DelegateFailed;
        }

        fresh = false;
        if (!outcome.final_persisted) _ = try ap.append(.{ .assistant_msg = .{ .text = outcome.final_text.items } });
        final_text.clearRetainingCapacity();
        try final_text.appendSlice(gpa, outcome.final_text.items);

        // The live stdin pump already performed the atomic final queue close;
        // do not repeat it in the legacy multi-invocation fallback below.
        if (outcome.steering_finalized) break;

        // Round budget. `--max-turns` bounds the subprocess, not this loop;
        // without a ceiling here a steady stream of steers runs forever. The
        // check sits BEFORE the steer poll so an unconsumed steer stays queued
        // for the next turn instead of vanishing into a round that never runs.
        if (rounds >= opts.max_rounds) break;

        // Steers queued while the subprocess ran become follow-up rounds.
        // `try_close_steer` closes the same last-poll race as the native
        // provider loop; false guarantees another poll can take the winner.
        var steer_text: ?block.Input = if (opts.poll_steer) |poll|
            poll(opts.on_delta_ctx, gpa)
        else
            null;
        if (steer_text == null and !tryCloseSteering(opts)) {
            steer_text = if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
        }
        if (steer_text) |text| {
            defer text.deinit(gpa);
            _ = try ap.append(.{ .steer = text });
            prompt.clearRetainingCapacity();
            try prompt.appendSlice(gpa, text.text);
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
