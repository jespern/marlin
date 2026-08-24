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
    const easy = c.curl_easy_init() orelse return error.CurlInit;
    defer c.curl_easy_cleanup(easy);

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
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, Callback(@TypeOf(ctx)).write(on_chunk));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &cb);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, req.connect_timeout_ms);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_LOW_SPEED_LIMIT, @as(c_long, 1));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_LOW_SPEED_TIME, @divTrunc(req.idle_timeout_ms, 1000));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFOFUNCTION, Callback(@TypeOf(ctx)).progress);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_XFERINFODATA, &cb);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = c.curl_easy_setopt(easy, c.CURLOPT_USERAGENT, "marlin/0.0");

    const code = c.curl_easy_perform(easy);

    var status: c_long = 0;
    _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &status);

    if (code == c.CURLE_ABORTED_BY_CALLBACK) return error.Cancelled;
    if (code != c.CURLE_OK and status == 0) return error.CurlPerform;

    if (status >= 400) {
        return .{ .status = status, .error_body = try cb.err_body.toOwnedSlice(gpa) };
    }
    cb.err_body.deinit(gpa);
    return .{ .status = status, .error_body = null };
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

        fn write(comptime on_chunk: fn (Ctx, []const u8) void) fn ([*c]u8, usize, usize, ?*anyopaque) callconv(.c) usize {
            return struct {
                fn go(ptr: [*c]u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
                    const self: *Self = @ptrCast(@alignCast(userdata.?));
                    const bytes = ptr[0 .. size * nmemb];
                    // We can't see the status line from the write cb directly;
                    // error bodies are small and non-SSE, so buffer defensively:
                    // heuristic: SSE chunks start streaming only on 200s, but
                    // we ALSO keep a copy of early bytes in case status >= 400.
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

// NOTE on the error-body heuristic above: for M0 we keep it simple — the
// caller checks Response.status; when >=400 the SSE sink will have received
// the error bytes too, which is harmless (no valid `data:` lines parse out
// of a JSON error object). M1 refines this with a HEADERFUNCTION that flips
// is_error_status as soon as the status line arrives.

test "compiles and links against libcurl" {
    globalInit();
    defer globalDeinit();
}
