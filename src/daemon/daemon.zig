//! marlind: the daemon. Owns all state — sessions, agent loops, the store,
//! provider connections. See docs/ARCHITECTURE.md §1.
//!
//! Thread model (M1):
//!   main thread        accept() loop on the unix socket; spawns client threads
//!   client reader ×N   reads bounded NDJSON records into dispatcher commands
//!   client writer ×N   drains one bounded outbox into that client's socket
//!   dispatcher thread  single consumer of the central MPSC queue; owns ALL
//!                      session state and the store; fans events out to
//!                      subscribed clients' outboxes
//!   turn thread ×M     one per running agent turn; produces events into the
//!                      central queue via loop.zig callbacks
//!
//! Ownership rules (the REAL protocol — mid-turn /permissions, steering,
//! and status all require the turn thread to share parts of the Session):
//!   - Store: shared across dispatcher and turn threads. The single sqlite
//!     connection is opened FULLMUTEX (serialized mode); turn threads append
//!     blocks while the dispatcher answers queries. See store.zig.
//!   - Session identity and configuration (id, kind, parent_*, cwd, model,
//!     effort, approval_mode, sandbox/network toggles, archived) are
//!     dispatcher-owned. Turn threads read them ONLY inside startTurn, on
//!     the dispatcher thread, before the thread spawns; every protocol
//!     mutation of these fields is rejected with err{busy} while a turn
//!     runs, which is what makes the snapshot sound.
//!   - Fields a RUNNING turn may touch, each with its own discipline:
//!       cancel, approval_mode_live, context_used   atomics
//!       gate                                       internally synchronized
//!       steer_queue                                under steer_mutex
//!       prune_frontier                             turn-thread exclusive
//!                                                  while running; dispatcher
//!                                                  only between turns
//!     Adding a turn-visible field means adding it to THIS list with a
//!     stated discipline — TurnJob.session is a live pointer, not a copy.
//!   - Client outboxes are Mpsc(owned OutboundLine); the client thread writes
//!     them to the socket, publishes the last flushed sequence, and frees.

const std = @import("std");
const builtin = @import("builtin");
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

const CatalogModel = struct {
    id: []u8,
    input_per_million: ?f64 = null,
    output_per_million: ?f64 = null,
    tiered: bool = false,
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
    /// Model catalog fetched by a worker thread (registry-form ids plus
    /// normalized pricing; id allocations are dispatcher-owned on receipt).
    catalog_ready: struct { client_id: u64, models: []CatalogModel },
    /// Turn thread → dispatcher completion. final_text and err_text are
    /// separately owned because child task results serialize both fields.
    turn_done: struct { sid: u64, interrupted: bool, err_text: ?[]u8, final_text: ?[]u8, tokens_in: u64, tokens_out: u64 },
    /// Parent turn thread → dispatcher. All strings are gpa-owned; `future`
    /// points into the parked parent turn's stack until resolve().
    child_start: ChildStart,
    shutdown,
};

const OutboundLine = struct {
    bytes: []u8,
    seq: u64,
};

const Client = struct {
    id: u64,
    stream: Io.net.Stream,
    outbox: queue.Mpsc(OutboundLine),
    writer_thread: ?std.Thread = null,
    reader_thread: ?std.Thread = null,
    queued_outbox_bytes: std.atomic.Value(usize) = .init(0),
    next_outbox_seq: std.atomic.Value(u64) = .init(0),
    flushed_outbox_seq: std.atomic.Value(u64) = .init(0),
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

/// Enough room for two maximum-sized records. A client that stops reading is
/// disconnected and replays durable blocks on reconnect instead of growing
/// daemon memory without bound.
const max_client_outbox_bytes: usize = 2 * proto.max_line_bytes;
/// A persisted user/steer block has more JSON envelope than its input
/// command. Keep a fixed wrapper margin so every accepted input is guaranteed
/// to remain replayable under the same protocol record limit.
const max_replayable_input_line_bytes: usize = proto.max_line_bytes - 4096;

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
    max_rounds: u32 = 128,
    archived: bool = false,
    model: []u8, // gpa-owned
    effort: proto.ReasoningEffort = .auto,
    cwd: []u8, // gpa-owned
    state: proto.SessionState = .idle,
    turn_thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    /// Approval mode: set at creation (headless "auto" vs interactive),
    /// switchable per session via /permissions (session_set_approvals).
    approval_mode: approval.Mode = .default,
    /// Atomic mirror of approval_mode for the RUNNING turn thread; updated
    /// together with it so /permissions applies mid-turn.
    approval_mode_live: std.atomic.Value(u8) = .init(@intFromEnum(approval.Mode.default)),
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
    /// Complete encoded approval_request retained while the gate is armed.
    /// Dispatcher-owned; reconnecting subscribers/watchers receive this exact
    /// actionable state instead of only an unexplained awaiting status.
    pending_approval_line: ?[]u8 = null,
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
    /// session_kill releases the in-memory object after its active turn has
    /// acknowledged cancellation. Durable state remains reloadable.
    evict_when_idle: bool = false,
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
    /// Shared std.http connection pool. Requests are turn-thread-owned while
    /// idle HTTP/TLS connections remain warm across turns.
    http_pool: http.Pool,
    sandbox_backend: sandbox.Backend = .unavailable,
    /// Non-null exactly when sandbox_backend is .seatbelt: the profile's
    /// protected-read denials are parameterized on these roots.
    protected_roots: ?sandbox.ProtectedRoots = null,
    events: queue.Mpsc(Event),
    clients: std.AutoHashMapUnmanaged(u64, *Client) = .empty,
    /// Protected by clients_mutex. Prevents an accept already in flight from
    /// registering after shutdown has begun draining the registry.
    accepting_clients: bool = true,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    next_client_id: u64 = 1,
    running: bool = true,
    /// /reboot in flight: client id awaiting the coordinated shutdown.
    /// The daemon quiesces (waits for turns to reach done) then acks + exits.
    pending_reboot: ?u64 = null,
    /// Set when reboot unlinks the listener before ACK. Cleanup must not
    /// unlink the same pathname again after the replacement daemon binds it.
    socket_retired: bool = false,
    /// Advisory lock held for the public socket's lifetime. A crash releases
    /// it in the kernel; coordinated reboot releases it before ACK so the
    /// replacement daemon can acquire it immediately.
    instance_lock: ?Io.File = null,
    /// Model catalog cache (registry-form ids and normalized pricing,
    /// gpa-owned). Refreshed at most once per catalog_ttl_ms; fetch runs on a
    /// worker thread.
    catalog: std.ArrayList(CatalogModel) = .empty,
    catalog_fetched_at: i64 = 0,
    catalog_fetching: bool = false,
    catalog_cancel: std.atomic.Value(bool) = .init(false),
    catalog_thread: ?std.Thread = null,

    const catalog_ttl_ms: i64 = 60 * 60 * 1000; // 1h

    // ------------------------------------------------------------- serve --

    pub fn serve(
        gpa: std.mem.Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        ready_pipe: ?Io.File,
    ) !void {
        // The daemon must survive its spawning terminal: autostart puts us in
        // our own process group, and we ignore SIGHUP for the case where the
        // user runs `marlin daemon` in a terminal that later goes away.
        ignoreSighup();

        // Serialize startup before touching the database or stale socket.
        // The lock file may remain on disk; ownership is the kernel lock, so
        // crashes cannot strand it and a loser can never unlink a live socket.
        const sock_path = try proto.socketPath(gpa, environ);
        defer gpa.free(sock_path);
        if (std.fs.path.dirname(sock_path)) |dir| {
            Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
        const lock_path = try std.fmt.allocPrint(gpa, "{s}.lock", .{sock_path});
        defer gpa.free(lock_path);
        var instance_lock = try acquireInstanceLock(io, lock_path);
        var lock_moved = false;
        defer if (!lock_moved) instance_lock.close(io);

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
            .http_pool = try http.Pool.init(gpa, io, environ),
            .sandbox_backend = sandbox_backend,
            .protected_roots = protected_roots,
            .events = queue.Mpsc(Event).init(gpa),
            .instance_lock = instance_lock,
        };
        lock_moved = true;
        defer self.releaseInstanceLock();
        store_moved = true;
        defer self.store.close();
        defer self.events.deinit();
        defer self.network.deinit();

        // The instance lock makes this socket provably stale.
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

        // SIGTERM/SIGINT shut down gracefully (socket removed, store closed)
        // instead of dying mid-write. Watcher exits when the pipe closes.
        var pipe_fds: [2]std.posix.fd_t = undefined;
        const shutdown_pipe: ?[2]std.posix.fd_t = if (builtin.os.tag != .windows and std.c.pipe(&pipe_fds) == 0)
            pipe_fds
        else
            null;
        var watcher: ?std.Thread = null;
        // Teardown order is load-bearing (defers run LIFO): close the WRITE
        // end first — that EOFs a watcher that never got a signal byte — THEN
        // join it, THEN close the read end. Joining before the write-end
        // close deadlocks serve() forever on protocol shutdown/reboot (the
        // watcher sits in read(2)), leaving a zombie daemon after every !rb;
        // and closing the read end does not wake a blocked read(2) on macOS.
        defer if (shutdown_pipe) |fds| {
            _ = std.c.close(fds[0]);
        };
        defer if (watcher) |w| w.join();
        defer if (shutdown_pipe) |fds| {
            shutdown_pipe_write.store(-1, .release);
            _ = std.c.close(fds[1]); // EOF wakes the watcher so it can exit
        };
        if (shutdown_pipe) |fds| {
            installShutdownSignals(fds[1]);
            watcher = std.Thread.spawn(.{}, ShutdownWatcher.run, .{ShutdownWatcher{
                .daemon = &self,
                .read_fd = fds[0],
            }}) catch null;
        }

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
        client.* = .{
            .id = self.next_client_id,
            .stream = stream,
            .outbox = queue.Mpsc(OutboundLine).init(self.gpa),
        };
        self.next_client_id += 1;
        client.writer_thread = std.Thread.spawn(.{}, clientWriter, .{ self, client }) catch |err| {
            client.outbox.deinit();
            self.gpa.destroy(client);
            return err;
        };

        // Publish only once the writer exists, and start the reader while the
        // registry lock prevents shutdown from freeing this client. A fast
        // hello may queue immediately; lookup waits for this lock to release.
        clients_mutex.lockUncancelable(self.io);
        if (!self.accepting_clients) {
            clients_mutex.unlock(self.io);
            self.cleanupFailedClientSetup(client);
            return error.DaemonShuttingDown;
        }
        self.clients.put(self.gpa, client.id, client) catch |err| {
            clients_mutex.unlock(self.io);
            self.cleanupFailedClientSetup(client);
            return err;
        };
        client.reader_thread = std.Thread.spawn(.{}, clientReader, .{ self, client }) catch |err| {
            _ = self.clients.remove(client.id);
            clients_mutex.unlock(self.io);
            self.cleanupFailedClientSetup(client);
            return err;
        };
        clients_mutex.unlock(self.io);
    }

    // Client registry has its own tiny mutex because both the accept path
    // (add) and dispatcher (lookup/remove) touch it. Values are only
    // *mutated* by their owning threads per the rules above.
    var clients_mutex: Io.Mutex = .init;

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

    /// Stop both directions before joining either thread. shutdown(2) is the
    /// cancellation mechanism for a writer blocked in write(2) and a reader
    /// blocked waiting for its next record.
    fn stopClientIo(self: *Daemon, client: *Client) void {
        client.outbox.close(self.io);
        client.stream.shutdown(self.io, .both) catch {};
        if (client.writer_thread) |thread| {
            thread.join();
            client.writer_thread = null;
        }
        if (client.reader_thread) |thread| {
            thread.join();
            client.reader_thread = null;
        }
    }

    fn cleanupFailedClientSetup(self: *Daemon, client: *Client) void {
        self.stopClientIo(client);
        client.subs.deinit(self.gpa);
        client.outbox.deinit();
        self.gpa.destroy(client);
    }

    fn destroyClient(self: *Daemon, client: *Client) void {
        self.stopClientIo(client);
        client.stream.close(self.io);
        client.subs.deinit(self.gpa);
        client.outbox.deinit();
        self.gpa.destroy(client);
    }

    /// Reader thread: one per client. Socket lines → event queue.
    fn clientReader(self: *Daemon, client: *Client) void {
        var rbuf: [64 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(client.stream, self.io, &rbuf);
        const r = &reader.interface;
        while (true) {
            const line = proto.readLineAlloc(self.gpa, r) catch |err| switch (err) {
                error.ProtocolLineTooLong => {
                    self.sendTo(client, .{ .err = .{
                        .code = "line_too_long",
                        .msg = "protocol record exceeds 32 MiB",
                    } });
                    continue;
                },
                else => break,
            };
            self.events.push(self.io, .{ .client_msg = .{ .client_id = client.id, .msg_line = line } }) catch {
                self.gpa.free(line);
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
        writer_loop: while (client.outbox.pop(self.io)) |line| {
            if (!self.writeClientLine(client, w, line)) break;
            var last_written_seq = line.seq;
            // Replay and fan-out bursts share one flush instead of one syscall
            // per block. A lone live delta still flushes immediately.
            while (client.outbox.tryPop(self.io)) |queued| {
                if (!self.writeClientLine(client, w, queued)) break :writer_loop;
                last_written_seq = queued.seq;
            }
            w.flush() catch break;
            client.flushed_outbox_seq.store(last_written_seq, .release);
        }
        // Drain anything left after close without writing.
        while (client.outbox.tryPop(self.io)) |line| {
            _ = client.queued_outbox_bytes.fetchSub(line.bytes.len, .acq_rel);
            self.gpa.free(line.bytes);
        }
    }

    fn writeClientLine(self: *Daemon, client: *Client, writer: *std.Io.Writer, line: OutboundLine) bool {
        defer self.gpa.free(line.bytes);
        _ = client.queued_outbox_bytes.fetchSub(line.bytes.len, .acq_rel);
        writer.writeAll(line.bytes) catch return false;
        return true;
    }

    fn enqueueLine(self: *Daemon, client: *Client, line: []u8) ?u64 {
        const previous = client.queued_outbox_bytes.fetchAdd(line.len, .acq_rel);
        if (line.len > max_client_outbox_bytes or previous > max_client_outbox_bytes - line.len) {
            _ = client.queued_outbox_bytes.fetchSub(line.len, .acq_rel);
            self.gpa.free(line);
            std.log.warn("disconnecting slow client {d}: outbox exceeded {Bi}", .{
                client.id,
                max_client_outbox_bytes,
            });
            client.outbox.close(self.io);
            client.stream.shutdown(self.io, .both) catch {};
            return null;
        }
        const seq = client.next_outbox_seq.fetchAdd(1, .acq_rel) +% 1;
        client.outbox.push(self.io, .{ .bytes = line, .seq = seq }) catch {
            _ = client.queued_outbox_bytes.fetchSub(line.len, .acq_rel);
            self.gpa.free(line);
            return null;
        };
        return seq;
    }

    fn sendTo(self: *Daemon, client: *Client, msg: proto.DaemonMsg) void {
        _ = self.sendToTracked(client, msg);
    }

    fn sendToTracked(self: *Daemon, client: *Client, msg: proto.DaemonMsg) ?u64 {
        const line = proto.encode(self.gpa, msg) catch |err| {
            if (err == error.ProtocolLineTooLong) self.sendResponseTooLarge(client);
            return null;
        };
        return self.enqueueLine(client, line);
    }

    fn sendResponseTooLarge(self: *Daemon, client: *Client) void {
        const line = proto.encode(self.gpa, proto.DaemonMsg{ .err = .{
            .code = "response_too_large",
            .msg = "response exceeds the 32 MiB protocol limit",
        } }) catch return;
        _ = self.enqueueLine(client, line);
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
                switch (msg) {
                    .input => |input| if (cm.msg_line.len > max_replayable_input_line_bytes) {
                        self.sendInputError(
                            client,
                            input.request_id,
                            "input_too_large",
                            "message is too close to the protocol limit to persist and replay safely",
                        );
                        return;
                    },
                    else => {},
                }
                self.handleClientMsg(client, msg) catch |err| {
                    // A protocol request must always terminate visibly. Do not
                    // let allocator/store/thread failures escape only to the
                    // daemon log while the client waits forever for its ack.
                    std.log.warn("{t} request from client {d} failed: {t}", .{
                        std.meta.activeTag(msg),
                        client.id,
                        err,
                    });
                    self.sendTo(client, .{ .err = .{
                        .code = "request_failed",
                        .msg = "daemon could not complete the request; durable state was left consistent",
                    } });
                };
            },
            .client_gone => |cg| {
                if (self.removeClient(cg.client_id)) |client| {
                    // The registry no longer contains this client, so each
                    // subscription can now be tested against the remaining
                    // live set before its arrays are destroyed.
                    for (client.subs.items) |sid| self.releaseSessionIfUnused(sid);
                    self.destroyClient(client);
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
                if (self.sessions.get(ta.sid)) |session| {
                    if (session.pending_approval_line) |old| self.gpa.free(old);
                    session.pending_approval_line = ta.line;
                    session.state = .awaiting_approval;
                    self.store.setSessionStatus(ta.sid, "awaiting_approval") catch {};
                    // A turn can reach its first approval after a plain reboot
                    // has begun quiescing. Refuse that reboot now rather than
                    // strand an approval whose TUI already exited.
                    self.refusePendingRebootForApproval();
                    self.fanOutActionableLine(ta.sid, ta.line);
                    self.broadcastStatus(ta.sid, .awaiting_approval);
                } else {
                    self.gpa.free(ta.line);
                }
            },
            .turn_resumed => |tr| {
                if (self.sessions.get(tr.sid)) |session| {
                    self.clearPendingApproval(session);
                    session.state = .running;
                    self.store.setSessionStatus(tr.sid, "running") catch {};
                }
                self.broadcastStatus(tr.sid, .running);
            },
            .catalog_ready => |cr| {
                if (self.catalog_thread) |thread| thread.join();
                self.catalog_thread = null;
                // Replace the cache (dispatcher owns it now).
                for (self.catalog.items) |m| self.gpa.free(m.id);
                self.catalog.clearRetainingCapacity();
                for (cr.models) |m| self.catalog.append(self.gpa, m) catch self.gpa.free(m.id);
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
                self.clearPendingApproval(session);
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
                // Task children are one-shot workers. Their durable transcript
                // remains attachable, but keeping every completed child's
                // mutexes, queues, model and cwd resident makes fan-out grow
                // forever. Rehydrate lazily if somebody opens the child.
                if (session.evict_when_idle or session.kind == .task_child)
                    self.unloadSession(td.sid);
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
                // Freeze the producer boundary before leaving the dispatcher.
                // In particular, a task child queued just behind this event
                // owns a future on its parent turn's stack; cleanup must
                // resolve it rather than joining that parent forever.
                self.events.close(self.io);
                // Nudge AFTER the flag flips: the accept loop re-checks
                // running per connection, so a nudge that lands while running
                // is still true is consumed as an ordinary client and the
                // loop re-blocks in accept(2) with nobody left to wake it
                // (the observed SIGTERM hang).
                self.running = false;
                self.nudgeAcceptLoop();
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
                const session = try self.gpa.create(Session);
                errdefer self.gpa.destroy(session);
                const model = try self.gpa.dupe(u8, sc.model);
                errdefer self.gpa.free(model);
                const cwd = try self.gpa.dupe(u8, sc.cwd);
                errdefer self.gpa.free(cwd);
                session.* = .{
                    .id = sid,
                    .model = model,
                    .effort = sc.effort,
                    .cwd = cwd,
                    .approval_mode = approval.Mode.parse(sc.approvals),
                    .sandbox_enabled = self.cfg.permissions_enabled,
                    .network_filtering_enabled = self.network.isActive(),
                };
                session.approval_mode_live.store(@intFromEnum(session.approval_mode), .release);
                // Reserve every fallible in-memory resource before committing
                // the durable row. After createSession succeeds, publishing to
                // the map cannot fail and no ghost session can be left behind.
                try self.sessions.ensureUnusedCapacity(self.gpa, 1);
                try self.store.createSession(sid, nowMs(self.io), sc.cwd, sc.model, sc.effort);
                self.sessions.putAssumeCapacityNoClobber(sid, session);
                self.sendTo(client, .{ .session_created = .{ .sid = sid } });
                self.broadcastSessionList();
            },
            .session_list => |sl| try self.sendSessionList(client, sl.include_archived),
            .session_watch => {
                client.watches_sessions = true;
                try self.sendSessionList(client, false);
                self.sendPendingApprovals(client);
            },
            .session_kill => |sk| {
                self.cancelSessionTree(sk.sid);
                self.requestSessionTreeEviction(sk.sid);
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
                if (sa.archived) self.requestSessionTreeEviction(sa.sid);
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
                errdefer self.gpa.free(new_model);
                try self.store.setSessionModel(sm.sid, sm.model);
                self.gpa.free(session.model);
                session.model = new_model;
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
                try self.store.setSessionEffort(se.sid, se.effort);
                session.effort = se.effort;
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
            .session_set_approvals => |sa| {
                const session = (try self.getOrLoadSession(sa.sid)) orelse {
                    self.sendTo(client, .{ .err = .{ .code = "no_session", .msg = "unknown session" } });
                    return;
                };
                // Applies to the RUNNING turn too: the loop reads the live
                // mirror per call, and granting full access while a call is
                // parked on the gate resolves that prompt immediately —
                // /permissions full is most wanted exactly then.
                const mode = approval.Mode.parse(sa.approvals);
                session.approval_mode = mode;
                session.approval_mode_live.store(@intFromEnum(mode), .release);
                if (mode == .auto) {
                    if (session.gate.isPending(self.io)) |pending| {
                        _ = session.gate.resolve(self.io, pending, .approved);
                    }
                }
                self.sendTo(client, .{ .ok = .{} });
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
                // Replay either a bounded newest window or from_seq onward.
                if (s.from_seq > 0 or s.tail_limit > 0) {
                    var replay_arena_state = std.heap.ArenaAllocator.init(self.gpa);
                    defer replay_arena_state.deinit();
                    var replay: std.ArrayList(block.Block) = .empty;
                    if (s.tail_limit > 0)
                        if (s.before_seq > 0)
                            try self.store.loadTailBeforeInto(
                                replay_arena_state.allocator(),
                                &replay,
                                s.sid,
                                s.before_seq,
                                @min(s.tail_limit, 512),
                            )
                        else
                            try self.store.loadTailInto(
                                replay_arena_state.allocator(),
                                &replay,
                                s.sid,
                                @min(s.tail_limit, 512),
                            )
                    else
                        try self.store.loadBlocksInto(replay_arena_state.allocator(), &replay, s.sid, s.from_seq, 1_000_000);
                    for (replay.items) |replayed| {
                        self.sendTo(client, .{ .blk = .{ .sid = s.sid, .b = replayed } });
                    }
                    if (s.tail_limit > 0 or s.replay_done) {
                        self.sendTo(client, .{ .replay_done = .{
                            .sid = s.sid,
                            .oldest_seq = if (replay.items.len > 0) replay.items[0].seq else 0,
                            .newest_seq = if (replay.items.len > 0) replay.items[replay.items.len - 1].seq else 0,
                            .has_older = s.tail_limit > 0 and replay.items.len > 0 and replay.items[0].seq > 1,
                        } });
                    }
                }
                const state: proto.SessionState = if (self.sessions.get(s.sid)) |ses| blk: {
                    if (ses.pending_approval_line) |line| self.sendLine(client, line);
                    break :blk ses.state;
                } else .idle;
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
                self.releaseSessionIfUnused(u.sid);
            },
            .input => |inp| {
                const session = (self.getOrLoadSession(inp.sid) catch {
                    self.sendInputError(client, inp.request_id, "store", "could not load session");
                    return;
                }) orelse {
                    self.sendInputError(client, inp.request_id, "no_session", "unknown session");
                    return;
                };
                if (session.archived) {
                    self.sendInputError(
                        client,
                        inp.request_id,
                        "archived",
                        "unarchive the session before modifying it",
                    );
                    return;
                }
                if (session.state == .running or session.state == .awaiting_approval) {
                    // Approval is a parked phase of the same turn. Input stays
                    // a steer for that turn; it must never create a competitor.
                    const owned = self.gpa.dupe(u8, inp.text) catch {
                        self.sendInputError(client, inp.request_id, "internal", "could not queue input");
                        return;
                    };
                    session.steer_mutex.lockUncancelable(self.io);
                    session.steer_queue.append(self.gpa, owned) catch {
                        session.steer_mutex.unlock(self.io);
                        self.gpa.free(owned);
                        self.sendInputError(client, inp.request_id, "internal", "could not queue input");
                        return;
                    };
                    session.steer_mutex.unlock(self.io);
                    self.sendTo(client, .{ .ok = .{ .request_id = inp.request_id } });
                    return;
                }
                self.startTurn(session, inp.text) catch |err| {
                    if (err == error.SessionBusy) {
                        self.sendInputError(client, inp.request_id, "busy", "session already has an active turn");
                        return;
                    }
                    self.sendInputError(client, inp.request_id, "internal", "could not start turn");
                    return;
                };
                self.sendTo(client, .{ .ok = .{ .request_id = inp.request_id } });
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
                const cwd = try self.gpa.dupe(u8, session.cwd);
                errdefer self.gpa.free(cwd);
                const model = try self.gpa.dupe(u8, session.model);
                errdefer self.gpa.free(model);
                const text = try self.gpa.dupe(u8, "");
                errdefer self.gpa.free(text);
                job.* = .{
                    .daemon = self,
                    .sid = session.id,
                    .cwd = cwd,
                    .model = model,
                    .effort = session.effort,
                    .text = text,
                    .cancel = &session.cancel,
                    .session = session,
                };
                const thread = try std.Thread.spawn(.{}, compactMain, .{job});
                session.turn_thread = thread;
                session.state = .running;
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
                self.catalog_cancel.store(false, .release);
                self.catalog_thread = std.Thread.spawn(.{}, catalogFetchMain, .{ self, client.id }) catch {
                    self.catalog_fetching = false;
                    self.sendCatalog(client);
                    return;
                };
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
                if (self.pending_reboot != null) {
                    self.sendTo(client, .{ .err = .{
                        .code = "reboot_pending",
                        .msg = "another client already requested reboot",
                    } });
                    return;
                }
                if (!r.force and self.hasPendingApproval()) {
                    self.sendTo(client, .{ .err = .{
                        .code = "approval_pending",
                        .msg = "cannot reboot while approval is pending; answer it, interrupt it, or use --force",
                    } });
                    return;
                }
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
            .max_rounds = if (row.max_rounds > 0) row.max_rounds else 128,
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

    fn sendInputError(
        self: *Daemon,
        client: *Client,
        request_id: u64,
        code: []const u8,
        msg: []const u8,
    ) void {
        self.sendTo(client, .{ .err = .{
            .code = code,
            .msg = msg,
            .request_id = request_id,
        } });
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

    /// Mark a loaded tree for eviction, releasing idle members immediately
    /// and deferring active ones until turn_done. Durable rows remain intact
    /// and are reconstructed by getOrLoadSession on the next access.
    fn requestSessionTreeEviction(self: *Daemon, sid: u64) void {
        var idle: std.ArrayList(u64) = .empty;
        defer idle.deinit(self.gpa);
        var it = self.sessions.valueIterator();
        while (it.next()) |sp| {
            const session = sp.*;
            if (!self.loadedSessionBelongsToTree(session, sid)) continue;
            session.evict_when_idle = true;
            if (session.state != .running and session.state != .awaiting_approval)
                idle.append(self.gpa, session.id) catch {};
        }
        for (idle.items) |idle_sid| self.unloadSession(idle_sid);
    }

    fn unloadSession(self: *Daemon, sid: u64) void {
        const removed = self.sessions.fetchRemove(sid) orelse return;
        self.destroySession(removed.value);
    }

    fn sessionHasSubscriber(self: *Daemon, sid: u64) bool {
        clients_mutex.lockUncancelable(self.io);
        defer clients_mutex.unlock(self.io);
        var it = self.clients.valueIterator();
        while (it.next()) |client| if (client.*.subscribed(sid)) return true;
        return false;
    }

    /// Loaded sessions are a working set, not a second durable catalog. Once
    /// the last focused client leaves, release idle roots immediately and
    /// release active ones after their turn completes. Reopening rehydrates
    /// from SQLite without changing the visible transcript.
    fn releaseSessionIfUnused(self: *Daemon, sid: u64) void {
        if (self.sessionHasSubscriber(sid)) return;
        const session = self.sessions.get(sid) orelse return;
        if (session.state == .running or session.state == .awaiting_approval) {
            session.evict_when_idle = true;
        } else {
            self.unloadSession(sid);
        }
    }

    fn destroySession(self: *Daemon, session: *Session) void {
        if (session.turn_thread) |thread| thread.join();
        self.clearPendingApproval(session);
        session.steer_mutex.lockUncancelable(self.io);
        for (session.steer_queue.items) |steer| self.gpa.free(steer);
        session.steer_queue.deinit(self.gpa);
        session.steer_mutex.unlock(self.io);
        self.gpa.free(session.model);
        self.gpa.free(session.cwd);
        self.gpa.destroy(session);
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

        // As with root creation, reserve the map slot before the durable
        // commit so allocation failure cannot leave an unreachable child row.
        try self.sessions.ensureUnusedCapacity(self.gpa, 1);
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
        self.sessions.putAssumeCapacityNoClobber(sid, session);
        session_transferred = true;
        // Structural catalog change: publish the new child once. Subsequent
        // state changes use the compact status watcher path.
        self.broadcastSessionList();
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
        if (session.turn_thread != null or session.state == .running or session.state == .awaiting_approval)
            return error.SessionBusy;
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

    /// Durable note for a turn that failed AFTER the loop started (its
    /// user_msg is already in the log): the failure reason itself must land
    /// in the transcript, not just flip the session to err.
    fn persistTurnNote(self: *Daemon, job: *TurnJob, note: []const u8) void {
        const b = block.Block{
            .id = ids.next(self.io),
            .session_id = job.sid,
            .turn_id = ids.next(self.io),
            .seq = (self.store.lastSeq(job.sid) catch return) + 1,
            .ts = nowMs(self.io),
            .body = .{ .system_note = .{ .text = note } },
        };
        self.store.appendBlock(b) catch return;
        TurnHooks.onBlock(job, b);
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
            .http_pool = &self.http_pool,
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
            .approval_mode_live = &job.session.approval_mode_live,
            .gate = &job.session.gate,
            .on_approval_needed = TurnHooks.onApprovalNeeded,
            .on_approval_done = TurnHooks.onApprovalDone,
            .on_delta = TurnHooks.onDelta,
            .on_reasoning_delta = TurnHooks.onReasoningDelta,
            .on_stream_status = TurnHooks.onStreamStatus,
            .on_delta_ctx = job,
            .on_block = TurnHooks.onBlock,
            .on_task = if (job.session.kind == .root) TurnHooks.onTask else null,
            .tool_profile = if (job.session.kind == .root) .full else .read_only,
            .cancel = job.cancel,
            .poll_steer = TurnHooks.pollSteer,
            .max_rounds = job.session.max_rounds,
        }, job.text) catch |e| {
            // Transport errors are flattened by the http layer; the recorded
            // cause turns "ConnectFailed" into "ConnectFailed
            // (TlsInitializationFailed)" — the difference between a shrug
            // and a diagnosis. Same thread: the request ran on this turn.
            const cause: ?anyerror = switch (e) {
                error.ConnectFailed, error.ReadFailed => http.lastTransportCause(),
                else => null,
            };
            err_text = if (cause) |c|
                std.fmt.allocPrint(self.gpa, "turn failed: {t} ({t})", .{ e, c }) catch null
            else
                std.fmt.allocPrint(self.gpa, "turn failed: {t}", .{e}) catch null;
            // The reason must survive in the transcript: turn_done frees
            // err_text after status fan-out, so without a durable note the
            // user sees a bare "error" state with no explanation.
            if (e != error.ProviderError)
                self.persistTurnNote(job, err_text orelse "turn failed");
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
            .http_pool = &self.http_pool,
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

        fn onReasoningDelta(ctx: ?*anyopaque, text: []const u8) void {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            const line = proto.encode(self.gpa, proto.DaemonMsg{ .reasoning_delta = .{ .sid = job.sid, .turn_id = 0, .text = text } }) catch return;
            self.events.push(self.io, .{ .turn_delta = .{ .sid = job.sid, .line = line } }) catch self.gpa.free(line);
        }

        fn onStreamStatus(ctx: ?*anyopaque, bytes: u64, quiet_ms: u64) void {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            const line = proto.encode(self.gpa, proto.DaemonMsg{ .stream_status = .{ .sid = job.sid, .bytes = bytes, .quiet_ms = quiet_ms } }) catch return;
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

        fn onApprovalNeeded(ctx: ?*anyopaque, id: u64, call_id: []const u8, tool: []const u8, args_json: []const u8) bool {
            const job: *TurnJob = @ptrCast(@alignCast(ctx.?));
            const self = job.daemon;
            var id_buf: [24]u8 = undefined;
            const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch return false;
            const line = proto.encode(self.gpa, proto.DaemonMsg{ .approval_request = .{
                .sid = job.sid,
                .approval_id = id_str,
                .call_id = call_id,
                .tool = tool,
                .args_json = args_json,
            } }) catch return false;
            self.events.push(self.io, .{ .turn_awaiting = .{ .sid = job.sid, .line = line } }) catch {
                self.gpa.free(line);
                return false;
            };
            const payload = std.json.Stringify.valueAlloc(self.gpa, .{
                .sid = job.sid,
                .approval_id = id,
                .call_id = call_id,
                .tool = tool,
                .args_json = args_json,
            }, .{}) catch return true;
            self.extensions.fireHook(.on_approval_needed, payload);
            self.gpa.free(payload);
            return true;
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
        ctx.self.sendLine(client, ctx.line);
    }

    /// Approval requests are actionable multiplexer state, not transcript
    /// traffic: session-watch clients receive them even when that session is
    /// not focused/subscribed, so switching to it presents the real card.
    fn fanOutActionableLine(self: *Daemon, sid: u64, line: []const u8) void {
        const ctx = FanCtx{ .self = self, .sid = sid, .line = line };
        self.forEachClient(ctx, struct {
            fn send(c: FanCtx, client: *Client) void {
                if (!client.said_hello or (!client.subscribed(c.sid) and !client.watches_sessions)) return;
                c.self.sendLine(client, c.line);
            }
        }.send);
    }

    fn sendLine(self: *Daemon, client: *Client, line: []const u8) void {
        if (line.len > proto.max_line_bytes) {
            self.sendResponseTooLarge(client);
            return;
        }
        const copy = self.gpa.dupe(u8, line) catch return;
        _ = self.enqueueLine(client, copy);
    }

    fn clearPendingApproval(self: *Daemon, session: *Session) void {
        if (session.pending_approval_line) |line| self.gpa.free(line);
        session.pending_approval_line = null;
    }

    fn sendPendingApprovals(self: *Daemon, client: *Client) void {
        var it = self.sessions.valueIterator();
        while (it.next()) |sp| {
            const session = sp.*;
            if (session.archived or client.subscribed(session.id)) continue;
            if (session.pending_approval_line) |line| self.sendLine(client, line);
        }
    }

    fn broadcastStatus(self: *Daemon, sid: u64, state: proto.SessionState) void {
        const line = proto.encode(self.gpa, proto.DaemonMsg{ .status = .{ .sid = sid, .state = state } }) catch return;
        defer self.gpa.free(line);
        const ctx = FanCtx{ .self = self, .sid = sid, .line = line };
        self.forEachClient(ctx, struct {
            fn send(value: FanCtx, client: *Client) void {
                if (!client.said_hello or (!client.subscribed(value.sid) and !client.watches_sessions)) return;
                value.self.sendLine(client, value.line);
            }
        }.send);
    }

    fn sendSessionList(self: *Daemon, client: *Client, include_archived: bool) !void {
        const rows = try self.store.listSessions(include_archived);
        defer {
            for (rows) |row| row.deinit(self.gpa);
            self.gpa.free(rows);
        }
        const infos = try self.sessionInfos(rows);
        defer self.gpa.free(infos);
        self.sendTo(client, .{ .session_list_result = .{ .sessions = infos } });
    }

    /// Project durable rows through the live in-memory state. Returned info
    /// borrows row strings and owns only its outer slice.
    fn sessionInfos(self: *Daemon, rows: []const store_mod.Store.SessionListing) ![]proto.SessionInfo {
        const infos = try self.gpa.alloc(proto.SessionInfo, rows.len);
        errdefer self.gpa.free(infos);
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
        return infos;
    }

    fn broadcastSessionList(self: *Daemon) void {
        // Build one authoritative snapshot, then fan the encoded line out
        // while holding the registry lock. The accept thread mutates clients,
        // so an unlocked valueIterator is a real map data race.
        const rows = self.store.listSessions(false) catch return;
        defer {
            for (rows) |row| row.deinit(self.gpa);
            self.gpa.free(rows);
        }
        const infos = self.sessionInfos(rows) catch return;
        defer self.gpa.free(infos);
        const line = proto.encode(self.gpa, proto.DaemonMsg{ .session_list_result = .{ .sessions = infos } }) catch return;
        defer self.gpa.free(line);
        const ctx = struct { daemon: *Daemon, encoded: []const u8 }{ .daemon = self, .encoded = line };
        self.forEachClient(ctx, struct {
            fn send(value: @TypeOf(ctx), client: *Client) void {
                if (!client.said_hello or !client.watches_sessions) return;
                value.daemon.sendLine(client, value.encoded);
            }
        }.send);
    }

    /// Send the current catalog (possibly empty → client falls back to
    /// favorites).
    fn sendCatalog(self: *Daemon, client: *Client) void {
        const models = self.gpa.alloc([]const u8, self.catalog.items.len) catch return;
        defer self.gpa.free(models);
        const pricing = self.gpa.alloc(proto.ModelPricing, self.catalog.items.len) catch return;
        defer self.gpa.free(pricing);
        for (self.catalog.items, 0..) |m, i| {
            models[i] = m.id;
            pricing[i] = .{
                .model = m.id,
                .input_per_million = m.input_per_million,
                .output_per_million = m.output_per_million,
                .tiered = m.tiered,
            };
        }
        self.sendTo(client, .{ .model_list_result = .{ .models = models, .pricing = pricing } });
    }

    /// Worker thread: GET /models from OpenRouter, parse ids, hand the
    /// result to the dispatcher. Failure → empty list (client falls back).
    fn catalogFetchMain(self: *Daemon, client_id: u64) void {
        const models = self.fetchCatalog() catch
            self.gpa.alloc(CatalogModel, 0) catch return;
        self.events.push(self.io, .{ .catalog_ready = .{ .client_id = client_id, .models = models } }) catch {
            for (models) |m| self.gpa.free(m.id);
            self.gpa.free(models);
        };
    }

    fn fetchCatalog(self: *Daemon) ![]CatalogModel {
        const url = try registry.openrouterModelsUrl(self.gpa, self.environ);
        defer self.gpa.free(url);

        const res = try http.get(
            self.gpa,
            self.io,
            self.environ,
            url,
            8 * 1024 * 1024,
            30_000,
            &self.catalog_cancel,
        );
        defer self.gpa.free(res.body);
        defer if (res.content_type) |ct| self.gpa.free(ct);
        if (res.status >= 400) return error.CatalogHttp;

        return parseCatalog(self.gpa, res.body);
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
        // Wake OUR still-linked listener before releasing the instance lock.
        // Once the ACK reaches the client a replacement daemon may bind the
        // public path; nudging after that can connect to the replacement and
        // leave this accept loop blocked forever on its unlinked old socket.
        // The dispatcher remains inside this handler until the ACK flushes,
        // so running=false cannot start cleanup underneath the writer.
        self.running = false;
        self.nudgeAcceptLoop();
        // Retire the public socket before ACKing. The ACK tells the client it
        // may exec immediately, so no new process may still connect to this
        // dying daemon and lose its hello request during cleanup.
        self.removeSocketFile();
        self.socket_retired = true;
        self.releaseInstanceLock();
        if (self.lookupClient(requester)) |client| {
            if (self.sendToTracked(client, .{ .ok = .{} })) |ack_seq| {
                if (!self.waitForClientFlush(client, ack_seq, 2_000))
                    std.log.warn("reboot ACK did not flush to client {d}", .{requester});
            }
        }
    }

    fn waitForClientFlush(self: *Daemon, client: *Client, target_seq: u64, timeout_ms: u32) bool {
        var elapsed_ms: u32 = 0;
        while (elapsed_ms < timeout_ms) : (elapsed_ms += 5) {
            if (client.flushed_outbox_seq.load(.acquire) >= target_seq) return true;
            self.io.sleep(.fromMilliseconds(5), .awake) catch return false;
        }
        return client.flushed_outbox_seq.load(.acquire) >= target_seq;
    }

    fn hasPendingApproval(self: *Daemon) bool {
        var it = self.sessions.valueIterator();
        while (it.next()) |sp| {
            const session = sp.*;
            if (session.state == .awaiting_approval or session.gate.isPending(self.io) != null) return true;
        }
        return false;
    }

    fn refusePendingRebootForApproval(self: *Daemon) void {
        const requester = self.pending_reboot orelse return;
        self.pending_reboot = null;
        if (self.lookupClient(requester)) |client| {
            self.sendTo(client, .{ .err = .{
                .code = "approval_pending",
                .msg = "reboot stopped because a running turn now needs approval; answer it, interrupt it, or retry with --force",
            } });
        }
    }

    fn nudgeAcceptLoop(self: *Daemon) void {
        const sock_path = proto.socketPath(self.gpa, self.environ) catch return;
        defer self.gpa.free(sock_path);
        const ua = Io.net.UnixAddress.init(sock_path) catch return;
        const s = ua.connect(self.io) catch return;
        s.close(self.io);
    }

    fn removeSocketFile(self: *Daemon) void {
        const sock_path = proto.socketPath(self.gpa, self.environ) catch return;
        defer self.gpa.free(sock_path);
        Io.Dir.cwd().deleteFile(self.io, sock_path) catch {};
    }

    fn shutdownCleanup(self: *Daemon) void {
        clients_mutex.lockUncancelable(self.io);
        self.accepting_clients = false;
        clients_mutex.unlock(self.io);

        // Stop the one non-turn worker before draining its completion event;
        // it owns the daemon HTTP/config pointers until joined.
        self.catalog_cancel.store(true, .release);
        if (self.catalog_thread) |thread| thread.join();
        self.catalog_thread = null;
        self.catalog_fetching = false;

        // The dispatcher stops at the shutdown marker, so producers that won
        // the queue lock immediately before close may still have payloads
        // behind it. Resolve child futures first and release every owned
        // payload; Mpsc only owns the value slots, not their allocations.
        while (self.events.tryPop(self.io)) |event| self.discardShutdownEvent(event);

        for (self.catalog.items) |m| self.gpa.free(m.id);
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
        while (sit.next()) |sp| self.destroySession(sp.*);
        self.sessions.deinit(self.gpa);
        self.http_pool.deinit();

        // Close all client outboxes; writer threads exit, readers hit EOF.
        clients_mutex.lockUncancelable(self.io);
        var cit = self.clients.valueIterator();
        while (cit.next()) |cp| {
            const client = cp.*;
            self.destroyClient(client);
        }
        self.clients.deinit(self.gpa);
        clients_mutex.unlock(self.io);

        // Remove the socket so the (blocked) accept loop errors out.
        if (!self.socket_retired) self.removeSocketFile();
        self.releaseInstanceLock();
    }

    fn releaseInstanceLock(self: *Daemon) void {
        if (self.instance_lock) |file| file.close(self.io);
        self.instance_lock = null;
    }

    fn discardShutdownEvent(self: *Daemon, event: Event) void {
        switch (event) {
            .client_msg => |value| self.gpa.free(value.msg_line),
            .client_gone, .turn_resumed, .shutdown => {},
            .turn_block => |value| self.gpa.free(value.line),
            .turn_delta => |value| self.gpa.free(value.line),
            .turn_awaiting => |value| self.gpa.free(value.line),
            .catalog_ready => |value| {
                for (value.models) |model| self.gpa.free(model.id);
                self.gpa.free(value.models);
            },
            .turn_done => |value| {
                if (value.err_text) |text| self.gpa.free(text);
                if (value.final_text) |text| self.gpa.free(text);
            },
            .child_start => |value| {
                defer self.gpa.free(value.prompt);
                defer if (value.model) |model| self.gpa.free(model);
                const output = self.gpa.dupe(u8, "error: child interrupted by daemon shutdown") catch return;
                if (!value.future.resolve(self.io, output, .interrupted)) self.gpa.free(output);
            },
        }
    }
};

fn acquireInstanceLock(io: Io, path: []const u8) !Io.File {
    return Io.Dir.cwd().createFile(io, path, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.WouldBlock => error.DaemonAlreadyRunning,
        else => err,
    };
}

/// Decode OpenRouter's catalog without coupling the wire protocol to its
/// per-token string representation. Bad individual price fields degrade to
/// unknown; a malformed catalog envelope still fails the fetch as a whole.
fn parseCatalog(gpa: std.mem.Allocator, body: []const u8) ![]CatalogModel {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidCatalog;
    const data = parsed.value.object.get("data") orelse return error.InvalidCatalog;
    if (data != .array) return error.InvalidCatalog;

    var out: std.ArrayList(CatalogModel) = .empty;
    errdefer {
        for (out.items) |model| gpa.free(model.id);
        out.deinit(gpa);
    }
    for (data.array.items) |entry| {
        if (entry != .object) continue;
        const raw_id = entry.object.get("id") orelse continue;
        if (raw_id != .string or raw_id.string.len == 0) continue;
        const raw_pricing = entry.object.get("pricing");
        const full_id = try std.fmt.allocPrint(gpa, "openrouter/{s}", .{raw_id.string});
        errdefer gpa.free(full_id);
        try out.append(gpa, .{
            .id = full_id,
            .input_per_million = catalogRate(raw_pricing, "prompt"),
            .output_per_million = catalogRate(raw_pricing, "completion"),
            .tiered = catalogPricingIsTiered(raw_pricing),
        });
    }
    std.mem.sort(CatalogModel, out.items, {}, struct {
        fn lessThan(_: void, a: CatalogModel, b: CatalogModel) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
    return out.toOwnedSlice(gpa);
}

fn catalogPricingObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const pricing = value orelse return null;
    return switch (pricing) {
        .object => |object| object,
        .array => |array| if (array.items.len > 0 and array.items[0] == .object)
            array.items[0].object
        else
            null,
        else => null,
    };
}

fn catalogPricingIsTiered(value: ?std.json.Value) bool {
    const pricing = value orelse return false;
    return pricing == .array and pricing.array.items.len > 1;
}

fn catalogRate(pricing: ?std.json.Value, field: []const u8) ?f64 {
    const object = catalogPricingObject(pricing) orelse return null;
    const raw = object.get(field) orelse return null;
    const per_token: f64 = switch (raw) {
        .string => |text| std.fmt.parseFloat(f64, text) catch return null,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return null,
        .float => |value| value,
        .integer => |value| @floatFromInt(value),
        else => return null,
    };
    if (!std.math.isFinite(per_token) or per_token < 0) return null;
    const per_million = per_token * 1_000_000;
    return if (std.math.isFinite(per_million)) per_million else null;
}

/// Write end of the shutdown self-pipe, set before the TERM/INT handler is
/// installed. The handler only writes one byte (async-signal-safe); a watcher
/// thread turns that byte into the ordinary .shutdown dispatcher event, so a
/// signal shuts down through exactly the code path /quit and reboot use.
var shutdown_pipe_write = std.atomic.Value(i32).init(-1);

fn onShutdownSignal(_: std.c.SIG) callconv(.c) void {
    const fd = shutdown_pipe_write.load(.acquire);
    if (fd >= 0) _ = std.c.write(fd, "T", 1);
}

fn installShutdownSignals(write_fd: std.posix.fd_t) void {
    if (std.posix.Sigaction == void) return;
    shutdown_pipe_write.store(@intCast(write_fd), .release);
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = onShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);
}

const ShutdownWatcher = struct {
    daemon: *Daemon,
    read_fd: std.posix.fd_t,

    fn run(w: ShutdownWatcher) void {
        var buf: [1]u8 = undefined;
        const n = std.posix.read(w.read_fd, &buf) catch return;
        if (n == 0) return; // pipe closed: normal shutdown already underway
        std.log.info("marlind: shutdown signal received", .{});
        w.daemon.events.push(w.daemon.io, .shutdown) catch {};
        // The dispatcher nudges the accept loop after it flips running=false;
        // nudging from here races the flag and can be eaten as a client.
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

const StopClientIoTestJob = struct {
    daemon: *Daemon,
    client: *Client,
    done: std.atomic.Value(bool) = .init(false),

    fn run(job: *StopClientIoTestJob) void {
        job.daemon.stopClientIo(job.client);
        job.done.store(true, .release);
    }
};

fn waitTestFlag(io: Io, flag: *const std.atomic.Value(bool), timeout_ms: u32) bool {
    var elapsed: u32 = 0;
    while (elapsed < timeout_ms) : (elapsed += 10) {
        if (flag.load(.acquire)) return true;
        io.sleep(.fromMilliseconds(10), .awake) catch return false;
    }
    return flag.load(.acquire);
}

test "instance lock rejects a second daemon and recovers on close" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-instance-lock");
    defer temp.deinit();
    const path = try std.fs.path.join(gpa, &.{ temp.path, "daemon.lock" });
    defer gpa.free(path);

    var first = try acquireInstanceLock(io, path);
    try std.testing.expectError(error.DaemonAlreadyRunning, acquireInstanceLock(io, path));
    first.close(io);
    var replacement = try acquireInstanceLock(io, path);
    replacement.close(io);
}

test "client teardown interrupts a writer blocked on a non-reading peer" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var peer = try server.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    var client_stream = try server.accept(io);
    defer client_stream.close(io);

    var daemon: Daemon = undefined;
    daemon.gpa = gpa;
    daemon.io = io;
    var client = Client{
        .id = 1,
        .stream = client_stream,
        .outbox = queue.Mpsc(OutboundLine).init(gpa),
    };
    defer client.outbox.deinit();
    client.writer_thread = try std.Thread.spawn(.{}, Daemon.clientWriter, .{ &daemon, &client });

    const line = try gpa.alloc(u8, 8 * 1024 * 1024);
    @memset(line, 'x');
    const queued_seq = daemon.enqueueLine(&client, line).?;
    var spin: u32 = 0;
    while (client.queued_outbox_bytes.load(.acquire) != 0 and spin < 100) : (spin += 1)
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    try std.testing.expectEqual(@as(usize, 0), client.queued_outbox_bytes.load(.acquire));
    // Dequeue/write-start is not delivery: the writer is blocked in write(2)
    // and must not publish this sequence as flushed.
    try std.testing.expect(client.flushed_outbox_seq.load(.acquire) < queued_seq);

    var stop = StopClientIoTestJob{ .daemon = &daemon, .client = &client };
    const stop_thread = try std.Thread.spawn(.{}, StopClientIoTestJob.run, .{&stop});
    if (!waitTestFlag(io, &stop.done, 2_000)) {
        // Test cleanup must remain finite even if the regression returns.
        peer.shutdown(io, .both) catch {};
        stop_thread.join();
        return error.ClientWriterTeardownHung;
    }
    stop_thread.join();
}

test "slow-client outbox is bounded" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    var peer = try server.socket.address.connect(io, .{ .mode = .stream });
    defer peer.close(io);
    var client_stream = try server.accept(io);
    defer client_stream.close(io);

    var daemon: Daemon = undefined;
    daemon.gpa = gpa;
    daemon.io = io;
    var client = Client{
        .id = 9,
        .stream = client_stream,
        .outbox = queue.Mpsc(OutboundLine).init(gpa),
        .queued_outbox_bytes = .init(max_client_outbox_bytes),
    };
    defer client.outbox.deinit();
    const rejected = try gpa.dupe(u8, "x");
    _ = daemon.enqueueLine(&client, rejected);
    try std.testing.expect(client.outbox.closed);
    try std.testing.expectEqual(max_client_outbox_bytes, client.queued_outbox_bytes.load(.acquire));
}

test "OpenRouter catalog normalizes pricing and tolerates bad entries" {
    const gpa = std.testing.allocator;
    const models = try parseCatalog(gpa,
        \\{"data":[
        \\  {"id":"paid","pricing":{"prompt":"0.000003","completion":"0.000015"}},
        \\  {"id":"free","pricing":{"prompt":"0","completion":0}},
        \\  {"id":"tiered","pricing":[{"prompt":"0.000002","completion":"0.000012"},{"prompt":"0.000004","completion":"0.000018","min_context":200000}]},
        \\  {"id":"numeric","pricing":{"prompt":0.000001,"completion":0.0000025}},
        \\  {"id":"broken","pricing":{"prompt":"not-a-number","completion":-1}},
        \\  {"id":""}, 7, {"name":"missing id"}
        \\]}
    );
    defer {
        for (models) |model| gpa.free(model.id);
        gpa.free(models);
    }

    try std.testing.expectEqual(@as(usize, 5), models.len);
    try std.testing.expectEqualStrings("openrouter/broken", models[0].id);
    try std.testing.expectEqual(@as(?f64, null), models[0].input_per_million);
    try std.testing.expectEqual(@as(?f64, null), models[0].output_per_million);
    try std.testing.expectEqualStrings("openrouter/free", models[1].id);
    try std.testing.expectEqual(@as(?f64, 0), models[1].input_per_million);
    try std.testing.expectEqual(@as(?f64, 0), models[1].output_per_million);
    try std.testing.expectApproxEqAbs(@as(f64, 1), models[2].input_per_million.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), models[2].output_per_million.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 3), models[3].input_per_million.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 15), models[3].output_per_million.?, 0.000001);
    try std.testing.expect(models[4].tiered);
    try std.testing.expectApproxEqAbs(@as(f64, 2), models[4].input_per_million.?, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 12), models[4].output_per_million.?, 0.000001);
}

test "OpenRouter catalog rejects a malformed envelope" {
    try std.testing.expectError(
        error.InvalidCatalog,
        parseCatalog(std.testing.allocator, "{\"data\":{}}"),
    );
}

test {
    std.testing.refAllDecls(@This());
}
