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
        defer gpa.free(name_owned);
        const value_owned = try gpa.dupe(u8, std.mem.trim(u8, entry[equal + 1 ..], " \t"));
        defer gpa.free(value_owned);
        const name = std.Uri.percentDecodeInPlace(name_owned);
        const value = std.Uri.percentDecodeInPlace(value_owned);
        if (name.len == 0 or std.mem.indexOfAny(u8, name, "\r\n:") != null or
            std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidOtelHeaders;
        try headers.append(gpa, try std.fmt.allocPrint(gpa, "{s}: {s}", .{ name, value }));
    }
    return headers.toOwnedSlice(gpa);
}

fn freeHeaders(gpa: std.mem.Allocator, headers: [][]u8) void {
    for (headers) |line| gpa.free(line);
    gpa.free(headers);
}

fn buildTraceRequest(allocator: std.mem.Allocator, trace: TelemetryTrace) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"resourceSpans\":[{\"resource\":{\"attributes\":[");
    try stringAttribute(w, "service.name", "marlin", false);
    try stringAttribute(w, "service.version", build_options.version, true);
    try w.writeAll("]},\"scopeSpans\":[{\"scope\":{\"name\":\"marlin\",\"version\":");
    try std.json.Stringify.encodeJsonString(build_options.version, .{}, w);
    try w.writeAll("},\"spans\":[");

    const trace_id = telemetry_ids.traceId(trace.session_id, trace.turn_id);
    const root_span_id = telemetry_ids.spanId(trace.turn_id);
    try spanPrefix(w, &trace_id, &root_span_id, null, "marlin.turn", 1, trace.started_at_ms, trace.ended_at_ms);
    try stringAttribute(w, "gen_ai.operation.name", "invoke_agent", false);
    try stringAttribute(w, "gen_ai.agent.name", "marlin", true);
    try stringAttribute(w, "gen_ai.request.model", trace.model, true);
    try stringAttribute(w, "marlin.session.kind", trace.session_kind, true);
    try stringAttribute(w, "marlin.turn.outcome", trace.outcome, true);
    try stringAttribute(w, "mirador.trace.tags", "marlin", true);
    var sid_buf: [32]u8 = undefined;
    const sid = try std.fmt.bufPrint(&sid_buf, "{x}", .{trace.session_id});
    try stringAttribute(w, "mirador.trace.attribute.session_id", sid, true);
    try intAttribute(w, "gen_ai.usage.input_tokens", trace.tokens_in, true);
    try intAttribute(w, "gen_ai.usage.output_tokens", trace.tokens_out, true);
    try spanSuffix(w, std.mem.eql(u8, trace.outcome, "error") or std.mem.eql(u8, trace.outcome, "abandoned"));

    for (trace.rounds) |round| {
        try w.writeByte(',');
        try spanPrefix(w, &trace_id, round.span_id, &root_span_id, "chat", 3, round.started_at_ms, round.ended_at_ms);
        try stringAttribute(w, "gen_ai.operation.name", "chat", false);
        try stringAttribute(w, "gen_ai.request.model", trace.model, true);
        if (round.provider.len > 0) try stringAttribute(w, "gen_ai.provider.name", round.provider, true);
        if (round.generation_id.len > 0) try stringAttribute(w, "openrouter.generation.id", round.generation_id, true);
        try intAttribute(w, "gen_ai.usage.input_tokens", round.tokens_in, true);
        try intAttribute(w, "gen_ai.usage.output_tokens", round.tokens_out, true);
        try intAttribute(w, "gen_ai.usage.cached_input_tokens", round.cached_tokens, true);
        try intAttribute(w, "marlin.response.bytes", round.response_bytes, true);
        if (round.first_visible_at_ms > 0 or round.first_byte_at_ms > 0) {
            const first = if (round.first_visible_at_ms > 0) round.first_visible_at_ms else round.first_byte_at_ms;
            try intAttribute(w, "marlin.ttft_ms", @intCast(@max(0, first - round.started_at_ms)), true);
        }
        try spanSuffix(w, !std.mem.eql(u8, round.status, "ok"));
    }

    for (trace.tools) |tool| {
        try w.writeByte(',');
        var name_buf: [160]u8 = undefined;
        const span_name = std.fmt.bufPrint(&name_buf, "execute_tool {s}", .{tool.name}) catch "execute_tool";
        try spanPrefix(w, &trace_id, tool.span_id, &root_span_id, span_name, 1, tool.started_at_ms, tool.ended_at_ms);
        try stringAttribute(w, "gen_ai.operation.name", "execute_tool", false);
        try stringAttribute(w, "gen_ai.tool.name", tool.name, true);
        try stringAttribute(w, "marlin.tool.status", tool.status, true);
        try spanSuffix(w, !std.mem.eql(u8, tool.status, "ok"));
    }

    try w.writeAll("]}]}]}");
    return out.toOwnedSlice();
}

fn spanPrefix(
    w: *std.Io.Writer,
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8,
    name: []const u8,
    kind: u8,
    started_ms: i64,
    ended_ms: i64,
) !void {
    try w.writeAll("{\"traceId\":");
    try std.json.Stringify.encodeJsonString(trace_id, .{}, w);
    try w.writeAll(",\"spanId\":");
    try std.json.Stringify.encodeJsonString(span_id, .{}, w);
    if (parent_span_id) |parent| {
        try w.writeAll(",\"parentSpanId\":");
        try std.json.Stringify.encodeJsonString(parent, .{}, w);
    }
    try w.writeAll(",\"name\":");
    try std.json.Stringify.encodeJsonString(name, .{}, w);
    try w.print(",\"kind\":{d},\"startTimeUnixNano\":\"{d}\",\"endTimeUnixNano\":\"{d}\",\"attributes\":[", .{
        kind,
        started_ms * std.time.ns_per_ms,
        ended_ms * std.time.ns_per_ms,
    });
}

fn spanSuffix(w: *std.Io.Writer, failed: bool) !void {
    try w.writeAll("],\"status\":{\"code\":");
    try w.print("{d}", .{if (failed) @as(u8, 2) else 1});
    try w.writeAll("}}");
}

fn stringAttribute(w: *std.Io.Writer, key: []const u8, value: []const u8, comma: bool) !void {
    if (comma) try w.writeByte(',');
    try w.writeAll("{\"key\":");
    try std.json.Stringify.encodeJsonString(key, .{}, w);
    try w.writeAll(",\"value\":{\"stringValue\":");
    try std.json.Stringify.encodeJsonString(value, .{}, w);
    try w.writeAll("}}");
}

fn intAttribute(w: *std.Io.Writer, key: []const u8, value: u64, comma: bool) !void {
    if (comma) try w.writeByte(',');
    try w.writeAll("{\"key\":");
    try std.json.Stringify.encodeJsonString(key, .{}, w);
    try w.writeAll(",\"value\":{\"intValue\":\"");
    try w.print("{d}", .{value});
    try w.writeAll("\"}}");
}

test "OTLP request contains correlated root, provider, and tool spans without content" {
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
            .provider = "test",
            .generation_id = "gen-1",
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
            .started_at_ms = 20,
            .ended_at_ms = 21,
            .status = "ok",
        }},
    });
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_state.allocator(), json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(std.mem.indexOf(u8, json, "openrouter/test/model") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "execute_tool read_file") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "prompt") == null);
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
