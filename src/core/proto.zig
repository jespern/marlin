//! Wire protocol between clients and the daemon.
//!
//! Transport: NDJSON over a unix socket. One JSON object per line, encoded
//! as std.json's native tagged-union form: {"<type>":{...payload...}}.
//! See docs/PROTOCOL.md.
//!
//! Disciplines:
//!   - Deltas are ephemeral; blocks are truth. Clients render deltas for
//!     liveness, then replace them with the finalized block.
//!   - sub.from_seq: 0 = live-only (no replay); N >= 1 replays stored blocks
//!     with seq >= N. Bounded pages go live only at the durable frontier.
//!   - Unknown fields are ignored on read; unknown message types are an err.

const std = @import("std");
const block = @import("block.zig");
const guest = @import("guest.zig");
pub const ReasoningEffort = @import("effort.zig").Effort;
pub const GuestBackend = guest.Backend;

pub const proto_version: u32 = 5;
/// Maximum complete NDJSON record, including its trailing newline. Large
/// blob replies can JSON-escape to several times their raw size, so this is
/// deliberately larger than any supported tool capture while still bounding
/// memory per connection.
pub const max_line_bytes: usize = 32 * 1024 * 1024;

pub const SessionState = enum { idle, running, awaiting_approval, err, done };

/// Coarse, lock-free turn phase used for cancellation diagnostics. This is
/// deliberately operational rather than provider-specific: clients can say
/// what is being cancelled without coupling themselves to loop internals.
pub const TurnPhase = enum { idle, starting, context, provider, approval, tool, child, compaction, finishing };

pub const InterruptResult = struct {
    sid: u64,
    active: bool,
    already_requested: bool = false,
    request_count: u32 = 0,
    pending_ms: u64 = 0,
    phase_ms: u64 = 0,
    phase: TurnPhase = .idle,
};

/// Durable role in the session hierarchy. M6 initially permits one level of
/// task children; review_child is reserved for the council layer that reuses
/// the same storage/protocol shape.
pub const SessionKind = enum { root, task_child, review_child };

/// Guest sessions use a delegated agent namespace. Native sessions are every
/// other registry prefix. The regime is inferred from this prefix until a
/// durable agent field exists (ARCHITECTURE.md, Native vs guest).
pub fn isGuestModel(model: []const u8) bool {
    return guest.isGuest(model);
}

pub fn guestBackend(model: []const u8) ?GuestBackend {
    return guest.backend(model);
}

pub fn guestModelName(model: []const u8) ?[]const u8 {
    return guest.modelName(model);
}

/// Optional catalog pricing attached to a model id. Rates are normalized to
/// USD per million tokens so clients never have to know a provider catalog's
/// native units. Null means the provider did not publish that rate.
pub const ModelPricing = struct {
    model: []const u8,
    input_per_million: ?f64 = null,
    output_per_million: ?f64 = null,
    /// True when the advertised rates are only the base tier and may change
    /// with context length.
    tiered: bool = false,
};

/// A named review council: an ordered roster of registry-form model ids.
/// Durable in config.toml ([[council]] tables); clients expand /review
/// invocations from this.
pub const CouncilInfo = struct {
    name: []const u8,
    models: []const []const u8,
};

pub const InputHistoryEntry = struct {
    sid: u64,
    seq: u64,
    ts: i64,
    text: []const u8,
};

pub const SearchHit = struct {
    sid: u64,
    block_id: u64,
    seq: u64,
    ts: i64,
    kind: block.BlockKind,
    title: []const u8,
    cwd: []const u8,
    snippet: []const u8,
};

pub const McpServerInfo = struct {
    name: []const u8,
    ready: bool,
    tool_count: u32,
    error_message: ?[]const u8 = null,
};

/// Daemon-host readiness for first-run setup. A remote client must never
/// infer these facts from its own environment or installed binaries.
pub const SetupStatus = struct {
    completed: bool = false,
    default_model: []const u8,
    default_effort: ReasoningEffort = .auto,
    codex_available: bool = false,
    codex_authenticated: bool = false,
    claude_code_available: bool = false,
    claude_code_authenticated: bool = false,
    openrouter_ready: bool = false,
    vercel_ready: bool = false,
    anthropic_ready: bool = false,
    litellm_ready: bool = false,
    local_ready: bool = false,
};

pub const DiagnosticRound = struct {
    round: u32,
    duration_ms: u64,
    ttft_ms: u64,
    /// Turn start to first provider request. Populated for round zero only;
    /// older telemetry can still reconstruct this coarse local gap.
    pre_provider_ms: u64 = 0,
    context_load_ms: u64 = 0,
    store_wait_ms: u64 = 0,
    context_rows: u64 = 0,
    context_bytes: u64 = 0,
    context_vm_steps: u64 = 0,
    setup_ms: u64 = 0,
    assemble_ms: u64 = 0,
    body_ms: u64 = 0,
    bytes: u64,
    status: []const u8,
    provider: []const u8 = "",
    generation_id: []const u8 = "",
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    cached_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
};

pub const DiagnosticTool = struct {
    name: []const u8,
    status: []const u8,
    duration_ms: u64,
};

/// Bounded, deterministic local evidence for one session. Prompt and tool
/// contents are deliberately absent: this is operational telemetry, not a
/// second transcript.
pub const Diagnostics = struct {
    sid: u64,
    sample_turns: u32,
    successful_turns: u32,
    failed_turns: u32,
    interrupted_turns: u32,
    abandoned_turns: u32,
    checkpoint_turns: u32,
    provider_requests: u32,
    tool_calls: u32,
    provider_p50_ms: u64,
    provider_p95_ms: u64,
    ttft_p50_ms: u64,
    ttft_p95_ms: u64,
    /// Exact measured local preparation for telemetry written by schema v13+.
    local_prep_p50_ms: u64 = 0,
    local_prep_p95_ms: u64 = 0,
    /// Coarse turn-start → first-provider gap, available for legacy rows too.
    pre_provider_p50_ms: u64 = 0,
    pre_provider_p95_ms: u64 = 0,
    pre_provider_max_ms: u64 = 0,
    pre_provider_slow_turns: u32 = 0,
    last_turn_id: u64 = 0,
    last_trace_id: []const u8 = "",
    last_outcome: []const u8 = "none",
    last_error: []const u8 = "",
    last_duration_ms: u64 = 0,
    last_rounds: []const DiagnosticRound = &.{},
    last_tools: []const DiagnosticTool = &.{},
    otlp_enabled: bool = false,
    otlp_pending: u32 = 0,
    otlp_last_error: []const u8 = "",
};

/// Client-owned media submitted with one user message. Base64 keeps NDJSON
/// valid for arbitrary binary data and lets a local client upload directly
/// to a remote daemon without sharing a filesystem.
pub const AttachmentUpload = struct {
    name: []const u8,
    mime: []const u8,
    data_base64: []const u8,
};

/// Client → daemon.
pub const ClientMsg = union(enum) {
    hello: struct { proto_version: u32, client_kind: []const u8 = "generic" },
    session_create: struct {
        cwd: []const u8,
        model: []const u8,
        effort: ReasoningEffort = .auto,
        title: []const u8 = "",
        /// Correlates interactive creation with its terminal reply. Zero is
        /// the legacy/untracked value used by synchronous clients.
        request_id: u64 = 0,
        /// "default" = mutating tools ask; "auto" = everything auto-approved
        /// (headless one-shots and --yolo).
        approvals: []const u8 = "default",
    },
    session_list: struct { include_archived: bool = false },
    /// Recent authored messages for client-side fuzzy Ctrl+R recall. Results
    /// are newest-first and span sessions.
    input_history: struct { sid: u64 = 0, limit: u32 = 256 },
    /// Durable transcript search. sid=0 searches every session.
    search: struct { query: []const u8, sid: u64 = 0, limit: u32 = 100 },
    /// Operational timings/outcomes for one session. `turn_limit` bounds the
    /// percentile sample; the latest turn's waterfall is always included.
    diagnostics: struct { sid: u64, turn_limit: u32 = 50 },
    /// Replace or disable the daemon's process-local OTLP exporter without a
    /// restart. Credentials travel only over the local socket or SSH pipe and
    /// are never persisted. Empty endpoint fields select disabled state.
    otel_configure: struct {
        endpoint: []const u8 = "",
        traces_endpoint: []const u8 = "",
        headers: []const u8 = "",
    },
    otel_status: struct {},
    /// Toggle opt-in GenAI content capture (prompts, replies, tool
    /// args/results on exported spans). Requires an active exporter; the
    /// flag applies to everything still in the durable outbox.
    otel_content: struct { enabled: bool },
    /// Subscribe this client to refreshed session_list_result snapshots when
    /// any session enters an actionable state or its membership changes.
    /// The daemon replies with an immediate snapshot, then sends updates until
    /// the client disconnects. This is independent of per-session block subs.
    session_watch: struct {
        /// Opt into additive session_upsert/session_remove events after the
        /// initial authoritative snapshot. Legacy watchers keep receiving
        /// complete snapshots on structural changes.
        incremental: bool = false,
    },
    session_kill: struct { sid: u64 },
    /// Hide/restore a durable session hierarchy without deleting its log.
    session_archive: struct { sid: u64, archived: bool = true },
    /// Set a session's display title. The daemon normalizes it like
    /// auto-generated titles (first line, trimmed, length-capped).
    session_rename: struct { sid: u64, title: []const u8 },
    session_set_model: struct { sid: u64, model: []const u8 },
    session_set_effort: struct { sid: u64, effort: ReasoningEffort },
    /// Persist the session collaboration mode. Plan mode is daemon-enforced
    /// read-only and survives client reconnects and daemon restarts.
    session_set_plan_mode: struct { sid: u64, enabled: bool },
    /// Toggle the kernel shell sandbox (and its prompt-free shell execution)
    /// for one session. Enabling requires the daemon's verified backend
    /// (hello_ok.sandbox_available); the daemon rejects it otherwise.
    session_set_sandbox: struct { sid: u64, enabled: bool },
    /// Switch a session's approval mode: "default" = boundary-crossing tools
    /// ask; "auto" = full access, nothing asks (/permissions full).
    session_set_approvals: struct { sid: u64, approvals: []const u8 },
    /// Toggle managed-tool hostname filtering for one session. Enabling
    /// requires a loaded policy (hello_ok.network_filtering).
    session_set_network_filtering: struct { sid: u64, enabled: bool },
    /// Fetch an uncapped tool result by its content-addressed blob hash.
    /// Used by `!c`; the inline block body may be intentionally truncated.
    blob_get: struct { hash: []const u8 },
    /// `tail_limit>0` requests the newest N blocks (ascending) instead of an
    /// unbounded replay from `from_seq`. `before_seq>0` bounds that window to
    /// older blocks, enabling fixed-size backwards pagination. `replay_limit`
    /// bounds forward catch-up. `replay_done` opts into the terminal marker
    /// for a legacy from-seq replay; old clients therefore never receive a
    /// union tag they cannot decode. These fields are additive for older peers.
    sub: struct {
        sid: u64,
        from_seq: u64 = 0,
        tail_limit: u32 = 0,
        before_seq: u64 = 0,
        /// Center a bounded replay window on this durable sequence. This is
        /// used when selecting a transcript-search result.
        around_seq: u64 = 0,
        /// Bound forward replay. The daemon delays the live subscription
        /// until paging reaches the durable frontier, so blocks cannot arrive
        /// out of order between pages.
        replay_limit: u32 = 0,
        replay_done: bool = false,
    },
    unsub: struct { sid: u64 },
    /// `request_id` correlates the optimistic client echo with the one
    /// terminal ok/err reply. Zero is the legacy/untracked value.
    input: struct {
        sid: u64,
        text: []const u8,
        request_id: u64 = 0,
        attachments: []const AttachmentUpload = &.{},
    },
    approve: struct { sid: u64, approval_id: []const u8, decision: ApprovalAnswer },
    /// One Claude Code permission prompt forwarded by the `marlin cc_approve`
    /// bridge subprocess of a delegated session. The daemon replies
    /// cc_approval_result — immediately when policy auto-allows the call,
    /// otherwise only after a human answers the parked approval_request
    /// (the reply may be arbitrarily delayed; the bridge waits).
    cc_approval: struct { sid: u64, tool: []const u8, args_json: []const u8 },
    /// Manual L2 compaction (/compact). Rejected while a turn is running.
    session_compact: struct { sid: u64 },
    /// Full model catalog for the /model picker: daemon fetches the
    /// provider's model list (cached ~1h) and replies model_list_result.
    model_list: struct {},
    /// Query and apply provider onboarding on the daemon host. Credential
    /// material is never echoed and clients send setup_apply with the
    /// transport's sensitive-buffer path.
    setup_status: struct {
        /// Guest login probes spawn vendor CLIs and are intentionally opt-in.
        /// Callers that only need durable defaults keep this false and return
        /// immediately; the interactive picker asks for the full result.
        probe_guests: bool = true,
    },
    setup_apply: struct {
        sid: u64,
        model: []const u8,
        provider_name: []const u8 = "",
        base_url: []const u8 = "",
        api_key_env: []const u8 = "",
        credential: []const u8 = "",
        /// Fresh setup creates a placeholder session before entering the TUI.
        /// It may be rewritten directly only while its transcript is empty.
        replace_empty_session: bool = false,
    },
    /// MCP is daemon-owned. Listing and lifecycle actions therefore work from
    /// any thin client without assuming a shared process or filesystem.
    mcp_list: struct {},
    mcp_restart: struct { name: []const u8 },
    /// Persist a stdio server in config.toml, then rebuild the live registry.
    mcp_add: struct { name: []const u8, cmd: []const []const u8 },
    mcp_remove: struct { name: []const u8 },
    /// Persist one client UI preference through the daemon-owned config path.
    ui_set_tab_bar: struct { enabled: bool },
    /// Persist `[ui] bell` (terminal BEL on a background approval).
    ui_set_bell: struct { enabled: bool },
    /// Persist the client-local inactivity delay and selected effect.
    ui_set_screensaver: struct { after_ms: u64, effect: []const u8 = "matrix" },
    /// Re-read config and atomically replace extensions while no turn is live.
    mcp_reload: struct {},
    interrupt: struct {
        sid: u64,
        /// Opt into interrupt_result instead of the legacy ok reply.
        report: bool = false,
    },
    /// Define or replace a named review council (durable in config.toml,
    /// daemon-owned like MCP servers). Replies council_list_result.
    council_set: struct { name: []const u8, models: []const []const u8 },
    /// Remove a named council. Replies council_list_result.
    council_remove: struct { name: []const u8 },
    /// List configured councils. Replies council_list_result.
    council_list: struct {},
    /// Complete the latest unfinished durable execution plan without starting
    /// a turn. Used by `/plan clear` as an explicit recovery path.
    plan_clear: struct { sid: u64, request_id: u64 = 0 },
    /// Accept the latest Plan-mode proposal: leave Plan mode, seed a durable
    /// execution todo, and start implementation in one dispatcher operation.
    plan_accept: struct { sid: u64, request_id: u64 = 0 },
    /// Blob-store maintenance (`marlin gc`): sweep orphan blobs, and demote
    /// full bodies older than expire_before_ms when non-zero. Runs in the
    /// daemon so the store keeps its single-connection discipline; replies
    /// gc_result.
    gc: struct { expire_before_ms: i64 = 0 },
    /// Coordinated shutdown for /reboot: quiesce (wait for running turns to
    /// hit a block boundary — or interrupt them when force=true), persist,
    /// release the socket, exit 0. Reply `ok` is sent RIGHT BEFORE exit; the
    /// requesting client execs the new binary when it sees it. Autostart
    /// then brings up the new daemon (one restart mechanism, not two).
    reboot: struct { force: bool = false },
    shutdown: struct {},
};

pub const ApprovalAnswer = enum { granted, denied };

/// Daemon → client.
pub const DaemonMsg = union(enum) {
    hello_ok: struct {
        proto_version: u32,
        daemon_version: []const u8,
        /// The daemon's kernel shell sandbox passed its startup canary;
        /// sessions may enable prompt-free sandboxed shell execution.
        sandbox_available: bool = false,
        /// A DNS blocklist / explicit-deny network policy is loaded for
        /// Marlin-owned network tools and may be enabled per session.
        network_filtering: bool = false,
        /// A blocklist or explicit-deny policy was requested in configuration.
        /// False distinguishes opt-out from a configured policy that failed.
        network_configured: bool = false,
        network_feed_count: u64 = 0,
        network_rule_count: u64 = 0,
        /// Modification time (ms) of the daemon's own executable, captured at
        /// startup; 0 when unknown. Lets a client spot a stale daemon even in
        /// dev, where every build shares one version string.
        daemon_exe_mtime_ms: i64 = 0,
    },
    session_created: struct { sid: u64, request_id: u64 = 0 },
    session_list_result: struct { sessions: []const SessionInfo },
    input_history_result: struct { entries: []const InputHistoryEntry },
    search_result: struct { query: []const u8, sid: u64 = 0, hits: []const SearchHit },
    diagnostics_result: Diagnostics,
    otel_status_result: struct { enabled: bool, content: bool = false },
    /// Sent only to session watchers that explicitly opted in: older tagged
    /// union decoders reject message types they do not know.
    session_upsert: struct { session: SessionInfo },
    session_remove: struct { sid: u64 },
    blk: struct { sid: u64, b: block.Block },
    delta: struct { sid: u64, turn_id: u64, text: []const u8 },
    reasoning_delta: struct { sid: u64, turn_id: u64, text: []const u8 },
    /// Ephemeral stream telemetry while a turn is receiving from the
    /// provider: cumulative body bytes this round and ms since the last
    /// visible (text/reasoning) delta. Emitted at most ~1/s.
    stream_status: struct { sid: u64, bytes: u64, quiet_ms: u64 },
    replay_done: struct {
        sid: u64,
        oldest_seq: u64 = 0,
        newest_seq: u64 = 0,
        has_older: bool = false,
        has_newer: bool = false,
        forward: bool = false,
        /// Latest plan state, independent of the bounded transcript window.
        /// This message is already explicitly opted into by current clients;
        /// older decoders safely ignore the additive field.
        plan_items: []const block.PlanItem = &.{},
        /// False for completed plans, which render in transcript instead.
        /// Old daemons omit this and preserve the historical pinned behavior.
        plan_pinned: bool = true,
    },
    /// err_text carries the reason whenever state is .err — an error state
    /// must never reach a client without its explanation (older daemons omit
    /// it; older clients ignore it).
    status: struct {
        sid: u64,
        state: SessionState,
        err_text: ?[]const u8 = null,
        /// Ephemeral operational detail for running turns. Optional so old
        /// daemons decode as unknown phase and old clients ignore the field.
        phase: ?TurnPhase = null,
    },
    approval_request: struct {
        sid: u64,
        approval_id: []const u8,
        call_id: []const u8,
        tool: []const u8,
        /// Raw JSON args — clients render their own preview.
        args_json: []const u8,
    },
    session_meta: struct {
        sid: u64,
        tokens_in: u64,
        tokens_out: u64,
        /// Estimated tokens in the assembled context (0 = not yet measured)
        /// and the model's window, for the status bar's context gauge.
        context_used: u64 = 0,
        context_limit: u64 = 0,
    },
    /// Reply to model_list: full registry-form model ids
    /// ("openrouter/vendor/model"), sorted. Empty on fetch failure — the
    /// client falls back to its curated favorites. `pricing` is optional for
    /// compatibility with older daemons and clients.
    model_list_result: struct {
        models: []const []const u8,
        pricing: []const ModelPricing = &.{},
    },
    setup_status_result: SetupStatus,
    setup_result: struct { model: []const u8, session_updated: bool = false },
    mcp_list_result: struct { servers: []const McpServerInfo },
    /// Terminal reply after a UI preference is durable.
    ui_config_result: struct {
        tab_bar: bool,
        bell: bool = true,
        screensaver_after_ms: u64 = 0,
        screensaver_effect: []const u8 = "matrix",
    },
    /// Reply to blob_get. Bytes are JSON-escaped on the NDJSON wire and may
    /// contain arbitrary command output (including NULs).
    blob_result: struct { hash: []const u8, bytes: []const u8 },
    /// Terminal reply to cc_approval. `message` (additive; older bridges
    /// ignore it) becomes the deny text Claude Code shows its model, so a
    /// policy denial reads as policy, not as a human saying no.
    cc_approval_result: struct { sid: u64, decision: ApprovalAnswer, message: ?[]const u8 = null },
    /// Terminal reply to gc.
    gc_result: struct { bytes_reclaimed: u64, orphan_blobs: u64, expired_blobs: u64 },
    /// Reply to council_set/council_remove/council_list: the full current
    /// council roster set, so clients replace their cache in one message.
    council_list_result: struct { councils: []const CouncilInfo },
    /// Terminal reply to plan_clear. `cleared=false` means no unfinished plan
    /// existed; either result is successful and idempotent.
    plan_clear_result: struct { sid: u64, cleared: bool, request_id: u64 = 0 },
    interrupt_result: InterruptResult,
    /// `request_id` is non-zero only when replying to a correlated request
    /// (currently input). Defaults preserve compatibility in both directions.
    ok: struct { request_id: u64 = 0 },
    err: struct { code: []const u8, msg: []const u8, request_id: u64 = 0 },
};

pub const SessionInfo = struct {
    sid: u64,
    /// Null for roots. Defaults preserve compatibility with pre-M6 daemons.
    parent_sid: ?u64 = null,
    kind: SessionKind = .root,
    /// The parent's tool_call block that created this child.
    parent_block_id: ?u64 = null,
    /// Durable round budget for child sessions; 0 means the root default.
    max_rounds: u32 = 0,
    title: []const u8,
    /// Session root as recorded at creation time. Default keeps decoding
    /// compatible with daemons that predate this field.
    cwd: []const u8 = "",
    model: []const u8,
    effort: ReasoningEffort = .auto,
    status: []const u8,
    /// Typed live state. Defaults to idle when decoding pre-M4 daemons; the
    /// legacy status/running fields remain on the wire for compatibility.
    state: SessionState = .idle,
    created_at: i64,
    running: bool,
    /// Effective shell-sandbox state: the session's toggle AND a verified
    /// backend. Defaults false when decoding older daemons.
    sandboxed: bool = false,
    /// Approval mode is "auto" (/permissions full): nothing asks. Server
    /// truth so clients never mirror this per-App instead of per-session.
    full_access: bool = false,
    /// Whether Marlin-owned network tools enforce the loaded hostname policy
    /// for this session. Defaults false when decoding older daemons.
    network_filtering: bool = false,
    /// Persistent collaboration mode. Defaults false for older daemons.
    plan_mode: bool = false,
    /// Archived sessions appear only in explicitly inclusive list requests.
    archived: bool = false,
};

/// Encode one message as an NDJSON line (incl. trailing \n). Caller frees.
pub fn encode(gpa: std.mem.Allocator, msg: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, msg, .{});
    defer gpa.free(json);
    try ensureLineLength(json.len + 1, max_line_bytes);
    const line = try gpa.alloc(u8, json.len + 1);
    @memcpy(line[0..json.len], json);
    line[json.len] = '\n';
    return line;
}

pub fn ensureLineLength(line_len: usize, limit: usize) !void {
    if (line_len > limit) return error.ProtocolLineTooLong;
}

/// Read one NDJSON record into owned memory. Unlike takeDelimiterInclusive,
/// the Reader's scratch-buffer size is not the protocol limit. Oversized
/// records are drained through their newline so a peer can receive a visible
/// error and continue on the same connection.
pub fn readLineAlloc(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return readLineAllocLimit(gpa, reader, max_line_bytes);
}

pub fn readLineAllocLimit(
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    limit: usize,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    _ = reader.streamDelimiterLimit(&output.writer, '\n', .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => {
            _ = reader.discardDelimiterInclusive('\n') catch |discard_err| switch (discard_err) {
                error.EndOfStream => {},
                else => |e| return e,
            };
            return error.ProtocolLineTooLong;
        },
        // Allocating is the only writer and WriteFailed means its growth
        // failed; preserve the useful cause at this abstraction boundary.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    const delimiter = try reader.takeByte();
    if (delimiter != '\n') return error.InvalidProtocolDelimiter;
    return output.toOwnedSlice();
}

/// Decode one NDJSON line (with or without trailing newline) into T.
/// The result references `arena` allocations only.
pub fn decode(comptime T: type, arena: std.mem.Allocator, line: []const u8) !T {
    const trimmed = std.mem.trim(u8, line, " \r\n");
    return std.json.parseFromSliceLeaky(T, arena, trimmed, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// Resolve the daemon socket path. Precedence:
///   $MARLIN_SOCKET > $XDG_RUNTIME_DIR/marlin/daemon.sock
///                  > $HOME/.local/state/marlin/daemon.sock
/// Caller frees.
pub fn socketPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("MARLIN_SOCKET")) |p| {
        if (p.len > 0) return gpa.dupe(u8, p);
    }
    if (environ.get("XDG_RUNTIME_DIR")) |rt| {
        if (rt.len > 0) return std.fs.path.join(gpa, &.{ rt, "marlin", "daemon.sock" });
    }
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "marlin", "daemon.sock" });
}

// ---------------------------------------------------------------- tests --
