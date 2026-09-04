//! Unit tests for hooks.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in hooks.zig.

const std = @import("std");
const Io = std.Io;
const process_io = @import("process_io.zig");

const hooks = @import("hooks.zig");
const fireArgv = hooks.fireArgv;

test {
    std.testing.refAllDecls(hooks);
}

test "hook receives a stable event envelope" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try fireArgv(
        gpa,
        threaded.io(),
        &.{ "sh", "-c", "input=$(cat); case \"$input\" in *'\"event\":\"on_turn_done\"'*'\"sid\":7'*) exit 0;; *) exit 9;; esac" },
        .on_turn_done,
        "{\"sid\":7}",
        null,
    );
}

test "hook rejects non-object payloads before spawn" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.HookPayloadMustBeObject, fireArgv(
        gpa,
        threaded.io(),
        &.{"false"},
        .on_error,
        "[]",
        null,
    ));
}
