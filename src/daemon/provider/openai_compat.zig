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

pub const RequestOptions = struct {
    /// OpenRouter sticky-routing/observability key. Omitted for generic
    /// OpenAI-compatible endpoints so strict local servers remain compatible.
    session_id: ?[]const u8 = null,
    /// "throughput", "latency", "price", or null for router default.
    provider_sort: ?[]const u8 = null,
    /// Emit explicit per-content cache breakpoints for model families that
    /// require them (Claude/Gemini/Qwen through OpenRouter).
    explicit_cache: bool = false,
};

/// Build the request body JSON. Caller frees.
pub fn buildRequestBody(
    gpa: std.mem.Allocator,
    model: []const u8,
    dialect: provider.Dialect,
    effort: Effort,
    messages: []const provider.Message,
    tools: []const ToolSpec,
    opts: RequestOptions,
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
    if (dialect == .openrouter) {
        if (opts.session_id) |session_id| {
            try ws.writeAll(",\"session_id\":");
            try enc(session_id, .{}, ws);
        }
        if (opts.provider_sort) |sort| {
            try ws.writeAll(",\"provider\":{\"sort\":");
            try enc(sort, .{}, ws);
            try ws.writeByte('}');
        }
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
                if (dialect == .openrouter and opts.explicit_cache and m.cache_breakpoint) {
                    try ws.writeAll("[{\"type\":\"text\",\"text\":");
                    try enc(t, .{}, ws);
                    try ws.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}]");
                } else {
                    try enc(t, .{}, ws);
                }
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
                // OpenRouter's ChatToolMessage accepts the same text content
                // items as user/system messages, so the final result in a
                // completed batch can advance Claude/Qwen/Gemini's explicit
                // cache prefix rather than only caching the initial system
                // prompt.
                if (dialect == .openrouter and opts.explicit_cache and m.cache_breakpoint) {
                    try ws.writeAll("[{\"type\":\"text\",\"text\":");
                    try enc(tr.text, .{}, ws);
                    try ws.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}}]");
                } else {
                    try enc(tr.text, .{}, ws);
                }
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
        if (dialect == .openrouter) try ws.writeAll(",\"parallel_tool_calls\":true");
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
    /// OpenRouter identifiers make a request directly inspectable through its
    /// Activity/generation observability surfaces; kept only for live logs.
    generation_id: std.ArrayList(u8) = .empty,
    provider_name: std.ArrayList(u8) = .empty,
    finish_reason: ?FinishReason = null,
    usage: ?provider.Usage = null,
    saw_done: bool = false,
    /// Set on JSON we couldn't parse (provider bug / mid-stream garbage).
    parse_errors: u32 = 0,
    /// Sticky: the response crossed a memory/protocol safety ceiling. The
    /// HTTP consumer observes this and closes the stream immediately.
    response_too_large: bool = false,
    tool_bytes: usize = 0,

    /// Immediate delta sink for UI liveness; may be null in headless tests.
    on_delta: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    on_reasoning_delta: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    on_delta_ctx: ?*anyopaque = null,
    text_forwarded: usize = 0,
    reasoning_forwarded: usize = 0,

    const forward_batch_bytes: usize = 48;
    /// JSON string escaping can expand one decoded byte to six wire bytes.
    /// Four MiB therefore remains replayable inside the 32 MiB record limit.
    pub const max_field_bytes: usize = 4 * 1024 * 1024;
    const max_metadata_bytes: usize = 4 * 1024;
    const max_tool_calls: usize = 128;

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
        self.generation_id.deinit(self.gpa);
        self.provider_name.deinit(self.gpa);
        for (self.calls.items) |*pc| {
            pc.call_id.deinit(self.gpa);
            pc.name.deinit(self.gpa);
            pc.args.deinit(self.gpa);
        }
        self.calls.deinit(self.gpa);
    }

    /// SSE sink: feed each `data:` event payload here.
    pub fn onEvent(self: *StreamAccum, ev: sse.Event) void {
        if (self.response_too_large) return;
        if (std.mem.eql(u8, ev.data, "[DONE]")) {
            self.saw_done = true;
            return;
        }
        self.handleChunk(ev.data) catch |err| {
            if (err == error.ResponseTooLarge)
                self.response_too_large = true
            else
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

        if (self.generation_id.items.len == 0) {
            if (root.get("id")) |id| if (id == .string)
                try appendBounded(self.gpa, &self.generation_id, id.string, max_metadata_bytes);
        }
        if (self.provider_name.items.len == 0) {
            if (root.get("provider")) |name| if (name == .string)
                try appendBounded(self.gpa, &self.provider_name, name.string, max_metadata_bytes);
        }

        // usage: on the final chunk (or OpenRouter's usage-only tail chunk)
        if (root.get("usage")) |u| if (u == .object) {
            const tin = intField(u.object, "prompt_tokens") orelse 0;
            const tout = intField(u.object, "completion_tokens") orelse 0;
            const cached = nestedIntField(u.object, "prompt_tokens_details", "cached_tokens") orelse 0;
            const cache_write = nestedIntField(u.object, "prompt_tokens_details", "cache_write_tokens") orelse 0;
            const reasoning_tokens = nestedIntField(u.object, "completion_tokens_details", "reasoning_tokens") orelse 0;
            if (tin != 0 or tout != 0)
                self.usage = .{
                    .tokens_in = tin,
                    .tokens_out = tout,
                    .cached_tokens = cached,
                    .cache_write_tokens = cache_write,
                    .reasoning_tokens = reasoning_tokens,
                };
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
            try appendBounded(self.gpa, &self.text, ct.string, max_field_bytes);
            self.maybeForwardText();
        };
        if (delta.object.get("reasoning")) |rs| if (rs == .string and rs.string.len > 0) {
            try appendBounded(self.gpa, &self.reasoning, rs.string, max_field_bytes);
            self.maybeForwardReasoning();
        };

        if (delta.object.get("tool_calls")) |tcs| if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                const idx: u32 = @intCast(intField(tc.object, "index") orelse 0);
                const pc = try self.callAt(idx);
                if (tc.object.get("id")) |id| if (id == .string)
                    try self.appendToolFragment(&pc.call_id, id.string);
                if (tc.object.get("function")) |f| if (f == .object) {
                    if (f.object.get("name")) |n| if (n == .string)
                        try self.appendToolFragment(&pc.name, n.string);
                    if (f.object.get("arguments")) |a| if (a == .string)
                        try self.appendToolFragment(&pc.args, a.string);
                };
            }
        };
    }

    fn callAt(self: *StreamAccum, index: u32) !*PartialCall {
        for (self.calls.items) |*pc| {
            if (pc.index == index) return pc;
        }
        if (self.calls.items.len >= max_tool_calls) return error.ResponseTooLarge;
        try self.calls.append(self.gpa, .{ .index = index });
        return &self.calls.items[self.calls.items.len - 1];
    }

    fn appendToolFragment(self: *StreamAccum, list: *std.ArrayList(u8), bytes: []const u8) !void {
        if (bytes.len > max_field_bytes -| self.tool_bytes) return error.ResponseTooLarge;
        try list.appendSlice(self.gpa, bytes);
        self.tool_bytes += bytes.len;
    }

    /// Providers often stream one token per SSE event. Coalescing a small
    /// batch prevents a complete TUI layout/render for every token while
    /// preserving line-level liveness. The loop calls flushDeltas at EOF.
    fn maybeForwardText(self: *StreamAccum) void {
        const pending = self.text.items[self.text_forwarded..];
        if (pending.len < forward_batch_bytes and std.mem.indexOfScalar(u8, pending, '\n') == null) return;
        if (self.on_delta) |cb| cb(self.on_delta_ctx, pending);
        self.text_forwarded = self.text.items.len;
    }

    fn maybeForwardReasoning(self: *StreamAccum) void {
        const pending = self.reasoning.items[self.reasoning_forwarded..];
        if (pending.len < forward_batch_bytes and std.mem.indexOfScalar(u8, pending, '\n') == null) return;
        if (self.on_reasoning_delta) |cb| cb(self.on_delta_ctx, pending);
        self.reasoning_forwarded = self.reasoning.items.len;
    }

    pub fn flushDeltas(self: *StreamAccum) void {
        const text_pending = self.text.items[self.text_forwarded..];
        if (text_pending.len > 0) {
            if (self.on_delta) |cb| cb(self.on_delta_ctx, text_pending);
            self.text_forwarded = self.text.items.len;
        }
        const reasoning_pending = self.reasoning.items[self.reasoning_forwarded..];
        if (reasoning_pending.len > 0) {
            if (self.on_reasoning_delta) |cb| cb(self.on_delta_ctx, reasoning_pending);
            self.reasoning_forwarded = self.reasoning.items.len;
        }
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

    fn nestedIntField(o: std.json.ObjectMap, object_key: []const u8, key: []const u8) ?u64 {
        const nested = o.get(object_key) orelse return null;
        if (nested != .object) return null;
        return intField(nested.object, key);
    }
};

fn appendBounded(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    bytes: []const u8,
    limit: usize,
) !void {
    if (bytes.len > limit -| list.items.len) return error.ResponseTooLarge;
    try list.appendSlice(gpa, bytes);
}

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
        \\{"id":"gen-test","provider":"OpenAI","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":8,"cache_write_tokens":1},"completion_tokens_details":{"reasoning_tokens":3}}}
        ,
        "[DONE]",
    });
    try std.testing.expectEqualStrings("Hello", acc.text.items);
    try std.testing.expectEqual(StreamAccum.FinishReason.stop, acc.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 10), acc.usage.?.tokens_in);
    try std.testing.expectEqual(@as(u64, 8), acc.usage.?.cached_tokens);
    try std.testing.expectEqual(@as(u64, 1), acc.usage.?.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 3), acc.usage.?.reasoning_tokens);
    try std.testing.expectEqualStrings("gen-test", acc.generation_id.items);
    try std.testing.expectEqualStrings("OpenAI", acc.provider_name.items);
    try std.testing.expect(acc.saw_done);
    try std.testing.expectEqual(@as(u32, 0), acc.parse_errors);
}

test "stream accumulators reject growth past the replay-safe ceiling" {
    const gpa = std.testing.allocator;
    var acc = StreamAccum.init(gpa);
    defer acc.deinit();

    const oversized = try gpa.alloc(u8, StreamAccum.max_field_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.ResponseTooLarge,
        appendBounded(gpa, &acc.text, oversized, StreamAccum.max_field_bytes),
    );
    try std.testing.expectEqual(@as(usize, 0), acc.text.items.len);

    acc.tool_bytes = StreamAccum.max_field_bytes;
    var fragment: std.ArrayList(u8) = .empty;
    defer fragment.deinit(gpa);
    try std.testing.expectError(error.ResponseTooLarge, acc.appendToolFragment(&fragment, "x"));
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

test "short text and reasoning deltas flush as separate streams" {
    const Capture = struct {
        text: [64]u8 = undefined,
        text_len: usize = 0,
        reasoning: [64]u8 = undefined,
        reasoning_len: usize = 0,

        fn onText(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.text[self.text_len .. self.text_len + bytes.len], bytes);
            self.text_len += bytes.len;
        }

        fn onReasoning(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.reasoning[self.reasoning_len .. self.reasoning_len + bytes.len], bytes);
            self.reasoning_len += bytes.len;
        }
    };

    var capture = Capture{};
    var acc = StreamAccum.init(std.testing.allocator);
    defer acc.deinit();
    acc.on_delta = Capture.onText;
    acc.on_reasoning_delta = Capture.onReasoning;
    acc.on_delta_ctx = &capture;
    feedEvents(&acc, &.{
        \\{"choices":[{"delta":{"reasoning":"think","content":"answer"}}]}
    });
    try std.testing.expectEqual(@as(usize, 0), capture.text_len);
    try std.testing.expectEqual(@as(usize, 0), capture.reasoning_len);
    acc.flushDeltas();
    try std.testing.expectEqualStrings("answer", capture.text[0..capture.text_len]);
    try std.testing.expectEqualStrings("think", capture.reasoning[0..capture.reasoning_len]);
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
    const body = try buildRequestBody(gpa, "openai/gpt-4o", .openrouter, .high, &msgs, &tools, .{
        .session_id = "marlin-abc",
        .provider_sort = "throughput",
    });
    defer gpa.free(body);
    // Must be valid JSON with the right top-level fields.
    const ok = std.json.validate(gpa, body) catch false;
    try std.testing.expect(ok);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parallel_tool_calls\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"session_id\":\"marlin-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"provider\":{\"sort\":\"throughput\"}") != null);

    const auto_body = try buildRequestBody(gpa, "local/model", .openai_compatible, .auto, &msgs, &.{}, .{
        .session_id = "must-not-leak",
        .provider_sort = "throughput",
    });
    defer gpa.free(auto_body);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "provider\"") == null);

    const local_body = try buildRequestBody(gpa, "local/model", .openai_compatible, .low, &msgs, &.{}, .{});
    defer gpa.free(local_body);
    try std.testing.expect(std.mem.indexOf(u8, local_body, "\"reasoning_effort\":\"low\"") != null);

    var cached_msgs = msgs;
    cached_msgs[0].cache_breakpoint = true;
    const cached_body = try buildRequestBody(gpa, "anthropic/claude", .openrouter, .auto, &cached_msgs, &.{}, .{ .explicit_cache = true });
    defer gpa.free(cached_body);
    try std.testing.expect(std.mem.indexOf(u8, cached_body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);

    const cached_tool_msgs = [_]provider.Message{
        .{ .role = .assistant, .payload = .{ .assistant_tool_calls = .{ .text = "", .calls = &.{
            .{ .call_id = "call-1", .name = "grep", .args_json = "{}" },
        } } } },
        .{ .role = .tool, .payload = .{ .tool_result = .{ .call_id = "call-1", .text = "result" } }, .cache_breakpoint = true },
    };
    const cached_tool_body = try buildRequestBody(gpa, "anthropic/claude", .openrouter, .auto, &cached_tool_msgs, &.{}, .{ .explicit_cache = true });
    defer gpa.free(cached_tool_body);
    try std.testing.expect(std.mem.indexOf(u8, cached_tool_body, "\"role\":\"tool\",\"tool_call_id\":\"call-1\",\"content\":[{\"type\":\"text\",\"text\":\"result\",\"cache_control\":{\"type\":\"ephemeral\"}}]") != null);
}
