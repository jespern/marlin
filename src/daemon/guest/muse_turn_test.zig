//! Unit tests for muse_turn.zig: when a Muse turn is over, and how its
//! approvals are answered.
const std = @import("std");
const muse_turn = @import("muse_turn.zig");

test "a turn is over only when Muse is idle with no background work" {
    var tracking = muse_turn.Tracking{ .gpa = std.testing.allocator, .session_id = "s" };
    defer tracking.deinit();
    tracking.turn_running = true;
    try std.testing.expect(!tracking.idle());

    // A subagent launched in a background workflow outlives the turn.
    try tracking.open("wf-1", "workflow");
    try tracking.open("tool-1", "toolCall");
    tracking.close("tool-1");
    tracking.turn_running = false;
    try std.testing.expect(!tracking.idle());
    try std.testing.expect(!tracking.awaiting_follow_up);

    // It finishing makes Muse report back in a turn of its own.
    tracking.close("wf-1");
    try std.testing.expect(tracking.idle());
    try std.testing.expect(tracking.awaiting_follow_up);
}

test "live tool output is passed on once" {
    var tracking = muse_turn.Tracking{ .gpa = std.testing.allocator, .session_id = "s" };
    defer tracking.deinit();
    try std.testing.expectEqualStrings("3 no", try tracking.unseen("t", "3 no"));
    try std.testing.expectEqualStrings("tes.txt\n", try tracking.unseen("t", "3 notes.txt\n"));
    try std.testing.expectEqualStrings("", try tracking.unseen("t", "3 notes.txt\n"));
    tracking.close("t");
}

test "approvals pick a one-off grant, or a refusal" {
    // The choices `muse serve` 1.4.14 offered for a new network host.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\[{"choiceId":"allow_once","label":"Allow once","decision":"approved","scope":"once"},
        \\ {"choiceId":"allow_session","label":"Allow for this session","decision":"approvedForSession","scope":"session"},
        \\ {"choiceId":"allow_local_network","label":"Always allow this network destination","decision":"approvedPolicyAmendment","scope":"localPersistent"},
        \\ {"choiceId":"abort","label":"Reject","decision":"abort","scope":"once","acceptsFeedback":true}]
    , .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("allow_once", muse_turn.pickChoice(parsed.value, true).?);
    try std.testing.expectEqualStrings("abort", muse_turn.pickChoice(parsed.value, false).?);
}
