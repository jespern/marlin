//! Unit tests for screenshot.zig: window screenshots.
const std = @import("std");
const vaxis = @import("vaxis");
const screenshot = @import("screenshot.zig");

fn put(screen: *vaxis.Screen, col: u16, row: u16, text: []const u8, style: vaxis.Style) void {
    for (text, 0..) |_, i| screen.writeCell(col + @as(u16, @intCast(i)), row, .{ .char = .{ .grapheme = text[i .. i + 1], .width = 1 }, .style = style });
}

test "the frame becomes styled runs in the terminal's colors" {
    const gpa = std.testing.allocator;
    var screen: vaxis.Screen = try .init(gpa, .{ .rows = 3, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    put(&screen, 0, 0, "ok", .{});
    put(&screen, 3, 0, "red", .{ .fg = .{ .index = 1 }, .bold = true });
    put(&screen, 7, 0, "\"q\"", .{});
    put(&screen, 0, 1, "X", .{ .reverse = true });
    screen.writeCell(2, 1, .{ .char = .{ .grapheme = "日", .width = 2 }, .style = .{} });
    put(&screen, 4, 1, "z", .{});
    put(&screen, 0, 2, " ab ", .{ .bg = .{ .rgb = .{ 1, 2, 3 } } });

    var reported: [16]?[3]u8 = @splat(null);
    reported[1] = .{ 200, 10, 10 };
    const colors = screenshot.colorsFrom(.{ 220, 220, 220 }, .{ 0, 0, 0 }, reported);
    const geometry: screenshot.Geometry = .{ .cols = 20, .cell_width = 16, .cell_height = 34 };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const full = try screenshot.describe(arena.allocator(), &screen, 0, 3, colors, geometry, "Menlo");
    const expected =
        \\{"cols":20,"rows":3,"cw":16,"ch":34,"font":"Menlo","bg":[0,0,0],"runs":[
    ++
        \\[0,0,2,"ok",[220,220,220],null,0],[0,3,3,"red",[200,10,10],null,1],[0,7,3,"\"q\"",[220,220,220],null,0],
    ++
        \\[1,0,1,"X",[0,0,0],[220,220,220],0],[1,2,2,"日",[220,220,220],null,0],[1,4,1,"z",[220,220,220],null,0],
    ++
        \\[2,0,4," ab ",[220,220,220],[1,2,3],0]]}
    ;
    try std.testing.expectEqualStrings(expected, full);

    // Slim: a range of rows, renumbered from zero.
    const slim = try screenshot.describe(arena.allocator(), &screen, 1, 2, colors, geometry, "Menlo");
    try std.testing.expect(std.mem.indexOf(u8, slim, "\"rows\":1,") != null);
    try std.testing.expect(std.mem.indexOf(u8, slim, "[0,0,1,\"X\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, slim, "ok") == null);
}

test "the font comes from Ghostty's config" {
    try std.testing.expectEqualStrings("JetBrains Mono", screenshot.configFont("# x\nfont-size = 13\nfont-family = \"JetBrains Mono\"\n").?);
    try std.testing.expect(screenshot.configFont("theme = dark\n") == null);
}

test "Alt+S is the screenshot key" {
    try std.testing.expect(screenshot.isKey(.{ .codepoint = 's', .mods = .{ .alt = true } }));
    try std.testing.expect(!screenshot.isKey(.{ .codepoint = 's' }));
}
