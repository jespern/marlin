//! TUI client: libvaxis. Modal editor with durable session multiplexing.
//! See docs/ARCHITECTURE.md §8 for the target layout; splits/session picker
//! land in M4. This client is a pure protocol consumer: attach.Conn in,
//! blocks out. Deltas are ephemeral; finalized blocks replace them.
//!
//! Layout:
//!   ┌─ permanent clickable root-session tab strip ─┐
//!   ├─ session view: blocks, streaming region ─────┤
//!   ├─ prompt panel (3-10 lines, grows with content) ┤
//!   └─ status: state · model · tokens · ctx ───────┤
//!
//! Keys:
//!   insert:  type → input; Enter send; Shift+Enter/Alt+Enter/Ctrl+J newline;
//!            Up/Down move lines or walk history at the edges;
//!            Ctrl+R fuzzy-searches authored input history;
//!            readline/macOS movement and deletion chords are supported;
//!            Esc → normal (draft survives); Ctrl+C interrupts active work
//!   normal:  ? shortcuts; Esc/i insert; j/k scroll; g/G top/bottom;
//!            / searches this transcript; </> or Left/Right switch tabs; q quit
//!   global:  Ctrl+N creates a session; Ctrl+D archives when input is empty;
//!            Ctrl+L clears/redraws and returns to bottom;
//!            Ctrl+T toggles the expanded tool transcript;
//!            Alt/Option+1..9 jumps to that tab
//!   approval pending: y approve, n deny (both modes, input empty)
//!   commands: /model <m>, /effort <level>, /search <query>, /animate matrix,
//!             /new, /compact, /archive, /reboot [--build], /help, /quit
//!   shortcuts: !c (copy last full tool output), !rb [client|both] (scoped rebuild)
//!   paste:   bracketed paste; large pastes become [paste #N: X lines]
//!            chips, expanded into the message on send.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const vaxis = @import("vaxis");

const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const config = @import("../core/config.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const voice = @import("voice.zig");
const Editor = @import("editor.zig");
const media = @import("media.zig");
const render = @import("render.zig");
const markdown = @import("markdown.zig");
const layout_mod = @import("layout.zig");
const LayoutCache = layout_mod.LayoutCache;
const TailLayoutCache = layout_mod.TailLayoutCache;
const StreamLayoutCache = layout_mod.StreamLayoutCache;
const RenderBlock = layout_mod.RenderBlock;
const allocDurableRenderBlock = layout_mod.allocDurableRenderBlock;
const layoutBlockRange = layout_mod.layoutBlockRange;
const wrapPromptCard = layout_mod.wrapPromptCard;
const wrapReasoningCard = layout_mod.wrapReasoningCard;
const ExpandPair = layout_mod.ExpandPair;
const scanToolBatch = layout_mod.scanToolBatch;
const Transcript = layout_mod.Transcript;
const InflightCall = layout_mod.InflightCall;
const currentInflightCall = layout_mod.currentInflightCall;
const toolDisplayArg = layout_mod.toolDisplayArg;
const toolDisplayName = layout_mod.toolDisplayName;
const DiffLineNumbers = layout_mod.DiffLineNumbers;
const appendDiffLine = layout_mod.appendDiffLine;
const Palette = render.Palette;
const Line = render.Line;
const nextCpEndFor = render.nextCpEndFor;
const nextWordCol = render.nextWordCol;
const prevWordCol = render.prevWordCol;
const isLegacyRehydration = render.isLegacyRehydration;
const rehydrationLabel = render.rehydrationLabel;
const isCompactionStatusNote = render.isCompactionStatusNote;
const nowWallMs = render.nowWallMs;
const lineWidth = render.lineWidth;
const lineText = render.lineText;
const SyntaxLanguage = render.SyntaxLanguage;
const diffLanguage = render.diffLanguage;
const shellCommandSpans = render.shellCommandSpans;
const gitLogSpans = render.gitLogSpans;
const urlEnd = render.urlEnd;
const findLinkSpans = render.findLinkSpans;
const syntaxForBytes = render.syntaxForBytes;
const applyLineSyntax = render.applyLineSyntax;
const applyLineLinks = render.applyLineLinks;
const SelectionPoint = render.SelectionPoint;
const Selection = render.Selection;
const selectedText = render.selectedText;
const wrapPrefixed = render.wrapPrefixed;
const displayWidth = render.displayWidth;
const hardCellBreak = render.hardCellBreak;
const utf8Floor = render.utf8Floor;
const spaces = render.spaces;
const spinner_frames = render.spinner_frames;

/// Keep startup and first session-switch latency independent of transcript
/// length. Reaching the top explicitly backfills the complete durable log.
const initial_replay_blocks: u32 = 256;

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
    /// Stable error name from the reader thread (for example EndOfStream).
    daemon_gone: []const u8,
    /// Reconnect worker verdict: a fresh handshaked Conn to adopt, or null
    /// when every attempt failed and the TUI should quit like before.
    reconnected: ?*attach.Conn,
    /// Kitty-protocol key release (report_events); only the voice
    /// push-to-talk key acts on releases, everything else ignores them.
    key_release: vaxis.Key,
    /// Voice worker verdicts (transcription and model-download threads).
    voice: VoiceEvent,
};

pub const VoiceEvent = union(enum) {
    /// Cleaned transcript (gpa-owned; handler frees) for the composer.
    transcript: []u8,
    /// Static human-readable failure.
    stt_failed: []const u8,
    download_done,
    download_failed: []const u8,
};

const Mode = enum { insert, normal };

const UiAnimation = enum { none, matrix };

fn matrixTrailLength(height: u16) usize {
    return @max(@as(usize, height) * 5 / 8, 8);
}

fn matrixAnimationFrames(height: u16) usize {
    return (@as(usize, height) + matrixTrailLength(height)) * 2;
}

pub const RebuildScope = enum { none, attached, client, both };

pub const RebootRequest = struct {
    requested: bool = false,
    rebuild: RebuildScope = .none,
    force: bool = false,
};

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
    .{ .name = "/setup", .description = "choose and authenticate a provider or guest agent" },
    .{ .name = "/effort", .usage = " [level]", .description = "set reasoning effort or open the picker", .accepts_args = true },
    .{ .name = "/sandbox", .usage = " [on|off]", .description = "toggle the shell sandbox for this session", .accepts_args = true },
    .{ .name = "/permissions", .usage = " [full|default]", .description = "full access (no prompts) or default approvals", .accepts_args = true },
    .{ .name = "/network", .usage = " [on|off|status]", .description = "control managed-tool domain blocking", .accepts_args = true },
    .{ .name = "/mcp", .usage = " [add|remove|restart|reload]", .description = "inspect and manage MCP servers", .accepts_args = true },
    .{ .name = "/council", .usage = " [<name>|new <name>|edit <name>|remove <name>]", .description = "list, inspect, or edit review councils", .accepts_args = true },
    .{ .name = "/voice", .usage = " [setup|mode|off]", .description = "dictate into the composer (local STT; setup on first use)", .accepts_args = true },
    .{ .name = "/review", .usage = " <council> <question>", .description = "convene a named council on a question", .accepts_args = true },
    .{ .name = "/plan", .usage = " [task|off|clear]", .description = "enter Plan mode or manage its execution todo", .accepts_args = true },
    .{ .name = "/sessions", .description = "switch sessions" },
    .{ .name = "/search", .usage = " [query]", .description = "search across durable transcripts", .accepts_args = true },
    .{ .name = "/diagnostics", .description = "inspect recent turn, provider, and tool timing" },
    .{ .name = "/animate", .usage = " matrix", .description = "play a transient screen animation", .accepts_args = true },
    .{ .name = "/otel", .usage = " [set <endpoint>|status|off]", .description = "configure live OTLP export", .accepts_args = true },
    .{ .name = "/new", .description = "start a new session" },
    .{ .name = "/rename", .usage = " <title>", .description = "rename this session", .accepts_args = true },
    .{ .name = "/archive", .usage = " [children]", .description = "archive this session, or its finished children", .accepts_args = true },
    .{ .name = "/attach", .usage = " <image-path>", .description = "attach a PNG, JPEG, GIF, or WebP image", .accepts_args = true },
    .{ .name = "/compact", .description = "compact the current context" },
    .{ .name = "/config", .usage = " [tabbar on|off]", .description = "view or change UI settings (persisted)", .accepts_args = true },
    .{ .name = "/reboot", .usage = " [--build] [--force]", .description = "restart Marlin", .accepts_args = true },
    .{ .name = "/help", .description = "show commands and key bindings" },
    .{ .name = "/quit", .description = "leave Marlin" },
    .{ .name = "!c", .description = "copy the last full tool output" },
    .{ .name = "!rb", .usage = " [client|both]", .description = "rebuild attached Marlin, local client, or both", .accepts_args = true },
};

const CommandSuggestion = struct {
    label: []const u8,
    usage: []const u8 = "",
    description: []const u8,
    replacement: []const u8,
    submit_on_enter: bool,
};

const PickerKind = enum { model, effort, session, search_prompt, search, council, council_list, voice_engine, voice_mode, setup_provider };

const SetupProvider = enum { openrouter, codex, claude_code, vercel, anthropic, litellm, local, custom };
const SetupPrompt = enum { none, credential, base_url, model, provider_name };

const setup_provider_items = [_][]const u8{
    "OpenRouter · native · one key, many models",
    "Codex · guest · ChatGPT login",
    "Claude Code · guest · Claude login",
    "Vercel AI Gateway · native",
    "Anthropic API · native",
    "LiteLLM · local gateway",
    "Local · OpenAI-compatible server",
    "Custom · OpenAI-compatible endpoint",
};

const SetupReadiness = struct {
    completed: bool = false,
    codex_available: bool = false,
    codex_authenticated: bool = false,
    claude_code_available: bool = false,
    claude_code_authenticated: bool = false,
    openrouter_ready: bool = false,
    vercel_ready: bool = false,
    anthropic_ready: bool = false,
    litellm_ready: bool = false,
    local_ready: bool = false,

    fn fromWire(status: proto.SetupStatus) SetupReadiness {
        return .{
            .completed = status.completed,
            .codex_available = status.codex_available,
            .codex_authenticated = status.codex_authenticated,
            .claude_code_available = status.claude_code_available,
            .claude_code_authenticated = status.claude_code_authenticated,
            .openrouter_ready = status.openrouter_ready,
            .vercel_ready = status.vercel_ready,
            .anthropic_ready = status.anthropic_ready,
            .litellm_ready = status.litellm_ready,
            .local_ready = status.local_ready,
        };
    }
};

const OtelCommand = union(enum) {
    status,
    off,
    set: []const u8,
    content: bool,
};

const council_done_item = "Done";

/// Baked display lines for blocks of completed turns. Line contents point
/// into `arena_state` (derived strings) or App-owned block text; both stay
/// valid until reset. Keyed by width/transcript-toggle plus an epoch the
/// App bumps whenever existing blocks mutate or the session switches.
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
            rendered.pending_request_id = 0;
            rendered.pending_prior_state = null;
            rendered.seq = seq;
            rendered.turn_id = turn_id;
            return true;
        }
    }
    return false;
}

fn acknowledgeInputInBlocks(blocks: []RenderBlock, request_id: u64) bool {
    for (blocks) |*rendered| {
        if (rendered.pending_request_id != request_id) continue;
        rendered.pending_request_id = 0;
        rendered.pending_prior_state = null;
        return true;
    }
    return false;
}

const RejectedInput = struct {
    prior_state: ?proto.SessionState,
    text: []u8,
};

fn rejectInputInBlocks(
    gpa: std.mem.Allocator,
    blocks: *std.ArrayList(RenderBlock),
    request_id: u64,
) ?RejectedInput {
    for (blocks.items, 0..) |*rendered, i| {
        if (rendered.pending_request_id != request_id) continue;
        const rejected = RejectedInput{
            .prior_state = rendered.pending_prior_state,
            .text = gpa.dupe(u8, rendered.text) catch return null,
        };
        rendered.deinit(gpa);
        _ = blocks.orderedRemove(i);
        return rejected;
    }
    return null;
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
    /// Approval mode is "auto" (/permissions full) for this session.
    full_access: bool,
    plan_mode: bool,

    fn deinit(self: *SessionSummary, gpa: std.mem.Allocator) void {
        gpa.free(self.title);
        gpa.free(self.cwd);
        gpa.free(self.model);
        gpa.free(self.label);
    }
};

const OwnedCouncil = struct {
    name: []u8,
    models: std.ArrayList([]u8) = .empty,

    fn deinit(self: *OwnedCouncil, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        for (self.models.items) |model| gpa.free(model);
        self.models.deinit(gpa);
    }
};

const tab_bar_height: usize = 1;
const tab_label_max_cells: usize = 24;

const TabActivity = enum {
    idle,
    done,
    running,
    err,
    approval,
};

const TabHit = struct {
    start_col: usize,
    end_col: usize,
    sid: u64,

    fn contains(self: TabHit, col: usize) bool {
        return col >= self.start_col and col < self.end_col;
    }
};

/// Mouse intent is separate from tab geometry so a context menu can be added
/// later without changing hit testing or the renderer's layout contract.
const TabMouseAction = enum { activate, context_menu };

const TabLayoutItem = struct {
    sid: u64,
    label: []const u8,
    activity: TabActivity,
    active: bool,
    x: usize,
    width: usize,
};

const TabLayout = struct {
    items: []const TabLayoutItem,
    hidden_left: bool = false,
    hidden_right: bool = false,
};

const PlanItemOwned = struct {
    step: []u8,
    status: block.PlanStatus,
    started_at_ms: i64 = 0,
    duration_ms: u64 = 0,
};

fn hasUnfinishedPlan(items: anytype) bool {
    for (items) |item| if (item.status != .completed) return true;
    return false;
}

fn deinitPlan(gpa: std.mem.Allocator, items: *std.ArrayList(PlanItemOwned)) void {
    for (items.items) |item| gpa.free(item.step);
    items.deinit(gpa);
    items.* = .empty;
}

/// Inactive sessions keep their complete client-side view state without
/// remaining subscribed to their block streams. Moving these containers in
/// and out of App is allocation-free after the first visit.
const SavedSessionView = struct {
    editor: Editor,
    blocks: std.ArrayList(RenderBlock),
    delta: std.ArrayList(u8),
    reasoning_delta: std.ArrayList(u8),
    plan: std.ArrayList(PlanItemOwned) = .empty,
    state: proto.SessionState,
    model: std.ArrayList(u8),
    effort: proto.ReasoningEffort,
    cwd: std.ArrayList(u8),
    tokens_in: u64,
    tokens_out: u64,
    context_used: u64,
    context_limit: u64,
    plan_mode: bool,
    plan_proposal_ready: bool,
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
    turn_phase: proto.TurnPhase,
    phase_started_ms: i64,
    call_started_ms: i64,
    stream_bytes: u64,
    stream_quiet_ms: u64,
    stream_status_at_ms: i64,
    last_seq: u64,
    oldest_seq: u64,
    history_complete: bool,
    last_used: u64 = 0,

    fn deinit(self: *SavedSessionView, gpa: std.mem.Allocator) void {
        self.editor.deinit();
        for (self.blocks.items) |*rb| rb.deinit(gpa);
        self.blocks.deinit(gpa);
        self.delta.deinit(gpa);
        self.reasoning_delta.deinit(gpa);
        deinitPlan(gpa, &self.plan);
        self.model.deinit(gpa);
        self.cwd.deinit(gpa);
    }

    fn releaseStreamingBuffers(self: *SavedSessionView, gpa: std.mem.Allocator) void {
        self.delta.deinit(gpa);
        self.delta = .empty;
        self.reasoning_delta.deinit(gpa);
        self.reasoning_delta = .empty;
    }
};

const SearchHitOwned = struct {
    sid: u64,
    seq: u64,
    label: []u8,

    fn deinit(self: *SearchHitOwned, gpa: std.mem.Allocator) void {
        gpa.free(self.label);
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn: *attach.Conn,
    environ: ?*const std.process.Environ.Map = null,
    /// Event loop handle for worker threads spawned from App methods
    /// (voice transcription/download); set once in run().
    loop: ?*vaxis.Loop(Event) = null,
    voice_rt: VoiceRt = .{},
    sid: u64,
    editor: Editor,
    attachments: std.ArrayList(media.Pending) = .empty,

    mode: Mode = .insert,
    /// Terminal size (updated on every winsize event); columns drive editor
    /// movement and rows size viewport-relative client animations.
    term_cols: usize = 80,
    term_rows: u16 = 24,
    blocks: std.ArrayList(RenderBlock) = .empty,
    delta: std.ArrayList(u8) = .empty,
    reasoning_delta: std.ArrayList(u8) = .empty,
    /// Latest unfinished durable plan revision while it is pinned above the
    /// composer. Its terminal completed revision lives only in transcript.
    plan: std.ArrayList(PlanItemOwned) = .empty,
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
    /// Persistent daemon-owned collaboration mode for the active session.
    plan_mode: bool = false,
    /// An idle final answer from a Plan-mode turn can be implemented or
    /// revised without retyping the proposal.
    plan_proposal_ready: bool = false,
    /// Highest durable block incorporated for the active session.
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
    /// Selector overlay: null = closed; value = highlighted index into the
    /// filtered model or effort list (see pickerItems).
    picker: ?usize = null,
    picker_kind: PickerKind = .model,
    /// Compact normal-mode shortcut reference opened with `?`.
    shortcut_help: bool = false,
    /// Council detail overlay. The name is owned so daemon cache refreshes do
    /// not invalidate an open detail view.
    council_detail_name: std.ArrayList(u8) = .empty,
    /// Highlighted row in the command/shortcut autocomplete menu. The menu
    /// itself is derived from editor text and therefore needs no open flag.
    command_selection: usize = 0,
    /// Type-to-filter query while the picker is open.
    picker_filter: std.ArrayList(u8) = .empty,
    /// Provider onboarding is a client-side draft backed by daemon-owned
    /// persistence. Only the credential field is masked, and it is scrubbed
    /// immediately after setup_apply is encoded.
    setup_readiness: SetupReadiness = .{},
    setup_provider: ?SetupProvider = null,
    setup_prompt: SetupPrompt = .none,
    setup_required: bool = false,
    setup_replace_empty_session: bool = false,
    setup_status_pending: bool = false,
    setup_apply_pending: bool = false,
    setup_provider_name: std.ArrayList(u8) = .empty,
    setup_base_url: std.ArrayList(u8) = .empty,
    setup_api_key_env: std.ArrayList(u8) = .empty,
    setup_credential: std.ArrayList(u8) = .empty,
    /// Process-local OTLP setup. The endpoint survives only until the masked
    /// header entry is submitted or cancelled; neither value enters history.
    otel_endpoint: std.ArrayList(u8) = .empty,
    otel_header_prompt: bool = false,
    /// Inline readline-style reverse history search. The editor shows the
    /// current candidate while these buffers preserve the original draft and
    /// collect the query independently of the candidate text.
    history_search_active: bool = false,
    history_search_query: std.ArrayList(u8) = .empty,
    history_search_draft: std.ArrayList(u8) = .empty,
    history_search_draft_cursor: usize = 0,
    history_search_match: ?usize = null,
    /// Durable transcript-search results. Labels are separate so the generic
    /// picker can filter them without knowing search metadata.
    search_hits: std.ArrayList(SearchHitOwned) = .empty,
    search_labels: std.ArrayList([]const u8) = .empty,
    search_scope_sid: u64 = 0,
    search_pending: bool = false,
    search_cursor: usize = 0,
    /// Non-zero while a centered search replay still needs viewport
    /// positioning after its durable pages arrive.
    search_target_seq: u64 = 0,
    search_highlight_line: ?usize = null,
    /// Council editor state. The draft survives filter changes and is sent
    /// atomically only when the Done row is chosen; Esc discards it.
    council_edit_name: std.ArrayList(u8) = .empty,
    council_edit_models: std.ArrayList([]u8) = .empty,
    /// Full model catalog from the daemon (owned copies). Empty until
    /// model_list_result arrives; picker falls back to cfg.model_favorites.
    catalog: std.ArrayList([]u8) = .empty,
    /// Optional provider-published pricing keyed by model id. Model strings
    /// are separately owned so legacy model-list replies remain valid.
    catalog_pricing: std.ArrayList(proto.ModelPricing) = .empty,
    /// Client/daemon build mismatch detected at attach: shown in the startup
    /// notice AND kept on the welcome card, which cannot be clobbered by the
    /// next transient notice.
    build_mismatch: bool = false,
    /// Handshake facts cached for the welcome card — the draw path must
    /// never dereference conn (tests render with conn = undefined).
    welcome_daemon_version: [64]u8 = undefined,
    welcome_daemon_version_len: usize = 0,
    welcome_sandbox: bool = false,
    welcome_dnsblock_rules: u64 = 0, // 0 = filtering off
    /// Live lightweight session catalog from session_watch. Labels back the
    /// existing fuzzy picker; full view state lives in saved_views.
    sessions: std.ArrayList(SessionSummary) = .empty,
    session_labels: std.ArrayList([]const u8) = .empty,
    /// Monotonic catalog of active and archived ids, seeded before entering
    /// the TUI. It lets visible handles remain globally unambiguous even
    /// though session_watch intentionally omits archived rows.
    known_session_ids: std.ArrayList(u64) = .empty,
    saved_views: std.AutoHashMapUnmanaged(u64, *SavedSessionView) = .empty,
    saved_view_clock: u64 = 0,
    background_approvals: std.AutoHashMapUnmanaged(u64, PendingApproval) = .empty,
    /// Council cache from the daemon (durable config); refreshed by every
    /// council_list_result. Names and models are gpa-owned.
    councils: std.ArrayList(OwnedCouncil) = .empty,
    /// The next council_list_result follows a mutating command: summarize it.
    council_notice_pending: bool = false,
    /// Open the council picker when the requested list refresh arrives.
    council_list_pending: bool = false,
    recent_sessions: std.ArrayList(u64) = .empty,
    recent_cursor: usize = 0,
    /// Click targets from the most recently rendered tab strip. The entries
    /// contain no behavior, leaving room for button-specific actions later.
    tab_hits: std.ArrayList(TabHit) = .empty,
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
    /// What `!c` is copying ("read_file docs/FOO.md"); folded transcripts
    /// hide the source block, so the notice must identify it.
    clipboard_desc: std.ArrayList(u8) = .empty,
    /// Successful non-diff tool runs are rolled up by default. Errors and
    /// diffs remain visible even when the rest of the transcript is hidden.
    show_tool_transcript: bool = false,
    /// Top tab strip ([ui] tab_bar; /config tabbar toggles + persists).
    /// Hiding the bar only removes CHROME: alt+N, gt/gT, </> keep working.
    show_tab_bar: bool = true,
    /// Ctrl+L asks the event loop to invalidate libvaxis's previous-screen
    /// cache so the next render repaints every terminal cell.
    refresh_requested: bool = false,
    spinner_frame: usize = 0,
    /// Wall-clock ms when the active session's current turn entered
    /// .running; drives the elapsed counter on the Working line.
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
    ui_animation: UiAnimation = .none,
    ui_animation_frame: usize = 0,
    ui_animation_frames: usize = matrixAnimationFrames(24),
    ui_animation_seed: u64 = 0,
    ui_animation_active: std.atomic.Value(bool) = .init(false),
    animation_active: std.atomic.Value(bool) = .init(false),
    animation_stop: std.atomic.Value(bool) = .init(false),
    cfg: config.Config = .{},
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
    pending_new_session_request_id: u64 = 0,
    pending_new_cwd: std.ArrayList(u8) = .empty,
    /// Set by /reboot or !rb: after clean TUI teardown, run() returns this
    /// to cli.zig, which coordinates scoped builds and reattachment.
    reboot_request: RebootRequest = .{},
    next_input_request_id: u64 = 1,

    fn deinit(self: *App) void {
        self.clearAttachments();
        self.attachments.deinit(self.gpa);
        self.copy_cursor_line_text.deinit(self.gpa);
        self.yank_register.deinit(self.gpa);
        self.tail_layout_cache.reset(self.gpa);
        self.stream_layout_cache.reset(self.gpa);
        self.layout_cache.reset(self.gpa);
        self.picker_filter.deinit(self.gpa);
        self.clearSetupDraft();
        self.setup_provider_name.deinit(self.gpa);
        self.setup_base_url.deinit(self.gpa);
        self.setup_api_key_env.deinit(self.gpa);
        self.setup_credential.deinit(self.gpa);
        self.otel_endpoint.deinit(self.gpa);
        self.history_search_query.deinit(self.gpa);
        self.history_search_draft.deinit(self.gpa);
        self.clearSearchHits();
        self.search_hits.deinit(self.gpa);
        self.search_labels.deinit(self.gpa);
        self.council_detail_name.deinit(self.gpa);
        self.clearCouncilEdit();
        self.council_edit_name.deinit(self.gpa);
        self.council_edit_models.deinit(self.gpa);
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
        self.clearCouncils();
        self.councils.deinit(self.gpa);
        self.voice_rt.deinit(self.gpa);
        self.recent_sessions.deinit(self.gpa);
        self.tab_hits.deinit(self.gpa);
        self.pending_new_cwd.deinit(self.gpa);
        self.clipboard_pending.deinit(self.gpa);
        self.clipboard_desc.deinit(self.gpa);
        self.clearHistoryBackfill();
        self.history_backfill.deinit(self.gpa);
        for (self.blocks.items) |*rb| rb.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.delta.deinit(self.gpa);
        self.reasoning_delta.deinit(self.gpa);
        deinitPlan(self.gpa, &self.plan);
        self.model.deinit(self.gpa);
        self.cwd.deinit(self.gpa);
        self.home.deinit(self.gpa);
        self.notice.deinit(self.gpa);
        if (self.otel_header_prompt) self.editor.clearSensitive();
        self.editor.deinit();
    }

    fn clearAttachments(self: *App) void {
        for (self.attachments.items) |*attachment| attachment.deinit(self.gpa);
        self.attachments.clearRetainingCapacity();
    }

    fn addAttachment(self: *App, pending_value: media.Pending) void {
        var pending = pending_value;
        if (self.attachments.items.len >= 4) {
            pending.deinit(self.gpa);
            self.setNotice("at most four images may be attached to one message", .{});
            return;
        }
        self.attachments.append(self.gpa, pending) catch {
            pending.deinit(self.gpa);
            self.setNotice("could not stage image", .{});
            return;
        };
        self.editor.insertImagePlaceholder(self.attachments.items.len);
        self.setNotice("attached {s} · {d}/4 · Ctrl+V or /attach adds another", .{
            self.attachments.items[self.attachments.items.len - 1].name,
            self.attachments.items.len,
        });
    }

    fn attachPath(self: *App, path: []const u8) void {
        const pending = media.fromPath(self.gpa, self.io, self.cwd.items, path) catch |err| {
            self.setNotice("could not attach image: {s}", .{mediaErrorMessage(err)});
            return;
        };
        self.addAttachment(pending);
    }

    fn attachClipboard(self: *App) void {
        const pending = media.fromClipboard(self.gpa, self.io, self.environ) catch |err| {
            self.setNotice("image paste failed: {s}", .{mediaErrorMessage(err)});
            return;
        };
        self.addAttachment(pending);
    }

    fn setNotice(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.notice.clearRetainingCapacity();
        self.notice.print(self.gpa, fmt, args) catch {};
    }

    fn clearHistoryBackfill(self: *App) void {
        for (self.history_backfill.items) |*rendered| rendered.deinit(self.gpa);
        self.history_backfill.clearRetainingCapacity();
    }

    fn releaseStreamingBuffers(self: *App) void {
        self.delta.deinit(self.gpa);
        self.delta = .empty;
        self.reasoning_delta.deinit(self.gpa);
        self.reasoning_delta = .empty;
        self.stream_layout_cache.reset(self.gpa);
    }

    fn cacheWelcomeFacts(self: *App) void {
        self.welcome_daemon_version_len = @min(self.conn.daemon_version_len, self.welcome_daemon_version.len);
        @memcpy(
            self.welcome_daemon_version[0..self.welcome_daemon_version_len],
            self.conn.daemonVersion()[0..self.welcome_daemon_version_len],
        );
        self.welcome_sandbox = self.conn.sandbox_available;
        self.welcome_dnsblock_rules = if (self.conn.network_filtering) self.conn.network_rule_count else 0;
    }

    fn setModelStr(self: *App, m: []const u8) void {
        self.model.clearRetainingCapacity();
        self.model.appendSlice(self.gpa, m) catch {};
    }

    fn setCwdStr(self: *App, cwd: []const u8) void {
        self.cwd.clearRetainingCapacity();
        self.cwd.appendSlice(self.gpa, cwd) catch {};
    }

    fn setPlan(self: *App, source: []const block.PlanItem) void {
        var replacement: std.ArrayList(PlanItemOwned) = .empty;
        for (source) |item| {
            const step = self.gpa.dupe(u8, item.step) catch {
                deinitPlan(self.gpa, &replacement);
                return;
            };
            replacement.append(self.gpa, .{
                .step = step,
                .status = item.status,
                .started_at_ms = item.started_at_ms,
                .duration_ms = item.duration_ms,
            }) catch {
                self.gpa.free(step);
                deinitPlan(self.gpa, &replacement);
                return;
            };
        }
        deinitPlan(self.gpa, &self.plan);
        self.plan = replacement;
    }

    fn clearCompletedPlan(self: *App) void {
        if (self.plan.items.len > 0 and !hasUnfinishedPlan(self.plan.items)) {
            deinitPlan(self.gpa, &self.plan);
            self.layout_epoch +%= 1;
        }
    }

    fn restoreLatestUnfinishedPlan(self: *App) void {
        if (self.plan.items.len > 0) return;
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const rendered = self.blocks.items[i];
            if (rendered.kind != .plan) continue;
            if (hasUnfinishedPlan(rendered.plan_items)) self.setPlan(rendered.plan_items);
            return;
        }
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

    fn updateSessionSummaryState(self: *App, sid: u64, state: proto.SessionState) void {
        for (self.sessions.items) |*session| {
            if (session.sid == sid) {
                session.state = state;
                return;
            }
        }
    }

    fn rootSessionId(self: *const App, sid: u64) u64 {
        var cursor = sid;
        var remaining = self.sessions.items.len + 1;
        while (remaining > 0) : (remaining -= 1) {
            const summary = self.sessionSummary(cursor) orelse return cursor;
            cursor = summary.parent_sid orelse return cursor;
        }
        return sid; // malformed cycle: retain a safe, deterministic focus
    }

    fn tabActivity(self: *const App, root_sid: u64) TabActivity {
        var activity: TabActivity = .idle;
        for (self.sessions.items) |session| {
            if (!self.sessionBelongsToTree(session.sid, root_sid)) continue;
            const candidate = tabActivityForState(session.state);
            if (tabActivityRank(candidate) > tabActivityRank(activity)) activity = candidate;
        }
        return activity;
    }

    /// Rows the tab strip occupies at the top of the screen; every layout
    /// and mouse computation offsets by this so hiding the bar reflows
    /// everything else for free.
    fn tabBarRows(self: *const App) usize {
        return if (self.show_tab_bar) tab_bar_height else 0;
    }

    fn tabAtColumn(self: *const App, col: usize) ?u64 {
        for (self.tab_hits.items) |hit| {
            if (hit.contains(col)) return hit.sid;
        }
        return null;
    }

    /// The session parked on an approval inside this tab's tree, if any —
    /// the ! indicator aggregates over the tree, so activating the tab must
    /// land where the approval can actually be answered.
    fn awaitingSessionInTree(self: *const App, root_sid: u64) ?u64 {
        for (self.sessions.items) |session| {
            if (session.state != .awaiting_approval) continue;
            if (self.sessionBelongsToTree(session.sid, root_sid)) return session.sid;
        }
        return null;
    }

    /// First non-focused session parked on an approval, anywhere.
    fn firstAwaitingSid(self: *const App) ?u64 {
        for (self.sessions.items) |session| {
            if (session.sid == self.sid) continue;
            if (session.state == .awaiting_approval) return session.sid;
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
        self.clearHistoryBackfill();
        self.history_search_active = false;
        self.history_search_query.clearRetainingCapacity();
        self.history_search_draft.clearRetainingCapacity();
        self.history_search_match = null;
        self.copy_cursor = null;
        self.stream_layout_cache.reset(self.gpa);
        self.layout_epoch +%= 1;
        self.editor = Editor.init(self.gpa);
        self.blocks = .empty;
        self.delta = .empty;
        self.reasoning_delta = .empty;
        self.plan = .empty;
        self.state = .idle;
        self.model = .empty;
        self.effort = .auto;
        self.cwd = .empty;
        self.tokens_in = 0;
        self.tokens_out = 0;
        self.context_used = 0;
        self.context_limit = 0;
        self.plan_mode = false;
        self.plan_proposal_ready = false;
        self.last_seq = 0;
        self.oldest_seq = 0;
        self.history_complete = true;
        self.history_loading = false;
        self.history_before_seq = 0;
        self.history_page_failed = false;
        self.scroll_up = 0;
        self.last_total_lines = 0;
        self.last_first_visible = 0;
        self.search_highlight_line = null;
        self.last_view_h = 0;
        self.last_pinned_start = 0;
        self.last_pinned_rows = 0;
        self.last_body_first = 0;
        self.last_body_rows = 0;
        self.pending = null;
        self.sel_anchor = null;
        self.sel_head = .{ .line = 0, .col = 0 };
        self.sel_dragging = false;
        self.copy_pending = false;
        self.sel_clear_after_copy = false;
        self.show_tool_transcript = false;
        self.spinner_frame = 0;
        self.turn_started_ms = 0;
        self.turn_phase = .idle;
        self.phase_started_ms = 0;
        self.call_started_ms = 0;
        self.stream_bytes = 0;
        self.stream_quiet_ms = 0;
        self.stream_status_at_ms = 0;
    }

    fn saveActiveView(self: *App) !void {
        const saved = try self.gpa.create(SavedSessionView);
        errdefer self.gpa.destroy(saved);
        self.saved_view_clock +%= 1;
        saved.* = .{
            .editor = self.editor,
            .blocks = self.blocks,
            .delta = self.delta,
            .reasoning_delta = self.reasoning_delta,
            .plan = self.plan,
            .state = self.state,
            .model = self.model,
            .effort = self.effort,
            .cwd = self.cwd,
            .tokens_in = self.tokens_in,
            .tokens_out = self.tokens_out,
            .context_used = self.context_used,
            .context_limit = self.context_limit,
            .plan_mode = self.plan_mode,
            .plan_proposal_ready = self.plan_proposal_ready,
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
            .turn_phase = self.turn_phase,
            .phase_started_ms = self.phase_started_ms,
            .call_started_ms = self.call_started_ms,
            .stream_bytes = self.stream_bytes,
            .stream_quiet_ms = self.stream_quiet_ms,
            .stream_status_at_ms = self.stream_status_at_ms,
            .last_seq = self.last_seq,
            .oldest_seq = self.oldest_seq,
            .history_complete = self.history_complete,
            .last_used = self.saved_view_clock,
        };
        try self.saved_views.put(self.gpa, self.sid, saved);
        self.trimSavedViews();
        self.resetActiveAfterMove();
    }

    const max_saved_views = 8;

    /// Inactive views are a cache, not durable state. Keep a small MRU set;
    /// an evicted session replays from seq 1 when reopened. This bounds the
    /// number of full transcripts retained by a long-lived TUI.
    fn trimSavedViews(self: *App) void {
        while (self.saved_views.count() > max_saved_views) {
            var oldest_sid: ?u64 = null;
            var oldest_tick: u64 = std.math.maxInt(u64);
            var it = self.saved_views.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.last_used < oldest_tick) {
                    oldest_tick = entry.value_ptr.*.last_used;
                    oldest_sid = entry.key_ptr.*;
                }
            }
            const sid = oldest_sid orelse return;
            const saved = self.saved_views.get(sid) orelse return;
            if (saved.pending) |pending|
                self.background_approvals.put(self.gpa, sid, pending) catch {};
            _ = self.saved_views.remove(sid);
            saved.deinit(self.gpa);
            self.gpa.destroy(saved);
        }
    }

    fn restoreSavedView(self: *App, saved: *SavedSessionView) void {
        self.copy_cursor = null;
        self.layout_epoch +%= 1;
        self.editor = saved.editor;
        self.blocks = saved.blocks;
        self.delta = saved.delta;
        self.reasoning_delta = saved.reasoning_delta;
        self.plan = saved.plan;
        self.state = saved.state;
        self.model = saved.model;
        self.effort = saved.effort;
        self.cwd = saved.cwd;
        self.tokens_in = saved.tokens_in;
        self.tokens_out = saved.tokens_out;
        self.context_used = saved.context_used;
        self.context_limit = saved.context_limit;
        self.plan_mode = saved.plan_mode;
        self.plan_proposal_ready = saved.plan_proposal_ready;
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
        self.turn_phase = saved.turn_phase;
        self.phase_started_ms = saved.phase_started_ms;
        self.call_started_ms = saved.call_started_ms;
        self.stream_bytes = saved.stream_bytes;
        self.stream_quiet_ms = saved.stream_quiet_ms;
        self.stream_status_at_ms = saved.stream_status_at_ms;
        self.last_seq = saved.last_seq;
        self.oldest_seq = saved.oldest_seq;
        self.history_complete = saved.history_complete;
        self.history_loading = false;
        self.history_before_seq = 0;
        self.history_page_failed = false;
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
            self.plan_mode = summary.plan_mode;
        }
        if (self.background_approvals.get(sid)) |pending| {
            self.pending = pending;
            _ = self.background_approvals.remove(sid);
        }
        // Server truth, per session — the FULL ACCESS badge must never
        // follow the App across tabs (a full A, default B switch used to
        // keep the badge lit).
        self.permissions_full = if (self.sessionSummary(sid)) |summary| summary.full_access else false;

        if (touch_recent) self.touchRecentSession(sid);
        self.syncAnimationTicker();
        if (self.last_seq == 0) {
            self.history_complete = false;
            self.history_loading = true;
            self.history_before_seq = 0;
            self.conn.send(.{ .sub = .{
                .sid = sid,
                .from_seq = 1,
                .tail_limit = initial_replay_blocks,
            } }) catch {};
        } else {
            self.conn.send(.{ .sub = .{
                .sid = sid,
                .from_seq = self.last_seq +| 1,
                .replay_limit = initial_replay_blocks,
            } }) catch {};
        }
        self.rememberSession(sid);
        var handle_buf: session_handle.Full = undefined;
        self.setNotice("session → {s}", .{self.displaySessionHandle(&handle_buf, sid)});
    }

    fn clearTranscriptForSearch(self: *App) void {
        self.clearHistoryBackfill();
        for (self.blocks.items) |*rendered| rendered.deinit(self.gpa);
        self.blocks.clearRetainingCapacity();
        self.delta.clearRetainingCapacity();
        self.reasoning_delta.clearRetainingCapacity();
        deinitPlan(self.gpa, &self.plan);
        self.layout_cache.reset(self.gpa);
        self.tail_layout_cache.reset(self.gpa);
        self.stream_layout_cache.reset(self.gpa);
        self.layout_epoch +%= 1;
        self.last_seq = 0;
        self.oldest_seq = 0;
        self.history_complete = false;
        self.history_loading = true;
        self.history_before_seq = 0;
        self.history_page_failed = false;
        self.scroll_up = 0;
        self.last_total_lines = 0;
        self.last_first_visible = 0;
        self.search_highlight_line = null;
        self.copy_cursor = null;
        self.sel_anchor = null;
    }

    fn jumpToSearchHit(self: *App, sid: u64, seq: u64) !void {
        if (sid == self.sid) {
            for (self.blocks.items) |rendered| {
                if (rendered.seq != seq) continue;
                self.search_target_seq = seq;
                self.search_highlight_line = null;
                var handle_buf: session_handle.Full = undefined;
                self.setNotice("match → {s}:{d}", .{ self.displaySessionHandle(&handle_buf, sid), seq });
                return;
            }
        }
        if (sid != self.sid) {
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
                self.plan_mode = summary.plan_mode;
            }
            if (self.background_approvals.get(sid)) |pending| {
                self.pending = pending;
                _ = self.background_approvals.remove(sid);
            }
            self.permissions_full = if (self.sessionSummary(sid)) |summary| summary.full_access else false;
            self.touchRecentSession(sid);
            self.syncAnimationTicker();
        } else {
            self.conn.send(.{ .unsub = .{ .sid = sid } }) catch {};
        }

        self.clearTranscriptForSearch();
        self.search_target_seq = seq;
        try self.conn.send(.{ .sub = .{
            .sid = sid,
            .tail_limit = initial_replay_blocks,
            .around_seq = seq,
        } });
        self.rememberSession(sid);
        var handle_buf: session_handle.Full = undefined;
        self.setNotice("match → {s}:{d}", .{ self.displaySessionHandle(&handle_buf, sid), seq });
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

    /// Move in the same chronological root-session order shown by the tab
    /// strip. This is deliberately separate from gt/gT, whose useful Vim-like
    /// contract is MRU navigation across every session (including children).
    fn cycleTab(self: *App, direction: i8) void {
        const active_root = self.rootSessionId(self.sid);
        const sid = nextRootTabSid(self.sessions.items, active_root, direction) orelse return;
        if (sid == self.sid) return;
        self.switchSession(sid, true) catch self.setNotice("could not switch tab", .{});
    }

    /// Option/Alt+N: jump straight to the Nth tab in the strip's
    /// chronological order (1-based), from any mode. From a focused child
    /// this also jumps to its own root (the highlighted tab).
    fn jumpToTab(self: *App, index: usize) void {
        const sid = rootTabSidAtIndex(self.sessions.items, index) orelse {
            self.setNotice("no tab {d}", .{index});
            return;
        };
        if (sid == self.sid) return;
        self.switchSession(sid, true) catch self.setNotice("could not switch tab", .{});
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
            var summary = self.allocSessionSummary(info) orelse continue;
            self.sessions.append(self.gpa, summary) catch {
                summary.deinit(self.gpa);
                continue;
            };
            self.session_labels.append(self.gpa, summary.label) catch {
                var removed = self.sessions.pop().?;
                removed.deinit(self.gpa);
                continue;
            };

            var known_recent = false;
            for (self.recent_sessions.items) |recent| {
                if (recent == info.sid) known_recent = true;
            }
            if (!known_recent) self.recent_sessions.append(self.gpa, info.sid) catch {};

            if (info.sid == self.sid) {
                self.state = info.state;
                self.plan_mode = info.plan_mode;
                if (!info.plan_mode) self.plan_proposal_ready = false;
            } else if (self.saved_views.get(info.sid)) |saved| {
                saved.state = info.state;
                saved.plan_mode = info.plan_mode;
                if (!info.plan_mode) saved.plan_proposal_ready = false;
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

        // session_watch omits archived sessions. Any inactive view absent
        // from the authoritative snapshot is unreachable UI state, so release
        // its transcript/editor allocations instead of retaining it forever.
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.gpa);
        var saved_it = self.saved_views.iterator();
        while (saved_it.next()) |entry| {
            var present = false;
            for (incoming) |info| {
                if (info.sid == entry.key_ptr.*) {
                    present = true;
                    break;
                }
            }
            if (!present) stale.append(self.gpa, entry.key_ptr.*) catch {};
        }
        for (stale.items) |sid| {
            const saved = self.saved_views.get(sid) orelse continue;
            _ = self.saved_views.remove(sid);
            saved.deinit(self.gpa);
            self.gpa.destroy(saved);
            _ = self.background_approvals.remove(sid);
        }
    }

    fn allocSessionSummary(self: *App, info: proto.SessionInfo) ?SessionSummary {
        const title = self.gpa.dupe(u8, info.title) catch return null;
        const cwd = self.gpa.dupe(u8, info.cwd) catch {
            self.gpa.free(title);
            return null;
        };
        const model = self.gpa.dupe(u8, info.model) catch {
            self.gpa.free(title);
            self.gpa.free(cwd);
            return null;
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
            return null;
        };
        return .{
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
            .full_access = info.full_access,
            .plan_mode = info.plan_mode,
        };
    }

    fn upsertSessionSummary(self: *App, info: proto.SessionInfo) void {
        self.rememberSession(info.sid);
        var summary = self.allocSessionSummary(info) orelse return;

        for (self.sessions.items, 0..) |*existing, i| {
            if (existing.sid != info.sid) continue;
            existing.deinit(self.gpa);
            existing.* = summary;
            self.session_labels.items[i] = summary.label;
            if (info.sid == self.sid) {
                self.state = info.state;
                self.setModelStr(info.model);
                self.permissions_full = info.full_access;
                self.plan_mode = info.plan_mode;
                if (!info.plan_mode) self.plan_proposal_ready = false;
            }
            if (self.saved_views.get(info.sid)) |saved| {
                saved.state = info.state;
                saved.plan_mode = info.plan_mode;
                if (!info.plan_mode) saved.plan_proposal_ready = false;
            }
            if (info.state != .awaiting_approval) _ = self.background_approvals.remove(info.sid);
            return;
        }

        var insert_at: usize = self.sessions.items.len;
        if (info.parent_sid) |parent_sid| {
            for (self.sessions.items, 0..) |existing, i| {
                if (existing.sid != parent_sid) continue;
                insert_at = i + 1;
                while (insert_at < self.sessions.items.len and self.sessions.items[insert_at].parent_sid != null) {
                    const sibling = self.sessions.items[insert_at];
                    if (info.created_at < sibling.created_at or
                        (info.created_at == sibling.created_at and info.sid < sibling.sid)) break;
                    insert_at += 1;
                }
                break;
            }
        } else {
            for (self.sessions.items, 0..) |existing, i| {
                if (existing.parent_sid != null) continue;
                if (info.created_at > existing.created_at or
                    (info.created_at == existing.created_at and info.sid > existing.sid))
                {
                    insert_at = i;
                    break;
                }
            }
        }
        self.sessions.insert(self.gpa, insert_at, summary) catch {
            summary.deinit(self.gpa);
            return;
        };
        self.session_labels.insert(self.gpa, insert_at, summary.label) catch {
            var removed = self.sessions.orderedRemove(insert_at);
            removed.deinit(self.gpa);
            return;
        };
        var known_recent = false;
        for (self.recent_sessions.items) |recent| if (recent == info.sid) {
            known_recent = true;
            break;
        };
        if (!known_recent) self.recent_sessions.append(self.gpa, info.sid) catch {};
        if (info.sid == self.sid) {
            self.state = info.state;
            self.plan_mode = info.plan_mode;
            if (!info.plan_mode) self.plan_proposal_ready = false;
        }
    }

    fn removeSessionSummary(self: *App, sid: u64) void {
        for (self.sessions.items, 0..) |*summary, i| {
            if (summary.sid != sid) continue;
            summary.deinit(self.gpa);
            _ = self.sessions.orderedRemove(i);
            _ = self.session_labels.orderedRemove(i);
            break;
        }
        var recent_i: usize = 0;
        while (recent_i < self.recent_sessions.items.len) {
            if (self.recent_sessions.items[recent_i] == sid)
                _ = self.recent_sessions.orderedRemove(recent_i)
            else
                recent_i += 1;
        }
        self.recent_cursor = 0;
        if (self.saved_views.get(sid)) |saved| {
            _ = self.saved_views.remove(sid);
            saved.deinit(self.gpa);
            self.gpa.destroy(saved);
        }
        _ = self.background_approvals.remove(sid);
    }

    fn currentInflightCall(self: *const App) ?InflightCall {
        return layout_mod.currentInflightCall(self.blocks.items);
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
        label: []const u8,
    ) void {
        const before = self.blocks.items.len;
        self.pushDurableBlock(b, .tool_result, text, label, status);
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

    fn pushInputEcho(
        self: *App,
        kind: block.BlockKind,
        text: []const u8,
        request_id: u64,
        prior_state: ?proto.SessionState,
    ) void {
        self.pushInputEchoLabel(kind, text, "", request_id, prior_state);
    }

    fn pushInputEchoLabel(
        self: *App,
        kind: block.BlockKind,
        text: []const u8,
        label: []const u8,
        request_id: u64,
        prior_state: ?proto.SessionState,
    ) void {
        const before = self.blocks.items.len;
        self.pushBlockPending(kind, text, label, .ok, true);
        if (self.blocks.items.len == before) return;
        const rendered = &self.blocks.items[self.blocks.items.len - 1];
        rendered.pending_request_id = request_id;
        rendered.pending_prior_state = prior_state;
    }

    fn acknowledgeInput(self: *App, request_id: u64) void {
        if (request_id == 0) return;
        if (acknowledgeInputInBlocks(self.blocks.items, request_id)) return;
        var it = self.saved_views.valueIterator();
        while (it.next()) |saved| {
            if (acknowledgeInputInBlocks(saved.*.blocks.items, request_id)) return;
        }
    }

    fn rejectInput(self: *App, request_id: u64) void {
        if (request_id == 0) return;
        if (rejectInputInBlocks(self.gpa, &self.blocks, request_id)) |rejected| {
            defer self.gpa.free(rejected.text);
            self.editor.pushHistory(rejected.text);
            if (self.editor.isEmpty()) self.editor.insertSlice(rejected.text);
            if (rejected.prior_state) |state| {
                self.state = state;
                self.releaseStreamingBuffers();
                self.stream_status_at_ms = 0;
                self.turn_started_ms = 0;
                self.turn_phase = .idle;
                self.phase_started_ms = 0;
                self.syncAnimationTicker();
            }
            self.restoreLatestUnfinishedPlan();
            self.layout_epoch +%= 1;
            return;
        }
        var it = self.saved_views.valueIterator();
        while (it.next()) |saved| {
            if (rejectInputInBlocks(self.gpa, &saved.*.blocks, request_id)) |rejected| {
                defer self.gpa.free(rejected.text);
                self.editor.pushHistory(rejected.text);
                if (rejected.prior_state) |state| saved.*.state = state;
                return;
            }
        }
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
                if (self.history_loading and self.history_before_seq > 0 and b.b.seq < self.history_before_seq) {
                    self.bufferOlderBlock(b.b);
                    return;
                }
                if (b.b.seq <= self.last_seq) return;
                if (self.oldest_seq == 0) {
                    self.oldest_seq = b.b.seq;
                    // Compatibility with an older daemon that ignores the
                    // tail request and performs a full replay without a
                    // replay_done marker.
                    if (b.b.seq == 1) {
                        self.history_complete = true;
                        if (self.history_before_seq == 0) self.history_loading = false;
                    }
                }
                self.last_seq = b.b.seq;
                self.applyBlock(b.b);
            },
            .replay_done => |replay| {
                if (replay.sid != self.sid) return;
                if (!replay.has_newer) {
                    if (replay.plan_pinned and hasUnfinishedPlan(replay.plan_items)) {
                        self.setPlan(replay.plan_items);
                    } else {
                        deinitPlan(self.gpa, &self.plan);
                    }
                }
                if (!replay.forward and replay.has_newer and replay.newest_seq > 0) {
                    if (replay.oldest_seq > 0) self.oldest_seq = replay.oldest_seq;
                    self.history_complete = !replay.has_older;
                    self.conn.send(.{ .sub = .{
                        .sid = self.sid,
                        .from_seq = replay.newest_seq +| 1,
                        .replay_limit = initial_replay_blocks,
                    } }) catch self.setNotice("could not continue session replay", .{});
                    return;
                }
                if (replay.forward) {
                    if (replay.has_newer and replay.newest_seq > 0) {
                        self.conn.send(.{ .sub = .{
                            .sid = self.sid,
                            .from_seq = replay.newest_seq +| 1,
                            .replay_limit = initial_replay_blocks,
                        } }) catch self.setNotice("could not continue session replay", .{});
                    } else {
                        self.history_loading = false;
                    }
                    return;
                }
                if (self.history_before_seq > 0) {
                    self.finishOlderHistoryPage(replay.oldest_seq, replay.has_older);
                    return;
                }
                if (replay.oldest_seq > 0) self.oldest_seq = replay.oldest_seq;
                self.history_complete = !replay.has_older;
                self.history_loading = false;
                self.history_before_seq = 0;
                if (self.scroll_up > 0) self.scroll_up = std.math.maxInt(usize);
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
                self.updateSessionSummaryState(s.sid, s.state);
                if (s.sid != self.sid) {
                    if (self.saved_views.get(s.sid)) |saved| {
                        saved.state = s.state;
                        if (s.phase) |phase| {
                            if (saved.turn_phase != phase) {
                                saved.phase_started_ms = nowWallMs(self.io);
                                if (phase == .provider) {
                                    saved.stream_bytes = 0;
                                    saved.stream_quiet_ms = 0;
                                    saved.stream_status_at_ms = 0;
                                }
                            }
                            saved.turn_phase = phase;
                        }
                        if (s.state == .idle or s.state == .err or s.state == .done) {
                            saved.turn_phase = .idle;
                            saved.phase_started_ms = 0;
                            saved.stream_bytes = 0;
                            saved.stream_quiet_ms = 0;
                            saved.stream_status_at_ms = 0;
                            saved.releaseStreamingBuffers(self.gpa);
                        }
                    }
                    return;
                }
                // Old daemons ignore tail_limit/replay_done and finish their
                // full replay with status. Recognize that safe fallback.
                if (self.history_loading and self.history_before_seq == 0 and self.oldest_seq <= 1) {
                    self.history_complete = true;
                    self.history_loading = false;
                }
                if (s.state == .running and self.state != .running) {
                    self.clearCompletedPlan();
                    self.spinner_frame = 0;
                    self.turn_started_ms = nowWallMs(self.io);
                    self.turn_phase = .starting;
                    self.phase_started_ms = self.turn_started_ms;
                }
                if (s.phase) |phase| {
                    if (self.turn_phase != phase) {
                        self.phase_started_ms = nowWallMs(self.io);
                        if (phase == .provider) {
                            self.stream_bytes = 0;
                            self.stream_quiet_ms = 0;
                            self.stream_status_at_ms = 0;
                        }
                    }
                    self.turn_phase = phase;
                }
                if (s.state != .running) {
                    self.stream_status_at_ms = 0;
                    self.turn_phase = .idle;
                    self.phase_started_ms = 0;
                }
                self.state = s.state;
                self.syncAnimationTicker();
                if (s.state != .awaiting_approval) self.pending = null;
                if (s.state == .idle or s.state == .err or s.state == .done)
                    self.releaseStreamingBuffers();
                // An error state never arrives bare: show its reason in the
                // notice slot (the transcript note holds the durable copy).
                if (s.state == .err) if (s.err_text) |text| if (text.len > 0)
                    self.setNotice("{s}", .{text});
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
            .session_created => |sc| self.handleSessionCreated(sc.sid, sc.request_id),
            .session_list_result => |sl| self.replaceSessionSummaries(sl.sessions),
            .input_history_result => |history| {
                // The daemon sends newest-first. Push oldest-first so the
                // editor's recency ordering and duplicate collapse agree.
                var i = history.entries.len;
                while (i > 0) {
                    i -= 1;
                    self.editor.pushHistory(history.entries[i].text);
                }
                if (self.history_search_active) self.refreshHistorySearch(true);
            },
            .search_result => |result| self.replaceSearchHits(result),
            .diagnostics_result => |report| {
                if (report.sid != self.sid) return;
                const rendered = formatDiagnostics(self.gpa, report) catch {
                    self.setNotice("could not render diagnostics", .{});
                    return;
                };
                defer self.gpa.free(rendered);
                self.pushBlock(.system_note, rendered, "diagnostics", .ok);
            },
            .otel_status_result => |status| self.setNotice(
                "OTLP {s}{s}",
                .{
                    if (status.enabled) @as([]const u8, "enabled") else "disabled",
                    if (status.content) @as([]const u8, " · content capture ON") else "",
                },
            ),
            .session_upsert => |su| self.upsertSessionSummary(su.session),
            .session_remove => |sr| self.removeSessionSummary(sr.sid),
            .interrupt_result => |result| {
                if (result.sid != self.sid) return;
                if (!result.active) {
                    self.setNotice("nothing to interrupt", .{});
                } else if (result.already_requested) {
                    self.setNotice("still cancelling · {s} · {d}s", .{
                        @tagName(result.phase),
                        result.pending_ms / 1000,
                    });
                } else {
                    self.setNotice("cancelling · {s} for {d}s", .{
                        @tagName(result.phase),
                        result.phase_ms / 1000,
                    });
                }
            },
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
            .setup_status_result => |status| self.applySetupStatus(status),
            .setup_result => |result| self.applySetupResult(result),
            .mcp_list_result => |result| self.showMcpStatus(result.servers),
            .ui_config_result => |result| {
                self.show_tab_bar = result.tab_bar;
                self.refresh_requested = true;
                self.setNotice("tab bar {s} (saved to config.toml)", .{onOff(result.tab_bar)});
            },
            .council_list_result => |result| self.applyCouncils(result.councils),
            .plan_clear_result => |result| {
                if (result.sid != self.sid) return;
                if (result.cleared) {
                    deinitPlan(self.gpa, &self.plan);
                    self.layout_epoch +%= 1;
                    self.setNotice("execution plan cleared", .{});
                } else {
                    self.setNotice("no unfinished execution plan", .{});
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
                self.rejectInput(e.request_id);
                self.setup_status_pending = false;
                if (self.setup_apply_pending) {
                    self.setup_apply_pending = false;
                    self.beginSetup(self.setup_required);
                }
                if (self.awaiting_new_session and e.request_id != 0 and e.request_id == self.pending_new_session_request_id) {
                    self.awaiting_new_session = false;
                    self.pending_new_session_request_id = 0;
                    self.pending_new_cwd.clearRetainingCapacity();
                }
                if (self.history_loading and std.mem.eql(u8, e.code, "request_failed")) {
                    self.clearHistoryBackfill();
                    self.history_loading = false;
                    self.history_before_seq = 0;
                    self.history_page_failed = false;
                }
                self.setNotice("daemon error {s}: {s}", .{ e.code, e.msg });
            },
            .ok => |ok| self.acknowledgeInput(ok.request_id),
            else => {},
        }
    }

    fn applyBlock(self: *App, b: block.Block) void {
        switch (b.body) {
            .user_msg => |u| {
                if (!u.synthetic and !isLegacyRehydration(u.text)) {
                    self.clearCompletedPlan();
                    self.plan_proposal_ready = false;
                }
                if (u.synthetic or isLegacyRehydration(u.text)) {
                    const label = rehydrationLabel(self.gpa, u.text) catch return;
                    defer self.gpa.free(label);
                    self.pushDurableBlock(b, .system_note, label, "", .ok);
                } else {
                    const label = if (u.attachments.len > 0)
                        layout_mod.mediaLabel(self.gpa, u.attachments) catch null
                    else
                        null;
                    defer if (label) |owned| self.gpa.free(owned);
                    if (!reconcilePendingEcho(self.blocks.items, .user_msg, u.text, b.seq, b.turn_id)) {
                        self.pushDurableBlock(b, .user_msg, u.text, label orelse "", .ok);
                    } else if (label) |owned| {
                        for (self.blocks.items) |*rendered| {
                            if (rendered.seq != b.seq) continue;
                            const replacement = self.gpa.dupe(u8, owned) catch return;
                            self.gpa.free(rendered.label);
                            rendered.label = replacement;
                            break;
                        }
                    }
                    // Seed input history from the log (replay covers pre-reboot
                    // messages; live blocks cover this session's submits).
                    self.editor.pushHistory(u.text);
                }
            },
            .steer => |s| {
                if (!reconcilePendingEcho(self.blocks.items, .steer, s.text, b.seq, b.turn_id))
                    self.pushDurableBlock(b, .steer, s.text, "", .ok);
                self.editor.pushHistory(s.text);
            },
            .assistant_msg => |a| {
                // Finalized text replaces the streaming delta.
                self.releaseStreamingBuffers();
                self.pushDurableBlock(b, .assistant_msg, a.text, "", .ok);
                if (self.plan_mode and !self.history_loading) self.plan_proposal_ready = true;
            },
            .reasoning => |r| {
                // Reasoning and progress commentary use distinct live streams
                // but the same durable card type. Clear whichever buffer this
                // finalized block exactly replaces.
                if (std.mem.eql(u8, self.reasoning_delta.items, r.text)) {
                    self.reasoning_delta.clearRetainingCapacity();
                } else if (std.mem.eql(u8, self.delta.items, r.text)) {
                    self.delta.clearRetainingCapacity();
                    self.stream_layout_cache.reset(self.gpa);
                }
                const before = self.blocks.items.len;
                self.pushDurableBlock(b, .reasoning, r.text, "", .ok);
                if (self.blocks.items.len > before)
                    self.blocks.items[self.blocks.items.len - 1].commentary = r.commentary;
            },
            .tool_call => |tc| {
                self.pushDurableBlock(b, .tool_call, tc.args_json, tc.name, .ok);
                // A call with nothing queued ahead of it starts immediately.
                if (self.currentInflightCall()) |cur| {
                    if (cur.queued == 0) self.call_started_ms = nowWallMs(self.io);
                }
            },
            .tool_result => |tr| {
                const label = if (tr.attachments.len > 0)
                    layout_mod.mediaLabel(self.gpa, tr.attachments) catch null
                else
                    null;
                defer if (label) |owned| self.gpa.free(owned);
                self.pushDurableToolResult(b, tr.inline_body, tr.status, tr.full_body_ref, label orelse "");
                self.call_started_ms = if (self.currentInflightCall() != null)
                    nowWallMs(self.io)
                else
                    0;
            },
            .approval => |ap| {
                const txt = if (ap.decision) |d| @tagName(d) else "pending";
                self.pushDurableBlock(b, .approval, txt, "", .ok);
            },
            .plan => |plan| {
                self.setPlan(plan.items);
                const rendered = allocDurableRenderBlock(self.gpa, b) catch return;
                if (rendered) |owned| {
                    self.blocks.append(self.gpa, owned) catch {
                        var orphan = owned;
                        orphan.deinit(self.gpa);
                    };
                }
                self.clearCompletedPlan();
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

    fn bufferOlderBlock(self: *App, b: block.Block) void {
        if (self.history_page_failed) return;
        if (self.history_backfill.items.len > 0 and
            self.history_backfill.items[self.history_backfill.items.len - 1].seq >= b.seq) return;
        const rendered = allocDurableRenderBlock(self.gpa, b) catch {
            self.history_page_failed = true;
            self.clearHistoryBackfill();
            return;
        } orelse return;
        self.history_backfill.append(self.gpa, rendered) catch {
            var owned = rendered;
            owned.deinit(self.gpa);
            self.history_page_failed = true;
            self.clearHistoryBackfill();
        };
    }

    fn finishOlderHistoryPage(self: *App, oldest_seq: u64, has_older: bool) void {
        defer {
            self.history_loading = false;
            self.history_before_seq = 0;
            self.history_page_failed = false;
        }
        if (self.history_page_failed) {
            self.clearHistoryBackfill();
            self.setNotice("could not load older history", .{});
            return;
        }

        const loaded = self.history_backfill.items.len;
        self.blocks.insertSlice(self.gpa, 0, self.history_backfill.items) catch {
            self.clearHistoryBackfill();
            self.setNotice("could not load older history", .{});
            return;
        };
        // Ownership moved into blocks; retain only the scratch allocation.
        self.history_backfill.items.len = 0;
        if (oldest_seq > 0) self.oldest_seq = oldest_seq;
        self.history_complete = !has_older;

        // History is bounded by Editor; rebuilding restores chronological
        // order now that older user messages were prepended.
        self.editor.clearHistory();
        for (self.blocks.items) |rendered| {
            if (rendered.kind == .user_msg) self.editor.pushHistory(rendered.text);
        }
        self.copy_cursor = null;
        self.sel_anchor = null;
        self.sel_dragging = false;
        self.layout_epoch +%= 1;
        self.layout_cache.reset(self.gpa);
        self.tail_layout_cache.reset(self.gpa);
        if (self.scroll_up > 0) self.scroll_up = std.math.maxInt(usize);
        self.setNotice("loaded {d} older blocks", .{loaded});
    }

    // -------------------------------------------------------- user input --

    fn submitInput(self: *App, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0 and self.attachments.items.len == 0) return;
        const may_quit_setup = std.mem.eql(u8, trimmed, "/quit") or std.mem.eql(u8, trimmed, "/q");
        if (self.setup_required and !may_quit_setup) {
            self.beginSetup(true);
            self.setNotice("choose a backend before sending the first prompt", .{});
            return;
        }
        if (trimmed.len > 0 and (trimmed[0] == '/' or trimmed[0] == '!')) {
            // Commands are client actions rather than durable user_msg
            // blocks, but they still belong in the local editor history so
            // Up then Enter can repeat them during this client lifetime.
            self.editor.pushHistory(trimmed);
            self.runCommand(trimmed);
            return;
        }
        const was_busy = self.state == .running or self.state == .awaiting_approval;
        if (was_busy and self.attachments.items.len > 0) {
            self.setNotice("images attach to a new turn; interrupt or wait before sending", .{});
            return;
        }
        var uploads_buf: [4]proto.AttachmentUpload = undefined;
        for (self.attachments.items, 0..) |attachment, i| uploads_buf[i] = .{
            .name = attachment.name,
            .mime = attachment.mime,
            .data_base64 = attachment.data_base64,
        };
        const uploads = uploads_buf[0..self.attachments.items.len];
        const attachment_label = pendingMediaLabel(self.gpa, self.attachments.items) catch null;
        defer if (attachment_label) |label| self.gpa.free(label);
        const request_id = self.next_input_request_id;
        self.next_input_request_id +%= 1;
        if (self.next_input_request_id == 0) self.next_input_request_id = 1;
        self.conn.send(.{ .input = .{
            .sid = self.sid,
            .text = trimmed,
            .request_id = request_id,
            .attachments = uploads,
        } }) catch |err| {
            if (err == error.ProtocolLineTooLong)
                self.setNotice("message exceeds the {d} MiB protocol limit", .{proto.max_line_bytes / (1024 * 1024)})
            else
                self.setNotice("send failed — daemon gone? ({t})", .{err});
            return;
        };
        self.clearAttachments();
        if (was_busy) {
            self.pushInputEcho(.steer, trimmed, request_id, null);
            self.setNotice("queued as steer for active turn", .{});
        } else {
            // The composer becomes a scrollback card immediately. The turn
            // thread's persisted user_msg will reconcile this local echo.
            self.clearCompletedPlan();
            self.pushInputEchoLabel(.user_msg, trimmed, attachment_label orelse "", request_id, self.state);
            self.state = .running;
            self.spinner_frame = 0;
            self.turn_started_ms = nowWallMs(self.io);
            self.turn_phase = .starting;
            self.phase_started_ms = self.turn_started_ms;
            self.syncAnimationTicker();
        }
        self.scroll_up = 0;
    }

    fn needsAnimationTick(self: *const App) bool {
        return self.state == .running or
            self.voice_rt.download != null or
            self.voice_rt.phase != .idle or
            self.ui_animation_active.load(.acquire);
    }

    fn syncAnimationTicker(self: *App) void {
        self.animation_active.store(self.needsAnimationTick(), .release);
    }

    fn startUiAnimation(self: *App, animation: UiAnimation) void {
        var seed_bytes: [8]u8 = undefined;
        self.io.random(&seed_bytes);
        self.ui_animation = animation;
        self.ui_animation_frame = 0;
        self.ui_animation_frames = matrixAnimationFrames(self.term_rows);
        self.ui_animation_seed = std.mem.readInt(u64, &seed_bytes, .little);
        self.ui_animation_active.store(true, .release);
        self.syncAnimationTicker();
    }

    fn tickUiAnimation(self: *App) void {
        if (self.ui_animation == .none) return;
        self.ui_animation_frame += 1;
        if (self.ui_animation_frame >= self.ui_animation_frames) {
            self.ui_animation = .none;
            self.ui_animation_frame = 0;
            self.ui_animation_active.store(false, .release);
            self.refresh_requested = true;
            self.syncAnimationTicker();
        }
    }

    fn runCommand(self: *App, cmd: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const head = it.next() orelse return;

        if (std.mem.eql(u8, head, "/quit") or std.mem.eql(u8, head, "/q")) {
            self.should_quit = true;
        } else if (std.mem.eql(u8, head, "/setup")) {
            self.requestSetup(false);
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
        } else if (std.mem.eql(u8, head, "/search")) {
            const query = std.mem.trim(u8, it.rest(), " \t\r\n");
            self.openSearchPrompt(0);
            if (query.len > 0) {
                self.picker_filter.appendSlice(self.gpa, query) catch {
                    self.picker = null;
                    self.setNotice("could not start search", .{});
                    return;
                };
                self.submitSearch();
            }
        } else if (std.mem.eql(u8, head, "/permissions")) {
            self.setPermissions(it.rest());
        } else if (std.mem.eql(u8, head, "/sandbox")) {
            self.toggleSandbox(it.rest());
        } else if (std.mem.eql(u8, head, "/network")) {
            self.networkCommand(it.rest());
        } else if (std.mem.eql(u8, head, "/mcp")) {
            const action = it.next();
            if (action == null) {
                self.conn.send(.{ .mcp_list = .{} }) catch {
                    self.setNotice("could not request MCP status", .{});
                };
            } else if (std.mem.eql(u8, action.?, "restart")) {
                const name = it.next() orelse {
                    self.setNotice("usage: /mcp restart <name>", .{});
                    return;
                };
                if (it.next() != null) {
                    self.setNotice("usage: /mcp restart <name>", .{});
                    return;
                }
                self.conn.send(.{ .mcp_restart = .{ .name = name } }) catch {
                    self.setNotice("could not restart MCP server", .{});
                };
            } else if (std.mem.eql(u8, action.?, "add")) {
                const name = it.next() orelse {
                    self.setNotice("usage: /mcp add <name> <command> [args...]", .{});
                    return;
                };
                var command: std.ArrayList([]const u8) = .empty;
                defer command.deinit(self.gpa);
                while (it.next()) |arg| command.append(self.gpa, arg) catch {
                    self.setNotice("could not allocate MCP command", .{});
                    return;
                };
                if (command.items.len == 0) {
                    self.setNotice("usage: /mcp add <name> <command> [args...]", .{});
                    return;
                }
                self.conn.send(.{ .mcp_add = .{ .name = name, .cmd = command.items } }) catch {
                    self.setNotice("could not add MCP server", .{});
                };
            } else if (std.mem.eql(u8, action.?, "remove")) {
                const name = it.next() orelse {
                    self.setNotice("usage: /mcp remove <name>", .{});
                    return;
                };
                if (it.next() != null) {
                    self.setNotice("usage: /mcp remove <name>", .{});
                    return;
                }
                self.conn.send(.{ .mcp_remove = .{ .name = name } }) catch {
                    self.setNotice("could not remove MCP server", .{});
                };
            } else if (std.mem.eql(u8, action.?, "reload") and it.next() == null) {
                self.conn.send(.{ .mcp_reload = .{} }) catch {
                    self.setNotice("could not reload MCP config", .{});
                };
            } else {
                self.setNotice("usage: /mcp [add <name> <command> [args...]|remove <name>|restart <name>|reload]", .{});
            }
        } else if (std.mem.eql(u8, head, "/council")) {
            const action = it.next();
            if (action == null or std.mem.eql(u8, action.?, "list")) {
                if (self.councils.items.len > 0)
                    self.openCouncilList()
                else
                    self.council_list_pending = true;
                self.conn.send(.{ .council_list = .{} }) catch {
                    self.council_list_pending = false;
                    self.setNotice("could not request councils", .{});
                };
            } else if (std.mem.eql(u8, action.?, "new") or std.mem.eql(u8, action.?, "edit")) {
                const name = it.next() orelse {
                    self.setNotice("usage: /council {s} <name>", .{action.?});
                    return;
                };
                if (it.next() != null) {
                    self.setNotice("usage: /council {s} <name>", .{action.?});
                    return;
                }
                if (std.mem.eql(u8, action.?, "new") and self.councilByName(name) != null) {
                    self.setNotice("council '{s}' already exists — use /council edit {s}", .{ name, name });
                    return;
                }
                self.openCouncilPicker(name);
            } else if (std.mem.eql(u8, action.?, "set") or std.mem.eql(u8, action.?, "add")) {
                const name = it.next() orelse {
                    self.setNotice("usage: /council set <name> <model...>", .{});
                    return;
                };
                var models: std.ArrayList([]const u8) = .empty;
                defer models.deinit(self.gpa);
                while (it.next()) |model| models.append(self.gpa, model) catch return;
                if (models.items.len == 0) {
                    self.setNotice("usage: /council set <name> <model...>", .{});
                    return;
                }
                self.council_notice_pending = true;
                self.conn.send(.{ .council_set = .{ .name = name, .models = models.items } }) catch {
                    self.setNotice("could not save council", .{});
                };
            } else if (std.mem.eql(u8, action.?, "remove") or std.mem.eql(u8, action.?, "delete")) {
                const name = it.next() orelse {
                    self.setNotice("usage: /council remove <name>", .{});
                    return;
                };
                self.council_notice_pending = true;
                self.conn.send(.{ .council_remove = .{ .name = name } }) catch {
                    self.setNotice("could not remove council", .{});
                };
            } else if (it.next() == null) {
                self.showCouncilDetail(action.?);
            } else {
                self.setNotice("usage: /council [<name>|new <name>|edit <name>|remove <name>]", .{});
            }
        } else if (std.mem.eql(u8, head, "/plan")) {
            const arg = std.mem.trim(u8, it.rest(), " \t");
            if (std.mem.eql(u8, arg, "clear")) {
                if (self.state == .running or self.state == .awaiting_approval) {
                    self.setNotice("cannot clear a plan mid-turn", .{});
                    return;
                }
                self.conn.send(.{ .plan_clear = .{ .sid = self.sid } }) catch {
                    self.setNotice("could not clear plan", .{});
                };
            } else if (std.mem.eql(u8, arg, "off")) {
                _ = self.setPlanMode(false);
            } else if (arg.len == 0) {
                _ = self.setPlanMode(true);
            } else if (self.setPlanMode(true)) {
                self.submitInput(arg);
            }
        } else if (std.mem.eql(u8, head, "/review")) {
            const name = it.next() orelse {
                self.setNotice("usage: /review <council> <question>", .{});
                return;
            };
            const question = std.mem.trim(u8, it.rest(), " \t");
            if (question.len == 0) {
                self.setNotice("usage: /review <council> <question>", .{});
                return;
            }
            const council = self.councilByName(name) orelse {
                if (self.councils.items.len == 0)
                    self.setNotice("no councils configured — /council new <name>", .{})
                else
                    self.setNotice("unknown council '{s}' — /council lists them", .{name});
                return;
            };
            if (proto.isGuestModel(self.model.items)) {
                self.setNotice("councils need a native session (guest sessions have no marlin tools)", .{});
                return;
            }
            const expanded = buildReviewPrompt(self.gpa, council, question) catch {
                self.setNotice("could not compose review prompt", .{});
                return;
            };
            defer self.gpa.free(expanded);
            self.submitInput(expanded);
        } else if (std.mem.eql(u8, head, "/voice")) {
            const action = it.next();
            if (action == null) {
                if (!self.voice_rt.enabled) self.startVoiceSetup() else self.voiceStatusNotice();
            } else if (std.mem.eql(u8, action.?, "setup")) {
                self.startVoiceSetup();
            } else if (std.mem.eql(u8, action.?, "off")) {
                if (self.voice_rt.setup) |st| {
                    const environ = self.environ orelse return;
                    config.setVoice(self.gpa, self.io, environ, false, st.engine.configName(), if (st.mode == .toggle) "toggle" else "ptt", st.model_path, st.stt_bin) catch {};
                }
                self.voice_rt.enabled = false;
                self.setNotice("voice off — /voice turns it back on", .{});
            } else if (std.mem.eql(u8, action.?, "on")) {
                if (self.voice_rt.setup) |st| {
                    const environ = self.environ orelse return;
                    config.setVoice(self.gpa, self.io, environ, true, st.engine.configName(), if (st.mode == .toggle) "toggle" else "ptt", st.model_path, st.stt_bin) catch {};
                    self.voice_rt.enabled = true;
                    self.voiceStatusNotice();
                } else self.startVoiceSetup();
            } else if (std.mem.eql(u8, action.?, "mode")) {
                const which = it.next() orelse {
                    self.setNotice("usage: /voice mode ptt|toggle", .{});
                    return;
                };
                const mode: voice.Mode = if (std.mem.eql(u8, which, "toggle")) .toggle else .ptt;
                if (self.voice_rt.setup) |*st| {
                    st.mode = mode;
                    const environ = self.environ orelse return;
                    config.setVoice(self.gpa, self.io, environ, self.voice_rt.enabled, st.engine.configName(), if (mode == .toggle) "toggle" else "ptt", st.model_path, st.stt_bin) catch {};
                    self.voiceStatusNotice();
                } else self.setNotice("voice is not set up — /voice setup first", .{});
            } else {
                self.setNotice("usage: /voice [setup|mode ptt|toggle|off|on]", .{});
            }
        } else if (std.mem.eql(u8, head, "/sessions")) {
            self.openPicker(.session);
        } else if (std.mem.eql(u8, head, "/new")) {
            self.newSession() catch {
                self.setNotice("could not create session", .{});
            };
        } else if (std.mem.eql(u8, head, "/rename")) {
            const title = std.mem.trim(u8, it.rest(), " \t");
            if (title.len == 0) {
                self.setNotice("usage: /rename <title>", .{});
                return;
            }
            self.conn.send(.{ .session_rename = .{ .sid = self.sid, .title = title } }) catch {
                self.setNotice("could not rename session", .{});
                return;
            };
            self.setNotice("renamed to {s}", .{title});
        } else if (std.mem.eql(u8, head, "/archive")) {
            const arg = it.rest();
            if (arg.len == 0) {
                self.archiveCurrentSession();
            } else if (std.mem.eql(u8, arg, "children")) {
                self.archiveFinishedChildren();
            } else {
                self.setNotice("usage: /archive [children]", .{});
            }
        } else if (std.mem.eql(u8, head, "/attach")) {
            self.attachPath(it.rest());
        } else if (std.mem.eql(u8, head, "!c")) {
            self.copyLastToolOutput();
        } else if (std.mem.eql(u8, head, "/reboot") or std.mem.eql(u8, head, "!rb")) {
            var rebuild: RebuildScope = if (std.mem.eql(u8, head, "!rb")) .attached else .none;
            var force = false;
            while (it.next()) |arg| {
                if (std.mem.eql(u8, arg, "--build")) {
                    rebuild = .attached;
                } else if (std.mem.eql(u8, arg, "--force")) {
                    force = true;
                } else if (std.mem.eql(u8, head, "!rb") and std.mem.eql(u8, arg, "client")) {
                    rebuild = .client;
                } else if (std.mem.eql(u8, head, "!rb") and std.mem.eql(u8, arg, "both")) {
                    rebuild = .both;
                } else {
                    if (std.mem.eql(u8, head, "!rb"))
                        self.setNotice("usage: !rb [client|both] [--force]", .{})
                    else
                        self.setNotice("usage: /reboot [--build] [--force]", .{});
                    return;
                }
            }
            if (self.state == .awaiting_approval and !force and rebuild != .client) {
                self.setNotice("approval pending — answer it, interrupt, or /reboot --force", .{});
                return;
            }
            if (self.state == .running and rebuild != .client) {
                self.setNotice("turn running — /reboot waits for it (interrupt first if you want force)", .{});
            }
            self.reboot_request = .{ .requested = true, .rebuild = rebuild, .force = force };
            self.should_quit = true;
        } else if (std.mem.eql(u8, head, "/compact")) {
            if (proto.isGuestModel(self.model.items)) {
                self.setNotice("guest agents manage their own context — /compact is native-only", .{});
                return;
            }
            if (self.state == .running or self.state == .awaiting_approval) {
                self.setNotice("cannot compact mid-turn", .{});
                return;
            }
            self.conn.send(.{ .session_compact = .{ .sid = self.sid } }) catch return;
            self.setNotice("compacting…", .{});
        } else if (std.mem.eql(u8, head, "/diagnostics")) {
            if (it.next() != null) {
                self.setNotice("usage: /diagnostics", .{});
                return;
            }
            self.conn.send(.{ .diagnostics = .{ .sid = self.sid } }) catch {
                self.setNotice("could not request diagnostics", .{});
            };
        } else if (std.mem.eql(u8, head, "/animate")) {
            const name = it.next() orelse {
                self.setNotice("usage: /animate matrix", .{});
                return;
            };
            if (it.next() != null or !std.mem.eql(u8, name, "matrix")) {
                self.setNotice("usage: /animate matrix", .{});
                return;
            }
            self.startUiAnimation(.matrix);
        } else if (std.mem.eql(u8, head, "/otel")) {
            self.otelCommand(it.next(), it.rest());
        } else if (std.mem.eql(u8, head, "/config")) {
            self.configCommand(it.next(), it.next());
        } else if (std.mem.eql(u8, head, "/help")) {
            self.setNotice("/setup · /sessions · /search [query] · /diagnostics · /animate matrix · /otel [set <endpoint>|status|off] · /new · /rename <title> · /archive [children] · /attach <image> · /model <m> · /effort <level> · /sandbox [on|off] · /permissions [full|default] · /network [on|off|status] · /mcp [add|remove|restart|reload] · /council · /review <name> <q> · /config [tabbar on|off] · /compact · /reboot [--build] [--force] · !rb [client|both] · !c · /quit", .{});
        } else {
            self.setNotice("unknown command {s} (try /help)", .{head});
        }
    }

    /// `/config` — the durable UI-preference surface. No args shows current
    /// values; `tabbar [on|off]` (bare = toggle) applies live and persists to
    /// config.toml, so the choice survives reboots and other clients.
    fn configCommand(self: *App, setting: ?[]const u8, value: ?[]const u8) void {
        const name = setting orelse {
            self.setNotice("config · tabbar {s} — /config tabbar [on|off]", .{onOff(self.show_tab_bar)});
            return;
        };
        if (!std.mem.eql(u8, name, "tabbar")) {
            self.setNotice("usage: /config tabbar [on|off]", .{});
            return;
        }
        const enable = if (value) |v| blk: {
            if (std.mem.eql(u8, v, "on") or std.mem.eql(u8, v, "true")) break :blk true;
            if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false")) break :blk false;
            self.setNotice("usage: /config tabbar [on|off]", .{});
            return;
        } else !self.show_tab_bar;
        self.show_tab_bar = enable;
        self.refresh_requested = true;
        self.conn.send(.{ .ui_set_tab_bar = .{ .enabled = enable } }) catch |err| {
            self.setNotice("tab bar {s} (not saved: {t})", .{ onOff(enable), err });
            return;
        };
        self.setNotice("tab bar {s} (saving…)", .{onOff(enable)});
    }

    fn showMcpStatus(self: *App, servers: []const proto.McpServerInfo) void {
        self.notice.clearRetainingCapacity();
        if (servers.len == 0) {
            self.notice.appendSlice(self.gpa, "MCP · no servers configured") catch {};
            return;
        }
        self.notice.appendSlice(self.gpa, "MCP · ") catch return;
        for (servers, 0..) |server, i| {
            if (i > 0) self.notice.appendSlice(self.gpa, " · ") catch return;
            if (server.ready) {
                self.notice.print(self.gpa, "{s} ✓ {d} tools", .{ server.name, server.tool_count }) catch return;
            } else {
                const message = server.error_message orelse "unavailable";
                self.notice.print(self.gpa, "{s} ✗ {s}", .{ server.name, message[0..@min(message.len, 96)] }) catch return;
            }
        }
    }

    fn clearCouncilEdit(self: *App) void {
        self.council_edit_name.clearRetainingCapacity();
        for (self.council_edit_models.items) |model| self.gpa.free(model);
        self.council_edit_models.clearRetainingCapacity();
    }

    fn clearCouncils(self: *App) void {
        for (self.councils.items) |*council| council.deinit(self.gpa);
        self.councils.clearRetainingCapacity();
    }

    fn applyCouncils(self: *App, councils: []const proto.CouncilInfo) void {
        self.clearCouncils();
        for (councils) |info| {
            var owned = OwnedCouncil{ .name = self.gpa.dupe(u8, info.name) catch return };
            for (info.models) |model| {
                const copy = self.gpa.dupe(u8, model) catch break;
                owned.models.append(self.gpa, copy) catch {
                    self.gpa.free(copy);
                    break;
                };
            }
            self.councils.append(self.gpa, owned) catch {
                owned.deinit(self.gpa);
                return;
            };
        }
        if (self.council_list_pending) {
            self.council_list_pending = false;
            self.openCouncilList();
        } else if (self.picker_kind == .council_list and self.picker != null and self.councils.items.len == 0) {
            self.picker = null;
            self.picker_filter.clearRetainingCapacity();
            self.setNotice("no councils configured — /council new <name>", .{});
        }
        if (self.council_detail_name.items.len > 0 and self.councilByName(self.council_detail_name.items) == null) {
            self.closeCouncilDetail();
            self.setNotice("that council no longer exists", .{});
        }
        if (!self.council_notice_pending) return;
        self.council_notice_pending = false;
        self.notice.clearRetainingCapacity();
        if (self.councils.items.len == 0) {
            self.notice.appendSlice(self.gpa, "councils · none — /council new <name>") catch {};
            return;
        }
        self.notice.appendSlice(self.gpa, "councils · ") catch return;
        for (self.councils.items, 0..) |council, i| {
            if (i > 0) self.notice.appendSlice(self.gpa, " · ") catch return;
            self.notice.print(self.gpa, "{s} ({d} models)", .{ council.name, council.models.items.len }) catch return;
        }
    }

    fn councilByName(self: *const App, name: []const u8) ?*const OwnedCouncil {
        for (self.councils.items) |*council| {
            if (std.mem.eql(u8, council.name, name)) return council;
        }
        return null;
    }

    // ------------------------------------------------------------ voice --

    /// Resolve [voice] config into a runnable runtime, silently: a broken
    /// or absent setup leaves voice dormant with zero noise — dependencies
    /// are only ever mentioned inside /voice itself.
    fn initVoiceFromConfig(self: *App) void {
        const cfg = self.cfg;
        if (!cfg.voice_enabled) return;
        const engine = voice.Engine.parse(cfg.voice_engine) orelse return;
        if (cfg.voice_stt_bin.len == 0) return;
        const environ = self.environ orelse return;
        const ffmpeg = (voice.findBinary(self.gpa, self.io, environ, &.{"ffmpeg"}) catch null) orelse return;
        const model = self.gpa.dupe(u8, cfg.voice_model) catch {
            self.gpa.free(ffmpeg);
            return;
        };
        const bin = self.gpa.dupe(u8, cfg.voice_stt_bin) catch {
            self.gpa.free(ffmpeg);
            self.gpa.free(model);
            return;
        };
        self.voice_rt.ffmpeg = ffmpeg;
        self.voice_rt.setup = .{
            .engine = engine,
            .mode = if (std.mem.eql(u8, cfg.voice_mode, "toggle")) .toggle else .ptt,
            .model_path = model,
            .stt_bin = bin,
        };
        self.voice_rt.enabled = true;
    }

    fn voiceStatusNotice(self: *App) void {
        const rt = &self.voice_rt;
        if (!rt.enabled or rt.setup == null) {
            self.setNotice("voice is not set up — /voice setup walks through it (local, offline)", .{});
            return;
        }
        const st = rt.setup.?;
        self.setNotice("voice · {s} · {s} · ctrl+space{s} · /voice [setup|mode ptt|toggle|off]", .{
            st.engine.configName(),
            if (st.mode == .ptt) "push-to-talk" else "toggle",
            if (st.mode == .ptt and !rt.kitty_release) " (terminal lacks key-release: acting as toggle)" else "",
        });
    }

    fn startVoiceSetup(self: *App) void {
        const environ = self.environ orelse return;
        // The only place dependencies are ever mentioned.
        const ffmpeg = (voice.findBinary(self.gpa, self.io, environ, &.{"ffmpeg"}) catch null) orelse {
            self.setNotice("voice needs ffmpeg for the microphone — `brew install ffmpeg`, then /voice setup again", .{});
            return;
        };
        if (self.voice_rt.ffmpeg) |old| self.gpa.free(old);
        self.voice_rt.ffmpeg = ffmpeg;
        self.voice_rt.wiz_engine = null;
        self.voice_rt.wiz_mode = null;
        self.openPicker(.voice_engine);
    }

    fn voiceWizardEngineChosen(self: *App, item: []const u8) void {
        const environ = self.environ orelse return;
        var chosen: ?voice.Engine = null;
        for (voice_engine_items, 0..) |label, i| {
            if (std.mem.eql(u8, label, item)) chosen = voice_engines[i];
        }
        const engine = chosen orelse return;
        const bin = (voice.findBinary(self.gpa, self.io, environ, engine.binaryCandidates()) catch null) orelse {
            self.setNotice("voice: {s} needs `{s}` — install it, then /voice setup again", .{
                engine.configName(), engine.installHint(),
            });
            return;
        };
        if (self.voice_rt.wiz_stt_bin) |old| self.gpa.free(old);
        self.voice_rt.wiz_stt_bin = bin;
        self.voice_rt.wiz_engine = engine;
        self.openPicker(.voice_mode);
    }

    fn voiceWizardModeChosen(self: *App, item: []const u8) void {
        const rt = &self.voice_rt;
        const engine = rt.wiz_engine orelse return;
        rt.wiz_mode = if (std.mem.startsWith(u8, item, "toggle")) .toggle else .ptt;
        if (rt.wiz_mode == .ptt and !rt.kitty_release)
            self.setNotice("this terminal doesn't report key releases — ctrl+space will act as a toggle here", .{});

        if (engine.modelUrl() == null) {
            self.finishVoiceSetup("");
            return;
        }
        const environ = self.environ orelse return;
        const dir = voice.modelsDir(self.gpa, environ) catch return;
        defer self.gpa.free(dir);
        const dest = std.fs.path.join(self.gpa, &.{ dir, engine.modelFileName().? }) catch return;
        if (Io.Dir.cwd().statFile(self.io, dest, .{})) |_| {
            defer self.gpa.free(dest);
            self.finishVoiceSetup(dest);
            return;
        } else |_| {}

        // Model download with live progress (rendered from voiceTick).
        const progress = self.gpa.create(voice.DownloadProgress) catch {
            self.gpa.free(dest);
            return;
        };
        progress.* = .{};
        const job = self.gpa.create(VoiceDownloadJob) catch {
            self.gpa.destroy(progress);
            self.gpa.free(dest);
            return;
        };
        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .loop = self.loop orelse return,
            .url = engine.modelUrl().?,
            .dest = dest,
            .progress = progress,
        };
        if (rt.wiz_model_dest) |old| self.gpa.free(old);
        rt.wiz_model_dest = self.gpa.dupe(u8, dest) catch null;
        rt.download = progress;
        rt.rate_bytes = 0;
        rt.rate_at_ms = 0;
        rt.rate_bps = 0;
        rt.download_thread = std.Thread.spawn(.{}, VoiceDownloadJob.run, .{job}) catch {
            self.gpa.destroy(progress);
            rt.download = null;
            self.setNotice("voice: could not start the model download", .{});
            return;
        };
        self.syncAnimationTicker();
        self.setNotice("voice: downloading {s}…", .{engine.modelFileName().?});
    }

    fn finishVoiceSetup(self: *App, model_path: []const u8) void {
        const rt = &self.voice_rt;
        const engine = rt.wiz_engine orelse return;
        const mode = rt.wiz_mode orelse .ptt;
        const environ = self.environ orelse return;
        const bin = rt.wiz_stt_bin orelse return;

        config.setVoice(
            self.gpa,
            self.io,
            environ,
            true,
            engine.configName(),
            if (mode == .toggle) "toggle" else "ptt",
            model_path,
            bin,
        ) catch {
            self.setNotice("voice: could not persist [voice] to config.toml", .{});
            return;
        };

        rt.freeSetup(self.gpa);
        const model = self.gpa.dupe(u8, model_path) catch return;
        const bin_copy = self.gpa.dupe(u8, bin) catch {
            self.gpa.free(model);
            return;
        };
        rt.setup = .{ .engine = engine, .mode = mode, .model_path = model, .stt_bin = bin_copy };
        rt.enabled = true;
        rt.wiz_engine = null;
        rt.wiz_mode = null;
        self.setNotice("voice ready · {s} ctrl+space to dictate into the composer", .{
            if (mode == .ptt and rt.kitty_release) "hold" else "press",
        });
    }

    /// Download progress → status notice, driven by animation ticks. A
    /// dedicated modal would be prettier; the status line is honest and
    /// already everywhere.
    fn voiceTick(self: *App) void {
        const rt = &self.voice_rt;
        const progress = rt.download orelse return;
        const done = progress.done.load(.acquire);
        const total = progress.total.load(.acquire);
        const now = nowWallMs(self.io);
        if (rt.rate_at_ms == 0) {
            rt.rate_at_ms = now;
            rt.rate_bytes = done;
        } else if (now - rt.rate_at_ms >= 1000) {
            rt.rate_bps = (done -| rt.rate_bytes) * 1000 / @as(u64, @intCast(now - rt.rate_at_ms));
            rt.rate_at_ms = now;
            rt.rate_bytes = done;
        }
        var bar: [24]u8 = undefined;
        const cells = bar.len;
        const filled = if (total > 0) @min(cells, done * cells / total) else 0;
        for (0..cells) |i| bar[i] = if (i < filled) '#' else '-';
        if (total > 0) {
            self.setNotice("voice model  [{s}] {d}% · {d}/{d} MB · {d:.1} MB/s · esc cancels", .{
                bar[0..],                                                 done * 100 / total, done >> 20, total >> 20,
                @as(f64, @floatFromInt(rt.rate_bps)) / (1024.0 * 1024.0),
            });
        } else {
            self.setNotice("voice model  [{s}] {d} MB · esc cancels", .{ bar[0..], done >> 20 });
        }
    }

    fn voiceDownloadFinished(self: *App, failure: ?[]const u8) void {
        const rt = &self.voice_rt;
        if (rt.download_thread) |t| t.join();
        rt.download_thread = null;
        if (rt.download) |pr| self.gpa.destroy(pr);
        rt.download = null;
        self.syncAnimationTicker();
        if (failure) |name| {
            self.setNotice("voice: model download failed ({s}) — /voice setup resumes it", .{name});
            return;
        }
        const dest = rt.wiz_model_dest orelse return;
        self.finishVoiceSetup(dest);
    }

    fn voiceCancelDownload(self: *App) void {
        const rt = &self.voice_rt;
        const progress = rt.download orelse return;
        progress.cancel.store(true, .release);
        // The worker notices and posts download_failed(Cancelled); the .part
        // file stays for the next /voice setup to resume.
    }

    fn startVoiceRecording(self: *App) void {
        const rt = &self.voice_rt;
        if (rt.phase != .idle or !rt.enabled) return;
        const setup = rt.setup orelse return;
        _ = setup;
        const ffmpeg = rt.ffmpeg orelse return;
        var nonce: [4]u8 = undefined;
        self.io.random(&nonce);
        const tmp = (self.environ orelse return).get("TMPDIR") orelse "/tmp";
        const wav = std.fmt.allocPrint(self.gpa, "{s}/marlin-voice-{x}.wav", .{
            std.mem.trimEnd(u8, tmp, "/"), std.mem.readInt(u32, &nonce, .little),
        }) catch return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const argv = voice.recordArgv(arena_state.allocator(), ffmpeg, wav) catch {
            self.gpa.free(wav);
            return;
        };
        const child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch {
            self.gpa.free(wav);
            self.setNotice("voice: could not start recording (microphone permission?)", .{});
            return;
        };
        rt.recorder = child;
        rt.wav_path = wav;
        rt.phase = .recording;
        rt.record_started_ms = nowWallMs(self.io);
        // Keep ticks flowing so the status bar's elapsed counter is live.
        self.syncAnimationTicker();
        self.prewarmVoiceModel();
        self.setNotice("● recording — {s}", .{if (rt.setup.?.mode == .ptt and rt.kitty_release) "release to transcribe" else "ctrl+space to stop"});
    }

    /// While the user is talking, pull the model through the page cache so
    /// the transcriber starts hot. Rate-limited: a cached re-read is cheap
    /// but not free, and one warm pass a minute keeps residency fresh.
    fn prewarmVoiceModel(self: *App) void {
        const rt = &self.voice_rt;
        const setup = rt.setup orelse return;
        if (setup.model_path.len == 0) return;
        const now = nowWallMs(self.io);
        if (rt.prewarm_at_ms != 0 and now - rt.prewarm_at_ms < 60_000) return;
        rt.prewarm_at_ms = now;
        const job = self.gpa.create(VoicePrewarmJob) catch return;
        const path = self.gpa.dupe(u8, setup.model_path) catch {
            self.gpa.destroy(job);
            return;
        };
        job.* = .{ .gpa = self.gpa, .io = self.io, .path = path };
        const thread = std.Thread.spawn(.{}, VoicePrewarmJob.run, .{job}) catch {
            self.gpa.free(path);
            self.gpa.destroy(job);
            return;
        };
        thread.detach();
    }

    fn stopVoiceRecording(self: *App) void {
        const rt = &self.voice_rt;
        if (rt.phase != .recording) return;
        const setup = rt.setup orelse return;
        // SIGINT lets ffmpeg finalize the wav header.
        if (rt.recorder) |recorder| {
            if (recorder.id) |pid| std.posix.kill(pid, std.posix.SIG.INT) catch {};
        }
        const job = self.gpa.create(VoiceJob) catch return;
        job.* = .{
            .gpa = self.gpa,
            .io = self.io,
            .loop = self.loop orelse return,
            .recorder = rt.recorder,
            .wav_path = rt.wav_path.?,
            .setup = setup,
        };
        rt.recorder = null;
        rt.wav_path = null;
        rt.phase = .transcribing;
        self.setNotice("… transcribing", .{});
        const thread = std.Thread.spawn(.{}, VoiceJob.run, .{job}) catch {
            self.gpa.destroy(job);
            rt.phase = .idle;
            self.syncAnimationTicker();
            return;
        };
        thread.detach();
    }

    fn abortVoiceRecording(self: *App) void {
        const rt = &self.voice_rt;
        if (rt.phase != .recording) return;
        if (rt.recorder) |*recorder| {
            recorder.kill(self.io);
            _ = recorder.wait(self.io) catch {};
        }
        rt.recorder = null;
        if (rt.wav_path) |wav| {
            Io.Dir.cwd().deleteFile(self.io, wav) catch {};
            self.gpa.free(wav);
        }
        rt.wav_path = null;
        rt.phase = .idle;
        self.syncAnimationTicker();
        self.setNotice("voice: recording discarded", .{});
    }

    fn handleVoiceEvent(self: *App, ev: VoiceEvent) void {
        switch (ev) {
            .transcript => |text| {
                defer self.gpa.free(text);
                self.voice_rt.phase = .idle;
                self.syncAnimationTicker();
                if (text.len == 0) {
                    self.setNotice("voice: heard nothing", .{});
                    return;
                }
                if (!self.editor.isEmpty()) self.editor.insertSlice(" ");
                self.editor.insertSlice(text);
                self.mode = .insert;
                self.setNotice("voice: {d} chars — review, then enter", .{text.len});
            },
            .stt_failed => |name| {
                self.voice_rt.phase = .idle;
                self.syncAnimationTicker();
                self.setNotice("voice: transcription failed ({s})", .{name});
            },
            .download_done => self.voiceDownloadFinished(null),
            .download_failed => |name| self.voiceDownloadFinished(name),
        }
    }

    /// The ctrl+space press in either mode. Returns true when consumed.
    fn handleVoiceKey(self: *App) bool {
        const rt = &self.voice_rt;
        if (!rt.enabled or rt.setup == null) return false;
        switch (rt.phase) {
            .transcribing => return true, // swallow until the verdict lands
            .recording => {
                // Toggle stop; under PTT this is the repeat/no-release path.
                if (rt.setup.?.mode == .toggle or !rt.kitty_release) self.stopVoiceRecording();
                return true;
            },
            .idle => {
                self.startVoiceRecording();
                return true;
            },
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

    const ToolResultSource = struct { name: []const u8, arg: ?[]const u8 };

    /// Which call produced the tool_result at `idx`. Results persist in
    /// call order within a turn, so the k-th result pairs with the turn's
    /// k-th call (the same positional invariant scanToolBatch folds by).
    fn toolResultSource(self: *const App, idx: usize) ToolResultSource {
        const turn_id = self.blocks.items[idx].turn_id;
        var start = idx;
        while (start > 0 and self.blocks.items[start - 1].turn_id == turn_id) start -= 1;
        var result_ord: usize = 0;
        for (self.blocks.items[start..idx]) |rb| {
            if (rb.kind == .tool_result) result_ord += 1;
        }
        var seen: usize = 0;
        for (self.blocks.items[start..]) |rb| {
            if (rb.kind != .tool_call) continue;
            if (seen == result_ord) return .{
                .name = toolDisplayName(rb.label),
                .arg = toolDisplayArg(rb.label, rb.text, self.cwd.items),
            };
            seen += 1;
        }
        return .{ .name = "tool", .arg = null };
    }

    /// Stage the human-readable copy source for the frame-loop notice.
    fn setClipboardDesc(self: *App, src: ToolResultSource) void {
        const max_arg = 48;
        self.clipboard_desc.clearRetainingCapacity();
        self.clipboard_desc.appendSlice(self.gpa, src.name) catch return;
        const arg = src.arg orelse return;
        if (arg.len == 0) return;
        self.clipboard_desc.append(self.gpa, ' ') catch return;
        self.clipboard_desc.appendSlice(self.gpa, arg[0..@min(arg.len, max_arg)]) catch return;
        if (arg.len > max_arg) self.clipboard_desc.appendSlice(self.gpa, "…") catch return;
    }

    fn copyLastToolOutput(self: *App) void {
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const rendered = self.blocks.items[i];
            if (rendered.kind != .tool_result) continue;
            // The result may be folded out of view ("Ran N commands"), so
            // name its source; a silent copy of invisible bytes reads as
            // clipboard corruption.
            self.setClipboardDesc(self.toolResultSource(i));
            if (rendered.full_body_ref) |ref| {
                self.conn.send(.{ .blob_get = .{ .hash = ref } }) catch {
                    self.setNotice("could not request full tool output", .{});
                    return;
                };
                self.setNotice("fetching full output of {s}…", .{self.clipboard_desc.items});
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

    /// Sticky prompt rows and their separator are decorative duplicates of
    /// durable transcript lines. Mouse/copy coordinates map only the
    /// contiguous body below them; the original prompt remains selectable
    /// through ordinary scrollback.
    fn visibleLineAtRow(self: *const App, row: usize) ?usize {
        if (row >= self.last_view_h) return null;
        if (self.last_pinned_rows == 0 and self.last_body_rows == 0) {
            const line = self.last_first_visible + row;
            return if (line < self.last_total_lines) line else null;
        }
        if (row < self.last_pinned_rows) return null;
        const body_row = row - self.last_pinned_rows;
        if (body_row < self.last_body_rows)
            return self.last_body_first + body_row;
        return null;
    }

    fn lineVisible(self: *const App, line: usize) bool {
        if (self.last_pinned_rows == 0 and self.last_body_rows == 0)
            return line < self.last_total_lines and
                line >= self.last_first_visible and line < self.last_first_visible + self.last_view_h;
        return line >= self.last_body_first and line < self.last_body_first + self.last_body_rows;
    }

    /// Enter transcript copy mode with the cursor on the bottom visible line.
    fn enterCopyMode(self: *App) void {
        if (self.last_total_lines == 0) return;
        var row = self.last_view_h;
        while (row > 0) {
            row -= 1;
            if (self.visibleLineAtRow(row)) |line| {
                self.copy_cursor = .{ .line = line, .col = 0 };
                self.copy_linewise = false;
                self.setNotice("copy mode · hjkl move · v/V select · y yank · Esc exit", .{});
                return;
            }
        }
    }

    /// Keep the copy cursor inside the visible window by adjusting scroll_up
    /// (geometry from the previous frame; draw clamps the rest).
    fn followCopyCursor(self: *App) void {
        const cursor = self.copy_cursor orelse return;
        if (self.lineVisible(cursor.line)) return;
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

    /// Clamp the cursor into the (possibly non-contiguous) visible view.
    fn clampCopyCursorToView(self: *App) void {
        var cursor = self.copy_cursor orelse return;
        if (self.lineVisible(cursor.line)) return;
        if (self.last_view_h == 0) return;
        const first = self.visibleLineAtRow(0) orelse return;
        const last = self.visibleLineAtRow(self.last_view_h - 1) orelse first;
        cursor.line = if (cursor.line < first) first else last;
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
            self.maybeRequestHistoryAtTop();
            return;
        } else return;
        self.copy_cursor = cursor;
        if (self.sel_anchor != null) self.updateCopySelection(cursor);
        self.followCopyCursor();
        self.maybeRequestHistoryAtTop();
    }

    fn selection(self: *const App) ?Selection {
        const a = self.sel_anchor orelse return null;
        return Selection.init(a, self.sel_head);
    }

    fn openPicker(self: *App, kind: PickerKind) void {
        self.picker_kind = kind;
        self.picker = 0;
        self.picker_filter.clearRetainingCapacity();
        if (kind == .council) return;
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

    fn clearSetupDraft(self: *App) void {
        if (self.setup_prompt != .none) self.editor.clearSensitive();
        self.setup_prompt = .none;
        self.setup_provider = null;
        self.setup_provider_name.clearRetainingCapacity();
        self.setup_base_url.clearRetainingCapacity();
        self.setup_api_key_env.clearRetainingCapacity();
        if (self.setup_credential.items.len > 0) @memset(self.setup_credential.items, 0);
        self.setup_credential.clearRetainingCapacity();
    }

    fn requestSetup(self: *App, required: bool) void {
        if (self.setup_status_pending or self.setup_apply_pending) return;
        self.setup_required = self.setup_required or required;
        if (required) self.setup_replace_empty_session = true;
        self.setup_status_pending = true;
        self.conn.send(.{ .setup_status = .{} }) catch {
            self.setup_status_pending = false;
            self.setNotice("could not query provider setup", .{});
        };
    }

    fn beginSetup(self: *App, required: bool) void {
        self.clearSetupDraft();
        self.setup_required = self.setup_required or required;
        if (required) self.setup_replace_empty_session = true;
        self.openPicker(.setup_provider);
        self.setNotice("choose how Marlin should run models · keys are saved by the daemon host", .{});
    }

    fn applySetupStatus(self: *App, status: proto.SetupStatus) void {
        self.setup_readiness = .fromWire(status);
        if (!self.setup_status_pending) return;
        self.setup_status_pending = false;
        self.beginSetup(self.setup_required);
    }

    fn setupProviderFromItem(item: []const u8) ?SetupProvider {
        for (setup_provider_items, 0..) |candidate, index| {
            if (std.mem.eql(u8, item, candidate)) return @enumFromInt(index);
        }
        return null;
    }

    fn setupProviderReady(self: *const App, provider: SetupProvider) bool {
        return switch (provider) {
            .openrouter => self.setup_readiness.openrouter_ready,
            .codex => self.setup_readiness.codex_authenticated,
            .claude_code => self.setup_readiness.claude_code_authenticated,
            .vercel => self.setup_readiness.vercel_ready,
            .anthropic => self.setup_readiness.anthropic_ready,
            .litellm => self.setup_readiness.litellm_ready,
            .local => self.setup_readiness.local_ready,
            .custom => false,
        };
    }

    fn setupProviderNote(self: *const App, item: []const u8) []const u8 {
        const provider = setupProviderFromItem(item) orelse return "";
        if (self.setupProviderReady(provider)) return switch (provider) {
            .codex, .claude_code => "  ✓ signed in",
            .local => "  ✓ configured",
            else => "  ✓ key found",
        };
        return switch (provider) {
            .codex => if (self.setup_readiness.codex_available) "  · login needed" else "  · not installed",
            .claude_code => if (self.setup_readiness.claude_code_available) "  · login needed" else "  · not installed",
            .custom => "",
            else => "  · setup needed",
        };
    }

    fn setSetupBuffer(self: *App, buffer: *std.ArrayList(u8), value: []const u8) bool {
        buffer.clearRetainingCapacity();
        buffer.appendSlice(self.gpa, value) catch {
            self.setNotice("could not continue provider setup", .{});
            return false;
        };
        return true;
    }

    fn startSetupPrompt(self: *App, prompt: SetupPrompt, initial: []const u8, notice: []const u8) void {
        self.picker = null;
        self.picker_filter.clearRetainingCapacity();
        self.setup_prompt = prompt;
        self.mode = .insert;
        self.editor.replaceText(initial);
        self.setNotice("{s}", .{notice});
    }

    fn setupProviderChosen(self: *App, item: []const u8) void {
        const provider = setupProviderFromItem(item) orelse return;
        self.clearSetupDraft();
        self.setup_provider = provider;
        switch (provider) {
            .codex => {
                if (!self.setup_readiness.codex_available) {
                    self.openPicker(.setup_provider);
                    self.setNotice("Codex is not installed on the daemon host · install it, then retry /setup", .{});
                    return;
                }
                if (!self.setup_readiness.codex_authenticated) {
                    self.openPicker(.setup_provider);
                    self.setNotice("Codex guest needs a ChatGPT session · run `codex login` on the daemon host, then /setup", .{});
                    return;
                }
                self.finishSetup("codex/default");
            },
            .claude_code => {
                if (!self.setup_readiness.claude_code_available) {
                    self.openPicker(.setup_provider);
                    self.setNotice("Claude Code is not installed on the daemon host · install it, then retry /setup", .{});
                    return;
                }
                if (!self.setup_readiness.claude_code_authenticated) {
                    self.openPicker(.setup_provider);
                    self.setNotice("Claude Code needs a login · run `claude auth login` on the daemon host, then /setup", .{});
                    return;
                }
                self.finishSetup("claudecode/default");
            },
            .openrouter => {
                if (!self.setSetupBuffer(&self.setup_provider_name, "openrouter")) return;
                if (!self.setSetupBuffer(&self.setup_base_url, "https://openrouter.ai/api/v1")) return;
                if (!self.setSetupBuffer(&self.setup_api_key_env, "OPENROUTER_API_KEY")) return;
                if (self.setup_readiness.openrouter_ready)
                    self.startSetupPrompt(.model, "openrouter/anthropic/claude-sonnet-4.5", "choose a registry model id · Enter accepts the suggested model")
                else
                    self.startSetupPrompt(.credential, "", "paste an OpenRouter API key · input is masked · Esc goes back");
            },
            .vercel => {
                if (!self.setSetupBuffer(&self.setup_provider_name, "vercel")) return;
                if (!self.setSetupBuffer(&self.setup_base_url, "https://ai-gateway.vercel.sh/v1")) return;
                if (!self.setSetupBuffer(&self.setup_api_key_env, "AI_GATEWAY_API_KEY")) return;
                if (self.setup_readiness.vercel_ready)
                    self.startSetupPrompt(.model, "vercel/anthropic/claude-sonnet-4.5", "choose a Vercel gateway model id · Enter accepts the suggestion")
                else
                    self.startSetupPrompt(.credential, "", "paste a Vercel AI Gateway API key · input is masked · Esc goes back");
            },
            .anthropic => {
                if (!self.setSetupBuffer(&self.setup_provider_name, "anthropic")) return;
                if (!self.setSetupBuffer(&self.setup_base_url, "https://api.anthropic.com/v1")) return;
                if (!self.setSetupBuffer(&self.setup_api_key_env, "ANTHROPIC_API_KEY")) return;
                if (self.setup_readiness.anthropic_ready)
                    self.startSetupPrompt(.model, "anthropic/claude-sonnet-4-5", "choose an Anthropic model id · Enter accepts the suggestion")
                else
                    self.startSetupPrompt(.credential, "", "paste an Anthropic API key · input is masked · Esc goes back");
            },
            .litellm => {
                if (!self.setSetupBuffer(&self.setup_provider_name, "litellm")) return;
                if (!self.setSetupBuffer(&self.setup_api_key_env, "LITELLM_API_KEY")) return;
                self.startSetupPrompt(.base_url, "http://127.0.0.1:4000/v1", "LiteLLM base URL · Enter accepts the local default");
            },
            .local => {
                if (!self.setSetupBuffer(&self.setup_provider_name, "local")) return;
                if (!self.setSetupBuffer(&self.setup_api_key_env, "MARLIN_LOCAL_API_KEY")) return;
                self.startSetupPrompt(.base_url, "http://127.0.0.1:11434/v1", "OpenAI-compatible base URL · edit the suggested local address if needed");
            },
            .custom => self.startSetupPrompt(.provider_name, "", "short provider name, for example acme · model ids will use acme/…"),
        }
    }

    fn setupCredentialRequired(self: *const App) bool {
        return switch (self.setup_provider orelse return false) {
            .openrouter, .vercel, .anthropic => true,
            else => false,
        };
    }

    fn setupModelSuggestion(self: *const App) []const u8 {
        return switch (self.setup_provider orelse return "") {
            .openrouter => "openrouter/anthropic/claude-sonnet-4.5",
            .vercel => "vercel/anthropic/claude-sonnet-4.5",
            .anthropic => "anthropic/claude-sonnet-4-5",
            .litellm => "litellm/",
            .local => "local/",
            .custom => "",
            .codex, .claude_code => "",
        };
    }

    fn submitSetupPrompt(self: *App, raw: []const u8) void {
        const value = std.mem.trim(u8, raw, " \t\r\n");
        switch (self.setup_prompt) {
            .none => {},
            .provider_name => {
                if (!validSetupProviderName(value)) {
                    self.setNotice("provider name must use letters, digits, - or _", .{});
                    return;
                }
                if (!self.setSetupBuffer(&self.setup_provider_name, value)) return;
                var env_name: [96]u8 = undefined;
                if (value.len + "_API_KEY".len > env_name.len) {
                    self.setNotice("provider name is too long", .{});
                    return;
                }
                for (value, 0..) |byte, i| env_name[i] = if (byte == '-') '_' else std.ascii.toUpper(byte);
                @memcpy(env_name[value.len..][0.."_API_KEY".len], "_API_KEY");
                if (!self.setSetupBuffer(&self.setup_api_key_env, env_name[0 .. value.len + "_API_KEY".len])) return;
                self.startSetupPrompt(.base_url, "https://", "OpenAI-compatible base URL, including /v1 when your provider requires it");
            },
            .base_url => {
                if (!(std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://"))) {
                    self.setNotice("base URL must start with http:// or https://", .{});
                    return;
                }
                if (!self.setSetupBuffer(&self.setup_base_url, value)) return;
                self.startSetupPrompt(.credential, "", "API key (optional for local gateways) · Enter skips · input is masked");
            },
            .credential => {
                if (self.setupCredentialRequired() and value.len < 8) {
                    self.setNotice("that does not look like an API key · Esc goes back", .{});
                    return;
                }
                if (!self.setSetupBuffer(&self.setup_credential, value)) return;
                if (value.len == 0 and self.setup_provider != .openrouter and self.setup_provider != .vercel and self.setup_provider != .anthropic) {
                    if (!self.setSetupBuffer(&self.setup_api_key_env, "NONE")) return;
                }
                const suggestion = if (self.setup_provider == .custom)
                    std.fmt.allocPrint(self.gpa, "{s}/", .{self.setup_provider_name.items}) catch return
                else
                    self.gpa.dupe(u8, self.setupModelSuggestion()) catch return;
                defer self.gpa.free(suggestion);
                self.startSetupPrompt(.model, suggestion, "finish the model id in provider/model form");
            },
            .model => {
                const slash = std.mem.indexOfScalar(u8, value, '/') orelse {
                    self.setNotice("model must use provider/model form", .{});
                    return;
                };
                if (slash == 0 or slash + 1 == value.len) {
                    self.setNotice("model id needs a name after provider/", .{});
                    return;
                }
                const expected = self.setup_provider_name.items;
                if (expected.len > 0 and !std.mem.eql(u8, value[0..slash], expected)) {
                    self.setNotice("model id must start with {s}/", .{expected});
                    return;
                }
                self.finishSetup(value);
            },
        }
    }

    fn finishSetup(self: *App, model: []const u8) void {
        if (self.setup_apply_pending) return;
        const configured_provider = self.setup_provider_name.items;
        self.conn.sendSensitive(.{ .setup_apply = .{
            .sid = self.sid,
            .model = model,
            .provider_name = configured_provider,
            .base_url = self.setup_base_url.items,
            .api_key_env = self.setup_api_key_env.items,
            .credential = self.setup_credential.items,
            .replace_empty_session = self.setup_replace_empty_session,
        } }) catch {
            self.setNotice("could not send provider setup to the daemon", .{});
            return;
        };
        if (self.setup_credential.items.len > 0) @memset(self.setup_credential.items, 0);
        self.setup_credential.clearRetainingCapacity();
        self.editor.clearSensitive();
        self.setup_prompt = .none;
        self.picker = null;
        self.setup_apply_pending = true;
        self.setNotice("activating provider setup on the daemon host…", .{});
    }

    fn applySetupResult(self: *App, result: @FieldType(proto.DaemonMsg, "setup_result")) void {
        self.setup_apply_pending = false;
        self.setup_readiness.completed = true;
        self.setup_required = false;
        self.setup_replace_empty_session = false;
        if (result.session_updated) {
            self.setModelStr(result.model);
            self.setNotice("ready · {s} · /setup changes provider later", .{result.model});
        } else if (!std.mem.eql(u8, self.model.items, result.model)) {
            self.applyModel(result.model);
        } else {
            self.setNotice("provider setup saved · {s}", .{result.model});
        }
        self.clearSetupDraft();
    }

    fn beginHistorySearch(self: *App) void {
        if (self.history_search_active) {
            self.cycleHistorySearch();
            return;
        }
        self.history_search_draft.clearRetainingCapacity();
        self.history_search_draft.appendSlice(self.gpa, self.editor.text.items) catch return;
        self.history_search_draft_cursor = self.editor.cursor;
        self.history_search_query.clearRetainingCapacity();
        self.history_search_match = null;
        self.history_search_active = true;
        self.refreshHistorySearch(true);
        self.conn.send(.{ .input_history = .{
            .sid = self.sid,
            .limit = Editor.max_history_entries,
        } }) catch {
            // The already-seeded current-session history remains useful when
            // a reconnect races the shortcut.
            self.setNotice("global input history unavailable", .{});
        };
    }

    fn refreshHistorySearch(self: *App, from_newest: bool) void {
        if (!self.history_search_active) return;
        const previous = self.history_search_match;
        var index = if (from_newest)
            self.editor.history.items.len
        else
            (self.history_search_match orelse self.editor.history.items.len);
        while (index > 0) {
            index -= 1;
            const candidate = self.editor.history.items[index];
            if (fuzzyHistoryScore(candidate, self.history_search_query.items) == null) continue;
            self.history_search_match = index;
            self.editor.replaceText(candidate);
            return;
        }
        if (!from_newest and previous != null) return;
        self.history_search_match = null;
        self.editor.replaceText(self.history_search_draft.items);
        self.editor.cursor = @min(self.history_search_draft_cursor, self.editor.text.items.len);
    }

    fn cycleHistorySearch(self: *App) void {
        self.refreshHistorySearch(false);
    }

    fn cancelHistorySearch(self: *App) void {
        if (!self.history_search_active) return;
        self.editor.replaceText(self.history_search_draft.items);
        self.editor.cursor = @min(self.history_search_draft_cursor, self.editor.text.items.len);
        self.finishHistorySearch();
    }

    fn acceptHistorySearch(self: *App) void {
        if (!self.history_search_active) return;
        self.finishHistorySearch();
    }

    fn finishHistorySearch(self: *App) void {
        self.history_search_active = false;
        self.history_search_query.clearRetainingCapacity();
        self.history_search_draft.clearRetainingCapacity();
        self.history_search_match = null;
    }

    fn clearSearchHits(self: *App) void {
        for (self.search_hits.items) |*hit| hit.deinit(self.gpa);
        self.search_hits.clearRetainingCapacity();
        self.search_labels.clearRetainingCapacity();
        self.search_cursor = 0;
    }

    fn openSearchPrompt(self: *App, session_id: u64) void {
        self.clearSearchHits();
        self.search_scope_sid = session_id;
        self.search_pending = false;
        self.openPicker(.search_prompt);
    }

    fn submitSearch(self: *App) void {
        const query = std.mem.trim(u8, self.picker_filter.items, " \t\r\n");
        if (query.len == 0 or self.search_pending) return;
        self.search_pending = true;
        self.conn.send(.{ .search = .{
            .query = query,
            .sid = self.search_scope_sid,
            .limit = 100,
        } }) catch {
            self.search_pending = false;
            self.setNotice("could not search transcript", .{});
        };
    }

    fn replaceSearchHits(self: *App, result: @FieldType(proto.DaemonMsg, "search_result")) void {
        if (!self.search_pending or result.sid != self.search_scope_sid) return;
        self.search_pending = false;
        self.clearSearchHits();
        for (result.hits) |hit| {
            self.rememberSession(hit.sid);
            var handle_buf: session_handle.Full = undefined;
            const location = if (hit.title.len > 0) hit.title else hit.cwd;
            const label = std.fmt.allocPrint(self.gpa, "{s}:{d} · {s} · {s} · {s}", .{
                self.displaySessionHandle(&handle_buf, hit.sid),
                hit.seq,
                location,
                @tagName(hit.kind),
                hit.snippet,
            }) catch continue;
            self.search_hits.append(self.gpa, .{
                .sid = hit.sid,
                .seq = hit.seq,
                .label = label,
            }) catch {
                self.gpa.free(label);
                continue;
            };
            self.search_labels.append(self.gpa, label) catch {
                var removed = self.search_hits.pop().?;
                removed.deinit(self.gpa);
            };
        }
        if (self.search_hits.items.len == 0) {
            self.picker = null;
            self.picker_filter.clearRetainingCapacity();
            self.setNotice("no transcript matches", .{});
            return;
        }
        self.picker_kind = .search;
        self.picker = 0;
        self.picker_filter.clearRetainingCapacity();
    }

    fn selectSearchHit(self: *App, label: []const u8) ?SearchHitOwned {
        for (self.search_hits.items, 0..) |hit, index| {
            if (!std.mem.eql(u8, hit.label, label)) continue;
            self.search_cursor = index;
            return hit;
        }
        return null;
    }

    fn nextSearchHit(self: *App, direction: i8) void {
        const len = self.search_hits.items.len;
        if (len == 0) {
            self.setNotice("no active search · press /", .{});
            return;
        }
        self.search_cursor = if (direction < 0)
            (self.search_cursor + len - 1) % len
        else
            (self.search_cursor + 1) % len;
        const hit = self.search_hits.items[self.search_cursor];
        self.jumpToSearchHit(hit.sid, hit.seq) catch self.setNotice("could not open search match", .{});
    }

    /// The picker's source list: full model catalog/favorites, or the fixed
    /// effort vocabulary shared with persistence and provider adapters.
    fn pickerSource(self: *const App) []const []const u8 {
        return switch (self.picker_kind) {
            .model, .council => if (self.catalog.items.len > 0) @ptrCast(self.catalog.items) else self.cfg.model_favorites,
            .effort => &proto.ReasoningEffort.choices,
            .session => self.session_labels.items,
            .search => self.search_labels.items,
            .search_prompt => &.{},
            .council_list => &.{},
            .voice_engine => &voice_engine_items,
            .voice_mode => &voice_mode_items,
            .setup_provider => &setup_provider_items,
        };
    }

    /// Filtered picker items (arena-allocated indices into pickerSource).
    /// Filter: case-insensitive substring; multiple space-separated words
    /// must ALL match ("son 4.5" → claude-sonnet-4.5).
    fn pickerItems(self: *const App, arena: std.mem.Allocator) ![]const []const u8 {
        const source = self.pickerSource();
        const q = self.picker_filter.items;
        if (self.picker_kind == .search_prompt) return &.{};
        if (self.picker_kind == .council_list) {
            var councils: std.ArrayList([]const u8) = .empty;
            outer: for (self.councils.items) |council| {
                var words = std.mem.tokenizeScalar(u8, q, ' ');
                while (words.next()) |word| {
                    if (containsIgnoreCase(council.name, word) == null) continue :outer;
                }
                try councils.append(arena, council.name);
            }
            return councils.items;
        }
        if (q.len == 0 and self.picker_kind != .council) return source;
        var out: std.ArrayList([]const u8) = .empty;
        if (self.picker_kind == .council) try out.append(arena, council_done_item);
        outer: for (source) |m| {
            var words = std.mem.tokenizeScalar(u8, q, ' ');
            while (words.next()) |word| {
                if (containsIgnoreCase(m, word) == null) continue :outer;
            }
            try out.append(arena, m);
        }
        if (self.picker_kind == .council) selected: for (self.council_edit_models.items) |selected| {
            for (source) |m| {
                if (std.mem.eql(u8, selected, m)) continue :selected;
            }
            var words = std.mem.tokenizeScalar(u8, q, ' ');
            while (words.next()) |word| {
                if (containsIgnoreCase(selected, word) == null) continue :selected;
            }
            try out.append(arena, selected);
        };
        return out.items;
    }

    fn pickerSourceCount(self: *const App) usize {
        if (self.picker_kind == .council_list) return self.councils.items.len;
        const source = self.pickerSource();
        if (self.picker_kind != .council) return source.len;
        var total = source.len;
        selected: for (self.council_edit_models.items) |selected| {
            for (source) |m| {
                if (std.mem.eql(u8, selected, m)) continue :selected;
            }
            total += 1;
        }
        return total;
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
        const current_guest = proto.guestBackend(self.model.items);
        const requested_guest = proto.guestBackend(m);
        if (current_guest != null and requested_guest != null and current_guest.? != requested_guest.?) {
            self.setNotice("switch through a native model first so Marlin can hand over between guest agents", .{});
            return;
        }
        self.conn.send(.{ .session_set_model = .{ .sid = self.sid, .model = m } }) catch return;
        if (!proto.isGuestModel(self.model.items) and proto.isGuestModel(m)) {
            const guest_name = if (std.mem.startsWith(u8, m, "claudecode/")) m["claudecode/".len..] else m;
            self.setNotice("switching to {s} — generating handover summary…", .{guest_name});
        } else {
            self.setModelStr(m);
            self.setNotice("model → {s}", .{m});
        }
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

    fn setPlanMode(self: *App, enabled: bool) bool {
        if (self.state == .running or self.state == .awaiting_approval) {
            self.setNotice("cannot change Plan mode mid-turn", .{});
            return false;
        }
        self.conn.send(.{ .session_set_plan_mode = .{ .sid = self.sid, .enabled = enabled } }) catch {
            self.setNotice("could not change Plan mode", .{});
            return false;
        };
        self.plan_mode = enabled;
        self.plan_proposal_ready = false;
        if (enabled)
            self.setNotice("Plan mode on · read-only investigation · Shift+Tab exits", .{})
        else
            self.setNotice("Plan mode off", .{});
        return true;
    }

    fn togglePlanMode(self: *App) void {
        _ = self.setPlanMode(!self.plan_mode);
    }

    fn acceptPlanProposal(self: *App) void {
        if (!self.plan_mode or !self.plan_proposal_ready or self.state != .idle) return;
        self.conn.send(.{ .plan_accept = .{ .sid = self.sid } }) catch {
            self.setNotice("could not start implementation", .{});
            return;
        };
        self.plan_proposal_ready = false;
        self.setNotice("plan accepted · starting implementation…", .{});
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
        if (proto.isGuestModel(self.model.items)) {
            self.setNotice("sandbox is Marlin's; guest agents use their own permissions", .{});
            return;
        }
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

    fn otelCommand(self: *App, action_arg: ?[]const u8, rest_arg: []const u8) void {
        const parsed = parseOtelCommand(action_arg, rest_arg) orelse {
            self.setNotice("usage: /otel [status|off|set <endpoint>|content on|content off]", .{});
            return;
        };
        switch (parsed) {
            .status => self.conn.send(.{ .otel_status = .{} }) catch {
                self.setNotice("could not request OTLP status", .{});
            },
            .off => self.conn.send(.{ .otel_configure = .{} }) catch {
                self.setNotice("could not disable OTLP export", .{});
            },
            .content => |enabled| self.conn.send(.{ .otel_content = .{ .enabled = enabled } }) catch {
                self.setNotice("could not toggle OTLP content capture", .{});
            },
            .set => |endpoint| {
                self.otel_endpoint.clearRetainingCapacity();
                self.otel_endpoint.appendSlice(self.gpa, endpoint) catch {
                    self.setNotice("could not start OTLP setup", .{});
                    return;
                };
                self.editor.clear();
                self.otel_header_prompt = true;
                self.mode = .insert;
                self.setNotice("enter OTLP headers: name=value[,name=value] · Enter applies · Esc cancels", .{});
            },
        }
    }

    fn submitOtelHeaders(self: *App, headers: []const u8) void {
        if (!self.otel_header_prompt) return;
        self.otel_header_prompt = false;
        defer self.otel_endpoint.clearRetainingCapacity();
        self.conn.sendSensitive(.{ .otel_configure = .{
            .endpoint = self.otel_endpoint.items,
            .headers = headers,
        } }) catch {
            self.setNotice("could not configure OTLP export", .{});
            return;
        };
        self.setNotice("configuring OTLP export…", .{});
    }

    fn cancelOtelSetup(self: *App) void {
        self.editor.clearSensitive();
        self.otel_endpoint.clearRetainingCapacity();
        self.otel_header_prompt = false;
        self.setNotice("OTLP setup cancelled", .{});
    }

    fn networkCommand(self: *App, arg: []const u8) void {
        if (proto.isGuestModel(self.model.items)) {
            self.setNotice("dnsblock is Marlin's; guest-agent networking is not filtered here", .{});
            return;
        }
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

    fn councilModelSelected(self: *const App, model: []const u8) bool {
        for (self.council_edit_models.items) |selected| {
            if (std.mem.eql(u8, selected, model)) return true;
        }
        return false;
    }

    fn openCouncilPicker(self: *App, name: []const u8) void {
        if (!validCouncilName(name)) {
            self.setNotice("council names are letters, digits, - and _", .{});
            return;
        }
        self.clearCouncilEdit();
        self.council_edit_name.appendSlice(self.gpa, name) catch {
            self.setNotice("could not open council editor", .{});
            return;
        };
        if (self.councilByName(name)) |council| {
            for (council.models.items) |model| {
                const copy = self.gpa.dupe(u8, model) catch {
                    self.clearCouncilEdit();
                    self.setNotice("could not open council editor", .{});
                    return;
                };
                self.council_edit_models.append(self.gpa, copy) catch {
                    self.gpa.free(copy);
                    self.clearCouncilEdit();
                    self.setNotice("could not open council editor", .{});
                    return;
                };
            }
        }
        self.openPicker(.council);
        if (self.catalog.items.len == 0) self.conn.send(.{ .model_list = .{} }) catch {};
    }

    fn toggleCouncilModel(self: *App, model: []const u8) void {
        for (self.council_edit_models.items, 0..) |selected, i| {
            if (!std.mem.eql(u8, selected, model)) continue;
            self.gpa.free(selected);
            _ = self.council_edit_models.orderedRemove(i);
            return;
        }
        const copy = self.gpa.dupe(u8, model) catch {
            self.setNotice("could not update council", .{});
            return;
        };
        self.council_edit_models.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            self.setNotice("could not update council", .{});
        };
    }

    fn saveCouncilEdit(self: *App) void {
        if (self.council_edit_models.items.len == 0) {
            self.setNotice("choose at least one model before Done", .{});
            return;
        }
        const name = self.council_edit_name.items;
        var models: std.ArrayList([]const u8) = .empty;
        defer models.deinit(self.gpa);
        for (self.council_edit_models.items) |model| models.append(self.gpa, model) catch {
            self.setNotice("could not save council", .{});
            return;
        };
        self.council_notice_pending = true;
        self.conn.send(.{ .council_set = .{ .name = name, .models = models.items } }) catch {
            self.setNotice("could not save council", .{});
            return;
        };
        self.picker = null;
        self.picker_filter.clearRetainingCapacity();
        self.setNotice("saving council {s} ({d} models)…", .{ name, models.items.len });
        self.clearCouncilEdit();
    }

    fn cancelCouncilEdit(self: *App) void {
        const had_draft = self.council_edit_name.items.len > 0;
        self.clearCouncilEdit();
        self.picker = null;
        self.picker_filter.clearRetainingCapacity();
        if (had_draft) self.setNotice("council edit cancelled", .{});
    }

    fn openCouncilList(self: *App) void {
        if (self.councils.items.len == 0) {
            self.setNotice("no councils configured — /council new <name>", .{});
            return;
        }
        self.openPicker(.council_list);
    }

    fn showCouncilDetail(self: *App, name: []const u8) void {
        if (self.councilByName(name) == null) {
            self.setNotice("unknown council '{s}' — /council lists them", .{name});
            return;
        }
        self.council_detail_name.clearRetainingCapacity();
        self.council_detail_name.appendSlice(self.gpa, name) catch {
            self.council_detail_name.clearRetainingCapacity();
            self.setNotice("could not show council", .{});
        };
    }

    fn closeCouncilDetail(self: *App) void {
        self.council_detail_name.clearRetainingCapacity();
    }

    fn applyPickerItem(self: *App, item: []const u8) void {
        switch (self.picker_kind) {
            .model => self.applyModel(item),
            .effort => self.applyEffort(proto.ReasoningEffort.parse(item) orelse return),
            .session => self.switchSession(self.sessionIdForLabel(item) orelse return, true) catch
                self.setNotice("could not switch session", .{}),
            .search => {
                const hit = self.selectSearchHit(item) orelse return;
                self.jumpToSearchHit(hit.sid, hit.seq) catch self.setNotice("could not open search match", .{});
            },
            .search_prompt => {},
            .council => self.toggleCouncilModel(item),
            .council_list => self.showCouncilDetail(item),
            .voice_engine => self.voiceWizardEngineChosen(item),
            .voice_mode => self.voiceWizardModeChosen(item),
            .setup_provider => self.setupProviderChosen(item),
        }
    }

    fn archivePickerSession(self: *App, item: []const u8) void {
        const sid = self.sessionIdForLabel(item) orelse return;
        for (self.sessions.items) |session| {
            if (!self.sessionBelongsToTree(session.sid, sid)) continue;
            if (session.state == .running or session.state == .awaiting_approval) {
                self.setNotice("cannot archive a running session tree", .{});
                return;
            }
        }
        if (sid == self.sid) {
            self.picker = null;
            self.picker_filter.clearRetainingCapacity();
            self.archiveCurrentSession();
            return;
        }
        self.conn.send(.{ .session_archive = .{ .sid = sid } }) catch {
            self.setNotice("could not archive session", .{});
            return;
        };
        var handle_buf: session_handle.Full = undefined;
        self.setNotice("archiving session {s}", .{self.displaySessionHandle(&handle_buf, sid)});
    }

    fn pickerCurrent(self: *const App) []const u8 {
        return switch (self.picker_kind) {
            .model => self.model.items,
            .effort => @tagName(self.effort),
            .session, .search_prompt, .search, .council, .council_list, .voice_engine, .voice_mode, .setup_provider => "",
        };
    }

    fn newSession(self: *App) !void {
        if (self.setup_required) {
            self.beginSetup(true);
            self.setNotice("finish provider setup before creating another session", .{});
            return;
        }
        if (self.awaiting_new_session) {
            self.setNotice("new session already being created", .{});
            return;
        }
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = try std.process.currentPath(self.io, &cwd_buf);
        const request_id = self.next_input_request_id;
        self.next_input_request_id +%= 1;
        if (self.next_input_request_id == 0) self.next_input_request_id = 1;
        try self.conn.send(.{ .session_create = .{
            .cwd = cwd_buf[0..cwd_len],
            .model = self.model.items,
            .effort = self.effort,
            .request_id = request_id,
        } });
        self.pending_new_cwd.clearRetainingCapacity();
        try self.pending_new_cwd.appendSlice(self.gpa, cwd_buf[0..cwd_len]);
        // The reply is routed through the reader thread; we can't recv here.
        // Optimistic switch happens when session_created arrives — but that
        // message has no sub; simplest correct M2 flow: remember we asked.
        // Handled in handleDaemonLineCreated below via the pending flag.
        self.awaiting_new_session = true;
        self.pending_new_session_request_id = request_id;
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

    fn handleSessionCreated(self: *App, sid: u64, request_id: u64) void {
        if (!self.awaiting_new_session) return;
        if (request_id != 0 and request_id != self.pending_new_session_request_id) return;
        self.awaiting_new_session = false;
        self.pending_new_session_request_id = 0;
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
        self.conn.send(.{ .interrupt = .{ .sid = self.sid, .report = true } }) catch {
            self.setNotice("could not send interrupt", .{});
            return;
        };
        self.setNotice("interrupt requested", .{});
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

    fn requestOlderHistory(self: *App) void {
        if (self.history_complete or self.history_loading) return;
        if (self.oldest_seq <= 1) {
            self.history_complete = true;
            return;
        }
        self.copy_cursor = null;
        self.sel_anchor = null;
        self.sel_dragging = false;
        self.clearHistoryBackfill();
        self.history_loading = true;
        self.history_before_seq = self.oldest_seq;
        self.history_page_failed = false;
        self.conn.send(.{ .sub = .{
            .sid = self.sid,
            .tail_limit = initial_replay_blocks,
            .before_seq = self.history_before_seq,
        } }) catch {
            self.history_loading = false;
            self.history_before_seq = 0;
            self.setNotice("could not load older history", .{});
            return;
        };
        self.setNotice("loading older history…", .{});
    }

    fn maybeRequestHistoryAtTop(self: *App) void {
        if (self.history_complete or self.history_loading) return;
        const max_scroll = self.last_total_lines -| self.last_view_h;
        if (self.scroll_up >= max_scroll) self.requestOlderHistory();
    }
};

// ------------------------------------------------------------- rendering --

fn statusModel(arena: std.mem.Allocator, model: []const u8) ![]const u8 {
    if (proto.isGuestModel(model)) {
        const name = if (std.mem.startsWith(u8, model, "claudecode/"))
            model["claudecode/".len..]
        else
            model;
        return std.fmt.allocPrint(arena, "(guest) {s}", .{name});
    }
    const gateway = "openrouter/";
    return if (std.mem.startsWith(u8, model, gateway)) model[gateway.len..] else model;
}

/// Guest sessions do not run Marlin's assembler, so ctx% is always a lie
/// (used stays 0; the limit lookup even matches `claudecode` as `claude`).
fn statusContext(arena: std.mem.Allocator, guest: bool, used: u64, limit: u64) ![]const u8 {
    if (guest) return "ctx n/a";
    if (limit == 0) return "";
    return std.fmt.allocPrint(arena, "ctx {d}%", .{used * 100 / limit});
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

fn validCouncilName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    }
    return true;
}

fn parseOtelCommand(action_arg: ?[]const u8, rest_arg: []const u8) ?OtelCommand {
    const action = action_arg orelse "status";
    const rest = std.mem.trim(u8, rest_arg, " \t\r\n");
    if (std.mem.eql(u8, action, "status") and rest.len == 0) return .status;
    if (std.mem.eql(u8, action, "off") and rest.len == 0) return .off;
    if (std.mem.eql(u8, action, "set") and rest.len > 0 and
        std.mem.indexOfAny(u8, rest, " \t\r\n") == null)
        return .{ .set = rest };
    if (std.mem.eql(u8, action, "content")) {
        if (std.mem.eql(u8, rest, "on")) return .{ .content = true };
        if (std.mem.eql(u8, rest, "off")) return .{ .content = false };
    }
    return null;
}

fn commandQuery(editor: *const Editor) ?[]const u8 {
    const text = editor.text.items;
    if (text.len == 0 or (text[0] != '/' and text[0] != '!')) return null;
    if (std.mem.indexOfAny(u8, text, "\r\n") != null) return null;
    if (std.mem.indexOfAny(u8, text, " \t")) |space| {
        const head = text[0..space];
        if (!std.mem.eql(u8, head, "/council") and
            !std.mem.eql(u8, head, "/review") and
            !std.mem.eql(u8, head, "/plan") and
            !std.mem.eql(u8, head, "/animate") and
            !std.mem.eql(u8, head, "/otel") and
            !std.mem.eql(u8, head, "!rb")) return null;
        const rest = std.mem.trimStart(u8, text[space..], " \t");
        if (std.mem.indexOfAny(u8, rest, " \t") != null) return null;
    }
    return text;
}

fn commandSuggestions(app: *const App, arena: std.mem.Allocator) ![]const CommandSuggestion {
    const query = commandQuery(&app.editor) orelse return &.{};
    var out: std.ArrayList(CommandSuggestion) = .empty;
    if (query.len > "/council".len and
        std.mem.eql(u8, query[0.."/council".len], "/council") and
        (query["/council".len] == ' ' or query["/council".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/council".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "new", .description = "create a council" },
            .{ .name = "edit", .description = "edit a council roster" },
            .{ .name = "remove", .description = "remove a council" },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/council {s} ", .{action.name});
                try out.append(arena, .{
                    .label = try std.fmt.allocPrint(arena, "/council {s}", .{action.name}),
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = false,
                });
            }
        }
        for (app.councils.items) |council| {
            if (rest.len <= council.name.len and std.ascii.eqlIgnoreCase(rest, council.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/council {s}", .{council.name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = try std.fmt.allocPrint(arena, "show council · {d} models", .{council.models.items.len}),
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/review".len and
        std.mem.eql(u8, query[0.."/review".len], "/review") and
        (query["/review".len] == ' ' or query["/review".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/review".len..], " \t");
        for (app.councils.items) |council| {
            if (rest.len <= council.name.len and std.ascii.eqlIgnoreCase(rest, council.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/review {s} ", .{council.name});
                try out.append(arena, .{
                    .label = try std.fmt.allocPrint(arena, "/review {s}", .{council.name}),
                    .description = try std.fmt.allocPrint(arena, "review with council · {d} models", .{council.models.items.len}),
                    .replacement = replacement,
                    .submit_on_enter = false,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/otel".len and
        std.mem.eql(u8, query[0.."/otel".len], "/otel") and
        (query["/otel".len] == ' ' or query["/otel".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/otel".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8, submit: bool }{
            .{ .name = "set", .description = "set endpoint, then enter masked headers", .submit = false },
            .{ .name = "status", .description = "show live OTLP exporter state", .submit = true },
            .{ .name = "off", .description = "disable live OTLP export", .submit = true },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/otel {s}{s}", .{ action.name, if (action.submit) "" else " " });
                try out.append(arena, .{
                    .label = try std.fmt.allocPrint(arena, "/otel {s}", .{action.name}),
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = action.submit,
                });
            }
        }
        return out.items;
    }
    if (query.len > "!rb".len and
        std.mem.eql(u8, query[0.."!rb".len], "!rb") and
        (query["!rb".len] == ' ' or query["!rb".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["!rb".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "client", .description = "rebuild only the local client" },
            .{ .name = "both", .description = "rebuild the local client and attached Marlin" },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "!rb {s}", .{action.name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    if (query.len > "/animate".len and
        std.mem.eql(u8, query[0.."/animate".len], "/animate") and
        (query["/animate".len] == ' ' or query["/animate".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/animate".len..], " \t");
        if (rest.len <= "matrix".len and std.ascii.eqlIgnoreCase(rest, "matrix"[0..rest.len])) {
            try out.append(arena, .{
                .label = "/animate matrix",
                .description = "play falling green symbols over the current screen",
                .replacement = "/animate matrix",
                .submit_on_enter = true,
            });
        }
        return out.items;
    }
    if (query.len > "/plan".len and
        std.mem.eql(u8, query[0.."/plan".len], "/plan") and
        (query["/plan".len] == ' ' or query["/plan".len] == '\t'))
    {
        const rest = std.mem.trimStart(u8, query["/plan".len..], " \t");
        const actions = [_]struct { name: []const u8, description: []const u8 }{
            .{ .name = "off", .description = "leave Plan mode" },
            .{ .name = "clear", .description = "clear the durable execution todo" },
        };
        for (actions) |action| {
            if (rest.len <= action.name.len and std.ascii.eqlIgnoreCase(rest, action.name[0..rest.len])) {
                const replacement = try std.fmt.allocPrint(arena, "/plan {s}", .{action.name});
                try out.append(arena, .{
                    .label = replacement,
                    .description = action.description,
                    .replacement = replacement,
                    .submit_on_enter = true,
                });
            }
        }
        return out.items;
    }
    for (composer_commands) |command| {
        if (query.len <= command.name.len and std.ascii.eqlIgnoreCase(query, command.name[0..query.len])) {
            try out.append(arena, .{
                .label = command.name,
                .usage = command.usage,
                .description = command.description,
                .replacement = command.name,
                .submit_on_enter = true,
            });
        }
    }
    return out.items;
}

fn completeSuggestion(editor: *Editor, suggestion: CommandSuggestion, tab: bool) void {
    editor.clear();
    editor.insertSlice(suggestion.replacement);
    if (tab and suggestion.submit_on_enter) {
        for (composer_commands) |command| {
            if (std.mem.eql(u8, suggestion.replacement, command.name) and command.accepts_args) {
                editor.insertSlice(" ");
                break;
            }
        }
    }
}

fn transcriptView(app: *App) Transcript {
    return .{
        .io = app.io,
        .blocks = app.blocks.items,
        .show_tool_transcript = app.show_tool_transcript,
        .state = app.state,
        .layout_epoch = app.layout_epoch,
        .delta = app.delta.items,
        .reasoning_delta = app.reasoning_delta.items,
        .spinner_frame = app.spinner_frame,
        .turn_started_ms = app.turn_started_ms,
        .turn_phase = app.turn_phase,
        .phase_started_ms = app.phase_started_ms,
        .call_started_ms = app.call_started_ms,
        .stream_bytes = app.stream_bytes,
        .stream_quiet_ms = app.stream_quiet_ms,
        .stream_status_at_ms = app.stream_status_at_ms,
        .show_working_ticker = !hasUnfinishedPlan(app.plan.items),
        .cwd = app.cwd.items,
        .approval = if (app.pending) |*pending| .{
            .tool = pending.tool(),
            .args = pending.args(),
        } else null,
        .layout_cache = &app.layout_cache,
        .tail_layout_cache = &app.tail_layout_cache,
        .stream_layout_cache = &app.stream_layout_cache,
    };
}

fn layoutLines(arena: std.mem.Allocator, app: *App, width: u16) !std.ArrayList(Line) {
    var transcript = transcriptView(app);
    return layout_mod.layoutLines(arena, app.gpa, &transcript, width);
}

fn formatDiagnostics(gpa: std.mem.Allocator, report: proto.Diagnostics) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.print(gpa, "**Session** `{x}`\n", .{report.sid});
    try out.print(gpa, "**Sample** {d} turns · {d} ok · {d} failed · {d} interrupted · {d} abandoned · {d} checkpoints\n", .{
        report.sample_turns,
        report.successful_turns,
        report.failed_turns,
        report.interrupted_turns,
        report.abandoned_turns,
        report.checkpoint_turns,
    });
    try out.print(gpa, "**Provider** {d} requests · p50 {d:.2}s · p95 {d:.2}s · TTFT p50 {d:.2}s · p95 {d:.2}s\n", .{
        report.provider_requests,
        diagnosticsSeconds(report.provider_p50_ms),
        diagnosticsSeconds(report.provider_p95_ms),
        diagnosticsSeconds(report.ttft_p50_ms),
        diagnosticsSeconds(report.ttft_p95_ms),
    });
    try out.print(gpa, "**Local prep** measured p50 {d:.2}s · p95 {d:.2}s\n", .{
        diagnosticsSeconds(report.local_prep_p50_ms),
        diagnosticsSeconds(report.local_prep_p95_ms),
    });
    try out.print(gpa, "**Legacy pre-provider** p50 {d:.2}s · p95 {d:.2}s · max {d:.2}s · {d} at least 1s\n", .{
        diagnosticsSeconds(report.pre_provider_p50_ms),
        diagnosticsSeconds(report.pre_provider_p95_ms),
        diagnosticsSeconds(report.pre_provider_max_ms),
        report.pre_provider_slow_turns,
    });
    try out.print(gpa, "**Tools** {d} calls\n", .{report.tool_calls});

    if (report.last_turn_id == 0) {
        try out.appendSlice(gpa, "**Last** no telemetry yet (run a new turn after this build)\n");
    } else {
        try out.print(gpa, "**Last** {s} · {d:.2}s · trace `{s}`\n", .{
            report.last_outcome,
            diagnosticsSeconds(report.last_duration_ms),
            report.last_trace_id,
        });
        if (report.last_error.len > 0) try out.print(gpa, "**Error** {s}\n", .{report.last_error});
        for (report.last_rounds) |round| {
            try out.print(gpa, "- Provider #{d}: {s} · {d:.2}s · TTFT {d:.2}s · {d} bytes · {d} in/{d} out", .{
                round.round + 1,
                round.status,
                diagnosticsSeconds(round.duration_ms),
                diagnosticsSeconds(round.ttft_ms),
                round.bytes,
                round.tokens_in,
                round.tokens_out,
            });
            if (round.round == 0) try out.print(gpa, " · pre-provider {d:.2}s", .{diagnosticsSeconds(round.pre_provider_ms)});
            const local_ms = round.context_load_ms +| round.setup_ms +| round.assemble_ms +| round.body_ms;
            if (local_ms > 0) try out.print(gpa, " · local {d:.2}s [setup {d:.2}s, db {d:.2}s ({d}ms wait, {d} rows/{d} bytes/{d} steps), assemble {d:.2}s, body {d:.2}s]", .{
                diagnosticsSeconds(local_ms),
                diagnosticsSeconds(round.setup_ms),
                diagnosticsSeconds(round.context_load_ms),
                round.store_wait_ms,
                round.context_rows,
                round.context_bytes,
                round.context_vm_steps,
                diagnosticsSeconds(round.assemble_ms),
                diagnosticsSeconds(round.body_ms),
            });
            if (round.provider.len > 0) try out.print(gpa, " · {s}", .{round.provider});
            if (round.generation_id.len > 0) try out.print(gpa, " · `{s}`", .{round.generation_id});
            try out.append(gpa, '\n');
        }
        for (report.last_tools) |tool| try out.print(gpa, "- Tool `{s}`: {s} · {d:.2}s\n", .{
            tool.name,
            tool.status,
            diagnosticsSeconds(tool.duration_ms),
        });
    }

    try out.print(gpa, "**OTLP** {s}", .{if (report.otlp_enabled) "enabled" else "disabled"});
    if (report.otlp_enabled) try out.print(gpa, " · {d} pending", .{report.otlp_pending});
    if (report.otlp_last_error.len > 0) try out.print(gpa, " · last error: {s}", .{report.otlp_last_error});
    return out.toOwnedSlice(gpa);
}

fn diagnosticsSeconds(ms: u64) f64 {
    return @as(f64, @floatFromInt(ms)) / 1000.0;
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
    marker: []const u8,
    content_width: usize,
) ![]const u8 {
    const guest_prefix: []const u8 = if (proto.isGuestModel(model)) "(guest) " else "";
    const price = if (pricing) |value| try formatModelPricing(arena, value) else "";
    const price_width = displayWidth(price);
    const price_gap: usize = if (price.len > 0) 2 else 0;
    const marker_width = displayWidth(marker);
    const model_capacity = content_width -| (displayWidth(guest_prefix) + price_width + price_gap + marker_width);
    const model_end = hardCellBreak(model, 0, model_capacity);
    const model_text = model[0..model_end];
    const used = displayWidth(guest_prefix) + displayWidth(model_text) + price_width + marker_width;
    const gap = if (price.len > 0)
        try spaces(arena, content_width -| used)
    else
        "";
    return std.fmt.allocPrint(arena, " {s}{s}{s}{s}{s}", .{ guest_prefix, model_text, gap, price, marker });
}

fn pickerTextPreview(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const cap = utf8Floor(text, @min(text.len, 240));
    var out: std.ArrayList(u8) = .empty;
    var previous_space = false;
    for (text[0..cap]) |byte| {
        const space = byte == '\n' or byte == '\r' or byte == '\t';
        if (space) {
            if (!previous_space) try out.append(arena, ' ');
        } else {
            try out.append(arena, byte);
        }
        previous_space = space;
    }
    if (cap < text.len) try out.appendSlice(arena, "…");
    return out.items;
}

/// Expand `/review <council> <question>` into the parent agent's turn input:
/// the named roster plus the council procedure, so invocation costs the user
/// one line. Caller frees.
fn buildReviewPrompt(gpa: std.mem.Allocator, council: *const OwnedCouncil, question: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "Convene the review council \"{s}\". Reviewers, in order:\n", .{council.name});
    for (council.models.items) |model| try out.print(gpa, "- {s}\n", .{model});
    try out.appendSlice(gpa,
        \\
        \\Load the `council` skill and follow its procedure with exactly this
        \\roster. If the skill is unavailable: write ONE self-contained review
        \\prompt (paths the read-only reviewers can open; paste diff hunks for
        \\anything uncommitted; require verdict, findings with file:line, and
        \\confidence), fan it out with task_batch calls of at most eight tasks
        \\each — one task per reviewer, identical prompt, the model ids above,
        \\and task for a final one-reviewer remainder, max_rounds 12 — then
        \\consolidate: agreements and disagreements
        \\attributed by model, false
        \\positives, and your recommendation. Report reviewers that fail.
        \\
        \\Question for the council:
    );
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, question);
    return out.toOwnedSlice(gpa);
}

fn tabActivityForState(state: proto.SessionState) TabActivity {
    return switch (state) {
        .idle => .idle,
        .done => .done,
        .running => .running,
        .err => .err,
        .awaiting_approval => .approval,
    };
}

fn tabActivityRank(activity: TabActivity) u8 {
    return switch (activity) {
        .idle => 0,
        .done => 1,
        .running => 2,
        .err => 3,
        .approval => 4,
    };
}

fn tabActivityText(activity: TabActivity) []const u8 {
    return switch (activity) {
        .idle => " ·",
        .done => " ✓",
        .running => " ●",
        .err => " ×",
        .approval => " !",
    };
}

const TabCandidate = struct {
    sid: u64,
    label: []const u8,
    activity: TabActivity,
    active: bool,
    created_at: i64,

    fn width(self: TabCandidate) usize {
        // leading space + label + fixed-width activity + trailing space
        return displayWidth(self.label) + 4;
    }
};

fn rootTabPrecedes(a: *const SessionSummary, b: *const SessionSummary) bool {
    return a.created_at < b.created_at or (a.created_at == b.created_at and a.sid < b.sid);
}

/// Return the adjacent root in the tab strip's chronological order, wrapping
/// at either edge. Child sessions never become standalone keyboard targets.
fn nextRootTabSid(sessions: []const SessionSummary, active_sid: u64, direction: i8) ?u64 {
    var first: ?*const SessionSummary = null;
    var last: ?*const SessionSummary = null;
    var active: ?*const SessionSummary = null;

    for (sessions) |*session| {
        if (session.parent_sid != null or session.kind != .root) continue;
        if (first == null or rootTabPrecedes(session, first.?)) first = session;
        if (last == null or rootTabPrecedes(last.?, session)) last = session;
        if (session.sid == active_sid) active = session;
    }
    const current = active orelse return if (direction < 0) (last orelse return null).sid else (first orelse return null).sid;

    var adjacent: ?*const SessionSummary = null;
    for (sessions) |*session| {
        if (session.parent_sid != null or session.kind != .root or session.sid == current.sid) continue;
        if (direction < 0) {
            if (rootTabPrecedes(session, current) and
                (adjacent == null or rootTabPrecedes(adjacent.?, session))) adjacent = session;
        } else {
            if (rootTabPrecedes(current, session) and
                (adjacent == null or rootTabPrecedes(session, adjacent.?))) adjacent = session;
        }
    }
    return if (adjacent) |session| session.sid else if (direction < 0) last.?.sid else first.?.sid;
}

/// The Nth root tab (1-based) in the same order the strip renders:
/// rootTabPrecedes over root sessions. Null when index is 0 or off the end.
fn rootTabSidAtIndex(sessions: []const SessionSummary, index: usize) ?u64 {
    if (index == 0) return null;
    for (sessions) |*candidate| {
        if (candidate.parent_sid != null or candidate.kind != .root) continue;
        var preceding: usize = 0;
        for (sessions) |*other| {
            if (other.parent_sid != null or other.kind != .root or other == candidate) continue;
            if (rootTabPrecedes(other, candidate)) preceding += 1;
        }
        if (preceding == index - 1) return candidate.sid;
    }
    return null;
}

fn tabLabel(
    arena: std.mem.Allocator,
    app: *const App,
    sid: u64,
    summary: ?*const SessionSummary,
) ![]const u8 {
    var handle_buf: session_handle.Full = undefined;
    const handle = app.displaySessionHandle(&handle_buf, sid);
    const short_handle = handle[0..@min(handle.len, 4)];
    const identity = if (summary) |session|
        if (session.title.len > 0)
            session.title
        else if (std.fs.path.basename(session.cwd).len > 0)
            std.fs.path.basename(session.cwd)
        else
            "session"
    else if (std.fs.path.basename(app.cwd.items).len > 0)
        std.fs.path.basename(app.cwd.items)
    else
        "session";
    const raw = try std.fmt.allocPrint(arena, "{s} · {s}", .{ identity, short_handle });
    return raw[0..hardCellBreak(raw, 0, tab_label_max_cells)];
}

/// Build a chronological, root-only tab window. When the full strip does not
/// fit, retain a contiguous neighborhood around the active root and reserve
/// two cells at either edge for overflow markers.
fn layoutTabBar(arena: std.mem.Allocator, app: *const App, width: usize) !TabLayout {
    if (width == 0) return .{ .items = &.{} };

    const active_root = app.rootSessionId(app.sid);
    var candidates: std.ArrayList(TabCandidate) = .empty;
    for (app.sessions.items) |*session| {
        if (session.parent_sid != null or session.kind != .root) continue;
        try candidates.append(arena, .{
            .sid = session.sid,
            .label = try tabLabel(arena, app, session.sid, session),
            .activity = app.tabActivity(session.sid),
            .active = session.sid == active_root,
            .created_at = session.created_at,
        });
    }
    if (candidates.items.len == 0) {
        try candidates.append(arena, .{
            .sid = app.sid,
            .label = try tabLabel(arena, app, app.sid, null),
            .activity = tabActivityForState(app.state),
            .active = true,
            .created_at = 0,
        });
    }
    std.mem.sort(TabCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: TabCandidate, b: TabCandidate) bool {
            return a.created_at < b.created_at or (a.created_at == b.created_at and a.sid < b.sid);
        }
    }.lessThan);

    var active_index: usize = 0;
    var total_width: usize = candidates.items.len - 1; // one-cell gaps
    for (candidates.items, 0..) |candidate, i| {
        total_width += candidate.width();
        if (candidate.active) active_index = i;
    }

    var start: usize = 0;
    var end: usize = candidates.items.len;
    if (total_width > width) {
        const budget = width -| 4;
        start = active_index;
        end = active_index + 1;
        var used = @min(candidates.items[active_index].width(), budget);
        while (true) {
            var changed = false;
            if (end < candidates.items.len) {
                const cost = 1 + candidates.items[end].width();
                if (used + cost <= budget) {
                    used += cost;
                    end += 1;
                    changed = true;
                }
            }
            if (start > 0) {
                const cost = 1 + candidates.items[start - 1].width();
                if (used + cost <= budget) {
                    used += cost;
                    start -= 1;
                    changed = true;
                }
            }
            if (!changed) break;
        }
    }

    const hidden_left = start > 0;
    const hidden_right = end < candidates.items.len;
    const right_limit = width -| (if (hidden_right) @as(usize, 2) else 0);
    var x: usize = if (hidden_left) 2 else 0;
    var items: std.ArrayList(TabLayoutItem) = .empty;
    for (candidates.items[start..end], 0..) |candidate, i| {
        if (x >= right_limit) break;
        const item_width = @min(candidate.width(), right_limit - x);
        try items.append(arena, .{
            .sid = candidate.sid,
            .label = candidate.label,
            .activity = candidate.activity,
            .active = candidate.active,
            .x = x,
            .width = item_width,
        });
        x += item_width;
        if (i + 1 < end - start and x < right_limit) x += 1;
    }
    return .{ .items = items.items, .hidden_left = hidden_left, .hidden_right = hidden_right };
}

/// Word-aware cell-width break for prose. Long tokens fall back to a hard
/// grapheme break, so emoji and CJK never corrupt wrapping or table sizing.
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
    const suggestions = try commandSuggestions(app, arena);
    if (suggestions.len == 0) return;

    const shown: u16 = @intCast(@min(suggestions.len, composer_commands.len));
    const menu_h = shown + 1;
    if (input_top < menu_h) return;
    app.command_selection = @min(app.command_selection, suggestions.len - 1);

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
        const suggestion = suggestions[row];
        const selected = row == app.command_selection;
        const row_style = if (selected) Palette.command_selected else Palette.command_menu;
        const name_style = if (selected) Palette.command_selected_name else Palette.command_name;
        const description_style = if (selected) Palette.command_selected_description else Palette.command_description;
        const row_win = menu.child(.{ .y_off = @intCast(row), .height = 1, .width = menu.width });
        row_win.fill(.{ .style = row_style });

        const label = try std.fmt.allocPrint(arena, " {s}{s}", .{ suggestion.label, suggestion.usage });
        const pad_len: usize = if (label.len < pad.len) pad.len - label.len else 1;
        const segments = [_]vaxis.Segment{
            .{ .text = label, .style = name_style },
            .{ .text = pad[0..pad_len], .style = row_style },
            .{ .text = suggestion.description, .style = description_style },
        };
        _ = row_win.print(&segments, .{ .wrap = .none });
    }

    const hint = menu.child(.{ .y_off = @intCast(shown), .height = 1, .width = menu.width });
    _ = hint.printSegment(.{
        .text = " ↑↓ select · Tab complete · Enter choose",
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
    .{ .key = "</> or ←/→", .description = "previous / next tab" },
    .{ .key = "⌥1–⌥9", .description = "jump to Nth tab (works in insert mode too)" },
    .{ .key = "Ctrl+V", .description = "attach clipboard image (Control, not Command)" },
    .{ .key = "gt / gT", .description = "switch sessions · Ngt = Nth recent" },
    .{ .key = "J", .description = "join lines" },
    .{ .key = "a / A / I", .description = "insert after cursor / line end / line start" },
    .{ .key = "j / k", .description = "scroll one line" },
    .{ .key = "Ctrl+d / Ctrl+u", .description = "scroll one page" },
    .{ .key = "gg / G", .description = "jump to top / bottom" },
    .{ .key = "/ · n/N", .description = "search transcript · next/previous match" },
    .{ .key = "?", .description = "toggle shortcut help" },
    .{ .key = "q", .description = "quit Marlin" },
    .{ .description = "COMPOSER (vim)", .heading = true },
    .{ .key = "h l w b 0 $", .description = "move in the input line" },
    .{ .key = "x / D", .description = "delete char / to line end" },
    .{ .key = "d c y + motion", .description = "operators: w b e 0 $ f t, dd/cc/yy, iw i\" i( …" },
    .{ .key = "counts f t ; ,", .description = "3w d2w 2dd · find char, repeat" },
    .{ .key = "u / Ctrl+R", .description = "undo / redo (normal mode)" },
    .{ .key = "s S C Y o O r ~", .description = "vim synonyms, open line, replace, case" },
    .{ .key = "p", .description = "paste the yank register" },
    .{ .description = "COPY MODE", .heading = true },
    .{ .key = "v", .description = "enter copy mode (cursor over transcript)" },
    .{ .key = "hjkl w b 0 $ g G", .description = "move the cursor" },
    .{ .key = "v / V", .description = "select char-wise / line-wise" },
    .{ .key = "y", .description = "yank: clipboard + paste register" },
    .{ .key = "arrows", .description = "scroll the view" },
    .{ .description = "GLOBAL", .heading = true },
    .{ .key = "Ctrl+R (insert)", .description = "fuzzy-search authored input history" },
    .{ .key = "Enter while working", .description = "steer the active turn" },
    .{ .key = "Ctrl+N", .description = "create a new session" },
    .{ .key = "Ctrl+D (empty)", .description = "archive the current session" },
    .{ .key = "Ctrl+L", .description = "redraw and return to bottom" },
    .{ .key = "Ctrl+T", .description = "toggle tool transcript" },
    .{ .key = "Ctrl+C", .description = "interrupt the active turn" },
};

fn drawCouncilDetail(app: *const App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const council = app.councilByName(app.council_detail_name.items) orelse return;
    const h = win.height;
    const w = win.width;
    if (h < 8 or w < 32) return;

    var widest: usize = displayWidth(council.name) + 10;
    for (council.models.items) |model| widest = @max(widest, displayWidth(model) + 4);
    const box_w: u16 = @intCast(@min(@max(widest, 44) + 4, @as(usize, w -| 4)));
    const shown: u16 = @intCast(@min(council.models.items.len, h -| 7));
    const box_h: u16 = shown + 4;
    const box = win.child(.{
        .x_off = @intCast((w -| box_w) / 2),
        .y_off = @intCast((h -| box_h) / 2),
        .width = box_w,
        .height = box_h,
        .border = .{ .where = .all, .style = Palette.tool },
    });
    box.fill(.{ .style = .{} });

    const title = try std.fmt.allocPrint(arena, " council {s} · {d} models", .{ council.name, council.models.items.len });
    _ = box.printSegment(.{ .text = title, .style = Palette.user }, .{ .wrap = .none });
    for (council.models.items[0..shown], 0..) |model, i| {
        const line = try std.fmt.allocPrint(arena, " {d}. {s}", .{ i + 1, model });
        _ = box.printSegment(.{ .text = line, .style = Palette.tool_out }, .{
            .row_offset = @intCast(i + 1),
            .wrap = .none,
        });
    }
    if (shown < council.models.items.len) {
        const remaining = try std.fmt.allocPrint(arena, " … {d} more", .{council.models.items.len - shown});
        _ = box.printSegment(.{ .text = remaining, .style = Palette.status_muted }, .{
            .row_offset = shown + 1,
            .wrap = .none,
        });
    }
    _ = box.printSegment(.{
        .text = " e edit · Esc close",
        .style = Palette.tool_out,
    }, .{ .row_offset = box_h -| 2, .wrap = .none });
}

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

/// Empty-session welcome card, centered in the transcript area: identity
/// (version + daemon build), the session's model, and first steps. Rendered
/// only while the session has zero transcript lines; any content reclaims
/// the space. No box, no mode — orientation, not chrome.
fn drawWelcome(app: *const App, win: vaxis.Window, top_rows: usize, view_h: usize, arena: std.mem.Allocator) !void {
    if (view_h < 6 or win.width < 40) return;

    const Row = struct { key: []const u8 = "", text: []const u8, style: vaxis.Style = Palette.welcome_dim };
    var rows: std.ArrayList(Row) = .empty;

    try rows.append(arena, .{ .key = "marlin", .text = "v" ++ build_options.version, .style = Palette.welcome_dim });
    const daemon_ver = app.welcome_daemon_version[0..app.welcome_daemon_version_len];
    if (daemon_ver.len > 0) {
        try rows.append(arena, .{ .text = try std.fmt.allocPrint(arena, "daemon v{s} · sandbox {s} · dnsblock {s}", .{
            daemon_ver,
            if (app.welcome_sandbox) "✓" else "off",
            if (app.welcome_dnsblock_rules > 0)
                try std.fmt.allocPrint(arena, "{d} rules", .{app.welcome_dnsblock_rules})
            else
                "off",
        }) });
    }
    if (app.build_mismatch) {
        try rows.append(arena, .{ .text = "⚠ daemon runs a different build — /reboot to sync", .style = Palette.welcome_warn });
    }
    try rows.append(arena, .{ .text = "" });
    if (app.setup_required) {
        try rows.append(arena, .{ .key = "setup", .text = "choose a provider or guest agent", .style = Palette.welcome_title });
        try rows.append(arena, .{ .key = "Enter", .text = "reopen backend selection" });
        try rows.append(arena, .{ .key = "/quit", .text = "leave without configuring" });
        return drawWelcomeRows(win, top_rows, view_h, arena, rows.items);
    }
    try rows.append(arena, .{ .key = "model", .text = app.model.items });
    try rows.append(arena, .{ .text = "" });
    try rows.append(arena, .{ .key = "Enter", .text = "send a prompt" });
    try rows.append(arena, .{ .key = "/", .text = "slash commands · /model switches model" });
    try rows.append(arena, .{ .key = "Ctrl+N", .text = "new session · ⌥1–⌥9 to switch" });
    try rows.append(arena, .{ .key = "Esc ?", .text = "all keyboard shortcuts" });

    return drawWelcomeRows(win, top_rows, view_h, arena, rows.items);
}

fn drawWelcomeRows(win: vaxis.Window, top_rows: usize, view_h: usize, arena: std.mem.Allocator, rows: anytype) !void {
    const key_column: usize = 8;
    var block_w: usize = 0;
    for (rows) |item| block_w = @max(block_w, key_column + displayWidth(item.text));
    block_w = @min(block_w, @as(usize, win.width) -| 2);

    const shown: usize = @min(rows.len, view_h);
    const x_off: usize = (@as(usize, win.width) -| block_w) / 2;
    const y_off: usize = top_rows + (view_h -| shown) / 2;
    for (rows[0..shown], 0..) |item, i| {
        if (item.text.len == 0 and item.key.len == 0) continue;
        const padding = try spaces(arena, key_column -| displayWidth(item.key));
        const segments = [_]vaxis.Segment{
            .{ .text = item.key, .style = Palette.welcome_title },
            .{ .text = padding, .style = .{} },
            .{ .text = item.text, .style = item.style },
        };
        const row_win = win.child(.{
            .x_off = @intCast(x_off),
            .y_off = @intCast(y_off + i),
            .height = 1,
            .width = @intCast(block_w),
        });
        _ = row_win.print(&segments, .{ .wrap = .none });
    }
}

fn tabActivityStyle(activity: TabActivity, active: bool) vaxis.Style {
    var style: vaxis.Style = switch (activity) {
        .idle => .{ .fg = .{ .index = 8 }, .dim = true },
        .done => .{ .fg = .{ .index = 2 } },
        .running => .{ .fg = .{ .index = 3 }, .bold = true },
        .err => .{ .fg = .{ .index = 1 }, .bold = true },
        .approval => .{ .fg = .{ .index = 3 }, .bold = true },
    };
    style.bg = if (active) Palette.prompt_bg else Palette.command_bg;
    return style;
}

fn drawTabBar(app: *App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const bar = win.child(.{ .height = tab_bar_height, .width = win.width });
    bar.fill(.{ .style = Palette.tab_bar });
    app.tab_hits.clearRetainingCapacity();

    const layout = try layoutTabBar(arena, app, win.width);
    if (layout.hidden_left) {
        _ = bar.printSegment(.{ .text = "‹ ", .style = Palette.tab_overflow }, .{ .wrap = .none });
    }
    if (layout.hidden_right and win.width >= 2) {
        _ = bar.printSegment(.{ .text = " ›", .style = Palette.tab_overflow }, .{
            .col_offset = win.width - 2,
            .wrap = .none,
        });
    }

    for (layout.items) |item| {
        if (item.width == 0) continue;
        const style = if (item.active) Palette.tab_active else Palette.tab_inactive;
        const tab = bar.child(.{
            .x_off = @intCast(item.x),
            .width = @intCast(item.width),
            .height = 1,
        });
        tab.fill(.{ .style = style });
        const label_capacity = item.width -| 4;
        const label_end = hardCellBreak(item.label, 0, label_capacity);
        const segments = [_]vaxis.Segment{
            .{ .text = " ", .style = style },
            .{ .text = item.label[0..label_end], .style = style },
            .{ .text = tabActivityText(item.activity), .style = tabActivityStyle(item.activity, item.active) },
            .{ .text = " ", .style = style },
        };
        _ = tab.print(&segments, .{ .wrap = .none });
        app.tab_hits.append(app.gpa, .{
            .start_col = item.x,
            .end_col = item.x + item.width,
            .sid = item.sid,
        }) catch {};
    }
}

const PlanDisplayRange = struct { start: usize = 0, len: usize = 0 };
const max_plan_items: usize = 5;
const plan_frame_rows: usize = 2; // top border + open-bottom padding row
const surface_gap_rows: u16 = 1;

fn planDisplayRange(items: []const PlanItemOwned, max_rows: usize) PlanDisplayRange {
    if (max_rows == 0 or items.len == 0) return .{};
    var focus: ?usize = null;
    for (items, 0..) |item, index| {
        if (item.status == .in_progress) {
            focus = index;
            break;
        }
        if (focus == null and item.status == .pending) focus = index;
    }
    // Completed plans normally leave live chrome immediately; retain this
    // fallback so a restored legacy view remains inspectable.
    const at = focus orelse items.len - 1;
    const len = @min(items.len, max_rows);
    var start = at -| (len / 2);
    if (start + len > items.len) start = items.len - len;
    return .{ .start = start, .len = len };
}

const PlanSurfaceLayout = struct {
    plan_h: u16,
    view_h: u16,
};

fn planSurfaceLayout(
    height: u16,
    top_rows: usize,
    input_h: u16,
    items: []const PlanItemOwned,
) PlanSurfaceLayout {
    const fixed_h = @as(u16, @intCast(top_rows)) + input_h + surface_gap_rows + 1;
    const plan_capacity = height -| (fixed_h + 2);
    const item_capacity = @min(max_plan_items, plan_capacity -| plan_frame_rows);
    const range = planDisplayRange(items, item_capacity);
    const plan_h: u16 = @intCast(if (range.len > 0) range.len + plan_frame_rows else 0);
    return .{
        .plan_h = plan_h,
        .view_h = height -| (fixed_h + plan_h),
    };
}

const PlanMarker = struct {
    glyph: []const u8,
    glyph_style: vaxis.Style,
    text_style: vaxis.Style,
};

fn planMarker(status: block.PlanStatus, session_state: proto.SessionState, spinner_frame: usize) PlanMarker {
    return switch (status) {
        .pending => .{
            .glyph = "·",
            .glyph_style = Palette.plan_pending,
            .text_style = Palette.plan_pending,
        },
        .in_progress => switch (session_state) {
            .running => .{
                .glyph = spinner_frames[spinner_frame % spinner_frames.len],
                .glyph_style = Palette.plan_active,
                .text_style = Palette.plan_active,
            },
            .err => .{
                .glyph = "×",
                .glyph_style = Palette.plan_error,
                .text_style = Palette.plan_pending,
            },
            .idle, .awaiting_approval, .done => .{
                .glyph = "⏸",
                .glyph_style = Palette.plan_pending,
                .text_style = Palette.plan_pending,
            },
        },
        .completed => .{
            .glyph = "✔",
            .glyph_style = Palette.plan_done_mark,
            // Completion changes only the mark. Keep the task readable
            // instead of fading the whole line into the panel background.
            .text_style = Palette.plan_pending,
        },
    };
}

fn formatPlanDuration(arena: std.mem.Allocator, duration_ms: u64) ![]const u8 {
    if (duration_ms < 1_000) return "<1s";
    const seconds = (duration_ms +| 500) / 1_000;
    if (seconds < 60) return std.fmt.allocPrint(arena, "{d}s", .{seconds});
    const minutes = seconds / 60;
    if (minutes < 60)
        return std.fmt.allocPrint(arena, "{d}m {d}s", .{ minutes, seconds % 60 });
    return std.fmt.allocPrint(arena, "{d}h {d}m", .{ minutes / 60, minutes % 60 });
}

const PlanTableWidths = struct { task: usize, time: usize };

fn planTableWidths(total: usize) PlanTableWidths {
    const time = @min(@as(usize, 10), @max(@as(usize, 7), total / 6));
    return .{ .task = total -| (time + 3), .time = time };
}

fn planRule(arena: std.mem.Allocator, width: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    while (used < width) : (used += 1) try out.appendSlice(arena, "─");
    return out.toOwnedSlice(arena);
}

fn planItemTimeMs(app: *const App, item: PlanItemOwned, now_ms: i64) ?u64 {
    if (item.status == .completed)
        return if (item.duration_ms > 0) item.duration_ms else null;
    if (item.status != .in_progress) return null;

    var elapsed = item.duration_ms;
    if (app.state == .running) {
        const started = if (item.started_at_ms > 0) item.started_at_ms else app.turn_started_ms;
        if (started > 0 and now_ms > started) elapsed +|= @intCast(now_ms - started);
        // Render immediate feedback instead of a blank cell for the first ms.
        if (elapsed == 0) elapsed = 1;
    }
    return if (elapsed > 0) elapsed else null;
}

fn drawPlan(
    app: *App,
    win: vaxis.Window,
    arena: std.mem.Allocator,
    top: u16,
    height: u16,
) !void {
    if (height == 0) return;
    const panel = win.child(.{ .y_off = top, .height = height, .width = win.width });
    panel.fill(.{ .style = Palette.plan_panel });
    const item_rows = @as(usize, height) -| plan_frame_rows;
    const range = planDisplayRange(app.plan.items, item_rows);
    const widths = planTableWidths(win.width);
    const task_header = try planRule(arena, widths.task);
    const time_header = try planRule(arena, widths.time);
    const top_border = [_]vaxis.Segment{
        .{ .text = "┌", .style = Palette.plan_header },
        .{ .text = task_header, .style = Palette.plan_header },
        .{ .text = "┬", .style = Palette.plan_header },
        .{ .text = time_header, .style = Palette.plan_header },
        .{ .text = "┐", .style = Palette.plan_header },
    };
    _ = panel.print(&top_border, .{ .wrap = .none });

    const now_ms = nowWallMs(app.io);
    for (app.plan.items[range.start .. range.start + range.len], 0..) |item, row| {
        const marker = planMarker(item.status, app.state, app.spinner_frame);
        const available = widths.task -| 3;
        const end = hardCellBreak(item.step, 0, available);
        const left = [_]vaxis.Segment{
            .{ .text = "│ ", .style = Palette.plan_header },
            .{ .text = marker.glyph, .style = marker.glyph_style },
            .{ .text = " ", .style = marker.text_style },
            .{ .text = item.step[0..end], .style = marker.text_style },
        };
        const row_offset: u16 = @intCast(row + 1);
        _ = panel.print(&left, .{ .row_offset = row_offset, .wrap = .none });
        _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
            .row_offset = row_offset,
            .col_offset = @intCast(widths.task + 1),
            .wrap = .none,
        });
        if (planItemTimeMs(app, item, now_ms)) |time_ms| {
            const time = try formatPlanDuration(arena, time_ms);
            const time_cells = displayWidth(time);
            _ = panel.printSegment(.{ .text = time, .style = marker.text_style }, .{
                .row_offset = row_offset,
                .col_offset = @intCast(widths.task + 2 + widths.time -| (time_cells + 1)),
                .wrap = .none,
            });
        }
        _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
            .row_offset = row_offset,
            .col_offset = win.width - 1,
            .wrap = .none,
        });
    }

    // The final row is breathing room inside the open-bottom table. Keep all
    // three vertical rules so its frame reaches the composer below.
    const padding_row = height - 1;
    _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
        .row_offset = padding_row,
        .wrap = .none,
    });
    _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
        .row_offset = padding_row,
        .col_offset = @intCast(widths.task + 1),
        .wrap = .none,
    });
    _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
        .row_offset = padding_row,
        .col_offset = win.width - 1,
        .wrap = .none,
    });
}

fn draw(app: *App, vx: *vaxis.Vaxis, arena: std.mem.Allocator) !void {
    const win = vx.window();
    win.clear();
    app.tab_hits.clearRetainingCapacity();
    const h = win.height;
    const w = win.width;
    if (h < 4 or w < 20) return;

    if (app.show_tab_bar) try drawTabBar(app, win, arena);
    const top_rows = app.tabBarRows();

    // The composer is a three-row panel for a one-line prompt (padding,
    // content, padding) and grows with multiline input.
    const prompt: []const u8 = if (app.history_search_active) search_prompt: {
        const query = app.history_search_query.items;
        const query_end = hardCellBreak(query, 0, @max(@as(usize, w) / 3, 1));
        break :search_prompt try std.fmt.allocPrint(arena, "⌕ '{s}'▏: ", .{query[0..query_end]});
    } else if (app.setup_prompt != .none)
        switch (app.setup_prompt) {
            .none => unreachable,
            .credential => "API key ❯ ",
            .base_url => "base URL ❯ ",
            .model => "model ❯ ",
            .provider_name => "provider ❯ ",
        }
    else if (app.otel_header_prompt)
        "OTLP headers ❯ "
    else if (app.plan_mode)
        if (app.mode == .insert) "PLAN ❯ " else "PLAN : "
    else if (app.mode == .insert)
        "❯ "
    else
        ": ";
    const panel_inner_w = w -| 2; // one cell of horizontal padding
    const editor_body_w = @max(panel_inner_w -| displayWidth(prompt), 1);
    const content_h: u16 = @intCast(app.editor.displayHeight(editor_body_w));
    const proposal_ready = app.plan_mode and app.plan_proposal_ready and app.state == .idle;
    const input_h: u16 = @intCast(inputPanelHeight(content_h) + @intFromBool(proposal_ready));
    // The plan's final framed row provides breathing room before the composer;
    // the ordinary transcript gap remains above the lowest surface.
    const surfaces = planSurfaceLayout(h, top_rows, input_h, app.plan.items);
    const plan_h = surfaces.plan_h;
    const view_h = surfaces.view_h;

    // ---- session view ----
    var transcript = transcriptView(app);
    // On very short terminals the TODO panel may not fit; keep the ordinary
    // ticker in that case so liveness never disappears with the panel.
    transcript.show_working_ticker = plan_h == 0;
    var lines = try layout_mod.layoutLines(arena, app.gpa, &transcript, w);
    const total = lines.items.len;
    if (app.search_target_seq > 0 and !app.history_loading) {
        var target_index: ?usize = null;
        for (app.blocks.items, 0..) |rendered, index| {
            if (rendered.seq == app.search_target_seq) {
                target_index = index;
                break;
            }
        }
        if (target_index) |index| {
            var prefix_lines: std.ArrayList(Line) = .empty;
            var last_tool_label: []const u8 = "";
            try layoutBlockRange(
                arena,
                &transcript,
                &prefix_lines,
                0,
                index + 1,
                w,
                &last_tool_label,
                true,
            );
            const target_line = prefix_lines.items.len -| 1;
            const max_scroll = total -| view_h;
            const desired_first = target_line -| (@as(usize, view_h) / 3);
            app.scroll_up = max_scroll -| @min(desired_first, max_scroll);
            app.search_highlight_line = target_line;
            // Avoid treating this deliberate reposition as transcript growth.
            app.last_total_lines = total;
        }
        app.search_target_seq = 0;
    }
    // Anchor while reading: scroll_up counts from the BOTTOM, so content
    // arriving while scrolled up would slide the view. Compensate by the
    // growth delta; pinned (scroll_up == 0) stays pinned.
    if (app.scroll_up > 0 and total > app.last_total_lines) {
        app.scroll_up +|= total - app.last_total_lines;
    }
    app.last_total_lines = total;
    const max_scroll = total -| view_h;
    if (app.scroll_up > max_scroll) app.scroll_up = max_scroll;

    const DisplayLine = struct {
        line: Line,
        abs_line: usize,
        selectable: bool,
    };
    var visible: std.ArrayList(DisplayLine) = .empty;
    const prompt_range = layout_mod.activePromptLineRange(&transcript);
    const ordinary_first = total -| view_h;
    const pin_prompt = app.scroll_up == 0 and prompt_range != null and
        prompt_range.?.len + 2 <= view_h and ordinary_first >= prompt_range.?.start;
    if (pin_prompt) {
        const sticky_prompt = prompt_range.?;
        for (lines.items[sticky_prompt.start..][0..sticky_prompt.len], sticky_prompt.start..) |ln, abs_line| {
            var pinned_line = ln;
            // The sticky copy is navigation chrome rather than an editable
            // composer. Give its first content row a distinct anchored mark;
            // the durable prompt in ordinary scrollback keeps the usual ❯.
            if (abs_line == sticky_prompt.start + 1) {
                pinned_line.text = " # ";
                pinned_line.style = Palette.pinned_prompt_mark;
            }
            try visible.append(arena, .{ .line = pinned_line, .abs_line = abs_line, .selectable = false });
        }
        // One blank, non-selectable row keeps the pinned surface visually
        // separate from the live scrollback immediately below it.
        try visible.append(arena, .{
            .line = .{ .text = "", .style = .{} },
            .abs_line = sticky_prompt.start + sticky_prompt.len,
            .selectable = false,
        });
        const pinned_rows = sticky_prompt.len + 1;
        const body_capacity = view_h - pinned_rows;
        const body_floor = sticky_prompt.start + sticky_prompt.len;
        const body_first = @max(body_floor, total -| body_capacity);
        const body_end = @min(body_first + body_capacity, total);
        for (lines.items[body_first..body_end], body_first..) |ln, abs_line| {
            try visible.append(arena, .{ .line = ln, .abs_line = abs_line, .selectable = true });
        }
        app.last_pinned_start = sticky_prompt.start;
        app.last_pinned_rows = pinned_rows;
        app.last_body_first = body_first;
        app.last_body_rows = body_end - body_first;
        app.last_first_visible = body_first;
    } else {
        const first_visible = (total -| view_h) -| app.scroll_up;
        const end_visible = @min(first_visible + view_h, total);
        for (lines.items[first_visible..end_visible], first_visible..) |ln, abs_line| {
            try visible.append(arena, .{ .line = ln, .abs_line = abs_line, .selectable = true });
        }
        app.last_pinned_start = 0;
        app.last_pinned_rows = 0;
        app.last_body_first = first_visible;
        app.last_body_rows = end_visible - first_visible;
        app.last_first_visible = first_visible;
    }
    // Keep terminal viewport geometry even when the transcript has fewer
    // rows; mouse/copy mapping separately rejects blank rows.
    app.last_view_h = view_h;

    // Empty-session welcome card: only when there is genuinely nothing to
    // show (fresh session, replay finished, no turn running).
    if (total == 0 and !app.history_loading and app.state == .idle)
        try drawWelcome(app, win, top_rows, view_h, arena);

    for (visible.items, 0..) |display, row| {
        const ln = display.line;
        const abs_line = display.abs_line;
        if (ln.fill_style) |fill_style| {
            const fill_start = @min(ln.fill_start, w);
            const fill_width = @min(ln.fill_width orelse (w -| fill_start), w -| fill_start);
            const row_win = win.child(.{
                .x_off = @intCast(fill_start),
                .y_off = @intCast(top_rows + row),
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
            .row_offset = @intCast(top_rows + row),
            .wrap = .none,
        });
        applyLineSyntax(win, @intCast(top_rows + row), ln);
        applyLineLinks(win, @intCast(top_rows + row), ln);
        if (display.selectable and app.search_highlight_line == abs_line) {
            var col: usize = 0;
            const width = @min(lineWidth(win, ln), @as(usize, w));
            while (col < width) : (col += 1) {
                const cell = win.readCell(@intCast(col), @intCast(top_rows + row)) orelse continue;
                var highlighted = cell;
                highlighted.style.reverse = true;
                win.writeCell(@intCast(col), @intCast(top_rows + row), highlighted);
            }
        }
        // Apply selection after printing so partial-cell highlighting keeps
        // each segment's original syntax color and other style attributes.
        if (display.selectable) {
            if (app.selection()) |sel| {
                if (sel.columns(abs_line, lineWidth(win, ln))) |cols| {
                    var col = cols.start;
                    while (col < cols.end and col < @as(usize, w)) : (col += 1) {
                        const cell = win.readCell(@intCast(col), @intCast(top_rows + row)) orelse continue;
                        var selected_cell = cell;
                        selected_cell.style.reverse = true;
                        win.writeCell(@intCast(col), @intCast(top_rows + row), selected_cell);
                    }
                }
            }
        }
        if (display.selectable) {
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
                        if (win.readCell(@intCast(col), @intCast(top_rows + row))) |cell| {
                            var cursor_cell = cell;
                            cursor_cell.style.reverse = !cursor_cell.style.reverse;
                            win.writeCell(@intCast(col), @intCast(top_rows + row), cursor_cell);
                        }
                    }
                }
            }
        }
    }

    const input_top = h - 1 - input_h;
    const plan_top = input_top -| plan_h;
    try drawPlan(app, win, arena, plan_top, plan_h);

    // ---- input box ----
    const input_panel = win.child(.{ .y_off = input_top, .height = input_h, .width = w });
    input_panel.fill(.{ .style = Palette.prompt_panel });
    const input_win = input_panel.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = panel_inner_w,
        .height = content_h,
    });
    if (app.otel_header_prompt or app.setup_prompt == .credential)
        app.editor.drawMasked(input_win, prompt, Palette.prompt_mark, Palette.prompt_text)
    else
        app.editor.draw(input_win, prompt, if (app.plan_mode) Palette.plan_active else Palette.prompt_mark, Palette.prompt_text);
    if (proposal_ready) {
        _ = input_panel.printSegment(.{
            .text = " Enter implement · e revise · Esc stay · q dismiss",
            .style = Palette.plan_active,
        }, .{ .row_offset = input_h - 1, .wrap = .none });
    }
    if (app.mode == .normal or app.history_search_active) win.hideCursor();
    if (app.setup_prompt == .none and !app.otel_header_prompt)
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
    const guest = proto.isGuestModel(app.model.items);
    const context_percent = if (app.context_limit > 0)
        app.context_used * 100 / app.context_limit
    else
        0;
    const ctx_txt = try statusContext(arena, guest, app.context_used, app.context_limit);
    const ctx_style = if (guest)
        Palette.status_muted
    else if (context_percent >= 90)
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
    status_segments[status_n] = .{ .text = try statusModel(arena, app.model.items), .style = Palette.status_model };
    status_n += 1;
    if (app.effort != .auto) {
        status_segments[status_n] = .{
            .text = try std.fmt.allocPrint(arena, " {s}", .{@tagName(app.effort)}),
            .style = Palette.status_effort,
        };
        status_n += 1;
    }
    if (ctx_txt.len > 0) {
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
    // Guest sessions cannot use Marlin's sandbox or dnsblock — show the
    // slots muted so they read as unavailable, not toggled off.
    const sandboxed_now = app.currentSandboxed();
    const sandbox_txt: []const u8 = if (guest)
        "⛨ sandbox n/a"
    else if (sandboxed_now)
        "⛨ sandboxed"
    else if (app.conn.sandbox_available)
        "⛨ sandbox off"
    else
        "⛨ no sandbox";
    const sandbox_style = if (guest)
        Palette.status_muted
    else if (sandboxed_now)
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
    const dns_txt: []const u8 = if (guest)
        "dnsblock n/a"
    else if (dns_on)
        "dnsblock on"
    else if (dns_available)
        "dnsblock off"
    else if (app.conn.network_configured)
        "dnsblock err"
    else
        "dnsblock off";
    const dns_style = if (guest)
        Palette.status_muted
    else if (dns_on)
        Palette.status_running
    else if (dns_available or app.conn.network_configured)
        Palette.status_context_warn
    else
        Palette.status_sep;
    const mode_txt: []const u8 = if (app.plan_mode) "PLAN" else if (app.permissions_full) "FULL ACCESS" else "";
    // Voice dictation state. Invisible until /voice setup enables it —
    // dormant means dormant — then a quiet armed hint that turns loud
    // while a capture or transcription is in flight.
    var voice_buf: [24]u8 = undefined;
    var voice_txt: []const u8 = "";
    var voice_cols: u16 = 0;
    var voice_style: vaxis.Style = Palette.status_sep;
    if (app.voice_rt.enabled) switch (app.voice_rt.phase) {
        .idle => {
            const ptt = if (app.voice_rt.setup) |st|
                st.mode == .ptt and app.voice_rt.kitty_release
            else
                false;
            voice_txt = if (ptt) "mic·ptt" else "mic·tap";
            voice_cols = 7; // "·" renders one cell
        },
        .recording => {
            const secs = @divTrunc(@max(0, nowWallMs(app.io) - app.voice_rt.record_started_ms), 1000);
            voice_txt = std.fmt.bufPrint(&voice_buf, "● rec {d}s", .{secs}) catch "● rec";
            voice_cols = @intCast(voice_txt.len - "●".len + 1);
            voice_style = Palette.status_approval;
        },
        .transcribing => {
            voice_txt = "… stt";
            voice_cols = 5;
            voice_style = Palette.status_running;
        },
    };
    var right_w: u16 = sandbox_cols + 1 + @as(u16, @intCast(dns_txt.len)) + 3;
    if (mode_txt.len > 0) right_w += @intCast(mode_txt.len + 3);
    if (voice_txt.len > 0) right_w += voice_cols + 3;
    if (status_win.width > right_w) {
        const right_win = status_win.child(.{
            .x_off = @intCast(status_win.width - right_w),
            .width = right_w,
        });
        var right_segments: [8]vaxis.Segment = undefined;
        var right_n: usize = 0;
        if (voice_txt.len > 0) {
            right_segments[right_n] = .{ .text = voice_txt, .style = voice_style };
            right_n += 1;
            right_segments[right_n] = .{ .text = " · ", .style = Palette.status_sep };
            right_n += 1;
        }
        if (mode_txt.len > 0) {
            right_segments[right_n] = .{ .text = mode_txt, .style = if (app.plan_mode) Palette.plan_active else Palette.status_approval };
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
        const total_src = app.pickerSourceCount();
        const current = app.pickerCurrent();
        const picker_label: []const u8 = switch (app.picker_kind) {
            .model => "model",
            .effort => "effort",
            .session => "sessions",
            .search_prompt => if (app.search_scope_sid == 0) "search all sessions" else "search this session",
            .search => if (app.search_scope_sid == 0) "search results" else "session matches",
            .council => try std.fmt.allocPrint(arena, "council {s} · {d} selected", .{
                app.council_edit_name.items,
                app.council_edit_models.items.len,
            }),
            .council_list => "councils",
            .voice_engine => "voice engine",
            .voice_mode => "voice input mode",
            .setup_provider => "setup · choose a backend",
        };

        const list_max: u16 = @min(@as(u16, 14), h -| 6);
        const win_start = if (sel >= list_max) sel + 1 - list_max else 0;
        const visible_end = @min(items.len, win_start + list_max);
        var widest: usize = 30;
        for (items[win_start..visible_end]) |f| {
            const displayed = if (app.picker_kind == .search)
                try pickerTextPreview(arena, f)
            else
                f;
            var row_width = displayWidth(displayed);
            if (app.picker_kind == .setup_provider) row_width += displayWidth(app.setupProviderNote(f));
            if (app.picker_kind == .council and !std.mem.eql(u8, f, council_done_item)) row_width += 2;
            if (app.picker_kind == .model or app.picker_kind == .council) {
                if (proto.isGuestModel(f)) row_width += displayWidth("(guest) ");
                if (app.pricingForModel(f)) |pricing| {
                    row_width += 2 + displayWidth(try formatModelPricing(arena, pricing));
                }
            }
            widest = @max(widest, @min(row_width, 96));
        }
        const box_w: u16 = @intCast(@min(widest + 8, @as(usize, w -| 4)));
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
        const src_note: []const u8 = if ((app.picker_kind == .model or app.picker_kind == .council) and app.catalog.items.len == 0)
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
        var row: u16 = 1;
        var i: usize = win_start;
        while (i < items.len and row <= shown) : (i += 1) {
            const f = items[i];
            const done = app.picker_kind == .council and std.mem.eql(u8, f, council_done_item);
            const cur = if (app.picker_kind == .session)
                (app.sessionIdForLabel(f) orelse 0) == app.sid
            else if (app.picker_kind == .council)
                !done and app.councilModelSelected(f)
            else
                std.mem.eql(u8, f, current);
            const line = if (app.picker_kind == .model)
                try pickerModelLine(arena, f, app.pricingForModel(f), if (cur) " ●" else "", box_w -| 4)
            else if (app.picker_kind == .council)
                if (done)
                    try std.fmt.allocPrint(arena, " ✓ Done ({d} selected)", .{app.council_edit_models.items.len})
                else
                    try pickerModelLine(arena, f, app.pricingForModel(f), if (cur) " ☑" else " ☐", box_w -| 4)
            else if (app.picker_kind == .council_list)
                if (app.councilByName(f)) |council|
                    try std.fmt.allocPrint(arena, " {s} · {d} models", .{ f, council.models.items.len })
                else
                    f
            else if (app.picker_kind == .search)
                try std.fmt.allocPrint(arena, " {s}", .{try pickerTextPreview(arena, f)})
            else if (app.picker_kind == .setup_provider)
                try std.fmt.allocPrint(arena, " {s}{s}", .{ f, app.setupProviderNote(f) })
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
        const hint = switch (app.picker_kind) {
            .session => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter · Del/Ctrl+D archive · Esc", .{ items.len, total_src }),
            .search_prompt => if (app.search_pending) " searching… · Esc" else " type query · Enter search · Esc",
            .search => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter jump · Esc", .{ items.len, total_src }),
            .council => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter toggle/Done · Esc cancel", .{ items.len -| 1, total_src }),
            .council_list => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter inspect · Esc", .{ items.len, total_src }),
            .setup_provider => " type=filter · ↑↓ · Enter choose · Esc close",
            else => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter · Esc", .{ items.len, total_src }),
        };
        _ = box.printSegment(.{ .text = hint, .style = Palette.tool_out }, .{ .row_offset = shown + 1, .wrap = .none });
    }

    if (app.council_detail_name.items.len > 0 and app.picker == null)
        try drawCouncilDetail(app, win, arena)
    else if (app.shortcut_help and app.picker == null)
        try drawShortcutHelp(win, arena);

    drawUiAnimation(app, win);
}

fn matrixHash(value: u64) u64 {
    var x = value;
    x ^= x >> 30;
    x *%= 0xbf58476d1ce4e5b9;
    x ^= x >> 27;
    x *%= 0x94d049bb133111eb;
    return x ^ (x >> 31);
}

fn drawUiAnimation(app: *const App, win: vaxis.Window) void {
    switch (app.ui_animation) {
        .none => {},
        .matrix => drawMatrixAnimation(app, win),
    }
}

fn matrixWaveOpacity(frame: usize, total_frames: usize) u8 {
    const fade_in_frames: usize = 10;
    const fade_out_frames: usize = 22;
    if (frame < fade_in_frames)
        return @intCast(frame * 255 / fade_in_frames);

    const remaining = (total_frames - 1) -| frame;
    if (remaining < fade_out_frames)
        return @intCast(remaining * 255 / fade_out_frames);
    return 255;
}

fn matrixWaveFront(frame: usize, total_frames: usize, height: u16, max_trail: usize) i64 {
    const start: i64 = 2;
    const end = @as(i64, height) + @as(i64, @intCast(max_trail));
    const clamped_frame = @min(frame, total_frames - 1);
    return start + @divTrunc(
        @as(i64, @intCast(clamped_frame)) * (end - start),
        @as(i64, @intCast(total_frames - 1)),
    );
}

fn matrixWaveColor(base: [3]u8, opacity: u8) vaxis.Color {
    return .{ .rgb = .{
        @intCast(@as(u16, base[0]) * opacity / 255),
        @intCast(@as(u16, base[1]) * opacity / 255),
        @intCast(@as(u16, base[2]) * opacity / 255),
    } };
}

fn matrixCellIsOpen(win: vaxis.Window, col: u16, row: u16) bool {
    const cell = win.readCell(col, row) orelse return false;
    if (!std.mem.eql(u8, cell.char.grapheme, " ")) return false;
    if (col == 0) return true;

    const previous = win.readCell(col - 1, row) orelse return true;
    const previous_width = if (previous.char.width > 0)
        previous.char.width
    else
        win.gwidth(previous.char.grapheme);
    return previous_width <= 1;
}

fn drawMatrixAnimation(app: *const App, win: vaxis.Window) void {
    if (win.width == 0 or win.height == 0) return;
    const glyphs = [_][]const u8{
        "ｱ",
        "ｲ",
        "ｳ",
        "ｴ",
        "ｵ",
        "ｶ",
        "ｷ",
        "ｸ",
        "ｹ",
        "ｺ",
        "ｻ",
        "ｼ",
        "ｽ",
        "ｾ",
        "ｿ",
        "ﾀ",
        "ﾁ",
        "ﾂ",
        "ﾃ",
        "ﾄ",
        "ﾅ",
        "ﾆ",
        "ﾇ",
        "ﾈ",
        "ﾉ",
        "ﾊ",
        "ﾋ",
        "ﾌ",
        "ﾍ",
        "ﾎ",
        "ﾏ",
        "ﾐ",
        "ﾑ",
        "ﾒ",
        "ﾓ",
        "ﾔ",
        "ﾕ",
        "ﾖ",
        "ﾗ",
        "ﾘ",
        "ﾙ",
        "ﾚ",
        "ﾛ",
        "ﾜ",
        "ｦ",
        "ﾝ",
        "0",
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
        "7",
        "8",
        "9",
        "◦",
        "·",
        "¦",
        "┊",
        "╎",
        "╌",
        "⌁",
        "⟡",
    };
    const max_trail = matrixTrailLength(win.height);
    const min_trail = @min(max_trail, @max(@as(usize, win.height) / 2, 6));
    const streams_per_column = 3;
    const opacity = matrixWaveOpacity(app.ui_animation_frame, app.ui_animation_frames);
    const wave_front = matrixWaveFront(app.ui_animation_frame, app.ui_animation_frames, win.height, max_trail);

    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        for (0..streams_per_column) |lane| {
            const stream = matrixHash(app.ui_animation_seed +%
                @as(u64, col) *% 0x9e3779b97f4a7c15 +%
                @as(u64, lane) *% 0xd1b54a32d192ed03);
            if (lane > 0 and stream % 7 == 0) continue;

            const trail_len = min_trail + @as(usize, @intCast((stream >> 24) % (max_trail - min_trail + 1)));
            const stagger: i64 = @intCast((stream >> 40) % 9);
            const lane_offset: i64 = @intCast(lane * 4);
            const head = wave_front - stagger - lane_offset;

            var trail: usize = 0;
            while (trail < trail_len) : (trail += 1) {
                const row = head - @as(i64, @intCast(trail));
                if (row < 0 or row >= win.height) continue;
                if (!matrixCellIsOpen(win, col, @intCast(row))) continue;

                const visibility = matrixHash(stream +%
                    @as(u64, @intCast(row)) *% 0x94d049bb133111eb +%
                    @as(u64, trail) *% 0xbf58476d1ce4e5b9);
                if (visibility & 0xff >= opacity) continue;

                var cell = win.readCell(col, @intCast(row)) orelse continue;
                const glyph_hash = matrixHash(stream +%
                    @as(u64, app.ui_animation_frame / 2) *% 17 +%
                    @as(u64, trail));
                cell.char = .{ .grapheme = glyphs[glyph_hash % glyphs.len], .width = 1 };
                cell.style.fg = if (trail == 0)
                    matrixWaveColor(.{ 0xd8, 0xff, 0xdc }, opacity)
                else if (trail < 4)
                    matrixWaveColor(.{ 0x68, 0xf5, 0x82 }, opacity)
                else
                    matrixWaveColor(.{ 0x18, 0xa8, 0x45 }, opacity);
                cell.style.bold = trail <= 1;
                cell.style.dim = trail > trail_len / 2;
                cell.link = .{};
                cell.image = null;
                cell.default = false;
                win.writeCell(col, @intCast(row), cell);
            }
        }
    }
}

// ------------------------------------------------------------ entry point --

/// Reader thread: daemon socket lines → vaxis event queue.
fn readerThread(gpa: std.mem.Allocator, conn: *attach.Conn, loop: *vaxis.Loop(Event)) void {
    var disconnect_reason: []const u8 = "reader stopped";
    while (true) {
        const owned = conn.readLine() catch |err| {
            disconnect_reason = @errorName(err);
            break;
        };
        loop.postEvent(.{ .daemon_line = owned }) catch {
            gpa.free(owned);
            return;
        };
    }
    loop.postEvent(.{ .daemon_gone = disconnect_reason }) catch {};
}

/// Transport death is recoverable, not fatal: the daemon resyncs STATE on
/// resubscribe (from_seq replay), so a dropped local socket (daemon restart)
/// or ssh child (laptop sleep, network hop) just needs a new transport under
/// the same view — the mosh-like behavior, with state instead of pixels.
const ReconnectJob = struct {
    app: *App,
    loop: *vaxis.Loop(Event),
    self_exe: []const u8,
    cancel: attach.ConnectCancel = .{},

    fn stop(self: *ReconnectJob) void {
        self.cancel.cancel();
    }

    fn waitBetweenAttempts(self: *ReconnectJob) bool {
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < 1_500) : (elapsed_ms += 50) {
            if (self.cancel.isCancelled()) return false;
            self.app.io.sleep(.fromMilliseconds(50), .awake) catch {};
        }
        return !self.cancel.isCancelled();
    }

    /// Bounded retries remain interruptible: quitting cancels an in-flight
    /// local/SSH handshake and the spacing sleep, so teardown does not wait on
    /// remote handshake deadlines.
    fn run(job: *ReconnectJob) void {
        var attempt: u32 = 0;
        while (attempt < 3) : (attempt += 1) {
            if (attempt > 0 and !job.waitBetweenAttempts()) return;
            const environ = job.app.environ orelse break;
            const conn = attach.connectCancelable(job.app.gpa, job.app.io, environ, job.self_exe, &job.cancel) catch |err| {
                if (err == error.ConnectCanceled) return;
                continue;
            };
            if (job.cancel.isCancelled()) {
                conn.deinit();
                return;
            }
            job.loop.postEvent(.{ .reconnected = conn }) catch conn.deinit();
            return;
        }
        if (!job.cancel.isCancelled()) job.loop.postEvent(.{ .reconnected = null }) catch {};
    }
};

/// Swap the dead transport for the fresh one and restore the exact client
/// state: catalog watch, council cache, and the focused session resumed from
/// the last applied block — the same continuation a tab switch uses, so the
/// transcript and scroll position survive untouched. Returns false when the
/// TUI cannot be made whole (caller quits with the old semantics).
fn adoptReconnectedConn(app: *App, loop: *vaxis.Loop(Event), rt: *std.Thread, new_conn: *attach.Conn) bool {
    // Restore subscriptions before publishing the transport to App. A failed
    // replay request then leaves the dead connection as the sole owner and the
    // fresh connection can be destroyed without a reader thread racing it.
    new_conn.send(.{ .session_watch = .{ .incremental = true } }) catch {
        new_conn.deinit();
        return false;
    };
    new_conn.send(.{ .council_list = .{} }) catch {};
    if (app.last_seq == 0) {
        new_conn.send(.{ .sub = .{
            .sid = app.sid,
            .from_seq = 1,
            .tail_limit = initial_replay_blocks,
        } }) catch {
            new_conn.deinit();
            return false;
        };
    } else {
        new_conn.send(.{ .sub = .{
            .sid = app.sid,
            .from_seq = app.last_seq +| 1,
            .replay_limit = initial_replay_blocks,
        } }) catch {
            new_conn.deinit();
            return false;
        };
    }

    // Start the replacement reader against its explicit Conn before swapping
    // App ownership. If spawn fails, the deferred exit join still owns the old
    // thread handle; otherwise its daemon_gone post means this join is immediate.
    const new_rt = std.Thread.spawn(.{}, readerThread, .{ app.gpa, new_conn, loop }) catch {
        new_conn.deinit();
        return false;
    };
    rt.join();
    const old = app.conn;
    app.conn = new_conn;
    rt.* = new_rt;
    old.deinit();
    app.cacheWelcomeFacts();
    if (app.awaiting_new_session) {
        app.awaiting_new_session = false;
        app.pending_new_session_request_id = 0;
        app.pending_new_cwd.clearRetainingCapacity();
        app.setNotice("reconnected · retry /new if the session was not created", .{});
    } else {
        app.setNotice("reconnected", .{});
    }
    return true;
}

/// mtime (ms) of this client's own binary, for stale-daemon detection
/// against hello_ok's daemon_exe_mtime_ms. null when unresolvable.
fn selfExeMtimeMs(gpa: std.mem.Allocator, io: Io) ?i64 {
    const path = std.process.executablePathAlloc(io, gpa) catch return null;
    defer gpa.free(path);
    const st = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms));
}

fn animationThread(app: *App, loop: *vaxis.Loop(Event)) void {
    while (!app.animation_stop.load(.acquire)) {
        if (app.animation_active.load(.acquire)) {
            loop.postEvent(.tick) catch return;
            const delay_ms: i64 = if (app.ui_animation_active.load(.acquire)) 33 else 90;
            app.io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
        } else {
            app.io.sleep(.fromMilliseconds(200), .awake) catch {};
        }
    }
}

pub const RebootPlan = struct {
    request: RebootRequest = .{},
    sid: u64 = 0,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    self_exe: []const u8,
    sid_arg: ?[]const u8,
    reboot_out: ?*RebootPlan,
) !u8 {
    // -- connect + pick session BEFORE entering the TUI --
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        std.log.err("cannot reach daemon: {t}", .{e});
        return 1;
    };
    var conn_owned = true;
    defer if (conn_owned) conn.deinit();

    var loaded_config = try config.load(gpa, io, environ);
    defer loaded_config.deinit();
    const cfg = loaded_config.value;
    var model_at_start: []const u8 = cfg.model_default;
    var effort_at_start: proto.ReasoningEffort = cfg.effort_default;
    var model_buf: [256]u8 = undefined;
    var cwd_at_start: []const u8 = "";
    var cwd_buf: [4096]u8 = undefined;
    var initial_known_ids: std.ArrayList(u64) = .empty;
    var setup_at_start: ?SetupReadiness = null;
    var start_setup = false;
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
            // Backend facts come from the daemon host. This matters over SSH:
            // the client machine's config, keys, and installed guest binaries
            // say nothing about what will execute the turn.
            try conn.send(.{ .setup_status = .{ .probe_guests = false } });
            const setup = try conn.recvUntil(arena, .setup_status_result);
            setup_at_start = .fromWire(setup);
            start_setup = !setup.completed and list.sessions.len == 0;
            effort_at_start = setup.default_effort;
            const configured_model_len = @min(setup.default_model.len, model_buf.len);
            @memcpy(model_buf[0..configured_model_len], setup.default_model[0..configured_model_len]);
            model_at_start = model_buf[0..configured_model_len];
            const cwd_len = try std.process.currentPath(io, &cwd_buf);
            cwd_at_start = cwd_buf[0..cwd_len];
            try conn.send(.{ .session_create = .{
                .cwd = cwd_at_start,
                .model = model_at_start,
                .effort = effort_at_start,
            } });
            const created = try conn.recvUntil(arena, .session_created);
            sid = created.sid;
        }
        // Fast initial attach: the newest bounded window. The TUI backfills
        // the durable log if the user actually reaches this window's top.
        try conn.send(.{ .sub = .{
            .sid = sid,
            .from_seq = 1,
            .tail_limit = initial_replay_blocks,
        } });
    }

    var app = App{
        .gpa = gpa,
        .io = io,
        .conn = conn,
        .environ = environ,
        .sid = sid,
        .editor = Editor.init(gpa),
        .known_session_ids = initial_known_ids,
        .cfg = cfg,
        .history_complete = false,
        .history_loading = true,
    };
    initial_ids_transferred = true;
    defer app.deinit();
    app.setModelStr(model_at_start);
    if (setup_at_start) |readiness| app.setup_readiness = readiness;
    app.show_tab_bar = cfg.ui_tab_bar;
    app.effort = effort_at_start;
    app.setCwdStr(cwd_at_start);
    if (environ.get("HOME")) |home| app.setHomeStr(home);
    app.touchRecentSession(sid);
    // Healthy filtering is visible in the status-bar segment already; only
    // a misconfiguration (configured but failed to load) warrants a notice.
    if (!conn.network_filtering and conn.network_configured) {
        app.setNotice("dnsblock configured but unavailable — feed load failed; networking is fail-open", .{});
    }
    // Stale-daemon warning (ordered after the network notice so it wins the
    // single notice slot). The handshake only checks proto_version, and every
    // dev build shares one version string — so also compare the daemon's
    // exe mtime at ITS startup against this client's binary. Local socket
    // only: a remote daemon is another machine's binary by design.
    app.cacheWelcomeFacts();
    if (conn.transport == .socket) {
        const daemon_ver = conn.daemonVersion();
        if (!std.mem.eql(u8, daemon_ver, build_options.version)) {
            app.build_mismatch = true;
            app.setNotice("daemon is {s} but this client is {s} — /reboot to sync", .{ daemon_ver, build_options.version });
        } else if (conn.daemon_exe_mtime_ms != 0) {
            if (selfExeMtimeMs(gpa, io)) |mine| if (mine != conn.daemon_exe_mtime_ms) {
                app.build_mismatch = true;
                app.setNotice("daemon runs a different build than this client — /reboot to sync", .{});
            };
        }
    }
    if (start_setup) app.requestSetup(true);

    var daemon_disconnect_reason: ?[]const u8 = null;
    {
        // -- vaxis init --
        var tty_buf: [4096]u8 = undefined;
        var tty = try vaxis.Tty.init(io, &tty_buf);
        defer tty.deinit();
        const writer = tty.writer();

        var vx = try vaxis.init(io, gpa, environ, .{
            // Doubles as the bracketed-paste allocator: Loop passes it when
            // parsing paste bodies into .paste events.
            .system_clipboard_allocator = gpa,
            // Key releases (voice push-to-talk) on kitty-protocol terminals.
            .kitty_keyboard_flags = .{ .report_events = true },
        });
        defer vx.deinit(gpa, tty.writer());

        var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
        app.loop = &loop;
        try loop.installResizeHandler();
        try loop.start();
        defer loop.stop();

        try vx.enterAltScreen(writer);
        try writer.flush();
        try vx.queryTerminal(tty.writer(), .fromSeconds(1));
        app.voice_rt.kitty_release = vx.caps.kitty_keyboard;
        app.initVoiceFromConfig();
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
            app.term_rows = ws.rows;
            try vx.resize(gpa, tty.writer(), ws);
        }

        // -- daemon reader thread --
        var rt = try std.Thread.spawn(.{}, readerThread, .{ app.gpa, app.conn, &loop });
        // Joined at exit: we shutdown() the socket which EOFs the reader —
        // closing the fd under a live read is a BADF panic on the Threaded Io.
        // Both defers read their CURRENT values: reconnection replaces the
        // conn and respawns the reader mid-session.
        defer app.conn.deinit();
        defer rt.join();
        defer app.conn.shutdown();
        conn_owned = false;
        var reconnect_job: ReconnectJob = undefined;
        var reconnect_thread: ?std.Thread = null;
        defer if (reconnect_thread) |t| {
            reconnect_job.stop();
            t.join();
        };
        // Lightweight catalog/status updates for every session; block streams
        // remain subscribed only for the focused session.
        try conn.send(.{ .session_watch = .{ .incremental = true } });
        // Council cache for /review expansion; silent (no notice pending).
        conn.send(.{ .council_list = .{} }) catch {};

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
            // Transport verdicts are collected here and handled once below
            // the switch: daemon_gone can surface in the drain loop too, and
            // starting/adopting a reconnect must happen exactly once a frame.
            var conn_lost: ?[]const u8 = null;
            var reconnect_verdict: ??*attach.Conn = null;
            switch (event) {
                .key_press => |key| try handleKey(&app, key),
                .key_release => |key| {
                    if (isVoiceKey(key) and app.voice_rt.phase == .recording and
                        app.voice_rt.setup != null and app.voice_rt.setup.?.mode == .ptt)
                        app.stopVoiceRecording();
                },
                .voice => |vev| app.handleVoiceEvent(vev),
                .mouse => |m| handleMouse(&app, m),
                .tick => {
                    app.spinner_frame +%= 1;
                    app.voiceTick();
                    app.tickUiAnimation();
                },
                .winsize => |ws| {
                    app.term_cols = ws.cols;
                    app.term_rows = ws.rows;
                    try vx.resize(gpa, tty.writer(), ws);
                },
                .paste => |text| {
                    app.editor.paste(text);
                    if (app.otel_header_prompt or app.setup_prompt == .credential) @memset(@constCast(text), 0);
                    gpa.free(@constCast(text));
                },
                .daemon_line => |line| {
                    app.handleDaemonLine(line);
                    // Drain any additional queued lines before redrawing.
                    while (try loop.tryEvent()) |ev2| {
                        switch (ev2) {
                            .daemon_line => |l2| app.handleDaemonLine(l2),
                            .daemon_gone => |reason| conn_lost = reason,
                            .reconnected => |maybe| reconnect_verdict = maybe,
                            .key_press => |k2| try handleKey(&app, k2),
                            .key_release => |k2| {
                                if (isVoiceKey(k2) and app.voice_rt.phase == .recording and
                                    app.voice_rt.setup != null and app.voice_rt.setup.?.mode == .ptt)
                                    app.stopVoiceRecording();
                            },
                            .voice => |vev| app.handleVoiceEvent(vev),
                            .mouse => |m2| handleMouse(&app, m2),
                            .tick => {
                                app.spinner_frame +%= 1;
                                app.voiceTick();
                                app.tickUiAnimation();
                            },
                            .winsize => |ws2| {
                                app.term_cols = ws2.cols;
                                app.term_rows = ws2.rows;
                                try vx.resize(gpa, tty.writer(), ws2);
                            },
                            .paste => |t2| {
                                app.editor.paste(t2);
                                if (app.otel_header_prompt or app.setup_prompt == .credential) @memset(@constCast(t2), 0);
                                gpa.free(@constCast(t2));
                            },
                        }
                    }
                },
                .daemon_gone => |reason| conn_lost = reason,
                .reconnected => |maybe| reconnect_verdict = maybe,
            }

            if (conn_lost) |reason| {
                // A deliberate quit/reboot expects its transport to die; only
                // an unexpected loss gets the reconnect treatment. The dead
                // conn stays allocated until adoption so in-flight sends fail
                // harmlessly instead of using freed memory.
                if (app.should_quit or reconnect_thread != null) {
                    daemon_disconnect_reason = reason;
                    app.should_quit = true;
                } else {
                    app.setNotice("connection lost — reconnecting…", .{});
                    reconnect_job = .{ .app = &app, .loop = &loop, .self_exe = self_exe };
                    reconnect_thread = std.Thread.spawn(.{}, ReconnectJob.run, .{&reconnect_job}) catch blk: {
                        daemon_disconnect_reason = reason;
                        app.should_quit = true;
                        break :blk null;
                    };
                }
            }
            if (reconnect_verdict) |maybe_conn| {
                if (reconnect_thread) |t| {
                    t.join();
                    reconnect_thread = null;
                }
                const restored = if (maybe_conn) |new_conn|
                    adoptReconnectedConn(&app, &loop, &rt, new_conn)
                else
                    false;
                if (!restored) {
                    daemon_disconnect_reason = "reconnect failed";
                    app.should_quit = true;
                }
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
                const staged_bytes: u64 = app.clipboard_pending.items.len;
                app.clipboard_pending.clearRetainingCapacity();
                if (!copied) {
                    app.setNotice("clipboard copy failed", .{});
                } else if (app.clipboard_desc.items.len > 0) {
                    app.setNotice("copied {s} output · {Bi:.1}", .{ app.clipboard_desc.items, staged_bytes });
                } else {
                    app.setNotice("copied last tool output", .{});
                }
                app.clipboard_desc.clearRetainingCapacity();
            }

            try draw(&app, &vx, frame_arena.allocator());
            try vx.render(writer);
            try writer.flush();
        }

        // A quit that raced an in-flight reconnect can leave the worker's
        // fresh Conn (and its ssh child) queued and unowned: join the worker
        // first, then reap anything it posted.
        if (reconnect_thread) |t| {
            reconnect_job.stop();
            t.join();
            reconnect_thread = null;
        }
        while (loop.tryEvent() catch null) |ev| switch (ev) {
            .reconnected => |maybe| if (maybe) |c| c.deinit(),
            .daemon_line => |l| gpa.free(l),
            .paste => |t| gpa.free(@constCast(t)),
            else => {},
        };
    }
    if (reboot_out) |ro| ro.* = .{ .request = app.reboot_request, .sid = app.sid };
    if (daemon_disconnect_reason) |reason| {
        try eprint(
            io,
            "marlin: daemon connection lost ({s}); session is durable — reattach to continue\n",
            .{reason},
        );
        return 1;
    }
    return 0;
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn onOff(enabled: bool) []const u8 {
    return if (enabled) "on" else "off";
}

fn tabMouseAction(m: vaxis.Mouse) ?TabMouseAction {
    if (m.type != .press) return null;
    return switch (m.button) {
        .left => .activate,
        .right => .context_menu,
        else => null,
    };
}

/// Mouse: the wheel ALWAYS scrolls the session view — never the input box,
/// never history. A left click on the permanent top strip activates its tab.
/// Left press/drag/release below it selects terminal-cell ranges; release
/// copies the precise range via OSC52.
fn handleMouse(app: *App, m: vaxis.Mouse) void {
    // Some terminals report the release button as `none`, so complete an
    // active left-button drag based on event type before switching on button.
    if (m.type == .release and app.sel_dragging) {
        if (app.last_view_h > 0) {
            const terminal_row: usize = if (m.row < 0) 0 else @intCast(m.row);
            const raw_row = terminal_row -| app.tabBarRows();
            const row = @min(raw_row, app.last_view_h - 1);
            const col: usize = if (m.col < 0) 0 else @intCast(m.col);
            if (app.visibleLineAtRow(row)) |line|
                app.sel_head = .{ .line = line, .col = col };
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

    const terminal_row: usize = if (m.row < 0) 0 else @intCast(m.row);
    if (terminal_row < app.tabBarRows()) {
        const col: usize = if (m.col < 0) 0 else @intCast(m.col);
        if (app.tabAtColumn(col)) |sid| {
            if (tabMouseAction(m)) |action| switch (action) {
                // A tab flagged ! takes you TO the parked approval, not to
                // the tree's root; keyboard jumps (alt+N, gt) stay literal.
                .activate => {
                    const target = app.awaitingSessionInTree(sid) orelse sid;
                    app.switchSession(target, true) catch app.setNotice("could not switch session", .{});
                },
                // Reserved for a future tab menu; right-click intentionally
                // has no product behavior yet.
                .context_menu => {},
            };
        }
        // Preserve the global wheel contract even when the pointer happens
        // to be over the strip; other non-click events belong to no view.
        if (m.button != .wheel_up and m.button != .wheel_down) return;
    }

    switch (m.button) {
        .wheel_up => {
            app.scroll_up +|= 3;
            app.maybeRequestHistoryAtTop();
        },
        .wheel_down => app.scroll_up -|= 3,
        .left => {
            const row = terminal_row - app.tabBarRows();
            // Only selectable body rows inside the session view participate;
            // the sticky prompt is a duplicate of durable scrollback.
            if (row >= app.last_view_h or app.visibleLineAtRow(row) == null) {
                if (m.type == .press) app.sel_anchor = null;
                return;
            }
            const point = SelectionPoint{
                .line = app.visibleLineAtRow(row).?,
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

/// Small, allocation-free fuzzy matcher for authored-input recall. FTS is
/// intentionally not involved: Ctrl+R should match sparse subsequences and
/// reward word starts/contiguous runs like a shell-history picker.
fn fuzzyHistoryScore(candidate: []const u8, query: []const u8) ?i64 {
    if (query.len == 0) return 0;
    var at: usize = 0;
    var previous: ?usize = null;
    var score: i64 = 0;
    for (query) |query_byte| {
        const q = std.ascii.toLower(query_byte);
        var found: ?usize = null;
        while (at < candidate.len) : (at += 1) {
            if (std.ascii.toLower(candidate[at]) == q) {
                found = at;
                break;
            }
        }
        const index = found orelse return null;
        score += 10;
        if (previous) |prev| {
            if (index == prev + 1) score += 12;
        }
        if (index == 0 or std.ascii.isWhitespace(candidate[index - 1]) or
            std.mem.indexOfScalar(u8, "/_-.:", candidate[index - 1]) != null)
            score += 8;
        score -= @intCast(@min(index, 100));
        previous = index;
        at = index + 1;
    }
    score -= @intCast(@min(candidate.len / 16, 100));
    return score;
}

fn popLastCodepoint(bytes: *std.ArrayList(u8)) void {
    if (bytes.items.len == 0) return;
    var new_len = bytes.items.len - 1;
    while (new_len > 0 and bytes.items[new_len] & 0xc0 == 0x80) new_len -= 1;
    bytes.shrinkRetainingCapacity(new_len);
}

fn isEnterKey(key: vaxis.Key) bool {
    if (key.mods.shift or key.mods.alt or key.mods.ctrl or key.mods.super or key.mods.hyper or key.mods.meta) return false;
    if (key.codepoint == vaxis.Key.enter or key.codepoint == '\n' or key.codepoint == vaxis.Key.kp_enter) return true;
    const text = key.text orelse return false;
    return std.mem.eql(u8, text, "\r") or std.mem.eql(u8, text, "\n");
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
    return key.matches(vaxis.Key.down, .{});
}

fn isNewSessionKey(key: vaxis.Key) bool {
    return key.matches('n', .{ .ctrl = true });
}

fn isArchiveCurrentKey(app: *const App, key: vaxis.Key) bool {
    return key.matches('d', .{ .ctrl = true }) and
        app.editor.isEmpty() and app.attachments.items.len == 0 and
        app.copy_cursor == null;
}

fn isArchivePickerKey(kind: PickerKind, key: vaxis.Key) bool {
    return kind == .session and
        (key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true }));
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

fn isPlanToggleKey(key: vaxis.Key) bool {
    return key.matchExact(vaxis.Key.tab, .{ .shift = true });
}

const PlanProposalAction = enum { none, implement, revise, stay, dismiss };

const voice_engines = [_]voice.Engine{ .whisper_turbo, .whisper_base, .parakeet };
const voice_engine_items = [_][]const u8{
    voice.Engine.whisper_turbo.label(),
    voice.Engine.whisper_base.label(),
    voice.Engine.parakeet.label(),
};
const voice_mode_items = [_][]const u8{
    "push-to-talk · hold ctrl+space, release to transcribe",
    "toggle · press ctrl+space to start, press again to stop",
};

/// True for the dictation hotkey in both kitty (' '+ctrl) and legacy (NUL)
/// encodings.
fn isVoiceKey(key: vaxis.Key) bool {
    return key.matches(' ', .{ .ctrl = true }) or key.codepoint == 0;
}

/// Transcription worker: waits out the recorder, runs the STT engine, and
/// posts the cleaned transcript (or a failure) back to the event loop.
const VoiceJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(Event),
    recorder: ?std.process.Child,
    wav_path: []u8,
    setup: voice.Setup,

    fn run(job: *VoiceJob) void {
        defer job.gpa.destroy(job);
        defer job.gpa.free(job.wav_path);
        job.transcribe() catch |err| {
            Io.Dir.cwd().deleteFile(job.io, job.wav_path) catch {};
            job.loop.postEvent(.{ .voice = .{ .stt_failed = @errorName(err) } }) catch {};
        };
    }

    fn transcribe(job: *VoiceJob) !void {
        if (job.recorder) |*recorder| _ = recorder.wait(job.io) catch {};
        const out_dir = std.fs.path.dirname(job.wav_path) orelse ".";
        var arena_state = std.heap.ArenaAllocator.init(job.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const argv = try voice.sttArgv(arena, job.setup, job.wav_path, out_dir);
        const result = try std.process.run(arena, job.io, .{
            .argv = argv,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(64 * 1024),
        });
        var text: []const u8 = result.stdout;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            // parakeet writes a sidecar txt instead of using stdout.
            const stem = std.fs.path.stem(job.wav_path);
            const sidecar = try std.fs.path.join(arena, &.{ out_dir, try std.fmt.allocPrint(arena, "{s}.txt", .{stem}) });
            text = Io.Dir.cwd().readFileAlloc(job.io, sidecar, arena, .limited(1 << 20)) catch "";
            Io.Dir.cwd().deleteFile(job.io, sidecar) catch {};
        }
        Io.Dir.cwd().deleteFile(job.io, job.wav_path) catch {};
        const exited_ok = result.term == .exited and result.term.exited == 0;
        const cleaned = try voice.cleanTranscript(job.gpa, text);
        if (!exited_ok and cleaned.len == 0) {
            job.gpa.free(cleaned);
            return error.TranscriberFailed;
        }
        job.loop.postEvent(.{ .voice = .{ .transcript = cleaned } }) catch job.gpa.free(cleaned);
    }
};

/// Fire-and-forget page-cache prewarm, spawned when recording starts so
/// the model is hot by the time the user stops talking.
const VoicePrewarmJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []u8,

    fn run(job: *VoicePrewarmJob) void {
        voice.prewarmModel(job.gpa, job.io, job.path);
        job.gpa.free(job.path);
        job.gpa.destroy(job);
    }
};

/// Model download worker for /voice setup.
const VoiceDownloadJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    loop: *vaxis.Loop(Event),
    url: []const u8,
    dest: []u8,
    progress: *voice.DownloadProgress,

    fn run(job: *VoiceDownloadJob) void {
        defer job.gpa.destroy(job);
        voice.download(job.gpa, job.io, job.url, job.dest, job.progress) catch |err| {
            job.loop.postEvent(.{ .voice = .{ .download_failed = @errorName(err) } }) catch {};
            return;
        };
        job.loop.postEvent(.{ .voice = .download_done }) catch {};
    }
};

/// Everything /voice owns at runtime. Dormant (all defaults) until either
/// config enables it at startup or /voice setup finishes.
const VoiceRt = struct {
    enabled: bool = false,
    setup: ?voice.Setup = null, // strings gpa-owned
    ffmpeg: ?[]u8 = null,
    phase: enum { idle, recording, transcribing } = .idle,
    recorder: ?std.process.Child = null,
    wav_path: ?[]u8 = null,
    /// Terminal reports key releases (kitty): push-to-talk possible.
    kitty_release: bool = false,
    // -- wizard state (live only during /voice setup) --
    wiz_engine: ?voice.Engine = null,
    wiz_mode: ?voice.Mode = null,
    wiz_stt_bin: ?[]u8 = null,
    wiz_model_dest: ?[]u8 = null,
    download: ?*voice.DownloadProgress = null,
    download_thread: ?std.Thread = null,
    rate_bytes: u64 = 0,
    rate_at_ms: i64 = 0,
    rate_bps: u64 = 0,
    /// Last page-cache prewarm; refreshed at most once a minute.
    prewarm_at_ms: i64 = 0,
    /// When the live capture began — drives the status bar's elapsed counter.
    record_started_ms: i64 = 0,

    fn freeSetup(self: *VoiceRt, gpa: std.mem.Allocator) void {
        if (self.setup) |st| {
            gpa.free(st.model_path);
            gpa.free(st.stt_bin);
        }
        self.setup = null;
    }

    fn deinit(self: *VoiceRt, gpa: std.mem.Allocator) void {
        self.freeSetup(gpa);
        if (self.ffmpeg) |f| gpa.free(f);
        if (self.wav_path) |w| gpa.free(w);
        if (self.wiz_stt_bin) |b| gpa.free(b);
        if (self.wiz_model_dest) |d| gpa.free(d);
        if (self.download) |pr| {
            pr.cancel.store(true, .release);
            if (self.download_thread) |t| t.join();
            gpa.destroy(pr);
        }
    }
};

fn planProposalAction(key: vaxis.Key) PlanProposalAction {
    if (isEnterKey(key)) return .implement;
    if (key.matches('e', .{})) return .revise;
    if (key.matches(vaxis.Key.escape, .{})) return .stay;
    if (key.matches('q', .{})) return .dismiss;
    return .none;
}

fn tabNavigationDirection(key: vaxis.Key) ?i8 {
    if (key.matches('>', .{}) or key.matches(vaxis.Key.right, .{})) return 1;
    if (key.matches('<', .{}) or key.matches(vaxis.Key.left, .{})) return -1;
    return null;
}

fn pendingMediaLabel(gpa: std.mem.Allocator, attachments: []const media.Pending) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (attachments, 0..) |attachment, i| {
        if (i > 0) try out.append(gpa, '\n');
        const byte_len = std.base64.standard.Decoder.calcSizeForSlice(attachment.data_base64) catch 0;
        try out.print(gpa, "▣ {s} · {s} · {Bi:.1}", .{ attachment.name, attachment.mime, byte_len });
    }
    return out.toOwnedSlice(gpa);
}

fn mediaErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NoImageOnClipboard => "clipboard contains no image",
        error.ClipboardImageUnsupported => "clipboard image capture is unavailable on this platform; use /attach",
        error.ClipboardReadFailed => "could not read the system clipboard",
        error.ImageTooLarge, error.StreamTooLong => "image exceeds the 10 MiB limit",
        error.UnsupportedImage => "supported formats are PNG, JPEG, GIF, and WebP",
        error.FileNotFound => "file not found",
        error.AccessDenied => "file is not readable",
        error.EmptyPath => "usage: /attach <image-path>",
        else => @errorName(err),
    };
}

fn validSetupProviderName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return !std.mem.eql(u8, name, "codex") and !std.mem.eql(u8, name, "claudecode");
}

fn handleKey(app: *App, key: vaxis.Key) !void {
    if (app.setup_prompt != .none) {
        const ed = &app.editor;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) {
            app.editor.clearSensitive();
            app.setup_prompt = .none;
            app.openPicker(.setup_provider);
            app.setNotice("provider setup · choose a backend", .{});
        } else if (isEnterKey(key)) {
            const value = try ed.takeExpandedSensitive();
            defer {
                @memset(value, 0);
                app.gpa.free(value);
            }
            app.submitSetupPrompt(value);
        } else if (editCommand(key)) |command| {
            applyEditCommand(ed, command);
        } else if (key.text) |text| {
            ed.insertSlice(text);
        }
        return;
    }

    if (app.otel_header_prompt) {
        const ed = &app.editor;
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) {
            app.cancelOtelSetup();
        } else if (isEnterKey(key)) {
            const headers = try ed.takeExpandedSensitive();
            defer {
                @memset(headers, 0);
                app.gpa.free(headers);
            }
            app.submitOtelHeaders(std.mem.trim(u8, headers, " \t\r\n"));
        } else if (editCommand(key)) |command| {
            applyEditCommand(ed, command);
        } else if (key.text) |text| {
            ed.insertSlice(text);
        }
        return;
    }

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

    if (key.matches('v', .{ .ctrl = true })) {
        app.attachClipboard();
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

    if (app.council_detail_name.items.len > 0) {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
            app.closeCouncilDetail();
        } else if (key.matches('e', .{})) {
            const name = app.gpa.dupe(u8, app.council_detail_name.items) catch return;
            defer app.gpa.free(name);
            app.closeCouncilDetail();
            app.openCouncilPicker(name);
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

    // Readline-style reverse-i-search stays inside the composer. The editor
    // displays the candidate; printable keys edit the independent query.
    if (app.history_search_active) {
        if (key.matches(vaxis.Key.escape, .{}) or key.matches('g', .{ .ctrl = true })) {
            app.cancelHistorySearch();
        } else if (key.matches('r', .{ .ctrl = true })) {
            app.cycleHistorySearch();
        } else if (isEnterKey(key)) {
            app.acceptHistorySearch();
        } else if (key.matches(vaxis.Key.backspace, .{}) or key.matches('h', .{ .ctrl = true })) {
            popLastCodepoint(&app.history_search_query);
            app.refreshHistorySearch(true);
        } else if (key.text) |text| {
            if (text.len > 0 and text[0] >= 0x20 and text[0] != 0x7f) {
                app.history_search_query.appendSlice(app.gpa, text) catch {};
                app.refreshHistorySearch(true);
            }
        }
        return;
    }

    // Pickers swallow all keys while open. Typing filters; Up/Down or
    // Ctrl+n/p navigate; Enter applies or toggles; Esc closes/cancels.
    if (app.picker) |sel| {
        if (key.matches(vaxis.Key.escape, .{})) {
            if (app.picker_kind == .council)
                app.cancelCouncilEdit()
            else {
                if (app.picker_kind == .search_prompt or app.picker_kind == .search) {
                    app.search_pending = false;
                    app.clearSearchHits();
                }
                app.picker = null;
                app.picker_filter.clearRetainingCapacity();
            }
            return;
        }
        // The model catalog can exceed a small stack buffer; this arena lives
        // only for the key event and keeps filtering allocation bounded there.
        var picker_arena = std.heap.ArenaAllocator.init(app.gpa);
        defer picker_arena.deinit();
        const items = app.pickerItems(picker_arena.allocator()) catch return;
        const n = items.len;

        if (isEnterKey(key) and app.picker_kind == .search_prompt) {
            app.submitSearch();
        } else if (isEnterKey(key)) {
            if (n > 0) {
                const pick = items[@min(sel, n - 1)];
                if (app.picker_kind == .council) {
                    if (std.mem.eql(u8, pick, council_done_item))
                        app.saveCouncilEdit()
                    else
                        app.toggleCouncilModel(pick);
                } else {
                    app.picker = null;
                    app.applyPickerItem(pick);
                    app.picker_filter.clearRetainingCapacity();
                }
            }
        } else if (isArchivePickerKey(app.picker_kind, key)) {
            if (n > 0) app.archivePickerSession(items[@min(sel, n - 1)]);
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

    if (app.setup_required and app.editor.isEmpty() and isEnterKey(key)) {
        app.beginSetup(true);
        return;
    }

    if (isPlanToggleKey(key)) {
        app.togglePlanMode();
        return;
    }

    if (app.plan_proposal_ready and app.plan_mode and app.state == .idle) {
        switch (planProposalAction(key)) {
            .implement => app.acceptPlanProposal(),
            .revise => {
                app.plan_proposal_ready = false;
                app.mode = .insert;
                app.setNotice("revise the plan in the composer", .{});
            },
            .dismiss => {
                app.plan_proposal_ready = false;
                app.setNotice("proposal dismissed · Plan mode remains on", .{});
            },
            .stay, .none => {},
        }
        return;
    }

    // A mode-independent, single-chord alias for /new. Pickers retain Vim's
    // Ctrl+n navigation because their modal block above consumes it first.
    if (isNewSessionKey(key)) {
        app.newSession() catch app.setNotice("could not create session", .{});
        return;
    }

    // Match shell EOF muscle memory without risking a draft or attachment.
    // Pickers consume Ctrl+D above; copy mode keeps its page-down binding.
    if (isArchiveCurrentKey(app, key)) {
        app.archiveCurrentSession();
        return;
    }

    // Option/Alt+1..9 jumps straight to that tab (strip order) from either
    // mode. Below the modal blocks on purpose: an open picker or help panel
    // keeps swallowing every key.
    if (key.mods.alt and !key.mods.ctrl and key.codepoint >= '1' and key.codepoint <= '9') {
        app.jumpToTab(@intCast(key.codepoint - '0'));
        return;
    }

    // Voice dictation: ctrl+space in either mode. Esc discards an active
    // recording or cancels a model download. Dormant (never consumes keys)
    // until /voice setup ran.
    if (isVoiceKey(key)) {
        if (app.handleVoiceKey()) return;
    }
    if (app.voice_rt.phase == .recording and key.matches(vaxis.Key.escape, .{})) {
        app.abortVoiceRecording();
        return;
    }
    if (app.voice_rt.download != null and key.matches(vaxis.Key.escape, .{})) {
        app.voiceCancelDownload();
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
    // Nothing parked HERE but something parked elsewhere: y/n jump to it
    // instead of dead-keying. Deliberately never answers a background
    // approval blind — you approve only what is on screen.
    if (app.pending == null and app.editor.isEmpty() and
        (key.matches('y', .{}) or key.matches('n', .{})))
    {
        if (app.firstAwaitingSid()) |awaiting_sid| {
            app.switchSession(awaiting_sid, true) catch return;
            app.setNotice("approval pending here — y approves, n denies", .{});
            return;
        }
    }

    switch (app.mode) {
        .insert => {
            const ed = &app.editor;
            if (key.matches('r', .{ .ctrl = true })) {
                app.beginHistorySearch();
                return;
            }
            // Same width draw() gives the editor: terminal minus the prompt.
            const edit_w: usize = app.term_cols -| 2;
            var command_arena = std.heap.ArenaAllocator.init(app.gpa);
            defer command_arena.deinit();
            const suggestions = commandSuggestions(app, command_arena.allocator()) catch &.{};
            // A recalled /command still looks like an autocomplete query.
            // While walking history, Up/Down must keep walking history rather
            // than being captured by the command menu.
            if (suggestions.len > 0 and !ed.isWalkingHistory()) {
                app.command_selection = @min(app.command_selection, suggestions.len - 1);
                if (isNextInputRowKey(key)) {
                    app.command_selection = if (app.command_selection + 1 < suggestions.len)
                        app.command_selection + 1
                    else
                        0;
                    return;
                } else if (isPreviousInputRowKey(key) or key.matches(vaxis.Key.tab, .{ .shift = true })) {
                    app.command_selection = if (app.command_selection > 0)
                        app.command_selection - 1
                    else
                        suggestions.len - 1;
                    return;
                } else if (key.matches(vaxis.Key.tab, .{})) {
                    completeSuggestion(ed, suggestions[app.command_selection], true);
                    app.command_selection = 0;
                    return;
                } else if (isEnterKey(key)) {
                    const suggestion = suggestions[app.command_selection];
                    completeSuggestion(ed, suggestion, false);
                    app.command_selection = 0;
                    if (suggestion.submit_on_enter) {
                        const text = try ed.takeExpandedWithImages(app.attachments.items.len);
                        defer app.gpa.free(text);
                        app.submitInput(text);
                    }
                    return;
                }
            }
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal; // draft survives: editor state untouched
                app.sel_anchor = null;
            } else if (isNewlineKey(key)) {
                ed.insertNewline();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const text = try ed.takeExpandedWithImages(app.attachments.items.len);
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
                    app.maybeRequestHistoryAtTop();
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
            if (tabNavigationDirection(key)) |direction| {
                var steps = app.takeCount();
                while (steps > 0) : (steps -= 1) app.cycleTab(direction);
            } else if (key.matches('/', .{})) {
                app.openSearchPrompt(app.sid);
            } else if (key.matches('n', .{})) {
                app.nextSearchHit(1);
            } else if (key.matches('N', .{ .shift = true }) or key.matches('N', .{})) {
                app.nextSearchHit(-1);
            } else if (key.matches('?', .{})) {
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
                app.maybeRequestHistoryAtTop();
            } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
                app.scroll_up -|= 20;
            } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
                app.scroll_up +|= 20;
                app.maybeRequestHistoryAtTop();
            } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
                app.scroll_up = 0;
            } else if (key.matches('g', .{})) {
                app.pending_g = true;
            } else if (key.matches('v', .{}) or key.matches('V', .{ .shift = true }) or key.matches('V', .{})) {
                app.enterCopyMode();
            } else if (key.matches('h', .{})) {
                var n = app.takeCount();
                while (n > 0) : (n -= 1) app.editor.moveLeft();
            } else if (key.matches('l', .{})) {
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

test "enter matching accepts terminal and keypad encodings" {
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expect(isEnterKey(.{ .codepoint = '\n' }));
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.kp_enter }));
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.multicodepoint, .text = "\r" }));
    try std.testing.expect(isEnterKey(.{ .codepoint = vaxis.Key.multicodepoint, .text = "\n" }));
    try std.testing.expect(!isEnterKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true } }));
    try std.testing.expect(!isEnterKey(.{ .codepoint = 'x', .text = "x" }));
}

test "inline Ctrl+R search refines cycles and restores the draft" {
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
    app.editor.pushHistory("banana launcher");
    app.editor.pushHistory("build release assets");
    app.editor.insertSlice("draft in progress");
    try app.history_search_draft.appendSlice(gpa, app.editor.text.items);
    app.history_search_draft_cursor = app.editor.cursor;
    app.history_search_active = true;
    app.refreshHistorySearch(true);
    try std.testing.expectEqualStrings("build release assets", app.editor.text.items);

    try app.history_search_query.append(gpa, 'b');
    app.refreshHistorySearch(true);
    app.cycleHistorySearch();
    try std.testing.expectEqualStrings("banana launcher", app.editor.text.items);

    app.history_search_query.clearRetainingCapacity();
    try app.history_search_query.appendSlice(gpa, "bln");
    app.refreshHistorySearch(true);
    try std.testing.expectEqualStrings("banana launcher", app.editor.text.items);

    app.cancelHistorySearch();
    try std.testing.expect(!app.history_search_active);
    try std.testing.expectEqualStrings("draft in progress", app.editor.text.items);
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
    try std.testing.expectEqualStrings(
        " (guest) claudecode/fable",
        try pickerModelLine(arena, "claudecode/fable", null, "", 40),
    );
    try std.testing.expect(std.mem.endsWith(
        u8,
        try pickerModelLine(arena, "openrouter/example/model", null, " ☑", 40),
        " ☑",
    ));
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

test "composer suggestions include commands, council actions, and council names" {
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
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "adversarial") };
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/example/model"));
    try app.councils.append(gpa, council);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    app.editor.insertSlice("/com");
    var suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/compact", suggestions[0].label);

    app.editor.clear();
    app.editor.insertSlice("/council n");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/council new", suggestions[0].label);
    try std.testing.expect(!suggestions[0].submit_on_enter);

    app.editor.clear();
    app.editor.insertSlice("/council adv");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/council adversarial", suggestions[0].label);
    try std.testing.expect(suggestions[0].submit_on_enter);

    completeSuggestion(&app.editor, suggestions[0], false);
    try std.testing.expectEqualStrings("/council adversarial", app.editor.text.items);

    app.editor.clear();
    app.editor.insertSlice("/review adv");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/review adversarial", suggestions[0].label);
    try std.testing.expect(!suggestions[0].submit_on_enter);

    completeSuggestion(&app.editor, suggestions[0], false);
    try std.testing.expectEqualStrings("/review adversarial ", app.editor.text.items);
    try std.testing.expect(commandQuery(&app.editor) == null);

    app.editor.clear();
    app.editor.insertSlice("/otel s");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), suggestions.len);
    try std.testing.expectEqualStrings("/otel set", suggestions[0].label);
    try std.testing.expect(!suggestions[0].submit_on_enter);
    try std.testing.expectEqualStrings("/otel status", suggestions[1].label);
    try std.testing.expect(suggestions[1].submit_on_enter);

    app.editor.clear();
    app.editor.insertSlice("/plan c");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/plan clear", suggestions[0].label);
    try std.testing.expect(suggestions[0].submit_on_enter);

    app.editor.clear();
    app.editor.insertSlice("/animate m");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("/animate matrix", suggestions[0].label);
    try std.testing.expect(suggestions[0].submit_on_enter);

    app.editor.clear();
    app.editor.insertSlice("!rb c");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    suggestions = try commandSuggestions(&app, arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), suggestions.len);
    try std.testing.expectEqualStrings("!rb client", suggestions[0].label);
    try std.testing.expect(suggestions[0].submit_on_enter);
}

test "/animate matrix starts and expires a client-only animation" {
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

    app.runCommand("/animate matrix");
    try std.testing.expectEqual(UiAnimation.matrix, app.ui_animation);
    try std.testing.expect(app.ui_animation_active.load(.acquire));
    try std.testing.expect(app.animation_active.load(.acquire));

    const animation_frames = matrixAnimationFrames(app.term_rows);
    try std.testing.expectEqual(animation_frames, app.ui_animation_frames);
    for (0..animation_frames) |_| app.tickUiAnimation();
    try std.testing.expectEqual(UiAnimation.none, app.ui_animation);
    try std.testing.expect(!app.ui_animation_active.load(.acquire));
    try std.testing.expect(!app.animation_active.load(.acquire));
    try std.testing.expect(app.refresh_requested);

    app.runCommand("/animate unknown");
    try std.testing.expectEqualStrings("usage: /animate matrix", app.notice.items);
}

test "matrix rain is about half a viewport height long" {
    for ([_]u16{ 12, 24, 60 }) |height| {
        const trail = matrixTrailLength(height);
        try std.testing.expect(trail >= @as(usize, height) / 2);
        try std.testing.expect(trail <= @max(@as(usize, height) * 3 / 4, 8));
        try std.testing.expect(matrixAnimationFrames(height) > trail);
    }
}

test "matrix wave enters at the top, crosses the viewport, and fades out" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .ui_animation = .matrix,
        .ui_animation_frames = matrixAnimationFrames(18),
        .ui_animation_seed = 0x12345678,
    };
    defer app.deinit();

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 18,
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
        .height = 18,
        .screen = &screen,
    };

    const countRows = struct {
        const Counts = struct { top: usize, bottom: usize };

        fn run(window: vaxis.Window, split: u16) Counts {
            var counts: Counts = .{ .top = 0, .bottom = 0 };
            for (0..window.height) |row| for (0..window.width) |col| {
                const cell = window.readCell(@intCast(col), @intCast(row)).?;
                if (cell.default) continue;
                if (row < split) counts.top += 1 else counts.bottom += 1;
            };
            return counts;
        }
    }.run;

    app.ui_animation_frame = 6;
    win.clear();
    drawUiAnimation(&app, win);
    const early = countRows(win, win.height / 2);
    try std.testing.expect(early.top > 0);
    try std.testing.expectEqual(@as(usize, 0), early.bottom);

    app.ui_animation_frame = app.ui_animation_frames / 2;
    win.clear();
    drawUiAnimation(&app, win);
    const middle = countRows(win, win.height / 2);
    try std.testing.expect(middle.top > 0 and middle.bottom > 0);

    app.ui_animation_frame = app.ui_animation_frames - 2;
    win.clear();
    drawUiAnimation(&app, win);
    const late = countRows(win, win.height / 2);
    try std.testing.expect(late.bottom > 0);
    try std.testing.expect(late.top < late.bottom);
    try std.testing.expect(late.top + late.bottom < middle.top + middle.bottom);

    try std.testing.expectEqual(@as(u8, 0), matrixWaveOpacity(0, app.ui_animation_frames));
    try std.testing.expectEqual(@as(u8, 0), matrixWaveOpacity(app.ui_animation_frames - 1, app.ui_animation_frames));
}

test "matrix animation paints default blank cells across the screen" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .ui_animation = .matrix,
        .ui_animation_frame = matrixAnimationFrames(12) / 2,
        .ui_animation_frames = matrixAnimationFrames(12),
        .ui_animation_seed = 0x12345678,
    };
    defer app.deinit();

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 12,
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
        .height = 12,
        .screen = &screen,
    };
    win.clear();

    drawUiAnimation(&app, win);

    var matrix_cells: usize = 0;
    var top_cells: usize = 0;
    var bottom_cells: usize = 0;
    var left_cells: usize = 0;
    var right_cells: usize = 0;
    for (0..win.height) |row| for (0..win.width) |col| {
        const cell = win.readCell(@intCast(col), @intCast(row)).?;
        if (!cell.default) {
            matrix_cells += 1;
            top_cells += @intFromBool(row < win.height / 2);
            bottom_cells += @intFromBool(row >= win.height / 2);
            left_cells += @intFromBool(col < win.width / 2);
            right_cells += @intFromBool(col >= win.width / 2);
            try std.testing.expect(!std.mem.eql(u8, cell.char.grapheme, " "));
            try std.testing.expectEqual(@as(u16, 1), win.gwidth(cell.char.grapheme));
        }
    };
    try std.testing.expect(matrix_cells > 0);
    try std.testing.expect(top_cells > 0 and bottom_cells > 0);
    try std.testing.expect(left_cells > 0 and right_cells > 0);
}

test "matrix animation interleaves around existing text at high density" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .ui_animation = .matrix,
        .ui_animation_frame = matrixAnimationFrames(18) / 2,
        .ui_animation_frames = matrixAnimationFrames(18),
        .ui_animation_seed = 0x12345678,
    };
    defer app.deinit();

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 18,
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
        .height = 18,
        .screen = &screen,
    };
    const baseline_style: vaxis.Style = .{ .fg = .{ .index = 4 }, .bg = .{ .index = 5 } };
    win.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = baseline_style });
    for (0..win.height) |row| {
        if (row % 3 != 1) continue;
        var col: u16 = 4;
        while (col < win.width - 4) : (col += 7)
            win.writeCell(col, @intCast(row), .{ .char = .{ .grapheme = "x", .width = 1 }, .style = baseline_style });
    }

    drawUiAnimation(&app, win);

    var matrix_cells: usize = 0;
    var unicode_cells: usize = 0;
    var text_cells: usize = 0;
    var blank_cells: usize = 0;
    for (0..win.height) |row| for (0..win.width) |col| {
        const cell = win.readCell(@intCast(col), @intCast(row)).?;
        if (std.mem.eql(u8, cell.char.grapheme, "x")) {
            text_cells += 1;
            try std.testing.expect(vaxis.Style.eql(cell.style, baseline_style));
        } else if (std.mem.eql(u8, cell.char.grapheme, " ")) {
            blank_cells += 1;
        } else {
            matrix_cells += 1;
            unicode_cells += @intFromBool(cell.char.grapheme.len > 1);
            try std.testing.expect(!cell.default);
            try std.testing.expect(vaxis.Color.eql(cell.style.bg, baseline_style.bg));
        }
    };
    try std.testing.expect(text_cells > 0);
    try std.testing.expect(matrix_cells > blank_cells);
    try std.testing.expect(unicode_cells > 0);
}

test "matrix animation does not paint wide-character continuation cells" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 2,
        .cols = 4,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 4,
        .height = 2,
        .screen = &screen,
    };
    win.clear();
    win.writeCell(1, 0, .{ .char = .{ .grapheme = "界", .width = 2 } });

    try std.testing.expect(!matrixCellIsOpen(win, 1, 0));
    try std.testing.expect(!matrixCellIsOpen(win, 2, 0));
    try std.testing.expect(matrixCellIsOpen(win, 3, 0));
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

test "council list opens inspection before explicit editing" {
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
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "core") };
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/example/model"));
    try app.councils.append(gpa, council);
    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/example/model"));

    app.openCouncilList();
    try std.testing.expectEqual(PickerKind.council_list, app.picker_kind);
    try std.testing.expectEqual(@as(?usize, 0), app.picker);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const items = try app.pickerItems(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("core", items[0]);

    try handleKey(&app, .{ .codepoint = vaxis.Key.enter });
    try std.testing.expect(app.picker == null);
    try std.testing.expectEqualStrings("core", app.council_detail_name.items);
    try std.testing.expectEqual(@as(usize, 0), app.council_edit_models.items.len);

    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expectEqual(@as(usize, 0), app.council_detail_name.items.len);

    app.runCommand("/council core");
    try std.testing.expectEqualStrings("core", app.council_detail_name.items);
    try std.testing.expectEqual(@as(usize, 0), app.council_edit_models.items.len);

    try handleKey(&app, .{ .codepoint = 'e', .text = "e" });
    try std.testing.expectEqual(@as(usize, 0), app.council_detail_name.items.len);
    try std.testing.expectEqual(PickerKind.council, app.picker_kind);
    try std.testing.expectEqualStrings("core", app.council_edit_name.items);
    try std.testing.expect(app.councilModelSelected("openrouter/example/model"));
}

test "council picker reuses catalog with Done and checked multi-select seats" {
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

    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/x-ai/grok-4.6"));
    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/z-ai/glm-5.3"));
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "core") };
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/z-ai/glm-5.3"));
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/legacy/retired-model"));
    try app.councils.append(gpa, council);

    app.runCommand("/council edit core");
    try std.testing.expectEqual(PickerKind.council, app.picker_kind);
    try std.testing.expectEqual(@as(?usize, 0), app.picker);
    try std.testing.expectEqualStrings("core", app.council_edit_name.items);
    try std.testing.expect(app.councilModelSelected("openrouter/z-ai/glm-5.3"));

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const items = try app.pickerItems(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings(council_done_item, items[0]);
    try std.testing.expectEqualStrings("openrouter/legacy/retired-model", items[3]);

    app.picker = 1;
    try handleKey(&app, .{ .codepoint = vaxis.Key.multicodepoint, .text = "\r" });
    try std.testing.expect(app.councilModelSelected("openrouter/x-ai/grok-4.6"));
    try std.testing.expectEqual(@as(?usize, 1), app.picker);

    try app.picker_filter.appendSlice(gpa, "glm");
    arena_state.deinit();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    const filtered = try app.pickerItems(arena_state.allocator());
    try std.testing.expectEqual(@as(usize, 2), filtered.len);
    try std.testing.expectEqualStrings(council_done_item, filtered[0]);
    try std.testing.expectEqualStrings("openrouter/z-ai/glm-5.3", filtered[1]);

    try handleKey(&app, .{ .codepoint = vaxis.Key.escape });
    try std.testing.expect(app.picker == null);
    try std.testing.expectEqual(@as(usize, 0), app.council_edit_models.items.len);
    try std.testing.expectEqualStrings("council edit cancelled", app.notice.items);
    try std.testing.expectEqual(@as(usize, 2), app.councils.items[0].models.items.len);
}

test "council Done refuses an empty roster without closing the picker" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .picker_kind = .council,
        .picker = 0,
    };
    defer app.deinit();
    try app.council_edit_name.appendSlice(gpa, "empty");
    try app.catalog.append(gpa, try gpa.dupe(u8, "openrouter/x-ai/grok-4.6"));

    try handleKey(&app, .{ .codepoint = vaxis.Key.enter });
    try std.testing.expectEqual(@as(?usize, 0), app.picker);
    try std.testing.expectEqualStrings("choose at least one model before Done", app.notice.items);
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

test "OTEL command parsing is vendor-neutral and strict" {
    try std.testing.expect(parseOtelCommand(null, "").? == .status);
    try std.testing.expect(parseOtelCommand("status", "").? == .status);
    try std.testing.expect(parseOtelCommand("off", "").? == .off);
    const set = parseOtelCommand("set", " https://otel.example ").?;
    try std.testing.expectEqualStrings("https://otel.example", set.set);
    try std.testing.expect(parseOtelCommand("set", "") == null);
    try std.testing.expect(parseOtelCommand("set", "https://otel.example extra") == null);
    try std.testing.expect(parseOtelCommand("mirador", "") == null);
}

test "provider setup distinguishes installed guests and advances custom fields without history" {
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

    app.setup_readiness.codex_available = true;
    try std.testing.expectEqualStrings("  · login needed", app.setupProviderNote(setup_provider_items[1]));
    app.setup_readiness.codex_authenticated = true;
    try std.testing.expectEqualStrings("  ✓ signed in", app.setupProviderNote(setup_provider_items[1]));

    app.setupProviderChosen(setup_provider_items[7]);
    try std.testing.expectEqual(SetupPrompt.provider_name, app.setup_prompt);
    app.submitSetupPrompt("acme");
    try std.testing.expectEqual(SetupPrompt.base_url, app.setup_prompt);
    try std.testing.expectEqualStrings("ACME_API_KEY", app.setup_api_key_env.items);
    app.submitSetupPrompt("https://gateway.acme.test/v1");
    try std.testing.expectEqual(SetupPrompt.credential, app.setup_prompt);
    app.submitSetupPrompt("");
    try std.testing.expectEqual(SetupPrompt.model, app.setup_prompt);
    try std.testing.expectEqualStrings("NONE", app.setup_api_key_env.items);
    try std.testing.expectEqualStrings("acme/", app.editor.text.items);
    try std.testing.expectEqual(@as(usize, 0), app.editor.history.items.len);
    app.submitSetupPrompt("acme/");
    try std.testing.expectEqual(SetupPrompt.model, app.setup_prompt);
    try std.testing.expectEqualStrings("model id needs a name after provider/", app.notice.items);
}

test "required provider setup still permits an explicit quit" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .setup_required = true,
    };
    defer app.deinit();

    app.submitInput("/quit");
    try std.testing.expect(app.should_quit);
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
    try std.testing.expect(app.reboot_request.requested);
    try std.testing.expectEqual(RebuildScope.attached, app.reboot_request.rebuild);
    try std.testing.expect(!app.reboot_request.force);
    try std.testing.expect(app.should_quit);
    try std.testing.expectEqualStrings("!rb", app.editor.history.items[0]);
}

test "bang rb supports client and both scopes" {
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

    app.runCommand("!rb client");
    try std.testing.expectEqual(RebuildScope.client, app.reboot_request.rebuild);

    app.should_quit = false;
    app.reboot_request = .{};
    app.runCommand("!rb both --force");
    try std.testing.expectEqual(RebuildScope.both, app.reboot_request.rebuild);
    try std.testing.expect(app.reboot_request.force);
}

test "plain reboot refuses a focused approval unless forced" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .state = .awaiting_approval,
    };
    defer app.deinit();

    app.runCommand("/reboot");
    try std.testing.expect(!app.reboot_request.requested);
    try std.testing.expect(!app.should_quit);
    try std.testing.expect(std.mem.indexOf(u8, app.notice.items, "approval pending") != null);

    app.runCommand("/reboot --build --force");
    try std.testing.expect(app.reboot_request.requested);
    try std.testing.expectEqual(RebuildScope.attached, app.reboot_request.rebuild);
    try std.testing.expect(app.reboot_request.force);
    try std.testing.expect(app.should_quit);
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
    try std.testing.expect(!isNextInputRowKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expect(isNewSessionKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isNewSessionKey(.{ .codepoint = 'n' }));
}

test "normal-mode tab shortcuts recognize angle brackets and arrows" {
    try std.testing.expectEqual(@as(?i8, 1), tabNavigationDirection(.{ .codepoint = '>' }));
    try std.testing.expectEqual(@as(?i8, -1), tabNavigationDirection(.{ .codepoint = '<' }));
    try std.testing.expectEqual(@as(?i8, 1), tabNavigationDirection(.{ .codepoint = vaxis.Key.right }));
    try std.testing.expectEqual(@as(?i8, -1), tabNavigationDirection(.{ .codepoint = vaxis.Key.left }));
    // Kitty reports the physical key plus shifted codepoint in its enhanced
    // keyboard mode; Key.matches must recognize that real terminal shape too.
    try std.testing.expectEqual(@as(?i8, 1), tabNavigationDirection(.{
        .codepoint = '.',
        .shifted_codepoint = '>',
        .text = ">",
        .mods = .{ .shift = true },
    }));
    try std.testing.expectEqual(@as(?i8, null), tabNavigationDirection(.{ .codepoint = 'h' }));
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

test "correlated session creation replies clear only the matching pending request" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .awaiting_new_session = true,
        .pending_new_session_request_id = 77,
    };
    defer app.deinit();
    try app.pending_new_cwd.appendSlice(gpa, "/work");

    const unrelated = try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "request_failed",
        .msg = "other request failed",
        .request_id = 76,
    } });
    app.handleDaemonLine(unrelated);
    try std.testing.expect(app.awaiting_new_session);
    try std.testing.expectEqual(@as(u64, 77), app.pending_new_session_request_id);

    const matching = try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "request_failed",
        .msg = "create failed",
        .request_id = 77,
    } });
    app.handleDaemonLine(matching);
    try std.testing.expect(!app.awaiting_new_session);
    try std.testing.expectEqual(@as(u64, 0), app.pending_new_session_request_id);
    try std.testing.expectEqual(@as(usize, 0), app.pending_new_cwd.items.len);
}

test "session picker reserves archive chords without stealing filter text" {
    try std.testing.expect(isArchivePickerKey(.session, .{ .codepoint = vaxis.Key.delete }));
    try std.testing.expect(isArchivePickerKey(.session, .{ .codepoint = 'd', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isArchivePickerKey(.session, .{ .codepoint = 'a' }));
    try std.testing.expect(!isArchivePickerKey(.session, .{ .codepoint = 'q' }));
    try std.testing.expect(!isArchivePickerKey(.model, .{ .codepoint = vaxis.Key.delete }));
}

test "Ctrl+N aliases /new in either mode while pickers keep navigation" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        // Avoid touching the deliberately absent test connection: this also
        // verifies key repeat cannot issue a second create request.
        .awaiting_new_session = true,
    };
    defer app.deinit();
    app.editor.insertSlice("draft survives");

    for ([_]Mode{ .insert, .normal }) |mode| {
        app.mode = mode;
        try handleKey(&app, .{ .codepoint = 'n', .mods = .{ .ctrl = true } });
        try std.testing.expectEqualStrings("new session already being created", app.notice.items);
        try std.testing.expectEqualStrings("draft survives", app.editor.text.items);
    }

    app.awaiting_new_session = false;
    app.picker_kind = .effort;
    app.picker = 0;
    try handleKey(&app, .{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try std.testing.expectEqual(@as(?usize, 1), app.picker);
    try std.testing.expect(!app.awaiting_new_session);
}

test "staging images inserts numbered prompt placeholders" {
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

    app.editor.insertSlice("compare");
    app.addAttachment(.{
        .name = try gpa.dupe(u8, "first.png"),
        .mime = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "AA=="),
    });
    app.addAttachment(.{
        .name = try gpa.dupe(u8, "second.png"),
        .mime = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "AA=="),
    });

    try std.testing.expectEqualStrings("compare [image #1] [image #2] ", app.editor.text.items);
    try std.testing.expectEqual(@as(usize, 2), app.attachments.items.len);
}

test "Ctrl+D archives only a truly empty composer outside copy mode" {
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
    const ctrl_d = vaxis.Key{ .codepoint = 'd', .mods = .{ .ctrl = true } };

    try std.testing.expect(isArchiveCurrentKey(&app, ctrl_d));
    try std.testing.expect(!isArchiveCurrentKey(&app, .{ .codepoint = 'd' }));

    app.editor.insertSlice("draft survives");
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_d));
    app.editor.clear();

    try app.attachments.append(gpa, .{
        .name = try gpa.dupe(u8, "image.png"),
        .mime = try gpa.dupe(u8, "image/png"),
        .data_base64 = try gpa.dupe(u8, "AA=="),
    });
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_d));
    app.clearAttachments();

    app.copy_cursor = .{ .line = 0, .col = 0 };
    try std.testing.expect(!isArchiveCurrentKey(&app, ctrl_d));
    app.copy_cursor = null;

    // The shared /archive path retains its running-session guard.
    app.state = .running;
    try handleKey(&app, ctrl_d);
    try std.testing.expect(std.mem.indexOf(u8, app.notice.items, "interrupt it first") != null);
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

test "reasoning cards are muted, padded, and inset" {
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

    // Content-only: no leading/trailing blanks — the layout loop owns air.
    try std.testing.expect(lines.items.len >= 2); // wrapped body
    try std.testing.expectEqualStrings("  · ", lines.items[0].text);
    try std.testing.expect(lines.items[0].style.bold);
    try std.testing.expect(lines.items[lines.items.len - 1].text2.len > 0);
    // Completed commentary is secondary narration: the same muted index-7
    // grey it streamed in as, one step below the assistant's final prose.
    try std.testing.expect(!lines.items[0].style2.italic);
    try std.testing.expect(!lines.items[0].style2.bold);
    try std.testing.expect(vaxis.Color.eql(lines.items[0].style2.fg, Palette.reasoning.fg));
    for (lines.items) |line| {
        // Flat CC-style narration: no background panel, ever — a filled
        // card highlighted the least important content and its padding
        // could not sit symmetric against reused separator rows.
        try std.testing.expect(line.fill_style == null);
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
        try statusModel(arena, "openrouter/anthropic/claude-sonnet-4.5"),
    );
    try std.testing.expectEqualStrings(
        "(guest) fable",
        try statusModel(arena, "claudecode/fable"),
    );
    try std.testing.expectEqualStrings(
        "(guest) codex/default",
        try statusModel(arena, "codex/default"),
    );
    try std.testing.expectEqualStrings("ctx n/a", try statusContext(arena, true, 0, 200_000));
    try std.testing.expectEqualStrings("ctx 12%", try statusContext(arena, false, 24_000, 200_000));
    try std.testing.expectEqualStrings("", try statusContext(arena, false, 0, 0));
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
    _ = try appendDiffLine(arena, &lines, "  ", "+    const msg = \"hello\";", .zig, Palette.tool_out, &nums);
    // A hunk header renders only its enclosing-declaration context…
    try std.testing.expect(try appendDiffLine(arena, &lines, "  ", "@@ -4,1 +4,1 @@ pub fn greet() void {", .zig, Palette.tool_out, &nums));
    _ = try appendDiffLine(arena, &lines, "  ", "+    greet();", .zig, Palette.tool_out, &nums);
    _ = try appendDiffLine(arena, &lines, "  ", "-    farewell();", .zig, Palette.tool_out, &nums);
    try std.testing.expectEqual(@as(usize, 4), lines.items.len);
    // …while a bare one (no context) feeds the gutter and renders nothing.
    try std.testing.expect(!try appendDiffLine(arena, &lines, "  ", "@@ -9,1 +9,1 @@", .zig, Palette.tool_out, &nums));
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
    try std.testing.expect(std.mem.indexOf(u8, hunk.text, "@@") == null); // machinery hidden
    try std.testing.expect(std.mem.indexOf(u8, hunk.text2, "pub fn greet") != null);
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

test "correlated daemon error removes only its optimistic input and restores state" {
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

    app.state = .done;
    app.pushInputEcho(.user_msg, "rejected", 41, app.state);
    app.pushInputEcho(.steer, "unrelated", 42, null);
    app.state = .running;
    app.animation_active.store(true, .release);

    const line = try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "archived",
        .msg = "read only",
        .request_id = 41,
    } });
    app.handleDaemonLine(line);

    try std.testing.expectEqual(proto.SessionState.done, app.state);
    try std.testing.expect(!app.animation_active.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), app.blocks.items.len);
    try std.testing.expectEqualStrings("unrelated", app.blocks.items[0].text);
    try std.testing.expectEqual(@as(u64, 42), app.blocks.items[0].pending_request_id);
    try std.testing.expectEqualStrings("rejected", app.editor.text.items);
}

test "correlated ok accepts the echo while generic errors cannot reject it" {
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

    app.pushInputEcho(.user_msg, "accepted", 55, .idle);
    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .ok = .{ .request_id = 55 } }));
    try std.testing.expectEqual(@as(usize, 1), app.blocks.items.len);
    try std.testing.expect(app.blocks.items[0].pending_echo);
    try std.testing.expectEqual(@as(u64, 0), app.blocks.items[0].pending_request_id);

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "other_command",
        .msg = "unrelated",
    } }));
    try std.testing.expectEqual(@as(usize, 1), app.blocks.items.len);
}

test "replay marker completes a bounded tail without needing a connection" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 7,
        .editor = Editor.init(gpa),
        .history_complete = false,
        .history_loading = true,
    };
    defer app.deinit();

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .replay_done = .{
        .sid = 7,
        .oldest_seq = 20,
        .newest_seq = 275,
        .has_older = true,
        .plan_items = &.{
            .{ .step = "Inspect", .status = .completed, .duration_ms = 18_400 },
            .{ .step = "Implement", .status = .in_progress, .started_at_ms = 20_000 },
        },
    } }));
    try std.testing.expectEqual(@as(u64, 20), app.oldest_seq);
    try std.testing.expect(!app.history_complete);
    try std.testing.expect(!app.history_loading);
    try std.testing.expectEqual(@as(usize, 2), app.plan.items.len);
    try std.testing.expectEqual(@as(u64, 18_400), app.plan.items[0].duration_ms);
    try std.testing.expectEqualStrings("Implement", app.plan.items[1].step);
    try std.testing.expectEqual(block.PlanStatus.in_progress, app.plan.items[1].status);
    try std.testing.expectEqual(@as(i64, 20_000), app.plan.items[1].started_at_ms);
}

test "replay marker never repins a completed plan" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 7,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();
    app.setPlan(&.{.{ .step = "Done", .status = .completed, .duration_ms = 1_000 }});

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .replay_done = .{
        .sid = 7,
        .plan_pinned = true,
        .plan_items = &.{.{ .step = "Done", .status = .completed, .duration_ms = 1_000 }},
    } }));
    try std.testing.expectEqual(@as(usize, 0), app.plan.items.len);
}

test "older replay page is prepended atomically in transcript order" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 7,
        .editor = Editor.init(gpa),
        .last_seq = 3,
        .oldest_seq = 3,
        .history_complete = false,
        .history_loading = true,
        .history_before_seq = 3,
    };
    defer app.deinit();
    try app.blocks.append(gpa, .{
        .kind = .user_msg,
        .seq = 3,
        .turn_id = 2,
        .text = try gpa.dupe(u8, "newest"),
        .label = try gpa.dupe(u8, ""),
    });

    for ([_]struct { u64, []const u8 }{
        .{ 1, "oldest" },
        .{ 2, "middle" },
    }) |entry| {
        app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .blk = .{
            .sid = 7,
            .b = .{
                .id = entry[0],
                .session_id = 7,
                .turn_id = 1,
                .seq = entry[0],
                .ts = 0,
                .body = .{ .user_msg = .{ .text = entry[1] } },
            },
        } }));
    }
    // The visible list does not change before the page marker.
    try std.testing.expectEqual(@as(usize, 1), app.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.history_backfill.items.len);

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .replay_done = .{
        .sid = 7,
        .oldest_seq = 1,
        .newest_seq = 2,
        .has_older = false,
    } }));
    try std.testing.expectEqual(@as(usize, 3), app.blocks.items.len);
    try std.testing.expectEqualStrings("oldest", app.blocks.items[0].text);
    try std.testing.expectEqualStrings("middle", app.blocks.items[1].text);
    try std.testing.expectEqualStrings("newest", app.blocks.items[2].text);
    try std.testing.expectEqual(@as(u64, 1), app.oldest_seq);
    try std.testing.expect(app.history_complete);
    try std.testing.expect(!app.history_loading);
    try std.testing.expectEqual(@as(usize, 0), app.history_backfill.items.len);
    try std.testing.expectEqual(@as(usize, 3), app.editor.history.items.len);
}

test "failed replay request releases buffered page and can be retried" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 7,
        .editor = Editor.init(gpa),
        .oldest_seq = 3,
        .history_complete = false,
        .history_loading = true,
        .history_before_seq = 3,
    };
    defer app.deinit();
    try app.history_backfill.append(gpa, .{
        .kind = .user_msg,
        .seq = 2,
        .text = try gpa.dupe(u8, "owned page text"),
        .label = try gpa.dupe(u8, ""),
    });

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .err = .{
        .code = "request_failed",
        .msg = "store unavailable",
    } }));
    try std.testing.expect(!app.history_loading);
    try std.testing.expectEqual(@as(u64, 0), app.history_before_seq);
    try std.testing.expectEqual(@as(usize, 0), app.history_backfill.items.len);
    try std.testing.expect(!app.history_complete);
}

test "diagnostics render in scrollback with the full latest-turn waterfall" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 7,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    const rounds = [_]proto.DiagnosticRound{.{
        .round = 0,
        .duration_ms = 1250,
        .ttft_ms = 340,
        .pre_provider_ms = 90,
        .context_load_ms = 12,
        .store_wait_ms = 2,
        .context_rows = 40,
        .context_bytes = 8192,
        .context_vm_steps = 500,
        .setup_ms = 8,
        .assemble_ms = 4,
        .body_ms = 3,
        .bytes = 4096,
        .status = "ok",
        .provider = "openrouter",
        .generation_id = "gen-test-123",
        .tokens_in = 120,
        .tokens_out = 45,
    }};
    const tools = [_]proto.DiagnosticTool{.{
        .name = "read_file",
        .status = "ok",
        .duration_ms = 80,
    }};
    const msg: proto.DaemonMsg = .{ .diagnostics_result = .{
        .sid = 7,
        .sample_turns = 3,
        .successful_turns = 2,
        .failed_turns = 1,
        .interrupted_turns = 0,
        .abandoned_turns = 0,
        .checkpoint_turns = 1,
        .provider_requests = 4,
        .tool_calls = 1,
        .provider_p50_ms = 1000,
        .provider_p95_ms = 2200,
        .ttft_p50_ms = 250,
        .ttft_p95_ms = 500,
        .local_prep_p50_ms = 20,
        .local_prep_p95_ms = 35,
        .pre_provider_p50_ms = 40,
        .pre_provider_p95_ms = 90,
        .pre_provider_max_ms = 1200,
        .pre_provider_slow_turns = 1,
        .last_turn_id = 9,
        .last_trace_id = "0123456789abcdef0123456789abcdef",
        .last_outcome = "error",
        .last_error = "collector response retained in full",
        .last_duration_ms = 1500,
        .last_rounds = &rounds,
        .last_tools = &tools,
        .otlp_enabled = true,
        .otlp_pending = 2,
        .otlp_last_error = "HTTP 401 authorization failed",
    } };
    app.handleDaemonLine(try proto.encode(gpa, msg));

    try std.testing.expectEqual(@as(usize, 1), app.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.system_note, app.blocks.items[0].kind);
    try std.testing.expectEqualStrings("diagnostics", app.blocks.items[0].label);
    try std.testing.expect(std.mem.indexOf(u8, app.blocks.items[0].text, "Provider #1") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.blocks.items[0].text, "Legacy pre-provider") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.blocks.items[0].text, "500 steps") != null);
    try std.testing.expect(std.mem.indexOf(u8, app.blocks.items[0].text, "HTTP 401 authorization failed") != null);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try layoutLines(arena, &app, 52);
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(gpa);
    for (lines.items) |line| {
        try rendered.appendSlice(gpa, try lineText(arena, line));
        try rendered.append(gpa, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "diagnostics") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "gen-test-123") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "HTTP 401") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.items, "authorization failed") != null);
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

test "incremental session catalog upserts preserve hierarchy and remove owned state" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 20,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.replaceSessionSummaries(&.{.{
        .sid = 10,
        .title = "older",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
    }});
    app.upsertSessionSummary(.{
        .sid = 20,
        .title = "new root",
        .cwd = "/work",
        .model = "m",
        .status = "idle",
        .created_at = 20,
        .running = false,
    });
    app.upsertSessionSummary(.{
        .sid = 21,
        .parent_sid = 20,
        .kind = .task_child,
        .title = "child",
        .cwd = "/work",
        .model = "m",
        .status = "running",
        .state = .running,
        .created_at = 21,
        .running = true,
    });
    try std.testing.expectEqualSlices(u64, &.{ 20, 21, 10 }, &.{
        app.sessions.items[0].sid,
        app.sessions.items[1].sid,
        app.sessions.items[2].sid,
    });
    // Restoring an older archived root inserts by durable catalog order; it
    // must not jump ahead of sessions created while it was hidden.
    app.upsertSessionSummary(.{
        .sid = 15,
        .title = "restored",
        .model = "m",
        .status = "idle",
        .created_at = 15,
        .running = false,
    });
    try std.testing.expectEqualSlices(u64, &.{ 20, 21, 15, 10 }, &.{
        app.sessions.items[0].sid,
        app.sessions.items[1].sid,
        app.sessions.items[2].sid,
        app.sessions.items[3].sid,
    });

    app.upsertSessionSummary(.{
        .sid = 20,
        .title = "renamed",
        .cwd = "/work",
        .model = "new-model",
        .status = "running",
        .state = .running,
        .created_at = 20,
        .running = true,
        .sandboxed = true,
    });
    try std.testing.expectEqual(proto.SessionState.running, app.state);
    try std.testing.expectEqualStrings("new-model", app.sessions.items[0].model);
    try std.testing.expect(app.sessions.items[0].sandboxed);
    try std.testing.expect(app.session_labels.items[0].ptr == app.sessions.items[0].label.ptr);

    app.removeSessionSummary(21);
    try std.testing.expectEqual(@as(usize, 3), app.sessions.items.len);
    try std.testing.expect(app.sessionSummary(21) == null);
}

test "inactive session view cache evicts least recently used transcripts" {
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

    for (1..App.max_saved_views + 4) |sid| {
        app.sid = sid;
        app.pushBlock(.assistant_msg, "cached transcript", "", .ok);
        try app.saveActiveView();
    }
    try std.testing.expectEqual(@as(usize, App.max_saved_views), app.saved_views.count());
    try std.testing.expect(app.saved_views.get(1) == null);
    try std.testing.expect(app.saved_views.get(App.max_saved_views + 3) != null);
}

test "tab bar is permanent, root-only, chronological, and rolls up child activity" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 30, .editor = Editor.init(gpa) };
    defer app.deinit();

    app.replaceSessionSummaries(&.{
        .{ .sid = 20, .title = "", .cwd = "/work/beta", .model = "m", .status = "running", .state = .running, .created_at = 20, .running = true },
        .{ .sid = 30, .parent_sid = 20, .kind = .task_child, .title = "review crypto", .cwd = "/work/beta", .model = "m", .status = "err", .state = .err, .created_at = 21, .running = false },
        .{ .sid = 10, .title = "", .cwd = "/work/alpha", .model = "m", .status = "idle", .created_at = 10, .running = false },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const layout = try layoutTabBar(arena_state.allocator(), &app, 120);
    try std.testing.expectEqual(@as(usize, 2), layout.items.len);
    try std.testing.expectEqual(@as(u64, 10), layout.items[0].sid);
    try std.testing.expectEqual(@as(u64, 20), layout.items[1].sid);
    try std.testing.expect(!layout.items[0].active);
    try std.testing.expect(layout.items[1].active); // focused child highlights its root
    try std.testing.expectEqual(TabActivity.err, layout.items[1].activity);
    try std.testing.expect(std.mem.indexOf(u8, layout.items[0].label, "alpha") != null);

    var empty = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 99, .editor = Editor.init(gpa) };
    defer empty.deinit();
    const fallback = try layoutTabBar(arena_state.allocator(), &empty, 80);
    try std.testing.expectEqual(@as(usize, 1), fallback.items.len);
    try std.testing.expect(fallback.items[0].active);
    try std.testing.expectEqual(@as(u64, 99), fallback.items[0].sid);
}

test "normal-mode tab navigation follows chronological roots and wraps" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 30, .editor = Editor.init(gpa) };
    defer app.deinit();

    app.replaceSessionSummaries(&.{
        .{ .sid = 20, .title = "second", .model = "m", .status = "idle", .created_at = 20, .running = false },
        .{ .sid = 30, .parent_sid = 20, .kind = .task_child, .title = "child", .model = "m", .status = "idle", .created_at = 21, .running = false },
        .{ .sid = 40, .title = "third", .model = "m", .status = "idle", .created_at = 20, .running = false },
        .{ .sid = 10, .title = "first", .model = "m", .status = "idle", .created_at = 10, .running = false },
    });

    // Alt+N indexing matches the rendered strip order: children never get a
    // slot, ties break on sid, and out-of-range indices are null (notice).
    try std.testing.expectEqual(@as(?u64, 10), rootTabSidAtIndex(app.sessions.items, 1));
    try std.testing.expectEqual(@as(?u64, 20), rootTabSidAtIndex(app.sessions.items, 2));
    try std.testing.expectEqual(@as(?u64, 40), rootTabSidAtIndex(app.sessions.items, 3));
    try std.testing.expectEqual(@as(?u64, null), rootTabSidAtIndex(app.sessions.items, 4));
    try std.testing.expectEqual(@as(?u64, null), rootTabSidAtIndex(app.sessions.items, 0));

    // Focused children navigate relative to their highlighted root. Equal
    // timestamps use sid as the same deterministic tie-break as the renderer.
    try std.testing.expectEqual(@as(?u64, 40), nextRootTabSid(app.sessions.items, app.rootSessionId(30), 1));
    try std.testing.expectEqual(@as(?u64, 10), nextRootTabSid(app.sessions.items, app.rootSessionId(30), -1));
    try std.testing.expectEqual(@as(?u64, 20), nextRootTabSid(app.sessions.items, 10, 1));
    try std.testing.expectEqual(@as(?u64, 40), nextRootTabSid(app.sessions.items, 10, -1));
    try std.testing.expectEqual(@as(?u64, 10), nextRootTabSid(app.sessions.items, 40, 1));

    // With one visible root, every shortcut is a no-op and never repurposes
    // Left/Right as composer movement in normal mode.
    var one = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 10, .editor = Editor.init(gpa) };
    defer one.deinit();
    one.replaceSessionSummaries(&.{.{ .sid = 10, .title = "only", .model = "m", .status = "idle", .created_at = 10, .running = false }});
    one.editor.insertSlice("draft");
    one.editor.cursor = 2;
    one.mode = .normal;
    try handleKey(&one, .{ .codepoint = '>' });
    try handleKey(&one, .{ .codepoint = vaxis.Key.left });
    try handleKey(&one, .{ .codepoint = '<' });
    try handleKey(&one, .{ .codepoint = vaxis.Key.right });
    try std.testing.expectEqual(@as(usize, 2), one.editor.cursor);
}

test "tab overflow retains the active tab and tab hit testing is button-extensible" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 4, .editor = Editor.init(gpa) };
    defer app.deinit();

    app.replaceSessionSummaries(&.{
        .{ .sid = 1, .title = "one", .model = "m", .status = "idle", .created_at = 1, .running = false },
        .{ .sid = 2, .title = "two", .model = "m", .status = "idle", .created_at = 2, .running = false },
        .{ .sid = 3, .title = "three", .model = "m", .status = "idle", .created_at = 3, .running = false },
        .{ .sid = 4, .title = "four", .model = "m", .status = "running", .state = .running, .created_at = 4, .running = true },
        .{ .sid = 5, .title = "five", .model = "m", .status = "idle", .created_at = 5, .running = false },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const layout = try layoutTabBar(arena_state.allocator(), &app, 24);
    try std.testing.expect(layout.hidden_left or layout.hidden_right);
    var found_active = false;
    for (layout.items) |item| {
        if (item.sid == 4) found_active = item.active;
        try std.testing.expect(item.x + item.width <= 24);
    }
    try std.testing.expect(found_active);

    try app.tab_hits.append(gpa, .{ .start_col = 3, .end_col = 11, .sid = 4 });
    try std.testing.expectEqual(@as(?u64, 4), app.tabAtColumn(3));
    try std.testing.expectEqual(@as(?u64, 4), app.tabAtColumn(10));
    try std.testing.expectEqual(@as(?u64, null), app.tabAtColumn(11));
    try std.testing.expectEqual(TabMouseAction.activate, tabMouseAction(.{ .row = 0, .col = 4, .button = .left, .mods = .{}, .type = .press }).?);
    try std.testing.expectEqual(TabMouseAction.context_menu, tabMouseAction(.{ .row = 0, .col = 4, .button = .right, .mods = .{}, .type = .press }).?);
    try std.testing.expect(tabMouseAction(.{ .row = 0, .col = 4, .button = .left, .mods = .{}, .type = .release }) == null);

    // Clicking the already-active tab is a complete no-op and must not begin
    // transcript selection even when no connection object is available.
    handleMouse(&app, .{ .row = 0, .col = 4, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expect(app.sel_anchor == null);
    handleMouse(&app, .{ .row = 0, .col = 4, .button = .wheel_up, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 3), app.scroll_up);

    app.last_total_lines = 45;
    app.last_first_visible = 40;
    app.last_view_h = 5;
    handleMouse(&app, .{ .row = 1, .col = 7, .button = .left, .mods = .{}, .type = .press });
    try std.testing.expectEqual(@as(usize, 40), app.sel_anchor.?.line); // row 0 is the tab strip
}

test "active prompt scrolls normally before sticking at the top" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var vx = try vaxis.init(threaded.io(), gpa, &environ, .{});
    defer vx.deinit(gpa, &output.writer);
    try vx.resize(gpa, &output.writer, .{ .rows = 18, .cols = 80, .x_pixel = 0, .y_pixel = 0 });

    var conn: attach.Conn = undefined;
    conn.sandbox_available = false;
    conn.network_filtering = false;
    conn.network_configured = false;
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = &conn, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.state = .running;
    try app.blocks.append(gpa, .{ .kind = .user_msg, .turn_id = 1, .text = try gpa.dupe(u8, "old prompt"), .label = try gpa.dupe(u8, "") });
    try app.blocks.append(gpa, .{ .kind = .assistant_msg, .turn_id = 1, .text = try gpa.dupe(u8, "old answer"), .label = try gpa.dupe(u8, "") });
    try app.blocks.append(gpa, .{ .kind = .user_msg, .turn_id = 2, .text = try gpa.dupe(u8, "the active request"), .label = try gpa.dupe(u8, "") });

    var frame = std.heap.ArenaAllocator.init(gpa);
    defer frame.deinit();
    try draw(&app, &vx, frame.allocator());
    try std.testing.expectEqual(@as(usize, 0), app.last_pinned_rows);
    try std.testing.expectEqual(app.last_first_visible, app.visibleLineAtRow(0).?);

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        try app.blocks.append(gpa, .{
            .kind = .reasoning,
            .turn_id = 2,
            .text = try std.fmt.allocPrint(gpa, "progress line {d}", .{i}),
            .label = try gpa.dupe(u8, ""),
            .commentary = true,
        });
    }
    app.layout_epoch +%= 1;
    frame.deinit();
    frame = std.heap.ArenaAllocator.init(gpa);
    try draw(&app, &vx, frame.allocator());
    try std.testing.expectEqual(@as(usize, 4), app.last_pinned_rows);
    try std.testing.expect(app.last_body_first > app.last_pinned_start + app.last_pinned_rows);
    try std.testing.expect(app.visibleLineAtRow(0) == null);
    try std.testing.expect(app.visibleLineAtRow(app.last_pinned_rows - 1) == null);
    try std.testing.expectEqual(app.last_body_first, app.visibleLineAtRow(app.last_pinned_rows).?);
    const pinned_mark = vx.window().readCell(1, @intCast(app.tabBarRows() + 1)).?;
    try std.testing.expectEqualStrings("#", pinned_mark.char.grapheme);
    try std.testing.expect(vaxis.Color.eql(pinned_mark.style.fg, Palette.pinned_prompt_mark.fg));

    app.scroll_up = 1;
    frame.deinit();
    frame = std.heap.ArenaAllocator.init(gpa);
    try draw(&app, &vx, frame.allocator());
    try std.testing.expectEqual(@as(usize, 0), app.last_pinned_rows);
    try std.testing.expectEqual(app.last_first_visible, app.visibleLineAtRow(0).?);
}

test "draw permanently reserves and paints the clickable tab row" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var vx = try vaxis.init(threaded.io(), gpa, &environ, .{});
    defer vx.deinit(gpa, &output.writer);
    try vx.resize(gpa, &output.writer, .{ .rows = 12, .cols = 80, .x_pixel = 0, .y_pixel = 0 });

    var conn: attach.Conn = undefined;
    conn.sandbox_available = false;
    conn.network_filtering = false;
    conn.network_configured = false;
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = &conn, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.setCwdStr("/work/marlin");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try draw(&app, &vx, arena_state.allocator());

    try std.testing.expectEqual(@as(usize, 1), app.tab_hits.items.len);
    try std.testing.expectEqual(@as(u64, 1), app.tab_hits.items[0].sid);
    try std.testing.expectEqual(@as(usize, 6), app.last_view_h);
    const tab_cell = vx.window().readCell(0, 0).?;
    try std.testing.expect(vaxis.Color.eql(tab_cell.style.bg, Palette.prompt_bg));
}

test "empty session draws the welcome card; content reclaims it" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    var vx = try vaxis.init(threaded.io(), gpa, &environ, .{});
    defer vx.deinit(gpa, &output.writer);
    try vx.resize(gpa, &output.writer, .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 });

    var conn: attach.Conn = undefined;
    conn.sandbox_available = true;
    conn.network_filtering = true;
    conn.network_configured = true;
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = &conn, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.setModelStr("openrouter/example/model");
    const dv = "0.0.0-dev";
    @memcpy(app.welcome_daemon_version[0..dv.len], dv);
    app.welcome_daemon_version_len = dv.len;
    app.welcome_sandbox = true;
    app.welcome_dnsblock_rules = 173_613;
    app.build_mismatch = true;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try draw(&app, &vx, arena_state.allocator());

    var screen: std.ArrayList(u8) = .empty;
    defer screen.deinit(gpa);
    var row: u16 = 0;
    while (row < 24) : (row += 1) {
        var col: u16 = 0;
        while (col < 80) : (col += 1) {
            const cell = vx.window().readCell(col, row) orelse continue;
            try screen.appendSlice(gpa, cell.char.grapheme);
        }
        try screen.append(gpa, '\n');
    }
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "marlin") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "daemon v0.0.0-dev · sandbox ✓ · dnsblock 173613 rules") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "⚠ daemon runs a different build — /reboot to sync") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "openrouter/example/model") != null);
    try std.testing.expect(std.mem.indexOf(u8, screen.items, "send a prompt") != null);

    // Loading history, a running turn, or any transcript content reclaims
    // the area: the card is empty-state orientation, never chrome.
    app.history_loading = true;
    var frame2 = std.heap.ArenaAllocator.init(gpa);
    defer frame2.deinit();
    try draw(&app, &vx, frame2.allocator());
    var found = false;
    row = 0;
    scan: while (row < 24) : (row += 1) {
        var col: u16 = 0;
        var line_buf: [512]u8 = undefined;
        var line_len: usize = 0;
        while (col < 80) : (col += 1) {
            const cell = vx.window().readCell(col, row) orelse continue;
            const g = cell.char.grapheme;
            if (line_len + g.len <= line_buf.len) {
                @memcpy(line_buf[line_len..][0..g.len], g);
                line_len += g.len;
            }
        }
        if (std.mem.indexOf(u8, line_buf[0..line_len], "send a prompt") != null) {
            found = true;
            break :scan;
        }
    }
    try std.testing.expect(!found);
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
    // No paired call in view → generic source label.
    try std.testing.expectEqualStrings("tool", app.clipboard_desc.items);
}

test "!c names the folded source it copies (positional batch pairing)" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // inline results only; !c never touches the socket
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    // One parallel batch: three calls then three results, same turn. The
    // last result pairs with the last call even though the transcript
    // folds all of them into a "Ran 3 commands" summary.
    const calls = [_]struct { id: []const u8, name: []const u8, args: []const u8 }{
        .{ .id = "c1", .name = "grep", .args = "{\"pattern\":\"foo\"}" },
        .{ .id = "c2", .name = "bash", .args = "{\"command\":\"ls\"}" },
        .{ .id = "c3", .name = "read_file", .args = "{\"path\":\"docs/PERMISSIONS.md\"}" },
    };
    var seq: u64 = 1;
    for (calls) |c| {
        app.applyBlock(.{
            .id = seq,
            .session_id = 1,
            .turn_id = 9,
            .seq = seq,
            .ts = 0,
            .body = .{ .tool_call = .{ .call_id = c.id, .name = c.name, .args_json = c.args } },
        });
        seq += 1;
    }
    for (calls) |c| {
        app.applyBlock(.{
            .id = seq,
            .session_id = 1,
            .turn_id = 9,
            .seq = seq,
            .ts = 0,
            .body = .{ .tool_result = .{
                .call_id = c.id,
                .status = .ok,
                .inline_body = "259|## Implementation slices",
                .full_body_ref = null,
            } },
        });
        seq += 1;
    }

    app.runCommand("!c");
    try std.testing.expectEqualStrings("259|## Implementation slices", app.clipboard_pending.items);
    try std.testing.expectEqualStrings("Read docs/PERMISSIONS.md", app.clipboard_desc.items);
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
        if (std.mem.indexOf(u8, text, "⚙ Edit") != null) saw_dangling = true;
    }
    try std.testing.expect(saw_summary);
    try std.testing.expect(saw_dangling);
}

test "raw provider reasoning folds; commentary narration stays visible" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();

    // The grok shape: raw reasoning (with a drafted reply inside) followed
    // by the model's deliberate one-line narration, both kind=reasoning.
    try app.blocks.append(gpa, .{
        .kind = .reasoning,
        .seq = 1,
        .turn_id = 7,
        .text = try gpa.dupe(u8, "The user wants a review. Thanks for the update, solid work!"),
        .label = try gpa.dupe(u8, ""),
    });
    try app.blocks.append(gpa, .{
        .kind = .reasoning,
        .seq = 2,
        .turn_id = 7,
        .text = try gpa.dupe(u8, "Re-reading the tree against the last review."),
        .label = try gpa.dupe(u8, ""),
        .commentary = true,
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const collapsed = try layoutLines(arena, &app, 120);
    var saw_raw = false;
    var saw_narration = false;
    for (collapsed.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Thanks for the update") != null) saw_raw = true;
        if (std.mem.indexOf(u8, text, "Re-reading the tree") != null) saw_narration = true;
    }
    try std.testing.expect(!saw_raw);
    try std.testing.expect(saw_narration);

    // ctrl+t (transcript view) reveals the raw reasoning again.
    app.show_tool_transcript = true;
    app.layout_epoch +%= 1;
    const expanded = try layoutLines(arena, &app, 120);
    saw_raw = false;
    for (expanded.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "Thanks for the update") != null) saw_raw = true;
    }
    try std.testing.expect(saw_raw);
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

test "Plan mode keys distinguish toggle and proposal actions" {
    try std.testing.expect(isPlanToggleKey(.{ .codepoint = vaxis.Key.tab, .mods = .{ .shift = true } }));
    try std.testing.expect(!isPlanToggleKey(.{ .codepoint = vaxis.Key.tab }));
    try std.testing.expectEqual(PlanProposalAction.implement, planProposalAction(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expectEqual(PlanProposalAction.revise, planProposalAction(.{ .codepoint = 'e' }));
    try std.testing.expectEqual(PlanProposalAction.stay, planProposalAction(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(PlanProposalAction.dismiss, planProposalAction(.{ .codepoint = 'q' }));
    try std.testing.expectEqual(PlanProposalAction.none, planProposalAction(.{ .codepoint = 'x' }));
}

test "Plan clear result removes only the active session todo" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 7,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();
    try app.plan.append(gpa, .{ .step = try gpa.dupe(u8, "stale work"), .status = .in_progress });

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .plan_clear_result = .{
        .sid = 8,
        .cleared = true,
    } }));
    try std.testing.expectEqual(@as(usize, 1), app.plan.items.len);

    app.handleDaemonLine(try proto.encode(gpa, proto.DaemonMsg{ .plan_clear_result = .{
        .sid = 7,
        .cleared = true,
    } }));
    try std.testing.expectEqual(@as(usize, 0), app.plan.items.len);
    try std.testing.expectEqualStrings("execution plan cleared", app.notice.items);
}

test "Plan mode proposal becomes actionable only from a live finalized answer" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(gpa),
        .plan_mode = true,
    };
    defer app.deinit();

    app.history_loading = true;
    app.applyBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 0,
        .body = .{ .assistant_msg = .{ .text = "old proposal" } },
    });
    try std.testing.expect(!app.plan_proposal_ready);

    app.history_loading = false;
    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 2,
        .seq = 2,
        .ts = 0,
        .body = .{ .assistant_msg = .{ .text = "new proposal" } },
    });
    try std.testing.expect(app.plan_proposal_ready);

    app.applyBlock(.{
        .id = 3,
        .session_id = 1,
        .turn_id = 3,
        .seq = 3,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "revise it" } },
    });
    try std.testing.expect(!app.plan_proposal_ready);
}

test "plan table centers current work and retains completed timings" {
    const items = [_]PlanItemOwned{
        .{ .step = @constCast("one"), .status = .completed },
        .{ .step = @constCast("two"), .status = .completed },
        .{ .step = @constCast("three"), .status = .in_progress },
        .{ .step = @constCast("four"), .status = .pending },
        .{ .step = @constCast("five"), .status = .pending },
        .{ .step = @constCast("six"), .status = .pending },
    };
    const visible = planDisplayRange(&items, 3);
    try std.testing.expectEqual(@as(usize, 1), visible.start);
    try std.testing.expectEqual(@as(usize, 3), visible.len);

    const completed = [_]PlanItemOwned{
        .{ .step = @constCast("one"), .status = .completed },
        .{ .step = @constCast("two"), .status = .completed },
    };
    try std.testing.expectEqual(@as(usize, 2), planDisplayRange(&completed, 5).len);
    try std.testing.expectEqual(@as(usize, 0), planDisplayRange(&items, 0).len);
    try std.testing.expect(hasUnfinishedPlan(&items));
    try std.testing.expect(!hasUnfinishedPlan(&completed));
}

test "live plan reserves a framed blank row above the composer" {
    const items = [_]PlanItemOwned{.{
        .step = @constCast("work"),
        .status = .in_progress,
    }};
    const with_plan = planSurfaceLayout(20, 0, 3, &items);
    try std.testing.expectEqual(@as(u16, 3), with_plan.plan_h);
    try std.testing.expectEqual(@as(u16, 12), with_plan.view_h);

    const without_plan = planSurfaceLayout(20, 0, 3, &.{});
    try std.testing.expectEqual(@as(u16, 0), without_plan.plan_h);
    try std.testing.expectEqual(@as(u16, 15), without_plan.view_h);
}

test "completed plan leaves the live panel and remains durable in transcript" {
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
        .turn_id = 1,
        .seq = 1,
        .ts = 0,
        .body = .{ .plan = .{ .items = &.{.{ .step = "Inspect", .status = .in_progress }} } },
    });
    try std.testing.expectEqual(@as(usize, 0), app.blocks.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.plan.items.len);

    app.applyBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 1,
        .seq = 2,
        .ts = 0,
        .body = .{ .plan = .{ .items = &.{.{
            .step = "Inspect",
            .status = .completed,
            .duration_ms = 4_200,
        }} } },
    });
    try std.testing.expectEqual(@as(usize, 1), app.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.plan, app.blocks.items[0].kind);
    try std.testing.expectEqual(@as(usize, 0), app.plan.items.len);

    app.applyBlock(.{
        .id = 3,
        .session_id = 1,
        .turn_id = 2,
        .seq = 3,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "what next?" } },
    });
    try std.testing.expectEqual(@as(usize, 0), app.plan.items.len);
    try std.testing.expectEqual(@as(usize, 2), app.blocks.items.len);
    try std.testing.expectEqual(block.BlockKind.plan, app.blocks.items[0].kind);
    try std.testing.expectEqualStrings("Inspect", app.blocks.items[0].plan_items[0].step);
}

test "plan table uses semantic markers, stable columns, and concise timing" {
    const pending = planMarker(.pending, .idle, 0);
    const active = planMarker(.in_progress, .running, 3);
    const paused = planMarker(.in_progress, .idle, 3);
    const failed = planMarker(.in_progress, .err, 3);
    const completed = planMarker(.completed, .idle, 0);

    try std.testing.expectEqualStrings("·", pending.glyph);
    try std.testing.expectEqualStrings(spinner_frames[3], active.glyph);
    try std.testing.expectEqualStrings("⏸", paused.glyph);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(paused.glyph));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_pending.fg, paused.glyph_style.fg));
    try std.testing.expect(!paused.text_style.bold);
    try std.testing.expectEqualStrings("×", failed.glyph);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(failed.glyph));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_error.fg, failed.glyph_style.fg));
    try std.testing.expectEqualStrings("✔", completed.glyph);
    try std.testing.expectEqual(@as(usize, 1), displayWidth(completed.glyph));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_done_mark.fg, completed.glyph_style.fg));
    try std.testing.expect(vaxis.Color.eql(Palette.plan_pending.fg, completed.text_style.fg));
    try std.testing.expect(!completed.text_style.dim);
    try std.testing.expect(active.text_style.bold);

    const wide = planTableWidths(80);
    try std.testing.expectEqual(@as(usize, 67), wide.task);
    try std.testing.expectEqual(@as(usize, 10), wide.time);
    const narrow = planTableWidths(20);
    try std.testing.expectEqual(@as(usize, 10), narrow.task);
    try std.testing.expectEqual(@as(usize, 7), narrow.time);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("<1s", try formatPlanDuration(arena, 450));
    try std.testing.expectEqualStrings("18s", try formatPlanDuration(arena, 18_400));
    try std.testing.expectEqualStrings("2m 5s", try formatPlanDuration(arena, 125_000));
    try std.testing.expectEqualStrings("1h 2m", try formatPlanDuration(arena, 3_720_000));
    const task_rule = try planRule(arena, wide.task);
    const time_rule = try planRule(arena, wide.time);
    try std.testing.expectEqual(@as(usize, 67), displayWidth(task_rule));
    try std.testing.expectEqual(@as(usize, 10), displayWidth(time_rule));
    try std.testing.expect(std.mem.indexOf(u8, task_rule, "TODO") == null);
    try std.testing.expect(std.mem.indexOf(u8, time_rule, "TIME") == null);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = std.testing.allocator,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 1,
        .editor = Editor.init(std.testing.allocator),
        .state = .running,
    };
    defer app.deinit();
    const timed_active = PlanItemOwned{
        .step = @constCast("work"),
        .status = .in_progress,
        .started_at_ms = 2_000,
        .duration_ms = 3_000,
    };
    try std.testing.expectEqual(@as(?u64, 6_000), planItemTimeMs(&app, timed_active, 5_000));
    app.state = .idle;
    try std.testing.expectEqual(@as(?u64, 3_000), planItemTimeMs(&app, timed_active, 50_000));
}

test "parked approvals are findable per tree and globally; badge follows the session" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined,
        .sid = 10,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.replaceSessionSummaries(&.{ .{
        .sid = 10,
        .title = "focused root",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
        .full_access = true,
    }, .{
        .sid = 20,
        .title = "other root",
        .model = "m",
        .status = "idle",
        .created_at = 20,
        .running = false,
    }, .{
        .sid = 21,
        .parent_sid = 20,
        .kind = .task_child,
        .title = "parked child",
        .model = "m",
        .status = "awaiting_approval",
        .state = .awaiting_approval,
        .created_at = 21,
        .running = false,
    } });

    // Activating the flagged tree lands on the parked child, not the root.
    try std.testing.expectEqual(@as(?u64, 21), app.awaitingSessionInTree(20));
    try std.testing.expectEqual(@as(?u64, null), app.awaitingSessionInTree(10));
    // y/n with nothing parked here jumps to the parked session.
    try std.testing.expectEqual(@as(?u64, 21), app.firstAwaitingSid());

    // FULL ACCESS is per session (server truth), not App state: an upsert
    // for the focused session updates the badge; other sessions never do.
    app.upsertSessionSummary(.{
        .sid = 10,
        .title = "focused root",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
        .full_access = true,
    });
    try std.testing.expect(app.permissions_full);
    app.upsertSessionSummary(.{
        .sid = 10,
        .title = "focused root",
        .model = "m",
        .status = "idle",
        .created_at = 10,
        .running = false,
        .full_access = false,
    });
    try std.testing.expect(!app.permissions_full);
}

test "review prompt expansion names the council, roster, and question" {
    const gpa = std.testing.allocator;
    var council = OwnedCouncil{ .name = try gpa.dupe(u8, "core") };
    defer council.deinit(gpa);
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/x-ai/grok-4.6"));
    try council.models.append(gpa, try gpa.dupe(u8, "openrouter/z-ai/glm-5.3"));

    const prompt = try buildReviewPrompt(gpa, &council, "is the cache safe?");
    defer gpa.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "council \"core\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- openrouter/x-ai/grok-4.6\n- openrouter/z-ai/glm-5.3") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "task_batch") != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "Question for the council: is the cache safe?"));
}

test "transcript spacing invariant: every section breathes, nothing doubles" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{ .gpa = gpa, .io = threaded.io(), .conn = undefined, .sid = 1, .editor = Editor.init(gpa) };
    defer app.deinit();

    // Every block kind, in deliberately hostile adjacency: summaries after
    // cards (the reported bug), commentary between tool stretches, notes and
    // markers back to back.
    const Entry = struct { block.BlockKind, u64, []const u8, []const u8, bool };
    const entries = [_]Entry{
        .{ .user_msg, 7, "start the work", "", false },
        .{ .tool_call, 7, "{\"command\":\"zig build\"}", "bash", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .tool_call, 7, "{\"pattern\":\"x\"}", "grep", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .user_msg, 7, "and now?", "", false },
        .{ .tool_call, 7, "{\"path\":\"a\"}", "read_file", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .reasoning, 7, "checking the gate before answering", "", true },
        .{ .tool_call, 7, "{\"path\":\"b\"}", "read_file", false },
        .{ .tool_result, 7, "ok", "", false },
        .{ .assistant_msg, 7, "all good", "", false },
        .{ .steer, 7, "also check the docs", "", false },
        .{ .compaction, 7, "", "", false },
        .{ .system_note, 7, "context compacted automatically", "", false },
        .{ .user_msg, 8, "next round", "", false },
        .{ .assistant_msg, 8, "done", "", false },
    };
    for (entries, 0..) |entry, i| try app.blocks.append(gpa, .{
        .kind = entry[0],
        .seq = i + 1,
        .turn_id = entry[1],
        .text = try gpa.dupe(u8, entry[2]),
        .label = try gpa.dupe(u8, entry[3]),
        .commentary = entry[4],
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Pass = struct { show_transcript: bool, state: proto.SessionState };
    for ([_]Pass{
        .{ .show_transcript = false, .state = .idle },
        .{ .show_transcript = true, .state = .idle },
        // Running splits the active turn into the tail layout range: the
        // freshly submitted prompt is the tail's first section and its air
        // must survive the range seam (the reported flush-card bug).
        .{ .show_transcript = false, .state = .running },
    }) |pass| {
        const show_transcript = pass.show_transcript;
        app.show_tool_transcript = show_transcript;
        app.state = pass.state;
        app.layout_epoch +%= 1;
        const lines = try layoutLines(arena, &app, 100);
        try std.testing.expect(lines.items.len > 0);

        var saw_dense_flush = false;
        for (lines.items, 0..) |line, i| {
            const plain_blank = line.text.len == 0 and line.text2.len == 0 and
                line.text3.len == 0 and line.fill_style == null;
            const prev: ?Line = if (i > 0) lines.items[i - 1] else null;
            const prev_plain_blank = if (prev) |p|
                p.text.len == 0 and p.text2.len == 0 and p.text3.len == 0 and p.fill_style == null
            else
                false;

            // 1. Never two plain blanks in a row; never a leading blank.
            if (plain_blank) try std.testing.expect(i > 0 and !prev_plain_blank);

            // 2. Content never sits flush under a card: a filled padding row
            //    is only ever followed by more card rows or a plain blank.
            if (prev != null and prev.?.fill_style != null and line.fill_style == null) {
                try std.testing.expect(plain_blank);
            }

            // 2b. Nor above one: a card's first filled row always has air —
            //     this is the range-seam case (a freshly submitted prompt
            //     starts the tail range, whose leading blank is a no-op in
            //     its own list and must be restored at concatenation).
            if (line.fill_style != null and prev != null and prev.?.fill_style == null) {
                try std.testing.expect(prev_plain_blank);
            }

            // 3. Section markers always breathe: one blank (or a card row,
            //    for labels attached to cards) directly above.
            const is_marker = std.mem.startsWith(u8, line.text, "  • ") or
                std.mem.startsWith(u8, line.text, "  · ") or
                std.mem.startsWith(u8, line.text, "  ↪ ") or
                std.mem.startsWith(u8, line.text, "  ≋ ");
            if (is_marker) {
                try std.testing.expect(i > 0);
                try std.testing.expect(prev_plain_blank or prev.?.fill_style != null);
            }

            // Dense grouping must survive: in the full transcript view a
            // result row sits flush under its call row.
            if (show_transcript and i > 0) {
                const text = try lineText(arena, line);
                const prev_text = try lineText(arena, prev.?);
                if (std.mem.indexOf(u8, prev_text, "⚙") != null and !plain_blank and
                    std.mem.indexOf(u8, text, "⚙") == null and text.len > 0)
                {
                    saw_dense_flush = true;
                }
            }
        }
        // 4. Nothing trails.
        const last = lines.items[lines.items.len - 1];
        try std.testing.expect(last.text.len > 0 or last.text2.len > 0 or
            last.text3.len > 0 or last.fill_style != null);
        if (show_transcript) try std.testing.expect(saw_dense_flush);
    }
}
