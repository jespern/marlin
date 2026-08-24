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

    /// Read one DaemonMsg. Returned value references `arena` memory.
    pub fn recv(self: *Conn, arena: std.mem.Allocator) !proto.DaemonMsg {
        const line = try self.reader.interface.takeDelimiterInclusive('\n');
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
    const rbuf = try gpa.alloc(u8, 1024 * 1024);
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

/// Connect, autostarting the daemon if needed. Handshakes (hello/hello_ok).
pub fn connect(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
) !*Conn {
    var conn = try tryConnect(gpa, io, environ);
    if (conn == null) {
        // Autostart: spawn `<self> daemon` and never wait on it. When this
        // client exits, the daemon is reparented to init and lives on.
        // Own process group: the daemon must not receive the terminal's
        // SIGHUP/SIGINT when the spawning client's TTY goes away.
        var child = try std.process.spawn(io, .{
            .argv = &.{ self_exe, "daemon" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        });
        _ = &child; // deliberately not waited/killed

        var attempt: u32 = 0;
        while (attempt < 100) : (attempt += 1) {
            io.sleep(.fromMilliseconds(50), .awake) catch {};
            conn = try tryConnect(gpa, io, environ);
            if (conn != null) break;
        }
        if (conn == null) return error.DaemonStartFailed;
    }

    const c = conn.?;
    errdefer c.deinit();
    try c.send(.{ .hello = .{ .proto_version = proto.proto_version } });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const hello = try c.recvUntil(arena_state.allocator(), .hello_ok);
    c.sandbox_available = hello.sandbox_available;
    c.network_filtering = hello.network_filtering;
    c.network_feed_count = hello.network_feed_count;
    c.network_rule_count = hello.network_rule_count;
    return c;
}

test {
    std.testing.refAllDecls(@This());
}
