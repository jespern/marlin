//! Environment for shell-tab shells. The terminal they run in is
//! libghostty-vt, so where Ghostty's terminfo is installed they are told so
//! (TERM=xterm-ghostty, as in a Ghostty window); elsewhere they get
//! xterm-256color. Variables describing whatever terminal launched the
//! daemon are dropped: they would mislead programs about this one.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

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

/// Where an installed Ghostty keeps its resources (shell-integration/
/// beneath), after $GHOSTTY_RESOURCES_DIR.
const ghostty_resource_dirs = [_][]const u8{
    "/Applications/Ghostty.app/Contents/Resources/ghostty",
    "/usr/share/ghostty",
    "/usr/local/share/ghostty",
    "/opt/homebrew/share/ghostty",
};

pub const Integration = struct {
    /// bash takes its integration through ENV, which needs --posix.
    bash_posix: bool = false,
};

/// Ghostty's shell integration, from the Ghostty installed on this host:
/// the shell then reports its prompts and commands with exit codes (OSC
/// 133), its directory (OSC 7), and titles. Ported from Ghostty's
/// termio/shell_integration.zig (zsh, fish, bash). With no Ghostty here,
/// or another shell, nothing changes.
pub fn integrate(gpa: std.mem.Allocator, environ: *std.process.Environ.Map, shell_path: []const u8, exists: Probe, ctx: ?*anyopaque) !Integration {
    const shell = std.fs.path.basename(shell_path);
    const marker: []const u8 = if (std.mem.eql(u8, shell, "zsh"))
        "zsh/.zshenv"
    else if (std.mem.eql(u8, shell, "fish"))
        "fish/vendor_conf.d/ghostty-shell-integration.fish"
    else if (std.mem.eql(u8, shell, "bash"))
        // Apple's patched bash 3.2 skips the ENV startup this relies on.
        if (builtin.os.tag == .macos and std.mem.eql(u8, shell_path, "/bin/bash")) return .{} else "bash/ghostty.bash"
    else
        return .{};

    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(gpa);
    if (environ.get("GHOSTTY_RESOURCES_DIR")) |dir| try candidates.append(gpa, dir);
    try candidates.appendSlice(gpa, &ghostty_resource_dirs);
    var resources: ?[]u8 = null;
    defer if (resources) |dir| gpa.free(dir);
    for (candidates.items) |dir| {
        const probe = try std.fs.path.join(gpa, &.{ dir, "shell-integration", marker });
        defer gpa.free(probe);
        if (exists(ctx, probe)) {
            resources = try gpa.dupe(u8, dir);
            break;
        }
    }
    const dir = resources orelse return .{};
    const integration_dir = try std.fs.path.join(gpa, &.{ dir, "shell-integration" });
    defer gpa.free(integration_dir);

    try environ.put("GHOSTTY_RESOURCES_DIR", dir);
    // Ghostty's defaults, less what is Ghostty's own (its bin dir on PATH).
    try environ.put("GHOSTTY_SHELL_FEATURES", "cursor:blink,title");
    if (std.mem.eql(u8, shell, "zsh")) {
        if (environ.get("ZDOTDIR")) |old| try environ.put("GHOSTTY_ZSH_ZDOTDIR", old);
        const zdotdir = try std.fs.path.join(gpa, &.{ integration_dir, "zsh" });
        defer gpa.free(zdotdir);
        try environ.put("ZDOTDIR", zdotdir);
        return .{};
    }
    if (std.mem.eql(u8, shell, "fish")) {
        try environ.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", integration_dir);
        const old = environ.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        const dirs = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ integration_dir, old });
        defer gpa.free(dirs);
        try environ.put("XDG_DATA_DIRS", dirs);
        return .{};
    }
    // bash: ENV runs the integration in POSIX mode, which restores the
    // user's own startup files and history.
    if (environ.get("ENV")) |old| try environ.put("GHOSTTY_BASH_ENV", old);
    const script = try std.fs.path.join(gpa, &.{ integration_dir, "bash", "ghostty.bash" });
    defer gpa.free(script);
    try environ.put("ENV", script);
    try environ.put("GHOSTTY_BASH_INJECT", "1");
    if (environ.get("HISTFILE") == null) if (environ.get("HOME")) |home| {
        const histfile = try std.fs.path.join(gpa, &.{ home, ".bash_history" });
        defer gpa.free(histfile);
        try environ.put("HISTFILE", histfile);
    };
    return .{ .bash_posix = true };
}
