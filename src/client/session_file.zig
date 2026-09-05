//! Atomic publication of the session selected by an attach client.

const std = @import("std");
const Io = std.Io;
const session_handle = @import("../core/session_handle.zig");

/// Write the complete stable handle followed by a newline. Full handles remain
/// resolvable even if later sessions force display handles to grow.
pub fn write(io: Io, path: []const u8, sid: u64) !void {
    if (path.len == 0) return error.EmptyPath;
    const handle = session_handle.full(sid);
    var contents: [session_handle.full_len + 1]u8 = undefined;
    @memcpy(contents[0..session_handle.full_len], &handle);
    contents[session_handle.full_len] = '\n';

    var atomic = try Io.Dir.cwd().createFileAtomic(io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, &contents);
    try atomic.file.sync(io);
    try atomic.replace(io);
}
