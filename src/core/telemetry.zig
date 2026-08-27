//! Stable OpenTelemetry identifiers derived from Marlin's durable ids.

const std = @import("std");

pub const TraceId = [32]u8;
pub const SpanId = [16]u8;

pub fn traceId(session_id: u64, turn_id: u64) TraceId {
    var out: TraceId = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}{x:0>16}", .{ session_id, turn_id }) catch unreachable;
    return out;
}

pub fn spanId(id: u64) SpanId {
    var out: SpanId = undefined;
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{id}) catch unreachable;
    return out;
}

test "telemetry ids have OTLP widths" {
    const trace = traceId(0x12, 0x34);
    const span = spanId(0x56);
    try std.testing.expectEqualStrings("00000000000000120000000000000034", &trace);
    try std.testing.expectEqualStrings("0000000000000056", &span);
}
