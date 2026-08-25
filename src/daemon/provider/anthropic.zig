//! Anthropic Messages dialect — the one non-OpenAI-compat API worth having:
//! a direct line to the most-used model family (second billing path,
//! surviving an aggregator outage) and native cache_control breakpoints.
//!
//! Auth is `x-api-key` + `anthropic-version` headers, NOT a bearer token;
//! the loop routes Endpoint.bearer into those headers for this dialect.
//!
//! Deliberately NOT implemented yet: extended thinking. With tools enabled,
//! the API requires replaying signed thinking blocks verbatim on subsequent
//! rounds; the block log does not persist signatures, so requesting thinking
//! would 400 on every second round. Reasoning effort is therefore ignored on
//! the direct dialect until thinking blocks become first-class in the store
//! (they still work via the OpenRouter route).

const std = @import("std");
const provider = @import("provider.zig");
const openai = @import("openai_compat.zig");
const sse = @import("sse.zig");

pub const version_header: []const u8 = "anthropic-version: 2023-06-01";

/// Build the /v1/messages request body. Caller frees.
///
/// The Messages API requires strict user/assistant alternation, while the
/// internal transcript emits one Message per tool result (parallel batches)
/// and steers as separate user messages — consecutive same-role messages
/// therefore merge into one entry with multiple content blocks. A message's
/// cache_breakpoint lands as cache_control on the last content block it
/// produced, preserving the assembler's exact prefix boundary.
pub fn buildRequestBody(
    gpa: std.mem.Allocator,
    model: []const u8,
    messages: []const provider.Message,
    tools: []const openai.ToolSpec,
    max_tokens: u64,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const ws = &aw.writer;
    const enc = std.json.Stringify.encodeJsonString;

    try ws.writeAll("{\"model\":");
    try enc(model, .{}, ws);
    try ws.print(",\"max_tokens\":{d},\"stream\":true", .{max_tokens});

    // System messages become the top-level system block array.
    var body_start: usize = 0;
    var wrote_system = false;
    for (messages) |m| {
        if (m.role != .system) break;
        if (!wrote_system) {
            try ws.writeAll(",\"system\":[");
            wrote_system = true;
        } else try ws.writeByte(',');
        try ws.writeAll("{\"type\":\"text\",\"text\":");
        try enc(systemText(m), .{}, ws);
        if (m.cache_breakpoint) try ws.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
        try ws.writeAll("}");
        body_start += 1;
    }
    if (wrote_system) try ws.writeAll("]");

    try ws.writeAll(",\"messages\":[");
    var open_role: ?Role = null;
    var first_entry = true;
    for (messages[body_start..]) |m| {
        const role = mapRole(m.role);
        if (open_role != role) {
            if (open_role != null) try ws.writeAll("]}");
            if (!first_entry) try ws.writeByte(',');
            first_entry = false;
            try ws.writeAll(if (role == .user)
                "{\"role\":\"user\",\"content\":["
            else
                "{\"role\":\"assistant\",\"content\":[");
            open_role = role;
        } else {
            try ws.writeByte(',');
        }
        try writeBlocks(ws, m);
    }
    if (open_role != null) try ws.writeAll("]}");
    try ws.writeAll("]");

    if (tools.len > 0) {
        try ws.writeAll(",\"tools\":[");
        for (tools, 0..) |t, i| {
            if (i > 0) try ws.writeByte(',');
            try ws.writeAll("{\"name\":");
            try enc(t.name, .{}, ws);
            try ws.writeAll(",\"description\":");
            try enc(t.description, .{}, ws);
            try ws.writeAll(",\"input_schema\":");
            try ws.writeAll(t.schema_json); // already JSON
            try ws.writeAll("}");
        }
        try ws.writeAll("]");
    }
    try ws.writeAll("}");
    return aw.toOwnedSlice();
}

const Role = enum { user, assistant };

fn mapRole(role: provider.Role) Role {
    return switch (role) {
        .assistant => .assistant,
        // Tool results return to the model as user-role tool_result blocks.
        .system, .user, .tool => .user,
    };
}

fn systemText(m: provider.Message) []const u8 {
    return switch (m.payload) {
        .text => |t| t,
        else => "",
    };
}

/// The content blocks one internal Message contributes to the open entry.
fn writeBlocks(ws: *std.Io.Writer, m: provider.Message) !void {
    const enc = std.json.Stringify.encodeJsonString;
    switch (m.payload) {
        .text => |t| {
            try ws.writeAll("{\"type\":\"text\",\"text\":");
            try enc(t, .{}, ws);
            try cacheSuffix(ws, m);
            try ws.writeAll("}");
        },
        .assistant_tool_calls => |calls| {
            if (calls.text.len > 0) {
                try ws.writeAll("{\"type\":\"text\",\"text\":");
                try enc(calls.text, .{}, ws);
                try ws.writeAll("},");
            }
            for (calls.calls, 0..) |tc, j| {
                if (j > 0) try ws.writeByte(',');
                try ws.writeAll("{\"type\":\"tool_use\",\"id\":");
                try enc(tc.call_id, .{}, ws);
                try ws.writeAll(",\"name\":");
                try enc(tc.name, .{}, ws);
                try ws.writeAll(",\"input\":");
                // Post-repair raw JSON object; the API rejects non-objects.
                try ws.writeAll(if (isJsonObject(tc.args_json)) tc.args_json else "{}");
                if (j == calls.calls.len - 1) try cacheSuffix(ws, m);
                try ws.writeAll("}");
            }
        },
        .tool_result => |tr| {
            try ws.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try enc(tr.call_id, .{}, ws);
            try ws.writeAll(",\"content\":");
            try enc(tr.text, .{}, ws);
            try cacheSuffix(ws, m);
            try ws.writeAll("}");
        },
    }
}

fn cacheSuffix(ws: *std.Io.Writer, m: provider.Message) !void {
    if (m.cache_breakpoint)
        try ws.writeAll(",\"cache_control\":{\"type\":\"ephemeral\"}");
}

fn isJsonObject(s: []const u8) bool {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return trimmed.len >= 2 and trimmed[0] == '{';
}

// -------------------------------------------------------------- stream --

/// Decodes the Messages SSE event stream into the shared dialect-neutral
/// accumulator: content_block indexes map text → assistant text, thinking →
/// reasoning, tool_use → reassembled calls. Usage arrives split across
/// message_start (input side) and message_delta (output side); Anthropic's
/// input_tokens EXCLUDE cache reads/writes, so the total is the sum — kept
/// consistent with OpenRouter's inclusive prompt_tokens.
pub const Stream = struct {
    acc: *openai.StreamAccum,
    kinds: [max_blocks]BlockKind = @splat(.none),
    tokens_in: u64 = 0,
    cached: u64 = 0,
    cache_write: u64 = 0,

    const max_blocks = 128;
    const BlockKind = enum(u8) { none, text, thinking, tool_use, other };

    pub fn onEvent(self: *Stream, ev: sse.Event) void {
        if (self.acc.response_too_large) return;
        self.handle(ev.data) catch |err| {
            if (err == error.ResponseTooLarge)
                self.acc.response_too_large = true
            else
                self.acc.parse_errors += 1;
        };
    }

    fn handle(self: *Stream, data: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.acc.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
        const root = switch (parsed) {
            .object => |o| o,
            else => return error.BadChunk,
        };
        const kind = root.get("type") orelse return error.BadChunk;
        if (kind != .string) return error.BadChunk;
        const t = kind.string;

        if (std.mem.eql(u8, t, "content_block_delta")) {
            const idx = jsonIndex(root) orelse return error.BadChunk;
            const delta = objField(root, "delta") orelse return error.BadChunk;
            const dt = strField(delta, "type") orelse return error.BadChunk;
            if (std.mem.eql(u8, dt, "text_delta")) {
                if (strField(delta, "text")) |text| try self.acc.addText(text);
            } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                if (strField(delta, "thinking")) |text| try self.acc.addReasoning(text);
            } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                if (idx < max_blocks and self.kinds[idx] == .tool_use) {
                    if (strField(delta, "partial_json")) |fragment|
                        try self.acc.addToolArgs(@intCast(idx), fragment);
                }
            }
            // signature_delta and friends: ignored (no thinking replay yet).
            return;
        }
        if (std.mem.eql(u8, t, "content_block_start")) {
            const idx = jsonIndex(root) orelse return error.BadChunk;
            if (idx >= max_blocks) return error.ResponseTooLarge;
            const cb = objField(root, "content_block") orelse return error.BadChunk;
            const bt = strField(cb, "type") orelse return error.BadChunk;
            if (std.mem.eql(u8, bt, "text")) {
                self.kinds[idx] = .text;
            } else if (std.mem.eql(u8, bt, "thinking") or std.mem.eql(u8, bt, "redacted_thinking")) {
                self.kinds[idx] = .thinking;
            } else if (std.mem.eql(u8, bt, "tool_use")) {
                self.kinds[idx] = .tool_use;
                try self.acc.beginToolCall(
                    @intCast(idx),
                    strField(cb, "id") orelse "",
                    strField(cb, "name") orelse "",
                );
            } else {
                self.kinds[idx] = .other;
            }
            return;
        }
        if (std.mem.eql(u8, t, "message_start")) {
            const msg = objField(root, "message") orelse return;
            if (strField(msg, "id")) |id| try self.acc.setGenerationId(id);
            if (objField(msg, "usage")) |usage| {
                self.tokens_in = uintField(usage, "input_tokens") orelse 0;
                self.cached = uintField(usage, "cache_read_input_tokens") orelse 0;
                self.cache_write = uintField(usage, "cache_creation_input_tokens") orelse 0;
            }
            return;
        }
        if (std.mem.eql(u8, t, "message_delta")) {
            if (objField(root, "delta")) |delta| {
                if (strField(delta, "stop_reason")) |reason|
                    self.acc.finish_reason = mapStop(reason);
            }
            if (objField(root, "usage")) |usage| {
                const out = uintField(usage, "output_tokens") orelse 0;
                self.acc.usage = .{
                    .tokens_in = self.tokens_in + self.cached + self.cache_write,
                    .tokens_out = out,
                    .cached_tokens = self.cached,
                    .cache_write_tokens = self.cache_write,
                };
            }
            return;
        }
        if (std.mem.eql(u8, t, "message_stop")) {
            self.acc.saw_done = true;
            return;
        }
        if (std.mem.eql(u8, t, "error")) {
            // Mid-stream provider error (overloaded etc.); surfaced as a
            // truncated round rather than a crash. The note stays in logs.
            if (objField(root, "error")) |e| {
                std.log.warn("anthropic stream error: {s}", .{strField(e, "message") orelse "unknown"});
            }
            self.acc.parse_errors += 1;
            return;
        }
        // ping / content_block_stop: nothing to do.
    }

    fn mapStop(reason: []const u8) openai.StreamAccum.FinishReason {
        if (std.mem.eql(u8, reason, "end_turn")) return .stop;
        if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
        if (std.mem.eql(u8, reason, "tool_use")) return .tool_calls;
        if (std.mem.eql(u8, reason, "max_tokens")) return .length;
        return .other;
    }
};

fn objField(map: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = map.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn strField(map: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = map.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn uintField(map: std.json.ObjectMap, key: []const u8) ?u64 {
    const v = map.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

fn jsonIndex(map: std.json.ObjectMap) ?usize {
    const v = map.get("index") orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

// ---------------------------------------------------------------- tests --

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

test "stream decode: text, thinking, tool_use reassembly, usage, stop reason" {
    const gpa = std.testing.allocator;
    var acc = openai.StreamAccum.init(gpa);
    defer acc.deinit();
    var stream = Stream{ .acc = &acc };

    const events = [_][]const u8{
        \\{"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":50,"output_tokens":1}}}
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

test {
    std.testing.refAllDecls(@This());
}
