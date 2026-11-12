//! End to end against a fake OAuth + MCP server on loopback: the 401
//! challenge, metadata discovery, registration, the authorize redirect, the
//! callback, the PKCE-checked token exchange, bearer discovery, an SSE reply
//! that stays open, routing headers, and refresh on expiry.

const std = @import("std");
const Io = std.Io;
const mcp = @import("tools/mcp.zig");
const oauth = @import("tools/mcp_oauth.zig");
const mcp_login = @import("mcp_login.zig");
const http = @import("provider/http.zig");

const Fake = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16,
    stop: std.atomic.Value(bool) = .init(false),
    challenge: [64]u8 = undefined,
    challenge_len: usize = 0,
    token: []const u8 = "tok1",
    refreshed: bool = false,
    stream_held: std.atomic.Value(u32) = .init(0),
    failure: ?[]const u8 = null,

    fn base(self: *const Fake, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port}) catch unreachable;
    }

    fn serve(self: *Fake) void {
        while (!self.stop.load(.acquire)) {
            var stream = self.listener.accept(self.io) catch return;
            self.handle(stream) catch |err| {
                if (self.failure == null) self.failure = @errorName(err);
            };
            stream.close(self.io);
        }
    }

    fn handle(self: *Fake, stream: Io.net.Stream) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var read_buf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, self.io, &read_buf);
        const line = std.mem.trim(u8, try reader.interface.takeDelimiterInclusive('\n'), " \r\n");
        var parts = std.mem.tokenizeScalar(u8, line, ' ');
        _ = parts.next() orelse return; // method: routing is by path
        const target = try arena.dupe(u8, parts.next() orelse return);
        var headers: std.StringHashMapUnmanaged([]const u8) = .empty;
        var length: usize = 0;
        while (true) {
            const h = std.mem.trim(u8, try reader.interface.takeDelimiterInclusive('\n'), " \r\n");
            if (h.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
            const name = try std.ascii.allocLowerString(arena, std.mem.trim(u8, h[0..colon], " "));
            const value = try arena.dupe(u8, std.mem.trim(u8, h[colon + 1 ..], " "));
            try headers.put(arena, name, value);
            if (std.mem.eql(u8, name, "content-length")) length = try std.fmt.parseInt(usize, value, 10);
        }
        const body = try reader.interface.readAllocAll(arena, length);
        if (std.mem.eql(u8, target, "/__stop")) return;

        var base_buf: [64]u8 = undefined;
        const b = self.base(&base_buf);
        var write_buf: [16 * 1024]u8 = undefined;
        var w = Io.net.Stream.Writer.init(stream, self.io, &write_buf);
        const out = &w.interface;
        defer out.flush() catch {};

        if (std.mem.eql(u8, target, "/.well-known/oauth-protected-resource/mcp")) {
            return json(out, try std.fmt.allocPrint(arena, "{{\"resource\":\"{s}/mcp\",\"authorization_servers\":[\"{s}\"],\"scopes_supported\":[\"read\"]}}", .{ b, b }));
        }
        if (std.mem.eql(u8, target, "/.well-known/oauth-authorization-server")) {
            return json(out, try std.fmt.allocPrint(arena,
                \\{{"issuer":"{s}","authorization_endpoint":"{s}/authorize","token_endpoint":"{s}/token","registration_endpoint":"{s}/register","code_challenge_methods_supported":["S256"],"scopes_supported":["read","offline_access"],"authorization_response_iss_parameter_supported":true}}
            , .{ b, b, b, b }));
        }
        if (std.mem.eql(u8, target, "/register")) {
            const doc = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
            if (!std.mem.eql(u8, doc.object.get("application_type").?.string, "native")) return error.NotNative;
            return json(out, "{\"client_id\":\"c1\"}");
        }
        if (std.mem.startsWith(u8, target, "/authorize?")) {
            const challenge = (try oauth.queryParam(arena, target, "code_challenge")).?;
            @memcpy(self.challenge[0..challenge.len], challenge);
            self.challenge_len = challenge.len;
            if (!std.mem.eql(u8, (try oauth.queryParam(arena, target, "resource")).?, try std.fmt.allocPrint(arena, "{s}/mcp", .{b}))) return error.WrongResource;
            const redirect = (try oauth.queryParam(arena, target, "redirect_uri")).?;
            const state = (try oauth.queryParam(arena, target, "state")).?;
            var location: std.ArrayList(u8) = .empty;
            try location.appendSlice(arena, redirect);
            try location.append(arena, '?');
            try oauth.appendFormPair(arena, &location, "code", "the-code");
            try oauth.appendFormPair(arena, &location, "state", state);
            try oauth.appendFormPair(arena, &location, "iss", b);
            return out.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{location.items});
        }
        if (std.mem.eql(u8, target, "/token")) {
            const form = try std.fmt.allocPrint(arena, "?{s}", .{body});
            const grant = (try oauth.queryParam(arena, form, "grant_type")).?;
            if ((try oauth.queryParam(arena, form, "resource")) == null) return error.MissingResource;
            if (std.mem.eql(u8, grant, "authorization_code")) {
                const verifier = (try oauth.queryParam(arena, form, "code_verifier")).?;
                if (!std.mem.eql(u8, try oauth.codeChallenge(arena, verifier), self.challenge[0..self.challenge_len])) return error.PkceMismatch;
                // Already expired by the client's margin, to force a refresh.
                return json(out, "{\"access_token\":\"tok1\",\"token_type\":\"Bearer\",\"expires_in\":1,\"refresh_token\":\"r1\"}");
            }
            if (!std.mem.eql(u8, (try oauth.queryParam(arena, form, "refresh_token")).?, "r1")) return error.WrongRefresh;
            self.token = "tok2";
            self.refreshed = true;
            return json(out, "{\"access_token\":\"tok2\",\"token_type\":\"Bearer\",\"expires_in\":3600}");
        }
        if (std.mem.eql(u8, target, "/mcp")) {
            const auth = headers.get("authorization") orelse "";
            const expected = try std.fmt.allocPrint(arena, "Bearer {s}", .{self.token});
            if (!std.mem.eql(u8, auth, expected)) {
                return out.print("HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer resource_metadata=\"{s}/.well-known/oauth-protected-resource/mcp\"\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{b});
            }
            if (!std.mem.eql(u8, headers.get("mcp-protocol-version") orelse "", mcp.current_protocol)) return error.MissingVersion;
            const rpc = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
            const id = rpc.object.get("id").?.integer;
            const rpc_method = rpc.object.get("method").?.string;
            if (!std.mem.eql(u8, headers.get("mcp-method") orelse "", rpc_method)) return error.MethodHeader;
            if (std.mem.eql(u8, rpc_method, "tools/list")) {
                return json(out, try std.fmt.allocPrint(arena,
                    \\{{"jsonrpc":"2.0","id":{d},"result":{{"tools":[{{"name":"echo","description":"Echo","inputSchema":{{"type":"object","properties":{{"text":{{"type":"string"}},"region":{{"type":"string","x-mcp-header":"Region"}}}}}}}}]}}}}
                , .{id}));
            }
            if (!std.mem.eql(u8, headers.get("mcp-name") orelse "", "echo")) return error.NameHeader;
            if (!std.mem.eql(u8, headers.get("mcp-param-region") orelse "", "eu")) return error.ParamHeader;
            // An SSE reply: a progress notification, the answer, then the
            // stream stays open. The client must stop at its answer.
            try out.print("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n", .{});
            try out.print("data: {{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{{\"progress\":1}}}}\n\n", .{});
            try out.print("event: message\ndata: {{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"echo ok\"}}]}}}}\n\n", .{id});
            try out.flush();
            _ = self.stream_held.fetchAdd(1, .release);
            while (!self.stop.load(.acquire)) {
                // Hold until the client has closed its side or the test ends.
                var probe: [1]u8 = undefined;
                const n = reader.interface.readSliceShort(&probe) catch break;
                if (n == 0) break;
            }
            return;
        }
        try out.print("HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n", .{});
    }

    fn json(out: *Io.Writer, body: []const u8) !void {
        try out.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ body.len, body });
    }

    fn shutdown(self: *Fake) void {
        self.stop.store(true, .release);
        const address = Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
        var stream = address.connect(self.io, .{ .mode = .stream }) catch return;
        var buf: [128]u8 = undefined;
        var w = Io.net.Stream.Writer.init(stream, self.io, &buf);
        w.interface.writeAll("GET /__stop HTTP/1.1\r\n\r\n") catch {};
        w.interface.flush() catch {};
        stream.close(self.io);
    }
};

const Recorder = struct {
    io: Io,
    url_ready: Io.Event = .unset,
    finished: Io.Event = .unset,

    fn notify(ctx: *anyopaque, _: *mcp_login.Job, event: mcp_login.Event) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        switch (event) {
            .url_ready => self.url_ready.set(self.io),
            .finished => self.finished.set(self.io),
        }
    }
};

test "remote MCP login, bearer discovery, SSE call, and refresh against a fake server" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const auth_path = try std.fs.path.join(arena, &.{ dir, "mcp-auth.json" });

    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var fake: Fake = .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }), .port = 0 };
    defer fake.listener.deinit(io);
    fake.port = fake.listener.socket.address.getPort();
    const thread = try std.Thread.spawn(.{}, Fake.serve, .{&fake});
    defer {
        fake.shutdown();
        thread.join();
    }
    var base_buf: [64]u8 = undefined;
    const server_url = try std.fmt.allocPrint(arena, "{s}/mcp", .{fake.base(&base_buf)});

    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const server = try mcp.Server.initHttp(gpa, io, "fake", server_url, &.{}, &environ, auth_path);
    defer server.deinit();
    server.http_timeout_ms = 10_000;

    // No token: the server challenges and points at its metadata.
    try std.testing.expectError(error.McpUnauthorized, server.discover());
    try std.testing.expect(std.mem.indexOf(u8, server.lastChallenge().?, "resource_metadata=") != null);

    var recorder: Recorder = .{ .io = io };
    const job = try mcp_login.start(gpa, io, &environ, 1, "fake", server_url, server.lastChallenge().?, auth_path, .{ .ctx = &recorder, .func = Recorder.notify });
    var job_alive = true;
    defer if (job_alive) {
        job.cancel();
        job.deinit();
    };
    try recorder.url_ready.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });

    // The "browser": follow the authorize redirect by hand, then paste it.
    var pool = try http.Pool.init(gpa, io, null);
    defer pool.deinit();
    const authorize = try http.exchange(&pool.client, gpa, .{ .url = job.authorization_url.?, .capture = &.{"Location"} });
    defer authorize.deinit(gpa);
    try std.testing.expectEqual(@as(i64, 302), authorize.status);
    try job.deliver(authorize.captured[0].?);
    try recorder.finished.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try std.testing.expect(job.ok);
    job_alive = false;
    job.deinit();
    try std.testing.expect(fake.failure == null);
    try std.testing.expectEqualStrings("tok1", oauth.load(arena, io, auth_path, "fake", server_url).?.access_token);

    // tok1 came back already expired, so discovery refreshes first.
    try server.discover();
    try std.testing.expect(fake.refreshed);
    try std.testing.expectEqualStrings("tok2", oauth.load(arena, io, auth_path, "fake", server_url).?.access_token);
    try std.testing.expectEqual(@as(usize, 1), server.tools.items.len);
    try std.testing.expectEqualStrings("mcp__fake__echo", server.tools.items[0].public_name);

    // The answer arrives on an SSE stream the server leaves open.
    const result = server.call("mcp__fake__echo", "{\"text\":\"hi\",\"region\":\"eu\"}", null);
    defer result.deinit(gpa);
    try std.testing.expectEqual(@import("../core/block.zig").ToolStatus.ok, result.status);
    try std.testing.expectEqualStrings("echo ok", result.output);
    try std.testing.expect(fake.failure == null);
}

test "pasted callbacks keep their path and query" {
    try std.testing.expectEqualStrings("/callback?code=a&state=b", try mcp_login.callbackTarget("http://127.0.0.1:5555/callback?code=a&state=b"));
    try std.testing.expectEqualStrings("/callback?code=a", try mcp_login.callbackTarget("  http://localhost:1/callback?code=a\n"));
    try std.testing.expectEqualStrings("/callback?code=a", try mcp_login.callbackTarget("/callback?code=a"));
    try std.testing.expectError(error.InvalidCallback, mcp_login.callbackTarget("code=a"));
}

test "header values outside visible ASCII travel base64-wrapped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("eu-west", try mcp.encodeHeaderValue(arena, "eu-west"));
    try std.testing.expectEqualStrings("=?base64?w6l0w6k=?=", try mcp.encodeHeaderValue(arena, "été"));
    try std.testing.expectEqualStrings("=?base64?IHBhZGRlZCA=?=", try mcp.encodeHeaderValue(arena, " padded "));
    // A literal that looks like the sentinel is wrapped so it reads back verbatim.
    try std.testing.expectEqualStrings("=?base64?PT9iYXNlNjQ/YWJjPz0=?=", try mcp.encodeHeaderValue(arena, "=?base64?abc?="));
}
