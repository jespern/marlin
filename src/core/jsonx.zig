//! Lenient JSON utilities.
//!
//! Models emit damaged JSON in tool arguments constantly: trailing commas,
//! unbalanced braces, raw newlines inside strings, prose before/after the
//! object. Strategy (docs/ARCHITECTURE.md §4): strict validate first; on
//! failure run a bounded repair pass; if still invalid, the caller feeds the
//! parse error back to the model as the tool result — models self-correct.

const std = @import("std");

pub const RepairError = error{ Unrecoverable, OutOfMemory };

/// Attempt to extract/repair a JSON object from model output.
/// Fast path: input already valid → the input slice itself is returned.
/// Repair path: returns a new slice allocated with `gpa` (caller owns).
pub fn repairObject(gpa: std.mem.Allocator, raw: []const u8) RepairError![]const u8 {
    if (validate(raw)) return raw;

    // 1. Trim to the outermost {...} (drop prose prefix/suffix).
    const first = std.mem.indexOfScalar(u8, raw, '{') orelse return error.Unrecoverable;
    const last = std.mem.lastIndexOfScalar(u8, raw, '}');
    const candidate = if (last != null and last.? > first)
        raw[first .. last.? + 1]
    else
        raw[first..]; // no closing brace at all — repair pass will close it
    if (validate(candidate)) return try gpa.dupe(u8, candidate);

    // 2. Structural repair: walk the candidate tracking string/escape state;
    //    escape raw newlines inside strings, drop trailing commas, then close
    //    any dangling string and unbalanced containers.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var stack: std.ArrayList(u8) = .empty; // open container chars
    defer stack.deinit(gpa);

    var in_string = false;
    var escaped = false;
    for (candidate) |ch| {
        if (in_string) {
            if (escaped) {
                escaped = false;
                try out.append(gpa, ch);
            } else switch (ch) {
                '\\' => {
                    escaped = true;
                    try out.append(gpa, ch);
                },
                '"' => {
                    in_string = false;
                    try out.append(gpa, ch);
                },
                '\n' => try out.appendSlice(gpa, "\\n"),
                '\r' => try out.appendSlice(gpa, "\\r"),
                '\t' => try out.appendSlice(gpa, "\\t"),
                else => try out.append(gpa, ch),
            }
            continue;
        }
        switch (ch) {
            '"' => {
                in_string = true;
                try out.append(gpa, ch);
            },
            '{', '[' => {
                try stack.append(gpa, ch);
                try out.append(gpa, ch);
            },
            '}', ']' => {
                // Drop a trailing comma before a closer.
                trimTrailingComma(&out);
                if (stack.items.len > 0) {
                    const open = stack.items[stack.items.len - 1];
                    const want: u8 = if (open == '{') '}' else ']';
                    if (ch == want) _ = stack.pop();
                    // Mismatched closer: keep it; validation decides.
                }
                try out.append(gpa, ch);
            },
            else => try out.append(gpa, ch),
        }
    }
    // Close dangling string.
    if (in_string) {
        if (escaped) _ = out.pop(); // drop lone trailing backslash
        try out.append(gpa, '"');
    }
    // Drop trailing comma at top of remaining structure, then close stack.
    trimTrailingComma(&out);
    while (stack.pop()) |open| {
        try out.append(gpa, if (open == '{') '}' else ']');
    }

    const repaired = try out.toOwnedSlice(gpa);
    if (validate(repaired)) return repaired;
    gpa.free(repaired);
    return error.Unrecoverable;
}

fn trimTrailingComma(out: *std.ArrayList(u8)) void {
    var i = out.items.len;
    while (i > 0) : (i -= 1) {
        const c = out.items[i - 1];
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') continue;
        if (c == ',') {
            _ = out.orderedRemove(i - 1);
        }
        break;
    }
}

fn validate(s: []const u8) bool {
    return std.json.validate(std.heap.page_allocator, s) catch false;
}

// ---------------------------------------------------------------- tests --
