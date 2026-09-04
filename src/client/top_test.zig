//! Unit tests for top.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in top.zig.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const render = @import("render.zig");
const Palette = render.Palette;

const top = @import("top.zig");
const RowView = top.RowView;
const computeColumns = top.computeColumns;
const formatAge = top.formatAge;
const orderedRows = top.orderedRows;
const rowDepth = top.rowDepth;
const truncateLeft = top.truncateLeft;

test {
    std.testing.refAllDecls(top);
}

test "top age labels use compact units" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("-", formatAge(&buf, 0, 59_000));
    try std.testing.expectEqualStrings("59s", formatAge(&buf, 1_000, 60_000));
    try std.testing.expectEqualStrings("1m", formatAge(&buf, 1_000, 61_000));
    try std.testing.expectEqualStrings("2h", formatAge(&buf, 1_000, 1_000 + 2 * 60 * 60 * 1000));
    try std.testing.expectEqualStrings("2d", formatAge(&buf, 1_000, 1_000 + 48 * 60 * 60 * 1000));
}

test "top columns shed optional fields on narrow terminals" {
    try std.testing.expect(computeColumns(100).cwd > 0);
    try std.testing.expect(computeColumns(60).model > 0);
    try std.testing.expectEqual(@as(usize, 0), computeColumns(45).model);
    try std.testing.expectEqual(@as(usize, 0), computeColumns(70).cwd);
}

test "top truncation keeps utf8 boundaries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const short = try truncateLeft(arena_state.allocator(), "alpha/βeta/file", 8);
    try std.testing.expect(std.unicode.utf8ValidateSlice(short));
    try std.testing.expect(render.displayWidth(short) <= 8);
}

test "top hierarchy depth follows parent chains" {
    const rows = [_]RowView{
        .{ .sid = 1, .parent_sid = null, .kind = .root, .state = .idle, .created_at = 1, .title = "root", .cwd = "/", .model = "m" },
        .{ .sid = 2, .parent_sid = 1, .kind = .task_child, .state = .idle, .created_at = 2, .title = "child", .cwd = "/", .model = "m" },
        .{ .sid = 3, .parent_sid = 2, .kind = .task_child, .state = .idle, .created_at = 3, .title = "grandchild", .cwd = "/", .model = "m" },
    };
    try std.testing.expectEqual(@as(usize, 0), rowDepth(&rows, rows[0]));
    try std.testing.expectEqual(@as(usize, 1), rowDepth(&rows, rows[1]));
    try std.testing.expectEqual(@as(usize, 2), rowDepth(&rows, rows[2]));
}

test "top orders oldest roots first while keeping descendants together" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const rows = [_]RowView{
        .{ .sid = 30, .parent_sid = null, .kind = .root, .state = .idle, .created_at = 30, .title = "newest", .cwd = "/", .model = "m" },
        .{ .sid = 21, .parent_sid = 20, .kind = .task_child, .state = .idle, .created_at = 22, .title = "later child", .cwd = "/", .model = "m" },
        .{ .sid = 10, .parent_sid = null, .kind = .root, .state = .idle, .created_at = 10, .title = "oldest", .cwd = "/", .model = "m" },
        .{ .sid = 20, .parent_sid = null, .kind = .root, .state = .idle, .created_at = 20, .title = "middle", .cwd = "/", .model = "m" },
        .{ .sid = 22, .parent_sid = 20, .kind = .task_child, .state = .idle, .created_at = 21, .title = "earlier child", .cwd = "/", .model = "m" },
    };
    const ordered = try orderedRows(arena_state.allocator(), &rows);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 22, 21, 30 }, &.{
        ordered[0].sid,
        ordered[1].sid,
        ordered[2].sid,
        ordered[3].sid,
        ordered[4].sid,
    });
}
