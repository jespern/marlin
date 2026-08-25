//! TUI client: libvaxis. Modal (insert/normal), single pane (M2).
//! See docs/ARCHITECTURE.md §8 for the target layout; splits/session picker
//! land in M4. This client is a pure protocol consumer: attach.Conn in,
//! blocks out. Deltas are ephemeral; finalized blocks replace them.
//!
//! Layout (M3):
//!   ┌─ session view: blocks, streaming region ─┐
//!   ├─ prompt panel (3-10 lines, grows with content) ┤
//!   └─ status: state · model · tokens · ctx ────┤
//!
//! Keys:
//!   insert:  type → input; Enter send; Shift+Enter/Alt+Enter/Ctrl+J newline;
//!            Up/Down or Ctrl+P/N move lines or walk history at the edges;
//!            readline/macOS movement and deletion chords are supported;
//!            Esc → normal (draft survives); Ctrl+C interrupts active work
//!   normal:  ? shortcuts; Esc/i insert; j/k scroll; g/G top/bottom;
//!            a archive current + advance; A archive finished children; q quit
//!   global:  Ctrl+L clears/redraws and returns to bottom; Ctrl+T toggles
//!            the expanded tool transcript
//!   approval pending: y approve, n deny (both modes, input empty)
//!   commands: /model <m>, /effort <level>, /new, /compact,
//!             /archive, /reboot [--build], /help, /quit
//!   shortcuts: !c (copy last full tool output), !rb (reboot with build)
//!   paste:   bracketed paste; large pastes become [paste #N: X lines]
//!            chips, expanded into the message on send.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const config = @import("../core/config.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const credentials = @import("../core/credentials.zig");
const Editor = @import("editor.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    /// Animation clock; posted only while a turn is running.
    tick,
    /// Bracketed paste text (allocated by the loop's paste allocator = gpa;
    /// handler frees).
    paste: []const u8,
    /// One raw NDJSON line from the daemon (gpa-owned; handler frees).
    daemon_line: []u8,
    daemon_gone,
};

const Mode = enum { insert, normal };

pub const RebootRequest = enum { none, plain, build };

const ComposerCommand = struct {
    name: []const u8,
    usage: []const u8 = "",
    description: []const u8,
    accepts_args: bool = false,
};

/// Visible canonical commands and terse aliases. `/q` remains accepted by
/// the dispatcher, while prefix matching completes it to `/quit`.
const composer_commands = [_]ComposerCommand{
    .{ .name = "/model", .usage = " [model]", .description = "switch model or open the picker", .accepts_args = true },
    .{ .name = "/effort", .usage = " [level]", .description = "set reasoning effort or open the picker", .accepts_args = true },
    .{ .name = "/sandbox", .usage = " [on|off]", .description = "toggle the shell sandbox for this session", .accepts_args = true },
    .{ .name = "/permissions", .usage = " [full|default]", .description = "full access (no prompts) or default approvals", .accepts_args = true },
    .{ .name = "/network", .usage = " [on|off|status]", .description = "control managed-tool domain blocking", .accepts_args = true },
    .{ .name = "/sessions", .description = "switch sessions" },
    .{ .name = "/new", .description = "start a new session" },
    .{ .name = "/archive", .usage = " [children]", .description = "archive this session, or its finished children", .accepts_args = true },
    .{ .name = "/compact", .description = "compact the current context" },
    .{ .name = "/reboot", .usage = " [--build]", .description = "restart Marlin", .accepts_args = true },
    .{ .name = "/help", .description = "show commands and key bindings" },
    .{ .name = "/quit", .description = "leave Marlin" },
    .{ .name = "!c", .description = "copy the last full tool output" },
    .{ .name = "!rb", .description = "rebuild and restart Marlin" },
};

const CommandMatches = struct {
    indices: [composer_commands.len]usize = undefined,
    len: usize = 0,
};

const PickerKind = enum { model, effort, session };

/// Baked display lines for blocks of completed turns. Line contents point
/// into `arena_state` (derived strings) or App-owned block text; both stay
/// valid until reset. Keyed by width/transcript-toggle plus an epoch the
/// App bumps whenever existing blocks mutate or the session switches.
const LayoutCache = struct {
    arena_state: ?*std.heap.ArenaAllocator = null,
    lines: std.ArrayList(Line) = .empty,
    covered: usize = 0,
    width: usize = 0,
    expanded: bool = false,
    epoch: u64 = 0,
    label_state: []const u8 = "",

    fn allocator(self: *LayoutCache, gpa: std.mem.Allocator) !std.mem.Allocator {
        if (self.arena_state == null) {
            const st = try gpa.create(std.heap.ArenaAllocator);
            st.* = .init(gpa);
            self.arena_state = st;
        }
        return self.arena_state.?.allocator();
    }

    fn reset(self: *LayoutCache, gpa: std.mem.Allocator) void {
        if (self.arena_state) |st| {
            st.deinit();
            gpa.destroy(st);
        }
        // The lines list itself lives in the arena; dropping the arena
        // dropped it too.
        self.* = .{};
    }
};

/// A block reduced to what the renderer needs (owned copies).
const RenderBlock = struct {
    kind: block.BlockKind,
    /// Durable identity from the block log. Zero marks an optimistic local
    /// echo that will be reconciled when the daemon block arrives.
    seq: u64 = 0,
    turn_id: u64 = 0,
    /// Primary text (message text, tool output, note...).
    text: []u8,
    /// tool_call: "name" — used for the collapsed header line.
    label: []u8,
    status: block.ToolStatus = .ok,
    /// Content-addressed uncapped tool output. Null means `text` is already
    /// the complete result and can be copied without another daemon query.
    full_body_ref: ?[]u8 = null,
    /// Locally inserted for instant submit feedback. The matching durable
    /// block clears this bit instead of producing a duplicate render block.
    pending_echo: bool = false,

    fn deinit(self: *RenderBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.label);
        if (self.full_body_ref) |ref| gpa.free(ref);
    }
};

fn reconcilePendingEcho(
    blocks: []RenderBlock,
    kind: block.BlockKind,
    text: []const u8,
    seq: u64,
    turn_id: u64,
) bool {
    for (blocks) |*rendered| {
        if (rendered.pending_echo and rendered.kind == kind and std.mem.eql(u8, rendered.text, text)) {
            rendered.pending_echo = false;
            rendered.seq = seq;
            rendered.turn_id = turn_id;
            return true;
        }
    }
    return false;
}

const PendingApproval = struct {
    id_buf: [32]u8 = undefined,
    id_len: usize = 0,
    tool_buf: [64]u8 = undefined,
    tool_len: usize = 0,
    args_buf: [256]u8 = undefined,
    args_len: usize = 0,

    fn id(self: *const PendingApproval) []const u8 {
        return self.id_buf[0..self.id_len];
    }
    fn tool(self: *const PendingApproval) []const u8 {
        return self.tool_buf[0..self.tool_len];
    }
    fn args(self: *const PendingApproval) []const u8 {
        return self.args_buf[0..self.args_len];
    }
};

const SelectionPoint = struct {
    line: usize,
    /// Terminal cell column, not a byte offset.
    col: usize,

    fn before(a: SelectionPoint, b: SelectionPoint) bool {
        return a.line < b.line or (a.line == b.line and a.col <= b.col);
    }
};

const Selection = struct {
    lo: SelectionPoint,
    hi: SelectionPoint,

    fn init(a: SelectionPoint, b: SelectionPoint) Selection {
        return if (a.before(b)) .{ .lo = a, .hi = b } else .{ .lo = b, .hi = a };
    }

    /// Selected terminal-cell interval on `line`, end-exclusive and clamped
    /// to the rendered text width. Mouse endpoints themselves are inclusive.
    fn columns(self: Selection, line: usize, line_width: usize) ?struct { start: usize, end: usize } {
        if (line < self.lo.line or line > self.hi.line) return null;
        const start = if (line == self.lo.line) @min(self.lo.col, line_width) else 0;
        const wanted_end = if (line == self.hi.line) self.hi.col +| 1 else line_width;
        return .{ .start = start, .end = @min(wanted_end, line_width) };
    }
};

const SessionSummary = struct {
    sid: u64,
    parent_sid: ?u64,
    kind: proto.SessionKind,
    title: []u8,
    cwd: []u8,
    model: []u8,
    effort: proto.ReasoningEffort,
    state: proto.SessionState,
    created_at: i64,
    label: []u8,
    /// Effective shell-sandbox state (session toggle AND verified backend).
    sandboxed: bool,
    /// Whether managed tools enforce the loaded hostname policy.
    network_filtering: bool,

    fn deinit(self: *SessionSummary, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.cwd);
        gpa.free(self.model);
        gpa.free(self.label);
    }
};

/// Inactive sessions keep their complete client-side view state without
/// remaining subscribed to their block streams. Moving these containers in
/// and out of App is allocation-free after the first visit.
const SavedSessionView = struct {
    editor: Editor,
    blocks: std.ArrayList(RenderBlock),
    delta: std.ArrayList(u8),
    reasoning_delta: std.ArrayList(u8),
    state: proto.SessionState,
    model: std.ArrayList(u8),
    effort: proto.ReasoningEffort,
    cwd: std.ArrayList(u8),
    tokens_in: u64,
    tokens_out: u64,
    context_used: u64,
    context_limit: u64,
    scroll_up: usize,
    last_total_lines: usize,
    last_first_visible: usize,
    last_view_h: usize,
    pending: ?PendingApproval,
    sel_anchor: ?SelectionPoint,
    sel_head: SelectionPoint,
    sel_dragging: bool,
    copy_pending: bool,
    show_tool_transcript: bool,
    spinner_frame: usize,
    turn_started_ms: i64,
    call_started_ms: i64,
    last_seq: u64,

    fn deinit(self: *SavedSessionView, gpa: std.mem.Allocator) void {
        self.editor.deinit();
        for (self.blocks.items) |*rb| rb.deinit(gpa);
        self.blocks.deinit(gpa);
        self.delta.deinit(gpa);
        self.reasoning_delta.deinit(gpa);
        self.model.deinit(gpa);
        self.cwd.deinit(gpa);
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn: *attach.Conn,
    sid: u64,
    editor: Editor,

    mode: Mode = .insert,
    /// Terminal columns (updated on every winsize event); used by handleKey
    /// for the editor's vertical-move edge detection so it matches draw().
    term_cols: usize = 80,
    blocks: std.ArrayList(RenderBlock) = .empty,
    delta: std.ArrayList(u8) = .empty,
    reasoning_delta: std.ArrayList(u8) = .empty,
    state: proto.SessionState = .idle,
    model: std.ArrayList(u8) = .empty,
    effort: proto.ReasoningEffort = .auto,
    /// Session root from daemon metadata, not necessarily the attach
    /// process's current directory.
    cwd: std.ArrayList(u8) = .empty,
    /// Used only to render cwd with a compact ~/ prefix.
    home: std.ArrayList(u8) = .empty,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    context_used: u64 = 0,
    context_limit: u64 = 0,
    /// Highest durable block incorporated for the active session.
    last_seq: u64 = 0,
    /// 0 = pinned to bottom; N = scrolled up N lines.
    scroll_up: usize = 0,
    /// Line count of the last rendered frame; used to keep the view
    /// anchored (not sliding) when new lines arrive while scrolled up.
    last_total_lines: usize = 0,
    /// View geometry of the last frame (for mouse row → line mapping).
    last_first_visible: usize = 0,
    last_view_h: usize = 0,
    pending: ?PendingApproval = null,
    /// Selector overlay: null = closed; value = highlighted index into the
    /// filtered model or effort list (see pickerItems).
    picker: ?usize = null,
    picker_kind: PickerKind = .model,
    /// Compact normal-mode shortcut reference opened with `?`.
    shortcut_help: bool = false,
    /// Highlighted row in the command/shortcut autocomplete menu. The menu
    /// itself is derived from editor text and therefore needs no open flag.
    command_selection: usize = 0,
    /// Type-to-filter query while the picker is open.
    picker_filter: std.ArrayList(u8) = .empty,
    /// Full model catalog from the daemon (owned copies). Empty until
    /// model_list_result arrives; picker falls back to cfg.model_favorites.
    catalog: std.ArrayList([]u8) = .empty,
    /// Optional provider-published pricing keyed by model id. Model strings
    /// are separately owned so legacy model-list replies remain valid.
    catalog_pricing: std.ArrayList(proto.ModelPricing) = .empty,
    /// Live lightweight session catalog from session_watch. Labels back the
    /// existing fuzzy picker; full view state lives in saved_views.
    sessions: std.ArrayList(SessionSummary) = .empty,
    session_labels: std.ArrayList([]const u8) = .empty,
    /// Monotonic catalog of active and archived ids, seeded before entering
    /// the TUI. It lets visible handles remain globally unambiguous even
    /// though session_watch intentionally omits archived rows.
    known_session_ids: std.ArrayList(u64) = .empty,
    saved_views: std.AutoHashMapUnmanaged(u64, *SavedSessionView) = .empty,
    background_approvals: std.AutoHashMapUnmanaged(u64, PendingApproval) = .empty,
    recent_sessions: std.ArrayList(u64) = .empty,
    recent_cursor: usize = 0,
    /// Character-precise mouse selection over the session view. Lines are
    /// absolute layout indices; columns are terminal cells within the line.
    sel_anchor: ?SelectionPoint = null,
    sel_head: SelectionPoint = .{ .line = 0, .col = 0 },
    sel_dragging: bool = false,
    /// Set when a selection was completed (mouse released): next frame
    /// copies the selected cells via OSC52 and clears the flag.
    copy_pending: bool = false,
    /// Keyboard yanks clear the selection highlight once copied (vim visual-
    /// mode y); mouse selections keep theirs.
    sel_clear_after_copy: bool = false,
    /// Text ready for the event loop to send through OSC52. Blob responses
    /// arrive in the daemon reader path, where the terminal writer is not
    /// available, so `!c` stages the bytes here for the next frame.
    clipboard_pending: std.ArrayList(u8) = .empty,
    /// Successful non-diff tool runs are rolled up by default. Errors and
    /// diffs remain visible even when the rest of the transcript is hidden.
    show_tool_transcript: bool = false,
    /// Ctrl+L asks the event loop to invalidate libvaxis's previous-screen
    /// cache so the next render repaints every terminal cell.
    refresh_requested: bool = false,
    spinner_frame: usize = 0,
    /// Wall-clock ms when the active session's current turn entered
    /// .running; drives the elapsed counter on the Working line.
    turn_started_ms: i64 = 0,
    /// Wall ms when the tool call now executing began (0 = none). Stamped
    /// as call/result blocks stream in; drives the per-call timer on the
    /// Working line.
    call_started_ms: i64 = 0,
    /// Provider stream telemetry (ephemeral, ~1/s while receiving):
    /// cumulative bytes this round, ms since the last visible delta, and
    /// when the last report arrived (0 = none; stale reports are hidden).
    stream_bytes: u64 = 0,
    stream_quiet_ms: u64 = 0,
    stream_status_at_ms: i64 = 0,
    animation_active: std.atomic.Value(bool) = .init(false),
    animation_stop: std.atomic.Value(bool) = .init(false),
    cfg: config.Config = .{},
    /// Baked layout of completed turns; see LayoutCache.
    layout_cache: LayoutCache = .{},
    /// Bumped whenever existing blocks mutate in place or the block list is
    /// replaced (session switch) — invalidates layout_cache.
    layout_epoch: u64 = 0,
    /// Copy-mode (vim-style keyboard selection over the transcript):
    /// non-null = active. Coordinates are absolute layout lines, like the
    /// mouse selection.
    copy_cursor: ?SelectionPoint = null,
    /// Whether the pending selection is line-wise (V / bare y).
    copy_linewise: bool = false,
    /// Rendered width and text of the cursor's line, captured by draw() so
    /// $/w/b know the line without recomputing layout in the key handler.
    copy_cursor_line_width: usize = 0,
    copy_cursor_line_text: std.ArrayList(u8) = .empty,
    /// Last yanked text; p in the composer pastes it.
    yank_register: std.ArrayList(u8) = .empty,
    /// Composer operator-pending state: 'd'/'c'/'y' awaiting a motion or
    /// text object; pending_obj holds 'i'/'a' awaiting the object key.
    pending_op: u8 = 0,
    pending_obj: u8 = 0,
    /// Numeric prefix under construction (3w, d2w, 2dd). 0 = none.
    pending_count: usize = 0,
    /// 'f'/'t'/'F'/'T' awaiting its target character.
    pending_find: u8 = 0,
    /// vim r awaiting the replacement character.
    pending_replace: bool = false,
    /// g pressed, awaiting g/t/T (gg top, gt/gT session cycling).
    pending_g: bool = false,
    /// Last f/t/F/T for ; and , repeats.
    last_find_kind: u8 = 0,
    last_find_ch: u8 = 0,
    /// The yank register holds whole lines (dd/yy/cc/V); p pastes below.
    yank_linewise: bool = false,
    /// /permissions full is active for this session (client-side mirror of
    /// the daemon's approval mode; a daemon restart resets both to default).
    permissions_full: bool = false,
    /// Transient one-line notice shown in the status bar.
    notice: std.ArrayList(u8) = .empty,
    should_quit: bool = false,
    awaiting_new_session: bool = false,
    pending_new_cwd: std.ArrayList(u8) = .empty,
    /// Set by /reboot: after clean TUI teardown, run() returns this to
    /// cli.zig which execs `marlin reboot [--build] --then attach @<sid>`.
    reboot_request: RebootRequest = .none,

    fn deinit(self: *App) void {
        self.copy_cursor_line_text.deinit(self.gpa);
        self.yank_register.deinit(self.gpa);
        self.layout_cache.reset(self.gpa);
        self.picker_filter.deinit(self.gpa);
        for (self.catalog.items) |m| self.gpa.free(m);
        self.catalog.deinit(self.gpa);
        for (self.catalog_pricing.items) |pricing| self.gpa.free(pricing.model);
        self.catalog_pricing.deinit(self.gpa);
        for (self.sessions.items) |*session| session.deinit(self.gpa);
        self.sessions.deinit(self.gpa);
        self.session_labels.deinit(self.gpa);
        self.known_session_ids.deinit(self.gpa);
        var saved_it = self.saved_views.valueIterator();
        while (saved_it.next()) |saved| {
            saved.*.deinit(self.gpa);
            self.gpa.destroy(saved.*);
        }
        self.saved_views.deinit(self.gpa);
        self.background_approvals.deinit(self.gpa);
        self.recent_sessions.deinit(self.gpa);
        self.pending_new_cwd.deinit(self.gpa);
        self.clipboard_pending.deinit(self.gpa);
        for (self.blocks.items) |*rb| rb.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.delta.deinit(self.gpa);
        self.reasoning_delta.deinit(self.gpa);
        self.model.deinit(self.gpa);
        self.cwd.deinit(self.gpa);
        self.home.deinit(self.gpa);
        self.notice.deinit(self.gpa);
        self.editor.deinit();
    }

    fn setNotice(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.notice.clearRetainingCapacity();
        self.notice.print(self.gpa, fmt, args) catch {};
    }

    fn setModelStr(self: *App, m: []const u8) void {
        self.model.clearRetainingCapacity();
        self.model.appendSlice(self.gpa, m) catch {};
    }

    fn setCwdStr(self: *App, cwd: []const u8) void {
        self.cwd.clearRetainingCapacity();
        self.cwd.appendSlice(self.gpa, cwd) catch {};
    }

    fn setHomeStr(self: *App, home: []const u8) void {
        self.home.clearRetainingCapacity();
        self.home.appendSlice(self.gpa, home) catch {};
    }

    fn sessionSummary(self: *const App, sid: u64) ?*const SessionSummary {
        for (self.sessions.items) |*session| {
            if (session.sid == sid) return session;
        }
        return null;
    }

    fn rememberSession(self: *App, sid: u64) void {
        for (self.known_session_ids.items) |known| if (known == sid) return;
        self.known_session_ids.append(self.gpa, sid) catch {};
    }

    fn displaySessionHandle(self: *const App, buf: *session_handle.Full, sid: u64) []const u8 {
        return session_handle.display(buf, sid, self.known_session_ids.items);
    }

    fn sessionIdForLabel(self: *const App, label: []const u8) ?u64 {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.label, label)) return session.sid;
        }
        return null;
    }

    fn resetActiveAfterMove(self: *App) void {
        self.copy_cursor = null;
        self.layout_epoch +%= 1;
        self.editor = Editor.init(self.gpa);
        self.blocks = .empty;
        self.delta = .empty;
        self.reasoning_delta = .empty;
        self.state = .idle;
        self.model = .empty;
        self.effort = .auto;
        self.cwd = .empty;
        self.tokens_in = 0;
        self.tokens_out = 0;
        self.context_used = 0;
        self.context_limit = 0;
        self.last_seq = 0;
        self.scroll_up = 0;
        self.last_total_lines = 0;
        self.last_first_visible = 0;
        self.last_view_h = 0;
        self.pending = null;
        self.sel_anchor = null;
        self.sel_head = .{ .line = 0, .col = 0 };
        self.sel_dragging = false;
        self.copy_pending = false;
        self.sel_clear_after_copy = false;
        self.show_tool_transcript = false;
        self.spinner_frame = 0;
        self.turn_started_ms = 0;
        self.call_started_ms = 0;
    }

    fn saveActiveView(self: *App) !void {
        const saved = try self.gpa.create(SavedSessionView);
        errdefer self.gpa.destroy(saved);
        saved.* = .{
            .editor = self.editor,
            .blocks = self.blocks,
            .delta = self.delta,
            .reasoning_delta = self.reasoning_delta,
            .state = self.state,
            .model = self.model,
            .effort = self.effort,
            .cwd = self.cwd,
            .tokens_in = self.tokens_in,
            .tokens_out = self.tokens_out,
            .context_used = self.context_used,
            .context_limit = self.context_limit,
            .scroll_up = self.scroll_up,
            .last_total_lines = self.last_total_lines,
            .last_first_visible = self.last_first_visible,
            .last_view_h = self.last_view_h,
            .pending = self.pending,
            .sel_anchor = self.sel_anchor,
            .sel_head = self.sel_head,
            .sel_dragging = self.sel_dragging,
            .copy_pending = self.copy_pending,
            .show_tool_transcript = self.show_tool_transcript,
            .spinner_frame = self.spinner_frame,
            .turn_started_ms = self.turn_started_ms,
            .call_started_ms = self.call_started_ms,
            .last_seq = self.last_seq,
        };
        try self.saved_views.put(self.gpa, self.sid, saved);
        self.resetActiveAfterMove();
    }

    fn restoreSavedView(self: *App, saved: *SavedSessionView) void {
        self.copy_cursor = null;
        self.layout_epoch +%= 1;
        self.editor = saved.editor;
        self.blocks = saved.blocks;
        self.delta = saved.delta;
        self.reasoning_delta = saved.reasoning_delta;
        self.state = saved.state;
        self.model = saved.model;
        self.effort = saved.effort;
        self.cwd = saved.cwd;
        self.tokens_in = saved.tokens_in;
        self.tokens_out = saved.tokens_out;
        self.context_used = saved.context_used;
        self.context_limit = saved.context_limit;
        self.scroll_up = saved.scroll_up;
        self.last_total_lines = saved.last_total_lines;
        self.last_first_visible = saved.last_first_visible;
        self.last_view_h = saved.last_view_h;
        self.pending = saved.pending;
        self.sel_anchor = saved.sel_anchor;
        self.sel_head = saved.sel_head;
        self.sel_dragging = saved.sel_dragging;
        self.copy_pending = saved.copy_pending;
        self.show_tool_transcript = saved.show_tool_transcript;
        self.spinner_frame = saved.spinner_frame;
        self.turn_started_ms = saved.turn_started_ms;
        self.call_started_ms = saved.call_started_ms;
        self.last_seq = saved.last_seq;
    }

    fn touchRecentSession(self: *App, sid: u64) void {
        for (self.recent_sessions.items, 0..) |recent, i| {
            if (recent == sid) {
                _ = self.recent_sessions.orderedRemove(i);
                break;
            }
        }
        self.recent_sessions.insert(self.gpa, 0, sid) catch return;
        self.recent_cursor = 0;
    }

    fn switchSession(self: *App, sid: u64, touch_recent: bool) !void {
        if (sid == self.sid) return;
        const old_sid = self.sid;
        try self.saveActiveView();
        self.conn.send(.{ .unsub = .{ .sid = old_sid } }) catch {};
        self.sid = sid;

        if (self.saved_views.get(sid)) |saved| {
            _ = self.saved_views.remove(sid);
            self.restoreSavedView(saved);
            self.gpa.destroy(saved);
        } else if (self.sessionSummary(sid)) |summary| {
            try self.model.appendSlice(self.gpa, summary.model);
            try self.cwd.appendSlice(self.gpa, summary.cwd);
            self.effort = summary.effort;
            self.state = summary.state;
        }
        if (self.background_approvals.get(sid)) |pending| {
            self.pending = pending;
            _ = self.background_approvals.remove(sid);
        }

        if (touch_recent) self.touchRecentSession(sid);
        self.animation_active.store(self.state == .running, .release);
        const from_seq = if (self.last_seq == 0) 1 else self.last_seq +| 1;
        self.conn.send(.{ .sub = .{ .sid = sid, .from_seq = from_seq } }) catch {};
        self.rememberSession(sid);
        var handle_buf: session_handle.Full = undefined;
        self.setNotice("session → {s}", .{self.displaySessionHandle(&handle_buf, sid)});
    }

    fn cycleSession(self: *App, direction: i8) void {
        if (self.recent_sessions.items.len < 2) return;
        const len = self.recent_sessions.items.len;
        if (direction > 0) {
            self.recent_cursor = (self.recent_cursor + 1) % len;
        } else {
            self.recent_cursor = if (self.recent_cursor == 0) len - 1 else self.recent_cursor - 1;
        }
        const sid = self.recent_sessions.items[self.recent_cursor];
        self.switchSession(sid, false) catch self.setNotice("could not switch session", .{});
    }

    /// Ngt: jump to the Nth most-recent session (1 = current top of the
    /// recency list). Counts past the end clamp to the oldest, like vim.
    fn jumpToSession(self: *App, ordinal: usize) void {
        const idx = recentOrdinalIndex(self.recent_sessions.items.len, ordinal) orelse return;
        self.recent_cursor = idx;
        const sid = self.recent_sessions.items[idx];
        self.switchSession(sid, false) catch self.setNotice("could not switch session", .{});
    }

    fn recentOrdinalIndex(len: usize, ordinal: usize) ?usize {
        if (len == 0 or ordinal == 0) return null;
        return @min(ordinal - 1, len - 1);
    }

    fn replaceSessionSummaries(self: *App, incoming: []const proto.SessionInfo) void {
        for (incoming) |info| self.rememberSession(info.sid);
        for (self.sessions.items) |*session| session.deinit(self.gpa);
        self.sessions.clearRetainingCapacity();
        self.session_labels.clearRetainingCapacity();

        for (incoming) |info| {
            const title = self.gpa.dupe(u8, info.title) catch continue;
            const cwd = self.gpa.dupe(u8, info.cwd) catch {
                self.gpa.free(title);
                continue;
            };
            const model = self.gpa.dupe(u8, info.model) catch {
                self.gpa.free(title);
                self.gpa.free(cwd);
                continue;
            };
            const identity = if (info.title.len > 0) info.title else info.model;
            const hierarchy = if (info.parent_sid != null) @as([]const u8, "  ↳ ") else "";
            var handle_buf: session_handle.Full = undefined;
            const label = std.fmt.allocPrint(self.gpa, "{s}{s}  {s} · {s} · {s}", .{
                hierarchy,
                self.displaySessionHandle(&handle_buf, info.sid),
                identity,
                @tagName(info.state),
                info.cwd,
            }) catch {
                self.gpa.free(title);
                self.gpa.free(cwd);
                self.gpa.free(model);
                continue;
            };
            self.sessions.append(self.gpa, .{
                .sid = info.sid,
                .parent_sid = info.parent_sid,
                .kind = info.kind,
                .title = title,
                .cwd = cwd,
                .model = model,
                .effort = info.effort,
                .state = info.state,
                .created_at = info.created_at,
                .label = label,
                .sandboxed = info.sandboxed,
                .network_filtering = info.network_filtering,
            }) catch {
                self.gpa.free(title);
                self.gpa.free(cwd);
                self.gpa.free(model);
                self.gpa.free(label);
                continue;
            };
            self.session_labels.append(self.gpa, label) catch {};

            var known_recent = false;
            for (self.recent_sessions.items) |recent| {
                if (recent == info.sid) known_recent = true;
            }
            if (!known_recent) self.recent_sessions.append(self.gpa, info.sid) catch {};

            if (info.sid == self.sid) {
                self.state = info.state;
            } else if (self.saved_views.get(info.sid)) |saved| {
                saved.state = info.state;
            }
            if (info.state != .awaiting_approval) _ = self.background_approvals.remove(info.sid);
        }

        // Default snapshots omit archived sessions. Keep MRU cycling aligned
        // with exactly what the picker can reach.
        var recent_i: usize = 0;
        while (recent_i < self.recent_sessions.items.len) {
            if (self.sessionSummary(self.recent_sessions.items[recent_i]) == null) {
                _ = self.recent_sessions.orderedRemove(recent_i);
            } else {
                recent_i += 1;
            }
        }
        self.recent_cursor = 0;
    }

    const InflightCall = struct { rb: *const RenderBlock, queued: usize };

    /// The tool call executing right now. Within the active turn's tail
    /// (after the last user_msg/steer), the daemon records calls before
    /// running them in order, so the (results+1)-th call is live whenever
    /// calls outnumber results.
    fn currentInflightCall(self: *const App) ?InflightCall {
        var start = self.blocks.items.len;
        while (start > 0) : (start -= 1) {
            const k = self.blocks.items[start - 1].kind;
            if (k == .user_msg or k == .steer) break;
        }
        var calls: usize = 0;
        var results: usize = 0;
        for (self.blocks.items[start..]) |rb| switch (rb.kind) {
            .tool_call => calls += 1,
            .tool_result => results += 1,
            else => {},
        };
        if (calls <= results) return null;
        var seen: usize = 0;
        for (self.blocks.items[start..]) |*rb| {
            if (rb.kind != .tool_call) continue;
            if (seen == results) return .{ .rb = rb, .queued = calls - results - 1 };
            seen += 1;
        }
        return null;
    }

    fn pushBlock(self: *App, kind: block.BlockKind, text: []const u8, label: []const u8, status: block.ToolStatus) void {
        self.pushBlockPending(kind, text, label, status, false);
    }

    fn pushDurableBlock(
        self: *App,
        b: block.Block,
        kind: block.BlockKind,
        text: []const u8,
        label: []const u8,
        status: block.ToolStatus,
    ) void {
        const before = self.blocks.items.len;
        self.pushBlock(kind, text, label, status);
        if (self.blocks.items.len > before) {
            const rendered = &self.blocks.items[self.blocks.items.len - 1];
            rendered.seq = b.seq;
            rendered.turn_id = b.turn_id;
        }
    }

    fn pushDurableToolResult(
        self: *App,
        b: block.Block,
        text: []const u8,
        status: block.ToolStatus,
        full_body_ref: ?[]const u8,
    ) void {
        const before = self.blocks.items.len;
        self.pushDurableBlock(b, .tool_result, text, "", status);
        if (self.blocks.items.len == before) return;
        if (full_body_ref) |ref| {
            self.blocks.items[self.blocks.items.len - 1].full_body_ref = self.gpa.dupe(u8, ref) catch null;
        }
    }

    fn pushBlockPending(
        self: *App,
        kind: block.BlockKind,
        text: []const u8,
        label: []const u8,
        status: block.ToolStatus,
        pending_echo: bool,
    ) void {
        const t = self.gpa.dupe(u8, text) catch return;
        const l = self.gpa.dupe(u8, label) catch {
            self.gpa.free(t);
            return;
        };
        self.blocks.append(self.gpa, .{
            .kind = kind,
            .text = t,
            .label = l,
            .status = status,
            .pending_echo = pending_echo,
        }) catch {
            self.gpa.free(t);
            self.gpa.free(l);
        };
    }

    // ------------------------------------------------------ daemon input --

    fn handleDaemonLine(self: *App, line: []u8) void {
        defer self.gpa.free(line);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const msg = proto.decode(proto.DaemonMsg, arena_state.allocator(), line) catch return;

        switch (msg) {
            .blk => |b| {
                if (b.sid != self.sid) return;
                if (b.b.seq <= self.last_seq) return;
                self.last_seq = b.b.seq;
                self.applyBlock(b.b);
            },
            .delta => |d| {
                if (d.sid != self.sid) return;
                self.delta.appendSlice(self.gpa, d.text) catch {};
            },
            .reasoning_delta => |d| {
                if (d.sid != self.sid) return;
                self.reasoning_delta.appendSlice(self.gpa, d.text) catch {};
            },
            .stream_status => |ss| {
                if (ss.sid != self.sid) return;
                self.stream_bytes = ss.bytes;
                self.stream_quiet_ms = ss.quiet_ms;
                self.stream_status_at_ms = nowWallMs(self.io);
            },
            .status => |s| {
                if (s.sid != self.sid) {
                    if (self.saved_views.get(s.sid)) |saved| saved.state = s.state;
                    return;
                }
                if (s.state == .running and self.state != .running) {
                    self.spinner_frame = 0;
                    self.turn_started_ms = nowWallMs(self.io);
                }
                if (s.state != .running) self.stream_status_at_ms = 0;
                self.state = s.state;
                self.animation_active.store(s.state == .running, .release);
                if (s.state != .awaiting_approval) self.pending = null;
            },
            .approval_request => |ar| {
                var p = PendingApproval{};
                p.id_len = @min(ar.approval_id.len, p.id_buf.len);
                @memcpy(p.id_buf[0..p.id_len], ar.approval_id[0..p.id_len]);
                p.tool_len = @min(ar.tool.len, p.tool_buf.len);
                @memcpy(p.tool_buf[0..p.tool_len], ar.tool[0..p.tool_len]);
                p.args_len = @min(ar.args_json.len, p.args_buf.len);
                @memcpy(p.args_buf[0..p.args_len], ar.args_json[0..p.args_len]);
                if (ar.sid == self.sid)
                    self.pending = p
                else
                    self.background_approvals.put(self.gpa, ar.sid, p) catch {};
            },
            .session_created => |sc| self.handleSessionCreated(sc.sid),
            .session_list_result => |sl| self.replaceSessionSummaries(sl.sessions),
            .blob_result => |blob| self.stageClipboard(blob.bytes),
            .model_list_result => |ml| {
                for (self.catalog.items) |old| self.gpa.free(old);
                self.catalog.clearRetainingCapacity();
                for (self.catalog_pricing.items) |old| self.gpa.free(old.model);
                self.catalog_pricing.clearRetainingCapacity();
                for (ml.models) |m| {
                    const copy = self.gpa.dupe(u8, m) catch continue;
                    self.catalog.append(self.gpa, copy) catch self.gpa.free(copy);
                }
                for (ml.pricing) |pricing| {
                    const model = self.gpa.dupe(u8, pricing.model) catch continue;
                    self.catalog_pricing.append(self.gpa, .{
                        .model = model,
                        .input_per_million = validCatalogRate(pricing.input_per_million),
                        .output_per_million = validCatalogRate(pricing.output_per_million),
                        .tiered = pricing.tiered,
                    }) catch self.gpa.free(model);
                }
            },
            .session_meta => |m| {
                if (m.sid != self.sid) return;
                self.tokens_in = m.tokens_in;
                self.tokens_out = m.tokens_out;
                if (m.context_used > 0) self.context_used = m.context_used;
                if (m.context_limit > 0) self.context_limit = m.context_limit;
            },
            .err => |e| {
                self.setNotice("daemon error {s}: {s}", .{ e.code, e.msg });
            },
            else => {},
        }
    }

    fn applyBlock(self: *App, b: block.Block) void {
        switch (b.body) {
            .user_msg => |u| {
                if (u.synthetic or isLegacyRehydration(u.text)) {
                    const label = rehydrationLabel(self.gpa, u.text) catch return;
                    defer self.gpa.free(label);
                    self.pushDurableBlock(b, .system_note, label, "", .ok);
                } else {
                    if (reconcilePendingEcho(self.blocks.items, .user_msg, u.text, b.seq, b.turn_id))
                        self.layout_epoch +%= 1
                    else
                        self.pushDurableBlock(b, .user_msg, u.text, "", .ok);
                    // Seed input history from the log (replay covers pre-reboot
                    // messages; live blocks cover this session's submits).
                    self.editor.pushHistory(u.text);
                }
            },
            .steer => |s| {
                if (reconcilePendingEcho(self.blocks.items, .steer, s.text, b.seq, b.turn_id))
                    self.layout_epoch +%= 1
                else
                    self.pushDurableBlock(b, .steer, s.text, "", .ok);
            },
            .assistant_msg => |a| {
                // Finalized text replaces the streaming delta.
                self.delta.clearRetainingCapacity();
                self.reasoning_delta.clearRetainingCapacity();
                self.pushDurableBlock(b, .assistant_msg, a.text, "", .ok);
            },
            .reasoning => |r| {
                // Reasoning and progress commentary use distinct live streams
                // but the same durable card type. Clear whichever buffer this
                // finalized block exactly replaces.
                if (std.mem.eql(u8, self.reasoning_delta.items, r.text))
                    self.reasoning_delta.clearRetainingCapacity()
                else if (std.mem.eql(u8, self.delta.items, r.text))
                    self.delta.clearRetainingCapacity();
                self.pushDurableBlock(b, .reasoning, r.text, "", .ok);
            },
            .tool_call => |tc| {
                self.pushDurableBlock(b, .tool_call, tc.args_json, tc.name, .ok);
                // A call with nothing queued ahead of it starts immediately.
                if (self.currentInflightCall()) |cur| {
                    if (cur.queued == 0) self.call_started_ms = nowWallMs(self.io);
                }
            },
            .tool_result => |tr| {
                self.pushDurableToolResult(b, tr.inline_body, tr.status, tr.full_body_ref);
                self.call_started_ms = if (self.currentInflightCall() != null)
                    nowWallMs(self.io)
                else
                    0;
            },
            .approval => |ap| {
                const txt = if (ap.decision) |d| @tagName(d) else "pending";
                self.pushDurableBlock(b, .approval, txt, "", .ok);
            },
            .system_note => |sn| {
                if (!isCompactionStatusNote(sn.text))
                    self.pushDurableBlock(b, .system_note, sn.text, "", .ok);
            },
            .compaction => self.pushDurableBlock(b, .compaction, "context compacted", "", .ok),
        }
        // New content: keep pinned to bottom unless the user scrolled up.
        if (self.scroll_up > 0) self.scroll_up +|= 0; // stay where they are
    }

    // -------------------------------------------------------- user input --

    fn submitInput(self: *App, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed[0] == '/' or trimmed[0] == '!') {
            // Commands are client actions rather than durable user_msg
            // blocks, but they still belong in the local editor history so
            // Up then Enter can repeat them during this client lifetime.
            self.editor.pushHistory(trimmed);
            self.runCommand(trimmed);
            return;
        }
        const was_running = self.state == .running;
        self.conn.send(.{ .input = .{ .sid = self.sid, .text = trimmed } }) catch {
            self.setNotice("send failed — daemon gone?", .{});
            return;
        };
        if (was_running) {
            self.pushBlockPending(.steer, trimmed, "", .ok, true);
            self.setNotice("queued as steer (turn running)", .{});
        } else {
            // The composer becomes a scrollback card immediately. The turn
            // thread's persisted user_msg will reconcile this local echo.
            self.pushBlockPending(.user_msg, trimmed, "", .ok, true);
            self.state = .running;
            self.spinner_frame = 0;
            self.turn_started_ms = nowWallMs(self.io);
            self.animation_active.store(true, .release);
        }
        self.scroll_up = 0;
    }

    fn runCommand(self: *App, cmd: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const head = it.next() orelse return;

        if (std.mem.eql(u8, head, "/quit") or std.mem.eql(u8, head, "/q")) {
            self.should_quit = true;
        } else if (std.mem.eql(u8, head, "/model")) {
            const m = it.rest();
            if (m.len == 0) {
                self.openPicker(.model);
                // Ask the daemon for the full catalog (async; picker shows
                // favorites until the reply lands).
                if (self.catalog.items.len == 0) {
                    self.conn.send(.{ .model_list = .{} }) catch {};
                }
                return;
            }
            self.applyModel(m);
        } else if (std.mem.eql(u8, head, "/effort")) {
            const value = it.rest();
            if (value.len == 0) {
                self.openPicker(.effort);
                return;
            }
            const selected = proto.ReasoningEffort.parse(value) orelse {
                self.setNotice("unknown effort {s} — use auto, none, minimal, low, medium, high, xhigh, or max", .{value});
                return;
            };
            self.applyEffort(selected);
        } else if (std.mem.eql(u8, head, "/permissions")) {
            self.setPermissions(it.rest());
        } else if (std.mem.eql(u8, head, "/sandbox")) {
            self.toggleSandbox(it.rest());
        } else if (std.mem.eql(u8, head, "/network")) {
            self.networkCommand(it.rest());
        } else if (std.mem.eql(u8, head, "/sessions")) {
            self.openPicker(.session);
        } else if (std.mem.eql(u8, head, "/new")) {
            self.newSession() catch {
                self.setNotice("could not create session", .{});
            };
        } else if (std.mem.eql(u8, head, "/archive")) {
            const arg = it.rest();
            if (arg.len == 0) {
                self.archiveCurrentSession();
            } else if (std.mem.eql(u8, arg, "children")) {
                self.archiveFinishedChildren();
            } else {
                self.setNotice("usage: /archive [children]", .{});
            }
        } else if (std.mem.eql(u8, head, "!c")) {
            self.copyLastToolOutput();
        } else if (std.mem.eql(u8, head, "/reboot") or std.mem.eql(u8, head, "!rb")) {
            const arg = it.rest();
            if (self.state == .running or self.state == .awaiting_approval) {
                self.setNotice("turn running — /reboot waits for it (interrupt first if you want force)", .{});
            }
            self.reboot_request = if (std.mem.eql(u8, head, "!rb") or std.mem.eql(u8, arg, "--build")) .build else .plain;
            self.should_quit = true;
        } else if (std.mem.eql(u8, head, "/compact")) {
            if (self.state == .running or self.state == .awaiting_approval) {
                self.setNotice("cannot compact mid-turn", .{});
                return;
            }
            self.conn.send(.{ .session_compact = .{ .sid = self.sid } }) catch return;
            self.setNotice("compacting…", .{});
        } else if (std.mem.eql(u8, head, "/help")) {
            self.setNotice("/sessions · /new · /archive [children] · /model <m> · /effort <level> · /sandbox [on|off] · /permissions [full|default] · /network [on|off|status] · /compact · /reboot [--build] · !c · !rb · /quit", .{});
        } else {
            self.setNotice("unknown command {s} (try /help)", .{head});
        }
    }

    fn stageClipboard(self: *App, text: []const u8) void {
        if (text.len == 0) {
            self.setNotice("last tool output is empty", .{});
            return;
        }
        self.clipboard_pending.clearRetainingCapacity();
        self.clipboard_pending.appendSlice(self.gpa, text) catch {
            self.setNotice("could not stage clipboard output", .{});
        };
    }

    fn copyLastToolOutput(self: *App) void {
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const rendered = self.blocks.items[i];
            if (rendered.kind != .tool_result) continue;
            if (rendered.full_body_ref) |ref| {
                self.conn.send(.{ .blob_get = .{ .hash = ref } }) catch {
                    self.setNotice("could not request full tool output", .{});
                    return;
                };
                self.setNotice("fetching full tool output…", .{});
            } else {
                self.stageClipboard(rendered.text);
            }
            return;
        }
        self.setNotice("no tool output to copy", .{});
    }

    /// Consume the numeric prefix (default 1).
    fn takeCount(self: *App) usize {
        const n = if (self.pending_count == 0) 1 else self.pending_count;
        self.pending_count = 0;
        return n;
    }

    /// Repeat a forward range motion `n` times from the cursor by walking a
    /// scratch cursor; the editor is restored before returning.
    fn repeatForwardRange(self: *App, comptime range_fn: fn (*const Editor) Editor.Range, n: usize) Editor.Range {
        const ed = &self.editor;
        const saved = ed.cursor;
        var end = saved;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = range_fn(ed);
            if (r.end == end and i > 0) break;
            end = r.end;
            ed.cursor = @min(end, ed.text.items.len);
        }
        ed.cursor = saved;
        return .{ .start = saved, .end = end };
    }

    fn repeatBackwardRange(self: *App, comptime range_fn: fn (*const Editor) Editor.Range, n: usize) Editor.Range {
        const ed = &self.editor;
        const saved = ed.cursor;
        var start = saved;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const r = range_fn(ed);
            if (r.start == start and i > 0) break;
            start = r.start;
            ed.cursor = start;
        }
        ed.cursor = saved;
        return .{ .start = start, .end = saved };
    }

    /// Resolve a completed f/t/F/T: either move the cursor or feed the
    /// pending operator (df" / ct)). Inclusive for f, exclusive for t.
    fn resolveFind(self: *App, kind: u8, ch: u8, count: usize) void {
        const ed = &self.editor;
        const forward = kind == 'f' or kind == 't';
        const target = ed.findOnLine(ch, forward, count) orelse {
            self.pending_op = 0;
            return;
        };
        self.last_find_kind = kind;
        self.last_find_ch = ch;
        const t = ed.text.items;
        if (self.pending_op != 0) {
            const op = self.pending_op;
            self.pending_op = 0;
            const range: Editor.Range = switch (kind) {
                'f' => .{ .start = ed.cursor, .end = nextCpEndFor(t, target) },
                't' => .{ .start = ed.cursor, .end = target },
                'F' => .{ .start = target, .end = ed.cursor },
                'T' => .{ .start = nextCpEndFor(t, target), .end = ed.cursor },
                else => return,
            };
            self.applyOperator(op, range);
            return;
        }
        ed.cursor = switch (kind) {
            'f', 'F' => target,
            't' => if (target > 0) target - 1 else 0,
            'T' => nextCpEndFor(t, target),
            else => target,
        };
    }

    fn applyOperator(self: *App, op: u8, range: Editor.Range) void {
        if (range.end <= range.start) return;
        const slice = self.editor.text.items[range.start..range.end];
        self.yank_register.clearRetainingCapacity();
        self.yank_register.appendSlice(self.gpa, slice) catch {};
        self.yank_linewise = slice.len > 0 and slice[slice.len - 1] == '\n';
        switch (op) {
            'y' => self.editor.cursor = range.start,
            'd' => {
                self.editor.pushUndo();
                self.editor.deleteRange(range.start, range.end);
            },
            'c' => {
                self.editor.pushUndo();
                self.editor.deleteRange(range.start, range.end);
                self.mode = .insert;
            },
            else => {},
        }
    }

    /// Second (and third) key of a d/c/y sequence: a motion, a doubled
    /// operator for the whole line, or an i/a text object. Anything else
    /// cancels, vim-style.
    fn operatorKey(self: *App, key: vaxis.Key) void {
        const op = self.pending_op;
        const ed = &self.editor;
        if (self.pending_obj != 0) {
            const around = self.pending_obj == 'a';
            self.pending_op = 0;
            self.pending_obj = 0;
            const range: ?Editor.Range = if (key.matches('w', .{}))
                ed.innerWordRange(around)
            else if (key.matches('"', .{}))
                ed.quoteRange('"', around)
            else if (key.matches('\'', .{}))
                ed.quoteRange('\'', around)
            else if (key.matches('`', .{}))
                ed.quoteRange('`', around)
            else if (key.matches('(', .{}) or key.matches(')', .{}) or key.matches('b', .{}))
                ed.delimRange('(', ')', around)
            else if (key.matches('[', .{}) or key.matches(']', .{}))
                ed.delimRange('[', ']', around)
            else if (key.matches('{', .{}) or key.matches('}', .{}))
                ed.delimRange('{', '}', around)
            else
                null;
            if (range) |r| self.applyOperator(op, r);
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            self.pending_op = 0;
            self.pending_count = 0;
            return;
        }
        if ((key.codepoint >= '1' and key.codepoint <= '9') or
            (key.codepoint == '0' and self.pending_count > 0))
        {
            self.pending_count = self.pending_count * 10 + @as(usize, @intCast(key.codepoint - '0'));
            return;
        }
        if (key.matches('i', .{}) or key.matches('a', .{})) {
            self.pending_obj = if (key.matches('a', .{})) 'a' else 'i';
            return;
        }
        if (key.matches('f', .{}) or key.matches('t', .{}) or
            key.matches('F', .{ .shift = true }) or key.matches('T', .{ .shift = true }))
        {
            // Operator + find: keep the operator pending, await the char.
            self.pending_find = @intCast(key.codepoint);
            return;
        }
        const count = self.takeCount();
        self.pending_op = 0;
        const range: ?Editor.Range = if (key.codepoint == op)
            // dd deletes the line including its newline; cc keeps the shell.
            ed.linesRange(count, op != 'c')
        else if (key.matches('w', .{}))
            self.repeatForwardRange(Editor.wordForwardRange, count)
        else if (key.matches('e', .{}))
            self.repeatForwardRange(Editor.wordEndRange, count)
        else if (key.matches('b', .{}))
            self.repeatBackwardRange(Editor.wordBackRange, count)
        else if (key.matches('$', .{}))
            ed.toLineEndRange()
        else if (key.matches('0', .{}))
            ed.toLineStartRange()
        else
            null;
        if (range) |r| self.applyOperator(op, r);
    }

    /// Enter transcript copy mode with the cursor on the bottom visible line.
    fn enterCopyMode(self: *App) void {
        if (self.last_total_lines == 0) return;
        const line = self.last_first_visible + self.last_view_h -| 1;
        self.copy_cursor = .{ .line = @min(line, self.last_total_lines - 1), .col = 0 };
        self.copy_linewise = false;
        self.setNotice("copy mode · hjkl move · v/V select · y yank · Esc exit", .{});
    }

    /// Keep the copy cursor inside the visible window by adjusting scroll_up
    /// (geometry from the previous frame; draw clamps the rest).
    fn followCopyCursor(self: *App) void {
        const cursor = self.copy_cursor orelse return;
        const total = self.last_total_lines;
        const view = @max(self.last_view_h, 1);
        if (total <= view) {
            self.scroll_up = 0;
            return;
        }
        const max_scroll = total - view;
        var first = total - view - @min(self.scroll_up, max_scroll);
        if (cursor.line < first) first = cursor.line;
        if (cursor.line >= first + view) first = cursor.line + 1 - view;
        self.scroll_up = max_scroll - @min(first, max_scroll);
    }

    /// Clamp the cursor into the (possibly just scrolled) view.
    fn clampCopyCursorToView(self: *App) void {
        var cursor = self.copy_cursor orelse return;
        const total = self.last_total_lines;
        const view = @max(self.last_view_h, 1);
        if (total == 0) return;
        const max_scroll = total -| view;
        const first = total -| view -| @min(self.scroll_up, max_scroll);
        if (cursor.line < first) cursor.line = first;
        if (cursor.line >= first + view) cursor.line = first + view - 1;
        cursor.line = @min(cursor.line, total - 1);
        self.copy_cursor = cursor;
        if (self.sel_anchor != null) self.updateCopySelection(cursor);
    }

    fn updateCopySelection(self: *App, cursor: SelectionPoint) void {
        const a = self.sel_anchor orelse return;
        if (self.copy_linewise) {
            const lo = @min(a.line, cursor.line);
            const hi = @max(a.line, cursor.line);
            self.sel_anchor = .{ .line = lo, .col = 0 };
            self.sel_head = .{ .line = hi, .col = std.math.maxInt(usize) };
        } else {
            self.sel_head = cursor;
        }
    }

    fn yankSelection(self: *App, cursor: SelectionPoint) void {
        if (self.sel_anchor == null) {
            // Bare y yanks the whole cursor line, vim's yy in spirit.
            self.copy_linewise = true;
            self.sel_anchor = cursor;
        }
        self.updateCopySelection(cursor);
        if (!self.copy_linewise) self.sel_head = cursor;
        self.copy_pending = true;
        self.sel_clear_after_copy = true;
        self.copy_cursor = null; // yank ends copy mode
    }

    fn copyModeKey(self: *App, key: vaxis.Key) void {
        var cursor = self.copy_cursor orelse return;
        const total = if (self.last_total_lines > 0) self.last_total_lines else 1;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            if (self.sel_anchor != null) {
                self.sel_anchor = null;
            } else {
                self.copy_cursor = null;
            }
            return;
        } else if (key.matches('y', .{})) {
            self.yankSelection(cursor);
            return;
        } else if (key.matches('v', .{})) {
            self.copy_linewise = false;
            self.sel_anchor = cursor;
            self.sel_head = cursor;
            return;
        } else if (key.matches('V', .{ .shift = true }) or key.matches('V', .{})) {
            self.copy_linewise = true;
            self.sel_anchor = cursor;
            self.updateCopySelection(cursor);
            return;
        } else if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
            cursor.col -|= 1;
        } else if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
            cursor.col +|= 1;
        } else if (key.matches('j', .{})) {
            cursor.line = @min(cursor.line + 1, total - 1);
        } else if (key.matches('k', .{})) {
            cursor.line -|= 1;
        } else if (key.matches('0', .{})) {
            cursor.col = 0;
        } else if (key.matches('$', .{})) {
            cursor.col = self.copy_cursor_line_width -| 1;
        } else if (key.matches('w', .{})) {
            cursor.col = nextWordCol(self.copy_cursor_line_text.items, cursor.col);
        } else if (key.matches('b', .{})) {
            cursor.col = prevWordCol(self.copy_cursor_line_text.items, cursor.col);
        } else if (key.matches('g', .{})) {
            cursor.line = 0;
        } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
            cursor.line = total - 1;
        } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
            cursor.line = @min(cursor.line + 20, total - 1);
        } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
            cursor.line -|= 20;
        } else if (key.matches(vaxis.Key.down, .{})) {
            self.scroll_up -|= 1;
            self.clampCopyCursorToView();
            return;
        } else if (key.matches(vaxis.Key.up, .{})) {
            self.scroll_up +|= 1;
            self.clampCopyCursorToView();
            return;
        } else return;
        self.copy_cursor = cursor;
        if (self.sel_anchor != null) self.updateCopySelection(cursor);
        self.followCopyCursor();
    }

    fn selection(self: *const App) ?Selection {
        const a = self.sel_anchor orelse return null;
        return Selection.init(a, self.sel_head);
    }

    fn openPicker(self: *App, kind: PickerKind) void {
        self.picker_kind = kind;
        self.picker = 0;
        self.picker_filter.clearRetainingCapacity();
        const current = self.pickerCurrent();
        for (self.pickerSource(), 0..) |item, i| {
            const selected = if (kind == .session)
                (self.sessionIdForLabel(item) orelse 0) == self.sid
            else
                std.mem.eql(u8, item, current);
            if (selected) {
                self.picker = i;
                break;
            }
        }
    }

    /// The picker's source list: full model catalog/favorites, or the fixed
    /// effort vocabulary shared with persistence and provider adapters.
    fn pickerSource(self: *const App) []const []const u8 {
        return switch (self.picker_kind) {
            .model => if (self.catalog.items.len > 0) @ptrCast(self.catalog.items) else self.cfg.model_favorites,
            .effort => &proto.ReasoningEffort.choices,
            .session => self.session_labels.items,
        };
    }

    /// Filtered picker items (arena-allocated indices into pickerSource).
    /// Filter: case-insensitive substring; multiple space-separated words
    /// must ALL match ("son 4.5" → claude-sonnet-4.5).
    fn pickerItems(self: *const App, arena: std.mem.Allocator) ![]const []const u8 {
        const source = self.pickerSource();
        const q = self.picker_filter.items;
        if (q.len == 0) return source;
        var out: std.ArrayList([]const u8) = .empty;
        outer: for (source) |m| {
            var words = std.mem.tokenizeScalar(u8, q, ' ');
            while (words.next()) |word| {
                if (containsIgnoreCase(m, word) == null) continue :outer;
            }
            try out.append(arena, m);
        }
        return out.items;
    }

    fn pricingForModel(self: *const App, model: []const u8) ?proto.ModelPricing {
        for (self.catalog_pricing.items) |pricing| {
            if (std.mem.eql(u8, pricing.model, model)) return pricing;
        }
        return null;
    }

    fn applyModel(self: *App, m: []const u8) void {
        if (self.state == .running or self.state == .awaiting_approval) {
            self.setNotice("cannot switch model mid-turn", .{});
            return;
        }
        self.conn.send(.{ .session_set_model = .{ .sid = self.sid, .model = m } }) catch return;
        self.setModelStr(m);
        self.setNotice("model → {s}", .{m});
    }

    fn applyEffort(self: *App, selected: proto.ReasoningEffort) void {
        if (self.state == .running or self.state == .awaiting_approval) {
            self.setNotice("cannot switch effort mid-turn", .{});
            return;
        }
        self.conn.send(.{ .session_set_effort = .{ .sid = self.sid, .effort = selected } }) catch return;
        self.effort = selected;
        self.setNotice("effort → {s}", .{@tagName(selected)});
    }

    /// Effective sandbox state of the active session, from the last watch
    /// snapshot. Before a snapshot arrives, assume the daemon default (the
    /// snapshot follows within the same connect exchange).
    fn currentSandboxed(self: *const App) bool {
        if (self.sessionSummary(self.sid)) |summary| return summary.sandboxed;
        return self.conn.sandbox_available;
    }

    /// /permissions full|default — session-wide approval switch. Full
    /// access means NOTHING asks (the --yolo mode, chosen mid-session);
    /// default restores boundary-crossing prompts. Tracked optimistically:
    /// the daemon rejects mid-turn switches with a visible err notice.
    fn setPermissions(self: *App, arg: []const u8) void {
        const full = if (std.mem.eql(u8, arg, "full"))
            true
        else if (std.mem.eql(u8, arg, "default"))
            false
        else if (arg.len == 0)
            !self.permissions_full
        else {
            self.setNotice("usage: /permissions [full|default]", .{});
            return;
        };
        const mode: []const u8 = if (full) "auto" else "default";
        self.conn.send(.{ .session_set_approvals = .{ .sid = self.sid, .approvals = mode } }) catch return;
        self.permissions_full = full;
        if (full) {
            self.setNotice("permissions: FULL ACCESS — nothing will ask for approval", .{});
        } else {
            self.setNotice("permissions: default — boundary-crossing tools ask again", .{});
        }
    }

    fn toggleSandbox(self: *App, arg: []const u8) void {
        if (self.state == .running or self.state == .awaiting_approval) {
            self.setNotice("cannot toggle sandbox mid-turn", .{});
            return;
        }
        const target = if (arg.len == 0)
            !self.currentSandboxed()
        else if (std.mem.eql(u8, arg, "on"))
            true
        else if (std.mem.eql(u8, arg, "off"))
            false
        else {
            self.setNotice("usage: /sandbox [on|off]", .{});
            return;
        };
        if (target and !self.conn.sandbox_available) {
            self.setNotice("sandbox unavailable on this platform — per-call approvals retained", .{});
            return;
        }
        self.conn.send(.{ .session_set_sandbox = .{ .sid = self.sid, .enabled = target } }) catch return;
        if (target) {
            self.setNotice("sandbox on — workspace shell runs without prompts", .{});
        } else {
            self.setNotice("sandbox off — every shell call asks again", .{});
        }
    }

    fn currentNetworkFiltering(self: *const App) bool {
        if (self.sessionSummary(self.sid)) |summary| return summary.network_filtering;
        return self.conn.network_filtering;
    }

    fn networkCommand(self: *App, arg: []const u8) void {
        if (arg.len == 0 or std.mem.eql(u8, arg, "status")) {
            if (!self.conn.network_filtering) {
                if (self.conn.network_configured) {
                    self.setNotice("network filter unavailable — configured rules failed to load; networking is fail-open", .{});
                } else {
                    self.setNotice("network filter off — no blocklist or deny rules configured", .{});
                }
                return;
            }
            const state = if (self.currentNetworkFiltering()) "on" else "off";
            self.setNotice("network filter {s} — {d} rules from {d} feeds; fetch enforced · shell literals screened", .{
                state,
                self.conn.network_rule_count,
                self.conn.network_feed_count,
            });
            return;
        }
        if (self.state == .running or self.state == .awaiting_approval) {
            self.setNotice("cannot toggle network filtering mid-turn", .{});
            return;
        }
        const target = if (std.mem.eql(u8, arg, "on"))
            true
        else if (std.mem.eql(u8, arg, "off"))
            false
        else {
            self.setNotice("usage: /network [on|off|status]", .{});
            return;
        };
        if (target and !self.conn.network_filtering) {
            if (self.conn.network_configured) {
                self.setNotice("network filter unavailable — configured rules failed to load; reboot after connectivity returns", .{});
            } else {
                self.setNotice("network filter off — add [network] blocklists or deny rules, then reboot", .{});
            }
            return;
        }
        self.conn.send(.{ .session_set_network_filtering = .{ .sid = self.sid, .enabled = target } }) catch return;
        self.setNotice("network filter {s} for this session", .{if (target) @as([]const u8, "on") else "off"});
    }

    fn applyPickerItem(self: *App, item: []const u8) void {
        switch (self.picker_kind) {
            .model => self.applyModel(item),
            .effort => self.applyEffort(proto.ReasoningEffort.parse(item) orelse return),
            .session => self.switchSession(self.sessionIdForLabel(item) orelse return, true) catch
                self.setNotice("could not switch session", .{}),
        }
    }

    fn pickerCurrent(self: *const App) []const u8 {
        return switch (self.picker_kind) {
            .model => self.model.items,
            .effort => @tagName(self.effort),
            .session => "",
        };
    }

    fn newSession(self: *App) !void {
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = try std.process.currentPath(self.io, &cwd_buf);
        try self.conn.send(.{ .session_create = .{
            .cwd = cwd_buf[0..cwd_len],
            .model = self.model.items,
            .effort = self.effort,
        } });
        self.pending_new_cwd.clearRetainingCapacity();
        try self.pending_new_cwd.appendSlice(self.gpa, cwd_buf[0..cwd_len]);
        // The reply is routed through the reader thread; we can't recv here.
        // Optimistic switch happens when session_created arrives — but that
        // message has no sub; simplest correct M2 flow: remember we asked.
        // Handled in handleDaemonLineCreated below via the pending flag.
        self.awaiting_new_session = true;
    }

    fn sessionBelongsToTree(self: *const App, candidate_sid: u64, root_sid: u64) bool {
        var cursor: ?u64 = candidate_sid;
        while (cursor) |sid| {
            if (sid == root_sid) return true;
            const summary = self.sessionSummary(sid) orelse return false;
            cursor = summary.parent_sid;
        }
        return false;
    }

    fn archiveCurrentSession(self: *App) void {
        if (self.state == .running or self.state == .awaiting_approval) {
            self.setNotice("cannot archive a running session — interrupt it first", .{});
            return;
        }

        const archived_sid = self.sid;
        var fallback: ?u64 = null;
        if (self.sessionSummary(archived_sid)) |current| {
            if (current.parent_sid) |parent_sid| {
                if (self.sessionSummary(parent_sid) != null) fallback = parent_sid;
            }
        }
        if (fallback == null) {
            for (self.recent_sessions.items) |candidate_sid| {
                if (!self.sessionBelongsToTree(candidate_sid, archived_sid) and
                    self.sessionSummary(candidate_sid) != null)
                {
                    fallback = candidate_sid;
                    break;
                }
            }
        }

        self.conn.send(.{ .session_archive = .{ .sid = archived_sid } }) catch {
            self.setNotice("could not archive session", .{});
            return;
        };
        if (fallback) |sid| {
            self.switchSession(sid, true) catch {
                self.setNotice("session archived, but could not switch sessions", .{});
                return;
            };
            var handle_buf: session_handle.Full = undefined;
            self.setNotice("archived session {s}", .{self.displaySessionHandle(&handle_buf, archived_sid)});
        } else {
            self.newSession() catch {
                self.setNotice("session archived; use /new to continue", .{});
            };
        }
    }

    /// Archive every finished (idle/err/done) child of the focused session
    /// in one sweep — the one-command answer to a status bar stuck on
    /// "N children · N errors" after task children have been dealt with.
    /// Running or approval-parked children are deliberately left alone.
    fn archiveFinishedChildren(self: *App) void {
        var archived: usize = 0;
        var skipped_active: usize = 0;
        for (self.sessions.items) |session| {
            if (session.parent_sid != self.sid) continue;
            if (session.state == .running or session.state == .awaiting_approval) {
                skipped_active += 1;
                continue;
            }
            self.conn.send(.{ .session_archive = .{ .sid = session.sid } }) catch continue;
            archived += 1;
        }
        if (archived == 0 and skipped_active == 0) {
            self.setNotice("no children to archive", .{});
        } else if (skipped_active > 0) {
            self.setNotice("archived {d}, left {d} still active", .{ archived, skipped_active });
        } else {
            self.setNotice("archived {d} finished child{s}", .{ archived, if (archived == 1) "" else "ren" });
        }
    }

    fn handleSessionCreated(self: *App, sid: u64) void {
        if (!self.awaiting_new_session) return;
        self.awaiting_new_session = false;
        self.rememberSession(sid);
        const model = self.gpa.dupe(u8, self.model.items) catch return;
        defer self.gpa.free(model);
        const effort = self.effort;
        self.switchSession(sid, true) catch {
            self.setNotice("could not switch to new session", .{});
            return;
        };
        if (self.model.items.len == 0) self.setModelStr(model);
        self.effort = effort;
        if (self.cwd.items.len == 0) self.setCwdStr(self.pending_new_cwd.items);
        self.pending_new_cwd.clearRetainingCapacity();
        self.shortcut_help = false;
        var handle_buf: session_handle.Full = undefined;
        self.setNotice("new session {s}", .{self.displaySessionHandle(&handle_buf, sid)});
    }

    fn approveReply(self: *App, granted: bool) void {
        const p = self.pending orelse return;
        self.conn.send(.{ .approve = .{
            .sid = self.sid,
            .approval_id = p.id(),
            .decision = if (granted) .granted else .denied,
        } }) catch return;
        self.pending = null;
    }

    fn interrupt(self: *App) void {
        self.conn.send(.{ .interrupt = .{ .sid = self.sid } }) catch {};
        self.setNotice("interrupt sent", .{});
    }

    fn clearView(self: *App) void {
        self.scroll_up = 0;
        self.sel_anchor = null;
        self.sel_dragging = false;
        self.copy_pending = false;
        self.sel_clear_after_copy = false;
        self.notice.clearRetainingCapacity();
        self.refresh_requested = true;
    }
};

// ------------------------------------------------------------- rendering --

const Palette = struct {
    const user: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true }; // cyan
    // Sampled from the Codex composer in the same terminal (#42454b), so
    // the raised surface has the same contrast instead of approximating it
    // through theme-dependent ANSI grays.
    const prompt_bg: vaxis.Color = .{ .rgb = .{ 0x42, 0x45, 0x4b } };
    const prompt_panel: vaxis.Style = .{ .bg = prompt_bg };
    const prompt_text: vaxis.Style = .{ .bg = prompt_bg };
    const prompt_mark: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 6 }, .bold = true };
    const command_bg: vaxis.Color = .{ .rgb = .{ 0x2d, 0x30, 0x35 } };
    const command_menu: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 7 } };
    const command_name: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 6 }, .bold = true };
    const command_description: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 8 }, .dim = true };
    const command_selected: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 7 } };
    const command_selected_name: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 6 }, .bold = true };
    const command_selected_description: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 7 } };
    const shortcut_panel: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 7 } };
    const shortcut_key: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 6 }, .bold = true };
    const shortcut_text: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 7 } };
    const shortcut_border: vaxis.Style = .{ .fg = .{ .index = 6 } };
    const assistant: vaxis.Style = .{};
    const md_heading_1: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } }, .bold = true };
    const md_heading_2: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true };
    const md_heading_3: vaxis.Style = .{ .bold = true };
    const md_lead: vaxis.Style = .{ .fg = .{ .index = 7 }, .bold = true };
    const md_inline_code_bg: vaxis.Color = .{ .rgb = .{ 0x2d, 0x30, 0x35 } };
    const md_code: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xff, 0xcb, 0x6b } }, .bg = md_inline_code_bg };
    const md_code_panel: vaxis.Style = .{ .bg = md_inline_code_bg };
    const md_code_border: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = md_inline_code_bg, .dim = true };
    const md_table_header_bg: vaxis.Color = .{ .rgb = .{ 0x32, 0x35, 0x3b } };
    /// Table borders and cell separators recede; bright default-fg chrome
    /// made every table louder than its contents.
    const md_table_border: vaxis.Style = .{ .fg = .{ .index = 8 } };
    const md_table_header: vaxis.Style = .{ .fg = .{ .index = 7 }, .bg = md_table_header_bg, .bold = true };
    const md_quote: vaxis.Style = .{ .fg = .{ .index = 8 }, .italic = true };
    const md_rule: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };
    const md_callout_bg: vaxis.Color = .{ .rgb = .{ 0x28, 0x2c, 0x32 } };
    const md_callout: vaxis.Style = .{ .bg = md_callout_bg };
    const reasoning_bg: vaxis.Color = .{ .rgb = .{ 0x30, 0x33, 0x39 } };
    const reasoning_panel: vaxis.Style = .{ .bg = reasoning_bg };
    /// Reasoning commentary sits one step ABOVE body text, never below it:
    /// the same words were just streamed in the default style, and
    /// dimming/italicizing them on completion reads as the text degrading.
    /// Emphasis comes from WEIGHT, not color: measured on a real theme, the
    /// default foreground is already pure white, so no fg value can be
    /// brighter — but bold strokes light more pixels per glyph and read as
    /// brighter at terminal sizes. RGB white is kept to pin the floor on
    /// themes whose default fg actually is grey.
    const reasoning: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } }, .bg = reasoning_bg, .bold = true };
    const reasoning_mark: vaxis.Style = .{ .fg = .{ .index = 6 }, .bg = reasoning_bg, .bold = true };
    /// Tool machinery (the ⚙ glyph, arg previews, result bodies): dimmed
    /// gray so it reads as background activity, never as user input or as
    /// assistant prose meant for the human.
    const tool: vaxis.Style = .{ .fg = .{ .index = 8 } };
    /// File-tool targets remain a single emphasized value. Bash previews use
    /// the semantic shell roles below instead of rendering as one blue blob.
    const tool_cmd: vaxis.Style = .{ .fg = .{ .index = 4 }, .bold = true }; // blue
    const shell_command: vaxis.Style = .{ .fg = .{ .index = 7 } };
    const shell_executable: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x82, 0xaa, 0xff } }, .bold = true };
    const shell_flag: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } } };
    const shell_operator: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc7, 0x92, 0xea } }, .bold = true };
    const shell_string: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc3, 0xe8, 0x8d } } };
    const shell_path: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xff, 0xcb, 0x6b } } };
    const shell_variable: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf7, 0x8c, 0x6c } } };
    const tool_out: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };
    /// Secondary text on collapse-summary and Working lines. Deliberately
    /// NOT tool_out: index-8+dim is near-invisible on dark themes, and these
    /// lines are the only live signal while a turn runs.
    const collapse_hint: vaxis.Style = .{ .fg = .{ .index = 7 } };
    const working: vaxis.Style = .{ .fg = .{ .index = 7 }, .bold = true };
    const tool_err: vaxis.Style = .{ .fg = .{ .index = 1 } }; // red
    const git_subject: vaxis.Style = .{ .fg = .{ .index = 7 } };
    const git_hash: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xff, 0xcb, 0x6b } } };
    const git_ref: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } }, .bold = true };
    // Fixed dark surfaces match the current Codex-like composer and keep the
    // add/delete signal restrained enough for syntax colors to remain legible.
    const diff_add_bg: vaxis.Color = .{ .rgb = .{ 0x1f, 0x37, 0x29 } };
    const diff_del_bg: vaxis.Color = .{ .rgb = .{ 0x3b, 0x24, 0x29 } };
    const diff_add: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x73, 0xd0, 0x91 } }, .bg = diff_add_bg, .bold = true };
    const diff_del: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf0, 0x71, 0x78 } }, .bg = diff_del_bg, .bold = true };
    const diff_add_code: vaxis.Style = .{ .bg = diff_add_bg };
    const diff_del_code: vaxis.Style = .{ .bg = diff_del_bg };
    const diff_context: vaxis.Style = .{ .fg = .{ .index = 8 } };
    const diff_hunk: vaxis.Style = .{ .fg = .{ .index = 6 } }; // cyan @@ + decl ctx
    const syntax_keyword: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc7, 0x92, 0xea } }, .bold = true };
    const syntax_string: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc3, 0xe8, 0x8d } } };
    const syntax_number: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf7, 0x8c, 0x6c } } };
    const syntax_comment: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x69, 0x70, 0x98 } }, .italic = true };
    const syntax_type: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } } };
    const syntax_function: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x82, 0xaa, 0xff } } };
    const syntax_constant: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xff, 0xcb, 0x6b } } };
    const note: vaxis.Style = .{ .fg = .{ .index = 3 } }; // yellow
    const steer: vaxis.Style = .{ .fg = .{ .index = 5 } }; // magenta
    const status_bg: vaxis.Color = .{ .index = 0 };
    const status_bar: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 7 } };
    const status_sep: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 8 }, .dim = true };
    const status_idle: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 2 } };
    const status_running: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 }, .bold = true };
    const status_approval: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 }, .bold = true };
    const status_error: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 1 }, .bold = true };
    const status_model: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 6 } };
    const status_effort: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 5 } };
    const status_child: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 6 }, .bold = true };
    const status_context: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 4 } };
    const status_context_warn: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 } };
    const status_context_hot: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 1 } };
    const status_cwd: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 2 } };
    const status_notice: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 } };
    const approval_card: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    const delta_style: vaxis.Style = .{};
};

fn statusModel(model: []const u8) []const u8 {
    const gateway = "openrouter/";
    return if (std.mem.startsWith(u8, model, gateway)) model[gateway.len..] else model;
}

fn statusCwd(arena: std.mem.Allocator, cwd: []const u8, home: []const u8) ![]const u8 {
    if (cwd.len == 0) return "cwd ?";
    if (home.len > 0 and
        std.mem.startsWith(u8, cwd, home) and
        (cwd.len == home.len or cwd[home.len] == '/'))
    {
        return std.fmt.allocPrint(arena, "~{s}", .{cwd[home.len..]});
    }
    return cwd;
}

/// Autocomplete is active only while the composer contains a command token;
/// once an argument or newline starts, normal editor navigation takes over.
fn commandQuery(editor: *const Editor) ?[]const u8 {
    const text = editor.text.items;
    if (text.len == 0 or (text[0] != '/' and text[0] != '!')) return null;
    for (text) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') return null;
    }
    return text;
}

fn commandMatches(editor: *const Editor) CommandMatches {
    var out = CommandMatches{};
    const query = commandQuery(editor) orelse return out;
    for (composer_commands, 0..) |command, i| {
        if (query.len <= command.name.len and
            std.ascii.eqlIgnoreCase(query, command.name[0..query.len]))
        {
            out.indices[out.len] = i;
            out.len += 1;
        }
    }
    return out;
}

fn completeCommand(editor: *Editor, command: ComposerCommand, add_argument_space: bool) void {
    editor.clear();
    editor.insertSlice(command.name);
    if (add_argument_space and command.accepts_args) editor.insertSlice(" ");
}

const LinkSpan = struct {
    /// Byte offsets in the concatenated visible text of a Line.
    start: usize,
    end: usize,
    /// OSC 8 destination. Always an allowlisted http(s) URL.
    uri: []const u8,
};

const SyntaxSpan = struct {
    /// Byte offsets in the concatenated visible text of a Line.
    start: usize,
    end: usize,
    style: vaxis.Style,
};

/// One logical display line: 1..3 styled segments (segments never wrap
/// independently; the line is the wrap unit). Slices point into the App's
/// block storage or the frame arena (valid for the frame).
const Line = struct {
    text: []const u8,
    style: vaxis.Style,
    /// When set, paint the complete terminal row before printing segments.
    /// Prompt cards use this to retain their background past the text.
    fill_style: ?vaxis.Style = null,
    /// A bounded Markdown surface can fill only its content measure. A null
    /// width retains the historical full-row behavior used by prompt cards.
    fill_start: u16 = 0,
    fill_width: ?u16 = null,
    /// Optional second/third segment printed after `text` on the same row.
    text2: []const u8 = "",
    style2: vaxis.Style = .{},
    text3: []const u8 = "",
    style3: vaxis.Style = .{},
    /// Hyperlinks over the concatenated text/text2/text3 byte stream.
    links: []const LinkSpan = &.{},
    /// Foreground-only code syntax overlays. The underlying row background
    /// remains intact for added/deleted diff lines.
    syntax: []const SyntaxSpan = &.{},
    /// Wrapped message lines resolve links against the unbroken source URL.
    /// Other line kinds are scanned once after layout is complete.
    links_resolved: bool = false,
};

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Grayscale ramp for the Working shimmer: a crest of white travels through
/// otherwise mid-grey letters as the animation tick advances the phase —
/// monochrome movement, not a color cycle.
const shimmer_shades = [_]vaxis.Color{
    .{ .rgb = .{ 0x6e, 0x6e, 0x6e } },
    .{ .rgb = .{ 0x7e, 0x7e, 0x7e } },
    .{ .rgb = .{ 0x96, 0x96, 0x96 } },
    .{ .rgb = .{ 0xb6, 0xb6, 0xb6 } },
    .{ .rgb = .{ 0xdc, 0xdc, 0xdc } },
    .{ .rgb = .{ 0xff, 0xff, 0xff } },
    .{ .rgb = .{ 0xdc, 0xdc, 0xdc } },
    .{ .rgb = .{ 0xb6, 0xb6, 0xb6 } },
    .{ .rgb = .{ 0x96, 0x96, 0x96 } },
    .{ .rgb = .{ 0x7e, 0x7e, 0x7e } },
};

/// One bold shimmer span per code point of `text`, phase-shifted by `frame`
/// so successive animation ticks move the brightness crest. `offset` is the
/// byte position of `text` within the line's concatenated visible text.
fn shimmerSpans(
    arena: std.mem.Allocator,
    text: []const u8,
    offset: usize,
    frame: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var i: usize = 0;
    var char_index: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        try spans.append(arena, .{
            .start = offset + i,
            .end = offset + end,
            .style = .{
                .fg = shimmer_shades[(char_index + frame) % shimmer_shades.len],
                .bold = true,
            },
        });
        i = end;
        char_index += 1;
    }
    return spans.toOwnedSlice(arena);
}

/// Codepoint end for byte index i (module-local mirror of the editor's).
fn nextCpEndFor(t: []const u8, i: usize) usize {
    if (i >= t.len) return t.len;
    var j = i + 1;
    while (j < t.len and (t[j] & 0b1100_0000) == 0b1000_0000) : (j += 1) {}
    return j;
}

/// Next word start at or after `col` (ASCII word boundaries over the
/// rendered line text; columns approximate bytes, which holds for the
/// transcript's overwhelmingly ASCII content).
fn nextWordCol(text: []const u8, col: usize) usize {
    var i = @min(col, text.len);
    while (i < text.len and text[i] != ' ') i += 1;
    while (i < text.len and text[i] == ' ') i += 1;
    return if (i == text.len and text.len > 0) text.len - 1 else i;
}

/// Previous word start strictly before `col`.
fn prevWordCol(text: []const u8, col: usize) usize {
    var i = @min(col, text.len);
    while (i > 0 and (i > text.len - 1 or i >= text.len or text[i - 1] == ' ')) i -= 1;
    while (i > 0 and text[i - 1] != ' ') i -= 1;
    return i;
}

/// Freshest complete-ish line of a streaming text (for the reasoning ticker).
fn lastNonEmptyLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return text;
}

/// Largest byte index <= max that does not split a UTF-8 sequence.
fn utf8Floor(text: []const u8, max: usize) usize {
    var end = @min(max, text.len);
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
    return end;
}

/// Clip long text at a UTF-8-safe boundary with an ellipsis; short text
/// passes through untouched.
fn clipText(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return text;
    return std.fmt.allocPrint(arena, "{s} …", .{text[0..utf8Floor(text, max)]});
}

const legacy_rehydration_prefix = "[rehydrated after compaction]";

fn isLegacyRehydration(text: []const u8) bool {
    return std.mem.startsWith(u8, text, legacy_rehydration_prefix);
}

fn rehydrationLabel(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (!isLegacyRehydration(text))
        return allocator.dupe(u8, "rehydrated file context");
    const rest = std.mem.trimStart(u8, text[legacy_rehydration_prefix.len..], " \t");
    const first_line = if (std.mem.indexOfScalar(u8, rest, '\n')) |end| rest[0..end] else rest;
    const path = std.mem.trim(u8, std.mem.trimEnd(u8, first_line, ":"), " \t");
    if (path.len == 0) return allocator.dupe(u8, "rehydrated file context");
    return std.fmt.allocPrint(allocator, "rehydrated {s}", .{path});
}

fn isCompactionStatusNote(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "context compacted automatically") or
        std.mem.startsWith(u8, text, "context compacted by /compact");
}

fn nowWallMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

fn lineWidth(win: vaxis.Window, line: Line) usize {
    return @as(usize, win.gwidth(line.text)) +
        @as(usize, win.gwidth(line.text2)) +
        @as(usize, win.gwidth(line.text3));
}

fn lineText(arena: std.mem.Allocator, line: Line) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ line.text, line.text2, line.text3 });
}

const SyntaxLanguage = enum {
    generic,
    zig,
    rust,
    javascript,
    python,
    shell,
    json,
    toml,
    yaml,
    c_like,
    go,
    ruby,
    markdown,
};

fn languageForPath(path: []const u8) SyntaxLanguage {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or
        std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return .javascript;
    if (std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".pyi")) return .python;
    if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash") or
        std.mem.eql(u8, ext, ".zsh") or std.mem.eql(u8, ext, ".fish")) return .shell;
    if (std.mem.eql(u8, ext, ".json") or std.mem.eql(u8, ext, ".jsonc")) return .json;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".cxx") or std.mem.eql(u8, ext, ".hpp") or
        std.mem.eql(u8, ext, ".java") or std.mem.eql(u8, ext, ".swift") or
        std.mem.eql(u8, ext, ".kt")) return .c_like;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".rb")) return .ruby;
    if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".mdx")) return .markdown;
    return .generic;
}

/// Edit results start with `replaced ... in path`; regular git diffs expose
/// the target in a `+++ b/path` line. Supporting both keeps bash-produced
/// diffs useful too.
fn diffLanguage(text: []const u8) SyntaxLanguage {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.lastIndexOf(u8, line, " in ")) |at| {
            const path = std.mem.trim(u8, line[at + 4 ..], " \t\r");
            const lang = languageForPath(path);
            if (lang != .generic) return lang;
        }
        if (std.mem.startsWith(u8, line, "+++ ")) {
            var path = std.mem.trim(u8, line[4..], " \t\r");
            if (std.mem.startsWith(u8, path, "b/")) path = path[2..];
            if (!std.mem.eql(u8, path, "/dev/null")) return languageForPath(path);
        }
    }
    return .generic;
}

fn wordIn(word: []const u8, words: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, words, ' ');
    while (it.next()) |candidate| {
        if (std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

fn isKeyword(lang: SyntaxLanguage, word: []const u8) bool {
    const words: []const u8 = switch (lang) {
        .zig => "align allowzero and anyframe anytype asm async await break catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while",
        .rust => "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while",
        .javascript => "async await break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return static super switch this throw try typeof var void while with yield interface type enum implements namespace private protected public readonly",
        .python => "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
        .shell => "case do done elif else esac fi for function if in select then time until while",
        .c_like => "alignas alignof auto break case catch class const constexpr continue default delete do else enum explicit export extern final for friend goto if import inline interface namespace new noexcept operator override private protected public register return signed sizeof static struct switch template this throw try typedef typename union unsigned using virtual volatile while",
        .go => "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        .ruby => "alias and begin break case class def defined do else elsif end ensure false for if in module next not or redo rescue retry return self super then true undef unless until when while yield",
        else => "",
    };
    return wordIn(word, words);
}

fn isBuiltinType(word: []const u8) bool {
    return wordIn(
        word,
        "anyerror anyopaque bool byte c_int char comptime_float comptime_int f16 f32 f64 f80 f128 i8 i16 i32 i64 i128 isize noreturn str string String u8 u16 u32 u64 u128 usize void",
    );
}

fn isConstant(word: []const u8) bool {
    return wordIn(word, "false true null undefined nil None True False");
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '@' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn lineCommentMarker(lang: SyntaxLanguage) ?[]const u8 {
    return switch (lang) {
        .python, .shell, .toml, .yaml, .ruby => "#",
        .zig, .rust, .javascript, .c_like, .go => "//",
        else => null,
    };
}

fn appendSyntaxSpan(
    arena: std.mem.Allocator,
    spans: *std.ArrayList(SyntaxSpan),
    start: usize,
    end: usize,
    offset: usize,
    style: vaxis.Style,
) !void {
    try spans.append(arena, .{ .start = offset + start, .end = offset + end, .style = style });
}

/// Lightweight, line-local lexer. It intentionally recognizes broad lexical
/// classes rather than pretending to be a parser; malformed/incomplete diff
/// lines still receive stable highlighting and never affect stored text.
fn syntaxSpans(
    arena: std.mem.Allocator,
    code: []const u8,
    lang: SyntaxLanguage,
    offset: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var i: usize = 0;
    while (i < code.len) {
        if (lineCommentMarker(lang)) |marker| {
            if (std.mem.startsWith(u8, code[i..], marker)) {
                try appendSyntaxSpan(arena, &spans, i, code.len, offset, Palette.syntax_comment);
                break;
            }
        }
        if (std.mem.startsWith(u8, code[i..], "/*")) {
            const close = std.mem.indexOfPos(u8, code, i + 2, "*/");
            const end = if (close) |at| at + 2 else code.len;
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_comment);
            i = end;
            continue;
        }
        const c = code[i];
        if (c == '"' or c == '\'' or c == '`') {
            const quote = c;
            var end = i + 1;
            while (end < code.len) : (end += 1) {
                if (code[end] == '\\') {
                    end = @min(end + 1, code.len);
                    continue;
                }
                if (code[end] == quote) {
                    end += 1;
                    break;
                }
            }
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_string);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var end = i + 1;
            while (end < code.len and (std.ascii.isAlphanumeric(code[end]) or
                code[end] == '.' or code[end] == '_')) : (end += 1)
            {}
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_number);
            i = end;
            continue;
        }
        if (isIdentStart(c)) {
            var end = i + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            const word = code[i..end];
            var style: ?vaxis.Style = null;
            if (isKeyword(lang, word) or c == '@')
                style = Palette.syntax_keyword
            else if (isConstant(word))
                style = Palette.syntax_constant
            else if (isBuiltinType(word) or std.ascii.isUpper(c))
                style = Palette.syntax_type
            else {
                var next = end;
                while (next < code.len and (code[next] == ' ' or code[next] == '\t')) next += 1;
                if (next < code.len and code[next] == '(') style = Palette.syntax_function;
            }
            if (style) |token_style| try appendSyntaxSpan(arena, &spans, i, end, offset, token_style);
            i = end;
            continue;
        }
        i += 1;
    }
    return spans.items;
}

fn isShellOperator(c: u8) bool {
    return switch (c) {
        '&', '|', ';', '<', '>', '(', ')' => true,
        else => false,
    };
}

/// Return the end of a shell operator, including a leading file descriptor
/// (`2>&1`). Keeping the whole redirection together makes it read as syntax,
/// not as a number followed by unrelated punctuation.
fn shellOperatorEnd(command: []const u8, start: usize) ?usize {
    var at = start;
    while (at < command.len and std.ascii.isDigit(command[at])) at += 1;
    if (at == command.len or !isShellOperator(command[at])) return null;
    if (at > start and command[at] != '<' and command[at] != '>') return null;

    at += 1;
    while (at < command.len and
        (isShellOperator(command[at]) or std.ascii.isDigit(command[at])))
    {
        at += 1;
    }
    return at;
}

fn shellOperatorExpectsCommand(operator: []const u8) bool {
    if (operator.len == 0 or std.ascii.isDigit(operator[0]) or
        operator[0] == '<' or operator[0] == '>') return false;
    if (std.mem.startsWith(u8, operator, "&>")) return false;
    return std.mem.indexOfAny(u8, operator, "|;&()") != null;
}

fn isShellWrapper(word: []const u8) bool {
    return wordIn(word, "command builtin env exec nohup sudo");
}

fn isShellPath(word: []const u8) bool {
    return (word.len > 0 and (word[0] == '.' or word[0] == '~' or word[0] == '/')) or
        std.mem.indexOfScalar(u8, word, '/') != null;
}

/// Shell-aware styling for bash tool previews. This is deliberately lexical:
/// it separates the landmarks people scan for (programs, flags, operators,
/// strings, paths, and variables) without trying to execute or fully parse
/// arbitrary shell input.
fn shellCommandSpans(
    arena: std.mem.Allocator,
    command: []const u8,
    offset: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var at: usize = 0;
    var expect_command = true;

    while (at < command.len) {
        while (at < command.len and (command[at] == ' ' or command[at] == '\t')) at += 1;
        if (at >= command.len) break;

        if (command[at] == '#') {
            try appendSyntaxSpan(arena, &spans, at, command.len, offset, Palette.syntax_comment);
            break;
        }

        if (command[at] == '"' or command[at] == '\'' or command[at] == '`') {
            const quote = command[at];
            var end = at + 1;
            while (end < command.len) {
                if (command[end] == '\\' and quote != '\'') {
                    end = @min(end + 2, command.len);
                    continue;
                }
                if (command[end] == quote) {
                    end += 1;
                    break;
                }
                end += 1;
            }
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_string);
            expect_command = false;
            at = end;
            continue;
        }

        if (command[at] == '$') {
            var end = at + 1;
            if (end < command.len and command[end] == '{') {
                end += 1;
                while (end < command.len and command[end] != '}') end += 1;
                if (end < command.len) end += 1;
            } else {
                while (end < command.len and
                    (std.ascii.isAlphanumeric(command[end]) or command[end] == '_')) end += 1;
            }
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_variable);
            at = end;
            continue;
        }

        if (shellOperatorEnd(command, at)) |end| {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_operator);
            if (shellOperatorExpectsCommand(command[at..end])) expect_command = true;
            at = end;
            continue;
        }

        var end = at + 1;
        while (end < command.len and command[end] != ' ' and command[end] != '\t' and
            command[end] != '"' and command[end] != '\'' and command[end] != '`' and
            !isShellOperator(command[end]))
        {
            end += 1;
        }
        const word = command[at..end];
        const assignment = std.mem.indexOfScalar(u8, word, '=') != null and word[0] != '-';

        if (expect_command and assignment) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_variable);
        } else if (isKeyword(.shell, word)) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.syntax_keyword);
            expect_command = wordIn(word, "do elif else for function if select then time until while");
        } else if (expect_command) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_executable);
            expect_command = isShellWrapper(word);
        } else if (word.len > 1 and word[0] == '-') {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_flag);
        } else if (isShellPath(word)) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_path);
        } else if (assignment) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_variable);
        } else if (std.ascii.isDigit(word[0])) {
            var all_numeric = true;
            for (word) |c| {
                if (!std.ascii.isDigit(c)) {
                    all_numeric = false;
                    break;
                }
            }
            if (all_numeric) try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.syntax_number);
        }
        at = end;
    }
    return spans.items;
}

/// Recognize the stable `git log --oneline` shape without depending on the
/// originating command. This also handles useful stdout from a compound shell
/// command whose final step failed: the error glyph stays red, while the log
/// itself remains legible.
fn gitLogSpans(
    arena: std.mem.Allocator,
    line: []const u8,
    offset: usize,
) ![]const SyntaxSpan {
    var hash_end: usize = 0;
    while (hash_end < line.len and hash_end < 40 and std.ascii.isHex(line[hash_end])) hash_end += 1;
    if (hash_end < 7 or hash_end >= line.len or line[hash_end] != ' ') return &.{};

    var spans: std.ArrayList(SyntaxSpan) = .empty;
    try appendSyntaxSpan(arena, &spans, 0, hash_end, offset, Palette.git_hash);

    var refs_start = hash_end + 1;
    while (refs_start < line.len and line[refs_start] == ' ') refs_start += 1;
    if (refs_start < line.len and line[refs_start] == '(') {
        if (std.mem.indexOfScalarPos(u8, line, refs_start + 1, ')')) |close| {
            try appendSyntaxSpan(arena, &spans, refs_start, close + 1, offset, Palette.git_ref);
        }
    }
    return spans.items;
}

fn isUrlStart(text: []const u8, at: usize) bool {
    return std.mem.startsWith(u8, text[at..], "https://") or
        std.mem.startsWith(u8, text[at..], "http://");
}

fn isUrlTerminator(c: u8) bool {
    return c <= ' ' or c == '<' or c == '>' or c == '"' or c == '\'' or c == '`';
}

fn countByte(text: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (text) |c| if (c == needle) {
        count += 1;
    };
    return count;
}

/// End of a plain http(s) URL, excluding prose/Markdown punctuation.
fn urlEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and !isUrlTerminator(text[end])) end += 1;

    // Sentence punctuation is almost never intended to be part of a URL.
    while (end > start and std.mem.indexOfScalar(u8, ".,;:!?", text[end - 1]) != null) end -= 1;

    // Keep balanced delimiters inside URLs, but drop unmatched prose or
    // Markdown closers: `(https://example.test/foo)` -> URL without final `)`.
    const pairs = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };
    inline for (pairs) |pair| {
        while (end > start and text[end - 1] == pair[1] and
            countByte(text[start..end], pair[1]) > countByte(text[start..end], pair[0]))
        {
            end -= 1;
        }
    }
    return end;
}

/// Find visible spans that should carry OSC 8 metadata. Markdown stays
/// visible for now, but both its label and destination become clickable.
fn findLinkSpans(arena: std.mem.Allocator, text: []const u8) ![]const LinkSpan {
    var spans: std.ArrayList(LinkSpan) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') {
            if (std.mem.indexOfPos(u8, text, i + 1, "](")) |label_end| {
                const uri_start = label_end + 2;
                if (uri_start < text.len and isUrlStart(text, uri_start)) {
                    const uri_end = urlEnd(text, uri_start);
                    if (uri_end > uri_start and uri_end < text.len and text[uri_end] == ')') {
                        const uri = text[uri_start..uri_end];
                        if (label_end > i + 1) try spans.append(arena, .{
                            .start = i + 1,
                            .end = label_end,
                            .uri = uri,
                        });
                        try spans.append(arena, .{
                            .start = uri_start,
                            .end = uri_end,
                            .uri = uri,
                        });
                        i = uri_end + 1;
                        continue;
                    }
                }
            }
        }

        if (isUrlStart(text, i)) {
            const end = urlEnd(text, i);
            if (end > i) try spans.append(arena, .{ .start = i, .end = end, .uri = text[i..end] });
            i = @max(end, i + 1);
            continue;
        }
        i += 1;
    }
    return spans.items;
}

/// Intersect source-text links with one hard-wrapped chunk. Each resulting
/// span keeps the full URI even when only part of its label/URL is visible.
fn linksForChunk(
    arena: std.mem.Allocator,
    source_links: []const LinkSpan,
    chunk_start: usize,
    chunk_end: usize,
    prefix_len: usize,
) ![]const LinkSpan {
    var spans: std.ArrayList(LinkSpan) = .empty;
    for (source_links) |link| {
        const start = @max(link.start, chunk_start);
        const end = @min(link.end, chunk_end);
        if (start < end) try spans.append(arena, .{
            .start = prefix_len + start - chunk_start,
            .end = prefix_len + end - chunk_start,
            .uri = link.uri,
        });
    }
    return spans.items;
}

fn resolveLineLinks(arena: std.mem.Allocator, lines: []Line) !void {
    for (lines) |*line| {
        if (line.links_resolved) continue;
        const text = try lineText(arena, line.*);
        line.links = try findLinkSpans(arena, text);
        line.links_resolved = true;
    }
}

fn linkForBytes(links: []const LinkSpan, start: usize, end: usize) ?[]const u8 {
    for (links) |link| {
        if (start < link.end and end > link.start) return link.uri;
    }
    return null;
}

fn syntaxForBytes(spans: []const SyntaxSpan, start: usize, end: usize) ?vaxis.Style {
    for (spans) |span| {
        if (start < span.end and end > span.start) return span.style;
    }
    return null;
}

/// Overlay syntax or inline-Markdown attributes. A non-default background is
/// intentional (inline-code chips); a default background preserves any block
/// surface already painted underneath, including diff and code-panel rows.
fn applyLineSyntax(win: vaxis.Window, row: u16, line: Line) void {
    if (line.syntax.len == 0) return;
    const parts = [_][]const u8{ line.text, line.text2, line.text3 };
    var byte_offset: usize = 0;
    var col: usize = 0;
    for (parts) |part| {
        var part_offset: usize = 0;
        var it = vaxis.unicode.graphemeIterator(part);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(part);
            const start = byte_offset + part_offset;
            const end = start + bytes.len;
            const cell_width: usize = @intCast(win.gwidth(bytes));
            if (syntaxForBytes(line.syntax, start, end)) |style| {
                if (col < @as(usize, win.width)) {
                    if (win.readCell(@intCast(col), row)) |cell| {
                        var highlighted = cell;
                        if (!vaxis.Color.eql(style.fg, .default)) highlighted.style.fg = style.fg;
                        if (!vaxis.Color.eql(style.bg, .default)) highlighted.style.bg = style.bg;
                        highlighted.style.bold = style.bold;
                        highlighted.style.dim = style.dim;
                        highlighted.style.italic = style.italic;
                        highlighted.style.strikethrough = style.strikethrough;
                        win.writeCell(@intCast(col), row, highlighted);
                    }
                }
            }
            part_offset += bytes.len;
            col += cell_width;
        }
        byte_offset += part.len;
    }
}

/// Attach OSC 8 metadata after styled segments have been painted. This keeps
/// syntax colors and selection independent from the link parser.
fn applyLineLinks(win: vaxis.Window, row: u16, line: Line) void {
    if (line.links.len == 0) return;
    const parts = [_][]const u8{ line.text, line.text2, line.text3 };
    var byte_offset: usize = 0;
    var col: usize = 0;
    for (parts) |part| {
        var part_offset: usize = 0;
        var it = vaxis.unicode.graphemeIterator(part);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(part);
            const start = byte_offset + part_offset;
            const end = start + bytes.len;
            const cell_width: usize = @intCast(win.gwidth(bytes));
            if (linkForBytes(line.links, start, end)) |uri| {
                if (col < @as(usize, win.width)) {
                    if (win.readCell(@intCast(col), row)) |cell| {
                        var linked = cell;
                        linked.link = .{ .uri = uri };
                        linked.style.fg = .{ .index = 6 }; // cyan
                        linked.style.ul_style = .single;
                        win.writeCell(@intCast(col), row, linked);
                    }
                }
            }
            part_offset += bytes.len;
            col += cell_width;
        }
        byte_offset += part.len;
    }
}

/// Append every complete grapheme intersecting [start_col, end_col).
fn appendColumns(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    win: vaxis.Window,
    text: []const u8,
    start_col: usize,
    end_col: usize,
) !void {
    var it = vaxis.unicode.graphemeIterator(text);
    var col: usize = 0;
    while (it.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const next = col + @as(usize, win.gwidth(bytes));
        if (next > start_col and col < end_col) try out.appendSlice(arena, bytes);
        col = next;
        if (col >= end_col) break;
    }
}

fn selectedText(
    arena: std.mem.Allocator,
    win: vaxis.Window,
    lines: []const Line,
    selection: Selection,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (selection.lo.line >= lines.len) return out.items;
    const last = @min(selection.hi.line, lines.len - 1);
    var line_idx = selection.lo.line;
    while (line_idx <= last) : (line_idx += 1) {
        if (line_idx > selection.lo.line) try out.append(arena, '\n');
        const line = lines[line_idx];
        const text = try lineText(arena, line);
        const cols = selection.columns(line_idx, lineWidth(win, line)) orelse continue;
        try appendColumns(arena, &out, win, text, cols.start, cols.end);
    }
    return out.items;
}

fn wrapPromptCard(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
) !void {
    const first_prefix = " ❯ ";
    const continuation = "   ";
    const prefix_cells: usize = 3;
    const body_width = width -| (prefix_cells + 1); // keep right padding
    if (body_width < 8) return;

    try lines.append(arena, .{ .text = "", .style = Palette.prompt_text, .fill_style = Palette.prompt_panel });
    var first = true;
    var logical = std.mem.splitScalar(u8, text, '\n');
    while (logical.next()) |raw_line| {
        const source_links = try findLinkSpans(arena, raw_line);
        var rest = raw_line;
        while (true) {
            const take = @min(rest.len, body_width);
            const chunk_start = raw_line.len - rest.len;
            const prefix = if (first) first_prefix else continuation;
            const links = try linksForChunk(
                arena,
                source_links,
                chunk_start,
                chunk_start + take,
                prefix.len,
            );
            try lines.append(arena, .{
                .text = prefix,
                .style = if (first) Palette.prompt_mark else Palette.prompt_text,
                .text2 = rest[0..take],
                .style2 = Palette.prompt_text,
                .fill_style = Palette.prompt_panel,
                .links = links,
                .links_resolved = true,
            });
            first = false;
            if (take == rest.len) break;
            rest = rest[take..];
        }
    }
    try lines.append(arena, .{ .text = "", .style = Palette.prompt_text, .fill_style = Palette.prompt_panel });
}

/// Reasoning/progress updates are useful transcript landmarks, so give them
/// a quiet full-width surface and real breathing room without competing with
/// the stronger user-prompt cards.
fn wrapReasoningCard(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
) !void {
    const prefix = "  · ";
    const cont = "    ";
    try lines.append(arena, .{ .text = "", .style = Palette.reasoning_panel, .fill_style = Palette.reasoning_panel });

    // Commentary arrives with inline markdown (**bold**, `code`, links);
    // render it instead of showing the markers verbatim. Newlines flatten
    // to spaces — the card is prose, not layout.
    const flat = try arena.dupe(u8, text);
    std.mem.replaceScalar(u8, flat, '\n', ' ');
    const im = try inlineMarkdown(arena, flat);

    const avail = @max(@as(usize, 8), (width -| 2) -| prefix.len);
    var start: usize = 0;
    var first = true;
    while (first or start < im.text.len) {
        var end = wordBreak(im.text, start, avail);
        if (end == start and start < im.text.len) end = hardCellBreak(im.text, start, avail);
        const head: []const u8 = if (first) prefix else cont;
        var styles: std.ArrayList(SyntaxSpan) = .empty;
        var links: std.ArrayList(LinkSpan) = .empty;
        try appendTranslatedInline(arena, &styles, &links, im, start, end, head.len);
        try lines.append(arena, .{
            .text = head,
            .style = if (first) Palette.reasoning_mark else Palette.reasoning,
            .text2 = im.text[start..end],
            .style2 = Palette.reasoning,
            .fill_style = Palette.reasoning_panel,
            .syntax = styles.items,
            .links = links.items,
            .links_resolved = true,
        });
        first = false;
        start = end;
        while (start < im.text.len and im.text[start] == ' ') start += 1;
        if (start >= im.text.len) break;
    }
    try lines.append(arena, .{ .text = "", .style = Palette.reasoning_panel, .fill_style = Palette.reasoning_panel });
}

const CollapsedToolRun = struct {
    count: usize,
    /// First block after the run.
    next: usize,
};

fn isDiffOutput(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "\n@@ ") != null or std.mem.startsWith(u8, text, "@@ ");
}

/// Tools whose diff output is a change the agent MADE. Only these stop the
/// collapse run below; a diff the agent merely read (`bash git diff …`) is
/// ordinary command output and collapses like any other success.
fn isFileEditTool(label: []const u8) bool {
    return std.mem.eql(u8, label, "edit") or std.mem.eql(u8, label, "write_file");
}

/// A failed command can emit hundreds of perfectly ordinary compiler or test
/// lines. Reserve red for the lines that actually summarize the failure; the
/// surrounding transcript stays at the same quiet level as successful tool
/// output, so the useful diagnostic remains easy to find.
fn isSalientToolErrorLine(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const prefixes = [_][]const u8{
        "error:",
        "fatal:",
        "panic:",
        "fail ",
        "fail:",
        "denied:",
        "blocked:",
        "permission denied",
        "access denied",
        "[exit code:",
    };
    for (prefixes) |prefix| {
        if (std.ascii.startsWithIgnoreCase(trimmed, prefix)) return true;
    }
    return std.ascii.indexOfIgnoreCase(trimmed, " fail ") != null or
        std.ascii.indexOfIgnoreCase(trimmed, ": permission denied") != null or
        std.ascii.indexOfIgnoreCase(trimmed, ": access denied") != null;
}

/// A calls-first batch can be visible while its tools are still running.
/// Return its extent only when it is the incomplete tail of the transcript.
fn pendingToolBatch(blocks: []const RenderBlock, start: usize) ?CollapsedToolRun {
    if (start >= blocks.len or blocks[start].kind != .tool_call) return null;
    const turn_id = blocks[start].turn_id;
    if (start > 0 and
        blocks[start - 1].kind == .tool_call and
        blocks[start - 1].turn_id == turn_id) return null;

    var calls_end = start;
    while (calls_end < blocks.len and
        blocks[calls_end].kind == .tool_call and
        blocks[calls_end].turn_id == turn_id) : (calls_end += 1)
    {}
    const count = calls_end - start;
    if (count < 2) return null;

    var i = calls_end;
    while (i < blocks.len and
        blocks[i].kind == .approval and
        blocks[i].turn_id == turn_id) : (i += 1)
    {}
    var results: usize = 0;
    while (i < blocks.len and
        blocks[i].kind == .tool_result and
        blocks[i].turn_id == turn_id and
        results < count) : (i += 1)
    {
        results += 1;
    }
    if (results < count and i == blocks.len) return .{ .count = count, .next = i };
    return null;
}

/// Flatten blocks + delta into wrapped display lines for a given width.
/// Returned list and its line slices use `arena` (per-frame).
/// Render blocks[start..end) as display lines. `alloc` owns every derived
/// string: the frame arena for the live tail, the layout cache's arena for
/// baked completed turns. `allow_fold` enables the running-command fold,
/// which reads live session state and therefore applies only to the tail.
/// The collapsed-transcript machinery renders call/result pairs from two
/// places (the sequential walk and batch-failure expansion); one renderer
/// each keeps them identical.
fn appendToolCallLine(alloc: std.mem.Allocator, lines: *std.ArrayList(Line), rb: RenderBlock, w: usize) !void {
    // Keep the machinery subdued. Bash commands receive semantic shell
    // roles; for file tools the emphasized value is a path.
    const hi = extractHighlightArg(rb.label, rb.text);
    const head = try std.fmt.allocPrint(alloc, "  ⚙ {s} ", .{rb.label});
    if (hi) |h| {
        const hi_capped = h[0..@min(h.len, w -| (head.len + 2))];
        const is_bash = std.mem.eql(u8, rb.label, "bash");
        try lines.append(alloc, .{
            .text = head,
            .style = Palette.tool,
            .text2 = hi_capped,
            .style2 = if (is_bash) Palette.shell_command else Palette.tool_cmd,
            .syntax = if (is_bash)
                try shellCommandSpans(alloc, hi_capped, head.len)
            else
                &.{},
        });
    } else {
        const preview_len = @min(rb.text.len, @min(w -| (rb.label.len + 4), 120));
        try lines.append(alloc, .{
            .text = head,
            .style = Palette.tool,
            .text2 = rb.text[0..preview_len],
            .style2 = Palette.tool,
        });
    }
}

fn appendToolResultLines(alloc: std.mem.Allocator, lines: *std.ArrayList(Line), rb: RenderBlock, tool_label: []const u8) !void {
    // Collapsed: show at most 8 lines — but a diff the agent
    // AUTHORED (edit/write tools) shows whole (up to 24) because
    // a truncated diff misleads. Diffs merely read via bash keep
    // diff coloring but the ordinary cap.
    const is_diff = isDiffOutput(rb.text);
    const max_shown: usize = if (is_diff and isFileEditTool(tool_label)) 24 else 8;
    const language = if (is_diff) diffLanguage(rb.text) else SyntaxLanguage.generic;
    var shown: usize = 0;
    var total: usize = 0;
    var diff_nums: DiffLineNumbers = .{};
    var it = std.mem.splitScalar(u8, rb.text, '\n');
    while (it.next()) |l| {
        total += 1;
        if (shown < max_shown) {
            if (rb.status == .ok and is_diff) {
                try appendDiffLine(alloc, lines, "    ", l, language, Palette.tool_out, &diff_nums);
            } else if (rb.status != .ok) {
                // One failure marker establishes the section;
                // repeating it for every stack-frame line creates
                // a solid red wall with no visual hierarchy.
                const prefix: []const u8 = if (shown == 0) switch (rb.status) {
                    .err => "    ✗ ",
                    .denied => "    ⊘ ",
                    .interrupted => "    ⏹ ",
                    .ok => unreachable,
                } else "      ";
                const salient = isSalientToolErrorLine(l) or
                    (rb.status == .denied and shown == 0);
                try lines.append(alloc, .{
                    .text = prefix,
                    .style = if (shown == 0) Palette.tool_err else Palette.tool_out,
                    .text2 = l,
                    .style2 = if (salient) Palette.tool_err else Palette.tool_out,
                });
            } else {
                const glyph = "    ";
                const git_syntax = try gitLogSpans(alloc, l, glyph.len);
                if (git_syntax.len > 0) {
                    try lines.append(alloc, .{
                        .text = glyph,
                        .style = Palette.tool_out,
                        .text2 = l,
                        .style2 = Palette.git_subject,
                        .syntax = git_syntax,
                    });
                } else {
                    const prefixed = try std.fmt.allocPrint(alloc, "{s}{s}", .{ glyph, l });
                    try lines.append(alloc, .{ .text = prefixed, .style = Palette.tool_out });
                }
            }
            shown += 1;
        }
    }
    if (total > shown) {
        const more = try std.fmt.allocPrint(alloc, "    … {d} more lines", .{total - shown});
        try lines.append(alloc, .{ .text = more, .style = Palette.tool_out });
    }
}

/// One completed tool batch: N consecutive same-turn calls followed by
/// their N results (approval/reasoning/note blocks may interleave). Results
/// are persisted in call order, so pairing is positional.
const ScannedBatch = struct {
    next: usize,
    complete: bool,
    ok_count: usize,
};

const ExpandPair = struct { call: usize, result: usize };

/// Scan the batch starting at `start`; pairs that must stay visible (failed
/// results, or author-diffs from the edit/write tools whose truncation would
/// mislead) are appended to `expand`.
fn scanToolBatch(
    alloc: std.mem.Allocator,
    blocks: []const RenderBlock,
    start: usize,
    expand: *std.ArrayList(ExpandPair),
) !ScannedBatch {
    const turn_id = blocks[start].turn_id;
    var calls_end = start;
    while (calls_end < blocks.len and
        blocks[calls_end].kind == .tool_call and
        blocks[calls_end].turn_id == turn_id) : (calls_end += 1)
    {}
    const call_count = calls_end - start;

    var matched: usize = 0;
    var ok_count: usize = 0;
    var i = calls_end;
    while (i < blocks.len and matched < call_count) : (i += 1) {
        switch (blocks[i].kind) {
            .approval, .reasoning, .system_note => {},
            .tool_result => {
                const call_idx = start + matched;
                const failed = blocks[i].status != .ok;
                const author_diff = isDiffOutput(blocks[i].text) and
                    isFileEditTool(blocks[call_idx].label);
                if (failed or author_diff) {
                    try expand.append(alloc, .{ .call = call_idx, .result = i });
                } else {
                    ok_count += 1;
                }
                matched += 1;
            },
            else => break,
        }
    }
    return .{ .next = i, .complete = matched == call_count, .ok_count = ok_count };
}

/// Emit and reset the accumulated "Ran N commands" summary. Deferred so
/// consecutive tool stretches merge across interleaved commentary cards
/// instead of stacking one summary line per provider round.
fn flushRanSummary(alloc: std.mem.Allocator, lines: *std.ArrayList(Line), pending: *usize) !void {
    if (pending.* == 0) return;
    const summary = try std.fmt.allocPrint(alloc, "Ran {d} {s}", .{
        pending.*,
        if (pending.* == 1) "command" else "commands",
    });
    try lines.append(alloc, .{
        .text = "  • ",
        .style = Palette.note,
        .text2 = summary,
        .style2 = Palette.assistant,
        .text3 = " · ctrl+t to view transcript",
        .style3 = Palette.collapse_hint,
    });
    pending.* = 0;
}

const max_layout_lines: usize = 50_000;

fn layoutBlockRange(
    alloc: std.mem.Allocator,
    app: *App,
    lines: *std.ArrayList(Line),
    start: usize,
    end: usize,
    w: usize,
    last_tool_label: *[]const u8,
    allow_fold: bool,
) !void {
    // A corrupt or unexpectedly pathological transcript must degrade to a
    // visible truncation, never an unbounded allocation loop in the TUI.
    const max_layout_steps = (end - start) *| 2 +| 1_024;
    var pending_ran: usize = 0;
    var block_idx: usize = start;
    var layout_steps: usize = 0;
    while (block_idx < end) : (block_idx += 1) {
        if (layout_steps >= max_layout_steps or lines.items.len >= max_layout_lines) {
            try lines.append(alloc, .{
                .text = "  [transcript rendering truncated at safety limit]",
                .style = Palette.tool_err,
            });
            break;
        }
        layout_steps += 1;
        const rb = app.blocks.items[block_idx];
        if (!app.show_tool_transcript and rb.kind == .tool_call) {
            const blocks_all = app.blocks.items;
            // Fold completed batches into one summary, merging consecutive
            // batches of this turn. Failed pairs (and author-diffs) stay
            // visible INDIVIDUALLY — one failing sibling must not dump the
            // whole group into the transcript.
            var expand: std.ArrayList(ExpandPair) = .empty;
            var folded: usize = 0;
            var scan_idx = block_idx;
            var scan_end = block_idx;
            while (scan_idx < end and
                blocks_all[scan_idx].kind == .tool_call and
                blocks_all[scan_idx].turn_id == rb.turn_id)
            {
                const batch = try scanToolBatch(alloc, blocks_all, scan_idx, &expand);
                if (!batch.complete) break;
                folded += batch.ok_count;
                scan_end = batch.next;
                scan_idx = batch.next;
                if (expand.items.len > 0) break; // surface failures promptly
            }

            // A trailing call/batch with no results yet is still executing:
            // fold it into the summary line instead of flashing detail lines
            // that vanish when a fast command completes. Approval-parked
            // calls keep their detail line — the user must see what they
            // are deciding on.
            var running_count: usize = 0;
            var running_call_idx: usize = 0;
            if (allow_fold and app.state == .running and expand.items.len == 0 and
                scan_idx < blocks_all.len and
                blocks_all[scan_idx].kind == .tool_call and
                blocks_all[scan_idx].turn_id == rb.turn_id)
            {
                if (pendingToolBatch(blocks_all, scan_idx)) |batch| {
                    running_count = batch.count;
                    scan_end = blocks_all.len;
                } else {
                    var j = scan_idx + 1;
                    while (j < blocks_all.len and blocks_all[j].kind == .approval) : (j += 1) {}
                    if (j == blocks_all.len) {
                        running_count = 1;
                        running_call_idx = scan_idx;
                        scan_end = blocks_all.len;
                    }
                }
            }

            if (expand.items.len == 0 and running_count == 0 and folded > 0) {
                pending_ran += folded;
                if (scan_end > block_idx) {
                    block_idx = scan_end - 1;
                    continue;
                }
            }
            const total_ran = pending_ran + folded;
            if (total_ran > 0 or expand.items.len > 0 or running_count > 0) {
                pending_ran = 0;
                const summary = if (total_ran > 0)
                    try std.fmt.allocPrint(alloc, "Ran {d} {s}", .{
                        total_ran,
                        if (total_ran == 1) "command" else "commands",
                    })
                else if (running_count > 1)
                    try std.fmt.allocPrint(alloc, "Running {d} commands", .{running_count})
                else if (running_count == 1)
                    "Running"
                else
                    try std.fmt.allocPrint(alloc, "{d} {s} failed", .{
                        expand.items.len,
                        if (expand.items.len == 1) "command" else "commands",
                    });
                var hint: []const u8 = " · ctrl+t to view transcript";
                if (running_count == 1) {
                    const call = blocks_all[running_call_idx];
                    const hi = extractHighlightArg(call.label, call.text) orelse
                        call.text[0..@min(call.text.len, 40)];
                    const capped = hi[0..@min(hi.len, 60)];
                    hint = try std.fmt.allocPrint(alloc, " · {s} {s}{s}", .{
                        call.label,
                        capped,
                        if (capped.len < hi.len) "…" else "",
                    });
                } else if (total_ran > 0 and running_count > 1) {
                    hint = try std.fmt.allocPrint(alloc, " · running {d} more", .{running_count});
                }
                if (total_ran > 0 or running_count > 0) {
                    try lines.append(alloc, .{
                        .text = "  • ",
                        .style = Palette.note,
                        .text2 = summary,
                        .style2 = Palette.assistant,
                        .text3 = hint,
                        .style3 = Palette.collapse_hint,
                    });
                }
                for (expand.items) |pair| {
                    try appendToolCallLine(alloc, lines, blocks_all[pair.call], w);
                    try appendToolResultLines(alloc, lines, blocks_all[pair.result], blocks_all[pair.call].label);
                }
                if (scan_end > block_idx) {
                    block_idx = scan_end - 1;
                    continue;
                }
            }
        }
        switch (rb.kind) {
            .user_msg => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try blankLine(alloc, lines);
                try wrapPromptCard(alloc, lines, rb.text, w);
            },
            .assistant_msg => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try blankLine(alloc, lines);
                try wrapMarkdown(alloc, lines, rb.text, w);
            },
            .reasoning => {
                // Commentary is one short sentence by prompt contract;
                // anything much longer is a provider reasoning summary —
                // keep the card, clip the wall (full text stays in the log).
                try wrapReasoningCard(alloc, lines, try clipText(alloc, rb.text, 280), w);
            },
            .tool_call => {
                try flushRanSummary(alloc, lines, &pending_ran);
                last_tool_label.* = rb.label;
                try appendToolCallLine(alloc, lines, rb, w);
            },
            .tool_result => try appendToolResultLines(alloc, lines, rb, last_tool_label.*),
            .approval => {
                const txt = try std.fmt.allocPrint(alloc, "    [approval: {s}]", .{rb.text});
                try wrapInto(alloc, lines, txt, .{ .text = txt, .style = Palette.note });
            },
            .steer => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try wrapPrefixed(alloc, lines, "  ↪ ", rb.text, Palette.steer, w);
            },
            .system_note => {
                const txt = try std.fmt.allocPrint(alloc, "[{s}]", .{try clipText(alloc, rb.text, 480)});
                try wrapPrefixed(alloc, lines, "  ", txt, Palette.note, w);
            },
            .compaction => {
                try flushRanSummary(alloc, lines, &pending_ran);
                try wrapPrefixed(alloc, lines, "  ≋ ", "context compacted", Palette.note, w);
            },
        }
    }
    try flushRanSummary(alloc, lines, &pending_ran);
}

/// Blocks of COMPLETED turns are immutable layout input: collapse runs never
/// cross turn boundaries and folding only affects the active tail. Everything
/// before the final turn-id group (which also covers optimistic echoes) is
/// safe to bake into the layout cache.
fn stableBlockCount(app: *const App) usize {
    const items = app.blocks.items;
    if (items.len == 0) return 0;
    const last_turn = items[items.len - 1].turn_id;
    var i = items.len;
    while (i > 0 and items[i - 1].turn_id == last_turn) i -= 1;
    return i;
}

fn layoutLines(arena: std.mem.Allocator, app: *App, width: u16) !std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    const w: usize = if (width == 0) 80 else width;

    // Completed turns bake once into the persistent cache; each frame then
    // costs O(active turn), not O(session). Any key change or epoch bump
    // (session switch, echo reconcile) rebuilds from scratch.
    const cache = &app.layout_cache;
    if (cache.width != w or cache.expanded != app.show_tool_transcript or
        cache.epoch != app.layout_epoch or cache.covered > app.blocks.items.len)
    {
        cache.reset(app.gpa);
        cache.width = w;
        cache.expanded = app.show_tool_transcript;
        cache.epoch = app.layout_epoch;
    }
    const stable = stableBlockCount(app);
    if (stable > cache.covered) {
        const bake_alloc = try cache.allocator(app.gpa);
        const prev = cache.lines.items.len;
        var label = cache.label_state;
        try layoutBlockRange(bake_alloc, app, &cache.lines, cache.covered, stable, w, &label, false);
        cache.label_state = label;
        try resolveLineLinks(bake_alloc, cache.lines.items[prev..]);
        cache.covered = stable;
    }
    try lines.appendSlice(arena, cache.lines.items);
    var label_state = cache.label_state;
    try layoutBlockRange(arena, app, &lines, cache.covered, app.blocks.items.len, w, &label_state, true);

    // Streaming region: provider reasoning summaries are verbose by nature
    // (first-person deliberation), so the live view is a one-line ticker
    // showing only the freshest thought — not a growing wall. The durable
    // card at round end is clipped separately below.
    if (app.reasoning_delta.items.len > 0) {
        const tail = lastNonEmptyLine(app.reasoning_delta.items);
        const cap = @min(tail.len, w -| 8);
        try lines.append(arena, .{
            .text = "  · ",
            .style = Palette.reasoning_mark,
            .text2 = tail[0..utf8Floor(tail, cap)],
            .style2 = Palette.collapse_hint,
        });
    }
    if (app.delta.items.len > 0) {
        try blankLine(arena, &lines);
        try wrapMarkdown(arena, &lines, app.delta.items, w);
    } else if (app.reasoning_delta.items.len == 0 and app.state == .running) {
        try blankLine(arena, &lines);
        const head = try std.fmt.allocPrint(arena, "{s} ", .{
            spinner_frames[app.spinner_frame % spinner_frames.len],
        });
        const word = "Working…";
        const elapsed_s: i64 = if (app.turn_started_ms > 0)
            @max(0, @divTrunc(nowWallMs(app.io) - app.turn_started_ms, 1000))
        else
            0;
        const elapsed = if (elapsed_s >= 60)
            try std.fmt.allocPrint(arena, " · {d}m {d}s", .{ @divTrunc(elapsed_s, 60), @mod(elapsed_s, 60) })
        else
            try std.fmt.allocPrint(arena, " · {d}s", .{elapsed_s});
        // What is it actually doing? Show the executing tool call with its
        // own timer so a long-running command is visible at a glance.
        var detail = elapsed;
        // Stream telemetry: proves liveness when the provider is sending but
        // nothing is visible yet (long thinking, tool-call assembly). Hidden
        // once reports go stale (between rounds, during tool execution).
        const stream_fresh = app.stream_status_at_ms > 0 and
            nowWallMs(app.io) - app.stream_status_at_ms < 3000;
        if (stream_fresh and app.currentInflightCall() == null) {
            const quiet_s = app.stream_quiet_ms / 1000;
            if (quiet_s >= 3) {
                detail = try std.fmt.allocPrint(arena, "{s} · streaming {Bi:.1} · last token {d}s ago", .{
                    elapsed, app.stream_bytes, quiet_s,
                });
            } else {
                detail = try std.fmt.allocPrint(arena, "{s} · streaming {Bi:.1}", .{
                    elapsed, app.stream_bytes,
                });
            }
        }
        if (app.currentInflightCall()) |cur| {
            const arg_full = extractHighlightArg(cur.rb.label, cur.rb.text) orelse "";
            const arg = arg_full[0..utf8Floor(arg_full, @min(arg_full.len, 60))];
            const call_s: i64 = if (app.call_started_ms > 0)
                @max(0, @divTrunc(nowWallMs(app.io) - app.call_started_ms, 1000))
            else
                0;
            const sep: []const u8 = if (arg.len > 0) " " else "";
            const queued = if (cur.queued > 0)
                try std.fmt.allocPrint(arena, " (+{d} queued)", .{cur.queued})
            else
                "";
            detail = try std.fmt.allocPrint(arena, "{s} · {s}{s}{s} · {d}s{s}", .{
                elapsed, cur.rb.label, sep, arg, call_s, queued,
            });
        }
        try lines.append(arena, .{
            .text = head,
            .style = Palette.working,
            .text2 = word,
            .style2 = Palette.working,
            .text3 = detail,
            .style3 = Palette.collapse_hint,
            .syntax = try shimmerSpans(arena, word, head.len, app.spinner_frame),
        });
    }

    // Approval card.
    if (app.pending) |*p| {
        try blankLine(arena, &lines);
        const card = try std.fmt.allocPrint(arena, "⚠ approve {s} {s} ?  [y]es / [n]o", .{ p.tool(), p.args() });
        try wrapPrefixed(arena, &lines, "", card, Palette.approval_card, w);
    }
    try resolveLineLinks(arena, lines.items);
    return lines;
}

fn blankLine(arena: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    try lines.append(arena, .{ .text = "", .style = .{} });
}

/// The one argument worth reading in a tool call: bash's command, file
/// tools' path, grep/glob's pattern, fetch's url. Returns a slice into
/// args_json (JSON-escaped — good enough for a one-line preview; commands
/// with heavy escaping still show faithfully enough to recognize).
fn extractHighlightArg(tool_name: []const u8, args_json: []const u8) ?[]const u8 {
    const key: []const u8 = if (std.mem.eql(u8, tool_name, "bash"))
        "command"
    else if (std.mem.eql(u8, tool_name, "grep") or std.mem.eql(u8, tool_name, "glob"))
        "pattern"
    else if (std.mem.eql(u8, tool_name, "fetch"))
        "url"
    else if (std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit"))
        "path"
    else
        return null;
    return extractJsonStringRaw(args_json, key);
}

/// Find "key":"..." and return the raw (still-escaped) string contents.
fn extractJsonStringRaw(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    var at = std.mem.indexOf(u8, json, needle) orelse return null;
    at += needle.len;
    while (at < json.len and (json[at] == ' ' or json[at] == '\t')) at += 1;
    if (at >= json.len or json[at] != '"') return null;
    at += 1;
    var end = at;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') {
            end += 1;
            continue;
        }
        if (json[end] == '"') break;
    }
    if (end > json.len) return null;
    return json[at..end];
}

fn hunkContextStart(line: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const close = std.mem.indexOfPos(u8, line, 2, "@@") orelse return null;
    var start = close + 2;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    return if (start < line.len) start else null;
}

/// Turn a raw unified-diff line into a gutter + code row. Changed rows carry
/// a subtle full-width surface; syntax is an independent foreground overlay.
/// Line-number gutter state for a streamed diff: seeded by each @@ hunk
/// header, advanced per rendered line. Adds/context show the NEW file's
/// number, deletions the OLD one; inactive (no header seen) renders none.
const DiffLineNumbers = struct {
    old: usize = 0,
    new: usize = 0,
    active: bool = false,

    fn onHunk(self: *DiffLineNumbers, line: []const u8) void {
        self.active = false;
        const minus = std.mem.indexOfScalar(u8, line, '-') orelse return;
        const plus = std.mem.indexOfScalarPos(u8, line, minus, '+') orelse return;
        self.old = parseLeadingInt(line[minus + 1 ..]) orelse return;
        self.new = parseLeadingInt(line[plus + 1 ..]) orelse return;
        self.active = true;
    }

    fn parseLeadingInt(text: []const u8) ?usize {
        var end: usize = 0;
        while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(usize, text[0..end], 10) catch null;
    }
};

fn appendDiffLine(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    glyph: []const u8,
    line: []const u8,
    language: SyntaxLanguage,
    fallback_style: vaxis.Style,
    nums: *DiffLineNumbers,
) !void {
    if (std.mem.startsWith(u8, line, "@@ ")) {
        nums.onHunk(line);
        const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, line });
        const syntax = if (hunkContextStart(line)) |start|
            try syntaxSpans(arena, line[start..], language, glyph.len + start)
        else
            &.{};
        try lines.append(arena, .{ .text = text, .style = Palette.diff_hunk, .syntax = syntax });
        return;
    }

    const is_add = std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++");
    const is_del = std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---");
    const is_context = std.mem.startsWith(u8, line, " ");
    if (is_add or is_del or is_context) {
        var number: usize = 0;
        if (nums.active) {
            if (is_add) {
                number = nums.new;
                nums.new += 1;
            } else if (is_del) {
                number = nums.old;
                nums.old += 1;
            } else {
                number = nums.new;
                nums.new += 1;
                nums.old += 1;
            }
        }
        const gutter = if (nums.active)
            try std.fmt.allocPrint(arena, "{s}{d:>4} {c}", .{ glyph, number, line[0] })
        else
            try std.fmt.allocPrint(arena, "{s}{c}", .{ glyph, line[0] });
        const code = line[1..];
        const code_style = if (is_add)
            Palette.diff_add_code
        else if (is_del)
            Palette.diff_del_code
        else
            Palette.diff_context;
        const marker_style = if (is_add)
            Palette.diff_add
        else if (is_del)
            Palette.diff_del
        else
            Palette.diff_context;
        const syntax = try syntaxSpans(arena, code, language, gutter.len);
        try lines.append(arena, .{
            .text = gutter,
            .style = marker_style,
            .text2 = code,
            .style2 = code_style,
            .fill_style = if (is_add or is_del) code_style else null,
            .syntax = syntax,
        });
        return;
    }

    const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, line });
    try lines.append(arena, .{ .text = text, .style = fallback_style });
}

fn wrapInto(arena: std.mem.Allocator, lines: *std.ArrayList(Line), _: []const u8, line: Line) !void {
    try lines.append(arena, line);
}

/// Wrap auxiliary transcript text onto the same visual rail as assistant
/// prose. Continuations hang beneath the text instead of snapping to column
/// zero, and cell-aware breaks keep Unicode intact.
fn wrapPrefixed(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    prefix: []const u8,
    text: []const u8,
    style: vaxis.Style,
    width: usize,
) !void {
    const continuation = try spaces(arena, displayWidth(prefix));
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const source_links = try findLinkSpans(arena, raw_line);
        if (raw_line.len == 0) {
            try lines.append(arena, .{ .text = "", .style = style });
            continue;
        }
        var start: usize = 0;
        while (start < raw_line.len) {
            const line_prefix = if (first) prefix else continuation;
            const body_width = width -| displayWidth(line_prefix);
            if (body_width == 0) return;
            var end = wordBreak(raw_line, start, body_width);
            if (end == start) end = hardCellBreak(raw_line, start, body_width);
            const chunk = raw_line[start..end];
            const full = if (line_prefix.len > 0)
                try std.fmt.allocPrint(arena, "{s}{s}", .{ line_prefix, chunk })
            else
                chunk;
            const links = try linksForChunk(
                arena,
                source_links,
                start,
                end,
                line_prefix.len,
            );
            try lines.append(arena, .{
                .text = full,
                .style = style,
                .links = links,
                .links_resolved = true,
            });
            first = false;
            start = end;
            while (start < raw_line.len and (raw_line[start] == ' ' or raw_line[start] == '\t')) start += 1;
        }
    }
}

const InlineMarkdown = struct {
    text: []const u8,
    styles: []const SyntaxSpan,
    links: []const LinkSpan,
};

fn appendInlineStyle(
    arena: std.mem.Allocator,
    styles: *std.ArrayList(SyntaxSpan),
    start: usize,
    end: usize,
    style: vaxis.Style,
) !void {
    if (start < end) try styles.append(arena, .{ .start = start, .end = end, .style = style });
}

/// Small, deliberately conservative inline Markdown pass. It removes the
/// punctuation users do not want to read in a terminal while retaining
/// emphasis, inline-code styling, and safe HTTP(S) link metadata.
fn inlineMarkdown(arena: std.mem.Allocator, source: []const u8) !InlineMarkdown {
    var out: std.ArrayList(u8) = .empty;
    var styles: std.ArrayList(SyntaxSpan) = .empty;
    var links: std.ArrayList(LinkSpan) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (std.mem.startsWith(u8, source[i..], "**") or std.mem.startsWith(u8, source[i..], "__")) {
            const delimiter = source[i .. i + 2];
            if (std.mem.indexOfPos(u8, source, i + 2, delimiter)) |close| {
                const start = out.items.len;
                try out.appendSlice(arena, source[i + 2 .. close]);
                try appendInlineStyle(arena, &styles, start, out.items.len, .{ .bold = true });
                i = close + 2;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[i..], "~~")) {
            if (std.mem.indexOfPos(u8, source, i + 2, "~~")) |close| {
                const start = out.items.len;
                try out.appendSlice(arena, source[i + 2 .. close]);
                try appendInlineStyle(arena, &styles, start, out.items.len, .{ .strikethrough = true });
                i = close + 2;
                continue;
            }
        }
        if (source[i] == '*' or source[i] == '_') {
            if (std.mem.indexOfScalarPos(u8, source, i + 1, source[i])) |close| {
                const valid_underscore = source[i] != '_' or
                    ((i == 0 or !std.ascii.isAlphanumeric(source[i - 1])) and
                        (close + 1 == source.len or !std.ascii.isAlphanumeric(source[close + 1])));
                if (close > i + 1 and valid_underscore) {
                    const start = out.items.len;
                    try out.appendSlice(arena, source[i + 1 .. close]);
                    try appendInlineStyle(arena, &styles, start, out.items.len, .{ .italic = true });
                    i = close + 1;
                    continue;
                }
            }
        }
        if (source[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, source, i + 1, '`')) |close| {
                const start = out.items.len;
                try out.appendSlice(arena, source[i + 1 .. close]);
                try appendInlineStyle(arena, &styles, start, out.items.len, Palette.md_code);
                i = close + 1;
                continue;
            }
        }
        if (source[i] == '[') {
            if (std.mem.indexOfPos(u8, source, i + 1, "](")) |label_end| {
                const uri_start = label_end + 2;
                if (std.mem.indexOfScalarPos(u8, source, uri_start, ')')) |uri_end| {
                    const uri = source[uri_start..uri_end];
                    if (isUrlStart(uri, 0)) {
                        const start = out.items.len;
                        try out.appendSlice(arena, source[i + 1 .. label_end]);
                        try links.append(arena, .{ .start = start, .end = out.items.len, .uri = uri });
                        i = uri_end + 1;
                        continue;
                    }
                }
            }
        }
        if (source[i] == '\\' and i + 1 < source.len and
            std.mem.indexOfScalar(u8, "\\`*_~[]", source[i + 1]) != null)
        {
            try out.append(arena, source[i + 1]);
            i += 2;
            continue;
        }
        try out.append(arena, source[i]);
        i += 1;
    }

    // Plain URLs remain clickable after the Markdown punctuation is removed.
    const plain_links = try findLinkSpans(arena, out.items);
    try links.appendSlice(arena, plain_links);
    return .{ .text = out.items, .styles = styles.items, .links = links.items };
}

fn stylesForChunk(
    arena: std.mem.Allocator,
    source: []const SyntaxSpan,
    chunk_start: usize,
    chunk_end: usize,
    prefix_len: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    for (source) |span| {
        const start = @max(span.start, chunk_start);
        const end = @min(span.end, chunk_end);
        if (start < end) try spans.append(arena, .{
            .start = prefix_len + start - chunk_start,
            .end = prefix_len + end - chunk_start,
            .style = span.style,
        });
    }
    return spans.items;
}

const markdown_gutter = "  ";
const markdown_max_body_width: usize = 112;

fn displayWidth(text: []const u8) usize {
    return @intCast(vaxis.gwidth.gwidth(text, .unicode));
}

fn validCatalogRate(rate: ?f64) ?f64 {
    const value = rate orelse return null;
    return if (std.math.isFinite(value) and value >= 0) value else null;
}

fn formatCatalogRate(arena: std.mem.Allocator, rate: ?f64) ![]const u8 {
    const value = validCatalogRate(rate) orelse return "—";
    if (value > 0 and value < 0.000001) return "<$0.000001";
    const rendered = try std.fmt.allocPrint(arena, "${d:.6}", .{value});
    var end = rendered.len;
    while (end > 0 and rendered[end - 1] == '0') end -= 1;
    if (end > 0 and rendered[end - 1] == '.') end -= 1;
    return rendered[0..end];
}

fn formatModelPricing(arena: std.mem.Allocator, pricing: proto.ModelPricing) ![]const u8 {
    const input = validCatalogRate(pricing.input_per_million);
    const output = validCatalogRate(pricing.output_per_million);
    if (input == null and output == null) return "price n/a";
    if (input == 0 and output == 0) return if (pricing.tiered) "free · tiered" else "free";
    return std.fmt.allocPrint(arena, "{s} → {s} / 1M{s}", .{
        try formatCatalogRate(arena, input),
        try formatCatalogRate(arena, output),
        if (pricing.tiered) " · tiered" else "",
    });
}

fn pickerModelLine(
    arena: std.mem.Allocator,
    model: []const u8,
    pricing: ?proto.ModelPricing,
    current: bool,
    content_width: usize,
) ![]const u8 {
    const marker = if (current) " ●" else "";
    const price = if (pricing) |value| try formatModelPricing(arena, value) else "";
    const price_width = displayWidth(price);
    const price_gap: usize = if (price.len > 0) 2 else 0;
    const model_capacity = content_width -| (price_width + price_gap);
    const model_end = hardCellBreak(model, 0, model_capacity);
    const model_text = model[0..model_end];
    const used = displayWidth(model_text) + price_width;
    const gap = if (price.len > 0)
        try spaces(arena, content_width -| used)
    else
        "";
    return std.fmt.allocPrint(arena, " {s}{s}{s}{s}", .{ model_text, gap, price, marker });
}

fn markdownGutter(width: usize) []const u8 {
    return if (width >= 32) markdown_gutter else "";
}

fn markdownMeasure(width: usize) usize {
    const gutter_width = displayWidth(markdownGutter(width));
    return @min(width, markdown_max_body_width + gutter_width);
}

/// Hard cell-width break that always lands on a grapheme boundary.
fn hardCellBreak(text: []const u8, start: usize, capacity: usize) usize {
    if (start >= text.len or capacity == 0) return start;
    var it = vaxis.unicode.graphemeIterator(text[start..]);
    var bytes_used: usize = 0;
    var cells_used: usize = 0;
    while (it.next()) |grapheme| {
        const bytes = grapheme.bytes(text[start..]);
        const cells = displayWidth(bytes);
        if (bytes_used > 0 and cells_used + cells > capacity) break;
        bytes_used += bytes.len;
        cells_used += cells;
        if (cells_used >= capacity) break;
    }
    return start + bytes_used;
}

/// Word-aware cell-width break for prose. Long tokens fall back to a hard
/// grapheme break, so emoji and CJK never corrupt wrapping or table sizing.
fn wordBreak(text: []const u8, start: usize, capacity: usize) usize {
    const hard_end = hardCellBreak(text, start, capacity);
    if (hard_end >= text.len) return text.len;
    var at = hard_end;
    while (at > start) : (at -= 1) {
        if (text[at - 1] == ' ' or text[at - 1] == '\t') return at - 1;
    }
    return hard_end;
}

fn spaces(arena: std.mem.Allocator, count: usize) ![]const u8 {
    const out = try arena.alloc(u8, count);
    @memset(out, ' ');
    return out;
}

fn appendGlyphNTimes(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    glyph: []const u8,
    count: usize,
) !void {
    for (0..count) |_| try out.appendSlice(arena, glyph);
}

fn appendMarkdownLine(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    raw: []const u8,
    first_prefix: []const u8,
    continuation_prefix: []const u8,
    base_style: vaxis.Style,
    width: usize,
) !void {
    const rendered = try inlineMarkdown(arena, raw);
    if (rendered.text.len == 0) {
        try lines.append(arena, .{ .text = first_prefix, .style = base_style });
        return;
    }

    var start: usize = 0;
    var first = true;
    while (start < rendered.text.len) {
        const line_prefix = if (first) first_prefix else continuation_prefix;
        const body_width = width -| displayWidth(line_prefix);
        if (body_width == 0) return;
        var end = wordBreak(rendered.text, start, body_width);
        if (end == start) end = hardCellBreak(rendered.text, start, body_width);
        const chunk = rendered.text[start..end];
        const full = if (line_prefix.len > 0)
            try std.fmt.allocPrint(arena, "{s}{s}", .{ line_prefix, chunk })
        else
            chunk;
        try lines.append(arena, .{
            .text = full,
            .style = base_style,
            .links = try linksForChunk(arena, rendered.links, start, end, line_prefix.len),
            .syntax = try stylesForChunk(arena, rendered.styles, start, end, line_prefix.len),
            .links_resolved = true,
        });
        first = false;
        start = end;
        while (start < rendered.text.len and (rendered.text[start] == ' ' or rendered.text[start] == '\t')) start += 1;
    }
}

fn tableCells(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') == null) return &.{};
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '|');
    while (it.next()) |cell| try cells.append(arena, std.mem.trim(u8, cell, " \t\r"));
    return cells.items;
}

fn isTableDelimiter(arena: std.mem.Allocator, raw: []const u8) !bool {
    const cells = try tableCells(arena, raw);
    if (cells.len == 0) return false;
    for (cells) |cell| {
        var dashes: usize = 0;
        for (cell) |c| switch (c) {
            '-' => dashes += 1,
            ':', ' ', '\t' => {},
            else => return false,
        };
        if (dashes < 3) return false;
    }
    return true;
}

const TableBorder = enum { top, middle, bottom };

fn appendTableBorder(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    widths: []const usize,
    gutter: []const u8,
    border: TableBorder,
) !void {
    var out: std.ArrayList(u8) = .empty;
    const left: []const u8 = switch (border) {
        .top => "╭",
        .middle => "├",
        .bottom => "╰",
    };
    const joint: []const u8 = switch (border) {
        .top => "┬",
        .middle => "┼",
        .bottom => "┴",
    };
    const right: []const u8 = switch (border) {
        .top => "╮",
        .middle => "┤",
        .bottom => "╯",
    };
    try out.appendSlice(arena, left);
    for (widths, 0..) |column_width, column| {
        if (column > 0) try out.appendSlice(arena, joint);
        try appendGlyphNTimes(arena, &out, "─", column_width + 2);
    }
    try out.appendSlice(arena, right);
    try lines.append(arena, .{
        .text = gutter,
        .style = .{},
        .text2 = out.items,
        .style2 = Palette.md_table_border,
        .links_resolved = true,
    });
}

fn appendTranslatedInline(
    arena: std.mem.Allocator,
    styles: *std.ArrayList(SyntaxSpan),
    links: *std.ArrayList(LinkSpan),
    rendered: InlineMarkdown,
    start: usize,
    end: usize,
    output_offset: usize,
) !void {
    for (rendered.styles) |span| {
        const span_start = @max(span.start, start);
        const span_end = @min(span.end, end);
        if (span_start < span_end) try styles.append(arena, .{
            .start = output_offset + span_start - start,
            .end = output_offset + span_end - start,
            .style = span.style,
        });
    }
    for (rendered.links) |link| {
        const link_start = @max(link.start, start);
        const link_end = @min(link.end, end);
        if (link_start < link_end) try links.append(arena, .{
            .start = output_offset + link_start - start,
            .end = output_offset + link_end - start,
            .uri = link.uri,
        });
    }
}

fn appendTableRow(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    cells: []const []const u8,
    widths: []const usize,
    gutter: []const u8,
    style: vaxis.Style,
) !void {
    const rendered = try arena.alloc(InlineMarkdown, widths.len);
    const positions = try arena.alloc(usize, widths.len);
    @memset(positions, 0);
    for (rendered, 0..) |*cell, column| {
        cell.* = try inlineMarkdown(arena, if (column < cells.len) cells[column] else "");
    }

    var first_visual = true;
    while (true) {
        var remaining = false;
        for (rendered, positions) |cell, position| {
            if (position < cell.text.len) {
                remaining = true;
                break;
            }
        }
        if (!first_visual and !remaining) break;

        var out: std.ArrayList(u8) = .empty;
        var styles: std.ArrayList(SyntaxSpan) = .empty;
        var links: std.ArrayList(LinkSpan) = .empty;
        try out.appendSlice(arena, "│ ");
        for (widths, 0..) |column_width, column| {
            if (column > 0) try out.appendSlice(arena, " │ ");
            const cell = rendered[column];
            const start = positions[column];
            var end = if (start < cell.text.len) wordBreak(cell.text, start, column_width) else start;
            if (end == start and start < cell.text.len) end = hardCellBreak(cell.text, start, column_width);
            const output_offset = gutter.len + out.items.len;
            try out.appendSlice(arena, cell.text[start..end]);
            try appendTranslatedInline(arena, &styles, &links, cell, start, end, output_offset);
            const used = displayWidth(cell.text[start..end]);
            if (used < column_width) try out.appendNTimes(arena, ' ', column_width - used);
            positions[column] = end;
            while (positions[column] < cell.text.len and
                (cell.text[positions[column]] == ' ' or cell.text[positions[column]] == '\t'))
            {
                positions[column] += 1;
            }
        }
        try out.appendSlice(arena, " │");
        {
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, out.items, pos, "│")) |sep| {
                try appendSyntaxSpan(arena, &styles, sep, sep + "│".len, gutter.len, Palette.md_table_border);
                pos = sep + "│".len;
            }
        }
        try lines.append(arena, .{
            .text = gutter,
            .style = .{},
            .text2 = out.items,
            .style2 = style,
            .syntax = styles.items,
            .links = links.items,
            .links_resolved = true,
        });
        first_visual = false;
    }
}

fn appendTable(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    logical: []const []const u8,
    start: usize,
    end: usize,
    measure: usize,
    gutter: []const u8,
) !void {
    const header = try tableCells(arena, logical[start]);
    if (header.len == 0) return;
    const widths = try arena.alloc(usize, header.len);
    @memset(widths, 1);
    var row = start;
    while (row < end) : (row += 1) {
        if (row == start + 1) continue;
        const cells = try tableCells(arena, logical[row]);
        for (cells[0..@min(cells.len, widths.len)], 0..) |cell_raw, column| {
            const cell = try inlineMarkdown(arena, cell_raw);
            widths[column] = @max(widths[column], @min(displayWidth(cell.text), 36));
        }
    }

    const overhead = displayWidth(gutter) + 3 * widths.len + 1;
    const available = @max(widths.len, measure -| overhead);
    const minimum = @max(@as(usize, 1), @min(@as(usize, 6), available / widths.len));
    for (widths) |*column_width| column_width.* = @max(column_width.*, minimum);
    while (true) {
        var sum: usize = 0;
        for (widths) |column_width| sum += column_width;
        if (sum <= available) break;
        var widest: ?usize = null;
        for (widths, 0..) |column_width, column| {
            if (column_width > minimum and (widest == null or column_width > widths[widest.?])) widest = column;
        }
        if (widest) |column| {
            widths[column] -= 1;
        } else break;
    }

    try appendTableBorder(arena, lines, widths, gutter, .top);
    try appendTableRow(arena, lines, header, widths, gutter, Palette.md_table_header);
    try appendTableBorder(arena, lines, widths, gutter, .middle);
    row = start + 2;
    while (row < end) : (row += 1) {
        try appendTableRow(arena, lines, try tableCells(arena, logical[row]), widths, gutter, Palette.assistant);
    }
    try appendTableBorder(arena, lines, widths, gutter, .bottom);
}

fn languageForFence(info: []const u8) SyntaxLanguage {
    const label = std.mem.trim(u8, info, " \t\r");
    if (std.ascii.eqlIgnoreCase(label, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(label, "rust") or std.ascii.eqlIgnoreCase(label, "rs")) return .rust;
    if (std.ascii.eqlIgnoreCase(label, "javascript") or std.ascii.eqlIgnoreCase(label, "js") or
        std.ascii.eqlIgnoreCase(label, "typescript") or std.ascii.eqlIgnoreCase(label, "ts")) return .javascript;
    if (std.ascii.eqlIgnoreCase(label, "python") or std.ascii.eqlIgnoreCase(label, "py")) return .python;
    if (std.ascii.eqlIgnoreCase(label, "shell") or std.ascii.eqlIgnoreCase(label, "bash") or
        std.ascii.eqlIgnoreCase(label, "sh") or std.ascii.eqlIgnoreCase(label, "zsh")) return .shell;
    if (std.ascii.eqlIgnoreCase(label, "json") or std.ascii.eqlIgnoreCase(label, "jsonc")) return .json;
    if (std.ascii.eqlIgnoreCase(label, "toml")) return .toml;
    if (std.ascii.eqlIgnoreCase(label, "yaml") or std.ascii.eqlIgnoreCase(label, "yml")) return .yaml;
    if (std.ascii.eqlIgnoreCase(label, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(label, "ruby") or std.ascii.eqlIgnoreCase(label, "rb")) return .ruby;
    if (std.ascii.eqlIgnoreCase(label, "markdown") or std.ascii.eqlIgnoreCase(label, "md")) return .markdown;
    if (std.ascii.eqlIgnoreCase(label, "c") or std.ascii.eqlIgnoreCase(label, "cpp") or
        std.ascii.eqlIgnoreCase(label, "c++") or std.ascii.eqlIgnoreCase(label, "java") or
        std.ascii.eqlIgnoreCase(label, "swift") or std.ascii.eqlIgnoreCase(label, "kotlin")) return .c_like;
    return .generic;
}

fn expandCodeTabs(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\t') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    for (raw) |byte| {
        if (byte == '\t')
            try out.appendSlice(arena, "    ")
        else
            try out.append(arena, byte);
    }
    return out.items;
}

fn appendCodeBorder(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    gutter: []const u8,
    panel_width: usize,
    label: ?[]const u8,
) !void {
    var panel: std.ArrayList(u8) = .empty;
    if (label) |header| {
        try panel.appendSlice(arena, "╭─ ");
        const label_capacity = panel_width -| 5;
        const label_end = hardCellBreak(header, 0, label_capacity);
        try panel.appendSlice(arena, header[0..label_end]);
        try panel.append(arena, ' ');
        const used = displayWidth(panel.items) + 1;
        if (used < panel_width) try appendGlyphNTimes(arena, &panel, "─", panel_width - used);
        try panel.appendSlice(arena, "╮");
    } else {
        try panel.appendSlice(arena, "╰");
        try appendGlyphNTimes(arena, &panel, "─", panel_width -| 2);
        try panel.appendSlice(arena, "╯");
    }
    try lines.append(arena, .{
        .text = gutter,
        .style = .{},
        .text2 = panel.items,
        .style2 = Palette.md_code_border,
        .links_resolved = true,
    });
}

fn decimalDigits(value: usize) usize {
    var digits: usize = 1;
    var rest = value;
    while (rest >= 10) : (rest /= 10) digits += 1;
    return digits;
}

fn appendCodeBlock(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    code_lines: []const []const u8,
    info: []const u8,
    measure: usize,
    gutter: []const u8,
) !void {
    const panel_width = measure -| displayWidth(gutter);
    if (panel_width < 12) return;
    const language_label = std.mem.trim(u8, info, " \t\r");
    const short_label = if (language_label.len > 0) language_label else "code";
    const header = if (panel_width >= 34)
        try std.fmt.allocPrint(arena, "{s} · select to copy", .{short_label})
    else
        short_label;
    try appendCodeBorder(arena, lines, gutter, panel_width, header);

    const language = languageForFence(language_label);
    const line_digits = decimalDigits(@max(code_lines.len, 1));
    const show_line_numbers = panel_width >= line_digits + 24;
    const panel_overhead = if (show_line_numbers) line_digits + 7 else 4;
    const body_width = panel_width -| panel_overhead;
    for (code_lines, 0..) |raw, line_number| {
        const code = try expandCodeTabs(arena, raw);
        var start: usize = 0;
        var first = true;
        while (first or start < code.len) {
            const end = if (start < code.len) hardCellBreak(code, start, body_width) else start;
            const chunk = code[start..end];
            var panel: std.ArrayList(u8) = .empty;
            try panel.appendSlice(arena, "│ ");
            if (show_line_numbers) {
                const number = try std.fmt.allocPrint(arena, "{d}", .{line_number + 1});
                if (number.len < line_digits) try panel.appendNTimes(arena, ' ', line_digits - number.len);
                if (first)
                    try panel.appendSlice(arena, number)
                else
                    try panel.appendNTimes(arena, ' ', number.len);
                try panel.appendSlice(arena, " │ ");
            }
            const code_offset = gutter.len + panel.items.len;
            try panel.appendSlice(arena, chunk);
            const used = displayWidth(chunk);
            if (used < body_width) try panel.appendNTimes(arena, ' ', body_width - used);
            const right_border_offset = gutter.len + panel.items.len;
            try panel.appendSlice(arena, " │");
            var styles: std.ArrayList(SyntaxSpan) = .empty;
            try styles.append(arena, .{
                .start = gutter.len,
                .end = code_offset,
                .style = Palette.md_code_border,
            });
            try styles.appendSlice(arena, try syntaxSpans(arena, chunk, language, code_offset));
            try styles.append(arena, .{
                .start = right_border_offset,
                .end = gutter.len + panel.items.len,
                .style = Palette.md_code_border,
            });
            try lines.append(arena, .{
                .text = gutter,
                .style = .{},
                .text2 = panel.items,
                .style2 = Palette.md_code_panel,
                .syntax = styles.items,
                .links_resolved = true,
            });
            first = false;
            start = end;
        }
    }
    try appendCodeBorder(arena, lines, gutter, panel_width, null);
}

const CalloutKind = enum { note, tip, important, warning, caution, status };

fn calloutLabel(kind: CalloutKind) []const u8 {
    return switch (kind) {
        .note => "NOTE",
        .tip => "TIP",
        .important => "IMPORTANT",
        .warning => "WARNING",
        .caution => "CAUTION",
        .status => "STATUS",
    };
}

fn calloutAccent(kind: CalloutKind) vaxis.Color {
    return switch (kind) {
        .note, .status => .{ .rgb = .{ 0x89, 0xdd, 0xff } },
        .tip => .{ .rgb = .{ 0x73, 0xd0, 0x91 } },
        .important => .{ .rgb = .{ 0xc7, 0x92, 0xea } },
        .warning => .{ .rgb = .{ 0xff, 0xcb, 0x6b } },
        .caution => .{ .rgb = .{ 0xf0, 0x71, 0x78 } },
    };
}

fn calloutMarker(raw: []const u8) ?CalloutKind {
    const marker = std.mem.trim(u8, raw, " \t\r");
    if (marker.len < 4 or !std.mem.startsWith(u8, marker, "[!") or marker[marker.len - 1] != ']') return null;
    const name = marker[2 .. marker.len - 1];
    inline for (std.meta.tags(CalloutKind)) |kind| {
        if (kind != .status and std.ascii.eqlIgnoreCase(name, calloutLabel(kind))) return kind;
    }
    return null;
}

fn semanticCallout(raw: []const u8) ?CalloutKind {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "**Formal status:**") or
        std.mem.startsWith(u8, trimmed, "**Status:**") or
        std.mem.startsWith(u8, trimmed, "**Result:**")) return .status;
    if (std.mem.startsWith(u8, trimmed, "✅") or std.mem.startsWith(u8, trimmed, "✓")) return .tip;
    if (std.mem.startsWith(u8, trimmed, "⚠")) return .warning;
    if (std.mem.startsWith(u8, trimmed, "❌") or std.mem.startsWith(u8, trimmed, "✗")) return .caution;
    return null;
}

fn decorateCalloutLines(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    start: usize,
    gutter: []const u8,
    measure: usize,
    kind: CalloutKind,
) !void {
    for (lines.items[start..]) |*line| {
        if (!std.mem.startsWith(u8, line.text, gutter)) continue;
        const whole = line.text;
        line.text = whole[0..gutter.len];
        line.style = .{};
        line.text2 = whole[gutter.len..];
        line.style2 = Palette.md_callout;
        line.fill_style = Palette.md_callout;
        line.fill_start = @intCast(displayWidth(gutter));
        line.fill_width = @intCast(measure -| displayWidth(gutter));
        var spans: std.ArrayList(SyntaxSpan) = .empty;
        try spans.append(arena, .{
            .start = gutter.len,
            .end = gutter.len + "▌".len,
            .style = .{ .fg = calloutAccent(kind), .bg = Palette.md_callout_bg, .bold = true },
        });
        try spans.appendSlice(arena, line.syntax);
        line.syntax = spans.items;
    }
}

fn appendCallout(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    bodies: []const []const u8,
    kind: CalloutKind,
    show_label: bool,
    measure: usize,
    gutter: []const u8,
) !void {
    const prefix = try std.fmt.allocPrint(arena, "{s}▌ ", .{gutter});
    const continuation = prefix;
    const first_line = lines.items.len;
    if (show_label) {
        const label = try std.fmt.allocPrint(arena, "**{s}**", .{calloutLabel(kind)});
        try appendMarkdownLine(arena, lines, label, prefix, continuation, Palette.md_callout, measure);
    }
    if (bodies.len == 0) {
        try appendMarkdownLine(arena, lines, "", prefix, continuation, Palette.md_callout, measure);
    } else for (bodies) |body| {
        try appendMarkdownLine(arena, lines, body, prefix, continuation, Palette.md_callout, measure);
    }
    try decorateCalloutLines(arena, lines, first_line, gutter, measure, kind);
}

const ListItem = struct {
    content: []const u8,
    marker: []const u8,
    indent: usize,
};

fn parseListItem(raw: []const u8) ?ListItem {
    var leading: usize = 0;
    while (leading < raw.len and (raw[leading] == ' ' or raw[leading] == '\t')) : (leading += 1) {}
    const trimmed = raw[leading..];
    var marker: []const u8 = undefined;
    var content: []const u8 = undefined;
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or
        std.mem.startsWith(u8, trimmed, "+ "))
    {
        marker = "•";
        content = trimmed[2..];
    } else {
        var digits: usize = 0;
        while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) : (digits += 1) {}
        if (digits == 0 or digits + 1 >= trimmed.len or
            (trimmed[digits] != '.' and trimmed[digits] != ')') or trimmed[digits + 1] != ' ')
        {
            return null;
        }
        marker = trimmed[0 .. digits + 1];
        content = trimmed[digits + 2 ..];
    }
    if (std.mem.startsWith(u8, content, "[ ] ")) {
        marker = "☐";
        content = content[4..];
    } else if (std.mem.startsWith(u8, content, "[x] ") or std.mem.startsWith(u8, content, "[X] ")) {
        marker = "☑";
        content = content[4..];
    }
    return .{ .content = content, .marker = marker, .indent = @min(leading, 8) };
}

fn headingLevel(trimmed: []const u8) usize {
    var level: usize = 0;
    while (level < trimmed.len and level < 6 and trimmed[level] == '#') : (level += 1) {}
    return if (level > 0 and level < trimmed.len and trimmed[level] == ' ') level else 0;
}

fn isHorizontalRule(trimmed: []const u8) bool {
    var glyph: u8 = 0;
    var count: usize = 0;
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (glyph == 0) glyph = byte else if (glyph != byte) return false;
        count += 1;
    }
    return count >= 3;
}

fn ensureBlankLine(arena: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    if (lines.items.len > 0 and lineWidthBytes(lines.items[lines.items.len - 1]) > 0) try blankLine(arena, lines);
}

fn lineWidthBytes(line: Line) usize {
    return line.text.len + line.text2.len + line.text3.len;
}

/// Terminal-native Markdown renderer with a readable measure, hierarchical
/// headings/lists, rich tables and code panels, and semantic callouts. It
/// remains line-oriented so scrollback and selection retain stable rows.
fn wrapMarkdown(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
) !void {
    var logical: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| try logical.append(arena, line);

    const gutter = markdownGutter(width);
    const measure = markdownMeasure(width);
    const paragraph_prefix = try std.fmt.allocPrint(arena, "{s}• ", .{gutter});
    const paragraph_continuation = try spaces(arena, displayWidth(paragraph_prefix));
    var i: usize = 0;
    while (i < logical.items.len) {
        const raw = logical.items[i];
        const trimmed = std.mem.trimStart(u8, raw, " \t");

        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            const fence = trimmed[0..3];
            const info = std.mem.trim(u8, trimmed[3..], " \t\r");
            var end = i + 1;
            while (end < logical.items.len and
                !std.mem.startsWith(u8, std.mem.trimStart(u8, logical.items[end], " \t"), fence)) : (end += 1)
            {}
            try ensureBlankLine(arena, lines);
            try appendCodeBlock(arena, lines, logical.items[i + 1 .. end], info, measure, gutter);
            try ensureBlankLine(arena, lines);
            i = if (end < logical.items.len) end + 1 else end;
            continue;
        }

        if (i + 1 < logical.items.len and
            (try tableCells(arena, raw)).len > 0 and
            try isTableDelimiter(arena, logical.items[i + 1]))
        {
            var end = i + 2;
            while (end < logical.items.len and (try tableCells(arena, logical.items[end])).len > 0) : (end += 1) {}
            try ensureBlankLine(arena, lines);
            try appendTable(arena, lines, logical.items, i, end, measure, gutter);
            try ensureBlankLine(arena, lines);
            i = end;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const quote = trimmed[2..];
            if (calloutMarker(quote)) |kind| {
                var bodies: std.ArrayList([]const u8) = .empty;
                var end = i + 1;
                while (end < logical.items.len) : (end += 1) {
                    const next = std.mem.trimStart(u8, logical.items[end], " \t");
                    if (!std.mem.startsWith(u8, next, ">")) break;
                    const body = std.mem.trimStart(u8, next[1..], " ");
                    try bodies.append(arena, body);
                }
                try ensureBlankLine(arena, lines);
                try appendCallout(arena, lines, bodies.items, kind, true, measure, gutter);
                try ensureBlankLine(arena, lines);
                i = end;
                continue;
            }
            const prefix = try std.fmt.allocPrint(arena, "{s}│ ", .{gutter});
            try appendMarkdownLine(arena, lines, quote, prefix, prefix, Palette.md_quote, measure);
            i += 1;
            continue;
        }

        if (trimmed.len == 0) {
            try ensureBlankLine(arena, lines);
            i += 1;
            continue;
        }

        if (semanticCallout(trimmed)) |kind| {
            const body = [_][]const u8{trimmed};
            try ensureBlankLine(arena, lines);
            try appendCallout(arena, lines, &body, kind, false, measure, gutter);
            try ensureBlankLine(arena, lines);
            i += 1;
            continue;
        }

        const level = headingLevel(trimmed);
        if (level > 0) {
            try ensureBlankLine(arena, lines);
            const marker: []const u8 = if (level == 1) "◆ " else if (level == 2) "▸ " else "";
            const prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ gutter, marker });
            const continuation = try spaces(arena, displayWidth(prefix));
            const style = if (level == 1)
                Palette.md_heading_1
            else if (level == 2)
                Palette.md_heading_2
            else
                Palette.md_heading_3;
            try appendMarkdownLine(arena, lines, trimmed[level + 1 ..], prefix, continuation, style, measure);
            i += 1;
            continue;
        }

        if (parseListItem(raw)) |item| {
            const indent = try spaces(arena, item.indent);
            const prefix = try std.fmt.allocPrint(arena, "{s}{s}{s} ", .{ gutter, indent, item.marker });
            const continuation = try spaces(arena, displayWidth(prefix));
            try appendMarkdownLine(arena, lines, item.content, prefix, continuation, Palette.assistant, measure);
            i += 1;
            continue;
        }

        if (isHorizontalRule(trimmed)) {
            var rule: std.ArrayList(u8) = .empty;
            try appendGlyphNTimes(arena, &rule, "─", @min(measure -| displayWidth(gutter), 64));
            try lines.append(arena, .{ .text = gutter, .style = .{}, .text2 = rule.items, .style2 = Palette.md_rule, .links_resolved = true });
            i += 1;
            continue;
        }

        const lead = std.mem.startsWith(u8, trimmed, "**") and std.mem.endsWith(u8, trimmed, "**");
        try appendMarkdownLine(
            arena,
            lines,
            raw,
            paragraph_prefix,
            paragraph_continuation,
            if (lead) Palette.md_lead else Palette.assistant,
            measure,
        );
        i += 1;
    }
}

fn inputPanelHeight(content_height: usize) usize {
    return content_height + 2; // one blank row above and below the editor
}

fn drawCommandMenu(
    app: *App,
    win: vaxis.Window,
    arena: std.mem.Allocator,
    input_top: u16,
    width: u16,
) !void {
    if (app.mode != .insert or app.picker != null or app.editor.isWalkingHistory() or commandQuery(&app.editor) == null) return;
    const matches = commandMatches(&app.editor);
    if (matches.len == 0) return;

    const shown: u16 = @intCast(@min(matches.len, composer_commands.len));
    const menu_h = shown + 1; // results + keyboard hint
    if (input_top < menu_h) return;
    app.command_selection = @min(app.command_selection, matches.len - 1);

    const menu = win.child(.{
        .x_off = 1,
        .y_off = @intCast(input_top - menu_h),
        .width = width -| 2,
        .height = menu_h,
    });
    menu.fill(.{ .style = Palette.command_menu });

    const pad = "                        ";
    var row: usize = 0;
    while (row < shown) : (row += 1) {
        const command = composer_commands[matches.indices[row]];
        const selected = row == app.command_selection;
        const row_style = if (selected) Palette.command_selected else Palette.command_menu;
        const name_style = if (selected) Palette.command_selected_name else Palette.command_name;
        const description_style = if (selected) Palette.command_selected_description else Palette.command_description;
        const row_win = menu.child(.{ .y_off = @intCast(row), .height = 1, .width = menu.width });
        row_win.fill(.{ .style = row_style });

        const label = try std.fmt.allocPrint(arena, " {s}{s}", .{ command.name, command.usage });
        const pad_len: usize = if (label.len < pad.len) pad.len - label.len else 1;
        const segments = [_]vaxis.Segment{
            .{ .text = label, .style = name_style },
            .{ .text = pad[0..pad_len], .style = row_style },
            .{ .text = command.description, .style = description_style },
        };
        _ = row_win.print(&segments, .{ .wrap = .none });
    }

    const hint = menu.child(.{ .y_off = @intCast(shown), .height = 1, .width = menu.width });
    _ = hint.printSegment(.{
        .text = " ↑↓ select · Tab complete · Enter run",
        .style = Palette.command_description,
    }, .{ .wrap = .none });
}

const ShortcutHelpRow = struct {
    key: []const u8 = "",
    description: []const u8,
    heading: bool = false,
};

const shortcut_help_rows = [_]ShortcutHelpRow{
    .{ .key = "Esc / i", .description = "return to insert mode" },
    .{ .key = "gt / gT", .description = "switch sessions · Ngt = Nth recent" },
    .{ .key = "J", .description = "join lines" },
    .{ .key = "a / A / I", .description = "insert after cursor / line end / line start" },
    .{ .key = "j / k", .description = "scroll one line" },
    .{ .key = "Ctrl+d / Ctrl+u", .description = "scroll one page" },
    .{ .key = "gg / G", .description = "jump to top / bottom" },
    .{ .key = "?", .description = "toggle shortcut help" },
    .{ .key = "q", .description = "quit Marlin" },
    .{ .description = "COMPOSER (vim)", .heading = true },
    .{ .key = "h l w b 0 $", .description = "move in the input line" },
    .{ .key = "x / D", .description = "delete char / to line end" },
    .{ .key = "d c y + motion", .description = "operators: w b e 0 $ f t, dd/cc/yy, iw i\" i( …" },
    .{ .key = "counts f t ; ,", .description = "3w d2w 2dd · find char, repeat" },
    .{ .key = "u / Ctrl+R", .description = "undo / redo" },
    .{ .key = "s S C Y o O r ~", .description = "vim synonyms, open line, replace, case" },
    .{ .key = "p", .description = "paste the yank register" },
    .{ .description = "COPY MODE", .heading = true },
    .{ .key = "v", .description = "enter copy mode (cursor over transcript)" },
    .{ .key = "hjkl w b 0 $ g G", .description = "move the cursor" },
    .{ .key = "v / V", .description = "select char-wise / line-wise" },
    .{ .key = "y", .description = "yank: clipboard + paste register" },
    .{ .key = "arrows", .description = "scroll the view" },
    .{ .description = "GLOBAL", .heading = true },
    .{ .key = "Ctrl+L", .description = "redraw and return to bottom" },
    .{ .key = "Ctrl+T", .description = "toggle tool transcript" },
    .{ .key = "Ctrl+C", .description = "interrupt the active turn" },
};

fn drawShortcutHelp(win: vaxis.Window, arena: std.mem.Allocator) !void {
    const h = win.height;
    const w = win.width;
    if (h < 8 or w < 32) return;

    const shown: u16 = @intCast(@min(shortcut_help_rows.len, h -| 6));
    const box_h = shown + 3; // title + rows + close hint
    const box_w: u16 = @min(@as(u16, 58), w -| 4);
    const box = win.child(.{
        .x_off = @intCast((w -| box_w) / 2),
        .y_off = @intCast((h -| box_h) / 2),
        .width = box_w,
        .height = box_h,
        .border = .{ .where = .all, .style = Palette.shortcut_border },
    });
    box.fill(.{ .style = Palette.shortcut_panel });
    _ = box.printSegment(.{
        .text = " NORMAL MODE · shortcuts",
        .style = Palette.shortcut_key,
    }, .{ .wrap = .none });

    const key_column: usize = 19;
    var row: u16 = 0;
    while (row < shown) : (row += 1) {
        const item = shortcut_help_rows[row];
        const row_win = box.child(.{ .y_off = @intCast(row + 1), .height = 1, .width = box.width });
        if (item.heading) {
            const heading = try std.fmt.allocPrint(arena, " {s}", .{item.description});
            _ = row_win.printSegment(.{ .text = heading, .style = Palette.shortcut_key }, .{ .wrap = .none });
            continue;
        }
        const key = try std.fmt.allocPrint(arena, " {s}", .{item.key});
        const padding = try spaces(arena, if (key.len < key_column) key_column - key.len else 1);
        const segments = [_]vaxis.Segment{
            .{ .text = key, .style = Palette.shortcut_key },
            .{ .text = padding, .style = Palette.shortcut_panel },
            .{ .text = item.description, .style = Palette.shortcut_text },
        };
        _ = row_win.print(&segments, .{ .wrap = .none });
    }

    _ = box.printSegment(.{
        .text = " Esc · ? · q close",
        .style = Palette.shortcut_text,
    }, .{ .row_offset = shown + 1, .wrap = .none });
}

fn draw(app: *App, vx: *vaxis.Vaxis, arena: std.mem.Allocator) !void {
    const win = vx.window();
    win.clear();
    const h = win.height;
    const w = win.width;
    if (h < 4 or w < 20) return;

    // The composer is a three-row panel for a one-line prompt (padding,
    // content, padding) and grows with multiline input.
    const prompt: []const u8 = if (app.mode == .insert) "❯ " else ": ";
    const panel_inner_w = w -| 2; // one cell of horizontal padding
    const content_h: u16 = @intCast(app.editor.displayHeight(panel_inner_w -| 2));
    const input_h: u16 = @intCast(inputPanelHeight(content_h));
    const input_gap: u16 = 1;
    const view_h: u16 = h -| (input_h + input_gap + 1); // input + gap + status

    // ---- session view ----
    var lines = try layoutLines(arena, app, w);
    const total = lines.items.len;
    // Anchor while reading: scroll_up counts from the BOTTOM, so content
    // arriving while scrolled up would slide the view. Compensate by the
    // growth delta; pinned (scroll_up == 0) stays pinned.
    if (app.scroll_up > 0 and total > app.last_total_lines) {
        app.scroll_up +|= total - app.last_total_lines;
    }
    app.last_total_lines = total;
    const max_scroll = total -| view_h;
    if (app.scroll_up > max_scroll) app.scroll_up = max_scroll;
    const first_visible = (total -| view_h) -| app.scroll_up;
    app.last_first_visible = first_visible;
    app.last_view_h = view_h;
    const visible = lines.items[first_visible..@min(first_visible + view_h, total)];

    for (visible, 0..) |ln, row| {
        const abs_line = first_visible + row;
        if (ln.fill_style) |fill_style| {
            const fill_start = @min(ln.fill_start, w);
            const fill_width = @min(ln.fill_width orelse (w -| fill_start), w -| fill_start);
            const row_win = win.child(.{
                .x_off = @intCast(fill_start),
                .y_off = @intCast(row),
                .height = 1,
                .width = fill_width,
            });
            row_win.fill(.{ .style = fill_style });
        }
        var segs_buf: [3]vaxis.Segment = undefined;
        var n: usize = 0;
        segs_buf[n] = .{ .text = ln.text, .style = ln.style };
        n += 1;
        if (ln.text2.len > 0) {
            segs_buf[n] = .{ .text = ln.text2, .style = ln.style2 };
            n += 1;
        }
        if (ln.text3.len > 0) {
            segs_buf[n] = .{ .text = ln.text3, .style = ln.style3 };
            n += 1;
        }
        _ = win.print(segs_buf[0..n], .{
            .row_offset = @intCast(row),
            .wrap = .none,
        });
        applyLineSyntax(win, @intCast(row), ln);
        applyLineLinks(win, @intCast(row), ln);
        // Apply selection after printing so partial-cell highlighting keeps
        // each segment's original syntax color and other style attributes.
        if (app.selection()) |sel| {
            if (sel.columns(abs_line, lineWidth(win, ln))) |cols| {
                var col = cols.start;
                while (col < cols.end and col < @as(usize, w)) : (col += 1) {
                    const cell = win.readCell(@intCast(col), @intCast(row)) orelse continue;
                    var selected_cell = cell;
                    selected_cell.style.reverse = true;
                    win.writeCell(@intCast(col), @intCast(row), selected_cell);
                }
            }
        }
        if (app.copy_cursor) |cursor| {
            if (cursor.line == abs_line) {
                // Capture the cursor line's geometry for $/w/b, then draw a
                // block cursor (reverse; inside a selection the un-reversed
                // cell reads as the cursor, exactly like vim).
                app.copy_cursor_line_width = lineWidth(win, ln);
                app.copy_cursor_line_text.clearRetainingCapacity();
                if (lineText(arena, ln)) |txt| {
                    app.copy_cursor_line_text.appendSlice(app.gpa, txt) catch {};
                } else |_| {}
                const col = @min(cursor.col, @max(app.copy_cursor_line_width, 1) - 1);
                if (col < @as(usize, w)) {
                    if (win.readCell(@intCast(col), @intCast(row))) |cell| {
                        var cursor_cell = cell;
                        cursor_cell.style.reverse = !cursor_cell.style.reverse;
                        win.writeCell(@intCast(col), @intCast(row), cursor_cell);
                    }
                }
            }
        }
    }

    // ---- input box ----
    const input_top = h - 1 - input_h;
    const input_panel = win.child(.{ .y_off = input_top, .height = input_h, .width = w });
    input_panel.fill(.{ .style = Palette.prompt_panel });
    const input_win = input_panel.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = panel_inner_w,
        .height = content_h,
    });
    app.editor.draw(input_win, prompt, Palette.prompt_mark, Palette.prompt_text);
    if (app.mode == .normal) win.hideCursor();
    try drawCommandMenu(app, win, arena, input_top, w);

    // ---- status bar ----
    const status_win = win.child(.{ .y_off = h - 1, .height = 1, .width = w });
    status_win.fill(.{ .style = Palette.status_bar });
    const state_txt: []const u8 = switch (app.state) {
        .idle => "idle",
        .running => "running",
        .awaiting_approval => "APPROVAL?",
        .err => "error",
        .done => "done",
    };
    const state_style: vaxis.Style = switch (app.state) {
        .idle, .done => Palette.status_idle,
        .running => Palette.status_running,
        .awaiting_approval => Palette.status_approval,
        .err => Palette.status_error,
    };
    const context_percent = if (app.context_limit > 0)
        app.context_used * 100 / app.context_limit
    else
        0;
    const ctx_txt = try std.fmt.allocPrint(arena, "ctx {d}%", .{context_percent});
    const ctx_style = if (context_percent >= 90)
        Palette.status_context_hot
    else if (context_percent >= 70)
        Palette.status_context_warn
    else
        Palette.status_context;
    const cwd_txt = try statusCwd(arena, app.cwd.items, app.home.items);
    var session_handle_buf: session_handle.Full = undefined;
    const session_txt = try std.fmt.allocPrint(arena, "{s}", .{app.displaySessionHandle(&session_handle_buf, app.sid)});
    const scroll_txt = try std.fmt.allocPrint(arena, "↕ {d} (G: bottom)", .{app.scroll_up});
    const focused_parent_sid = if (app.sessionSummary(app.sid)) |summary| summary.parent_sid else null;
    var child_count: usize = 0;
    var child_running: usize = 0;
    var child_approvals: usize = 0;
    var child_errors: usize = 0;
    for (app.sessions.items) |session| {
        if (session.parent_sid != app.sid) continue;
        child_count += 1;
        switch (session.state) {
            .running => child_running += 1,
            .awaiting_approval => child_approvals += 1,
            .err => child_errors += 1,
            else => {},
        }
    }
    const child_txt: []const u8 = if (focused_parent_sid) |parent_sid| child: {
        var parent_handle_buf: session_handle.Full = undefined;
        break :child try std.fmt.allocPrint(arena, "child of {s}", .{app.displaySessionHandle(&parent_handle_buf, parent_sid)});
    } else if (child_count > 0)
        if (child_approvals > 0)
            try std.fmt.allocPrint(arena, "{d} child{s} · {d} approval{s}", .{
                child_count,
                if (child_count == 1) "" else "ren",
                child_approvals,
                if (child_approvals == 1) "" else "s",
            })
        else if (child_errors > 0)
            try std.fmt.allocPrint(arena, "{d} child{s} · {d} error{s}", .{
                child_count,
                if (child_count == 1) "" else "ren",
                child_errors,
                if (child_errors == 1) "" else "s",
            })
        else if (child_running > 0)
            try std.fmt.allocPrint(arena, "{d} child{s} · {d} running", .{
                child_count,
                if (child_count == 1) "" else "ren",
                child_running,
            })
        else
            try std.fmt.allocPrint(arena, "{d} child{s}", .{
                child_count,
                if (child_count == 1) "" else "ren",
            })
    else
        "";
    const child_style = if (child_approvals > 0)
        Palette.status_approval
    else if (child_errors > 0)
        Palette.status_error
    else if (child_running > 0)
        Palette.status_running
    else
        Palette.status_child;
    var background_running: usize = 0;
    var background_approvals: usize = 0;
    for (app.sessions.items) |session| {
        if (session.sid == app.sid) continue;
        // The hierarchy segment owns the focused parent/child relationship;
        // keep the generic background counter for unrelated sessions and
        // running siblings rather than showing the same activity twice.
        if (session.parent_sid == app.sid) continue;
        if (focused_parent_sid != null and session.sid == focused_parent_sid.?) continue;
        switch (session.state) {
            .running => background_running += 1,
            .awaiting_approval => background_approvals += 1,
            else => {},
        }
    }
    const background_txt = if (background_running > 0 or background_approvals > 0)
        try std.fmt.allocPrint(arena, "{d} running · {d} approval{s}", .{
            background_running,
            background_approvals,
            if (background_approvals == 1) "" else "s",
        })
    else
        "";

    // Stable public session handle, shared with `marlin ls` and accepted by
    // attach/archive/kill/compact as any unique prefix of four or more chars.
    var status_segments: [27]vaxis.Segment = undefined;
    var status_n: usize = 0;
    status_segments[status_n] = .{ .text = " ", .style = Palette.status_bar };
    status_n += 1;
    status_segments[status_n] = .{ .text = state_txt, .style = state_style };
    status_n += 1;
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = statusModel(app.model.items), .style = Palette.status_model };
    status_n += 1;
    if (app.effort != .auto) {
        status_segments[status_n] = .{
            .text = try std.fmt.allocPrint(arena, " {s}", .{@tagName(app.effort)}),
            .style = Palette.status_effort,
        };
        status_n += 1;
    }
    if (app.context_limit > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = ctx_txt, .style = ctx_style };
        status_n += 1;
    }
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = cwd_txt, .style = Palette.status_cwd };
    status_n += 1;
    if (app.scroll_up > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = scroll_txt, .style = Palette.status_bar };
        status_n += 1;
    }
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = session_txt, .style = Palette.status_sep };
    status_n += 1;
    if (child_txt.len > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = child_txt, .style = child_style };
        status_n += 1;
    }
    if (background_txt.len > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{
            .text = background_txt,
            .style = if (background_approvals > 0) Palette.status_approval else Palette.status_running,
        };
        status_n += 1;
    }
    if (app.notice.items.len > 0) {
        status_segments[status_n] = .{ .text = "  ", .style = Palette.status_bar };
        status_n += 1;
        status_segments[status_n] = .{ .text = app.notice.items, .style = Palette.status_notice };
        status_n += 1;
    }
    _ = status_win.print(status_segments[0..status_n], .{ .wrap = .none });

    // Far-right indicators: shell sandbox state and DNS blocklist filtering.
    // Drawn after the left segments so they win on narrow terminals.
    const sandboxed_now = app.currentSandboxed();
    const sandbox_txt: []const u8 = if (sandboxed_now)
        "⛨ sandboxed"
    else if (app.conn.sandbox_available)
        "⛨ sandbox off"
    else
        "⛨ no sandbox";
    const sandbox_style = if (sandboxed_now)
        Palette.status_running
    else if (app.conn.sandbox_available)
        Palette.status_context_warn
    else
        Palette.status_sep;
    // The shield is 3 UTF-8 bytes but renders as one cell; every variant
    // above carries exactly one, so columns = bytes - 2.
    const sandbox_cols: u16 = @intCast(sandbox_txt.len - "⛨".len + 1);
    const dns_available = app.conn.network_filtering;
    const dns_on = app.currentNetworkFiltering();
    const dns_txt: []const u8 = if (dns_on)
        "dnsblock on"
    else if (dns_available)
        "dnsblock off"
    else if (app.conn.network_configured)
        "dnsblock err"
    else
        "dnsblock off";
    const dns_style = if (dns_on)
        Palette.status_running
    else if (dns_available or app.conn.network_configured)
        Palette.status_context_warn
    else
        Palette.status_sep;
    const full_txt: []const u8 = if (app.permissions_full) "FULL ACCESS" else "";
    var right_w: u16 = sandbox_cols + 1 + @as(u16, @intCast(dns_txt.len)) + 3;
    if (full_txt.len > 0) right_w += @intCast(full_txt.len + 3);
    if (status_win.width > right_w) {
        const right_win = status_win.child(.{
            .x_off = @intCast(status_win.width - right_w),
            .width = right_w,
        });
        var right_segments: [6]vaxis.Segment = undefined;
        var right_n: usize = 0;
        if (full_txt.len > 0) {
            right_segments[right_n] = .{ .text = full_txt, .style = Palette.status_approval };
            right_n += 1;
            right_segments[right_n] = .{ .text = " · ", .style = Palette.status_sep };
            right_n += 1;
        }
        right_segments[right_n] = .{ .text = dns_txt, .style = dns_style };
        right_n += 1;
        right_segments[right_n] = .{ .text = " · ", .style = Palette.status_sep };
        right_n += 1;
        right_segments[right_n] = .{ .text = sandbox_txt, .style = sandbox_style };
        right_n += 1;
        right_segments[right_n] = .{ .text = " ", .style = Palette.status_bar };
        right_n += 1;
        _ = right_win.print(right_segments[0..right_n], .{ .wrap = .none });
    }

    // ---- model / reasoning-effort selector overlay ----
    if (app.picker) |sel| {
        const items = try app.pickerItems(arena);
        const total_src = app.pickerSource().len;
        const current = app.pickerCurrent();
        const picker_label: []const u8 = switch (app.picker_kind) {
            .model => "model",
            .effort => "effort",
            .session => "sessions",
        };

        var widest: usize = 30;
        for (items) |f| {
            var row_width = displayWidth(f);
            if (app.picker_kind == .model) {
                if (app.pricingForModel(f)) |pricing| {
                    row_width += 2 + displayWidth(try formatModelPricing(arena, pricing));
                }
            }
            widest = @max(widest, @min(row_width, 96));
        }
        const box_w: u16 = @intCast(@min(widest + 8, @as(usize, w -| 4)));
        const list_max: u16 = @min(@as(u16, 14), h -| 6);
        const shown: u16 = @intCast(@min(items.len, list_max));
        const box_h: u16 = shown + 3; // filter line + list + hint line
        const px: i17 = @intCast((w -| box_w) / 2);
        const py: i17 = @intCast((h -| box_h) / 2);
        const box = win.child(.{
            .x_off = px,
            .y_off = py,
            .width = box_w,
            .height = box_h,
            .border = .{ .where = .all, .style = Palette.tool },
        });
        box.fill(.{ .style = .{} });

        // Filter line (acts as a mini prompt).
        const src_note: []const u8 = if (app.picker_kind == .model and app.catalog.items.len == 0)
            " (favorites — catalog loading…)"
        else
            "";
        const fline = try std.fmt.allocPrint(arena, " {s} · filter: {s}▏{s}", .{
            picker_label,
            app.picker_filter.items,
            src_note,
        });
        _ = box.printSegment(.{ .text = fline, .style = Palette.user }, .{ .wrap = .none });

        // Windowed list around the selection.
        const win_start = if (sel >= list_max) sel + 1 - list_max else 0;
        var row: u16 = 1;
        var i: usize = win_start;
        while (i < items.len and row <= shown) : (i += 1) {
            const f = items[i];
            const cur = if (app.picker_kind == .session)
                (app.sessionIdForLabel(f) orelse 0) == app.sid
            else
                std.mem.eql(u8, f, current);
            const line = if (app.picker_kind == .model)
                try pickerModelLine(arena, f, app.pricingForModel(f), cur, box_w -| 4)
            else
                try std.fmt.allocPrint(arena, " {s}{s}", .{ f[0..@min(f.len, box_w -| 4)], if (cur) " ●" else "" });
            const style: vaxis.Style = if (i == sel)
                .{ .fg = .{ .index = 6 }, .bold = true, .reverse = true }
            else if (cur)
                .{ .fg = .{ .index = 6 } }
            else
                .{};
            _ = box.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .wrap = .none });
            row += 1;
        }
        const hint = try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter · Esc", .{ items.len, total_src });
        _ = box.printSegment(.{ .text = hint, .style = Palette.tool_out }, .{ .row_offset = shown + 1, .wrap = .none });
    }

    if (app.shortcut_help and app.picker == null) try drawShortcutHelp(win, arena);
}

// ------------------------------------------------------------ entry point --

/// Reader thread: daemon socket lines → vaxis event queue.
fn readerThread(app: *App, loop: *vaxis.Loop(Event)) void {
    while (true) {
        const line = app.conn.reader.interface.takeDelimiterInclusive('\n') catch break;
        const owned = app.gpa.dupe(u8, line) catch break;
        loop.postEvent(.{ .daemon_line = owned }) catch {
            app.gpa.free(owned);
            break;
        };
    }
    loop.postEvent(.daemon_gone) catch {};
}

fn animationThread(app: *App, loop: *vaxis.Loop(Event)) void {
    while (!app.animation_stop.load(.acquire)) {
        if (app.animation_active.load(.acquire)) {
            loop.postEvent(.tick) catch return;
            app.io.sleep(.fromMilliseconds(90), .awake) catch {};
        } else {
            app.io.sleep(.fromMilliseconds(200), .awake) catch {};
        }
    }
}

pub const RebootPlan = struct {
    request: RebootRequest = .none,
    sid: u64 = 0,
};

/// First-run bootstrap: prompt for an OpenRouter key on plain stdio (before
/// any TUI), store it in ~/.config/marlin/credentials (0600), and inject it
/// into this process's environ so the autostarted daemon inherits it.
/// Returns false when the user gave nothing usable.
fn bootstrapKey(gpa: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map) !bool {
    var obuf: [1024]u8 = undefined;
    var ow: Io.File.Writer = .init(.stderr(), io, &obuf);
    try ow.interface.print(
        \\marlin needs a provider to talk to.
        \\
        \\  OpenRouter (one key, every model): https://openrouter.ai/keys
        \\  (or set MARLIN_LOCAL_BASE_URL for any OpenAI-compatible endpoint)
        \\
        \\Paste your OpenRouter API key (stored in ~/.config/marlin/credentials,
        \\chmod 600; the env var OPENROUTER_API_KEY always overrides): 
    , .{});
    try ow.interface.flush();

    var ibuf: [512]u8 = undefined;
    var reader: Io.File.Reader = .init(.stdin(), io, &ibuf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch {
        try ow.interface.print("\nno input — aborting.\n", .{});
        try ow.interface.flush();
        return false;
    };
    const key = std.mem.trim(u8, line, " \t\r\n");
    if (key.len < 8) {
        try ow.interface.print("that doesn't look like a key — aborting.\n", .{});
        try ow.interface.flush();
        return false;
    }
    try credentials.store(gpa, io, environ, "OPENROUTER_API_KEY", key);
    try environ.put(
        try environ.allocator.dupe(u8, "OPENROUTER_API_KEY"),
        try environ.allocator.dupe(u8, key),
    );
    try ow.interface.print("saved. starting marlin…\n", .{});
    try ow.interface.flush();
    return true;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    self_exe: []const u8,
    sid_arg: ?[]const u8,
    reboot_out: ?*RebootPlan,
) !u8 {
    // -- first-run bootstrap: no provider key → prompt before the TUI --
    if (environ.get("OPENROUTER_API_KEY") == null and environ.get("MARLIN_LOCAL_BASE_URL") == null) {
        if (!try bootstrapKey(gpa, io, environ)) return 1;
    }

    // -- connect + pick session BEFORE entering the TUI --
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        std.log.err("cannot reach daemon: {t}", .{e});
        return 1;
    };
    defer conn.deinit();

    var loaded_config = try config.load(gpa, io, environ);
    defer loaded_config.deinit();
    const cfg = loaded_config.value;
    var model_at_start: []const u8 = cfg.model_default;
    var effort_at_start: proto.ReasoningEffort = cfg.effort_default;
    var model_buf: [256]u8 = undefined;
    var cwd_at_start: []const u8 = "";
    var cwd_buf: [4096]u8 = undefined;
    var initial_known_ids: std.ArrayList(u64) = .empty;
    var initial_ids_transferred = false;
    defer if (!initial_ids_transferred) initial_known_ids.deinit(gpa);

    var sid: u64 = 0;
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Fetch metadata even for an explicit attach: the session may have
        // been created from another directory (or another client process).
        try conn.send(.{ .session_list = .{ .include_archived = true } });
        const list = try conn.recvUntil(arena, .session_list_result);
        for (list.sessions) |session| try initial_known_ids.append(gpa, session.sid);
        var selected: ?usize = null;
        if (sid_arg) |query| {
            const ids = try arena.alloc(u64, list.sessions.len);
            for (list.sessions, 0..) |session, i| ids[i] = session.sid;
            const requested = session_handle.resolve(query, ids) catch |err| {
                switch (err) {
                    error.PrefixTooShort => std.log.err("session handle '{s}' is too short (use at least {d} characters)", .{ query, session_handle.min_prefix_len }),
                    error.InvalidHandle => std.log.err("invalid session handle '{s}'", .{query}),
                    error.NotFound => std.log.err("no session matches '{s}'", .{query}),
                    error.Ambiguous => std.log.err("session handle '{s}' is ambiguous; use more characters from `marlin ls --all`", .{query}),
                }
                return 2;
            };
            sid = requested;
            for (list.sessions, 0..) |session, i| {
                if (session.sid == requested) {
                    selected = i;
                    break;
                }
            }
        } else {
            for (list.sessions, 0..) |session, i| {
                if (session.archived) continue;
                sid = session.sid;
                selected = i;
                break;
            }
        }

        if (selected) |i| {
            const m = list.sessions[i].model;
            const model_len = @min(m.len, model_buf.len);
            @memcpy(model_buf[0..model_len], m[0..model_len]);
            model_at_start = model_buf[0..model_len];
            effort_at_start = list.sessions[i].effort;

            const session_cwd = list.sessions[i].cwd;
            const cwd_len = @min(session_cwd.len, cwd_buf.len);
            @memcpy(cwd_buf[0..cwd_len], session_cwd[0..cwd_len]);
            cwd_at_start = cwd_buf[0..cwd_len];
        } else if (sid_arg == null) {
            const cwd_len = try std.process.currentPath(io, &cwd_buf);
            cwd_at_start = cwd_buf[0..cwd_len];
            try conn.send(.{ .session_create = .{
                .cwd = cwd_at_start,
                .model = cfg.model_default,
                .effort = cfg.effort_default,
            } });
            const created = try conn.recvUntil(arena, .session_created);
            sid = created.sid;
        }
        // Full replay: seq 1 onward.
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 1 } });
    }

    var app = App{
        .gpa = gpa,
        .io = io,
        .conn = conn,
        .sid = sid,
        .editor = Editor.init(gpa),
        .known_session_ids = initial_known_ids,
        .cfg = cfg,
    };
    initial_ids_transferred = true;
    defer app.deinit();
    app.setModelStr(model_at_start);
    app.effort = effort_at_start;
    app.setCwdStr(cwd_at_start);
    if (environ.get("HOME")) |home| app.setHomeStr(home);
    app.touchRecentSession(sid);
    // Healthy filtering is visible in the status-bar segment already; only
    // a misconfiguration (configured but failed to load) warrants a notice.
    if (!conn.network_filtering and conn.network_configured) {
        app.setNotice("dnsblock configured but unavailable — feed load failed; networking is fail-open", .{});
    }

    // -- vaxis init --
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, environ, .{
        // Doubles as the bracketed-paste allocator: Loop passes it when
        // parsing paste bodies into .paste events.
        .system_clipboard_allocator = gpa,
    });
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.setBracketedPaste(writer, true);
    // Mouse: wheel scrolls the session view; native cell-precise selection
    // copies through OSC52. Shift+drag remains the terminal's escape hatch.
    try vx.setMouseMode(writer, true);
    try writer.flush();

    // Initial size: not all paths deliver a winsize event up-front (and a
    // PTY may report late); fetch it directly so the first frame renders.
    {
        var ws = tty.getWinsize() catch vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        if (ws.rows == 0 or ws.cols == 0) ws = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        app.term_cols = ws.cols;
        try vx.resize(gpa, tty.writer(), ws);
    }

    // -- daemon reader thread --
    const rt = try std.Thread.spawn(.{}, readerThread, .{ &app, &loop });
    // Joined at exit: we shutdown() the socket which EOFs the reader —
    // closing the fd under a live read is a BADF panic on the Threaded Io.
    defer rt.join();
    defer conn.stream.shutdown(io, .both) catch {};
    // Lightweight catalog/status updates for every session; block streams
    // remain subscribed only for the focused session.
    try conn.send(.{ .session_watch = .{} });

    const animation_thread = try std.Thread.spawn(.{}, animationThread, .{ &app, &loop });
    defer animation_thread.join();
    defer app.animation_stop.store(true, .release);

    // First frame before any event arrives.
    {
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        try draw(&app, &vx, frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }

    // -- main event loop --
    while (!app.should_quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try handleKey(&app, key),
            .mouse => |m| handleMouse(&app, m),
            .tick => app.spinner_frame +%= 1,
            .winsize => |ws| {
                app.term_cols = ws.cols;
                try vx.resize(gpa, tty.writer(), ws);
            },
            .paste => |text| {
                app.editor.paste(text);
                gpa.free(@constCast(text));
            },
            .daemon_line => |line| {
                app.handleDaemonLine(line);
                // Drain any additional queued lines before redrawing.
                while (try loop.tryEvent()) |ev2| {
                    switch (ev2) {
                        .daemon_line => |l2| app.handleDaemonLine(l2),
                        .daemon_gone => app.should_quit = true,
                        .key_press => |k2| try handleKey(&app, k2),
                        .mouse => |m2| handleMouse(&app, m2),
                        .tick => app.spinner_frame +%= 1,
                        .winsize => |ws2| {
                            app.term_cols = ws2.cols;
                            try vx.resize(gpa, tty.writer(), ws2);
                        },
                        .paste => |t2| {
                            app.editor.paste(t2);
                            gpa.free(@constCast(t2));
                        },
                    }
                }
            },
            .daemon_gone => {
                app.setNotice("daemon connection lost", .{});
                app.should_quit = true;
            },
        }

        if (app.refresh_requested) {
            app.refresh_requested = false;
            vx.queueRefresh();
        }

        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();

        // Completed mouse selection → OSC52 copy (before draw so the
        // notice shows this frame; selection stays highlighted).
        if (app.copy_pending) {
            app.copy_pending = false;
            if (app.selection()) |selection| {
                const farena = frame_arena.allocator();
                const sel_lines = try layoutLines(farena, &app, @intCast(app.term_cols));
                const text = try selectedText(farena, vx.window(), sel_lines.items, selection);
                if (text.len > 0) {
                    app.yank_register.clearRetainingCapacity();
                    app.yank_register.appendSlice(app.gpa, text) catch {};
                    var copied = true;
                    vx.copyToSystemClipboard(writer, text, farena) catch {
                        copied = false;
                    };
                    if (copied)
                        app.setNotice("copied selection", .{})
                    else
                        app.setNotice("clipboard copy failed", .{});
                }
            }
            if (app.sel_clear_after_copy) {
                app.sel_clear_after_copy = false;
                app.sel_anchor = null;
            }
        }

        if (app.clipboard_pending.items.len > 0) {
            var copied = true;
            vx.copyToSystemClipboard(
                writer,
                app.clipboard_pending.items,
                frame_arena.allocator(),
            ) catch {
                copied = false;
            };
            app.clipboard_pending.clearRetainingCapacity();
            if (copied)
                app.setNotice("copied last tool output", .{})
            else
                app.setNotice("clipboard copy failed", .{});
        }

        try draw(&app, &vx, frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }
    if (reboot_out) |ro| ro.* = .{ .request = app.reboot_request, .sid = app.sid };
    return 0;
}

/// Mouse: the wheel ALWAYS scrolls the session view — never the input box,
/// never history. Left press/drag/release selects terminal-cell ranges in
/// the session view; release copies the precise range via OSC52.
fn handleMouse(app: *App, m: vaxis.Mouse) void {
    // Some terminals report the release button as `none`, so complete an
    // active left-button drag based on event type before switching on button.
    if (m.type == .release and app.sel_dragging) {
        if (app.last_view_h > 0) {
            const raw_row: usize = if (m.row < 0) 0 else @intCast(m.row);
            const row = @min(raw_row, app.last_view_h - 1);
            const col: usize = if (m.col < 0) 0 else @intCast(m.col);
            app.sel_head = .{ .line = app.last_first_visible + row, .col = col };
        }
        app.sel_dragging = false;
        if (app.sel_anchor) |anchor| {
            if (anchor.line != app.sel_head.line or anchor.col != app.sel_head.col) {
                app.copy_pending = true;
            } else {
                app.sel_anchor = null;
            }
        }
        return;
    }

    switch (m.button) {
        .wheel_up => app.scroll_up +|= 3,
        .wheel_down => app.scroll_up -|= 3,
        .left => {
            const row: usize = if (m.row < 0) 0 else @intCast(m.row);
            // Only rows inside the session view participate.
            if (row >= app.last_view_h) {
                if (m.type == .press) app.sel_anchor = null; // click below view clears
                return;
            }
            const point = SelectionPoint{
                .line = app.last_first_visible + row,
                .col = if (m.col < 0) 0 else @intCast(m.col),
            };
            switch (m.type) {
                .press => {
                    app.sel_anchor = point;
                    app.sel_head = point;
                    app.sel_dragging = true;
                },
                .drag => {
                    if (app.sel_dragging) app.sel_head = point;
                },
                .release => {}, // active drags are completed above
                .motion => {},
            }
        },
        else => {},
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn isNewlineKey(key: vaxis.Key) bool {
    // Key.matches intentionally consumes Shift for printable text, which
    // could make plain Enter look shifted when a terminal attaches text to
    // control keys. Modifier-sensitive Enter handling must be exact.
    return (key.codepoint == vaxis.Key.enter and (key.mods.shift or key.mods.alt)) or
        (key.codepoint == 'j' and key.mods.ctrl and !key.mods.alt);
}

/// Common readline bindings plus their native terminal-key equivalents. Keep
/// this translation separate from Editor so key compatibility can be tested
/// without constructing a complete TUI App.
const EditCommand = enum {
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    delete_before,
    delete_after,
    delete_word_before,
    delete_word_before_whitespace,
    delete_word_after,
    delete_to_line_start,
    delete_to_line_end,
};

fn editCommand(key: vaxis.Key) ?EditCommand {
    if (key.matches(vaxis.Key.left, .{ .alt = true }) or key.matches('b', .{ .alt = true }))
        return .move_word_left;
    if (key.matches(vaxis.Key.right, .{ .alt = true }) or key.matches('f', .{ .alt = true }))
        return .move_word_right;
    if (key.matches(vaxis.Key.left, .{}) or key.matches('b', .{ .ctrl = true }))
        return .move_left;
    if (key.matches(vaxis.Key.right, .{}) or key.matches('f', .{ .ctrl = true }))
        return .move_right;
    if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true }))
        return .move_line_start;
    if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true }))
        return .move_line_end;
    if (key.matches(vaxis.Key.backspace, .{ .alt = true }))
        return .delete_word_before;
    if (key.matches(vaxis.Key.delete, .{ .alt = true }) or key.matches('d', .{ .alt = true }))
        return .delete_word_after;
    if (key.matches(vaxis.Key.backspace, .{}) or key.matches('h', .{ .ctrl = true }))
        return .delete_before;
    if (key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true }))
        return .delete_after;
    if (key.matches('k', .{ .ctrl = true }))
        return .delete_to_line_end;
    if (key.matches('u', .{ .ctrl = true }))
        return .delete_to_line_start;
    if (key.matches('w', .{ .ctrl = true }))
        return .delete_word_before_whitespace;
    return null;
}

fn isPreviousInputRowKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true });
}

fn isNextInputRowKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true });
}

fn applyEditCommand(ed: *Editor, command: EditCommand) void {
    switch (command) {
        .move_left => ed.moveLeft(),
        .move_right => ed.moveRight(),
        .move_word_left => ed.moveWordLeft(),
        .move_word_right => ed.moveWordRight(),
        .move_line_start => ed.moveLineStart(),
        .move_line_end => ed.moveLineEnd(),
        .delete_before => ed.deleteBefore(),
        .delete_after => ed.deleteAfter(),
        .delete_word_before => ed.deleteWordBefore(),
        .delete_word_before_whitespace => ed.deleteWordBeforeWhitespace(),
        .delete_word_after => ed.deleteWordAfter(),
        .delete_to_line_start => ed.deleteToLineStart(),
        .delete_to_line_end => ed.deleteToLineEnd(),
    }
}

fn handleKey(app: *App, key: vaxis.Key) !void {
    if (key.matches('t', .{ .ctrl = true })) {
        app.show_tool_transcript = !app.show_tool_transcript;
        if (app.show_tool_transcript)
            app.setNotice("tool transcript expanded", .{})
        else
            app.setNotice("tool transcript collapsed", .{});
        return;
    }

    if (key.matches('l', .{ .ctrl = true })) {
        app.clearView();
        return;
    }

    // Ctrl+C is never an implicit process exit. A repeated keypress can land
    // after an interrupt transitions the session to idle; quitting then would
    // make the stop gesture race the daemon status update.
    if (key.matches('c', .{ .ctrl = true })) {
        if (app.state == .running or app.state == .awaiting_approval) {
            app.interrupt();
        } else {
            app.setNotice("nothing to interrupt · q or /quit exits", .{});
        }
        return;
    }

    // Shortcut help is modal: only explicit close keys act on it. Global
    // Ctrl commands above remain available for redraw, transcript, and abort.
    if (app.shortcut_help) {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('?', .{}) or key.matches('q', .{})) {
            app.shortcut_help = false;
        }
        return;
    }

    // Model/effort selector swallows all keys while open. Typing filters;
    // Up/Down or Ctrl+n/p navigate; Enter applies; Esc closes.
    if (app.picker) |sel| {
        if (key.matches(vaxis.Key.escape, .{})) {
            app.picker = null;
            app.picker_filter.clearRetainingCapacity();
            return;
        }
        // Count filtered items to clamp navigation (cheap stack arena).
        var fb: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fb);
        const items = app.pickerItems(fba.allocator()) catch app.pickerSource();
        const n = items.len;

        if (key.matches(vaxis.Key.enter, .{})) {
            if (n > 0) {
                const pick = items[@min(sel, n - 1)];
                app.picker = null;
                app.applyPickerItem(pick);
                app.picker_filter.clearRetainingCapacity();
            }
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            if (n > 0) app.picker = if (sel + 1 < n) sel + 1 else 0;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            if (n > 0) app.picker = if (sel > 0) sel - 1 else n - 1;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (app.picker_filter.items.len > 0) {
                _ = app.picker_filter.pop();
                app.picker = 0;
            }
        } else if (key.text) |txt| {
            if (txt.len > 0 and txt[0] >= 0x20 and txt[0] != 0x7f) {
                app.picker_filter.appendSlice(app.gpa, txt) catch {};
                app.picker = 0;
            }
        }
        return;
    }

    // Approval hotkeys work in both modes when the input is empty.
    if (app.pending != null and app.editor.isEmpty()) {
        if (key.matches('y', .{})) {
            app.approveReply(true);
            return;
        }
        if (key.matches('n', .{})) {
            app.approveReply(false);
            return;
        }
    }

    switch (app.mode) {
        .insert => {
            const ed = &app.editor;
            // Same width draw() gives the editor: terminal minus the prompt.
            const edit_w: usize = app.term_cols -| 2;
            const command_matches = commandMatches(ed);
            // A recalled /command still looks like an autocomplete query.
            // While walking history, Up/Down must keep walking history rather
            // than being captured by the command menu.
            if (command_matches.len > 0 and !ed.isWalkingHistory()) {
                app.command_selection = @min(app.command_selection, command_matches.len - 1);
                if (isNextInputRowKey(key)) {
                    app.command_selection = if (app.command_selection + 1 < command_matches.len)
                        app.command_selection + 1
                    else
                        0;
                    return;
                } else if (isPreviousInputRowKey(key) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    app.command_selection = if (app.command_selection > 0)
                        app.command_selection - 1
                    else
                        command_matches.len - 1;
                    return;
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    const command = composer_commands[command_matches.indices[app.command_selection]];
                    completeCommand(ed, command, true);
                    app.command_selection = 0;
                    return;
                } else if (key.matches(vaxis.Key.enter, .{})) {
                    const command = composer_commands[command_matches.indices[app.command_selection]];
                    completeCommand(ed, command, false);
                    const text = try ed.takeExpanded();
                    defer app.gpa.free(text);
                    app.command_selection = 0;
                    app.submitInput(text);
                    return;
                }
            }
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal; // draft survives: editor state untouched
                app.sel_anchor = null;
            } else if (isNewlineKey(key)) {
                ed.insertNewline();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const text = try ed.takeExpanded();
                defer app.gpa.free(text);
                app.submitInput(text);
            } else if (isPreviousInputRowKey(key)) {
                if (!ed.moveUp(edit_w)) ed.histUp();
                app.command_selection = 0;
            } else if (isNextInputRowKey(key)) {
                if (!ed.moveDown(edit_w)) ed.histDown();
                app.command_selection = 0;
            } else if (editCommand(key)) |command| {
                applyEditCommand(ed, command);
                app.command_selection = 0;
            } else if (key.text) |text| {
                ed.insertSlice(text);
                app.command_selection = 0;
            }
        },
        .normal => {
            if (app.copy_cursor != null) {
                app.copyModeKey(key);
                return;
            }
            if (app.pending_g) {
                app.pending_g = false;
                const count = app.pending_count;
                app.pending_count = 0;
                if (key.matches('g', .{})) {
                    app.scroll_up = std.math.maxInt(usize); // clamped in draw
                } else if (key.matches('t', .{})) {
                    // vim Ngt is absolute; here N indexes the recency list.
                    if (count > 0) app.jumpToSession(count) else app.cycleSession(1);
                } else if (key.matches('T', .{ .shift = true }) or key.matches('T', .{})) {
                    var steps = @max(count, 1);
                    while (steps > 0) : (steps -= 1) app.cycleSession(-1);
                }
                return;
            }
            if (app.pending_replace) {
                app.pending_replace = false;
                if (key.text) |txt| {
                    app.editor.pushUndo();
                    app.editor.replaceUnderCursor(txt);
                }
                return;
            }
            if (app.pending_find != 0) {
                const kind = app.pending_find;
                app.pending_find = 0;
                if (key.codepoint <= 0x7f and key.codepoint >= 0x20) {
                    app.resolveFind(kind, @intCast(key.codepoint), app.takeCount());
                } else {
                    app.pending_op = 0;
                    app.pending_count = 0;
                }
                return;
            }
            if (app.pending_op != 0) {
                app.operatorKey(key);
                return;
            }
            if ((key.codepoint >= '1' and key.codepoint <= '9') or
                (key.codepoint == '0' and app.pending_count > 0))
            {
                app.pending_count = app.pending_count * 10 + @as(usize, @intCast(key.codepoint - '0'));
                return;
            }
            if (key.matches('?', .{})) {
                app.shortcut_help = true;
            } else if (key.matches(vaxis.Key.escape, .{}) or key.matches('i', .{})) {
                app.editor.pushUndo();
                app.mode = .insert;
            } else if (key.matches('a', .{})) {
                // Vim append: archive moved to /archive — a destructive-ish
                // action must not sit on the muscle-memory insert key.
                app.editor.pushUndo();
                app.editor.moveRight();
                app.mode = .insert;
            } else if (key.matches('A', .{ .shift = true }) or key.matches('A', .{})) {
                app.editor.pushUndo();
                app.editor.moveLineEnd();
                app.mode = .insert;
            } else if (key.matches('I', .{ .shift = true }) or key.matches('I', .{})) {
                app.editor.pushUndo();
                app.editor.moveLineStart();
                app.mode = .insert;
            } else if (key.matches('q', .{})) {
                app.should_quit = true;
            } else if (key.matches('J', .{ .shift = true }) or key.matches('J', .{})) {
                // vim J: join lines. Sessions cycle on gt/gT (tab-style).
                app.editor.pushUndo();
                var joins = app.takeCount();
                joins = if (joins > 1) joins - 1 else 1;
                while (joins > 0) : (joins -= 1) {
                    if (!app.editor.joinLines()) break;
                }
            } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                app.scroll_up -|= 1;
            } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                app.scroll_up +|= 1;
            } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
                app.scroll_up -|= 20;
            } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
                app.scroll_up +|= 20;
            } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
                app.scroll_up = 0;
            } else if (key.matches('g', .{})) {
                app.pending_g = true;
            } else if (key.matches('v', .{}) or key.matches('V', .{ .shift = true }) or key.matches('V', .{})) {
                app.enterCopyMode();
            } else if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.moveLeft();
            } else if (key.matches('l', .{}) or key.matches(vaxis.Key.right, .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.moveRight();
            } else if (key.matches('w', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.moveWordStart();
            } else if (key.matches('e', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.moveWordRight();
            } else if (key.matches('b', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.moveWordLeft();
            } else if (key.matches('0', .{})) {
                app.editor.moveLineStart();
            } else if (key.matches('$', .{})) {
                app.editor.moveLineEnd();
            } else if (key.matches('f', .{}) or key.matches('t', .{}) or
                key.matches('F', .{ .shift = true }) or key.matches('T', .{ .shift = true }))
            {
                app.pending_find = @intCast(key.codepoint);
            } else if (key.matches(';', .{}) or key.matches(',', .{})) {
                if (app.last_find_kind != 0) {
                    const kind = if (key.matches(';', .{}))
                        app.last_find_kind
                    else switch (app.last_find_kind) {
                        'f' => @as(u8, 'F'),
                        'F' => 'f',
                        't' => 'T',
                        'T' => 't',
                        else => app.last_find_kind,
                    };
                    const remembered_ch = app.last_find_ch;
                    app.resolveFind(kind, remembered_ch, app.takeCount());
                    app.last_find_kind = if (key.matches(',', .{})) switch (kind) {
                        'f' => @as(u8, 'F'),
                        'F' => 'f',
                        't' => 'T',
                        'T' => 't',
                        else => kind,
                    } else kind;
                }
            } else if (key.matches('r', .{})) {
                app.pending_replace = true;
            } else if (key.matches('~', .{})) {
                app.editor.pushUndo();
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.toggleCaseUnderCursor();
            } else if (key.matches('x', .{})) {
                app.editor.pushUndo();
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.deleteAfter();
            } else if (key.matches('X', .{ .shift = true })) {
                app.editor.pushUndo();
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.deleteBefore();
            } else if (key.matches('s', .{})) {
                app.editor.pushUndo();
                app.editor.deleteAfter();
                app.mode = .insert;
            } else if (key.matches('S', .{ .shift = true })) {
                app.pending_op = 'c';
                app.operatorKey(.{ .codepoint = 'c' });
            } else if (key.matches('C', .{ .shift = true })) {
                app.applyOperator('c', app.editor.toLineEndRange());
            } else if (key.matches('Y', .{ .shift = true })) {
                app.applyOperator('y', app.editor.lineRangeAt(true));
            } else if (key.matches('D', .{ .shift = true }) or key.matches('D', .{})) {
                app.applyOperator('d', app.editor.toLineEndRange());
            } else if (key.matches('o', .{})) {
                app.editor.pushUndo();
                app.editor.openLine(true);
                app.mode = .insert;
            } else if (key.matches('O', .{ .shift = true })) {
                app.editor.pushUndo();
                app.editor.openLine(false);
                app.mode = .insert;
            } else if (key.matches('u', .{})) {
                if (!app.editor.undo()) app.setNotice("already at oldest change", .{});
            } else if (key.matches('r', .{ .ctrl = true })) {
                if (!app.editor.redo()) app.setNotice("already at newest change", .{});
            } else if (key.matches('d', .{})) {
                app.pending_op = 'd';
            } else if (key.matches('c', .{})) {
                app.pending_op = 'c';
            } else if (key.matches('y', .{})) {
                app.pending_op = 'y';
            } else if (key.matches('p', .{}) or key.matches('P', .{ .shift = true })) {
                if (app.yank_register.items.len > 0) {
                    app.editor.pushUndo();
                    const before = key.matches('P', .{ .shift = true });
                    if (app.yank_linewise) {
                        const line = app.editor.lineRangeAt(true);
                        app.editor.cursor = if (before) line.start else line.end;
                        const at = app.editor.cursor;
                        app.editor.insertSlice(app.yank_register.items);
                        app.editor.cursor = at;
                    } else {
                        if (!before) app.editor.moveRight();
                        app.editor.insertSlice(app.yank_register.items);
                    }
                } else {
                    app.setNotice("yank register empty — y in copy mode (v) fills it", .{});
                }
            }
        },
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "modified enter inserts a newline while plain enter submits" {
    try std.testing.expect(isNewlineKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true } }));
    try std.testing.expect(isNewlineKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .alt = true } }));
    try std.testing.expect(isNewlineKey(.{ .codepoint = 'j', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isNewlineKey(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expect(!isNewlineKey(.{ .codepoint = vaxis.Key.enter, .text = "\r" }));
}

test "model picker formats provider pricing compactly" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("$3 → $15 / 1M", try formatModelPricing(arena, .{
        .model = "openrouter/paid",
        .input_per_million = 3,
        .output_per_million = 15,
    }));
    try std.testing.expectEqualStrings("$0.125 → $2.5 / 1M · tiered", try formatModelPricing(arena, .{
        .model = "openrouter/tiered",
        .input_per_million = 0.125,
        .output_per_million = 2.5,
        .tiered = true,
    }));
    try std.testing.expectEqualStrings("free", try formatModelPricing(arena, .{ .model = "openrouter/free", .input_per_million = 0, .output_per_million = 0 }));
    try std.testing.expectEqualStrings("price n/a", try formatModelPricing(arena, .{ .model = "openrouter/unknown" }));
    try std.testing.expectEqual(@as(?f64, null), validCatalogRate(-1));
    try std.testing.expectEqual(@as(?f64, null), validCatalogRate(std.math.nan(f64)));
}

test "model picker accepts priced and legacy catalogs" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();

    app.handleDaemonLine(try gpa.dupe(u8,
        \\{"model_list_result":{"models":["openrouter/example/model"],"pricing":[{"model":"openrouter/example/model","input_per_million":3,"output_per_million":15}]}}
    ));
    try std.testing.expectEqualStrings("openrouter/example/model", app.catalog.items[0]);
    const pricing = app.pricingForModel("openrouter/example/model").?;
    try std.testing.expectEqual(@as(?f64, 3), pricing.input_per_million);
    try std.testing.expectEqual(@as(?f64, 15), pricing.output_per_million);

    app.handleDaemonLine(try gpa.dupe(u8,
        \\{"model_list_result":{"models":["openrouter/legacy/model"]}}
    ));
    try std.testing.expectEqualStrings("openrouter/legacy/model", app.catalog.items[0]);
    try std.testing.expect(app.pricingForModel("openrouter/legacy/model") == null);
}

test "composer command catalog filters slash commands and bang shortcuts" {
    const gpa = std.testing.allocator;
    var ed = Editor.init(gpa);
    defer ed.deinit();

    ed.insertSlice("/");
    try std.testing.expectEqual(composer_commands.len - 2, commandMatches(&ed).len);
    ed.clear();
    ed.insertSlice("/co");
    const compact = commandMatches(&ed);
    try std.testing.expectEqual(@as(usize, 1), compact.len);
    try std.testing.expectEqualStrings("/compact", composer_commands[compact.indices[0]].name);
    ed.clear();
    ed.insertSlice("/q");
    const quit = commandMatches(&ed);
    try std.testing.expectEqual(@as(usize, 1), quit.len);
    try std.testing.expectEqualStrings("/quit", composer_commands[quit.indices[0]].name);

    ed.clear();
    ed.insertSlice("!");
    const shortcuts = commandMatches(&ed);
    try std.testing.expectEqual(@as(usize, 2), shortcuts.len);
    try std.testing.expectEqualStrings("!c", composer_commands[shortcuts.indices[0]].name);
    try std.testing.expectEqualStrings("!rb", composer_commands[shortcuts.indices[1]].name);

    completeCommand(&ed, composer_commands[0], true);
    try std.testing.expectEqualStrings("/model ", ed.text.items);
    try std.testing.expect(commandQuery(&ed) == null);
}

test "command menu Tab completes and Enter runs the selection" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // completion and /help are entirely client-local
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.editor.insertSlice("/mo");
    try handleKey(&app, .{ .codepoint = vaxis.Key.tab });
    try std.testing.expectEqualStrings("/model ", app.editor.text.items);

    app.editor.clear();
    app.editor.insertSlice("/he");
    try handleKey(&app, .{ .codepoint = vaxis.Key.enter });
    try std.testing.expect(app.editor.isEmpty());
    try std.testing.expectEqualStrings("/help", app.editor.history.items[0]);
    try std.testing.expect(app.notice.items.len > 0);
}

test "history walks past recalled local commands without autocomplete capture" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.editor.pushHistory("ordinary prompt");
    app.editor.pushHistory("/help");
    try handleKey(&app, .{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqualStrings("/help", app.editor.text.items);
    try std.testing.expect(app.editor.isWalkingHistory());

    // `/help` matches the command menu, but this second Up still belongs to
    // history because the text was recalled rather than freshly typed.
    try handleKey(&app, .{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqualStrings("ordinary prompt", app.editor.text.items);
}

test "/effort opens the shared selector vocabulary" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // opening and filtering the selector are local
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.effort = .high;
    app.runCommand("/effort");
    try std.testing.expectEqual(PickerKind.effort, app.picker_kind);
    try std.testing.expectEqual(@as(?usize, 5), app.picker);
    try std.testing.expectEqualStrings("auto", app.pickerSource()[0]);
    try std.testing.expectEqualStrings("max", app.pickerSource()[proto.ReasoningEffort.choices.len - 1]);
    try std.testing.expectEqualStrings("high", app.pickerCurrent());
}

test "bang rb expands to reboot with build" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.submitInput("!rb");
    try std.testing.expectEqual(RebootRequest.build, app.reboot_request);
    try std.testing.expect(app.should_quit);
    try std.testing.expectEqualStrings("!rb", app.editor.history.items[0]);
}

test "standard editor key bindings map to commands" {
    const Case = struct { key: vaxis.Key, command: EditCommand };
    const cases = [_]Case{
        .{ .key = .{ .codepoint = vaxis.Key.left }, .command = .move_left },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .ctrl = true } }, .command = .move_left },
        .{ .key = .{ .codepoint = vaxis.Key.right }, .command = .move_right },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .ctrl = true } }, .command = .move_right },
        .{ .key = .{ .codepoint = vaxis.Key.left, .mods = .{ .alt = true } }, .command = .move_word_left },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .alt = true } }, .command = .move_word_left },
        .{ .key = .{ .codepoint = vaxis.Key.right, .mods = .{ .alt = true } }, .command = .move_word_right },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .alt = true } }, .command = .move_word_right },
        .{ .key = .{ .codepoint = vaxis.Key.home }, .command = .move_line_start },
        .{ .key = .{ .codepoint = 'a', .mods = .{ .ctrl = true } }, .command = .move_line_start },
        .{ .key = .{ .codepoint = vaxis.Key.end }, .command = .move_line_end },
        .{ .key = .{ .codepoint = 'e', .mods = .{ .ctrl = true } }, .command = .move_line_end },
        .{ .key = .{ .codepoint = vaxis.Key.backspace }, .command = .delete_before },
        .{ .key = .{ .codepoint = 'h', .mods = .{ .ctrl = true } }, .command = .delete_before },
        .{ .key = .{ .codepoint = vaxis.Key.delete }, .command = .delete_after },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .command = .delete_after },
        .{ .key = .{ .codepoint = vaxis.Key.backspace, .mods = .{ .alt = true } }, .command = .delete_word_before },
        .{ .key = .{ .codepoint = 'w', .mods = .{ .ctrl = true } }, .command = .delete_word_before_whitespace },
        .{ .key = .{ .codepoint = vaxis.Key.delete, .mods = .{ .alt = true } }, .command = .delete_word_after },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .alt = true } }, .command = .delete_word_after },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .command = .delete_to_line_start },
        .{ .key = .{ .codepoint = 'k', .mods = .{ .ctrl = true } }, .command = .delete_to_line_end },
    };
    for (cases) |case| try std.testing.expectEqual(case.command, editCommand(case.key).?);

    try std.testing.expect(isPreviousInputRowKey(.{ .codepoint = vaxis.Key.up }));
    try std.testing.expect(isPreviousInputRowKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } }));
    try std.testing.expect(isNextInputRowKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expect(isNextInputRowKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
}

test "Ctrl+L clears transient view state without touching the draft" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .scroll_up = 12,
        .sel_anchor = .{ .line = 2, .col = 3 },
        .sel_dragging = true,
        .copy_pending = true,
    };
    defer app.deinit();
    app.editor.insertSlice("draft survives");
    app.setNotice("old notice", .{});

    try handleKey(&app, .{ .codepoint = 'l', .mods = .{ .ctrl = true } });

    try std.testing.expectEqual(@as(usize, 0), app.scroll_up);
    try std.testing.expect(app.sel_anchor == null);
    try std.testing.expect(!app.sel_dragging);
    try std.testing.expect(!app.copy_pending);
    try std.testing.expect(app.refresh_requested);
    try std.testing.expectEqualStrings("", app.notice.items);
    try std.testing.expectEqualStrings("draft survives", app.editor.text.items);
}

test "Ctrl+C never exits an idle TUI or destroys its draft" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();
    app.editor.insertSlice("draft survives");

    try handleKey(&app, .{ .codepoint = 'c', .mods = .{ .ctrl = true } });

    try std.testing.expect(!app.should_quit);
    try std.testing.expectEqualStrings("draft survives", app.editor.text.items);
    try std.testing.expectEqualStrings("nothing to interrupt · q or /quit exits", app.notice.items);
}

test "Escape leaves normal mode after closing any active picker" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .mode = .normal,
        .picker = 0,
    };
    defer app.deinit();
    app.editor.insertSlice("draft survives");

    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.normal, app.mode);
    try std.testing.expect(app.picker == null);

    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqualStrings("draft survives", app.editor.text.items);
}

test "question mark opens modal shortcut help in normal mode" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .mode = .normal,
        .scroll_up = 8,
    };
    defer app.deinit();

    try handleKey(&app, .{ .codepoint = '?' });
    try std.testing.expect(app.shortcut_help);

    try handleKey(&app, .{ .codepoint = 'j' });
    try std.testing.expectEqual(@as(usize, 8), app.scroll_up);
    try std.testing.expect(app.shortcut_help);

    try handleKey(&app, .{ .codepoint = 'q' });
    try std.testing.expect(!app.shortcut_help);
    try std.testing.expect(!app.should_quit);

    try handleKey(&app, .{ .codepoint = '?' });
    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expect(!app.shortcut_help);
    try std.testing.expectEqual(Mode.normal, app.mode);
}

test "a A I enter insert mode with vim cursor placement" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.editor.insertSlice("hello");
    app.editor.moveLineStart();
    app.mode = .normal;

    try handleKey(&app, .{ .codepoint = 'A', .mods = .{ .shift = true } });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(app.editor.text.items.len, app.editor.cursor);

    app.mode = .normal;
    try handleKey(&app, .{ .codepoint = 'I', .mods = .{ .shift = true } });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.editor.cursor);

    app.mode = .normal;
    try handleKey(&app, .{ .codepoint = 'a' });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 1), app.editor.cursor);
}

test "archive has no single-key binding; a enters insert even mid-turn" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .mode = .normal,
        .state = .running,
    };
    defer app.deinit();

    try handleKey(&app, .{ .codepoint = 'a' });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 0), app.notice.items.len);
}

test "selection is character precise on one or many lines" {
    const same = Selection.init(.{ .line = 4, .col = 8 }, .{ .line = 4, .col = 2 });
    const same_cols = same.columns(4, 20).?;
    try std.testing.expectEqual(@as(usize, 2), same_cols.start);
    try std.testing.expectEqual(@as(usize, 9), same_cols.end);

    const multi = Selection.init(.{ .line = 2, .col = 3 }, .{ .line = 4, .col = 5 });
    const first = multi.columns(2, 10).?;
    try std.testing.expectEqual(@as(usize, 3), first.start);
    try std.testing.expectEqual(@as(usize, 10), first.end);
    const middle = multi.columns(3, 10).?;
    try std.testing.expectEqual(@as(usize, 0), middle.start);
    try std.testing.expectEqual(@as(usize, 10), middle.end);
    const last = multi.columns(4, 10).?;
    try std.testing.expectEqual(@as(usize, 0), last.start);
    try std.testing.expectEqual(@as(usize, 6), last.end);
    try std.testing.expect(multi.columns(1, 10) == null);
}

test "one-line composer and scrollback prompt cards are three rows" {
    try std.testing.expectEqual(@as(usize, 3), inputPanelHeight(1));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapPromptCard(arena, &lines, "ship it", 80);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expect(lines.items[0].fill_style != null);
    try std.testing.expectEqualStrings(" ❯ ", lines.items[1].text);
    try std.testing.expectEqualStrings("ship it", lines.items[1].text2);
    try std.testing.expect(lines.items[2].fill_style != null);
}

test "reasoning cards are bright, padded, and inset" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapReasoningCard(
        arena,
        &lines,
        "I am checking the implementation evidence before mapping it against the milestone exit criteria.",
        38,
    );

    try std.testing.expect(lines.items.len >= 4); // top + wrapped body + bottom
    try std.testing.expectEqualStrings("", lines.items[0].text);
    try std.testing.expectEqualStrings("", lines.items[lines.items.len - 1].text);
    try std.testing.expectEqualStrings("  · ", lines.items[1].text);
    try std.testing.expect(lines.items[1].style.bold);
    // Body text must never be dimmed or italicized — completed commentary
    // renders bold true-RGB white, one step above the streaming default.
    try std.testing.expect(!lines.items[1].style2.italic);
    try std.testing.expect(lines.items[1].style2.bold);
    try std.testing.expect(vaxis.Color.eql(lines.items[1].style2.fg, .{ .rgb = .{ 0xff, 0xff, 0xff } }));
    for (lines.items) |line| {
        try std.testing.expect(line.fill_style != null);
        try std.testing.expect(vaxis.Color.eql(line.fill_style.?.bg, Palette.reasoning_bg));
        try std.testing.expect(displayWidth(try lineText(arena, line)) <= 36);
    }
}

test "bash previews distinguish commands flags operators strings and paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const command = "git log --oneline --decorate -8 && printf '\\n--- current ---\\n' && git diff --stat ./src";
    const spans = try shellCommandSpans(arena, command, 0);

    const first_git = syntaxForBytes(spans, 0, 1).?;
    const flag_at = std.mem.indexOf(u8, command, "--oneline").?;
    const operator_at = std.mem.indexOf(u8, command, "&&").?;
    const string_at = std.mem.indexOfScalar(u8, command, '\'').?;
    const printf_at = std.mem.indexOf(u8, command, "printf").?;
    const path_at = std.mem.indexOf(u8, command, "./src").?;

    try std.testing.expect(vaxis.Color.eql(first_git.fg, Palette.shell_executable.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, flag_at, flag_at + 1).?.fg, Palette.shell_flag.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, operator_at, operator_at + 1).?.fg, Palette.shell_operator.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, string_at, string_at + 1).?.fg, Palette.shell_string.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, printf_at, printf_at + 1).?.fg, Palette.shell_executable.fg));
    try std.testing.expect(vaxis.Color.eql(syntaxForBytes(spans, path_at, path_at + 1).?.fg, Palette.shell_path.fg));
}

test "git oneline output separates hash refs and subject" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const line = "d892bef (HEAD -> main) Polish TUI output and reasoning controls";
    const spans = try gitLogSpans(arena_state.allocator(), line, 4);

    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqual(@as(usize, 4), spans[0].start);
    try std.testing.expectEqual(@as(usize, 11), spans[0].end);
    try std.testing.expect(vaxis.Color.eql(spans[0].style.fg, Palette.git_hash.fg));
    try std.testing.expect(vaxis.Color.eql(spans[1].style.fg, Palette.git_ref.fg));
    try std.testing.expectEqual(@as(usize, 0), (try gitLogSpans(arena_state.allocator(), "not a git log line", 4)).len);
}

test "status metadata is compact without losing its identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "anthropic/claude-sonnet-4.5",
        statusModel("openrouter/anthropic/claude-sonnet-4.5"),
    );
    try std.testing.expectEqualStrings(
        "~/Work/marlin",
        try statusCwd(arena, "/Users/jespern/Work/marlin", "/Users/jespern"),
    );
    try std.testing.expectEqualStrings(
        "/opt/marlin",
        try statusCwd(arena, "/opt/marlin", "/Users/jespern"),
    );
}

test "diff language comes from edit summaries or git target paths" {
    try std.testing.expectEqual(
        SyntaxLanguage.zig,
        diffLanguage("replaced 1 occurrence(s) in src/client/tui.zig\n@@ -1,2 +1,2 @@"),
    );
    try std.testing.expectEqual(
        SyntaxLanguage.javascript,
        diffLanguage("diff --git a/web/app.ts b/web/app.ts\n--- a/web/app.ts\n+++ b/web/app.ts\n@@ -1 +1 @@"),
    );
    try std.testing.expectEqual(SyntaxLanguage.generic, diffLanguage("@@ -1 +1 @@"));
}

test "diff rows combine subtle surfaces with syntax foregrounds" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;

    var nums: DiffLineNumbers = .{};
    try appendDiffLine(arena, &lines, "  ", "+    const msg = \"hello\";", .zig, Palette.tool_out, &nums);
    try appendDiffLine(arena, &lines, "  ", "@@ -4,1 +4,1 @@ pub fn greet() void {", .zig, Palette.tool_out, &nums);
    try appendDiffLine(arena, &lines, "  ", "+    greet();", .zig, Palette.tool_out, &nums);
    try appendDiffLine(arena, &lines, "  ", "-    farewell();", .zig, Palette.tool_out, &nums);
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);

    // Before any hunk header: no number. After: new-file numbers for adds,
    // old-file numbers for deletions.
    try std.testing.expectEqualStrings("     4 +", lines.items[2].text);
    try std.testing.expectEqualStrings("     4 -", lines.items[3].text);

    const added = lines.items[0];
    try std.testing.expectEqualStrings("  +", added.text);
    try std.testing.expectEqualStrings("    const msg = \"hello\";", added.text2);
    try std.testing.expect(added.fill_style != null);
    try std.testing.expect(vaxis.Color.eql(added.fill_style.?.bg, Palette.diff_add_bg));
    try std.testing.expect(added.syntax.len >= 2); // `const` + string

    const hunk = lines.items[1];
    try std.testing.expect(std.mem.indexOf(u8, hunk.text, "pub fn greet") != null);
    try std.testing.expect(hunk.syntax.len >= 3); // pub + fn + greet

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 48,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 48,
        .height = 1,
        .screen = &screen,
    };
    win.fill(.{ .style = added.fill_style.? });
    _ = win.print(&.{
        .{ .text = added.text, .style = added.style },
        .{ .text = added.text2, .style = added.style2 },
    }, .{ .wrap = .none });
    applyLineSyntax(win, 0, added);

    // Three gutter cells + four spaces puts the `c` in `const` at column 7.
    const keyword_cell = win.readCell(7, 0).?;
    try std.testing.expect(vaxis.Color.eql(keyword_cell.style.bg, Palette.diff_add_bg));
    try std.testing.expect(vaxis.Color.eql(keyword_cell.style.fg, Palette.syntax_keyword.fg));
}

test "plain and Markdown URLs become safe clickable spans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "See https://marlin.wtf/docs, then [the repo](https://github.com/jespern/marlin).";
    const spans = try findLinkSpans(arena, text);

    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("https://marlin.wtf/docs", spans[0].uri);
    try std.testing.expectEqualStrings("the repo", text[spans[1].start..spans[1].end]);
    try std.testing.expectEqualStrings("https://github.com/jespern/marlin", spans[1].uri);
    try std.testing.expectEqualStrings(spans[1].uri, spans[2].uri);

    const unsafe = try findLinkSpans(arena, "[nope](javascript:alert(1)) file:///tmp/secret");
    try std.testing.expectEqual(@as(usize, 0), unsafe.len);
}

test "wrapped URL pieces retain the complete OSC 8 destination" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "https://example.test/really/long/path";
    const text = "see " ++ uri;
    var lines: std.ArrayList(Line) = .empty;
    try wrapPrefixed(arena, &lines, "", text, Palette.assistant, 16);

    var linked_lines: usize = 0;
    for (lines.items) |line| {
        if (line.links.len == 0) continue;
        linked_lines += 1;
        for (line.links) |link| try std.testing.expectEqualStrings(uri, link.uri);
    }
    try std.testing.expect(linked_lines >= 2);
}

test "link spans attach OSC 8 metadata to rendered cells" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 32,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 32,
        .height = 1,
        .screen = &screen,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const text = "go https://marlin.wtf";
    const line = Line{
        .text = text,
        .style = Palette.assistant,
        .links = try findLinkSpans(arena_state.allocator(), text),
        .links_resolved = true,
    };
    _ = win.printSegment(.{ .text = text }, .{ .wrap = .none });
    applyLineLinks(win, 0, line);

    const linked = win.readCell(3, 0).?;
    try std.testing.expectEqualStrings("https://marlin.wtf", linked.link.uri);
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, linked.style.ul_style);
    try std.testing.expectEqualStrings("", win.readCell(0, 0).?.link.uri);
}

test "URL punctuation trimming keeps balanced path delimiters" {
    const text = "https://example.test/wiki/Foo_(bar)).";
    const end = urlEnd(text, 0);
    try std.testing.expectEqualStrings("https://example.test/wiki/Foo_(bar)", text[0..end]);
}

test "assistant Markdown removes punctuation and retains styles and links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try inlineMarkdown(
        arena_state.allocator(),
        "Use **M3** and `zig build`; see [the docs](https://marlin.wtf/docs).",
    );

    try std.testing.expectEqualStrings("Use M3 and zig build; see the docs.", rendered.text);
    try std.testing.expectEqual(@as(usize, 2), rendered.styles.len);
    try std.testing.expectEqual(@as(usize, 1), rendered.links.len);
    try std.testing.expectEqualStrings("the docs", rendered.text[rendered.links[0].start..rendered.links[0].end]);
    try std.testing.expectEqualStrings("https://marlin.wtf/docs", rendered.links[0].uri);
    try std.testing.expect(vaxis.Color.eql(rendered.styles[1].style.bg, Palette.md_inline_code_bg));
}

test "assistant Markdown renders bounded tables with header surfaces and inline styles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "| Milestone | Status |\n|---|---|\n| **M0** | ✅ Complete with a deliberately long status that wraps cleanly |",
        44,
    );

    try std.testing.expect(lines.items.len > 5); // wrapped body + borders + spacer
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text2, "╭"));
    try std.testing.expect(lines.items[1].style2.bold);
    try std.testing.expect(vaxis.Color.eql(lines.items[1].style2.bg, Palette.md_table_header_bg));
    const body = try lineText(arena, lines.items[3]);
    try std.testing.expect(std.mem.indexOf(u8, body, "M0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "**") == null);
    try std.testing.expect(lines.items[3].syntax.len > 0);
    for (lines.items) |line| try std.testing.expect(displayWidth(try lineText(arena, line)) <= 44);
}

test "assistant Markdown has readable measure and hanging list indents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "# Milestones\n\n1. This ordered item is intentionally long enough to wrap beneath its text instead of beneath the marker, even when the terminal is very wide, because assistant prose should retain a readable measure across large desktop windows.\n  - [x] nested task",
        220,
    );

    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text, "  ◆ "));
    try std.testing.expect(lines.items[0].style.bold);
    for (lines.items) |line| try std.testing.expect(displayWidth(try lineText(arena, line)) <= markdown_max_body_width + markdown_gutter.len);

    var saw_continuation = false;
    var saw_task = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.startsWith(u8, text, "     ") and text.len > 5) saw_continuation = true;
        if (std.mem.startsWith(u8, text, "    ☑ ")) saw_task = true;
    }
    try std.testing.expect(saw_continuation);
    try std.testing.expect(saw_task);
}

test "assistant paragraphs use a dotted rail with hanging continuation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "A distinct prose section gets a calm visual anchor and enough text to wrap onto another terminal row.",
        42,
    );

    try std.testing.expect(lines.items.len >= 2);
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text, "  • "));
    try std.testing.expect(std.mem.startsWith(u8, lines.items[1].text, "    "));
    try std.testing.expect(!std.mem.startsWith(u8, lines.items[1].text, "  • "));

    var auxiliary: std.ArrayList(Line) = .empty;
    try wrapPrefixed(
        arena,
        &auxiliary,
        "  · ",
        "A reasoning section also remains inset when it crosses the available terminal width.",
        Palette.reasoning,
        34,
    );
    try std.testing.expect(auxiliary.items.len >= 2);
    try std.testing.expect(std.mem.startsWith(u8, auxiliary.items[0].text, "  · "));
    try std.testing.expect(std.mem.startsWith(u8, auxiliary.items[1].text, "    "));
}

test "assistant Markdown renders code panels and semantic callouts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "**Formal status:** ready to ship.\n\n```zig\nconst answer: usize = 42;\n```\n\n> [!WARNING]\n> Keep the rollback path.",
        80,
    );

    try std.testing.expect(lines.items[0].fill_style != null);
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text2, "▌ "));
    try std.testing.expect(vaxis.Color.eql(lines.items[0].style2.bg, Palette.md_callout_bg));

    var saw_code_header = false;
    var saw_syntax = false;
    var saw_code_gutter = false;
    var saw_warning = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "zig · select to copy") != null) saw_code_header = true;
        if (std.mem.indexOf(u8, text, "const answer") != null and line.syntax.len >= 2) saw_syntax = true;
        if (std.mem.indexOf(u8, text, "│ 1 │") != null) saw_code_gutter = true;
        if (std.mem.indexOf(u8, text, "WARNING") != null and line.fill_style != null) saw_warning = true;
    }
    try std.testing.expect(saw_code_header);
    try std.testing.expect(saw_syntax);
    try std.testing.expect(saw_code_gutter);
    try std.testing.expect(saw_warning);
}

test "assistant inline Markdown supports emphasis and strikethrough" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try inlineMarkdown(arena_state.allocator(), "*soft* ~~gone~~ snake_case_value");
    try std.testing.expectEqualStrings("soft gone snake_case_value", rendered.text);
    try std.testing.expectEqual(@as(usize, 2), rendered.styles.len);
    try std.testing.expect(rendered.styles[0].style.italic);
    try std.testing.expect(rendered.styles[1].style.strikethrough);
}

test "successful tools collapse but diffs and failures stop the run" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]RenderBlock{
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "grep") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "one match"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "read_file") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "contents"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "edit") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "@@ fn main()\n-old\n+new"), .label = try arena.dupe(u8, "") },
    };

    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(arena);
    const first = try scanToolBatch(arena, &blocks, 0, &expand);
    try std.testing.expectEqual(@as(usize, 1), first.ok_count);
    try std.testing.expectEqual(@as(usize, 2), first.next);
    const second = try scanToolBatch(arena, &blocks, 2, &expand);
    try std.testing.expectEqual(@as(usize, 1), second.ok_count);
    try std.testing.expect(expand.items.len == 0);
    // The edit diff must stay visible: zero foldable, one expanded pair.
    const third = try scanToolBatch(arena, &blocks, 4, &expand);
    try std.testing.expectEqual(@as(usize, 0), third.ok_count);
    try std.testing.expectEqual(@as(usize, 1), expand.items.len);
    try std.testing.expectEqual(@as(usize, 4), expand.items[0].call);
}

test "calls-first parallel tool batches collapse as one transcript run" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    const entries = [_]struct { block.BlockKind, []const u8, []const u8 }{
        .{ .tool_call, "{}", "read_file" },
        .{ .tool_call, "{}", "read_file" },
        .{ .tool_call, "{}", "grep" },
        .{ .tool_result, "first file", "" },
        .{ .tool_result, "second file", "" },
        .{ .tool_result, "matches", "" },
    };
    for (entries) |entry| {
        try app.blocks.append(gpa, .{
            .kind = entry[0],
            .turn_id = 9,
            .text = try gpa.dupe(u8, entry[1]),
            .label = try gpa.dupe(u8, entry[2]),
        });
    }

    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(gpa);
    const batch = try scanToolBatch(gpa, app.blocks.items, 0, &expand);
    try std.testing.expectEqual(@as(usize, 3), batch.ok_count);
    try std.testing.expectEqual(@as(usize, 6), batch.next);
    try std.testing.expect(batch.complete);
    try std.testing.expect(expand.items.len == 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var summaries: usize = 0;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line.text2, "Ran 3 commands")) summaries += 1;
        try std.testing.expect(std.mem.indexOf(u8, line.text, "first file") == null);
        try std.testing.expect(std.mem.indexOf(u8, line.text2, "first file") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), summaries);
}

test "in-flight calls-first batch renders one compact running line" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .state = .running,
    };
    defer app.deinit();
    for ([_][]const u8{ "read_file", "grep", "glob" }) |name| {
        try app.blocks.append(gpa, .{
            .kind = .tool_call,
            .turn_id = 9,
            .text = try gpa.dupe(u8, "{}"),
            .label = try gpa.dupe(u8, name),
        });
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var summaries: usize = 0;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line.text2, "Running 3 commands")) summaries += 1;
        try std.testing.expect(std.mem.indexOf(u8, line.text, "⚙") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), summaries);
}

test "failed tool output uses red only for its marker and salient diagnostics" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .show_tool_transcript = true,
    };
    defer app.deinit();
    try app.blocks.append(gpa, .{
        .kind = .tool_call,
        .text = try gpa.dupe(u8, "{}"),
        .label = try gpa.dupe(u8, "bash"),
    });
    try app.blocks.append(gpa, .{
        .kind = .tool_result,
        .text = try gpa.dupe(
            u8,
            "compiler output\n/opt/zig/std.zig:10:2: stack frame\nerror: command failed\ncase one FAIL PermissionDenied\n[exit code: 1]",
        ),
        .label = try gpa.dupe(u8, ""),
        .status = .err,
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);

    var saw_marker = false;
    var saw_neutral_continuation = false;
    var saw_red_error = false;
    var saw_red_fail = false;
    for (lines.items) |line| {
        if (std.mem.eql(u8, line.text2, "compiler output")) {
            saw_marker = std.mem.eql(u8, line.text, "    ✗ ") and
                vaxis.Color.eql(line.style.fg, Palette.tool_err.fg) and
                vaxis.Color.eql(line.style2.fg, Palette.tool_out.fg) and
                line.style2.dim;
        } else if (std.mem.indexOf(u8, line.text2, "stack frame") != null) {
            saw_neutral_continuation = std.mem.eql(u8, line.text, "      ") and
                vaxis.Color.eql(line.style.fg, Palette.tool_out.fg) and
                vaxis.Color.eql(line.style2.fg, Palette.tool_out.fg);
        } else if (std.mem.startsWith(u8, line.text2, "error:")) {
            saw_red_error = vaxis.Color.eql(line.style2.fg, Palette.tool_err.fg);
        } else if (std.mem.indexOf(u8, line.text2, " FAIL ") != null) {
            saw_red_fail = vaxis.Color.eql(line.style2.fg, Palette.tool_err.fg);
        }
    }
    try std.testing.expect(saw_marker);
    try std.testing.expect(saw_neutral_continuation);
    try std.testing.expect(saw_red_error);
    try std.testing.expect(saw_red_fail);
}

test "diffs merely read via bash collapse like any other success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]RenderBlock{
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "bash") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "diff --git a/x b/x\n@@ -1 +1 @@\n-old\n+new"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "grep") },
        .{ .kind = .tool_result, .text = try arena.dupe(u8, "one match"), .label = try arena.dupe(u8, "") },
    };

    // The bash `git diff` output looks like a diff but the agent changed
    // nothing — it folds like any other success.
    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(arena);
    const batch = try scanToolBatch(arena, &blocks, 0, &expand);
    try std.testing.expectEqual(@as(usize, 1), batch.ok_count);
    try std.testing.expect(expand.items.len == 0);
}

test "tool collapse never crosses a durable turn boundary" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]RenderBlock{
        .{ .kind = .tool_call, .turn_id = 11, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "grep") },
        .{ .kind = .tool_result, .turn_id = 11, .text = try arena.dupe(u8, "match"), .label = try arena.dupe(u8, "") },
        .{ .kind = .tool_call, .turn_id = 12, .text = try arena.dupe(u8, "{}"), .label = try arena.dupe(u8, "read_file") },
        .{ .kind = .tool_result, .turn_id = 12, .text = try arena.dupe(u8, "contents"), .label = try arena.dupe(u8, "") },
    };

    var expand: std.ArrayList(ExpandPair) = .empty;
    defer expand.deinit(arena);
    const batch = try scanToolBatch(arena, &blocks, 0, &expand);
    try std.testing.expectEqual(@as(usize, 1), batch.ok_count);
    try std.testing.expectEqual(@as(usize, 2), batch.next);
}

test "durable user block reconciles optimistic local echo" {
    const gpa = std.testing.allocator;
    var rendered = [_]RenderBlock{.{
        .kind = .user_msg,
        .text = try gpa.dupe(u8, "hello"),
        .label = try gpa.dupe(u8, ""),
        .pending_echo = true,
    }};
    defer rendered[0].deinit(gpa);

    try std.testing.expect(reconcilePendingEcho(&rendered, .user_msg, "hello", 9, 3));
    try std.testing.expect(!rendered[0].pending_echo);
    try std.testing.expectEqual(@as(u64, 9), rendered[0].seq);
    try std.testing.expectEqual(@as(u64, 3), rendered[0].turn_id);
    try std.testing.expect(!reconcilePendingEcho(&rendered, .user_msg, "hello", 9, 3));
}

test "synthetic and legacy rehydration render as notes, not prompts or history" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 4,
        .seq = 1,
        .ts = 0,
        .body = .{ .user_msg = .{
            .text = "[rehydrated after compaction] docs/PLAN.md:\nprivate contents",
            .synthetic = true,
        } },
    });
    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 4,
        .seq = 2,
        .ts = 0,
        // Pre-marker durable blocks are recognized by their legacy prefix.
        .body = .{ .user_msg = .{ .text = "[rehydrated after compaction] src/main.zig:\nold contents" } },
    });

    try std.testing.expectEqual(@as(usize, 2), app.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.system_note, app.blocks.items[0].kind);
    try std.testing.expectEqualStrings("rehydrated docs/PLAN.md", app.blocks.items[0].text);
    try std.testing.expectEqualStrings("rehydrated src/main.zig", app.blocks.items[1].text);
    try std.testing.expectEqual(@as(usize, 0), app.editor.history.items.len);
}

test "compaction renders one marker without exposing its summary" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();
    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 4,
        .seq = 1,
        .ts = 0,
        .body = .{ .compaction = .{
            .summary = "## Accomplished\nA huge internal summary that must stay hidden",
            .covers_from_seq = 1,
            .covers_to_seq = 10,
        } },
    });
    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 4,
        .seq = 2,
        .ts = 0,
        .body = .{ .system_note = .{ .text = "context compacted automatically (headroom); summary + rehydrated files above replace the older conversation" } },
    });

    try std.testing.expectEqual(@as(usize, 1), app.blocks.items.len);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var markers: usize = 0;
    for (lines.items) |line| {
        const rendered = try lineText(arena_state.allocator(), line);
        if (std.mem.indexOf(u8, rendered, "context compacted") != null) markers += 1;
        try std.testing.expect(std.mem.indexOf(u8, rendered, "Accomplished") == null);
        try std.testing.expect(std.mem.indexOf(u8, rendered, "huge internal summary") == null);
    }
    try std.testing.expectEqual(@as(usize, 1), markers);
}

test "legacy provider error notes are display-bounded" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();
    const old_raw_error = "provider returned HTTP 400: " ++ ("x" ** 1600) ++ " NEVER_RENDER_THIS_TAIL";
    app.pushBlock(.system_note, old_raw_error, "", .ok);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const lines = try layoutLines(arena_state.allocator(), &app, 100);
    var rendered_len: usize = 0;
    for (lines.items) |line| {
        const rendered = try lineText(arena_state.allocator(), line);
        rendered_len += rendered.len;
        try std.testing.expect(std.mem.indexOf(u8, rendered, "NEVER_RENDER_THIS_TAIL") == null);
    }
    try std.testing.expect(rendered_len < 550);
}

test "session labels round-trip ids and preserve inactive view state" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 0x2a,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.replaceSessionSummaries(&.{.{
        .sid = 0x2a,
        .title = "review",
        .cwd = "/tmp/project",
        .model = "provider/model",
        .status = "running",
        .state = .running,
        .created_at = 1,
        .running = true,
    }});
    try std.testing.expectEqual(@as(?u64, 0x2a), app.sessionIdForLabel(app.session_labels.items[0]));
    try std.testing.expectEqual(@as(?u64, null), app.sessionIdForLabel("no session label"));
    try std.testing.expectEqual(proto.SessionState.running, app.state);

    app.editor.insertSlice("draft survives");
    app.scroll_up = 17;
    app.pushBlock(.assistant_msg, "scrollback survives", "", .ok);
    try app.saveActiveView();
    try std.testing.expectEqual(@as(usize, 0), app.blocks.items.len);

    const saved = app.saved_views.get(0x2a).?;
    _ = app.saved_views.remove(0x2a);
    app.restoreSavedView(saved);
    gpa.destroy(saved);
    try std.testing.expectEqualStrings("draft survives", app.editor.text.items);
    try std.testing.expectEqual(@as(usize, 17), app.scroll_up);
    try std.testing.expectEqualStrings("scrollback survives", app.blocks.items[0].text);
}

test "tool results retain full blob refs and inline !c stages clipboard text" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 4,
        .seq = 7,
        .ts = 0,
        .body = .{ .tool_result = .{
            .call_id = "call",
            .status = .ok,
            .inline_body = "capped",
            .full_body_ref = "abc123",
        } },
    });
    try std.testing.expectEqualStrings("abc123", app.blocks.items[0].full_body_ref.?);
    app.blocks.items[0].deinit(gpa);
    app.blocks.clearRetainingCapacity();

    app.pushBlock(.tool_result, "complete output", "", .ok);
    app.runCommand("!c");
    try std.testing.expectEqualStrings("complete output", app.clipboard_pending.items);
}

test "local commands enter editor history" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // /help is entirely client-local
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.submitInput("/help");
    try std.testing.expectEqual(@as(usize, 1), app.editor.history.items.len);
    app.editor.histUp();
    try std.testing.expectEqualStrings("/help", app.editor.text.items);
}

test "layout cache: incremental result equals fresh one-shot layout" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const Fixture = struct {
        fn fill(app: *App, a: std.mem.Allocator, turns: usize) !void {
            var t: usize = 0;
            var seq: u64 = 1;
            while (t < turns) : (t += 1) {
                const turn_id = t + 10;
                try app.blocks.append(a, .{ .kind = .user_msg, .seq = seq, .turn_id = turn_id, .text = try a.dupe(u8, "do the thing"), .label = try a.dupe(u8, "") });
                seq += 1;
                try app.blocks.append(a, .{ .kind = .tool_call, .seq = seq, .turn_id = turn_id, .text = try a.dupe(u8, "{\"command\":\"zig build test\"}"), .label = try a.dupe(u8, "bash") });
                seq += 1;
                try app.blocks.append(a, .{ .kind = .tool_result, .seq = seq, .turn_id = turn_id, .status = if (t % 3 == 0) .err else .ok, .text = try a.dupe(u8, "line one\nline two\nline three"), .label = try a.dupe(u8, "") });
                seq += 1;
                try app.blocks.append(a, .{ .kind = .assistant_msg, .seq = seq, .turn_id = turn_id, .text = try a.dupe(u8, "done: **ok**"), .label = try a.dupe(u8, "") });
                seq += 1;
            }
        }
        fn rendered(a: std.mem.Allocator, app: *App) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            const lines = try layoutLines(a, app, 120);
            for (lines.items) |line| {
                try out.appendSlice(a, try lineText(a, line));
                try out.append(a, '\n');
            }
            return out.items;
        }
    };

    // Incremental: layout after 3 turns (warms cache), add 2 more, layout again.
    var warm = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer warm.deinit();
    try Fixture.fill(&warm, gpa, 3);
    var arena1 = std.heap.ArenaAllocator.init(gpa);
    defer arena1.deinit();
    _ = try Fixture.rendered(arena1.allocator(), &warm);
    try std.testing.expect(warm.layout_cache.covered > 0);
    for (warm.blocks.items) |*rb| rb.deinit(gpa);
    warm.blocks.clearRetainingCapacity();
    try Fixture.fill(&warm, gpa, 5);
    warm.layout_epoch +%= 1; // list rebuilt wholesale, as a session switch would
    var arena2 = std.heap.ArenaAllocator.init(gpa);
    defer arena2.deinit();
    _ = try Fixture.rendered(arena2.allocator(), &warm);
    try std.testing.expect(warm.layout_cache.covered > 0);
    // Now truly incremental: append one more turn on the warmed cache.
    try Fixture.fill(&warm, gpa, 1);
    var arena3 = std.heap.ArenaAllocator.init(gpa);
    defer arena3.deinit();
    const incremental = try Fixture.rendered(arena3.allocator(), &warm);

    // Fresh app, identical blocks, single cold layout.
    var fresh = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer fresh.deinit();
    try Fixture.fill(&fresh, gpa, 5);
    try Fixture.fill(&fresh, gpa, 1);
    var arena4 = std.heap.ArenaAllocator.init(gpa);
    defer arena4.deinit();
    const cold = try Fixture.rendered(arena4.allocator(), &fresh);

    try std.testing.expectEqualStrings(cold, incremental);
}

test "layout remains bounded around a dangling call between turns" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();

    const Entry = struct { block.BlockKind, u64, []const u8, []const u8 };
    const entries = [_]Entry{
        .{ .tool_call, 7, "{\"pattern\":\"one\"}", "grep" },
        .{ .tool_result, 7, "ok", "" },
        .{ .tool_call, 7, "{\"path\":\"one\"}", "read_file" },
        .{ .tool_result, 7, "ok", "" },
        .{ .tool_call, 7, "{\"path\":\"two\"}", "read_file" },
        .{ .tool_result, 7, "ok", "" },
        .{ .reasoning, 7, "editing", "" },
        // Historical interrupted turns can end with an unmatched call.
        .{ .tool_call, 7, "{\"path\":\"x\"}", "edit" },
        .{ .user_msg, 8, "next turn", "" },
        .{ .system_note, 8, "interrupted", "" },
    };
    for (entries, 0..) |entry, i| try app.blocks.append(gpa, .{
        .kind = entry[0],
        .seq = i + 1,
        .turn_id = entry[1],
        .text = try gpa.dupe(u8, entry[2]),
        .label = try gpa.dupe(u8, entry[3]),
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 120);
    try std.testing.expect(lines.items.len < 100);
    var saw_summary = false;
    var saw_dangling = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Ran 3 commands") != null) saw_summary = true;
        if (std.mem.indexOf(u8, text, "⚙ edit") != null) saw_dangling = true;
    }
    try std.testing.expect(saw_summary);
    try std.testing.expect(saw_dangling);
}

test "layout line safety limit produces a visible truncation" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.pushBlock(.system_note, "after limit", "", .ok);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try lines.resize(arena, max_layout_lines);
    var label: []const u8 = "";
    try layoutBlockRange(arena, &app, &lines, 0, 1, 120, &label, false);
    try std.testing.expectEqual(max_layout_lines + 1, lines.items.len);
    try std.testing.expectEqualStrings(
        "  [transcript rendering truncated at safety limit]",
        lines.items[lines.items.len - 1].text,
    );
}

test "a failing sibling expands alone; healthy batch members stay folded" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();

    // Calls-first batch of three; the second result fails.
    const entries = [_]struct { block.BlockKind, []const u8, []const u8, block.ToolStatus }{
        .{ .tool_call, "{\"command\":\"zig version\"}", "bash", .ok },
        .{ .tool_call, "{\"command\":\"jq .lib_dir\"}", "bash", .ok },
        .{ .tool_call, "{\"pattern\":\"curl_easy\"}", "grep", .ok },
        .{ .tool_result, "0.16.0", "", .ok },
        .{ .tool_result, "jq: parse error", "", .err },
        .{ .tool_result, "141: curl_easy_setopt", "", .ok },
    };
    var seq: u64 = 1;
    for (entries) |entry| {
        try app.blocks.append(gpa, .{
            .kind = entry[0],
            .seq = seq,
            .turn_id = 7,
            .status = entry[3],
            .text = try gpa.dupe(u8, entry[1]),
            .label = try gpa.dupe(u8, entry[2]),
        });
        seq += 1;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 120);

    var gear_lines: usize = 0;
    var saw_summary = false;
    var saw_failure = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "⚙") != null) gear_lines += 1;
        if (std.mem.indexOf(u8, text, "Ran 2 commands") != null) saw_summary = true;
        if (std.mem.indexOf(u8, text, "jq: parse error") != null) saw_failure = true;
    }
    // Exactly one expanded call (the failure); the two healthy pairs fold.
    try std.testing.expectEqual(@as(usize, 1), gear_lines);
    try std.testing.expect(saw_summary);
    try std.testing.expect(saw_failure);
}

test "tool summaries merge across commentary into one line" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();

    // Three rounds: commentary + one successful pair each. Previously this
    // rendered three separate "Ran 1 command" lines.
    var seq: u64 = 1;
    var round: usize = 0;
    while (round < 3) : (round += 1) {
        try app.blocks.append(gpa, .{ .kind = .reasoning, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "checking things"), .label = try gpa.dupe(u8, "") });
        seq += 1;
        try app.blocks.append(gpa, .{ .kind = .tool_call, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "{\"command\":\"true\"}"), .label = try gpa.dupe(u8, "bash") });
        seq += 1;
        try app.blocks.append(gpa, .{ .kind = .tool_result, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "ok"), .label = try gpa.dupe(u8, "") });
        seq += 1;
    }
    try app.blocks.append(gpa, .{ .kind = .assistant_msg, .seq = seq, .turn_id = 7, .text = try gpa.dupe(u8, "done"), .label = try gpa.dupe(u8, "") });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 120);

    var summaries: usize = 0;
    var merged = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Ran ") != null) summaries += 1;
        if (std.mem.indexOf(u8, text, "Ran 3 commands") != null) merged = true;
    }
    try std.testing.expectEqual(@as(usize, 1), summaries);
    try std.testing.expect(merged);
}

test "copy mode: enter, select, yank fills selection and requests copy" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.mode = .normal;
    app.last_total_lines = 50;
    app.last_view_h = 10;
    app.last_first_visible = 40;

    try handleKey(&app, .{ .codepoint = 'v' });
    try std.testing.expect(app.copy_cursor != null);
    try std.testing.expectEqual(@as(usize, 49), app.copy_cursor.?.line);

    try handleKey(&app, .{ .codepoint = 'k' });
    try handleKey(&app, .{ .codepoint = 'k' });
    try std.testing.expectEqual(@as(usize, 47), app.copy_cursor.?.line);

    // Anchor char-wise, extend down one line, yank.
    try handleKey(&app, .{ .codepoint = 'v' });
    try std.testing.expect(app.sel_anchor != null);
    try handleKey(&app, .{ .codepoint = 'j' });
    try std.testing.expectEqual(@as(usize, 48), app.sel_head.line);
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expect(app.copy_pending);
    try std.testing.expect(app.copy_cursor == null); // yank exits copy mode

    // Line-wise: V spans full lines in the selection endpoints.
    try handleKey(&app, .{ .codepoint = 'v' });
    try handleKey(&app, .{ .codepoint = 'V', .mods = .{ .shift = true } });
    try handleKey(&app, .{ .codepoint = 'k' });
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expectEqual(@as(usize, 0), app.sel_anchor.?.col);
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize)), app.sel_head.col);
}

test "normal mode: p pastes the yank register into the composer" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.mode = .normal;
    try app.yank_register.appendSlice(gpa, "zig build test");
    try handleKey(&app, .{ .codepoint = 'p' });
    try std.testing.expectEqualStrings("zig build test", app.editor.text.items);

    // Motions operate on the composer: 0 then w lands after the first word.
    try handleKey(&app, .{ .codepoint = '0' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try handleKey(&app, .{ .codepoint = 'D' });
    // True-vim w: next word START, so D leaves the separator behind.
    try std.testing.expectEqualStrings("zig ", app.editor.text.items);
}

test "composer operators: dw ci\" yy dd" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.mode = .normal;

    // dw from the start eats the first word and its trailing space.
    app.editor.insertSlice("zig build test");
    app.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("build test", app.editor.text.items);
    try std.testing.expectEqualStrings("zig ", app.yank_register.items);

    // ci" clears the quoted span and enters insert mode.
    app.editor.clear();
    app.editor.insertSlice("run \"the old thing\" now");
    app.editor.cursor = 8;
    try handleKey(&app, .{ .codepoint = 'c' });
    try handleKey(&app, .{ .codepoint = 'i' });
    try handleKey(&app, .{ .codepoint = '"' });
    try std.testing.expectEqualStrings("run \"\" now", app.editor.text.items);
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expectEqual(@as(usize, 5), app.editor.cursor);

    // yy fills the register without touching the text.
    app.mode = .normal;
    app.editor.clear();
    app.editor.insertSlice("keep me");
    try handleKey(&app, .{ .codepoint = 'y' });
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expectEqualStrings("keep me", app.editor.text.items);
    try std.testing.expectEqualStrings("keep me", app.yank_register.items);

    // dd removes the cursor's line including its newline.
    app.editor.clear();
    app.editor.insertSlice("one\ntwo\nthree");
    app.editor.cursor = 5;
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'd' });
    try std.testing.expectEqualStrings("one\nthree", app.editor.text.items);

    // An unknown motion cancels cleanly.
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'z' });
    try std.testing.expectEqualStrings("one\nthree", app.editor.text.items);
    try std.testing.expectEqual(@as(u8, 0), app.pending_op);

    // di( around the cursor inside brackets.
    app.editor.clear();
    app.editor.insertSlice("call(alpha, beta)");
    app.editor.cursor = 7;
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 'i' });
    try handleKey(&app, .{ .codepoint = '(' });
    try std.testing.expectEqualStrings("call()", app.editor.text.items);
}

test "vim completeness: counts, find, undo, synonyms, linewise paste" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.mode = .normal;

    // d2w with a count: two words and their separators.
    app.editor.insertSlice("one two three four");
    app.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = '2' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("three four", app.editor.text.items);

    // u undoes it; ctrl+r redoes it.
    try handleKey(&app, .{ .codepoint = 'u' });
    try std.testing.expectEqualStrings("one two three four", app.editor.text.items);
    try handleKey(&app, .{ .codepoint = 'r', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("three four", app.editor.text.items);

    // f/t with operator: dt<space> from start eats "three".
    try handleKey(&app, .{ .codepoint = 'd' });
    try handleKey(&app, .{ .codepoint = 't' });
    try handleKey(&app, .{ .codepoint = ' ', .text = " " });
    try std.testing.expectEqualStrings(" four", app.editor.text.items);

    // 3w count motion, then x.
    app.editor.clear();
    app.editor.insertSlice("a bb ccc dddd");
    app.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = '3' });
    try handleKey(&app, .{ .codepoint = 'w' });
    try std.testing.expectEqual(@as(usize, 9), app.editor.cursor); // start of dddd
    try handleKey(&app, .{ .codepoint = 'x' });
    try std.testing.expectEqualStrings("a bb ccc ddd", app.editor.text.items);

    // r replaces in place; ~ toggles case.
    app.editor.moveLineStart();
    try handleKey(&app, .{ .codepoint = 'r' });
    try handleKey(&app, .{ .codepoint = 'A', .text = "A" });
    try std.testing.expectEqualStrings("A bb ccc ddd", app.editor.text.items);
    try handleKey(&app, .{ .codepoint = '~' });
    try std.testing.expectEqualStrings("a bb ccc ddd", app.editor.text.items);

    // C changes to end of line and enters insert.
    app.editor.cursor = 2;
    try handleKey(&app, .{ .codepoint = 'C', .mods = .{ .shift = true } });
    try std.testing.expectEqualStrings("a ", app.editor.text.items);
    try std.testing.expectEqual(Mode.insert, app.mode);
    app.mode = .normal;

    // Linewise yank and paste below (Y then p).
    app.editor.clear();
    app.editor.insertSlice("alpha\nbeta");
    app.editor.cursor = 0;
    try handleKey(&app, .{ .codepoint = 'Y', .mods = .{ .shift = true } });
    try std.testing.expect(app.yank_linewise);
    try handleKey(&app, .{ .codepoint = 'p' });
    try std.testing.expectEqualStrings("alpha\nalpha\nbeta", app.editor.text.items);

    // o opens a line below and enters insert.
    app.mode = .normal;
    try handleKey(&app, .{ .codepoint = 'o' });
    try std.testing.expectEqual(Mode.insert, app.mode);
    try std.testing.expect(std.mem.startsWith(u8, app.editor.text.items, "alpha\nalpha\n\n"));
}

test "J joins lines; gg tops; gt cycles sessions" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.mode = .normal;

    app.editor.insertSlice("one\n  two\nthree");
    app.editor.cursor = 0;
    try handleKey(&app, .{ .codepoint = 'J', .mods = .{ .shift = true } });
    try std.testing.expectEqualStrings("one two\nthree", app.editor.text.items);
    // 3J from the top joins all three lines (two joins).
    try handleKey(&app, .{ .codepoint = 'u' });
    try std.testing.expectEqualStrings("one\n  two\nthree", app.editor.text.items);
    app.editor.cursor = 0;
    try handleKey(&app, .{ .codepoint = '3' });
    try handleKey(&app, .{ .codepoint = 'J', .mods = .{ .shift = true } });
    try std.testing.expectEqualStrings("one two three", app.editor.text.items);

    // gg scrolls to top (clamped in draw); a lone g arms the prefix only.
    app.scroll_up = 0;
    try handleKey(&app, .{ .codepoint = 'g' });
    try std.testing.expect(app.pending_g);
    try std.testing.expectEqual(@as(usize, 0), app.scroll_up);
    try handleKey(&app, .{ .codepoint = 'g' });
    try std.testing.expect(!app.pending_g);
    try std.testing.expect(app.scroll_up > 0);

    // Ngt ordinal math: 1-based, clamps past the end, no-ops on empty.
    try std.testing.expectEqual(@as(?usize, 1), App.recentOrdinalIndex(3, 2));
    try std.testing.expectEqual(@as(?usize, 2), App.recentOrdinalIndex(3, 9));
    try std.testing.expectEqual(@as(?usize, null), App.recentOrdinalIndex(0, 2));
    try std.testing.expectEqual(@as(?usize, null), App.recentOrdinalIndex(3, 0));

    // Yank from copy mode exits it and schedules the highlight clear.
    app.last_total_lines = 5;
    app.copy_cursor = .{ .line = 1, .col = 0 };
    try handleKey(&app, .{ .codepoint = 'y' });
    try std.testing.expect(app.copy_cursor == null);
    try std.testing.expect(app.copy_pending);
    try std.testing.expect(app.sel_clear_after_copy);
}

test "currentInflightCall tracks the executing call within the active turn" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();

    // Prior turn's dangling call must not leak into the current one.
    app.pushBlock(.tool_call, "{\"command\":\"old\"}", "bash", .ok);
    app.pushBlock(.user_msg, "do things", "", .ok);
    try std.testing.expect(app.currentInflightCall() == null);

    // Calls-first batch: two recorded, none answered → first runs, one queued.
    app.pushBlock(.tool_call, "{\"command\":\"zig build test\"}", "bash", .ok);
    app.pushBlock(.tool_call, "{\"path\":\"src/main.zig\"}", "read_file", .ok);
    const first = app.currentInflightCall().?;
    try std.testing.expectEqualStrings("bash", first.rb.label);
    try std.testing.expectEqual(@as(usize, 1), first.queued);

    // First result lands → the second call is now live.
    app.pushBlock(.tool_result, "ok", "", .ok);
    const second = app.currentInflightCall().?;
    try std.testing.expectEqualStrings("read_file", second.rb.label);
    try std.testing.expectEqual(@as(usize, 0), second.queued);

    // All answered → nothing in flight.
    app.pushBlock(.tool_result, "contents", "", .ok);
    try std.testing.expect(app.currentInflightCall() == null);
}
