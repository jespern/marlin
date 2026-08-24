//! The agent turn loop (docs/ARCHITECTURE.md §4): context assembly, provider
//! streaming, approval-gated tools, steering, compaction, and cancellation.

const std = @import("std");
const Io = std.Io;

const block = @import("../core/block.zig");
const ids = @import("../core/ids.zig");
const jsonx = @import("../core/jsonx.zig");
const config = @import("../core/config.zig");
const Store = @import("store.zig").Store;
const context = @import("context.zig");
const approval = @import("approval.zig");
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
    /// Session approval mode (default: mutating tools ask).
    approval_mode: approval.Mode = .auto,
    /// Gate the turn parks on while a client decides. Required when
    /// approval_mode may produce `ask` decisions.
    gate: ?*approval.Gate = null,
    /// Called when an `ask` decision needs a client answer, BEFORE parking.
    /// The callback must deliver approval_request to clients (and flip the
    /// session status to awaiting_approval). `id` is the approval id.
    on_approval_needed: ?*const fn (ctx: ?*anyopaque, id: u64, call_id: []const u8, tool: []const u8, args_json: []const u8) void = null,
    /// Called after the gate resolves (status back to running).
    on_approval_done: ?*const fn (ctx: ?*anyopaque, id: u64, verdict: approval.Verdict) void = null,
    /// Called with streaming assistant text for UI liveness.
    on_delta: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
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

/// Bundles the repetitive persist-then-notify step.
const Appender = struct {
    store: *Store,
    io: Io,
    opts: *const RunOpts,
    seq: u64,
    turn_id: u64,

    fn append(self: *Appender, body: block.Body) !u64 {
        self.seq += 1;
        const b = block.Block{
            .id = ids.next(self.io),
            .session_id = self.opts.session_id,
            .turn_id = self.turn_id,
            .seq = self.seq,
            .ts = nowMs(self.io),
            .body = body,
        };
        try self.store.appendBlock(b);
        if (self.opts.on_block) |cb| cb(self.opts.on_delta_ctx, b);
        return b.id;
    }
};

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
    var ap = Appender{
        .store = store,
        .io = io,
        .opts = &opts,
        .seq = try store.lastSeq(opts.session_id),
        .turn_id = ids.next(io),
    };

    _ = try ap.append(.{ .user_msg = .{ .text = user_text } });

    var total_in: u64 = 0;
    var total_out: u64 = 0;
    var round: u32 = 0;

    while (round < opts.max_rounds) : (round += 1) {
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

        // -- assemble context from the full block log (arena per request) --
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const loaded = try store.getBlocks(opts.session_id, 1, 1_000_000);
        defer {
            for (loaded) |*lb| lb.deinit();
            gpa.free(loaded);
        }
        var blocks = try arena.alloc(block.Block, loaded.len);
        for (loaded, 0..) |lb, i| blocks[i] = lb.blk;

        const frontier: u64 = if (opts.prune_frontier) |pf| pf.* else 0;
        const system_prompt_suffix = if (opts.extensions) |ext| ext.systemPromptSuffix() else "";
        var msgs = try context.assemble(arena, blocks, .{
            .prune_before_seq = frontier,
            .system_prompt_suffix = system_prompt_suffix,
        });

        // -- L2 headroom check (turn boundary = before each request) --
        var est_used = context.estimateAssembled(msgs);
        if (context.needsCompaction(est_used, opts.endpoint.model, opts.cfg)) {
            if (try maybeCompact(gpa, io, arena, &ap, opts, blocks, .auto)) {
                // Re-load + re-assemble on top of the new compaction block.
                const loaded2 = try store.getBlocks(opts.session_id, 1, 1_000_000);
                defer {
                    for (loaded2) |*lb| lb.deinit();
                    gpa.free(loaded2);
                }
                blocks = try arena.alloc(block.Block, loaded2.len);
                for (loaded2, 0..) |lb, i| blocks[i] = lb.blk;
                msgs = try context.assemble(arena, blocks, .{
                    .prune_before_seq = frontier,
                    .system_prompt_suffix = system_prompt_suffix,
                });
            } else if (opts.prune_frontier) |pf| {
                // Compaction not possible (session too small / no progress):
                // fall back to L1 pruning if it can reclaim enough.
                if (context.planPrune(blocks, pf.*, opts.cfg.prune_protect_tokens, opts.cfg.prune_min_reclaim_tokens)) |new_frontier| {
                    pf.* = new_frontier;
                    _ = try ap.append(.{ .system_note = .{ .text = "context pruned (L1): old tool outputs elided" } });
                    msgs = try context.assemble(arena, blocks, .{
                        .prune_before_seq = new_frontier,
                        .system_prompt_suffix = system_prompt_suffix,
                    });
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
                    msgs = try context.assemble(arena, blocks, .{
                        .prune_before_seq = new_frontier,
                        .system_prompt_suffix = system_prompt_suffix,
                    });
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
        );

        // -- stream the response --
        var acc = openai.StreamAccum.init(gpa);
        defer acc.deinit();
        acc.on_delta = opts.on_delta;
        acc.on_delta_ctx = opts.on_delta_ctx;

        var pump = Pump{ .parser = sse.Parser.init(gpa), .acc = &acc };
        defer pump.parser.deinit();

        const resp = http.streamPost(gpa, .{
            .url = opts.endpoint.url,
            .bearer = opts.endpoint.bearer,
            .body_json = body,
            .cancel = opts.cancel,
        }, &pump, Pump.onChunk) catch |e| switch (e) {
            error.Cancelled => {
                _ = try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
                try store.updateSessionUsage(opts.session_id, total_in, total_out);
                return .{ .text = try gpa.dupe(u8, ""), .rounds = round, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
            },
            else => return e,
        };

        if (resp.status >= 400) {
            const eb = resp.error_body orelse try gpa.dupe(u8, "");
            defer gpa.free(eb);
            const msg = try std.fmt.allocPrint(gpa, "provider returned HTTP {d}: {s}", .{ resp.status, eb[0..@min(eb.len, 2000)] });
            defer gpa.free(msg);
            _ = try ap.append(.{ .system_note = .{ .text = msg } });
            return error.ProviderError;
        }

        if (acc.usage) |u| {
            total_in += u.tokens_in;
            total_out += u.tokens_out;
        }

        // -- no tool calls → final answer --
        if (acc.calls.items.len == 0) {
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

        // -- execute tool calls (serial in M2; parallel_safe grouping later) --
        for (acc.calls.items) |*pc| {
            const args_repaired = jsonx.repairObject(gpa, pc.args.items) catch pc.args.items;
            defer if (args_repaired.ptr != pc.args.items.ptr) gpa.free(@constCast(args_repaired));

            const tool_call_block_id = try ap.append(.{ .tool_call = .{
                .call_id = pc.call_id.items,
                .name = pc.name.items,
                .args_json = args_repaired,
            } });

            // -- approval gate: EVERY execution flows through here --
            const spec = tools_registry.find(pc.name.items) orelse
                if (opts.extensions) |ext| ext.find(pc.name.items) else null;
            // Auto-inside (docs/PERMISSIONS.md): a shell call that will
            // execute under the canary-verified kernel sandbox needs no
            // per-call prompt — the sandbox enforces the write scope and
            // protected paths the prompt was guarding. Direct write/edit
            // tools bypass the kernel sandbox and keep asking until
            // symlink-safe direct-tool enforcement lands.
            const sandboxed = opts.sandbox_options.backend == .seatbelt and
                std.mem.eql(u8, pc.name.items, bash_tool.spec_name);
            const decision: approval.Decision = if (spec) |s|
                if (opts.tool_profile == .read_only and s.mutating)
                    .deny
                else
                    approval.policyFor(opts.cfg, opts.approval_mode, s.mutating, sandboxed)
            else
                .run; // unknown tool → dispatch returns error text anyway

            var exec: tools_registry.ExecOut = undefined;
            switch (decision) {
                .deny => {
                    exec = .{
                        .output = try gpa.dupe(u8, "error: tool denied by session policy"),
                        .status = .denied,
                    };
                },
                .ask => {
                    const approval_id = ids.next(io);
                    const id_str = try std.fmt.allocPrint(gpa, "{d}", .{approval_id});
                    defer gpa.free(id_str);

                    if (opts.on_approval_needed) |cb|
                        cb(opts.on_delta_ctx, approval_id, pc.call_id.items, pc.name.items, args_repaired);

                    const verdict: approval.Verdict = if (opts.gate) |g|
                        g.wait(io, approval_id, opts.cancel)
                    else
                        .approved; // no gate wired (tests) → auto

                    if (opts.on_approval_done) |cb| cb(opts.on_delta_ctx, approval_id, verdict);

                    _ = try ap.append(.{ .approval = .{
                        .approval_id = id_str,
                        .call_id = pc.call_id.items,
                        .decision = switch (verdict) {
                            .approved => .granted,
                            .denied => .denied,
                        },
                        .decided_by = null,
                    } });

                    if (verdict == .denied) {
                        // Interrupt while parked also lands here; surface both.
                        const was_cancel = cancelled(opts.cancel);
                        exec = .{
                            .output = try gpa.dupe(u8, if (was_cancel)
                                "error: tool call interrupted by user"
                            else
                                "error: tool call denied by user"),
                            .status = if (was_cancel) .interrupted else .denied,
                        };
                    } else {
                        exec = runTool(gpa, io, opts, tool_call_block_id, pc.name.items, args_repaired);
                    }
                },
                .run => {
                    exec = runTool(gpa, io, opts, tool_call_block_id, pc.name.items, args_repaired);
                },
            }
            defer gpa.free(exec.output);

            // Blob the full output when it exceeds the inline cap.
            const cap: usize = opts.cfg.inline_tool_cap_bytes;
            var full_ref: ?[]const u8 = null;
            defer if (full_ref) |r| gpa.free(@constCast(r));
            if (exec.output.len > cap) full_ref = try store.putBlob(exec.output, nowMs(io));
            const inline_body = try context.capInline(gpa, exec.output, cap);
            defer if (inline_body.ptr != exec.output.ptr) gpa.free(@constCast(inline_body));

            const tr_block_id = try ap.append(.{ .tool_result = .{
                .call_id = pc.call_id.items,
                .status = exec.status,
                .inline_body = inline_body,
                .full_body_ref = full_ref,
            } });
            if (full_ref) |r| try store.addBlobRef(r, tr_block_id);
        }
        // Loop: next round re-assembles including the new tool results.
    }

    return error.TooManyRounds;
}

fn cancelled(flag: ?*std.atomic.Value(bool)) bool {
    const f = flag orelse return false;
    return f.load(.acquire);
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
    opts: RunOpts,
    blocks: []const block.Block,
    trigger: CompactTrigger,
) !bool {
    const plan = context.planCompaction(blocks) orelse {
        if (trigger == .manual) {
            _ = try ap.append(.{ .system_note = .{ .text = "nothing to compact (session too small or no progress since last compaction)" } });
        }
        return false;
    };

    const transcript = try context.renderForSummary(arena, blocks, plan.from_seq, plan.to_seq, 400_000);
    const ep = opts.compaction_endpoint orelse opts.endpoint;

    const summary = summarize(gpa, arena, ep, transcript, opts.cancel) catch |e| {
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
        _ = try ap.append(.{ .system_note = .{ .text = "rehydrated file state after compaction" } });
        _ = try ap.append(.{ .user_msg = .{ .text = note } });
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
    ep: Endpoint,
    transcript: []const u8,
    cancel: ?*std.atomic.Value(bool),
) ![]const u8 {
    var msgs = [_]provider.Message{
        .{ .role = .system, .payload = .{ .text = context.compaction_prompt } },
        .{ .role = .user, .payload = .{ .text = transcript } },
    };
    const body = try openai.buildRequestBody(arena, ep.model, ep.dialect, .auto, &msgs, &.{});

    var acc = openai.StreamAccum.init(gpa);
    defer acc.deinit();
    var pump = Pump{ .parser = sse.Parser.init(gpa), .acc = &acc };
    defer pump.parser.deinit();

    const resp = try http.streamPost(gpa, .{
        .url = ep.url,
        .bearer = ep.bearer,
        .body_json = body,
        .cancel = cancel,
    }, &pump, Pump.onChunk);
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
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const loaded = try store.getBlocks(opts.session_id, 1, 1_000_000);
    defer {
        for (loaded) |*lb| lb.deinit();
        gpa.free(loaded);
    }
    const blocks = try arena.alloc(block.Block, loaded.len);
    for (loaded, 0..) |lb, i| blocks[i] = lb.blk;

    var ap = Appender{
        .store = store,
        .io = io,
        .opts = &opts,
        .seq = try store.lastSeq(opts.session_id),
        .turn_id = ids.next(io),
    };
    return maybeCompact(gpa, io, arena, &ap, opts, blocks, .manual);
}

fn toolAllowed(opts: RunOpts, spec: *const tools_registry.Spec) bool {
    if (std.mem.eql(u8, spec.name, task_tool.spec_name)) return opts.on_task != null and opts.tool_profile == .full;
    if (opts.tool_profile == .read_only and spec.mutating) return false;
    return true;
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
        if (ext.dispatch(name, args_json, opts.cwd)) |result| return result;
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

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

/// Glue: curl chunk → SSE parser → StreamAccum.
const Pump = struct {
    parser: sse.Parser,
    acc: *openai.StreamAccum,

    fn onChunk(self: *Pump, bytes: []const u8) void {
        self.parser.feed(bytes, self.acc, onEvent) catch {};
    }

    fn onEvent(acc: *openai.StreamAccum, ev: sse.Event) void {
        acc.onEvent(ev);
    }
};

test {
    std.testing.refAllDecls(@This());
}
