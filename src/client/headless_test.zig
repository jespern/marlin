//! Unit tests for headless.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in headless.zig.

const std = @import("std");
const Io = std.Io;
const block = @import("../core/block.zig");
const proto = @import("../core/proto.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const media = @import("media.zig");
const self_build = @import("self_build.zig");

const headless = @import("headless.zig");
const RebuildActions = headless.RebuildActions;
const RebuildScope = headless.RebuildScope;
const inspect = headless.inspect;
const parseFlags = headless.parseFlags;
const parseInspectOptions = headless.parseInspectOptions;
const parseRebootOptions = headless.parseRebootOptions;
const reboot = headless.reboot;
const rebuildActions = headless.rebuildActions;

test {
    std.testing.refAllDecls(headless);
}

test "reboot scopes map to local and remote actions" {
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = false, .reboot_daemon = true },
        rebuildActions(.attached, false),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = false, .remote = true, .reboot_daemon = true },
        rebuildActions(.attached, true),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = false, .reboot_daemon = false },
        rebuildActions(.client, true),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = true, .reboot_daemon = true },
        rebuildActions(.both, true),
    );
}

test "reboot option parsing preserves follow-up arguments" {
    const args = [_][:0]const u8{ "--build-both", "--force", "--then", "attach", "@7" };
    const options = try parseRebootOptions(&args);
    try std.testing.expectEqual(RebuildScope.both, options.rebuild);
    try std.testing.expect(options.force);
    try std.testing.expectEqual(@as(?usize, 3), options.follow_up_at);
    try std.testing.expectError(error.InvalidArgument, parseRebootOptions(&.{"--bogus"}));
}

test "flag parsing" {
    const args = [_][:0]const u8{ "--continue", "--model", "openrouter/x", "do stuff" };
    const f = try parseFlags(&args);
    try std.testing.expect(f.continue_last);
    try std.testing.expectEqualStrings("openrouter/x", f.model.?);
    try std.testing.expectEqualStrings("do stuff", f.task.?);
}

test "inspect option parsing" {
    const args = [_][:0]const u8{ "63df", "--json", "--kind", "tool_result", "--limit", "40", "--around", "12", "--turn", "latest" };
    const options = try parseInspectOptions(&args);
    try std.testing.expectEqualStrings("63df", options.handle.?);
    try std.testing.expect(options.json);
    try std.testing.expectEqual(block.BlockKind.tool_result, options.kind.?);
    try std.testing.expectEqual(@as(u32, 40), options.limit);
    try std.testing.expectEqual(@as(u64, 12), options.around_seq);
    try std.testing.expect(options.latest_turn);
}

test "inspect option parsing rejects unsafe or contradictory bounds" {
    try std.testing.expectError(error.InvalidLimit, parseInspectOptions(&.{ "63df", "--limit", "0" }));
    try std.testing.expectError(error.InvalidKind, parseInspectOptions(&.{ "63df", "--kind", "bogus" }));
    try std.testing.expectError(error.ConflictingOptions, parseInspectOptions(&.{ "63df", "--plan", "--turn", "latest" }));
    try std.testing.expectError(error.MissingHandle, parseInspectOptions(&.{"--json"}));
}
