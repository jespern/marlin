//! A finished shell's output with its colors: VT text from the daemon's
//! ghostty formatter (SGR runs, OSC 8 links, CRLF between rows), turned
//! into plain rows plus style spans for the transcript.
const std = @import("std");
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");
const render = @import("render.zig");
const shell_term = @import("shell_term.zig");

pub const Row = struct {
    text: []const u8,
    syntax: []const render.SyntaxSpan,
};

const SepList = @FieldType(vt.sgr.Parser, "params_sep");
const max_params = SepList.bit_length;

/// Rows of visible text with style spans; escape sequences other than SGR
/// are dropped, and a style carries across rows as in a terminal. Trailing
/// blank rows are left out.
pub fn rows(arena: std.mem.Allocator, styled: []const u8) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(render.SyntaxSpan) = .empty;
    var pen: vt.Style = .{};
    var style: vaxis.Style = .{};
    var i: usize = 0;
    while (i < styled.len) {
        const c = styled[i];
        switch (c) {
            0x1b => {
                i = try escape(styled, i, &pen);
                style = shell_term.cellStyle(pen);
            },
            '\n' => {
                try out.append(arena, .{ .text = text.items, .syntax = spans.items });
                text = .empty;
                spans = .empty;
                i += 1;
            },
            '\r' => i += 1,
            else => {
                var end = i + 1;
                while (end < styled.len and styled[end] != 0x1b and styled[end] != '\n' and styled[end] != '\r') end += 1;
                const start = text.items.len;
                try text.appendSlice(arena, styled[i..end]);
                i = end;
                if (std.meta.eql(style, vaxis.Style{})) continue;
                if (spans.items.len > 0) {
                    const last = &spans.items[spans.items.len - 1];
                    if (last.end == start and std.meta.eql(last.style, style)) {
                        last.end = text.items.len;
                        continue;
                    }
                }
                try spans.append(arena, .{ .start = start, .end = text.items.len, .style = style });
            },
        }
    }
    if (text.items.len > 0) try out.append(arena, .{ .text = text.items, .syntax = spans.items });
    var len = out.items.len;
    while (len > 0 and std.mem.trim(u8, out.items[len - 1].text, " ").len == 0) len -= 1;
    return out.items[0..len];
}

/// Skip the escape sequence at `start`, applying it to `pen` when it is
/// SGR. Returns the index just past it.
fn escape(bytes: []const u8, start: usize, pen: *vt.Style) !usize {
    if (start + 1 >= bytes.len) return bytes.len;
    switch (bytes[start + 1]) {
        '[' => {
            var end = start + 2;
            while (end < bytes.len and (bytes[end] < 0x40 or bytes[end] > 0x7e)) end += 1;
            if (end >= bytes.len) return bytes.len;
            if (bytes[end] == 'm') applySgr(bytes[start + 2 .. end], pen);
            return end + 1;
        },
        ']' => {
            // OSC: up to BEL or ST.
            var end = start + 2;
            while (end < bytes.len) : (end += 1) {
                if (bytes[end] == 0x07) return end + 1;
                if (bytes[end] == 0x1b and end + 1 < bytes.len and bytes[end + 1] == '\\') return end + 2;
            }
            return bytes.len;
        },
        else => return start + 2,
    }
}

fn applySgr(params_text: []const u8, pen: *vt.Style) void {
    var params: [max_params]u16 = undefined;
    var seps: SepList = .empty;
    var count: usize = 0;
    var acc: u16 = 0;
    for (params_text) |c| switch (c) {
        '0'...'9' => acc = acc *| 10 +| (c - '0'),
        ';', ':' => {
            if (count >= max_params - 1) return;
            params[count] = acc;
            if (c == ':') seps.set(count);
            count += 1;
            acc = 0;
        },
        else => return,
    };
    if (params_text.len > 0) {
        params[count] = acc;
        count += 1;
    }
    var parser: vt.sgr.Parser = .{ .params = params[0..count], .params_sep = seps };
    while (parser.next()) |attr| pen.* = pen.withAttribute(attr);
}
