//! Headless protocol clients: `marlin run`, `marlin ls`, `marlin archive`,
//! `marlin unarchive`, `marlin kill`, and `marlin shutdown`. All drive the
//! daemon over the socket — the in-process M0 path is gone; the daemon
//! autostarts on demand (attach.connect).
//!
//! run flags:
//!   --continue        reuse the most recent session
//!   --model <m>       override the model (registry string)
//!   --quiet           suppress streaming; print only the final text
//!   --ask             create the session in default approval mode (mutating
//!                     tools ask; headless then auto-grants — e2e test seam
//!                     for the park/approve/resume path)

const std = @import("std");
const Io = std.Io;

const proto = @import("../core/proto.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const media = @import("media.zig");
const self_build = @import("self_build.zig");

const ResolvedSession = struct {
    sid: u64,
    handle: session_handle.Full,
    handle_len: usize,

    fn text(self: *const ResolvedSession) []const u8 {
        return self.handle[0..self.handle_len];
    }
};

/// `marlin search <query>` — durable cross-session transcript search.
pub fn search(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    if (args.len == 0) {
        try eprint(io, "usage: marlin search <query>\n", .{});
        return 2;
    }
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(gpa);
    for (args, 0..) |arg, i| {
        if (i > 0) try query.append(gpa, ' ');
        try query.appendSlice(gpa, arg);
    }

    const conn = attach.connect(gpa, io, environ, self_exe) catch |err| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{err});
        return 1;
    };
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try conn.send(.{ .session_list = .{ .include_archived = true } });
    const list = try conn.recvUntil(arena, .session_list_result);
    const ids = try sessionIds(arena, list.sessions);
    try conn.send(.{ .search = .{ .query = query.items, .limit = 100 } });
    const result = try conn.recvUntil(arena, .search_result);
    for (result.hits) |hit| {
        var handle_buf: session_handle.Full = undefined;
        const handle = session_handle.display(&handle_buf, hit.sid, ids);
        const location = if (hit.title.len > 0) hit.title else hit.cwd;
        const snippet = try arena.dupe(u8, hit.snippet);
        for (snippet) |*byte| if (byte.* == '\n' or byte.* == '\r' or byte.* == '\t') {
            byte.* = ' ';
        };
        try print(io, "{s}:{d}\t{s}\t{s}\t{s}\n", .{
            handle, hit.seq, @tagName(hit.kind), location, snippet,
        });
    }
    return 0;
}

/// `marlin diagnostics [handle] [--json]` — durable local timing evidence.
/// Without a handle, inspect the newest non-archived session.
pub fn diagnostics(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    var json = false;
    var handle: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else if (handle == null) {
            handle = arg;
        } else {
            try eprint(io, "usage: marlin diagnostics [session-handle] [--json]\n", .{});
            return 2;
        }
    }

    const conn = attach.connect(gpa, io, environ, self_exe) catch |err| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{err});
        return 1;
    };
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sid: u64 = 0;
    if (handle) |query| {
        sid = ((try resolveSessionArg(io, conn, arena, query)) orelse return 2).sid;
    } else {
        try conn.send(.{ .session_list = .{ .include_archived = false } });
        const list = try conn.recvUntil(arena, .session_list_result);
        if (list.sessions.len == 0) {
            try eprint(io, "marlin diagnostics: no sessions\n", .{});
            return 1;
        }
        sid = list.sessions[0].sid;
    }

    try conn.send(.{ .diagnostics = .{ .sid = sid } });
    const report = conn.recvUntil(arena, .diagnostics_result) catch {
        try eprint(io, "marlin diagnostics: daemon could not produce a report\n", .{});
        return 1;
    };
    if (json) {
        const encoded = try std.json.Stringify.valueAlloc(arena, report, .{});
        try print(io, "{s}\n", .{encoded});
        return 0;
    }

    try print(io, "session {x}\n", .{report.sid});
    try print(io, "sample  {d} turns · {d} ok · {d} failed · {d} interrupted · {d} abandoned · {d} checkpoints\n", .{
        report.sample_turns,
        report.successful_turns,
        report.failed_turns,
        report.interrupted_turns,
        report.abandoned_turns,
        report.checkpoint_turns,
    });
    try print(io, "provider  {d} requests · p50 {d:.2}s · p95 {d:.2}s · TTFT p50 {d:.2}s · p95 {d:.2}s\n", .{
        report.provider_requests,
        seconds(report.provider_p50_ms),
        seconds(report.provider_p95_ms),
        seconds(report.ttft_p50_ms),
        seconds(report.ttft_p95_ms),
    });
    try print(io, "tools  {d} calls\n", .{report.tool_calls});
    if (report.last_turn_id != 0) {
        try print(io, "last  {s} · {d:.2}s · trace {s}\n", .{
            report.last_outcome,
            seconds(report.last_duration_ms),
            report.last_trace_id,
        });
        if (report.last_error.len > 0) try print(io, "error  {s}\n", .{report.last_error});
        for (report.last_rounds) |round| {
            try print(io, "  provider #{d}  {s} · {d:.2}s · TTFT {d:.2}s · {d} bytes · {d} in/{d} out", .{
                round.round + 1,
                round.status,
                seconds(round.duration_ms),
                seconds(round.ttft_ms),
                round.bytes,
                round.tokens_in,
                round.tokens_out,
            });
            if (round.provider.len > 0) try print(io, " · {s}", .{round.provider});
            if (round.generation_id.len > 0) try print(io, " · {s}", .{round.generation_id});
            try print(io, "\n", .{});
        }
        for (report.last_tools) |tool| try print(io, "  tool {s}  {s} · {d:.2}s\n", .{
            tool.name,
            tool.status,
            seconds(tool.duration_ms),
        });
    } else {
        try print(io, "last  no telemetry yet (run a new turn after this build)\n", .{});
    }
    try print(io, "OTLP  {s}", .{if (report.otlp_enabled) "enabled" else "disabled"});
    if (report.otlp_enabled) try print(io, " · {d} pending", .{report.otlp_pending});
    if (report.otlp_last_error.len > 0) try print(io, " · last error: {s}", .{report.otlp_last_error});
    try print(io, "\n", .{});
    return 0;
}

fn seconds(ms: u64) f64 {
    return @as(f64, @floatFromInt(ms)) / 1000.0;
}

pub fn mcp(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    const conn = attach.connect(gpa, io, environ, self_exe) catch |err| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{err});
        return 1;
    };
    defer conn.deinit();
    var command_args: ?[][]const u8 = null;
    defer if (command_args) |owned| gpa.free(owned);
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "list"))) {
        try conn.send(.{ .mcp_list = .{} });
    } else if (args.len == 2 and std.mem.eql(u8, args[0], "restart")) {
        try conn.send(.{ .mcp_restart = .{ .name = args[1] } });
    } else if (args.len >= 4 and std.mem.eql(u8, args[0], "add") and std.mem.eql(u8, args[2], "--")) {
        const owned = try gpa.alloc([]const u8, args.len - 3);
        command_args = owned;
        for (args[3..], owned) |arg, *dest| dest.* = arg;
        try conn.send(.{ .mcp_add = .{ .name = args[1], .cmd = owned } });
    } else if (args.len == 2 and std.mem.eql(u8, args[0], "remove")) {
        try conn.send(.{ .mcp_remove = .{ .name = args[1] } });
    } else if (args.len == 1 and std.mem.eql(u8, args[0], "reload")) {
        try conn.send(.{ .mcp_reload = .{} });
    } else {
        try eprint(io, "usage: marlin mcp [list|add <name> -- <command> [args...]|remove <name>|restart <name>|reload]\n", .{});
        return 2;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const result = conn.recvUntil(arena_state.allocator(), .mcp_list_result) catch return 1;
    if (result.servers.len == 0) {
        try print(io, "no MCP servers configured\n", .{});
        return 0;
    }
    var healthy = true;
    for (result.servers) |server| {
        if (server.ready) {
            try print(io, "{s}\tready\t{d} tools\n", .{ server.name, server.tool_count });
        } else {
            healthy = false;
            try print(io, "{s}\tunavailable\t{s}\n", .{ server.name, server.error_message orelse "unknown error" });
        }
    }
    return if (healthy) 0 else 1;
}

fn sessionIds(arena: std.mem.Allocator, sessions: []const proto.SessionInfo) ![]u64 {
    const ids = try arena.alloc(u64, sessions.len);
    for (sessions, 0..) |session, i| ids[i] = session.sid;
    return ids;
}

fn resolvedSession(sid: u64, known: []const u64) ResolvedSession {
    var handle_buf: session_handle.Full = undefined;
    const handle = session_handle.display(&handle_buf, sid, known);
    return .{ .sid = sid, .handle = handle_buf, .handle_len = handle.len };
}

/// Resolve every command-line session reference against the complete durable
/// catalog, including archived sessions. Null means a diagnostic was printed.
fn resolveSessionArg(
    io: Io,
    conn: *attach.Conn,
    arena: std.mem.Allocator,
    query: []const u8,
) !?ResolvedSession {
    try conn.send(.{ .session_list = .{ .include_archived = true } });
    const list = try conn.recvUntil(arena, .session_list_result);
    const ids = try sessionIds(arena, list.sessions);
    const sid = session_handle.resolve(query, ids) catch |err| {
        switch (err) {
            error.PrefixTooShort => try eprint(io, "marlin: session handle '{s}' is too short (use at least {d} characters)\n", .{ query, session_handle.min_prefix_len }),
            error.InvalidHandle => try eprint(io, "marlin: invalid session handle '{s}'\n", .{query}),
            error.NotFound => try eprint(io, "marlin: no session matches '{s}'\n", .{query}),
            error.Ambiguous => {
                try eprint(io, "marlin: session handle '{s}' is ambiguous; use more characters:\n", .{query});
                for (list.sessions) |session| {
                    if (!session_handle.matchesPrefix(query, session.sid)) continue;
                    var handle_buf: session_handle.Full = undefined;
                    const handle = session_handle.display(&handle_buf, session.sid, ids);
                    const title = if (session.title.len > 0) session.title else "(untitled)";
                    try eprint(io, "  {s}  {s}  {s}\n", .{ handle, title, session.cwd });
                }
            },
        }
        return null;
    };
    return resolvedSession(sid, ids);
}

pub const Flags = struct {
    continue_last: bool = false,
    model: ?[]const u8 = null,
    quiet: bool = false,
    ask: bool = false,
    image: ?[]const u8 = null,
    task: ?[]const u8 = null,
};

pub fn parseFlags(args: []const [:0]const u8) !Flags {
    var f = Flags{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--continue")) {
            f.continue_last = true;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            f.quiet = true;
        } else if (std.mem.eql(u8, a, "--ask")) {
            f.ask = true;
        } else if (std.mem.eql(u8, a, "--model")) {
            i += 1;
            if (i >= args.len) return error.MissingModelArg;
            f.model = args[i];
        } else if (std.mem.eql(u8, a, "--image")) {
            i += 1;
            if (i >= args.len) return error.MissingImageArg;
            f.image = args[i];
        } else if (f.task == null) {
            f.task = a;
        } else {
            return error.UnexpectedArg;
        }
    }
    return f;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    const flags = parseFlags(args) catch {
        try eprint(io, "usage: marlin run [--continue] [--model <m>] [--image <path>] [--quiet] \"task\"\n", .{});
        return 2;
    };
    const task = flags.task orelse {
        try eprint(io, "marlin run: missing task text\n", .{});
        return 2;
    };

    var pending_image: ?media.Pending = null;
    defer if (pending_image) |*image| image.deinit(gpa);
    if (flags.image) |path| {
        var local_cwd_buf: [4096]u8 = undefined;
        const local_cwd_len = try std.process.currentPath(io, &local_cwd_buf);
        pending_image = media.fromPath(gpa, io, local_cwd_buf[0..local_cwd_len], path) catch |err| {
            try eprint(io, "marlin: cannot attach image '{s}': {t}\n", .{ path, err });
            return 2;
        };
    }

    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model_str: []const u8 = flags.model orelse "";
    var effort: proto.ReasoningEffort = .auto;

    // Headless mode never prompts. Ask the daemon host for its durable
    // default (important over SSH), and fail before creating a doomed session
    // when a fresh installation has not completed interactive setup.
    if (!flags.continue_last) {
        try conn.send(.{ .setup_status = .{ .probe_guests = false } });
        const setup = try conn.recvUntil(arena, .setup_status_result);
        if (flags.model == null and !setup.completed) {
            try eprint(io, "marlin run: provider setup is incomplete; start Marlin interactively and choose /setup, or pass --model with credentials configured on the daemon host\n", .{});
            return 2;
        }
        if (flags.model == null) model_str = setup.default_model;
        effort = setup.default_effort;
    }

    // Resolve the session id.
    var sid: u64 = 0;
    if (flags.continue_last) {
        try conn.send(.{ .session_list = .{} });
        const list = try conn.recvUntil(arena, .session_list_result);
        if (list.sessions.len == 0) {
            try eprint(io, "marlin: no session to continue\n", .{});
            return 1;
        }
        sid = list.sessions[0].sid; // newest first
    } else {
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = try std.process.currentPath(io, &cwd_buf);
        // Headless one-shots auto-approve: there is no one to ask.
        const approvals: []const u8 = if (flags.ask) "default" else "auto";
        try conn.send(.{ .session_create = .{
            .cwd = cwd_buf[0..cwd_len],
            .model = model_str,
            .effort = effort,
            .approvals = approvals,
        } });
        const created = try conn.recvUntil(arena, .session_created);
        sid = created.sid;
    }

    // Subscribe live-only (we don't need history replayed) and start the turn.
    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    var uploads: [1]proto.AttachmentUpload = undefined;
    const upload_slice: []const proto.AttachmentUpload = if (pending_image) |image| blk: {
        uploads[0] = .{ .name = image.name, .mime = image.mime, .data_base64 = image.data_base64 };
        break :blk uploads[0..1];
    } else &.{};
    try conn.send(.{ .input = .{ .sid = sid, .text = task, .attachments = upload_slice } });

    // Stream until the session goes idle/err again.
    var final_text: ?[]u8 = null;
    defer if (final_text) |t| gpa.free(t);
    var tokens_in: u64 = 0;
    var tokens_out: u64 = 0;
    var saw_running = false;
    var failed = false;

    while (true) {
        var msg_arena = std.heap.ArenaAllocator.init(gpa);
        defer msg_arena.deinit();
        const msg = conn.recv(msg_arena.allocator()) catch break;
        switch (msg) {
            .delta => |d| {
                if (d.sid == sid and !flags.quiet) try print(io, "{s}", .{d.text});
            },
            .blk => |b| {
                if (b.sid != sid) continue;
                switch (b.b.body) {
                    .assistant_msg => |am| {
                        if (final_text) |t| gpa.free(t);
                        final_text = try gpa.dupe(u8, am.text);
                    },
                    .tool_call => |tc| {
                        if (!flags.quiet) try print(io, "\n[tool: {s}]\n", .{tc.name});
                    },
                    .system_note => |sn| {
                        if (!flags.quiet) try print(io, "\n[{s}]\n", .{sn.text});
                    },
                    else => {},
                }
            },
            .status => |s| {
                if (s.sid != sid) continue;
                switch (s.state) {
                    .running => saw_running = true,
                    .idle => if (saw_running) break,
                    .err => {
                        failed = true;
                        if (saw_running) break;
                        saw_running = true; // err before running=already done
                    },
                    else => {},
                }
                if (s.state == .err) break;
            },
            .session_meta => |m| {
                if (m.sid == sid) {
                    tokens_in = m.tokens_in;
                    tokens_out = m.tokens_out;
                }
            },
            .approval_request => |ar| {
                // A --continue'd interactive session may still be in "ask"
                // mode; headless grants everything (same as approvals=auto).
                if (ar.sid == sid) {
                    try conn.send(.{ .approve = .{ .sid = sid, .approval_id = ar.approval_id, .decision = .granted } });
                }
            },
            .err => |e| {
                try eprint(io, "marlin: daemon error {s}: {s}\n", .{ e.code, e.msg });
                return 1;
            },
            else => {},
        }
    }

    if (failed) {
        try eprint(io, "\nmarlin: turn failed (see session log)\n", .{});
        return 1;
    }
    if (flags.quiet) {
        try print(io, "{s}\n", .{final_text orelse ""});
    } else {
        var resolved = resolvedSession(sid, &.{});
        // Collision extension needs the complete catalog. Failure to refresh
        // this cosmetic suffix must not turn a completed agent run into an
        // error, so retain the ordinary eight-character fallback.
        if (conn.send(.{ .session_list = .{ .include_archived = true } })) |_| {
            if (conn.recvUntil(arena, .session_list_result)) |list| {
                if (sessionIds(arena, list.sessions)) |ids| resolved = resolvedSession(sid, ids) else |_| {}
            } else |_| {}
        } else |_| {}
        try print(io, "\n\n[{d} in / {d} out tokens, session {s}]\n", .{ tokens_in, tokens_out, resolved.text() });
    }
    return 0;
}

pub fn ls(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    const include_archived = if (args.len == 0)
        false
    else if (args.len == 1 and std.mem.eql(u8, args[0], "--all"))
        true
    else {
        try eprint(io, "usage: marlin ls [--all]\n", .{});
        return 2;
    };
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Always load archived ids so every displayed handle is globally unique;
    // ordinary `ls` merely filters those rows from its output.
    try conn.send(.{ .session_list = .{ .include_archived = true } });
    const list = try conn.recvUntil(arena, .session_list_result);
    const ids = try sessionIds(arena, list.sessions);

    var visible: usize = 0;
    for (list.sessions) |session| if (include_archived or !session.archived) {
        visible += 1;
    };
    if (visible == 0) {
        try print(io, "no sessions\n", .{});
        return 0;
    }
    for (list.sessions) |s| {
        if (!include_archived and s.archived) continue;
        const marker: []const u8 = if (s.running) "●" else " ";
        const hierarchy: []const u8 = if (s.parent_sid != null) "  ↳" else "";
        const title = if (s.title.len > 0) s.title else "(untitled)";
        const archived = if (s.archived) "  archived" else "";
        var handle_buf: session_handle.Full = undefined;
        const handle = session_handle.display(&handle_buf, s.sid, ids);
        try print(io, "{s}{s} {s}  {s}  [{s}]{s}\n", .{ marker, hierarchy, handle, title, s.model, archived });
    }
    return 0;
}

pub fn setArchived(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
    archived: bool,
) !u8 {
    if (args.len != 1) {
        try eprint(io, "usage: marlin {s} <session-handle>\n", .{if (archived) "archive" else "unarchive"});
        return 2;
    }
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const resolved = (try resolveSessionArg(io, conn, arena_state.allocator(), args[0])) orelse return 2;
    const sid = resolved.sid;
    try conn.send(.{ .session_archive = .{ .sid = sid, .archived = archived } });
    _ = try conn.recvUntil(arena_state.allocator(), .ok);
    try print(io, "{s} session {s}\n", .{ if (archived) "archived" else "restored", resolved.text() });
    return 0;
}

pub fn kill(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    if (args.len < 1) {
        try eprint(io, "usage: marlin kill <session-handle>\n", .{});
        return 2;
    }
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const resolved = (try resolveSessionArg(io, conn, arena_state.allocator(), args[0])) orelse return 2;
    const sid = resolved.sid;
    try conn.send(.{ .session_kill = .{ .sid = sid } });
    _ = try conn.recvUntil(arena_state.allocator(), .ok);
    return 0;
}

pub fn shutdown(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
) !u8 {
    const conn = (attach.tryConnect(gpa, io, environ) catch null) orelse {
        try print(io, "marlin: daemon not running\n", .{});
        return 0;
    };
    defer conn.deinit();
    try conn.send(.{ .hello = .{ .proto_version = proto.proto_version } });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    _ = try conn.recvUntil(arena_state.allocator(), .hello_ok);
    try conn.send(.{ .shutdown = .{} });
    _ = conn.recvUntil(arena_state.allocator(), .ok) catch {};
    return 0;
}

/// `marlin gc [--expire-days N]` — safe orphan sweep by default. Full blob
/// bodies are demoted only when the operator supplies an explicit horizon.
pub fn gc(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    var expire_before_ms: ?i64 = null;
    if (args.len != 0) {
        if (args.len != 2 or !std.mem.eql(u8, args[0], "--expire-days")) {
            try eprint(io, "usage: marlin gc [--expire-days N]\n", .{});
            return 2;
        }
        const days = std.fmt.parseInt(i64, args[1], 10) catch {
            try eprint(io, "marlin gc: expiry days must be a positive integer\n", .{});
            return 2;
        };
        const ms_per_day: i64 = 24 * 60 * 60 * 1000;
        if (days <= 0 or days > @divTrunc(std.math.maxInt(i64), ms_per_day)) {
            try eprint(io, "marlin gc: expiry days must be a positive integer\n", .{});
            return 2;
        }
        const now = Io.Timestamp.now(io, .real);
        const now_ms: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
        expire_before_ms = now_ms - days * ms_per_day;
    }

    // Through the daemon (autostarting it if needed): store.zig stays the
    // only sqlite user and the single-connection discipline holds.
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin gc: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try conn.send(.{ .gc = .{ .expire_before_ms = expire_before_ms orelse 0 } });
    const report = conn.recvUntil(arena_state.allocator(), .gc_result) catch {
        try eprint(io, "marlin gc: maintenance failed\n", .{});
        return 1;
    };
    try print(io, "reclaimed {d} bytes ({d} orphan blobs, {d} expired bodies)\n", .{
        report.bytes_reclaimed,
        report.orphan_blobs,
        report.expired_blobs,
    });
    return 0;
}

/// `marlin compact [handle]` — manual L2 compaction. Without one: newest
/// session. Waits for the daemon to finish (status returns to idle/err).
pub fn compact(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var sid: u64 = 0;
    var resolved_handle: session_handle.Full = undefined;
    var resolved_handle_len: usize = 0;
    if (args.len >= 1) {
        const resolved = (try resolveSessionArg(io, conn, arena, args[0])) orelse return 2;
        sid = resolved.sid;
        resolved_handle = resolved.handle;
        resolved_handle_len = resolved.handle_len;
    } else {
        try conn.send(.{ .session_list = .{ .include_archived = true } });
        const list = try conn.recvUntil(arena, .session_list_result);
        var selected: ?u64 = null;
        for (list.sessions) |session| {
            if (!session.archived) {
                selected = session.sid;
                break;
            }
        }
        if (selected == null) {
            try eprint(io, "marlin: no sessions\n", .{});
            return 1;
        }
        sid = selected.?;
        const ids = try sessionIds(arena, list.sessions);
        const resolved = resolvedSession(sid, ids);
        resolved_handle = resolved.handle;
        resolved_handle_len = resolved.handle_len;
    }

    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    try conn.send(.{ .session_compact = .{ .sid = sid } });

    // Wait for the compaction lifecycle to complete: running → idle.
    var saw_running = false;
    while (true) {
        const msg = try conn.recv(arena);
        switch (msg) {
            .status => |s| {
                if (s.sid != sid) continue;
                switch (s.state) {
                    .running => saw_running = true,
                    .idle, .done => if (saw_running) {
                        try print(io, "compacted session {s}\n", .{resolved_handle[0..resolved_handle_len]});
                        return 0;
                    },
                    .err => {
                        try eprint(io, "marlin: compaction errored\n", .{});
                        return 1;
                    },
                    else => {},
                }
            },
            .err => |e| {
                try eprint(io, "marlin: {s}: {s}\n", .{ e.code, e.msg });
                return 1;
            },
            else => {},
        }
    }
}

const RebuildScope = enum { none, attached, client, both };

const RebootOptions = struct {
    rebuild: RebuildScope = .none,
    force: bool = false,
    follow_up_at: ?usize = null,
};

fn parseRebootOptions(args: []const [:0]const u8) error{InvalidArgument}!RebootOptions {
    var options = RebootOptions{};
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--build")) {
            options.rebuild = .attached;
        } else if (std.mem.eql(u8, arg, "--build-client")) {
            options.rebuild = .client;
        } else if (std.mem.eql(u8, arg, "--build-both")) {
            options.rebuild = .both;
        } else if (std.mem.eql(u8, arg, "--force")) {
            options.force = true;
        } else if (std.mem.eql(u8, arg, "--then")) {
            options.follow_up_at = i + 1;
            break;
        } else {
            return error.InvalidArgument;
        }
    }
    return options;
}

const RebuildActions = struct {
    local: bool,
    remote: bool,
    reboot_daemon: bool,
};

fn rebuildActions(scope: RebuildScope, remote: bool) RebuildActions {
    return .{
        .local = scope == .client or scope == .both or (scope == .attached and !remote),
        .remote = remote and (scope == .attached or scope == .both),
        .reboot_daemon = scope != .client,
    };
}

/// Coordinated local/remote reboot. Builds remain process-boundary operations:
/// local source builds run here, remote source builds run through SSH, and the
/// daemon protocol owns only quiescence and exit.
pub fn reboot(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    const options = parseRebootOptions(args) catch {
        try eprint(io, "usage: marlin reboot [--build|--build-client|--build-both] [--force] [--then <args...>]\n", .{});
        return 2;
    };
    const follow_up = if (options.follow_up_at) |at| args[at..] else &.{};
    const remote = environ.get(attach.remote_env);
    const actions = rebuildActions(options.rebuild, remote != null);

    var local_candidate: ?[]u8 = null;
    defer if (local_candidate) |path| gpa.free(path);
    if (actions.local) {
        local_candidate = self_build.build(gpa, io, "local Marlin") catch |err| {
            if (err == error.NotSourceBuild) {
                try eprint(
                    io,
                    "marlin: !rb client requires the running executable to be <checkout>/zig-out/bin/marlin\n" ++
                        "marlin: package installations should be updated with their installer or package manager\n",
                    .{},
                );
            } else {
                try eprint(io, "marlin: local build failed: {t}\n", .{err});
            }
            return 1;
        };
    }

    const exec_path = local_candidate orelse self_exe;
    if (!try sanityCheckCandidate(gpa, io, exec_path)) return 1;

    var remote_builder: ?*attach.Conn = null;
    defer if (remote_builder) |conn| conn.deinit();
    if (actions.remote) {
        const host = remote.?;
        try eprint(io, "marlin: building attached Marlin on {s}...\n", .{host});
        remote_builder = attach.spawnRemoteRebuild(gpa, io, host) catch |err| {
            try eprint(io, "marlin: could not start remote build: {t}\n", .{err});
            return 1;
        };
        const marker = proto.readLineAlloc(gpa, remote_builder.?.reader) catch |err| {
            try eprint(io, "marlin: remote build failed before readiness: {t}\n", .{err});
            return 1;
        };
        defer gpa.free(marker);
        if (!std.mem.eql(u8, marker, attach.rebuild_ready_marker)) {
            try eprint(io, "marlin: remote build failed — reboot aborted\n", .{});
            return 1;
        }
    }

    if (actions.reboot_daemon) {
        const ok = if (remote != null)
            try rebootConnectedDaemon(gpa, io, environ, self_exe, options.force)
        else
            try rebootLocalDaemon(gpa, io, environ, options.force);
        if (!ok) return 1;
    }

    if (remote_builder) |conn| {
        conn.writer.writeAll("continue\n") catch |err| {
            try eprint(io, "marlin: could not activate remote build: {t}\n", .{err});
            return 1;
        };
        conn.writer.flush() catch |err| {
            try eprint(io, "marlin: could not activate remote build: {t}\n", .{err});
            return 1;
        };
        const marker = proto.readLineAlloc(gpa, conn.reader) catch |err| {
            try eprint(io, "marlin: remote build did not start: {t}\n", .{err});
            return 1;
        };
        defer gpa.free(marker);
        if (!std.mem.eql(u8, marker, attach.rebuild_started_marker)) {
            try eprint(io, "marlin: remote build activation failed\n", .{});
            return 1;
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, exec_path);
    for (follow_up) |a| try argv.append(gpa, a);
    const err = std.process.replace(io, .{ .argv = argv.items });
    try eprint(io, "marlin: exec failed: {t}\n", .{err});
    return 1;
}

fn sanityCheckCandidate(gpa: std.mem.Allocator, io: Io, candidate: []const u8) !bool {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ candidate, "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch |err| {
        try eprint(io, "marlin: candidate binary failed sanity exec: {t} — reboot aborted\n", .{err});
        return false;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0 or
        !std.mem.startsWith(u8, result.stdout, "marlin "))
    {
        try eprint(io, "marlin: candidate binary failed sanity check — reboot aborted\n", .{});
        return false;
    }
    return true;
}

fn rebootConnectedDaemon(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    force: bool,
) !bool {
    const conn = attach.connect(gpa, io, environ, self_exe) catch |err| {
        try eprint(io, "marlin: cannot reach attached daemon for reboot: {t}\n", .{err});
        return false;
    };
    defer conn.deinit();
    return requestReboot(gpa, io, conn, force);
}

fn rebootLocalDaemon(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    force: bool,
) !bool {
    const conn = (attach.tryConnect(gpa, io, environ) catch null) orelse return true;
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try conn.send(.{ .hello = .{ .proto_version = proto.proto_version, .client_kind = "reboot" } });
    _ = try conn.recvUntil(arena_state.allocator(), .hello_ok);
    return requestReboot(gpa, io, conn, force);
}

fn requestReboot(gpa: std.mem.Allocator, io: Io, conn: *attach.Conn, force: bool) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try conn.send(.{ .reboot = .{ .force = force } });
    _ = conn.recvUntil(arena_state.allocator(), .ok) catch |err| {
        if (err == error.DaemonError) {
            try eprint(io, "marlin: reboot refused; daemon remains running\n", .{});
            return false;
        }
        try eprint(io, "marlin: daemon did not ack reboot (crashed?) — proceeding\n", .{});
    };
    return true;
}

fn print(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [8192]u8 = undefined;
    var w: Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w: Io.File.Writer = .init(.stderr(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

test "reboot scopes map to local and remote actions" {
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = false, .reboot_daemon = true },
        rebuildActions(.attached, false),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = false, .remote = true, .reboot_daemon = true },
        rebuildActions(.attached, true),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = false, .reboot_daemon = false },
        rebuildActions(.client, true),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = true, .reboot_daemon = true },
        rebuildActions(.both, true),
    );
}

test "reboot option parsing preserves follow-up arguments" {
    const args = [_][:0]const u8{ "--build-both", "--force", "--then", "attach", "@7" };
    const options = try parseRebootOptions(&args);
    try std.testing.expectEqual(RebuildScope.both, options.rebuild);
    try std.testing.expect(options.force);
    try std.testing.expectEqual(@as(?usize, 3), options.follow_up_at);
    try std.testing.expectError(error.InvalidArgument, parseRebootOptions(&.{"--bogus"}));
}

test "flag parsing" {
    const args = [_][:0]const u8{ "--continue", "--model", "openrouter/x", "do stuff" };
    const f = try parseFlags(&args);
    try std.testing.expect(f.continue_last);
    try std.testing.expectEqualStrings("openrouter/x", f.model.?);
    try std.testing.expectEqualStrings("do stuff", f.task.?);
}
