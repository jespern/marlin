const std = @import("std");
const vaxis = @import("vaxis");
const terminal_osc = @import("terminal_osc.zig");

test {
    std.testing.refAllDecls(terminal_osc);
}

test "terminal progress aggregates active session states" {
    try std.testing.expectEqual(terminal_osc.Progress.hidden, terminal_osc.progressForStates(&.{ .idle, .done, .err }));
    try std.testing.expectEqual(terminal_osc.Progress.indeterminate, terminal_osc.progressForStates(&.{ .idle, .running }));
    try std.testing.expectEqual(terminal_osc.Progress.warning, terminal_osc.progressForStates(&.{ .running, .awaiting_approval }));
}

test "OSC progress and notifications are bounded escape sequences" {
    const gpa = std.testing.allocator;
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try terminal_osc.writeProgress(&output.writer, .indeterminate, 255);
    try terminal_osc.writeWorkingDirectory(&output.writer, "work station", "/Users/me/My Project");
    try terminal_osc.writeNotification(&output.writer, gpa, 42, "Marlin", "needs approval\x1b]");
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b]9;4;3;100\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b]7;file://work%20station/Users/me/My%20Project\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "\x1b]99;i=marlin-42:d=0:e=1:p=title;TWFybGlu\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "needs approval") == null);
}

test "terminal theme derives shimmer from reported foreground and background" {
    var theme = terminal_osc.Theme{};
    theme.applyReport(.{ .kind = .bg, .value = .{ 0, 0, 0 } });
    theme.applyReport(.{ .kind = .fg, .value = .{ 200, 100, 50 } });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 76, 38, 19 } }, theme.shimmer[0]);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 200, 100, 50 } }, theme.shimmer[5]);
    theme.applyReport(.{ .kind = .{ .index = 6 }, .value = .{ 1, 2, 3 } });
    try std.testing.expectEqual([3]u8{ 1, 2, 3 }, theme.palette[6].?);
}
