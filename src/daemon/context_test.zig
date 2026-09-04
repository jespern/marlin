//! Unit tests for context.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in context.zig.

const std = @import("std");
const config = @import("../core/config.zig");
const block = @import("../core/block.zig");
const provider = @import("provider/provider.zig");

const context = @import("context.zig");
const assemble = context.assemble;
const capInline = context.capInline;
const latestHandover = context.latestHandover;
const legacy_rehydration_prefix = context.legacy_rehydration_prefix;
const needsCompaction = context.needsCompaction;
const planCompaction = context.planCompaction;
const planPrune = context.planPrune;
const prune_stub = context.prune_stub;
const recentWrittenFiles = context.recentWrittenFiles;
const tbt = context.tbt;

test {
    std.testing.refAllDecls(context);
}

fn tb(seq: u64, body: block.Body) block.Block {
    return tbt(seq, 1, body);
}

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
    try std.testing.expect(std.mem.indexOf(u8, sys, "Never begin network access silently") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "read a specific URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "PLANNING") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "call `plan_update`") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "only current and remaining work") != null);
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
