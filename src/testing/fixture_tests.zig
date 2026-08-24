//! Fixture replay tests: recorded REAL provider SSE streams fed through the
//! sse.Parser → openai_compat.StreamAccum pipeline, at pathological chunk
//! sizes. Regression armor for provider format drift: when OpenRouter/OpenAI
//! change their stream shape, re-record with scripts/record-fixture.sh and
//! these tests tell you exactly what broke.
//!
//! Fixtures live in src/testing/fixtures/sse/ and are embedded at comptime.

const std = @import("std");
const sse = @import("../daemon/provider/sse.zig");
const openai = @import("../daemon/provider/openai_compat.zig");

const completion_fixture = @embedFile("fixtures/sse/completion_text.sse");
const tool_call_fixture = @embedFile("fixtures/sse/tool_call.sse");

fn replay(gpa: std.mem.Allocator, fixture: []const u8, chunk_size: usize) !openai.StreamAccum {
    var acc = openai.StreamAccum.init(gpa);
    errdefer acc.deinit();
    var parser = sse.Parser.init(gpa);
    defer parser.deinit();

    var i: usize = 0;
    while (i < fixture.len) {
        const end = @min(i + chunk_size, fixture.len);
        try parser.feed(fixture[i..end], &acc, pump);
        i = end;
    }
    return acc;
}

fn pump(acc: *openai.StreamAccum, ev: sse.Event) void {
    acc.onEvent(ev);
}

test "real completion fixture: text, finish, usage, DONE — all chunk sizes" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 1, 7, 4096 }) |chunk| {
        var acc = try replay(gpa, completion_fixture, chunk);
        defer acc.deinit();

        try std.testing.expectEqualStrings("fixture test", acc.text.items);
        try std.testing.expectEqual(openai.StreamAccum.FinishReason.stop, acc.finish_reason.?);
        try std.testing.expect(acc.saw_done);
        try std.testing.expect(acc.usage != null);
        try std.testing.expect(acc.usage.?.tokens_in > 0);
        try std.testing.expectEqual(@as(u32, 0), acc.parse_errors);
        try std.testing.expectEqual(@as(usize, 0), acc.calls.items.len);
    }
}

test "real tool-call fixture: reassembled arguments parse as JSON — all chunk sizes" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 1, 13, 4096 }) |chunk| {
        var acc = try replay(gpa, tool_call_fixture, chunk);
        defer acc.deinit();

        try std.testing.expectEqual(openai.StreamAccum.FinishReason.tool_calls, acc.finish_reason.?);
        try std.testing.expectEqual(@as(usize, 1), acc.calls.items.len);
        const call = acc.calls.items[0];
        try std.testing.expectEqualStrings("bash", call.name.items);
        try std.testing.expect(call.call_id.items.len > 0);

        // The reassembled arguments must be valid JSON with a command field.
        const parsed = try std.json.parseFromSlice(
            struct { command: []const u8 },
            gpa,
            call.args.items,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();
        try std.testing.expect(parsed.value.command.len > 0);
        try std.testing.expectEqual(@as(u32, 0), acc.parse_errors);
    }
}
