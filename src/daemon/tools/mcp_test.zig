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
