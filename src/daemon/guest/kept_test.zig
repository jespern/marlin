const std = @import("std");
const Io = std.Io;
const kept = @import("kept.zig");
const shared = @import("shared.zig");

// Case: a long Codex session failed every turn after a restart with
// "codex app-server exited mid-turn": its thread/resume reply, the whole
// thread on one line, was longer than the journal reader's buffer, and the
// reader called that a failed read rather than a line to accumulate.
test "a journal line longer than the reader's buffer is read whole" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-kept");
    defer temp.deinit();

    const long = try gpa.alloc(u8, 2 * 1024 * 1024);
    defer gpa.free(long);
    @memset(long, 'x');
    var journal: std.ArrayList(u8) = .empty;
    defer journal.deinit(gpa);
    try journal.appendSlice(gpa, "first\n");
    try journal.appendSlice(gpa, long);
    try journal.appendSlice(gpa, "\nlast\n");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out = try std.fmt.bufPrint(&path_buf, "{s}/out", .{temp.path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = out, .data = journal.items });

    // No keeper listens: the guest ended, and its journal is read to the end.
    const k = try kept.Kept.attach(gpa, io, temp.path);
    defer k.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var acc: std.ArrayList(u8) = .empty;
    const reader = &k.reader.interface;
    try std.testing.expectEqualStrings("first\n", (try shared.takeEventLine(reader, arena, &acc, shared.max_event_line_bytes)).?);
    const got = (try shared.takeEventLine(reader, arena, &acc, shared.max_event_line_bytes)).?;
    try std.testing.expectEqual(long.len + 1, got.len);
    try std.testing.expectEqualStrings("last\n", (try shared.takeEventLine(reader, arena, &acc, shared.max_event_line_bytes)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try shared.takeEventLine(reader, arena, &acc, shared.max_event_line_bytes));
}
