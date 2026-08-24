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

pub const proto_version: u32 = 1;

pub const SessionState = enum { idle, running, awaiting_approval, err, done };

/// Client → daemon.
pub const ClientMsg = union(enum) {
    hello: struct { proto_version: u32, client_kind: []const u8 = "generic" },
    session_create: struct {
        cwd: []const u8,
        model: []const u8,
        title: []const u8 = "",
        /// "default" = mutating tools ask; "auto" = everything auto-approved
        /// (headless one-shots and --yolo).
        approvals: []const u8 = "default",
    },
    session_list: struct {},
    session_kill: struct { sid: u64 },
    session_set_model: struct { sid: u64, model: []const u8 },
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
    hello_ok: struct { proto_version: u32, daemon_version: []const u8 },
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
    ok: struct {},
    err: struct { code: []const u8, msg: []const u8 },
};

pub const SessionInfo = struct {
    sid: u64,
    title: []const u8,
    model: []const u8,
    status: []const u8,
    created_at: i64,
    running: bool,
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

test "garbage line is an error, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.UnknownField,
        decode(ClientMsg, arena_state.allocator(), "{\"nope\":{}}"),
    );
}
