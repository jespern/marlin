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
    daemon.outgoing = null;
    daemon.predecessor_fd = -1;
    daemon.predecessor_reader = null;
    daemon.handed_over = false;
    daemon.web_deferred = false;
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
    daemon.outgoing = null;
    daemon.predecessor_fd = -1;
    daemon.predecessor_reader = null;
    daemon.handed_over = false;
    daemon.web_deferred = false;
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
    daemon.outgoing = null;
    daemon.predecessor_fd = -1;
    daemon.predecessor_reader = null;
    daemon.handed_over = false;
    daemon.web_deferred = false;
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
        // One literal, so every field the rig does not name takes its
        // declared default: assigned one by one, the rest held whatever the
        // allocation did (a stale voice_setup_thread refused /voice setup
        // on the Linux CI runner only).
        r.daemon = .{
            .gpa = gpa,
            .io = io,
            .environ = &r.environ,
            .events = .init(gpa),
            .clients = .empty,
            .clients_mutex = .init,
            .phone_push = null,
            .mcp_stale = .empty,
            .sessions = .empty,
            .shells = .empty,
            .agent_waits = .empty,
            .next_shell_id = 1,
            .store = try store.Store.open(gpa, null),
            .cfg = .{},
            .network = .{ .gpa = gpa },
            .advertiser = null,
            .sandbox_backend = .unavailable,
            .presence = .{},
            .pending_reboot = null,
            .outgoing = null,
            .predecessor_fd = -1,
            .predecessor_reader = null,
            .handed_over = false,
            .web_deferred = false,
            // Not reached by these tests.
            .extensions = undefined,
            .http_pool = undefined,
        };
        const d = &r.daemon;
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
        for (r.daemon.mcp_stale.items) |name| gpa.free(name);
        r.daemon.mcp_stale.deinit(gpa);
        r.session.live_text.deinit(gpa);
        r.session.live_reasoning.deinit(gpa);
        r.session.agent_hops_from.deinit(gpa);
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

// Case: Jesper typed `!!` on his phone while the terminal showed the same
// session; the terminal followed it into the shell and took the size, and
// the phone drew a 120-column screen in tiny type.
test "attaching to a shell someone else is viewing leaves its size until you type" {
    const r = try ShellRig.create();
    defer r.destroy();

    try r.send(2, "{{\"shell_open\":{{\"request_id\":3,\"sid\":7,\"cols\":44,\"rows\":30,\"follow_size\":true}}}}", .{});
    const shell_id = (try r.drain(2))[0].shell_opened.shell_id;
    const host = r.daemon.shells.get(shell_id).?;

    // The terminal follows the session into the shell: the phone keeps it.
    try r.send(1, "{{\"shell_attach\":{{\"request_id\":4,\"shell_id\":{d},\"cols\":120,\"rows\":40}}}}", .{shell_id});
    _ = try r.drain(1);
    try std.testing.expectEqual(@as(u16, 44), host.geometry.cols);
    for (try r.drain(2)) |msg| try std.testing.expect(msg != .shell_resized);

    // Typing at the terminal takes it.
    try r.send(1, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"Cg==\"}}}}", .{shell_id});
    try std.testing.expectEqual(@as(u16, 120), host.geometry.cols);

    // With the phone gone, attaching alone takes the size at once.
    try r.send(2, "{{\"shell_input\":{{\"shell_id\":{d},\"data_base64\":\"Cg==\"}}}}", .{shell_id});
    try r.send(2, "{{\"shell_detach\":{{\"shell_id\":{d}}}}}", .{shell_id});
    try r.send(1, "{{\"shell_detach\":{{\"shell_id\":{d}}}}}", .{shell_id});
    try std.testing.expectEqual(@as(u16, 44), host.geometry.cols);
    try r.send(1, "{{\"shell_attach\":{{\"request_id\":5,\"shell_id\":{d},\"cols\":120,\"rows\":40}}}}", .{shell_id});
    try std.testing.expectEqual(@as(u16, 120), host.geometry.cols);
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

// Case: Jesper queued a message on his phone mid-turn, switched tabs and came
// back: it was gone until the turn took it. The queue is the daemon's, so
// every client shows it, and any of them can take an entry back.
test "a session's queued input reaches every client, and any client can take it back" {
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    defer {
        for (r.session.steer_queue.items) |queued| queued.input.deinit(gpa);
        r.session.steer_queue.deinit(gpa);
    }
    const Queue = struct {
        /// The last queue snapshot client `id` was sent, if any.
        fn last(rig: *ShellRig, id: u64) !?[]const proto.QueuedInput {
            var items: ?[]const proto.QueuedInput = null;
            for (try rig.drain(id)) |msg| if (msg == .queued) {
                try std.testing.expectEqual(@as(u64, 7), msg.queued.sid);
                items = msg.queued.items;
            };
            return items;
        }
        fn reply(rig: *ShellRig, id: u64) !proto.DaemonMsg {
            for (try rig.drain(id)) |msg| if (msg == .ok or msg == .err) return msg;
            return error.NoReply;
        }
    };
    r.session.state = .running;
    r.session.steer_accepting = true;
    try r.send(1, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    try r.send(2, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    // Nothing queued: a subscribe brings no snapshot.
    try std.testing.expectEqual(@as(?[]const proto.QueuedInput, null), try Queue.last(r, 2));
    _ = try r.drain(1);

    // Queued from the phone: the terminal sees it at once.
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"also run the tests\",\"request_id\":5}}}}", .{});
    const seen = (try Queue.last(r, 1)).?;
    try std.testing.expectEqual(@as(usize, 1), seen.len);
    try std.testing.expectEqualStrings("also run the tests", seen[0].input.text);
    const id = seen[0].id;
    _ = try r.drain(2);

    // The phone comes back to the session: the queue comes with it.
    try r.send(2, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    try std.testing.expectEqual(id, (try Queue.last(r, 2)).?[0].id);

    // Taken back from the terminal: the phone's queue empties.
    try r.send(1, "{{\"unqueue\":{{\"sid\":7,\"id\":{d},\"request_id\":6}}}}", .{id});
    try std.testing.expectEqual(@as(usize, 0), (try Queue.last(r, 2)).?.len);
    try std.testing.expectEqual(@as(usize, 0), r.session.steer_queue.items.len);
    try std.testing.expect(try Queue.reply(r, 1) == .ok);
    // Again, or after the turn took it: already gone.
    try r.send(1, "{{\"unqueue\":{{\"sid\":7,\"id\":{d},\"request_id\":7}}}}", .{id});
    try std.testing.expect(try Queue.reply(r, 1) == .err);

    // The turn takes one: its message arrives first, then the shorter queue,
    // so the queued card becomes the message without a gap.
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"taken\",\"request_id\":10}}}}", .{});
    _ = try r.drain(1);
    const taken = r.session.steer_queue.orderedRemove(0).input;
    const b = @import("../core/block.zig").Block{ .id = 1, .session_id = 7, .turn_id = 1, .seq = 1, .ts = 0, .body = .{ .steer = taken } };
    const line = try proto.encode(gpa, proto.DaemonMsg{ .blk = .{ .sid = 7, .b = b } });
    taken.deinit(gpa);
    try r.daemon.handleEvent(.{ .turn_block = .{ .sid = 7, .line = line, .steer = true } });
    const after = try r.drain(1);
    try std.testing.expectEqual(@as(usize, 2), after.len);
    try std.testing.expect(after[0] == .blk);
    try std.testing.expectEqual(@as(usize, 0), after[1].queued.items.len);
    _ = try r.drain(2);

    // A pause keeps the queue for /resume; it still shows, and still goes.
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"after the pause\",\"request_id\":8}}}}", .{});
    _ = try r.drain(1);
    _ = try r.drain(2);
    try r.send(1, "{{\"session_pause\":{{\"sid\":7}}}}", .{});
    try std.testing.expectEqual(@as(usize, 0), r.session.steer_queue.items.len);
    try r.send(2, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    const held = (try Queue.last(r, 2)).?;
    try std.testing.expectEqualStrings("after the pause", held[0].input.text);
    try r.send(2, "{{\"unqueue\":{{\"sid\":7,\"id\":{d},\"request_id\":9}}}}", .{held[0].id});
    try std.testing.expectEqual(@as(usize, 0), (try Queue.last(r, 1)).?.len);
    try std.testing.expect(!try r.daemon.store.hasPausedInputs(7));
}

// Case: Jesper queued a message on his phone while Claude Code worked; the ×
// answered "already sent" yet the card stayed. Claude Code had it on stdin but
// reads it only at its next step. Until then it shows as sent, with no ×.
test "a queued input a guest took but has not read shows as sent, not cancellable" {
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    defer {
        for (r.session.steer_queue.items) |queued| queued.input.deinit(gpa);
        r.session.steer_queue.deinit(gpa);
        for (r.session.steer_sent.items) |queued| queued.input.deinit(gpa);
        r.session.steer_sent.deinit(gpa);
    }
    r.session.state = .running;
    r.session.steer_accepting = true;
    try r.send(1, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"also run the tests\",\"request_id\":5}}}}", .{});
    _ = try r.drain(1);
    _ = try r.drain(2);

    // Claude Code's input pump takes it and writes it to the guest's stdin.
    const taken = r.daemon.takeQueuedInput(&r.session).?;
    defer taken.deinit(gpa);
    try r.daemon.handleEvent(.{ .queue_changed = 7 });
    var shown: ?[]const proto.QueuedInput = null;
    for (try r.drain(1)) |msg| if (msg == .queued) {
        shown = msg.queued.items;
    };
    try std.testing.expectEqual(@as(usize, 1), shown.?.len);
    try std.testing.expect(shown.?[0].sent);
    try std.testing.expectEqualStrings("also run the tests", shown.?[0].input.text);

    // Taking it back is refused, and says why.
    try r.send(1, "{{\"unqueue\":{{\"sid\":7,\"id\":{d},\"request_id\":6}}}}", .{shown.?[0].id});
    var refused = false;
    for (try r.drain(1)) |msg| if (msg == .err) {
        try std.testing.expectEqualStrings("already sent: the agent reads it at its next step", msg.err.msg);
        refused = true;
    };
    try std.testing.expect(refused);

    // A subscriber arriving now sees it too.
    try r.send(2, "{{\"sub\":{{\"sid\":7,\"tail_limit\":10}}}}", .{});
    var late: ?[]const proto.QueuedInput = null;
    for (try r.drain(2)) |msg| if (msg == .queued) {
        late = msg.queued.items;
    };
    try std.testing.expect(late.?[0].sent);

    // Claude Code echoes it: the steer block retires it and the queue empties.
    r.daemon.retireSentInput(&r.session, taken.text);
    const b = @import("../core/block.zig").Block{ .id = 1, .session_id = 7, .turn_id = 1, .seq = 1, .ts = 0, .body = .{ .steer = taken } };
    const line = try proto.encode(gpa, proto.DaemonMsg{ .blk = .{ .sid = 7, .b = b } });
    try r.daemon.handleEvent(.{ .turn_block = .{ .sid = 7, .line = line, .steer = true } });
    const after = try r.drain(1);
    try std.testing.expect(after[0] == .blk);
    try std.testing.expectEqual(@as(usize, 0), after[1].queued.items.len);
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
    // The refusal itself on failure, not just `false` (CI-only on Linux).
    try std.testing.expectEqualStrings("", (try Wait.reply(r, .voice_setup_result)).msg);
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
        for (other.steer_queue.items) |queued| queued.input.deinit(gpa);
        other.steer_queue.deinit(gpa);
        for (r.session.steer_queue.items) |queued| queued.input.deinit(gpa);
        r.session.steer_queue.deinit(gpa);
        other.live_text.deinit(gpa);
        other.live_reasoning.deinit(gpa);
        other.agent_hops_from.deinit(gpa);
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
    const delivered = other.steer_queue.items[0].input.text;
    try std.testing.expect(std.mem.startsWith(u8, delivered, "[Message from another Marlin session"));
    try std.testing.expect(std.mem.indexOf(u8, delivered, caller_handle) != null);
    try std.testing.expect(std.mem.endsWith(u8, delivered, "Is the lexer done?"));
    // It lands in a turn the user started: their reply stays as it is.
    try std.testing.expect(std.mem.indexOf(u8, delivered, @import("tools/sessions.zig").brief_close) == null);
    // The receiver's transcript folds it under the sender, showing their words.
    try std.testing.expectEqualStrings("Is the lexer done?", other.steer_queue.items[0].input.display_text.?);
    try std.testing.expect(std.mem.indexOf(u8, other.steer_queue.items[0].input.from.?, caller_handle) != null);
    // Its turn keeps its own chain; a message back to us would go on ours.
    try std.testing.expectEqual(@as(u8, 0), other.agent_hops);
    try std.testing.expectEqual(@as(?u8, 1), other.agent_hops_from.get(7));

    // A chain at the hop limit stops.
    r.session.agent_hops = @import("tools/sessions.zig").max_hops;
    try Call.send(r, 7, 5, "message_session", .{ .handle = handle, .text = "again" });
    try std.testing.expectEqual(block_mod.ToolStatus.denied, (try Call.result(r, 5)).?.status);
    try std.testing.expectEqual(@as(usize, 1), other.steer_queue.items.len);
    r.session.agent_hops = 0;

    // How many messages a session sends is not capped (it once was, at 10).
    for (0..15) |i| {
        try Call.send(r, 7, 100 + i, "message_session", .{ .handle = handle, .text = "more" });
        try std.testing.expectEqual(block_mod.ToolStatus.ok, (try Call.result(r, 100 + i)).?.status);
    }
    try std.testing.expectEqual(@as(usize, 16), other.steer_queue.items.len);

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

    // A message to a session parked in wait_for_session ends its wait: it
    // reads the message next instead of holding it (and everything else
    // queued for it) until the other turn ends. Case: steward waited on
    // chat while chat sent it message after message, and the user's tab
    // could do nothing.
    const Wake = struct {
        /// The answers to requests `a` and `b` on client 1, from one drain.
        fn results(rig: *ShellRig, a: u64, b: u64) ![2]?@FieldType(proto.DaemonMsg, "agent_tool_result") {
            var out: [2]?@FieldType(proto.DaemonMsg, "agent_tool_result") = .{ null, null };
            for (try rig.drain(1)) |msg| if (msg == .agent_tool_result) {
                if (msg.agent_tool_result.request_id == a) out[0] = msg.agent_tool_result;
                if (msg.agent_tool_result.request_id == b) out[1] = msg.agent_tool_result;
            };
            return out;
        }
    };
    r.session.state = .running;
    r.session.steer_accepting = true;
    try Call.send(r, 7, 11, "wait_for_session", .{ .handle = handle });
    try std.testing.expect(try Call.result(r, 11) == null);
    try Call.send(r, 8, 12, "message_session", .{ .handle = caller_handle, .text = "Hold the release." });
    const woken = try Wake.results(r, 11, 12);
    try std.testing.expectEqual(block_mod.ToolStatus.ok, woken[1].?.status);
    try std.testing.expectEqual(block_mod.ToolStatus.ok, woken[0].?.status);
    try std.testing.expect(std.mem.startsWith(u8, woken[0].?.output, "Stopped waiting on "));
    try std.testing.expect(std.mem.indexOf(u8, woken[0].?.output, handle[0..8]) != null);
    try std.testing.expectEqual(@as(usize, 0), r.daemon.agent_waits.items.len);
    // So does the user typing into it.
    try Call.send(r, 7, 13, "wait_for_session", .{ .handle = handle });
    try std.testing.expect(try Call.result(r, 13) == null);
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"what now?\",\"request_id\":31}}}}", .{});
    const typed = (try Call.result(r, 13)).?;
    try std.testing.expect(std.mem.indexOf(u8, typed.output, "the user sent you a message") != null);
    try std.testing.expectEqual(@as(usize, 0), r.daemon.agent_waits.items.len);
    // A message to some other session leaves the wait alone.
    try Call.send(r, 7, 14, "wait_for_session", .{ .handle = handle });
    try Call.send(r, 7, 15, "message_session", .{ .handle = handle, .text = "Still there?" });
    const unrelated = try Wake.results(r, 14, 15);
    try std.testing.expect(unrelated[0] == null);
    try std.testing.expectEqual(block_mod.ToolStatus.ok, unrelated[1].?.status);
    try std.testing.expectEqual(@as(usize, 1), r.daemon.agent_waits.items.len);
    r.session.state = .idle;
    try r.send(2, "{{\"interrupt\":{{\"sid\":7}}}}", .{});
    _ = try Call.result(r, 14);

    // A human speaking starts the chain over.
    r.session.agent_hops = 3;
    r.session.state = .running;
    r.session.steer_accepting = true;
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"carry on\",\"request_id\":30}}}}", .{});
    try std.testing.expectEqual(@as(u8, 0), r.session.agent_hops);
}

// Case (2026-11-23): Jesper's steward, in a turn he started, read replies
// from workers deep in their own chains, and was then refused messages to
// everyone. A reply mid-turn counts only toward messages back to its sender.
test "a reply that arrives mid-turn counts only toward its sender" {
    const session_handle = @import("../core/session_handle.zig");
    const sessions_tool = @import("tools/sessions.zig");
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    var others: [2]daemon_mod.Session = undefined;
    for (&others, [_]u64{ 8, 9 }) |*other, sid| {
        try r.daemon.store.createSession(sid, 0, "/other", "codex/gpt", .auto);
        other.* = .{ .id = sid, .model = try gpa.dupe(u8, "codex/gpt"), .cwd = try gpa.dupe(u8, "/other"), .state = .running, .steer_accepting = true };
        try r.daemon.sessions.put(gpa, sid, other);
    }
    defer for (&others) |*other| {
        for (other.steer_queue.items) |queued| queued.input.deinit(gpa);
        other.steer_queue.deinit(gpa);
        other.agent_hops_from.deinit(gpa);
        other.live_text.deinit(gpa);
        other.live_reasoning.deinit(gpa);
        gpa.free(other.model);
        gpa.free(other.cwd);
    };
    defer {
        for (r.session.steer_queue.items) |queued| queued.input.deinit(gpa);
        r.session.steer_queue.deinit(gpa);
    }
    var buf: session_handle.Full = undefined;
    const all = [_]u64{ 7, 8, 9 };
    const handles = [_][]const u8{
        try r.arena.allocator().dupe(u8, session_handle.display(&buf, 7, &all)),
        try r.arena.allocator().dupe(u8, session_handle.display(&buf, 8, &all)),
        try r.arena.allocator().dupe(u8, session_handle.display(&buf, 9, &all)),
    };
    const Call = struct {
        fn status(rig: *ShellRig, caller: u64, request_id: u64, to: []const u8) !block_mod.ToolStatus {
            const args_json = try std.json.Stringify.valueAlloc(rig.gpa, .{ .handle = to, .text = "update" }, .{});
            defer rig.gpa.free(args_json);
            const msg = try std.json.Stringify.valueAlloc(rig.gpa, .{ .agent_tool = .{ .request_id = request_id, .sid = caller, .name = "message_session", .args_json = args_json } }, .{});
            defer rig.gpa.free(msg);
            try rig.send(1, "{s}", .{msg});
            for (try rig.drain(1)) |got| if (got == .agent_tool_result and got.agent_tool_result.request_id == request_id) return got.agent_tool_result.status;
            return error.NoResult;
        }
    };

    // Jesper's turn (7) hears from 8, whose chain is at the limit.
    r.session.state = .running;
    r.session.steer_accepting = true;
    others[0].agent_hops = sessions_tool.max_hops - 1;
    try std.testing.expectEqual(block_mod.ToolStatus.ok, try Call.status(r, 8, 1, handles[0]));
    // 9 has nothing to do with that chain.
    try std.testing.expectEqual(block_mod.ToolStatus.ok, try Call.status(r, 7, 2, handles[2]));
    try std.testing.expectEqual(@as(u8, 0), r.session.agent_hops);
    // Answering 8 would go on its chain: two agents still can't ping-pong.
    try std.testing.expectEqual(block_mod.ToolStatus.denied, try Call.status(r, 7, 3, handles[1]));
    // Jesper speaking starts every chain over.
    try r.send(2, "{{\"input\":{{\"sid\":7,\"text\":\"answer it\",\"request_id\":30}}}}", .{});
    try std.testing.expectEqual(block_mod.ToolStatus.ok, try Call.status(r, 7, 4, handles[1]));
}

// Case: Robin, Jesper's assistant outside Marlin, routes what needs him and
// can answer it. It reads the attention log, hears when it grows, answers a
// waiting question and approval, and messages a session as itself.
test "an assistant outside Marlin reads the attention log and answers what waits" {
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    defer {
        for (r.session.steer_queue.items) |queued| queued.input.deinit(gpa);
        r.session.steer_queue.deinit(gpa);
    }
    const Call = struct {
        fn send(rig: *ShellRig, caller: u64, outside: []const u8, request_id: u64, name: []const u8, args: anytype) !void {
            const args_json = try std.json.Stringify.valueAlloc(rig.gpa, args, .{});
            defer rig.gpa.free(args_json);
            const msg = try std.json.Stringify.valueAlloc(rig.gpa, .{ .agent_tool = .{ .request_id = request_id, .sid = caller, .caller = outside, .name = name, .args_json = args_json } }, .{});
            defer rig.gpa.free(msg);
            try rig.send(1, "{s}", .{msg});
        }
        fn result(rig: *ShellRig, id: u64) !@FieldType(proto.DaemonMsg, "agent_tool_result") {
            for (try rig.drain(1)) |msg| if (msg == .agent_tool_result and msg.agent_tool_result.request_id == id) return msg.agent_tool_result;
            return error.NoResult;
        }
        fn events(rig: *ShellRig, id: u64, after: u64) !std.json.Value {
            try send(rig, 0, "robin", id, "attention", .{ .after = after });
            const got = try result(rig, id);
            try std.testing.expectEqual(block_mod.ToolStatus.ok, got.status);
            return (try std.json.parseFromSliceLeaky(std.json.Value, rig.arena.allocator(), got.output, .{})).object.get("events").?;
        }
    };
    try r.send(1, "{{\"attention_watch\":{{}}}}", .{});

    // A session's agent asks a question through its bridge (client 2).
    try r.send(2, "{{\"cc_question\":{{\"sid\":7,\"question\":\"Which colour?\",\"options_json\":\"[\\\"red\\\",\\\"blue\\\"]\"}}}}", .{});
    var woken = false;
    for (try r.drain(1)) |msg| if (msg == .attention) {
        woken = true;
    };
    try std.testing.expect(woken);
    const asked = (try Call.events(r, 1, 0)).array.items;
    try std.testing.expectEqual(@as(usize, 1), asked.len);
    const question = asked[0].object;
    try std.testing.expectEqualStrings("question", question.get("kind").?.string);
    try std.testing.expectEqualStrings("Which colour?", question.get("question").?.string);
    const question_id = question.get("question_id").?.string;
    const handle = question.get("handle").?.string;

    // Sessions don't answer each other's prompts or read the log.
    try Call.send(r, 7, "", 2, "attention", .{});
    try std.testing.expectEqual(block_mod.ToolStatus.err, (try Call.result(r, 2)).status);
    // An outside call names its caller.
    try Call.send(r, 0, "", 3, "sessions", .{});
    try std.testing.expectEqual(block_mod.ToolStatus.err, (try Call.result(r, 3)).status);

    // The wrong question is refused; the right one reaches the bridge, and
    // the log says it stopped waiting.
    try Call.send(r, 0, "robin", 4, "answer", .{ .handle = handle, .question_id = "123", .answer = "red" });
    try std.testing.expectEqual(block_mod.ToolStatus.err, (try Call.result(r, 4)).status);
    try Call.send(r, 0, "robin", 5, "answer", .{ .handle = handle, .question_id = question_id, .answer = "blue" });
    try std.testing.expectEqual(block_mod.ToolStatus.ok, (try Call.result(r, 5)).status);
    var answered: ?[]const u8 = null;
    for (try r.drain(2)) |msg| if (msg == .cc_question_result) {
        answered = msg.cc_question_result.answer;
    };
    try std.testing.expectEqualStrings("blue", answered.?);
    const resolved = (try Call.events(r, 6, 1)).array.items;
    try std.testing.expectEqualStrings("resolved", resolved[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings(question_id, resolved[0].object.get("question_id").?.string);

    // An approval outside the session's folder waits; Robin denies it.
    gpa.free(r.session.cwd);
    r.session.cwd = try gpa.dupe(u8, "/tmp/marlin-outside-test");
    try r.send(2, "{{\"cc_approval\":{{\"sid\":7,\"tool\":\"Write\",\"args_json\":\"{{\\\"file_path\\\":\\\"/etc/marlin-test\\\",\\\"content\\\":\\\"x\\\"}}\"}}}}", .{});
    const waiting = (try Call.events(r, 7, 2)).array.items;
    try std.testing.expectEqualStrings("approval", waiting[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("Write", waiting[0].object.get("tool").?.string);
    try std.testing.expectEqualStrings("/etc/marlin-test", waiting[0].object.get("args").?.object.get("file_path").?.string);
    try Call.send(r, 0, "robin", 8, "approve", .{ .handle = handle, .approval_id = waiting[0].object.get("approval_id").?.string, .decision = "deny" });
    try std.testing.expectEqual(block_mod.ToolStatus.ok, (try Call.result(r, 8)).status);
    var decided: ?proto.ApprovalAnswer = null;
    for (try r.drain(2)) |msg| if (msg == .cc_approval_result) {
        decided = msg.cc_approval_result.decision;
    };
    try std.testing.expectEqual(proto.ApprovalAnswer.denied, decided.?);
    // Answered once is answered.
    try Call.send(r, 0, "robin", 9, "approve", .{ .handle = handle, .approval_id = waiting[0].object.get("approval_id").?.string, .decision = "allow" });
    try std.testing.expectEqual(block_mod.ToolStatus.err, (try Call.result(r, 9)).status);

    // Robin sees every session and writes as itself; it has no turn, so no
    // per-turn limit, and starts a chain at hop 1.
    try Call.send(r, 0, "robin", 10, "sessions", .{});
    try std.testing.expect(std.mem.startsWith(u8, (try Call.result(r, 10)).output, "Marlin sessions:"));
    r.session.state = .running;
    r.session.steer_accepting = true;
    try Call.send(r, 0, "robin", 11, "message_session", .{ .handle = handle, .text = "Status?" });
    try std.testing.expectEqual(block_mod.ToolStatus.ok, (try Call.result(r, 11)).status);
    const delivered = r.session.steer_queue.items[0].input.text;
    try std.testing.expect(std.mem.startsWith(u8, delivered, "[Message from robin, the user's assistant outside Marlin."));
    try std.testing.expect(std.mem.endsWith(u8, delivered, "Status?"));
    // Robin is no session to answer, so the running turn's chain is untouched.
    try std.testing.expectEqual(@as(u8, 0), r.session.agent_hops);
    try std.testing.expectEqual(@as(u32, 0), r.session.agent_hops_from.count());

    // `last` reads the newest moments.
    try Call.send(r, 0, "robin", 12, "attention", .{ .last = 1 });
    const newest = try std.json.parseFromSliceLeaky(std.json.Value, r.arena.allocator(), (try Call.result(r, 12)).output, .{});
    try std.testing.expectEqual(@as(usize, 1), newest.object.get("events").?.array.items.len);
    try std.testing.expectEqual(newest.object.get("latest").?.integer, newest.object.get("events").?.array.items[0].object.get("seq").?.integer);
}

// Turns borrow the tool list a refresh replaces: a server that changes its
// tools mid-turn is re-listed once no turn runs, as /mcp restart waits too.
test "a changed MCP server is re-listed only once no turn is running" {
    const r = try ShellRig.create();
    defer r.destroy();
    const gpa = r.gpa;
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    const config = @import("../core/config.zig");
    const cfg = config.Config{ .mcp_servers = &.{
        .{ .name = "grow", .cmd = &.{ "sh", "-c", @import("tools/mcp_test.zig").changing_server }, .mutating = true },
    } };
    const runtime = try @import("extensions.zig").Runtime.init(gpa, r.threaded.io(), cfg, &environ);
    defer runtime.deinit();
    r.daemon.extensions = runtime;
    const out = runtime.dispatch("mcp__grow__add", "{}", "/", null).?;
    gpa.free(out.output);

    r.session.state = .running;
    for (0..2) |_| try r.daemon.handleEvent(.{ .mcp_tools_changed = .{ .name = try gpa.dupe(u8, "grow") } });
    r.daemon.refreshMcpWhenIdle();
    try std.testing.expect(runtime.find("mcp__grow__added") == null);
    try std.testing.expectEqual(@as(usize, 1), r.daemon.mcp_stale.items.len); // once, not twice

    r.session.state = .idle;
    r.daemon.refreshMcpWhenIdle();
    try std.testing.expect(runtime.find("mcp__grow__added") != null);
    try std.testing.expectEqual(@as(usize, 0), r.daemon.mcp_stale.items.len);
}

test "session_group and session_move store the tab order and broadcast every open root" {
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
    // One literal, so unnamed fields take their defaults (see ShellRig).
    var daemon: daemon_mod.Daemon = .{
        .gpa = gpa,
        .io = io,
        .environ = &environ,
        .events = .init(gpa),
        .clients = .empty,
        .clients_mutex = .init,
        .phone_push = null,
        .mcp_stale = .empty,
        .sessions = .empty,
        .shells = .empty,
        .agent_waits = .empty,
        .next_shell_id = 1,
        .store = try store.Store.open(gpa, null),
        .cfg = .{},
        .network = .{ .gpa = gpa },
        .advertiser = null,
        .sandbox_backend = .unavailable,
        .presence = .{},
        .pending_reboot = null,
        .outgoing = null,
        .predecessor_fd = -1,
        .predecessor_reader = null,
        .handed_over = false,
        .web_deferred = false,
        // Not reached by this test.
        .extensions = undefined,
        .http_pool = undefined,
    };
    defer daemon.store.close();
    defer daemon.clients.deinit(gpa);
    defer daemon.sessions.deinit(gpa);
    defer daemon.events.deinit();
    // Directories that do not exist group by their path.
    for ([_][]const u8{ "/nowhere/a", "/nowhere/b", "/nowhere/a", "/nowhere/b" }, 1..) |cwd, sid|
        try daemon.store.createSession(sid, @intCast(sid), cwd, "m", .auto);
    var mover = daemon_mod.Client{ .id = 1, .stream = stream, .outbox = .init(gpa), .said_hello = true };
    var watcher = daemon_mod.Client{
        .id = 2,
        .stream = stream,
        .outbox = .init(gpa),
        .said_hello = true,
        .watches_sessions = true,
        .watches_session_deltas = true,
    };
    defer for ([_]*daemon_mod.Client{ &mover, &watcher }) |client| {
        while (client.outbox.tryPop(io)) |line| gpa.free(line.bytes);
        client.outbox.deinit();
    };
    try daemon.clients.put(gpa, mover.id, &mover);
    try daemon.clients.put(gpa, watcher.id, &watcher);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ranks: [5]i64 = @splat(0);
    for ([_]proto.ClientMsg{
        .{ .session_group = .{} },
        .{ .session_move = .{ .sid = 4, .before_sid = 1 } },
    }, [_][4]i64{ .{ 1, 3, 2, 4 }, .{ 2, 4, 3, 1 } }) |request, expected| {
        const line = try proto.encode(gpa, request);
        try daemon.handleEvent(.{ .client_msg = .{ .client_id = mover.id, .msg_line = line } });
        const reply = mover.outbox.tryPop(io).?;
        defer gpa.free(reply.bytes);
        try std.testing.expect(try proto.decode(proto.DaemonMsg, arena, try arena.dupe(u8, reply.bytes)) == .ok);
        while (watcher.outbox.tryPop(io)) |update| {
            defer gpa.free(update.bytes);
            const msg = try proto.decode(proto.DaemonMsg, arena, try arena.dupe(u8, update.bytes));
            if (msg == .session_upsert) ranks[msg.session_upsert.session.sid] = msg.session_upsert.session.tab_order;
        }
        try std.testing.expectEqualSlices(i64, &expected, ranks[1..]);
    }

    const child = try proto.encode(gpa, proto.ClientMsg{ .session_move = .{ .sid = 99 } });
    try daemon.handleEvent(.{ .client_msg = .{ .client_id = mover.id, .msg_line = child } });
    const refused = mover.outbox.tryPop(io).?;
    defer gpa.free(refused.bytes);
    const err = try proto.decode(proto.DaemonMsg, arena, try arena.dupe(u8, refused.bytes));
    try std.testing.expectEqualStrings("no_session", err.err.code);
}

test "/group keeps each group where its first tab was and tabs in order within it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const order = try daemon_mod.groupedTabOrder(
        arena.allocator(),
        &.{ 1, 2, 3, 4, 5, 6 },
        &.{ "robin", "marlin", "robin", "/tmp", "marlin", "robin" },
    );
    try std.testing.expectEqualSlices(u64, &.{ 1, 3, 6, 2, 5, 4 }, order);
}
