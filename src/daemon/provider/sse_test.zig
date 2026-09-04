//! Unit tests for sse.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in sse.zig.

const std = @import("std");

const sse = @import("sse.zig");
const Parser = sse.Parser;
const TestSink = sse.TestSink;

test {
    std.testing.refAllDecls(sse);
}

fn feedAll(p: *Parser, s: *TestSink, input: []const u8, chunk_size: usize) !void {
    var i: usize = 0;
    while (i < input.len) {
        const end = @min(i + chunk_size, input.len);
        try p.feed(input[i..end], s, TestSink.on);
        i = end;
    }
}

test "basic event dispatch, LF" {
    const gpa = std.testing.allocator;
    var p = Parser.init(gpa);
    defer p.deinit();
    var s = TestSink{ .gpa = gpa };
    defer s.deinit();

    try p.feed("data: {\"x\":1}\n\ndata: [DONE]\n\n", &s, TestSink.on);
    try std.testing.expectEqual(@as(usize, 2), s.events.items.len);
    try std.testing.expectEqualStrings("{\"x\":1}", s.events.items[0].data);
    try std.testing.expectEqualStrings("[DONE]", s.events.items[1].data);
}

test "CRLF, comments, event names, multi-line data" {
    const gpa = std.testing.allocator;
    var p = Parser.init(gpa);
    defer p.deinit();
    var s = TestSink{ .gpa = gpa };
    defer s.deinit();

    const input = ": keep-alive\r\n" ++
        "event: content_block_delta\r\n" ++
        "data: line1\r\n" ++
        "data: line2\r\n" ++
        "\r\n";
    try p.feed(input, &s, TestSink.on);
    try std.testing.expectEqual(@as(usize, 1), s.events.items.len);
    try std.testing.expectEqualStrings("content_block_delta", s.events.items[0].name);
    try std.testing.expectEqualStrings("line1\nline2", s.events.items[0].data);
}

test "torture: 1-byte chunks across everything" {
    const gpa = std.testing.allocator;
    var p = Parser.init(gpa);
    defer p.deinit();
    var s = TestSink{ .gpa = gpa };
    defer s.deinit();

    const input = "event: e1\ndata: {\"a\":\"é\"}\n\ndata: two\n\n";
    try feedAll(&p, &s, input, 1);
    try std.testing.expectEqual(@as(usize, 2), s.events.items.len);
    try std.testing.expectEqualStrings("{\"a\":\"é\"}", s.events.items[0].data);
    try std.testing.expectEqualStrings("e1", s.events.items[0].name);
    try std.testing.expectEqualStrings("two", s.events.items[1].data);
    try std.testing.expectEqualStrings("", s.events.items[1].name);
}

test "no trailing blank line → no dispatch (partial event held)" {
    const gpa = std.testing.allocator;
    var p = Parser.init(gpa);
    defer p.deinit();
    var s = TestSink{ .gpa = gpa };
    defer s.deinit();

    try p.feed("data: partial", &s, TestSink.on);
    try std.testing.expectEqual(@as(usize, 0), s.events.items.len);
    try p.feed("\n\n", &s, TestSink.on);
    try std.testing.expectEqual(@as(usize, 1), s.events.items.len);
    try std.testing.expectEqualStrings("partial", s.events.items[0].data);
}

test "oversized event rejected" {
    const gpa = std.testing.allocator;
    var p = Parser.init(gpa);
    defer p.deinit();
    p.max_event_bytes = 16;
    var s = TestSink{ .gpa = gpa };
    defer s.deinit();

    const r = p.feed("data: aaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n\n", &s, TestSink.on);
    try std.testing.expectError(error.EventTooLarge, r);
}
