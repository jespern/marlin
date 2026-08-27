//! Best-effort OTLP/HTTP trace export from the durable telemetry outbox.
//! The worker owns its HTTP pool and never participates in turn completion.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");

const telemetry_ids = @import("../core/telemetry.zig");
const Store = @import("store.zig").Store;
const TelemetryTrace = @import("store.zig").TelemetryTrace;
const http = @import("provider/http.zig");

pub const Exporter = struct {
    gpa: std.mem.Allocator,
    io: Io,
    store: *Store,
    endpoint: [:0]u8,
    headers: [][]u8,
    pool: http.Pool,
    active: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    thread: std.Thread,

    /// Standard OTEL environment variables make export opt-in without putting
    /// collector credentials in Marlin's config file.
    pub fn start(
        gpa: std.mem.Allocator,
        io: Io,
        store: *Store,
        environ: *const std.process.Environ.Map,
    ) !?*Exporter {
        return startConfigured(gpa, io, store, environ, .{
            .endpoint = environ.get("OTEL_EXPORTER_OTLP_ENDPOINT") orelse "",
            .traces_endpoint = environ.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT") orelse "",
            .headers = environ.get("OTEL_EXPORTER_OTLP_HEADERS") orelse "",
        });
    }

    pub const Config = struct {
        endpoint: []const u8 = "",
        traces_endpoint: []const u8 = "",
        headers: []const u8 = "",
    };

    pub fn startConfigured(
        gpa: std.mem.Allocator,
        io: Io,
        store: *Store,
        environ: *const std.process.Environ.Map,
        config: Config,
    ) !?*Exporter {
        const traces_endpoint = std.mem.trim(u8, config.traces_endpoint, " \t\r\n");
        const base_endpoint = std.mem.trim(u8, config.endpoint, " \t\r\n");
        const raw = if (traces_endpoint.len > 0) traces_endpoint else base_endpoint;
        if (raw.len == 0) return null;

        const endpoint = try buildEndpoint(gpa, raw, traces_endpoint.len > 0);
        errdefer gpa.free(endpoint);
        const headers = try parseHeaders(gpa, config.headers);
        errdefer freeHeaders(gpa, headers);
        var pool = try http.Pool.init(gpa, io, environ);
        errdefer pool.deinit();
        const self = try gpa.create(Exporter);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .store = store,
            .endpoint = endpoint,
            .headers = headers,
            .pool = pool,
            .thread = undefined,
        };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            self.pool.deinit();
            freeHeaders(gpa, headers);
            gpa.free(endpoint);
            gpa.destroy(self);
            return err;
        };
        return self;
    }

    pub fn activate(self: *Exporter) void {
        self.active.store(true, .release);
    }

    pub fn deinit(self: *Exporter) void {
        self.stop.store(true, .release);
        self.thread.join();
        self.pool.deinit();
        freeHeaders(self.gpa, self.headers);
        self.gpa.free(self.endpoint);
        const gpa = self.gpa;
        self.* = undefined;
        gpa.destroy(self);
    }

    fn run(self: *Exporter) void {
        while (!self.stop.load(.acquire) and !self.active.load(.acquire)) self.pause(10);
        while (!self.stop.load(.acquire)) {
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const now = nowMs(self.io);
            const trace = self.store.nextTelemetryTrace(arena, now) catch |err| {
                std.log.warn("OTLP outbox read failed: {t}", .{err});
                self.pause(5_000);
                continue;
            } orelse {
                self.pause(500);
                continue;
            };
            const body = buildTraceRequest(arena, trace) catch |err| {
                self.recordFailure(trace, now, @errorName(err));
                self.pause(1_000);
                continue;
            };
            var client = self.pool.acquire() catch |err| {
                self.recordFailure(trace, now, @errorName(err));
                self.pause(1_000);
                continue;
            };
            defer client.deinit();
            const response = client.streamPost(self.gpa, .{
                .url = self.endpoint,
                .bearer = null,
                .body_json = body,
                .extra_headers = self.headers,
                .connect_timeout_ms = 10_000,
                .response_head_timeout_ms = 15_000,
                .idle_timeout_ms = 15_000,
                .total_timeout_ms = 30_000,
                .cancel = &self.stop,
            }, {}, discard) catch |err| {
                if (self.stop.load(.acquire)) return;
                self.recordFailure(trace, now, @errorName(err));
                self.pause(1_000);
                continue;
            };
            defer if (response.error_body) |bytes| self.gpa.free(bytes);
            if (response.status >= 200 and response.status < 300) {
                self.store.markTelemetryExported(trace.session_id, trace.turn_id, nowMs(self.io)) catch |err|
                    std.log.warn("could not acknowledge OTLP export: {t}", .{err});
            } else {
                var status_buf: [32]u8 = undefined;
                const message = std.fmt.bufPrint(&status_buf, "HTTP {d}", .{response.status}) catch "HTTP error";
                self.recordFailure(trace, now, message);
                self.pause(1_000);
            }
        }
    }

    fn recordFailure(self: *Exporter, trace: TelemetryTrace, now: i64, message: []const u8) void {
        // Fixed bounded retry keeps a broken collector completely off the
        // interactive hot path while retaining every durable span.
        self.store.markTelemetryExportFailed(
            trace.session_id,
            trace.turn_id,
            now + 30_000,
            message,
        ) catch |err| std.log.warn("could not record OTLP failure: {t}", .{err});
    }

    fn pause(self: *Exporter, millis: i64) void {
        var remaining = millis;
        while (remaining > 0 and !self.stop.load(.acquire)) {
            const slice = @min(remaining, 100);
            self.io.sleep(.fromMilliseconds(slice), .awake) catch return;
            remaining -= slice;
        }
    }
};

fn discard(_: void, _: []const u8) bool {
    return true;
}

fn nowMs(io: Io) i64 {
    return @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}

fn buildEndpoint(gpa: std.mem.Allocator, raw: []const u8, traces_specific: bool) ![:0]u8 {
    const uri = std.Uri.parse(raw) catch return error.InvalidOtelEndpoint;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
        !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidOtelEndpoint;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    _ = uri.getHost(&host_buf) catch return error.InvalidOtelEndpoint;

    if (traces_specific or std.mem.endsWith(u8, raw, "/v1/traces"))
        return std.fmt.allocPrintSentinel(gpa, "{s}", .{raw}, 0);
    return std.fmt.allocPrintSentinel(gpa, "{s}/v1/traces", .{std.mem.trimEnd(u8, raw, "/")}, 0);
}

fn parseHeaders(gpa: std.mem.Allocator, raw: []const u8) ![][]u8 {
    var headers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (headers.items) |line| gpa.free(line);
        headers.deinit(gpa);
    }
    var entries = std.mem.splitScalar(u8, raw, ',');
    while (entries.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;
        const equal = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidOtelHeaders;
        const name_owned = try gpa.dupe(u8, std.mem.trim(u8, entry[0..equal], " \t"));
        defer {
            @memset(name_owned, 0);
            gpa.free(name_owned);
        }
        const value_owned = try gpa.dupe(u8, std.mem.trim(u8, entry[equal + 1 ..], " \t"));
        defer {
            @memset(value_owned, 0);
            gpa.free(value_owned);
        }
        const name = std.Uri.percentDecodeInPlace(name_owned);
        const value = std.Uri.percentDecodeInPlace(value_owned);
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "\r\n:") != null or
            std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidOtelHeaders;
        try headers.append(gpa, try std.fmt.allocPrint(gpa, "{s}: {s}", .{ name, value }));
    }
    return headers.toOwnedSlice(gpa);
}

fn freeHeaders(gpa: std.mem.Allocator, headers: [][]u8) void {
    for (headers) |line| {
        @memset(line, 0);
        gpa.free(line);
    }
    gpa.free(headers);
}

const OtlpAnyValue = struct {
    stringValue: ?[]const u8 = null,
    intValue: ?[]const u8 = null,
    boolValue: ?bool = null,
    doubleValue: ?f64 = null,
    arrayValue: ?OtlpArrayValue = null,
};

const OtlpArrayValue = struct {
    values: []const OtlpAnyValue,
};

const OtlpKeyValue = struct {
    key: []const u8,
    value: OtlpAnyValue,
};

const OtlpStatus = struct {
    code: u8,
};

const OtlpSpan = struct {
    traceId: []const u8,
    spanId: []const u8,
    parentSpanId: ?[]const u8 = null,
    name: []const u8,
    kind: u8,
    startTimeUnixNano: []const u8,
    endTimeUnixNano: []const u8,
    attributes: []const OtlpKeyValue,
    status: ?OtlpStatus = null,
};

const OtlpScope = struct {
    name: []const u8,
    version: []const u8,
};

const OtlpScopeSpans = struct {
    scope: OtlpScope,
    spans: []const OtlpSpan,
};

const OtlpResource = struct {
    attributes: []const OtlpKeyValue,
};

const OtlpResourceSpans = struct {
    resource: OtlpResource,
    scopeSpans: []const OtlpScopeSpans,
};

const OtlpTraceRequest = struct {
    resourceSpans: []const OtlpResourceSpans,
};

fn buildTraceRequest(allocator: std.mem.Allocator, trace: TelemetryTrace) ![]u8 {
    const trace_id = telemetry_ids.traceId(trace.session_id, trace.turn_id);
    const root_span_id = telemetry_ids.spanId(trace.turn_id);
    const conversation_id = try std.fmt.allocPrint(allocator, "{x}", .{trace.session_id});

    var spans: std.ArrayList(OtlpSpan) = .empty;
    var root_attributes: std.ArrayList(OtlpKeyValue) = .empty;
    try root_attributes.append(allocator, stringKeyValue("marlin.session.kind", trace.session_kind));
    try root_attributes.append(allocator, stringKeyValue("marlin.turn.outcome", trace.outcome));
    try root_attributes.append(allocator, stringKeyValue("mirador.trace.tags", "marlin"));
    try root_attributes.append(allocator, stringKeyValue("mirador.trace.attribute.session_id", conversation_id));
    const root_failed = std.mem.eql(u8, trace.outcome, "error") or std.mem.eql(u8, trace.outcome, "abandoned");
    if (root_failed) try root_attributes.append(allocator, stringKeyValue("error.type", trace.outcome));
    try spans.append(allocator, try makeSpan(
        allocator,
        &trace_id,
        &root_span_id,
        null,
        "marlin.turn",
        1,
        trace.started_at_ms,
        trace.ended_at_ms,
        root_attributes.items,
        root_failed,
    ));

    for (trace.rounds) |round| {
        const request_model = if (round.request_model.len > 0) round.request_model else trace.model;
        const provider_name = if (round.provider_name.len > 0) round.provider_name else "unknown";
        const span_name = try std.fmt.allocPrint(allocator, "chat {s}", .{request_model});
        var attributes: std.ArrayList(OtlpKeyValue) = .empty;
        try attributes.append(allocator, stringKeyValue("gen_ai.operation.name", "chat"));
        try attributes.append(allocator, stringKeyValue("gen_ai.provider.name", provider_name));
        try attributes.append(allocator, stringKeyValue("gen_ai.conversation.id", conversation_id));
        try attributes.append(allocator, stringKeyValue("gen_ai.request.model", request_model));
        try attributes.append(allocator, boolKeyValue("gen_ai.request.stream", true));
        if (round.max_tokens > 0)
            try attributes.append(allocator, try intKeyValue(allocator, "gen_ai.request.max_tokens", round.max_tokens));
        if (round.reasoning_level.len > 0)
            try attributes.append(allocator, stringKeyValue("gen_ai.request.reasoning.level", round.reasoning_level));
        if (round.server_address.len > 0) {
            try attributes.append(allocator, stringKeyValue("server.address", round.server_address));
            try attributes.append(allocator, try intKeyValue(allocator, "server.port", round.server_port));
        }
        if (round.generation_id.len > 0)
            try attributes.append(allocator, stringKeyValue("gen_ai.response.id", round.generation_id));
        if (round.response_model.len > 0)
            try attributes.append(allocator, stringKeyValue("gen_ai.response.model", round.response_model));
        if (round.finish_reason.len > 0)
            try attributes.append(allocator, try stringArrayKeyValue(allocator, "gen_ai.response.finish_reasons", &.{round.finish_reason}));
        if (round.first_byte_at_ms > 0)
            try attributes.append(allocator, doubleKeyValue(
                "gen_ai.response.time_to_first_chunk",
                @as(f64, @floatFromInt(@max(0, round.first_byte_at_ms - round.started_at_ms))) / 1000.0,
            ));
        if (round.usage_available) {
            try attributes.append(allocator, try intKeyValue(allocator, "gen_ai.usage.input_tokens", round.tokens_in));
            try attributes.append(allocator, try intKeyValue(allocator, "gen_ai.usage.output_tokens", round.tokens_out));
        }
        if (round.provider.len > 0 and !std.mem.eql(u8, round.provider, provider_name))
            try attributes.append(allocator, stringKeyValue("marlin.provider.backend", round.provider));
        if (round.cached_tokens > 0)
            try attributes.append(allocator, try intKeyValue(allocator, "gen_ai.usage.cache_read.input_tokens", round.cached_tokens));
        if (round.cache_write_tokens > 0)
            try attributes.append(allocator, try intKeyValue(allocator, "gen_ai.usage.cache_write.input_tokens", round.cache_write_tokens));
        if (round.reasoning_tokens > 0)
            try attributes.append(allocator, try intKeyValue(allocator, "gen_ai.usage.reasoning.output_tokens", round.reasoning_tokens));
        try attributes.append(allocator, try intKeyValue(allocator, "marlin.response.bytes", round.response_bytes));
        if (round.first_visible_at_ms > 0)
            try attributes.append(allocator, try intKeyValue(
                allocator,
                "marlin.time_to_first_visible_ms",
                @intCast(@max(0, round.first_visible_at_ms - round.started_at_ms)),
            ));
        const round_failed = !std.mem.eql(u8, round.status, "ok");
        if (round_failed) {
            const error_type = if (round.http_status >= 400)
                try std.fmt.allocPrint(allocator, "{d}", .{round.http_status})
            else
                round.status;
            try attributes.append(allocator, stringKeyValue("error.type", error_type));
        }
        try spans.append(allocator, try makeSpan(
            allocator,
            &trace_id,
            round.span_id,
            &root_span_id,
            span_name,
            3,
            round.started_at_ms,
            round.ended_at_ms,
            attributes.items,
            round_failed,
        ));
    }

    for (trace.tools) |tool| {
        const parent_span_id = for (trace.rounds) |round| {
            if (round.round == tool.round) break round.span_id;
        } else &root_span_id;
        const span_name = try std.fmt.allocPrint(allocator, "execute_tool {s}", .{tool.name});
        var attributes: std.ArrayList(OtlpKeyValue) = .empty;
        try attributes.append(allocator, stringKeyValue("gen_ai.operation.name", "execute_tool"));
        try attributes.append(allocator, stringKeyValue("gen_ai.tool.name", tool.name));
        try attributes.append(allocator, stringKeyValue("gen_ai.agent.name", "marlin"));
        if (tool.call_id.len > 0)
            try attributes.append(allocator, stringKeyValue("gen_ai.tool.call.id", tool.call_id));
        if (tool.description.len > 0)
            try attributes.append(allocator, stringKeyValue("gen_ai.tool.description", tool.description));
        try attributes.append(allocator, stringKeyValue("gen_ai.tool.type", "function"));
        const failed = !std.mem.eql(u8, tool.status, "ok");
        if (failed) try attributes.append(allocator, stringKeyValue("error.type", tool.status));
        try spans.append(allocator, try makeSpan(
            allocator,
            &trace_id,
            tool.span_id,
            parent_span_id,
            span_name,
            1,
            tool.started_at_ms,
            tool.ended_at_ms,
            attributes.items,
            failed,
        ));
    }

    const resource_attributes = [_]OtlpKeyValue{
        stringKeyValue("service.name", "marlin"),
        stringKeyValue("service.version", build_options.version),
    };
    const scope_spans = [_]OtlpScopeSpans{.{
        .scope = .{ .name = "marlin", .version = build_options.version },
        .spans = spans.items,
    }};
    const resource_spans = [_]OtlpResourceSpans{.{
        .resource = .{ .attributes = &resource_attributes },
        .scopeSpans = &scope_spans,
    }};
    return std.json.Stringify.valueAlloc(allocator, OtlpTraceRequest{
        .resourceSpans = &resource_spans,
    }, .{
        .emit_null_optional_fields = false,
        .emit_nonportable_numbers_as_strings = true,
    });
}

fn makeSpan(
    allocator: std.mem.Allocator,
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8,
    name: []const u8,
    kind: u8,
    started_ms: i64,
    ended_ms: i64,
    attributes: []const OtlpKeyValue,
    failed: bool,
) !OtlpSpan {
    return .{
        .traceId = trace_id,
        .spanId = span_id,
        .parentSpanId = parent_span_id,
        .name = name,
        .kind = kind,
        .startTimeUnixNano = try std.fmt.allocPrint(allocator, "{d}", .{started_ms * std.time.ns_per_ms}),
        .endTimeUnixNano = try std.fmt.allocPrint(allocator, "{d}", .{ended_ms * std.time.ns_per_ms}),
        .attributes = attributes,
        .status = if (failed) .{ .code = 2 } else null,
    };
}

fn stringKeyValue(key: []const u8, value: []const u8) OtlpKeyValue {
    return .{ .key = key, .value = .{ .stringValue = value } };
}

fn intKeyValue(allocator: std.mem.Allocator, key: []const u8, value: u64) !OtlpKeyValue {
    return .{ .key = key, .value = .{ .intValue = try std.fmt.allocPrint(allocator, "{d}", .{value}) } };
}

fn boolKeyValue(key: []const u8, value: bool) OtlpKeyValue {
    return .{ .key = key, .value = .{ .boolValue = value } };
}

fn doubleKeyValue(key: []const u8, value: f64) OtlpKeyValue {
    return .{ .key = key, .value = .{ .doubleValue = value } };
}

fn stringArrayKeyValue(
    allocator: std.mem.Allocator,
    key: []const u8,
    values: []const []const u8,
) !OtlpKeyValue {
    const encoded = try allocator.alloc(OtlpAnyValue, values.len);
    for (values, encoded) |value, *item| item.* = .{ .stringValue = value };
    return .{ .key = key, .value = .{ .arrayValue = .{ .values = encoded } } };
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

fn spanAttribute(span: std.json.Value, key: []const u8) ?std.json.Value {
    const attributes = span.object.get("attributes") orelse return null;
    for (attributes.array.items) |attribute| {
        const attribute_key = attribute.object.get("key") orelse continue;
        if (attribute_key == .string and std.mem.eql(u8, attribute_key.string, key))
            return attribute.object.get("value");
    }
    return null;
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
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), json, .{});
    defer parsed.deinit();
    const spans = traceSpans(parsed.value);
    try std.testing.expectEqual(@as(usize, 3), spans.len);

    const root = spanNamed(spans, "marlin.turn");
    try std.testing.expectEqual(@as(i64, 1), root.object.get("kind").?.integer);
    try std.testing.expect(spanAttribute(root.*, "gen_ai.operation.name") == null);
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
    });
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
