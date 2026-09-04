//! Unit tests for markdown.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in markdown.zig.

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

const markdown = @import("markdown.zig");
const inlineMarkdown = markdown.inlineMarkdown;
const markdown_gutter = markdown.markdown_gutter;
const markdown_max_body_width = markdown.markdown_max_body_width;
const wrapMarkdown = markdown.wrapMarkdown;

test {
    std.testing.refAllDecls(markdown);
}

test "assistant Markdown removes punctuation and retains styles and links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try inlineMarkdown(
        arena_state.allocator(),
        "Use **M3** and `zig build`; see [the docs](https://marlin.wtf/docs).",
    );

    try std.testing.expectEqualStrings("Use M3 and zig build; see the docs.", rendered.text);
    try std.testing.expectEqual(@as(usize, 2), rendered.styles.len);
    try std.testing.expectEqual(@as(usize, 1), rendered.links.len);
    try std.testing.expectEqualStrings("the docs", rendered.text[rendered.links[0].start..rendered.links[0].end]);
    try std.testing.expectEqualStrings("https://marlin.wtf/docs", rendered.links[0].uri);
    try std.testing.expect(vaxis.Color.eql(rendered.styles[1].style.bg, Palette.md_inline_code_bg));
}

test "assistant Markdown renders bounded tables with header surfaces and inline styles" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "| Milestone | Status |\n|---|---|\n| **M0** | ✅ Complete with a deliberately long status that wraps cleanly |",
        44,
    );

    try std.testing.expect(lines.items.len > 5); // wrapped body + borders + spacer
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text2, "╭"));
    try std.testing.expect(lines.items[1].style2.bold);
    try std.testing.expect(vaxis.Color.eql(lines.items[1].style2.bg, Palette.md_table_header_bg));
    const body = try lineText(arena, lines.items[3]);
    try std.testing.expect(std.mem.indexOf(u8, body, "M0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "**") == null);
    try std.testing.expect(lines.items[3].syntax.len > 0);
    for (lines.items) |line| try std.testing.expect(displayWidth(try lineText(arena, line)) <= 44);
}

test "assistant Markdown has readable measure and hanging list indents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "# Milestones\n\n1. This ordered item is intentionally long enough to wrap beneath its text instead of beneath the marker, even when the terminal is very wide, because assistant prose should retain a readable measure across large desktop windows.\n  - [x] nested task",
        220,
    );

    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text, "  ◆ "));
    try std.testing.expect(lines.items[0].style.bold);
    for (lines.items) |line| try std.testing.expect(displayWidth(try lineText(arena, line)) <= markdown_max_body_width + markdown_gutter.len);

    var saw_continuation = false;
    var saw_task = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.startsWith(u8, text, "     ") and text.len > 5) saw_continuation = true;
        if (std.mem.startsWith(u8, text, "    ☑ ")) saw_task = true;
    }
    try std.testing.expect(saw_continuation);
    try std.testing.expect(saw_task);
}

test "assistant paragraphs use a dotted rail with hanging continuation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "A distinct prose section gets a calm visual anchor and enough text to wrap onto another terminal row.",
        42,
    );

    try std.testing.expect(lines.items.len >= 2);
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text, "  • "));
    try std.testing.expect(std.mem.startsWith(u8, lines.items[1].text, "    "));
    try std.testing.expect(!std.mem.startsWith(u8, lines.items[1].text, "  • "));

    var auxiliary: std.ArrayList(Line) = .empty;
    try wrapPrefixed(
        arena,
        &auxiliary,
        "  · ",
        "A reasoning section also remains inset when it crosses the available terminal width.",
        Palette.reasoning,
        34,
    );
    try std.testing.expect(auxiliary.items.len >= 2);
    try std.testing.expect(std.mem.startsWith(u8, auxiliary.items[0].text, "  · "));
    try std.testing.expect(std.mem.startsWith(u8, auxiliary.items[1].text, "    "));
}

test "assistant Markdown renders code panels and semantic callouts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "**Formal status:** ready to ship.\n\n```zig\nconst answer: usize = 42;\n```\n\n> [!WARNING]\n> Keep the rollback path.",
        80,
    );

    try std.testing.expect(lines.items[0].fill_style != null);
    try std.testing.expect(std.mem.startsWith(u8, lines.items[0].text2, "▌ "));
    try std.testing.expect(vaxis.Color.eql(lines.items[0].style2.bg, Palette.md_callout_bg));

    var saw_code_header = false;
    var saw_syntax = false;
    var saw_code_gutter = false;
    var saw_warning = false;
    for (lines.items) |line| {
        const text = try lineText(arena, line);
        if (std.mem.indexOf(u8, text, "╭─ zig ") != null) saw_code_header = true;
        if (std.mem.indexOf(u8, text, "const answer") != null and line.syntax.len >= 2) saw_syntax = true;
        if (std.mem.indexOf(u8, text, "│ 1 │") != null) saw_code_gutter = true;
        if (std.mem.indexOf(u8, text, "WARNING") != null and line.fill_style != null) saw_warning = true;
    }
    try std.testing.expect(saw_code_header);
    try std.testing.expect(saw_syntax);
    try std.testing.expect(saw_code_gutter);
    try std.testing.expect(saw_warning);
}

test "code panel headers carry a copy payload and advertise it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapMarkdown(
        arena,
        &lines,
        "```zig\nconst a = 1;\nconst b = 2;\n```",
        80,
    );

    var header: ?Line = null;
    for (lines.items) |line| {
        if (line.copy_payload != null) {
            try std.testing.expect(header == null); // exactly one per block
            header = line;
        }
    }
    // The payload is the raw code, unwrapped and without panel chrome.
    try std.testing.expectEqualStrings("const a = 1;\nconst b = 2;", header.?.copy_payload.?);
    const text = try lineText(arena, header.?);
    try std.testing.expect(std.mem.indexOf(u8, text, markdown.copy_affordance) != null);
    try std.testing.expect(header.?.syntax.len == 1);

    // Too narrow for the affordance: the label disappears, the click
    // target (payload on the header row) remains.
    var narrow: std.ArrayList(Line) = .empty;
    try wrapMarkdown(arena, &narrow, "```zig\nconst a = 1;\n```", 14);
    var narrow_header: ?Line = null;
    for (narrow.items) |line| {
        if (line.copy_payload != null) narrow_header = line;
    }
    const narrow_text = try lineText(arena, narrow_header.?);
    try std.testing.expect(std.mem.indexOf(u8, narrow_text, markdown.copy_affordance) == null);
    try std.testing.expectEqualStrings("const a = 1;", narrow_header.?.copy_payload.?);
}

test "assistant inline Markdown supports emphasis and strikethrough" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rendered = try inlineMarkdown(arena_state.allocator(), "*soft* ~~gone~~ snake_case_value");
    try std.testing.expectEqualStrings("soft gone snake_case_value", rendered.text);
    try std.testing.expectEqual(@as(usize, 2), rendered.styles.len);
    try std.testing.expect(rendered.styles[0].style.italic);
    try std.testing.expect(rendered.styles[1].style.strikethrough);
}
