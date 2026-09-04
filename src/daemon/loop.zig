//! The agent turn loop (docs/ARCHITECTURE.md §4): context assembly, provider
//! streaming, approval-gated tools, steering, compaction, and cancellation.

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

const empty_final_recovery_prompt =
    "Your previous response contained no user-visible answer or tool call. Continue the task now: use tools if work remains, otherwise provide the final answer.";

pub const Endpoint = struct {
    url: [:0]const u8, // .../chat/completions
    bearer: ?[]const u8,
    model: []const u8, // provider-native model string
    provider_name: []const u8 = "unknown",
    backend: provider.Backend,
};

fn nativeDialect(ep: Endpoint) provider.Dialect {
    return switch (ep.backend) {
        .native => |dialect| dialect,
        .guest => unreachable,
    };
}

fn guestBackend(ep: Endpoint) ?provider.Guest {
    return switch (ep.backend) {
        .native => null,
        .guest => |guest| guest,
    };
}

pub const ToolPhase = enum { start, done };
pub const ToolProfile = enum { full, read_only, plan };

/// What a guest agent needs to ship its telemetry to Marlin's collector.
/// Strings are turn-job-owned snapshots of the exporter configuration.
pub const OtelGuest = struct {
    base_endpoint: []const u8 = "",
    traces_endpoint: []const u8 = "",
    /// Standard comma-separated, percent-encoded `name=value` form.
    headers: []const u8 = "",
    /// Mirrors Marlin's opt-in content capture: when the operator has opted
    /// into shipping conversation content, guest prompt/tool content flags
    /// are enabled too; otherwise guests keep their redacted defaults.
    capture_content: bool = false,
};

pub const RunOpts = struct {
    session_id: u64,
    /// Durable turn id allocated by the dispatcher. Zero keeps standalone
    /// tests/backward callers on the loop's local id generator.
    turn_id: u64 = 0,
    cwd: []const u8,
    endpoint: Endpoint,
    /// Daemon-owned HTTP connection pool shared across provider rounds.
    http_pool: ?*http.Pool = null,
    /// Add OpenRouter's trace linkage only when the matching Marlin OTLP root
    /// will be exported. Avoid orphan parent ids in Broadcast-only setups.
    otel_correlation: bool = false,
    /// Collector snapshot handed to guest agents so their own telemetry
    /// (claude, codex) lands in the same backend, nested under Marlin's turn
    /// trace via TRACEPARENT. Null when Marlin itself is not exporting.
    otel_guest: ?OtelGuest = null,
    effort: Effort = .auto,
    cfg: config.Config,
    /// Daemon-owned environment. Tool subprocesses receive a scrubbed copy;
    /// provider credentials never cross the daemon boundary.
    tool_environ: ?*const std.process.Environ.Map = null,
    /// Absolute path to the marlin binary, for subprocesses that must call
    /// back into the daemon (the Claude Code permission bridge). Null skips
    /// bridge wiring (tests; exe path unresolvable).
    marlin_exe: ?[]const u8 = null,
    /// Secret values the daemon actually holds, redacted from tool output at
    /// capture time (ARCHITECTURE §7) — before hashing, capping, or blobbing,
    /// because the append-only store makes anything persisted immortal.
    secrets: []const permissions.Secret = &.{},
    /// Kernel sandbox selected only after its runtime canary passes.
    sandbox_options: sandbox.Options = .{},
    /// Allow-by-default hostname policy for structured network tools.
    network_policy: ?*const network_policy.Policy = null,
    /// Daemon-owned M5 extension registry (exec, MCP, skills, hooks).
    extensions: ?*extensions.Runtime = null,
    /// Compaction endpoint (usually same as endpoint but cheap model);
    /// null → use `endpoint` for summarization too.
    compaction_endpoint: ?Endpoint = null,
    /// L1 prune frontier (session state, survives turns): tool_result blocks
    /// with seq < this are stubbed at assembly. Loop advances it when the
    /// soft threshold trips; caller persists it per session.
    prune_frontier: ?*u64 = null,
    /// Written with the estimated assembled context tokens each round
    /// (status-bar accounting; provider-reported usage resyncs it per turn).
    context_used_out: ?*std.atomic.Value(u64) = null,
    /// Dispatcher/daemon preparation before entering runTurn.
    initial_setup_ms: u64 = 0,
    /// Session approval mode (default: mutating tools ask). Snapshot used
    /// when no live pointer is wired (tests, compaction).
    approval_mode: approval.Mode = .auto,
    /// Live session approval mode (@intFromEnum-encoded), read per call so
    /// /permissions applies to the RUNNING turn, not just future ones.
    approval_mode_live: ?*const std.atomic.Value(u8) = null,
    /// Gate the turn parks on while a client decides. Required when
    /// approval_mode may produce `ask` decisions.
    gate: ?*approval.Gate = null,
    /// Called after the gate is armed but before parking. Returns false when
    /// the request could not be published; the call is then denied rather than
    /// leaving an unreachable waiter. `id` is the approval id.
    on_approval_needed: ?*const fn (ctx: ?*anyopaque, id: u64, call_id: []const u8, tool: []const u8, args_json: []const u8) bool = null,
    /// Called after the gate resolves (status back to running).
    on_approval_done: ?*const fn (ctx: ?*anyopaque, id: u64, verdict: approval.Verdict) void = null,
    /// Called with streaming assistant text for UI liveness.
    on_delta: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// Separate provider reasoning stream; clients render it as a progress
    /// card instead of mixing it into final assistant prose.
    on_reasoning_delta: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// Stream liveness: cumulative response bytes this round + ms since the
    /// last visible delta. Throttled to ~1/s; drives the client status line.
    on_stream_status: ?*const fn (ctx: ?*anyopaque, bytes: u64, quiet_ms: u64) void = null,
    /// Coarse phase transitions for cancellation diagnostics. The callback
    /// must be non-blocking; the daemon publishes it through atomics.
    on_phase: ?*const fn (ctx: ?*anyopaque, phase: proto.TurnPhase) void = null,
    on_delta_ctx: ?*anyopaque = null,
    /// Called when a tool starts/finishes (for progress display).
    on_tool: ?*const fn (ctx: ?*anyopaque, name: []const u8, phase: ToolPhase) void = null,
    /// Daemon-owned durable-child primitive. It receives the already-persisted
    /// parent tool_call block id and parks this turn until the child completes.
    on_task: ?*const fn (ctx: ?*anyopaque, parent_block_id: u64, args_json: []const u8) tools_registry.ExecOut = null,
    /// Read-only children omit mutating tools and recursive task. Plan mode is
    /// stricter: no bash, no mutations, no plan_update, but read-only tasks
    /// remain available for investigation.
    tool_profile: ToolProfile = .full,
    /// Internal continuation prompts remain model-visible without appearing as
    /// authored user input or entering composer history.
    synthetic_input: bool = false,
    /// Root sessions checkpoint a very long agent loop at max_rounds and let
    /// the daemon immediately resume it as a fresh internal turn. Children
    /// keep max_rounds as a hard parent-facing completion boundary.
    auto_continue_round_budget: bool = false,
    /// Called after EVERY block is persisted (daemon fan-out). The block's
    /// memory is only valid during the callback.
    on_block: ?*const fn (ctx: ?*anyopaque, b: block.Block) void = null,
    /// Cooperative cancellation: checked between rounds and threaded into
    /// the HTTP layer. When set mid-stream the turn ends with .interrupted.
    cancel: ?*std.atomic.Value(bool) = null,
    /// Steer poll: return queued mid-turn user text (caller allocs w/ gpa;
    /// loop frees). Checked between rounds and after a tool-free response;
    /// accepted text is injected as a steer block before the turn may finish.
    poll_steer: ?*const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 = null,
    /// Atomically close this turn to new steering only when its queue is
    /// empty. False means a steer raced the final poll and the loop must
    /// continue. Null is appropriate for single-threaded tests.
    try_close_steer: ?*const fn (ctx: ?*anyopaque) bool = null,
    max_rounds: u32 = 32,
};

pub const TurnResult = struct {
    /// Final assistant text (allocated; caller frees).
    text: []u8,
    rounds: u32,
    tokens_in: u64,
    tokens_out: u64,
    interrupted: bool = false,
    /// The bounded loop ended at an internal checkpoint rather than a model
    /// final answer. The daemon may resume root sessions transparently.
    round_budget_reached: bool = false,
};

pub fn publishPhase(opts: RunOpts, phase: proto.TurnPhase) void {
    if (opts.on_phase) |cb| cb(opts.on_delta_ctx, phase);
}

/// Bundles the repetitive persist-then-notify step.
pub const Appender = struct {
    store: *Store,
    io: Io,
    opts: *const RunOpts,
    seq: u64,
    turn_id: u64,
    history: ?*std.ArrayList(block.Block) = null,
    history_arena: ?std.mem.Allocator = null,

    pub fn append(self: *Appender, body: block.Body) !u64 {
        return self.appendWithBlobs(body, &.{});
    }

    pub fn appendWithBlob(self: *Appender, body: block.Body, hash: []const u8, bytes: []const u8) !u64 {
        return self.appendWithBlobs(body, &.{.{ .hash = hash, .bytes = bytes }});
    }

    pub fn appendWithBlobs(self: *Appender, body: block.Body, blobs: []const Store.BlobPayload) !u64 {
        self.seq += 1;
        errdefer self.seq -= 1;
        var cached_body: ?block.Body = null;
        if (self.history_arena) |arena| cached_body = try cloneBody(arena, body);
        const b: block.Block = .{
            .id = ids.next(self.io),
            .session_id = self.opts.session_id,
            .turn_id = self.turn_id,
            .seq = self.seq,
            .ts = nowMs(self.io),
            .body = body,
        };
        if (blobs.len > 0)
            try self.store.appendBlockWithBlobs(b, blobs)
        else
            try self.store.appendBlock(b);
        if (self.history) |history| {
            var cached = b;
            cached.body = cached_body.?;
            try history.append(self.history_arena.?, cached);
        }
        if (self.opts.on_block) |cb| cb(self.opts.on_delta_ctx, b);
        return b.id;
    }
};

fn cloneBody(arena: std.mem.Allocator, body: block.Body) !block.Body {
    return switch (body) {
        .user_msg => |value| .{ .user_msg = .{
            .text = try arena.dupe(u8, value.text),
            .attachments = try cloneMediaRefs(arena, value.attachments),
            .synthetic = value.synthetic,
        } },
        .assistant_msg => |value| .{ .assistant_msg = .{ .text = try arena.dupe(u8, value.text) } },
        .reasoning => |value| .{ .reasoning = .{ .text = try arena.dupe(u8, value.text), .commentary = value.commentary } },
        .tool_call => |value| .{ .tool_call = .{
            .call_id = try arena.dupe(u8, value.call_id),
            .name = try arena.dupe(u8, value.name),
            .args_json = try arena.dupe(u8, value.args_json),
        } },
        .tool_result => |value| .{ .tool_result = .{
            .call_id = try arena.dupe(u8, value.call_id),
            .status = value.status,
            .inline_body = try arena.dupe(u8, value.inline_body),
            .full_body_ref = if (value.full_body_ref) |reference| try arena.dupe(u8, reference) else null,
            .payload_bytes = value.payload_bytes,
            .attachments = try cloneMediaRefs(arena, value.attachments),
        } },
        .approval => |value| .{ .approval = .{
            .approval_id = try arena.dupe(u8, value.approval_id),
            .call_id = try arena.dupe(u8, value.call_id),
            .decision = value.decision,
            .decided_by = if (value.decided_by) |client| try arena.dupe(u8, client) else null,
        } },
        .steer => |value| .{ .steer = .{ .text = try arena.dupe(u8, value.text) } },
        .plan => |value| blk: {
            const items = try arena.alloc(block.PlanItem, value.items.len);
            for (value.items, items) |item, *copy| copy.* = .{
                .step = try arena.dupe(u8, item.step),
                .status = item.status,
                .started_at_ms = item.started_at_ms,
                .duration_ms = item.duration_ms,
            };
            break :blk .{ .plan = .{ .items = items } };
        },
        .compaction => |value| .{ .compaction = .{
            .summary = try arena.dupe(u8, value.summary),
            .covers_from_seq = value.covers_from_seq,
            .covers_to_seq = value.covers_to_seq,
        } },
        .system_note => |value| .{ .system_note = .{ .text = try arena.dupe(u8, value.text) } },
    };
}

fn cloneMediaRefs(arena: std.mem.Allocator, refs: []const block.MediaRef) ![]const block.MediaRef {
    const out = try arena.alloc(block.MediaRef, refs.len);
    for (refs, 0..) |ref, i| out[i] = .{
        .hash = try arena.dupe(u8, ref.hash),
        .mime = try arena.dupe(u8, ref.mime),
        .name = try arena.dupe(u8, ref.name),
        .byte_len = ref.byte_len,
    };
    return out;
}

/// Attach daemon-clock timing to a model-authored plan revision. Active time
/// is accumulated per turn, excluding idle wall-clock gaps between prompts.
/// Step text is unique by the plan tool contract and survives reordering.
fn latestPlanBlock(history: []const block.Block) ?*const block.Block {
    var index = history.len;
    while (index > 0) {
        index -= 1;
        if (history[index].kind() == .plan) return &history[index];
    }
    return null;
}

/// Completed work must have appeared as active in the immediately preceding
/// plan revision. Without that transition the daemon has no honest start time
/// from which to derive a duration.
pub fn skippedPlanCompletion(items: []const block.PlanItem, history: []const block.Block) ?[]const u8 {
    const previous = latestPlanBlock(history);
    for (items) |item| {
        if (item.status != .completed) continue;
        const prior_status: ?block.PlanStatus = if (previous) |prior_block| status: {
            for (prior_block.body.plan.items) |candidate| {
                if (std.mem.eql(u8, candidate.step, item.step)) break :status candidate.status;
            }
            break :status null;
        } else null;
        if (prior_status == null or prior_status.? == .pending) return item.step;
    }
    return null;
}

pub fn enforcePlanTransitions(
    gpa: std.mem.Allocator,
    exec: *tools_registry.ExecOut,
    history: []const block.Block,
) !void {
    if (exec.status != .ok) return;
    const items = exec.plan_items orelse return;
    const step = skippedPlanCompletion(items, history) orelse return;
    const output = try std.fmt.allocPrint(
        gpa,
        "error: plan_update step '{s}' was not in_progress in the preceding plan; omit work completed before planning, or mark the step in_progress before doing it and complete it in a later update",
        .{step},
    );
    gpa.free(exec.output);
    for (items) |item| gpa.free(@constCast(item.step));
    gpa.free(items);
    exec.output = output;
    exec.status = .err;
    exec.plan_items = null;
}

pub fn stampPlanTimings(
    store: *Store,
    session_id: u64,
    current_turn_id: u64,
    items: []block.PlanItem,
    history: []const block.Block,
    now_ms: i64,
) !void {
    const previous = latestPlanBlock(history);

    const current_start_ms = if (try store.turnTimeBounds(session_id, current_turn_id)) |bounds|
        bounds.start_ms
    else
        now_ms;
    var previous_end_ms: i64 = 0;
    if (previous) |prior_block| {
        previous_end_ms = prior_block.ts;
        if (prior_block.turn_id != current_turn_id) {
            if (try store.turnTimeBounds(session_id, prior_block.turn_id)) |bounds|
                previous_end_ms = bounds.end_ms;
        }
    }

    for (items) |*item| {
        var prior: ?block.PlanItem = null;
        if (previous) |prior_block| {
            for (prior_block.body.plan.items) |candidate| {
                if (std.mem.eql(u8, candidate.step, item.step)) {
                    prior = candidate;
                    break;
                }
            }
        }

        switch (item.status) {
            .pending => {
                item.started_at_ms = 0;
                item.duration_ms = 0;
            },
            .in_progress => {
                item.duration_ms = 0;
                item.started_at_ms = now_ms;
                if (prior) |old| {
                    if (old.status == .in_progress) {
                        const prior_block = previous.?;
                        const old_start = if (old.started_at_ms > 0) old.started_at_ms else prior_block.ts;
                        if (prior_block.turn_id == current_turn_id) {
                            item.started_at_ms = old_start;
                            item.duration_ms = old.duration_ms;
                        } else {
                            const prior_segment: u64 = if (old_start > 0 and previous_end_ms > old_start)
                                @intCast(previous_end_ms - old_start)
                            else
                                0;
                            item.duration_ms = old.duration_ms +| prior_segment;
                            item.started_at_ms = current_start_ms;
                        }
                    }
                }
            },
            .completed => {
                item.started_at_ms = 0;
                item.duration_ms = 0;
                if (prior) |old| switch (old.status) {
                    .completed => {
                        item.duration_ms = old.duration_ms;
                    },
                    .in_progress => {
                        const prior_block = previous.?;
                        const old_start = if (old.started_at_ms > 0) old.started_at_ms else prior_block.ts;
                        if (prior_block.turn_id == current_turn_id) {
                            const segment: u64 = if (old_start > 0 and now_ms > old_start)
                                @intCast(now_ms - old_start)
                            else
                                0;
                            item.duration_ms = old.duration_ms +| segment;
                        } else {
                            const prior_segment: u64 = if (old_start > 0 and previous_end_ms > old_start)
                                @intCast(previous_end_ms - old_start)
                            else
                                0;
                            const current_segment: u64 = if (current_start_ms > 0 and now_ms > current_start_ms)
                                @intCast(now_ms - current_start_ms)
                            else
                                0;
                            item.duration_ms = old.duration_ms +| prior_segment +| current_segment;
                        }
                    },
                    .pending => {},
                };
            },
        }
    }
}

fn loadMedia(ctx: *const anyopaque, allocator: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const store: *const Store = @ptrCast(@alignCast(ctx));
    return store.getBlobAlloc(allocator, hash);
}

fn appendEphemeralUserMessage(
    arena: std.mem.Allocator,
    msgs: []const provider.Message,
    text: []const u8,
) ![]provider.Message {
    const out = try arena.alloc(provider.Message, msgs.len + 1);
    @memcpy(out[0..msgs.len], msgs);
    out[msgs.len] = .{ .role = .user, .payload = .{ .text = text } };
    return out;
}

/// Run one full agent turn: user text in → tool roundtrips → final text out.
/// All blocks are persisted as they happen; a crash mid-turn leaves a
/// consistent log.
pub fn runTurn(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    opts: RunOpts,
    user_text: []const u8,
    attachments: []const block.MediaRef,
) !TurnResult {
    // Delegated sessions own the agent loop; no context assembly, provider
    // HTTP, or Marlin tool dispatch happens here.
    if (guestBackend(opts.endpoint)) |guest| {
        var ap = Appender{
            .store = store,
            .io = io,
            .opts = &opts,
            .seq = try store.lastSeq(opts.session_id),
            .turn_id = resolvedTurnId(opts, io),
        };
        const fresh = ap.seq == 0;
        const user_block_id = try ap.append(.{ .user_msg = .{
            .text = user_text,
            .attachments = attachments,
            .synthetic = opts.synthetic_input,
        } });
        for (attachments) |attachment| try store.addBlobRef(attachment.hash, user_block_id);
        const delegated_prompt = if (attachments.len > 0)
            try std.fmt.allocPrint(gpa, "{s}\n\n[{d} image attachment(s) are stored in Marlin but unavailable to this guest agent]", .{ user_text, attachments.len })
        else
            null;
        defer if (delegated_prompt) |prompt| gpa.free(prompt);
        return switch (guest) {
            .claude_code => runClaudeCodeTurn(gpa, io, store, opts, &ap, delegated_prompt orelse user_text, fresh),
            .codex => runCodexTurn(gpa, io, store, opts, &ap, delegated_prompt orelse user_text),
        };
    }

    var history_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer history_arena_state.deinit();
    const history_arena = history_arena_state.allocator();
    var history: std.ArrayList(block.Block) = .empty;
    const context_load = try store.loadContextBlocksIntoMeasured(io, history_arena, &history, opts.session_id, 1_000_000);
    const after_context_load_ms = nowAwakeMs(io);

    var ap = Appender{
        .store = store,
        .io = io,
        .opts = &opts,
        .seq = context_load.last_seq,
        .turn_id = resolvedTurnId(opts, io),
        .history = &history,
        .history_arena = history_arena,
    };

    var http_client = if (opts.http_pool) |pool| try pool.acquire() else try http.Client.init(gpa, io);
    defer http_client.deinit();

    const user_block_id = try ap.append(.{ .user_msg = .{
        .text = user_text,
        .attachments = attachments,
        .synthetic = opts.synthetic_input,
    } });
    for (attachments) |attachment| try store.addBlobRef(attachment.hash, user_block_id);

    // System-prompt context built once per turn: repo-local instructions and
    // the dynamic environment (cwd, git, date, sandbox/network regime).
    const project_instructions = projectInstructions(gpa, io, opts.cwd);
    defer if (project_instructions) |pi| gpa.free(pi);
    const environment: ?[]u8 = environmentBlock(gpa, io, &opts) catch null;
    defer if (environment) |env| gpa.free(env);

    var total_in: u64 = 0;
    var total_out: u64 = 0;
    var round: u32 = 0;
    var empty_final_retries: u8 = 0;
    var recover_empty_final = false;
    var web_search_available = nativeDialect(opts.endpoint) == .openrouter;
    const setup_after_load_ms = @max(0, nowAwakeMs(io) - after_context_load_ms);

    while (round < opts.max_rounds) : (round += 1) {
        publishPhase(opts, .context);
        const assemble_started_ms = nowAwakeMs(io);
        // -- cancellation checkpoint --
        if (cancelled(opts.cancel)) {
            _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{ .text = try gpa.dupe(u8, ""), .rounds = round, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
        }
        // -- steer checkpoint: inject queued mid-turn user text --
        _ = try drainSteers(gpa, opts, &ap);

        // -- assemble context from the turn-local append-only history --
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var blocks = history.items;

        const frontier: u64 = if (opts.prune_frontier) |pf| pf.* else 0;
        const extension_prompt_suffix = if (opts.extensions) |ext| ext.systemPromptSuffix() else "";
        var prompt_parts: std.ArrayList([]const u8) = .empty;
        if (extension_prompt_suffix.len > 0) try prompt_parts.append(arena, extension_prompt_suffix);
        if (web_search_available) try prompt_parts.append(arena, openrouter_web_search_prompt);
        if (opts.tool_profile == .plan) try prompt_parts.append(arena, plan_mode_prompt);
        const system_prompt_suffix = if (prompt_parts.items.len == 0)
            ""
        else
            try std.mem.join(arena, "\n\n", prompt_parts.items);
        var asm_opts = context.AssembleOpts{
            .prune_before_seq = frontier,
            .system_prompt_suffix = system_prompt_suffix,
            .project_instructions = project_instructions orelse "",
            .environment = environment orelse "",
            .media_loader = loadMedia,
            .media_loader_ctx = store,
        };
        var msgs = try context.assemble(arena, blocks, asm_opts);

        // -- L2 headroom check (turn boundary = before each request) --
        var est_used = context.estimateAssembled(msgs);
        if (context.needsCompaction(est_used, opts.endpoint.model, opts.cfg)) {
            if (try maybeCompact(gpa, io, arena, &ap, &http_client, opts, blocks, .auto)) {
                // Appender placed the new compaction block directly into the
                // cache; refresh the slice in case ArrayList reallocated.
                blocks = history.items;
                msgs = try context.assemble(arena, blocks, asm_opts);
            } else if (opts.prune_frontier) |pf| {
                // Compaction not possible (session too small / no progress):
                // fall back to L1 pruning if it can reclaim enough.
                if (context.planPrune(blocks, pf.*, opts.cfg.prune_protect_tokens, opts.cfg.prune_min_reclaim_tokens)) |new_frontier| {
                    pf.* = new_frontier;
                    _ = try ap.append(.{ .system_note = .{ .text = "context pruned (L1): old tool outputs elided" } });
                    asm_opts.prune_before_seq = new_frontier;
                    msgs = try context.assemble(arena, blocks, asm_opts);
                }
            }
        } else if (opts.prune_frontier) |pf| {
            // Soft threshold: prune well before compaction territory so the
            // cheap lever fires first. Soft = half the compaction trigger.
            const limit = context.contextLimit(opts.endpoint.model);
            const soft = limit / 2;
            if (est_used > soft) {
                if (context.planPrune(blocks, pf.*, opts.cfg.prune_protect_tokens, opts.cfg.prune_min_reclaim_tokens)) |new_frontier| {
                    pf.* = new_frontier;
                    _ = try ap.append(.{ .system_note = .{ .text = "context pruned (L1): old tool outputs elided" } });
                    asm_opts.prune_before_seq = new_frontier;
                    msgs = try context.assemble(arena, blocks, asm_opts);
                }
            }
        }
        if (recover_empty_final) {
            msgs = try appendEphemeralUserMessage(arena, msgs, empty_final_recovery_prompt);
            recover_empty_final = false;
        }

        // Publish the (possibly reduced) estimate for status displays.
        est_used = context.estimateAssembled(msgs);
        if (opts.context_used_out) |cu| cu.store(est_used, .release);
        const assemble_ms: u64 = @intCast(@max(0, nowAwakeMs(io) - assemble_started_ms));

        const extension_specs = if (opts.extensions) |ext| ext.specs() else &.{};
        var tool_count: usize = 0;
        for (&tools_registry.specs) |*s| if (toolAllowed(opts, s)) {
            tool_count += 1;
        };
        for (extension_specs) |*s| if (toolAllowed(opts, s)) {
            tool_count += 1;
        };
        const tools = try arena.alloc(openai.ToolSpec, tool_count);
        var tool_i: usize = 0;
        for (&tools_registry.specs) |*s| {
            if (!toolAllowed(opts, s)) continue;
            tools[tool_i] = .{ .name = s.name, .description = s.description, .schema_json = s.schema_json };
            tool_i += 1;
        }
        for (extension_specs) |*s| {
            if (!toolAllowed(opts, s)) continue;
            tools[tool_i] = .{ .name = s.name, .description = s.description, .schema_json = s.schema_json };
            tool_i += 1;
        }

        const provider_span = telemetry_ids.spanId(ids.next(io));
        const trace_id = telemetry_ids.traceId(opts.session_id, ap.turn_id);
        var request_opts = try providerRequestOptions(arena, opts, opts.endpoint);
        request_opts.openrouter_web_search = web_search_available;
        if (nativeDialect(opts.endpoint) == .openrouter and opts.otel_correlation) {
            request_opts.trace_id = &trace_id;
            request_opts.parent_span_id = &provider_span;
        }
        const body_started_ms = nowAwakeMs(io);
        const body = try buildProviderBody(
            arena,
            opts.endpoint,
            opts.effort,
            msgs,
            tools,
            request_opts,
            opts.cfg.output_headroom_tokens,
        );
        const body_ms: u64 = @intCast(@max(0, nowAwakeMs(io) - body_started_ms));

        // -- stream the response --
        var acc = openai.StreamAccum.init(gpa);
        defer acc.deinit();
        var anthropic_stream = anthropic.Stream{ .acc = &acc };

        var pump = Pump{
            .parser = sse.Parser.init(gpa),
            .acc = &acc,
            .anthropic_stream = if (nativeDialect(opts.endpoint) == .anthropic) &anthropic_stream else null,
            .io = io,
            .opts = &opts,
            .started_ms = nowMs(io),
        };
        pump.last_visible_ms = pump.started_ms;
        pump.last_emit_ms = pump.started_ms;
        defer pump.parser.deinit();
        var round_observation = RoundObservation{
            .enabled = opts.turn_id != 0,
            .session_id = opts.session_id,
            .turn_id = ap.turn_id,
            .round = round,
            .span_id = provider_span,
            .request_model = opts.endpoint.model,
            .provider_name = opts.endpoint.provider_name,
            .endpoint_url = opts.endpoint.url,
            .reasoning_level = if (nativeDialect(opts.endpoint) == .anthropic) "" else opts.effort.providerValue() orelse "",
            .max_tokens = if (nativeDialect(opts.endpoint) == .anthropic) @max(1024, opts.cfg.output_headroom_tokens) else 0,
            .context_load_ms = if (round == 0) context_load.total_ms else 0,
            .store_wait_ms = if (round == 0) context_load.wait_ms else 0,
            .context_rows = if (round == 0) context_load.rows else 0,
            .context_bytes = if (round == 0) context_load.body_bytes else 0,
            .context_vm_steps = if (round == 0) context_load.vm_steps else 0,
            .setup_ms = if (round == 0) opts.initial_setup_ms +| setup_after_load_ms else 0,
            .assemble_ms = assemble_ms,
            .body_ms = body_ms,
            .pump = &pump,
            .acc = &acc,
        };
        defer round_observation.persist(store, io);
        // Visible deltas route through the pump so it can stamp liveness
        // before chaining to the caller's callbacks.
        acc.on_delta = Pump.onVisibleText;
        acc.on_reasoning_delta = Pump.onVisibleReasoning;
        acc.on_delta_ctx = &pump;

        publishPhase(opts, .provider);
        const resp = http_client.streamPost(gpa, .{
            .url = opts.endpoint.url,
            .bearer = requestBearer(opts.endpoint),
            .body_json = body,
            .extra_headers = try dialectHeaders(arena, opts.endpoint),
            .cancel = opts.cancel,
            .on_wait = Pump.onProviderWait,
            .on_wait_ctx = &pump,
        }, &pump, Pump.onChunk) catch |e| switch (e) {
            error.Cancelled => {
                round_observation.status = "interrupted";
                _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
                try store.updateSessionUsage(opts.session_id, total_in, total_out);
                return .{ .text = try gpa.dupe(u8, ""), .rounds = round, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
            },
            error.ConsumerAborted => if (acc.response_too_large) {
                round_observation.status = "response_too_large";
                return error.ProviderResponseTooLarge;
            } else {
                round_observation.status = "consumer_aborted";
                return e;
            },
            else => {
                round_observation.status = @errorName(e);
                return e;
            },
        };
        round_observation.http_status = @intCast(@max(resp.status, 0));

        if (resp.status >= 400) {
            round_observation.status = "provider_error";
            const eb = resp.error_body orelse try gpa.dupe(u8, "");
            defer gpa.free(eb);
            const msg = try providerErrorNote(gpa, resp.status, eb);
            defer gpa.free(msg);
            _ = try ap.append(.{ .system_note = .{ .text = msg } });
            return error.ProviderError;
        }
        round_observation.status = "ok";
        acc.flushDeltas();

        if (acc.usage) |u| {
            total_in += u.tokens_in;
            total_out += u.tokens_out;
            if (u.web_search_requests > 0) web_search_available = false;
            if (nativeDialect(opts.endpoint) == .openrouter) {
                std.log.debug(
                    "OpenRouter generation {s} via {s}: input={d} cached={d} cache_write={d} output={d} reasoning={d} web_search={d}",
                    .{
                        if (acc.generation_id.items.len > 0) acc.generation_id.items else "unknown",
                        if (acc.provider_name.items.len > 0) acc.provider_name.items else "unknown",
                        u.tokens_in,
                        u.cached_tokens,
                        u.cache_write_tokens,
                        u.tokens_out,
                        u.reasoning_tokens,
                        u.web_search_requests,
                    },
                );
            }
        }
        // OpenRouter documents server-tool counts in usage, but some native
        // search streams currently omit that field while still returning URL
        // annotations. Either signal spends this turn's one search-bearing
        // provider request, keeping later Marlin tool rounds bounded.
        if (acc.citations.items.len > 0) web_search_available = false;

        // Provider-surfaced reasoning is useful liveness and durable context
        // for the human transcript, but is intentionally not sent back to the
        // model by context assembly.
        if (acc.reasoning.items.len > 0) {
            _ = try ap.append(.{ .reasoning = .{ .text = acc.reasoning.items } });
        }

        const response_text = try acc.textWithCitationLinks(arena);

        // -- no tool calls → final answer, unless the user steered --
        if (acc.calls.items.len == 0) {
            if (response_text.len == 0) {
                if (try drainSteers(gpa, opts, &ap) > 0) continue;
                if (acc.finish_reason == .content_filter) return error.ProviderContentFiltered;
                if (empty_final_retries == 0 and round + 1 < opts.max_rounds) {
                    empty_final_retries += 1;
                    recover_empty_final = true;
                    continue;
                }
                return error.ProviderEmptyResponse;
            }
            _ = try ap.append(.{ .assistant_msg = .{ .text = response_text } });
            // A steer submitted while this provider request was streaming
            // must become another model round, even though the response
            // otherwise looked final. Closing under the daemon's queue mutex
            // removes the last-poll/turn-done race: false means input arrived
            // between the drain and the close, so loop around and consume it.
            if (try drainSteers(gpa, opts, &ap) > 0) continue;
            if (!tryCloseSteering(opts)) continue;
            publishPhase(opts, .finishing);
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{
                .text = try gpa.dupe(u8, response_text),
                .rounds = round + 1,
                .tokens_in = total_in,
                .tokens_out = total_out,
            };
        }

        // Text emitted alongside tool calls is user-facing progress commentary,
        // not the final answer. Persist it so the TUI does not briefly stream a
        // useful update and then erase it when the tool round starts. Marked
        // commentary=true: clients keep these visible while folding the raw
        // provider reasoning above.
        if (response_text.len > 0) {
            _ = try ap.append(.{ .reasoning = .{ .text = response_text, .commentary = true } });
        }

        // Persist the provider's complete assistant tool batch before any
        // result. Besides matching the Chat Completions transcript contract,
        // this lets independent read-only calls execute concurrently.
        const prepared = try arena.alloc(PreparedCall, acc.calls.items.len);
        var prepared_count: usize = 0;
        defer {
            for (prepared[0..prepared_count]) |*call| call.deinit(gpa);
        }
        for (acc.calls.items, 0..) |*pc, i| {
            const args_repaired = jsonx.repairObject(gpa, pc.args.items) catch pc.args.items;
            const args_owned = if (args_repaired.ptr != pc.args.items.ptr)
                @constCast(args_repaired)
            else
                try gpa.dupe(u8, args_repaired);
            errdefer gpa.free(args_owned);

            // Persist a REDACTED copy. The block log, the search index, and
            // the OTLP export are all immortal, so a model that writes a key
            // into a command line must not get it stored; the tool itself
            // still receives the literal arguments and executes unchanged.
            const persisted_args = (try permissions.redactSecrets(gpa, opts.secrets, args_owned)) orelse args_owned;
            defer if (persisted_args.ptr != args_owned.ptr) gpa.free(persisted_args);
            const tool_call_block_id = try ap.append(.{ .tool_call = .{
                .call_id = pc.call_id.items,
                .name = pc.name.items,
                .args_json = persisted_args,
            } });

            const spec = tools_registry.find(pc.name.items) orelse
                if (opts.extensions) |ext| ext.find(pc.name.items) else null;
            prepared[i] = .{
                .call_id = pc.call_id.items,
                .name = pc.name.items,
                .args_json = args_owned,
                .tool_call_block_id = tool_call_block_id,
                .spec = spec,
                .span_id = telemetry_ids.spanId(ids.next(io)),
            };
            prepared_count += 1;
        }

        // Resolve all policy decisions before launching a parallel group.
        // Approval prompts remain serial and explicit; only calls whose spec
        // opts into parallel safety can overlap.
        for (prepared) |*call| {
            // -- approval gate: EVERY execution flows through here --
            // Auto-inside (docs/PERMISSIONS.md): a call whose boundaries are
            // ENFORCED needs no per-call prompt. Shell is enforced by the
            // canary-verified kernel sandbox; write_file/edit run in-daemon,
            // so their enforcement is the symlink-safe proof that the real
            // target stays inside the real workspace (fs.write_workspace:
            // "allow when sandbox verified"). Outside-workspace or unprovable
            // targets keep the legacy prompt.
            var sandboxed = opts.sandbox_options.backend != .unavailable and
                std.mem.eql(u8, call.name, bash_tool.spec_name);
            if (!sandboxed and opts.sandbox_options.backend != .unavailable and
                (std.mem.eql(u8, call.name, files_tool.write_spec_name) or
                    std.mem.eql(u8, call.name, files_tool.edit_spec_name)))
            {
                sandboxed = permissions.workspaceWriteAllowed(gpa, io, opts.cwd, call.args_json);
            }
            const decision: approval.Decision = if (call.spec) |s|
                if (!toolAllowed(opts, s))
                    .deny
                else
                    approval.policyFor(opts.cfg, effectiveApprovalMode(opts), s.mutating, sandboxed)
            else
                .run; // unknown tool → dispatch returns error text anyway

            switch (decision) {
                .deny => {
                    call.exec = .{
                        .output = try gpa.dupe(u8, "error: tool denied by session policy"),
                        .status = .denied,
                    };
                },
                .ask => {
                    publishPhase(opts, .approval);
                    const approval_id = ids.next(io);
                    const id_str = try std.fmt.allocPrint(gpa, "{d}", .{approval_id});
                    defer gpa.free(id_str);

                    const verdict: approval.Verdict = if (opts.gate) |g| blk: {
                        if (!g.arm(io, approval_id, opts.cancel)) break :blk .denied;
                        const published = if (opts.on_approval_needed) |cb|
                            cb(opts.on_delta_ctx, approval_id, call.call_id, call.name, call.args_json)
                        else
                            false;
                        if (!published) {
                            _ = g.resolve(io, approval_id, .denied);
                        }
                        break :blk g.wait(io, approval_id);
                    } else .approved; // no gate wired (tests) → auto

                    if (opts.on_approval_done) |cb| cb(opts.on_delta_ctx, approval_id, verdict);
                    publishPhase(opts, .tool);

                    _ = try ap.append(.{ .approval = .{
                        .approval_id = id_str,
                        .call_id = call.call_id,
                        .decision = switch (verdict) {
                            .approved => .granted,
                            .denied => .denied,
                        },
                        .decided_by = null,
                    } });

                    if (verdict == .denied) {
                        // Interrupt while parked also lands here; surface both.
                        const was_cancel = cancelled(opts.cancel);
                        call.exec = .{
                            .output = try gpa.dupe(u8, if (was_cancel)
                                "error: tool call interrupted by user"
                            else
                                "error: tool call denied by user"),
                            .status = if (was_cancel) .interrupted else .denied,
                        };
                    }
                },
                .run => {},
            }
        }

        publishPhase(opts, .tool);
        for (prepared) |*call| {
            if (call.exec != null and call.started_at_ms == 0) {
                call.started_at_ms = nowMs(io);
                call.ended_at_ms = call.started_at_ms;
            }
        }
        try executePrepared(gpa, io, opts, prepared);

        // Results stay in provider call order even when execution completed
        // out of order. The transcript is therefore deterministic and valid.
        for (prepared) |*call| {
            try enforcePlanTransitions(gpa, &call.exec.?, history.items);

            // Capture-time redaction, BEFORE hashing/capping/blobbing: the
            // append-only store makes anything persisted immortal.
            if (try permissions.redactSecrets(gpa, opts.secrets, call.exec.?.output)) |clean| {
                gpa.free(call.exec.?.output);
                call.exec.?.output = clean;
            }
            const exec = call.exec.?;

            // Blob the full output when it exceeds the inline cap.
            const cap: usize = opts.cfg.inline_tool_cap_bytes;
            var full_ref: ?[]const u8 = null;
            defer if (full_ref) |r| gpa.free(@constCast(r));
            if (exec.output.len > cap) full_ref = try Store.blobHashAlloc(gpa, exec.output);
            const inline_body = try context.capInline(gpa, exec.output, cap);
            defer if (inline_body.ptr != exec.output.ptr) gpa.free(@constCast(inline_body));

            const media_refs = try gpa.alloc(block.MediaRef, exec.media.len);
            defer gpa.free(media_refs);
            const media_hashes = try gpa.alloc([]u8, exec.media.len);
            var media_hashed: usize = 0;
            defer {
                for (media_hashes[0..media_hashed]) |hash| gpa.free(hash);
                gpa.free(media_hashes);
            }
            for (exec.media, 0..) |item, index| {
                const hash = try Store.blobHashAlloc(gpa, item.bytes);
                media_hashes[index] = hash;
                media_hashed += 1;
                media_refs[index] = .{
                    .hash = hash,
                    .mime = item.mime,
                    .name = item.name,
                    .byte_len = item.bytes.len,
                };
            }

            const result_body: block.Body = .{ .tool_result = .{
                .call_id = call.call_id,
                .status = exec.status,
                .inline_body = inline_body,
                .full_body_ref = full_ref,
                .payload_bytes = exec.payload_bytes,
                .attachments = media_refs,
            } };
            const blob_count = exec.media.len + @intFromBool(full_ref != null);
            if (blob_count == 0) {
                _ = try ap.append(result_body);
            } else {
                const blobs = try gpa.alloc(Store.BlobPayload, blob_count);
                defer gpa.free(blobs);
                var blob_index: usize = 0;
                if (full_ref) |hash| {
                    blobs[blob_index] = .{ .hash = hash, .bytes = exec.output };
                    blob_index += 1;
                }
                for (exec.media, media_hashes) |item, hash| {
                    blobs[blob_index] = .{ .hash = hash, .bytes = item.bytes };
                    blob_index += 1;
                }
                _ = try ap.appendWithBlobs(result_body, blobs);
            }
            if (exec.status == .ok) {
                if (exec.plan_items) |items| {
                    try stampPlanTimings(
                        store,
                        opts.session_id,
                        ap.turn_id,
                        items,
                        history.items,
                        nowMs(io),
                    );
                    _ = try ap.append(.{ .plan = .{ .items = items } });
                }
            }
            if (opts.turn_id != 0) store.telemetryRecordTool(opts.session_id, ap.turn_id, .{
                .round = round,
                .call_id = call.call_id,
                .span_id = &call.span_id,
                .name = call.name,
                .description = if (call.spec) |spec| spec.description else "",
                .started_at_ms = call.started_at_ms,
                .ended_at_ms = call.ended_at_ms,
                .status = @tagName(exec.status),
            }) catch |err| std.log.warn("could not persist tool telemetry: {t}", .{err});
        }
        // Loop: next round re-assembles including the new tool results.
    }

    // max_rounds bounds one worker-thread lifetime, not the user's task. Root
    // sessions resume from this durable checkpoint automatically; task
    // children deliberately return their bounded partial-result contract.
    _ = try ap.append(.{ .system_note = .{ .text = if (opts.auto_continue_round_budget)
        "internal round checkpoint reached"
    else
        "child round budget reached; partial work returned to parent" } });
    try store.updateSessionUsage(opts.session_id, total_in, total_out);
    return .{
        .text = try gpa.dupe(u8, "[round budget reached before a final answer; partial work is in the transcript]"),
        .rounds = round,
        .tokens_in = total_in,
        .tokens_out = total_out,
        .round_budget_reached = true,
    };
}

/// The mode consulted per call: the session's live value when wired (so a
/// mid-turn /permissions switch affects the very next call), else the
/// turn-start snapshot.
pub fn effectiveApprovalMode(opts: RunOpts) approval.Mode {
    const live = opts.approval_mode_live orelse return opts.approval_mode;
    return @enumFromInt(live.load(.acquire));
}

/// Guest agents ask only after their own sandbox/policy requires escalation.
/// Treat that request as mutating at Marlin's boundary and resolve it through
/// the same durable gate and UI used by native tool calls.
pub fn resolveGuestApproval(
    gpa: std.mem.Allocator,
    io: Io,
    opts: RunOpts,
    ap: *Appender,
    call_id: []const u8,
    tool: []const u8,
    args_json: []const u8,
) !approval.Verdict {
    const decision: approval.Decision = if (opts.tool_profile != .full)
        .deny
    else
        approval.policyFor(opts.cfg, effectiveApprovalMode(opts), true, false);
    if (decision == .run) return .approved;
    if (decision == .deny) return .denied;

    publishPhase(opts, .approval);
    const approval_id = ids.next(io);
    const id_str = try std.fmt.allocPrint(gpa, "{d}", .{approval_id});
    defer gpa.free(id_str);
    const verdict: approval.Verdict = if (opts.gate) |gate| blk: {
        if (!gate.arm(io, approval_id, opts.cancel)) break :blk .denied;
        const published = if (opts.on_approval_needed) |callback|
            callback(opts.on_delta_ctx, approval_id, call_id, tool, args_json)
        else
            false;
        if (!published) _ = gate.resolve(io, approval_id, .denied);
        break :blk gate.wait(io, approval_id);
    } else .approved;

    if (opts.on_approval_done) |callback| callback(opts.on_delta_ctx, approval_id, verdict);
    publishPhase(opts, .provider);
    _ = try ap.append(.{ .approval = .{
        .approval_id = id_str,
        .call_id = call_id,
        .decision = if (verdict == .approved) .granted else .denied,
        .decided_by = null,
    } });
    return verdict;
}

pub fn cancelled(flag: ?*std.atomic.Value(bool)) bool {
    const f = flag orelse return false;
    return f.load(.acquire);
}

/// Persist every steer currently available. The callback transfers ownership
/// of each returned allocation to this function.
fn drainSteers(gpa: std.mem.Allocator, opts: RunOpts, ap: *Appender) !usize {
    const poll = opts.poll_steer orelse return 0;
    var count: usize = 0;
    while (poll(opts.on_delta_ctx, gpa)) |steer_text| {
        defer gpa.free(steer_text);
        _ = try ap.append(.{ .steer = .{ .text = steer_text } });
        count += 1;
    }
    return count;
}

pub fn tryCloseSteering(opts: RunOpts) bool {
    const close = opts.try_close_steer orelse return true;
    return close(opts.on_delta_ctx);
}

fn errorMessage(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    const err = value.object.get("error") orelse return null;
    if (err != .object) return null;
    const message = err.object.get("message") orelse return null;
    return if (message == .string) message.string else null;
}

fn utf8Prefix(text: []const u8, max: usize) []const u8 {
    var end = @min(text.len, max);
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

fn compactErrorText(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    const clipped = utf8Prefix(std.mem.trim(u8, text, " \t\r\n"), max);
    var out = try arena.alloc(u8, clipped.len);
    for (clipped, 0..) |ch, i| out[i] = switch (ch) {
        '\r', '\n', '\t' => ' ',
        else => ch,
    };
    return out;
}

/// Persist a useful provider failure, not an entire gateway response. For
/// OpenRouter errors the actionable upstream message is nested as JSON in
/// metadata.raw, while provider_name identifies the attempted backend.
pub fn providerErrorNote(allocator: std.mem.Allocator, status: i64, body: []const u8) ![]u8 {
    var parsed_state = std.heap.ArenaAllocator.init(allocator);
    defer parsed_state.deinit();
    const arena = parsed_state.allocator();

    var message: ?[]const u8 = null;
    var provider_name: ?[]const u8 = null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch null;
    if (parsed) |root| {
        message = errorMessage(root);
        if (root == .object) {
            if (root.object.get("error")) |err| if (err == .object) {
                if (err.object.get("metadata")) |metadata| if (metadata == .object) {
                    if (metadata.object.get("provider_name")) |name| {
                        if (name == .string) provider_name = name.string;
                    }
                    if (metadata.object.get("raw")) |raw| if (raw == .string) {
                        const nested = std.json.parseFromSliceLeaky(std.json.Value, arena, raw.string, .{}) catch null;
                        if (nested) |value| message = errorMessage(value) orelse message;
                    };
                };
            };
        }
    }

    const useful = try compactErrorText(arena, message orelse if (body.len > 0) body else "request failed", 480);
    if (provider_name) |name| {
        const provider_short = try compactErrorText(arena, name, 80);
        return std.fmt.allocPrint(allocator, "provider HTTP {d} via {s}: {s}", .{ status, provider_short, useful });
    }
    return std.fmt.allocPrint(allocator, "provider HTTP {d}: {s}", .{ status, useful });
}

// ------------------------------------------------------------ compaction --

pub const CompactTrigger = enum { auto, manual };

/// Try to compact the session: summarize the plannable range via the
/// compaction endpoint, append a compaction block, then rehydrate. Returns
/// false when there's nothing sensible to compact (small session, no
/// progress since last compaction) or the summarizer failed (logged;
/// the turn proceeds uncompacted rather than dying).
fn maybeCompact(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    ap: *Appender,
    http_client: *http.Client,
    opts: RunOpts,
    blocks: []const block.Block,
    trigger: CompactTrigger,
) !bool {
    const plan = context.planCompaction(blocks, trigger == .auto) orelse {
        if (trigger == .manual) {
            _ = try ap.append(.{ .system_note = .{ .text = "nothing to compact (session too small or no progress since last compaction)" } });
        }
        return false;
    };

    publishPhase(opts, .compaction);
    defer publishPhase(opts, .context);

    const transcript = try context.renderForSummary(arena, blocks, plan.from_seq, plan.to_seq, 400_000);
    const ep = opts.compaction_endpoint orelse opts.endpoint;

    const summary = summarize(
        gpa,
        arena,
        http_client,
        ep,
        transcript,
        opts.cancel,
        try providerRequestOptions(arena, opts, ep),
        context.compaction_prompt,
        null,
    ) catch |e| {
        const msg = try std.fmt.allocPrint(arena, "compaction failed ({t}) — continuing uncompacted", .{e});
        _ = try ap.append(.{ .system_note = .{ .text = msg } });
        return false;
    };

    _ = try ap.append(.{ .compaction = .{
        .summary = summary,
        .covers_from_seq = plan.from_seq,
        .covers_to_seq = plan.to_seq,
    } });

    // -- rehydrate: head+tail of recently written files + continuation note.
    // (Claude Code's insight: summary-only compaction is amnesia.)
    const paths = try context.recentWrittenFiles(arena, blocks, 3);
    for (paths) |p| {
        const abs = try files_tool.resolvePath(arena, p, opts.cwd);
        const contents = Io.Dir.cwd().readFileAlloc(io, abs, arena, .limited(64 * 1024)) catch continue;
        const windowed = try context.capInline(arena, contents, 4_000);
        const note = try std.fmt.allocPrint(arena, "[rehydrated after compaction] {s}:\n{s}", .{ p, windowed });
        _ = try ap.append(.{ .user_msg = .{ .text = note, .synthetic = true } });
    }
    const note_txt: []const u8 = switch (trigger) {
        .auto => "context compacted automatically (headroom); summary + rehydrated files above replace the older conversation",
        .manual => "context compacted by /compact; summary + rehydrated files above replace the older conversation",
    };
    _ = try ap.append(.{ .system_note = .{ .text = note_txt } });
    return true;
}

// ------------------------------------------------------------- guests --
// The guest runtimes live behind a file boundary the compiler enforces
// (docs/ARCHITECTURE.md, Native vs guest): loop.zig is the NATIVE agent
// turn; daemon/guest/* host the official vendor binaries and borrow only
// the block appender, turn options, phase/steer handling, approval
// resolution, and redaction from it.
const claude_code_turn = @import("guest/claude_code_turn.zig");
pub const codex_turn = @import("guest/codex_turn.zig");
const guest_shared = @import("guest/shared.zig");
pub const lastDelegateErrorNote = guest_shared.lastDelegateErrorNote;
const runClaudeCodeTurn = claude_code_turn.runClaudeCodeTurn;
const runCodexTurn = codex_turn.runCodexTurn;

/// Summaries are bounded prose, not agent output; a fixed budget keeps the
/// anthropic max_tokens requirement independent of the session's headroom.
const summary_max_tokens: u64 = 8192;

/// One non-tool provider round: transcript in, summary text out.
/// Allocated into `arena`. `stream_opts` fans visible deltas to the TUI
/// when the caller wants the user to watch (native→guest handover).
pub fn summarize(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    http_client: *http.Client,
    ep: Endpoint,
    transcript: []const u8,
    cancel: ?*std.atomic.Value(bool),
    request_opts: openai.RequestOptions,
    system_prompt: []const u8,
    stream_opts: ?*const RunOpts,
) ![]const u8 {
    var msgs = [_]provider.Message{
        .{ .role = .system, .payload = .{ .text = system_prompt } },
        .{ .role = .user, .payload = .{ .text = transcript } },
    };
    const body = try buildProviderBody(arena, ep, .auto, &msgs, &.{}, request_opts, summary_max_tokens);

    var acc = openai.StreamAccum.init(gpa);
    defer acc.deinit();
    var anthropic_stream = anthropic.Stream{ .acc = &acc };
    var pump = Pump{
        .parser = sse.Parser.init(gpa),
        .acc = &acc,
        .anthropic_stream = if (nativeDialect(ep) == .anthropic) &anthropic_stream else null,
        .opts = stream_opts,
    };
    defer pump.parser.deinit();
    if (stream_opts != null) {
        acc.on_delta = Pump.onVisibleText;
        acc.on_reasoning_delta = Pump.onVisibleReasoning;
        acc.on_delta_ctx = &pump;
    }

    const resp = http_client.streamPost(gpa, .{
        .url = ep.url,
        .bearer = requestBearer(ep),
        .body_json = body,
        .extra_headers = try dialectHeaders(arena, ep),
        .cancel = cancel,
    }, &pump, Pump.onChunk) catch |err| {
        if (err == error.ConsumerAborted and acc.response_too_large)
            return error.ProviderResponseTooLarge;
        return err;
    };
    if (resp.status >= 400) {
        if (resp.error_body) |eb| gpa.free(eb);
        return error.SummarizerHttpError;
    }
    if (acc.text.items.len == 0) return error.EmptySummary;
    return arena.dupe(u8, acc.text.items);
}

/// Manual /compact: run the summarize+append+rehydrate path outside a turn.
/// Returns true when a compaction block was appended.
pub fn compactSession(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    opts: RunOpts,
) !bool {
    // Delegated sessions carry no Marlin-assembled context to compact.
    if (guestBackend(opts.endpoint) != null) return error.DelegatedContext;
    var http_client = if (opts.http_pool) |pool| try pool.acquire() else try http.Client.init(gpa, io);
    defer http_client.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var relevant: std.ArrayList(block.Block) = .empty;
    try store.loadContextBlocksInto(arena, &relevant, opts.session_id, 1_000_000);
    const blocks = relevant.items;

    var ap = Appender{
        .store = store,
        .io = io,
        .opts = &opts,
        .seq = try store.lastSeq(opts.session_id),
        .turn_id = ids.next(io),
    };
    return maybeCompact(gpa, io, arena, &ap, &http_client, opts, blocks, .manual);
}

/// Native→guest handover: the CURRENT native model writes a visible briefing
/// for the delegated agent. Empty logs skip the LLM. Summarizer failure still
/// switches; we persist a short mechanical note rather than blocking the user.
pub fn writeHandover(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    opts: RunOpts,
    guest_model: []const u8,
) !void {
    if (guestBackend(opts.endpoint) != null) return error.DelegatedContext;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var history: std.ArrayList(block.Block) = .empty;
    try store.loadContextBlocksInto(arena, &history, opts.session_id, 1_000_000);

    var ap = Appender{
        .store = store,
        .io = io,
        .opts = &opts,
        .seq = try store.lastSeq(opts.session_id),
        .turn_id = ids.next(io),
    };

    const guest_label: []const u8 = switch (proto.guestBackend(guest_model) orelse return error.UnknownGuest) {
        .claude_code => "Claude Code",
        .codex => "Codex guest",
    };
    const announce = try std.fmt.allocPrint(
        arena,
        "Switching to {s} ({s}). Generating a handover summary with the current model…",
        .{ guest_label, guest_model },
    );
    _ = try ap.append(.{ .system_note = .{ .text = announce } });
    publishPhase(opts, .provider);

    if (history.items.len == 0) {
        const empty_note = try std.fmt.allocPrint(
            arena,
            "{s}No prior native work to hand over.",
            .{block.handover_prefix},
        );
        _ = try ap.append(.{ .system_note = .{ .text = empty_note } });
        return;
    }

    var http_client = if (opts.http_pool) |pool| try pool.acquire() else try http.Client.init(gpa, io);
    defer http_client.deinit();
    const from_seq = history.items[0].seq;
    const to_seq = history.items[history.items.len - 1].seq;
    const transcript = try context.renderForSummary(arena, history.items, from_seq, to_seq, 400_000);
    const summary = summarize(
        gpa,
        arena,
        &http_client,
        opts.endpoint,
        transcript,
        opts.cancel,
        try providerRequestOptions(arena, opts, opts.endpoint),
        context.handover_prompt,
        &opts,
    ) catch |e| {
        const msg = try std.fmt.allocPrint(
            arena,
            "{s}Handover summary failed ({t}). {s} will start without a briefing; the Marlin transcript above is still the session log.",
            .{ block.handover_prefix, e, guest_label },
        );
        _ = try ap.append(.{ .system_note = .{ .text = msg } });
        return;
    };
    const note = try std.fmt.allocPrint(arena, "{s}{s}", .{ block.handover_prefix, summary });
    _ = try ap.append(.{ .system_note = .{ .text = note } });
}

pub fn toolAllowed(opts: RunOpts, spec: *const tools_registry.Spec) bool {
    const is_task = std.mem.eql(u8, spec.name, task_tool.spec_name) or
        std.mem.eql(u8, spec.name, task_tool.batch_spec_name);
    if (is_task) return opts.on_task != null and opts.tool_profile != .read_only;
    if (opts.tool_profile == .plan) {
        if (std.mem.eql(u8, spec.name, "bash") or std.mem.eql(u8, spec.name, "plan_update")) return false;
        return !spec.mutating;
    }
    if (opts.tool_profile == .read_only and spec.mutating) return false;
    return true;
}

fn providerRequestOptions(arena: std.mem.Allocator, opts: RunOpts, ep: Endpoint) !openai.RequestOptions {
    if (nativeDialect(ep) != .openrouter) return .{};
    return .{
        .session_id = try std.fmt.allocPrint(arena, "marlin-{x:0>16}", .{opts.session_id}),
        .provider_sort = opts.cfg.openrouter_sort,
        .explicit_cache = needsExplicitCache(ep.model),
    };
}

fn needsExplicitCache(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "anthropic/") or
        std.mem.startsWith(u8, model, "google/") or
        std.mem.startsWith(u8, model, "qwen/") or
        std.mem.startsWith(u8, model, "alibaba/");
}

const openrouter_observability_headers = [_][]const u8{"X-OpenRouter-Metadata: enabled"};

pub const openrouter_web_search_prompt =
    \\WEB SEARCH
    \\- Web search is available for discovering sources and verifying current
    \\  information. Use `fetch` when you already have a specific URL. Preserve
    \\  source URLs in the response.
    \\- Before invoking web search, emit a brief user-visible progress note
    \\  naming the search target. Never search silently.
;

const plan_mode_prompt =
    \\PLAN MODE
    \\- Investigate and design only. Do not modify files, run shell commands, or call mutating tools.
    \\- Ask focused questions only when the answer materially changes the plan.
    \\- End with a concrete implementation plan that is ready for the user to accept or revise.
    \\- Do not call plan_update; that tool tracks execution after a proposal is accepted.
;

fn observabilityHeaders(dialect: provider.Dialect) []const []const u8 {
    return if (dialect == .openrouter) &openrouter_observability_headers else &.{};
}

/// The bearer the HTTP layer should send. Anthropic's Messages API has no
/// bearer auth; its key travels in x-api-key via dialectHeaders instead.
fn requestBearer(ep: Endpoint) ?[]const u8 {
    return if (nativeDialect(ep) == .anthropic) null else ep.bearer;
}

fn dialectHeaders(arena: std.mem.Allocator, ep: Endpoint) ![]const []const u8 {
    const dialect = nativeDialect(ep);
    if (dialect != .anthropic) return observabilityHeaders(dialect);
    const headers = try arena.alloc([]const u8, 2);
    headers[0] = try std.fmt.allocPrint(arena, "x-api-key: {s}", .{ep.bearer orelse ""});
    headers[1] = anthropic.version_header;
    return headers;
}

/// Dialect-dispatched request body. Anthropic requires max_tokens; the
/// output headroom the context engine already reserves is exactly that
/// budget. Reasoning effort is OpenAI-shape only for now (see anthropic.zig
/// header for why thinking is deferred).
fn buildProviderBody(
    arena: std.mem.Allocator,
    ep: Endpoint,
    effort: Effort,
    msgs: []const provider.Message,
    tools: []const openai.ToolSpec,
    request_opts: openai.RequestOptions,
    max_tokens: u64,
) ![]u8 {
    const dialect = nativeDialect(ep);
    return switch (dialect) {
        .anthropic => anthropic.buildRequestBody(arena, ep.model, msgs, tools, @max(1024, max_tokens)),
        .openrouter, .openai_compatible => openai.buildRequestBody(arena, ep.model, dialect, effort, msgs, tools, request_opts),
    };
}

fn runTool(gpa: std.mem.Allocator, io: Io, opts: RunOpts, parent_block_id: u64, name: []const u8, args_json: []const u8) tools_registry.ExecOut {
    if (opts.on_tool) |cb| cb(opts.on_delta_ctx, name, .start);
    defer if (opts.on_tool) |cb| cb(opts.on_delta_ctx, name, .done);
    if (std.mem.eql(u8, name, task_tool.spec_name) or
        std.mem.eql(u8, name, task_tool.batch_spec_name))
    {
        publishPhase(opts, .child);
        defer publishPhase(opts, .tool);
        if (opts.on_task) |cb| {
            if (std.mem.eql(u8, name, task_tool.batch_spec_name))
                return runTaskBatch(gpa, io, opts, parent_block_id, args_json, cb);
            return cb(opts.on_delta_ctx, parent_block_id, args_json);
        }
        return .{
            .output = gpa.dupe(u8, "error: task is unavailable in this session") catch @panic("oom"),
            .status = .denied,
        };
    }
    if (opts.extensions) |ext| {
        if (ext.dispatch(name, args_json, opts.cwd, opts.cancel)) |result| return result;
    }
    return tools_registry.dispatch(
        gpa,
        io,
        name,
        args_json,
        opts.cwd,
        opts.tool_environ,
        opts.sandbox_options,
        opts.network_policy,
        opts.cancel,
    );
}

const BatchTaskCall = struct {
    args_json: []u8,
    result: ?tools_registry.ExecOut = null,

    fn deinit(self: *BatchTaskCall, gpa: std.mem.Allocator) void {
        gpa.free(self.args_json);
        if (self.result) |result| result.deinit(gpa);
        self.* = undefined;
    }
};

const BatchTaskWorker = struct {
    fn run(
        cb: *const fn (?*anyopaque, u64, []const u8) tools_registry.ExecOut,
        ctx: ?*anyopaque,
        parent_block_id: u64,
        call: *BatchTaskCall,
    ) void {
        call.result = cb(ctx, parent_block_id, call.args_json);
    }
};

pub fn runTaskBatch(
    gpa: std.mem.Allocator,
    io: Io,
    opts: RunOpts,
    parent_block_id: u64,
    args_json: []const u8,
    cb: *const fn (?*anyopaque, u64, []const u8) tools_registry.ExecOut,
) tools_registry.ExecOut {
    _ = io;
    const parsed = std.json.parseFromSlice(task_tool.BatchArgs, gpa, args_json, .{
        .ignore_unknown_fields = false,
    }) catch return taskBatchError(gpa, "arguments do not match the schema");
    defer parsed.deinit();
    if (parsed.value.tasks.len < 2 or parsed.value.tasks.len > task_tool.max_batch_tasks)
        return taskBatchError(gpa, "requires between two and eight tasks");

    const calls = gpa.alloc(BatchTaskCall, parsed.value.tasks.len) catch
        return taskBatchError(gpa, "out of memory");
    var initialized: usize = 0;
    defer {
        for (calls[0..initialized]) |*call| call.deinit(gpa);
        gpa.free(calls);
    }
    for (parsed.value.tasks) |args| {
        calls[initialized] = .{
            .args_json = std.json.Stringify.valueAlloc(gpa, args, .{}) catch
                return taskBatchError(gpa, "could not encode task arguments"),
        };
        initialized += 1;
    }

    var threads: std.ArrayList(std.Thread) = .empty;
    defer threads.deinit(gpa);
    threads.ensureTotalCapacity(gpa, calls.len) catch
        return taskBatchError(gpa, "out of memory");
    var at: usize = 0;
    while (at < calls.len) : (at += 1) {
        const thread = std.Thread.spawn(.{}, BatchTaskWorker.run, .{
            cb,
            opts.on_delta_ctx,
            parent_block_id,
            &calls[at],
        }) catch break;
        threads.appendAssumeCapacity(thread);
    }
    for (threads.items) |thread| thread.join();
    // A resource-exhausted spawn never overlaps with serial fallback: every
    // worker already started is joined before the remaining children begin.
    for (calls[at..]) |*call| BatchTaskWorker.run(cb, opts.on_delta_ctx, parent_block_id, call);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const BatchResult = struct {
        index: usize,
        status: []const u8,
        result: std.json.Value,
    };
    const results = arena.alloc(BatchResult, calls.len) catch
        return taskBatchError(gpa, "out of memory");
    var overall_status: block.ToolStatus = .ok;
    for (calls, results, 0..) |call, *result, index| {
        const child = call.result.?;
        if (child.status == .interrupted) overall_status = .interrupted;
        result.* = .{
            .index = index,
            .status = @tagName(child.status),
            .result = std.json.parseFromSliceLeaky(std.json.Value, arena, child.output, .{}) catch
                .{ .string = child.output },
        };
    }
    const output = std.json.Stringify.valueAlloc(gpa, .{ .results = results }, .{}) catch
        return taskBatchError(gpa, "could not encode results");
    return .{ .output = output, .status = overall_status };
}

fn taskBatchError(gpa: std.mem.Allocator, message: []const u8) tools_registry.ExecOut {
    return .{
        .output = std.fmt.allocPrint(gpa, "error: task_batch {s}", .{message}) catch @panic("oom"),
        .status = .err,
    };
}

const PreparedCall = struct {
    call_id: []const u8,
    name: []const u8,
    args_json: []u8,
    tool_call_block_id: u64,
    spec: ?*const tools_registry.Spec,
    span_id: telemetry_ids.SpanId,
    started_at_ms: i64 = 0,
    ended_at_ms: i64 = 0,
    exec: ?tools_registry.ExecOut = null,

    fn deinit(self: *PreparedCall, gpa: std.mem.Allocator) void {
        gpa.free(self.args_json);
        if (self.exec) |result| result.deinit(gpa);
        self.* = undefined;
    }

    fn parallelSafe(self: PreparedCall) bool {
        return self.spec != null and self.spec.?.parallel_safe;
    }
};

const ToolWorker = struct {
    fn run(gpa: std.mem.Allocator, io: Io, opts: RunOpts, call: *PreparedCall) void {
        call.started_at_ms = nowMs(io);
        call.exec = runTool(gpa, io, opts, call.tool_call_block_id, call.name, call.args_json);
        call.ended_at_ms = nowMs(io);
    }
};

pub const max_parallel_tool_workers: usize = 8;

pub fn parallelChunkEnd(start: usize, group_end: usize) usize {
    return @min(start +| max_parallel_tool_workers, group_end);
}

/// Execute maximal contiguous groups of parallel-safe calls concurrently.
/// Unsafe calls are ordering barriers, preserving model-requested mutation
/// semantics. Results are only persisted by the parent turn thread.
fn executePrepared(gpa: std.mem.Allocator, io: Io, opts: RunOpts, calls: []PreparedCall) !void {
    var i: usize = 0;
    while (i < calls.len) {
        if (calls[i].exec != null) {
            i += 1;
            continue;
        }
        if (!calls[i].parallelSafe()) {
            ToolWorker.run(gpa, io, opts, &calls[i]);
            i += 1;
            continue;
        }

        var end = i + 1;
        while (end < calls.len and calls[end].exec == null and calls[end].parallelSafe()) : (end += 1) {}
        if (end - i == 1) {
            ToolWorker.run(gpa, io, opts, &calls[i]);
            i = end;
            continue;
        }

        var threads: std.ArrayList(std.Thread) = .empty;
        defer threads.deinit(gpa);
        try threads.ensureTotalCapacity(gpa, max_parallel_tool_workers);
        var chunk_start = i;
        while (chunk_start < end) {
            threads.clearRetainingCapacity();
            const chunk_end = parallelChunkEnd(chunk_start, end);
            var at = chunk_start;
            while (at < chunk_end) : (at += 1) {
                const thread = std.Thread.spawn(.{}, ToolWorker.run, .{ gpa, io, opts, &calls[at] }) catch break;
                threads.appendAssumeCapacity(thread);
            }
            for (threads.items) |thread| thread.join();

            if (at < chunk_end) {
                // A partial chunk is joined before serial fallback; no worker
                // remains live while the rest of this safe group executes.
                for (calls[at..end]) |*call| ToolWorker.run(gpa, io, opts, call);
                break;
            }
            chunk_start = chunk_end;
        }
        i = end;
    }
}

pub fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

fn nowAwakeMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

fn resolvedTurnId(opts: RunOpts, io: Io) u64 {
    return if (opts.turn_id != 0) opts.turn_id else ids.next(io);
}

/// Repo-local agent instructions: MARLIN.md, falling back to AGENTS.md, at
/// the session root. Read fresh each turn so edits apply immediately.
/// Missing, empty, or oversized files yield null.
pub fn projectInstructions(gpa: std.mem.Allocator, io: Io, cwd: []const u8) ?[]u8 {
    const names = [_][]const u8{ "MARLIN.md", "AGENTS.md" };
    for (names) |name| {
        const path = std.fs.path.join(gpa, &.{ cwd, name }) catch return null;
        defer gpa.free(path);
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(48 * 1024)) catch continue;
        if (std.mem.trim(u8, bytes, " \t\r\n").len == 0) {
            gpa.free(bytes);
            continue;
        }
        return bytes;
    }
    return null;
}

/// One git probe in the session cwd under the scrubbed tool environment.
/// Returns owned stdout on exit 0; any failure degrades to null.
fn gitProbe(
    gpa: std.mem.Allocator,
    io: Io,
    opts: *const RunOpts,
    argv: []const []const u8,
    stdout_limit: usize,
) ?[]u8 {
    const res = process_io.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = opts.tool_environ,
        .stdout_limit = stdout_limit,
        .stderr_limit = 4096,
        .timeout_ms = 500,
        .cancel = opts.cancel,
    }) catch return null;
    defer gpa.free(res.stderr);
    if (res.term != .exited or res.term.exited != 0) {
        gpa.free(res.stdout);
        return null;
    }
    return res.stdout;
}

/// The dynamic ENVIRONMENT section of the system prompt: facts the model
/// would otherwise burn a round discovering or silently guess wrong (cwd,
/// date, git state) plus the live sandbox/network regime that the base
/// prompt's SANDBOX AND PERMISSIONS section refers to.
pub fn environmentBlock(gpa: std.mem.Allocator, io: Io, opts: *const RunOpts) ![]u8 {
    const ts = Io.Timestamp.now(io, .real);
    const secs: u64 = @intCast(@max(0, @divTrunc(ts.nanoseconds, std.time.ns_per_s)));
    const year_day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var git_desc: []const u8 = "not a git repository";
    const git_probe = gitProbe(
        gpa,
        io,
        opts,
        &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
        4096,
    );
    defer if (git_probe) |g| gpa.free(g);
    var git_summary: ?[]u8 = null;
    defer if (git_summary) |summary| gpa.free(summary);
    if (git_probe) |branch_raw| {
        const branch = std.mem.trim(u8, branch_raw, " \t\r\n");
        if (branch.len > 0 and !std.mem.eql(u8, branch, "HEAD")) {
            git_summary = try std.fmt.allocPrint(gpa, "a git repository, branch {s}", .{branch});
            git_desc = git_summary.?;
        } else {
            git_desc = "a git repository (detached HEAD)";
        }
    }

    const sandbox_desc: []const u8 = switch (opts.sandbox_options.backend) {
        .seatbelt, .landlock => "active (kernel-enforced; workspace shell commands run without approval prompts)",
        .unavailable => "inactive (shell commands may require per-call user approval)",
    };

    var network_owned: ?[]u8 = null;
    defer if (network_owned) |n| gpa.free(n);
    var network_desc: []const u8 = "off";
    if (opts.network_policy) |np| {
        if (np.isActive()) {
            network_owned = if (np.domainCount() > 0)
                try std.fmt.allocPrint(gpa, "DNS blocklist active ({d} {s}, {d} blocked domains)", .{
                    np.feedCount(),
                    if (np.feedCount() == 1) @as([]const u8, "feed") else "feeds",
                    np.domainCount(),
                })
            else
                try gpa.dupe(u8, "explicit deny rules active");
            network_desc = network_owned.?;
        }
    }

    return std.fmt.allocPrint(gpa,
        \\
        \\ENVIRONMENT
        \\- Working directory: {s} ({s})
        \\- Platform: {s} ({s}) · Today's date: {d:0>4}-{d:0>2}-{d:0>2}
        \\- Shell sandbox: {s}
        \\- Network filtering: {s}
    , .{
        opts.cwd,
        git_desc,
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        sandbox_desc,
        network_desc,
    });
}

const RoundObservation = struct {
    enabled: bool,
    session_id: u64,
    turn_id: u64,
    round: u32,
    span_id: telemetry_ids.SpanId,
    request_model: []const u8,
    provider_name: []const u8,
    endpoint_url: []const u8,
    reasoning_level: []const u8,
    max_tokens: u64,
    context_load_ms: u64 = 0,
    store_wait_ms: u64 = 0,
    context_rows: u64 = 0,
    context_bytes: u64 = 0,
    context_vm_steps: u64 = 0,
    setup_ms: u64 = 0,
    assemble_ms: u64 = 0,
    body_ms: u64 = 0,
    pump: *const Pump,
    acc: *const openai.StreamAccum,
    status: []const u8 = "transport_error",
    http_status: u16 = 0,

    fn persist(self: RoundObservation, store: *Store, io: Io) void {
        if (!self.enabled) return;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const uri = std.Uri.parse(self.endpoint_url) catch null;
        const server_address = if (uri) |parsed| host: {
            const host_name = parsed.getHost(&host_buf) catch break :host "";
            break :host host_name.bytes;
        } else "";
        const server_port: u16 = if (uri) |parsed| parsed.port orelse
            if (std.ascii.eqlIgnoreCase(parsed.scheme, "http"))
                80
            else if (std.ascii.eqlIgnoreCase(parsed.scheme, "https"))
                443
            else
                0 else 0;
        store.telemetryRecordRound(self.session_id, self.turn_id, .{
            .round = self.round,
            .span_id = &self.span_id,
            .started_at_ms = self.pump.started_ms,
            .first_byte_at_ms = self.pump.first_byte_ms,
            .first_visible_at_ms = self.pump.first_visible_ms,
            .ended_at_ms = nowMs(io),
            .status = self.status,
            .http_status = self.http_status,
            .response_bytes = self.pump.bytes_total,
            .provider = self.acc.provider_name.items,
            .provider_name = self.provider_name,
            .request_model = self.request_model,
            .response_model = self.acc.response_model.items,
            .server_address = server_address,
            .server_port = server_port,
            .finish_reason = self.acc.finishReason(),
            .reasoning_level = self.reasoning_level,
            .max_tokens = self.max_tokens,
            .generation_id = self.acc.generation_id.items,
            .usage_available = self.acc.usage != null,
            .tokens_in = if (self.acc.usage) |usage| usage.tokens_in else 0,
            .tokens_out = if (self.acc.usage) |usage| usage.tokens_out else 0,
            .cached_tokens = if (self.acc.usage) |usage| usage.cached_tokens else 0,
            .cache_write_tokens = if (self.acc.usage) |usage| usage.cache_write_tokens else 0,
            .reasoning_tokens = if (self.acc.usage) |usage| usage.reasoning_tokens else 0,
            .context_load_ms = self.context_load_ms,
            .store_wait_ms = self.store_wait_ms,
            .context_rows = self.context_rows,
            .context_bytes = self.context_bytes,
            .context_vm_steps = self.context_vm_steps,
            .setup_ms = self.setup_ms,
            .assemble_ms = self.assemble_ms,
            .body_ms = self.body_ms,
        }) catch |err| std.log.warn("could not persist provider telemetry: {t}", .{err});
    }
};

/// Glue: HTTP response bytes → SSE parser → StreamAccum.
const Pump = struct {
    parser: sse.Parser,
    acc: *openai.StreamAccum,
    /// Non-null for the anthropic dialect: events route through its decoder
    /// into the same accumulator instead of the OpenAI-shape decoder.
    anthropic_stream: ?*anthropic.Stream = null,
    io: ?Io = null,
    opts: ?*const RunOpts = null,
    started_ms: i64 = 0,
    first_byte_ms: i64 = 0,
    first_visible_ms: i64 = 0,
    bytes_total: u64 = 0,
    last_visible_ms: i64 = 0,
    last_emit_ms: i64 = 0,

    fn onChunk(self: *Pump, bytes: []const u8) bool {
        if (self.first_byte_ms == 0) {
            if (self.io) |io| self.first_byte_ms = nowMs(io);
        }
        self.bytes_total += bytes.len;
        self.parser.feed(bytes, self, onEvent) catch {
            self.acc.response_too_large = true;
            return false;
        };
        self.maybeEmitStatus();
        return !self.acc.response_too_large;
    }

    fn onEvent(self: *Pump, ev: sse.Event) void {
        if (self.anthropic_stream) |stream| stream.onEvent(ev) else self.acc.onEvent(ev);
    }

    fn onVisibleText(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Pump = @ptrCast(@alignCast(ctx.?));
        self.markVisible();
        const opts = self.opts orelse return;
        if (opts.on_delta) |cb| cb(opts.on_delta_ctx, text);
    }

    fn onVisibleReasoning(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Pump = @ptrCast(@alignCast(ctx.?));
        self.markVisible();
        const opts = self.opts orelse return;
        if (opts.on_reasoning_delta) |cb| cb(opts.on_delta_ctx, text);
    }

    fn onProviderWait(ctx: ?*anyopaque, elapsed_ms: u64) void {
        const self: *Pump = @ptrCast(@alignCast(ctx.?));
        const opts = self.opts orelse return;
        if (opts.on_stream_status) |cb| cb(opts.on_delta_ctx, 0, elapsed_ms);
    }

    fn markVisible(self: *Pump) void {
        const io = self.io orelse return;
        self.last_visible_ms = nowMs(io);
        if (self.first_visible_ms == 0) self.first_visible_ms = self.last_visible_ms;
    }

    /// At most one status per second, and only while bytes actually flow —
    /// silence is the idle watchdog's business, not telemetry's.
    fn maybeEmitStatus(self: *Pump) void {
        const io = self.io orelse return;
        const opts = self.opts orelse return;
        const cb = opts.on_stream_status orelse return;
        const now = nowMs(io);
        if (now - self.last_emit_ms < 1000) return;
        self.last_emit_ms = now;
        cb(opts.on_delta_ctx, self.bytes_total, @intCast(@max(0, now - self.last_visible_ms)));
    }
};

pub const AnthropicWireChecks = struct {
    saw_api_key: bool = false,
    saw_version: bool = false,
    saw_authorization: bool = false,
    body_ok: bool = false,
};

pub const SteeringWireChecks = struct {
    requests: usize = 0,
    second_saw_first_steer: bool = false,
    third_saw_raced_steer: bool = false,
};
