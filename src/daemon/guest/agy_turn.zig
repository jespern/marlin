//! GUEST turn: Antigravity (`agy acp`: Gemini 4 Neon and the other models a
//! Google sign-in offers). Speaks the Agent Client Protocol over stdio under
//! the user's own sign-in: one agy conversation per Marlin session, resumed
//! each turn without replay; Marlin's own tools passed per session; every
//! permission prompt answered by Marlin's approval policy (agy stays in its
//! asking mode, so Marlin is the one gate). Same wall as codex_turn.zig:
//! loop.zig is the native agent turn; this file hosts a vendor agent.
//!
//! Like Codex's app-server, each turn's `agy acp` runs under a keeper
//! (keeper.zig) and lives through a daemon restart: the successor replays
//! its journal to where the predecessor stopped reading, then goes live.

const std = @import("std");
const guest_auth = @import("../../core/guest.zig");
const Io = std.Io;

const block = @import("../../core/block.zig");
const Store = @import("../store.zig").Store;
const process_io = @import("../process_io.zig");
const context = @import("../context.zig");
const permissions = @import("../permissions.zig");
const claude_code = @import("../provider/claude_code.zig");
const agy = @import("../provider/agy.zig");
const build_options = @import("build_options");

const loop = @import("../loop.zig");
const profile = @import("../profile.zig");
const Appender = loop.Appender;
const RunOpts = loop.RunOpts;
const TurnResult = loop.TurnResult;
const cancelled = loop.cancelled;
const nowMs = loop.nowMs;
const publishPhase = loop.publishPhase;
const resolveGuestApproval = loop.resolveGuestApproval;
const tryCloseSteering = loop.tryCloseSteering;

const shared = @import("shared.zig");
const kept_mod = @import("kept.zig");
const Kept = kept_mod.Kept;
const guest_activity = @import("activity.zig");
const agy_watch = @import("agy_watch.zig");
const compactDiagnostic = @import("claude_code_turn.zig").compactDiagnostic;
const compactionNote = @import("claude_code_turn.zig").compactionNote;
const setDelegateError = shared.setDelegateError;
const CcWatcher = shared.CcWatcher;
const CcStderrDrain = shared.CcStderrDrain;

const line_bytes: usize = 4 * 1024 * 1024;
/// How long a closed stdin gets to end `agy acp` before its process group
/// is signalled; it saves the conversation on the way out.
const shutdown_grace_ms: u32 = 2000;
/// ACP's "authentication required".
const auth_required_code: i64 = -32000;
/// While waiting on background work, wake cadence to notice queued steers or
/// subagents that finished on disk.
const background_poll_ms: i32 = 500;
/// After a background subagent finishes on disk, how long to wait for agy to
/// start its reactive wakeup (matches muse_turn.zig).
pub const follow_up_wait_ms: i64 = 5_000;
/// After `usage_update` in a reactive wakeup (no RPC response marks its end),
/// how long to wait for a follow-up `tool_call` before finishing the turn.
const reactive_settle_ms: i32 = 1_500;

/// Idempotent teardown shared by the happy path and the error path, which
/// must join the stderr drain before reading its tail (as codex_turn.zig).
const Teardown = struct {
    io: Io,
    watcher: *CcWatcher,
    watcher_thread: ?std.Thread,
    drain_thread: ?std.Thread,
    child: ?*std.process.Child,
    /// A kept server: its keeper reaps it (the turn removes its journal).
    kept: ?*Kept = null,
    group: std.process.Child.Id,
    done: bool = false,

    fn run(self: *Teardown) void {
        if (self.done) return;
        self.done = true;
        self.watcher.done.store(true, .release);
        if (self.watcher_thread) |t| t.join();
        if (self.kept) |k| {
            k.closeStdin();
            if (!k.waitExit(shutdown_grace_ms)) _ = k.terminate(0);
            return;
        }
        const child = self.child.?;
        if (process_io.closeStdinAndReap(child, self.io, shutdown_grace_ms)) {
            if (self.drain_thread) |thread| thread.join();
            process_io.releaseReapedChild(child, self.io);
        } else {
            process_io.terminateProcessGroup(self.io, self.group, 0);
            _ = child.wait(self.io) catch {};
            if (self.drain_thread) |thread| thread.join();
        }
    }
};

fn noteServerExit(gpa: std.mem.Allocator, ap: *Appender, stderr_tail: []const u8) void {
    var note_buf: [768]u8 = undefined;
    var note: []const u8 = "agy acp exited mid-turn with no stderr output";
    if (compactDiagnostic(gpa, stderr_tail, 512)) |compact| {
        defer gpa.free(compact);
        if (compact.len > 0)
            note = std.fmt.bufPrint(&note_buf, "agy acp exited mid-turn (stderr: {s})", .{compact}) catch note;
    } else |_| {}
    setDelegateError(note);
    _ = ap.append(.{ .system_note = .{ .text = note } }) catch {};
}

/// Writes ACP messages and numbers requests.
const Wire = struct {
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

    /// The answer to one of agy's requests; `id_json` is its id as sent.
    fn respond(self: *Wire, arena: std.mem.Allocator, id_json: []const u8, result: anytype) !void {
        const id = try std.json.parseFromSliceLeaky(std.json.Value, arena, id_json, .{});
        try self.value(arena, .{ .jsonrpc = "2.0", .id = id, .result = result });
    }

    /// Turns down one of agy's requests that Marlin does not serve.
    fn refuse(self: *Wire, arena: std.mem.Allocator, id_json: []const u8) !void {
        const id = try std.json.parseFromSliceLeaky(std.json.Value, arena, id_json, .{});
        try self.value(arena, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32601, .message = "method not found" } });
    }
};

fn waitResponse(arena: std.mem.Allocator, reader: *Io.Reader, request_id: i64) !agy.Response {
    // Arena-owned: the decoded response may point into these bytes.
    var acc: std.ArrayList(u8) = .empty;
    while (true) {
        const raw = shared.takeEventLine(reader, arena, &acc, shared.max_event_line_bytes) catch |err| switch (err) {
            error.LineTooLong => return error.AgyEventLineTooLong,
            error.ReadFailed => return error.AgyServerExited,
            error.OutOfMemory => return error.OutOfMemory,
        } orelse return error.AgyServerExited;
        const inbound = agy.decodeLine(arena, raw) catch continue;
        switch (inbound) {
            .response => |response| if (response.id == request_id) return response,
            else => {},
        }
    }
}

/// A failed request's message for the user: a sign-in problem says how to
/// fix it.
fn rpcError(arena: std.mem.Allocator, response: agy.Response) ?[]const u8 {
    const err_value = response.err orelse return null;
    if (agy.intField(err_value, "code")) |code| if (code == auth_required_code) return guest_auth.loginRequiredNote(.agy);
    if (agy.strField(err_value, "message")) |message|
        return if (guest_auth.isAuthFailure(message)) guest_auth.loginRequiredNote(.agy) else message;
    return agy.stringify(arena, err_value) catch "agy acp request failed";
}

fn markServerExit(exited: *bool, result: anytype) @TypeOf(result) {
    _ = result catch |err| {
        if (err == error.AgyServerExited) exited.* = true;
    };
    return result;
}

fn failWith(ap: *Appender, message: []const u8) !TurnResult {
    setDelegateError(message);
    _ = try ap.append(.{ .system_note = .{ .text = message } });
    return error.DelegateFailed;
}

/// The replay caught up: persist, announce and write from here on.
fn goLive(opts: RunOpts, ap: *Appender, activity: *guest_activity.Tracker, line_writer: *kept_mod.LineWriter, phase: TurnPhase) !void {
    ap.replaying = false;
    ap.seq = try ap.store.lastSeq(opts.session_id);
    line_writer.replaying = false;
    activity.unmute();
    publishPhase(opts, if (phase == .waiting_background) .background else .provider);
}

/// The reply landed but the run stays alive for its background work: say so
/// in the transcript and the phase, matching claude_code_turn.zig.
fn noteBackgroundWait(gpa: std.mem.Allocator, opts: RunOpts, ap: *Appender, open: usize, description: []const u8) !void {
    const note = if (description.len > 0 and open == 1)
        try std.fmt.allocPrint(gpa, "waiting on background task: {s}", .{description})
    else if (description.len > 0)
        try std.fmt.allocPrint(gpa, "waiting on {d} background tasks: {s}, …", .{ open, description })
    else
        try std.fmt.allocPrint(gpa, "waiting on {d} background task{s}", .{ open, if (open == 1) "" else "s" });
    defer gpa.free(note);
    _ = try ap.append(.{ .system_note = .{ .text = note } });
    if (!ap.replaying) publishPhase(opts, .background);
}

pub const TurnPhase = enum {
    /// Waiting for the JSON-RPC response to our active `session/prompt`.
    prompt_active,
    /// `session/prompt` returned `end_turn` while background commands or
    /// subagents are still running; keep `agy acp` alive in `.background`.
    waiting_background,
    /// A background task/subagent woke `agy` up for a reactive turn (which has
    /// no JSON-RPC response to mark its end).
    reactive_active,
    /// The reactive wakeup emitted `usage_update` with no open background work;
    /// waiting briefly for a subsequent `tool_call` or silence (turn done).
    reactive_settling,
};

pub const TurnState = struct {
    phase: TurnPhase = .prompt_active,
    awaiting_wakeup: bool = false,
    wakeup_deadline_ms: i64 = 0,

    pub const Action = enum { keep_reading, enter_background, enter_provider, finish_turn };

    pub fn onPromptEnd(self: *TurnState, open_bg: usize, pending_wakeup: bool) Action {
        if (open_bg > 0) {
            self.phase = .waiting_background;
            self.awaiting_wakeup = false;
            return .enter_background;
        }
        if (pending_wakeup) {
            self.phase = .reactive_settling;
            self.awaiting_wakeup = false;
            return .keep_reading;
        }
        return .finish_turn;
    }

    pub fn onPromptSent(self: *TurnState) void {
        self.phase = .prompt_active;
        self.awaiting_wakeup = false;
    }

    pub fn onUpdate(self: *TurnState, is_usage: bool, is_work: bool, open_bg: usize) Action {
        switch (self.phase) {
            .prompt_active => return .keep_reading,
            .waiting_background => {
                if (!is_usage and !is_work) return .keep_reading;
                self.awaiting_wakeup = false;
                self.phase = if (is_usage and open_bg == 0) .reactive_settling else .reactive_active;
                return .enter_provider;
            },
            .reactive_active => {
                if (is_work or is_usage) self.awaiting_wakeup = false;
                if (is_usage) {
                    if (open_bg > 0) {
                        self.phase = .waiting_background;
                        return .enter_background;
                    }
                    self.phase = .reactive_settling;
                }
                return .keep_reading;
            },
            .reactive_settling => {
                if (is_work) {
                    self.phase = .reactive_active;
                    self.awaiting_wakeup = false;
                } else if (is_usage and open_bg > 0) {
                    self.phase = .waiting_background;
                    return .enter_background;
                }
                return .keep_reading;
            },
        }
    }

    pub fn onWaitTimeout(self: *TurnState, open_bg: usize, parent_busy: bool, wakeup_signal: bool, now_ms: i64) Action {
        switch (self.phase) {
            .prompt_active => return .keep_reading,
            .waiting_background => {
                if (open_bg > 0) return .keep_reading;
                self.phase = .reactive_active;
                self.awaiting_wakeup = true;
                self.wakeup_deadline_ms = now_ms + follow_up_wait_ms;
                return .enter_provider;
            },
            .reactive_active => {
                if (!self.awaiting_wakeup) return .keep_reading;
                if (open_bg > 0) {
                    self.phase = .waiting_background;
                    self.awaiting_wakeup = false;
                    return .enter_background;
                }
                if (parent_busy) {
                    self.wakeup_deadline_ms = now_ms + follow_up_wait_ms;
                    return .keep_reading;
                }
                if (now_ms < self.wakeup_deadline_ms) return .keep_reading;
                self.awaiting_wakeup = false;
                return .finish_turn;
            },
            .reactive_settling => {
                if (open_bg > 0) {
                    self.phase = .waiting_background;
                    self.awaiting_wakeup = false;
                    return .enter_background;
                }
                if (parent_busy or wakeup_signal) {
                    self.phase = .reactive_active;
                    self.awaiting_wakeup = true;
                    self.wakeup_deadline_ms = now_ms + follow_up_wait_ms;
                    return .enter_provider;
                }
                return .finish_turn;
            },
        }
    }
};

/// The agent's prose and thinking stream in chunks with no end marker; each
/// becomes a block when something else starts. Prose followed by more work
/// is commentary; the prose a prompt ends with is the answer.
const Pending = struct {
    gpa: std.mem.Allocator,
    message: std.ArrayList(u8) = .empty,
    thought: std.ArrayList(u8) = .empty,

    fn deinit(self: *Pending) void {
        self.message.deinit(self.gpa);
        self.thought.deinit(self.gpa);
    }

    fn flushThought(self: *Pending, ap: *Appender) !void {
        if (self.thought.items.len == 0) return;
        _ = try ap.append(.{ .reasoning = .{ .text = self.thought.items } });
        self.thought.clearRetainingCapacity();
    }

    /// Returns true when it stored an answer.
    fn flushMessage(self: *Pending, ap: *Appender, final: bool, final_text: *std.ArrayList(u8)) !bool {
        try self.flushThought(ap);
        const text = std.mem.trim(u8, self.message.items, " \t\r\n");
        defer self.message.clearRetainingCapacity();
        if (text.len == 0) return false;
        if (!final) {
            _ = try ap.append(.{ .reasoning = .{ .text = text, .commentary = true } });
            return false;
        }
        _ = try ap.append(.{ .assistant_msg = .{ .text = text } });
        final_text.clearRetainingCapacity();
        try final_text.appendSlice(self.gpa, text);
        return true;
    }
};

/// Tool calls seen this turn: started (a tool_call block exists, with its
/// title for background wait notes) and finished (its result does).
const Calls = struct {
    gpa: std.mem.Allocator,
    started: std.StringHashMapUnmanaged([]u8) = .empty,
    finished: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Calls) void {
        var sit = self.started.iterator();
        while (sit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.started.deinit(self.gpa);
        var fit = self.finished.keyIterator();
        while (fit.next()) |key| self.gpa.free(key.*);
        self.finished.deinit(self.gpa);
    }

    fn markStarted(self: *Calls, id: []const u8, title: []const u8) !bool {
        if (self.started.contains(id)) return false;
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);
        const owned_title = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(owned_title);
        try self.started.put(self.gpa, owned_id, owned_title);
        return true;
    }

    fn markFinished(self: *Calls, id: []const u8) !bool {
        if (self.finished.contains(id)) return false;
        try self.finished.put(self.gpa, try self.gpa.dupe(u8, id), {});
        return true;
    }

    fn openCount(self: *const Calls) usize {
        var count: usize = 0;
        var it = self.started.keyIterator();
        while (it.next()) |key| if (!self.finished.contains(key.*)) {
            count += 1;
        };
        return count;
    }

    fn firstOpenTitle(self: *const Calls) ?[]const u8 {
        var it = self.started.iterator();
        while (it.next()) |entry| if (!self.finished.contains(entry.key_ptr.*)) {
            if (entry.value_ptr.*.len > 0) return entry.value_ptr.*;
        };
        return null;
    }
};

/// Images in a tool call's content (show_image through Marlin's bridge).
fn resultImages(arena: std.mem.Allocator, update: std.json.Value) ![]const claude_code.ResultImage {
    const content = agy.field(update, "content") orelse return &.{};
    if (content != .array) return &.{};
    var out: std.ArrayList(claude_code.ResultImage) = .empty;
    for (content.array.items) |item| {
        if (!std.mem.eql(u8, agy.strField(item, "type") orelse "", "content")) continue;
        const inner = agy.field(item, "content") orelse continue;
        if (!std.mem.eql(u8, agy.strField(inner, "type") orelse "", "image")) continue;
        try out.append(arena, .{
            .media_type = agy.strField(inner, "mimeType") orelse continue,
            .data_base64 = agy.strField(inner, "data") orelse continue,
        });
    }
    return out.items;
}

fn startCall(
    arena: std.mem.Allocator,
    ap: *Appender,
    opts: RunOpts,
    calls: *Calls,
    activity: *guest_activity.Tracker,
    bg_watch: *agy_watch.Watcher,
    update: std.json.Value,
    id: []const u8,
    now_ms: i64,
) !void {
    const detail = agy.strField(update, "title") orelse "";
    if (!try calls.markStarted(id, detail)) return;
    const name = agy.toolName(update);
    const args = try agy.toolArgs(arena, update);
    // Same redaction discipline as the native tool_call append.
    const persisted_args = (try permissions.redactSecrets(arena, opts.secrets, args)) orelse args;
    _ = try ap.append(.{ .tool_call = .{ .call_id = id, .name = name, .args_json = persisted_args } });
    if (!ap.replaying) if (opts.on_tool) |callback| callback(opts.on_delta_ctx, name, .start);
    const kind = agy.strField(update, "kind") orelse "";
    if (std.mem.eql(u8, kind, "execute")) bg_watch.noteCommandStart(id);
    try activity.start(id, "", if (std.mem.eql(u8, kind, "execute")) .process else .tool, name, detail, now_ms);
}

fn finishCall(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    ap: *Appender,
    opts: RunOpts,
    calls: *Calls,
    activity: *guest_activity.Tracker,
    bg_watch: *agy_watch.Watcher,
    update: std.json.Value,
    id: []const u8,
    status: []const u8,
) !void {
    if (!try calls.markFinished(id)) return;
    bg_watch.noteCommandFinish(id);
    noteSubagentTool(bg_watch, update);
    activity.finish(id);
    const images = try resultImages(arena, update);
    const raw_body = try agy.toolBody(arena, update);
    const redacted = try permissions.redactSecrets(gpa, opts.secrets, raw_body);
    defer if (redacted) |value| gpa.free(value);
    const body = redacted orelse raw_body;
    try shared.appendGuestResult(gpa, ap, .{
        .call_id = id,
        .status = if (std.mem.eql(u8, status, "completed")) .ok else .err,
        .inline_body = body[0..@min(body.len, opts.cfg.inline_tool_cap_bytes)],
        .full_body_ref = null,
    }, images);
    if (!ap.replaying) if (opts.on_tool) |callback| callback(opts.on_delta_ctx, agy.toolName(update), .done);
}

fn noteSubagentTool(bg_watch: *agy_watch.Watcher, update: std.json.Value) void {
    const raw_name = agy.strField(update, "name") orelse return;
    const input = agy.field(update, "rawInput") orelse return;
    if (std.mem.eql(u8, raw_name, "send_message")) {
        if (agy.strField(input, "Recipient")) |recipient| bg_watch.noteSubagentMessaged(recipient);
    } else if (std.mem.eql(u8, raw_name, "manage_subagents")) {
        const action = agy.strField(input, "Action") orelse return;
        if (std.mem.eql(u8, action, "kill_all")) {
            bg_watch.noteAllSubagentsKilled();
        } else if (std.mem.eql(u8, action, "kill")) {
            if (agy.field(input, "ConversationIds")) |ids| if (ids == .array) for (ids.array.items) |entry| {
                if (entry == .string) bg_watch.noteSubagentKilled(entry.string);
            };
        }
    }
}

const UpdateSignal = struct { is_usage: bool = false, is_work: bool = false };

/// One `session/update` of our session. Returns whether it was a usage or work
/// event so the turn state machine tracks reactive wakeups.
fn handleUpdate(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    ap: *Appender,
    opts: RunOpts,
    pending: *Pending,
    calls: *Calls,
    activity: *guest_activity.Tracker,
    bg_watch: *agy_watch.Watcher,
    final_text: *std.ArrayList(u8),
    update: std.json.Value,
    replaying: bool,
) !UpdateSignal {
    const kind = agy.strField(update, "sessionUpdate") orelse return .{};
    if (std.mem.eql(u8, kind, "agent_message_chunk")) {
        const text = agy.strField(agy.field(update, "content") orelse return .{}, "text") orelse return .{};
        try pending.flushThought(ap);
        try pending.message.appendSlice(gpa, text);
        if (!replaying) if (opts.on_delta) |callback| callback(opts.on_delta_ctx, text);
        return .{ .is_work = true };
    } else if (std.mem.eql(u8, kind, "agent_thought_chunk")) {
        const text = agy.strField(agy.field(update, "content") orelse return .{}, "text") orelse return .{};
        _ = try pending.flushMessage(ap, false, final_text);
        try pending.thought.appendSlice(gpa, text);
        if (!replaying) if (opts.on_reasoning_delta) |callback| callback(opts.on_delta_ctx, text);
        return .{ .is_work = true };
    } else if (std.mem.eql(u8, kind, "tool_call") or std.mem.eql(u8, kind, "tool_call_update")) {
        const id = agy.strField(update, "toolCallId") orelse return .{};
        _ = try pending.flushMessage(ap, false, final_text);
        // An update for a call never announced still names it.
        if (std.mem.eql(u8, kind, "tool_call") or agy.strField(update, "title") != null)
            try startCall(arena, ap, opts, calls, activity, bg_watch, update, id, nowMs(io));
        const status = agy.strField(update, "status") orelse "";
        if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "failed")) {
            if (!calls.started.contains(id)) return .{};
            try finishCall(gpa, arena, ap, opts, calls, activity, bg_watch, update, id, status);
        }
        return .{ .is_work = true };
    } else if (std.mem.eql(u8, kind, "usage_update")) {
        if (agy.intField(update, "used")) |used| if (opts.context_used_out) |out|
            out.store(@intCast(@max(0, used)), .release);
        if (agy.intField(update, "size")) |size| if (size > 0) if (opts.context_limit_out) |out|
            out.store(@intCast(size), .release);
        return .{ .is_usage = true };
    }
    return .{};
}

fn waitReadable(
    reader: *Io.Reader,
    partial: usize,
    kept: ?*Kept,
    child: ?*std.process.Child,
    timeout_ms: i32,
) error{Detached}!bool {
    if (reader.bufferedLen() > 0 or partial > 0) return true;
    if (kept) |k| return k.waitReadable(timeout_ms);
    const fd = child.?.stdout.?.handle;
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, timeout_ms) catch return true;
    return ready > 0;
}

fn backgroundDescription(calls: *const Calls, bg_watch: *agy_watch.Watcher, buf: []u8) []const u8 {
    if (calls.firstOpenTitle()) |title| return title;
    return bg_watch.firstActiveSubagentName(buf) orelse "";
}

pub fn runAgyTurn(
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
    const bridge: ?agy.Bridge = if (opts.marlin_exe) |exe| .{ .marlin_exe = exe, .sid = opts.session_id } else null;
    const instructions = try claude_code.systemPromptAppend(
        arena,
        if (bridge != null) guest_auth.interactive_instructions else guest_auth.progress_instructions,
        profile.load(arena, io, opts.tool_environ, opts.cwd) orelse "",
    );
    const argv = try arena.dupe([]const u8, &.{ agy.binaryPath(opts.tool_environ), "acp" });
    var guest_environ: ?std.process.Environ.Map = if (opts.tool_environ) |source|
        try permissions.toolEnvironment(gpa, source)
    else
        null;
    defer if (guest_environ) |*map| map.deinit();

    // A kept server (keeper.zig) runs on through a daemon restart; one a
    // previous daemon started is followed by replaying its journal to where
    // that daemon stopped reading, then live.
    const attach = opts.guest_attach;
    const replay_until: u64 = if (attach) |a| a.replay_until else 0;
    const resume_kept: ?*Kept = if (attach) |a| Kept.attach(gpa, io, a.dir) catch |err| {
        const note = try std.fmt.allocPrint(arena, "agy could not be followed after the restart: {t}", .{err});
        kept_mod.removeDir(io, a.dir);
        return failWith(ap, note);
    } else null;
    const kept: ?*Kept = resume_kept orelse shared.spawnKept(gpa, io, opts, argv, if (guest_environ) |*map| map else null, 1, ap.turn_id, "agy");
    var kept_owned = kept != null;
    // Runs after the teardown below: the keeper has reaped the server.
    defer if (kept_owned) {
        const k = kept.?;
        if (opts.kept_slot) |slot| slot.set(io, null);
        k.reap();
        kept_mod.removeDir(io, k.dir);
        k.deinit();
    };
    var child: ?std.process.Child = null;
    if (kept == null) child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = opts.cwd },
        .environ_map = if (guest_environ) |*map| map else null,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| {
        const note = try shared.spawnErrorNote(arena, io, opts.cwd, err, .agy);
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateSpawnFailed;
    };
    // Its group; 0 when a followed server already ended (nothing to signal).
    const guest_pid: std.posix.pid_t = if (kept) |k| k.pid else child.?.id.?;
    if (kept) |k| if (opts.kept_slot) |slot| slot.set(io, k);

    var watcher = CcWatcher.init(io, opts.cancel, guest_pid, opts.park_clock, opts.cfg.guest_max_runtime_ms);
    watcher.max_runtime_live = opts.guest_max_runtime_live;
    const watcher_thread: ?std.Thread = if (guest_pid > 0) try std.Thread.spawn(.{}, CcWatcher.run, .{&watcher}) else null;
    var drain: CcStderrDrain = .{ .io = io, .file = undefined };
    const drain_thread: ?std.Thread = if (child) |c| blk: {
        drain.file = c.stderr.?;
        break :blk std.Thread.spawn(.{}, CcStderrDrain.run, .{&drain}) catch null;
    } else null;
    var teardown = Teardown{
        .io = io,
        .watcher = &watcher,
        .watcher_thread = watcher_thread,
        .drain_thread = drain_thread,
        .child = if (child != null) &child.? else null,
        .kept = kept,
        .group = guest_pid,
    };
    defer teardown.run();
    var server_exited = false;
    errdefer if (server_exited and
        !watcher.cancelled.load(.acquire) and !watcher.timed_out.load(.acquire))
    {
        teardown.run();
        var tail_buf: [4096]u8 = undefined;
        noteServerExit(gpa, ap, if (kept) |k| k.stderrTail(&tail_buf) else drain.tail[0..drain.len]);
    };

    var writer_buffer: [64 * 1024]u8 = undefined;
    var writer_file: Io.File.Writer = undefined;
    var line_writer: kept_mod.LineWriter = undefined;
    const writer: *Io.Writer = if (kept) |k| blk: {
        // While replaying, what this turn writes was written already.
        line_writer = .init(k, replay_until > 0, &writer_buffer);
        break :blk &line_writer.writer;
    } else blk: {
        writer_file = child.?.stdin.?.writer(io, &writer_buffer);
        break :blk &writer_file.interface;
    };
    defer if (kept != null) line_writer.deinit();
    var line_buffer: []u8 = &.{};
    defer if (line_buffer.len > 0) gpa.free(line_buffer);
    var reader_file: Io.File.Reader = undefined;
    const reader: *Io.Reader = if (kept) |k| &k.reader.interface else blk: {
        line_buffer = try gpa.alloc(u8, line_bytes);
        reader_file = child.?.stdout.?.reader(io, line_buffer);
        break :blk &reader_file.interface;
    };
    var replaying = replay_until > 0;
    if (replaying) ap.replaying = true;
    var detached = false;
    var detach_offset: u64 = 0;
    var wire = Wire{ .writer = writer };

    // Marlin implements none of ACP's client file system or terminal
    // methods: agy reads, writes and runs commands itself, asking first.
    const init_id = try wire.request(arena, "initialize", .{
        .protocolVersion = agy.protocol_version,
        .clientCapabilities = .{
            .fs = .{ .readTextFile = false, .writeTextFile = false },
            .terminal = false,
        },
        .clientInfo = .{ .name = "marlin", .title = "Marlin", .version = build_options.version },
    });
    const initialized = try markServerExit(&server_exited, waitResponse(arena, reader, init_id));
    if (rpcError(arena, initialized)) |message| return failWith(ap, message);

    const mcp_servers = try agy.mcpServers(arena, bridge, opts.tool_environ);
    // agy's extension for system instructions; applied each time a process
    // opens the conversation, so a profile edit counts from the next turn.
    const meta = .{ .antigravity = .{ .systemPrompt = .{ .append = instructions } } };
    var session_id: []const u8 = "";
    var config_options: ?std.json.Value = null;
    const saved_session = try store.getAgySessionId(opts.session_id);
    defer if (saved_session) |saved| gpa.free(saved);
    if (saved_session) |saved| {
        const resume_id = try wire.request(arena, "session/resume", .{
            .sessionId = saved,
            .cwd = opts.cwd,
            .mcpServers = mcp_servers,
            ._meta = meta,
        });
        const resumed = try markServerExit(&server_exited, waitResponse(arena, reader, resume_id));
        if (rpcError(arena, resumed)) |message| {
            if (guest_auth.loginRequiredBackend(message) != null) return failWith(ap, message);
            // The conversation may have been deleted outside Marlin.
            try store.setAgySessionId(opts.session_id, null);
        } else {
            session_id = try arena.dupe(u8, saved);
            if (resumed.result) |result| config_options = agy.field(result, "configOptions");
        }
    }
    // Compacting needs a conversation with something in it; never start one.
    if (opts.guest_compact != null and session_id.len == 0) {
        _ = try ap.append(.{ .system_note = .{ .text = "nothing to compact yet: Antigravity has no conversation for this session" } });
        return .{ .text = try gpa.dupe(u8, ""), .rounds = 0, .tokens_in = 0, .tokens_out = 0 };
    }
    if (session_id.len == 0) {
        const new_id = try wire.request(arena, "session/new", .{
            .cwd = opts.cwd,
            .mcpServers = mcp_servers,
            ._meta = meta,
        });
        const started = try markServerExit(&server_exited, waitResponse(arena, reader, new_id));
        if (rpcError(arena, started)) |message| return failWith(ap, message);
        const result = started.result orelse return error.BadAgyResponse;
        session_id = try arena.dupe(u8, agy.strField(result, "sessionId") orelse return error.BadAgyResponse);
        config_options = agy.field(result, "configOptions");
        try store.setAgySessionId(opts.session_id, session_id);
    }

    // Marlin's model and effort, where they differ from the conversation's.
    // Thinking levels depend on the model, so the model goes first.
    if (agy.modelValue(opts.endpoint.model)) |model| {
        const current = agy.currentValue(config_options, "model") orelse "";
        if (!std.mem.eql(u8, current, model)) {
            const set_id = try wire.request(arena, "session/set_config_option", .{ .sessionId = session_id, .configId = "model", .value = model });
            const set = try markServerExit(&server_exited, waitResponse(arena, reader, set_id));
            if (rpcError(arena, set)) |message|
                return failWith(ap, try std.fmt.allocPrint(arena, "Antigravity could not select {s}: {s}", .{ model, message }));
            if (set.result) |result| if (agy.field(result, "configOptions")) |options| {
                config_options = options;
            };
        }
    }
    if (agy.thoughtLevel(opts.effort)) |level| {
        const current = agy.currentValue(config_options, "thought_level") orelse "";
        if (agy.offers(config_options, "thought_level", level) and !std.mem.eql(u8, current, level)) {
            const set_id = try wire.request(arena, "session/set_config_option", .{ .sessionId = session_id, .configId = "thought_level", .value = level });
            const set = try markServerExit(&server_exited, waitResponse(arena, reader, set_id));
            if (rpcError(arena, set)) |message| {
                const note = try std.fmt.allocPrint(arena, "Antigravity kept its thinking level ({s})", .{message});
                _ = try ap.append(.{ .system_note = .{ .text = note } });
            }
        }
    }
    // Marlin answers every permission prompt; a conversation left in one of
    // agy's self-approving modes would go around it.
    if (agy.currentValue(config_options, "mode")) |mode| if (!std.mem.eql(u8, mode, "default")) {
        const set_id = try wire.request(arena, "session/set_config_option", .{ .sessionId = session_id, .configId = "mode", .value = "default" });
        const set = try markServerExit(&server_exited, waitResponse(arena, reader, set_id));
        if (rpcError(arena, set)) |message| return failWith(ap, message);
    };
    // The models this sign-in offers, for the model picker.
    if (!replaying) {
        const models = try agy.modelList(arena, config_options);
        if (models.len > 0) store.kvSetText(agy.models_key, models) catch {};
    }

    // ACP runs commands sent as prompt text; agy offers `/compact`.
    const prompt_text = if (opts.guest_compact != null) "/compact" else blk: {
        var history: std.ArrayList(block.Block) = .empty;
        store.loadContextBlocksInto(arena, &history, opts.session_id, 1_000_000) catch {};
        break :blk try context.guestPrompt(arena, history.items, first_text);
    };
    const TextBlock = struct { type: []const u8 = "text", text: []const u8 };
    var prompt_id = try wire.request(arena, "session/prompt", .{
        .sessionId = session_id,
        .prompt = &[_]TextBlock{.{ .text = prompt_text }},
    });

    var rounds: u32 = 1;
    var tokens_in: u64 = 0;
    var tokens_out: u64 = 0;
    var final_text: std.ArrayList(u8) = .empty;
    defer final_text.deinit(gpa);
    var pending = Pending{ .gpa = gpa };
    defer pending.deinit();
    var calls = Calls{ .gpa = gpa };
    defer calls.deinit();
    var done = false;
    var interrupted = false;
    var failed = false;
    var failure_text: []const u8 = "Antigravity turn failed";
    var activity = guest_activity.Tracker.init(gpa, opts.on_guest_activity, opts.on_delta_ctx);
    activity.io = io;
    defer activity.deinit();
    if (replaying) activity.mute();
    var bg_watch = try agy_watch.Watcher.init(gpa, io, &activity, session_id, null, opts.tool_environ);
    defer bg_watch.deinit();
    if (!replaying) bg_watch.start();
    var turn_state = TurnState{};
    var bg_desc_buf: [128]u8 = undefined;

    var line_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer line_arena_state.deinit();
    var line_acc: std.ArrayList(u8) = .empty;
    defer line_acc.deinit(gpa);
    events: while (!done) {
        if (!replaying and (turn_state.phase == .waiting_background or
            turn_state.phase == .reactive_settling or
            (turn_state.phase == .reactive_active and turn_state.awaiting_wakeup)))
        {
            const wait_ms: i32 = switch (turn_state.phase) {
                .waiting_background => background_poll_ms,
                .reactive_settling => reactive_settle_ms,
                .reactive_active => @intCast(@max(@as(i64, 50), @min(@as(i64, background_poll_ms), turn_state.wakeup_deadline_ms - nowMs(io)))),
                .prompt_active => unreachable,
            };
            const ready = waitReadable(reader, line_acc.items.len, kept, if (child != null) &child.? else null, wait_ms) catch {
                detached = true;
                detach_offset = kept.?.consumed() - line_acc.items.len;
                break :events;
            };
            if (!ready) {
                if (turn_state.phase == .waiting_background) if (opts.poll_steer) |poll| if (poll(opts.on_delta_ctx, gpa)) |steer| {
                    defer steer.deinit(gpa);
                    _ = try ap.append(.{ .steer = steer });
                    final_text.clearRetainingCapacity();
                    prompt_id = try wire.request(arena, "session/prompt", .{
                        .sessionId = session_id,
                        .prompt = &[_]TextBlock{.{ .text = steer.text }},
                    });
                    turn_state.onPromptSent();
                    publishPhase(opts, .provider);
                    rounds += 1;
                    continue :events;
                };
                bg_watch.refresh();
                const open_bg = calls.openCount() + bg_watch.activeSubagentCount();
                const parent_busy = bg_watch.isParentBusy();
                const wakeup_signal = bg_watch.takeWakeupSignal();
                switch (turn_state.onWaitTimeout(open_bg, parent_busy, wakeup_signal, nowMs(io))) {
                    .keep_reading => continue :events,
                    .enter_provider => {
                        _ = try pending.flushMessage(ap, false, &final_text);
                        publishPhase(opts, .provider);
                        continue :events;
                    },
                    .enter_background => {
                        _ = try pending.flushMessage(ap, true, &final_text);
                        try noteBackgroundWait(gpa, opts, ap, open_bg, backgroundDescription(&calls, &bg_watch, &bg_desc_buf));
                        continue :events;
                    },
                    .finish_turn => {
                        _ = try pending.flushMessage(ap, true, &final_text);
                        var follow_up: ?block.Input = if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
                        if (follow_up == null and !tryCloseSteering(opts))
                            follow_up = if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
                        if (follow_up) |text| {
                            defer text.deinit(gpa);
                            _ = try ap.append(.{ .steer = text });
                            final_text.clearRetainingCapacity();
                            prompt_id = try wire.request(arena, "session/prompt", .{
                                .sessionId = session_id,
                                .prompt = &[_]TextBlock{.{ .text = text.text }},
                            });
                            turn_state.onPromptSent();
                            publishPhase(opts, .provider);
                            rounds += 1;
                            continue :events;
                        }
                        done = true;
                        break :events;
                    },
                }
            }
        }
        const raw = shared.takeEventLine(reader, gpa, &line_acc, shared.max_event_line_bytes) catch |err| switch (err) {
            error.LineTooLong => {
                _ = try ap.append(.{ .system_note = .{ .text = "agy: one event line exceeded 64 MiB and was dropped" } });
                continue;
            },
            error.ReadFailed => {
                // Detached while waiting: a partial line stays unread.
                if (kept) |k| if (k.detached) {
                    detached = true;
                    detach_offset = k.consumed() - line_acc.items.len;
                };
                break;
            },
            error.OutOfMemory => return error.OutOfMemory,
        } orelse break;
        if (replaying and kept.?.consumed() > replay_until) {
            replaying = false;
            try goLive(opts, ap, &activity, &line_writer, turn_state.phase);
            bg_watch.start();
        }
        _ = line_arena_state.reset(.retain_capacity);
        const line_arena = line_arena_state.allocator();
        const inbound = agy.decodeLine(line_arena, raw) catch continue;
        switch (inbound) {
            .response => |response| if (response.id == prompt_id) {
                _ = try pending.flushMessage(ap, true, &final_text);
                if (rpcError(line_arena, response)) |message| {
                    failure_text = try arena.dupe(u8, message);
                    failed = true;
                    break :events;
                }
                const usage = agy.promptUsage(response.result);
                tokens_in += usage.input;
                tokens_out += usage.output;
                const stop_reason = if (response.result) |result| agy.strField(result, "stopReason") orelse "end_turn" else "end_turn";
                if (std.mem.eql(u8, stop_reason, "cancelled")) {
                    interrupted = true;
                    break :events;
                }
                if (agy.stopNote(stop_reason)) |note| _ = try ap.append(.{ .system_note = .{ .text = note } });
                if (opts.guest_compact != null) {
                    _ = try ap.append(.{ .system_note = .{ .text = try compactionNote(line_arena, "Antigravity", "manual", 0, null) } });
                    done = true;
                    break :events;
                }
                if (!replaying) bg_watch.refresh();
                const pending_wakeup = if (replaying) false else bg_watch.hasPendingPromptWakeup();
                bg_watch.clearWakeupSignal();
                const open_bg = calls.openCount() + if (replaying) @as(usize, 0) else bg_watch.activeSubagentCount();
                switch (turn_state.onPromptEnd(open_bg, pending_wakeup)) {
                    .enter_background => {
                        try noteBackgroundWait(gpa, opts, ap, open_bg, backgroundDescription(&calls, &bg_watch, &bg_desc_buf));
                        continue :events;
                    },
                    .keep_reading => continue :events,
                    .enter_provider, .finish_turn => {},
                }
                // ACP has no steering into a running prompt: what the user
                // queued meanwhile is the next prompt. Replaying, the journal
                // says whether the first daemon sent one: it did when more
                // of it follows.
                var follow_up: ?block.Input = if (replaying)
                    (if (kept.?.consumed() < replay_until) block.Input{ .text = try gpa.dupe(u8, "") } else null)
                else if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
                if (!replaying and follow_up == null and !tryCloseSteering(opts))
                    follow_up = if (opts.poll_steer) |poll| poll(opts.on_delta_ctx, gpa) else null;
                if (follow_up) |text| {
                    defer text.deinit(gpa);
                    _ = try ap.append(.{ .steer = text });
                    final_text.clearRetainingCapacity();
                    prompt_id = try wire.request(line_arena, "session/prompt", .{
                        .sessionId = session_id,
                        .prompt = &[_]TextBlock{.{ .text = text.text }},
                    });
                    turn_state.onPromptSent();
                    rounds += 1;
                } else done = true;
            },
            // The daemon that read it first answered it.
            .request => |request| if (!replaying) {
                if (std.mem.eql(u8, request.method, "session/request_permission")) {
                    const params = request.params;
                    const tool_call = agy.field(params, "toolCall") orelse .null;
                    const call_id = agy.strField(tool_call, "toolCallId") orelse request.id_json;
                    const args = try agy.toolArgs(line_arena, tool_call);
                    const verdict = try resolveGuestApproval(gpa, io, opts, ap, call_id, agy.toolName(tool_call), args);
                    const Outcome = struct { outcome: []const u8, optionId: ?[]const u8 = null };
                    const option = agy.permissionOption(agy.field(params, "options"), verdict == .approved);
                    try wire.respond(line_arena, request.id_json, .{ .outcome = if (option) |id|
                        Outcome{ .outcome = "selected", .optionId = id }
                    else
                        Outcome{ .outcome = "cancelled" } });
                } else {
                    try wire.refuse(line_arena, request.id_json);
                }
            },
            .notification => |notification| {
                if (!std.mem.eql(u8, notification.method, "session/update")) continue;
                const params = notification.params;
                if (!std.mem.eql(u8, agy.strField(params, "sessionId") orelse session_id, session_id)) continue;
                const update = agy.field(params, "update") orelse continue;
                const signal = try handleUpdate(gpa, line_arena, io, ap, opts, &pending, &calls, &activity, &bg_watch, &final_text, update, replaying);
                if (signal.is_usage and !replaying and turn_state.phase != .prompt_active) bg_watch.refresh();
                const open_bg = calls.openCount() + if (replaying) @as(usize, 0) else bg_watch.activeSubagentCount();
                switch (turn_state.onUpdate(signal.is_usage, signal.is_work, open_bg)) {
                    .keep_reading, .finish_turn => {},
                    .enter_provider => {
                        bg_watch.clearWakeupSignal();
                        if (!replaying) publishPhase(opts, .provider);
                    },
                    .enter_background => {
                        _ = try pending.flushMessage(ap, true, &final_text);
                        try noteBackgroundWait(gpa, opts, ap, open_bg, backgroundDescription(&calls, &bg_watch, &bg_desc_buf));
                    },
                }
            },
        }
        if (replaying and kept.?.consumed() >= replay_until) {
            replaying = false;
            try goLive(opts, ap, &activity, &line_writer, turn_state.phase);
            bg_watch.start();
        }
        // Handing over: stop between events; the next daemon replays to here.
        if (!done) if (kept) |k| if (k.detachRequested()) {
            detached = true;
            detach_offset = k.consumed();
            break :events;
        };
    }

    if (detached) {
        // The server runs on with its stdin open for the next daemon.
        teardown.done = true;
        watcher.done.store(true, .release);
        if (watcher_thread) |t| t.join();
        const k = kept.?;
        kept_mod.writeJson(gpa, io, k.dir, kept_mod.detach_name, kept_mod.DetachFile{
            .consumed = @max(detach_offset, replay_until),
            .inputs_sent = 0,
        }) catch |err| std.log.err("guest keeper: could not record the handover point: {t}", .{err});
        if (opts.kept_slot) |slot| slot.set(io, null);
        kept_owned = false;
        k.deinit();
        return error.GuestDetached;
    }

    if (watcher.cancelled.load(.acquire) or interrupted or cancelled(opts.cancel)) {
        _ = try pending.flushMessage(ap, false, &final_text);
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
        const note = try shared.deadlineNote(gpa, "agy", watcher.timed_out_runtime_ms);
        defer gpa.free(note);
        setDelegateError(note);
        _ = try ap.append(.{ .system_note = .{ .text = note } });
        return error.DelegateTimeout;
    }
    if (!done and !failed) {
        server_exited = true;
        return error.AgyServerExited;
    }
    if (failed) {
        const note = if (guest_auth.loginRequiredBackend(failure_text) != null)
            try gpa.dupe(u8, failure_text)
        else
            try std.fmt.allocPrint(gpa, "Antigravity request failed: {s}. Your conversation is saved and continues with your next message.", .{failure_text});
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
