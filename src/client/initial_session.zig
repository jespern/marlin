//! Which session a bare `marlin` (no handle) lands in. The shell's directory
//! is the intent: the newest live root session already rooted there, else
//! none — and the caller creates one there. Over `--remote` the client's
//! directory says nothing about the daemon host, so the newest live session
//! wins as before.
const std = @import("std");
const proto = @import("../core/proto.zig");

/// Index into `sessions` (daemon order: newest tree first), or null when a
/// fresh session in `cwd` is the right answer.
pub fn pick(sessions: []const proto.SessionInfo, cwd: []const u8, remote: bool) ?usize {
    if (remote) {
        for (sessions, 0..) |session, i| if (!session.archived) return i;
        return null;
    }
    const want = trimSlash(cwd);
    for (sessions, 0..) |session, i| {
        if (session.archived or session.kind != .root) continue;
        if (std.mem.eql(u8, trimSlash(session.cwd), want)) return i;
    }
    return null;
}

fn trimSlash(path: []const u8) []const u8 {
    var p = path;
    while (p.len > 1 and p[p.len - 1] == '/') p = p[0 .. p.len - 1];
    return p;
}
