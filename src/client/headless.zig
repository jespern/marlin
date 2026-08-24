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

    const cfg = config.defaults();
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
        try conn.send(.{ .session_create = .{ .cwd = cwd_buf[0..cwd_len], .model = model_str, .approvals = approvals } });
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
        try print(io, "{s} {d}  {s}  [{s}]\n", .{ marker, s.sid, title, s.model });
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
