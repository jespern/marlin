//! marlin web: a localhost HTTP bridge in front of the daemon socket (POC).
//!
//! Routes:
//!   GET  /               embedded single-page UI (webui.html)
//!   GET  /events?sid=N   SSE stream on a dedicated daemon connection:
//!                        session_watch + bounded sub(sid); every daemon
//!                        NDJSON line is forwarded verbatim as one event.
//!   GET  /history?sid=N&before=S
//!                        one bounded older-history page as finite SSE
//!   POST /send           body = ONE ClientMsg JSON line, forwarded on a
//!                        fresh daemon connection; the first daemon reply
//!                        line comes back as application/json.
//!
//! The web layer holds no session state: subscriptions live on the SSE
//! connection, everything else is stateless per request — the same shape as
//! any other marlin client.
//!
//! Binds 127.0.0.1 only. The trust boundary is the TRANSPORT: loopback, or
//! the tailnet when `tailscale serve` proxies the port to this node's fixed
//! https URL (`[web] tailscale = true` opts in).
//! No token, no login — a phone opens the same URL forever. What remains is
//! what a BROWSER can be tricked into sending, and both vectors identify
//! themselves in headers: DNS rebinding arrives under a foreign Host,
//! cross-site POSTs carry a foreign Origin. Both are rejected; curl and the
//! PWA never notice. A hostile local user is explicitly out of scope
//! (loopback is machine-wide — /web disable on a multi-user box).
//! Serving honors `[web] enabled` (on by default; /web enable|disable
//! persists the switch, MARLIN_WEB=1 overrides for one-offs).
//!
//! Requests log one Common Log Format line each to stderr — the daemon's
//! companion ring captures them, so the /web tab reads like an access.log.

const std = @import("std");
const Io = std.Io;

const config = @import("../core/config.zig");
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

const html = @embedFile("webui.html");
const mobile_push = @import("../mobile/push.zig");
const service_worker = @embedFile("webui-sw.js");
const icon_180 = @embedFile("webui-icon-180.png");
const icon_512 = @embedFile("webui-icon-512.png");
const manifest =
    \\{"name":"marlin","short_name":"marlin","start_url":"/","display":"standalone",
    \\"background_color":"#17191d","theme_color":"#17191d","icons":[
    \\{"src":"/icon-180.png","sizes":"180x180","type":"image/png"},
    \\{"src":"/icon-512.png","sizes":"512x512","type":"image/png"}]}
;
const default_port: u16 = 8377;

/// macOS app installs bundle the CLI without adding a PATH executable.
/// Explicit CLI mode prevents background launches from opening a GUI.
pub fn runTailscale(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const []const u8) !std.process.RunResult {
    return runTailscaleCommand(gpa, io, environ, "tailscale", args) catch |err| {
        if (err != error.FileNotFound or @import("builtin").os.tag != .macos) return err;
        return runTailscaleCommand(gpa, io, environ, "/Applications/Tailscale.app/Contents/MacOS/Tailscale", args);
    };
}

pub fn runTailscaleCommand(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, executable: []const u8, args: []const []const u8) !std.process.RunResult {
    if (args.len > 7) return error.TooManyArguments;
    var env = try environ.clone(gpa);
    defer env.deinit();
    try env.put("TAILSCALE_BE_CLI", "1");
    var argv: [8][]const u8 = undefined;
    argv[0] = executable;
    @memcpy(argv[1 .. args.len + 1], args);
    return std.process.run(gpa, io, .{
        .argv = argv[0 .. args.len + 1],
        .environ_map = &env,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } },
    });
}

/// Best-effort `tailscale serve --bg <port>`: expose the loopback port at
/// this node's fixed tailnet https URL. Returns the gpa-owned tailnet host
/// name when serving, null (with a log line) when tailscale is absent,
/// logged out, or the CLI shape is unrecognized — the UI stays usable on
/// loopback either way.
fn setupTailscale(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, port: u16) ?[]u8 {
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    const serve_result = runTailscale(gpa, io, environ, &.{ "serve", "--bg", port_str }) catch |err| {
        std.log.info("tailscale serve unavailable ({t}); web ui is loopback-only", .{err});
        return null;
    };
    defer gpa.free(serve_result.stdout);
    defer gpa.free(serve_result.stderr);
    if (serve_result.term != .exited or serve_result.term.exited != 0) {
        const detail = std.mem.trim(u8, serve_result.stderr, " \t\r\n");
        std.log.warn("tailscale serve refused ({s}); web ui is loopback-only", .{detail});
        return null;
    }

    const status = runTailscale(gpa, io, environ, &.{ "status", "--json" }) catch return null;
    defer gpa.free(status.stdout);
    defer gpa.free(status.stderr);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), status.stdout, .{}) catch return null;
    if (parsed != .object) return null;
    const self_node = parsed.object.get("Self") orelse return null;
    if (self_node != .object) return null;
    const dns = self_node.object.get("DNSName") orelse return null;
    if (dns != .string) return null;
    const host = std.mem.trimEnd(u8, dns.string, ".");
    if (host.len == 0) return null;
    return gpa.dupe(u8, host) catch null;
}

pub fn serve(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    // Enabled by default; disabled is an explicit user choice (/web disable
    // or `[web] enabled = false`), so honor it and say the way back.
    var port: u16 = default_port;
    var want_tailscale = false;
    var want_push = false;
    {
        var loaded = config.load(gpa, io, environ) catch |e| {
            std.log.err("cannot load config: {t}", .{e});
            return 1;
        };
        defer loaded.deinit();
        if (!loaded.value.web_enabled) {
            std.log.err(
                "the web ui is disabled — run /web enable in marlin (or set [web] enabled = true; MARLIN_WEB=1 for a one-off).",
                .{},
            );
            return 2;
        }
        port = loaded.value.web_port;
        want_tailscale = loaded.value.web_tailscale;
        want_push = loaded.value.web_push and environ.get("MARLIN_REMOTE") == null;
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch {
                std.log.err("invalid port '{s}'", .{args[i]});
                return 2;
            };
        }
    }

    // Connect once up front: autostarts the daemon and fails fast on a
    // broken socket before we claim the HTTP port.
    const probe = attach.connect(gpa, io, environ, self_exe) catch |e| {
        std.log.err("cannot reach daemon: {t}", .{e});
        return 1;
    };
    probe.deinit();

    var addr = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        std.log.err("cannot listen on 127.0.0.1:{d}: {t}", .{ port, e });
        return 1;
    };
    defer server.deinit(io);

    const tailnet_host: ?[]const u8 = if (want_tailscale) setupTailscale(gpa, io, environ, port) else null;
    defer if (tailnet_host) |h| gpa.free(@constCast(h));
    std.log.info("marlin web ui on http://127.0.0.1:{d}/", .{port});
    if (tailnet_host) |host| {
        std.log.info("tailnet: https://{s}/ (fixed URL; the tailnet is the gate)", .{host});
    }

    while (true) {
        const stream = server.accept(io) catch break;
        const ctx = gpa.create(ConnCtx) catch {
            var s = stream;
            s.close(io);
            continue;
        };
        ctx.* = .{ .gpa = gpa, .io = io, .environ = environ, .self_exe = self_exe, .stream = stream, .tailnet_host = tailnet_host, .push_enabled = want_push };
        const thread = std.Thread.spawn(.{}, connMain, .{ctx}) catch {
            var s = stream;
            s.close(io);
            gpa.destroy(ctx);
            continue;
        };
        thread.detach();
    }
    return 0;
}

const ConnCtx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    stream: Io.net.Stream,
    /// Non-null when tailscale serve fronts this port; its DNS name is then
    /// an allowed Host/Origin alongside loopback.
    tailnet_host: ?[]const u8,
    push_enabled: bool = false,
};

fn connMain(ctx: *ConnCtx) void {
    defer ctx.gpa.destroy(ctx);
    var stream = ctx.stream;
    defer stream.close(ctx.io);

    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [16 * 1024]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, ctx.io, &rbuf);
    var writer = Io.net.Stream.Writer.init(stream, ctx.io, &wbuf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);

    while (true) {
        var req = http_server.receiveHead() catch return;
        handleRequest(ctx, &req) catch return;
    }
}

/// What one finished request logs: the response status and body bytes.
const Access = struct { status: std.http.Status = .ok, bytes: u64 = 0 };

/// respond() plus access accounting — every terminal reply goes through here
/// so the log line carries the real status and size.
fn reply(req: *std.http.Server.Request, access: *Access, body: []const u8, options: std.http.Server.Request.RespondOptions) !void {
    access.* = .{ .status = options.status, .bytes = body.len };
    try req.respond(body, options);
}

const clf_months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// Common Log Format timestamp: `08/Sep/2026:14:12:33 +0000` (UTC — marlin
/// logs carry no local timezone database).
pub fn clfTime(buf: []u8, epoch_seconds: i64) []const u8 {
    const secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(epoch_seconds, 0)) };
    const year_day = secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>2}/{s}/{d}:{d:0>2}:{d:0>2}:{d:0>2} +0000", .{
        month_day.day_index + 1,
        clf_months[month_day.month.numeric() - 1],
        year_day.year,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

/// One access.log line per finished request, written directly to stderr
/// (NOT std.log: no `info:` prefix) so the companion ring and the /web tab
/// show plain Common Log Format. Streams log at completion with their total
/// body bytes, the way nginx does. The bridge binds loopback only, so the
/// peer is always 127.0.0.1.
fn logAccess(ctx: *ConnCtx, req: *const std.http.Server.Request, access: Access) void {
    var when_buf: [40]u8 = undefined;
    const when = clfTime(&when_buf, Io.Timestamp.now(ctx.io, .real).toSeconds());
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writer(ctx.io, &buffer);
    writer.interface.print("127.0.0.1 - - [{s}] \"{s} {s} {s}\" {d} {d}\n", .{
        when,
        @tagName(req.head.method),
        req.head.target,
        @tagName(req.head.version),
        @intFromEnum(access.status),
        access.bytes,
    }) catch return;
    writer.interface.flush() catch {};
}

fn handleRequest(ctx: *ConnCtx, req: *std.http.Server.Request) !void {
    const target = req.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var access = Access{};
    defer logAccess(ctx, req, access);

    // Transport is the trust boundary (loopback / tailnet); these header
    // checks close the two ways a BROWSER can be steered across it. DNS
    // rebinding reaches us under the attacker's Host; a cross-site POST
    // carries the attacker's Origin. Same-origin requests, curl, and the
    // installed PWA pass untouched — nothing here ever needs re-auth.
    if (!hostAllowed(ctx.tailnet_host, headerValue(req, "host"))) {
        try reply(req, &access, "forbidden: unrecognized Host\n", .{ .status = .forbidden });
        return;
    }
    if (req.head.method == .POST and !originAllowed(ctx.tailnet_host, headerValue(req, "origin"))) {
        try reply(req, &access, "forbidden: cross-origin request\n", .{ .status = .forbidden });
        return;
    }

    if (std.mem.eql(u8, target, "/connection")) {
        const body = try std.json.Stringify.valueAlloc(ctx.gpa, .{ .tailnet_host = ctx.tailnet_host, .push_enabled = ctx.push_enabled }, .{});
        defer ctx.gpa.free(body);
        try reply(req, &access, body, .{ .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } } });
    } else if (std.mem.eql(u8, target, "/sw.js")) {
        try reply(req, &access, service_worker, .{ .extra_headers = &.{ .{ .name = "content-type", .value = "text/javascript" }, .{ .name = "cache-control", .value = "no-cache" } } });
    } else if (std.mem.startsWith(u8, path, "/push/")) {
        try servePush(ctx, req, path, &access);
    } else if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        try reply(req, &access, html, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        } });
    } else if (std.mem.eql(u8, target, "/manifest.webmanifest")) {
        try reply(req, &access, manifest, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/manifest+json" },
        } });
    } else if (std.mem.eql(u8, target, "/icon-180.png")) {
        try reply(req, &access, icon_180, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "image/png" },
        } });
    } else if (std.mem.eql(u8, target, "/icon-512.png")) {
        try reply(req, &access, icon_512, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "image/png" },
        } });
    } else if (std.mem.startsWith(u8, target, "/events")) {
        try serveEvents(ctx, req, &access);
    } else if (std.mem.startsWith(u8, target, "/history")) {
        try serveHistory(ctx, req, &access);
    } else if (std.mem.eql(u8, target, "/send") and req.head.method == .POST) {
        try serveSend(ctx, req, &access);
    } else {
        try reply(req, &access, "not found\n", .{ .status = .not_found });
    }
}

fn servePush(ctx: *ConnCtx, req: *std.http.Server.Request, path: []const u8, access: *Access) !void {
    if (!ctx.push_enabled) {
        try reply(req, access, "phone push is disabled", .{ .status = .not_found });
        return;
    }
    const action: []const u8 = if (std.mem.eql(u8, path, "/push/info") and req.head.method == .GET) "info" else if (std.mem.eql(u8, path, "/push/subscribe") and req.head.method == .POST) "subscribe" else if (std.mem.eql(u8, path, "/push/unsubscribe") and req.head.method == .POST) "unsubscribe" else {
        try reply(req, access, "not found", .{ .status = .not_found });
        return;
    };
    var input: []const u8 = "";
    defer if (input.len != 0) ctx.gpa.free(input);
    if (req.head.method == .POST) {
        var buf: [8192]u8 = undefined;
        const reader = try req.readerExpectContinue(&buf);
        input = reader.allocRemaining(ctx.gpa, .limited(buf.len)) catch {
            try reply(req, access, "subscription too large", .{ .status = .payload_too_large });
            return;
        };
    }
    const result = mobile_push.run(ctx.gpa, ctx.io, ctx.environ, ctx.self_exe, action, input) catch {
        try reply(req, access, "phone push unavailable; check the subscription", .{ .status = .service_unavailable });
        return;
    };
    defer ctx.gpa.free(result);
    try reply(req, access, result, .{ .extra_headers = &.{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" } } });
}

/// Forward one client message and return the daemon's first reply line.
fn serveSend(ctx: *ConnCtx, req: *std.http.Server.Request, access: *Access) !void {
    const json_header = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    var body_buf: [64 * 1024]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&body_buf);
    const line = body_reader.allocRemaining(ctx.gpa, .limited(body_buf.len)) catch {
        try reply(req, access, "body too large\n", .{ .status = .payload_too_large });
        return;
    };
    defer ctx.gpa.free(line);
    const trimmed = std.mem.trim(u8, line, " \t\r\n");

    // Reject anything that is not a well-formed ClientMsg before it can
    // reach the daemon.
    {
        var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena_state.deinit();
        _ = proto.decode(proto.ClientMsg, arena_state.allocator(), trimmed) catch {
            try reply(req, access,
                \\{"err":{"code":"bad_msg","msg":"not a valid client message"}}
            , .{ .status = .bad_request, .extra_headers = &json_header });
            return;
        };
    }

    const conn = attach.connect(ctx.gpa, ctx.io, ctx.environ, ctx.self_exe) catch {
        try reply(req, access,
            \\{"err":{"code":"daemon","msg":"cannot reach daemon"}}
        , .{ .status = .bad_gateway, .extra_headers = &json_header });
        return;
    };
    defer conn.deinit();

    try conn.writer.writeAll(trimmed);
    try conn.writer.writeAll("\n");
    try conn.writer.flush();
    const daemon_reply = conn.readLine() catch {
        try reply(req, access,
            \\{"err":{"code":"daemon","msg":"daemon closed the connection"}}
        , .{ .status = .bad_gateway, .extra_headers = &json_header });
        return;
    };
    defer ctx.gpa.free(daemon_reply);
    try reply(req, access, daemon_reply, .{ .extra_headers = &json_header });
}

/// Dedicated daemon connection per SSE stream; ends when either side closes.
fn serveEvents(ctx: *ConnCtx, req: *std.http.Server.Request, access: *Access) !void {
    const sid = sidFromQuery(req.head.target) orelse {
        try reply(req, access, "missing or bad sid\n", .{ .status = .bad_request });
        return;
    };

    const conn = attach.connect(ctx.gpa, ctx.io, ctx.environ, ctx.self_exe) catch {
        try reply(req, access, "cannot reach daemon\n", .{ .status = .bad_gateway });
        return;
    };
    defer conn.deinit();

    var sub_buf: [96]u8 = undefined;
    const sub_line = std.fmt.bufPrint(
        &sub_buf,
        "{{\"sub\":{{\"sid\":{d},\"tail_limit\":512}}}}\n",
        .{sid},
    ) catch unreachable;
    try conn.writer.writeAll("{\"session_watch\":{\"incremental\":true}}\n");
    try conn.writer.writeAll(sub_line);
    try conn.writer.flush();

    var stream_buf: [1024]u8 = undefined;
    var response = try req.respondStreaming(&stream_buf, .{ .respond_options = .{
        .transfer_encoding = .none,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });

    access.* = .{ .status = .ok, .bytes = 0 };
    while (true) {
        const line = conn.readLine() catch break;
        defer ctx.gpa.free(line);
        const body = std.mem.trimEnd(u8, line, "\r\n");
        response.writer.writeAll("data: ") catch break;
        response.writer.writeAll(body) catch break;
        response.writer.writeAll("\n\n") catch break;
        // Two-stage flush, both required: BodyWriter buffers its own bytes
        // (writer.flush drains them into the protocol output), and
        // BodyWriter.flush pushes the protocol output to the socket —
        // it does NOT drain the body buffer itself (see endUnflushed).
        response.writer.flush() catch break;
        response.flush() catch break;
        access.bytes += body.len + 8; // "data: " + "\n\n"
    }
}

/// One bounded older-history page as SSE. Unlike /events this stream ends at
/// replay_done; the browser opens it only when the user asks for more.
fn serveHistory(ctx: *ConnCtx, req: *std.http.Server.Request, access: *Access) !void {
    const sid = queryU64(req.head.target, "sid") orelse {
        try reply(req, access, "missing or bad sid\n", .{ .status = .bad_request });
        return;
    };
    const before = queryU64(req.head.target, "before") orelse {
        try reply(req, access, "missing or bad before seq\n", .{ .status = .bad_request });
        return;
    };
    const conn = attach.connect(ctx.gpa, ctx.io, ctx.environ, ctx.self_exe) catch {
        try reply(req, access, "cannot reach daemon\n", .{ .status = .bad_gateway });
        return;
    };
    defer conn.deinit();

    var sub_buf: [144]u8 = undefined;
    const sub_line = std.fmt.bufPrint(
        &sub_buf,
        "{{\"sub\":{{\"sid\":{d},\"tail_limit\":512,\"before_seq\":{d}}}}}\n",
        .{ sid, before },
    ) catch unreachable;
    try conn.writer.writeAll(sub_line);
    try conn.writer.flush();

    var stream_buf: [1024]u8 = undefined;
    var response = try req.respondStreaming(&stream_buf, .{ .respond_options = .{
        .transfer_encoding = .none,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    access.* = .{ .status = .ok, .bytes = 0 };
    while (true) {
        const line = conn.readLine() catch break;
        defer ctx.gpa.free(line);
        const body = std.mem.trimEnd(u8, line, "\r\n");
        response.writer.writeAll("data: ") catch break;
        response.writer.writeAll(body) catch break;
        response.writer.writeAll("\n\n") catch break;
        response.writer.flush() catch break;
        response.flush() catch break;
        access.bytes += body.len + 8; // "data: " + "\n\n"
        if (std.mem.startsWith(u8, body, "{\"replay_done\":")) break;
    }
}

/// Extract `sid=<u64>` from a request target's query string.
pub fn sidFromQuery(target: []const u8) ?u64 {
    return queryU64(target, "sid");
}

/// First value of one request header (case-insensitive name).
fn headerValue(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

/// A Host header is ours when it names loopback or the tailnet DNS name
/// (any port, trailing-dot tolerant). Absent/foreign Hosts — the shape of a
/// DNS-rebinding request — are rejected.
pub fn hostAllowed(tailnet_host: ?[]const u8, host_header: ?[]const u8) bool {
    const raw = host_header orelse return false;
    const host = std.mem.trimEnd(u8, raw[0 .. std.mem.lastIndexOfScalar(u8, raw, ':') orelse raw.len], ".");
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "127.0.0.1")) return true;
    if (tailnet_host) |allowed| {
        if (std.ascii.eqlIgnoreCase(host, std.mem.trimEnd(u8, allowed, "."))) return true;
    }
    return false;
}

/// Browsers attach Origin to every cross-origin POST; its absence means a
/// same-origin request or a non-browser client, both fine. A present Origin
/// must resolve to an allowed host over http(s) — anything else (including
/// the literal "null" of sandboxed frames) is a cross-site request.
pub fn originAllowed(tailnet_host: ?[]const u8, origin_header: ?[]const u8) bool {
    const origin = origin_header orelse return true;
    const rest = if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else
        return false;
    return hostAllowed(tailnet_host, rest);
}

pub fn queryU64(target: []const u8, name: []const u8) ?u64 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return std.fmt.parseInt(u64, pair[eq + 1 ..], 10) catch null;
    }
    return null;
}
