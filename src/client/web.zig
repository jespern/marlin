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
//! Binds `[web] listen` (127.0.0.1 by default). Loopback is trusted as
//! before: a loopback peer asking for a loopback Host needs no login. Every
//! other request names one of `[web] hosts` — the address a reverse proxy
//! serves over HTTPS — and must carry a paired device cookie
//! (mobile/pairing.zig): the phone types a code the terminal shows, once.
//! Unpaired requests get only the app shell, /connection, and /pair. With
//! `[web] proxy` set, no other non-loopback peer may even connect.
//! What a BROWSER can be tricked into sending identifies itself in headers:
//! DNS rebinding arrives under a foreign Host, cross-site POSTs carry a
//! foreign Origin. Both are rejected. A hostile local user is explicitly out
//! of scope (loopback is machine-wide — /web disable on a multi-user box).
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
const pairing = @import("../mobile/pairing.zig");
const service_worker = @embedFile("webui-sw.js");
const icon_180 = @embedFile("webui-icon-180.png");
const icon_512 = @embedFile("webui-icon-512.jpg");
const manifest =
    \\{"name":"marlin","short_name":"marlin","start_url":"/","display":"standalone",
    \\"background_color":"#17191d","theme_color":"#17191d","icons":[
    \\{"src":"/icon-180.png","sizes":"180x180","type":"image/png"},
    \\{"src":"/icon-512.jpg","sizes":"512x512","type":"image/jpeg"}]}
;
const default_port: u16 = 8377;

/// Shell sessions are a terminal-client feature: a browser never gets a PTY,
/// nor sees one. Every shell_* message is refused, including any added later,
/// since attaching or listing would expose a running shell's screen.
pub fn allowedOverWeb(msg: proto.ClientMsg) bool {
    return !std.mem.startsWith(u8, @tagName(msg), "shell_");
}

/// Block on the daemon-held stdin pipe; its EOF means the daemon exited (any
/// cause), so exit too. Runs on a detached thread — the process dying is the
/// point, so there is nothing to join.
fn parentDeathWatch(io: Io) void {
    const in = Io.File.stdin();
    var buf: [64]u8 = undefined;
    while (true) {
        const n = in.readStreaming(io, &.{&buf}) catch break;
        if (n == 0) break;
    }
    std.process.exit(0);
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
    var loaded = config.load(gpa, io, environ) catch |e| {
        std.log.err("cannot load config: {t}", .{e});
        return 1;
    };
    defer loaded.deinit();
    const cfg = loaded.value;
    if (!cfg.web_enabled) {
        std.log.err(
            "the web ui is disabled — run /web enable in marlin (or set [web] enabled = true; MARLIN_WEB=1 for a one-off).",
            .{},
        );
        return 2;
    }
    var port: u16 = cfg.web_port;

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
    var addr = Io.net.IpAddress.parse(cfg.web_listen, port) catch {
        std.log.err("[web] listen = \"{s}\" is not an IP address", .{cfg.web_listen});
        return 2;
    };
    const proxy: ?Io.net.IpAddress = if (cfg.web_proxy) |text| Io.net.IpAddress.parse(text, 0) catch {
        std.log.err("[web] proxy = \"{s}\" is not an IP address", .{text});
        return 2;
    } else null;

    // Connect once up front: autostarts the daemon and fails fast on a
    // broken socket before we claim the HTTP port.
    const probe = attach.connect(gpa, io, environ, self_exe) catch |e| {
        std.log.err("cannot reach daemon: {t}", .{e});
        return 1;
    };
    probe.deinit();

    // Exit when the spawning daemon goes away. Without this an orphaned
    // companion outlives its daemon and keeps the port (see web_service.zig).
    // reuse_address stays on so /reboot can rebind through TIME_WAIT; the
    // watchdog is what actually prevents two live listeners coexisting, since
    // it reaps the old companion before the new one binds.
    if (!(Io.File.stdin().isTty(io) catch true)) {
        const watch = std.Thread.spawn(.{}, parentDeathWatch, .{io}) catch null;
        if (watch) |t| t.detach();
    }

    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        std.log.err("cannot listen on {f}: {t}", .{ addr, e });
        return 1;
    };
    defer server.deinit(io);

    const pairing_root = pairing.stateRoot(gpa, environ) catch null;
    defer if (pairing_root) |root| gpa.free(root);
    var settings: Settings = .{
        .hosts = cfg.web_hosts,
        .proxy = proxy,
        .push_enabled = cfg.web_push and environ.get("MARLIN_REMOTE") == null,
        .pairing_root = pairing_root,
    };
    std.log.info("marlin web ui on http://{f}/", .{addr});
    if (cfg.web_hosts.len > 0) {
        std.log.info("phone: https://{s}/ (paired devices only)", .{cfg.web_hosts[0]});
    } else if (!isLoopback(addr)) {
        std.log.warn("listening beyond loopback with no [web] hosts: remote requests are refused", .{});
    }

    while (true) {
        var stream = server.accept(io) catch break;
        const peer = stream.socket.address;
        if (!peerAllowed(proxy, peer)) {
            std.log.warn("refused {f}: not the [web] proxy", .{peer});
            stream.close(io);
            continue;
        }
        const ctx = gpa.create(ConnCtx) catch {
            stream.close(io);
            continue;
        };
        ctx.* = .{ .gpa = gpa, .io = io, .environ = environ, .self_exe = self_exe, .stream = stream, .peer = peer, .settings = &settings };
        const thread = std.Thread.spawn(.{}, connMain, .{ctx}) catch {
            stream.close(io);
            gpa.destroy(ctx);
            continue;
        };
        thread.detach();
    }
    return 0;
}

/// Read once at startup and shared by every connection thread.
const Settings = struct {
    /// `[web] hosts`: public names allowed in Host/Origin besides loopback.
    hosts: []const []const u8,
    proxy: ?Io.net.IpAddress,
    push_enabled: bool,
    /// pairing.json's directory; null without HOME/XDG_STATE_HOME, in which
    /// case nothing can pair and only loopback works.
    pairing_root: ?[]const u8,
    /// Serializes this process's read-modify-write of pairing.json.
    pair_mutex: Io.Mutex = .init,
};

const ConnCtx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    stream: Io.net.Stream,
    peer: Io.net.IpAddress,
    settings: *Settings,
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

/// The parts of a request head that outlive its body. Reading a body
/// invalidates `req.head` strings and may reuse the header buffer, so every
/// handler reads these instead.
const Head = struct {
    method: std.http.Method,
    version: std.http.Version,
    target_buf: [512]u8 = undefined,
    target_len: usize = 0,
    client_buf: [64]u8 = undefined,
    client_len: usize = 0,
    user_agent: []const u8 = "",
    user_agent_buf: [256]u8 = undefined,
    https: bool = false,

    fn target(self: *const Head) []const u8 {
        return self.target_buf[0..self.target_len];
    }
    fn client(self: *const Head) []const u8 {
        return self.client_buf[0..self.client_len];
    }
};

/// One access.log line per finished request, written directly to stderr
/// (NOT std.log: no `info:` prefix) so the companion ring and the /web tab
/// show plain Common Log Format. Streams log at completion with their total
/// body bytes, the way nginx does.
fn logAccess(ctx: *ConnCtx, head: *const Head, access: Access) void {
    var when_buf: [40]u8 = undefined;
    const when = clfTime(&when_buf, Io.Timestamp.now(ctx.io, .real).toSeconds());
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writer(ctx.io, &buffer);
    writer.interface.print("{s} - - [{s}] \"{s} {s} {s}\" {d} {d}\n", .{
        head.client(),
        when,
        @tagName(head.method),
        head.target(),
        @tagName(head.version),
        @backingInt(access.status),
        access.bytes,
    }) catch return;
    writer.interface.flush() catch {};
}

fn handleRequest(ctx: *ConnCtx, req: *std.http.Server.Request) !void {
    var head: Head = .{ .method = req.head.method, .version = req.head.version };
    head.target_len = @min(req.head.target.len, head.target_buf.len);
    @memcpy(head.target_buf[0..head.target_len], req.head.target[0..head.target_len]);
    head.client_len = clientAddress(&head.client_buf, ctx.settings.proxy, ctx.peer, headerValue(req, "x-forwarded-for")).len;
    if (headerValue(req, "user-agent")) |ua| {
        const n = @min(ua.len, head.user_agent_buf.len);
        @memcpy(head.user_agent_buf[0..n], ua[0..n]);
        head.user_agent = head.user_agent_buf[0..n];
    }
    head.https = if (headerValue(req, "x-forwarded-proto")) |proto_name| std.ascii.eqlIgnoreCase(proto_name, "https") else false;
    const target = head.target();
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    var access = Access{};
    defer logAccess(ctx, &head, access);

    // These header checks close the two ways a BROWSER can be steered across
    // the boundary. DNS rebinding reaches us under the attacker's Host; a
    // cross-site POST carries the attacker's Origin. Same-origin requests,
    // curl, and the installed PWA pass untouched.
    const settings = ctx.settings;
    const host = headerValue(req, "host");
    if (!hostAllowed(settings.hosts, host)) {
        try reply(req, &access, "forbidden: unrecognized Host\n", .{ .status = .forbidden });
        return;
    }
    if (req.head.method == .POST and !originAllowed(settings.hosts, headerValue(req, "origin"))) {
        try reply(req, &access, "forbidden: cross-origin request\n", .{ .status = .forbidden });
        return;
    }

    // Loopback asking for itself is trusted, as it always was. Anything
    // addressed to a public name is a remote device and must be paired.
    const local = isLocal(ctx.peer, host);
    var token_buf: [pairing.token_len]u8 = undefined;
    const device: ?[]const u8 = if (local) null else knownDevice(ctx, &token_buf, headerValue(req, "cookie"));
    const paired = local or device != null;
    if (!paired and !publicRoute(req.head.method, path)) {
        try reply(req, &access,
            \\{"err":{"code":"unpaired","msg":"pair this device first"}}
        , .{ .status = .forbidden, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
        return;
    }

    if (std.mem.eql(u8, target, "/connection")) {
        const body = try std.json.Stringify.valueAlloc(ctx.gpa, .{
            .host = if (settings.hosts.len > 0) settings.hosts[0] else null,
            .push_enabled = settings.push_enabled,
            .paired = paired,
        }, .{});
        defer ctx.gpa.free(body);
        // Each visit renews a paired device's cookie, so it never lapses
        // while the phone is in use.
        var cookie_buf: [256]u8 = undefined;
        const renew: []const std.http.Header = if (device) |token| &.{.{ .name = "set-cookie", .value = deviceCookie(&cookie_buf, token, head.https) }} else &.{};
        var headers: [3]std.http.Header = .{ .{ .name = "content-type", .value = "application/json" }, .{ .name = "cache-control", .value = "no-store" }, undefined };
        if (renew.len == 1) headers[2] = renew[0];
        try reply(req, &access, body, .{ .extra_headers = headers[0 .. 2 + renew.len] });
    } else if (std.mem.eql(u8, path, "/pair") and req.head.method == .POST) {
        try servePair(ctx, req, &head, &access);
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
    } else if (std.mem.eql(u8, target, "/icon-512.jpg")) {
        try reply(req, &access, icon_512, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "image/jpeg" },
        } });
    } else if (std.mem.startsWith(u8, target, "/events")) {
        try serveEvents(ctx, req, target, device, &access);
        // An event stream has no length: only closing the connection tells
        // the client it ended (a revoked device, a daemon that went away).
        return error.StreamEnded;
    } else if (std.mem.startsWith(u8, target, "/history")) {
        try serveHistory(ctx, req, target, &access);
        return error.StreamEnded;
    } else if (std.mem.eql(u8, target, "/send") and req.head.method == .POST) {
        try serveSend(ctx, req, &access);
    } else {
        try reply(req, &access, "not found\n", .{ .status = .not_found });
    }
}

/// What an unpaired device may load: the app shell (so it can show the
/// pairing screen), /connection (so it knows to), and /pair itself.
pub fn publicRoute(method: std.http.Method, path: []const u8) bool {
    if (method == .POST) return std.mem.eql(u8, path, "/pair");
    if (method != .GET and method != .HEAD) return false;
    const routes = [_][]const u8{ "/", "/index.html", "/manifest.webmanifest", "/icon-180.png", "/icon-512.jpg", "/sw.js", "/connection" };
    for (routes) |route| {
        if (std.mem.eql(u8, path, route)) return true;
    }
    return false;
}

/// The device token from the request's cookie when it belongs to a paired
/// device, copied into `buf`; null otherwise.
fn knownDevice(ctx: *ConnCtx, buf: *[pairing.token_len]u8, cookie_header: ?[]const u8) ?[]const u8 {
    const root = ctx.settings.pairing_root orelse return null;
    const token = cookieValue(cookie_header, pairing.cookie_name) orelse return null;
    if (token.len != pairing.token_len) return null;
    if (!(pairing.verify(ctx.gpa, ctx.io, root, token) catch false)) return null;
    @memcpy(buf, token);
    return buf;
}

pub fn deviceCookie(buf: []u8, token: []const u8, secure: bool) []const u8 {
    return std.fmt.bufPrint(buf, "{s}={s}; Path=/; Max-Age={d}; HttpOnly; SameSite=Lax{s}", .{
        pairing.cookie_name,
        token,
        pairing.cookie_max_age_s,
        if (secure) "; Secure" else "",
    }) catch unreachable;
}

/// POST /pair {"code":"123456"}: trade the code /web shows for a device
/// cookie. A wrong guess counts against the code (pairing.max_failures).
fn servePair(ctx: *ConnCtx, req: *std.http.Server.Request, head: *const Head, access: *Access) !void {
    const json_header = [_]std.http.Header{.{ .name = "content-type", .value = "application/json" }};
    const root = ctx.settings.pairing_root orelse {
        try reply(req, access,
            \\{"err":{"code":"pairing","msg":"pairing needs a state directory on the Marlin host"}}
        , .{ .status = .service_unavailable, .extra_headers = &json_header });
        return;
    };
    var body_buf: [256]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&body_buf);
    const body = body_reader.allocRemaining(ctx.gpa, .limited(body_buf.len)) catch {
        try reply(req, access, "body too large\n", .{ .status = .payload_too_large });
        return;
    };
    defer ctx.gpa.free(body);
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const attempt = std.json.parseFromSliceLeaky(struct { code: []const u8 }, arena_state.allocator(), body, .{ .ignore_unknown_fields = true }) catch {
        try reply(req, access,
            \\{"err":{"code":"bad_msg","msg":"expected {\"code\":\"...\"}"}}
        , .{ .status = .bad_request, .extra_headers = &json_header });
        return;
    };

    const name = pairing.deviceName(if (head.user_agent.len > 0) head.user_agent else null);
    const now_ms = Io.Timestamp.now(ctx.io, .real).toMilliseconds();
    const redeemed = blk: {
        ctx.settings.pair_mutex.lockUncancelable(ctx.io);
        defer ctx.settings.pair_mutex.unlock(ctx.io);
        break :blk pairing.redeem(ctx.gpa, ctx.io, root, attempt.code, name, now_ms) catch |err| {
            std.log.err("pairing failed: {t}", .{err});
            try reply(req, access,
                \\{"err":{"code":"pairing","msg":"could not save the pairing; see /web on the Marlin host"}}
            , .{ .status = .internal_server_error, .extra_headers = &json_header });
            return;
        };
    };
    const device = redeemed orelse {
        std.log.warn("pairing attempt from {s} rejected", .{head.client()});
        try reply(req, access,
            \\{"err":{"code":"bad_code","msg":"wrong or expired code — press p in /web for a new one"}}
        , .{ .status = .forbidden, .extra_headers = &json_header });
        return;
    };
    std.log.info("paired {s} #{d} from {s}", .{ name, device.id, head.client() });
    var cookie_buf: [256]u8 = undefined;
    try reply(req, access, "{\"paired\":true}", .{ .extra_headers = &.{
        json_header[0],
        .{ .name = "cache-control", .value = "no-store" },
        .{ .name = "set-cookie", .value = deviceCookie(&cookie_buf, &device.token, head.https) },
    } });
}

fn servePush(ctx: *ConnCtx, req: *std.http.Server.Request, path: []const u8, access: *Access) !void {
    if (!ctx.settings.push_enabled) {
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
        const msg = proto.decode(proto.ClientMsg, arena_state.allocator(), trimmed) catch {
            try reply(req, access,
                \\{"err":{"code":"bad_msg","msg":"not a valid client message"}}
            , .{ .status = .bad_request, .extra_headers = &json_header });
            return;
        };
        if (!allowedOverWeb(msg)) {
            try reply(req, access,
                \\{"err":{"code":"forbidden","msg":"shell messages are not available over the web bridge"}}
            , .{ .status = .forbidden, .extra_headers = &json_header });
            return;
        }
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
/// `device` is the paired device's token (null for loopback); the stream
/// ends as soon as that device is unpaired.
fn serveEvents(ctx: *ConnCtx, req: *std.http.Server.Request, target: []const u8, device: ?[]const u8, access: *Access) !void {
    const sid = sidFromQuery(target) orelse {
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
        if (std.mem.startsWith(u8, body, "{\"web_devices_changed\":")) {
            const token = device orelse continue;
            const root = ctx.settings.pairing_root orelse break;
            if (pairing.verify(ctx.gpa, ctx.io, root, token) catch false) continue;
            break;
        }
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
fn serveHistory(ctx: *ConnCtx, req: *std.http.Server.Request, target: []const u8, access: *Access) !void {
    const sid = queryU64(target, "sid") orelse {
        try reply(req, access, "missing or bad sid\n", .{ .status = .bad_request });
        return;
    };
    const before = queryU64(target, "before") orelse {
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

/// The name part of a Host header: port and trailing dot stripped.
fn hostName(raw: []const u8) []const u8 {
    return std.mem.trimEnd(u8, raw[0 .. std.mem.lastIndexOfScalar(u8, raw, ':') orelse raw.len], ".");
}

fn isLoopbackName(host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
}

/// A Host header is ours when it names loopback or one of `[web] hosts`
/// (any port, case- and trailing-dot tolerant). Absent/foreign Hosts — the
/// shape of a DNS-rebinding request — are rejected.
pub fn hostAllowed(hosts: []const []const u8, host_header: ?[]const u8) bool {
    const host = hostName(host_header orelse return false);
    if (isLoopbackName(host)) return true;
    for (hosts) |allowed| {
        if (std.ascii.eqlIgnoreCase(host, std.mem.trimEnd(u8, allowed, "."))) return true;
    }
    return false;
}

/// Browsers attach Origin to every cross-origin POST; its absence means a
/// same-origin request or a non-browser client, both fine. A present Origin
/// must resolve to an allowed host over http(s) — anything else (including
/// the literal "null" of sandboxed frames) is a cross-site request.
pub fn originAllowed(hosts: []const []const u8, origin_header: ?[]const u8) bool {
    const origin = origin_header orelse return true;
    const rest = if (std.mem.startsWith(u8, origin, "https://"))
        origin["https://".len..]
    else if (std.mem.startsWith(u8, origin, "http://"))
        origin["http://".len..]
    else
        return false;
    return hostAllowed(hosts, rest);
}

/// The local machine: a loopback peer asking for a loopback name. Both
/// halves matter — a LAN peer can claim `Host: localhost`, and a proxy on
/// this machine connects from loopback on behalf of a remote phone.
pub fn isLocal(peer: Io.net.IpAddress, host_header: ?[]const u8) bool {
    return isLoopback(peer) and isLoopbackName(hostName(host_header orelse return false));
}

/// IPv4 bytes of an address, unwrapping IPv4-mapped IPv6 (a dual-stack
/// listener sees v4 peers as ::ffff:a.b.c.d).
fn ip4Bytes(addr: Io.net.IpAddress) ?[4]u8 {
    return switch (addr) {
        .ip4 => |a| a.bytes,
        .ip6 => |a| if (std.mem.eql(u8, a.bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) a.bytes[12..16].* else null,
    };
}

const ip6_loopback = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

pub fn isLoopback(addr: Io.net.IpAddress) bool {
    if (ip4Bytes(addr)) |bytes| return bytes[0] == 127;
    return switch (addr) {
        .ip6 => |a| std.mem.eql(u8, &a.bytes, &ip6_loopback),
        .ip4 => unreachable,
    };
}

/// Same host, any port.
pub fn sameHost(a: Io.net.IpAddress, b: Io.net.IpAddress) bool {
    if (ip4Bytes(a)) |x| {
        const y = ip4Bytes(b) orelse return false;
        return std.mem.eql(u8, &x, &y);
    }
    if (ip4Bytes(b) != null) return false;
    return std.mem.eql(u8, &a.ip6.bytes, &b.ip6.bytes);
}

/// Loopback always connects; with `[web] proxy` set, it is the only other
/// peer that may.
pub fn peerAllowed(proxy: ?Io.net.IpAddress, peer: Io.net.IpAddress) bool {
    if (isLoopback(peer)) return true;
    const only = proxy orelse return true;
    return sameHost(only, peer);
}

/// The client to name in the access log: the peer's address, or the first
/// X-Forwarded-For entry when the peer is the configured proxy (only it is
/// trusted to say who it forwards for).
pub fn clientAddress(buf: []u8, proxy: ?Io.net.IpAddress, peer: Io.net.IpAddress, forwarded_for: ?[]const u8) []const u8 {
    if (proxy) |p| if (sameHost(p, peer)) if (forwarded_for) |list| {
        const first = std.mem.trim(u8, list[0 .. std.mem.indexOfScalar(u8, list, ',') orelse list.len], " \t");
        if (first.len > 0 and first.len <= buf.len) {
            @memcpy(buf[0..first.len], first);
            return buf[0..first.len];
        }
    };
    if (ip4Bytes(peer)) |b| return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch buf[0..0];
    var w: Io.Writer = .fixed(buf);
    peer.format(&w) catch return buf[0..0];
    // "[addr]:port" → "addr"
    const text = w.buffered();
    const end = std.mem.indexOfScalar(u8, text, ']') orelse return text;
    return text[1..end];
}

/// One cookie's value from a Cookie header ("a=1; b=2").
pub fn cookieValue(header: ?[]const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, header orelse return null, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " \t");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], name)) return trimmed[eq + 1 ..];
    }
    return null;
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
