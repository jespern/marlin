//! The agent turn loop (docs/ARCHITECTURE.md §4): context assembly, provider
//! streaming, approval-gated tools, steering, compaction, and cancellation.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const block = @import("../core/block.zig");
const proto = @import("../core/proto.zig");
const ids = @import("../core/ids.zig");
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
const http = @import("provider/http.zig");
const sse = @import("provider/sse.zig");
const tools_registry = @import("tools/registry.zig");
const task_tool = @import("tools/task.zig");
const bash_tool = @import("tools/bash.zig");
const files_tool = @import("tools/files.zig");
const Effort = @import("../core/effort.zig").Effort;

pub const Endpoint = struct {
    url: [:0]const u8, // .../chat/completions
    bearer: ?[]const u8,
    model: []const u8, // provider-native model string
    dialect: provider.Dialect,
};

pub const ToolPhase = enum { start, done };
pub const ToolProfile = enum { full, read_only };

pub const RunOpts = struct {
    session_id: u64,
    cwd: []const u8,
    endpoint: Endpoint,
    /// Daemon-owned HTTP connection pool shared across provider rounds.
    http_pool: ?*http.Pool = null,
    effort: Effort = .auto,
    cfg: config.Config,
    /// Daemon-owned environment. Tool subprocesses receive a scrubbed copy;
    /// provider credentials never cross the daemon boundary.
    tool_environ: ?*const std.process.Environ.Map = null,
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
    /// Read-only child sessions advertise only non-mutating tools and never
    /// advertise task, preventing recursive delegation in the first M6 cut.
    tool_profile: ToolProfile = .full,
    /// Called after EVERY block is persisted (daemon fan-out). The block's
    /// memory is only valid during the callback.
    on_block: ?*const fn (ctx: ?*anyopaque, b: block.Block) void = null,
    /// Cooperative cancellation: checked between rounds and threaded into
    /// the HTTP layer. When set mid-stream the turn ends with .interrupted.
    cancel: ?*std.atomic.Value(bool) = null,
    /// Steer poll: return queued mid-turn user text (caller allocs w/ gpa;
    /// loop frees). Checked between rounds; injected as a steer block.
    poll_steer: ?*const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 = null,
    max_rounds: u32 = 32,
};

pub const TurnResult = struct {
    /// Final assistant text (allocated; caller frees).
    text: []u8,
    rounds: u32,
    tokens_in: u64,
    tokens_out: u64,
    interrupted: bool = false,
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
        return self.appendMaybeBlob(body, null);
    }

    fn appendWithBlob(self: *Appender, body: block.Body, hash: []const u8, bytes: []const u8) !u64 {
        return self.appendMaybeBlob(body, .{ .hash = hash, .bytes = bytes });
    }

    const BlobPayload = struct { hash: []const u8, bytes: []const u8 };

    fn appendMaybeBlob(self: *Appender, body: block.Body, blob_payload: ?BlobPayload) !u64 {
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
        if (blob_payload) |blob_value|
            try self.store.appendBlockWithBlob(b, blob_value.hash, blob_value.bytes)
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
            .synthetic = value.synthetic,
        } },
        .assistant_msg => |value| .{ .assistant_msg = .{ .text = try arena.dupe(u8, value.text) } },
        .reasoning => |value| .{ .reasoning = .{ .text = try arena.dupe(u8, value.text) } },
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
        } },
        .approval => |value| .{ .approval = .{
            .approval_id = try arena.dupe(u8, value.approval_id),
            .call_id = try arena.dupe(u8, value.call_id),
            .decision = value.decision,
            .decided_by = if (value.decided_by) |client| try arena.dupe(u8, client) else null,
        } },
        .steer => |value| .{ .steer = .{ .text = try arena.dupe(u8, value.text) } },
        .compaction => |value| .{ .compaction = .{
            .summary = try arena.dupe(u8, value.summary),
            .covers_from_seq = value.covers_from_seq,
            .covers_to_seq = value.covers_to_seq,
        } },
        .system_note => |value| .{ .system_note = .{ .text = try arena.dupe(u8, value.text) } },
    };
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
) !TurnResult {
    var history_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer history_arena_state.deinit();
    const history_arena = history_arena_state.allocator();
    var history: std.ArrayList(block.Block) = .empty;
    try store.loadContextBlocksInto(history_arena, &history, opts.session_id, 1_000_000);

    var ap = Appender{
        .store = store,
        .io = io,
        .opts = &opts,
        .seq = try store.lastSeq(opts.session_id),
        .turn_id = ids.next(io),
        .history = &history,
        .history_arena = history_arena,
    };

    var http_client = if (opts.http_pool) |pool| try pool.acquire() else try http.Client.init(gpa, io);
    defer http_client.deinit();

    _ = try ap.append(.{ .user_msg = .{ .text = user_text } });

    // System-prompt context built once per turn: repo-local instructions and
    // the dynamic environment (cwd, git, date, sandbox/network regime).
    const project_instructions = projectInstructions(gpa, io, opts.cwd);
    defer if (project_instructions) |pi| gpa.free(pi);
    const environment: ?[]u8 = environmentBlock(gpa, io, &opts) catch null;
    defer if (environment) |env| gpa.free(env);

    var total_in: u64 = 0;
    var total_out: u64 = 0;
    var round: u32 = 0;

    while (round < opts.max_rounds) : (round += 1) {
        publishPhase(opts, .context);
        // -- cancellation checkpoint --
        if (cancelled(opts.cancel)) {
            _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{ .text = try gpa.dupe(u8, ""), .rounds = round, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
        }
        // -- steer checkpoint: inject queued mid-turn user text --
        if (opts.poll_steer) |poll| {
            while (poll(opts.on_delta_ctx, gpa)) |steer_text| {
                defer gpa.free(steer_text);
                _ = try ap.append(.{ .steer = .{ .text = steer_text } });
            }
        }

        // -- assemble context from the turn-local append-only history --
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var blocks = history.items;

        const frontier: u64 = if (opts.prune_frontier) |pf| pf.* else 0;
        const system_prompt_suffix = if (opts.extensions) |ext| ext.systemPromptSuffix() else "";
        var asm_opts = context.AssembleOpts{
            .prune_before_seq = frontier,
            .system_prompt_suffix = system_prompt_suffix,
            .project_instructions = project_instructions orelse "",
            .environment = environment orelse "",
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

        const body = try openai.buildRequestBody(
            arena,
            opts.endpoint.model,
            opts.endpoint.dialect,
            opts.effort,
            msgs,
            tools,
            try providerRequestOptions(arena, opts, opts.endpoint),
        );

        // -- stream the response --
        var acc = openai.StreamAccum.init(gpa);
        defer acc.deinit();

        var pump = Pump{
            .parser = sse.Parser.init(gpa),
            .acc = &acc,
            .io = io,
            .opts = &opts,
            .started_ms = nowMs(io),
        };
        pump.last_visible_ms = pump.started_ms;
        pump.last_emit_ms = pump.started_ms;
        defer pump.parser.deinit();
        // Visible deltas route through the pump so it can stamp liveness
        // before chaining to the caller's callbacks.
        acc.on_delta = Pump.onVisibleText;
        acc.on_reasoning_delta = Pump.onVisibleReasoning;
        acc.on_delta_ctx = &pump;

        publishPhase(opts, .provider);
        const resp = http_client.streamPost(gpa, .{
            .url = opts.endpoint.url,
            .bearer = opts.endpoint.bearer,
            .body_json = body,
            .extra_headers = observabilityHeaders(opts.endpoint.dialect),
            .cancel = opts.cancel,
            .on_wait = Pump.onProviderWait,
            .on_wait_ctx = &pump,
        }, &pump, Pump.onChunk) catch |e| switch (e) {
            error.Cancelled => {
                _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
                try store.updateSessionUsage(opts.session_id, total_in, total_out);
                return .{ .text = try gpa.dupe(u8, ""), .rounds = round, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
            },
            error.ConsumerAborted => if (acc.response_too_large)
                return error.ProviderResponseTooLarge
            else
                return e,
            else => return e,
        };

        if (resp.status >= 400) {
            const eb = resp.error_body orelse try gpa.dupe(u8, "");
            defer gpa.free(eb);
            const msg = try providerErrorNote(gpa, resp.status, eb);
            defer gpa.free(msg);
            _ = try ap.append(.{ .system_note = .{ .text = msg } });
            return error.ProviderError;
        }
        acc.flushDeltas();

        if (acc.usage) |u| {
            total_in += u.tokens_in;
            total_out += u.tokens_out;
            if (opts.endpoint.dialect == .openrouter) {
                std.log.debug(
                    "OpenRouter generation {s} via {s}: input={d} cached={d} cache_write={d} output={d} reasoning={d}",
                    .{
                        if (acc.generation_id.items.len > 0) acc.generation_id.items else "unknown",
                        if (acc.provider_name.items.len > 0) acc.provider_name.items else "unknown",
                        u.tokens_in,
                        u.cached_tokens,
                        u.cache_write_tokens,
                        u.tokens_out,
                        u.reasoning_tokens,
                    },
                );
            }
        }

        // Provider-surfaced reasoning is useful liveness and durable context
        // for the human transcript, but is intentionally not sent back to the
        // model by context assembly.
        if (acc.reasoning.items.len > 0) {
            _ = try ap.append(.{ .reasoning = .{ .text = acc.reasoning.items } });
        }

        // -- no tool calls → final answer --
        if (acc.calls.items.len == 0) {
            publishPhase(opts, .finishing);
            _ = try ap.append(.{ .assistant_msg = .{ .text = acc.text.items } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{
                .text = try gpa.dupe(u8, acc.text.items),
                .rounds = round + 1,
                .tokens_in = total_in,
                .tokens_out = total_out,
            };
        }

        // Text emitted alongside tool calls is user-facing progress commentary,
        // not the final answer. Persist it so the TUI does not briefly stream a
        // useful update and then erase it when the tool round starts.
        if (acc.text.items.len > 0) {
            _ = try ap.append(.{ .reasoning = .{ .text = acc.text.items } });
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

            const tool_call_block_id = try ap.append(.{ .tool_call = .{
                .call_id = pc.call_id.items,
                .name = pc.name.items,
                .args_json = args_owned,
            } });

            const spec = tools_registry.find(pc.name.items) orelse
                if (opts.extensions) |ext| ext.find(pc.name.items) else null;
            prepared[i] = .{
                .call_id = pc.call_id.items,
                .name = pc.name.items,
                .args_json = args_owned,
                .tool_call_block_id = tool_call_block_id,
                .spec = spec,
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
            var sandboxed = opts.sandbox_options.backend == .seatbelt and
                std.mem.eql(u8, call.name, bash_tool.spec_name);
            if (!sandboxed and opts.sandbox_options.backend == .seatbelt and
                (std.mem.eql(u8, call.name, files_tool.write_spec_name) or
                    std.mem.eql(u8, call.name, files_tool.edit_spec_name)))
            {
                sandboxed = permissions.workspaceWriteAllowed(gpa, io, opts.cwd, call.args_json);
            }
            const decision: approval.Decision = if (call.spec) |s|
                if (opts.tool_profile == .read_only and s.mutating)
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
        try executePrepared(gpa, io, opts, prepared);

        // Results stay in provider call order even when execution completed
        // out of order. The transcript is therefore deterministic and valid.
        for (prepared) |*call| {
            const exec = call.exec.?;

            // Blob the full output when it exceeds the inline cap.
            const cap: usize = opts.cfg.inline_tool_cap_bytes;
            var full_ref: ?[]const u8 = null;
            defer if (full_ref) |r| gpa.free(@constCast(r));
            if (exec.output.len > cap) full_ref = try Store.blobHashAlloc(gpa, exec.output);
            const inline_body = try context.capInline(gpa, exec.output, cap);
            defer if (inline_body.ptr != exec.output.ptr) gpa.free(@constCast(inline_body));

            const result_body: block.Body = .{ .tool_result = .{
                .call_id = call.call_id,
                .status = exec.status,
                .inline_body = inline_body,
                .full_body_ref = full_ref,
            } };
            _ = if (full_ref) |hash|
                try ap.appendWithBlob(result_body, hash, exec.output)
            else
                try ap.append(result_body);
        }
        // Loop: next round re-assembles including the new tool results.
    }

    // Running out of round budget on a long task is an end-of-turn, not an
    // error: the session stays usable and a plain "continue" resumes with
    // full context. The note is durable; the returned text feeds task
    // children their partial-result contract.
    _ = try ap.append(.{ .system_note = .{ .text = "round budget reached — say 'continue' to keep going" } });
    try store.updateSessionUsage(opts.session_id, total_in, total_out);
    return .{
        .text = try gpa.dupe(u8, "[round budget reached before a final answer; partial work is in the transcript]"),
        .rounds = round,
        .tokens_in = total_in,
        .tokens_out = total_out,
    };
}

/// The mode consulted per call: the session's live value when wired (so a
/// mid-turn /permissions switch affects the very next call), else the
/// turn-start snapshot.
fn effectiveApprovalMode(opts: RunOpts) approval.Mode {
    const live = opts.approval_mode_live orelse return opts.approval_mode;
    return @enumFromInt(live.load(.acquire));
}

fn cancelled(flag: ?*std.atomic.Value(bool)) bool {
    const f = flag orelse return false;
    return f.load(.acquire);
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

/// One non-tool provider round: transcript in, summary text out.
/// Allocated into `arena`.
fn summarize(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    http_client: *http.Client,
    ep: Endpoint,
    transcript: []const u8,
    cancel: ?*std.atomic.Value(bool),
    request_opts: openai.RequestOptions,
) ![]const u8 {
    var msgs = [_]provider.Message{
        .{ .role = .system, .payload = .{ .text = context.compaction_prompt } },
        .{ .role = .user, .payload = .{ .text = transcript } },
    };
    const body = try openai.buildRequestBody(arena, ep.model, ep.dialect, .auto, &msgs, &.{}, request_opts);

    var acc = openai.StreamAccum.init(gpa);
    defer acc.deinit();
    var pump = Pump{ .parser = sse.Parser.init(gpa), .acc = &acc };
    defer pump.parser.deinit();

    const resp = http_client.streamPost(gpa, .{
        .url = ep.url,
        .bearer = ep.bearer,
        .body_json = body,
        .extra_headers = observabilityHeaders(ep.dialect),
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

fn toolAllowed(opts: RunOpts, spec: *const tools_registry.Spec) bool {
    if (std.mem.eql(u8, spec.name, task_tool.spec_name)) return opts.on_task != null and opts.tool_profile == .full;
    if (opts.tool_profile == .read_only and spec.mutating) return false;
    return true;
}

fn providerRequestOptions(arena: std.mem.Allocator, opts: RunOpts, ep: Endpoint) !openai.RequestOptions {
    if (ep.dialect != .openrouter) return .{};
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

fn observabilityHeaders(dialect: provider.Dialect) []const []const u8 {
    return if (dialect == .openrouter) &openrouter_observability_headers else &.{};
}

fn runTool(gpa: std.mem.Allocator, io: Io, opts: RunOpts, parent_block_id: u64, name: []const u8, args_json: []const u8) tools_registry.ExecOut {
    if (opts.on_tool) |cb| cb(opts.on_delta_ctx, name, .start);
    defer if (opts.on_tool) |cb| cb(opts.on_delta_ctx, name, .done);
    if (std.mem.eql(u8, name, task_tool.spec_name)) {
        if (opts.on_task) |cb| return cb(opts.on_delta_ctx, parent_block_id, args_json);
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

const PreparedCall = struct {
    call_id: []const u8,
    name: []const u8,
    args_json: []u8,
    tool_call_block_id: u64,
    spec: ?*const tools_registry.Spec,
    exec: ?tools_registry.ExecOut = null,

    fn deinit(self: *PreparedCall, gpa: std.mem.Allocator) void {
        gpa.free(self.args_json);
        if (self.exec) |result| gpa.free(result.output);
        self.* = undefined;
    }

    fn parallelSafe(self: PreparedCall) bool {
        return self.spec != null and self.spec.?.parallel_safe;
    }
};

const ToolWorker = struct {
    fn run(gpa: std.mem.Allocator, io: Io, opts: RunOpts, call: *PreparedCall) void {
        call.exec = runTool(gpa, io, opts, call.tool_call_block_id, call.name, call.args_json);
    }
};

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
        try threads.ensureTotalCapacity(gpa, end - i);
        for (calls[i..end]) |*call| {
            const thread = std.Thread.spawn(.{}, ToolWorker.run, .{ gpa, io, opts, call }) catch {
                ToolWorker.run(gpa, io, opts, call);
                continue;
            };
            threads.appendAssumeCapacity(thread);
        }
        for (threads.items) |thread| thread.join();
        i = end;
    }
}

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
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
        .seatbelt => "active (kernel-enforced; workspace shell commands run without approval prompts)",
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

/// Glue: curl chunk → SSE parser → StreamAccum.
const Pump = struct {
    parser: sse.Parser,
    acc: *openai.StreamAccum,
    io: ?Io = null,
    opts: ?*const RunOpts = null,
    started_ms: i64 = 0,
    bytes_total: u64 = 0,
    last_visible_ms: i64 = 0,
    last_emit_ms: i64 = 0,

    fn onChunk(self: *Pump, bytes: []const u8) bool {
        self.bytes_total += bytes.len;
        self.parser.feed(bytes, self, onEvent) catch {
            self.acc.response_too_large = true;
            return false;
        };
        self.maybeEmitStatus();
        return !self.acc.response_too_large;
    }

    fn onEvent(self: *Pump, ev: sse.Event) void {
        self.acc.onEvent(ev);
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
        .endpoint = .{ .url = "http://unused", .bearer = null, .model = "m", .dialect = .openai_compatible },
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

test {
    std.testing.refAllDecls(@This());
}
