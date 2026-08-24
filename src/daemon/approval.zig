//! Approval system (docs/ARCHITECTURE.md §7). Designed in from day one:
//! EVERY tool execution flows through the gate; in auto-mode sessions the
//! answer is immediate.
//!
//! Policy per tool per session: auto | ask | deny. Defaults: read-only auto,
//! mutating ask; session approvals mode "auto" (headless / --yolo) flips all
//! to auto. `ask` emits approval_request to all subscribed clients; first
//! decision wins; no timeout — the turn parks in awaiting_approval (that
//! parked state is exactly what the session picker/status summary/phone surfaces).
//!
//! Threading: the TURN thread blocks in Gate.wait(); the DISPATCHER thread
//! resolves via Gate.resolve() when a client answers (or on interrupt).
//! TODO(M6): allowlist patterns + promotion UX, bash sandboxing hooks.

const std = @import("std");
const Io = std.Io;

const config = @import("../core/config.zig");

pub const Verdict = enum { approved, denied };

/// Session-level approval mode, set at session_create.
pub const Mode = enum {
    /// Read-only auto, mutating ask.
    default,
    /// Everything auto (headless one-shots, --yolo).
    auto,

    pub fn parse(s: []const u8) Mode {
        if (std.mem.eql(u8, s, "auto")) return .auto;
        return .default;
    }
};

/// What to do for one call, derived from policy — before asking anyone.
pub const Decision = enum { run, ask, deny };

pub fn policyFor(cfg: config.Config, mode: Mode, mutating: bool) Decision {
    if (mode == .auto) return .run;
    const p = if (mutating) cfg.mutating_tools_policy else cfg.readonly_tools_policy;
    return switch (p) {
        .auto => .run,
        .ask => .ask,
        .deny => .deny,
    };
}

/// One-shot blocking gate: turn thread waits, dispatcher resolves.
/// Reused across calls within a session (re-armed by wait()).
pub const Gate = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Non-null while a request is pending; the id of that request.
    pending_id: ?u64 = null,
    verdict: ?Verdict = null,

    /// Called on the TURN thread. Arms the gate for `id` and blocks until
    /// resolve(). Interrupt paths must call denyPending() — there is no
    /// timed wait on Io.Condition, so cancellation is a resolve, not a poll.
    pub fn wait(self: *Gate, io: Io, id: u64, cancel: ?*std.atomic.Value(bool)) Verdict {
        self.mutex.lockUncancelable(io);
        // If cancellation already happened, don't park at all.
        if (cancel) |f| {
            if (f.load(.acquire)) {
                self.mutex.unlock(io);
                return .denied;
            }
        }
        self.pending_id = id;
        self.verdict = null;
        while (self.verdict == null) {
            self.cond.waitUncancelable(io, &self.mutex);
        }
        const v = self.verdict.?;
        self.pending_id = null;
        self.verdict = null;
        self.mutex.unlock(io);
        return v;
    }

    /// Called on the DISPATCHER thread. Returns false when `id` is not the
    /// pending request (stale/duplicate answer — first decision won).
    pub fn resolve(self: *Gate, io: Io, id: u64, v: Verdict) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const pending = self.pending_id orelse return false;
        if (pending != id) return false;
        if (self.verdict != null) return false;
        self.verdict = v;
        self.cond.signal(io);
        return true;
    }

    /// Is a request currently parked? (For status displays / re-broadcast.)
    pub fn isPending(self: *Gate, io: Io) ?u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.pending_id;
    }

    /// Deny whatever is pending (interrupt / shutdown path). No-op when idle.
    pub fn denyPending(self: *Gate, io: Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.pending_id == null) return;
        if (self.verdict != null) return;
        self.verdict = .denied;
        self.cond.signal(io);
    }
};

// ---------------------------------------------------------------- tests --

test "policyFor: defaults and auto mode" {
    const cfg = config.defaults();
    try std.testing.expectEqual(Decision.run, policyFor(cfg, .default, false));
    try std.testing.expectEqual(Decision.ask, policyFor(cfg, .default, true));
    try std.testing.expectEqual(Decision.run, policyFor(cfg, .auto, true));

    var deny_cfg = cfg;
    deny_cfg.mutating_tools_policy = .deny;
    try std.testing.expectEqual(Decision.deny, policyFor(deny_cfg, .default, true));
    try std.testing.expectEqual(Decision.run, policyFor(deny_cfg, .auto, true));
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
    const v = gate.wait(io, 42, null);
    t.join();
    try std.testing.expectEqual(Verdict.approved, v);
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
    const v = gate.wait(io, 1, &cancel);
    try std.testing.expectEqual(Verdict.denied, v);
}
