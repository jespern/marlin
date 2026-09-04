//! Unit tests for attach.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in attach.zig.

const std = @import("std");
const Io = std.Io;
const proto = @import("../core/proto.zig");

const attach = @import("attach.zig");
const ConnectCancel = attach.ConnectCancel;
const connect = attach.connect;
const handshake = attach.handshake;
const spawnChildConn = attach.spawnChildConn;

test {
    std.testing.refAllDecls(attach);
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
            "{\"hello_ok\":{\"proto_version\":2,\"daemon_version\":\"test\",\"network_filtering\":true}}\n",
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

test "child transport handshakes over subprocess stdio" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A fake `_pipe`: consume the hello line, answer hello_ok, then swallow
    // everything until stdin EOF (which deinit provides by closing it).
    const conn = try spawnChildConn(gpa, io, &.{
        "/bin/sh",                                                                                                                             "-c",
        "read line; printf '{\"hello_ok\":{\"proto_version\":2,\"daemon_version\":\"fake\",\"sandbox_available\":true}}\\n'; cat > /dev/null",
    });
    handshake(conn, 5_000, null) catch |err| {
        conn.deinit();
        return err;
    };
    defer conn.deinit();
    try std.testing.expect(conn.sandbox_available);
    try std.testing.expect(conn.transport == .child);
}

test "handshake cancellation interrupts a blocked child transport" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const conn = try spawnChildConn(gpa, io, &.{ "/bin/sh", "-c", "read line; sleep 30" });
    var cancel = ConnectCancel{};
    const CancelJob = struct {
        io: Io,
        cancel: *ConnectCancel,

        fn run(job: *@This()) void {
            job.io.sleep(.fromMilliseconds(100), .awake) catch {};
            job.cancel.cancel();
        }
    };
    var job = CancelJob{ .io = io, .cancel = &cancel };
    const thread = try std.Thread.spawn(.{}, CancelJob.run, .{&job});
    defer thread.join();

    try std.testing.expectError(error.ConnectCanceled, handshake(conn, 5_000, &cancel));
    conn.deinit();
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
