//! Unit tests for shell_env.zig.
const std = @import("std");
const shell_env = @import("shell_env.zig");

const Fake = struct {
    present: []const []const u8,
    fn probe(ctx: ?*anyopaque, path: []const u8) bool {
        const self: *const Fake = @ptrCast(@alignCast(ctx.?));
        for (self.present) |p| if (std.mem.eql(u8, p, path)) return true;
        return false;
    }
};

fn base(gpa: std.mem.Allocator) !std.process.Environ.Map {
    var environ = std.process.Environ.Map.init(gpa);
    errdefer environ.deinit();
    try environ.put("HOME", "/home/me");
    try environ.put("TERM", "screen");
    try environ.put("TERM_PROGRAM", "tmux");
    try environ.put("TMUX", "/tmp/tmux-1/default,1,0");
    try environ.put("KITTY_WINDOW_ID", "3");
    try environ.put("PATH", "/usr/bin");
    return environ;
}

test "Ghostty's bundled terminfo is used through TERMINFO" {
    const gpa = std.testing.allocator;
    var environ = try base(gpa);
    defer environ.deinit();
    var fake: Fake = .{ .present = &.{"/Applications/Ghostty.app/Contents/Resources/terminfo/78/xterm-ghostty"} };
    try shell_env.prepare(gpa, &environ, Fake.probe, &fake);
    try std.testing.expectEqualStrings("xterm-ghostty", environ.get("TERM").?);
    try std.testing.expectEqualStrings("ghostty", environ.get("TERM_PROGRAM").?);
    try std.testing.expectEqualStrings("/Applications/Ghostty.app/Contents/Resources/terminfo", environ.get("TERMINFO").?);
    try std.testing.expect(environ.get("TMUX") == null);
    try std.testing.expect(environ.get("KITTY_WINDOW_ID") == null);
    try std.testing.expectEqualStrings("/usr/bin", environ.get("PATH").?);
}

test "a system-wide entry needs no TERMINFO; no entry falls back to xterm-256color" {
    const gpa = std.testing.allocator;
    var environ = try base(gpa);
    defer environ.deinit();
    var system: Fake = .{ .present = &.{"/usr/share/terminfo/x/xterm-ghostty"} };
    try shell_env.prepare(gpa, &environ, Fake.probe, &system);
    try std.testing.expectEqualStrings("xterm-ghostty", environ.get("TERM").?);
    try std.testing.expect(environ.get("TERMINFO") == null);

    var plain = try base(gpa);
    defer plain.deinit();
    var none: Fake = .{ .present = &.{} };
    try shell_env.prepare(gpa, &plain, Fake.probe, &none);
    try std.testing.expectEqualStrings("xterm-256color", plain.get("TERM").?);
    try std.testing.expect(plain.get("TERM_PROGRAM") == null);
    try std.testing.expectEqualStrings("truecolor", plain.get("COLORTERM").?);
}
