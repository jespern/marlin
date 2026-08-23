//! Approval system (docs/ARCHITECTURE.md §7). Designed in from day one:
//! EVERY tool execution flows through requestApproval(), even in M0 where
//! the policy answer is always `auto`.
//!
//! Policy per tool per session: auto | ask | deny. Defaults: read-only auto,
//! mutating ask; --yolo flips all to auto for that session.
//! `ask` emits approval_request to all subscribed clients; first decision
//! wins; no timeout by default — the turn parks in awaiting_approval (that
//! parked state is exactly what the sidebar/phone surfaces).
//! Allowlist promotion: approving `git status` offers "always allow `git *`
//! in this session".

const std = @import("std");
const config = @import("../core/config.zig");

pub const Verdict = enum { approved, denied };

// TODO(M0): policy table + auto path only.
// TODO(M2): ask path (protocol round-trip), inline prompt cards in TUI.
// TODO(M6): allowlist patterns + promotion UX, bash sandboxing hooks.

test {
    std.testing.refAllDecls(@This());
}
