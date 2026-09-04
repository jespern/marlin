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
    /// OpenRouter executes this server tool inside the provider request. It is
    /// never emitted for generic OpenAI-compatible endpoints.
    openrouter_web_search: bool = false,
    /// OpenRouter Broadcast correlation. The Marlin provider span is the
    /// parent; OpenRouter emits its generation span beneath it.
    trace_id: ?[]const u8 = null,
    parent_span_id: ?[]const u8 = null,
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
            // Anthropic requests are built by anthropic.buildRequestBody.
            .anthropic => unreachable,
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
        if (opts.trace_id) |trace_id| {
            try ws.writeAll(",\"trace\":{\"trace_id\":");
            try enc(trace_id, .{}, ws);
            if (opts.parent_span_id) |parent_span_id| {
                try ws.writeAll(",\"parent_span_id\":");
                try enc(parent_span_id, .{}, ws);
            }
            try ws.writeAll(",\"trace_name\":\"marlin.turn\",\"generation_name\":\"openrouter.chat\"}");
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
            .user_content => |content| {
                try ws.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
                try enc(content.text, .{}, ws);
                try ws.writeAll("}");
                for (content.media) |media| {
                    try ws.writeAll(",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                    try ws.writeAll(media.mime);
                    try ws.writeAll(";base64,");
                    try ws.writeAll(media.data_base64);
                    try ws.writeAll("\"}}");
                }
                try ws.writeAll("]");
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

        // Chat Completions only portably guarantees image parts on user
        // messages. Keep every required tool response contiguous, then append
        // one user media message for the completed batch. Anthropic's native
        // builder can embed the same media directly inside tool_result.
        if (m.role == .tool and (i + 1 == messages.len or messages[i + 1].role != .tool)) {
            var first_tool = i;
            while (first_tool > 0 and messages[first_tool - 1].role == .tool) first_tool -= 1;
            var media_count: usize = 0;
            for (messages[first_tool .. i + 1]) |tool_message| switch (tool_message.payload) {
                .tool_result => |result| media_count += result.media.len,
                else => {},
            };
            if (media_count > 0) {
                try ws.writeAll(",{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"Images returned by the preceding tool results, in the same order:\"}");
                for (messages[first_tool .. i + 1]) |tool_message| switch (tool_message.payload) {
                    .tool_result => |result| for (result.media) |media| {
                        try ws.writeAll(",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                        try ws.writeAll(media.mime);
                        try ws.writeAll(";base64,");
                        try ws.writeAll(media.data_base64);
                        try ws.writeAll("\"}}");
                    },
                    else => {},
                };
                try ws.writeAll("]}");
            }
        }
    }
    try ws.writeAll("]");
    const include_web_search = dialect == .openrouter and opts.openrouter_web_search;
    if (tools.len > 0 or include_web_search) {
        try ws.writeAll(",\"tools\":[");
        var wrote_tool = false;
        if (include_web_search) {
            try ws.writeAll("{\"type\":\"openrouter:web_search\",\"parameters\":{\"max_results\":5,\"max_total_results\":15,\"max_characters\":2000}}");
            wrote_tool = true;
        }
        for (tools) |t| {
            if (wrote_tool) try ws.writeByte(',');
            try ws.writeAll("{\"type\":\"function\",\"function\":{\"name\":");
            try enc(t.name, .{}, ws);
            try ws.writeAll(",\"description\":");
            try enc(t.description, .{}, ws);
            try ws.writeAll(",\"parameters\":");
            try ws.writeAll(t.schema_json); // already JSON
            try ws.writeAll("}}");
            wrote_tool = true;
        }
        try ws.writeAll("]");
        if (dialect == .openrouter and tools.len > 0) try ws.writeAll(",\"parallel_tool_calls\":true");
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
    citations: std.ArrayList(Citation) = .empty,
    /// OpenRouter identifiers make a request directly inspectable through its
    /// Activity/generation observability surfaces; kept only for live logs.
    generation_id: std.ArrayList(u8) = .empty,
    provider_name: std.ArrayList(u8) = .empty,
    response_model: std.ArrayList(u8) = .empty,
    finish_reason: ?FinishReason = null,
    usage: ?provider.Usage = null,
    saw_done: bool = false,
    /// Set on JSON we couldn't parse (provider bug / mid-stream garbage).
    parse_errors: u32 = 0,
    /// Sticky: the response crossed a memory/protocol safety ceiling. The
    /// HTTP consumer observes this and closes the stream immediately.
    response_too_large: bool = false,
    tool_bytes: usize = 0,
    citation_bytes: usize = 0,

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
    const max_citations: usize = 64;
    const max_citation_bytes: usize = 256 * 1024;

    pub const FinishReason = enum { stop, tool_calls, length, content_filter, other };

    pub fn finishReason(self: *const StreamAccum) []const u8 {
        return if (self.finish_reason) |reason| @tagName(reason) else "";
    }

    pub const PartialCall = struct {
        index: u32,
        call_id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,
        args: std.ArrayList(u8) = .empty,
    };

    pub const Citation = struct {
        url: []u8,
        title: []u8,
    };

    pub fn init(gpa: std.mem.Allocator) StreamAccum {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *StreamAccum) void {
        self.text.deinit(self.gpa);
        self.reasoning.deinit(self.gpa);
        self.generation_id.deinit(self.gpa);
        self.provider_name.deinit(self.gpa);
        self.response_model.deinit(self.gpa);
        for (self.calls.items) |*pc| {
            pc.call_id.deinit(self.gpa);
            pc.name.deinit(self.gpa);
            pc.args.deinit(self.gpa);
        }
        self.calls.deinit(self.gpa);
        for (self.citations.items) |citation| {
            self.gpa.free(citation.url);
            self.gpa.free(citation.title);
        }
        self.citations.deinit(self.gpa);
    }

    // ------------------------------------------------ dialect decoder API --
    // The accumulator is dialect-neutral; onEvent below is the OpenAI-shape
    // decoder. Other dialects (anthropic.zig) fill the same accumulator
    // through these, inheriting bounds and delta coalescing.

    pub fn addText(self: *StreamAccum, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try appendBounded(self.gpa, &self.text, bytes, max_field_bytes);
        self.maybeForwardText();
    }

    pub fn addReasoning(self: *StreamAccum, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        try appendBounded(self.gpa, &self.reasoning, bytes, max_field_bytes);
        self.maybeForwardReasoning();
    }

    pub fn beginToolCall(self: *StreamAccum, index: u32, id: []const u8, name: []const u8) !void {
        const pc = try self.callAt(index);
        try self.appendToolFragment(&pc.call_id, id);
        try self.appendToolFragment(&pc.name, name);
    }

    pub fn addToolArgs(self: *StreamAccum, index: u32, fragment: []const u8) !void {
        const pc = try self.callAt(index);
        try self.appendToolFragment(&pc.args, fragment);
    }

    pub fn setGenerationId(self: *StreamAccum, id: []const u8) !void {
        if (self.generation_id.items.len > 0) return;
        try appendBounded(self.gpa, &self.generation_id, id, max_metadata_bytes);
    }

    pub fn setResponseModel(self: *StreamAccum, model: []const u8) !void {
        if (self.response_model.items.len > 0) return;
        try appendBounded(self.gpa, &self.response_model, model, max_metadata_bytes);
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
        if (self.response_model.items.len == 0) {
            if (root.get("model")) |model| if (model == .string)
                try appendBounded(self.gpa, &self.response_model, model.string, max_metadata_bytes);
        }

        // usage: on the final chunk (or OpenRouter's usage-only tail chunk)
        if (root.get("usage")) |u| if (u == .object) {
            const tin = intField(u.object, "prompt_tokens") orelse intField(u.object, "input_tokens") orelse 0;
            const tout = intField(u.object, "completion_tokens") orelse intField(u.object, "output_tokens") orelse 0;
            const cached = nestedIntField(u.object, "prompt_tokens_details", "cached_tokens") orelse 0;
            const cache_write = nestedIntField(u.object, "prompt_tokens_details", "cache_write_tokens") orelse 0;
            const reasoning_tokens = nestedIntField(u.object, "completion_tokens_details", "reasoning_tokens") orelse 0;
            const web_search_requests = nestedIntField(u.object, "server_tool_use", "web_search_requests") orelse 0;
            if (tin != 0 or tout != 0 or web_search_requests != 0)
                self.usage = .{
                    .tokens_in = tin,
                    .tokens_out = tout,
                    .cached_tokens = cached,
                    .cache_write_tokens = cache_write,
                    .reasoning_tokens = reasoning_tokens,
                    .web_search_requests = web_search_requests,
                };
        };

        const choices = root.get("choices") orelse return;
        if (choices != .array or choices.array.items.len == 0) return;
        const choice0 = choices.array.items[0];
        if (choice0 != .object) return;
        try self.collectAnnotations(choice0.object);
        if (choice0.object.get("message")) |message| {
            if (message == .object) try self.collectAnnotations(message.object);
        }

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
        try self.collectAnnotations(delta.object);

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

    pub fn appendToolFragment(self: *StreamAccum, list: *std.ArrayList(u8), bytes: []const u8) !void {
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

    fn collectAnnotations(self: *StreamAccum, object: std.json.ObjectMap) !void {
        const annotations = object.get("annotations") orelse return;
        if (annotations != .array) return;
        for (annotations.array.items) |annotation| {
            if (annotation != .object) continue;
            const kind = annotation.object.get("type") orelse continue;
            if (kind != .string or !std.mem.eql(u8, kind.string, "url_citation")) continue;
            const value = annotation.object.get("url_citation") orelse continue;
            if (value != .object) continue;
            const url_value = value.object.get("url") orelse continue;
            if (url_value != .string or
                (!std.mem.startsWith(u8, url_value.string, "https://") and
                    !std.mem.startsWith(u8, url_value.string, "http://"))) continue;
            var safe_url = true;
            for (url_value.string) |byte| {
                if (byte <= 0x20 or byte == 0x7f) {
                    safe_url = false;
                    break;
                }
            }
            if (!safe_url) continue;
            const title_value = value.object.get("title");
            const title = if (title_value) |candidate|
                if (candidate == .string) candidate.string else ""
            else
                "";
            try self.addCitation(url_value.string, title);
        }
    }

    fn addCitation(self: *StreamAccum, url: []const u8, title: []const u8) !void {
        for (self.citations.items) |citation| {
            if (std.mem.eql(u8, citation.url, url)) return;
        }
        if (self.citations.items.len >= max_citations or
            url.len > max_citation_bytes -| self.citation_bytes or
            title.len > max_citation_bytes -| self.citation_bytes -| url.len)
        {
            return error.ResponseTooLarge;
        }
        const owned_url = try self.gpa.dupe(u8, url);
        errdefer self.gpa.free(owned_url);
        const owned_title = try self.gpa.dupe(u8, title);
        errdefer self.gpa.free(owned_title);
        try self.citations.append(self.gpa, .{ .url = owned_url, .title = owned_title });
        self.citation_bytes += url.len + title.len;
    }

    /// OpenRouter normally asks the model to write Markdown links itself. If
    /// an annotation arrives without its URL in the answer, retain that source
    /// explicitly so the durable transcript never loses the citation.
    pub fn textWithCitationLinks(self: *const StreamAccum, allocator: std.mem.Allocator) ![]u8 {
        var missing: usize = 0;
        for (self.citations.items) |citation| {
            if (std.mem.indexOf(u8, self.text.items, citation.url) == null) missing += 1;
        }
        if (missing == 0) return allocator.dupe(u8, self.text.items);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, self.text.items);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.appendSlice(allocator, "\nSources:\n");
        for (self.citations.items) |citation| {
            if (std.mem.indexOf(u8, self.text.items, citation.url) != null) continue;
            try out.appendSlice(allocator, "- ");
            if (citation.title.len > 0) {
                try appendSafeTitle(&out, allocator, citation.title);
                try out.appendSlice(allocator, " — ");
            }
            try out.appendSlice(allocator, citation.url);
            try out.append(allocator, '\n');
        }
        return out.toOwnedSlice(allocator);
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

fn appendSafeTitle(out: *std.ArrayList(u8), allocator: std.mem.Allocator, title: []const u8) !void {
    var previous_space = false;
    for (title[0..@min(title.len, 200)]) |byte| {
        const current = if (byte < 0x20 or byte == 0x7f) ' ' else byte;
        if (current == ' ') {
            if (previous_space) continue;
            previous_space = true;
        } else {
            previous_space = false;
        }
        try out.append(allocator, current);
    }
}

pub fn appendBounded(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    bytes: []const u8,
    limit: usize,
) !void {
    if (bytes.len > limit -| list.items.len) return error.ResponseTooLarge;
    try list.appendSlice(gpa, bytes);
}

// ---------------------------------------------------------------- tests --
