//! Unit tests for shell_term.zig: libghostty-vt behind the shell tab.
const std = @import("std");
const vaxis = @import("vaxis");
const shell_term = @import("shell_term.zig");
const Emulator = shell_term.Emulator;

fn testWindow(screen: *vaxis.Screen, cols: u16, rows: u16) vaxis.Window {
    return .{ .x_off = 0, .y_off = 0, .parent_x_off = 0, .parent_y_off = 0, .width = cols, .height = rows, .screen = screen };
}

test "PTY output draws into cells with its colors and attributes" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const emulator = try Emulator.create(gpa, threaded.io(), 20, 4);
    defer emulator.destroy();
    var screen = try vaxis.Screen.init(gpa, .{ .rows = 4, .cols = 20, .x_pixel = 0, .y_pixel = 0 });
    defer screen.deinit(gpa);
    const win = testWindow(&screen, 20, 4);

    emulator.feed("hello\r\n\x1b[1;31mred\x1b[0m \x1b[38;2;1;2;3mrgb\x1b[0m 日本");
    try emulator.draw(arena.allocator(), win);

    try std.testing.expectEqualStrings("h", win.readCell(0, 0).?.char.grapheme);
    const red = win.readCell(0, 1).?;
    try std.testing.expectEqualStrings("r", red.char.grapheme);
    try std.testing.expect(red.style.bold);
    try std.testing.expectEqual(vaxis.Color{ .index = 1 }, red.style.fg);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 1, 2, 3 } }, win.readCell(4, 1).?.style.fg);
    const wide = win.readCell(8, 1).?;
    try std.testing.expectEqualStrings("日", wide.char.grapheme);
    try std.testing.expectEqual(@as(u8, 2), wide.char.width);
    try std.testing.expectEqualStrings("本", win.readCell(10, 1).?.char.grapheme);
}

test "terminal queries are answered for the program" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const emulator = try Emulator.create(gpa, threaded.io(), 80, 24);
    defer emulator.destroy();

    emulator.feed("ab\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;3R", emulator.replies.items);
    emulator.replies.clearRetainingCapacity();
    emulator.feed("\x1b[c");
    try std.testing.expect(std.mem.startsWith(u8, emulator.replies.items, "\x1b[?"));
}

test "keys encode for the program's current modes" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const emulator = try Emulator.create(gpa, threaded.io(), 80, 24);
    defer emulator.destroy();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const cases = [_]struct { key: vaxis.Key, bytes: []const u8 }{
        .{ .key = .{ .codepoint = 'a', .text = "a" }, .bytes = "a" },
        .{ .key = .{ .codepoint = 'a', .text = "A", .shifted_codepoint = 'A', .mods = .{ .shift = true } }, .bytes = "A" },
        .{ .key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } }, .bytes = "\x03" },
        .{ .key = .{ .codepoint = vaxis.Key.enter }, .bytes = "\r" },
        .{ .key = .{ .codepoint = vaxis.Key.backspace }, .bytes = "\x7f" },
        .{ .key = .{ .codepoint = vaxis.Key.up }, .bytes = "\x1b[A" },
        .{ .key = .{ .codepoint = 'x', .text = "x", .mods = .{ .alt = true } }, .bytes = "\x1bx" },
    };
    for (cases) |case| {
        out.clearRetainingCapacity();
        try emulator.encodeKey(&out.writer, case.key);
        try std.testing.expectEqualStrings(case.bytes, out.written());
    }

    // Application cursor keys (as vim/less request them).
    emulator.feed("\x1b[?1h");
    out.clearRetainingCapacity();
    try emulator.encodeKey(&out.writer, .{ .codepoint = vaxis.Key.up });
    try std.testing.expectEqualStrings("\x1bOA", out.written());
}

test "pastes are bracketed only when the program asked" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const emulator = try Emulator.create(gpa, threaded.io(), 80, 24);
    defer emulator.destroy();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var plain = "echo hi".*;
    try emulator.encodePaste(&out.writer, &plain);
    try std.testing.expectEqualStrings("echo hi", out.written());

    emulator.feed("\x1b[?2004h");
    out.clearRetainingCapacity();
    var bracketed = "echo hi".*;
    try emulator.encodePaste(&out.writer, &bracketed);
    try std.testing.expectEqualStrings("\x1b[200~echo hi\x1b[201~", out.written());
}

test "resizing reflows the grid size" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const emulator = try Emulator.create(gpa, threaded.io(), 80, 24);
    defer emulator.destroy();
    try emulator.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), emulator.cols());
    try std.testing.expectEqual(@as(u16, 40), emulator.rows());
}
