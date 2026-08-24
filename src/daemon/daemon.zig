//! marlind: the daemon. Owns all state — sessions, agent loops, the store,
//! provider connections. See docs/ARCHITECTURE.md §1.
//!
//! Thread model (M1):
//!   main thread        accept() loop on the unix socket; spawns client threads
//!   client thread ×N   reads NDJSON lines from one client, translates them
//!                      into dispatcher commands; writes fan-out messages from
//!                      its per-client outbox
//!   dispatcher thread  single consumer of the central MPSC queue; owns ALL
//!                      session state and the store; fans events out to
//!                      subscribed clients' outboxes
//!   turn thread ×M     one per running agent turn; produces events into the
//!                      central queue via loop.zig callbacks
//!
//! Ownership rules:
//!   - Store and Session structs are touched ONLY by the dispatcher thread.
//!   - Client outboxes are Mpsc(owned []u8 line); the client thread writes
//!     them to the socket and frees.
//!   - Turn threads never see sessions; they get a TurnJob value copy.

const std = @import("std");
const Io = std.Io;

const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const ids = @import("../core/ids.zig");
const config = @import("../core/config.zig");
const queue = @import("../core/queue.zig");
const store_mod = @import("store.zig");
const loop = @import("loop.zig");
const context = @import("context.zig");
const approval = @import("approval.zig");
const registry = @import("provider/registry.zig");
const http = @import("provider/http.zig");

const daemon_version = "0.0.0";

// ---------------------------------------------------------------- events --

/// Everything that flows into the dispatcher.
const Event = union(enum) {
    client_msg: struct { client_id: u64, msg_line: []u8 }, // raw NDJSON from client
    client_gone: struct { client_id: u64 },
    // From turn threads (loop.zig callbacks). All payloads gpa-owned.
    turn_block: struct { sid: u64, line: []u8 }, // pre-encoded proto.DaemonMsg.blk
    turn_delta: struct { sid: u64, line: []u8 },
    /// A tool call needs a client decision; fan out approval_request and
    /// flip session status to awaiting_approval. Line pre-encoded.
    turn_awaiting: struct { sid: u64, line: []u8 },
    /// The gate resolved; session status back to running.
    turn_resumed: struct { sid: u64 },
    turn_done: struct { sid: u64, interrupted: bool, err_text: ?[]u8, tokens_in: u64, tokens_out: u64 },
    shutdown,
};

const Client = struct {
    id: u64,
    stream: Io.net.Stream,
    outbox: queue.Mpsc([]u8),
    writer_thread: ?std.Thread = null,
    subs: std.ArrayList(u64) = .empty, // subscribed session ids
    said_hello: bool = false,

    fn subscribed(self: *const Client, sid: u64) bool {
        for (self.subs.items) |s| {
            if (s == sid) return true;
        }
        return false;
    }
};

const Session = struct {
    id: u64,
    model: []u8, // gpa-owned
    cwd: []u8, // gpa-owned
    state: proto.SessionState = .idle,
    turn_thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Approval mode fixed at creation (headless "auto" vs interactive).
    approval_mode: approval.Mode = .default,
    /// Gate the turn thread parks on for `ask` decisions.
    gate: approval.Gate = .{},
    /// L1 prune frontier (context.zig): tool_results with seq < this are
    /// stubbed at assembly. Advanced by the turn thread, read by it only —
    /// but stored here so it survives across turns. In-memory only: after a
    /// daemon restart pruning re-derives from scratch (worst case: one
    /// slightly-fatter first request).
    prune_frontier: u64 = 0,
    /// Last estimated assembled context size (tokens), for status display.
    context_used: std.atomic.Value(u64) = .init(0),
    /// Queued mid-turn steer texts (gpa-owned), drained by poll_steer.
    steer_queue: std.ArrayList([]u8) = .empty,
    steer_mutex: Io.Mutex = .init,
};

// ---------------------------------------------------------------- daemon --

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store: store_mod.Store,
    cfg: config.Config,
    events: queue.Mpsc(Event),
    clients: std.AutoHashMapUnmanaged(u64, *Client) = .empty,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    next_client_id: u64 = 1,
    running: bool = true,
    /// /reboot in flight: client id awaiting the coordinated shutdown.
    /// The daemon quiesces (waits for turns to reach done) then acks + exits.
    pending_reboot: ?u64 = null,

    // ------------------------------------------------------------- serve --

    pub fn serve(
        gpa: std.mem.Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        ready_pipe: ?Io.File,
    ) !void {
        http.globalInit();
        defer http.globalDeinit();

        // The daemon must survive its spawning terminal: autostart puts us in
        // our own process group, and we ignore SIGHUP for the case where the
        // user runs `marlin daemon` in a terminal that later goes away.
        ignoreSighup();

        const db_path = try store_mod.defaultDbPath(gpa, io, environ);
        defer gpa.free(db_path);

        var self = Daemon{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .store = try store_mod.Store.open(gpa, db_path),
            .cfg = config.defaults(),
            .events = queue.Mpsc(Event).init(gpa),
        };
        defer self.store.close();
        defer self.events.deinit();

        // Socket setup: mkdir -p, remove stale socket, listen, chmod 0600.
        const sock_path = try proto.socketPath(gpa, environ);
        defer gpa.free(sock_path);
        if (std.fs.path.dirname(sock_path)) |dir| {
            Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        Io.Dir.cwd().deleteFile(io, sock_path) catch {};

        const ua = try Io.net.UnixAddress.init(sock_path);
        var server = try ua.listen(io, .{});
        defer server.deinit(io);
        // Belt-and-braces: unix sockets are also protected by the parent dir.
        posixChmod600(sock_path);

        std.log.info("marlind listening on {s}", .{sock_path});
        // Signal readiness (autostart handshake): write one byte and close.
        if (ready_pipe) |p| {
            var wb: [1]u8 = .{'R'};
            var w = p.writer(io, &.{});
            _ = w.interface.writeAll(&wb) catch {};
            w.interface.flush() catch {};
            p.close(io);
        }

        // Dispatcher thread: consumes events, owns all state.
        const dispatcher = try std.Thread.spawn(.{}, dispatchLoop, .{&self});

        // Accept loop (main thread). Exits when the listener errors out
        // (dispatcher deletes the socket file on shutdown to unblock us).
        while (true) {
            const stream = server.accept(io) catch break;
            if (!self.running) {
                stream.close(io);
                break;
            }
            self.spawnClient(stream) catch |e| {
                std.log.warn("client setup failed: {t}", .{e});
                stream.close(io);
            };
        }

        self.events.close(io);
        dispatcher.join();
    }

    fn spawnClient(self: *Daemon, stream: Io.net.Stream) !void {
        const client = try self.gpa.create(Client);
        errdefer self.gpa.destroy(client);
        client.* = .{
            .id = self.next_client_id,
            .stream = stream,
            .outbox = queue.Mpsc([]u8).init(self.gpa),
        };
        self.next_client_id += 1;
        client.writer_thread = try std.Thread.spawn(.{}, clientWriter, .{ self, client });
        const reader_thread = try std.Thread.spawn(.{}, clientReader, .{ self, client });
        reader_thread.detach();
        // Registration in self.clients happens on the dispatcher thread via
        // the first client_msg (hello) — but fan-out needs the map earlier.
        // Simplest safe order: register through the event queue too.
        // (clientReader sends hello as its first line or the connection dies.)
        // We add to the map here under the dispatcher's ownership rule by
        // pushing a registration disguised as the first message; instead we
        // keep it simpler: the maps are ONLY touched by dispatchLoop, so we
        // push a synthetic "client_msg" carrying the pointer via id table…
        // Pragmatic M1 cut: a dedicated mutex-protected registry.
        self.registerClient(client);
    }

    // Client registry has its own tiny mutex because both the accept path
    // (add) and dispatcher (lookup/remove) touch it. Values are only
    // *mutated* by their owning threads per the rules above.
    var clients_mutex: Io.Mutex = .init;

    fn registerClient(self: *Daemon, client: *Client) void {
        clients_mutex.lockUncancelable(self.io);
        defer clients_mutex.unlock(self.io);
        self.clients.put(self.gpa, client.id, client) catch {};
    }

    fn lookupClient(self: *Daemon, id: u64) ?*Client {
        clients_mutex.lockUncancelable(self.io);
        defer clients_mutex.unlock(self.io);
        return self.clients.get(id);
    }

    fn removeClient(self: *Daemon, id: u64) ?*Client {
        clients_mutex.lockUncancelable(self.io);
        defer clients_mutex.unlock(self.io);
        const c = self.clients.get(id) orelse return null;
        _ = self.clients.remove(id);
        return c;
    }

    /// Iterate clients under the registry lock, calling f for each.
    fn forEachClient(self: *Daemon, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Client) void) void {
        clients_mutex.lockUncancelable(self.io);
        defer clients_mutex.unlock(self.io);
        var it = self.clients.valueIterator();
        while (it.next()) |cp| f(ctx, cp.*);
    }

    // ---------------------------------------------------------- client IO --

    /// Reader thread: one per client. Socket lines → event queue.
    fn clientReader(self: *Daemon, client: *Client) void {
        var rbuf: [256 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(client.stream, self.io, &rbuf);
        const r = &reader.interface;
        while (true) {
            const line = r.takeDelimiterInclusive('\n') catch break;
            const owned = self.gpa.dupe(u8, line) catch break;
            self.events.push(self.io, .{ .client_msg = .{ .client_id = client.id, .msg_line = owned } }) catch {
                self.gpa.free(owned);
                break;
            };
        }
        self.events.push(self.io, .{ .client_gone = .{ .client_id = client.id } }) catch {};
    }

    /// Writer thread: one per client. Outbox lines → socket.
    fn clientWriter(self: *Daemon, client: *Client) void {
        var wbuf: [256 * 1024]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(client.stream, self.io, &wbuf);
        const w = &writer.interface;
        while (client.outbox.pop(self.io)) |line| {
            defer self.gpa.free(line);
            w.writeAll(line) catch break;
            w.flush() catch break;
        }
        // Drain anything left after close without writing.
        while (client.outbox.tryPop(self.io)) |line| self.gpa.free(line);
    }

    fn sendTo(self: *Daemon, client: *Client, msg: proto.DaemonMsg) void {
        const line = proto.encode(self.gpa, msg) catch return;
        client.outbox.push(self.io, line) catch self.gpa.free(line);
    }

    // --------------------------------------------------------- dispatcher --

    fn dispatchLoop(self: *Daemon) void {
        while (self.events.pop(self.io)) |ev| {
            self.handleEvent(ev) catch |e| {
                std.log.warn("dispatch error: {t}", .{e});
            };
            if (!self.running) break;
        }
        self.shutdownCleanup();
    }

    fn handleEvent(self: *Daemon, ev: Event) !void {
        switch (ev) {
            .client_msg => |cm| {
                defer self.gpa.free(cm.msg_line);
                const client = self.lookupClient(cm.client_id) orelse return;
                var arena_state = std.heap.ArenaAllocator.init(self.gpa);
                defer arena_state.deinit();
                const msg = proto.decode(proto.ClientMsg, arena_state.allocator(), cm.msg_line) catch {
                    self.sendTo(client, .{ .err = .{ .code = "bad_msg", .msg = "could not parse message" } });
                    return;
                };
                try self.handleClientMsg(client, msg);
            },
            .client_gone => |cg| {
                if (self.removeClient(cg.client_id)) |client| {
                    client.outbox.close(self.io);
                    if (client.writer_thread) |t| t.join();
                    client.stream.close(self.io);
                    client.subs.deinit(self.gpa);
                    client.outbox.deinit();
                    self.gpa.destroy(client);
                }
            },
            .turn_block => |tb| {
                defer self.gpa.free(tb.line);
                self.fanOutLine(tb.sid, tb.line);
            },
            .turn_delta => |td| {
                defer self.gpa.free(td.line);
                self.fanOutLine(td.sid, td.line);
            },
            .turn_awaiting => |ta| {
                defer self.gpa.free(ta.line);
                if (self.sessions.get(ta.sid)) |session| session.state = .awaiting_approval;
                self.fanOutLine(ta.sid, ta.line);
                self.broadcastStatus(ta.sid, .awaiting_approval);
            },
            .turn_resumed => |tr| {
                if (self.sessions.get(tr.sid)) |session| session.state = .running;
                self.broadcastStatus(tr.sid, .running);
            },
            .turn_done => |td| {
                defer if (td.err_text) |t| self.gpa.free(t);
                const session = self.sessions.get(td.sid) orelse return;
                if (session.turn_thread) |t| {
                    t.join();
                    session.turn_thread = null;
                }
                session.cancel.store(false, .release);
                session.state = if (td.err_text != null) .err else .idle;
                // Meta BEFORE status: clients treat idle/err as end-of-turn
                // and stop reading, so usage must already be on the wire.
                self.broadcastMeta(td.sid, td.tokens_in, td.tokens_out);
                self.broadcastStatus(td.sid, session.state);
                // A pending /reboot proceeds once the last turn drains.
                self.maybeFinishReboot();
            },
            .shutdown => {
                self.running = false;
            },
        }
    }

    fn handleClientMsg(self: *Daemon, client: *Client, msg: proto.ClientMsg) !void {
        if (!client.said_hello and msg != .hello) {
            self.sendTo(client, .{ .err = .{ .code = "no_hello", .msg = "hello required first" } });
            return;
        }
        switch (msg) {
            .hello => |h| {
                if (h.proto_version != proto.proto_version) {
                    self.sendTo(client, .{ .err = .{ .code = "version", .msg = "protocol version mismatch" } });
                    return;
                }
                client.said_hello = true;
                self.sendTo(client, .{ .hello_ok = .{ .proto_version = proto.proto_version, .daemon_version = daemon_version } });
            },
            .session_create => |sc| {
                const sid = ids.next(self.io);
                try self.store.createSession(sid, nowMs(self.io), sc.cwd, sc.model);
                const session = try self.gpa.create(Session);
                session.* = .{
                    .id = sid,
                    .model = try self.gpa.dupe(u8, sc.model),
                    .cwd = try self.gpa.dupe(u8, sc.cwd),
                    .approval_mode = approval.Mode.parse(sc.approvals),
                };
                try self.sessions.put(self.gpa, sid, session);
                self.sendTo(client, .{ .session_created = .{ .sid = sid } });
            },
            .session_list => {
                const rows = try self.store.listSessions();
                defer {
                    for (rows) |row| row.deinit(self.gpa);
                    self.gpa.free(rows);
                }
                var infos = try self.gpa.alloc(proto.SessionInfo, rows.len);
                defer self.gpa.free(infos);
                for (rows, 0..) |row, i| {
                    const live = self.sessions.get(row.id);
                    infos[i] = .{
                        .sid = row.id,
                        .title = row.title,
                        .model = row.model,
                        .status = row.status,
                        .created_at = row.created_at,
                        .running = live != null and live.?.state == .running,
                    };
                }
                self.sendTo(client, .{ .session_list_result = .{ .sessions = infos } });
            },
            .session_kill => |sk| {
                if (self.sessions.get(sk.sid)) |session| {
                    session.cancel.store(true, .release);
                    session.gate.denyPending(self.io);
                }
                self.sendTo(client, .{ .ok = .{} });
            },
            .session_set_model => |sm| {
                const session = self.sessions.get(sm.sid) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (session.state == .running or session.state == .awaiting_approval) {
                    self.sendTo(client, .{ .err = .{ .code = "busy", .msg = "cannot switch model mid-turn" } });
                    return;
                }
                const new_model = try self.gpa.dupe(u8, sm.model);
                self.gpa.free(session.model);
                session.model = new_model;
                self.store.setSessionModel(sm.sid, sm.model) catch {};
                self.sendTo(client, .{ .ok = .{} });
            },
            .sub => |s| {
                if (!client.subscribed(s.sid)) try client.subs.append(self.gpa, s.sid);
                // Replay stored blocks from from_seq (0 = live-only).
                if (s.from_seq > 0) {
                    const loaded = try self.store.getBlocks(s.sid, s.from_seq, 1_000_000);
                    defer {
                        for (loaded) |*lb| lb.deinit();
                        self.gpa.free(loaded);
                    }
                    for (loaded) |lb| {
                        self.sendTo(client, .{ .blk = .{ .sid = s.sid, .b = lb.blk } });
                    }
                }
                const state: proto.SessionState = if (self.sessions.get(s.sid)) |ses| ses.state else .idle;
                self.sendTo(client, .{ .status = .{ .sid = s.sid, .state = state } });
            },
            .unsub => |u| {
                for (client.subs.items, 0..) |sid, i| {
                    if (sid == u.sid) {
                        _ = client.subs.swapRemove(i);
                        break;
                    }
                }
                self.sendTo(client, .{ .ok = .{} });
            },
            .input => |inp| {
                const session = self.sessions.get(inp.sid) orelse blk: {
                    // Session exists in DB but not in memory (daemon restart).
                    const row = self.store.getSession(inp.sid) catch {
                        self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                        return;
                    };
                    defer self.store.freeSession(row);
                    const session = try self.gpa.create(Session);
                    session.* = .{
                        .id = inp.sid,
                        .model = try self.gpa.dupe(u8, row.model),
                        .cwd = try self.gpa.dupe(u8, row.cwd),
                    };
                    try self.sessions.put(self.gpa, inp.sid, session);
                    break :blk session;
                };
                if (session.state == .running) {
                    // Steer: queue for the running turn.
                    const owned = try self.gpa.dupe(u8, inp.text);
                    session.steer_mutex.lockUncancelable(self.io);
                    defer session.steer_mutex.unlock(self.io);
                    try session.steer_queue.append(self.gpa, owned);
                    self.sendTo(client, .{ .ok = .{} });
                    return;
                }
                try self.startTurn(session, inp.text);
                self.sendTo(client, .{ .ok = .{} });
            },
            .approve => |a| {
                const session = self.sessions.get(a.sid) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                const id = std.fmt.parseInt(u64, a.approval_id, 10) catch {
                    self.sendTo(client, .{ .err = .{ .code = "bad_approval", .msg = "bad approval id" } });
                    return;
                };
                const verdict: approval.Verdict = switch (a.decision) {
                    .granted => .approved,
                    .denied => .denied,
                };
                // First decision wins; stale answers are ignored.
                _ = session.gate.resolve(self.io, id, verdict);
                self.sendTo(client, .{ .ok = .{} });
            },
            .session_compact => |sc| {
                const session = self.sessions.get(sc.sid) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (session.state == .running or session.state == .awaiting_approval) {
                    self.sendTo(client, .{ .err = .{ .code = "busy", .msg = "cannot compact mid-turn" } });
                    return;
                }
                if (session.turn_thread) |t| {
                    t.join();
                    session.turn_thread = null;
                }
                const job = try self.gpa.create(TurnJob);
                errdefer self.gpa.destroy(job);
                job.* = .{
                    .daemon = self,
                    .sid = session.id,
                    .cwd = try self.gpa.dupe(u8, session.cwd),
                    .model = try self.gpa.dupe(u8, session.model),
                    .text = try self.gpa.dupe(u8, ""),
                    .cancel = &session.cancel,
                    .session = session,
                };
                session.state = .running;
                session.turn_thread = try std.Thread.spawn(.{}, compactMain, .{job});
                self.broadcastStatus(session.id, .running);
                self.sendTo(client, .{ .ok = .{} });
            },
            .interrupt => |i| {
                if (self.sessions.get(i.sid)) |session| {
                    session.cancel.store(true, .release);
                    session.gate.denyPending(self.io);
                }
                self.sendTo(client, .{ .ok = .{} });
            },
            .shutdown => {
                self.sendTo(client, .{ .ok = .{} });
                self.running = false;
                // Unblock the accept loop: delete socket + connect to self is
                // overkill; closing the listener from another thread is racy.
                // Pragmatic: the accept loop checks self.running after accept;
                // we nudge it with a dummy connection from here (same process).
                self.nudgeAcceptLoop();
            },
            .reboot => |r| {
                // A reboot is a voluntary, coordinated crash (ARCHITECTURE.md
                // §self-hosting reboot). Quiesce: by default wait for running
                // turns to finish; force interrupts them (blocks are truth,
                // partial deltas are discardable).
                self.pending_reboot = client.id;
                if (r.force) {
                    var sit = self.sessions.valueIterator();
                    while (sit.next()) |sp| {
                        const session = sp.*;
                        if (session.state == .running or session.state == .awaiting_approval) {
                            session.cancel.store(true, .release);
                            session.gate.denyPending(self.io);
                        }
                    }
                }
                self.maybeFinishReboot();
            },
        }
    }

    // ------------------------------------------------------------- turns --

    const TurnJob = struct {
        daemon: *Daemon,
        sid: u64,
        cwd: []u8, // job-owned copies
        model: []u8,
        text: []u8,
        cancel: *std.atomic.Value(bool),
        session: *Session,
    };

    fn startTurn(self: *Daemon, session: *Session, text: []const u8) !void {
        const job = try self.gpa.create(TurnJob);
        errdefer self.gpa.destroy(job);
        job.* = .{
            .daemon = self,
            .sid = session.id,
            .cwd = try self.gpa.dupe(u8, session.cwd),
            .model = try self.gpa.dupe(u8, session.model),
            .text = try self.gpa.dupe(u8, text),
            .cancel = &session.cancel,
            .session = session,
        };
        session.state = .running;
        session.turn_thread = try std.Thread.spawn(.{}, turnMain, .{job});
        self.broadcastStatus(session.id, .running);
    }

    fn turnMain(job: *TurnJob) void {
        const self = job.daemon;
        defer {
            self.gpa.free(job.cwd);
            self.gpa.free(job.model);
            self.gpa.free(job.text);
            self.gpa.destroy(job);
        }

        var err_text: ?[]u8 = null;
        var tokens_in: u64 = 0;
        var tokens_out: u64 = 0;
        var interrupted = false;

        const ep = registry.resolve(self.gpa, self.environ, job.model) catch |e| {
            err_text = std.fmt.allocPrint(self.gpa, "provider resolve failed: {t}", .{e}) catch null;
            self.finishTurn(job.sid, false, err_text, 0, 0);
            return;
        };
        defer ep.deinit(self.gpa);

        // Compaction endpoint: model_compaction when configured AND
        // resolvable; otherwise the loop falls back to the main endpoint.
        var cep: ?registry.Endpoint = null;
        if (self.cfg.model_compaction) |cm| {
            cep = registry.resolve(self.gpa, self.environ, cm) catch null;
        }
        defer if (cep) |*c| c.deinit(self.gpa);

        const result = loop.runTurn(self.gpa, self.io, &self.store, .{
            .session_id = job.sid,
            .cwd = job.cwd,
            .endpoint = .{ .url = ep.url, .bearer = ep.bearer, .model = ep.model },
            .cfg = self.cfg,
            .compaction_endpoint = if (cep) |*c| .{ .url = c.url, .bearer = c.bearer, .model = c.model } else null,
            .prune_frontier = &job.session.prune_frontier,
            .context_used_out = &job.session.context_used,
            .approval_mode = job.session.approval_mode,
            .gate = &job.session.gate,
            .on_approval_needed = TurnHooks.onApprovalNeeded,
            .on_approval_done = TurnHooks.onApprovalDone,
            .on_delta = TurnHooks.onDelta,
            .on_delta_ctx = job,
            .on_block = TurnHooks.onBlock,
            .cancel = job.cancel,
            .poll_steer = TurnHooks.pollSteer,
        }, job.text) catch |e| {
            err_text = std.fmt.allocPrint(self.gpa, "turn failed: {t}", .{e}) catch null;
            self.finishTurn(job.sid, false, err_text, 0, 0);
            return;
        };
        defer self.gpa.free(result.text);
        tokens_in = result.tokens_in;
        tokens_out = result.tokens_out;
        interrupted = result.interrupted;
        self.finishTurn(job.sid, interrupted, null, tokens_in, tokens_out);
    }

    /// /compact thread body: like turnMain but runs only the compaction
    /// path. Ends with the normal turn_done bookkeeping (state → idle,
    /// meta broadcast) so clients see a coherent lifecycle.
    fn compactMain(job: *TurnJob) void {
        const self = job.daemon;
        defer {
            self.gpa.free(job.cwd);
            self.gpa.free(job.model);
            self.gpa.free(job.text);
            self.gpa.destroy(job);
        }

        const ep = registry.resolve(self.gpa, self.environ, job.model) catch |e| {
            const t = std.fmt.allocPrint(self.gpa, "provider resolve failed: {t}", .{e}) catch null;
            self.finishTurn(job.sid, false, t, 0, 0);
            return;
        };
        defer ep.deinit(self.gpa);
        var cep: ?registry.Endpoint = null;
        if (self.cfg.model_compaction) |cm| {
            cep = registry.resolve(self.gpa, self.environ, cm) catch null;
        }
        defer if (cep) |*c| c.deinit(self.gpa);

        const did = loop.compactSession(self.gpa, self.io, &self.store, .{
            .session_id = job.sid,
            .cwd = job.cwd,
            .endpoint = .{ .url = ep.url, .bearer = ep.bearer, .model = ep.model },
            .cfg = self.cfg,
            .compaction_endpoint = if (cep) |*c| .{ .url = c.url, .bearer = c.bearer, .model = c.model } else null,
            .approval_mode = .auto, // compaction runs no tools
            .on_block = TurnHooks.onBlock,
            .on_delta_ctx = job,
            .cancel = job.cancel,
        }) catch |e| {
            const t = std.fmt.allocPrint(self.gpa, "compaction failed: {t}", .{e}) catch null;
            self.finishTurn(job.sid, false, t, 0, 0);
            return;
        };
        _ = did; // "nothing to compact" already logged as a system_note
        self.finishTurn(job.sid, false, null, 0, 0);
    }

    fn finishTurn(self: *Daemon, sid: u64, interrupted: bool, err_text: ?[]u8, tin: u64, tout: u64) void {
        self.events.push(self.io, .{ .turn_done = .{
            .sid = sid,
            .interrupted = interrupted,
            .err_text = err_text,
            .tokens_in = tin,
            .tokens_out = tout,
        } }) catch {
            if (err_text) |t| self.gpa.free(t);
        };
    }

    /// Callbacks invoked ON THE TURN THREAD: encode once, push to the queue.
    /// NOTE: store writes happen on the turn thread (SQLite serialized mode
    /// handles cross-thread use; our store never shares statements).
    const TurnHooks = struct {
        fn onBlock(ctx: ?*anyopaque, b: block.Block) void {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            const line = proto.encode(self.gpa, proto.DaemonMsg{ .blk = .{ .sid = job.sid, .b = b } }) catch return;
            self.events.push(self.io, .{ .turn_block = .{ .sid = job.sid, .line = line } }) catch self.gpa.free(line);
        }

        fn onDelta(ctx: ?*anyopaque, text: []const u8) void {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            const line = proto.encode(self.gpa, proto.DaemonMsg{ .delta = .{ .sid = job.sid, .turn_id = 0, .text = text } }) catch return;
            self.events.push(self.io, .{ .turn_delta = .{ .sid = job.sid, .line = line } }) catch self.gpa.free(line);
        }

        fn pollSteer(ctx: ?*anyopaque, gpa: std.mem.Allocator) ?[]u8 {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            job.session.steer_mutex.lockUncancelable(self.io);
            defer job.session.steer_mutex.unlock(self.io);
            if (job.session.steer_queue.items.len == 0) return null;
            const text = job.session.steer_queue.orderedRemove(0);
            // Transfer to the loop's allocator (same gpa in practice).
            _ = gpa;
            return text;
        }

        fn onApprovalNeeded(ctx: ?*anyopaque, id: u64, call_id: []const u8, tool: []const u8, args_json: []const u8) void {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            var id_buf: [24]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return;
            const line = proto.encode(self.gpa, proto.DaemonMsg{ .approval_request = .{
                .sid = job.sid,
                .approval_id = id_str,
                .call_id = call_id,
                .tool = tool,
                .args_json = args_json,
            } }) catch return;
            self.events.push(self.io, .{ .turn_awaiting = .{ .sid = job.sid, .line = line } }) catch self.gpa.free(line);
        }

        fn onApprovalDone(ctx: ?*anyopaque, id: u64, verdict: approval.Verdict) void {
            _ = id;
            _ = verdict;
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            self.events.push(self.io, .{ .turn_resumed = .{ .sid = job.sid } }) catch {};
        }
    };

    // ----------------------------------------------------------- fan-out --

    const FanCtx = struct { self: *Daemon, sid: u64, line: []const u8 };

    fn fanOutLine(self: *Daemon, sid: u64, line: []const u8) void {
        const ctx = FanCtx{ .self = self, .sid = sid, .line = line };
        self.forEachClient(ctx, fanOne);
    }

    fn fanOne(ctx: FanCtx, client: *Client) void {
        if (!client.said_hello or !client.subscribed(ctx.sid)) return;
        const copy = ctx.self.gpa.dupe(u8, ctx.line) catch return;
        client.outbox.push(ctx.self.io, copy) catch ctx.self.gpa.free(copy);
    }

    fn broadcastStatus(self: *Daemon, sid: u64, state: proto.SessionState) void {
        const line = proto.encode(self.gpa, proto.DaemonMsg{ .status = .{ .sid = sid, .state = state } }) catch return;
        defer self.gpa.free(line);
        self.fanOutLine(sid, line);
    }

    fn broadcastMeta(self: *Daemon, sid: u64, tin: u64, tout: u64) void {
        var used: u64 = 0;
        var limit: u64 = 0;
        if (self.sessions.get(sid)) |session| {
            used = session.context_used.load(.acquire);
            limit = context.contextLimit(session.model);
        }
        const line = proto.encode(self.gpa, proto.DaemonMsg{ .session_meta = .{
            .sid = sid,
            .tokens_in = tin,
            .tokens_out = tout,
            .context_used = used,
            .context_limit = limit,
        } }) catch return;
        defer self.gpa.free(line);
        self.fanOutLine(sid, line);
    }

    // ---------------------------------------------------------- shutdown --

    /// Complete a pending /reboot once every session is quiescent. Sends the
    /// ok ack to the requesting client (its cue to exec the new binary),
    /// then shuts down exactly like `shutdown` — the client's autostart
    /// brings up the new binary. One restart mechanism, not two.
    fn maybeFinishReboot(self: *Daemon) void {
        const requester = self.pending_reboot orelse return;
        var sit = self.sessions.valueIterator();
        while (sit.next()) |sp| {
            const state = sp.*.state;
            if (state == .running or state == .awaiting_approval) return; // not yet
        }
        self.pending_reboot = null;
        if (self.lookupClient(requester)) |client| {
            self.sendTo(client, .{ .ok = .{} });
        }
        self.running = false;
        self.nudgeAcceptLoop();
    }

    fn nudgeAcceptLoop(self: *Daemon) void {
        const sock_path = proto.socketPath(self.gpa, self.environ) catch return;
        defer self.gpa.free(sock_path);
        const ua = Io.net.UnixAddress.init(sock_path) catch return;
        const s = ua.connect(self.io) catch return;
        s.close(self.io);
    }

    fn shutdownCleanup(self: *Daemon) void {
        // Cancel running turns and join them.
        var sit = self.sessions.valueIterator();
        while (sit.next()) |sp| {
            const session = sp.*;
            session.cancel.store(true, .release);
            session.gate.denyPending(self.io);
            if (session.turn_thread) |t| t.join();
            session.steer_mutex.lockUncancelable(self.io);
            for (session.steer_queue.items) |s| self.gpa.free(s);
            session.steer_queue.deinit(self.gpa);
            session.steer_mutex.unlock(self.io);
            self.gpa.free(session.model);
            self.gpa.free(session.cwd);
            self.gpa.destroy(session);
        }
        self.sessions.deinit(self.gpa);

        // Close all client outboxes; writer threads exit, readers hit EOF.
        clients_mutex.lockUncancelable(self.io);
        var cit = self.clients.valueIterator();
        while (cit.next()) |cp| {
            const client = cp.*;
            client.outbox.close(self.io);
            if (client.writer_thread) |t| t.join();
            client.stream.close(self.io);
            client.subs.deinit(self.gpa);
            client.outbox.deinit();
            self.gpa.destroy(client);
        }
        self.clients.deinit(self.gpa);
        clients_mutex.unlock(self.io);

        // Remove the socket so the (blocked) accept loop errors out.
        const sock_path = proto.socketPath(self.gpa, self.environ) catch return;
        defer self.gpa.free(sock_path);
        Io.Dir.cwd().deleteFile(self.io, sock_path) catch {};
    }
};

fn ignoreSighup() void {
    if (std.posix.Sigaction == void) return;
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.HUP, &act, null);
}

fn posixChmod600(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.c.chmod(buf[0..path.len :0], 0o600);
}

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

test {
    std.testing.refAllDecls(@This());
}
