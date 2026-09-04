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
