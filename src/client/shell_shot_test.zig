//! Unit tests for shell_shot.zig: shell screenshots.
const std = @import("std");
const vt = @import("ghostty-vt");
const shell_shot = @import("shell_shot.zig");

test "rows become styled runs in the terminal's colors" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var t: vt.Terminal = try .init(threaded.io(), gpa, .{ .cols = 20, .rows = 2 });
    defer t.deinit(gpa);
    var stream = t.vtStream();
    defer stream.deinit();
    stream.nextSlice("ok \x1b[1;31mred\x1b[0m \"q\"\r\n\x1b[7mX\x1b[0m");

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var pins: std.ArrayList(vt.Pin) = .empty;
    var it = t.screens.active.pages.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |pin| try pins.append(arena.allocator(), pin);

    var reported: [16]?[3]u8 = @splat(null);
    reported[1] = .{ 200, 10, 10 };
    const colors = shell_shot.colorsFrom(.{ 220, 220, 220 }, .{ 0, 0, 0 }, reported);
    const json = try shell_shot.describe(arena.allocator(), pins.items, colors, .{ .cols = 20, .cell_width = 16, .cell_height = 34 }, "Menlo");
    const expected =
        \\{"cols":20,"rows":2,"cw":16,"ch":34,"font":"Menlo","bg":[0,0,0],"runs":[
    ++
        \\[0,0,2,"ok",[220,220,220],null,0],[0,3,3,"red",[200,10,10],null,1],[0,7,3,"\"q\"",[220,220,220],null,0],
    ++
        \\[1,0,1,"X",[0,0,0],[220,220,220],0]]}
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "the font comes from Ghostty's config" {
    try std.testing.expectEqualStrings("JetBrains Mono", shell_shot.configFont("# x\nfont-size = 13\nfont-family = \"JetBrains Mono\"\n").?);
    try std.testing.expect(shell_shot.configFont("theme = dark\n") == null);
}
