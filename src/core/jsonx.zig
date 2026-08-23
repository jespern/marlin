//! Lenient JSON utilities.
//!
//! Models emit damaged JSON in tool arguments constantly: trailing commas,
//! unbalanced braces, raw newlines in strings, prose before/after the object.
//! Strategy (docs/ARCHITECTURE.md §4): strict parse first; on failure run a
//! bounded repair pass; on repeated failure, hand the parse error back to the
//! model as the tool result — models self-correct.

const std = @import("std");

pub const RepairError = error{Unrecoverable};

/// Attempt to extract/repair a JSON object from model output.
/// Returned slice is allocated with `gpa` (caller frees) unless the input was
/// already valid, in which case the input slice itself is returned.
pub fn repairObject(gpa: std.mem.Allocator, raw: []const u8) RepairError![]const u8 {
    _ = gpa;
    // TODO(M0):
    //   1. fast path: std.json.validate → return raw
    //   2. trim to outermost {...} (drop prose prefix/suffix)
    //   3. strip trailing commas; balance braces/brackets; close dangling string
    //   4. re-validate; else error.Unrecoverable
    return raw;
}

test "valid json passes through" {
    const out = try repairObject(std.testing.allocator, "{\"a\":1}");
    try std.testing.expectEqualStrings("{\"a\":1}", out);
}
