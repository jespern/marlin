const std = @import("std");
const vt = @import("ghostty-vt");
const web_shell = @import("web_shell.zig");

test "the /shell query attaches to a shell or opens one, sizes clamped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const attach = try web_shell.parseQuery(a, "/shell?shell_id=5&cols=44&rows=30");
    try std.testing.expectEqual(@as(?u64, 5), attach.shell_id);
    try std.testing.expectEqual(@as(u16, 44), attach.cols);

    const open = try web_shell.parseQuery(a, "/shell?sid=9&command=make%20test+-j%3D2&cols=2&rows=9999");
    try std.testing.expectEqual(@as(?u64, 9), open.sid);
    try std.testing.expectEqualStrings("make test -j=2", open.command);
    try std.testing.expectEqual(@as(u16, 10), open.cols);
    try std.testing.expectEqual(@as(u16, 300), open.rows);

    // Exactly one of shell_id and sid.
    try std.testing.expectError(error.BadQuery, web_shell.parseQuery(a, "/shell?cols=40"));
    try std.testing.expectError(error.BadQuery, web_shell.parseQuery(a, "/shell?sid=1&shell_id=2"));
    try std.testing.expectError(error.BadQuery, web_shell.parseQuery(a, "/shell?sid=x"));
}

const Frame = struct {
    frame: struct {
        cols: u16,
        rows: u16,
        alternate: bool,
        history: usize,
        lines: []const []const u8,
        cursor: struct { x: usize, y: usize, visible: bool },
        app_cursor: bool,
        title: []const u8,
    },
};

test "a frame is the scrollback and screen as styled rows, with the cursor" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var t: vt.Terminal = try .init(threaded.io(), gpa, .{ .cols = 20, .rows = 3 });
    defer t.deinit(gpa);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("old 1\r\nold 2\r\n\x1b[31mred\x1b[0m line\r\n\x1b]2;vim notes\x07$ ls");

    const json = try web_shell.frame(gpa, &t);
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(Frame, gpa, json, .{});
    defer parsed.deinit();
    const f = parsed.value.frame;
    try std.testing.expectEqual(@as(u16, 20), f.cols);
    try std.testing.expect(!f.alternate);
    // Four rows on a three-row screen: one scrolled off above it.
    try std.testing.expectEqual(@as(usize, 1), f.history);
    try std.testing.expectEqualStrings("old 1", f.lines[0]);
    try std.testing.expectEqualStrings("old 2", f.lines[1]);
    try std.testing.expect(std.mem.indexOf(u8, f.lines[2], "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.lines[2], "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.lines[3], "$ ls") != null);
    try std.testing.expectEqual(@as(usize, 4), f.cursor.x);
    try std.testing.expectEqual(@as(usize, 2), f.cursor.y);
    try std.testing.expect(f.cursor.visible);
    try std.testing.expectEqualStrings("vim notes", f.title);
    try std.testing.expect(!f.app_cursor);

    // A full-screen program: its screen only, arrows in application mode.
    stream.nextSlice("\x1b[?1049h\x1b[?1h\x1b[Hfull");
    const alt_json = try web_shell.frame(gpa, &t);
    defer gpa.free(alt_json);
    const alt = try std.json.parseFromSlice(Frame, gpa, alt_json, .{});
    defer alt.deinit();
    try std.testing.expect(alt.value.frame.alternate);
    try std.testing.expect(alt.value.frame.app_cursor);
    try std.testing.expectEqual(@as(usize, 0), alt.value.frame.history);
    try std.testing.expect(std.mem.indexOf(u8, alt.value.frame.lines[0], "full") != null);
}
