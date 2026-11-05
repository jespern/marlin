//! std.log routing. A full-screen TUI owns its terminal: a log line written
//! to stderr behind vaxis's back lands on screen and leaves vaxis's diff
//! believing cells hold what they no longer do, so stale characters linger.
//! Libraries log freely (libghostty-vt warns about every unimplemented mode
//! a shell-tab program sets), so while the TUI is up, logs are dropped.
const std = @import("std");

pub var tui_active: std.atomic.Value(bool) = .init(false);

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (tui_active.load(.acquire)) return;
    std.log.defaultLog(level, scope, format, args);
}
