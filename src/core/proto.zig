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
//!     with seq >= N, then goes live. Reconnect is therefore trivial.
//!   - Unknown fields are ignored on read; unknown message types are an err.

const std = @import("std");
const block = @import("block.zig");
pub const ReasoningEffort = @import("effort.zig").Effort;

pub const proto_version: u32 = 1;

pub const SessionState = enum { idle, running, awaiting_approval, err, done };

/// Durable role in the session hierarchy. M6 initially permits one level of
/// task children; review_child is reserved for the council layer that reuses
/// the same storage/protocol shape.
pub const SessionKind = enum { root, task_child, review_child };

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

/// Client → daemon.
pub const ClientMsg = union(enum) {
    hello: struct { proto_version: u32, client_kind: []const u8 = "generic" },
    session_create: struct {
        cwd: []const u8,
        model: []const u8,
        effort: ReasoningEffort = .auto,
        title: []const u8 = "",
        /// "default" = mutating tools ask; "auto" = everything auto-approved
        /// (headless one-shots and --yolo).
        approvals: []const u8 = "default",
    },
    session_list: struct { include_archived: bool = false },
    /// Subscribe this client to refreshed session_list_result snapshots when
    /// any session enters an actionable state or its membership changes.
    /// The daemon replies with an immediate snapshot, then sends updates until
    /// the client disconnects. This is independent of per-session block subs.
    session_watch: struct {},
    session_kill: struct { sid: u64 },
    /// Hide/restore a durable session hierarchy without deleting its log.
    session_archive: struct { sid: u64, archived: bool = true },
    session_set_model: struct { sid: u64, model: []const u8 },
    session_set_effort: struct { sid: u64, effort: ReasoningEffort },
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
    sub: struct { sid: u64, from_seq: u64 = 0 },
    unsub: struct { sid: u64 },
    input: struct { sid: u64, text: []const u8 },
    approve: struct { sid: u64, approval_id: []const u8, decision: ApprovalAnswer },
    /// Manual L2 compaction (/compact). Rejected while a turn is running.
    session_compact: struct { sid: u64 },
    /// Full model catalog for the /model picker: daemon fetches the
    /// provider's model list (cached ~1h) and replies model_list_result.
    model_list: struct {},
    interrupt: struct { sid: u64 },
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
    },
    session_created: struct { sid: u64 },
    session_list_result: struct { sessions: []const SessionInfo },
    blk: struct { sid: u64, b: block.Block },
    delta: struct { sid: u64, turn_id: u64, text: []const u8 },
    reasoning_delta: struct { sid: u64, turn_id: u64, text: []const u8 },
    /// Ephemeral stream telemetry while a turn is receiving from the
    /// provider: cumulative body bytes this round and ms since the last
    /// visible (text/reasoning) delta. Emitted at most ~1/s.
    stream_status: struct { sid: u64, bytes: u64, quiet_ms: u64 },
    status: struct { sid: u64, state: SessionState },
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
    /// Reply to blob_get. Bytes are JSON-escaped on the NDJSON wire and may
    /// contain arbitrary command output (including NULs).
    blob_result: struct { hash: []const u8, bytes: []const u8 },
    ok: struct {},
    err: struct { code: []const u8, msg: []const u8 },
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
    /// Whether Marlin-owned network tools enforce the loaded hostname policy
    /// for this session. Defaults false when decoding older daemons.
    network_filtering: bool = false,
    /// Archived sessions appear only in explicitly inclusive list requests.
    archived: bool = false,
};

/// Encode one message as an NDJSON line (incl. trailing \n). Caller frees.
pub fn encode(gpa: std.mem.Allocator, msg: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(gpa, msg, .{});
    defer gpa.free(json);
    const line = try gpa.alloc(u8, json.len + 1);
    @memcpy(line[0..json.len], json);
    line[json.len] = '\n';
    return line;
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

    const original: ClientMsg = .{ .input = .{ .sid = 0xDEAD_BEEF_0000_1111, .text = "hi \"there\"\nline2" } };
    const line = try encode(gpa, original);
    defer gpa.free(line);
    try std.testing.expect(line[line.len - 1] == '\n');

    const back = try decode(ClientMsg, arena, line);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF_0000_1111), back.input.sid);
    try std.testing.expectEqualStrings("hi \"there\"\nline2", back.input.text);

    const effort_msg: ClientMsg = .{ .session_set_effort = .{ .sid = 9, .effort = .xhigh } };
    const effort_line = try encode(gpa, effort_msg);
    defer gpa.free(effort_line);
    const effort_back = try decode(ClientMsg, arena, effort_line);
    try std.testing.expectEqual(ReasoningEffort.xhigh, effort_back.session_set_effort.effort);

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

    const watch_line = try encode(gpa, ClientMsg{ .session_watch = .{} });
    defer gpa.free(watch_line);
    const watch_back = try decode(ClientMsg, arena, watch_line);
    try std.testing.expectEqual(
        std.meta.activeTag(ClientMsg{ .session_watch = .{} }),
        std.meta.activeTag(watch_back),
    );

    const blob_line = try encode(gpa, ClientMsg{ .blob_get = .{ .hash = "abc123" } });
    defer gpa.free(blob_line);
    const blob_back = try decode(ClientMsg, arena, blob_line);
    try std.testing.expectEqualStrings("abc123", blob_back.blob_get.hash);
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

test "decode ignores unknown fields; defaults apply" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(ClientMsg, arena_state.allocator(),
        \\{"sub":{"sid":5,"future_field":true}}
    );
    try std.testing.expectEqual(@as(u64, 0), m.sub.from_seq);
    try std.testing.expectEqual(@as(u64, 5), m.sub.sid);
}

test "older hello defaults network configuration state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const m = try decode(DaemonMsg, arena_state.allocator(),
        \\{"hello_ok":{"proto_version":1,"daemon_version":"old"}}
    );
    try std.testing.expect(!m.hello_ok.network_configured);
    try std.testing.expect(!m.hello_ok.network_filtering);
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

test "garbage line is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UnknownField,
        decode(ClientMsg, arena_state.allocator(), "{\"nope\":{}}"),
    );
}
