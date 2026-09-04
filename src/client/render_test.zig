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
