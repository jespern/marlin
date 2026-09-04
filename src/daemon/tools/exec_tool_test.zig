//! Unit tests for exec_tool.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in exec_tool.zig.

const std = @import("std");
const Io = std.Io;
const block = @import("../../core/block.zig");
const process_io = @import("../process_io.zig");

const exec_tool = @import("exec_tool.zig");
const run = exec_tool.run;

test {
    std.testing.refAllDecls(exec_tool);
}

test "exec tool receives JSON on stdin" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const result = run(
        gpa,
        threaded.io(),
        &.{ "sh", "-c", "input=$(cat); printf 'seen:%s' \"$input\"" },
        "{\"value\":42}",
        "/tmp",
        null,
        2_000,
        null,
    );
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expectEqualStrings("seen:{\"value\":42}", result.output);
}

test "exec tool makes nonzero exit model-visible" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const result = run(gpa, threaded.io(), &.{ "sh", "-c", "printf nope; exit 7" }, "{}", "/tmp", null, 2_000, null);
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.err, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "exit code: 7") != null);
}
