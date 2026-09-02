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

fn publishPhase(opts: RunOpts, phase: proto.TurnPhase) void {
    if (opts.on_phase) |cb| cb(opts.on_delta_ctx, phase);
}

/// Bundles the repetitive persist-then-notify step.
const Appender = struct {
    store: *Store,
    io: Io,
    opts: *const RunOpts,
    seq: u64,
    turn_id: u64,
    history: ?*std.ArrayList(block.Block) = null,
    history_arena: ?std.mem.Allocator = null,

    fn append(self: *Appender, body: block.Body) !u64 {
        return self.appendWithBlobs(body, &.{});
    }

    fn appendWithBlob(self: *Appender, body: block.Body, hash: []const u8, bytes: []const u8) !u64 {
        return self.appendWithBlobs(body, &.{.{ .hash = hash, .bytes = bytes }});
    }

    fn appendWithBlobs(self: *Appender, body: block.Body, blobs: []const Store.BlobPayload) !u64 {
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
fn skippedPlanCompletion(items: []const block.PlanItem, history: []const block.Block) ?[]const u8 {
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

fn enforcePlanTransitions(
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

fn stampPlanTimings(
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

fn loadMedia(ctx: *const anyopaque, allocator: std.mem.Allocator, hash: []const u8) ![]const u8 {
    const store: *const Store = @ptrCast(@alignCast(ctx));
    return store.getBlobAlloc(allocator, hash);
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
fn effectiveApprovalMode(opts: RunOpts) approval.Mode {
    const live = opts.approval_mode_live orelse return opts.approval_mode;
    return @enumFromInt(live.load(.acquire));
}

/// Guest agents ask only after their own sandbox/policy requires escalation.
/// Treat that request as mutating at Marlin's boundary and resolve it through
/// the same durable gate and UI used by native tool calls.
fn resolveGuestApproval(
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

fn cancelled(flag: ?*std.atomic.Value(bool)) bool {
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

fn tryCloseSteering(opts: RunOpts) bool {
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
fn providerErrorNote(allocator: std.mem.Allocator, status: i64, body: []const u8) ![]u8 {
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

// ---------------------------------------------------- claude code turns --

/// Wall-clock ceiling for one delegated invocation; Claude Code has its own
/// internal turn management, this only prevents an unkillable zombie run.
const claude_code_deadline_ms: i64 = 60 * 60 * 1000;

/// Failure detail for the most recent Delegate* error on THIS thread,
/// mirroring http.lastTransportCause: Zig errors carry no payload, and a
/// bare "DelegateFailed" reaching the user is a shrug where a diagnosis
/// ("claude code error: Not logged in · Please run /login") exists.
threadlocal var delegate_error_buf: [256]u8 = undefined;
threadlocal var delegate_error_len: usize = 0;

pub fn lastDelegateErrorNote() ?[]const u8 {
    return if (delegate_error_len == 0) null else delegate_error_buf[0..delegate_error_len];
}

fn setDelegateError(text: []const u8) void {
    delegate_error_len = @min(text.len, delegate_error_buf.len);
    @memcpy(delegate_error_buf[0..delegate_error_len], text[0..delegate_error_len]);
}

const CcWatcher = struct {
    io: Io,
    cancel: ?*const std.atomic.Value(bool),
    group: std.posix.pid_t,
    deadline_at: i64,
    done: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),

    fn run(w: *CcWatcher) void {
        while (!w.done.load(.acquire)) {
            const cancel_hit = if (w.cancel) |c| c.load(.acquire) else false;
            const deadline_hit = nowMs(w.io) >= w.deadline_at;
            if (cancel_hit or deadline_hit) {
                if (cancel_hit) w.cancelled.store(true, .release);
                if (deadline_hit) w.timed_out.store(true, .release);
                process_io.terminateProcessGroup(w.io, w.group, 500);
                return;
            }
            w.io.sleep(.fromMilliseconds(200), .awake) catch return;
        }
    }
};

const CcStderrDrain = struct {
    io: Io,
    file: Io.File,
    tail: [4096]u8 = undefined,
    len: usize = 0,

    fn run(d: *CcStderrDrain) void {
        var buf: [4096]u8 = undefined;
        var reader = d.file.reader(d.io, &buf);
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch return;
            const room = d.tail.len - d.len;
            const n = @min(room, line.len);
            @memcpy(d.tail[d.len .. d.len + n], line[0..n]);
            d.len += n;
        }
    }
};

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

/// Put a key only when the parent environment didn't set it — the operator's
/// own value always wins over Marlin's pass-down defaults.
fn putEnvDefault(map: *std.process.Environ.Map, key: []const u8, value: []const u8) bool {
    if (map.get(key) != null) return true;
    map.put(key, value) catch return false;
    return true;
}

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
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch break;
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
fn runClaudeCodeTurn(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    opts: RunOpts,
    ap: *Appender,
    first_text: []const u8,
    fresh_first: bool,
) !TurnResult {
    delegate_error_len = 0; // no stale detail from an earlier turn on this thread
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

// ----------------------------------------------------------- codex guest --

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

fn codexAccountError(account_result: std.json.Value) ?[]const u8 {
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

fn runCodexTurn(
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    opts: RunOpts,
    ap: *Appender,
    first_text: []const u8,
) !TurnResult {
    delegate_error_len = 0;
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
    while (!done) {
        const line = reader.takeDelimiterInclusive('\n') catch break;
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

/// Summaries are bounded prose, not agent output; a fixed budget keeps the
/// anthropic max_tokens requirement independent of the session's headroom.
const summary_max_tokens: u64 = 8192;

/// One non-tool provider round: transcript in, summary text out.
/// Allocated into `arena`. `stream_opts` fans visible deltas to the TUI
/// when the caller wants the user to watch (native→guest handover).
fn summarize(
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

fn toolAllowed(opts: RunOpts, spec: *const tools_registry.Spec) bool {
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

const openrouter_web_search_prompt =
    \\WEB SEARCH
    \\- Web search is available for discovering sources and verifying current
    \\  information. Use `fetch` when you already have a specific URL. Preserve
    \\  source URLs in the response.
    \\- Before invoking web search, emit a brief user-visible progress note
    \\  naming the search target. Never search silently.
;

test "OpenRouter web search requires visible progress" {
    try std.testing.expect(std.mem.indexOf(u8, openrouter_web_search_prompt, "user-visible progress note") != null);
    try std.testing.expect(std.mem.indexOf(u8, openrouter_web_search_prompt, "Never search silently") != null);
}

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

fn runTaskBatch(
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

const max_parallel_tool_workers: usize = 8;

fn parallelChunkEnd(start: usize, group_end: usize) usize {
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

fn nowMs(io: Io) i64 {
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
fn projectInstructions(gpa: std.mem.Allocator, io: Io, cwd: []const u8) ?[]u8 {
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
fn environmentBlock(gpa: std.mem.Allocator, io: Io, opts: *const RunOpts) ![]u8 {
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

const AnthropicWireChecks = struct {
    saw_api_key: bool = false,
    saw_version: bool = false,
    saw_authorization: bool = false,
    body_ok: bool = false,
};

const SteeringWireChecks = struct {
    requests: usize = 0,
    second_saw_first_steer: bool = false,
    third_saw_raced_steer: bool = false,
};

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

test {
    std.testing.refAllDecls(@This());
}
