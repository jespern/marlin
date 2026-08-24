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
const provider = @import("provider/provider.zig");
const openai = @import("provider/openai_compat.zig");
const http = @import("provider/http.zig");
const sse = @import("provider/sse.zig");
const bash = @import("tools/bash.zig");
const files = @import("tools/files.zig");

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

    fn append(self: *Appender, body: block.Body) !void {
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

    try ap.append(.{ .user_msg = .{ .text = user_text } });

    var total_in: u64 = 0;
    var total_out: u64 = 0;
    var round: u32 = 0;

    while (round < opts.max_rounds) : (round += 1) {
        // -- cancellation checkpoint --
        if (cancelled(opts.cancel)) {
            try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{ .text = try gpa.dupe(u8, ""), .rounds = round, .tokens_in = total_in, .tokens_out = total_out, .interrupted = true };
        }
        // -- steer checkpoint: inject queued mid-turn user text --
        if (opts.poll_steer) |poll| {
            while (poll(opts.on_delta_ctx, gpa)) |steer_text| {
                defer gpa.free(steer_text);
                try ap.append(.{ .steer = .{ .text = steer_text } });
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

        const tools = [_]openai.ToolSpec{
            .{ .name = bash.spec_name, .description = bash.spec_description, .schema_json = bash.spec_schema },
            .{ .name = files.read_spec_name, .description = files.read_spec_description, .schema_json = files.read_spec_schema },
        };

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
                try ap.append(.{ .system_note = .{ .text = "turn interrupted by user" } });
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
            try ap.append(.{ .system_note = .{ .text = msg } });
            return error.ProviderError;
        }

        if (acc.usage) |u| {
            total_in += u.tokens_in;
            total_out += u.tokens_out;
        }

        // -- no tool calls → final answer --
        if (acc.calls.items.len == 0) {
            try ap.append(.{ .assistant_msg = .{ .text = acc.text.items } });
            try store.updateSessionUsage(opts.session_id, total_in, total_out);
            return .{
                .text = try gpa.dupe(u8, acc.text.items),
                .rounds = round + 1,
                .tokens_in = total_in,
                .tokens_out = total_out,
            };
        }

        // -- execute tool calls (serial in M0) --
        for (acc.calls.items) |*pc| {
            const args_repaired = jsonx.repairObject(gpa, pc.args.items) catch pc.args.items;
            defer if (args_repaired.ptr != pc.args.items.ptr) gpa.free(@constCast(args_repaired));

            try ap.append(.{ .tool_call = .{
                .call_id = pc.call_id.items,
                .name = pc.name.items,
                .args_json = args_repaired,
            } });

            if (opts.on_tool) |cb| cb(opts.on_delta_ctx, pc.name.items, .start);
            const exec = executeTool(gpa, io, pc.name.items, args_repaired, opts.cwd);
            if (opts.on_tool) |cb| cb(opts.on_delta_ctx, pc.name.items, .done);
            defer gpa.free(exec.output);

            // Blob the full output when it exceeds the inline cap.
            const cap: usize = opts.cfg.inline_tool_cap_bytes;
            var full_ref: ?[]const u8 = null;
            defer if (full_ref) |r| gpa.free(@constCast(r));
            if (exec.output.len > cap) full_ref = try store.putBlob(exec.output);
            const inline_body = try context.capInline(gpa, exec.output, cap);
            defer if (inline_body.ptr != exec.output.ptr) gpa.free(@constCast(inline_body));

            try ap.append(.{ .tool_result = .{
                .call_id = pc.call_id.items,
                .status = exec.status,
                .inline_body = inline_body,
                .full_body_ref = full_ref,
            } });
        }
        // Loop: next round re-assembles including the new tool results.
    }

    return error.TooManyRounds;
}

fn cancelled(flag: ?*std.atomic.Value(bool)) bool {
    const f = flag orelse return false;
    return f.load(.acquire);
}

const ExecOut = struct {
    output: []u8,
    status: block.ToolStatus,
};

fn executeTool(gpa: std.mem.Allocator, io: Io, name: []const u8, args_json: []const u8, cwd: []const u8) ExecOut {
    if (std.mem.eql(u8, name, bash.spec_name)) {
        const parsed = std.json.parseFromSlice(bash.Args, gpa, args_json, .{ .ignore_unknown_fields = true }) catch {
            return argError(gpa, args_json);
        };
        defer parsed.deinit();
        const r = bash.run(gpa, io, parsed.value, cwd) catch |e| {
            return .{ .output = errText(gpa, e), .status = .err };
        };
        if (r.exit_code != 0) {
            const with_code = std.fmt.allocPrint(gpa, "{s}\n[exit code: {d}]", .{ r.output, r.exit_code }) catch
                return .{ .output = r.output, .status = .err };
            gpa.free(r.output);
            return .{ .output = with_code, .status = .err };
        }
        return .{ .output = r.output, .status = .ok };
    }
    if (std.mem.eql(u8, name, files.read_spec_name)) {
        const parsed = std.json.parseFromSlice(files.ReadArgs, gpa, args_json, .{ .ignore_unknown_fields = true }) catch {
            return argError(gpa, args_json);
        };
        defer parsed.deinit();
        const out = files.readFile(gpa, io, parsed.value, cwd) catch |e| {
            return .{ .output = errText(gpa, e), .status = .err };
        };
        const is_err = std.mem.startsWith(u8, out, "error:");
        return .{ .output = out, .status = if (is_err) .err else .ok };
    }
    const msg = std.fmt.allocPrint(gpa, "error: unknown tool '{s}'", .{name}) catch @panic("oom");
    return .{ .output = msg, .status = .err };
}

fn argError(gpa: std.mem.Allocator, args_json: []const u8) ExecOut {
    const msg = std.fmt.allocPrint(
        gpa,
        "error: could not parse tool arguments as JSON. Got: {s}\nRe-issue the call with valid JSON matching the schema.",
        .{args_json[0..@min(args_json.len, 500)]},
    ) catch @panic("oom");
    return .{ .output = msg, .status = .err };
}

fn errText(gpa: std.mem.Allocator, e: anyerror) []u8 {
    return std.fmt.allocPrint(gpa, "error: {t}", .{e}) catch @panic("oom");
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
