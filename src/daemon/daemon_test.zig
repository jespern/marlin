//! Dispatcher regressions tested with real sessions and client outboxes.
const std = @import("std");
const daemon_mod = @import("daemon.zig");
const proto = @import("../core/proto.zig");
const store = @import("store.zig");
const block_mod = @import("../core/block.zig");

test {
    std.testing.refAllDecls(daemon_mod);
}

test "a /rename title survives later substantive prompts" {
    try std.testing.expect(daemon_mod.turnTitle(.root, .user, "integrating tetris client") == null);
    try std.testing.expect(daemon_mod.turnTitle(.root, .user, "commit it") == null);
    try std.testing.expectEqualStrings("integrating tetris client", daemon_mod.turnTitle(.root, .auto, "integrating tetris client").?);
}

test "guest progress cannot dismiss a parked question or approval" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var peer = try server.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    var stream = try server.accept(io);
    defer stream.close(io);

    var daemon: daemon_mod.Daemon = undefined;
    daemon.gpa = gpa;
    daemon.io = io;
    daemon.store = try store.Store.open(gpa, null);
    defer daemon.store.close();
    daemon.clients = .empty;
    defer daemon.clients.deinit(gpa);
    daemon.clients_mutex = .init;
    daemon.sessions = .empty;
    defer daemon.sessions.deinit(gpa);
    var client = daemon_mod.Client{ .id = 1, .stream = stream, .outbox = .init(gpa), .said_hello = true };
    defer {
        while (client.outbox.tryPop(io)) |line| gpa.free(line.bytes);
        client.outbox.deinit();
        client.subs.deinit(gpa);
    }
    try client.subs.append(gpa, 7);
    try daemon.clients.put(gpa, client.id, &client);
    var session = daemon_mod.Session{
        .id = 7,
        .model = try gpa.dupe(u8, "claudecode/default"),
        .cwd = try gpa.dupe(u8, "/tmp"),
    };
    defer gpa.free(session.model);
    defer gpa.free(session.cwd);
    defer if (session.pending_approval_line) |line| gpa.free(line);
    try daemon.sessions.put(gpa, session.id, &session);

    for ([_]proto.DaemonMsg{
        .{ .question_request = .{ .sid = 7, .question_id = "11", .question = "Which option?", .options = &.{ "One", "Two" } } },
        .{ .approval_request = .{ .sid = 7, .approval_id = "12", .call_id = "call", .tool = "Bash", .args_json = "{}" } },
    }) |request| {
        session.state = .awaiting_approval;
        session.phase.store(@backingInt(proto.TurnPhase.approval), .release);
        session.phase_started_at_ms.store(100, .release);
        session.pending_approval_line = try proto.encode(gpa, request);
        const parked_line = session.pending_approval_line.?;
        // MCP questions park through the dispatcher while the guest reader
        // can still report tool/provider/finishing phases. None is an answer.
        for ([_]proto.TurnPhase{ .tool, .provider, .finishing }) |phase| {
            try daemon.handleEvent(.{ .turn_phase = .{ .sid = 7, .phase = phase, .started_at_ms = 200 } });
            try std.testing.expectEqual(proto.SessionState.awaiting_approval, session.state);
            try std.testing.expectEqual(@backingInt(proto.TurnPhase.approval), session.phase.load(.acquire));
            try std.testing.expectEqual(@as(i64, 100), session.phase_started_at_ms.load(.acquire));
            try std.testing.expectEqualStrings(parked_line, session.pending_approval_line.?);
            try std.testing.expect(client.outbox.tryPop(io) == null);
        }
        // The actual lifecycle transition still clears the card, and normal
        // progress resumes without requiring an unsubscribe/subscribe cycle.
        try daemon.handleEvent(.{ .turn_resumed = .{ .sid = 7 } });
        try std.testing.expect(session.pending_approval_line == null);
        const resumed = client.outbox.tryPop(io).?;
        gpa.free(resumed.bytes);
        try daemon.handleEvent(.{ .turn_phase = .{ .sid = 7, .phase = .provider, .started_at_ms = 300 } });
        const progress = client.outbox.tryPop(io).?;
        defer gpa.free(progress.bytes);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const message = try proto.decode(proto.DaemonMsg, arena.allocator(), progress.bytes);
        try std.testing.expectEqual(proto.SessionState.running, message.status.state);
        try std.testing.expectEqual(proto.TurnPhase.provider, message.status.phase.?);
    }
    session.state = .done;
    try daemon.handleEvent(.{ .turn_phase = .{ .sid = 7, .phase = .finishing, .started_at_ms = 400 } });
    try std.testing.expect(client.outbox.tryPop(io) == null);
}

test "image steering keeps durable refs and gives guests readable files" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-steer-images");
    defer temp.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("TMPDIR", temp.path);
    var daemon: daemon_mod.Daemon = undefined;
    daemon.gpa = gpa;
    daemon.io = io;
    daemon.environ = &env;
    daemon.store = try store.Store.open(gpa, null);
    defer daemon.store.close();
    try daemon.store.createSession(7, 0, temp.path, "test", .auto);
    const bytes = "\x89PNG\r\n\x1a\nimage-payload";
    const encoded = try gpa.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    defer gpa.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    var seq: u64 = 1;
    for ([_][]const u8{ "openrouter/test", "codex/default", "claudecode/default" }) |model| {
        const input = try daemon.prepareSteerInput(model, "look here", null, &.{.{
            .name = "shot.png",
            .mime = "image/png",
            .data_base64 = encoded,
        }});
        defer input.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 1), input.attachments.len);
        if (proto.isGuestModel(model)) {
            try std.testing.expectEqualStrings("look here", input.display_text.?);
            const path = try std.fmt.allocPrint(gpa, "{s}/marlin-attachments/{s}.png", .{ temp.path, input.attachments[0].hash });
            defer gpa.free(path);
            try std.testing.expect(std.mem.indexOf(u8, input.text, path) != null);
            const actual = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
            defer gpa.free(actual);
            try std.testing.expectEqualStrings(bytes, actual);
        } else {
            try std.testing.expectEqualStrings("look here", input.text);
            try std.testing.expect(input.display_text == null);
        }
        try daemon.store.appendBlock(.{
            .id = seq,
            .session_id = 7,
            .turn_id = 1,
            .seq = seq,
            .ts = 0,
            .body = .{ .steer = input },
        });
        seq += 1;
    }
    const stmt = try daemon.store.prepare("SELECT count(*) FROM blob_refs");
    defer store.finalize(stmt);
    try std.testing.expectEqual(store.c.SQLITE_ROW, store.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 3), store.c.sqlite3_column_int64(stmt, 0));
}

test "shells outlive their opener and are shared by every viewer" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var peer = try server.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    var stream = try server.accept(io);
    defer stream.close(io);

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("SHELL", "/bin/sh");
    try environ.put("HOME", "/");
    try environ.put("PATH", "/usr/bin:/bin");

    var daemon: daemon_mod.Daemon = undefined;
    daemon.gpa = gpa;
    daemon.io = io;
    daemon.environ = &environ;
    daemon.events = .init(gpa);
    daemon.clients = .empty;
    defer daemon.clients.deinit(gpa);
    daemon.clients_mutex = .init;
    daemon.sessions = .empty;
    defer daemon.sessions.deinit(gpa);
    daemon.shells = .empty;
    daemon.agent_waits = .empty;
    daemon.next_shell_id = 1;
    daemon.store = try store.Store.open(gpa, null);
    defer daemon.store.close();
    daemon.cfg = .{};
    daemon.network = .{ .gpa = gpa };
    daemon.advertiser = null;
    daemon.sandbox_backend = .unavailable;
    daemon.presence = .{};
    // Built field by field from undefined: every field the code under test
    // reads must be set, or it reads garbage (a phantom reboot on Linux).
    daemon.pending_reboot = null;
    try daemon.store.createSession(7, 0, "/", "m", .auto);
    var session = daemon_mod.Session{ .id = 7, .model = try gpa.dupe(u8, "m"), .cwd = try gpa.dupe(u8, "/") };
    defer gpa.free(session.model);
    defer gpa.free(session.cwd);
    try daemon.sessions.put(gpa, session.id, &session);
    var opener = daemon_mod.Client{ .id = 1, .stream = stream, .outbox = .init(gpa), .said_hello = true };
    var other = daemon_mod.Client{ .id = 2, .stream = stream, .outbox = .init(gpa), .said_hello = true };
    defer for ([_]*daemon_mod.Client{ &opener, &other }) |client| {
        while (client.outbox.tryPop(io)) |line| gpa.free(line.bytes);
        client.outbox.deinit();
    };
    try daemon.clients.put(gpa, opener.id, &opener);
    try daemon.clients.put(gpa, other.id, &other);
    defer {
        var hosts = daemon.shells.valueIterator();
        while (hosts.next()) |host| host.*.destroy();
        daemon.shells.deinit(gpa);
        while (daemon.events.tryPop(io)) |event| switch (event) {
            .shell_output => |o| gpa.free(o.bytes),
            else => {},
        };
        daemon.events.deinit();
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Helpers = struct {
        fn send(d: *daemon_mod.Daemon, client_id: u64, comptime json: []const u8, args: anytype) !void {
            const bytes = try std.fmt.allocPrint(d.gpa, json ++ "\n", args);
            try d.handleEvent(.{ .client_msg = .{ .client_id = client_id, .msg_line = bytes } });
        }
        fn drain(alloc: std.mem.Allocator, client: *daemon_mod.Client, io_: std.Io) ![]proto.DaemonMsg {
            var msgs: std.ArrayList(proto.DaemonMsg) = .empty;
            while (client.outbox.tryPop(io_)) |line| {
                defer client.outbox.gpa.free(line.bytes);
                try msgs.append(alloc, try proto.decode(proto.DaemonMsg, alloc, try alloc.dupe(u8, line.bytes)));
            }
            return msgs.items;
        }
        fn output(alloc: std.mem.Allocator, msgs: []const proto.DaemonMsg, into: *std.ArrayList(u8)) !?proto.DaemonMsg {
            for (msgs) |msg| switch (msg) {
                .shell_output => |o| {
                    const decoder = std.base64.standard.Decoder;
                    const bytes = try alloc.alloc(u8, try decoder.calcSizeForSlice(o.data_base64));
                    try decoder.decode(bytes, o.data_base64);
                    try into.appendSlice(alloc, bytes);
                },
                .shell_exited => return msg,
                else => {},
            };
            return null;
        }
    };

    try Helpers.send(&daemon, opener.id, "{{\"shell_open\":{{\"request_id\":3,\"sid\":7,\"cols\":80,\"rows\":24}}}}", .{});
    var msgs = try Helpers.drain(a, &opener, io);
    try std.testing.expectEqual(@as(u64, 3), msgs[0].shell_opened.request_id);
    const shell_id = msgs[0].shell_opened.shell_id;
    try std.testing.expectEqual(shell_id, msgs[1].shell_snapshot.shell_id);

    // Not a viewer: cannot hang it up.
    try Helpers.send(&daemon, other.id, "{{\"shell_close\":{{\"shell_id\":{d}}}}}", .{shell_id});
    try std.testing.expectEqual(@as(usize, 1), daemon.shells.count());

    // A second client attaches and sees what the shell prints next.
    try Helpers.send(&daemon, other.id, "{{\"shell_attach\":{{\"request_id\":8,\"shell_id\":{d},\"cols\":100,\"rows\":30}}}}", .{shell_id});
    msgs = try Helpers.drain(a, &other, io);
    try std.testing.expectEqual(@as(u64, 8), msgs[0].shell_opened.request_id);
    try std.testing.expect(msgs[1] == .shell_snapshot);

    var input_buf: [128]u8 = undefined;
    const input = std.base64.standard.Encoder.encode(&input_buf, "echo hi-$((1+1))\r");
    try Helpers.send(&daemon, opener.id, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"{s}\"}}}}", .{ shell_id, input });
    var seen_opener: std.ArrayList(u8) = .empty;
    var seen_other: std.ArrayList(u8) = .empty;
    for (0..500) |_| {
        while (daemon.events.tryPop(io)) |event| try daemon.handleEvent(event);
        _ = try Helpers.output(a, try Helpers.drain(a, &opener, io), &seen_opener);
        _ = try Helpers.output(a, try Helpers.drain(a, &other, io), &seen_other);
        if (std.mem.indexOf(u8, seen_other.items, "hi-2") != null and std.mem.indexOf(u8, seen_opener.items, "hi-2") != null) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;

    // A title the program sets reaches clients with the session.
    other.watches_sessions = true;
    other.watches_session_deltas = true;
    const titled = std.base64.standard.Encoder.encode(&input_buf, "printf '\\033]2;%s\\007' tab-$((3+3))\r");
    try Helpers.send(&daemon, other.id, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"{s}\"}}}}", .{ shell_id, titled });
    var titled_seen = false;
    for (0..500) |_| {
        while (daemon.events.tryPop(io)) |event| try daemon.handleEvent(event);
        for (try Helpers.drain(a, &other, io)) |msg| switch (msg) {
            .session_upsert => |up| if (std.mem.eql(u8, up.session.shell_title, "tab-6")) {
                titled_seen = true;
            },
            else => {},
        };
        if (titled_seen) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;

    // The opener leaving does not end the shell.
    daemon.detachClientShells(opener.id);
    try std.testing.expectEqual(@as(usize, 1), daemon.shells.count());

    // While it is a shell, the session takes no agent input.
    try std.testing.expectEqual(shell_id, daemon.sessionShell(7).?.id);
    _ = try Helpers.drain(a, &opener, io);
    try Helpers.send(&daemon, opener.id, "{{\"input\":{{\"sid\":7,\"text\":\"hello agent\",\"request_id\":21}}}}", .{});
    var refused = false;
    for (try Helpers.drain(a, &opener, io)) |msg| if (msg == .err and msg.err.request_id == 21) {
        try std.testing.expectEqualStrings("shell", msg.err.code);
        refused = true;
    };
    try std.testing.expect(refused);

    // Ctrl+N from the shell: the new session starts where the shell is now,
    // not where it was opened.
    const cd = std.base64.standard.Encoder.encode(&input_buf, "cd /tmp && echo moved-$((2+2))\r");
    try Helpers.send(&daemon, other.id, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"{s}\"}}}}", .{ shell_id, cd });
    for (0..500) |_| {
        while (daemon.events.tryPop(io)) |event| try daemon.handleEvent(event);
        _ = try Helpers.output(a, try Helpers.drain(a, &other, io), &seen_other);
        if (std.mem.indexOf(u8, seen_other.items, "moved-4") != null) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    try Helpers.send(&daemon, other.id, "{{\"session_create\":{{\"cwd\":\"/\",\"model\":\"m\",\"request_id\":31,\"cwd_from_sid\":7}}}}", .{});
    var created_sid: ?u64 = null;
    for (try Helpers.drain(a, &other, io)) |msg| if (msg == .session_created and msg.session_created.request_id == 31) {
        created_sid = msg.session_created.sid;
    };
    const created = daemon.sessions.fetchRemove(created_sid.?).?.value;
    defer {
        gpa.free(created.model);
        gpa.free(created.cwd);
        gpa.destroy(created);
    }
    const tmp = try std.Io.Dir.cwd().realPathFileAlloc(io, "/tmp", a);
    try std.testing.expectEqualStrings(tmp, created.cwd);

    // Closing reaches everyone still viewing.
    try Helpers.send(&daemon, other.id, "{{\"shell_close\":{{\"shell_id\":{d}}}}}", .{shell_id});
    try std.testing.expectEqual(@as(usize, 0), daemon.shells.count());
    var exited: ?proto.DaemonMsg = null;
    for (try Helpers.drain(a, &other, io)) |msg| if (msg == .shell_exited) {
        exited = msg;
    };
    try std.testing.expectEqual(shell_id, exited.?.shell_exited.shell_id);

    // The session is ordinary again, with the shell's output in its log.
    try std.testing.expect(daemon.sessionShell(7) == null);
    var blocks: std.ArrayList(@import("../core/block.zig").Block) = .empty;
    try daemon.store.loadTailInto(a, &blocks, 7, 1);
    const recorded = blocks.items[0].body.shell_transcript;
    try std.testing.expect(std.mem.indexOf(u8, recorded.text, "hi-2") != null);
    try std.testing.expectEqual(@as(?i32, 1), recorded.signal);
}

/// A daemon with session 7 (cwd /, shell /bin/sh) and connected clients 1
/// and 2, for shell tests. Heap-allocated: clients point into it.
const ShellRig = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    server: std.Io.net.Server,
    peer: std.Io.net.Stream,
    stream: std.Io.net.Stream,
    environ: std.process.Environ.Map,
    daemon: daemon_mod.Daemon,
    session: daemon_mod.Session,
    clients: [2]daemon_mod.Client,
    arena: std.heap.ArenaAllocator,

    fn create() !*ShellRig {
        const gpa = std.testing.allocator;
        const r = try gpa.create(ShellRig);
        r.gpa = gpa;
        r.threaded = .init(gpa, .{});
        const io = r.threaded.io();
        r.server = try (try std.Io.net.IpAddress.parse("127.0.0.1", 0)).listen(io, .{ .reuse_address = true });
        r.peer = try r.server.socket.address.connect(io, .{ .mode = .stream });
        r.stream = try r.server.accept(io);
        r.environ = std.process.Environ.Map.init(gpa);
        try r.environ.put("SHELL", "/bin/sh");
        try r.environ.put("HOME", "/");
        try r.environ.put("PATH", "/usr/bin:/bin");
        const d = &r.daemon;
        d.gpa = gpa;
        d.io = io;
        d.environ = &r.environ;
        d.events = .init(gpa);
        d.clients = .empty;
        d.clients_mutex = .init;
        d.sessions = .empty;
        d.shells = .empty;
        d.agent_waits = .empty;
        d.next_shell_id = 1;
        d.store = try store.Store.open(gpa, null);
        d.cfg = .{};
        d.network = .{ .gpa = gpa };
        d.advertiser = null;
        d.sandbox_backend = .unavailable;
        d.presence = .{};
        d.pending_reboot = null;
        try d.store.createSession(7, 0, "/", "m", .auto);
        r.session = .{ .id = 7, .model = try gpa.dupe(u8, "m"), .cwd = try gpa.dupe(u8, "/") };
        try d.sessions.put(gpa, r.session.id, &r.session);
        for (&r.clients, 1..) |*client, id| {
            client.* = .{ .id = id, .stream = r.stream, .outbox = .init(gpa), .said_hello = true };
            try d.clients.put(gpa, client.id, client);
        }
        r.arena = .init(gpa);
        return r;
    }

    fn destroy(r: *ShellRig) void {
        const gpa = r.gpa;
        const io = r.threaded.io();
        var hosts = r.daemon.shells.valueIterator();
        while (hosts.next()) |host| host.*.destroy();
        r.daemon.shells.deinit(gpa);
        while (r.daemon.events.tryPop(io)) |event| switch (event) {
            .shell_output => |o| gpa.free(o.bytes),
            else => {},
        };
        r.daemon.events.deinit();
        for (&r.clients) |*client| {
            while (client.outbox.tryPop(io)) |line| gpa.free(line.bytes);
            client.outbox.deinit();
            client.subs.deinit(gpa);
        }
        r.daemon.clients.deinit(gpa);
        r.daemon.sessions.deinit(gpa);
        r.daemon.agent_waits.deinit(gpa);
        r.session.live_text.deinit(gpa);
        r.session.live_reasoning.deinit(gpa);
        gpa.free(r.session.model);
        gpa.free(r.session.cwd);
        r.daemon.store.close();
        r.environ.deinit();
        r.stream.close(io);
        r.peer.close(io);
        r.server.deinit(io);
        r.arena.deinit();
        r.threaded.deinit();
        gpa.destroy(r);
    }

    fn send(r: *ShellRig, client_id: u64, comptime json: []const u8, args: anytype) !void {
        const bytes = try std.fmt.allocPrint(r.gpa, json ++ "\n", args);
        try r.daemon.handleEvent(.{ .client_msg = .{ .client_id = client_id, .msg_line = bytes } });
    }

    /// What the daemon sent client `id` since last asked.
    fn drain(r: *ShellRig, id: u64) ![]proto.DaemonMsg {
        const a = r.arena.allocator();
        var msgs: std.ArrayList(proto.DaemonMsg) = .empty;
        const client = &r.clients[id - 1];
        while (client.outbox.tryPop(r.threaded.io())) |line| {
            defer r.gpa.free(line.bytes);
            try msgs.append(a, try proto.decode(proto.DaemonMsg, a, try a.dupe(u8, line.bytes)));
        }
        return msgs.items;
    }

    /// Run the daemon's queued events (PTY output, exits).
    fn pump(r: *ShellRig) !void {
        while (r.daemon.events.tryPop(r.threaded.io())) |event| try r.daemon.handleEvent(event);
    }
};

test "!! <command>: the shell runs just that and hands the session back when it ends" {
    const r = try ShellRig.create();
    defer r.destroy();
    const io = r.threaded.io();

    try r.send(1, "{{\"shell_open\":{{\"request_id\":3,\"sid\":7,\"cols\":80,\"rows\":24,\"command\":\" echo ran-$((2+3)); exit 3 \"}}}}", .{});
    var exited: ?proto.DaemonMsg = null;
    for (0..500) |_| {
        try r.pump();
        for (try r.drain(1)) |msg| if (msg == .shell_exited) {
            exited = msg;
        };
        if (exited != null) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    try std.testing.expectEqual(@as(?i32, 3), exited.?.shell_exited.code);

    // Nobody pressed Ctrl+D: the session is ordinary again, the command and
    // what it printed in its log.
    try std.testing.expect(r.daemon.sessionShell(7) == null);
    var blocks: std.ArrayList(@import("../core/block.zig").Block) = .empty;
    try r.daemon.store.loadTailInto(r.arena.allocator(), &blocks, 7, 1);
    const recorded = blocks.items[0].body.shell_transcript;
    try std.testing.expectEqualStrings("echo ran-$((2+3)); exit 3", recorded.ran.?);
    try std.testing.expect(std.mem.indexOf(u8, recorded.text, "ran-5") != null);
    try std.testing.expectEqual(@as(?i32, 3), recorded.exit_code);
}

test "a shell takes the size of whoever types; a follower is told, never resizes it by looking" {
    const r = try ShellRig.create();
    defer r.destroy();

    try r.send(1, "{{\"shell_open\":{{\"request_id\":3,\"sid\":7,\"cols\":120,\"rows\":40}}}}", .{});
    const shell_id = (try r.drain(1))[0].shell_opened.shell_id;
    const host = r.daemon.shells.get(shell_id).?;

    // A phone looks: the shell keeps the terminal's size.
    try r.send(2, "{{\"shell_attach\":{{\"request_id\":4,\"shell_id\":{d},\"cols\":44,\"rows\":30,\"follow_size\":true}}}}", .{shell_id});
    _ = try r.drain(2);
    try std.testing.expectEqual(@as(u16, 120), host.geometry.cols);

    // The phone types: the shell takes its size, and the phone hears so.
    try r.send(2, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"Cg==\"}}}}", .{shell_id});
    try std.testing.expectEqual(@as(u16, 44), host.geometry.cols);
    try std.testing.expectEqual(@as(u16, 30), host.geometry.rows);
    var resized = false;
    for (try r.drain(2)) |msg| if (msg == .shell_resized) {
        try std.testing.expectEqual(@as(u16, 44), msg.shell_resized.cols);
        resized = true;
    };
    try std.testing.expect(resized);
    // The terminal client, which sizes itself, is not told.
    for (try r.drain(1)) |msg| try std.testing.expect(msg != .shell_resized);

    // Back at the terminal: typing there takes the size back.
    try r.send(1, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"Cg==\"}}}}", .{shell_id});
    try std.testing.expectEqual(@as(u16, 120), host.geometry.cols);
    resized = false;
    for (try r.drain(2)) |msg| if (msg == .shell_resized) {
        try std.testing.expectEqual(@as(u16, 120), msg.shell_resized.cols);
        try std.testing.expectEqual(@as(u16, 40), msg.shell_resized.rows);
        resized = true;
    };
    try std.testing.expect(resized);

    // Typing again at the same size resizes nothing.
    try r.send(1, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"Cg==\"}}}}", .{shell_id});
    for (try r.drain(2)) |msg| try std.testing.expect(msg != .shell_resized);
}

// Case: Jesper's half-written prompt was gone after a reboot; the client
// hands its draft to the daemon, and whoever opens the session next gets it.
test "a session's draft is kept for the next client that opens it, until it is cleared" {
    const r = try ShellRig.create();
    defer r.destroy();
    const Draft = struct {
        fn after(rig: *ShellRig, client: u64) !?[]const u8 {
            try rig.send(client, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
            var text: ?[]const u8 = null;
            var status_seen = false;
            for (try rig.drain(client)) |msg| switch (msg) {
                .status => status_seen = true,
                // It fills the composer of a view that already exists.
                .draft => |d| {
                    try std.testing.expect(status_seen);
                    try std.testing.expectEqual(@as(u64, 7), d.sid);
                    text = d.text;
                },
                else => {},
            };
            return text;
        }
    };
    try std.testing.expectEqual(@as(?[]const u8, null), try Draft.after(r, 2));

    try r.send(1, "{{\"session_draft\":{{\"sid\":7,\"text\":\"half a thought\\nsecond line\"}}}}", .{});
    try std.testing.expectEqual(@as(usize, 0), (try r.drain(1)).len); // no reply
    try std.testing.expectEqualStrings("half a thought\nsecond line", (try Draft.after(r, 2)).?);
    try std.testing.expectEqualStrings("half a thought\nsecond line", (try Draft.after(r, 1)).?);

    // Sent or erased: nothing comes back.
    try r.send(1, "{{\"session_draft\":{{\"sid\":7,\"text\":\"\"}}}}", .{});
    try std.testing.expectEqual(@as(?[]const u8, null), try Draft.after(r, 2));
}

// Case: attached from the MacBook, /voice set up the MacBook. Over --remote
// the daemon's machine sets up and transcribes; the client only records.
test "a remote client's voice is set up and transcribed on the daemon's machine" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    const io = r.threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-daemon-voice");
    defer temp.deinit();
    const bin = try std.fmt.allocPrint(gpa, "{s}/bin", .{temp.path});
    defer gpa.free(bin);
    try std.Io.Dir.cwd().createDirPath(io, bin);
    inline for (.{
        .{ "ffmpeg", "#!/bin/sh\nin=\"\"; while [ $# -gt 1 ]; do [ \"$1\" = -i ] && in=\"$2\"; shift; done\ncp \"$in\" \"$1\"\n" },
        .{ "parakeet-mlx", "#!/bin/sh\nsleep 0.2\nprintf 'hello there\\n'\n" },
    }) |stub| {
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ bin, stub[0] }, 0);
        defer gpa.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = stub[1] });
        try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(path, 0o700));
    }
    const path_env = try std.fmt.allocPrint(gpa, "{s}:/bin:/usr/bin", .{bin});
    defer gpa.free(path_env);
    try r.environ.put("PATH", path_env);
    try r.environ.put("HOME", temp.path);
    try r.environ.put("TMPDIR", temp.path);
    try r.environ.put("XDG_CONFIG_HOME", temp.path);
    try r.environ.put("XDG_DATA_HOME", temp.path);

    const Wait = struct {
        /// Pump the daemon until client 1 gets a message tagged `tag`.
        fn reply(rig: *ShellRig, comptime tag: std.meta.Tag(proto.DaemonMsg)) !@FieldType(proto.DaemonMsg, @tagName(tag)) {
            for (0..500) |_| {
                try rig.pump();
                for (try rig.drain(1)) |msg| if (msg == tag) return @field(msg, @tagName(tag));
                try rig.threaded.io().sleep(.fromMilliseconds(10), .awake);
            }
            return error.Timeout;
        }
    };
    try r.send(1, "{{\"voice_status\":{{}}}}", .{});
    try std.testing.expect(!(try Wait.reply(r, .voice_status_result)).enabled);

    try r.send(1, "{{\"voice_setup\":{{\"engine\":\"parakeet\",\"mode\":\"toggle\"}}}}", .{});
    try std.testing.expect((try Wait.reply(r, .voice_setup_result)).ok);
    try r.send(1, "{{\"voice_status\":{{}}}}", .{});
    const status = try Wait.reply(r, .voice_status_result);
    try std.testing.expect(status.enabled);
    try std.testing.expectEqualStrings("toggle", status.mode);

    // One clip at a time; a second gets a clear answer instead of a queue.
    try r.send(1, "{{\"voice_transcribe\":{{\"request_id\":9,\"audio_base64\":\"QVVESU8=\"}}}}", .{});
    try r.send(1, "{{\"voice_transcribe\":{{\"request_id\":10,\"audio_base64\":\"QVVESU8=\"}}}}", .{});
    var busy = false;
    var heard: ?[]const u8 = null;
    for (0..500) |_| {
        try r.pump();
        for (try r.drain(1)) |msg| if (msg == .voice_transcript) {
            if (msg.voice_transcript.request_id == 10) busy = msg.voice_transcript.err.len > 0;
            if (msg.voice_transcript.request_id == 9) heard = msg.voice_transcript.text;
        };
        if (heard != null) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expect(busy);
    try std.testing.expectEqualStrings("hello there", heard.?);
}

test "a client that subscribes mid-stream gets the text so far whole, not from the next chunk" {
    // Case: Jesper saw "est" stream where the reply began "Test": the TUI
    // (back from another tab) and the phone (just opened) joined mid-stream.
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    r.session.state = .running;
    const Delta = struct {
        fn push(rig: *ShellRig, text: []const u8) !void {
            const line = try proto.encode(rig.gpa, proto.DaemonMsg{ .delta = .{ .sid = 7, .turn_id = 0, .text = text } });
            try rig.daemon.handleEvent(.{ .turn_delta = .{ .sid = 7, .line = line, .stream = .text, .text = try rig.gpa.dupe(u8, text) } });
        }
    };
    try Delta.push(r, "T");
    try Delta.push(r, "est the parser");

    try r.send(2, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    var live: ?[]const u8 = null;
    var replaced = false;
    for (try r.drain(2)) |msg| if (msg == .delta) {
        live = msg.delta.text;
        replaced = msg.delta.replace;
    };
    try std.testing.expectEqualStrings("Test the parser", live.?);
    try std.testing.expect(replaced);

    // The note is written: nothing is streaming, so a new subscriber gets
    // no live text (it reads the block).
    const note = try proto.encode(gpa, proto.DaemonMsg{ .blk = .{ .sid = 7, .b = .{ .id = 1, .session_id = 7, .turn_id = 1, .seq = 1, .ts = 0, .body = .{ .reasoning = .{ .text = "Test the parser", .commentary = true } } } } });
    try r.daemon.handleEvent(.{ .turn_block = .{ .sid = 7, .line = note, .ends = .text } });
    try r.send(1, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    for (try r.drain(1)) |msg| try std.testing.expect(msg != .delta);
}

test "agents reach other sessions: list, read, message (hop and turn limits), wait, release" {
    const session_handle = @import("../core/session_handle.zig");
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    try r.daemon.store.createSession(8, 0, "/other", "codex/gpt", .auto);
    var other = daemon_mod.Session{ .id = 8, .model = try gpa.dupe(u8, "codex/gpt"), .cwd = try gpa.dupe(u8, "/other") };
    defer {
        for (other.steer_queue.items) |input| input.deinit(gpa);
        other.steer_queue.deinit(gpa);
        for (r.session.steer_queue.items) |input| input.deinit(gpa);
        r.session.steer_queue.deinit(gpa);
        other.live_text.deinit(gpa);
        other.live_reasoning.deinit(gpa);
        gpa.free(other.model);
        gpa.free(other.cwd);
    }
    try r.daemon.sessions.put(gpa, 8, &other);
    var buf: session_handle.Full = undefined;
    const handle = try r.arena.allocator().dupe(u8, session_handle.display(&buf, 8, &.{ 7, 8 }));
    const caller_handle = try r.arena.allocator().dupe(u8, session_handle.display(&buf, 7, &.{ 7, 8 }));

    const Call = struct {
        fn send(rig: *ShellRig, caller: u64, request_id: u64, name: []const u8, args: anytype) !void {
            const args_json = try std.json.Stringify.valueAlloc(rig.gpa, args, .{});
            defer rig.gpa.free(args_json);
            const msg = try std.json.Stringify.valueAlloc(rig.gpa, .{ .agent_tool = .{ .request_id = request_id, .sid = caller, .name = name, .args_json = args_json } }, .{});
            defer rig.gpa.free(msg);
            try rig.send(1, "{s}", .{msg});
        }
        /// The answer to request `id` on client 1, if it has come.
        fn result(rig: *ShellRig, id: u64) !?@FieldType(proto.DaemonMsg, "agent_tool_result") {
            for (try rig.drain(1)) |msg| if (msg == .agent_tool_result and msg.agent_tool_result.request_id == id) return msg.agent_tool_result;
            return null;
        }
    };

    // The list: who I am, and the other session.
    try Call.send(r, 7, 1, "sessions", .{});
    const listed = (try Call.result(r, 1)).?;
    try std.testing.expect(std.mem.indexOf(u8, listed.output, "You are ") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.output, handle) != null);
    try std.testing.expect(std.mem.indexOf(u8, listed.output, "codex/gpt") != null);

    // Reading its transcript.
    try r.daemon.store.appendBlock(.{ .id = 1, .session_id = 8, .turn_id = 1, .seq = 1, .ts = 0, .body = .{ .user_msg = .{ .text = "hello" } } });
    try r.daemon.store.appendBlock(.{ .id = 2, .session_id = 8, .turn_id = 1, .seq = 2, .ts = 0, .body = .{ .assistant_msg = .{ .text = "hi there" } } });
    try Call.send(r, 7, 2, "read_session", .{ .handle = handle });
    const read = (try Call.result(r, 2)).?;
    try std.testing.expect(std.mem.indexOf(u8, read.output, "user: hello\n\nagent: hi there") != null);
    try Call.send(r, 7, 3, "read_session", .{ .handle = caller_handle });
    try std.testing.expectEqual(block_mod.ToolStatus.err, (try Call.result(r, 3)).?.status);

    // A message to a busy session waits for its next step, marked as ours.
    other.state = .running;
    other.steer_accepting = true;
    try Call.send(r, 7, 4, "message_session", .{ .handle = handle, .text = "Is the lexer done?" });
    const sent = (try Call.result(r, 4)).?;
    try std.testing.expectEqual(block_mod.ToolStatus.ok, sent.status);
    try std.testing.expectEqual(@as(usize, 1), other.steer_queue.items.len);
    const delivered = other.steer_queue.items[0].text;
    try std.testing.expect(std.mem.startsWith(u8, delivered, "[Message from another Marlin session"));
    try std.testing.expect(std.mem.indexOf(u8, delivered, caller_handle) != null);
    try std.testing.expect(std.mem.endsWith(u8, delivered, "Is the lexer done?"));
    try std.testing.expectEqual(@as(u8, 1), other.agent_hops);
    try std.testing.expectEqual(@as(u32, 1), r.session.agent_sent);

    // A chain at the hop limit, or a turn at its message limit, stops.
    r.session.agent_hops = 5;
    try Call.send(r, 7, 5, "message_session", .{ .handle = handle, .text = "again" });
    try std.testing.expectEqual(block_mod.ToolStatus.denied, (try Call.result(r, 5)).?.status);
    r.session.agent_hops = 0;
    r.session.agent_sent = 10;
    try Call.send(r, 7, 6, "message_session", .{ .handle = handle, .text = "again" });
    try std.testing.expectEqual(block_mod.ToolStatus.denied, (try Call.result(r, 6)).?.status);
    try std.testing.expectEqual(@as(usize, 1), other.steer_queue.items.len);

    // Waiting on a working session parks until its turn ends...
    try Call.send(r, 7, 7, "wait_for_session", .{ .handle = handle });
    try std.testing.expect(try Call.result(r, 7) == null);
    // ...and it may not wait on us in turn: neither would finish.
    r.session.state = .running;
    try Call.send(r, 8, 8, "wait_for_session", .{ .handle = caller_handle });
    const cycle = (try Call.result(r, 8)).?;
    try std.testing.expectEqual(block_mod.ToolStatus.err, cycle.status);
    try std.testing.expect(std.mem.indexOf(u8, cycle.output, "is waiting for you") != null);
    r.session.state = .idle;
    try r.daemon.store.appendBlock(.{ .id = 3, .session_id = 8, .turn_id = 2, .seq = 3, .ts = 0, .body = .{ .assistant_msg = .{ .text = "Yes, the lexer is done." } } });
    other.state = .idle;
    r.daemon.resolveAgentWaits(8);
    const answered = (try Call.result(r, 7)).?;
    try std.testing.expect(std.mem.endsWith(u8, answered.output, "Its last reply:\n\nYes, the lexer is done."));

    // An idle session answers at once; an interrupted waiter is let go.
    try Call.send(r, 7, 9, "wait_for_session", .{ .handle = handle });
    try std.testing.expect(std.mem.indexOf(u8, (try Call.result(r, 9)).?.output, "the lexer is done") != null);
    other.state = .running;
    try Call.send(r, 7, 10, "wait_for_session", .{ .handle = handle });
    try std.testing.expect(try Call.result(r, 10) == null);
    try r.send(2, "{{\"interrupt\":{{\"sid\":7}}}}", .{});
    try std.testing.expectEqual(block_mod.ToolStatus.interrupted, (try Call.result(r, 10)).?.status);
    try std.testing.expectEqual(@as(usize, 0), r.daemon.agent_waits.items.len);

    // A human speaking starts the chain over.
    r.session.agent_hops = 3;
    r.session.state = .running;
    r.session.steer_accepting = true;
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"carry on\",\"request_id\":30}}}}", .{});
    try std.testing.expectEqual(@as(u8, 0), r.session.agent_hops);
}
