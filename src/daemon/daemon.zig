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
const build_options = @import("build_options");
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
const permissions = @import("permissions.zig");
const sandbox = @import("sandbox.zig");
const network_policy = @import("network_policy.zig");
const extensions = @import("extensions.zig");
const registry = @import("provider/registry.zig");
const http = @import("provider/http.zig");
const task_tool = @import("tools/task.zig");
const tools_registry = @import("tools/registry.zig");

const daemon_version = build_options.version;

// ---------------------------------------------------------------- events --

const ChildStart = struct {
    parent_sid: u64,
    parent_block_id: u64,
    prompt: []u8,
    model: ?[]u8,
    effort: ?proto.ReasoningEffort,
    max_rounds: u32,
    future: *TaskFuture,
};

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
    /// Model catalog fetched by a worker thread (raw registry-form ids,
    /// one allocation each, gpa-owned; dispatcher takes ownership).
    catalog_ready: struct { client_id: u64, models: [][]u8 },
    /// Turn thread → dispatcher completion. final_text and err_text are
    /// separately owned because child task results serialize both fields.
    turn_done: struct { sid: u64, interrupted: bool, err_text: ?[]u8, final_text: ?[]u8, tokens_in: u64, tokens_out: u64 },
    /// Parent turn thread → dispatcher. All strings are gpa-owned; `future`
    /// points into the parked parent turn's stack until resolve().
    child_start: ChildStart,
    shutdown,
};

const Client = struct {
    id: u64,
    stream: Io.net.Stream,
    outbox: queue.Mpsc([]u8),
    writer_thread: ?std.Thread = null,
    subs: std.ArrayList(u64) = .empty, // subscribed session ids
    said_hello: bool = false,
    /// Receives refreshed session-list snapshots without subscribing to every
    /// session's block stream (M4 multiplexer/background activity contract).
    watches_sessions: bool = false,

    fn subscribed(self: *const Client, sid: u64) bool {
        for (self.subs.items) |s| {
            if (s == sid) return true;
        }
        return false;
    }
};

const TaskFuture = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    done: bool = false,
    output: ?[]u8 = null,
    status: block.ToolStatus = .err,

    fn wait(self: *TaskFuture, io: Io) tools_registry.ExecOut {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.done) self.cond.waitUncancelable(io, &self.mutex);
        return .{ .output = self.output.?, .status = self.status };
    }

    /// Result ownership transfers to the waiting turn on success.
    fn resolve(self: *TaskFuture, io: Io, output: []u8, status: block.ToolStatus) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.done) return false;
        self.output = output;
        self.status = status;
        self.done = true;
        self.cond.signal(io);
        return true;
    }
};

const Session = struct {
    id: u64,
    parent_sid: ?u64 = null,
    kind: proto.SessionKind = .root,
    parent_block_id: ?u64 = null,
    max_rounds: u32 = 32,
    archived: bool = false,
    model: []u8, // gpa-owned
    effort: proto.ReasoningEffort = .auto,
    cwd: []u8, // gpa-owned
    state: proto.SessionState = .idle,
    turn_thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Approval mode fixed at creation (headless "auto" vs interactive).
    approval_mode: approval.Mode = .default,
    /// Kernel shell sandbox + prompt-free shell execution (/sandbox).
    /// Seeded from cfg.permissions_enabled; effective only with a verified
    /// backend. In-memory like approval_mode: a daemon restart returns the
    /// session to the configured default.
    sandbox_enabled: bool = false,
    /// Per-session gate for the daemon-global managed-tool hostname policy.
    /// A restart restores the default: enabled when blocking rules loaded.
    network_filtering_enabled: bool = false,
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
    /// Non-null only while a task child is running for a parked parent call.
    task_waiter: ?*TaskFuture = null,
};

// ---------------------------------------------------------------- daemon --

pub const Daemon = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    store: store_mod.Store,
    cfg: config.Config,
    extensions: *extensions.Runtime,
    network: network_policy.Policy,
    sandbox_backend: sandbox.Backend = .unavailable,
    /// Non-null exactly when sandbox_backend is .seatbelt: the profile's
    /// protected-read denials are parameterized on these roots.
    protected_roots: ?sandbox.ProtectedRoots = null,
    events: queue.Mpsc(Event),
    clients: std.AutoHashMapUnmanaged(u64, *Client) = .empty,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    next_client_id: u64 = 1,
    running: bool = true,
    /// /reboot in flight: client id awaiting the coordinated shutdown.
    /// The daemon quiesces (waits for turns to reach done) then acks + exits.
    pending_reboot: ?u64 = null,
    /// Model catalog cache (registry-form ids, gpa-owned). Refreshed at
    /// most once per catalog_ttl_ms; fetch runs on a worker thread.
    catalog: std.ArrayList([]u8) = .empty,
    catalog_fetched_at: i64 = 0,
    catalog_fetching: bool = false,

    const catalog_ttl_ms: i64 = 60 * 60 * 1000; // 1h

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
        var opened_store = try store_mod.Store.open(gpa, db_path);
        var store_moved = false;
        errdefer if (!store_moved) opened_store.close();
        // Provider streams are not resumable across daemon death. Keep their
        // durable session hierarchy and mark the abandoned lifecycle honestly.
        try opened_store.recoverInterruptedSessions();

        var loaded_config = try config.load(gpa, io, environ);
        defer loaded_config.deinit();
        const cfg = loaded_config.value;
        const extension_runtime = try extensions.Runtime.init(gpa, io, cfg, environ);
        defer extension_runtime.deinit();
        const network = network_policy.Policy.init(gpa, io, environ, .{
            .blocklists = cfg.network_blocklists,
            .allow = cfg.network_allow,
            .deny = cfg.network_deny,
        });
        var probe_environ: ?std.process.Environ.Map = null;
        defer if (probe_environ) |*env| env.deinit();
        // Probe unconditionally: the canary is cheap, and a verified backend
        // is what lets /sandbox enable enforcement later without re-probing.
        // cfg.permissions_enabled only seeds each session's default.
        var sandbox_backend: sandbox.Backend = blk: {
            probe_environ = permissions.toolEnvironment(gpa, environ) catch break :blk .unavailable;
            break :blk sandbox.verifySeatbelt(gpa, io, &probe_environ.?);
        };

        // A verified backend without resolvable protected roots cannot honor
        // the protected-path contract, so it must not claim enforcement.
        var protected_roots: ?sandbox.ProtectedRoots = null;
        defer if (protected_roots) |*roots| roots.deinit(gpa);
        if (sandbox_backend == .seatbelt) {
            protected_roots = sandbox.resolveProtectedRoots(gpa, io, environ) catch null;
            if (protected_roots == null) sandbox_backend = .unavailable;
        }
        std.log.info("shell sandbox {s}; new sessions {s}", .{
            switch (sandbox_backend) {
                .seatbelt => @as([]const u8, "verified (seatbelt)"),
                .unavailable => "unavailable",
            },
            if (cfg.permissions_enabled and sandbox_backend == .seatbelt)
                @as([]const u8, "run workspace shell without prompts")
            else
                "keep per-call shell approvals",
        });
        std.log.info("network filtering {s}: {d} rules from {d} feeds (managed tools only)", .{
            if (network.isActive()) @as([]const u8, "active") else "inactive",
            network.ruleCount(),
            network.feedCount(),
        });

        var self = Daemon{
            .gpa = gpa,
            .io = io,
            .environ = environ,
            .store = opened_store,
            .cfg = cfg,
            .extensions = extension_runtime,
            .network = network,
            .sandbox_backend = sandbox_backend,
            .protected_roots = protected_roots,
            .events = queue.Mpsc(Event).init(gpa),
        };
        store_moved = true;
        defer self.store.close();
        defer self.events.deinit();
        defer self.network.deinit();

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
                if (self.sessions.get(ta.sid)) |session| {
                    session.state = .awaiting_approval;
                    self.store.setSessionStatus(ta.sid, "awaiting_approval") catch {};
                }
                self.fanOutActionableLine(ta.sid, ta.line);
                self.broadcastStatus(ta.sid, .awaiting_approval);
            },
            .turn_resumed => |tr| {
                if (self.sessions.get(tr.sid)) |session| {
                    session.state = .running;
                    self.store.setSessionStatus(tr.sid, "running") catch {};
                }
                self.broadcastStatus(tr.sid, .running);
            },
            .catalog_ready => |cr| {
                // Replace the cache (dispatcher owns it now).
                for (self.catalog.items) |m| self.gpa.free(m);
                self.catalog.clearRetainingCapacity();
                for (cr.models) |m| self.catalog.append(self.gpa, m) catch self.gpa.free(m);
                self.gpa.free(cr.models);
                self.catalog_fetched_at = nowMs(self.io);
                self.catalog_fetching = false;
                if (self.lookupClient(cr.client_id)) |client| self.sendCatalog(client);
            },
            .turn_done => |td| {
                defer if (td.err_text) |t| self.gpa.free(t);
                defer if (td.final_text) |t| self.gpa.free(t);
                const session = self.sessions.get(td.sid) orelse return;
                if (session.turn_thread) |t| {
                    t.join();
                    session.turn_thread = null;
                }
                session.cancel.store(false, .release);
                session.state = if (td.err_text != null) .err else .idle;
                self.store.setSessionStatus(td.sid, @tagName(session.state)) catch {};
                // Meta BEFORE status: clients treat idle/err as end-of-turn
                // and stop reading, so usage must already be on the wire.
                self.broadcastMeta(td.sid, td.tokens_in, td.tokens_out);
                self.broadcastStatus(td.sid, session.state);
                const payload = std.json.Stringify.valueAlloc(self.gpa, .{
                    .sid = td.sid,
                    .interrupted = td.interrupted,
                    .ok = td.err_text == null,
                    .error_message = td.err_text,
                    .tokens_in = td.tokens_in,
                    .tokens_out = td.tokens_out,
                }, .{}) catch null;
                if (payload) |json| {
                    defer self.gpa.free(json);
                    self.extensions.fireHook(.on_turn_done, json);
                    self.extensions.fireHook(.on_session_done, json);
                    if (td.err_text != null) self.extensions.fireHook(.on_error, json);
                }
                // A child is an ordinary durable session plus this one-shot
                // rendezvous back to the parent tool call.
                if (session.task_waiter) |future| {
                    session.task_waiter = null;
                    const outcome_status: block.ToolStatus = if (td.interrupted)
                        .interrupted
                    else if (td.err_text != null)
                        .err
                    else
                        .ok;
                    const result_json = std.json.Stringify.valueAlloc(self.gpa, .{
                        .child_sid = td.sid,
                        .status = if (td.interrupted)
                            @as([]const u8, "interrupted")
                        else if (td.err_text != null)
                            "error"
                        else
                            "completed",
                        .final_text = td.final_text orelse "",
                        .error_message = td.err_text,
                    }, .{}) catch self.gpa.dupe(u8, "error: could not encode child result") catch @panic("oom");
                    if (!future.resolve(self.io, result_json, outcome_status)) self.gpa.free(result_json);
                }
                // A pending /reboot proceeds once the last turn drains.
                self.maybeFinishReboot();
            },
            .child_start => |cs| {
                defer self.gpa.free(cs.prompt);
                defer if (cs.model) |m| self.gpa.free(m);
                self.startChild(cs) catch |e| {
                    const output = std.fmt.allocPrint(self.gpa, "error: could not start child session: {t}", .{e}) catch @panic("oom");
                    if (!cs.future.resolve(self.io, output, .err)) self.gpa.free(output);
                };
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
                self.sendTo(client, .{ .hello_ok = .{
                    .proto_version = proto.proto_version,
                    .daemon_version = daemon_version,
                    .sandbox_available = self.sandbox_backend == .seatbelt,
                    .network_filtering = self.network.isActive(),
                    .network_configured = config.networkPolicyConfigured(self.cfg),
                    .network_feed_count = self.network.feedCount(),
                    .network_rule_count = self.network.ruleCount(),
                } });
            },
            .session_create => |sc| {
                const sid = ids.next(self.io);
                try self.store.createSession(sid, nowMs(self.io), sc.cwd, sc.model, sc.effort);
                const session = try self.gpa.create(Session);
                session.* = .{
                    .id = sid,
                    .model = try self.gpa.dupe(u8, sc.model),
                    .effort = sc.effort,
                    .cwd = try self.gpa.dupe(u8, sc.cwd),
                    .approval_mode = approval.Mode.parse(sc.approvals),
                    .sandbox_enabled = self.cfg.permissions_enabled,
                    .network_filtering_enabled = self.network.isActive(),
                };
                try self.sessions.put(self.gpa, sid, session);
                self.sendTo(client, .{ .session_created = .{ .sid = sid } });
                self.broadcastSessionList();
            },
            .session_list => |sl| try self.sendSessionList(client, sl.include_archived),
            .session_watch => {
                client.watches_sessions = true;
                try self.sendSessionList(client, false);
            },
            .session_kill => |sk| {
                self.cancelSessionTree(sk.sid);
                self.sendTo(client, .{ .ok = .{} });
            },
            .session_archive => |sa| {
                _ = (try self.getOrLoadSession(sa.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (sa.archived and self.sessionTreeBusy(sa.sid)) {
                    self.sendTo(client, .{ .err = .{ .code = "busy", .msg = "cannot archive a running session tree" } });
                    return;
                }
                self.store.setSessionTreeArchived(sa.sid, if (sa.archived) nowMs(self.io) else null) catch {
                    self.sendTo(client, .{ .err = .{ .code = "store", .msg = "could not update session archive state" } });
                    return;
                };
                self.markLoadedSessionTreeArchived(sa.sid, sa.archived);
                self.sendTo(client, .{ .ok = .{} });
                self.broadcastSessionList();
            },
            .session_set_model => |sm| {
                const session = (try self.getOrLoadSession(sm.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (self.rejectArchivedSession(client, session)) return;
                if (session.state == .running or session.state == .awaiting_approval) {
                    self.sendTo(client, .{ .err = .{ .code = "busy", .msg = "cannot switch model mid-turn" } });
                    return;
                }
                const new_model = try self.gpa.dupe(u8, sm.model);
                self.gpa.free(session.model);
                session.model = new_model;
                self.store.setSessionModel(sm.sid, sm.model) catch {};
                self.sendTo(client, .{ .ok = .{} });
                self.broadcastSessionList();
            },
            .session_set_effort => |se| {
                const session = (try self.getOrLoadSession(se.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (self.rejectArchivedSession(client, session)) return;
                if (session.state == .running or session.state == .awaiting_approval) {
                    self.sendTo(client, .{ .err = .{ .code = "busy", .msg = "cannot switch effort mid-turn" } });
                    return;
                }
                session.effort = se.effort;
                self.store.setSessionEffort(se.sid, se.effort) catch {};
                self.sendTo(client, .{ .ok = .{} });
                self.broadcastSessionList();
            },
            .session_set_sandbox => |ss| {
                const session = (try self.getOrLoadSession(ss.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (self.rejectArchivedSession(client, session)) return;
                if (session.state == .running or session.state == .awaiting_approval) {
                    self.sendTo(client, .{ .err = .{ .code = "busy", .msg = "cannot toggle sandbox mid-turn" } });
                    return;
                }
                if (ss.enabled and self.sandbox_backend != .seatbelt) {
                    self.sendTo(client, .{ .err = .{
                        .code = "sandbox_unavailable",
                        .msg = "platform sandbox not verified on this daemon; per-call approvals retained",
                    } });
                    return;
                }
                session.sandbox_enabled = ss.enabled;
                self.sendTo(client, .{ .ok = .{} });
                self.broadcastSessionList();
            },
            .session_set_network_filtering => |sn| {
                const session = (try self.getOrLoadSession(sn.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (self.rejectArchivedSession(client, session)) return;
                if (session.state == .running or session.state == .awaiting_approval) {
                    self.sendTo(client, .{ .err = .{ .code = "busy", .msg = "cannot toggle network filtering mid-turn" } });
                    return;
                }
                if (sn.enabled and !self.network.isActive()) {
                    self.sendTo(client, .{ .err = .{
                        .code = "network_filter_unavailable",
                        .msg = if (config.networkPolicyConfigured(self.cfg))
                            "network policy is configured but no blocking rules loaded; reboot after connectivity returns"
                        else
                            "no network blocklist or explicit deny rules configured; update config and reboot",
                    } });
                    return;
                }
                session.network_filtering_enabled = sn.enabled;
                self.sendTo(client, .{ .ok = .{} });
                self.broadcastSessionList();
            },
            .blob_get => |bg| {
                const bytes = self.store.getBlob(bg.hash) catch |err| {
                    self.sendTo(client, .{ .err = .{
                        .code = "blob",
                        .msg = if (err == error.NotFound) "full tool output expired or missing" else "could not read full tool output",
                    } });
                    return;
                };
                defer self.gpa.free(bytes);
                self.sendTo(client, .{ .blob_result = .{ .hash = bg.hash, .bytes = bytes } });
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
                const session = (try self.getOrLoadSession(inp.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (self.rejectArchivedSession(client, session)) return;
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
                const session = (try self.getOrLoadSession(sc.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                if (self.rejectArchivedSession(client, session)) return;
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
                    .effort = session.effort,
                    .text = try self.gpa.dupe(u8, ""),
                    .cancel = &session.cancel,
                    .session = session,
                };
                session.state = .running;
                session.turn_thread = try std.Thread.spawn(.{}, compactMain, .{job});
                self.store.setSessionStatus(session.id, "running") catch {};
                self.broadcastStatus(session.id, .running);
                self.sendTo(client, .{ .ok = .{} });
            },
            .model_list => {
                // Fresh cache → answer immediately.
                if (self.catalog.items.len > 0 and nowMs(self.io) - self.catalog_fetched_at < catalog_ttl_ms) {
                    self.sendCatalog(client);
                    return;
                }
                // Stale/empty → kick a fetch thread (one at a time); the
                // reply goes out when catalog_ready lands. A second client
                // asking mid-fetch gets whatever cache exists (possibly
                // empty = favorites fallback) rather than queueing.
                if (self.catalog_fetching) {
                    self.sendCatalog(client);
                    return;
                }
                self.catalog_fetching = true;
                const t = std.Thread.spawn(.{}, catalogFetchMain, .{ self, client.id }) catch {
                    self.catalog_fetching = false;
                    self.sendCatalog(client);
                    return;
                };
                t.detach();
            },
            .interrupt => |i| {
                self.cancelSessionTree(i.sid);
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

    /// Sessions are loaded lazily after daemon restart. Settings and manual
    /// compaction must work before the first new input, not only after the
    /// input path happens to rehydrate the row.
    fn getOrLoadSession(self: *Daemon, sid: u64) !?*Session {
        if (self.sessions.get(sid)) |session| return session;
        const row = self.store.getSession(sid) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        defer self.store.freeSession(row);

        const session = try self.gpa.create(Session);
        errdefer self.gpa.destroy(session);
        const model = try self.gpa.dupe(u8, row.model);
        errdefer self.gpa.free(model);
        const cwd = try self.gpa.dupe(u8, row.cwd);
        errdefer self.gpa.free(cwd);
        session.* = .{
            .id = sid,
            .parent_sid = row.parent_sid,
            .kind = row.kind,
            .parent_block_id = row.parent_block_id,
            .max_rounds = if (row.max_rounds > 0) row.max_rounds else 32,
            .archived = row.archived,
            .model = model,
            .effort = row.effort,
            .cwd = cwd,
            .sandbox_enabled = self.cfg.permissions_enabled,
            .network_filtering_enabled = self.network.isActive(),
        };
        try self.sessions.put(self.gpa, sid, session);
        return session;
    }

    fn rejectArchivedSession(self: *Daemon, client: *Client, session: *const Session) bool {
        if (!session.archived) return false;
        self.sendTo(client, .{ .err = .{
            .code = "archived",
            .msg = "unarchive the session before modifying it",
        } });
        return true;
    }

    fn cancelSessionTree(self: *Daemon, sid: u64) void {
        if (self.sessions.get(sid)) |session| cancelActiveSession(self, session);
        // Nesting is deliberately limited to one level in this M6 slice.
        // Keeping the relation scan here makes the cascade explicit and easy
        // to generalize when deeper task trees become a product decision.
        var it = self.sessions.valueIterator();
        while (it.next()) |sp| {
            const child = sp.*;
            if (child.parent_sid == sid) cancelActiveSession(self, child);
        }
    }

    fn loadedSessionBelongsToTree(self: *Daemon, session: *const Session, root_sid: u64) bool {
        var cursor: ?u64 = session.id;
        while (cursor) |candidate_sid| {
            if (candidate_sid == root_sid) return true;
            const candidate = self.sessions.get(candidate_sid) orelse return false;
            cursor = candidate.parent_sid;
        }
        return false;
    }

    fn sessionTreeBusy(self: *Daemon, sid: u64) bool {
        var it = self.sessions.valueIterator();
        while (it.next()) |sp| {
            const session = sp.*;
            if (!self.loadedSessionBelongsToTree(session, sid)) continue;
            if (session.state == .running or session.state == .awaiting_approval) return true;
        }
        return false;
    }

    fn markLoadedSessionTreeArchived(self: *Daemon, sid: u64, archived: bool) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |sp| {
            const session = sp.*;
            if (self.loadedSessionBelongsToTree(session, sid)) session.archived = archived;
        }
    }

    /// Dispatcher-only child creation. The caller is a parent turn thread,
    /// but it reaches this function solely through Event.child_start.
    fn startChild(self: *Daemon, cs: ChildStart) !void {
        const parent = self.sessions.get(cs.parent_sid) orelse return error.ParentSessionMissing;
        if (parent.kind != .root) return error.NestedTaskDenied;
        if (parent.archived) return error.ParentSessionArchived;
        if (parent.cancel.load(.acquire)) return error.Cancelled;

        const sid = ids.next(self.io);
        const model_src = cs.model orelse parent.model;
        const effort = cs.effort orelse parent.effort;
        const title = taskTitle(cs.prompt);

        const session = try self.gpa.create(Session);
        var session_transferred = false;
        errdefer if (!session_transferred) self.gpa.destroy(session);
        const model = try self.gpa.dupe(u8, model_src);
        errdefer if (!session_transferred) self.gpa.free(model);
        const cwd = try self.gpa.dupe(u8, parent.cwd);
        errdefer if (!session_transferred) self.gpa.free(cwd);
        session.* = .{
            .id = sid,
            .parent_sid = parent.id,
            .kind = .task_child,
            .parent_block_id = cs.parent_block_id,
            .max_rounds = cs.max_rounds,
            .model = model,
            .effort = effort,
            .cwd = cwd,
            .approval_mode = .default,
            .sandbox_enabled = parent.sandbox_enabled,
            .network_filtering_enabled = parent.network_filtering_enabled,
            .task_waiter = cs.future,
        };

        try self.store.createChildSession(
            sid,
            nowMs(self.io),
            parent.id,
            cs.parent_block_id,
            title,
            parent.cwd,
            model_src,
            effort,
            cs.max_rounds,
        );
        try self.sessions.put(self.gpa, sid, session);
        session_transferred = true;
        self.startTurn(session, cs.prompt) catch |e| {
            session.task_waiter = null;
            session.state = .err;
            self.store.setSessionStatus(sid, "err") catch {};
            self.broadcastSessionList();
            return e;
        };
    }

    // ------------------------------------------------------------- turns --

    const TurnJob = struct {
        daemon: *Daemon,
        sid: u64,
        cwd: []u8, // job-owned copies
        model: []u8,
        effort: proto.ReasoningEffort,
        text: []u8,
        cancel: *std.atomic.Value(bool),
        session: *Session,
    };

    fn startTurn(self: *Daemon, session: *Session, text: []const u8) !void {
        const job = try self.gpa.create(TurnJob);
        errdefer self.gpa.destroy(job);
        const cwd = try self.gpa.dupe(u8, session.cwd);
        errdefer self.gpa.free(cwd);
        const model = try self.gpa.dupe(u8, session.model);
        errdefer self.gpa.free(model);
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        job.* = .{
            .daemon = self,
            .sid = session.id,
            .cwd = cwd,
            .model = model,
            .effort = session.effort,
            .text = owned_text,
            .cancel = &session.cancel,
            .session = session,
        };
        const thread = try std.Thread.spawn(.{}, turnMain, .{job});
        session.turn_thread = thread;
        session.state = .running;
        self.store.setSessionStatus(session.id, "running") catch {};
        self.broadcastStatus(session.id, .running);
    }

    /// A turn that dies before the loop runs would leave no blocks at all —
    /// the session looks inexplicably blank when inspected (worst for task
    /// children, whose transcript is the only evidence of what happened).
    /// Persist the submitted prompt and a failure note so the log tells the
    /// story; runs on the turn thread like the loop's own block appends.
    fn persistFailedTurn(self: *Daemon, job: *TurnJob, note: []const u8) void {
        const turn_id = ids.next(self.io);
        var seq = self.store.lastSeq(job.sid) catch return;
        const bodies = [_]block.Body{
            .{ .user_msg = .{ .text = job.text } },
            .{ .system_note = .{ .text = note } },
        };
        for (bodies) |body| {
            seq += 1;
            const b = block.Block{
                .id = ids.next(self.io),
                .session_id = job.sid,
                .turn_id = turn_id,
                .seq = seq,
                .ts = nowMs(self.io),
                .body = body,
            };
            self.store.appendBlock(b) catch return;
            TurnHooks.onBlock(job, b);
        }
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
            err_text = std.fmt.allocPrint(self.gpa, "provider resolve failed for model '{s}': {t}", .{ job.model, e }) catch null;
            self.persistFailedTurn(job, err_text orelse "provider resolve failed");
            self.finishTurn(job.sid, false, err_text, null, 0, 0);
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

        var sandbox_temp: ?[]u8 = null;
        defer if (sandbox_temp) |path| self.gpa.free(path);
        var sandbox_options = sandbox.Options{};
        if (self.sandbox_backend == .seatbelt and job.session.sandbox_enabled) {
            const tmp_root = self.environ.get("TMPDIR") orelse "/private/tmp";
            sandbox_temp = std.fmt.allocPrint(self.gpa, "{s}{c}marlin-tools{c}{d}", .{
                std.mem.trimEnd(u8, tmp_root, std.fs.path.sep_str),
                std.fs.path.sep,
                std.fs.path.sep,
                job.sid,
            }) catch null;
            if (sandbox_temp) |path| {
                Io.Dir.cwd().createDirPath(self.io, path) catch {
                    self.gpa.free(path);
                    sandbox_temp = null;
                };
            }
            if (sandbox_temp) |path| sandbox_options = .{
                .backend = .seatbelt,
                .temp_root = path,
                .protected = self.protected_roots,
            };
        }

        const result = loop.runTurn(self.gpa, self.io, &self.store, .{
            .session_id = job.sid,
            .cwd = job.cwd,
            .endpoint = .{ .url = ep.url, .bearer = ep.bearer, .model = ep.model, .dialect = ep.dialect },
            .effort = job.effort,
            .cfg = self.cfg,
            .tool_environ = self.environ,
            .sandbox_options = sandbox_options,
            .network_policy = if (job.session.network_filtering_enabled) &self.network else null,
            .extensions = self.extensions,
            .compaction_endpoint = if (cep) |*c| .{ .url = c.url, .bearer = c.bearer, .model = c.model, .dialect = c.dialect } else null,
            .prune_frontier = &job.session.prune_frontier,
            .context_used_out = &job.session.context_used,
            .approval_mode = job.session.approval_mode,
            .gate = &job.session.gate,
            .on_approval_needed = TurnHooks.onApprovalNeeded,
            .on_approval_done = TurnHooks.onApprovalDone,
            .on_delta = TurnHooks.onDelta,
            .on_delta_ctx = job,
            .on_block = TurnHooks.onBlock,
            .on_task = if (job.session.kind == .root) TurnHooks.onTask else null,
            .tool_profile = if (job.session.kind == .root) .full else .read_only,
            .cancel = job.cancel,
            .poll_steer = TurnHooks.pollSteer,
            .max_rounds = job.session.max_rounds,
        }, job.text) catch |e| {
            err_text = std.fmt.allocPrint(self.gpa, "turn failed: {t}", .{e}) catch null;
            self.finishTurn(job.sid, false, err_text, null, 0, 0);
            return;
        };
        tokens_in = result.tokens_in;
        tokens_out = result.tokens_out;
        interrupted = result.interrupted;
        self.finishTurn(job.sid, interrupted, null, result.text, tokens_in, tokens_out);
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
            self.finishTurn(job.sid, false, t, null, 0, 0);
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
            .endpoint = .{ .url = ep.url, .bearer = ep.bearer, .model = ep.model, .dialect = ep.dialect },
            .effort = .auto,
            .cfg = self.cfg,
            .extensions = self.extensions,
            .compaction_endpoint = if (cep) |*c| .{ .url = c.url, .bearer = c.bearer, .model = c.model, .dialect = c.dialect } else null,
            .approval_mode = .auto, // compaction runs no tools
            .on_block = TurnHooks.onBlock,
            .on_delta_ctx = job,
            .cancel = job.cancel,
        }) catch |e| {
            const t = std.fmt.allocPrint(self.gpa, "compaction failed: {t}", .{e}) catch null;
            self.finishTurn(job.sid, false, t, null, 0, 0);
            return;
        };
        _ = did; // "nothing to compact" already logged as a system_note
        self.finishTurn(job.sid, false, null, null, 0, 0);
    }

    fn finishTurn(self: *Daemon, sid: u64, interrupted: bool, err_text: ?[]u8, final_text: ?[]u8, tin: u64, tout: u64) void {
        self.events.push(self.io, .{ .turn_done = .{
            .sid = sid,
            .interrupted = interrupted,
            .err_text = err_text,
            .final_text = final_text,
            .tokens_in = tin,
            .tokens_out = tout,
        } }) catch {
            if (err_text) |t| self.gpa.free(t);
            if (final_text) |t| self.gpa.free(t);
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

        fn onTask(ctx: ?*anyopaque, parent_block_id: u64, args_json: []const u8) tools_registry.ExecOut {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            if (job.session.kind != .root) return taskError(self.gpa, "nested task calls are disabled");

            const parsed = std.json.parseFromSlice(task_tool.Args, self.gpa, args_json, .{
                .ignore_unknown_fields = false,
            }) catch return taskError(self.gpa, "task arguments do not match the schema");
            defer parsed.deinit();
            const args = parsed.value;
            if (std.mem.trim(u8, args.prompt, " \t\r\n").len == 0)
                return taskError(self.gpa, "task prompt must not be empty");
            if (args.max_rounds == 0 or args.max_rounds > 32)
                return taskError(self.gpa, "task max_rounds must be between 1 and 32");

            // Validate a requested model BEFORE creating the child: an
            // unresolvable model would otherwise die pre-loop and leave a
            // blank err-state session behind (observed with a bare model
            // name like "gpt-5.3-codex" — registry ids are provider-prefixed).
            if (args.model) |m| {
                if (registry.resolve(self.gpa, self.environ, m)) |probe| {
                    probe.deinit(self.gpa);
                } else |e| {
                    const msg = std.fmt.allocPrint(
                        self.gpa,
                        "task model '{s}' is not resolvable ({t}); use a registry-form id like 'openrouter/anthropic/claude-sonnet-4.5' or omit model to inherit this session's",
                        .{ m, e },
                    ) catch return taskError(self.gpa, "out of memory");
                    defer self.gpa.free(msg);
                    return taskError(self.gpa, msg);
                }
            }

            const prompt = self.gpa.dupe(u8, args.prompt) catch return taskError(self.gpa, "out of memory");
            var model: ?[]u8 = null;
            if (args.model) |m| {
                if (m.len == 0) {
                    self.gpa.free(prompt);
                    return taskError(self.gpa, "task model must not be empty");
                }
                model = self.gpa.dupe(u8, m) catch {
                    self.gpa.free(prompt);
                    return taskError(self.gpa, "out of memory");
                };
            }

            var future = TaskFuture{};
            self.events.push(self.io, .{ .child_start = .{
                .parent_sid = job.sid,
                .parent_block_id = parent_block_id,
                .prompt = prompt,
                .model = model,
                .effort = args.effort,
                .max_rounds = args.max_rounds,
                .future = &future,
            } }) catch {
                self.gpa.free(prompt);
                if (model) |m| self.gpa.free(m);
                return taskError(self.gpa, "daemon is shutting down");
            };
            return future.wait(self.io);
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
            const payload = std.json.Stringify.valueAlloc(self.gpa, .{
                .sid = job.sid,
                .approval_id = id,
                .call_id = call_id,
                .tool = tool,
                .args_json = args_json,
            }, .{}) catch return;
            defer self.gpa.free(payload);
            self.extensions.fireHook(.on_approval_needed, payload);
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

    /// Approval requests are actionable multiplexer state, not transcript
    /// traffic: session-watch clients receive them even when that session is
    /// not focused/subscribed, so switching to it presents the real card.
    fn fanOutActionableLine(self: *Daemon, sid: u64, line: []const u8) void {
        const ctx = FanCtx{ .self = self, .sid = sid, .line = line };
        self.forEachClient(ctx, struct {
            fn send(c: FanCtx, client: *Client) void {
                if (!client.said_hello or (!client.subscribed(c.sid) and !client.watches_sessions)) return;
                const copy = c.self.gpa.dupe(u8, c.line) catch return;
                client.outbox.push(c.self.io, copy) catch c.self.gpa.free(copy);
            }
        }.send);
    }

    fn broadcastStatus(self: *Daemon, sid: u64, state: proto.SessionState) void {
        const line = proto.encode(self.gpa, proto.DaemonMsg{ .status = .{ .sid = sid, .state = state } }) catch return;
        defer self.gpa.free(line);
        self.fanOutLine(sid, line);
        self.broadcastSessionList();
    }

    fn sendSessionList(self: *Daemon, client: *Client, include_archived: bool) !void {
        const rows = try self.store.listSessions(include_archived);
        defer {
            for (rows) |row| row.deinit(self.gpa);
            self.gpa.free(rows);
        }
        const infos = try self.gpa.alloc(proto.SessionInfo, rows.len);
        defer self.gpa.free(infos);
        for (rows, 0..) |row, i| {
            const live = self.sessions.get(row.id);
            const state = if (live) |session|
                session.state
            else
                std.meta.stringToEnum(proto.SessionState, row.status) orelse .idle;
            infos[i] = .{
                .sid = row.id,
                .parent_sid = row.parent_sid,
                .kind = row.kind,
                .parent_block_id = row.parent_block_id,
                .max_rounds = row.max_rounds,
                .title = row.title,
                .cwd = row.cwd,
                .model = row.model,
                .effort = row.effort,
                .status = row.status,
                .state = state,
                .created_at = row.created_at,
                .running = state == .running,
                .sandboxed = self.sandbox_backend == .seatbelt and
                    (if (live) |session| session.sandbox_enabled else self.cfg.permissions_enabled),
                .network_filtering = self.network.isActive() and
                    (if (live) |session| session.network_filtering_enabled else true),
                .archived = row.archived,
            };
        }
        self.sendTo(client, .{ .session_list_result = .{ .sessions = infos } });
    }

    fn broadcastSessionList(self: *Daemon) void {
        var it = self.clients.valueIterator();
        while (it.next()) |cp| {
            const client = cp.*;
            if (!client.said_hello or !client.watches_sessions) continue;
            self.sendSessionList(client, false) catch {};
        }
    }

    /// Send the current catalog (possibly empty → client falls back to
    /// favorites).
    fn sendCatalog(self: *Daemon, client: *Client) void {
        const models = self.gpa.alloc([]const u8, self.catalog.items.len) catch return;
        defer self.gpa.free(models);
        for (self.catalog.items, 0..) |m, i| models[i] = m;
        self.sendTo(client, .{ .model_list_result = .{ .models = models } });
    }

    /// Worker thread: GET /models from OpenRouter, parse ids, hand the
    /// result to the dispatcher. Failure → empty list (client falls back).
    fn catalogFetchMain(self: *Daemon, client_id: u64) void {
        const models = self.fetchCatalog() catch
            self.gpa.alloc([]u8, 0) catch return;
        self.events.push(self.io, .{ .catalog_ready = .{ .client_id = client_id, .models = models } }) catch {
            for (models) |m| self.gpa.free(m);
            self.gpa.free(models);
        };
    }

    fn fetchCatalog(self: *Daemon) ![][]u8 {
        const url = try registry.openrouterModelsUrl(self.gpa, self.environ);
        defer self.gpa.free(url);

        const res = try http.get(self.gpa, url, 8 * 1024 * 1024, 30_000, null);
        defer self.gpa.free(res.body);
        defer if (res.content_type) |ct| self.gpa.free(ct);
        if (res.status >= 400) return error.CatalogHttp;

        // {"data":[{"id":"vendor/model",...},...]}
        const Parsed = struct {
            data: []const struct { id: []const u8 },
        };
        const parsed = try std.json.parseFromSlice(Parsed, self.gpa, res.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |m| self.gpa.free(m);
            out.deinit(self.gpa);
        }
        for (parsed.value.data) |entry| {
            if (entry.id.len == 0) continue;
            const full = try std.fmt.allocPrint(self.gpa, "openrouter/{s}", .{entry.id});
            try out.append(self.gpa, full);
        }
        std.mem.sort([]u8, out.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return out.toOwnedSlice(self.gpa);
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
        for (self.catalog.items) |m| self.gpa.free(m);
        self.catalog.deinit(self.gpa);
        // Cancel running turns. Resolve child rendezvous before joining: the
        // dispatcher is no longer consuming turn_done events, so a parent
        // parked in task.wait must not depend on its child completion event.
        var cancel_it = self.sessions.valueIterator();
        while (cancel_it.next()) |sp| {
            const session = sp.*;
            cancelActiveSession(self, session);
            if (session.task_waiter) |future| {
                session.task_waiter = null;
                const output = self.gpa.dupe(u8, "error: child interrupted by daemon shutdown") catch continue;
                if (!future.resolve(self.io, output, .interrupted)) self.gpa.free(output);
            }
        }

        // Join and release sessions after every parked parent can make
        // progress independently of dispatcher event processing.
        var sit = self.sessions.valueIterator();
        while (sit.next()) |sp| {
            const session = sp.*;
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

fn cancelActiveSession(self: *Daemon, session: *Session) void {
    if (session.state != .running and session.state != .awaiting_approval) return;
    session.cancel.store(true, .release);
    session.gate.denyPending(self.io);
}

fn taskError(gpa: std.mem.Allocator, message: []const u8) tools_registry.ExecOut {
    const output = std.fmt.allocPrint(gpa, "error: {s}", .{message}) catch @panic("oom");
    return .{ .output = output, .status = .err };
}

fn taskTitle(prompt: []const u8) []const u8 {
    const first_line = if (std.mem.indexOfScalar(u8, prompt, '\n')) |i| prompt[0..i] else prompt;
    const trimmed = std.mem.trim(u8, first_line, " \t\r");
    var end = @min(trimmed.len, 72);
    // Avoid cutting a valid UTF-8 title in the middle of a continuation run.
    while (end > 0 and end < trimmed.len and (trimmed[end] & 0xc0) == 0x80) end -= 1;
    return trimmed[0..end];
}

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

test {
    std.testing.refAllDecls(@This());
}
