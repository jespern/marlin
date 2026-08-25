//! HTTP layer backed by Zig's standard HTTP client.
//!
//! Provider requests stream response bytes into the SSE parser. A daemon-owned
//! client pool retains HTTP/TLS connections across turns; bounded GETs use the
//! same transport for fetch, catalogs, and network blocklists.

const std = @import("std");
const Io = std.Io;

pub const Error = anyerror;

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

/// Kept as no-ops so daemon lifecycle callers remain simple.
pub fn globalInit() void {}
pub fn globalDeinit() void {}

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
    last_activity_ms: std.atomic.Value(i64),
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
    var progress = StreamProgress{
        .last_activity_ms = .init(Io.Timestamp.now(client.io, .awake).toMilliseconds()),
    };
    var results: [2]Select.Union = undefined;
    var select = Select.init(client.io, &results);
    select.async(.request, streamPostImpl(@TypeOf(ctx), on_chunk), .{ client, gpa, stream_req, ctx, &progress });
    select.async(.watchdog, waitForStreamAbort, .{ client.io, stream_req.cancel, &progress, stream_req.connect_timeout_ms, stream_req.idle_timeout_ms });

    const first = try select.await();
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

    const uri = try std.Uri.parse(stream_req.url);
    var header_storage = try gpa.alloc(std.http.Header, stream_req.extra_headers.len);
    defer gpa.free(header_storage);
    for (stream_req.extra_headers, 0..) |line, i| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        header_storage[i] = .{
            .name = std.mem.trim(u8, line[0..colon], " \t"),
            .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
        };
        if (header_storage[i].name.len == 0) return error.InvalidHeader;
    }

    var auth_storage: ?[]u8 = null;
    defer if (auth_storage) |auth| gpa.free(auth);
    const authorization: std.http.Client.Request.Headers.Value = if (stream_req.bearer) |token| blk: {
        auth_storage = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
        break :blk .{ .override = auth_storage.? };
    } else .omit;

    var request = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .headers = .{
            .authorization = authorization,
            .user_agent = .{ .override = "marlin/0.0" },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = header_storage,
    });
    defer request.deinit();

    request.transfer_encoding = .{ .content_length = stream_req.body_json.len };
    var body_writer = try request.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(stream_req.body_json);
    try body_writer.end();
    try request.connection.?.flush();

    var response = try request.receiveHead(&.{});
    progress.response_started.store(true, .release);
    markActivity(client.io, progress);
    const status: i64 = @intFromEnum(response.head.status);
    const is_error = status >= 400;

    var error_body: std.ArrayList(u8) = .empty;
    errdefer error_body.deinit(gpa);
    var transfer_buffer: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var chunk: [16 * 1024]u8 = undefined;

    while (true) {
        if (isCancelled(stream_req.cancel)) {
            if (request.connection) |connection| connection.closing = true;
            return error.Cancelled;
        }
        const n = reader.readSliceShort(&chunk) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.HttpReadFailed,
        };
        if (n == 0) break;
        markActivity(client.io, progress);
        if (is_error) {
            const room = 64 * 1024 - error_body.items.len;
            if (room > 0) try error_body.appendSlice(gpa, chunk[0..@min(n, room)]);
        } else {
            on_chunk(ctx, chunk[0..n]);
        }
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
    var pool = try Pool.init(gpa, io, environ);
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
    var pool = try Pool.init(gpa, io, environ);
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
    select.async(.request, getRun, .{ client, gpa, url, max_bytes, cancel, redirect_behavior });
    select.async(.watchdog, waitForAbort, .{ client.io, cancel, timeout_ms });

    const first = try select.await();
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

    const uri = try std.Uri.parse(url);
    var request = try client.request(.GET, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = .{ .user_agent = .{ .override = "marlin/0.0" } },
    });
    defer request.deinit();
    try request.sendBodiless();

    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(if (redirect_behavior == .unhandled) &.{} else &redirect_buffer);
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
        else => return error.UnsupportedCompressionMethod,
    };
    var chunk: [16 * 1024]u8 = undefined;
    while (body.items.len < max_bytes) {
        if (isCancelled(cancel)) {
            if (request.connection) |connection| connection.closing = true;
            return error.Cancelled;
        }
        const n = reader.readSliceShort(chunk[0..@min(chunk.len, max_bytes - body.items.len)]) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.HttpReadFailed,
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
    const started_ms = progress.last_activity_ms.load(.acquire);
    while (!isCancelled(cancel)) {
        const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
        const timeout_ms = if (progress.response_started.load(.acquire)) idle_timeout_ms else connect_timeout_ms;
        const baseline_ms = if (progress.response_started.load(.acquire)) progress.last_activity_ms.load(.acquire) else started_ms;
        if (now_ms - baseline_ms >= @max(timeout_ms, 1)) return .timed_out;
        io.sleep(.fromMilliseconds(50), .awake) catch return .cancelled;
    }
    return .cancelled;
}

fn waitForAbort(io: Io, cancel: ?*std.atomic.Value(bool), timeout_ms: i64) Abort {
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    const timeout_ns = @as(i96, @max(timeout_ms, 1)) * std.time.ns_per_ms;
    while (!isCancelled(cancel)) {
        if (Io.Timestamp.now(io, .awake).nanoseconds - started >= timeout_ns) return .timed_out;
        io.sleep(.fromMilliseconds(50), .awake) catch return .cancelled;
    }
    return .cancelled;
}

fn markActivity(io: Io, progress: *StreamProgress) void {
    progress.last_activity_ms.store(Io.Timestamp.now(io, .awake).toMilliseconds(), .release);
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
        },
        .serve => break,
    };
}

test "stream cancellation interrupts a blocked response" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
        .request => |result| try std.testing.expectError(error.Cancelled, result),
        .serve => break,
    };
}

test "stream connect timeout aborts before response headers" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
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
