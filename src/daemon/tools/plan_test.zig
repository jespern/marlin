//! Unit tests for plan.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in plan.zig.

const std = @import("std");
const block = @import("../../core/block.zig");

const plan = @import("plan.zig");
const run = plan.run;

test {
    std.testing.refAllDecls(plan);
}

test "plan update validates and owns a revision" {
    const gpa = std.testing.allocator;
    const result = run(gpa,
        \\{"explanation":"starting","plan":[{"step":"Inspect","status":"in_progress"},{"step":"Implement","status":"pending"}]}
    );
    defer {
        gpa.free(result.output);
        if (result.items) |items| {
            for (items) |item| gpa.free(@constCast(item.step));
            gpa.free(items);
        }
    }
    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.items.?.len);
    try std.testing.expectEqual(block.PlanStatus.in_progress, result.items.?[0].status);
}

test "plan update rejects two active steps" {
    const gpa = std.testing.allocator;
    const result = run(gpa,
        \\{"plan":[{"step":"One","status":"in_progress"},{"step":"Two","status":"in_progress"}]}
    );
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.err, result.status);
    try std.testing.expect(result.items == null);
}

test "plan update requires an active step while work remains" {
    const gpa = std.testing.allocator;
    const result = run(gpa,
        \\{"plan":[{"step":"One","status":"pending"},{"step":"Two","status":"pending"}]}
    );
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.err, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exactly one") != null);
}
