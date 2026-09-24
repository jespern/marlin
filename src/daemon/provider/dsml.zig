//! DeepSeek's textual tool-call markup ("DSML"), as it leaks into assistant
//! text when the model emits tool calls inline instead of through the API's
//! `tool_calls` field. Observed live from deepseek-v4.1-flash via OpenRouter:
//!
//!   <｜DSML｜ calls>
//!   <｜DSML｜ invoke name="bash">
//!   <｜DSML｜ parameter name="command" string="true">git status</｜DSML｜ parameter>
//!   </｜DSML｜ invoke>
//!   </｜DSML｜ calls>
//!
//! The marker is `｜DSML｜` with FULLWIDTH VERTICAL LINE (U+FF5C) on both sides.
//! Partial leaks also happen (a `parameter` tag with its opening `invoke`
//! missing), so recognition is by marker, not by well-formedness.
//!
//! Two uses: `containsMarkup` lets a consumer refuse text that is really a
//! tool call (the handover summarizer), and `extractCalls` recovers complete
//! `invoke` blocks as real tool calls so a native turn can execute them.

const std = @import("std");

pub const marker = "｜DSML｜";

pub fn containsMarkup(text: []const u8) bool {
    return std.mem.indexOf(u8, text, marker) != null;
}

pub const Call = struct {
    name: []const u8,
    /// JSON object of the parameters, arena-owned. String parameters are
    /// JSON strings; a parameter without `string="true"` is emitted raw when
    /// it parses as JSON and as a string otherwise.
    args_json: []const u8,
};

pub const Extracted = struct {
    calls: []const Call,
    /// The text with every complete `<｜DSML｜ calls>…</｜DSML｜ calls>` block
    /// and any stray marker lines removed, trimmed.
    prose: []const u8,
};

/// Recover complete invoke blocks from `text`. Malformed or partial markup
/// yields no calls for that block; its lines are still stripped from `prose`
/// so the leak never reaches the transcript verbatim.
pub fn extractCalls(arena: std.mem.Allocator, text: []const u8) !Extracted {
    var calls: std.ArrayList(Call) = .empty;
    var prose: std.ArrayList(u8) = .empty;

    var cursor: usize = 0;
    while (cursor < text.len) {
        const open = std.mem.indexOfPos(u8, text, cursor, "<" ++ marker ++ " invoke name=\"") orelse break;
        try prose.appendSlice(arena, text[cursor..open]);
        const name_start = open + ("<" ++ marker ++ " invoke name=\"").len;
        const name_end = std.mem.indexOfPos(u8, text, name_start, "\"") orelse break;
        const name = text[name_start..name_end];
        const close_tag = "</" ++ marker ++ " invoke>";
        const invoke_end = std.mem.indexOfPos(u8, text, name_end, close_tag) orelse {
            // Unterminated invoke: drop the rest as leak.
            cursor = text.len;
            break;
        };
        const body = text[name_end + 1 .. invoke_end];
        if (name.len > 0) {
            if (try parseParameters(arena, body)) |args_json| {
                try calls.append(arena, .{ .name = name, .args_json = args_json });
            }
        }
        cursor = invoke_end + close_tag.len;
    }
    if (cursor < text.len) try prose.appendSlice(arena, text[cursor..]);

    // Strip wrapper tags and any leftover marker lines.
    const cleaned = try stripMarkerLines(arena, prose.items);
    return .{ .calls = calls.items, .prose = std.mem.trim(u8, cleaned, " \t\r\n") };
}

/// `<｜DSML｜ parameter name="k" string="true">v</｜DSML｜ parameter>` pairs
/// to a JSON object. Null when any parameter is malformed.
fn parseParameters(arena: std.mem.Allocator, body: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '{');
    var first = true;
    var cursor: usize = 0;
    const open_tag = "<" ++ marker ++ " parameter name=\"";
    const close_tag = "</" ++ marker ++ " parameter>";
    while (std.mem.indexOfPos(u8, body, cursor, open_tag)) |open| {
        const key_start = open + open_tag.len;
        const key_end = std.mem.indexOfPos(u8, body, key_start, "\"") orelse return null;
        const key = body[key_start..key_end];
        const tag_end = std.mem.indexOfPos(u8, body, key_end, ">") orelse return null;
        const attrs = body[key_end..tag_end];
        const is_string = std.mem.indexOf(u8, attrs, "string=\"true\"") != null;
        const value_start = tag_end + 1;
        const value_end = std.mem.indexOfPos(u8, body, value_start, close_tag) orelse return null;
        const value = body[value_start..value_end];
        if (!first) try out.append(arena, ',');
        first = false;
        try appendJsonString(arena, &out, key);
        try out.append(arena, ':');
        if (is_string or !looksLikeJson(value)) {
            try appendJsonString(arena, &out, value);
        } else {
            try out.appendSlice(arena, std.mem.trim(u8, value, " \t\r\n"));
        }
        cursor = value_end + close_tag.len;
    }
    try out.append(arena, '}');
    return out.items;
}

fn looksLikeJson(value: []const u8) bool {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len == 0) return false;
    switch (v[0]) {
        '{', '[', '"', '-', '0'...'9' => {},
        't', 'f', 'n' => {},
        else => return false,
    }
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, v, .{}) catch return false;
    parsed.deinit();
    return true;
}

fn stripMarkerLines(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var wrote_any = false;
    while (it.next()) |line| {
        if (containsMarkup(line)) continue;
        if (wrote_any) try out.append(arena, '\n');
        try out.appendSlice(arena, line);
        wrote_any = true;
    }
    return out.items;
}

/// Append `text` as a JSON string literal (RFC 8259 escaping; other bytes
/// pass through, so valid UTF-8 stays valid).
fn appendJsonString(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '"');
    for (text) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        0x08 => try out.appendSlice(arena, "\\b"),
        0x0c => try out.appendSlice(arena, "\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f => {
            var buf: [6]u8 = undefined;
            try out.appendSlice(arena, try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}));
        },
        else => try out.append(arena, c),
    };
    try out.append(arena, '"');
}
