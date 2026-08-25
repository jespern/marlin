//! Socket client shared by TUI and headless: connect (with daemon autostart),
//! handshake, NDJSON read/write.
//!
//! DEPENDENCY RULE: client/ imports only core/ (never daemon/). This is what
//! keeps "the TUI is just a client" true.

const std = @import("std");
const Io = std.Io;
const proto = @import("../core/proto.zig");

pub const Conn = struct {
    gpa: std.mem.Allocator,
    io: Io,
    stream: Io.net.Stream,
    reader: Io.net.Stream.Reader,
    writer: Io.net.Stream.Writer,
    rbuf: []u8,
    wbuf: []u8,
    /// Daemon capabilities from hello_ok; populated by connect().
    sandbox_available: bool = false,
    network_filtering: bool = false,
    network_configured: bool = false,
    network_feed_count: u64 = 0,
    network_rule_count: u64 = 0,

    pub fn deinit(self: *Conn) void {
        self.stream.close(self.io);
        self.gpa.free(self.rbuf);
        self.gpa.free(self.wbuf);
        self.gpa.destroy(self);
    }

    pub fn send(self: *Conn, msg: proto.ClientMsg) !void {
        const line = try proto.encode(self.gpa, msg);
        defer self.gpa.free(line);
        try self.writer.interface.writeAll(line);
        try self.writer.interface.flush();
    }

    /// Read one owned wire record. Callers that need to retain the raw JSON
    /// (the TUI reader/SSE bridge) free it with this connection's allocator.
    pub fn readLine(self: *Conn) ![]u8 {
        return proto.readLineAlloc(self.gpa, &self.reader.interface);
    }

    /// Read one DaemonMsg. Returned value references `arena` memory.
    pub fn recv(self: *Conn, arena: std.mem.Allocator) !proto.DaemonMsg {
        const line = try self.readLine();
        defer self.gpa.free(line);
        return proto.decode(proto.DaemonMsg, arena, line);
    }

    /// Read messages until one matches the given tag; err messages become
    /// error.DaemonError (logged). Anything else is passed to `on_other`
    /// (may be null to ignore).
    pub fn recvUntil(
        self: *Conn,
        arena: std.mem.Allocator,
        comptime tag: std.meta.Tag(proto.DaemonMsg),
    ) !@FieldType(proto.DaemonMsg, @tagName(tag)) {
        while (true) {
            const msg = try self.recv(arena);
            if (msg == tag) return @field(msg, @tagName(tag));
            if (msg == .err) {
                std.log.err("daemon: {s}: {s}", .{ msg.err.code, msg.err.msg });
                return error.DaemonError;
            }
            // Ignore interleaved fan-out (deltas/blocks for other sessions).
        }
    }
};

/// Connect to the daemon socket; returns null when nothing is listening.
pub fn tryConnect(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !?*Conn {
    const sock_path = try proto.socketPath(gpa, environ);
    defer gpa.free(sock_path);

    const ua = Io.net.UnixAddress.init(sock_path) catch return null;
    const stream = ua.connect(io) catch return null;

    const conn = try gpa.create(Conn);
    errdefer gpa.destroy(conn);
    // Scratch space is intentionally much smaller than max_line_bytes;
    // readLine grows only for the occasional large record.
    const rbuf = try gpa.alloc(u8, 64 * 1024);
    errdefer gpa.free(rbuf);
    const wbuf = try gpa.alloc(u8, 256 * 1024);
    errdefer gpa.free(wbuf);
    conn.* = .{
        .gpa = gpa,
        .io = io,
        .stream = stream,
        .reader = Io.net.Stream.Reader.init(stream, io, rbuf),
        .writer = Io.net.Stream.Writer.init(stream, io, wbuf),
        .rbuf = rbuf,
        .wbuf = wbuf,
    };
    return conn;
}

fn isTransientHandshakeError(err: anyerror) bool {
    return switch (err) {
        error.EndOfStream,
        error.ConnectionResetByPeer,
        error.ConnectionAborted,
        error.BrokenPipe,
        error.NotOpenForReading,
        error.NotOpenForWriting,
        => true,
        else => false,
    };
}

const handshake_timeout_ms: u32 = 2_000;

const HandshakeDeadline = struct {
    conn: *Conn,
    done: Io.Event = .unset,
    fired: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn start(self: *HandshakeDeadline) !void {
        self.thread = try std.Thread.spawn(.{}, watch, .{self});
    }

    fn finish(self: *HandshakeDeadline) void {
        self.done.set(self.conn.io);
        self.thread.join();
    }

    fn watch(self: *HandshakeDeadline) void {
        self.done.waitTimeout(self.conn.io, .{ .duration = .{
            .raw = .fromMilliseconds(handshake_timeout_ms),
            .clock = .awake,
        } }) catch |err| switch (err) {
            error.Timeout => {
                self.fired.store(true, .release);
                self.conn.stream.shutdown(self.conn.io, .both) catch {};
            },
            error.Canceled => return,
        };
    }
};

fn handshake(conn: *Conn) !void {
    var deadline = HandshakeDeadline{ .conn = conn };
    try deadline.start();
    defer deadline.finish();

    try conn.send(.{ .hello = .{ .proto_version = proto.proto_version } });
    var arena_state = std.heap.ArenaAllocator.init(conn.gpa);
    defer arena_state.deinit();
    const hello = conn.recvUntil(arena_state.allocator(), .hello_ok) catch |err| {
        if (deadline.fired.load(.acquire)) return error.DaemonHandshakeTimedOut;
        return err;
    };
    if (deadline.fired.load(.acquire)) return error.DaemonHandshakeTimedOut;
    conn.sandbox_available = hello.sandbox_available;
    conn.network_filtering = hello.network_filtering;
    conn.network_configured = hello.network_configured;
    conn.network_feed_count = hello.network_feed_count;
    conn.network_rule_count = hello.network_rule_count;
}

/// Connect, autostarting the daemon if needed. Handshakes (hello/hello_ok).
pub fn connect(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
) !*Conn {
    var spawned = false;
    var attempt: u32 = 0;
    while (attempt < 100) : (attempt += 1) {
        const conn = try tryConnect(gpa, io, environ);
        if (conn) |candidate| {
            handshake(candidate) catch |err| {
                candidate.deinit();
                if (!isTransientHandshakeError(err)) return err;
                io.sleep(.fromMilliseconds(50), .awake) catch {};
                continue;
            };
            return candidate;
        }

        if (!spawned) {
            // Autostart once, then poll the whole connect+hello handshake.
            // During reboot the old socket may accept one last connection
            // and close it before hello_ok; that is not daemon readiness.
            var child = try std.process.spawn(io, .{
                .argv = &.{ self_exe, "daemon" },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
                // Production daemons detach into their own group. The E2E
                // runner opts into inheritance so one outer cancellation can
                // reliably terminate its complete scenario tree.
                .pgid = if (environ.get("MARLIN_DAEMON_PGID")) |mode|
                    if (std.mem.eql(u8, mode, "inherit")) null else 0
                else
                    0,
            });
            _ = &child; // deliberately not waited/killed
            spawned = true;
        }
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
    return error.DaemonStartFailed;
}

const FlakyHelloServer = struct {
    io: Io,
    server: *Io.net.Server,
    failed: std.atomic.Value(bool) = .init(false),

    fn readHello(self: *FlakyHelloServer, stream: Io.net.Stream) !void {
        var rbuf: [4096]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, self.io, &rbuf);
        const line = try reader.interface.takeDelimiterInclusive('\n');
        if (!std.mem.startsWith(u8, line, "{\"hello\":")) return error.BadHello;
    }

    fn serve(self: *FlakyHelloServer) !void {
        {
            var first = try self.server.accept(self.io);
            defer first.close(self.io);
            try self.readHello(first);
        }

        var second = try self.server.accept(self.io);
        defer second.close(self.io);
        try self.readHello(second);
        var wbuf: [1024]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(second, self.io, &wbuf);
        try writer.interface.writeAll(
            "{\"hello_ok\":{\"proto_version\":1,\"daemon_version\":\"test\",\"network_filtering\":true}}\n",
        );
        try writer.interface.flush();
    }

    fn run(self: *FlakyHelloServer) void {
        self.serve() catch self.failed.store(true, .release);
    }
};

const SilentHelloServer = struct {
    io: Io,
    server: *Io.net.Server,
    failed: std.atomic.Value(bool) = .init(false),

    fn serve(self: *SilentHelloServer) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var rbuf: [4096]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, self.io, &rbuf);
        _ = try reader.interface.takeDelimiterInclusive('\n');
        // Deliberately never send hello_ok. The client's absolute handshake
        // deadline shuts down both directions and releases this read.
        _ = reader.interface.takeDelimiterInclusive('\n') catch return;
        return error.UnexpectedSecondMessage;
    }

    fn run(self: *SilentHelloServer) void {
        self.serve() catch self.failed.store(true, .release);
    }
};

test "connect retries when a dying daemon closes during hello" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-attach");
    defer temp.deinit();
    const socket_path = try std.fs.path.join(gpa, &.{ temp.path, "daemon.sock" });
    defer gpa.free(socket_path);

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MARLIN_SOCKET", socket_path);

    const ua = try Io.net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);
    var flaky = FlakyHelloServer{ .io = io, .server = &server };
    const thread = try std.Thread.spawn(.{}, FlakyHelloServer.run, .{&flaky});
    var joined = false;
    defer if (!joined) {
        if (ua.connect(io)) |wake| wake.close(io) else |_| {}
        thread.join();
    };

    const conn = try connect(gpa, io, &environ, "/unused/marlin");
    defer conn.deinit();
    thread.join();
    joined = true;

    try std.testing.expect(!flaky.failed.load(.acquire));
    try std.testing.expect(conn.network_filtering);
}

test "connect times out when an accepted socket never completes hello" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-attach-timeout");
    defer temp.deinit();
    const socket_path = try std.fs.path.join(gpa, &.{ temp.path, "daemon.sock" });
    defer gpa.free(socket_path);

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MARLIN_SOCKET", socket_path);

    const ua = try Io.net.UnixAddress.init(socket_path);
    var server = try ua.listen(io, .{});
    defer server.deinit(io);
    var silent = SilentHelloServer{ .io = io, .server = &server };
    const thread = try std.Thread.spawn(.{}, SilentHelloServer.run, .{&silent});
    defer thread.join();

    try std.testing.expectError(
        error.DaemonHandshakeTimedOut,
        connect(gpa, io, &environ, "/unused/marlin"),
    );
    try std.testing.expect(!silent.failed.load(.acquire));
}

test {
    std.testing.refAllDecls(@This());
}
