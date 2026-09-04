//! Unit tests for approval.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in approval.zig.

const std = @import("std");
const Io = std.Io;
const config = @import("../core/config.zig");

const approval = @import("approval.zig");
const Decision = approval.Decision;
const Gate = approval.Gate;
const Verdict = approval.Verdict;
const policyFor = approval.policyFor;

test {
    std.testing.refAllDecls(approval);
}

test "policyFor: defaults and auto mode" {
    const cfg = config.defaults();
    try std.testing.expectEqual(Decision.run, policyFor(cfg, .default, false, false));
    try std.testing.expectEqual(Decision.ask, policyFor(cfg, .default, true, false));
    try std.testing.expectEqual(Decision.run, policyFor(cfg, .auto, true, false));

    var deny_cfg = cfg;
    deny_cfg.mutating_tools_policy = .deny;
    try std.testing.expectEqual(Decision.deny, policyFor(deny_cfg, .default, true, false));
    try std.testing.expectEqual(Decision.run, policyFor(deny_cfg, .auto, true, false));
}

test "policyFor: auto-inside runs sandboxed calls without a prompt" {
    const cfg = config.defaults();
    try std.testing.expectEqual(Decision.run, policyFor(cfg, .default, true, true));

    // A session whose sandbox toggle is off never reaches this path with
    // sandboxed=true — the daemon only asserts it for enabled sessions with
    // a verified backend; an unsandboxed call keeps asking.
    try std.testing.expectEqual(Decision.ask, policyFor(cfg, .default, true, false));

    // Explicit deny is intent, not a missing safety net — sandbox never
    // overrides it.
    var deny_cfg = cfg;
    deny_cfg.mutating_tools_policy = .deny;
    try std.testing.expectEqual(Decision.deny, policyFor(deny_cfg, .default, true, true));
}

test "gate: cross-thread resolve" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var gate = Gate{};
    const Resolver = struct {
        fn run(g: *Gate, rio: Io) void {
            // Spin until the waiter arms the gate, then grant.
            while (true) {
                if (g.isPending(rio)) |id| {
                    _ = g.resolve(rio, id, .approved);
                    return;
                }
                rio.sleep(.fromMilliseconds(5), .awake) catch {};
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Resolver.run, .{ &gate, io });
    try std.testing.expect(gate.arm(io, 42, null));
    const v = gate.wait(io, 42);
    t.join();
    try std.testing.expectEqual(Verdict.approved, v);
}

test "gate: answer after arm but before wait is retained" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var gate = Gate{};

    try std.testing.expect(gate.arm(io, 42, null));
    try std.testing.expect(gate.resolve(io, 42, .approved));
    try std.testing.expectEqual(Verdict.approved, gate.wait(io, 42));
    try std.testing.expectEqual(@as(?u64, null), gate.isPending(io));
}

test "gate: stale id rejected" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var gate = Gate{};
    try std.testing.expect(!gate.resolve(io, 7, .approved));
}

test "gate: cancel unparks with denied" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var gate = Gate{};
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expect(!gate.arm(io, 1, &cancel));
    try std.testing.expectEqual(@as(?u64, null), gate.isPending(io));
}
