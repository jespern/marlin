//! Environment for shell-tab shells. The terminal they run in is
//! libghostty-vt, so where Ghostty's terminfo is installed they are told so
//! (TERM=xterm-ghostty, as in a Ghostty window); elsewhere they get
//! xterm-256color. Variables describing whatever terminal launched the
//! daemon are dropped: they would mislead programs about this one.
const std = @import("std");
const Io = std.Io;

/// Terminfo directories searched for xterm-ghostty, after $TERMINFO,
/// ~/.terminfo and $TERMINFO_DIRS. Ghostty's app bundle is where macOS
/// installs keep it, reachable only through TERMINFO.
const system_dirs = [_][]const u8{
    "/usr/share/terminfo",
    "/usr/local/share/terminfo",
    "/opt/homebrew/share/terminfo",
    "/usr/lib/terminfo",
    "/lib/terminfo",
    "/etc/terminfo",
};
const bundle_dirs = [_][]const u8{
    "/Applications/Ghostty.app/Contents/Resources/terminfo",
};

const foreign = [_][]const u8{
    "TMUX",               "TMUX_PANE",        "STY",             "WINDOW",
    "KITTY_WINDOW_ID",    "KITTY_PID",        "KITTY_LISTEN_ON", "WEZTERM_PANE",
    "WEZTERM_EXECUTABLE", "ITERM_SESSION_ID", "TERM_SESSION_ID", "TERM_PROGRAM_VERSION",
    "VTE_VERSION",        "COLUMNS",          "LINES",
};

pub const Probe = *const fn (ctx: ?*anyopaque, path: []const u8) bool;

/// Rewrite `environ` (a copy of the daemon's) for a shell. `exists` reports
/// whether a terminfo file is present; it is injectable for tests.
pub fn prepare(gpa: std.mem.Allocator, environ: *std.process.Environ.Map, exists: Probe, ctx: ?*anyopaque) !void {
    for (foreign) |name| _ = environ.swapRemove(name);
    try environ.put("COLORTERM", "truecolor");
    if (try ghosttyTerminfo(gpa, environ, exists, ctx)) |dir| {
        defer gpa.free(dir);
        try environ.put("TERM", "xterm-ghostty");
        try environ.put("TERM_PROGRAM", "ghostty");
        const is_system = for (system_dirs) |system| {
            if (std.mem.eql(u8, system, dir)) break true;
        } else false;
        if (!is_system) try environ.put("TERMINFO", dir);
    } else {
        try environ.put("TERM", "xterm-256color");
        _ = environ.swapRemove("TERM_PROGRAM");
    }
}

/// The terminfo directory holding xterm-ghostty, if any (gpa-owned).
fn ghosttyTerminfo(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map, exists: Probe, ctx: ?*anyopaque) !?[]u8 {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(gpa);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |path| gpa.free(path);
        owned.deinit(gpa);
    }
    if (environ.get("TERMINFO")) |dir| if (dir.len > 0) try candidates.append(gpa, dir);
    if (environ.get("HOME")) |home| {
        const dir = try std.fs.path.join(gpa, &.{ home, ".terminfo" });
        try owned.append(gpa, dir);
        try candidates.append(gpa, dir);
    }
    if (environ.get("TERMINFO_DIRS")) |dirs| {
        var it = std.mem.tokenizeScalar(u8, dirs, ':');
        while (it.next()) |dir| try candidates.append(gpa, dir);
    }
    try candidates.appendSlice(gpa, &system_dirs);
    try candidates.appendSlice(gpa, &bundle_dirs);

    for (candidates.items) |dir| {
        // ncurses files entries under the first letter, macOS under its hex.
        for ([_][]const u8{ "x", "78" }) |sub| {
            const path = try std.fs.path.join(gpa, &.{ dir, sub, "xterm-ghostty" });
            defer gpa.free(path);
            if (exists(ctx, path)) return try gpa.dupe(u8, dir);
        }
    }
    return null;
}

/// The real probe: does the file exist?
pub fn fileExists(ctx: ?*anyopaque, path: []const u8) bool {
    const io: *const Io = @ptrCast(@alignCast(ctx.?));
    Io.Dir.cwd().access(io.*, path, .{}) catch return false;
    return true;
}
