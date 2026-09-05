//! Owned client state for a session view. App routes events and focus;
//! this module owns buffers and their lifetime. Layout and selection belong
//! to a view, so future panes must not share this value by pointer.

const std = @import("std");
const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const Editor = @import("editor.zig");
const layout = @import("layout.zig");
const RenderBlock = layout.RenderBlock;
const LayoutCache = layout.LayoutCache;
const TailLayoutCache = layout.TailLayoutCache;
const StreamLayoutCache = layout.StreamLayoutCache;
const SelectionPoint = @import("render.zig").SelectionPoint;

pub const PendingApproval = struct {
    id_buf: [32]u8 = undefined,
    id_len: usize = 0,
    tool_buf: [64]u8 = undefined,
    tool_len: usize = 0,
    args_buf: [256]u8 = undefined,
    args_len: usize = 0,

    pub fn id(self: *const PendingApproval) []const u8 {
        return self.id_buf[0..self.id_len];
    }
    pub fn tool(self: *const PendingApproval) []const u8 {
        return self.tool_buf[0..self.tool_len];
    }
    pub fn args(self: *const PendingApproval) []const u8 {
        return self.args_buf[0..self.args_len];
    }
};

pub const PlanItemOwned = struct {
    step: []u8,
    status: block.PlanStatus,
    started_at_ms: i64 = 0,
    duration_ms: u64 = 0,
};

pub fn hasUnfinishedPlan(items: anytype) bool {
    for (items) |item| if (item.status != .completed) return true;
    return false;
}

pub fn deinitPlan(gpa: std.mem.Allocator, items: *std.ArrayList(PlanItemOwned)) void {
    for (items.items) |item| gpa.free(item.step);
    items.deinit(gpa);
    items.* = .empty;
}

/// Everything the client knows about one session: its transcript, composer
/// draft, viewport, selection, approval, turn timers, and layout caches. The
/// App owns exactly one focused view today; a pane layout would own several.
/// Anything that is per-session belongs here, never on App, so that a switch
/// moves one value and a new field cannot leak across sessions by omission.
pub const SessionView = struct {
    sid: u64,
    editor: Editor,
    blocks: std.ArrayList(RenderBlock) = .empty,
    delta: std.ArrayList(u8) = .empty,
    reasoning_delta: std.ArrayList(u8) = .empty,
    /// Latest unfinished durable plan revision while it is pinned above the
    /// composer. Its terminal completed revision lives only in transcript.
    plan: std.ArrayList(PlanItemOwned) = .empty,
    state: proto.SessionState = .idle,
    model: std.ArrayList(u8) = .empty,
    effort: proto.ReasoningEffort = .auto,
    /// Session working directory from daemon metadata, not necessarily the
    /// attach process's current directory.
    cwd: std.ArrayList(u8) = .empty,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    context_used: u64 = 0,
    context_limit: u64 = 0,
    usage_credits: bool = false,
    /// Persistent daemon-owned collaboration mode for the session.
    plan_mode: bool = false,
    /// An idle final answer from a Plan-mode turn can be implemented or
    /// revised without retyping the proposal.
    plan_proposal_ready: bool = false,
    /// /permissions full is active for this session (client-side mirror of
    /// the daemon's approval mode; a daemon restart resets both to default).
    permissions_full: bool = false,
    /// Highest durable block incorporated for the session.
    last_seq: u64 = 0,
    /// Initial attach is a bounded tail. `history_complete=false` means a
    /// trip to the loaded top should request another bounded older page.
    oldest_seq: u64 = 0,
    history_complete: bool = true,
    history_loading: bool = false,
    /// Zero identifies the initial tail replay; non-zero is the exclusive
    /// upper bound of an older page currently being buffered.
    history_before_seq: u64 = 0,
    history_backfill: std.ArrayList(RenderBlock) = .empty,
    history_page_failed: bool = false,
    /// 0 = pinned to bottom; N = scrolled up N lines.
    scroll_up: usize = 0,
    /// Line count of the last rendered frame; used to keep the view
    /// anchored (not sliding) when new lines arrive while scrolled up.
    last_total_lines: usize = 0,
    /// View geometry of the last frame. Once a running turn's prompt reaches
    /// the top, the viewport may become non-contiguous to keep it there.
    last_first_visible: usize = 0,
    last_view_h: usize = 0,
    last_pinned_start: usize = 0,
    last_pinned_rows: usize = 0,
    last_body_first: usize = 0,
    last_body_rows: usize = 0,
    pending: ?PendingApproval = null,
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
    /// Successful non-diff tool runs are rolled up by default. Errors and
    /// diffs remain visible even when the rest of the transcript is hidden.
    show_tool_transcript: bool = false,
    spinner_frame: usize = 0,
    /// Wall-clock ms when the session's current turn entered .running;
    /// drives the elapsed counter on the Working line.
    turn_started_ms: i64 = 0,
    turn_phase: proto.TurnPhase = .idle,
    phase_started_ms: i64 = 0,
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
    /// Baked layout of completed turns; see LayoutCache.
    layout_cache: LayoutCache = .{},
    /// Baked durable portion of the active turn; see TailLayoutCache.
    tail_layout_cache: TailLayoutCache = .{},
    /// Incremental provisional assistant text; finalized blocks use the full
    /// Markdown layout caches above.
    stream_layout_cache: StreamLayoutCache = .{},
    /// Bumped whenever existing blocks mutate in place or the block list is
    /// replaced (session switch) — invalidates layout_cache.
    layout_epoch: u64 = 0,
    /// MRU tick while the view sits in App.saved_views; unused when focused.
    /// Inactive views are a cache, not durable state: an evicted session
    /// replays from seq 1 when reopened.
    last_used: u64 = 0,

    pub fn deinit(self: *SessionView, gpa: std.mem.Allocator) void {
        self.editor.deinit();
        for (self.blocks.items) |*rb| rb.deinit(gpa);
        self.blocks.deinit(gpa);
        for (self.history_backfill.items) |*rb| rb.deinit(gpa);
        self.history_backfill.deinit(gpa);
        self.delta.deinit(gpa);
        self.reasoning_delta.deinit(gpa);
        deinitPlan(gpa, &self.plan);
        self.model.deinit(gpa);
        self.cwd.deinit(gpa);
        self.layout_cache.reset(gpa);
        self.tail_layout_cache.reset(gpa);
        self.stream_layout_cache.reset(gpa);
    }

    /// Drop provisional streaming text once a turn settles so an idle view,
    /// focused or cached, holds only its durable transcript.
    pub fn releaseStreamingBuffers(self: *SessionView, gpa: std.mem.Allocator) void {
        self.delta.deinit(gpa);
        self.delta = .empty;
        self.reasoning_delta.deinit(gpa);
        self.reasoning_delta = .empty;
        self.stream_layout_cache.reset(gpa);
    }
};
