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
    \\You are Marlin, an AI coding agent collaborating with the user in their
    \\workspace. Continue until the requested outcome is genuinely handled.
    \\
    \\COMMUNICATION
    \\- Lead with the outcome, then give only the detail needed to understand or
    \\  verify it. Use plain language and match the user's technical level.
    \\- Be terse and declarative. Never narrate your own thought process:
    \\  no "I see that", "I need to consider", "I'm thinking about", "Let me",
    \\  or restating what the last tool output already showed. State findings
    \\  and actions directly — "The gate skips bash" not "I see that the gate
    \\  appears to skip bash".
    \\- Progress notes (the one line before a tool round) are telegraphic:
    \\  action plus target, a dozen words at most — "Checking the approval
    \\  gate in loop.zig" — never a paragraph, never a plan recital.
    \\- Final answers must stand alone and be as short as their content
    \\  allows. Use Markdown lists or tables only when they materially ease
    \\  scanning.
    \\- State uncertainty plainly. Distinguish observed facts, reasonable
    \\  inferences, and claims that still need real-world validation.
    \\
    \\TOOLS
    \\- Prefer the structured tools over shell equivalents: read_file over cat,
    \\  the grep tool (ripgrep-backed) over shell grep, glob over find, fetch
    \\  over curl or wget for ordinary HTTP requests, and edit/write_file over
    \\  sed or heredocs. They are faster, render better for the user, and reads
    \\  never wait on approval.
    \\- When a shell search is genuinely needed, use `rg` (ripgrep), never
    \\  bare grep or find — it is dramatically faster on repositories and
    \\  respects .gitignore. Fall back to grep only where rg is unavailable.
    \\- When processing JSON in the shell, use `jq` rather than ad-hoc
    \\  grep/sed/awk pipelines. It preserves the data's structure and makes
    \\  filtering, validation, and reshaping explicit. Fall back only where
    \\  jq is unavailable.
    \\- Reserve bash for what it is uniquely good at: builds, tests, git, and
    \\  running programs.
    \\- Read a file before editing it; after a change, re-run a focused check.
    \\
    \\PLANNING
    \\- For substantial work with multiple dependent steps, call `plan_update`
    \\  once initial inspection is sufficient to name concrete outcomes. Skip
    \\  plans for trivial questions and single-action changes.
    \\- Keep the plan operational and current: exactly one step in_progress
    \\  while work remains, mark completed steps promptly, and revise the
    \\  remaining steps when evidence changes the path. Do not merely announce
    \\  a plan in prose or repeat the displayed plan in progress commentary.
    \\- Never move a pending step directly to completed: first make it
    \\  in_progress, then complete it in a later update so elapsed time remains
    \\  accurate.
    \\- Execute the plan through completion. Use `task` or `task_batch` within
    \\  a step when independent read-only work benefits from parallelism, then
    \\  synthesize the children before advancing the plan.
    \\- Before a final answer, mark every finished step completed. Never claim
    \\  the work is done while leaving its plan in_progress.
    \\
    \\DELEGATION AND PARALLELISM
    \\- When `task` and `task_batch` are available, use them proactively for
    \\  substantial read-only work. Invoke `task_batch` without waiting for the
    \\  user to request it when two to eight independent investigations,
    \\  competing hypotheses, or review perspectives can materially improve
    \\  wall-clock time or confidence. Use `task` for one focused delegation.
    \\- Give each child a focused, non-overlapping prompt with the relevant
    \\  context and a concrete deliverable. Omit `model` to inherit the current
    \\  model; when selecting another model, use its complete registry id and
    \\  never guess a bare name.
    \\- Children are durable, read-only, and cannot delegate recursively. The
    \\  parent remains responsible for reconciling disagreements, synthesizing
    \\  the ordered results, making edits, and verifying the final outcome.
    \\- Do not delegate trivial work, tightly sequential steps, or tasks whose
    \\  coordination overhead exceeds the likely benefit.
    \\
    \\SANDBOX AND PERMISSIONS
    \\- Shell commands may execute inside a kernel sandbox (the ENVIRONMENT
    \\  section states whether it is active). The exact session working directory
    \\  and Marlin-provided `TMPDIR` are writable; writes elsewhere are denied,
    \\  as are reads of protected credential paths (~/.ssh, ~/.aws, ~/.gnupg,
    \\  Marlin's own credentials). This also applies to paths a program chooses
    \\  implicitly—toolchain caches, package stores, config files, and temp
    \\  directories—not just paths written in the command. Use `$TMPDIR` for
    \\  disposable state and put caches that should persist inside the workspace
    \\  (for example `ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global`). A permission
    \\  denial is enforced policy, not a product bug: re-plan within those roots,
    \\  or tell the user which exact step must run outside the sandbox and why.
    \\- Provider API keys and secret-shaped variables (*_API_KEY, *_TOKEN,
    \\  *_SECRET, AWS_*) are deliberately stripped from tool subprocesses.
    \\  Their absence is intentional; do not debug it or attempt recovery.
    \\- Marlin's network tools enforce a DNS blocklist when one is enabled
    \\  (see ENVIRONMENT). A blocked host is a policy decision to report to
    \\  the user, not a network outage to work around.
    \\
    \\CODE EDITING
    \\- Match the surrounding code's style, naming, idiom, and comment density.
    \\- Never add comments that narrate the change, restate the diff, or talk
    \\  to a reviewer; comment only what the code cannot say itself.
    \\- Change only what the task requires: no drive-by reformatting, renames,
    \\  or "improvements" to unrelated code. Prefer the smallest design that
    \\  genuinely solves the problem.
    \\
    \\GIT
    \\- Never commit, push, branch, or otherwise rewrite git state unless the
    \\  user explicitly asked for that action in this conversation.
    \\
    \\WORKING METHOD
    \\- Use tools to inspect the actual workspace and verify important claims.
    \\  Do not guess about files, repository state, command results, or tests.
    \\- For status or review requests, stay read-only unless the user also asks
    \\  for changes. For build or change requests, implement the change and run
    \\  focused verification in proportion to its risk.
    \\- Preserve unrelated user changes. Avoid destructive commands unless they
    \\  are clearly requested and the exact target has been checked.
    \\- When reporting project progress, compare the documented acceptance or
    \\  exit criteria with implementation and test evidence. Separate
    \\  "implemented", "verified", and "operationally proven"; do not call a
    \\  milestone complete merely because its code exists.
    \\- If a command fails, identify whether the failure is in the product, the
    \\  test, or the environment before drawing a conclusion.
    \\
    \\When done, state the result plainly, mention verification performed, and
    \\call out only meaningful remaining work.
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
    /// Stable extension text (currently the sorted skill index) appended to
    /// the base system prompt. Full skill bodies stay out of context until
    /// the model explicitly loads one with the skill tool.
    system_prompt_suffix: []const u8 = "",
    /// Repo-local instructions (MARLIN.md / AGENTS.md at the session root),
    /// injected verbatim under a PROJECT INSTRUCTIONS header. Empty = none.
    project_instructions: []const u8 = "",
    /// Per-turn dynamic facts (cwd, platform, date, git, sandbox, network),
    /// pre-rendered by the loop including its ENVIRONMENT header.
    environment: []const u8 = "",
    media_loader: ?MediaLoader = null,
    media_loader_ctx: ?*const anyopaque = null,
};

pub const MediaLoader = *const fn (
    ctx: *const anyopaque,
    allocator: std.mem.Allocator,
    hash: []const u8,
) anyerror![]const u8;

fn resolveMedia(arena: std.mem.Allocator, refs: []const block.MediaRef, opts: AssembleOpts) ![]const provider.Media {
    const loader = opts.media_loader orelse return &.{};
    const loader_ctx = opts.media_loader_ctx orelse return &.{};
    var media: std.ArrayList(provider.Media) = .empty;
    for (refs) |attachment| {
        const raw = loader(loader_ctx, arena, attachment.hash) catch continue;
        const encoded_len = std.base64.standard.Encoder.calcSize(raw.len);
        const encoded = try arena.alloc(u8, encoded_len);
        _ = std.base64.standard.Encoder.encode(encoded, raw);
        try media.append(arena, .{
            .name = attachment.name,
            .mime = attachment.mime,
            .data_base64 = encoded,
        });
    }
    return media.items;
}

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
    var sys: std.ArrayList(u8) = .empty;
    try sys.appendSlice(arena, system_prompt_base);
    if (opts.system_prompt_suffix.len > 0) {
        try sys.append(arena, '\n');
        try sys.appendSlice(arena, opts.system_prompt_suffix);
    }
    if (opts.project_instructions.len > 0) {
        try sys.appendSlice(arena, "\n\nPROJECT INSTRUCTIONS (from the repository; follow unless the user overrides)\n");
        try sys.appendSlice(arena, opts.project_instructions);
    }
    try msgs.append(arena, .{ .role = .system, .payload = .{ .text = sys.items }, .cache_breakpoint = true });

    // Pass 1: collect compaction coverage. Ranges may nest (a later
    // compaction covers an earlier compaction block itself); a block is
    // skipped if ANY compaction covers it. Summaries of covered compaction
    // blocks are superseded and not emitted.
    var covered_max: u64 = 0; // highest covers_to_seq seen
    var current_plan: ?[]const block.PlanItem = null;
    for (blocks) |b| {
        switch (b.body) {
            .compaction => |cp| covered_max = @max(covered_max, cp.covers_to_seq),
            .plan => |plan| current_plan = plan.items,
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

    // Put volatile workspace state as late as possible: immediately before
    // the newest user/steer input. Date and git dirtiness therefore cannot
    // invalidate the stable system + prior-conversation cache prefix, while
    // every provider round in this turn still sees the same environment.
    var environment_before_seq: u64 = 0;
    if (opts.environment.len > 0) {
        for (blocks) |b| {
            if (b.seq <= covered_max) continue;
            switch (b.body) {
                .user_msg => |u| {
                    if (!u.synthetic and !isLegacyRehydration(u.text))
                        environment_before_seq = b.seq;
                },
                .steer => environment_before_seq = b.seq,
                else => {},
            }
        }
    }

    // Pass 2: map non-covered, non-compaction blocks to messages.
    var i: usize = 0;
    while (i < blocks.len) : (i += 1) {
        const b = blocks[i];
        if (b.seq <= covered_max) continue; // inside a summarized range
        if (b.seq == environment_before_seq) {
            if (msgs.items.len > 0) msgs.items[msgs.items.len - 1].cache_breakpoint = true;
            try msgs.append(arena, .{ .role = .system, .payload = .{ .text = opts.environment } });
        }
        switch (b.body) {
            .user_msg => |u| {
                if (u.attachments.len == 0 or b.seq < opts.prune_before_seq or
                    opts.media_loader == null or opts.media_loader_ctx == null)
                {
                    const text = if (u.attachments.len > 0 and b.seq < opts.prune_before_seq)
                        try std.fmt.allocPrint(arena, "{s}\n\n[{d} image attachment(s) elided from active context]", .{ u.text, u.attachments.len })
                    else
                        u.text;
                    try msgs.append(arena, .{ .role = .user, .payload = .{ .text = text } });
                } else {
                    const media = try resolveMedia(arena, u.attachments, opts);
                    if (media.len == 0) {
                        const text = try std.fmt.allocPrint(arena, "{s}\n\n[image attachments unavailable]", .{u.text});
                        try msgs.append(arena, .{ .role = .user, .payload = .{ .text = text } });
                    } else try msgs.append(arena, .{ .role = .user, .payload = .{
                        .user_content = .{ .text = u.text, .media = media },
                    } });
                }
            },
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
                // Then their results. Approval/audit blocks are durable UI
                // evidence but not provider messages, so they must not split
                // an assistant tool batch from its results.
                const replied = try arena.alloc(bool, calls.items.len);
                @memset(replied, false);
                var results_seen: usize = 0;
                results: while (j < blocks.len and results_seen < calls.items.len) : (j += 1) {
                    switch (blocks[j].body) {
                        .tool_result => |tr| {
                            var result_text = pruneBody(blocks[j].seq, tr.inline_body, opts);
                            var media: []const provider.Media = &.{};
                            if (tr.attachments.len > 0) {
                                if (blocks[j].seq < opts.prune_before_seq) {
                                    result_text = try std.fmt.allocPrint(arena, "{s}\n\n[{d} tool image attachment(s) elided from active context]", .{ result_text, tr.attachments.len });
                                } else {
                                    media = try resolveMedia(arena, tr.attachments, opts);
                                    if (media.len == 0)
                                        result_text = try std.fmt.allocPrint(arena, "{s}\n\n[tool image attachments unavailable]", .{result_text});
                                }
                            }
                            try msgs.append(arena, .{ .role = .tool, .payload = .{
                                .tool_result = .{
                                    .call_id = tr.call_id,
                                    .text = result_text,
                                    .media = media,
                                },
                            } });
                            results_seen += 1;
                            for (calls.items, 0..) |call, ci| {
                                if (!replied[ci] and std.mem.eql(u8, call.call_id, tr.call_id)) {
                                    replied[ci] = true;
                                    break;
                                }
                            }
                        },
                        .reasoning, .approval, .plan, .system_note => {},
                        else => break :results,
                    }
                }
                // A turn that died between dispatch and result leaves a
                // dangling call in the durable log. Providers reject an
                // assistant tool call with no tool reply, which would wedge
                // the session on every future turn — repair at assembly
                // with a synthetic result.
                for (calls.items, replied) |call, got| {
                    if (got) continue;
                    try msgs.append(arena, .{ .role = .tool, .payload = .{
                        .tool_result = .{
                            .call_id = call.call_id,
                            .text = "[tool call did not complete: the turn ended before a result was recorded]",
                        },
                    } });
                }
                i = j - 1;
            },
            // A result without its assistant tool_call is invalid provider
            // input. Old compactions could bisect a parallel batch and leave
            // exactly this shape; omit it so those sessions self-heal.
            .tool_result => {},
            .reasoning, .approval, .plan, .system_note => {}, // not sent to the model
            .compaction => {}, // handled above
        }
    }
    // A completed tool batch is a profitable breakpoint for the next model
    // round; unlike a bare user prompt, it is known to have a follow-up.
    if (msgs.items.len > 0 and msgs.items[msgs.items.len - 1].role == .tool)
        msgs.items[msgs.items.len - 1].cache_breakpoint = true;
    if (current_plan) |items| {
        if (planHasWork(items)) {
            var text: std.ArrayList(u8) = .empty;
            try text.appendSlice(arena, "CURRENT PLAN (durable execution state; revise with plan_update)\n");
            for (items) |item| try text.print(arena, "- [{s}] {s}\n", .{
                switch (item.status) {
                    .pending => " ",
                    .in_progress => ">",
                    .completed => "x",
                },
                item.step,
            });
            try msgs.append(arena, .{ .role = .system, .payload = .{ .text = text.items } });
        }
    }
    return msgs.toOwnedSlice(arena);
}

fn planHasWork(items: []const block.PlanItem) bool {
    for (items) |item| if (item.status != .completed) return true;
    return false;
}

const legacy_rehydration_prefix = "[rehydrated after compaction]";

fn isLegacyRehydration(text: []const u8) bool {
    return std.mem.startsWith(u8, text, legacy_rehydration_prefix);
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
            .user_content => |content| {
                total += estimateTokens(content.text);
                total += @as(u64, @intCast(content.media.len)) * 2048;
            },
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
    \\Keep only state needed to continue accurately. Be concise: omit routine
    \\reads, repeated status checks, superseded plans, and raw command output.
    \\Structure the summary as:
    \\
    \\## Accomplished
    \\(completed work, with concrete outcomes)
    \\## In progress
    \\(what was mid-flight when this summary was taken)
    \\## Files touched
    \\(only materially changed or continuation-critical paths)
    \\## Next steps
    \\(planned or implied follow-up work, in order)
    \\## User constraints & decisions
    \\(durable constraints and decisions, paraphrased compactly)
    \\
    \\Include exact symbols, commands, and errors only when they are necessary
    \\to resume the active work. This summary is the memory of the covered range.
;

/// Native→guest handover: same structure as compaction, but this text is
/// shown to the user and given to Claude Code as its first-turn briefing.
/// It must not assume Marlin tool names — the guest has its own tools.
pub const handover_prompt =
    \\Write a handover briefing for another coding agent that will continue
    \\this work in the same repository. The next agent is Claude Code: it has
    \\its own tools and will not see Marlin's block log. Be concrete enough
    \\that it can resume without re-discovering the repo.
    \\
    \\Structure the briefing as:
    \\
    \\## Goal
    \\(what the user asked for, in their terms)
    \\## Accomplished
    \\(completed work, with concrete outcomes and paths)
    \\## In progress
    \\(what was mid-flight)
    \\## Files
    \\(continuation-critical paths only)
    \\## Constraints
    \\(durable user decisions)
    \\## Next
    \\(the immediate next action)
    \\
    \\Omit routine reads, raw logs, and Marlin-internal commands. Do not
    \\continue the work yourself.
;

/// Don't compact sessions smaller than this many blocks.
pub const compaction_min_blocks: usize = 12;

/// How many tail blocks stay OUT of the summarized range (the model keeps
/// the recent raw exchange for local continuity).
pub const compaction_keep_tail_blocks: usize = 8;

/// Pick the [from..to] seq range a new compaction should cover: everything
/// after the previous covered range, minus the protected tail. Returns null
/// when the session is too small or there's nothing new to compact.
pub fn planCompaction(blocks: []const block.Block, protect_latest_turn: bool) ?struct { from_seq: u64, to_seq: u64 } {
    if (blocks.len < compaction_min_blocks) return null;

    var covered_max: u64 = 0;
    for (blocks) |b| switch (b.body) {
        .compaction => |cp| covered_max = @max(covered_max, cp.covers_to_seq),
        else => {},
    };

    // Candidate range: first uncovered COMPLETE turn .. len - keep_tail,
    // ending before the COMPLETE turn containing the nominal cut. Provider
    // tool calls and their results share a turn_id, so this also guarantees
    // compaction never bisects a parallel tool batch.
    if (blocks.len <= compaction_keep_tail_blocks) return null;
    var from_idx: usize = 0;
    while (from_idx < blocks.len and blocks[from_idx].seq <= covered_max) : (from_idx += 1) {}
    if (from_idx == blocks.len) return null;
    if (from_idx > 0 and blocks[from_idx - 1].turn_id == blocks[from_idx].turn_id) {
        const partial_turn = blocks[from_idx].turn_id;
        while (from_idx < blocks.len and blocks[from_idx].turn_id == partial_turn) : (from_idx += 1) {}
    }
    if (from_idx == blocks.len) return null;

    var max_cut_idx = blocks.len;
    if (protect_latest_turn) {
        const latest_turn = blocks[blocks.len - 1].turn_id;
        while (max_cut_idx > 0 and blocks[max_cut_idx - 1].turn_id == latest_turn) : (max_cut_idx -= 1) {}
    }
    if (max_cut_idx <= from_idx) return null;

    const nominal_cut = @min(blocks.len - compaction_keep_tail_blocks, max_cut_idx);
    var cut_idx = nominal_cut;
    if (cut_idx < blocks.len) {
        const retained_turn = blocks[cut_idx].turn_id;
        while (cut_idx > from_idx and blocks[cut_idx - 1].turn_id == retained_turn) : (cut_idx -= 1) {}
    }

    // A single large turn can straddle the nominal block-count cut. When
    // backing up leaves too little to summarize, take the boundary after that
    // completed turn instead. Auto-compaction caps this at the start of the
    // active latest turn; manual compaction may consume the whole log.
    if (cut_idx <= from_idx or cut_idx - from_idx < compaction_min_blocks / 2) {
        cut_idx = nominal_cut;
        if (cut_idx < max_cut_idx) {
            const split_turn = blocks[cut_idx].turn_id;
            while (cut_idx < max_cut_idx and blocks[cut_idx].turn_id == split_turn) : (cut_idx += 1) {}
        }
    }
    if (cut_idx <= from_idx) return null;

    const from_seq = blocks[from_idx].seq;
    const to_seq = blocks[cut_idx - 1].seq;
    if (to_seq <= covered_max or from_seq > to_seq) return null;
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
            .reasoning, .approval, .plan, .system_note => {},
        }
        if (out.items.len > byte_budget) {
            try out.appendSlice(arena, "\n[... transcript truncated for summarization ...]\n");
            break;
        }
    }
    return out.items;
}

/// Most recent native→guest handover body, if the log has one.
pub fn latestHandover(blocks: []const block.Block) ?[]const u8 {
    var i = blocks.len;
    while (i > 0) {
        i -= 1;
        switch (blocks[i].body) {
            .system_note => |sn| if (block.isHandoverNote(sn.text)) return block.handoverBody(sn.text),
            else => {},
        }
    }
    return null;
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
    return tbt(seq, 1, body);
}

fn tbt(seq: u64, turn_id: u64, body: block.Body) block.Block {
    return .{ .id = seq, .session_id = 1, .turn_id = turn_id, .seq = seq, .ts = 0, .body = body };
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

test "assemble: batched calls survive interleaved audit blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "inspect both" } }),
        tb(2, .{ .tool_call = .{ .call_id = "c1", .name = "read_file", .args_json = "{}" } }),
        tb(3, .{ .tool_call = .{ .call_id = "c2", .name = "grep", .args_json = "{}" } }),
        tb(4, .{ .approval = .{ .approval_id = "a1", .call_id = "c1", .decision = .granted, .decided_by = null } }),
        tb(5, .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "one", .full_body_ref = null } }),
        tb(6, .{ .tool_result = .{ .call_id = "c2", .status = .ok, .inline_body = "two", .full_body_ref = null } }),
        tb(7, .{ .assistant_msg = .{ .text = "done" } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    try std.testing.expectEqual(@as(usize, 6), msgs.len);
    try std.testing.expectEqual(@as(usize, 2), msgs[2].payload.assistant_tool_calls.calls.len);
    try std.testing.expectEqualStrings("c1", msgs[3].payload.tool_result.call_id);
    try std.testing.expectEqualStrings("c2", msgs[4].payload.tool_result.call_id);
}

test "assemble: dangling tool call gets a synthetic result" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A turn that died between tool dispatch and result (observed live:
    // provider then 400s with "No tool output found for function call …"
    // on every subsequent turn).
    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "hi" } }),
        tb(2, .{ .tool_call = .{ .call_id = "c1", .name = "edit", .args_json = "{}" } }),
        tb(3, .{ .system_note = .{ .text = "turn failed: provider stream error" } }),
        tb(4, .{ .user_msg = .{ .text = "try again" } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    // system, user, assistant(calls), synthetic tool reply, user
    try std.testing.expectEqual(@as(usize, 5), msgs.len);
    try std.testing.expectEqual(provider.Role.tool, msgs[3].role);
    try std.testing.expectEqualStrings("c1", msgs[3].payload.tool_result.call_id);
    try std.testing.expect(std.mem.indexOf(u8, msgs[3].payload.tool_result.text, "did not complete") != null);
    try std.testing.expectEqual(provider.Role.user, msgs[4].role);
}

test "assemble: orphan results from a legacy split compaction are omitted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // This is the exact invalid legacy shape: compaction covered the user and
    // calls but stopped before the calls-first batch's results.
    const blocks = [_]block.Block{
        tbt(1, 10, .{ .user_msg = .{ .text = "inspect both" } }),
        tbt(2, 10, .{ .tool_call = .{ .call_id = "c1", .name = "read_file", .args_json = "{}" } }),
        tbt(3, 10, .{ .tool_call = .{ .call_id = "c2", .name = "read_file", .args_json = "{}" } }),
        tbt(4, 10, .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "one", .full_body_ref = null } }),
        tbt(5, 10, .{ .tool_result = .{ .call_id = "c2", .status = .ok, .inline_body = "two", .full_body_ref = null } }),
        tbt(6, 11, .{ .compaction = .{ .summary = "safe summary", .covers_from_seq = 1, .covers_to_seq = 3 } }),
        tbt(7, 11, .{ .user_msg = .{ .text = "continue" } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    try std.testing.expectEqual(@as(usize, 3), msgs.len);
    try std.testing.expectEqual(provider.Role.system, msgs[0].role);
    try std.testing.expectEqual(provider.Role.user, msgs[1].role);
    try std.testing.expectEqualStrings("continue", msgs[2].payload.text);
    for (msgs) |msg| try std.testing.expect(msg.role != .tool);
}

test "assemble: system prompt carries instructions, environment, and suffix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]block.Block{tb(1, .{ .user_msg = .{ .text = "hi" } })};
    const msgs = try assemble(arena, &blocks, .{
        .system_prompt_suffix = "SKILLS\n- deploy: ...",
        .project_instructions = "Run `zig build test`, never bare zig test.",
        .environment = "\nENVIRONMENT\n- Working directory: /work/api (a git repository, branch main, 3 changed/untracked files)",
    });
    const sys = msgs[0].payload.text;
    try std.testing.expect(std.mem.indexOf(u8, sys, "You are Marlin") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "SKILLS") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "PROJECT INSTRUCTIONS") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "never bare zig test") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "Working directory: /work/api") == null);
    try std.testing.expectEqual(provider.Role.system, msgs[1].role);
    try std.testing.expect(std.mem.indexOf(u8, msgs[1].payload.text, "Working directory: /work/api") != null);
    try std.testing.expect(msgs[0].cache_breakpoint);
    try std.testing.expect(!msgs[1].cache_breakpoint);
    // The base prompt must reference the regimes the environment reports and
    // steer shell searches to ripgrep.
    try std.testing.expect(std.mem.indexOf(u8, sys, "rg` (ripgrep)") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "use `jq`") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "fetch\n  over curl or wget") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "PLANNING") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "call `plan_update`") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "step directly to completed") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "Do not merely announce") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "DELEGATION AND PARALLELISM") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "Invoke `task_batch` without waiting") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "parent remains responsible") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "SANDBOX AND PERMISSIONS") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "exact session working directory") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "Marlin-provided `TMPDIR` are writable") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "toolchain caches") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "ZIG_GLOBAL_CACHE_DIR=$PWD/.zig-cache/global") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "DNS blocklist") != null);

    // Omitted sections leave no orphan headers behind.
    const bare = try assemble(arena, &blocks, .{});
    try std.testing.expect(std.mem.indexOf(u8, bare[0].payload.text, "PROJECT INSTRUCTIONS") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare[0].payload.text, "ENVIRONMENT\n-") == null);
}

test "assemble: latest unfinished plan survives compaction as current state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = [_]block.PlanItem{
        .{ .step = "Inspect the failure", .status = .completed },
        .{ .step = "Implement the fix", .status = .in_progress },
        .{ .step = "Verify end to end", .status = .pending },
    };
    const blocks = [_]block.Block{
        tb(2, .{ .plan = .{ .items = &items } }),
        tb(4, .{ .compaction = .{ .summary = "Earlier work", .covers_from_seq = 1, .covers_to_seq = 3 } }),
        tb(5, .{ .user_msg = .{ .text = "continue" } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    const current = msgs[msgs.len - 1];
    try std.testing.expectEqual(provider.Role.system, current.role);
    try std.testing.expect(std.mem.indexOf(u8, current.payload.text, "CURRENT PLAN") != null);
    try std.testing.expect(std.mem.indexOf(u8, current.payload.text, "[>] Implement the fix") != null);
    try std.testing.expect(std.mem.indexOf(u8, current.payload.text, "[ ] Verify end to end") != null);
}

test "assemble: completed plan collapses out of model context" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const items = [_]block.PlanItem{.{ .step = "Done", .status = .completed }};
    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "work" } }),
        tb(2, .{ .plan = .{ .items = &items } }),
    };
    const msgs = try assemble(arena, &blocks, .{});
    for (msgs) |msg| switch (msg.payload) {
        .text => |text| try std.testing.expect(std.mem.indexOf(u8, text, "CURRENT PLAN") == null),
        else => {},
    };
}

test "assemble: volatile environment follows stable history" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]block.Block{
        tb(1, .{ .user_msg = .{ .text = "old question" } }),
        tb(2, .{ .assistant_msg = .{ .text = "old answer" } }),
        tb(3, .{ .user_msg = .{ .text = "new question" } }),
    };
    const msgs = try assemble(arena, &blocks, .{ .environment = "ENVIRONMENT volatile" });
    try std.testing.expectEqual(@as(usize, 5), msgs.len);
    try std.testing.expectEqualStrings("old answer", msgs[2].payload.text);
    try std.testing.expect(msgs[2].cache_breakpoint);
    try std.testing.expectEqual(provider.Role.system, msgs[3].role);
    try std.testing.expectEqualStrings("ENVIRONMENT volatile", msgs[3].payload.text);
    try std.testing.expectEqualStrings("new question", msgs[4].payload.text);
}

test "assemble: synthetic rehydration does not displace the live environment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]block.Block{
        tbt(1, 20, .{ .user_msg = .{ .text = "live question" } }),
        tbt(2, 20, .{ .user_msg = .{ .text = "[rehydrated after compaction] old.txt:\nstate", .synthetic = true } }),
    };
    const msgs = try assemble(arena, &blocks, .{ .environment = "ENVIRONMENT current" });
    try std.testing.expectEqual(@as(usize, 4), msgs.len);
    try std.testing.expectEqual(provider.Role.system, msgs[1].role);
    try std.testing.expectEqualStrings("ENVIRONMENT current", msgs[1].payload.text);
    try std.testing.expectEqualStrings("live question", msgs[2].payload.text);
    try std.testing.expect(std.mem.startsWith(u8, msgs[3].payload.text, legacy_rehydration_prefix));
}

test "assemble: legacy rehydration also leaves environment before real input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]block.Block{
        tbt(1, 20, .{ .user_msg = .{ .text = "live question" } }),
        tbt(2, 20, .{ .user_msg = .{ .text = "[rehydrated after compaction] old.txt:\nstate" } }),
    };
    const msgs = try assemble(arena, &blocks, .{ .environment = "ENVIRONMENT current" });
    try std.testing.expectEqual(provider.Role.system, msgs[1].role);
    try std.testing.expectEqualStrings("live question", msgs[2].payload.text);
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

test "assemble resolves durable image refs only for active provider context" {
    const Loader = struct {
        fn load(_: *const anyopaque, allocator: std.mem.Allocator, hash: []const u8) ![]const u8 {
            try std.testing.expectEqualStrings("image-hash", hash);
            return allocator.dupe(u8, "\x89PNG\r\n\x1a\nbody");
        }
    };
    var marker: u8 = 0;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const blocks = [_]block.Block{tb(1, .{ .user_msg = .{
        .text = "inspect",
        .attachments = &.{.{
            .hash = "image-hash",
            .mime = "image/png",
            .name = "shot.png",
            .byte_len = 12,
        }},
    } })};
    const msgs = try assemble(arena, &blocks, .{
        .media_loader = Loader.load,
        .media_loader_ctx = &marker,
    });
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expect(msgs[1].payload == .user_content);
    try std.testing.expectEqualStrings("inspect", msgs[1].payload.user_content.text);
    try std.testing.expectEqual(@as(usize, 1), msgs[1].payload.user_content.media.len);
    try std.testing.expectEqualStrings("image/png", msgs[1].payload.user_content.media[0].mime);

    const pruned = try assemble(arena, &blocks, .{
        .prune_before_seq = 2,
        .media_loader = Loader.load,
        .media_loader_ctx = &marker,
    });
    try std.testing.expect(pruned[1].payload == .text);
    try std.testing.expect(std.mem.indexOf(u8, pruned[1].payload.text, "elided") != null);
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
    try std.testing.expectEqual(@as(?@TypeOf(planCompaction(&small, false).?), null), planCompaction(&small, false));

    var big: [20]block.Block = undefined;
    for (0..20) |i| big[i] = tbt(i + 1, i + 1, .{ .user_msg = .{ .text = "x" } });
    const plan = planCompaction(&big, false).?;
    try std.testing.expectEqual(@as(u64, 1), plan.from_seq);
    try std.testing.expectEqual(@as(u64, 12), plan.to_seq); // 20 - 8 tail
}

test "planCompaction: cut backs up before a parallel tool turn" {
    var blocks: [20]block.Block = undefined;
    for (0..20) |i| blocks[i] = tbt(i + 1, i + 1, .{ .system_note = .{ .text = "x" } });
    blocks[8] = tbt(9, 99, .{ .user_msg = .{ .text = "inspect" } });
    blocks[9] = tbt(10, 99, .{ .tool_call = .{ .call_id = "c1", .name = "read_file", .args_json = "{}" } });
    blocks[10] = tbt(11, 99, .{ .tool_call = .{ .call_id = "c2", .name = "read_file", .args_json = "{}" } });
    blocks[11] = tbt(12, 99, .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "one", .full_body_ref = null } });
    blocks[12] = tbt(13, 99, .{ .tool_result = .{ .call_id = "c2", .status = .ok, .inline_body = "two", .full_body_ref = null } });
    blocks[13] = tbt(14, 99, .{ .assistant_msg = .{ .text = "done" } });

    const plan = planCompaction(&blocks, false).?;
    // The nominal cut is after seq 12. Retain the whole seq 9..14 turn.
    try std.testing.expectEqual(@as(u64, 8), plan.to_seq);
}

test "planCompaction: resumes after a legacy partially covered turn" {
    var blocks: [22]block.Block = undefined;
    for (0..22) |i| blocks[i] = tbt(i + 1, i + 1, .{ .system_note = .{ .text = "x" } });
    blocks[0] = tbt(1, 50, .{ .tool_call = .{ .call_id = "c1", .name = "read_file", .args_json = "{}" } });
    blocks[1] = tbt(2, 50, .{ .tool_call = .{ .call_id = "c2", .name = "read_file", .args_json = "{}" } });
    blocks[2] = tbt(3, 50, .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "one", .full_body_ref = null } });
    blocks[3] = tbt(4, 50, .{ .tool_result = .{ .call_id = "c2", .status = .ok, .inline_body = "two", .full_body_ref = null } });
    blocks[4] = tbt(5, 51, .{ .compaction = .{ .summary = "legacy", .covers_from_seq = 1, .covers_to_seq = 2 } });

    const plan = planCompaction(&blocks, false).?;
    // seq 3..4 are the uncovered remainder of turn 50 and cannot become the
    // beginning of another summary range.
    try std.testing.expectEqual(@as(u64, 5), plan.from_seq);
}

test "planCompaction: long turn uses its end while auto protects active turn" {
    var blocks: [15]block.Block = undefined;
    for (0..14) |i| blocks[i] = tbt(i + 1, 70, .{ .system_note = .{ .text = "long completed turn" } });
    blocks[14] = tbt(15, 71, .{ .user_msg = .{ .text = "active prompt" } });

    const automatic = planCompaction(&blocks, true).?;
    try std.testing.expectEqual(@as(u64, 14), automatic.to_seq);

    const completed_only = planCompaction(blocks[0..14], false).?;
    try std.testing.expectEqual(@as(u64, 14), completed_only.to_seq);
    try std.testing.expect(planCompaction(blocks[0..14], true) == null);
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

test "latestHandover returns the most recent handover body" {
    const blocks = [_]block.Block{
        tb(1, .{ .system_note = .{ .text = "Switching to Claude Code (claudecode/fable). Generating a handover summary with the current model…" } }),
        tb(2, .{ .system_note = .{ .text = "[handover]\n## Goal\nfirst" } }),
        tb(3, .{ .assistant_msg = .{ .text = "noise" } }),
        tb(4, .{ .system_note = .{ .text = "[handover]\n## Goal\nsecond" } }),
    };
    try std.testing.expectEqualStrings("## Goal\nsecond", latestHandover(&blocks).?);
    try std.testing.expect(latestHandover(&.{tb(1, .{ .system_note = .{ .text = "other" } })}) == null);
}

test {
    std.testing.refAllDecls(@This());
}
