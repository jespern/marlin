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
//! Binds 127.0.0.1 only, and every request (except manifest/icons) must
//! carry the persistent per-user token — `?token=` once, then a
//! SameSite=Strict cookie. That is deliberately a BEARER TOKEN, not a user
//! system: it stops drive-by cross-site POSTs and DNS rebinding from
//! driving the daemon (POST /send forwards any ClientMsg, including
//! shutdown), not a hostile local user. Serving still requires the explicit
//! `[web] enabled = true` opt-in (or MARLIN_WEB=1).

const std = @import("std");
const Io = std.Io;

const config = @import("../core/config.zig");
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

const html = @embedFile("webui.html");
const icon_180 = @embedFile("webui-icon-180.png");
const icon_512 = @embedFile("webui-icon-512.png");
const manifest =
    \\{"name":"marlin","short_name":"marlin","start_url":"/","display":"standalone",
    \\"background_color":"#17191d","theme_color":"#17191d","icons":[
    \\{"src":"/icon-180.png","sizes":"180x180","type":"image/png"},
    \\{"src":"/icon-512.png","sizes":"512x512","type":"image/png"}]}
;
const default_port: u16 = 8377;
const token_len = 32; // hex chars (16 random bytes)

/// Load or mint the persistent access token
/// ($XDG_STATE_HOME|~/.local/state)/marlin/web-token, 0600. Persistent so a
/// phone's home-screen install (whose cookie carries the token) survives
/// server restarts; delete the file to rotate.
fn loadOrCreateToken(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    buf: *[token_len]u8,
) ![]const u8 {
    const state_root = if (environ.get("XDG_STATE_HOME")) |s| blk: {
        if (s.len == 0) break :blk null;
        break :blk try std.fs.path.join(gpa, &.{ s, "marlin" });
    } else null;
    const dir = state_root orelse blk: {
        const home = environ.get("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(gpa, &.{ home, ".local", "state", "marlin" });
    };
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "web-token" });
    defer gpa.free(path);

    if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256))) |existing| {
        defer gpa.free(existing);
        const trimmed = std.mem.trim(u8, existing, " \t\r\n");
        if (trimmed.len == token_len) {
            @memcpy(buf, trimmed[0..token_len]);
            return buf;
        }
    } else |_| {}

    var raw: [token_len / 2]u8 = undefined;
    io.random(&raw);
    const hex = "0123456789abcdef";
    for (raw, 0..) |byte, index| {
        buf[index * 2] = hex[byte >> 4];
        buf[index * 2 + 1] = hex[byte & 0xf];
    }
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf }) catch |e| {
        std.log.warn("could not persist web token ({t}); using an ephemeral one", .{e});
    };
    posixChmod600(path);
    return buf;
}

fn posixChmod600(path: []const u8) void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= pbuf.len) return;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    _ = std.c.chmod(pbuf[0..path.len :0], 0o600);
}

pub fn serve(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    args: []const [:0]const u8,
) !u8 {
    // Deliberately opt-in: this is an unauthenticated localhost surface that
    // can drive every daemon capability. Refuse to start unless the user has
    // said so in durable configuration (or the env override for one-offs).
    {
        var loaded = config.load(gpa, io, environ) catch |e| {
            std.log.err("cannot load config: {t}", .{e});
            return 1;
        };
        defer loaded.deinit();
        if (!loaded.value.web_enabled) {
            std.log.err(
                "the web ui is disabled (it is an UNAUTHENTICATED local control surface).\n" ++
                    "  enable it deliberately: add\n" ++
                    "    [web]\n" ++
                    "    enabled = true\n" ++
                    "  to ~/.config/marlin/config.toml, or run once with MARLIN_WEB=1.",
                .{},
            );
            return 2;
        }
    }

    var port: u16 = default_port;
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

    var token_buf: [token_len]u8 = undefined;
    const token = loadOrCreateToken(gpa, io, environ, &token_buf) catch |e| {
        std.log.err("cannot establish web token: {t}", .{e});
        return 1;
    };

    var addr = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        std.log.err("cannot listen on 127.0.0.1:{d}: {t}", .{ port, e });
        return 1;
    };
    defer server.deinit(io);
    std.log.info("marlin web ui on http://127.0.0.1:{d}/?token={s}", .{ port, token });
    std.log.info("(the token gates every request; open the full URL once per browser)", .{});

    while (true) {
        const stream = server.accept(io) catch break;
        const ctx = gpa.create(ConnCtx) catch {
            var s = stream;
            s.close(io);
            continue;
        };
        ctx.* = .{ .gpa = gpa, .io = io, .environ = environ, .self_exe = self_exe, .stream = stream, .token = token };
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
    token: []const u8,
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

fn handleRequest(ctx: *ConnCtx, req: *std.http.Server.Request) !void {
    const target = req.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];

    // Everything but the manifest/icons (no secrets; browsers fetch the
    // manifest credential-less) requires the token: `?token=` on the first
    // visit, after which a SameSite=Strict cookie carries it — which is what
    // actually defuses cross-site POSTs and DNS rebinding, since neither
    // sends our cookie and neither knows the token.
    const public = std.mem.eql(u8, path, "/manifest.webmanifest") or
        std.mem.startsWith(u8, path, "/icon-");
    const via_query = tokenMatch(ctx.token, queryValue(target, "token"));
    if (!public and !via_query and !tokenMatch(ctx.token, cookieValue(req, "marlin_token"))) {
        try req.respond(
            "forbidden: open the ?token= URL printed by `marlin web`\n",
            .{ .status = .forbidden },
        );
        return;
    }
    // Refresh the cookie whenever the token arrived by query, so a pasted
    // URL (or a home-screen install) upgrades itself to cookie auth.
    var cookie_buf: [128]u8 = undefined;
    const set_cookie: []const std.http.Header = if (via_query) &.{.{
        .name = "set-cookie",
        .value = std.fmt.bufPrint(
            &cookie_buf,
            "marlin_token={s}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict",
            .{ctx.token},
        ) catch unreachable,
    }} else &.{};

    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        var all: [2]std.http.Header = undefined;
        all[0] = .{ .name = "content-type", .value = "text/html; charset=utf-8" };
        var count: usize = 1;
        if (set_cookie.len > 0) {
            all[1] = set_cookie[0];
            count = 2;
        }
        try req.respond(html, .{ .extra_headers = all[0..count] });
    } else if (std.mem.eql(u8, target, "/manifest.webmanifest")) {
        try req.respond(manifest, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/manifest+json" },
        } });
    } else if (std.mem.eql(u8, target, "/icon-180.png")) {
        try req.respond(icon_180, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "image/png" },
        } });
    } else if (std.mem.eql(u8, target, "/icon-512.png")) {
        try req.respond(icon_512, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "image/png" },
        } });
    } else if (std.mem.startsWith(u8, target, "/events")) {
        try serveEvents(ctx, req);
    } else if (std.mem.startsWith(u8, target, "/history")) {
        try serveHistory(ctx, req);
    } else if (std.mem.eql(u8, target, "/send") and req.head.method == .POST) {
        try serveSend(ctx, req);
    } else {
        try req.respond("not found\n", .{ .status = .not_found });
    }
}

/// Forward one client message and return the daemon's first reply line.
fn serveSend(ctx: *ConnCtx, req: *std.http.Server.Request) !void {
    const json_header = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
    };

    var body_buf: [64 * 1024]u8 = undefined;
    const body_reader = try req.readerExpectContinue(&body_buf);
    const line = body_reader.allocRemaining(ctx.gpa, .limited(body_buf.len)) catch {
        try req.respond("body too large\n", .{ .status = .payload_too_large });
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
            try req.respond(
                \\{"err":{"code":"bad_msg","msg":"not a valid client message"}}
            , .{ .status = .bad_request, .extra_headers = &json_header });
            return;
        };
    }

    const conn = attach.connect(ctx.gpa, ctx.io, ctx.environ, ctx.self_exe) catch {
        try req.respond(
            \\{"err":{"code":"daemon","msg":"cannot reach daemon"}}
        , .{ .status = .bad_gateway, .extra_headers = &json_header });
        return;
    };
    defer conn.deinit();

    try conn.writer.interface.writeAll(trimmed);
    try conn.writer.interface.writeAll("\n");
    try conn.writer.interface.flush();
    const reply = conn.readLine() catch {
        try req.respond(
            \\{"err":{"code":"daemon","msg":"daemon closed the connection"}}
        , .{ .status = .bad_gateway, .extra_headers = &json_header });
        return;
    };
    defer ctx.gpa.free(reply);
    try req.respond(reply, .{ .extra_headers = &json_header });
}

/// Dedicated daemon connection per SSE stream; ends when either side closes.
fn serveEvents(ctx: *ConnCtx, req: *std.http.Server.Request) !void {
    const sid = sidFromQuery(req.head.target) orelse {
        try req.respond("missing or bad sid\n", .{ .status = .bad_request });
        return;
    };

    const conn = attach.connect(ctx.gpa, ctx.io, ctx.environ, ctx.self_exe) catch {
        try req.respond("cannot reach daemon\n", .{ .status = .bad_gateway });
        return;
    };
    defer conn.deinit();

    var sub_buf: [96]u8 = undefined;
    const sub_line = std.fmt.bufPrint(
        &sub_buf,
        "{{\"sub\":{{\"sid\":{d},\"tail_limit\":512}}}}\n",
        .{sid},
    ) catch unreachable;
    try conn.writer.interface.writeAll("{\"session_watch\":{\"incremental\":true}}\n");
    try conn.writer.interface.writeAll(sub_line);
    try conn.writer.interface.flush();

    var stream_buf: [1024]u8 = undefined;
    var response = try req.respondStreaming(&stream_buf, .{ .respond_options = .{
        .transfer_encoding = .none,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });

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
    }
}

/// One bounded older-history page as SSE. Unlike /events this stream ends at
/// replay_done; the browser opens it only when the user asks for more.
fn serveHistory(ctx: *ConnCtx, req: *std.http.Server.Request) !void {
    const sid = queryU64(req.head.target, "sid") orelse {
        try req.respond("missing or bad sid\n", .{ .status = .bad_request });
        return;
    };
    const before = queryU64(req.head.target, "before") orelse {
        try req.respond("missing or bad before seq\n", .{ .status = .bad_request });
        return;
    };
    const conn = attach.connect(ctx.gpa, ctx.io, ctx.environ, ctx.self_exe) catch {
        try req.respond("cannot reach daemon\n", .{ .status = .bad_gateway });
        return;
    };
    defer conn.deinit();

    var sub_buf: [144]u8 = undefined;
    const sub_line = std.fmt.bufPrint(
        &sub_buf,
        "{{\"sub\":{{\"sid\":{d},\"tail_limit\":512,\"before_seq\":{d}}}}}\n",
        .{ sid, before },
    ) catch unreachable;
    try conn.writer.interface.writeAll(sub_line);
    try conn.writer.interface.flush();

    var stream_buf: [1024]u8 = undefined;
    var response = try req.respondStreaming(&stream_buf, .{ .respond_options = .{
        .transfer_encoding = .none,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "cache-control", .value = "no-cache" },
        },
    } });
    while (true) {
        const line = conn.readLine() catch break;
        defer ctx.gpa.free(line);
        const body = std.mem.trimEnd(u8, line, "\r\n");
        response.writer.writeAll("data: ") catch break;
        response.writer.writeAll(body) catch break;
        response.writer.writeAll("\n\n") catch break;
        response.writer.flush() catch break;
        response.flush() catch break;
        if (std.mem.startsWith(u8, body, "{\"replay_done\":")) break;
    }
}

/// Extract `sid=<u64>` from a request target's query string.
fn sidFromQuery(target: []const u8) ?u64 {
    return queryU64(target, "sid");
}

/// Raw value of one query parameter (no percent-decoding: tokens are hex).
fn queryValue(target: []const u8, name: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// Value of one cookie from the request's Cookie header(s).
fn cookieValue(req: *const std.http.Server.Request, name: []const u8) ?[]const u8 {
    var it = req.iterateHeaders();
    while (it.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "cookie")) continue;
        var cookies = std.mem.splitScalar(u8, header.value, ';');
        while (cookies.next()) |raw| {
            const cookie = std.mem.trim(u8, raw, " ");
            const eq = std.mem.indexOfScalar(u8, cookie, '=') orelse continue;
            if (std.mem.eql(u8, cookie[0..eq], name)) return cookie[eq + 1 ..];
        }
    }
    return null;
}

/// Constant-time token comparison; length mismatch is an immediate no.
fn tokenMatch(expected: []const u8, candidate: ?[]const u8) bool {
    const given = candidate orelse return false;
    if (expected.len != token_len or given.len != token_len) return false;
    var a: [token_len]u8 = undefined;
    var b: [token_len]u8 = undefined;
    @memcpy(&a, expected[0..token_len]);
    @memcpy(&b, given[0..token_len]);
    return std.crypto.timing_safe.eql([token_len]u8, a, b);
}

fn queryU64(target: []const u8, name: []const u8) ?u64 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], name)) continue;
        return std.fmt.parseInt(u64, pair[eq + 1 ..], 10) catch null;
    }
    return null;
}

test "sid query parsing accepts u64 and rejects garbage" {
    try std.testing.expectEqual(@as(?u64, 42), sidFromQuery("/events?sid=42"));
    try std.testing.expectEqual(
        @as(?u64, 1874397504305914847),
        sidFromQuery("/events?a=b&sid=1874397504305914847"),
    );
    try std.testing.expectEqual(@as(?u64, null), sidFromQuery("/events"));
    try std.testing.expectEqual(@as(?u64, null), sidFromQuery("/events?sid=abc"));
    try std.testing.expectEqual(@as(?u64, null), sidFromQuery("/events?side=1"));
    try std.testing.expectEqual(@as(?u64, 99), queryU64("/history?sid=42&before=99", "before"));
    try std.testing.expectEqual(@as(?u64, null), queryU64("/history?sid=42&before=nope", "before"));
}

test {
    std.testing.refAllDecls(@This());
}

test "token gate: query and cookie forms match, garbage does not" {
    const tok = "0123456789abcdef0123456789abcdef";
    try std.testing.expect(tokenMatch(tok, queryValue("/?token=0123456789abcdef0123456789abcdef", "token")));
    try std.testing.expect(!tokenMatch(tok, queryValue("/?token=wrong", "token")));
    try std.testing.expect(!tokenMatch(tok, queryValue("/", "token")));
    try std.testing.expect(!tokenMatch(tok, null));
    try std.testing.expectEqualStrings(
        "abc",
        queryValue("/events?sid=4&token=abc", "token").?,
    );
}
