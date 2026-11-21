//! Unit tests for handover.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in handover.zig.
const std = @import("std");
const handover = @import("handover.zig");

test {
    std.testing.refAllDecls(handover);
}

test "control lines arrive whole however the writes are split" {
    const gpa = std.testing.allocator;
    const pair = try handover.controlPair();
    defer for (pair) |fd| {
        _ = std.c.close(fd);
    };
    for ([_][]const u8{ "{\"ready\":", "{}}\n{\"arri", "ved\":{\"token\":\"ab\"}}\n" }) |part|
        try std.testing.expectEqual(@as(isize, @intCast(part.len)), std.c.write(pair[1], part.ptr, part.len));
    _ = std.c.shutdown(pair[1], std.c.SHUT.WR);

    var reader: handover.LineReader = .{ .fd = pair[0] };
    defer reader.deinit(gpa);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect(try handover.parseReport(arena, (try reader.next(gpa, 1024)).?) == .ready);
    const arrived = try handover.parseReport(arena, (try reader.next(gpa, 1024)).?);
    try std.testing.expectEqualStrings("ab", arrived.arrived.token);
    try std.testing.expect(try reader.next(gpa, 1024) == null);
}

test "the state crosses as one line, and a different format is refused" {
    const gpa = std.testing.allocator;
    const pair = try handover.controlPair();
    defer for (pair) |fd| {
        _ = std.c.close(fd);
    };
    const commands = [_]@import("../core/block.zig").ShellCommand{.{ .command = "make test", .exit_code = 2 }};
    const shells = [_]handover.ShellState{.{
        .id = 3,
        .sid = 7,
        .pid = 4242,
        .master_fd = 12,
        .cols = 80,
        .rows = 24,
        .cwd = "/work",
        .created_at_ms = 5,
        .ran = "htop",
        .commands = &commands,
        .snapshot_base64 = "c25hcA==",
    }};
    try handover.send(gpa, pair[1], handover.State{ .listen_fd = 5, .lock_fd = 6, .predecessor_pid = 99, .next_shell_id = 4, .shells = &shells });
    try handover.send(gpa, pair[1], .{ .version = handover.version + 1, .listen_fd = 5, .lock_fd = 6, .predecessor_pid = 99, .next_shell_id = 4 });

    var reader: handover.LineReader = .{ .fd = pair[0] };
    defer reader.deinit(gpa);
    const parsed = try handover.readState(gpa, &reader);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i32, 5), parsed.value.listen_fd);
    try std.testing.expectEqual(@as(u64, 4), parsed.value.next_shell_id);
    const shell = parsed.value.shells[0];
    try std.testing.expectEqual(@as(i32, 4242), shell.pid);
    try std.testing.expectEqualStrings("htop", shell.ran.?);
    try std.testing.expectEqual(@as(?i32, 2), shell.commands[0].exit_code);
    try std.testing.expectError(error.HandoverVersionMismatch, handover.readState(gpa, &reader));
}

test "a predecessor waits for exactly the tokens it handed out" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pending: handover.Pending = .{};
    defer pending.deinit(gpa);
    const first = handover.newToken(io);
    const second = handover.newToken(io);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    try pending.add(gpa, first);
    try pending.add(gpa, second);
    try std.testing.expect(!pending.arrive("0123456789abcdef0123456789abcdef"));
    try std.testing.expect(pending.arrive(&second));
    try std.testing.expect(!pending.arrive(&second));
    try std.testing.expect(!pending.empty());
    try std.testing.expect(pending.arrive(&first));
    try std.testing.expect(pending.empty());
}
