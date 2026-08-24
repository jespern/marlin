//! The agent turn loop (docs/ARCHITECTURE.md §4). M0: in-process, blocking,
//! auto-approve, deltas printed by a caller-supplied sink. The daemon-thread
//! version (steer queue, interrupt flag, parallel tools) lands in M1.

const std = @import("std");
const Io = std.Io;

const block = @import("../core/block.zig");
const ids = @import("../core/ids.zig");
const jsonx = @import("../core/jsonx.zig");
const config = @import("../core/config.zig");
const Store = @import("store.zig").Store;
const context = @import("context.zig");
const approval = @import("approval.zig");
const provider = @import("provider/provider.zig");
const openai = @import("provider/openai_compat.zig");
const http = @import("provider/http.zig");
const sse = @import("provider/sse.zig");
const tools_registry = @import("tools/registry.zig");

pub const Endpoint = struct {
    url: [:0]const u8, // .../chat/completions
    bearer: ?[]const u8,
    model: []const u8, // provider-native model string
};

pub const ToolPhase = enum { start, done };

pub const RunOpts = struct {
    session_id: u64,
    cwd: []const u8,
    endpoint: Endpoint,
    cfg: config.Config,
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
        const msgs = try context.assemble(arena, blocks);

        var tools: [tools_registry.specs.len]openai.ToolSpec = undefined;
        for (&tools_registry.specs, 0..) |*s, ti| {
            tools[ti] = .{ .name = s.name, .description = s.description, .schema_json = s.schema_json };
        }

        const body = try openai.buildRequestBody(arena, opts.endpoint.model, msgs, &tools);

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

        // -- execute tool calls (serial in M2; parallel_safe grouping later) --
        for (acc.calls.items) |*pc| {
            const args_repaired = jsonx.repairObject(gpa, pc.args.items) catch pc.args.items;
            defer if (args_repaired.ptr != pc.args.items.ptr) gpa.free(@constCast(args_repaired));

            _ = try ap.append(.{ .tool_call = .{
                .call_id = pc.call_id.items,
                .name = pc.name.items,
                .args_json = args_repaired,
            } });

            // -- approval gate: EVERY execution flows through here --
            const spec = tools_registry.find(pc.name.items);
            const decision: approval.Decision = if (spec) |s|
                approval.policyFor(opts.cfg, opts.approval_mode, s.mutating)
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
                        exec = runTool(gpa, io, opts, pc.name.items, args_repaired);
                    }
                },
                .run => {
                    exec = runTool(gpa, io, opts, pc.name.items, args_repaired);
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

fn runTool(gpa: std.mem.Allocator, io: Io, opts: RunOpts, name: []const u8, args_json: []const u8) tools_registry.ExecOut {
    if (opts.on_tool) |cb| cb(opts.on_delta_ctx, name, .start);
    defer if (opts.on_tool) |cb| cb(opts.on_delta_ctx, name, .done);
    return tools_registry.dispatch(gpa, io, name, args_json, opts.cwd, opts.cancel);
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
