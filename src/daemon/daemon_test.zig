//! Dispatcher regressions tested with real sessions and client outboxes.
const std = @import("std");
const daemon_mod = @import("daemon.zig");
const proto = @import("../core/proto.zig");
const store = @import("store.zig");

test {
    std.testing.refAllDecls(daemon_mod);
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
        session.phase.store(@intFromEnum(proto.TurnPhase.approval), .release);
        session.phase_started_at_ms.store(100, .release);
        session.pending_approval_line = try proto.encode(gpa, request);
        const parked_line = session.pending_approval_line.?;
        // MCP questions park through the dispatcher while the guest reader
        // can still report tool/provider/finishing phases. None is an answer.
        for ([_]proto.TurnPhase{ .tool, .provider, .finishing }) |phase| {
            try daemon.handleEvent(.{ .turn_phase = .{ .sid = 7, .phase = phase, .started_at_ms = 200 } });
            try std.testing.expectEqual(proto.SessionState.awaiting_approval, session.state);
            try std.testing.expectEqual(@intFromEnum(proto.TurnPhase.approval), session.phase.load(.acquire));
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
