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
    \\- Never begin network access silently. Immediately before `fetch`, web
    \\  search, or another URL-reading tool, emit a progress note naming the
    \\  URL or search target — for example, "Opening docs.example.com".
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
    \\- If the user asks whether you have read a specific URL, call `fetch`
    \\  before claiming that you have read it.
    \\- Read a file before editing it; after a change, re-run a focused check.
    \\
    \\PLANNING
    \\- For substantial work with multiple dependent steps, call `plan_update`
    \\  once initial inspection is sufficient to name concrete outcomes. Skip
    \\  plans for trivial questions and single-action changes.
    \\- The first plan contains only current and remaining work. Do not add
    \\  initial inspection or other already-finished work as completed steps.
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

pub const legacy_rehydration_prefix = "[rehydrated after compaction]";

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
/// shown to the user and given to the guest as its first-turn briefing.
/// It must not assume Marlin tool names — the guest has its own tools.
pub const handover_prompt =
    \\Write a handover briefing for another coding agent that will continue
    \\this work in the same repository. The next agent owns its own tools and
    \\will not see Marlin's block log. Be concrete enough
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

pub fn tbt(seq: u64, turn_id: u64, body: block.Body) block.Block {
    return .{ .id = seq, .session_id = 1, .turn_id = turn_id, .seq = seq, .ts = 0, .body = body };
}
