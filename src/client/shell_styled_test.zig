//! Unit tests for shell_styled.zig: colored shell transcripts.
const std = @import("std");
const vaxis = @import("vaxis");
const shell_styled = @import("shell_styled.zig");

test "rows carry SGR styles as spans and drop other escapes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try shell_styled.rows(arena.allocator(), "\x1b[0m\x1b[1m\x1b[38;5;2mok\x1b[0m done\r\n" ++
        "\x1b]8;;https://x.test\x1b\\link\x1b]8;;\x1b\\ \x1b[38:2::1:2:3mrgb\r\n\r\n   \r\n");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("ok done", rows[0].text);
    try std.testing.expectEqual(@as(usize, 1), rows[0].syntax.len);
    try std.testing.expectEqual(@as(usize, 0), rows[0].syntax[0].start);
    try std.testing.expectEqual(@as(usize, 2), rows[0].syntax[0].end);
    try std.testing.expect(rows[0].syntax[0].style.bold);
    try std.testing.expect(vaxis.Color.eql(rows[0].syntax[0].style.fg, .{ .index = 2 }));

    try std.testing.expectEqualStrings("link rgb", rows[1].text);
    try std.testing.expectEqual(@as(usize, 1), rows[1].syntax.len);
    try std.testing.expectEqual(@as(usize, 5), rows[1].syntax[0].start);
    try std.testing.expect(vaxis.Color.eql(rows[1].syntax[0].style.fg, .{ .rgb = .{ 1, 2, 3 } }));
}

test "a style carries across rows until reset" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try shell_styled.rows(arena.allocator(), "\x1b[4mone\r\ntwo\x1b[m three");
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqual(@as(usize, 3), rows[1].syntax[0].end);
    try std.testing.expect(rows[1].syntax[0].style.ul_style == .single);
}

test "OSC 8 links become link spans, across rows, allowlisted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try shell_styled.rows(arena.allocator(), "see \x1b]8;;https://x.test/a\x1b\\docs\x1b]8;;\x1b\\ here\r\n" ++
        "\x1b]8;id=1;file:///tmp/notes.md\x07notes\r\nstill\x1b]8;;\x07 plain\r\n" ++
        "\x1b]8;;javascript:alert(1)\x1b\\bad\x1b]8;;\x1b\\\r\n");
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqual(@as(usize, 1), rows[0].links.len);
    try std.testing.expectEqualStrings("docs", rows[0].text[rows[0].links[0].start..rows[0].links[0].end]);
    try std.testing.expectEqualStrings("https://x.test/a", rows[0].links[0].uri);
    // An open link carries into the next row, as a style does.
    try std.testing.expectEqualStrings("file:///tmp/notes.md", rows[1].links[0].uri);
    try std.testing.expectEqualStrings("still", rows[2].text[rows[2].links[0].start..rows[2].links[0].end]);
    try std.testing.expectEqualStrings("still plain", rows[2].text);
    // Schemes outside http(s) and file are text, not links.
    try std.testing.expectEqual(@as(usize, 0), rows[3].links.len);
    try std.testing.expectEqualStrings("bad", rows[3].text);
}
