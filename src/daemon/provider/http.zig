//! HTTP layer backed by Zig's standard HTTP client.
//!
//! Provider requests stream response bytes into the SSE parser. A daemon-owned
//! client pool retains HTTP/TLS connections across turns; bounded GETs use the
//! same transport for fetch, catalogs, and network blocklists.

const std = @import("std");
const Io = std.Io;

/// The complete failure vocabulary of this layer. Typed on purpose: the
/// block log must be able to distinguish "user interrupted" from "provider
/// hung" from "transport died mid-body" — anyerror soup misreported a hung
/// stream as a model failure. Underlying std.http causes are flattened; the
/// interesting ones are logged at debug before mapping.
pub const Error = error{
    /// The caller's cancel flag was observed, or the Io runtime cancelled us
    /// (daemon shutdown).
    Cancelled,
    /// The watchdog fired: no response head within connect_timeout_ms, or no
    /// body bytes within idle_timeout_ms.
    HttpTimeout,
    /// The request could not even be formed: unparseable URL or malformed
    /// extra-header line.
    InvalidRequest,
    /// Connect/TLS/proxy/send failed, or the connection died before the
    /// response head arrived — nothing of the response was received.
    ConnectFailed,
    /// The response head arrived but the body failed mid-read (peer reset,
    /// TLS damage, protocol error).
    ReadFailed,
    /// The response used a content-encoding this path refuses.
    UnsupportedEncoding,
    /// A request/watchdog task pair could not be started; the request was
    /// not attempted.
    ConcurrencyUnavailable,
    OutOfMemory,
};

/// Classify a transport failure from before any body bytes arrived.
fn mapConnect(err: anyerror) Error {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    std.log.debug("http connect-phase failure: {t}", .{err});
    return error.ConnectFailed;
}

pub const Response = struct {
    status: i64,
    /// Collected error body when status >= 400 (allocated, caller frees).
    error_body: ?[]u8,
};

pub const StreamRequest = struct {
    url: [:0]const u8,
    bearer: ?[]const u8,
    body_json: []const u8,
    /// Extra headers as complete `Name: value` lines.
    extra_headers: []const []const u8 = &.{},
    connect_timeout_ms: i64 = 10_000,
    /// Abort if no response bytes arrive for this long.
    idle_timeout_ms: i64 = 120_000,
    cancel: ?*std.atomic.Value(bool) = null,
};

/// Daemon-owned std.http client. std.http's connection pool is threadsafe;
/// individual requests remain exclusive to their turn thread.
pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: Io,
    client: std.http.Client,
    proxy_arena: std.heap.ArenaAllocator,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        environ: ?*const std.process.Environ.Map,
    ) !Pool {
        var self = Pool{
            .gpa = gpa,
            .io = io,
            .client = .{ .allocator = gpa, .io = io },
            .proxy_arena = std.heap.ArenaAllocator.init(gpa),
        };
        errdefer self.client.deinit();
        errdefer self.proxy_arena.deinit();
        if (environ) |env| try self.client.initDefaultProxies(self.proxy_arena.allocator(), env);
        return self;
    }

    pub fn deinit(self: *Pool) void {
        self.client.deinit();
        self.proxy_arena.deinit();
        self.* = undefined;
    }

    pub fn acquire(self: *Pool) Error!Client {
        return .{ .client = &self.client };
    }
};

pub const Client = struct {
    client: *std.http.Client,
    owned: ?*std.http.Client = null,

    pub fn init(gpa: std.mem.Allocator, io: Io) Error!Client {
        const client = try gpa.create(std.http.Client);
        client.* = .{ .allocator = gpa, .io = io };
        return .{ .client = client, .owned = client };
    }

    pub fn deinit(self: *Client) void {
        if (self.owned) |owned| {
            const allocator = owned.allocator;
            owned.deinit();
            allocator.destroy(owned);
        }
        self.* = undefined;
    }

    pub fn streamPost(
        self: *Client,
        gpa: std.mem.Allocator,
        req: StreamRequest,
        ctx: anytype,
        comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
    ) Error!Response {
        return streamPostTimed(self.client, gpa, req, ctx, on_chunk);
    }
};

pub fn streamPost(
    gpa: std.mem.Allocator,
    io: Io,
    req: StreamRequest,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
) Error!Response {
    var client = try Client.init(gpa, io);
    defer client.deinit();
    return client.streamPost(gpa, req, ctx, on_chunk);
}

const Abort = enum { cancelled, timed_out };

const StreamProgress = struct {
    response_started: std.atomic.Value(bool) = .init(false),
    activity_generation: std.atomic.Value(u64) = .init(0),
};

fn streamPostTimed(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    stream_req: StreamRequest,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
) Error!Response {
    const RunResult = Error!Response;
    const Select = Io.Select(union(enum) {
        request: RunResult,
        watchdog: Abort,
    });
    var progress = StreamProgress{};
    var results: [2]Select.Union = undefined;
    var select = Select.init(client.io, &results);
    select.concurrent(.request, streamPostImpl(@TypeOf(ctx), on_chunk), .{ client, gpa, stream_req, ctx, &progress }) catch
        return error.ConcurrencyUnavailable;
    select.concurrent(.watchdog, waitForStreamAbort, .{ client.io, stream_req.cancel, &progress, stream_req.connect_timeout_ms, stream_req.idle_timeout_ms }) catch
        return error.ConcurrencyUnavailable;

    // Io-level cancellation (daemon shutdown) folds into Cancelled.
    const first = select.await() catch return error.Cancelled;
    return switch (first) {
        .request => |result| blk: {
            select.cancelDiscard();
            break :blk result;
        },
        .watchdog => |reason| blk: {
            select.cancelDiscard();
            break :blk switch (reason) {
                .cancelled => error.Cancelled,
                .timed_out => error.HttpTimeout,
            };
        },
    };
}

fn streamPostImpl(
    comptime Ctx: type,
    comptime on_chunk: fn (Ctx, []const u8) void,
) fn (*std.http.Client, std.mem.Allocator, StreamRequest, Ctx, *StreamProgress) Error!Response {
    return struct {
        fn run(
            client: *std.http.Client,
            gpa: std.mem.Allocator,
            stream_req: StreamRequest,
            ctx: Ctx,
            progress: *StreamProgress,
        ) Error!Response {
            return streamPostRun(client, gpa, stream_req, ctx, progress, on_chunk);
        }
    }.run;
}

fn streamPostRun(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    stream_req: StreamRequest,
    ctx: anytype,
    progress: *StreamProgress,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
) Error!Response {
    if (isCancelled(stream_req.cancel)) return error.Cancelled;

    const uri = std.Uri.parse(stream_req.url) catch return error.InvalidRequest;
    var header_storage = try gpa.alloc(std.http.Header, stream_req.extra_headers.len);
    defer gpa.free(header_storage);
    for (stream_req.extra_headers, 0..) |line, i| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidRequest;
        header_storage[i] = .{
            .name = std.mem.trim(u8, line[0..colon], " \t"),
            .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
        };
        if (header_storage[i].name.len == 0) return error.InvalidRequest;
    }

    var auth_storage: ?[]u8 = null;
    defer if (auth_storage) |auth| gpa.free(auth);
    const authorization: std.http.Client.Request.Headers.Value = if (stream_req.bearer) |token| blk: {
        auth_storage = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
        break :blk .{ .override = auth_storage.? };
    } else .omit;

    var request = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = authorization,
            .user_agent = .{ .override = "marlin/0.0" },
            .content_type = .{ .override = "application/json" },
            // Streaming must never sit behind a decompression window: a
            // gzipped SSE stream buffers whole windows before yielding, so
            // deltas arrive in bursts minutes late (or only at stream end).
            .accept_encoding = .{ .override = "identity" },
        },
        .extra_headers = header_storage,
    }) catch |err| return mapConnect(err);
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = stream_req.body_json.len };
    var body_writer = request.sendBodyUnflushed(&.{}) catch |err| return mapConnect(err);
    body_writer.writer.writeAll(stream_req.body_json) catch return error.ConnectFailed;
    body_writer.end() catch return error.ConnectFailed;
    request.connection.?.flush() catch return error.ConnectFailed;

    var response = request.receiveHead(&.{}) catch |err| return mapConnect(err);
    progress.response_started.store(true, .release);
    markActivity(progress);
    const status: i64 = @intFromEnum(response.head.status);
    const is_error = status >= 400;

    var error_body: std.ArrayList(u8) = .empty;
    errdefer error_body.deinit(gpa);
    var transfer_buffer: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buffer);

    while (true) {
        if (isCancelled(stream_req.cancel)) {
            if (request.connection) |connection| connection.closing = true;
            return error.Cancelled;
        }
        // Deliver whatever has arrived, as soon as one byte exists.
        // readSliceShort would block until its whole buffer filled, holding
        // live deltas hostage to a fill quota (worst case: until EOF).
        reader.fill(1) catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => {
                if (response.bodyErr()) |cause| std.log.debug("stream body failure: {t}", .{cause});
                return error.ReadFailed;
            },
        };
        const bytes = reader.buffered();
        markActivity(progress);
        if (is_error) {
            const room = 64 * 1024 - error_body.items.len;
            if (room > 0) try error_body.appendSlice(gpa, bytes[0..@min(bytes.len, room)]);
        } else {
            on_chunk(ctx, bytes);
        }
        reader.toss(bytes.len);
    }

    return .{
        .status = status,
        .error_body = if (is_error) try error_body.toOwnedSlice(gpa) else null,
    };
}

pub const GetResult = struct {
    status: i64,
    body: []u8,
    content_type: ?[]u8,
};

pub const GetOneResult = struct {
    status: i64,
    body: []u8,
    content_type: ?[]u8,
    location: ?[]u8,
};

/// Bounded GET following up to five redirects.
pub fn get(
    gpa: std.mem.Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
    url: [:0]const u8,
    max_bytes: usize,
    timeout_ms: i64,
    cancel: ?*std.atomic.Value(bool),
) Error!GetResult {
    var pool = Pool.init(gpa, io, environ) catch |err| return mapConnect(err);
    defer pool.deinit();
    const result = try getImpl(&pool.client, gpa, url, max_bytes, timeout_ms, cancel, .init(5));
    if (result.location) |location| gpa.free(location);
    return .{ .status = result.status, .body = result.body, .content_type = result.content_type };
}

/// Bounded GET without following redirects. The fetch tool authorizes every
/// hop before making the next request.
pub fn getOne(
    gpa: std.mem.Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
    url: [:0]const u8,
    max_bytes: usize,
    timeout_ms: i64,
    cancel: ?*std.atomic.Value(bool),
) Error!GetOneResult {
    var pool = Pool.init(gpa, io, environ) catch |err| return mapConnect(err);
    defer pool.deinit();
    return getImpl(&pool.client, gpa, url, max_bytes, timeout_ms, cancel, .unhandled);
}

fn getImpl(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    url: []const u8,
    max_bytes: usize,
    timeout_ms: i64,
    cancel: ?*std.atomic.Value(bool),
    redirect_behavior: std.http.Client.Request.RedirectBehavior,
) Error!GetOneResult {
    const RunResult = Error!GetOneResult;
    const Select = Io.Select(union(enum) {
        request: RunResult,
        watchdog: Abort,
    });
    var results: [2]Select.Union = undefined;
    var select = Select.init(client.io, &results);
    select.concurrent(.request, getRun, .{ client, gpa, url, max_bytes, cancel, redirect_behavior }) catch
        return error.ConcurrencyUnavailable;
    select.concurrent(.watchdog, waitForAbort, .{ client.io, cancel, timeout_ms }) catch
        return error.ConcurrencyUnavailable;

    // Io-level cancellation (daemon shutdown) folds into Cancelled.
    const first = select.await() catch return error.Cancelled;
    return switch (first) {
        .request => |result| blk: {
            select.cancelDiscard();
            break :blk result;
        },
        .watchdog => |reason| blk: {
            select.cancelDiscard();
            break :blk switch (reason) {
                .cancelled => error.Cancelled,
                .timed_out => error.HttpTimeout,
            };
        },
    };
}

fn getRun(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    url: []const u8,
    max_bytes: usize,
    cancel: ?*std.atomic.Value(bool),
    redirect_behavior: std.http.Client.Request.RedirectBehavior,
) Error!GetOneResult {
    if (isCancelled(cancel)) return error.Cancelled;

    const uri = std.Uri.parse(url) catch return error.InvalidRequest;
    var request = client.request(.GET, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = .{ .user_agent = .{ .override = "marlin/0.0" } },
    }) catch |err| return mapConnect(err);
    defer request.deinit();
    request.sendBodiless() catch return error.ConnectFailed;

    var redirect_buffer: [8192]u8 = undefined;
    var response = request.receiveHead(if (redirect_behavior == .unhandled) &.{} else &redirect_buffer) catch |err| return mapConnect(err);
    const status: i64 = @intFromEnum(response.head.status);
    const content_type = if (response.head.content_type) |value| try gpa.dupe(u8, value) else null;
    errdefer if (content_type) |value| gpa.free(value);
    const location = if (response.head.location) |value| try gpa.dupe(u8, value) else null;
    errdefer if (location) |value| gpa.free(value);

    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    var transfer_buffer: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = switch (response.head.content_encoding) {
        .identity => response.reader(&transfer_buffer),
        .gzip, .deflate => response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer),
        else => return error.UnsupportedEncoding,
    };
    var chunk: [16 * 1024]u8 = undefined;
    while (body.items.len < max_bytes) {
        if (isCancelled(cancel)) {
            if (request.connection) |connection| connection.closing = true;
            return error.Cancelled;
        }
        const n = reader.readSliceShort(chunk[0..@min(chunk.len, max_bytes - body.items.len)]) catch |err| switch (err) {
            error.ReadFailed => {
                if (response.bodyErr()) |cause| std.log.debug("get body failure: {t}", .{cause});
                return error.ReadFailed;
            },
        };
        if (n == 0) break;
        try body.appendSlice(gpa, chunk[0..n]);
    }
    if (body.items.len == max_bytes and request.connection != null) request.connection.?.closing = true;

    return .{
        .status = status,
        .body = try body.toOwnedSlice(gpa),
        .content_type = content_type,
        .location = location,
    };
}

fn waitForStreamAbort(
    io: Io,
    cancel: ?*std.atomic.Value(bool),
    progress: *const StreamProgress,
    connect_timeout_ms: i64,
    idle_timeout_ms: i64,
) Abort {
    var response_started = progress.response_started.load(.acquire);
    var activity_generation = progress.activity_generation.load(.acquire);
    var elapsed_ms: i64 = 0;
    while (!isCancelled(cancel)) {
        const current_response_started = progress.response_started.load(.acquire);
        const current_generation = progress.activity_generation.load(.acquire);
        if (current_response_started != response_started or current_generation != activity_generation) {
            response_started = current_response_started;
            activity_generation = current_generation;
            elapsed_ms = 0;
        }

        const timeout_ms = @max(if (response_started) idle_timeout_ms else connect_timeout_ms, 1);
        if (elapsed_ms >= timeout_ms) return .timed_out;
        const sleep_ms = @min(timeout_ms - elapsed_ms, 50);
        io.sleep(.fromMilliseconds(sleep_ms), .awake) catch return .cancelled;
        elapsed_ms += sleep_ms;
    }
    return .cancelled;
}

fn waitForAbort(io: Io, cancel: ?*std.atomic.Value(bool), timeout_ms: i64) Abort {
    const bounded_timeout_ms = @max(timeout_ms, 1);
    var elapsed_ms: i64 = 0;
    while (!isCancelled(cancel)) {
        if (elapsed_ms >= bounded_timeout_ms) return .timed_out;
        const sleep_ms = @min(bounded_timeout_ms - elapsed_ms, 50);
        io.sleep(.fromMilliseconds(sleep_ms), .awake) catch return .cancelled;
        elapsed_ms += sleep_ms;
    }
    return .cancelled;
}

fn markActivity(progress: *StreamProgress) void {
    _ = progress.activity_generation.fetchAdd(1, .release);
}

fn isCancelled(cancel: ?*std.atomic.Value(bool)) bool {
    return if (cancel) |flag| flag.load(.acquire) else false;
}

fn testServer(io: Io) !Io.net.Server {
    const address = Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
    return address.listen(io, .{ .reuse_address = true });
}

fn testUrl(allocator: std.mem.Allocator, server: *const Io.net.Server) ![:0]u8 {
    return std.fmt.allocPrintSentinel(allocator, "http://127.0.0.1:{d}/test", .{server.socket.address.getPort()}, 0);
}

fn serveDelayedResponse(io: Io, server: *Io.net.Server, delay_ms: i64, body: []const u8) void {
    var stream = server.accept(io) catch return;
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buffer);
    _ = reader.interface.takeDelimiterInclusive('\n') catch return;
    io.sleep(.fromMilliseconds(delay_ms), .awake) catch return;
    var write_buffer: [4096]u8 = undefined;
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buffer);
    writer.interface.print(
        "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}",
        .{ body.len, body },
    ) catch return;
    writer.interface.flush() catch return;
}

fn discardChunk(_: void, _: []const u8) void {}

fn requestCompletes(
    io: Io,
    server: *Io.net.Server,
    cancel: *std.atomic.Value(bool),
    timeout_ms: i64,
) !void {
    const gpa = std.testing.allocator;
    const url = try testUrl(gpa, server);
    defer gpa.free(url);
    const RequestResult = Error!Response;
    const Select = Io.Select(union(enum) { serve: void, request: RequestResult });
    var results: [2]Select.Union = undefined;
    var select = Select.init(io, &results);
    defer select.cancelDiscard();
    select.async(.serve, serveDelayedResponse, .{ io, server, 5_000, "ok" });
    select.async(.request, streamPostTask(void, discardChunk), .{ gpa, io, StreamRequest{
        .url = url,
        .bearer = null,
        .body_json = "{}",
        .connect_timeout_ms = timeout_ms,
        .idle_timeout_ms = timeout_ms,
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

test "stream connect timeout aborts before response headers" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{ .async_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var server = try testServer(io);
    defer server.deinit(io);
    var cancel: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.HttpTimeout, requestCompletes(io, &server, &cancel, 100));
}

fn streamPostTask(
    comptime Ctx: type,
    comptime on_chunk: fn (Ctx, []const u8) void,
) fn (std.mem.Allocator, Io, StreamRequest, Ctx) Error!Response {
    return struct {
        fn run(gpa: std.mem.Allocator, io: Io, request: StreamRequest, ctx: Ctx) Error!Response {
            return @This().call(gpa, io, request, ctx);
        }

        fn call(gpa: std.mem.Allocator, io: Io, request: StreamRequest, ctx: Ctx) Error!Response {
            return @import("http.zig").streamPost(gpa, io, request, ctx, on_chunk);
        }
    }.run;
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
        fn onChunk(alloc: std.mem.Allocator, bytes: []const u8) void {
            collected.appendSlice(alloc, bytes) catch {};
            chunks += 1;
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
