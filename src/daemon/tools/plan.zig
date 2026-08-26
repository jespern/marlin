//! Durable execution-plan updates.

const std = @import("std");
const block = @import("../../core/block.zig");

pub const spec_name = "plan_update";
pub const spec_description =
    "Create or revise the session's durable execution plan. Use for substantial multi-step work; " ++
    "keep exactly one item in_progress while work remains. Every completed item must have been " ++
    "in_progress in the preceding revision; never skip directly from pending to completed.";
pub const spec_schema =
    \\{"type":"object","properties":{"explanation":{"type":"string","maxLength":500},"plan":{"type":"array","minItems":1,"maxItems":12,"items":{"type":"object","properties":{"step":{"type":"string","minLength":1,"maxLength":240},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["step","status"],"additionalProperties":false}}},"required":["plan"],"additionalProperties":false}
;

const max_items: usize = 12;
const max_step_bytes: usize = 240;

const Args = struct {
    explanation: []const u8 = "",
    plan: []const block.PlanItem,
};

pub const Result = struct {
    output: []u8,
    status: block.ToolStatus,
    items: ?[]block.PlanItem = null,
};

pub fn run(gpa: std.mem.Allocator, args_json: []const u8) Result {
    const parsed = std.json.parseFromSlice(Args, gpa, args_json, .{
        .ignore_unknown_fields = false,
    }) catch return fail(gpa, "arguments do not match the schema");
    defer parsed.deinit();

    if (parsed.value.plan.len == 0 or parsed.value.plan.len > max_items)
        return fail(gpa, "requires between one and twelve steps");
    if (parsed.value.explanation.len > 500)
        return fail(gpa, "explanation must be at most 500 bytes");

    var active: usize = 0;
    var pending: usize = 0;
    for (parsed.value.plan, 0..) |item, index| {
        const step = std.mem.trim(u8, item.step, " \t\r\n");
        if (step.len == 0 or step.len > max_step_bytes)
            return fail(gpa, "each step must contain 1–240 bytes");
        if (item.status == .in_progress) active += 1;
        if (item.status == .pending) pending += 1;
        for (parsed.value.plan[0..index]) |prior| {
            if (std.mem.eql(u8, step, std.mem.trim(u8, prior.step, " \t\r\n")))
                return fail(gpa, "steps must be unique");
        }
    }
    if (active > 1) return fail(gpa, "at most one step may be in_progress");
    if (pending > 0 and active != 1)
        return fail(gpa, "exactly one step must be in_progress while work remains");

    const items = gpa.alloc(block.PlanItem, parsed.value.plan.len) catch
        return fail(gpa, "out of memory");
    var initialized: usize = 0;
    for (parsed.value.plan) |item| {
        const step = std.mem.trim(u8, item.step, " \t\r\n");
        items[initialized] = .{
            .step = gpa.dupe(u8, step) catch {
                for (items[0..initialized]) |owned| gpa.free(@constCast(owned.step));
                gpa.free(items);
                return fail(gpa, "out of memory");
            },
            .status = item.status,
        };
        initialized += 1;
    }

    var completed: usize = 0;
    for (items) |item| {
        if (item.status == .completed) completed += 1;
    }
    const output = std.fmt.allocPrint(
        gpa,
        "plan updated: {d}/{d} completed{s}{s}",
        .{
            completed,
            items.len,
            if (parsed.value.explanation.len > 0) " — " else "",
            parsed.value.explanation,
        },
    ) catch {
        for (items) |owned| gpa.free(@constCast(owned.step));
        gpa.free(items);
        return fail(gpa, "out of memory");
    };
    return .{ .output = output, .status = .ok, .items = items };
}

fn fail(gpa: std.mem.Allocator, message: []const u8) Result {
    return .{
        .output = std.fmt.allocPrint(gpa, "error: plan_update {s}", .{message}) catch @panic("oom"),
        .status = .err,
    };
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
