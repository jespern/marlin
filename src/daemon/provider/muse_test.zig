//! Unit tests for muse.zig: Muse Code's command ids, profiles, and items.
const std = @import("std");
const muse = @import("muse.zig");

test "command ids are UUIDv7: time first, then version and variant" {
    var buf: [36]u8 = undefined;
    var random: [16]u8 = undefined;
    @memset(&random, 0xff);
    const id = muse.formatUuid7(0x01a1c358cbf4, random, &buf);
    try std.testing.expectEqualStrings("01a1c358-cbf4-7fff-bfff-ffffffffffff", id);

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var live_buf: [36]u8 = undefined;
    const live = muse.commandId(threaded.io(), &live_buf);
    try std.testing.expectEqual(@as(u8, '7'), live[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", live[19]) != null);
}

test "Marlin's permissions pick Muse's profile" {
    try std.testing.expectEqualStrings(":ask-me", muse.permissionProfile(true, false));
    try std.testing.expectEqualStrings(":unrestricted", muse.permissionProfile(true, true));
    try std.testing.expectEqualStrings(":read-only", muse.permissionProfile(false, true));
}

test "effort maps onto Muse's names, and auto keeps its default" {
    try std.testing.expectEqual(@as(?[]const u8, null), muse.reasoningEffort(.auto));
    try std.testing.expectEqualStrings("minimal", muse.reasoningEffort(.none).?);
    try std.testing.expectEqualStrings("xhigh", muse.reasoningEffort(.xhigh).?);
    try std.testing.expectEqual(@as(?[]const u8, null), muse.modelId("default"));
    try std.testing.expectEqualStrings("muse-wonder-1.0", muse.modelId("muse-wonder-1.0").?);
}

test "a shell call's output is unwrapped from Muse's envelope" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // As `muse serve` 1.4.14 reported `wc -l notes.txt`.
    const envelope =
        \\{
        \\  "chunk_id": "exec-1-1",
        \\  "command": "wc -l notes.txt",
        \\  "exit_code": 0,
        \\  "terminal_status": "completed",
        \\  "output": "       3 notes.txt\n",
        \\  "truncated": false
        \\}
    ;
    try std.testing.expectEqualStrings("       3 notes.txt\n", muse.toolOutput(arena, envelope));
    const failed =
        \\{"exit_code": 2, "terminal_status": "completed", "output": "no such file"}
    ;
    try std.testing.expectEqualStrings("no such file\n[exit 2]", muse.toolOutput(arena, failed));
    try std.testing.expectEqualStrings("Read text file `a.txt`.", muse.toolOutput(arena, "Read text file `a.txt`."));
}

test "Muse's tools take Marlin's names where they mean the same" {
    try std.testing.expectEqualStrings("Bash", muse.toolName("bash"));
    try std.testing.expectEqualStrings("Read", muse.toolName("read_file"));
    try std.testing.expectEqualStrings("request_user_input", muse.toolName("request_user_input"));
}

test "background kinds and auth errors" {
    try std.testing.expect(muse.isBackgroundKind("workflow"));
    try std.testing.expect(!muse.isBackgroundKind("subagent"));
    try std.testing.expect(!muse.isBackgroundKind("toolCall"));
    // As `muse serve` 1.4.14 updated a subagent: still inProgress, now done.
    var running = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"kind":"subagent","status":"inProgress","subagentId":"a"}
    , .{});
    defer running.deinit();
    try std.testing.expect(!muse.subagentDone(running.value));
    var finished = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"kind":"subagent","status":"inProgress","subagentId":"a","durationMs":8939}
    , .{});
    defer finished.deinit();
    try std.testing.expect(muse.subagentDone(finished.value));
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"kind":"authRequired","message":"not logged in: run /login to add an API key","retryable":false}
    , .{});
    defer parsed.deinit();
    try std.testing.expect(muse.isAuthError(parsed.value));
}
