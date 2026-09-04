//! Unit tests for otel.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in otel.zig.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const telemetry_ids = @import("../core/telemetry.zig");
const block = @import("../core/block.zig");
const Store = @import("store.zig").Store;
const TelemetryTrace = @import("store.zig").TelemetryTrace;
const http = @import("provider/http.zig");

const otel = @import("otel.zig");
const buildEndpoint = otel.buildEndpoint;
const buildTraceRequest = otel.buildTraceRequest;
const buildTurnContent = otel.buildTurnContent;
const contentCaptureRequested = otel.contentCaptureRequested;
const content_attribute_cap = otel.content_attribute_cap;
const freeHeaders = otel.freeHeaders;
const parseHeaders = otel.parseHeaders;
const spanAttribute = otel.spanAttribute;

test {
    std.testing.refAllDecls(otel);
}

fn traceSpans(value: std.json.Value) []const std.json.Value {
    return value.object.get("resourceSpans").?.array.items[0]
        .object.get("scopeSpans").?.array.items[0]
        .object.get("spans").?.array.items;
}

fn spanNamed(spans: []const std.json.Value, name: []const u8) *const std.json.Value {
    for (spans) |*span| {
        const span_name = span.object.get("name") orelse continue;
        if (span_name == .string and std.mem.eql(u8, span_name.string, name)) return span;
    }
    unreachable;
}

fn expectStringAttribute(span: std.json.Value, key: []const u8, expected: []const u8) !void {
    const value = spanAttribute(span, key) orelse return error.TestExpectedEqual;
    const string_value = value.object.get("stringValue") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(expected, string_value.string);
}

test "OTLP request follows GenAI inference and execute-tool structure without content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const json = try buildTraceRequest(arena_state.allocator(), .{
        .session_id = 1,
        .turn_id = 2,
        .model = "openrouter/test/model",
        .session_kind = "root",
        .started_at_ms = 10,
        .ended_at_ms = 30,
        .outcome = "ok",
        .error_text = "",
        .rounds_count = 1,
        .tool_calls = 1,
        .tokens_in = 12,
        .tokens_out = 4,
        .rounds = &.{.{
            .round = 0,
            .span_id = "0000000000000003",
            .started_at_ms = 12,
            .first_byte_at_ms = 15,
            .first_visible_at_ms = 16,
            .ended_at_ms = 20,
            .status = "ok",
            .http_status = 200,
            .response_bytes = 50,
            .provider = "OpenAI",
            .provider_name = "openrouter",
            .request_model = "test/model",
            .response_model = "test/model-v2",
            .server_address = "openrouter.ai",
            .server_port = 443,
            .finish_reason = "stop",
            .reasoning_level = "high",
            .max_tokens = 0,
            .generation_id = "gen-1",
            .usage_available = true,
            .tokens_in = 12,
            .tokens_out = 4,
            .cached_tokens = 2,
            .cache_write_tokens = 0,
            .reasoning_tokens = 1,
        }},
        .tools = &.{.{
            .round = 0,
            .call_id = "call-1",
            .span_id = "0000000000000004",
            .name = "read_file",
            .description = "Read a text file",
            .started_at_ms = 20,
            .ended_at_ms = 21,
            .status = "ok",
        }},
    }, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), json, .{});
    defer parsed.deinit();
    const spans = traceSpans(parsed.value);
    try std.testing.expectEqual(@as(usize, 3), spans.len);

    const root = spanNamed(spans, "invoke_agent marlin");
    try std.testing.expectEqual(@as(i64, 1), root.object.get("kind").?.integer);
    try expectStringAttribute(root.*, "gen_ai.operation.name", "invoke_agent");
    try expectStringAttribute(root.*, "gen_ai.agent.name", "marlin");
    try std.testing.expect(spanAttribute(root.*, "gen_ai.conversation.id") != null);
    try std.testing.expect(spanAttribute(root.*, "gen_ai.usage.input_tokens") != null);
    try std.testing.expect(spanAttribute(root.*, "gen_ai.usage.output_tokens") != null);
    try std.testing.expect(spanAttribute(root.*, "gen_ai.provider.name") == null);

    const inference = spanNamed(spans, "chat test/model");
    try std.testing.expectEqual(@as(i64, 3), inference.object.get("kind").?.integer);
    try std.testing.expectEqualStrings(root.object.get("spanId").?.string, inference.object.get("parentSpanId").?.string);
    try expectStringAttribute(inference.*, "gen_ai.operation.name", "chat");
    try expectStringAttribute(inference.*, "gen_ai.provider.name", "openrouter");
    try expectStringAttribute(inference.*, "gen_ai.request.model", "test/model");
    try expectStringAttribute(inference.*, "gen_ai.response.id", "gen-1");
    try expectStringAttribute(inference.*, "gen_ai.response.model", "test/model-v2");
    try expectStringAttribute(inference.*, "server.address", "openrouter.ai");
    try std.testing.expect(spanAttribute(inference.*, "gen_ai.response.finish_reasons") != null);
    try std.testing.expect(spanAttribute(inference.*, "gen_ai.response.time_to_first_chunk") != null);
    try std.testing.expect(inference.object.get("status") == null);

    const tool = spanNamed(spans, "execute_tool read_file");
    try std.testing.expectEqual(@as(i64, 1), tool.object.get("kind").?.integer);
    try std.testing.expectEqualStrings(inference.object.get("spanId").?.string, tool.object.get("parentSpanId").?.string);
    try expectStringAttribute(tool.*, "gen_ai.operation.name", "execute_tool");
    try expectStringAttribute(tool.*, "gen_ai.tool.name", "read_file");
    try expectStringAttribute(tool.*, "gen_ai.tool.call.id", "call-1");
    try expectStringAttribute(tool.*, "gen_ai.tool.description", "Read a text file");
    try expectStringAttribute(tool.*, "gen_ai.tool.type", "function");
    try std.testing.expect(tool.object.get("status") == null);

    for ([_][]const u8{
        "gen_ai.system_instructions",
        "gen_ai.input.messages",
        "gen_ai.output.messages",
        "gen_ai.tool.definitions",
        "gen_ai.tool.call.arguments",
        "gen_ai.tool.call.result",
    }) |content_key| try std.testing.expect(std.mem.indexOf(u8, json, content_key) == null);
}

test "OTLP GenAI failures set error type and error span status" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const json = try buildTraceRequest(arena_state.allocator(), .{
        .session_id = 1,
        .turn_id = 2,
        .model = "anthropic/test-model",
        .session_kind = "root",
        .started_at_ms = 10,
        .ended_at_ms = 30,
        .outcome = "error",
        .error_text = "secret provider message",
        .rounds_count = 1,
        .tool_calls = 1,
        .tokens_in = 0,
        .tokens_out = 0,
        .rounds = &.{.{
            .round = 0,
            .span_id = "0000000000000003",
            .started_at_ms = 12,
            .first_byte_at_ms = 0,
            .first_visible_at_ms = 0,
            .ended_at_ms = 20,
            .status = "provider_error",
            .http_status = 429,
            .response_bytes = 0,
            .provider = "",
            .provider_name = "anthropic",
            .request_model = "test-model",
            .response_model = "",
            .server_address = "api.anthropic.com",
            .server_port = 443,
            .finish_reason = "",
            .reasoning_level = "",
            .max_tokens = 16_000,
            .generation_id = "",
            .usage_available = false,
            .tokens_in = 0,
            .tokens_out = 0,
            .cached_tokens = 0,
            .cache_write_tokens = 0,
            .reasoning_tokens = 0,
        }},
        .tools = &.{.{
            .round = 0,
            .call_id = "call-1",
            .span_id = "0000000000000004",
            .name = "bash",
            .description = "",
            .started_at_ms = 20,
            .ended_at_ms = 21,
            .status = "denied",
        }},
    }, null);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), json, .{});
    defer parsed.deinit();
    const spans = traceSpans(parsed.value);

    const inference = spanNamed(spans, "chat test-model");
    try expectStringAttribute(inference.*, "error.type", "429");
    try std.testing.expectEqual(@as(i64, 2), inference.object.get("status").?.object.get("code").?.integer);
    try std.testing.expect(spanAttribute(inference.*, "gen_ai.request.max_tokens") != null);

    const tool = spanNamed(spans, "execute_tool bash");
    try expectStringAttribute(tool.*, "error.type", "denied");
    try std.testing.expectEqual(@as(i64, 2), tool.object.get("status").?.object.get("code").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, json, "secret provider message") == null);
}

test "content capture is recognized only for span-carrying opt-in values" {
    try std.testing.expect(contentCaptureRequested("SPAN_ONLY"));
    try std.testing.expect(contentCaptureRequested("span_and_event"));
    try std.testing.expect(contentCaptureRequested("true"));
    try std.testing.expect(!contentCaptureRequested(""));
    try std.testing.expect(!contentCaptureRequested("NO_CONTENT"));
    try std.testing.expect(!contentCaptureRequested("event_only"));
    try std.testing.expect(!contentCaptureRequested("false"));
}

test "content capture joins turn blocks onto spans and caps oversized values" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "test/model", .auto);
    const huge = try arena.alloc(u8, content_attribute_cap + 100);
    @memset(huge, 'x');
    const bodies = [_]block.Body{
        .{ .user_msg = .{ .text = "please fix the flaky test" } },
        .{ .user_msg = .{ .text = "machine context", .synthetic = true } },
        .{ .tool_call = .{ .call_id = "call-1", .name = "bash", .args_json = "{\"cmd\":\"zig build test\"}" } },
        .{ .tool_result = .{ .call_id = "call-1", .status = .ok, .inline_body = huge, .full_body_ref = null } },
        .{ .steer = .{ .text = "prefer rg" } },
        .{ .assistant_msg = .{ .text = "done — the test was time-dependent" } },
    };
    for (bodies, 1..) |body, seq| try store.appendBlock(.{
        .id = seq,
        .session_id = 1,
        .turn_id = 2,
        .seq = seq,
        .ts = 100,
        .body = body,
    });
    // Another turn's block must not leak into this turn's content.
    try store.appendBlock(.{
        .id = 99,
        .session_id = 1,
        .turn_id = 3,
        .seq = 99,
        .ts = 200,
        .body = .{ .user_msg = .{ .text = "unrelated later prompt" } },
    });

    const trace = TelemetryTrace{
        .session_id = 1,
        .turn_id = 2,
        .model = "test/model",
        .session_kind = "root",
        .started_at_ms = 10,
        .ended_at_ms = 30,
        .outcome = "ok",
        .error_text = "",
        .rounds_count = 1,
        .tool_calls = 1,
        .tokens_in = 12,
        .tokens_out = 4,
        .rounds = &.{},
        .tools = &.{.{
            .round = 0,
            .call_id = "call-1",
            .span_id = "0000000000000004",
            .name = "bash",
            .description = "",
            .started_at_ms = 20,
            .ended_at_ms = 21,
            .status = "ok",
        }},
    };
    const content = try buildTurnContent(arena, &store, trace);
    const json = try buildTraceRequest(arena, trace, content);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json, .{});
    defer parsed.deinit();
    const spans = traceSpans(parsed.value);

    const root = spanNamed(spans, "invoke_agent marlin");
    const input = spanAttribute(root.*, "gen_ai.input.messages").?.object.get("stringValue").?.string;
    try std.testing.expect(std.mem.indexOf(u8, input, "please fix the flaky test") != null);
    try std.testing.expect(std.mem.indexOf(u8, input, "prefer rg") != null);
    try std.testing.expect(std.mem.indexOf(u8, input, "machine context") == null);
    try std.testing.expect(std.mem.indexOf(u8, input, "unrelated later prompt") == null);
    const output = spanAttribute(root.*, "gen_ai.output.messages").?.object.get("stringValue").?.string;
    try std.testing.expect(std.mem.indexOf(u8, output, "time-dependent") != null);

    const tool = spanNamed(spans, "execute_tool bash");
    try expectStringAttribute(tool.*, "gen_ai.tool.call.arguments", "{\"cmd\":\"zig build test\"}");
    const result = spanAttribute(tool.*, "gen_ai.tool.call.result").?.object.get("stringValue").?.string;
    try std.testing.expect(result.len < huge.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "…[truncated 100 bytes]") != null);
}

test "OTEL endpoint normalization validates schemes and appends traces path" {
    const gpa = std.testing.allocator;
    const base = try buildEndpoint(gpa, "https://otel.example/", false);
    defer gpa.free(base);
    try std.testing.expectEqualStrings("https://otel.example/v1/traces", base);

    const traces = try buildEndpoint(gpa, "https://otel.example/custom/traces", true);
    defer gpa.free(traces);
    try std.testing.expectEqualStrings("https://otel.example/custom/traces", traces);

    try std.testing.expectError(error.InvalidOtelEndpoint, buildEndpoint(gpa, "file:///tmp/traces", false));
    try std.testing.expectError(error.InvalidOtelEndpoint, buildEndpoint(gpa, "not a URL", false));
}

test "OTEL headers decode standard percent escapes" {
    const gpa = std.testing.allocator;
    const headers = try parseHeaders(gpa, "Authorization=Bearer%20secret,x-team=marlin");
    defer freeHeaders(gpa, headers);
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("Authorization: Bearer secret", headers[0]);
    try std.testing.expectError(error.InvalidOtelHeaders, parseHeaders(gpa, "Authorization"));
}
