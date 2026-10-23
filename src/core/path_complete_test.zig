const std = @import("std");
const path_complete = @import("path_complete.zig");
const temp_dir = @import("../testing/temp_dir.zig");

fn names(cands: []const path_complete.Candidate, buf: [][]const u8) [][]const u8 {
    for (cands, 0..) |c, i| buf[i] = c.arg;
    return buf[0..cands.len];
}

test "directories under the session cwd, hidden and files excluded, sorted, typed prefix preserved" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try temp_dir.Dir.initFromProcess(gpa, io, "cwd-complete");
    defer tmp.deinit();
    var root = try std.Io.Dir.cwd().openDir(io, tmp.path, .{});
    defer root.close(io);
    try root.createDirPath(io, "beta/inner");
    try root.createDirPath(io, "alpha");
    try root.createDirPath(io, ".hidden");
    (try root.createFile(io, "afile", .{})).close(io);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [16][]const u8 = undefined;

    const all = try path_complete.directories(arena, io, tmp.path, null, "");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{ "alpha/", "beta/" }), names(all, &buf));

    const al = try path_complete.directories(arena, io, tmp.path, null, "al");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"alpha/"}), names(al, &buf));
    try std.testing.expectEqualStrings("alpha", al[0].name);

    const deeper = try path_complete.directories(arena, io, tmp.path, null, "beta/");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"beta/inner/"}), names(deeper, &buf));

    const hidden = try path_complete.directories(arena, io, tmp.path, null, ".h");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{".hidden/"}), names(hidden, &buf));

    try std.testing.expectEqual(@as(usize, 0), (try path_complete.directories(arena, io, tmp.path, null, "nope/")).len);
    try std.testing.expectEqual(@as(usize, 0), (try path_complete.directories(arena, io, tmp.path, null, "afile")).len);
}

test "~ expands against HOME for lookup but stays ~ in the suggestion; absolute paths stay absolute" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try temp_dir.Dir.initFromProcess(gpa, io, "cwd-home");
    defer tmp.deinit();
    var root = try std.Io.Dir.cwd().openDir(io, tmp.path, .{});
    defer root.close(io);
    try root.createDirPath(io, "Work/marlin");

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [16][]const u8 = undefined;

    const tilde = try path_complete.directories(arena, io, "/nonexistent", tmp.path, "~");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"~/"}), names(tilde, &buf));
    const under_home = try path_complete.directories(arena, io, "/nonexistent", tmp.path, "~/Wo");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"~/Work/"}), names(under_home, &buf));
    const nested = try path_complete.directories(arena, io, "/nonexistent", tmp.path, "~/Work/");
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"~/Work/marlin/"}), names(nested, &buf));
    // No HOME: ~ cannot be resolved, so nothing is offered rather than a wrong guess.
    try std.testing.expectEqual(@as(usize, 0), (try path_complete.directories(arena, io, tmp.path, null, "~/")).len);
    try std.testing.expectEqual(@as(usize, 0), (try path_complete.directories(arena, io, tmp.path, null, "~")).len);

    const abs_typed = try std.fmt.allocPrint(arena, "{s}/Wo", .{tmp.path});
    const absolute = try path_complete.directories(arena, io, "/nonexistent", null, abs_typed);
    try std.testing.expectEqual(@as(usize, 1), absolute.len);
    try std.testing.expect(std.mem.startsWith(u8, absolute[0].arg, tmp.path));
    try std.testing.expect(std.mem.endsWith(u8, absolute[0].arg, "/Work/"));
}

test "shell completion uses all matches and stops at an ambiguous prefix" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try temp_dir.Dir.initFromProcess(gpa, io, "cwd-shell");
    defer tmp.deinit();
    var root = try std.Io.Dir.cwd().openDir(io, tmp.path, .{});
    defer root.close(io);
    try root.createDirPath(io, "projects/marlin");
    try root.createDirPath(io, "projects/mobile");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("projects/", try path_complete.complete(arena, io, tmp.path, null, "proj"));
    try std.testing.expectEqualStrings("projects/m", try path_complete.complete(arena, io, tmp.path, null, "projects/"));
    try std.testing.expectEqualStrings("projects/m", try path_complete.complete(arena, io, tmp.path, null, "projects/m"));
    try std.testing.expectEqualStrings("projects/marlin/", try path_complete.complete(arena, io, tmp.path, null, "projects/ma"));
    try std.testing.expectEqualStrings("PROJ", try path_complete.complete(arena, io, tmp.path, null, "PROJ"));
    for (0..13) |i| try root.createDirPath(io, try std.fmt.allocPrint(arena, "many/shared{d}", .{i}));
    try root.createDirPath(io, "many/zebra");
    try std.testing.expectEqualStrings("many/", try path_complete.complete(arena, io, tmp.path, null, "many/"));
    try root.createDirPath(io, "unicode/é");
    try root.createDirPath(io, "unicode/ê");
    try std.testing.expectEqualStrings("unicode/", try path_complete.complete(arena, io, tmp.path, null, "unicode/"));
}
