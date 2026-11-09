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
    /// The program's OSC 8 hyperlinks, allowlisted.
    links: []const render.LinkSpan = &.{},
};

const SepList = @FieldType(vt.sgr.Parser, "params_sep");
const max_params = SepList.bit_length;

/// Rows of visible text with style spans and OSC 8 links; other escape
/// sequences are dropped, and a style or link carries across rows as in a
/// terminal. Trailing blank rows are left out.
pub fn rows(arena: std.mem.Allocator, styled: []const u8) ![]Row {
    var out: std.ArrayList(Row) = .empty;
    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(render.SyntaxSpan) = .empty;
    var links: std.ArrayList(render.LinkSpan) = .empty;
    var pen: vt.Style = .{};
    var style: vaxis.Style = .{};
    // The open hyperlink, and where in this row it began.
    var link: ?[]const u8 = null;
    var link_start: usize = 0;
    var i: usize = 0;
    while (i < styled.len) {
        const c = styled[i];
        switch (c) {
            0x1b => {
                var next_link = link;
                i = try escape(styled, i, &pen, &next_link);
                style = shell_term.cellStyle(pen);
                if (!optionalEql(next_link, link)) {
                    if (link) |uri| try closeLink(arena, &links, uri, link_start, text.items.len);
                    link = if (next_link) |uri| try arena.dupe(u8, uri) else null;
                    link_start = text.items.len;
                }
            },
            '\n' => {
                if (link) |uri| try closeLink(arena, &links, uri, link_start, text.items.len);
                link_start = 0;
                try out.append(arena, .{ .text = text.items, .syntax = spans.items, .links = links.items });
                text = .empty;
                spans = .empty;
                links = .empty;
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
    if (link) |uri| try closeLink(arena, &links, uri, link_start, text.items.len);
    if (text.items.len > 0) try out.append(arena, .{ .text = text.items, .syntax = spans.items, .links = links.items });
    var len = out.items.len;
    while (len > 0 and std.mem.trim(u8, out.items[len - 1].text, " ").len == 0) len -= 1;
    return out.items[0..len];
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn closeLink(arena: std.mem.Allocator, links: *std.ArrayList(render.LinkSpan), uri: []const u8, start: usize, end: usize) !void {
    if (end > start and render.allowedLinkUri(uri)) try links.append(arena, .{ .start = start, .end = end, .uri = uri });
}

/// Skip the escape sequence at `start`, applying it to `pen` when it is
/// SGR and to `link` when it is OSC 8. Returns the index just past it.
fn escape(bytes: []const u8, start: usize, pen: *vt.Style, link: *?[]const u8) !usize {
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
            const after: usize = while (end < bytes.len) : (end += 1) {
                if (bytes[end] == 0x07) break end + 1;
                if (bytes[end] == 0x1b and end + 1 < bytes.len and bytes[end + 1] == '\\') break end + 2;
            } else return bytes.len;
            // OSC 8 ; params ; uri — an empty uri closes the link.
            const body = bytes[start + 2 .. end];
            if (std.mem.startsWith(u8, body, "8;")) {
                if (std.mem.indexOfScalarPos(u8, body, 2, ';')) |sep| {
                    const uri = body[sep + 1 ..];
                    link.* = if (uri.len > 0) uri else null;
                }
            }
            return after;
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
