//! Terminal-native Markdown rendering for the Marlin TUI.

const std = @import("std");
const vaxis = @import("vaxis");
const render = @import("render.zig");
const Palette = render.Palette;
const LinkSpan = render.LinkSpan;
const SyntaxSpan = render.SyntaxSpan;
const Line = render.Line;
const lineText = render.lineText;
const SyntaxLanguage = render.SyntaxLanguage;
const appendSyntaxSpan = render.appendSyntaxSpan;
const syntaxSpans = render.syntaxSpans;
const isUrlStart = render.isUrlStart;
const findLinkSpans = render.findLinkSpans;
const linksForChunk = render.linksForChunk;
const blankLine = render.blankLine;
const wrapPrefixed = render.wrapPrefixed;
const displayWidth = render.displayWidth;
const hardCellBreak = render.hardCellBreak;
const wordBreak = render.wordBreak;
const spaces = render.spaces;
const appendGlyphNTimes = render.appendGlyphNTimes;

pub const InlineMarkdown = struct {
    text: []const u8,
    styles: []const SyntaxSpan,
    links: []const LinkSpan,
};

pub fn appendInlineStyle(
    arena: std.mem.Allocator,
    styles: *std.ArrayList(SyntaxSpan),
    start: usize,
    end: usize,
    style: vaxis.Style,
) !void {
    if (start < end) try styles.append(arena, .{ .start = start, .end = end, .style = style });
}

/// Small, deliberately conservative inline Markdown pass. It removes the
/// punctuation users do not want to read in a terminal while retaining
/// emphasis, inline-code styling, and safe HTTP(S) link metadata.
pub fn inlineMarkdown(arena: std.mem.Allocator, source: []const u8) !InlineMarkdown {
    var out: std.ArrayList(u8) = .empty;
    var styles: std.ArrayList(SyntaxSpan) = .empty;
    var links: std.ArrayList(LinkSpan) = .empty;
    var i: usize = 0;
    while (i < source.len) {
        if (std.mem.startsWith(u8, source[i..], "**") or std.mem.startsWith(u8, source[i..], "__")) {
            const delimiter = source[i .. i + 2];
            if (std.mem.indexOfPos(u8, source, i + 2, delimiter)) |close| {
                const start = out.items.len;
                try out.appendSlice(arena, source[i + 2 .. close]);
                try appendInlineStyle(arena, &styles, start, out.items.len, .{ .bold = true });
                i = close + 2;
                continue;
            }
        }
        if (std.mem.startsWith(u8, source[i..], "~~")) {
            if (std.mem.indexOfPos(u8, source, i + 2, "~~")) |close| {
                const start = out.items.len;
                try out.appendSlice(arena, source[i + 2 .. close]);
                try appendInlineStyle(arena, &styles, start, out.items.len, .{ .strikethrough = true });
                i = close + 2;
                continue;
            }
        }
        if (source[i] == '*' or source[i] == '_') {
            if (std.mem.indexOfScalarPos(u8, source, i + 1, source[i])) |close| {
                const valid_underscore = source[i] != '_' or
                    ((i == 0 or !std.ascii.isAlphanumeric(source[i - 1])) and
                        (close + 1 == source.len or !std.ascii.isAlphanumeric(source[close + 1])));
                if (close > i + 1 and valid_underscore) {
                    const start = out.items.len;
                    try out.appendSlice(arena, source[i + 1 .. close]);
                    try appendInlineStyle(arena, &styles, start, out.items.len, .{ .italic = true });
                    i = close + 1;
                    continue;
                }
            }
        }
        if (source[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, source, i + 1, '`')) |close| {
                const start = out.items.len;
                try out.appendSlice(arena, source[i + 1 .. close]);
                try appendInlineStyle(arena, &styles, start, out.items.len, Palette.md_code);
                i = close + 1;
                continue;
            }
        }
        if (source[i] == '[') {
            if (std.mem.indexOfPos(u8, source, i + 1, "](")) |label_end| {
                const uri_start = label_end + 2;
                if (std.mem.indexOfScalarPos(u8, source, uri_start, ')')) |uri_end| {
                    const uri = source[uri_start..uri_end];
                    if (isUrlStart(uri, 0)) {
                        const start = out.items.len;
                        try out.appendSlice(arena, source[i + 1 .. label_end]);
                        try links.append(arena, .{ .start = start, .end = out.items.len, .uri = uri });
                        i = uri_end + 1;
                        continue;
                    }
                }
            }
        }
        if (source[i] == '\\' and i + 1 < source.len and
            std.mem.indexOfScalar(u8, "\\`*_~[]", source[i + 1]) != null)
        {
            try out.append(arena, source[i + 1]);
            i += 2;
            continue;
        }
        try out.append(arena, source[i]);
        i += 1;
    }

    // Plain URLs remain clickable after the Markdown punctuation is removed.
    const plain_links = try findLinkSpans(arena, out.items);
    try links.appendSlice(arena, plain_links);
    return .{ .text = out.items, .styles = styles.items, .links = links.items };
}

pub fn stylesForChunk(
    arena: std.mem.Allocator,
    source: []const SyntaxSpan,
    chunk_start: usize,
    chunk_end: usize,
    prefix_len: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    for (source) |span| {
        const start = @max(span.start, chunk_start);
        const end = @min(span.end, chunk_end);
        if (start < end) try spans.append(arena, .{
            .start = prefix_len + start - chunk_start,
            .end = prefix_len + end - chunk_start,
            .style = span.style,
        });
    }
    return spans.items;
}

pub const markdown_gutter = "  ";
pub const markdown_max_body_width: usize = 112;
pub fn markdownGutter(width: usize) []const u8 {
    return if (width >= 32) markdown_gutter else "";
}

pub fn markdownMeasure(width: usize) usize {
    const gutter_width = displayWidth(markdownGutter(width));
    return @min(width, markdown_max_body_width + gutter_width);
}

/// Hard cell-width break that always lands on a grapheme boundary.
pub fn appendMarkdownLine(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    raw: []const u8,
    first_prefix: []const u8,
    continuation_prefix: []const u8,
    base_style: vaxis.Style,
    width: usize,
) !void {
    const rendered = try inlineMarkdown(arena, raw);
    if (rendered.text.len == 0) {
        try lines.append(arena, .{ .text = first_prefix, .style = base_style });
        return;
    }

    var start: usize = 0;
    var first = true;
    while (start < rendered.text.len) {
        const line_prefix = if (first) first_prefix else continuation_prefix;
        const body_width = width -| displayWidth(line_prefix);
        if (body_width == 0) return;
        var end = wordBreak(rendered.text, start, body_width);
        if (end == start) end = hardCellBreak(rendered.text, start, body_width);
        const chunk = rendered.text[start..end];
        const full = if (line_prefix.len > 0)
            try std.fmt.allocPrint(arena, "{s}{s}", .{ line_prefix, chunk })
        else
            chunk;
        try lines.append(arena, .{
            .text = full,
            .style = base_style,
            .links = try linksForChunk(arena, rendered.links, start, end, line_prefix.len),
            .syntax = try stylesForChunk(arena, rendered.styles, start, end, line_prefix.len),
            .links_resolved = true,
        });
        first = false;
        start = end;
        while (start < rendered.text.len and (rendered.text[start] == ' ' or rendered.text[start] == '\t')) start += 1;
    }
}

pub fn tableCells(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') == null) return &.{};
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];
    var cells: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '|');
    while (it.next()) |cell| try cells.append(arena, std.mem.trim(u8, cell, " \t\r"));
    return cells.items;
}

pub fn isTableDelimiter(arena: std.mem.Allocator, raw: []const u8) !bool {
    const cells = try tableCells(arena, raw);
    if (cells.len == 0) return false;
    for (cells) |cell| {
        var dashes: usize = 0;
        for (cell) |c| switch (c) {
            '-' => dashes += 1,
            ':', ' ', '\t' => {},
            else => return false,
        };
        if (dashes < 3) return false;
    }
    return true;
}

pub const TableBorder = enum { top, middle, bottom };

pub fn appendTableBorder(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    widths: []const usize,
    gutter: []const u8,
    border: TableBorder,
) !void {
    var out: std.ArrayList(u8) = .empty;
    const left: []const u8 = switch (border) {
        .top => "╭",
        .middle => "├",
        .bottom => "╰",
    };
    const joint: []const u8 = switch (border) {
        .top => "┬",
        .middle => "┼",
        .bottom => "┴",
    };
    const right: []const u8 = switch (border) {
        .top => "╮",
        .middle => "┤",
        .bottom => "╯",
    };
    try out.appendSlice(arena, left);
    for (widths, 0..) |column_width, column| {
        if (column > 0) try out.appendSlice(arena, joint);
        try appendGlyphNTimes(arena, &out, "─", column_width + 2);
    }
    try out.appendSlice(arena, right);
    try lines.append(arena, .{
        .text = gutter,
        .style = .{},
        .text2 = out.items,
        .style2 = Palette.md_table_border,
        .links_resolved = true,
    });
}

pub fn appendTranslatedInline(
    arena: std.mem.Allocator,
    styles: *std.ArrayList(SyntaxSpan),
    links: *std.ArrayList(LinkSpan),
    rendered: InlineMarkdown,
    start: usize,
    end: usize,
    output_offset: usize,
) !void {
    for (rendered.styles) |span| {
        const span_start = @max(span.start, start);
        const span_end = @min(span.end, end);
        if (span_start < span_end) try styles.append(arena, .{
            .start = output_offset + span_start - start,
            .end = output_offset + span_end - start,
            .style = span.style,
        });
    }
    for (rendered.links) |link| {
        const link_start = @max(link.start, start);
        const link_end = @min(link.end, end);
        if (link_start < link_end) try links.append(arena, .{
            .start = output_offset + link_start - start,
            .end = output_offset + link_end - start,
            .uri = link.uri,
        });
    }
}

pub fn appendTableRow(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    cells: []const []const u8,
    widths: []const usize,
    gutter: []const u8,
    style: vaxis.Style,
) !void {
    const rendered = try arena.alloc(InlineMarkdown, widths.len);
    const positions = try arena.alloc(usize, widths.len);
    @memset(positions, 0);
    for (rendered, 0..) |*cell, column| {
        cell.* = try inlineMarkdown(arena, if (column < cells.len) cells[column] else "");
    }

    var first_visual = true;
    while (true) {
        var remaining = false;
        for (rendered, positions) |cell, position| {
            if (position < cell.text.len) {
                remaining = true;
                break;
            }
        }
        if (!first_visual and !remaining) break;

        var out: std.ArrayList(u8) = .empty;
        var styles: std.ArrayList(SyntaxSpan) = .empty;
        var links: std.ArrayList(LinkSpan) = .empty;
        try out.appendSlice(arena, "│ ");
        for (widths, 0..) |column_width, column| {
            if (column > 0) try out.appendSlice(arena, " │ ");
            const cell = rendered[column];
            const start = positions[column];
            var end = if (start < cell.text.len) wordBreak(cell.text, start, column_width) else start;
            if (end == start and start < cell.text.len) end = hardCellBreak(cell.text, start, column_width);
            const output_offset = gutter.len + out.items.len;
            try out.appendSlice(arena, cell.text[start..end]);
            try appendTranslatedInline(arena, &styles, &links, cell, start, end, output_offset);
            const used = displayWidth(cell.text[start..end]);
            if (used < column_width) try out.appendNTimes(arena, ' ', column_width - used);
            positions[column] = end;
            while (positions[column] < cell.text.len and
                (cell.text[positions[column]] == ' ' or cell.text[positions[column]] == '\t'))
            {
                positions[column] += 1;
            }
        }
        try out.appendSlice(arena, " │");
        {
            var pos: usize = 0;
            while (std.mem.indexOfPos(u8, out.items, pos, "│")) |sep| {
                try appendSyntaxSpan(arena, &styles, sep, sep + "│".len, gutter.len, Palette.md_table_border);
                pos = sep + "│".len;
            }
        }
        try lines.append(arena, .{
            .text = gutter,
            .style = .{},
            .text2 = out.items,
            .style2 = style,
            .syntax = styles.items,
            .links = links.items,
            .links_resolved = true,
        });
        first_visual = false;
    }
}

pub fn appendTable(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    logical: []const []const u8,
    start: usize,
    end: usize,
    measure: usize,
    gutter: []const u8,
) !void {
    const header = try tableCells(arena, logical[start]);
    if (header.len == 0) return;
    const widths = try arena.alloc(usize, header.len);
    @memset(widths, 1);
    var row = start;
    while (row < end) : (row += 1) {
        if (row == start + 1) continue;
        const cells = try tableCells(arena, logical[row]);
        for (cells[0..@min(cells.len, widths.len)], 0..) |cell_raw, column| {
            const cell = try inlineMarkdown(arena, cell_raw);
            widths[column] = @max(widths[column], @min(displayWidth(cell.text), 36));
        }
    }

    const overhead = displayWidth(gutter) + 3 * widths.len + 1;
    const available = @max(widths.len, measure -| overhead);
    const minimum = @max(@as(usize, 1), @min(@as(usize, 6), available / widths.len));
    for (widths) |*column_width| column_width.* = @max(column_width.*, minimum);
    while (true) {
        var sum: usize = 0;
        for (widths) |column_width| sum += column_width;
        if (sum <= available) break;
        var widest: ?usize = null;
        for (widths, 0..) |column_width, column| {
            if (column_width > minimum and (widest == null or column_width > widths[widest.?])) widest = column;
        }
        if (widest) |column| {
            widths[column] -= 1;
        } else break;
    }

    try appendTableBorder(arena, lines, widths, gutter, .top);
    try appendTableRow(arena, lines, header, widths, gutter, Palette.md_table_header);
    try appendTableBorder(arena, lines, widths, gutter, .middle);
    row = start + 2;
    while (row < end) : (row += 1) {
        try appendTableRow(arena, lines, try tableCells(arena, logical[row]), widths, gutter, Palette.assistant);
    }
    try appendTableBorder(arena, lines, widths, gutter, .bottom);
}

pub fn languageForFence(info: []const u8) SyntaxLanguage {
    const label = std.mem.trim(u8, info, " \t\r");
    if (std.ascii.eqlIgnoreCase(label, "zig")) return .zig;
    if (std.ascii.eqlIgnoreCase(label, "rust") or std.ascii.eqlIgnoreCase(label, "rs")) return .rust;
    if (std.ascii.eqlIgnoreCase(label, "javascript") or std.ascii.eqlIgnoreCase(label, "js") or
        std.ascii.eqlIgnoreCase(label, "typescript") or std.ascii.eqlIgnoreCase(label, "ts")) return .javascript;
    if (std.ascii.eqlIgnoreCase(label, "python") or std.ascii.eqlIgnoreCase(label, "py")) return .python;
    if (std.ascii.eqlIgnoreCase(label, "shell") or std.ascii.eqlIgnoreCase(label, "bash") or
        std.ascii.eqlIgnoreCase(label, "sh") or std.ascii.eqlIgnoreCase(label, "zsh")) return .shell;
    if (std.ascii.eqlIgnoreCase(label, "json") or std.ascii.eqlIgnoreCase(label, "jsonc")) return .json;
    if (std.ascii.eqlIgnoreCase(label, "toml")) return .toml;
    if (std.ascii.eqlIgnoreCase(label, "yaml") or std.ascii.eqlIgnoreCase(label, "yml")) return .yaml;
    if (std.ascii.eqlIgnoreCase(label, "go")) return .go;
    if (std.ascii.eqlIgnoreCase(label, "ruby") or std.ascii.eqlIgnoreCase(label, "rb")) return .ruby;
    if (std.ascii.eqlIgnoreCase(label, "markdown") or std.ascii.eqlIgnoreCase(label, "md")) return .markdown;
    if (std.ascii.eqlIgnoreCase(label, "c") or std.ascii.eqlIgnoreCase(label, "cpp") or
        std.ascii.eqlIgnoreCase(label, "c++") or std.ascii.eqlIgnoreCase(label, "java") or
        std.ascii.eqlIgnoreCase(label, "swift") or std.ascii.eqlIgnoreCase(label, "kotlin")) return .c_like;
    return .generic;
}

pub fn expandCodeTabs(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\t') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    for (raw) |byte| {
        if (byte == '\t')
            try out.appendSlice(arena, "    ")
        else
            try out.append(arena, byte);
    }
    return out.items;
}

pub fn appendCodeBorder(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    gutter: []const u8,
    panel_width: usize,
    label: ?[]const u8,
) !void {
    var panel: std.ArrayList(u8) = .empty;
    if (label) |header| {
        try panel.appendSlice(arena, "╭─ ");
        const label_capacity = panel_width -| 5;
        const label_end = hardCellBreak(header, 0, label_capacity);
        try panel.appendSlice(arena, header[0..label_end]);
        try panel.append(arena, ' ');
        const used = displayWidth(panel.items) + 1;
        if (used < panel_width) try appendGlyphNTimes(arena, &panel, "─", panel_width - used);
        try panel.appendSlice(arena, "╮");
    } else {
        try panel.appendSlice(arena, "╰");
        try appendGlyphNTimes(arena, &panel, "─", panel_width -| 2);
        try panel.appendSlice(arena, "╯");
    }
    try lines.append(arena, .{
        .text = gutter,
        .style = .{},
        .text2 = panel.items,
        .style2 = Palette.md_code_border,
        .links_resolved = true,
    });
}

pub fn decimalDigits(value: usize) usize {
    var digits: usize = 1;
    var rest = value;
    while (rest >= 10) : (rest /= 10) digits += 1;
    return digits;
}

pub fn appendCodeBlock(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    code_lines: []const []const u8,
    info: []const u8,
    measure: usize,
    gutter: []const u8,
) !void {
    const panel_width = measure -| displayWidth(gutter);
    if (panel_width < 12) return;
    const language_label = std.mem.trim(u8, info, " \t\r");
    const header = if (language_label.len > 0) language_label else "code";
    try appendCodeBorder(arena, lines, gutter, panel_width, header);

    const language = languageForFence(language_label);
    const line_digits = decimalDigits(@max(code_lines.len, 1));
    const show_line_numbers = panel_width >= line_digits + 24;
    const panel_overhead = if (show_line_numbers) line_digits + 7 else 4;
    const body_width = panel_width -| panel_overhead;
    for (code_lines, 0..) |raw, line_number| {
        const code = try expandCodeTabs(arena, raw);
        var start: usize = 0;
        var first = true;
        while (first or start < code.len) {
            const end = if (start < code.len) hardCellBreak(code, start, body_width) else start;
            const chunk = code[start..end];
            var panel: std.ArrayList(u8) = .empty;
            try panel.appendSlice(arena, "│ ");
            if (show_line_numbers) {
                const number = try std.fmt.allocPrint(arena, "{d}", .{line_number + 1});
                if (number.len < line_digits) try panel.appendNTimes(arena, ' ', line_digits - number.len);
                if (first)
                    try panel.appendSlice(arena, number)
                else
                    try panel.appendNTimes(arena, ' ', number.len);
                try panel.appendSlice(arena, " │ ");
            }
            const code_offset = gutter.len + panel.items.len;
            try panel.appendSlice(arena, chunk);
            const used = displayWidth(chunk);
            if (used < body_width) try panel.appendNTimes(arena, ' ', body_width - used);
            const right_border_offset = gutter.len + panel.items.len;
            try panel.appendSlice(arena, " │");
            var styles: std.ArrayList(SyntaxSpan) = .empty;
            try styles.append(arena, .{
                .start = gutter.len,
                .end = code_offset,
                .style = Palette.md_code_border,
            });
            try styles.appendSlice(arena, try syntaxSpans(arena, chunk, language, code_offset));
            try styles.append(arena, .{
                .start = right_border_offset,
                .end = gutter.len + panel.items.len,
                .style = Palette.md_code_border,
            });
            try lines.append(arena, .{
                .text = gutter,
                .style = .{},
                .text2 = panel.items,
                .style2 = Palette.md_code_panel,
                .syntax = styles.items,
                .links_resolved = true,
            });
            first = false;
            start = end;
        }
    }
    try appendCodeBorder(arena, lines, gutter, panel_width, null);
}

pub const CalloutKind = enum { note, tip, important, warning, caution, status };

pub fn calloutLabel(kind: CalloutKind) []const u8 {
    return switch (kind) {
        .note => "NOTE",
        .tip => "TIP",
        .important => "IMPORTANT",
        .warning => "WARNING",
        .caution => "CAUTION",
        .status => "STATUS",
    };
}

pub fn calloutAccent(kind: CalloutKind) vaxis.Color {
    return switch (kind) {
        .note, .status => .{ .rgb = .{ 0x89, 0xdd, 0xff } },
        .tip => .{ .rgb = .{ 0x73, 0xd0, 0x91 } },
        .important => .{ .rgb = .{ 0xc7, 0x92, 0xea } },
        .warning => .{ .rgb = .{ 0xff, 0xcb, 0x6b } },
        .caution => .{ .rgb = .{ 0xf0, 0x71, 0x78 } },
    };
}

pub fn calloutMarker(raw: []const u8) ?CalloutKind {
    const marker = std.mem.trim(u8, raw, " \t\r");
    if (marker.len < 4 or !std.mem.startsWith(u8, marker, "[!") or marker[marker.len - 1] != ']') return null;
    const name = marker[2 .. marker.len - 1];
    inline for (std.meta.tags(CalloutKind)) |kind| {
        if (kind != .status and std.ascii.eqlIgnoreCase(name, calloutLabel(kind))) return kind;
    }
    return null;
}

pub fn semanticCallout(raw: []const u8) ?CalloutKind {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "**Formal status:**") or
        std.mem.startsWith(u8, trimmed, "**Status:**") or
        std.mem.startsWith(u8, trimmed, "**Result:**")) return .status;
    if (std.mem.startsWith(u8, trimmed, "✅") or std.mem.startsWith(u8, trimmed, "✓")) return .tip;
    if (std.mem.startsWith(u8, trimmed, "⚠")) return .warning;
    if (std.mem.startsWith(u8, trimmed, "❌") or std.mem.startsWith(u8, trimmed, "✗")) return .caution;
    return null;
}

pub fn decorateCalloutLines(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    start: usize,
    gutter: []const u8,
    measure: usize,
    kind: CalloutKind,
) !void {
    for (lines.items[start..]) |*line| {
        if (!std.mem.startsWith(u8, line.text, gutter)) continue;
        const whole = line.text;
        line.text = whole[0..gutter.len];
        line.style = .{};
        line.text2 = whole[gutter.len..];
        line.style2 = Palette.md_callout;
        line.fill_style = Palette.md_callout;
        line.fill_start = @intCast(displayWidth(gutter));
        line.fill_width = @intCast(measure -| displayWidth(gutter));
        var spans: std.ArrayList(SyntaxSpan) = .empty;
        try spans.append(arena, .{
            .start = gutter.len,
            .end = gutter.len + "▌".len,
            .style = .{ .fg = calloutAccent(kind), .bg = Palette.md_callout_bg, .bold = true },
        });
        try spans.appendSlice(arena, line.syntax);
        line.syntax = spans.items;
    }
}

pub fn appendCallout(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    bodies: []const []const u8,
    kind: CalloutKind,
    show_label: bool,
    measure: usize,
    gutter: []const u8,
) !void {
    const prefix = try std.fmt.allocPrint(arena, "{s}▌ ", .{gutter});
    const continuation = prefix;
    const first_line = lines.items.len;
    if (show_label) {
        const label = try std.fmt.allocPrint(arena, "**{s}**", .{calloutLabel(kind)});
        try appendMarkdownLine(arena, lines, label, prefix, continuation, Palette.md_callout, measure);
    }
    if (bodies.len == 0) {
        try appendMarkdownLine(arena, lines, "", prefix, continuation, Palette.md_callout, measure);
    } else for (bodies) |body| {
        try appendMarkdownLine(arena, lines, body, prefix, continuation, Palette.md_callout, measure);
    }
    try decorateCalloutLines(arena, lines, first_line, gutter, measure, kind);
}

pub const ListItem = struct {
    content: []const u8,
    marker: []const u8,
    indent: usize,
};

pub fn parseListItem(raw: []const u8) ?ListItem {
    var leading: usize = 0;
    while (leading < raw.len and (raw[leading] == ' ' or raw[leading] == '\t')) : (leading += 1) {}
    const trimmed = raw[leading..];
    var marker: []const u8 = undefined;
    var content: []const u8 = undefined;
    if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ") or
        std.mem.startsWith(u8, trimmed, "+ "))
    {
        marker = "•";
        content = trimmed[2..];
    } else {
        var digits: usize = 0;
        while (digits < trimmed.len and std.ascii.isDigit(trimmed[digits])) : (digits += 1) {}
        if (digits == 0 or digits + 1 >= trimmed.len or
            (trimmed[digits] != '.' and trimmed[digits] != ')') or trimmed[digits + 1] != ' ')
        {
            return null;
        }
        marker = trimmed[0 .. digits + 1];
        content = trimmed[digits + 2 ..];
    }
    if (std.mem.startsWith(u8, content, "[ ] ")) {
        marker = "☐";
        content = content[4..];
    } else if (std.mem.startsWith(u8, content, "[x] ") or std.mem.startsWith(u8, content, "[X] ")) {
        marker = "☑";
        content = content[4..];
    }
    return .{ .content = content, .marker = marker, .indent = @min(leading, 8) };
}

pub fn headingLevel(trimmed: []const u8) usize {
    var level: usize = 0;
    while (level < trimmed.len and level < 6 and trimmed[level] == '#') : (level += 1) {}
    return if (level > 0 and level < trimmed.len and trimmed[level] == ' ') level else 0;
}

pub fn isHorizontalRule(trimmed: []const u8) bool {
    var glyph: u8 = 0;
    var count: usize = 0;
    for (trimmed) |byte| {
        if (byte == ' ' or byte == '\t') continue;
        if (byte != '-' and byte != '*' and byte != '_') return false;
        if (glyph == 0) glyph = byte else if (glyph != byte) return false;
        count += 1;
    }
    return count >= 3;
}

pub fn ensureBlankLine(arena: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    if (lines.items.len > 0 and lineWidthBytes(lines.items[lines.items.len - 1]) > 0) try blankLine(arena, lines);
}

pub fn lineWidthBytes(line: Line) usize {
    return line.text.len + line.text2.len + line.text3.len;
}

/// Terminal-native Markdown renderer with a readable measure, hierarchical
/// headings/lists, rich tables and code panels, and semantic callouts. It
/// remains line-oriented so scrollback and selection retain stable rows.
pub fn wrapMarkdown(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
) !void {
    var logical: std.ArrayList([]const u8) = .empty;
    var split = std.mem.splitScalar(u8, text, '\n');
    while (split.next()) |line| try logical.append(arena, line);

    const gutter = markdownGutter(width);
    const measure = markdownMeasure(width);
    const paragraph_prefix = try std.fmt.allocPrint(arena, "{s}• ", .{gutter});
    const paragraph_continuation = try spaces(arena, displayWidth(paragraph_prefix));
    var i: usize = 0;
    while (i < logical.items.len) {
        const raw = logical.items[i];
        const trimmed = std.mem.trimStart(u8, raw, " \t");

        if (std.mem.startsWith(u8, trimmed, "```") or std.mem.startsWith(u8, trimmed, "~~~")) {
            const fence = trimmed[0..3];
            const info = std.mem.trim(u8, trimmed[3..], " \t\r");
            var end = i + 1;
            while (end < logical.items.len and
                !std.mem.startsWith(u8, std.mem.trimStart(u8, logical.items[end], " \t"), fence)) : (end += 1)
            {}
            try ensureBlankLine(arena, lines);
            try appendCodeBlock(arena, lines, logical.items[i + 1 .. end], info, measure, gutter);
            try ensureBlankLine(arena, lines);
            i = if (end < logical.items.len) end + 1 else end;
            continue;
        }

        if (i + 1 < logical.items.len and
            (try tableCells(arena, raw)).len > 0 and
            try isTableDelimiter(arena, logical.items[i + 1]))
        {
            var end = i + 2;
            while (end < logical.items.len and (try tableCells(arena, logical.items[end])).len > 0) : (end += 1) {}
            try ensureBlankLine(arena, lines);
            try appendTable(arena, lines, logical.items, i, end, measure, gutter);
            try ensureBlankLine(arena, lines);
            i = end;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "> ")) {
            const quote = trimmed[2..];
            if (calloutMarker(quote)) |kind| {
                var bodies: std.ArrayList([]const u8) = .empty;
                var end = i + 1;
                while (end < logical.items.len) : (end += 1) {
                    const next = std.mem.trimStart(u8, logical.items[end], " \t");
                    if (!std.mem.startsWith(u8, next, ">")) break;
                    const body = std.mem.trimStart(u8, next[1..], " ");
                    try bodies.append(arena, body);
                }
                try ensureBlankLine(arena, lines);
                try appendCallout(arena, lines, bodies.items, kind, true, measure, gutter);
                try ensureBlankLine(arena, lines);
                i = end;
                continue;
            }
            const prefix = try std.fmt.allocPrint(arena, "{s}│ ", .{gutter});
            try appendMarkdownLine(arena, lines, quote, prefix, prefix, Palette.md_quote, measure);
            i += 1;
            continue;
        }

        if (trimmed.len == 0) {
            try ensureBlankLine(arena, lines);
            i += 1;
            continue;
        }

        if (semanticCallout(trimmed)) |kind| {
            const body = [_][]const u8{trimmed};
            try ensureBlankLine(arena, lines);
            try appendCallout(arena, lines, &body, kind, false, measure, gutter);
            try ensureBlankLine(arena, lines);
            i += 1;
            continue;
        }

        const level = headingLevel(trimmed);
        if (level > 0) {
            try ensureBlankLine(arena, lines);
            const marker: []const u8 = if (level == 1) "◆ " else if (level == 2) "▸ " else "";
            const prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ gutter, marker });
            const continuation = try spaces(arena, displayWidth(prefix));
            const style = if (level == 1)
                Palette.md_heading_1
            else if (level == 2)
                Palette.md_heading_2
            else
                Palette.md_heading_3;
            try appendMarkdownLine(arena, lines, trimmed[level + 1 ..], prefix, continuation, style, measure);
            i += 1;
            continue;
        }

        if (parseListItem(raw)) |item| {
            const indent = try spaces(arena, item.indent);
            const prefix = try std.fmt.allocPrint(arena, "{s}{s}{s} ", .{ gutter, indent, item.marker });
            const continuation = try spaces(arena, displayWidth(prefix));
            try appendMarkdownLine(arena, lines, item.content, prefix, continuation, Palette.assistant, measure);
            i += 1;
            continue;
        }

        if (isHorizontalRule(trimmed)) {
            var rule: std.ArrayList(u8) = .empty;
            try appendGlyphNTimes(arena, &rule, "─", @min(measure -| displayWidth(gutter), 64));
            try lines.append(arena, .{ .text = gutter, .style = .{}, .text2 = rule.items, .style2 = Palette.md_rule, .links_resolved = true });
            i += 1;
            continue;
        }

        const lead = std.mem.startsWith(u8, trimmed, "**") and std.mem.endsWith(u8, trimmed, "**");
        try appendMarkdownLine(
            arena,
            lines,
            raw,
            paragraph_prefix,
            paragraph_continuation,
            if (lead) Palette.md_lead else Palette.assistant,
            measure,
        );
        i += 1;
    }
}
