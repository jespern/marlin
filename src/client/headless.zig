//! Headless protocol clients: `marlin run`, `marlin ls`, `marlin kill`,
//! `marlin shutdown`. All drive the daemon over the socket — the in-process
//! M0 path is gone; the daemon autostarts on demand (attach.connect).
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

const config = @import("../core/config.zig");
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

pub const Flags = struct {
    continue_last: bool = false,
    model: ?[]const u8 = null,
    quiet: bool = false,
    ask: bool = false,
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
        try eprint(io, "usage: marlin run [--continue] [--model <m>] [--quiet] \"task\"\n", .{});
        return 2;
    };
    const task = flags.task orelse {
        try eprint(io, "marlin run: missing task text\n", .{});
        return 2;
    };

    var loaded_config = try config.load(gpa, io, environ);
    defer loaded_config.deinit();
    const cfg = loaded_config.value;
    const model_str = flags.model orelse cfg.model_default;

    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

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
            .effort = cfg.effort_default,
            .approvals = approvals,
        } });
        const created = try conn.recvUntil(arena, .session_created);
        sid = created.sid;
    }

    // Subscribe live-only (we don't need history replayed) and start the turn.
    try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 0 } });
    try conn.send(.{ .input = .{ .sid = sid, .text = task } });

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
        try print(io, "\n\n[{d} in / {d} out tokens, session {d}]\n", .{ tokens_in, tokens_out, sid });
    }
    return 0;
}

pub fn ls(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
) !u8 {
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try conn.send(.{ .session_list = .{} });
    const list = try conn.recvUntil(arena_state.allocator(), .session_list_result);

    if (list.sessions.len == 0) {
        try print(io, "no sessions\n", .{});
        return 0;
    }
    for (list.sessions) |s| {
        const marker: []const u8 = if (s.running) "●" else " ";
        const title = if (s.title.len > 0) s.title else "(untitled)";
        // #xxxx short tag matches the TUI status bar; full id for attach.
        try print(io, "{s} #{x:0>4}  {s}  [{s}]  ({d})\n", .{ marker, s.sid & 0xFFFF, title, s.model, s.sid });
    }
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
        try eprint(io, "usage: marlin kill <session-id>\n", .{});
        return 2;
    }
    const sid = std.fmt.parseInt(u64, args[0], 10) catch {
        try eprint(io, "marlin: bad session id '{s}'\n", .{args[0]});
        return 2;
    };
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        try eprint(io, "marlin: cannot reach daemon: {t}\n", .{e});
        return 1;
    };
    defer conn.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
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

/// `marlin compact [sid]` — manual L2 compaction. Without sid: newest
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
    if (args.len >= 1) {
        sid = std.fmt.parseInt(u64, args[0], 10) catch {
            try eprint(io, "marlin: bad session id '{s}'\n", .{args[0]});
            return 2;
        };
    } else {
        try conn.send(.{ .session_list = .{} });
        const list = try conn.recvUntil(arena, .session_list_result);
        if (list.sessions.len == 0) {
            try eprint(io, "marlin: no sessions\n", .{});
            return 1;
        }
        sid = list.sessions[0].sid;
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
                        try print(io, "compacted session {d}\n", .{sid});
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

/// `marlin reboot [--build] [--force]` — coordinated re-exec onto a fresh
/// binary (ARCHITECTURE.md §self-hosting reboot).
///   1. --build: run `zig build` first; abort on failure.
///   2. Sanity-exec the candidate binary (`--version`) — exec-into-broken
///      must be impossible.
///   3. Send reboot{force}; daemon quiesces, acks, exits.
///   4. Re-exec ourselves (argv[0] path) with the given follow-up args —
///      autostart brings up the new daemon.
pub fn reboot(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    var do_build = false;
    var force = false;
    var follow_up: []const [:0]const u8 = &.{};
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--build")) {
            do_build = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--then")) {
            // e2e seam: exec into `marlin <follow-up args>` instead of the TUI.
            follow_up = args[i + 1 ..];
            break;
        } else {
            try eprint(io, "usage: marlin reboot [--build] [--force] [--then <args...>]\n", .{});
            return 2;
        }
    }

    // 1. Optional build, streamed to the terminal.
    if (do_build) {
        const res = std.process.run(gpa, io, .{
            .argv = &.{ "zig", "build" },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        }) catch |e| {
            try eprint(io, "marlin: zig build failed to spawn: {t}\n", .{e});
            return 1;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        const ok = res.term == .exited and res.term.exited == 0;
        if (!ok) {
            try eprint(io, "marlin: build failed — reboot aborted\n{s}\n", .{res.stderr[0..@min(res.stderr.len, 4000)]});
            return 1;
        }
    }

    // 2. Sanity-exec the candidate. The one unrecoverable reboot failure is
    // exec-into-broken-binary; make it impossible.
    {
        const res = std.process.run(gpa, io, .{
            .argv = &.{ self_exe, "version" },
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        }) catch |e| {
            try eprint(io, "marlin: candidate binary failed sanity exec: {t} — reboot aborted\n", .{e});
            return 1;
        };
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        const ok = res.term == .exited and res.term.exited == 0 and
            std.mem.startsWith(u8, res.stdout, "marlin");
        if (!ok) {
            try eprint(io, "marlin: candidate binary failed sanity check — reboot aborted\n", .{});
            return 1;
        }
    }

    // 3. Coordinated daemon shutdown (skip silently when no daemon runs —
    // reboot then degrades to plain exec).
    if (attach.tryConnect(gpa, io, environ) catch null) |conn| {
        defer conn.deinit();
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        try conn.send(.{ .hello = .{ .proto_version = proto.proto_version, .client_kind = "reboot" } });
        _ = try conn.recvUntil(arena, .hello_ok);
        try conn.send(.{ .reboot = .{ .force = force } });
        _ = conn.recvUntil(arena, .ok) catch {
            try eprint(io, "marlin: daemon did not ack reboot (crashed?) — proceeding\n", .{});
        };
    }

    // 4. Re-exec. The new process autostarts the new daemon on connect.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, self_exe);
    for (follow_up) |a| try argv.append(gpa, a);
    const err = std.process.replace(io, .{ .argv = argv.items });
    try eprint(io, "marlin: exec failed: {t}\n", .{err});
    return 1;
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

test "flag parsing" {
    const args = [_][:0]const u8{ "--continue", "--model", "openrouter/x", "do stuff" };
    const f = try parseFlags(&args);
    try std.testing.expect(f.continue_last);
    try std.testing.expectEqualStrings("openrouter/x", f.model.?);
    try std.testing.expectEqualStrings("do stuff", f.task.?);
}
