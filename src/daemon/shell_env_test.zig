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

test "Ghostty's installed shell integration is injected for zsh, fish, and bash" {
    const gpa = std.testing.allocator;
    const res = "/opt/ghostty";
    var fake: Fake = .{ .present = &.{
        res ++ "/shell-integration/zsh/.zshenv",
        res ++ "/shell-integration/fish/vendor_conf.d/ghostty-shell-integration.fish",
        res ++ "/shell-integration/bash/ghostty.bash",
    } };

    var zsh = try base(gpa);
    defer zsh.deinit();
    try zsh.put("GHOSTTY_RESOURCES_DIR", res);
    try zsh.put("ZDOTDIR", "/home/me/.config/zsh");
    try std.testing.expect(!(try shell_env.integrate(gpa, &zsh, "/bin/zsh", Fake.probe, &fake)).bash_posix);
    try std.testing.expectEqualStrings(res ++ "/shell-integration/zsh", zsh.get("ZDOTDIR").?);
    // The user's own ZDOTDIR is restored by the integration.
    try std.testing.expectEqualStrings("/home/me/.config/zsh", zsh.get("GHOSTTY_ZSH_ZDOTDIR").?);
    try std.testing.expectEqualStrings("cursor:blink,title", zsh.get("GHOSTTY_SHELL_FEATURES").?);

    var fish = try base(gpa);
    defer fish.deinit();
    try fish.put("GHOSTTY_RESOURCES_DIR", res);
    _ = try shell_env.integrate(gpa, &fish, "/opt/homebrew/bin/fish", Fake.probe, &fake);
    try std.testing.expectEqualStrings(res ++ "/shell-integration:/usr/local/share:/usr/share", fish.get("XDG_DATA_DIRS").?);
    try std.testing.expectEqualStrings(res ++ "/shell-integration", fish.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?);

    var bash = try base(gpa);
    defer bash.deinit();
    try bash.put("GHOSTTY_RESOURCES_DIR", res);
    try bash.put("ENV", "/home/me/.shinit");
    try std.testing.expect((try shell_env.integrate(gpa, &bash, "/usr/local/bin/bash", Fake.probe, &fake)).bash_posix);
    try std.testing.expectEqualStrings(res ++ "/shell-integration/bash/ghostty.bash", bash.get("ENV").?);
    try std.testing.expectEqualStrings("/home/me/.shinit", bash.get("GHOSTTY_BASH_ENV").?);
    try std.testing.expectEqualStrings("/home/me/.bash_history", bash.get("HISTFILE").?);

    // Another shell, or no Ghostty here: nothing changes.
    var sh = try base(gpa);
    defer sh.deinit();
    try sh.put("GHOSTTY_RESOURCES_DIR", res);
    _ = try shell_env.integrate(gpa, &sh, "/bin/sh", Fake.probe, &fake);
    try std.testing.expect(sh.get("GHOSTTY_SHELL_FEATURES") == null);
    var none = try base(gpa);
    defer none.deinit();
    var empty: Fake = .{ .present = &.{} };
    _ = try shell_env.integrate(gpa, &none, "/bin/zsh", Fake.probe, &empty);
    try std.testing.expect(none.get("ZDOTDIR") == null);
}
