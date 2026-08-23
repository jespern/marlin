//! Context assembly + the compaction cascade (docs/ARCHITECTURE.md §6).
//!
//! Assembly (derived from the block log at turn start, NEVER stored):
//!   [system prompt: base + skills index + pinned context]
//!   [compaction summaries, oldest first]
//!   [blocks after the last compaction point, mapped to messages]
//!
//! Cascade:
//!   L0  capture caps      — inline tool bodies capped at write time (store.zig
//!                           holds the full blob; this file decides the cap)
//!   L1  mechanical prune  — stub old tool_result inline bodies, protect the
//!                           most recent prune_protect_tokens of tool output;
//!                           only fire if ≥ prune_min_reclaim_tokens reclaimable
//!   L2  summarize+rehydrate — headroom-triggered or manual /compact; summary
//!                           contract: accomplished / in-progress / files w/
//!                           paths / next steps / constraints+decisions. Then
//!                           rehydrate: recent written files + todos + continue.
//!   L3  subagents         — task tool isolates bulky work (M6)
//!
//! Cache discipline: between L1/L2 events assembly is strictly append-only
//! with a byte-stable prefix. L1/L2 are the only cache breaks; both rare,
//! both logged as system_note blocks.
//!
//! Token accounting: provider-reported usage is ground truth; bytes/4 for
//! the unsent delta. No tokenizers in the binary.

const std = @import("std");
const config = @import("../core/config.zig");

/// Estimate tokens for text not yet measured by the provider.
pub fn estimateTokens(bytes: []const u8) u64 {
    return bytes.len / 4 + 1;
}

// TODO(M0): assemble() blocks→messages, L0 cap application.
// TODO(M3): L1 prune w/ hysteresis, L2 trigger math
//           (limit - used < output_headroom + compaction_headroom, checked at
//           turn boundaries), summarization call, rehydration, fixture tests.

test "token estimate is monotone-ish" {
    try std.testing.expect(estimateTokens("hello world") >= 2);
    try std.testing.expect(estimateTokens("") == 1);
}
