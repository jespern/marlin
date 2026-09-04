//! Unit tests for telemetry.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in telemetry.zig.

const std = @import("std");

const telemetry = @import("telemetry.zig");
const spanId = telemetry.spanId;
const traceId = telemetry.traceId;

test {
    std.testing.refAllDecls(telemetry);
}

test "telemetry ids have OTLP widths" {
    const trace = traceId(0x12, 0x34);
    const span = spanId(0x56);
    try std.testing.expectEqualStrings("00000000000000120000000000000034", &trace);
    try std.testing.expectEqualStrings("0000000000000056", &span);
}
