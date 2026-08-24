//! OpenAI-compatible dialect: OpenRouter (default), OpenAI, DeepSeek, Groq,
//! local llama.cpp/vLLM — anything speaking /chat/completions.
//!
//! Request: messages + tools, stream:true, stream_options.include_usage.
//! Stream: SSE `data:` events, each a chat.completion.chunk JSON; tool-call
//! arguments arrive fragmented across chunks (indexed by tool_calls[].index)
//! and are reassembled here. Terminated by `data: [DONE]`.
//!
//! Relies on implicit prefix caching server-side; our append-only assembly
//! discipline maximizes hits automatically.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const Effort = @import("../../core/effort.zig").Effort;

// ------------------------------------------------------------- request --

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    /// Raw JSON schema string for parameters.
    schema_json: []const u8,
};

/// Build the request body JSON. Caller frees.
pub fn buildRequestBody(
    gpa: std.mem.Allocator,
    model: []const u8,
    dialect: provider.Dialect,
    effort: Effort,
    messages: []const provider.Message,
    tools: []const ToolSpec,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const ws = &aw.writer;
    const enc = std.json.Stringify.encodeJsonString;

    try ws.writeAll("{\"model\":");
    try enc(model, .{}, ws);
    if (effort.providerValue()) |value| {
        switch (dialect) {
            .openrouter => try ws.writeAll(",\"reasoning\":{\"effort\":"),
            .openai_compatible => try ws.writeAll(",\"reasoning_effort\":"),
        }
        try enc(value, .{}, ws);
        if (dialect == .openrouter) try ws.writeByte('}');
    }
    try ws.writeAll(",\"stream\":true,\"stream_options\":{\"include_usage\":true},\"messages\":[");
    for (messages, 0..) |m, i| {
        if (i > 0) try ws.writeByte(',');
        try ws.writeAll("{\"role\":\"");
        try ws.writeAll(switch (m.role) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        });
        try ws.writeAll("\"");
        switch (m.payload) {
            .text => |t| {
                try ws.writeAll(",\"content\":");
                try enc(t, .{}, ws);
            },
            .assistant_tool_calls => |calls| {
                // content may be present alongside tool_calls
                if (calls.text.len > 0) {
                    try ws.writeAll(",\"content\":");
                    try enc(calls.text, .{}, ws);
                } else {
                    try ws.writeAll(",\"content\":null");
                }
                try ws.writeAll(",\"tool_calls\":[");
                for (calls.calls, 0..) |tc, j| {
                    if (j > 0) try ws.writeByte(',');
                    try ws.writeAll("{\"id\":");
                    try enc(tc.call_id, .{}, ws);
                    try ws.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                    try enc(tc.name, .{}, ws);
                    try ws.writeAll(",\"arguments\":");
                    try enc(tc.args_json, .{}, ws);
                    try ws.writeAll("}}");
                }
                try ws.writeAll("]");
            },
            .tool_result => |tr| {
                try ws.writeAll(",\"tool_call_id\":");
                try enc(tr.call_id, .{}, ws);
                try ws.writeAll(",\"content\":");
                try enc(tr.text, .{}, ws);
            },
        }
        try ws.writeAll("}");
    }
    try ws.writeAll("]");
    if (tools.len > 0) {
        try ws.writeAll(",\"tools\":[");
        for (tools, 0..) |t, i| {
            if (i > 0) try ws.writeByte(',');
            try ws.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try enc(t.name, .{}, ws);
            try ws.writeAll(",\"description\":");
            try enc(t.description, .{}, ws);
            try ws.writeAll(",\"parameters\":");
            try ws.writeAll(t.schema_json); // already JSON
            try ws.writeAll("}}");
        }
        try ws.writeAll("]");
    }
    try ws.writeAll("}");
    return aw.toOwnedSlice();
}

// -------------------------------------------------------------- stream --

/// Accumulates one streamed response: text deltas forwarded immediately,
/// tool-call fragments reassembled, usage captured from the final chunk.
pub const StreamAccum = struct {
    gpa: std.mem.Allocator,
    /// Full assistant text (accumulated from deltas).
    text: std.ArrayList(u8) = .empty,
    /// Reasoning text if the provider emits it (OpenRouter: `reasoning`).
    reasoning: std.ArrayList(u8) = .empty,
    calls: std.ArrayList(PartialCall) = .empty,
    finish_reason: ?FinishReason = null,
    usage: ?provider.Usage = null,
    saw_done: bool = false,
    /// Set on JSON we couldn't parse (provider bug / mid-stream garbage).
    parse_errors: u32 = 0,

    /// Immediate delta sink for UI liveness; may be null in headless tests.
    on_delta: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    on_delta_ctx: ?*anyopaque = null,

    pub const FinishReason = enum { stop, tool_calls, length, content_filter, other };

    pub const PartialCall = struct {
        index: u32,
        call_id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        args: std.ArrayList(u8) = .empty,
    };

    pub fn init(gpa: std.mem.Allocator) StreamAccum {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *StreamAccum) void {
        self.text.deinit(self.gpa);
        self.reasoning.deinit(self.gpa);
        for (self.calls.items) |*pc| {
            pc.call_id.deinit(self.gpa);
            pc.name.deinit(self.gpa);
            pc.args.deinit(self.gpa);
        }
        self.calls.deinit(self.gpa);
    }

    /// SSE sink: feed each `data:` event payload here.
    pub fn onEvent(self: *StreamAccum, ev: sse.Event) void {
        if (std.mem.eql(u8, ev.data, "[DONE]")) {
            self.saw_done = true;
            return;
        }
        self.handleChunk(ev.data) catch {
            self.parse_errors += 1;
        };
    }

    fn handleChunk(self: *StreamAccum, data: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
        const root = switch (parsed) {
            .object => |o| o,
            else => return error.BadChunk,
        };

        // usage: on the final chunk (or OpenRouter's usage-only tail chunk)
        if (root.get("usage")) |u| if (u == .object) {
            const tin = intField(u.object, "prompt_tokens") orelse 0;
            const tout = intField(u.object, "completion_tokens") orelse 0;
            if (tin != 0 or tout != 0)
                self.usage = .{ .tokens_in = tin, .tokens_out = tout };
        };

        const choices = root.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice0 = choices.array.items[0];
        if (choice0 != .object) return;

        if (choice0.object.get("finish_reason")) |fr| if (fr == .string) {
            self.finish_reason = parseFinish(fr.string);
        };

        const delta = choice0.object.get("delta") orelse return;
        if (delta != .object) return;

        if (delta.object.get("content")) |ct| if (ct == .string and ct.string.len > 0) {
            try self.text.appendSlice(self.gpa, ct.string);
            if (self.on_delta) |cb| cb(self.on_delta_ctx, ct.string);
        };
        if (delta.object.get("reasoning")) |rs| if (rs == .string and rs.string.len > 0) {
            try self.reasoning.appendSlice(self.gpa, rs.string);
        };

        if (delta.object.get("tool_calls")) |tcs| if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                const idx: u32 = @intCast(intField(tc.object, "index") orelse 0);
                const pc = try self.callAt(idx);
                if (tc.object.get("id")) |id| if (id == .string)
                    try pc.call_id.appendSlice(self.gpa, id.string);
                if (tc.object.get("function")) |f| if (f == .object) {
                    if (f.object.get("name")) |n| if (n == .string)
                        try pc.name.appendSlice(self.gpa, n.string);
                    if (f.object.get("arguments")) |a| if (a == .string)
                        try pc.args.appendSlice(self.gpa, a.string);
                };
            }
        };
    }

    fn callAt(self: *StreamAccum, index: u32) !*PartialCall {
        for (self.calls.items) |*pc| {
            if (pc.index == index) return pc;
        }
        try self.calls.append(self.gpa, .{ .index = index });
        return &self.calls.items[self.calls.items.len - 1];
    }

    fn parseFinish(s: []const u8) FinishReason {
        if (std.mem.eql(u8, s, "stop")) return .stop;
        if (std.mem.eql(u8, s, "tool_calls")) return .tool_calls;
        if (std.mem.eql(u8, s, "length")) return .length;
        if (std.mem.eql(u8, s, "content_filter")) return .content_filter;
        return .other;
    }

    fn intField(o: std.json.ObjectMap, key: []const u8) ?u64 {
        const v = o.get(key) orelse return null;
        return switch (v) {
            .integer => |i| if (i >= 0) @intCast(i) else null,
            else => null,
        };
    }
};

// ---------------------------------------------------------------- tests --

fn feedEvents(acc: *StreamAccum, events: []const []const u8) void {
    for (events) |e| acc.onEvent(.{ .name = "", .data = e });
}

test "text deltas accumulate; usage and finish captured" {
    var acc = StreamAccum.init(std.testing.allocator);
    defer acc.deinit();
    feedEvents(&acc, &.{
        \\{"choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{"content":"lo"}}]}
        ,
        \\{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2}}
        ,
        "[DONE]",
    });
    try std.testing.expectEqualStrings("Hello", acc.text.items);
    try std.testing.expectEqual(StreamAccum.FinishReason.stop, acc.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 10), acc.usage.?.tokens_in);
    try std.testing.expect(acc.saw_done);
    try std.testing.expectEqual(@as(u32, 0), acc.parse_errors);
}

test "tool call fragments reassemble across chunks (two calls interleaved)" {
    var acc = StreamAccum.init(std.testing.allocator);
    defer acc.deinit();
    feedEvents(&acc, &.{
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"bash","arguments":""}}]}}]}
        ,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"cmd\":"}}]}}]}
        ,
        \\{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"read_file","arguments":"{\"path\":\"x\"}"}}]}}]}
        ,
        \\{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"ls\"}"}}]}}]}
        ,
        \\{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}
        ,
        "[DONE]",
    });
    try std.testing.expectEqual(@as(usize, 2), acc.calls.items.len);
    try std.testing.expectEqualStrings("call_a", acc.calls.items[0].call_id.items);
    try std.testing.expectEqualStrings("bash", acc.calls.items[0].name.items);
    try std.testing.expectEqualStrings("{\"cmd\":\"ls\"}", acc.calls.items[0].args.items);
    try std.testing.expectEqualStrings("read_file", acc.calls.items[1].name.items);
    try std.testing.expectEqual(StreamAccum.FinishReason.tool_calls, acc.finish_reason.?);
}

test "garbage chunk counts a parse error but doesn't kill the stream" {
    var acc = StreamAccum.init(std.testing.allocator);
    defer acc.deinit();
    feedEvents(&acc, &.{
        "not json at all",
        \\{"choices":[{"delta":{"content":"ok"}}]}
    });
    try std.testing.expectEqual(@as(u32, 1), acc.parse_errors);
    try std.testing.expectEqualStrings("ok", acc.text.items);
}

test "request body builds valid json" {
    const gpa = std.testing.allocator;
    const msgs = [_]provider.Message{
        .{ .role = .system, .payload = .{ .text = "You are marlin." } },
        .{ .role = .user, .payload = .{ .text = "hi \"there\"\nnewline" } },
    };
    const tools = [_]ToolSpec{
        .{ .name = "bash", .description = "run a command", .schema_json = "{\"type\":\"object\"}" },
    };
    const body = try buildRequestBody(gpa, "openai/gpt-4o", .openrouter, .high, &msgs, &tools);
    defer gpa.free(body);
    // Must be valid JSON with the right top-level fields.
    const ok = std.json.validate(gpa, body) catch false;
    try std.testing.expect(ok);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\"}") != null);

    const auto_body = try buildRequestBody(gpa, "local/model", .openai_compatible, .auto, &msgs, &.{});
    defer gpa.free(auto_body);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "reasoning_effort") == null);

    const local_body = try buildRequestBody(gpa, "local/model", .openai_compatible, .low, &msgs, &.{});
    defer gpa.free(local_body);
    try std.testing.expect(std.mem.indexOf(u8, local_body, "\"reasoning_effort\":\"low\"") != null);
}
