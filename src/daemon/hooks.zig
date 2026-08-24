//! Hook runner: daemon events → user scripts (docs/ARCHITECTURE.md §7).
//!
//! Events: on_session_done, on_approval_needed, on_error, on_turn_done.
//! Contract: run the configured script with the JSON event on stdin, 10s
//! timeout, exit code logged but never fatal. This is the notification story
//! (ntfy/Telegram/say) without a gateway in the core.

const std = @import("std");
const Io = std.Io;

const process_io = @import("process_io.zig");

pub const Kind = enum {
    on_session_done,
    on_approval_needed,
    on_error,
    on_turn_done,
};

pub const timeout_ms: u32 = 10_000;

/// Invoke one configured hook. `payload_json` must be a JSON object; Marlin
/// wraps it with a stable event name so a single script can serve every hook.
/// Hook failures are logged and returned, but callers deliberately keep them
/// outside the agent turn's success/failure path.
pub fn fire(
    gpa: std.mem.Allocator,
    io: Io,
    script: []const u8,
    kind: Kind,
    payload_json: []const u8,
    child_environ: ?*const std.process.Environ.Map,
) !void {
    return fireArgv(gpa, io, &.{script}, kind, payload_json, child_environ);
}

fn fireArgv(
    gpa: std.mem.Allocator,
    io: Io,
    argv: []const []const u8,
    kind: Kind,
    payload_json: []const u8,
    child_environ: ?*const std.process.Environ.Map,
) !void {
    var parsed_arena = std.heap.ArenaAllocator.init(gpa);
    defer parsed_arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, parsed_arena.allocator(), payload_json, .{});
    if (parsed != .object) return error.HookPayloadMustBeObject;

    const input = try std.fmt.allocPrint(
        gpa,
        "{{\"event\":\"{s}\",\"payload\":{s}}}\n",
        .{ @tagName(kind), payload_json },
    );
    defer gpa.free(input);
    const result = try process_io.run(gpa, io, .{
        .argv = argv,
        .stdin = input,
        .environ_map = child_environ,
        .stdout_limit = 256 * 1024,
        .stderr_limit = 256 * 1024,
        .timeout_ms = timeout_ms,
    });
    defer result.deinit(gpa);

    const ok = result.term == .exited and result.term.exited == 0;
    if (!ok) {
        std.log.warn("hook {s} failed ({t}): {s}", .{ @tagName(kind), result.term, result.stderr });
        return error.HookFailed;
    }
    if (result.stderr.len > 0) std.log.info("hook {s}: {s}", .{ @tagName(kind), result.stderr });
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

test {
    std.testing.refAllDecls(@This());
}
