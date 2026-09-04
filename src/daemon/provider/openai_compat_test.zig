//! Unit tests for openai_compat.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in openai_compat.zig.

const std = @import("std");
const provider = @import("provider.zig");
const sse = @import("sse.zig");
const Effort = @import("../../core/effort.zig").Effort;

const openai_compat = @import("openai_compat.zig");
const StreamAccum = openai_compat.StreamAccum;
const ToolSpec = openai_compat.ToolSpec;
const appendBounded = openai_compat.appendBounded;
const buildRequestBody = openai_compat.buildRequestBody;

test {
    std.testing.refAllDecls(openai_compat);
}

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
        \\{"id":"gen-test","provider":"OpenAI","model":"gpt-5.1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":8,"cache_write_tokens":1},"completion_tokens_details":{"reasoning_tokens":3},"server_tool_use":{"web_search_requests":2}}}
        ,
        "[DONE]",
    });
    try std.testing.expectEqualStrings("Hello", acc.text.items);
    try std.testing.expectEqual(StreamAccum.FinishReason.stop, acc.finish_reason.?);
    try std.testing.expectEqual(@as(u64, 10), acc.usage.?.tokens_in);
    try std.testing.expectEqual(@as(u64, 8), acc.usage.?.cached_tokens);
    try std.testing.expectEqual(@as(u64, 1), acc.usage.?.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 3), acc.usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(u64, 2), acc.usage.?.web_search_requests);
    try std.testing.expectEqualStrings("gen-test", acc.generation_id.items);
    try std.testing.expectEqualStrings("OpenAI", acc.provider_name.items);
    try std.testing.expectEqualStrings("gpt-5.1", acc.response_model.items);
    try std.testing.expect(acc.saw_done);
    try std.testing.expectEqual(@as(u32, 0), acc.parse_errors);
}

test "web citation annotations survive as durable source links" {
    const gpa = std.testing.allocator;
    var acc = StreamAccum.init(gpa);
    defer acc.deinit();
    feedEvents(&acc, &.{
        \\{"choices":[{"delta":{"content":"A grounded answer.","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/report","title":"Example\n Report"}},{"type":"url_citation","url_citation":{"url":"https://example.com/report","title":"duplicate"}},{"type":"url_citation","url_citation":{"url":"javascript:alert(1)","title":"unsafe"}}]}}]}
    });

    try std.testing.expectEqual(@as(usize, 1), acc.citations.items.len);
    const text = try acc.textWithCitationLinks(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "Sources:") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Example Report — https://example.com/report") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "javascript:") == null);
}

test "web citation already linked by model is not duplicated" {
    const gpa = std.testing.allocator;
    var acc = StreamAccum.init(gpa);
    defer acc.deinit();
    feedEvents(&acc, &.{
        \\{"choices":[{"delta":{"content":"See [the source](https://example.com/report).","annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/report","title":"Example"}}]}}]}
    });

    const text = try acc.textWithCitationLinks(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("See [the source](https://example.com/report).", text);
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
        .openrouter_web_search = true,
        .trace_id = "00000000000000000000000000000001",
        .parent_span_id = "0000000000000002",
    });
    defer gpa.free(body);
    // Must be valid JSON with the right top-level fields.
    const ok = std.json.validate(gpa, body) catch false;
    try std.testing.expect(ok);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parallel_tool_calls\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"openrouter:web_search\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_results\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_total_results\":15") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"session_id\":\"marlin-abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"provider\":{\"sort\":\"throughput\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"trace_id\":\"00000000000000000000000000000001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parent_span_id\":\"0000000000000002\"") != null);

    const auto_body = try buildRequestBody(gpa, "local/model", .openai_compatible, .auto, &msgs, &.{}, .{
        .session_id = "must-not-leak",
        .provider_sort = "throughput",
        .openrouter_web_search = true,
        .trace_id = "must-not-leak",
        .parent_span_id = "must-not-leak",
    });
    defer gpa.free(auto_body);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "session_id") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "provider\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "openrouter:web_search") == null);
    try std.testing.expect(std.mem.indexOf(u8, auto_body, "trace_id") == null);

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

test "request body maps user images to OpenAI content parts" {
    const gpa = std.testing.allocator;
    const messages = [_]provider.Message{.{
        .role = .user,
        .payload = .{ .user_content = .{
            .text = "inspect",
            .media = &.{.{
                .name = "shot.png",
                .mime = "image/png",
                .data_base64 = "iVBORw0KGgo=",
            }},
        } },
    }};
    const body = try buildRequestBody(gpa, "vision-model", .openrouter, .auto, &messages, &.{}, .{});
    defer gpa.free(body);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image_url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/png;base64,iVBORw0KGgo=") != null);
}

test "request body maps tool images to OpenAI content parts" {
    const gpa = std.testing.allocator;
    const messages = [_]provider.Message{.{
        .role = .tool,
        .payload = .{ .tool_result = .{
            .call_id = "shot-1",
            .text = "screenshot",
            .media = &.{.{ .name = "shot.png", .mime = "image/png", .data_base64 = "iVBORw0KGgo=" }},
        } },
    }};
    const body = try buildRequestBody(gpa, "vision", .openrouter, .auto, &messages, &.{}, .{});
    defer gpa.free(body);
    try std.testing.expect(try std.json.validate(gpa, body));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\":\"shot-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"tool\",\"tool_call_id\":\"shot-1\",\"content\":\"screenshot\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\",\"content\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data:image/png;base64,iVBORw0KGgo=") != null);
}
