//! Unit tests for codex_turn.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in codex_turn.zig.

const std = @import("std");
const Io = std.Io;
const block = @import("../../core/block.zig");
const proto = @import("../../core/proto.zig");
const ids = @import("../../core/ids.zig");
const telemetry_ids = @import("../../core/telemetry.zig");
const config = @import("../../core/config.zig");
const Store = @import("../store.zig").Store;
const process_io = @import("../process_io.zig");
const context = @import("../context.zig");
const approval = @import("../approval.zig");
const permissions = @import("../permissions.zig");
const sandbox = @import("../sandbox.zig");
const provider = @import("../provider/provider.zig");
const anthropic = @import("../provider/anthropic.zig");
const claude_code = @import("../provider/claude_code.zig");
const codex = @import("../provider/codex.zig");
const http = @import("../provider/http.zig");
const build_options = @import("build_options");

const codex_turn = @import("codex_turn.zig");

test {
    std.testing.refAllDecls(codex_turn);
}

test "codex otel overrides stand down for an operator-configured collector" {
    const OtelGuest = @import("../loop.zig").OtelGuest;
    const guest: OtelGuest = .{
        .base_endpoint = "https://otel.mirador.org",
        .headers = "Authorization=Bearer%20marlin",
        .capture_content = true,
    };

    // No collector configured by the operator: Marlin's pass-down applies.
    const applied = codex_turn.otelOverrides(guest, false).?;
    try std.testing.expectEqualStrings("https://otel.mirador.org", applied.base_endpoint);
    try std.testing.expectEqualStrings("Authorization=Bearer%20marlin", applied.headers);
    try std.testing.expect(applied.capture_content);

    // The operator's own [otel] exporter wins outright: overriding just the
    // endpoint would pair Marlin's collector with their Authorization header.
    try std.testing.expect(codex_turn.otelOverrides(guest, true) == null);
    // Marlin not exporting: nothing to pass down either way.
    try std.testing.expect(codex_turn.otelOverrides(null, false) == null);
    try std.testing.expect(codex_turn.otelOverrides(null, true) == null);
}

test "codex app-server requests carry the turn's W3C trace context" {
    const gpa = std.testing.allocator;
    const traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01";
    // Request bodies are arena-owned in production; here too.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var traced_out: std.Io.Writer.Allocating = .init(gpa);
    defer traced_out.deinit();
    try codex_turn.codexRequest(
        arena,
        &traced_out.writer,
        "turn/start",
        7,
        codex.traceFor(traceparent),
        .{ .threadId = "thread-1" },
    );

    const traced = try std.json.parseFromSlice(std.json.Value, gpa, traced_out.written(), .{});
    defer traced.deinit();
    try std.testing.expectEqual(@as(i64, 7), traced.value.object.get("id").?.integer);
    // The app-server reads the JSON-RPC field, not the TRACEPARENT env var:
    // env-only runs produced parentless spans in unrelated trace ids, while
    // this field nests its spans under Marlin's turn span.
    const sent = traced.value.object.get("trace").?.object.get("traceparent").?;
    try std.testing.expectEqualStrings(traceparent, sent.string);
    try std.testing.expectEqualStrings(
        "thread-1",
        traced.value.object.get("params").?.object.get("threadId").?.string,
    );

    // No turn trace: the wire keeps exactly its pre-telemetry shape.
    var untraced_out: std.Io.Writer.Allocating = .init(gpa);
    defer untraced_out.deinit();
    try codex_turn.codexRequest(
        arena,
        &untraced_out.writer,
        "turn/start",
        7,
        codex.traceFor(null),
        .{ .threadId = "thread-1" },
    );
    const untraced = try std.json.parseFromSlice(std.json.Value, gpa, untraced_out.written(), .{});
    defer untraced.deinit();
    try std.testing.expect(untraced.value.object.get("trace") == null);
}
