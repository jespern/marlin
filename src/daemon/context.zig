//! Context assembly + the compaction cascade (docs/ARCHITECTURE.md §6).
//!
//! Context for each request is DERIVED from the block log at turn start:
//!
//!   [system prompt]
//!   [compaction summaries, oldest first]
//!   [blocks after the last compaction point, mapped to messages]
//!
//! The cascade (each layer fires only if the previous wasn't enough):
//!   L0 — capture caps: applied at tool-result creation time (loop.zig),
//!        nothing bulky enters the log's inline bodies raw.
//!   L1 — mechanical pruning (no LLM): replace old tool_result bodies with
//!        stubs, protecting the most recent prune_protect_tokens of output.
//!        Pruning is IN-MEMORY per assembly (blocks are immutable); the
//!        prune frontier (seq) is session state with hysteresis so the
//!        assembled prefix stays byte-stable between prune events.
//!   L2 — summarization compaction (LLM): summarize [start..cut], append a
//!        compaction block, rehydrate recently-written files + a
//!        continuation note. Triggered by headroom accounting at turn
//!        boundaries, or manually via /compact.
//!
//! Cache discipline: between L1/L2 events assembly is strictly append-only
//! with a byte-stable prefix. L1/L2 are the only cache breaks; both are
//! logged as system_note blocks so cost anomalies are explainable.

const std = @import("std");
const config = @import("../core/config.zig");
const block = @import("../core/block.zig");
const provider = @import("provider/provider.zig");

/// Estimate tokens for text not yet measured by the provider.
pub fn estimateTokens(bytes: []const u8) u64 {
    return bytes.len / 4 + 1;
}

pub const system_prompt_base =
    \\You are marlin, a fast and direct AI agent running in a terminal harness.
    \\You have tools to run shell commands and read files. Use them to complete
    \\the user's task; verify with real output rather than assuming. Be concise.
    \\When done, state the result plainly.
;

/// Apply the L0 inline cap to a tool output destined for context: head+tail
/// window with an elision marker. Returns a slice of `full` or an allocation.
pub fn capInline(gpa: std.mem.Allocator, full: []const u8, cap: usize) ![]const u8 {
    if (full.len <= cap) return full;
    const head = cap * 2 / 3;
    const tail = cap - head;
    return std.fmt.allocPrint(gpa, "{s}\n[... {d} bytes elided — full output stored ...]\n{s}", .{
        full[0..head],
        full.len - cap,
        full[full.len - tail ..],
    });
}

pub const prune_stub = "[output elided to save context — re-run the tool or read the file if needed]";

/// Per-model context window. Provider-agnostic lookup by substring; the
/// registry model string ("openrouter/anthropic/claude-sonnet-4.5") is
/// matched against known families. Unknown models get a conservative 128k.
pub fn contextLimit(model: []const u8) u64 {
    const table = .{
        .{ "claude", @as(u64, 200_000) },
        .{ "gpt-5", @as(u64, 272_000) },
        .{ "gpt-4o", @as(u64, 128_000) },
        .{ "gemini", @as(u64, 1_000_000) },
        .{ "deepseek", @as(u64, 128_000) },
        .{ "qwen", @as(u64, 262_144) },
        .{ "kimi", @as(u64, 262_144) },
        .{ "glm", @as(u64, 200_000) },
        .{ "grok", @as(u64, 256_000) },
    };
    inline for (table) |entry| {
        if (indexOfIgnoreCase(model, entry[0]) != null) return entry[1];
    }
    return 128_000;
}

/// std.ascii lost indexOfIgnoreCase in the 0.16 refactor; local replacement.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Options for assembly. `prune_before_seq` is the session's L1 frontier:
/// tool_result blocks with seq < frontier get their inline bodies stubbed.
pub const AssembleOpts = struct {
    prune_before_seq: u64 = 0,
};

/// Assemble provider messages from a block log slice. All returned message
/// payloads reference either `blocks` memory or `arena` allocations — use an
/// arena scoped to the turn.
///
/// Compaction blocks partition the log: for each compaction block, its
/// summary is emitted (as a user message, oldest first) and every block with
/// seq in [covers_from_seq, covers_to_seq] is skipped. Blocks arriving after
/// the last compaction point are mapped normally.
pub fn assemble(
    arena: std.mem.Allocator,
    blocks: []const block.Block,
    opts: AssembleOpts,
) ![]provider.Message {
    var msgs: std.ArrayList(provider.Message) = .empty;
    try msgs.append(arena, .{ .role = .system, .payload = .{ .text = system_prompt_base } });

    // Pass 1: collect compaction coverage. Ranges may nest (a later
    // compaction covers an earlier compaction block itself); a block is
    // skipped if ANY compaction covers it. Summaries of covered compaction
    // blocks are superseded and not emitted.
    var covered_max: u64 = 0; // highest covers_to_seq seen
    for (blocks) |b| {
        switch (b.body) {
            .compaction => |cp| covered_max = @max(covered_max, cp.covers_to_seq),
            else => {},
        }
    }

    // Emit surviving compaction summaries oldest-first: a compaction block
    // survives when no other compaction's range covers its seq.
    for (blocks) |b| {
        switch (b.body) {
            .compaction => |cp| {
                if (coveredByOther(blocks, b.seq)) continue;
                const summary_msg = try std.fmt.allocPrint(arena,
                    \\[Earlier conversation summarized:]
                    \\{s}
                , .{cp.summary});
                try msgs.append(arena, .{ .role = .user, .payload = .{ .text = summary_msg } });
            },
            else => {},
        }
    }

    // Pass 2: map non-covered, non-compaction blocks to messages.
    var i: usize = 0;
    while (i < blocks.len) : (i += 1) {
        const b = blocks[i];
        if (b.seq <= covered_max) continue; // inside a summarized range
        switch (b.body) {
            .user_msg => |u| try msgs.append(arena, .{ .role = .user, .payload = .{ .text = u.text } }),
            .steer => |s| try msgs.append(arena, .{ .role = .user, .payload = .{ .text = s.text } }),
            .assistant_msg => |a| try msgs.append(arena, .{ .role = .assistant, .payload = .{ .text = a.text } }),
            .tool_call => {
                // Collect consecutive tool_call blocks of this turn.
                var calls: std.ArrayList(provider.ToolCall) = .empty;
                var j = i;
                while (j < blocks.len) : (j += 1) {
                    switch (blocks[j].body) {
                        .tool_call => |tc| try calls.append(arena, .{
                            .call_id = tc.call_id,
                            .name = tc.name,
                            .args_json = tc.args_json,
                        }),
                        else => break,
                    }
                }
                try msgs.append(arena, .{ .role = .assistant, .payload = .{
                    .assistant_tool_calls = .{ .text = "", .calls = calls.items },
                } });
                // Then their results (interleaved tool_result blocks).
                while (j < blocks.len) : (j += 1) {
                    switch (blocks[j].body) {
                        .tool_result => |tr| try msgs.append(arena, .{ .role = .tool, .payload = .{
                            .tool_result = .{
                                .call_id = tr.call_id,
                                .text = pruneBody(blocks[j].seq, tr.inline_body, opts),
                            },
                        } }),
                        else => break,
                    }
                }
                i = j - 1;
            },
            .tool_result => |tr| {
                // Orphan result (shouldn't happen; be tolerant).
                try msgs.append(arena, .{ .role = .tool, .payload = .{
                    .tool_result = .{
                        .call_id = tr.call_id,
                        .text = pruneBody(b.seq, tr.inline_body, opts),
                    },
                } });
            },
            .reasoning, .approval, .system_note => {}, // not sent to the model
            .compaction => {}, // handled above
        }
    }
    return msgs.toOwnedSlice(arena);
}

/// Is compaction block at `seq` covered by a DIFFERENT compaction's range?
fn coveredByOther(blocks: []const block.Block, seq: u64) bool {
    for (blocks) |b| {
        switch (b.body) {
            .compaction => |cp| {
                if (b.seq != seq and seq >= cp.covers_from_seq and seq <= cp.covers_to_seq)
                    return true;
            },
            else => {},
        }
    }
    return false;
}

fn pruneBody(seq: u64, body: []const u8, opts: AssembleOpts) []const u8 {
    if (seq < opts.prune_before_seq and body.len > prune_stub.len) return prune_stub;
    return body;
}

// --------------------------------------------------------------- sizing --

/// Estimated total tokens of an assembled message list.
pub fn estimateAssembled(msgs: []const provider.Message) u64 {
    var total: u64 = 0;
    for (msgs) |m| {
        switch (m.payload) {
            .text => |t| total += estimateTokens(t),
            .assistant_tool_calls => |atc| {
                total += estimateTokens(atc.text);
                for (atc.calls) |c| total += estimateTokens(c.args_json) + estimateTokens(c.name) + 8;
            },
            .tool_result => |tr| total += estimateTokens(tr.text),
        }
        total += 4; // per-message overhead
    }
    return total;
}

// ------------------------------------------------------------------- L1 --

/// Decide a new L1 prune frontier. Returns null when pruning can't reclaim
/// enough to be worth a cache break (hysteresis), else the new frontier seq.
///
/// Walk tool_result blocks NEWEST-first accumulating body tokens; once the
/// accumulated total exceeds protect_tokens, everything older is prunable.
/// Only prune if the prunable total ≥ min_reclaim_tokens.
pub fn planPrune(
    blocks: []const block.Block,
    already_pruned_before: u64,
    protect_tokens: u64,
    min_reclaim_tokens: u64,
) ?u64 {
    var protected: u64 = 0;
    var frontier: u64 = 0; // seq of the oldest PROTECTED tool_result
    var reclaimable: u64 = 0;

    var idx = blocks.len;
    while (idx > 0) {
        idx -= 1;
        const b = blocks[idx];
        switch (b.body) {
            .tool_result => |tr| {
                const cost = estimateTokens(tr.inline_body);
                if (protected < protect_tokens) {
                    protected += cost;
                    frontier = b.seq;
                } else if (b.seq >= already_pruned_before) {
                    reclaimable += cost;
                }
            },
            else => {},
        }
    }
    if (reclaimable < min_reclaim_tokens) return null;
    return frontier;
}

// ------------------------------------------------------------------- L2 --

/// Headroom check: should we compact before the next request?
pub fn needsCompaction(
    used_tokens: u64,
    model: []const u8,
    cfg: config.Config,
) bool {
    const limit = contextLimit(model);
    const needed: u64 = @as(u64, cfg.output_headroom_tokens) + @as(u64, cfg.compaction_headroom_tokens);
    if (limit <= needed) return true;
    return used_tokens > limit - needed;
}

/// The structured summarization contract sent to the compaction model.
pub const compaction_prompt =
    \\Summarize this agent conversation for continuation after context reset.
    \\Structure your summary EXACTLY as:
    \\
    \\## Accomplished
    \\(completed work, with concrete outcomes)
    \\## In progress
    \\(what was mid-flight when this summary was taken)
    \\## Files touched
    \\(every file path read or written, one per line, with a note of what/why)
    \\## Next steps
    \\(planned or implied follow-up work, in order)
    \\## User constraints & decisions
    \\(everything the user asked for, corrected, or decided — verbatim where short)
    \\
    \\Be dense and specific: paths, symbols, commands, error messages. This
    \\summary is the ONLY memory of the covered conversation.
;

/// Don't compact sessions smaller than this many blocks.
pub const compaction_min_blocks: usize = 12;

/// How many tail blocks stay OUT of the summarized range (the model keeps
/// the recent raw exchange for local continuity).
pub const compaction_keep_tail_blocks: usize = 8;

/// Pick the [from..to] seq range a new compaction should cover: everything
/// after the previous covered range, minus the protected tail. Returns null
/// when the session is too small or there's nothing new to compact.
pub fn planCompaction(blocks: []const block.Block) ?struct { from_seq: u64, to_seq: u64 } {
    if (blocks.len < compaction_min_blocks) return null;

    var covered_max: u64 = 0;
    for (blocks) |b| switch (b.body) {
        .compaction => |cp| covered_max = @max(covered_max, cp.covers_to_seq),
        else => {},
    };

    // Candidate range: first uncovered block .. len - keep_tail.
    if (blocks.len <= compaction_keep_tail_blocks) return null;
    const cut_idx = blocks.len - compaction_keep_tail_blocks;
    const to_seq = blocks[cut_idx - 1].seq;
    var from_seq: u64 = 0;
    for (blocks) |b| {
        if (b.seq > covered_max) {
            from_seq = b.seq;
            break;
        }
    }
    if (from_seq == 0 or to_seq <= covered_max or from_seq > to_seq) return null;
    // Require some meat: at least min_blocks/2 blocks in range.
    var n: usize = 0;
    for (blocks) |b| {
        if (b.seq >= from_seq and b.seq <= to_seq) n += 1;
    }
    if (n < compaction_min_blocks / 2) return null;
    return .{ .from_seq = from_seq, .to_seq = to_seq };
}

/// Render the blocks of [from..to] as plain text for the summarizer.
pub fn renderForSummary(
    arena: std.mem.Allocator,
    blocks: []const block.Block,
    from_seq: u64,
    to_seq: u64,
    byte_budget: usize,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (blocks) |b| {
        if (b.seq < from_seq or b.seq > to_seq) continue;
        switch (b.body) {
            .user_msg => |u| try out.print(arena, "USER: {s}\n\n", .{u.text}),
            .steer => |s| try out.print(arena, "USER (steering): {s}\n\n", .{s.text}),
            .assistant_msg => |a| try out.print(arena, "ASSISTANT: {s}\n\n", .{a.text}),
            .tool_call => |tc| try out.print(arena, "TOOL CALL {s}: {s}\n", .{ tc.name, tc.args_json[0..@min(tc.args_json.len, 500)] }),
            .tool_result => |tr| try out.print(arena, "RESULT ({t}): {s}\n\n", .{ tr.status, tr.inline_body[0..@min(tr.inline_body.len, 1500)] }),
            .compaction => |cp| try out.print(arena, "[EARLIER SUMMARY]\n{s}\n\n", .{cp.summary}),
            .reasoning, .approval, .system_note => {},
        }
        if (out.items.len > byte_budget) {
            try out.appendSlice(arena, "\n[... transcript truncated for summarization ...]\n");
            break;
        }
    }
    return out.items;
}

/// Extract the file paths of the N most recently WRITTEN files from
/// tool_call history (write_file/edit args), newest first, deduped.
/// Returned paths are slices into args_json — arena-lifetime.
pub fn recentWrittenFiles(
    arena: std.mem.Allocator,
    blocks: []const block.Block,
    max: usize,
) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    var idx = blocks.len;
    outer: while (idx > 0 and paths.items.len < max) {
        idx -= 1;
        const b = blocks[idx];
        switch (b.body) {
            .tool_call => |tc| {
                if (!std.mem.eql(u8, tc.name, "write_file") and !std.mem.eql(u8, tc.name, "edit")) continue;
                const path = extractJsonString(tc.args_json, "path") orelse continue;
                for (paths.items) |p| {
                    if (std.mem.eql(u8, p, path)) continue :outer;
                }
                try paths.append(arena, path);
            },
            else => {},
        }
    }
    return paths.items;
}

/// Minimal JSON string field extractor ("key":"value") — good enough for
/// tool args we serialized ourselves. Returns slice into `json`.
fn extractJsonString(json: []const u8, comptime key: []const u8) ?[]const u8 {
    const needle = "\"" ++ key ++ "\":";
    var at = std.mem.indexOf(u8, json, needle) orelse return null;
    at += needle.len;
    while (at < json.len and (json[at] == ' ' or json[at] == '\t')) at += 1;
    if (at >= json.len or json[at] != '"') return null;
    at += 1;
    var end = at;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') {
            end += 1;
            continue;
        }
        if (json[end] == '"') break;
    }
    if (end >= json.len) return null;
    const raw = json[at..end];
    // Reject paths with escapes (rare); simpler than unescaping here.
    if (std.mem.indexOfScalar(u8, raw, '\\') != null) return null;
    return raw;
}

// ---------------------------------------------------------------- tests --

test "cap inline: small output untouched, big output windowed" {
    const gpa = std.testing.allocator;
    const small = try capInline(gpa, "tiny", 100);
    try std.testing.expectEqualStrings("tiny", small);

    const big_src = "A" ** 300;
    const capped = try capInline(gpa, big_src, 100);
    defer gpa.free(capped);
    try std.testing.expect(capped.len < 200);
    try std.testing.expect(std.mem.indexOf(u8, capped, "elided") != null);
}

fn tb(seq: u64, body: block.Body) block.Block {
    return .{ .id = seq, .session_id = 1, .turn_id = 1, .seq = seq, .ts = 0, .body = body };
}

test "assemble: user → tool round trip shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "hi" } }),
        tb(2, .{ .tool_call = .{ .call_id = "c1", .name = "bash", .args_json = "{}" } }),
        tb(3, .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "out", .full_body_ref = null } }),
        tb(4, .{ .assistant_msg = .{ .text = "done" } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    // system, user, assistant(tool_calls), tool, assistant
    try std.testing.expectEqual(@as(usize, 5), msgs.len);
    try std.testing.expectEqual(provider.Role.system, msgs[0].role);
    try std.testing.expectEqual(provider.Role.tool, msgs[3].role);
}

test "assemble: compaction replaces covered range, summary emitted first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "old question" } }),
        tb(2, .{ .assistant_msg = .{ .text = "old answer" } }),
        tb(3, .{ .compaction = .{ .summary = "SUMMARY-TEXT", .covers_from_seq = 1, .covers_to_seq = 2 } }),
        tb(4, .{ .user_msg = .{ .text = "new question" } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    // system, summary(user), new question(user)
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expect(std.mem.indexOf(u8, msgs[1].payload.text, "SUMMARY-TEXT") != null);
    try std.testing.expectEqualStrings("new question", msgs[2].payload.text);
}

test "assemble: nested compaction — newer covers older compaction block" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "q1" } }),
        tb(2, .{ .compaction = .{ .summary = "S1", .covers_from_seq = 1, .covers_to_seq = 1 } }),
        tb(3, .{ .user_msg = .{ .text = "q2" } }),
        tb(4, .{ .compaction = .{ .summary = "S2", .covers_from_seq = 1, .covers_to_seq = 3 } }),
        tb(5, .{ .user_msg = .{ .text = "q3" } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    // system, S2 summary, q3. S1 is covered by S2's range and must not appear.
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expect(std.mem.indexOf(u8, msgs[1].payload.text, "S2") != null);
    try std.testing.expect(std.mem.indexOf(u8, msgs[1].payload.text, "S1") == null);
}

test "assemble: prune frontier stubs old tool bodies only" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const big = "X" ** 200;
    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "q" } }),
        tb(2, .{ .tool_call = .{ .call_id = "c1", .name = "bash", .args_json = "{}" } }),
        tb(3, .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = big, .full_body_ref = null } }),
        tb(4, .{ .tool_call = .{ .call_id = "c2", .name = "bash", .args_json = "{}" } }),
        tb(5, .{ .tool_result = .{ .call_id = "c2", .status = .ok, .inline_body = big, .full_body_ref = null } }),
    };
    const msgs = try assemble(arena, &blocks, .{ .prune_before_seq = 4 });
    // seq 3 stubbed, seq 5 intact
    var stubbed: usize = 0;
    var intact: usize = 0;
    for (msgs) |m| switch (m.payload) {
        .tool_result => |tr| {
            if (std.mem.eql(u8, tr.text, prune_stub)) stubbed += 1 else intact += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), stubbed);
    try std.testing.expectEqual(@as(usize, 1), intact);
}

test "planPrune: protects recent output, hysteresis on small reclaim" {
    // 3 tool results à ~2500 tokens (10k chars). protect=4000 → newest two
    // protected (5000 ≥ 4000 after two), oldest reclaimable ~2500.
    const big = "Y" ** 10_000;
    const blocks = [_]block.Block{
        tb(1, .{ .tool_result = .{ .call_id = "a", .status = .ok, .inline_body = big, .full_body_ref = null } }),
        tb(2, .{ .tool_result = .{ .call_id = "b", .status = .ok, .inline_body = big, .full_body_ref = null } }),
        tb(3, .{ .tool_result = .{ .call_id = "c", .status = .ok, .inline_body = big, .full_body_ref = null } }),
    };
    // min_reclaim below reclaimable → prune, frontier = seq of oldest protected (2)
    const f = planPrune(&blocks, 0, 4000, 2000);
    try std.testing.expectEqual(@as(?u64, 2), f);
    // min_reclaim above reclaimable → no prune
    try std.testing.expectEqual(@as(?u64, null), planPrune(&blocks, 0, 4000, 50_000));
    // already pruned past it → nothing new to reclaim
    try std.testing.expectEqual(@as(?u64, null), planPrune(&blocks, 2, 4000, 2000));
}

test "needsCompaction: headroom math" {
    const cfg = config.defaults(); // 16k + 8k headroom
    try std.testing.expect(!needsCompaction(100_000, "openrouter/anthropic/claude-sonnet-4.5", cfg)); // 200k limit
    try std.testing.expect(needsCompaction(180_000, "openrouter/anthropic/claude-sonnet-4.5", cfg));
    try std.testing.expect(needsCompaction(110_000, "openrouter/openai/gpt-4o", cfg)); // 128k limit
}

test "planCompaction: too small, then covers up to tail" {
    var small: [4]block.Block = undefined;
    for (0..4) |i| small[i] = tb(i + 1, .{ .user_msg = .{ .text = "x" } });
    try std.testing.expectEqual(@as(?@TypeOf(planCompaction(&small).?), null), planCompaction(&small));

    var big: [20]block.Block = undefined;
    for (0..20) |i| big[i] = tb(i + 1, .{ .user_msg = .{ .text = "x" } });
    const plan = planCompaction(&big).?;
    try std.testing.expectEqual(@as(u64, 1), plan.from_seq);
    try std.testing.expectEqual(@as(u64, 12), plan.to_seq); // 20 - 8 tail
}

test "recentWrittenFiles: newest first, deduped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]block.Block{
        tb(1, .{ .tool_call = .{ .call_id = "1", .name = "write_file", .args_json = "{\"path\":\"a.txt\",\"content\":\"x\"}" } }),
        tb(2, .{ .tool_call = .{ .call_id = "2", .name = "read_file", .args_json = "{\"path\":\"ignored.txt\"}" } }),
        tb(3, .{ .tool_call = .{ .call_id = "3", .name = "edit", .args_json = "{\"path\":\"b.txt\",\"old_string\":\"1\",\"new_string\":\"2\"}" } }),
        tb(4, .{ .tool_call = .{ .call_id = "4", .name = "edit", .args_json = "{\"path\":\"a.txt\",\"old_string\":\"1\",\"new_string\":\"2\"}" } }),
    };
    const paths = try recentWrittenFiles(arena, &blocks, 5);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("a.txt", paths[0]); // newest mention wins
    try std.testing.expectEqualStrings("b.txt", paths[1]);
}

test {
    std.testing.refAllDecls(@This());
}
