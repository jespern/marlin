//! HTTP layer: libcurl wrapper. THE ONLY FILE THAT KNOWS CURL.
//!
//! - streaming POST: response bytes are handed to an on_chunk callback as
//!   they arrive (curl write callback → caller's SSE parser)
//! - cancellation: curl progress callback polls an atomic cancel flag
//! - retry/backoff (M0.5): exponential w/ jitter on 429/5xx/connect errors;
//!   the caller re-issues the whole request — partial deltas are discarded
//! - swap target: std.http.Client behind this same interface, someday.

const std = @import("std");

const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const Error = error{
    CurlInit,
    CurlPerform,
    Cancelled,
    HttpStatus,
    OutOfMemory,
};

pub const Response = struct {
    /// HTTP status code (set even when body streaming succeeded).
    status: i64,
    /// Collected error body when status >= 400 (allocated, caller frees).
    /// null on success (body went to the stream callback instead).
    error_body: ?[]u8,
};

pub const StreamRequest = struct {
    url: [:0]const u8,
    /// Bearer token; header built internally. Optional for local endpoints.
    bearer: ?[]const u8,
    body_json: []const u8,
    /// Extra headers, each as a full "Name: value" line.
    extra_headers: []const []const u8 = &.{},
    connect_timeout_ms: c_long = 10_000,
    /// Abort if no bytes arrive for this long (idle watchdog).
    idle_timeout_ms: c_long = 120_000,
    /// Polled by curl's progress callback; set from another thread to abort.
    cancel: ?*std.atomic.Value(bool) = null,
};

/// Daemon-owned idle easy-handle pool. A handle belongs to exactly one turn
/// thread while checked out; returning it preserves libcurl's live
/// connections, DNS cache, and TLS session cache for the next turn.
pub const Pool = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    idle: std.ArrayList(*c.CURL) = .empty,
    max_idle: usize = 8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Pool {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.idle.items) |easy| c.curl_easy_cleanup(easy);
        self.idle.deinit(self.gpa);
    }

    pub fn acquire(self: *Pool) Error!Client {
        self.mutex.lockUncancelable(self.io);
        const reused = self.idle.pop();
        self.mutex.unlock(self.io);
        const easy = reused orelse c.curl_easy_init() orelse return error.CurlInit;
        return .{ .easy = easy, .pool = self };
    }

    fn release(self: *Pool, easy: *c.CURL) void {
        // Drop every request-owned pointer while retaining connection state.
        c.curl_easy_reset(easy);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.idle.items.len >= self.max_idle) {
            c.curl_easy_cleanup(easy);
            return;
        }
        self.idle.append(self.gpa, easy) catch c.curl_easy_cleanup(easy);
    }
};

/// One exclusively-owned easy handle. Repeated streamPost calls reuse live
/// connections; deinit returns pooled handles instead of closing them.
pub const Client = struct {
    easy: *c.CURL,
    pool: ?*Pool = null,

    pub fn init() Error!Client {
        return .{ .easy = c.curl_easy_init() orelse return error.CurlInit };
    }

    pub fn deinit(self: *Client) void {
        if (self.pool) |pool| {
            pool.release(self.easy);
        } else {
            c.curl_easy_cleanup(self.easy);
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
        const easy = self.easy;
        // Reset request options without discarding libcurl's connection, DNS,
        // cookie, or TLS session caches.
        c.curl_easy_reset(easy);

        var headers: ?*c.curl_slist = null;
        defer if (headers) |h| c.curl_slist_free_all(h);
        headers = c.curl_slist_append(headers, "Content-Type: application/json");
        headers = c.curl_slist_append(headers, "Accept: text/event-stream");

        var auth_buf: [4096]u8 = undefined;
        if (req.bearer) |tok| {
            const line = std.fmt.bufPrintZ(&auth_buf, "Authorization: Bearer {s}", .{tok}) catch
                return error.OutOfMemory;
            headers = c.curl_slist_append(headers, line.ptr);
        }
        var hdr_z: std.ArrayList(u8) = .empty;
        defer hdr_z.deinit(gpa);
        for (req.extra_headers) |h| {
            hdr_z.clearRetainingCapacity();
            try hdr_z.appendSlice(gpa, h);
            try hdr_z.append(gpa, 0);
            headers = c.curl_slist_append(headers, @ptrCast(hdr_z.items.ptr));
        }

        var cb = Callback(@TypeOf(ctx)){ .gpa = gpa, .ctx = ctx, .cancel = req.cancel };

        _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, req.url.ptr);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, headers);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_POST, @as(c_long, 1));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, req.body_json.ptr);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, @as(c_long, @intCast(req.body_json.len)));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_HEADERFUNCTION, Callback(@TypeOf(ctx)).header);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_HEADERDATA, &cb);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, Callback(@TypeOf(ctx)).write(on_chunk));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &cb);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, req.connect_timeout_ms);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_LOW_SPEED_TIME, @divTrunc(req.idle_timeout_ms, 1000));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFOFUNCTION, Callback(@TypeOf(ctx)).progress);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFODATA, &cb);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_ACCEPT_ENCODING, "");
        _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTP_VERSION, c.CURL_HTTP_VERSION_2TLS);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_TCP_KEEPALIVE, @as(c_long, 1));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        _ = c.curl_easy_setopt(easy, c.CURLOPT_USERAGENT, "marlin/0.0");

        const code = c.curl_easy_perform(easy);

        var status: c_long = 0;
        _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status);

        if (code == c.CURLE_ABORTED_BY_CALLBACK) return error.Cancelled;
        if (code != c.CURLE_OK and status < 400) return error.CurlPerform;

        if (status >= 400) {
            return .{ .status = status, .error_body = try cb.err_body.toOwnedSlice(gpa) };
        }
        cb.err_body.deinit(gpa);
        return .{ .status = status, .error_body = null };
    }
};

/// One-time global init (call from main once; not thread-safe by contract).
pub fn globalInit() void {
    _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
}

pub fn globalDeinit() void {
    c.curl_global_cleanup();
}

/// Streaming POST. Calls `on_chunk(ctx, bytes)` for each response chunk as
/// it arrives. Returns after the stream completes or fails.
pub fn streamPost(
    gpa: std.mem.Allocator,
    req: StreamRequest,
    ctx: anytype,
    comptime on_chunk: fn (@TypeOf(ctx), []const u8) void,
) Error!Response {
    var client = try Client.init();
    defer client.deinit();
    return client.streamPost(gpa, req, ctx, on_chunk);
}

pub const GetResult = struct {
    status: i64,
    body: []u8, // caller frees
    content_type: ?[]u8, // caller frees when non-null
};

pub const GetOneResult = struct {
    status: i64,
    body: []u8, // caller frees
    content_type: ?[]u8, // caller frees when non-null
    /// Raw Location value when libcurl recognizes a redirect response.
    /// May be relative; caller resolves it against the requested URL.
    location: ?[]u8, // caller frees when non-null
};

/// Simple bounded GET (fetch tool). Follows redirects; caps the body.
pub fn get(
    gpa: std.mem.Allocator,
    url: [:0]const u8,
    max_bytes: usize,
    timeout_ms: c_long,
    cancel: ?*std.atomic.Value(bool),
) Error!GetResult {
    const easy = c.curl_easy_init() orelse return error.CurlInit;
    defer c.curl_easy_cleanup(easy);

    var sink = GetSink{ .gpa = gpa, .max = max_bytes, .cancel = cancel };
    errdefer sink.body.deinit(gpa);

    _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, GetSink.write);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &sink);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 10_000));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT_MS, timeout_ms);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFOFUNCTION, GetSink.progress);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFODATA, &sink);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 5));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_ACCEPT_ENCODING, ""); // all built-in codings
    _ = c.curl_easy_setopt(easy, c.CURLOPT_USERAGENT, "marlin/0.0");

    const code = c.curl_easy_perform(easy);
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status);

    if (code == c.CURLE_ABORTED_BY_CALLBACK) {
        // Either cancelled or byte cap hit; cap keeps what we have.
        if (cancel) |f| if (f.load(.acquire)) return error.Cancelled;
    } else if (code != c.CURLE_OK and status == 0) {
        return error.CurlPerform;
    }

    var ctype: ?[]u8 = null;
    var ct_ptr: [*c]u8 = null;
    if (c.curl_easy_getinfo(easy, c.CURLINFO_CONTENT_TYPE, &ct_ptr) == c.CURLE_OK and ct_ptr != null) {
        ctype = try gpa.dupe(u8, std.mem.span(ct_ptr));
    }
    return .{
        .status = status,
        .body = try sink.body.toOwnedSlice(gpa),
        .content_type = ctype,
    };
}

/// Bounded GET without following redirects. The fetch tool uses this form so
/// its hostname policy can authorize every hop before a connection is made.
pub fn getOne(
    gpa: std.mem.Allocator,
    url: [:0]const u8,
    max_bytes: usize,
    timeout_ms: c_long,
    cancel: ?*std.atomic.Value(bool),
) Error!GetOneResult {
    const easy = c.curl_easy_init() orelse return error.CurlInit;
    defer c.curl_easy_cleanup(easy);

    var sink = GetSink{ .gpa = gpa, .max = max_bytes, .cancel = cancel };
    errdefer sink.body.deinit(gpa);

    _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, GetSink.write);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &sink);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, @as(c_long, 10_000));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT_MS, timeout_ms);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFOFUNCTION, GetSink.progress);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFODATA, &sink);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_ACCEPT_ENCODING, "");
    _ = c.curl_easy_setopt(easy, c.CURLOPT_USERAGENT, "marlin/0.0");

    const code = c.curl_easy_perform(easy);
    var status: c_long = 0;
    _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status);

    if (code == c.CURLE_ABORTED_BY_CALLBACK) {
        if (cancel) |flag| if (flag.load(.acquire)) return error.Cancelled;
    } else if (code != c.CURLE_OK and status == 0) {
        return error.CurlPerform;
    }

    var content_type: ?[]u8 = null;
    errdefer if (content_type) |value| gpa.free(value);
    var ct_ptr: [*c]u8 = null;
    if (c.curl_easy_getinfo(easy, c.CURLINFO_CONTENT_TYPE, &ct_ptr) == c.CURLE_OK and ct_ptr != null) {
        content_type = try gpa.dupe(u8, std.mem.span(ct_ptr));
    }

    var location: ?[]u8 = null;
    errdefer if (location) |value| gpa.free(value);
    var location_ptr: [*c]u8 = null;
    if (c.curl_easy_getinfo(easy, c.CURLINFO_REDIRECT_URL, &location_ptr) == c.CURLE_OK and location_ptr != null) {
        location = try gpa.dupe(u8, std.mem.span(location_ptr));
    }

    return .{
        .status = status,
        .body = try sink.body.toOwnedSlice(gpa),
        .content_type = content_type,
        .location = location,
    };
}

const GetSink = struct {
    gpa: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    max: usize,
    cancel: ?*std.atomic.Value(bool),

    fn write(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
        const self: *GetSink = @ptrCast(@alignCast(userdata.?));
        const bytes = ptr[0 .. size * nmemb];
        if (self.body.items.len + bytes.len > self.max) {
            const room = self.max - self.body.items.len;
            self.body.appendSlice(self.gpa, bytes[0..room]) catch return 0;
            return 0; // abort transfer; we keep what we got
        }
        self.body.appendSlice(self.gpa, bytes) catch return 0;
        return bytes.len;
    }

    fn progress(userdata: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
        const self: *GetSink = @ptrCast(@alignCast(userdata.?));
        if (self.cancel) |flag| {
            if (flag.load(.acquire)) return 1;
        }
        return 0;
    }
};

/// Curl callback state + trampolines. Generic over the caller's ctx type.
fn Callback(comptime Ctx: type) type {
    return struct {
        gpa: std.mem.Allocator,
        ctx: Ctx,
        cancel: ?*std.atomic.Value(bool),
        status_checked: bool = false,
        is_error_status: bool = false,
        err_body: std.ArrayList(u8) = .empty,

        const Self = @This();

        fn header(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const bytes = ptr[0 .. size * nmemb];
            if (!std.mem.startsWith(u8, bytes, "HTTP/")) return bytes.len;

            // Handles both "HTTP/1.1 200" and "HTTP/2 200". Redirects and
            // proxy handshakes may produce multiple status lines; the latest
            // one describes the body that follows.
            const first_space = std.mem.indexOfScalar(u8, bytes, ' ') orelse return bytes.len;
            var status_at = first_space + 1;
            while (status_at < bytes.len and bytes[status_at] == ' ') status_at += 1;
            const rest = bytes[status_at..];
            if (rest.len < 3) return bytes.len;
            const status = std.fmt.parseInt(u16, rest[0..3], 10) catch return bytes.len;
            self.status_checked = true;
            self.is_error_status = status >= 400;
            return bytes.len;
        }

        fn write(comptime on_chunk: fn (Ctx, []const u8) void) fn ([*c]u8, usize, usize, ?*anyopaque) callconv(.c) usize {
            return struct {
                fn go(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
                    const self: *Self = @ptrCast(@alignCast(userdata.?));
                    const bytes = ptr[0 .. size * nmemb];
                    // A malformed server that omits a status line is treated
                    // conservatively; normal success streams never enter this
                    // error-only buffer.
                    if (!self.status_checked or self.is_error_status) {
                        self.err_body.appendSlice(self.gpa, bytes) catch return 0;
                        if (self.err_body.items.len > 64 * 1024) return 0; // cap error body
                    }
                    if (!self.is_error_status) on_chunk(self.ctx, bytes);
                    return size * nmemb;
                }
            }.go;
        }

        fn progress(userdata: ?*anyopaque, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t, _: c.curl_off_t) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            if (self.cancel) |flag| {
                if (flag.load(.acquire)) return 1; // abort transfer
            }
            return 0;
        }
    };
}

test "compiles and links against libcurl" {
    globalInit();
    defer globalDeinit();
}

test "pool returns an easy handle for reuse" {
    globalInit();
    defer globalDeinit();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var pool = Pool.init(std.testing.allocator, threaded.io());
    defer pool.deinit();

    var first = try pool.acquire();
    const ptr = first.easy;
    first.deinit();
    var second = try pool.acquire();
    defer second.deinit();
    try std.testing.expectEqual(ptr, second.easy);
}
