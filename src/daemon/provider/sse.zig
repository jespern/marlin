//! SSE (text/event-stream) parser, shared by all dialects.
//!
//! Incremental: feed() bytes as they arrive from the HTTP layer's write
//! callback; complete events are delivered to the sink callback. Tolerates:
//! CRLF and LF, comment lines (`:`), multi-line `data:`, events split across
//! arbitrary chunk boundaries (including mid-UTF-8), and BOM.
//!
//! Scope: we implement the subset LLM providers actually emit — `event:` and
//! `data:` fields. `id:`/`retry:` lines are ignored. Per the SSE spec, an
//! event is dispatched on a blank line; multiple `data:` lines join with \n.

const std = @import("std");

pub const Event = struct {
    /// Event name from `event:`; empty (= "message") for most providers.
    name: []const u8,
    /// Joined data payload. For OpenAI-style streams this is one JSON object
    /// or the literal "[DONE]".
    data: []const u8,
};

/// Incremental parser. Owns an internal buffer for partial lines/events.
/// Event slices passed to the sink are valid only during the callback.
pub const Parser = struct {
    gpa: std.mem.Allocator,
    /// Unconsumed input (partial line at the tail of the last chunk).
    pending: std.ArrayList(u8) = .empty,
    /// Accumulated `data:` lines for the in-progress event.
    data_buf: std.ArrayList(u8) = .empty,
    /// Accumulated `event:` name for the in-progress event.
    name_buf: std.ArrayList(u8) = .empty,
    /// Hard cap on buffered bytes; a malicious/broken server can't OOM us.
    max_event_bytes: usize = 8 * 1024 * 1024,

    pub fn init(gpa: std.mem.Allocator) Parser {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Parser) void {
        self.pending.deinit(self.gpa);
        self.data_buf.deinit(self.gpa);
        self.name_buf.deinit(self.gpa);
    }

    pub const FeedError = error{ OutOfMemory, EventTooLarge };

    /// Feed a chunk; invoke `sink(ctx, Event)` for each completed event.
    pub fn feed(
        self: *Parser,
        chunk: []const u8,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), Event) void,
    ) FeedError!void {
        if (self.pending.items.len + chunk.len > self.max_event_bytes)
            return error.EventTooLarge;
        try self.pending.appendSlice(self.gpa, chunk);

        // Consume complete lines; keep the partial tail.
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.pending.items, start, '\n')) |nl| {
            var line = self.pending.items[start..nl];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try self.handleLine(line, ctx, sink);
            start = nl + 1;
        }
        if (start > 0) {
            const rest = self.pending.items[start..];
            std.mem.copyForwards(u8, self.pending.items[0..rest.len], rest);
            self.pending.shrinkRetainingCapacity(rest.len);
        }
    }

    fn handleLine(
        self: *Parser,
        line_in: []const u8,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), Event) void,
    ) FeedError!void {
        var line = line_in;
        // Strip UTF-8 BOM on the very first line.
        if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line = line[3..];

        if (line.len == 0) {
            // Dispatch if any data accumulated (spec: empty data → no event).
            if (self.data_buf.items.len > 0) {
                sink(ctx, .{ .name = self.name_buf.items, .data = self.data_buf.items });
            }
            self.data_buf.clearRetainingCapacity();
            self.name_buf.clearRetainingCapacity();
            return;
        }
        if (line[0] == ':') return; // comment / keep-alive

        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |c| line[0..c] else line;
        var value = if (colon) |c| line[c + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "data")) {
            if (self.data_buf.items.len + value.len > self.max_event_bytes)
                return error.EventTooLarge;
            if (self.data_buf.items.len > 0) try self.data_buf.append(self.gpa, '\n');
            try self.data_buf.appendSlice(self.gpa, value);
        } else if (std.mem.eql(u8, field, "event")) {
            self.name_buf.clearRetainingCapacity();
            try self.name_buf.appendSlice(self.gpa, value);
        }
        // id:/retry:/unknown fields ignored.
    }
};

// ---------------------------------------------------------------- tests --

const TestSink = struct {
    events: std.ArrayList(struct { name: []u8, data: []u8 }) = .empty,
    gpa: std.mem.Allocator,

    fn deinit(self: *TestSink) void {
        for (self.events.items) |e| {
            self.gpa.free(e.name);
            self.gpa.free(e.data);
        }
        self.events.deinit(self.gpa);
    }

    fn on(self: *TestSink, ev: Event) void {
        const n = self.gpa.dupe(u8, ev.name) catch unreachable;
        const d = self.gpa.dupe(u8, ev.data) catch unreachable;
        self.events.append(self.gpa, .{ .name = n, .data = d }) catch unreachable;
    }
};

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
