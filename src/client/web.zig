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
//! Binds 127.0.0.1 only. There is NO authentication: anything that can reach
//! the port can drive marlin (including reboot/shutdown). POC, not a deploy —
//! which is why serving requires the explicit `[web] enabled = true` opt-in
//! (or MARLIN_WEB=1); it must never be reachable by default.

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

    var addr = Io.net.IpAddress.parse("127.0.0.1", port) catch unreachable;
    var server = addr.listen(io, .{ .reuse_address = true }) catch |e| {
        std.log.err("cannot listen on 127.0.0.1:{d}: {t}", .{ port, e });
        return 1;
    };
    defer server.deinit(io);
    std.log.info("marlin web ui on http://127.0.0.1:{d}", .{port});

    while (true) {
        const stream = server.accept(io) catch break;
        const ctx = gpa.create(ConnCtx) catch {
            var s = stream;
            s.close(io);
            continue;
        };
        ctx.* = .{ .gpa = gpa, .io = io, .environ = environ, .self_exe = self_exe, .stream = stream };
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
    if (std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/index.html")) {
        try req.respond(html, .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        } });
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
