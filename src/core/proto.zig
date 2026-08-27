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

pub const proto_version: u32 = 3;
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

pub const DiagnosticRound = struct {
    round: u32,
    duration_ms: u64,
    ttft_ms: u64,
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
    /// MCP is daemon-owned. Listing and lifecycle actions therefore work from
    /// any thin client without assuming a shared process or filesystem.
    mcp_list: struct {},
    mcp_restart: struct { name: []const u8 },
    /// Persist a stdio server in config.toml, then rebuild the live registry.
    mcp_add: struct { name: []const u8, cmd: []const []const u8 },
    mcp_remove: struct { name: []const u8 },
    /// Persist one client UI preference through the daemon-owned config path.
    ui_set_tab_bar: struct { enabled: bool },
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
    otel_status_result: struct { enabled: bool },
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
    status: struct { sid: u64, state: SessionState, err_text: ?[]const u8 = null },
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
    mcp_list_result: struct { servers: []const McpServerInfo },
    /// Terminal reply to ui_set_tab_bar after config.toml is durable.
    ui_config_result: struct { tab_bar: bool },
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

fn ensureLineLength(line_len: usize, limit: usize) !void {
    if (line_len > limit) return error.ProtocolLineTooLong;
}

/// Read one NDJSON record into owned memory. Unlike takeDelimiterInclusive,
/// the Reader's scratch-buffer size is not the protocol limit. Oversized
/// records are drained through their newline so a peer can receive a visible
/// error and continue on the same connection.
pub fn readLineAlloc(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    return readLineAllocLimit(gpa, reader, max_line_bytes);
}

fn readLineAllocLimit(
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

test "round trip: client messages" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original: ClientMsg = .{ .input = .{
        .sid = 0xDEAD_BEEF_0000_1111,
        .text = "hi \"there\"\nline2",
        .request_id = 42,
    } };
    const line = try encode(gpa, original);
    defer gpa.free(line);
    try std.testing.expect(line[line.len - 1] == '\n');

    const back = try decode(ClientMsg, arena, line);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_0000_1111), back.input.sid);
    try std.testing.expectEqualStrings("hi \"there\"\nline2", back.input.text);
    try std.testing.expectEqual(@as(u64, 42), back.input.request_id);

    const effort_msg: ClientMsg = .{ .session_set_effort = .{ .sid = 9, .effort = .xhigh } };
    const effort_line = try encode(gpa, effort_msg);
    defer gpa.free(effort_line);
    const effort_back = try decode(ClientMsg, arena, effort_line);
    try std.testing.expectEqual(ReasoningEffort.xhigh, effort_back.session_set_effort.effort);

    const plan_mode_msg: ClientMsg = .{ .session_set_plan_mode = .{ .sid = 9, .enabled = true } };
    const plan_mode_line = try encode(gpa, plan_mode_msg);
    defer gpa.free(plan_mode_line);
    const plan_mode_back = try decode(ClientMsg, arena, plan_mode_line);
    try std.testing.expect(plan_mode_back.session_set_plan_mode.enabled);

    const plan_clear_line = try encode(gpa, ClientMsg{ .plan_clear = .{ .sid = 9, .request_id = 17 } });
    defer gpa.free(plan_clear_line);
    const plan_clear_back = try decode(ClientMsg, arena, plan_clear_line);
    try std.testing.expectEqual(@as(u64, 17), plan_clear_back.plan_clear.request_id);

    const plan_accept_line = try encode(gpa, ClientMsg{ .plan_accept = .{ .sid = 9, .request_id = 18 } });
    defer gpa.free(plan_accept_line);
    const plan_accept_back = try decode(ClientMsg, arena, plan_accept_line);
    try std.testing.expectEqual(@as(u64, 18), plan_accept_back.plan_accept.request_id);

    const sandbox_msg: ClientMsg = .{ .session_set_sandbox = .{ .sid = 9, .enabled = false } };
    const sandbox_line = try encode(gpa, sandbox_msg);
    defer gpa.free(sandbox_line);
    const sandbox_back = try decode(ClientMsg, arena, sandbox_line);
    try std.testing.expect(!sandbox_back.session_set_sandbox.enabled);

    const network_msg: ClientMsg = .{ .session_set_network_filtering = .{ .sid = 9, .enabled = true } };
    const network_line = try encode(gpa, network_msg);
    defer gpa.free(network_line);
    const network_back = try decode(ClientMsg, arena, network_line);
    try std.testing.expect(network_back.session_set_network_filtering.enabled);

    const otel_line = try encode(gpa, ClientMsg{ .otel_configure = .{
        .endpoint = "https://otel.example",
        .headers = "Authorization=Bearer%20secret",
    } });
    defer gpa.free(otel_line);
    const otel_back = try decode(ClientMsg, arena, otel_line);
    try std.testing.expectEqualStrings("https://otel.example", otel_back.otel_configure.endpoint);
    try std.testing.expectEqualStrings("Authorization=Bearer%20secret", otel_back.otel_configure.headers);

    const watch_line = try encode(gpa, ClientMsg{ .session_watch = .{ .incremental = true } });
    defer gpa.free(watch_line);
    const watch_back = try decode(ClientMsg, arena, watch_line);
    try std.testing.expectEqual(
        std.meta.activeTag(ClientMsg{ .session_watch = .{} }),
        std.meta.activeTag(watch_back),
    );
    try std.testing.expect(watch_back.session_watch.incremental);

    const ui_line = try encode(gpa, ClientMsg{ .ui_set_tab_bar = .{ .enabled = false } });
    defer gpa.free(ui_line);
    const ui_back = try decode(ClientMsg, arena, ui_line);
    try std.testing.expect(!ui_back.ui_set_tab_bar.enabled);

    const blob_line = try encode(gpa, ClientMsg{ .blob_get = .{ .hash = "abc123" } });
    defer gpa.free(blob_line);
    const blob_back = try decode(ClientMsg, arena, blob_line);
    try std.testing.expectEqualStrings("abc123", blob_back.blob_get.hash);

    const tail_line = try encode(gpa, ClientMsg{ .sub = .{
        .sid = 7,
        .from_seq = 1,
        .tail_limit = 256,
        .before_seq = 1024,
        .replay_limit = 128,
        .replay_done = true,
    } });
    defer gpa.free(tail_line);
    const tail_back = try decode(ClientMsg, arena, tail_line);
    try std.testing.expectEqual(@as(u32, 256), tail_back.sub.tail_limit);
    try std.testing.expectEqual(@as(u64, 1024), tail_back.sub.before_seq);
    try std.testing.expectEqual(@as(u32, 128), tail_back.sub.replay_limit);
    try std.testing.expect(tail_back.sub.replay_done);

    const centered_line = try encode(gpa, ClientMsg{ .sub = .{
        .sid = 7,
        .tail_limit = 256,
        .around_seq = 42,
    } });
    defer gpa.free(centered_line);
    const centered_back = try decode(ClientMsg, arena, centered_line);
    try std.testing.expectEqual(@as(u64, 42), centered_back.sub.around_seq);

    const search_line = try encode(gpa, ClientMsg{ .search = .{
        .query = "banana launcher",
        .sid = 7,
        .limit = 20,
    } });
    defer gpa.free(search_line);
    const search_back = try decode(ClientMsg, arena, search_line);
    try std.testing.expectEqualStrings("banana launcher", search_back.search.query);
    try std.testing.expectEqual(@as(u64, 7), search_back.search.sid);

    const history_line = try encode(gpa, ClientMsg{ .input_history = .{ .sid = 7, .limit = 99 } });
    defer gpa.free(history_line);
    const history_back = try decode(ClientMsg, arena, history_line);
    try std.testing.expectEqual(@as(u64, 7), history_back.input_history.sid);
    try std.testing.expectEqual(@as(u32, 99), history_back.input_history.limit);

    const interrupt_line = try encode(gpa, ClientMsg{ .interrupt = .{ .sid = 9, .report = true } });
    defer gpa.free(interrupt_line);
    const interrupt_back = try decode(ClientMsg, arena, interrupt_line);
    try std.testing.expect(interrupt_back.interrupt.report);

    const rename_line = try encode(gpa, ClientMsg{ .session_rename = .{ .sid = 9, .title = "review web ui" } });
    defer gpa.free(rename_line);
    const rename_back = try decode(ClientMsg, arena, rename_line);
    try std.testing.expectEqual(@as(u64, 9), rename_back.session_rename.sid);
    try std.testing.expectEqualStrings("review web ui", rename_back.session_rename.title);

    const cc_line = try encode(gpa, ClientMsg{ .cc_approval = .{
        .sid = 4,
        .tool = "Bash",
        .args_json = "{\"command\":\"zig build test\"}",
    } });
    defer gpa.free(cc_line);
    const cc_back = try decode(ClientMsg, arena, cc_line);
    try std.testing.expectEqual(@as(u64, 4), cc_back.cc_approval.sid);
    try std.testing.expectEqualStrings("Bash", cc_back.cc_approval.tool);

    const cc_reply = try encode(gpa, DaemonMsg{ .cc_approval_result = .{ .sid = 4, .decision = .granted } });
    defer gpa.free(cc_reply);
    const cc_reply_back = try decode(DaemonMsg, arena, cc_reply);
    try std.testing.expectEqual(ApprovalAnswer.granted, cc_reply_back.cc_approval_result.decision);

    const gc_line = try encode(gpa, ClientMsg{ .gc = .{ .expire_before_ms = 123 } });
    defer gpa.free(gc_line);
    const gc_back = try decode(ClientMsg, arena, gc_line);
    try std.testing.expectEqual(@as(i64, 123), gc_back.gc.expire_before_ms);

    const gc_reply = try encode(gpa, DaemonMsg{ .gc_result = .{ .bytes_reclaimed = 9, .orphan_blobs = 1, .expired_blobs = 0 } });
    defer gpa.free(gc_reply);
    const gc_reply_back = try decode(DaemonMsg, arena, gc_reply);
    try std.testing.expectEqual(@as(u64, 9), gc_reply_back.gc_result.bytes_reclaimed);

    const council_line = try encode(gpa, ClientMsg{ .council_set = .{
        .name = "core",
        .models = &.{ "openrouter/x-ai/grok-4.6", "openrouter/z-ai/glm-5.3" },
    } });
    defer gpa.free(council_line);
    const council_back = try decode(ClientMsg, arena, council_line);
    try std.testing.expectEqualStrings("core", council_back.council_set.name);
    try std.testing.expectEqual(@as(usize, 2), council_back.council_set.models.len);

    const council_reply = try encode(gpa, DaemonMsg{ .council_list_result = .{
        .councils = &.{.{ .name = "core", .models = &.{"openrouter/x-ai/grok-4.6"} }},
    } });
    defer gpa.free(council_reply);
    const council_reply_back = try decode(DaemonMsg, arena, council_reply);
    try std.testing.expectEqualStrings("core", council_reply_back.council_list_result.councils[0].name);

    const plan_clear_reply = try encode(gpa, DaemonMsg{ .plan_clear_result = .{
        .sid = 9,
        .cleared = true,
        .request_id = 17,
    } });
    defer gpa.free(plan_clear_reply);
    const plan_clear_reply_back = try decode(DaemonMsg, arena, plan_clear_reply);
    try std.testing.expect(plan_clear_reply_back.plan_clear_result.cleared);
    try std.testing.expectEqual(@as(u64, 17), plan_clear_reply_back.plan_clear_result.request_id);
}

test "latest plan survives the replay marker wire" {
    const gpa = std.testing.allocator;
    const line = try encode(gpa, DaemonMsg{ .replay_done = .{
        .sid = 7,
        .plan_pinned = false,
        .plan_items = &.{
            .{ .step = "Inspect", .status = .completed, .duration_ms = 18_400 },
            .{ .step = "Implement", .status = .in_progress, .started_at_ms = 20_000 },
        },
    } });
    defer gpa.free(line);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const decoded = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expectEqual(@as(u64, 7), decoded.replay_done.sid);
    try std.testing.expectEqual(@as(usize, 2), decoded.replay_done.plan_items.len);
    try std.testing.expectEqual(@as(u64, 18_400), decoded.replay_done.plan_items[0].duration_ms);
    try std.testing.expectEqual(block.PlanStatus.in_progress, decoded.replay_done.plan_items[1].status);
    try std.testing.expectEqual(@as(i64, 20_000), decoded.replay_done.plan_items[1].started_at_ms);
    try std.testing.expect(!decoded.replay_done.plan_pinned);
}

test "input attachments survive the remote-client wire" {
    const gpa = std.testing.allocator;
    const line = try encode(gpa, ClientMsg{ .input = .{
        .sid = 7,
        .text = "look",
        .request_id = 9,
        .attachments = &.{.{
            .name = "shot.png",
            .mime = "image/png",
            .data_base64 = "iVBORw0KGgo=",
        }},
    } });
    defer gpa.free(line);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const decoded = try decode(ClientMsg, arena_state.allocator(), line);
    try std.testing.expectEqual(@as(usize, 1), decoded.input.attachments.len);
    try std.testing.expectEqualStrings("shot.png", decoded.input.attachments[0].name);
    try std.testing.expectEqualStrings("iVBORw0KGgo=", decoded.input.attachments[0].data_base64);
}

test "round trip: daemon block message with tool_result body" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msg: DaemonMsg = .{ .blk = .{ .sid = 7, .b = .{
        .id = 1,
        .session_id = 7,
        .turn_id = 2,
        .seq = 3,
        .ts = 1700000000000,
        .body = .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "out", .full_body_ref = null } },
    } } };
    const line = try encode(gpa, msg);
    defer gpa.free(line);

    const back = try decode(DaemonMsg, arena, line);
    try std.testing.expectEqual(@as(u64, 3), back.blk.b.seq);
    try std.testing.expectEqualStrings("out", back.blk.b.body.tool_result.inline_body);
}

test "round trip: interrupt diagnostics" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const line = try encode(gpa, DaemonMsg{ .interrupt_result = .{
        .sid = 7,
        .active = true,
        .already_requested = true,
        .request_count = 2,
        .pending_ms = 1500,
        .phase_ms = 4200,
        .phase = .provider,
    } });
    defer gpa.free(line);
    const back = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expect(back.interrupt_result.already_requested);
    try std.testing.expectEqual(TurnPhase.provider, back.interrupt_result.phase);
    try std.testing.expectEqual(@as(u64, 4200), back.interrupt_result.phase_ms);
}

test "decode ignores unknown fields; defaults apply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(ClientMsg, arena_state.allocator(),
        \\{"sub":{"sid":5,"future_field":true}}
    );
    try std.testing.expectEqual(@as(u64, 0), m.sub.from_seq);
    try std.testing.expectEqual(@as(u32, 0), m.sub.tail_limit);
    try std.testing.expectEqual(@as(u64, 0), m.sub.before_seq);
    try std.testing.expectEqual(@as(u32, 0), m.sub.replay_limit);
    try std.testing.expect(!m.sub.replay_done);
    try std.testing.expectEqual(@as(u64, 5), m.sub.sid);
}

test "correlation ids are additive and legacy messages default to zero" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const legacy_input = try decode(ClientMsg, arena,
        \\{"input":{"sid":5,"text":"hello"}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_input.input.request_id);

    const legacy_create = try decode(ClientMsg, arena,
        \\{"session_create":{"cwd":"/tmp","model":"test/model"}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_create.session_create.request_id);

    const legacy_created = try decode(DaemonMsg, arena,
        \\{"session_created":{"sid":7}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_created.session_created.request_id);

    const legacy_err = try decode(DaemonMsg, arena,
        \\{"err":{"code":"busy","msg":"no"}}
    );
    try std.testing.expectEqual(@as(u64, 0), legacy_err.err.request_id);

    const correlated_ok = try decode(DaemonMsg, arena,
        \\{"ok":{"request_id":91}}
    );
    try std.testing.expectEqual(@as(u64, 91), correlated_ok.ok.request_id);
}

test "bounded line reader supports records larger than legacy buffers" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 300 * 1024 + 1);
    defer gpa.free(input);
    @memset(input[0 .. input.len - 1], 'x');
    input[input.len - 1] = '\n';
    var reader = std.Io.Reader.fixed(input);
    const line = try readLineAllocLimit(gpa, &reader, 512 * 1024);
    defer gpa.free(line);
    try std.testing.expectEqual(@as(usize, 300 * 1024), line.len);
    try std.testing.expect(line[0] == 'x' and line[line.len - 1] == 'x');
}

test "oversized line is rejected, drained, and followed by a valid record" {
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("123456789\n{}\n");
    try std.testing.expectError(
        error.ProtocolLineTooLong,
        readLineAllocLimit(gpa, &reader, 8),
    );
    const next = try readLineAllocLimit(gpa, &reader, 8);
    defer gpa.free(next);
    try std.testing.expectEqualStrings("{}", next);
}

test "encoded line length includes its newline" {
    try ensureLineLength(16, 16);
    try std.testing.expectError(error.ProtocolLineTooLong, ensureLineLength(17, 16));
}

test "older hello defaults network configuration state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(DaemonMsg, arena_state.allocator(),
        \\{"hello_ok":{"proto_version":1,"daemon_version":"old"}}
    );
    try std.testing.expect(!m.hello_ok.network_configured);
    try std.testing.expect(!m.hello_ok.network_filtering);
    try std.testing.expectEqual(@as(i64, 0), m.hello_ok.daemon_exe_mtime_ms);
}

test "status err_text is additive: absent from old daemons, carried when set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const old = try decode(DaemonMsg, arena,
        \\{"status":{"sid":7,"state":"err"}}
    );
    try std.testing.expect(old.status.err_text == null);

    const line = try encode(std.testing.allocator, DaemonMsg{ .status = .{
        .sid = 7,
        .state = .err,
        .err_text = "claude code error: Not logged in",
    } });
    defer std.testing.allocator.free(line);
    const carried = try decode(DaemonMsg, arena, line);
    try std.testing.expectEqualStrings("claude code error: Not logged in", carried.status.err_text.?);
}

test "model catalog pricing round trips and remains optional" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const original: DaemonMsg = .{ .model_list_result = .{
        .models = &.{"openrouter/example/model"},
        .pricing = &.{.{
            .model = "openrouter/example/model",
            .input_per_million = 3,
            .output_per_million = 15,
            .tiered = true,
        }},
    } };
    const line = try encode(gpa, original);
    defer gpa.free(line);
    const back = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expectEqualStrings("openrouter/example/model", back.model_list_result.models[0]);
    try std.testing.expectEqual(@as(?f64, 3), back.model_list_result.pricing[0].input_per_million);
    try std.testing.expectEqual(@as(?f64, 15), back.model_list_result.pricing[0].output_per_million);
    try std.testing.expect(back.model_list_result.pricing[0].tiered);

    const legacy = try decode(DaemonMsg, arena_state.allocator(),
        \\{"model_list_result":{"models":["openrouter/legacy/model"]}}
    );
    try std.testing.expectEqual(@as(usize, 0), legacy.model_list_result.pricing.len);
}

test "round trip: blob result preserves arbitrary bytes" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const original = DaemonMsg{ .blob_result = .{
        .hash = "abc123",
        .bytes = "line one\nline two\x00tail",
    } };
    const line = try encode(gpa, original);
    defer gpa.free(line);
    const back = try decode(DaemonMsg, arena_state.allocator(), line);
    try std.testing.expectEqualStrings("abc123", back.blob_result.hash);
    try std.testing.expectEqualStrings("line one\nline two\x00tail", back.blob_result.bytes);
}

test "older session-list entries default cwd" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(DaemonMsg, arena_state.allocator(),
        \\{"session_list_result":{"sessions":[{"sid":5,"title":"old","model":"m","status":"idle","created_at":1,"running":false}]}}
    );
    try std.testing.expectEqualStrings("", m.session_list_result.sessions[0].cwd);
    try std.testing.expectEqual(SessionState.idle, m.session_list_result.sessions[0].state);
    try std.testing.expectEqual(SessionKind.root, m.session_list_result.sessions[0].kind);
    try std.testing.expectEqual(@as(?u64, null), m.session_list_result.sessions[0].parent_sid);
    try std.testing.expect(!m.session_list_result.sessions[0].archived);
}

test "older session-list requests exclude archived sessions by default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(ClientMsg, arena_state.allocator(),
        \\{"session_list":{}}
    );
    try std.testing.expect(!m.session_list.include_archived);
}

test "guest model prefixes identify their delegated backend" {
    try std.testing.expect(isGuestModel("claudecode/fable"));
    try std.testing.expect(isGuestModel("claudecode/default"));
    try std.testing.expect(isGuestModel("codex/default"));
    try std.testing.expectEqual(GuestBackend.codex, guestBackend("codex/default").?);
    try std.testing.expectEqualStrings("default", guestModelName("codex/default").?);
    try std.testing.expect(!isGuestModel("openrouter/anthropic/claude-sonnet-4.5"));
    try std.testing.expect(!isGuestModel("anthropic/claude-sonnet-4-5"));
    try std.testing.expect(!isGuestModel("claudecode"));
}

test "garbage line is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UnknownField,
        decode(ClientMsg, arena_state.allocator(), "{\"nope\":{}}"),
    );
}
