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

fn streamPostTimed(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    stream_req: StreamRequest,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
) Error!Response {
    const RunResult = Error!Response;
    const WaitResult = error{Canceled}!void;
    const Select = Io.Select(union(enum) {
        request: RunResult,
        watchdog: WaitResult,
    });
    var results: [2]Select.Union = undefined;
    var select = Select.init(client.io, &results);
    select.async(.request, streamPostImpl(@TypeOf(ctx), on_chunk), .{ client, gpa, stream_req, ctx });
    select.async(.watchdog, waitForAbort, .{ client.io, stream_req.cancel, stream_req.idle_timeout_ms });

    const first = try select.await();
    return switch (first) {
        .request => |result| blk: {
            select.cancelDiscard();
            break :blk result;
        },
        .watchdog => |wait_result| blk: {
            try wait_result;
            select.cancelDiscard();
            break :blk if (isCancelled(stream_req.cancel)) error.Cancelled else error.HttpTimeout;
        },
    };
}

fn streamPostImpl(
    comptime Ctx: type,
    comptime on_chunk: fn (Ctx, []const u8) void,
) fn (*std.http.Client, std.mem.Allocator, StreamRequest, Ctx) Error!Response {
    return struct {
        fn run(
            client: *std.http.Client,
            gpa: std.mem.Allocator,
            stream_req: StreamRequest,
            ctx: Ctx,
        ) Error!Response {
            return streamPostRun(client, gpa, stream_req, ctx, on_chunk);
        }
    }.run;
}

fn streamPostRun(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    stream_req: StreamRequest,
    ctx: anytype,
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
    _ = timeout_ms;
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

fn waitForAbort(io: Io, cancel: ?*std.atomic.Value(bool), timeout_ms: i64) error{Canceled}!void {
    const started = Io.Timestamp.now(io, .awake).nanoseconds;
    const timeout_ns = @as(i96, @max(timeout_ms, 1)) * std.time.ns_per_ms;
    while (!isCancelled(cancel)) {
        if (Io.Timestamp.now(io, .awake).nanoseconds - started >= timeout_ns) return;
        io.sleep(.fromMilliseconds(50), .awake) catch return error.Canceled;
    }
}

fn isCancelled(cancel: ?*std.atomic.Value(bool)) bool {
    return if (cancel) |flag| flag.load(.acquire) else false;
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
