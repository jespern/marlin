//! Unit tests for http.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in http.zig.

const std = @import("std");
const Io = std.Io;
const process_io = @import("../process_io.zig");

const http = @import("http.zig");
const Client = http.Client;
const Error = http.Error;
const Pool = http.Pool;
const Response = http.Response;
const StreamRequest = http.StreamRequest;
const discardChunk = http.discardChunk;
const ensureTlsReady = http.ensureTlsReady;
const lastTransportCause = http.lastTransportCause;
const readTestRequest = http.readTestRequest;
const serveDelayedResponse = http.serveDelayedResponse;
const streamPost = http.streamPost;
const streamPostTask = http.streamPostTask;
const testUrl = http.testUrl;
const writeTestResponse = http.writeTestResponse;

test {
    std.testing.refAllDecls(http);
}

fn acceptAndClose(io: Io, server: *Io.net.Server) void {
    var stream = server.accept(io) catch return;
    stream.close(io);
}

fn testServer(io: Io) !Io.net.Server {
    const address = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    return address.listen(io, .{ .reuse_address = true });
}

fn rejectChunk(_: void, _: []const u8) bool {
    return false;
}

fn requestCompletes(
    io: Io,
    server: *Io.net.Server,
    cancel: *std.atomic.Value(bool),
    server_delay_ms: i64,
    connect_timeout_ms: i64,
    response_head_timeout_ms: i64,
) !void {
    const gpa = std.testing.allocator;
    const url = try testUrl(gpa, server);
    defer gpa.free(url);
    const RequestResult = Error!Response;
    const Select = Io.Select(union(enum) { serve: void, request: RequestResult });
    var results: [2]Select.Union = undefined;
    var select = Select.init(io, &results);
    defer select.cancelDiscard();
    select.async(.serve, serveDelayedResponse, .{ io, server, server_delay_ms, "ok" });
    select.async(.request, streamPostTask(void, discardChunk), .{ gpa, io, StreamRequest{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .connect_timeout_ms = connect_timeout_ms,
        .response_head_timeout_ms = response_head_timeout_ms,
        .idle_timeout_ms = response_head_timeout_ms,
        .cancel = cancel,
    }, {} });

    while (true) switch (try select.await()) {
        .request => |result| {
            const response = try result;
            if (response.error_body) |body| gpa.free(body);
            return;
        },
        // The server task can finish first if the peer closes early. The
        // request result is the assertion target, so always wait for it.
        .serve => {},
    };
}

fn serveClosedKeepAliveThenFresh(
    io: Io,
    server: *Io.net.Server,
    first_closed: *std.atomic.Value(bool),
    accepted: *std.atomic.Value(u32),
) void {
    var first = server.accept(io) catch return;
    _ = accepted.fetchAdd(1, .release);
    readTestRequest(io, first) catch {
        first.close(io);
        return;
    };
    writeTestResponse(io, first, true) catch {
        first.close(io);
        return;
    };
    // Deliberately violate the advertised keep-alive after completing the
    // response, exactly like a CDN idle timeout does between turns.
    first.close(io);
    first_closed.store(true, .release);

    var second = server.accept(io) catch return;
    defer second.close(io);
    _ = accepted.fetchAdd(1, .release);
    readTestRequest(io, second) catch return;
    writeTestResponse(io, second, false) catch return;
}

fn serveTwoRequestsOnOneConnection(
    io: Io,
    server: *Io.net.Server,
    accepted: *std.atomic.Value(u32),
) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    _ = accepted.fetchAdd(1, .release);
    readTestRequest(io, stream) catch return;
    writeTestResponse(io, stream, true) catch return;
    readTestRequest(io, stream) catch return;
    writeTestResponse(io, stream, false) catch return;
}

fn expectPostOk(client: *Client, gpa: std.mem.Allocator, url: [:0]const u8) !void {
    const response = try client.streamPost(gpa, .{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .connect_timeout_ms = 2_000,
        .idle_timeout_ms = 2_000,
    }, {}, discardChunk);
    defer if (response.error_body) |body| gpa.free(body);
    try std.testing.expectEqual(@as(i64, 200), response.status);
}

fn serveSseInBursts(io: Io, server: *Io.net.Server) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    var read_buffer: [8192]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buffer);
    // Streaming requests must refuse compression: behind a gzip window,
    // deltas arrive in whole-window bursts. 406 fails the test if the
    // identity requirement ever regresses.
    var asked_identity = false;
    while (reader.interface.takeDelimiterInclusive('\n') catch null) |line| {
        const trimmed = std.mem.trim(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "accept-encoding:") and
            std.mem.indexOf(u8, trimmed, "identity") != null) asked_identity = true;
    }
    var write_buffer: [8192]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buffer);
    if (!asked_identity) {
        writer.interface.writeAll("HTTP/1.1 406 Not Acceptable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n") catch return;
        writer.interface.flush() catch return;
        return;
    }
    writer.interface.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n") catch return;
    writer.interface.flush() catch return;
    // Three bursts with pauses, like a live provider: each must reach the
    // caller's on_chunk promptly, not be held for a fill quota or EOF.
    const bursts = [_][]const u8{
        "data: {\"one\":1}\n\n",
        "data: {\"two\":2}\n\n",
        "data: [DONE]\n\n",
    };
    for (bursts) |burst| {
        writer.interface.writeAll(burst) catch return;
        writer.interface.flush() catch return;
        io.sleep(.fromMilliseconds(150), .awake) catch return;
    }
}

test "flattened transport errors record their underlying cause" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Bind a port, then free it: connecting to it is a guaranteed refusal.
    var server = try testServer(io);
    const port = server.socket.address.getPort();
    server.deinit(io);
    const url = try std.fmt.allocPrintSentinel(gpa, "http://127.0.0.1:{d}/x", .{port}, 0);
    defer gpa.free(url);

    const result = streamPost(gpa, io, .{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .connect_timeout_ms = 2_000,
        .idle_timeout_ms = 2_000,
    }, {}, discardChunk);
    try std.testing.expectError(error.ConnectFailed, result);
    // The whole point of the side channel: the flattened error still names
    // the std-level cause for the failure note.
    try std.testing.expect(lastTransportCause() != null);
}

test "direct TLS connect initializes the certificate clock (no null-now panic)" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try Pool.init(gpa, io, null);
    defer pool.deinit();
    // A fresh pool has no certificate clock; request() would set it lazily,
    // but the DNS-preflight path connects TLS directly.
    try std.testing.expect(pool.client.now == null);
    try ensureTlsReady(&pool.client);
    try std.testing.expect(pool.client.now != null);

    // With the clock set, a direct TLS connect to a peer that immediately
    // hangs up must fail with an ordinary error. Before the fix this path
    // panicked on `client.now.?` in Debug and was UB in release.
    var server = try testServer(io);
    defer server.deinit(io);
    const t = try std.Thread.spawn(.{}, acceptAndClose, .{ io, &server });
    defer t.join();
    const host = Io.net.HostName.init("127.0.0.1") catch unreachable;
    const result = pool.client.connectTcpOptions(.{
        .host = host,
        .port = server.socket.address.getPort(),
        .protocol = .tls,
    });
    if (result) |connection| {
        pool.client.connection_pool.release(connection, io);
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "stream cancellation interrupts a blocked response" {
    const gpa = std.testing.allocator;
    // Keep the async pool deliberately saturated so this test proves that the
    // request and watchdog use guaranteed concurrency rather than running
    // inline behind the mock server.
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    defer server.deinit(io);
    const url = try testUrl(gpa, &server);
    defer gpa.free(url);
    var cancel: std.atomic.Value(bool) = .init(false);

    const RequestResult = Error!Response;
    const Select = Io.Select(union(enum) { serve: void, request: RequestResult });
    var results: [2]Select.Union = undefined;
    var select = Select.init(io, &results);
    defer select.cancelDiscard();
    select.async(.serve, serveDelayedResponse, .{ io, &server, 5_000, "ok" });
    select.async(.request, streamPostTask(void, discardChunk), .{ gpa, io, StreamRequest{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .idle_timeout_ms = 10_000,
        .cancel = &cancel,
    }, {} });
    try io.sleep(.fromMilliseconds(100), .awake);
    cancel.store(true, .release);

    while (true) switch (try select.await()) {
        .request => |result| {
            try std.testing.expectError(error.Cancelled, result);
            return;
        },
        .serve => {},
    };
}

test "stream response-head timeout aborts a silent provider" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    defer server.deinit(io);
    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.HttpTimeout, requestCompletes(io, &server, &cancel, 5_000, 2_000, 100));
}

test "connected provider may take longer than connect timeout to return headers" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    defer server.deinit(io);
    var cancel: std.atomic.Value(bool) = .init(false);

    // The TCP connection is immediate, then the mock model thinks for 250ms.
    // A 25ms connection budget must not become a 25ms response-head budget.
    try requestCompletes(io, &server, &cancel, 250, 25, 2_000);
}

test "std HTTP pool returns clients sharing one connection pool" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var pool = try Pool.init(std.testing.allocator, threaded.io(), null);
    defer pool.deinit();

    var first = try pool.acquire();
    defer first.deinit();
    var second = try pool.acquire();
    defer second.deinit();
    try std.testing.expectEqual(first.client, second.client);
}

test "stale keep-alive connection is evicted before the next POST" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    const url = try testUrl(gpa, &server);
    defer gpa.free(url);
    var first_closed: std.atomic.Value(bool) = .init(false);
    var accepted: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, serveClosedKeepAliveThenFresh, .{ io, &server, &first_closed, &accepted });
    defer thread.join();
    defer server.deinit(io);

    var pool = try Pool.init(gpa, io, null);
    defer pool.deinit();
    var client = try pool.acquire();
    defer client.deinit();
    try expectPostOk(&client, gpa, url);
    for (0..200) |_| {
        if (first_closed.load(.acquire)) break;
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(first_closed.load(.acquire));
    try expectPostOk(&client, gpa, url);
    try std.testing.expectEqual(@as(u32, 2), accepted.load(.acquire));
}

test "healthy keep-alive connection is reused for the next POST" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    const url = try testUrl(gpa, &server);
    defer gpa.free(url);
    var accepted: std.atomic.Value(u32) = .init(0);
    const thread = try std.Thread.spawn(.{}, serveTwoRequestsOnOneConnection, .{ io, &server, &accepted });
    defer thread.join();
    defer server.deinit(io);

    var pool = try Pool.init(gpa, io, null);
    defer pool.deinit();
    var client = try pool.acquire();
    defer client.deinit();
    try expectPostOk(&client, gpa, url);
    try expectPostOk(&client, gpa, url);
    try std.testing.expectEqual(@as(u32, 1), accepted.load(.acquire));
}

test "streaming delivers every burst to on_chunk, promptly and in full" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var server = try testServer(io);
    defer server.deinit(io);
    const url = try testUrl(gpa, &server);
    defer gpa.free(url);

    const Collector = struct {
        var collected: std.ArrayList(u8) = .empty;
        var chunks: usize = 0;
        fn onChunk(alloc: std.mem.Allocator, bytes: []const u8) bool {
            collected.appendSlice(alloc, bytes) catch {};
            chunks += 1;
            return true;
        }
    };
    defer Collector.collected.deinit(gpa);

    const Select = Io.Select(union(enum) { serve: void, request: Error!Response });
    var results: [2]Select.Union = undefined;
    var select = Select.init(io, &results);
    defer select.cancelDiscard();
    select.async(.serve, serveSseInBursts, .{ io, &server });
    select.async(.request, streamPostTask(std.mem.Allocator, Collector.onChunk), .{ gpa, io, StreamRequest{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .connect_timeout_ms = 5_000,
        .idle_timeout_ms = 5_000,
    }, gpa });

    var status: i64 = 0;
    var served = false;
    var requested = false;
    while (!served or !requested) switch (try select.await()) {
        .serve => served = true,
        .request => |result| {
            const response = try result;
            if (response.error_body) |body| gpa.free(body);
            status = response.status;
            requested = true;
        },
    };
    try std.testing.expectEqual(@as(i64, 200), status);
    try std.testing.expectEqualStrings(
        "data: {\"one\":1}\n\ndata: {\"two\":2}\n\ndata: [DONE]\n\n",
        Collector.collected.items,
    );
    try std.testing.expect(Collector.chunks >= 3);
}

test "streaming consumer can abort a live response immediately" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    defer server.deinit(io);
    const url = try testUrl(gpa, &server);
    defer gpa.free(url);

    const Select = Io.Select(union(enum) { serve: void, request: Error!Response });
    var results: [2]Select.Union = undefined;
    var select = Select.init(io, &results);
    defer select.cancelDiscard();
    select.async(.serve, serveSseInBursts, .{ io, &server });
    select.async(.request, streamPostTask(void, rejectChunk), .{ gpa, io, StreamRequest{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .connect_timeout_ms = 5_000,
        .idle_timeout_ms = 5_000,
    }, {} });

    while (true) switch (try select.await()) {
        .serve => {},
        .request => |result| {
            try std.testing.expectError(error.ConsumerAborted, result);
            return;
        },
    };
}

test "absolute stream deadline cannot be extended by request activity" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    defer server.deinit(io);
    const url = try testUrl(gpa, &server);
    defer gpa.free(url);

    const Select = Io.Select(union(enum) { serve: void, request: Error!Response });
    var results: [2]Select.Union = undefined;
    var select = Select.init(io, &results);
    defer select.cancelDiscard();
    select.async(.serve, serveDelayedResponse, .{ io, &server, 5_000, "ok" });
    select.async(.request, streamPostTask(void, discardChunk), .{ gpa, io, StreamRequest{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .connect_timeout_ms = 10_000,
        .idle_timeout_ms = 10_000,
        .total_timeout_ms = 100,
    }, {} });

    while (true) switch (try select.await()) {
        .serve => {},
        .request => |result| {
            try std.testing.expectError(error.HttpTimeout, result);
            return;
        },
    };
}
