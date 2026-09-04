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
//! Threading: the TURN thread arms the gate before publishing the request,
//! then blocks in Gate.wait(); the DISPATCHER thread resolves via
//! Gate.resolve() when a client answers (or on interrupt).
//! TODO(M3.5): capability-scoped once/session grants and sandbox escalations.

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

/// `sandboxed`: this exact call will execute under the canary-verified
/// kernel sandbox (currently: bash with a Seatbelt backend). The sandbox
/// enforces what the ask-prompt was guarding — workspace write scope and
/// protected paths — so such a call runs without a per-call approval
/// (docs/PERMISSIONS.md auto-inside policy). The daemon asserts it only for
/// sessions whose /sandbox toggle is on AND whose backend verified; policy
/// trusts that upstream gate. An explicit deny still wins: deny is a
/// statement of intent, not a missing safety net.
pub fn policyFor(cfg: config.Config, mode: Mode, mutating: bool, sandboxed: bool) Decision {
    if (mode == .auto) return .run;
    const p = if (mutating) cfg.mutating_tools_policy else cfg.readonly_tools_policy;
    return switch (p) {
        .auto => .run,
        .ask => if (sandboxed) .run else .ask,
        .deny => .deny,
    };
}

/// One-shot blocking gate: turn thread arms then waits, dispatcher resolves.
/// Reused across calls within a session.
pub const Gate = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    /// Non-null while a request is pending; the id of that request.
    pending_id: ?u64 = null,
    verdict: ?Verdict = null,

    /// Publish must happen only after this succeeds: a client can otherwise
    /// answer before pending_id exists and have a valid decision discarded.
    pub fn arm(self: *Gate, io: Io, id: u64, cancel: ?*std.atomic.Value(bool)) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        // If cancellation already happened, don't park at all.
        if (cancel) |f| {
            if (f.load(.acquire)) return false;
        }
        // One session has one turn, and one turn asks about one call at a time.
        // Refuse to overwrite live state if either invariant is ever violated.
        if (self.pending_id != null) return false;
        self.pending_id = id;
        self.verdict = null;
        return true;
    }

    /// Called on the TURN thread after arm() and request publication. A valid
    /// answer may already have arrived; in that case this returns immediately.
    /// Interrupt paths call denyPending() because Io.Condition has no timed
    /// wait and cancellation is therefore a resolution, not a poll.
    pub fn wait(self: *Gate, io: Io, id: u64) Verdict {
        self.mutex.lockUncancelable(io);
        if (self.pending_id == null or self.pending_id.? != id) {
            self.mutex.unlock(io);
            return .denied;
        }
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
