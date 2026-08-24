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
    session_list: struct {},
    /// Subscribe this client to refreshed session_list_result snapshots when
    /// any session enters an actionable state or its membership changes.
    /// The daemon replies with an immediate snapshot, then sends updates until
    /// the client disconnects. This is independent of per-session block subs.
    session_watch: struct {},
    session_kill: struct { sid: u64 },
    session_set_model: struct { sid: u64, model: []const u8 },
    session_set_effort: struct { sid: u64, effort: ReasoningEffort },
    /// Toggle the kernel shell sandbox (and its prompt-free shell execution)
    /// for one session. Enabling requires the daemon's verified backend
    /// (hello_ok.sandbox_available); the daemon rejects it otherwise.
    session_set_sandbox: struct { sid: u64, enabled: bool },
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
        /// Marlin-owned network tools.
        network_filtering: bool = false,
    },
    session_created: struct { sid: u64 },
    session_list_result: struct { sessions: []const SessionInfo },
    blk: struct { sid: u64, b: block.Block },
    delta: struct { sid: u64, turn_id: u64, text: []const u8 },
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
    /// client falls back to its curated favorites.
    model_list_result: struct { models: []const []const u8 },
    /// Reply to blob_get. Bytes are JSON-escaped on the NDJSON wire and may
    /// contain arbitrary command output (including NULs).
    blob_result: struct { hash: []const u8, bytes: []const u8 },
    ok: struct {},
    err: struct { code: []const u8, msg: []const u8 },
};

pub const SessionInfo = struct {
    sid: u64,
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
}

test "garbage line is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UnknownField,
        decode(ClientMsg, arena_state.allocator(), "{\"nope\":{}}"),
    );
}
