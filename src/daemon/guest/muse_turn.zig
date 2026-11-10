//! GUEST turn: Muse Code. Drives `muse serve` over MSP (JSON-RPC on stdio)
//! with the user's own Meta login, persists its items as blocks, and routes
//! its approvals and questions through Marlin's picker. Same wall as
//! codex_turn.zig: loop.zig is the native agent turn; this file hosts a
//! vendor agent.
//!
//! Unlike Codex, Muse keeps working after a turn ends: subagents run as
//! background workflows, and when one finishes Muse starts a turn of its own
//! to report back. So a Marlin turn lasts until the Muse session is idle with
//! nothing left running in the background, not until the first
//! `turn/completed`.

const std = @import("std");
const guest_auth = @import("../../core/guest.zig");
const Io = std.Io;

const block = @import("../../core/block.zig");
const proto = @import("../../core/proto.zig");
const Store = @import("../store.zig").Store;
const process_io = @import("../process_io.zig");
const context = @import("../context.zig");
const permissions = @import("../permissions.zig");
const muse = @import("../provider/muse.zig");
const build_options = @import("build_options");

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
const compactDiagnostic = @import("claude_code_turn.zig").compactDiagnostic;
const compactionNote = @import("claude_code_turn.zig").compactionNote;
const setDelegateError = shared.setDelegateError;
const CcWatcher = shared.CcWatcher;
const CcStderrDrain = shared.CcStderrDrain;

const line_bytes: usize = 4 * 1024 * 1024;
/// How long a closed stdin gets to end `muse serve` before its process group
/// is signalled; it closes its sessions and records why it exited first.
const shutdown_grace_ms: u32 = 5000;
/// After a background job finishes, how long to wait for the turn Muse
/// starts to report it. A safety net: Muse starts it within a fraction of a
/// second.
const follow_up_wait_ms: i32 = 5_000;

const Teardown = struct {
    io: Io,
    watcher: *CcWatcher,
    watcher_thread: std.Thread,
    drain_thread: ?std.Thread,
    child: *std.process.Child,
    group: std.process.Child.Id,
    opts: RunOpts,
    done: bool = false,

    fn run(self: *Teardown) void {
        if (self.done) return;
        self.done = true;
        self.watcher.done.store(true, .release);
        self.watcher_thread.join();
        if (process_io.closeStdinAndReap(self.child, self.io, shutdown_grace_ms)) {
            if (self.drain_thread) |thread| thread.join();
            process_io.releaseReapedChild(self.child, self.io);
        } else {
            process_io.terminateProcessGroup(self.io, self.group, 0);
            _ = self.child.wait(self.io) catch {};
            if (self.drain_thread) |thread| thread.join();
        }
        if (self.opts.on_guest_process) |report| report(self.opts.on_delta_ctx, 0);
    }
};

fn noteServerExit(gpa: std.mem.Allocator, ap: *Appender, stderr_tail: []const u8) void {
    var note_buf: [768]u8 = undefined;
    var note: []const u8 = "muse serve exited mid-turn with no stderr output";
    if (compactDiagnostic(gpa, stderr_tail, 512)) |compact| {
        defer gpa.free(compact);
        if (compact.len > 0)
            note = std.fmt.bufPrint(&note_buf, "muse serve exited mid-turn (stderr: {s})", .{compact}) catch note;
    } else |_| {}
    setDelegateError(note);
    _ = ap.append(.{ .system_note = .{ .text = note } }) catch {};
}

/// Writes MSP messages and numbers requests. Every state-changing command
/// carries a fresh UUIDv7 `commandId`, which Muse uses for idempotency.
const Wire = struct {
    io: Io,
    writer: *Io.Writer,
    next_id: i64 = 1,

    fn line(self: *Wire, bytes: []const u8) !void {
        try self.writer.writeAll(bytes);
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }

    fn value(self: *Wire, arena: std.mem.Allocator, message: anytype) !void {
        try self.line(try std.json.Stringify.valueAlloc(arena, message, .{ .emit_null_optional_fields = false }));
    }

    fn request(self: *Wire, arena: std.mem.Allocator, comptime method: []const u8, params: anytype) !i64 {
        const id = self.next_id;
        self.next_id += 1;
        try self.value(arena, .{ .jsonrpc = "2.0", .id = id, .method = method, .params = params });
        return id;
    }

    fn commandId(self: *Wire, arena: std.mem.Allocator) ![]const u8 {
        var buf: [36]u8 = undefined;
        return arena.dupe(u8, muse.commandId(self.io, &buf));
    }

    /// The presentation receipt a server request (approval or question)
    /// expects at once; the decision follows as its own command.
    fn receipt(self: *Wire, arena: std.mem.Allocator, id_json: []const u8) !void {
        try self.line(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{}}}}", .{id_json}));
    }
};

fn waitResponse(arena: std.mem.Allocator, reader: *Io.Reader, request_id: i64) !muse.Response {
    // Arena-owned: the decoded response may point into these bytes.
    var acc: std.ArrayList(u8) = .empty;
    while (true) {
        const raw = shared.takeEventLine(reader, arena, &acc, shared.max_event_line_bytes) catch |err| switch (err) {
            error.LineTooLong => return error.MuseEventLineTooLong,
            error.ReadFailed => return error.MuseServerExited,
            error.OutOfMemory => return error.OutOfMemory,
        } orelse return error.MuseServerExited;
        const inbound = muse.decodeLine(arena, raw) catch continue;
        switch (inbound) {
            .response => |response| if (response.id == request_id) return response,
            else => {},
        }
    }
}

fn rpcError(arena: std.mem.Allocator, response: muse.Response) ?[]const u8 {
    const err_value = response.err orelse return null;
    if (muse.strField(err_value, "message")) |message|
        return if (guest_auth.isAuthFailure(message)) guest_auth.loginRequiredNote(.muse) else message;
    return muse.stringify(arena, err_value) catch "muse serve request failed";
}

fn markServerExit(exited: *bool, result: anytype) @TypeOf(result) {
    _ = result catch |err| {
        if (err == error.MuseServerExited) exited.* = true;
    };
    return result;
}

/// Blocks until the server has something to say or `timeout_ms` passes.
/// False on timeout.
fn waitReadable(reader: *Io.Reader, partial: usize, fd: std.posix.fd_t, timeout_ms: i32) bool {
    if (reader.bufferedLen() > 0 or partial > 0) return true;
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return true;
    return ready > 0;
}

/// Turn state the event loop tracks across Muse's own turns.
pub const Tracking = struct {
    gpa: std.mem.Allocator,
    /// Our Muse session: events for others (subagents' sessions) are
    /// activity, not transcript.
    session_id: []const u8 = "",
    /// Muse is in a turn (ours, a steer, or one it started itself), or one
    /// was just asked for.
    turn_running: bool = false,
    turns_completed: u32 = 0,
    /// A background job finished since the last turn began: Muse is likely
    /// to start a turn of its own to report it.
    awaiting_follow_up: bool = false,
    /// The `turn/start` request whose rejection would end this Marlin turn.
    pending_turn_request: i64 = 0,
    /// Background items (workflows, subagents) still in progress.
    background: std.StringHashMapUnmanaged(void) = .empty,
    /// Item id → kind for open items, to route their deltas.
    kinds: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Live tool output already passed on, per item.
    shown: std.StringHashMapUnmanaged(usize) = .empty,

    pub fn deinit(self: *Tracking) void {
        freeKeys(self.gpa, &self.background);
        var kinds = self.kinds.iterator();
        while (kinds.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.kinds.deinit(self.gpa);
        freeKeys(self.gpa, &self.shown);
    }

    fn freeKeys(gpa: std.mem.Allocator, map: anytype) void {
        var it = map.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        map.deinit(gpa);
    }

    pub fn open(self: *Tracking, id: []const u8, kind: []const u8) !void {
        if (self.kinds.contains(id)) return;
        const key = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(key);
        const owned_kind = try self.gpa.dupe(u8, kind);
        errdefer self.gpa.free(owned_kind);
        try self.kinds.put(self.gpa, key, owned_kind);
        if (muse.isBackgroundKind(kind) and !self.background.contains(id))
            try self.background.put(self.gpa, try self.gpa.dupe(u8, id), {});
    }

    pub fn close(self: *Tracking, id: []const u8) void {
        if (self.kinds.fetchRemove(id)) |entry| {
            self.gpa.free(entry.key);
            self.gpa.free(entry.value);
        }
        if (self.background.fetchRemove(id)) |entry| {
            self.gpa.free(entry.key);
            self.awaiting_follow_up = true;
        }
        if (self.shown.fetchRemove(id)) |entry| self.gpa.free(entry.key);
    }

    pub fn kindOf(self: *Tracking, id: []const u8) []const u8 {
        return self.kinds.get(id) orelse "";
    }

    /// The part of a cumulative output not passed on yet.
    pub fn unseen(self: *Tracking, id: []const u8, output: []const u8) ![]const u8 {
        const gop = try self.shown.getOrPut(self.gpa, id);
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, id) catch |err| {
                _ = self.shown.remove(id);
                return err;
            };
            gop.value_ptr.* = 0;
        }
        const from = @min(gop.value_ptr.*, output.len);
        gop.value_ptr.* = output.len;
        return output[from..];
    }

    /// Muse is between turns with nothing running in the background; only
    /// a follow-up turn of its own, or the user, starts more work.
    pub fn idle(self: *const Tracking) bool {
        return !self.turn_running and self.background.count() == 0;
    }
};

pub fn runMuseTurn(
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

    if (opts.guest_compact != null) {
        // Muse compacts its own context as it fills; an explicit request
        // needs its compaction events mapped first.
        _ = try ap.append(.{ .system_note = .{ .text = "Muse Code compacts its context on its own; /compact is not available for Muse sessions yet" } });
        return .{ .text = try gpa.dupe(u8, ""), .rounds = 0, .tokens_in = 0, .tokens_out = 0 };
    }

    var guest_environ: ?std.process.Environ.Map = if (opts.tool_environ) |source|
        try permissions.toolEnvironment(gpa, source)
    else
        null;
    defer if (guest_environ) |*map| map.deinit();
    const argv = [_][]const u8{ muse.binaryPath(opts.tool_environ), "serve" };
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = if (guest_environ) |*map| map else null,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        const note = try shared.spawnErrorNote(arena, io, opts.cwd, err, .muse);
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateSpawnFailed;
    };
    if (opts.on_guest_process) |report| report(opts.on_delta_ctx, @intCast(child.id.?));

    var watcher = CcWatcher.init(io, opts.cancel, child.id.?, opts.park_clock, opts.cfg.guest_max_runtime_ms);
    watcher.max_runtime_live = opts.guest_max_runtime_live;
    const watcher_thread = try std.Thread.spawn(.{}, CcWatcher.run, .{&watcher});
    var drain = CcStderrDrain{ .io = io, .file = child.stderr.? };
    const drain_thread = std.Thread.spawn(.{}, CcStderrDrain.run, .{&drain}) catch null;
    var teardown = Teardown{
        .io = io,
        .watcher = &watcher,
        .watcher_thread = watcher_thread,
        .drain_thread = drain_thread,
        .child = &child,
        .group = child.id.?,
        .opts = opts,
    };
    defer teardown.run();
    var server_exited = false;
    errdefer if (server_exited and
        !watcher.cancelled.load(.acquire) and !watcher.timed_out.load(.acquire))
    {
        teardown.run();
        noteServerExit(gpa, ap, drain.tail[0..drain.len]);
    };

    var writer_buffer: [64 * 1024]u8 = undefined;
    var writer_file = child.stdin.?.writer(io, &writer_buffer);
    var wire = Wire{ .io = io, .writer = &writer_file.interface };
    const line_buffer = try gpa.alloc(u8, line_bytes);
    defer gpa.free(line_buffer);
    var reader_file = child.stdout.?.reader(io, line_buffer);
    const reader = &reader_file.interface;
    const stdout_fd = child.stdout.?.handle;

    const init_id = try wire.request(arena, "initialize", .{
        .clientInfo = .{ .name = "marlin", .title = "Marlin", .version = build_options.version },
        .capabilities = .{ .userInputDialogs = true },
    });
    const initialized = try markServerExit(&server_exited, waitResponse(arena, reader, init_id));
    if (rpcError(arena, initialized)) |message| {
        setDelegateError(message);
        _ = try ap.append(.{ .system_note = .{ .text = message } });
        return error.DelegateFailed;
    }
    try wire.value(arena, .{ .jsonrpc = "2.0", .method = "initialized" });

    const profile_id = muse.permissionProfile(opts.tool_profile == .full, effectiveApprovalMode(opts) == .auto);
    const model_id = muse.modelId(opts.endpoint.model);
    var session_id: []const u8 = "";
    const saved_session = try store.getMuseSessionId(opts.session_id);
    defer if (saved_session) |saved| gpa.free(saved);
    if (saved_session) |saved| {
        const resume_id = try wire.request(arena, "session/resume", .{
            .commandId = try wire.commandId(arena),
            .sessionId = saved,
            .permissionProfile = profile_id,
            .modelId = model_id,
            .excludeItems = true,
        });
        const resumed = try markServerExit(&server_exited, waitResponse(arena, reader, resume_id));
        if (rpcError(arena, resumed)) |message| {
            if (guest_auth.isAuthFailure(message)) {
                setDelegateError(message);
                _ = try ap.append(.{ .system_note = .{ .text = message } });
                return error.DelegateFailed;
            }
            // The session may have been deleted outside Marlin: start over.
            try store.setMuseSessionId(opts.session_id, null);
        } else {
            session_id = saved;
        }
    }
    if (session_id.len == 0) {
        const start_id = try wire.request(arena, "session/start", .{
            .commandId = try wire.commandId(arena),
            .workspaceRoot = opts.cwd,
            .permissionProfile = profile_id,
            .modelId = model_id,
        });
        const started = try markServerExit(&server_exited, waitResponse(arena, reader, start_id));
        if (rpcError(arena, started)) |message| {
            setDelegateError(message);
            _ = try ap.append(.{ .system_note = .{ .text = message } });
            return error.DelegateFailed;
        }
        const result = started.result orelse return error.BadMuseResponse;
        const session = muse.field(result, "session") orelse return error.BadMuseResponse;
        session_id = try arena.dupe(u8, muse.strField(session, "sessionId") orelse return error.BadMuseResponse);
        try store.setMuseSessionId(opts.session_id, session_id);
    }

    const prompt = blk: {
        var history: std.ArrayList(block.Block) = .empty;
        store.loadContextBlocksInto(arena, &history, opts.session_id, 1_000_000) catch {};
        break :blk try context.guestPrompt(arena, history.items, first_text);
    };
    var tracking = Tracking{ .gpa = gpa, .session_id = session_id };
    defer tracking.deinit();
    try sendTurn(arena, &wire, opts, &tracking, prompt);
    var activity = guest_activity.Tracker.init(gpa, opts.on_guest_activity, opts.on_delta_ctx);
    defer activity.deinit();

    var rounds: u32 = 1;
    var tokens_in: u64 = 0;
    var tokens_out: u64 = 0;
    var final_text: std.ArrayList(u8) = .empty;
    defer final_text.deinit(gpa);
    var failed = false;
    var interrupted = false;
    var failure_text: []const u8 = "Muse turn failed";
    var auth_failed = false;

    var line_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer line_arena_state.deinit();
    var line_acc: std.ArrayList(u8) = .empty;
    defer line_acc.deinit(gpa);
    events: while (true) {
        if (tracking.idle()) {
            // Finished background work is reported in a turn Muse starts
            // itself; give it the moment it needs before ending.
            const follow_up = tracking.awaiting_follow_up and
                waitReadable(reader, line_acc.items.len, stdout_fd, follow_up_wait_ms);
            if (!follow_up) {
                tracking.awaiting_follow_up = false;
                if (try takeSteer(gpa, arena, &wire, opts, ap, &tracking)) {
                    rounds += 1;
                    final_text.clearRetainingCapacity();
                    continue;
                }
                if (!tryCloseSteering(opts)) continue;
                break;
            }
        }

        const raw = shared.takeEventLine(reader, gpa, &line_acc, shared.max_event_line_bytes) catch |err| switch (err) {
            error.LineTooLong => {
                _ = try ap.append(.{ .system_note = .{ .text = "muse: one event line exceeded 64 MiB and was dropped" } });
                continue;
            },
            error.ReadFailed => break,
            error.OutOfMemory => return error.OutOfMemory,
        } orelse break;
        _ = line_arena_state.reset(.retain_capacity);
        const line_arena = line_arena_state.allocator();
        const inbound = muse.decodeLine(line_arena, raw) catch continue;
        switch (inbound) {
            .response => |response| {
                if (rpcError(line_arena, response)) |message| {
                    setDelegateError(message);
                    failure_text = try arena.dupe(u8, message);
                    if (response.id == tracking.pending_turn_request) {
                        failed = true;
                        break :events;
                    }
                }
            },
            .request => |request| try handleRequest(gpa, io, line_arena, &wire, opts, ap, session_id, request),
            .notification => |notification| {
                const params = notification.params;
                const own = std.mem.eql(u8, muse.strField(params, "sessionId") orelse session_id, session_id);
                const method = notification.method;
                if (std.mem.eql(u8, method, "turn/started")) {
                    if (!own) continue;
                    tracking.turn_running = true;
                    tracking.awaiting_follow_up = false;
                    publishPhase(opts, .provider);
                } else if (std.mem.eql(u8, method, "turn/completed")) {
                    if (!own) continue;
                    tracking.turn_running = false;
                    tracking.turns_completed += 1;
                    const terminal = muse.strField(params, "terminal") orelse "completed";
                    if (std.mem.eql(u8, terminal, "cancelled")) interrupted = true;
                    if (std.mem.eql(u8, terminal, "failed")) {
                        failed = true;
                        if (muse.field(params, "error")) |err_value| {
                            if (muse.isAuthError(err_value)) auth_failed = true;
                            if (muse.strField(err_value, "message")) |message| {
                                failure_text = try arena.dupe(u8, message);
                                if (guest_auth.isAuthFailure(message)) auth_failed = true;
                            }
                        } else if (muse.strField(params, "reason")) |reason| {
                            failure_text = try arena.dupe(u8, reason);
                        }
                        break :events;
                    }
                } else if (std.mem.eql(u8, method, "turn/foregroundCompleted")) {
                    if (own) publishPhase(opts, .finishing);
                } else if (std.mem.eql(u8, method, "item/started") or
                    std.mem.eql(u8, method, "item/updated") or
                    std.mem.eql(u8, method, "item/completed"))
                {
                    const item = muse.field(params, "item") orelse continue;
                    const phase: ItemPhase = if (std.mem.eql(u8, method, "item/started"))
                        .started
                    else if (std.mem.eql(u8, method, "item/updated"))
                        .updated
                    else
                        .completed;
                    if (!own) {
                        try childItem(&activity, item, muse.strField(params, "sessionId") orelse "", phase, nowMs(io));
                        continue;
                    }
                    if (try handleItem(gpa, line_arena, ap, opts, &tracking, &activity, item, phase, nowMs(io))) |text| {
                        final_text.clearRetainingCapacity();
                        try final_text.appendSlice(gpa, text);
                    }
                } else if (std.mem.eql(u8, method, "item/delta")) {
                    const item_id = muse.strField(params, "itemId") orelse continue;
                    const delta = muse.strField(params, "delta") orelse continue;
                    if (!own) {
                        try activity.appendOutput(muse.strField(params, "sessionId") orelse continue, delta);
                        continue;
                    }
                    const field_path = muse.strField(params, "field") orelse "text";
                    const kind = tracking.kindOf(item_id);
                    if (std.mem.eql(u8, kind, "agentMessage") and std.mem.eql(u8, field_path, "text")) {
                        if (opts.on_delta) |callback| callback(opts.on_delta_ctx, delta);
                    } else if (std.mem.eql(u8, kind, "reasoning")) {
                        if (opts.on_reasoning_delta) |callback| callback(opts.on_delta_ctx, delta);
                    } else if (std.mem.eql(u8, field_path, "output")) {
                        try activity.appendOutput(item_id, delta);
                    }
                } else if (std.mem.eql(u8, method, "session/tokenUsage")) {
                    if (!own) continue;
                    const usage = muse.field(params, "usage") orelse continue;
                    tokens_in += @intCast(@max(0, muse.intField(usage, "inputTokens") orelse 0));
                    tokens_out += @intCast(@max(0, muse.intField(usage, "outputTokens") orelse 0));
                } else if (std.mem.eql(u8, method, "session/contextUsage")) {
                    if (!own) continue;
                    if (muse.intField(params, "usedTokens")) |used| if (opts.context_used_out) |out|
                        out.store(@intCast(@max(0, used)), .release);
                    if (muse.intField(params, "windowTokens")) |window| if (window > 0) if (opts.context_limit_out) |out|
                        out.store(@intCast(window), .release);
                }
            },
        }
        if (tracking.turn_running) {
            if (try takeSteer(gpa, arena, &wire, opts, ap, &tracking)) rounds += 1;
        }
    }

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
        const note = try shared.deadlineNote(gpa, "muse", watcher.timed_out_runtime_ms);
        defer gpa.free(note);
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateTimeout;
    }
    if (failed or tracking.turns_completed == 0) {
        if (tracking.turns_completed == 0 and !failed) {
            server_exited = true;
            return error.MuseServerExited;
        }
        const note = if (auth_failed)
            try gpa.dupe(u8, guest_auth.loginRequiredNote(.muse))
        else
            try std.fmt.allocPrint(gpa, "Muse request failed: {s}. Your Muse session is saved and continues with your next message.", .{failure_text});
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

/// Ask Muse for a turn, or, while one runs, add the text to it.
fn sendTurn(arena: std.mem.Allocator, wire: *Wire, opts: RunOpts, tracking: *Tracking, text: []const u8) !void {
    const steer = tracking.turn_running;
    tracking.pending_turn_request = try wire.request(arena, "turn/start", .{
        .commandId = try wire.commandId(arena),
        .sessionId = tracking.session_id,
        .input = .{.{ .type = "text", .text = text }},
        .reasoningEffort = muse.reasoningEffort(opts.effort),
        .ifBusy = if (steer) @as(?[]const u8, "steer") else null,
    });
    tracking.turn_running = true;
}

/// Hand Muse one queued user message, if any.
fn takeSteer(gpa: std.mem.Allocator, arena: std.mem.Allocator, wire: *Wire, opts: RunOpts, ap: *Appender, tracking: *Tracking) !bool {
    const poll = opts.poll_steer orelse return false;
    const text = poll(opts.on_delta_ctx, gpa) orelse return false;
    defer text.deinit(gpa);
    _ = try ap.append(.{ .steer = text });
    try sendTurn(arena, wire, opts, tracking, text.text);
    return true;
}

const ItemPhase = enum { started, updated, completed };

/// One of our session's items. Returns the text of a final answer.
fn handleItem(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ap: *Appender,
    opts: RunOpts,
    tracking: *Tracking,
    activity: *guest_activity.Tracker,
    item: std.json.Value,
    phase: ItemPhase,
    now_ms: i64,
) !?[]const u8 {
    const id = muse.strField(item, "itemId") orelse return null;
    const kind = muse.strField(item, "kind") orelse return null;
    if (phase != .completed) try tracking.open(id, kind);
    defer if (phase == .completed) tracking.close(id);

    if (std.mem.eql(u8, kind, "agentMessage")) {
        if (phase != .completed) return null;
        const text = muse.strField(item, "text") orelse return null;
        if (text.len == 0) return null;
        const final = std.mem.eql(u8, muse.strField(item, "messagePhase") orelse "finalAnswer", "finalAnswer");
        if (!final) {
            _ = try ap.append(.{ .reasoning = .{ .text = text, .commentary = true } });
            return null;
        }
        _ = try ap.append(.{ .assistant_msg = .{ .text = text } });
        return text;
    }
    if (std.mem.eql(u8, kind, "reasoning")) {
        if (phase != .completed) return null;
        const text = muse.strField(item, "text") orelse muse.strField(item, "summary") orelse return null;
        if (text.len > 0) _ = try ap.append(.{ .reasoning = .{ .text = text } });
        return null;
    }
    if (std.mem.eql(u8, kind, "toolCall")) {
        try toolCall(gpa, arena, ap, opts, tracking, activity, item, id, phase, now_ms);
        return null;
    }
    if (std.mem.eql(u8, kind, "subagent")) {
        const agent_id = muse.strField(item, "subagentId") orelse id;
        if (phase == .completed or muse.subagentDone(item)) {
            activity.finish(agent_id);
        } else if (!activity.contains(agent_id)) {
            const detail = muse.strField(item, "objective") orelse muse.strField(item, "fallbackText") orelse "";
            try activity.start(agent_id, "", .agent, muse.strField(item, "role") orelse "Agent", detail, now_ms);
        }
        return null;
    }
    if (std.mem.eql(u8, kind, "workflow")) {
        if (phase == .completed) {
            activity.finish(id);
            // Its subagents are done with it, whatever their items say.
            if (muse.field(item, "children")) |children| if (children == .array) for (children.array.items) |child| {
                if (muse.strField(child, "childId")) |child_id| activity.finish(child_id);
            };
        } else if (!activity.contains(id)) {
            const detail = muse.strField(item, "entryId") orelse muse.strField(item, "fallbackText") orelse "";
            try activity.start(id, "", .agent, "Workflow", detail, now_ms);
        }
        return null;
    }
    if (std.mem.eql(u8, kind, "compaction")) {
        if (phase == .completed)
            _ = try ap.append(.{ .system_note = .{ .text = try compactionNote(arena, "Muse Code", "auto", 0, null) } });
        return null;
    }
    // userMessage is already in the transcript; reminderChild items are
    // Muse's own background observers; anything newer is not shown yet.
    return null;
}

fn toolCall(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ap: *Appender,
    opts: RunOpts,
    tracking: *Tracking,
    activity: *guest_activity.Tracker,
    item: std.json.Value,
    id: []const u8,
    phase: ItemPhase,
    now_ms: i64,
) !void {
    const tool = muse.strField(item, "tool") orelse "tool";
    const name = muse.toolName(tool);
    const call_id = muse.strField(item, "callId") orelse id;
    switch (phase) {
        .started => {
            const args = muse.strField(item, "args") orelse "{}";
            const persisted_args = (try permissions.redactSecrets(arena, opts.secrets, args)) orelse args;
            _ = try ap.append(.{ .tool_call = .{ .call_id = call_id, .name = name, .args_json = persisted_args } });
            if (opts.on_tool) |callback| callback(opts.on_delta_ctx, name, .start);
            try activity.start(id, "", if (std.mem.eql(u8, tool, "bash")) .process else .tool, name, toolDetail(arena, args), now_ms);
        },
        .updated => {
            const output = muse.strField(item, "visibleOutput") orelse return;
            const fresh = try tracking.unseen(id, output);
            if (fresh.len > 0) try activity.appendOutput(id, fresh);
        },
        .completed => {
            activity.finish(id);
            const raw_body = muse.toolOutput(arena, muse.strField(item, "visibleOutput") orelse "");
            const redacted = try permissions.redactSecrets(gpa, opts.secrets, raw_body);
            defer if (redacted) |value| gpa.free(value);
            const body = redacted orelse raw_body;
            const status = muse.strField(item, "status") orelse "completed";
            _ = try ap.append(.{ .tool_result = .{
                .call_id = call_id,
                .status = if (std.mem.eql(u8, status, "completed")) .ok else .err,
                .inline_body = body[0..@min(body.len, opts.cfg.inline_tool_cap_bytes)],
                .full_body_ref = null,
            } });
            if (opts.on_tool) |callback| callback(opts.on_delta_ctx, name, .done);
        },
    }
}

fn toolDetail(arena: std.mem.Allocator, args: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, args, .{}) catch return "";
    inline for (.{ "description", "command", "path", "query", "url", "name" }) |key| {
        if (muse.strField(parsed, key)) |value| if (value.len > 0) return value;
    }
    return "";
}

/// A subagent session's item: activity under that subagent, not transcript.
fn childItem(activity: *guest_activity.Tracker, item: std.json.Value, child_session: []const u8, phase: ItemPhase, now_ms: i64) !void {
    const kind = muse.strField(item, "kind") orelse return;
    if (!std.mem.eql(u8, kind, "toolCall")) {
        if (phase == .completed and std.mem.eql(u8, kind, "agentMessage"))
            try activity.appendOutput(child_session, "\n");
        return;
    }
    const id = muse.strField(item, "itemId") orelse return;
    switch (phase) {
        .started => try activity.start(id, child_session, .tool, muse.toolName(muse.strField(item, "tool") orelse "tool"), "", now_ms),
        .updated => {},
        .completed => activity.finish(id),
    }
}

/// Muse asks the client: approvals and questions. Each is acknowledged at
/// once with a receipt, then decided by a separate command.
fn handleRequest(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    wire: *Wire,
    opts: RunOpts,
    ap: *Appender,
    session_id: []const u8,
    request: anytype,
) !void {
    const params = request.params;
    if (std.mem.eql(u8, request.method, "approval/request")) {
        try wire.receipt(arena, request.id_json);
        try decideApproval(gpa, io, arena, wire, opts, ap, session_id, params);
    } else if (std.mem.eql(u8, request.method, "userInput/request")) {
        try wire.receipt(arena, request.id_json);
        try answerQuestions(gpa, io, arena, wire, opts, session_id, params);
    } else {
        try wire.line(try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32601,\"message\":\"unsupported request\"}}}}", .{request.id_json}));
    }
}

fn decideApproval(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    wire: *Wire,
    opts: RunOpts,
    ap: *Appender,
    session_id: []const u8,
    params: std.json.Value,
) !void {
    const approval_id = muse.strField(params, "approvalId") orelse return;
    const requirement = muse.field(params, "currentRequirementId") orelse return;
    const tool = muse.toolName(muse.strField(params, "toolName") orelse "tool");
    const call_id = muse.strField(params, "toolCallId") orelse approval_id;
    const args = muse.strField(params, "rawArgs") orelse "{}";
    const verdict = try resolveGuestApproval(gpa, io, opts, ap, call_id, tool, args);
    const choices = muse.field(params, "availableChoices") orelse return;
    const choice = pickChoice(choices, verdict == .approved) orelse return;
    _ = try wire.request(arena, "approval/decide", .{
        .commandId = try wire.commandId(arena),
        .sessionId = session_id,
        .approvalId = approval_id,
        .requirementId = requirement,
        .choiceId = choice,
    });
}

/// The choice matching a one-off decision: approve this once, or deny it
/// (falling back to Muse's "Reject", which aborts the action).
pub fn pickChoice(choices: std.json.Value, approve: bool) ?[]const u8 {
    if (choices != .array) return null;
    const wanted: []const []const u8 = if (approve) &.{"approved"} else &.{ "denied", "abort" };
    for (wanted) |decision| {
        for (choices.array.items) |choice| {
            if (!std.mem.eql(u8, muse.strField(choice, "decision") orelse "", decision)) continue;
            if (approve and !std.mem.eql(u8, muse.strField(choice, "scope") orelse "once", "once")) continue;
            return muse.strField(choice, "choiceId");
        }
    }
    return null;
}

/// Muse's own question tool, asked one question at a time in Marlin's
/// picker. An answer that is an option's label selects it; anything else
/// the user typed goes back as free text.
fn answerQuestions(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    wire: *Wire,
    opts: RunOpts,
    session_id: []const u8,
    params: std.json.Value,
) !void {
    const prompt_id = muse.strField(params, "userInputId") orelse return;
    const questions = muse.field(params, "questions") orelse return;
    if (questions != .array) return;
    var answers: std.ArrayList(std.json.Value) = .empty;
    for (questions.array.items) |question| {
        const question_id = muse.strField(question, "id") orelse continue;
        var labels: std.ArrayList([]const u8) = .empty;
        if (muse.field(question, "options")) |options| if (options == .array) for (options.array.items) |option| {
            if (muse.strField(option, "label")) |label| try labels.append(arena, label);
        };
        const text = muse.strField(question, "question") orelse "";
        const args = try std.json.Stringify.valueAlloc(arena, .{ .question = text, .options = labels.items }, .{});
        const out = loop.runAskUser(gpa, io, opts, args);
        defer gpa.free(out.output);
        if (out.status != .ok) {
            _ = try wire.request(arena, "userInput/cancel", .{
                .commandId = try wire.commandId(arena),
                .sessionId = session_id,
                .userInputId = prompt_id,
                .reason = out.output,
            });
            return;
        }
        var answer: std.json.ObjectMap = .empty;
        try answer.put(arena, "questionId", .{ .string = question_id });
        const picked = for (labels.items) |label| {
            if (std.mem.eql(u8, label, out.output)) break label;
        } else null;
        const multiple = if (muse.field(question, "selection")) |selection|
            std.mem.eql(u8, muse.strField(selection, "mode") orelse "single", "multiple")
        else
            false;
        if (picked) |label| {
            if (multiple) {
                var one: std.json.Array = .init(arena);
                try one.append(.{ .string = label });
                try answer.put(arena, "selectedLabels", .{ .array = one });
            } else try answer.put(arena, "selectedLabel", .{ .string = label });
        } else {
            try answer.put(arena, "freeText", .{ .string = try arena.dupe(u8, out.output[0..@min(out.output.len, 500)]) });
        }
        try answers.append(arena, .{ .object = answer });
    }
    _ = try wire.request(arena, "userInput/answer", .{
        .commandId = try wire.commandId(arena),
        .sessionId = session_id,
        .userInputId = prompt_id,
        .answers = answers.items,
    });
}
