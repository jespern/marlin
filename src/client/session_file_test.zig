//! Unit tests for session_file.zig. Tests live beside the module they cover.

const std = @import("std");
const Io = std.Io;
const session_handle = @import("../core/session_handle.zig");
const session_file = @import("session_file.zig");

test {
    std.testing.refAllDecls(session_file);
}

test "session file atomically contains the complete stable handle" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-session-file");
    defer temp.deinit();
    const path = try std.fs.path.join(gpa, &.{ temp.path, "nested", "session" });
    defer gpa.free(path);

    try session_file.write(io, path, 42);
    const contents = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
    defer gpa.free(contents);
    const expected = session_handle.full(42);
    try std.testing.expectEqual(session_handle.full_len + 1, contents.len);
    try std.testing.expectEqualStrings(&expected, contents[0..session_handle.full_len]);
    try std.testing.expectEqual(@as(u8, '\n'), contents[session_handle.full_len]);
}

test "session file replaces an existing value" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-session-file-replace");
    defer temp.deinit();
    const path = try std.fs.path.join(gpa, &.{ temp.path, "session" });
    defer gpa.free(path);

    try session_file.write(io, path, 42);
    try session_file.write(io, path, 43);
    const contents = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1024));
    defer gpa.free(contents);
    const expected = session_handle.full(43);
    try std.testing.expectEqualStrings(&expected, contents[0..session_handle.full_len]);
}

test "session file rejects an empty path" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.EmptyPath, session_file.write(threaded.io(), "", 42));
}
