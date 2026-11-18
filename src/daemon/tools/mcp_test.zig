//! Unit tests for mcp.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in mcp.zig.

const std = @import("std");
const build_options = @import("build_options");
const Io = std.Io;
const block = @import("../../core/block.zig");
const registry = @import("registry.zig");

const mcp = @import("mcp.zig");
const ProtocolMode = mcp.ProtocolMode;
const Server = mcp.Server;
const publicToolName = mcp.publicToolName;

test {
    std.testing.refAllDecls(mcp);
}

const CancelMcpCall = struct {
    io: Io,
    flag: *std.atomic.Value(bool),

    fn run(self: CancelMcpCall) void {
        self.io.sleep(.fromMilliseconds(100), .awake) catch return;
        self.flag.store(true, .release);
    }
};

test "public MCP names are provider-safe and namespaced" {
    const gpa = std.testing.allocator;
    const name = try publicToolName(gpa, "playwright.dev", "page/click");
    defer gpa.free(name);
    try std.testing.expectEqualStrings("mcp__playwright_dev__page_click", name);

    const long = try publicToolName(gpa, "a-very-long-server-name-that-keeps-going", "a-very-long-tool-name-that-also-keeps-going");
    defer gpa.free(long);
    try std.testing.expectEqual(@as(usize, 64), long.len);
}

test "modern stdio server discovery and tool call" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"echo","description":"Echo input","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}}]}}' ;;
        \\    *'"method":"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"text","text":"from mcp"}]}}' ;;
        \\  esac
        \\done
    ;
    const server = try Server.init(gpa, threaded.io(), "demo", &.{ "sh", "-c", script }, null);
    defer server.deinit();
    try server.discover();
    try std.testing.expectEqual(@as(usize, 1), server.tools.items.len);
    try std.testing.expectEqualStrings("mcp__demo__echo", server.tools.items[0].public_name);
    try std.testing.expectEqual(true, server.tools.items[0].read_only_hint.?);
    const result = server.call("mcp__demo__echo", "{\"value\":1}", null);
    defer result.deinit(gpa);
    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expectEqualStrings("from mcp", result.output);
}

test "stdio discovery falls back to the legacy initialize lifecycle" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const script =
        \\ready=0
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) ready=1; printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"legacy","version":"1"}}}' ;;
        \\    *'"method":"notifications/initialized"'*) ;;
        \\    *'"method":"tools/list"'*) if [ "$ready" = 1 ]; then printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}'; else printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"not initialized"}}'; fi ;;
        \\  esac
        \\done
    ;
    const server = try Server.init(gpa, threaded.io(), "legacy", &.{ "sh", "-c", script }, null);
    defer server.deinit();
    try server.discover();
    try std.testing.expectEqual(ProtocolMode.legacy, server.mode);
    try std.testing.expectEqual(@as(usize, 0), server.tools.items.len);
}

test "MCP deadline is absolute across unrelated stdout messages" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"chatty","inputSchema":{"type":"object"}}]}}' ;;
        \\    *'"method":"tools/call"'*) while :; do printf '%s\n' '{"jsonrpc":"2.0","id":999,"result":{}}'; done ;;
        \\  esac
        \\done
    ;
    const server = try Server.init(gpa, threaded.io(), "chatty", &.{ "sh", "-c", script }, null);
    defer server.deinit();
    server.timeout_ms = 150;
    try server.discover();

    const result = server.call("mcp__chatty__chatty", "{}", null);
    defer result.deinit(gpa);
    try std.testing.expectEqual(block.ToolStatus.err, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Timeout") != null);
}

test "MCP deadline covers a server that stops consuming stdin" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const script =
        \\IFS= read -r line
        \\printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"blocked","inputSchema":{"type":"object"}}]}}'
        \\while :; do :; done
    ;
    const server = try Server.init(gpa, threaded.io(), "blocked", &.{ "sh", "-c", script }, null);
    defer server.deinit();
    server.timeout_ms = 150;
    try server.discover();

    const payload = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(payload);
    @memset(payload, 'x');
    const args_json = try std.fmt.allocPrint(gpa, "{{\"payload\":\"{s}\"}}", .{payload});
    defer gpa.free(args_json);
    const result = server.call("mcp__blocked__blocked", args_json, null);
    defer result.deinit(gpa);
    try std.testing.expectEqual(block.ToolStatus.err, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Timeout") != null);
}

test "MCP image results retain decoded provider-compatible media" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"shot","inputSchema":{"type":"object"}}]}}' ;;
        \\    *'"method":"tools/call"'*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete","content":[{"type":"image","mimeType":"image/gif","data":"R0lGODlhTUFSTElO"}]}}' ;;
        \\  esac
        \\done
    ;
    const server = try Server.init(gpa, threaded.io(), "vision", &.{ "sh", "-c", script }, null);
    defer server.deinit();
    try server.discover();

    const result = server.call("mcp__vision__shot", "{}", null);
    defer result.deinit(gpa);
    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expectEqual(@as(usize, 1), result.media.len);
    try std.testing.expectEqualStrings("image/gif", result.media[0].mime);
    try std.testing.expectEqualStrings("GIF89aMARLIN", result.media[0].bytes);
}

test "turn cancellation kills an active MCP call" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"wait","inputSchema":{"type":"object"}}]}}' ;;
        \\    *'"method":"tools/call"'*) while :; do :; done ;;
        \\  esac
        \\done
    ;
    const server = try Server.init(gpa, threaded.io(), "cancel", &.{ "sh", "-c", script }, null);
    defer server.deinit();
    try server.discover();

    var cancel: std.atomic.Value(bool) = .init(false);
    const cancel_thread = try std.Thread.spawn(.{}, CancelMcpCall.run, .{CancelMcpCall{
        .io = threaded.io(),
        .flag = &cancel,
    }});
    defer cancel_thread.join();
    const result = server.call("mcp__cancel__wait", "{}", &cancel);
    defer result.deinit(gpa);
    try std.testing.expectEqual(block.ToolStatus.interrupted, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interrupted") != null);
}

/// Counts tools-changed notices and wakes a waiting test.
const Changes = struct {
    io: Io,
    count: std.atomic.Value(u32) = .init(0),
    seen: Io.Event = .unset,

    fn hook(self: *Changes) mcp.ChangeHook {
        return .{ .ctx = self, .func = changed };
    }
    fn changed(ctx: *anyopaque, server: []const u8) void {
        const self: *Changes = @ptrCast(@alignCast(ctx));
        std.debug.assert(server.len > 0);
        _ = self.count.fetchAdd(1, .acq_rel);
        self.seen.set(self.io);
    }
    fn wait(self: *Changes) !void {
        try self.seen.waitTimeout(self.io, .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } });
        self.seen.reset();
    }
};

/// A 2026-07-28 stdio server whose `add` tool adds a second tool and says
/// so, after answering: on its subscription, between calls.
pub const changing_server =
    \\id() { printf '%s' "$1" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p'; }
    \\n=1
    \\while IFS= read -r line; do
    \\  i=$(id "$line")
    \\  case "$line" in
    \\    *'"method":"tools/list"'*)
    \\      tools='{"name":"add","inputSchema":{"type":"object"}}'
    \\      [ "$n" -ge 2 ] && tools="$tools"',{"name":"added","inputSchema":{"type":"object"}}'
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[%s]}}\n' "$i" "$tools" ;;
    \\    *'"method":"subscriptions/listen"'*)
    \\      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"marlin-tools-changed"},"notifications":{"toolsListChanged":true}}}' ;;
    \\    *'"method":"tools/call"'*)
    \\      n=2
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","content":[{"type":"text","text":"added"}]}}\n' "$i"
    \\      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":"marlin-tools-changed"}}}' ;;
    \\  esac
    \\done
;

// Case: Jesper asked whether Marlin follows MCP subscriptions; it read a
// server's tools once, at discovery, and never noticed them change.
test "a stdio server's tools change is heard between calls and re-listed" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const server = try Server.init(gpa, threaded.io(), "grow", &.{ "sh", "-c", changing_server }, null);
    defer server.deinit();
    try server.discover();
    try std.testing.expectEqual(@as(usize, 1), server.tools.items.len);

    var changes: Changes = .{ .io = threaded.io() };
    server.watch(changes.hook());
    const result = server.call("mcp__grow__add", "{}", null);
    defer result.deinit(gpa);
    try std.testing.expectEqualStrings("added", result.output);
    // The notice comes after the answer, with no request in flight.
    try changes.wait();
    try server.relist();
    try std.testing.expectEqual(@as(usize, 2), server.tools.items.len);
    try std.testing.expectEqualStrings("mcp__grow__added", server.tools.items[1].public_name);
    // The process was kept: the server remembers the change.
    try server.relist();
    try std.testing.expectEqual(@as(usize, 2), server.tools.items.len);
}

test "an older stdio server's unasked notice reaches a hook set later" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const script =
        \\ready=0
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"initialize"'*) ready=1; printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{"listChanged":true}},"serverInfo":{"name":"legacy","version":"1"}}}' ;;
        \\    *'"method":"tools/list"'*) if [ "$ready" = 1 ]; then printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"tools":[]}}' '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'; else printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"not initialized"}}'; fi ;;
        \\  esac
        \\done
    ;
    const server = try Server.init(gpa, threaded.io(), "legacy", &.{ "sh", "-c", script }, null);
    defer server.deinit();
    try server.discover();
    try std.testing.expectEqual(ProtocolMode.legacy, server.mode);
    try std.testing.expect(server.legacy_list_changed);
    // It came before anyone watched: kept, and delivered on watching.
    var changes: Changes = .{ .io = threaded.io() };
    for (0..200) |_| {
        server.hook_mutex.lockUncancelable(threaded.io());
        const missed = server.hook_missed;
        server.hook_mutex.unlock(threaded.io());
        if (missed) break;
        try threaded.io().sleep(.fromMilliseconds(10), .awake);
    }
    server.watch(changes.hook());
    try changes.wait();
}

test "stopping a stdio server does not wait on a child holding its stdout" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // `sleep` inherits stdout, as an npx launcher's real server does: the
    // pipe stays open until the whole group is gone.
    const script =
        \\sleep 30 &
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[]}}' ;;
        \\  esac
        \\done
    ;
    const server = try Server.init(gpa, io, "launcher", &.{ "sh", "-c", script }, null);
    try server.discover();
    const began = Io.Clock.awake.now(io);
    server.deinit();
    try std.testing.expect(began.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 5_000);
}

/// A 2026-07-28 HTTP server that streams one tools change on each
/// subscription, then holds the stream until the client lets go.
const HttpFake = struct {
    io: Io,
    listener: Io.net.Server,
    port: u16 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    listens: std.atomic.Value(u32) = .init(0),
    threads: std.ArrayList(std.Thread) = .empty,
    mutex: Io.Mutex = .init,

    fn serve(self: *HttpFake) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch return;
            if (self.stop.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            const thread = std.Thread.spawn(.{}, handle, .{ self, stream }) catch {
                stream.close(self.io);
                continue;
            };
            self.mutex.lockUncancelable(self.io);
            self.threads.append(std.testing.allocator, thread) catch thread.detach();
            self.mutex.unlock(self.io);
        }
    }

    fn handle(self: *HttpFake, stream: Io.net.Stream) void {
        defer stream.close(self.io);
        self.respond(stream) catch {};
    }

    fn respond(self: *HttpFake, stream: Io.net.Stream) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var read_buf: [16 * 1024]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, self.io, &read_buf);
        _ = try reader.interface.takeDelimiterInclusive('\n');
        var length: usize = 0;
        while (true) {
            const h = std.mem.trim(u8, try reader.interface.takeDelimiterInclusive('\n'), " \r\n");
            if (h.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(h, "content-length:")) length = try std.fmt.parseInt(usize, std.mem.trim(u8, h["content-length:".len..], " "), 10);
        }
        const body = try reader.interface.readAllocAll(arena, length);
        var write_buf: [4096]u8 = undefined;
        var w = Io.net.Stream.Writer.init(stream, self.io, &write_buf);
        const out = &w.interface;
        if (body.len == 0) return; // the stop poke
        const rpc = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        const method = rpc.object.get("method").?.string;
        if (std.mem.eql(u8, method, "subscriptions/listen")) {
            _ = self.listens.fetchAdd(1, .release);
            try out.writeAll("HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n");
            try out.writeAll("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"marlin-tools-changed\"},\"notifications\":{\"toolsListChanged\":true}}}\n\n");
            try out.writeAll("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"marlin-tools-changed\"}}}\n\n");
            try out.flush();
            while (!self.stop.load(.acquire)) {
                var probe: [1]u8 = undefined;
                const n = reader.interface.readSliceShort(&probe) catch break;
                if (n == 0) break;
            }
            return;
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            const reply = try std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"resultType\":\"complete\",\"tools\":[{{\"name\":\"ping\",\"inputSchema\":{{\"type\":\"object\"}}}}]}}}}", .{rpc.object.get("id").?.integer});
            try out.print("HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n{s}", .{ reply.len, reply });
            try out.flush();
            return;
        }
        try out.writeAll("HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n");
        try out.flush();
    }

    fn shutdown(self: *HttpFake, accept_thread: std.Thread) void {
        self.stop.store(true, .release);
        if (Io.net.IpAddress.parse("127.0.0.1", self.port)) |address| {
            if (address.connect(self.io, .{ .mode = .stream })) |stream| {
                var buf: [64]u8 = undefined;
                var w = Io.net.Stream.Writer.init(stream, self.io, &buf);
                w.interface.writeAll("POST / HTTP/1.1\r\ncontent-length: 0\r\n\r\n") catch {};
                w.interface.flush() catch {};
                stream.close(self.io);
            } else |_| {}
        } else |_| {}
        accept_thread.join();
        for (self.threads.items) |thread| thread.join();
        self.threads.deinit(std.testing.allocator);
    }
};

test "an HTTP server's tools changes arrive on a held subscriptions/listen stream" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var fake: HttpFake = .{ .io = io, .listener = try address.listen(io, .{ .reuse_address = true }) };
    defer fake.listener.deinit(io);
    fake.port = fake.listener.socket.address.getPort();
    const accept_thread = try std.Thread.spawn(.{}, HttpFake.serve, .{&fake});
    defer fake.shutdown(accept_thread);

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/mcp", .{fake.port});
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    const server = try Server.initHttp(gpa, io, "remote", url, &.{}, &environ, null);
    var changes: Changes = .{ .io = io };
    server.watch(changes.hook());
    try server.discover();
    try changes.wait();
    try std.testing.expectEqual(@as(u32, 1), fake.listens.load(.acquire));
    try server.relist();
    try std.testing.expectEqual(@as(usize, 1), server.tools.items.len);
    // Letting go cuts the held stream rather than waiting on it.
    const began = Io.Clock.awake.now(io);
    server.deinit();
    try std.testing.expect(began.durationTo(Io.Clock.awake.now(io)).toMilliseconds() < 5_000);
}
