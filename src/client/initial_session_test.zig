const std = @import("std");
const proto = @import("../core/proto.zig");
const initial_session = @import("initial_session.zig");

fn session(sid: u64, cwd: []const u8, archived: bool, kind: proto.SessionKind) proto.SessionInfo {
    return .{
        .sid = sid,
        .kind = kind,
        .title = "",
        .cwd = cwd,
        .model = "m",
        .status = "idle",
        .created_at = 0,
        .running = false,
        .archived = archived,
    };
}

test "bare marlin lands in the newest live root session rooted in the shell's directory" {
    const sessions = [_]proto.SessionInfo{
        session(3, "/home/j/other", false, .root),
        session(2, "/home/j/work", false, .root),
        session(1, "/home/j/work", false, .root),
    };
    try std.testing.expectEqual(@as(?usize, 1), initial_session.pick(&sessions, "/home/j/work", false));
    try std.testing.expectEqual(@as(?usize, 1), initial_session.pick(&sessions, "/home/j/work/", false)); // trailing slash
}

test "no session in this directory means a new one: null, even when others exist" {
    const sessions = [_]proto.SessionInfo{
        session(2, "/home/j/work", false, .root),
        session(1, "/home/j/work/sub", false, .root), // a subdirectory is not a match
    };
    try std.testing.expectEqual(@as(?usize, null), initial_session.pick(&sessions, "/home/j", false));
    try std.testing.expectEqual(@as(?usize, null), initial_session.pick(&sessions, "/home/j/work/sub/deeper", false));
    try std.testing.expectEqual(@as(?usize, null), initial_session.pick(&.{}, "/home/j", false));
}

test "archived sessions and children never match; an archived match yields a new session" {
    const sessions = [_]proto.SessionInfo{
        session(3, "/home/j/work", true, .root),
        session(2, "/home/j/work", false, .task_child),
    };
    try std.testing.expectEqual(@as(?usize, null), initial_session.pick(&sessions, "/home/j/work", false));
}

test "over --remote the newest live session wins regardless of directory" {
    const sessions = [_]proto.SessionInfo{
        session(3, "/srv/a", true, .root),
        session(2, "/srv/b", false, .root),
        session(1, "/home/j/work", false, .root),
    };
    try std.testing.expectEqual(@as(?usize, 1), initial_session.pick(&sessions, "/home/j/work", true));
    try std.testing.expectEqual(@as(?usize, null), initial_session.pick(&.{}, "/home/j/work", true));
}
