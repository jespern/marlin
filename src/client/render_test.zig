//! Unit tests for render.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in render.zig.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

const render = @import("render.zig");
const Palette = render.Palette;

test {
    std.testing.refAllDecls(render);
}

test "informational accents are blue while attention states remain yellow" {
    try std.testing.expect(vaxis.Color.eql(Palette.note.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.md_code.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.shell_path.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.git_hash.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.syntax_constant.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.status_running.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.status_notice.fg, Palette.soft_blue));

    const attention_yellow: vaxis.Color = .{ .index = 3 };
    try std.testing.expect(vaxis.Color.eql(Palette.status_approval.fg, attention_yellow));
    try std.testing.expect(vaxis.Color.eql(Palette.status_context_warn.fg, attention_yellow));
    try std.testing.expect(vaxis.Color.eql(Palette.approval_card.fg, attention_yellow));
}

test "links hidden behind a newline never underline the row's blank cells" {
    // Case: a Bash header shows `python3 - <<'EOF'`; a URL in the hidden
    // heredoc body drew a floating underline far right on the header row.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var screen = try vaxis.Screen.init(std.testing.allocator, .{ .rows = 1, .cols = 120, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(std.testing.allocator);
    const win = vaxis.Window{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = 120, .height = 1, .screen = &screen };
    var lines = [_]render.Line{.{
        .text = "  ⚙ Bash ",
        .style = .{},
        .text2 = "curl https://example.com/a <<'EOF'\nfetch('https://example.com/hidden')",
    }};
    try render.resolveLineLinks(arena_state.allocator(), &lines);
    _ = win.print(&.{
        .{ .text = lines[0].text },
        .{ .text = lines[0].text2 },
    }, .{ .wrap = .none });
    render.applyLineLinks(win, 0, lines[0]);

    var underlined: usize = 0;
    var last_text_col: usize = 0;
    for (0..120) |col| {
        const cell = win.readCell(@intCast(col), 0).?;
        if (!std.mem.eql(u8, cell.char.grapheme, " ") and cell.char.grapheme.len > 0) last_text_col = col;
        if (cell.style.ul_style == .single) {
            underlined += 1;
            try std.testing.expect(col <= last_text_col);
        }
    }
    try std.testing.expectEqual(@as(usize, "https://example.com/a".len), underlined);
}
