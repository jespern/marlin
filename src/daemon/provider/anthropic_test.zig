//! Unit tests for anthropic.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in anthropic.zig.

const std = @import("std");
const provider = @import("provider.zig");
const openai = @import("openai_compat.zig");
const sse = @import("sse.zig");

const anthropic = @import("anthropic.zig");
const Stream = anthropic.Stream;
const buildRequestBody = anthropic.buildRequestBody;

test {
    std.testing.refAllDecls(anthropic);
}

test "request body: system cache, role merging, tool_use and tool_result" {
    const gpa = std.testing.allocator;
    const calls = [_]provider.ToolCall{
        .{ .call_id = "toolu_1", .name = "grep", .args_json = "{\"pattern\":\"x\"}" },
        .{ .call_id = "toolu_2", .name = "read_file", .args_json = "" },
    };
    const msgs = [_]provider.Message{
        .{ .role = .system, .payload = .{ .text = "be terse" }, .cache_breakpoint = true },
        .{ .role = .user, .payload = .{ .text = "hi" } },
        .{ .role = .assistant, .payload = .{ .assistant_tool_calls = .{ .text = "looking", .calls = &calls } } },
        // Parallel results: two internal messages, ONE user entry on the wire.
        .{ .role = .tool, .payload = .{ .tool_result = .{ .call_id = "toolu_1", .text = "m1" } } },
        .{ .role = .tool, .payload = .{ .tool_result = .{ .call_id = "toolu_2", .text = "m2" } }, .cache_breakpoint = true },
    };
    const tools = [_]openai.ToolSpec{
        .{ .name = "grep", .description = "search", .schema_json = "{\"type\":\"object\"}" },
    };
    const body = try buildRequestBody(gpa, "claude-sonnet-4-5", &msgs, &tools, 16000);
    defer gpa.free(body);

    const expected =
        "{\"model\":\"claude-sonnet-4-5\",\"max_tokens\":16000,\"stream\":true," ++
        "\"system\":[{\"type\":\"text\",\"text\":\"be terse\",\"cache_control\":{\"type\":\"ephemeral\"}}]," ++
        "\"messages\":[" ++
        "{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}," ++
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"looking\"}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"grep\",\"input\":{\"pattern\":\"x\"}}," ++
        "{\"type\":\"tool_use\",\"id\":\"toolu_2\",\"name\":\"read_file\",\"input\":{}}]}," ++
        "{\"role\":\"user\",\"content\":[" ++
        "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"m1\"}," ++
        "{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_2\",\"content\":\"m2\",\"cache_control\":{\"type\":\"ephemeral\"}}]}]," ++
        "\"tools\":[{\"name\":\"grep\",\"description\":\"search\",\"input_schema\":{\"type\":\"object\"}}]}";
    try std.testing.expectEqualStrings(expected, body);
}

test "request body maps user images to Anthropic source blocks" {
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
        .cache_breakpoint = true,
    }};
    const body = try buildRequestBody(gpa, "claude", &messages, &.{}, 1024);
    defer gpa.free(body);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), body, .{});
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
}

test "request body maps tool images inside Anthropic tool results" {
    const gpa = std.testing.allocator;
    const messages = [_]provider.Message{.{
        .role = .tool,
        .payload = .{ .tool_result = .{
            .call_id = "shot-1",
            .text = "screenshot",
            .media = &.{.{ .name = "shot.png", .mime = "image/png", .data_base64 = "iVBORw0KGgo=" }},
        } },
    }};
    const body = try buildRequestBody(gpa, "claude", &messages, &.{}, 1024);
    defer gpa.free(body);
    try std.testing.expect(try std.json.validate(gpa, body));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"media_type\":\"image/png\"") != null);
}

test "stream decode: text, thinking, tool_use reassembly, usage, stop reason" {
    const gpa = std.testing.allocator;
    var acc = openai.StreamAccum.init(gpa);
    defer acc.deinit();
    var stream = Stream{ .acc = &acc };

    const events = [_][]const u8{
        \\{"type":"message_start","message":{"id":"msg_1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":50,"output_tokens":1}}}
        ,
        \\{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}
        ,
        \\{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}}
        ,
        \\{"type":"content_block_stop","index":0}
        ,
        \\{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}}
        ,
        \\{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}}
        ,
        \\{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_9","name":"bash","input":{}}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"comm"}}
        ,
        \\{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"and\":\"ls\"}"}}
        ,
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}
        ,
        \\{"type":"message_stop"}
        ,
    };
    for (events) |data| stream.onEvent(.{ .name = "", .data = data });

    try std.testing.expectEqualStrings("Hello", acc.text.items);
    try std.testing.expectEqualStrings("pondering", acc.reasoning.items);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", acc.response_model.items);
    try std.testing.expectEqual(@as(usize, 1), acc.calls.items.len);
    try std.testing.expectEqualStrings("toolu_9", acc.calls.items[0].call_id.items);
    try std.testing.expectEqualStrings("bash", acc.calls.items[0].name.items);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", acc.calls.items[0].args.items);
    try std.testing.expectEqual(openai.StreamAccum.FinishReason.tool_calls, acc.finish_reason.?);
    const usage = acc.usage.?;
    try std.testing.expectEqual(@as(u64, 1050), usage.tokens_in);
    try std.testing.expectEqual(@as(u64, 42), usage.tokens_out);
    try std.testing.expectEqual(@as(u64, 900), usage.cached_tokens);
    try std.testing.expectEqual(@as(u64, 50), usage.cache_write_tokens);
    try std.testing.expect(acc.saw_done);
    try std.testing.expectEqual(@as(u32, 0), acc.parse_errors);
}
