//! Unit tests for store.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in store.zig.

const std = @import("std");
const block = @import("../core/block.zig");
const Effort = @import("../core/effort.zig").Effort;
const proto = @import("../core/proto.zig");
const telemetry_ids = @import("../core/telemetry.zig");

const store_mod = @import("store.zig");
const Store = store_mod.Store;
const bindInt = store_mod.bindInt;
const c = store_mod.c;
const columnText = store_mod.columnText;
const finalize = store_mod.finalize;

test {
    std.testing.refAllDecls(store_mod);
}

fn expectQueryPlanUses(store: Store, comptime sql: [:0]const u8, bindings: []const i64, needle: []const u8) !void {
    const stmt = try store.prepare(sql);
    defer finalize(stmt);
    for (bindings, 1..) |value, idx| bindInt(stmt, @intCast(idx), value);
    var found = false;
    while (true) switch (c.sqlite3_step(stmt)) {
        c.SQLITE_ROW => if (std.mem.indexOf(u8, columnText(stmt, 3), needle) != null) {
            found = true;
        },
        c.SQLITE_DONE => break,
        else => return error.SqliteStep,
    };
    try std.testing.expect(found);
}

test "session + block round trip (in-memory)" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try store.createSession(42, 1700000000000, "/tmp", "openrouter/foo", .high);
    try std.testing.expectEqual(@as(?u64, 42), try store.lastSession());
    const sessions = try store.listSessions(false);
    defer {
        for (sessions) |session| session.deinit(gpa);
        gpa.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 1), sessions.len);
    try std.testing.expectEqualStrings("/tmp", sessions[0].cwd);
    try std.testing.expectEqualStrings("openrouter/foo", sessions[0].model);
    try std.testing.expectEqual(Effort.high, sessions[0].effort);

    try store.setSessionEffort(42, .low);
    const session = try store.getSession(42);
    defer store.freeSession(session);
    try std.testing.expectEqual(Effort.low, session.effort);

    const blk1 = block.Block{
        .id = 1,
        .session_id = 42,
        .turn_id = 1,
        .seq = 1,
        .ts = 1700000000001,
        .body = .{ .user_msg = .{ .text = "hello world" } },
    };
    try store.appendBlock(blk1);
    const append_stmt = store.statements.append_block.?;
    const blk2 = block.Block{
        .id = 2,
        .session_id = 42,
        .turn_id = 1,
        .seq = 2,
        .ts = 1700000000002,
        .body = .{ .tool_result = .{
            .call_id = "c1",
            .status = .ok,
            .inline_body = "output here",
            .full_body_ref = null,
        } },
    };
    try store.appendBlock(blk2);
    try std.testing.expectEqual(append_stmt, store.statements.append_block.?);

    try store.setSessionStatus(42, "running");
    const status_stmt = store.statements.set_session_status.?;
    try store.setSessionStatus(42, "idle");
    try std.testing.expectEqual(status_stmt, store.statements.set_session_status.?);
    try store.updateSessionUsage(42, 10, 20);
    const usage_stmt = store.statements.update_session_usage.?;
    try store.updateSessionUsage(42, 30, 40);
    try std.testing.expectEqual(usage_stmt, store.statements.update_session_usage.?);

    try std.testing.expectEqual(@as(u64, 2), try store.lastSeq(42));
    const last_seq_stmt = store.statements.last_seq.?;
    try std.testing.expectEqual(@as(u64, 2), try store.lastSeq(42));
    try std.testing.expectEqual(last_seq_stmt, store.statements.last_seq.?);

    const loaded = try store.getBlocks(42, 1, 100);
    defer {
        for (loaded) |*lb| lb.deinit();
        gpa.free(loaded);
    }
    try std.testing.expectEqual(@as(usize, 2), loaded.len);
    try std.testing.expectEqualStrings("hello world", loaded[0].blk.body.user_msg.text);
    try std.testing.expectEqual(block.ToolStatus.ok, loaded[1].blk.body.tool_result.status);
    try std.testing.expectEqual(@as(?[]const u8, null), loaded[1].blk.body.tool_result.full_body_ref);
}

test "duplicate seq rejected (append-only integrity)" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);
    const mk = struct {
        fn blk(seq: u64) block.Block {
            return .{ .id = seq, .session_id = 1, .turn_id = 1, .seq = seq, .ts = 0, .body = .{ .user_msg = .{ .text = "x" } } };
        }
    };
    try store.appendBlock(mk.blk(1));
    try std.testing.expectError(error.SqliteStep, store.appendBlock(mk.blk(1)));
    try store.appendBlock(mk.blk(2));
}

test "tail replay is bounded and remains in ascending transcript order" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);
    for (1..7) |seq| try store.appendBlock(.{
        .id = seq,
        .session_id = 1,
        .turn_id = 1,
        .seq = seq,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "x" } },
    });
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var tail: std.ArrayList(block.Block) = .empty;
    try store.loadTailInto(arena_state.allocator(), &tail, 1, 3);
    try std.testing.expectEqual(@as(usize, 3), tail.items.len);
    try std.testing.expectEqual(@as(u64, 4), tail.items[0].seq);
    try std.testing.expectEqual(@as(u64, 6), tail.items[2].seq);

    var older: std.ArrayList(block.Block) = .empty;
    try store.loadTailBeforeInto(arena_state.allocator(), &older, 1, 4, 2);
    try std.testing.expectEqual(@as(usize, 2), older.items.len);
    try std.testing.expectEqual(@as(u64, 2), older.items[0].seq);
    try std.testing.expectEqual(@as(u64, 3), older.items[1].seq);

    var forward_page: std.ArrayList(block.Block) = .empty;
    const has_newer = try store.loadForwardPageInto(
        arena_state.allocator(),
        &forward_page,
        1,
        1,
        3,
        1,
    );
    try std.testing.expect(has_newer);
    try std.testing.expectEqual(@as(usize, 1), forward_page.items.len);
    try std.testing.expectEqual(@as(u64, 1), forward_page.items[0].seq);

    var tail_page: std.ArrayList(block.Block) = .empty;
    const has_older = try store.loadTailPageInto(
        arena_state.allocator(),
        &tail_page,
        1,
        0,
        3,
        1,
    );
    try std.testing.expect(has_older);
    try std.testing.expectEqual(@as(usize, 1), tail_page.items.len);
    try std.testing.expectEqual(@as(u64, 6), tail_page.items[0].seq);
}

test "context load skips durable rows superseded by nested compactions" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);

    for (1..5) |seq| try store.appendBlock(.{
        .id = seq,
        .session_id = 1,
        .turn_id = 1,
        .seq = seq,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "covered" } },
    });
    try store.appendBlock(.{
        .id = 5,
        .session_id = 1,
        .turn_id = 2,
        .seq = 5,
        .ts = 0,
        .body = .{ .compaction = .{ .summary = "first", .covers_from_seq = 1, .covers_to_seq = 4 } },
    });
    for (6..9) |seq| try store.appendBlock(.{
        .id = seq,
        .session_id = 1,
        .turn_id = 3,
        .seq = seq,
        .ts = 0,
        .body = .{ .assistant_msg = .{ .text = "also covered" } },
    });
    try store.appendBlock(.{
        .id = 9,
        .session_id = 1,
        .turn_id = 4,
        .seq = 9,
        .ts = 0,
        .body = .{ .compaction = .{ .summary = "second", .covers_from_seq = 1, .covers_to_seq = 8 } },
    });
    try store.appendBlock(.{
        .id = 10,
        .session_id = 1,
        .turn_id = 5,
        .seq = 10,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "live tail" } },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var relevant: std.ArrayList(block.Block) = .empty;
    try store.loadContextBlocksInto(arena_state.allocator(), &relevant, 1, 100);
    try std.testing.expectEqual(@as(usize, 3), relevant.items.len);
    try std.testing.expectEqual(@as(u64, 5), relevant.items[0].seq);
    try std.testing.expectEqual(@as(u64, 9), relevant.items[1].seq);
    try std.testing.expectEqual(@as(u64, 10), relevant.items[2].seq);
}

test "context load materializes frontier before scanning large compacted history" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);

    for (1..2001) |seq| try store.appendBlock(.{
        .id = seq,
        .session_id = 1,
        .turn_id = 1,
        .seq = seq,
        .ts = 0,
        .body = .{ .tool_result = .{
            .call_id = "c",
            .status = .ok,
            .inline_body = "covered history",
            .full_body_ref = null,
        } },
    });
    try store.appendBlock(.{
        .id = 2001,
        .session_id = 1,
        .turn_id = 2,
        .seq = 2001,
        .ts = 0,
        .body = .{ .compaction = .{
            .summary = "history summarized",
            .covers_from_seq = 1,
            .covers_to_seq = 2000,
        } },
    });
    try store.appendBlock(.{
        .id = 2002,
        .session_id = 1,
        .turn_id = 3,
        .seq = 2002,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "live tail" } },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var relevant: std.ArrayList(block.Block) = .empty;
    const stats = try store.loadContextBlocksIntoMeasured(
        null,
        arena_state.allocator(),
        &relevant,
        1,
        1_000_000,
    );
    try std.testing.expectEqual(@as(usize, 2), relevant.items.len);
    try std.testing.expectEqual(@as(u64, 2001), relevant.items[0].seq);
    try std.testing.expectEqual(@as(u64, 2002), relevant.items[1].seq);
    try std.testing.expect(stats.vm_steps < 100_000);
    try std.testing.expectEqual(@as(u64, 2002), stats.last_seq);
    const context_stmt = store.statements.load_context.?;
    relevant.clearRetainingCapacity();
    _ = try store.loadContextBlocksIntoMeasured(null, arena_state.allocator(), &relevant, 1, 1_000_000);
    try std.testing.expectEqual(context_stmt, store.statements.load_context.?);
}

test "latest plan remains context-relevant after compaction" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);
    try store.appendBlock(.{
        .id = 1,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "work" } },
    });
    const items = [_]block.PlanItem{
        .{ .step = "Inspect", .status = .completed, .started_at_ms = 1_000, .duration_ms = 18_400 },
        .{ .step = "Implement", .status = .in_progress },
    };
    try store.appendBlock(.{
        .id = 2,
        .session_id = 1,
        .turn_id = 1,
        .seq = 2,
        .ts = 0,
        .body = .{ .plan = .{ .items = &items } },
    });
    try store.appendBlock(.{
        .id = 3,
        .session_id = 1,
        .turn_id = 2,
        .seq = 3,
        .ts = 0,
        .body = .{ .compaction = .{ .summary = "work started", .covers_from_seq = 1, .covers_to_seq = 2 } },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var relevant: std.ArrayList(block.Block) = .empty;
    try store.loadContextBlocksInto(arena, &relevant, 1, 100);
    try std.testing.expectEqual(@as(usize, 2), relevant.items.len);
    try std.testing.expectEqual(block.BlockKind.plan, relevant.items[0].kind());
    try std.testing.expectEqual(block.BlockKind.compaction, relevant.items[1].kind());

    const latest = (try store.loadLatestPlan(arena, 1)).?;
    try std.testing.expectEqual(@as(usize, 2), latest.items.len);
    try std.testing.expectEqual(@as(i64, 1_000), latest.items[0].started_at_ms);
    try std.testing.expectEqual(@as(u64, 18_400), latest.items[0].duration_ms);
    try std.testing.expectEqualStrings("Implement", latest.items[1].step);
    try std.testing.expectEqual(block.PlanStatus.in_progress, latest.items[1].status);
    try std.testing.expect(latest.pinned);

    try store.appendBlock(.{
        .id = 4,
        .session_id = 1,
        .turn_id = 3,
        .seq = 4,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "continue" } },
    });
    const archived = (try store.loadLatestPlan(arena, 1)).?;
    try std.testing.expect(archived.pinned);

    var done_items = [_]block.PlanItem{
        .{ .step = "Inspect", .status = .completed, .duration_ms = 18_400 },
        .{ .step = "Implement", .status = .completed, .duration_ms = 3_000 },
    };
    try store.appendBlock(.{
        .id = 5,
        .session_id = 1,
        .turn_id = 3,
        .seq = 5,
        .ts = 0,
        .body = .{ .plan = .{ .items = &done_items } },
    });
    try std.testing.expect(!(try store.loadLatestPlan(arena, 1)).?.pinned);
    try store.appendBlock(.{
        .id = 6,
        .session_id = 1,
        .turn_id = 4,
        .seq = 6,
        .ts = 0,
        .body = .{ .user_msg = .{ .text = "new work" } },
    });
    try std.testing.expect(!(try store.loadLatestPlan(arena, 1)).?.pinned);
}

test "one connection survives concurrent turn writes and dispatcher reads" {
    // Production shape: turn threads append blocks while the dispatcher
    // answers session-list queries on the SAME connection. Requires the
    // serialized (FULLMUTEX) open mode; without it this corrupted the heap
    // and segfaulted inside sqlite's parser on the first real prompt.
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);

    const Writer = struct {
        fn run(s: *Store) void {
            var seq: u64 = 1;
            while (seq <= 300) : (seq += 1) {
                s.appendBlock(.{
                    .id = seq,
                    .session_id = 1,
                    .turn_id = 1,
                    .seq = seq,
                    .ts = 0,
                    .body = .{ .user_msg = .{ .text = "concurrent" } },
                }) catch return;
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Writer.run, .{&store});
    var reads: usize = 0;
    while (reads < 300) : (reads += 1) {
        const sessions = try store.listSessions(false);
        for (sessions) |session| session.deinit(gpa);
        gpa.free(sessions);
    }
    t.join();
    try std.testing.expectEqual(@as(u64, 300), try store.lastSeq(1));
}

test "blob round trip is content-addressed and idempotent" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    const h1 = try store.putBlob("big tool output", 1700000000001);
    defer gpa.free(h1);
    const h2 = try store.putBlob("big tool output", 1700000000002);
    defer gpa.free(h2);
    try std.testing.expectEqualStrings(h1, h2);

    const bytes = try store.getBlob(h1);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("big tool output", bytes);

    try std.testing.expectError(error.NotFound, store.getBlob("nope"));

    // Ref bookkeeping is idempotent too.
    try store.addBlobRef(h1, 101);
    try store.addBlobRef(h1, 101);
    try store.addBlobRef(h1, 202);
}

test "oversized tool result persists blob block and ref atomically" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);

    const hash = try Store.blobHashAlloc(gpa, "atomic body");
    defer gpa.free(hash);
    const first: block.Block = .{
        .id = 10,
        .session_id = 1,
        .turn_id = 2,
        .seq = 1,
        .ts = 100,
        .body = .{ .tool_result = .{
            .call_id = "c1",
            .status = .ok,
            .inline_body = "atomic",
            .full_body_ref = hash,
        } },
    };
    try store.appendBlockWithBlob(first, hash, "atomic body");
    const bytes = try store.getBlob(hash);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("atomic body", bytes);
    const report = try store.gc(null);
    try std.testing.expectEqual(@as(u64, 0), report.orphan_blobs);

    // Duplicate seq makes the block insert fail after the blob insert. The
    // transaction must roll that new blob back rather than leave an orphan.
    const rejected_hash = try Store.blobHashAlloc(gpa, "must roll back");
    defer gpa.free(rejected_hash);
    var rejected = first;
    rejected.id = 11;
    rejected.body.tool_result.full_body_ref = rejected_hash;
    try std.testing.expectError(
        error.SqliteStep,
        store.appendBlockWithBlob(rejected, rejected_hash, "must roll back"),
    );
    try std.testing.expectError(error.NotFound, store.getBlob(rejected_hash));
}

test "gc removes orphans and explicitly demotes old idle blob bodies" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 0, "/", "m", .auto);
    try store.appendBlock(.{
        .id = 101,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 100,
        .body = .{ .tool_result = .{
            .call_id = "call",
            .status = .ok,
            .inline_body = "short",
            .full_body_ref = null,
        } },
    });
    const kept = try store.putBlob("referenced old output", 100);
    defer gpa.free(kept);
    try store.addBlobRef(kept, 101);
    const orphan = try store.putBlob("orphan output", 100);
    defer gpa.free(orphan);

    const swept = try store.gc(null);
    try std.testing.expectEqual(@as(u64, 1), swept.orphan_blobs);
    try std.testing.expectEqual(@as(u64, 0), swept.expired_blobs);
    try std.testing.expectError(error.NotFound, store.getBlob(orphan));
    const body = try store.getBlob(kept);
    defer gpa.free(body);
    try std.testing.expectEqualStrings("referenced old output", body);

    const demoted = try store.gc(200);
    try std.testing.expectEqual(@as(u64, 0), demoted.orphan_blobs);
    try std.testing.expectEqual(@as(u64, 1), demoted.expired_blobs);
    try std.testing.expect(demoted.bytes_reclaimed >= "referenced old output".len);
    try std.testing.expectError(error.NotFound, store.getBlob(kept));

    // Content addressing must not make expiry permanent: producing the exact
    // bytes again is fresh evidence and resurrects the shared hash.
    const resurrected = try store.putBlob("referenced old output", 300);
    defer gpa.free(resurrected);
    try std.testing.expectEqualStrings(kept, resurrected);
    const fresh = try store.getBlob(resurrected);
    defer gpa.free(fresh);
    try std.testing.expectEqualStrings("referenced old output", fresh);
}

test "schema is v13 with performance telemetry and scaling indexes" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try std.testing.expectEqual(@as(i64, 13), try store.kvGetInt("schema_version"));
    // migrate() must be a no-op on a current DB (idempotent open).
    try store.migrate();
    try std.testing.expectEqual(@as(i64, 13), try store.kvGetInt("schema_version"));
    try store.createSession(42, 1, "/tmp", "m", .auto);
    try store.setSessionPlanMode(42, true);
    const row = try store.getSession(42);
    defer store.freeSession(row);
    try std.testing.expect(row.plan_mode);
    try std.testing.expect((try store.getCodexThreadId(42)) == null);
    try store.setCodexThreadId(42, "thread_test");
    const codex_thread_id = (try store.getCodexThreadId(42)).?;
    defer gpa.free(codex_thread_id);
    try std.testing.expectEqualStrings("thread_test", codex_thread_id);
    const stmt = try store.prepare("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='blocks_by_session'");
    defer finalize(stmt);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));
    try expectQueryPlanUses(
        store,
        "EXPLAIN QUERY PLAN SELECT id FROM blocks WHERE session_id=? AND turn_id=? ORDER BY seq",
        &.{ 42, 1 },
        "blocks_by_turn",
    );
    try expectQueryPlanUses(
        store,
        "EXPLAIN QUERY PLAN SELECT id FROM sessions WHERE parent_sid=?",
        &.{42},
        "sessions_by_parent",
    );
    try expectQueryPlanUses(
        store,
        "EXPLAIN QUERY PLAN SELECT turn_id FROM telemetry_turns WHERE session_id=? ORDER BY started_at_ms DESC LIMIT ?",
        &.{ 42, 50 },
        "telemetry_turns_by_session_started",
    );
}

test "telemetry diagnostics and export outbox are durable and content-free" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(42, 1, "/tmp", "openrouter/test/model", .auto);
    try store.telemetryBeginTurn(42, 100, "openrouter/test/model", .root, 1_000);
    try store.telemetryRecordRound(42, 100, .{
        .round = 0,
        .span_id = "0000000000000065",
        .started_at_ms = 1_010,
        .first_byte_at_ms = 1_020,
        .first_visible_at_ms = 1_030,
        .ended_at_ms = 1_110,
        .status = "ok",
        .http_status = 200,
        .response_bytes = 512,
        .provider = "test-backend",
        .provider_name = "openrouter",
        .request_model = "test/model",
        .response_model = "test/model-v2",
        .server_address = "openrouter.ai",
        .server_port = 443,
        .finish_reason = "stop",
        .reasoning_level = "high",
        .max_tokens = 16_000,
        .generation_id = "gen-1",
        .usage_available = true,
        .tokens_in = 20,
        .tokens_out = 5,
        .cached_tokens = 10,
        .cache_write_tokens = 0,
        .reasoning_tokens = 2,
        .context_load_ms = 4,
        .store_wait_ms = 1,
        .context_rows = 8,
        .context_bytes = 4096,
        .context_vm_steps = 120,
        .setup_ms = 3,
        .assemble_ms = 2,
        .body_ms = 1,
    });
    try store.telemetryRecordTool(42, 100, .{
        .round = 0,
        .call_id = "call-1",
        .span_id = "0000000000000066",
        .name = "read_file",
        .description = "Read a text file",
        .started_at_ms = 1_111,
        .ended_at_ms = 1_121,
        .status = "ok",
    });
    try store.telemetryFinishTurn(42, 100, 1_200, "ok", "", 20, 5);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = try store.diagnostics(arena, 42, 50, 1_300, true);
    try std.testing.expectEqual(@as(u32, 1), report.sample_turns);
    try std.testing.expectEqual(@as(u32, 1), report.successful_turns);
    try std.testing.expectEqual(@as(u64, 100), report.provider_p50_ms);
    try std.testing.expectEqual(@as(u64, 20), report.ttft_p50_ms);
    try std.testing.expectEqual(@as(u64, 10), report.pre_provider_p50_ms);
    try std.testing.expectEqual(@as(u64, 10), report.pre_provider_max_ms);
    try std.testing.expectEqual(@as(u64, 10), report.local_prep_p50_ms);
    try std.testing.expectEqual(@as(usize, 1), report.last_rounds.len);
    try std.testing.expectEqual(@as(u64, 4), report.last_rounds[0].context_load_ms);
    try std.testing.expectEqual(@as(u64, 1), report.last_rounds[0].store_wait_ms);
    try std.testing.expectEqual(@as(u64, 8), report.last_rounds[0].context_rows);
    try std.testing.expectEqual(@as(u64, 120), report.last_rounds[0].context_vm_steps);
    try std.testing.expectEqual(@as(usize, 1), report.last_tools.len);
    try std.testing.expectEqualStrings("read_file", report.last_tools[0].name);
    try std.testing.expectEqual(@as(u32, 1), report.otlp_pending);

    const trace = (try store.nextTelemetryTrace(arena, 1_300)).?;
    try std.testing.expectEqual(@as(u64, 100), trace.turn_id);
    try std.testing.expectEqualStrings("gen-1", trace.rounds[0].generation_id);
    try std.testing.expectEqualStrings("openrouter", trace.rounds[0].provider_name);
    try std.testing.expectEqualStrings("test/model", trace.rounds[0].request_model);
    try std.testing.expectEqualStrings("test/model-v2", trace.rounds[0].response_model);
    try std.testing.expectEqual(@as(u64, 16_000), trace.rounds[0].max_tokens);
    try std.testing.expectEqualStrings("Read a text file", trace.tools[0].description);
    try store.markTelemetryExported(42, 100, 1_301);
    try std.testing.expect((try store.nextTelemetryTrace(arena, 1_302)) == null);
}

test "durable search indexes visible text and recent authored inputs" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();
    try store.createSession(1, 1, "/one", "m", .auto);
    try store.createSession(2, 2, "/two", "m", .auto);
    try store.setSessionTitle(1, "fruit work");
    try store.appendBlock(.{
        .id = 11,
        .session_id = 1,
        .turn_id = 1,
        .seq = 1,
        .ts = 10,
        .body = .{ .user_msg = .{ .text = "build the banana launcher" } },
    });
    try store.appendBlock(.{
        .id = 12,
        .session_id = 1,
        .turn_id = 1,
        .seq = 2,
        .ts = 11,
        .body = .{ .assistant_msg = .{ .text = "launcher implementation complete" } },
    });
    try store.appendBlock(.{
        .id = 21,
        .session_id = 2,
        .turn_id = 1,
        .seq = 1,
        .ts = 12,
        .body = .{ .user_msg = .{ .text = "private synthetic text", .synthetic = true } },
    });
    try store.appendBlock(.{
        .id = 22,
        .session_id = 2,
        .turn_id = 1,
        .seq = 2,
        .ts = 13,
        .body = .{ .steer = .{ .text = "add citrus support" } },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const hits = try store.search(arena_state.allocator(), "banana launch", 0, 20);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u64, 1), hits[0].sid);
    try std.testing.expectEqual(block.BlockKind.user_msg, hits[0].kind);
    try std.testing.expectEqualStrings("fruit work", hits[0].title);

    const scoped = try store.search(arena_state.allocator(), "launcher", 2, 20);
    try std.testing.expectEqual(@as(usize, 0), scoped.len);
    const history = try store.recentInputs(arena_state.allocator(), 2, 20);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqualStrings("add citrus support", history[0].text);
    try std.testing.expectEqualStrings("build the banana launcher", history[1].text);
    const recent_plan =
        \\EXPLAIN QUERY PLAN SELECT session_id,seq,ts,text FROM (
        \\  SELECT session_id,seq,ts,text,block_id,0 AS bucket FROM (
        \\    SELECT session_id,seq,ts,text,block_id FROM search_docs
        \\    WHERE session_id=? AND kind IN ('user_msg','steer')
        \\    ORDER BY ts DESC,block_id DESC LIMIT ?
        \\  )
        \\  UNION ALL
        \\  SELECT session_id,seq,ts,text,block_id,1 AS bucket FROM (
        \\    SELECT session_id,seq,ts,text,block_id FROM search_docs
        \\    WHERE session_id<>? AND kind IN ('user_msg','steer')
        \\    ORDER BY ts DESC,block_id DESC LIMIT ?
        \\  )
        \\) ORDER BY bucket,ts DESC,block_id DESC LIMIT ?
    ;
    try expectQueryPlanUses(store, recent_plan, &.{ 2, 20, 2, 20, 20 }, "search_docs_recent_inputs_session");
    try expectQueryPlanUses(store, recent_plan, &.{ 2, 20, 2, 20, 20 }, "search_docs_recent_inputs_global");

    // Exercise the capability fallback against the same maintained corpus.
    store.fts5 = false;
    const fallback = try store.search(arena_state.allocator(), "banana launcher", 0, 20);
    try std.testing.expectEqual(@as(usize, 1), fallback.len);
}

test "child session metadata is durable and grouped beneath its root" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try store.createSession(10, 100, "/work", "openrouter/root", .high);
    try store.appendBlock(.{
        .id = 77,
        .session_id = 10,
        .turn_id = 1,
        .seq = 1,
        .ts = 101,
        .body = .{ .tool_call = .{ .call_id = "task-1", .name = "task", .args_json = "{}" } },
    });
    try store.createChildSession(20, 102, 10, 77, "inspect storage", "/work", "openrouter/child", .medium, 7);

    const child = try store.getSession(20);
    defer store.freeSession(child);
    try std.testing.expectEqual(@as(?u64, 10), child.parent_sid);
    try std.testing.expectEqual(proto.SessionKind.task_child, child.kind);
    try std.testing.expectEqual(@as(?u64, 77), child.parent_block_id);
    try std.testing.expectEqual(@as(u32, 7), child.max_rounds);

    const listed = try store.listSessions(false);
    defer {
        for (listed) |row| row.deinit(gpa);
        gpa.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 2), listed.len);
    try std.testing.expectEqual(@as(u64, 10), listed[0].id);
    try std.testing.expectEqual(@as(u64, 20), listed[1].id);

    const one = try store.getSessionListing(20);
    defer one.deinit(gpa);
    try std.testing.expectEqual(@as(?u64, 10), one.parent_sid);
    try std.testing.expectEqualStrings("inspect storage", one.title);

    const tree = try store.listSessionTree(10);
    defer {
        for (tree) |row| row.deinit(gpa);
        gpa.free(tree);
    }
    try std.testing.expectEqual(@as(usize, 2), tree.len);
    try std.testing.expectEqual(@as(u64, 10), tree[0].id);
    try std.testing.expectEqual(@as(u64, 20), tree[1].id);

    try store.setSessionStatus(20, "running");
    try store.recoverInterruptedSessions();
    const recovered = try store.getSession(20);
    defer store.freeSession(recovered);
    try std.testing.expectEqualStrings("err", recovered.status);
}

test "archiving a root hides its hierarchy and can be reversed" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try store.createSession(10, 100, "/work", "openrouter/root", .auto);
    try store.appendBlock(.{
        .id = 77,
        .session_id = 10,
        .turn_id = 1,
        .seq = 1,
        .ts = 101,
        .body = .{ .tool_call = .{ .call_id = "task-1", .name = "task", .args_json = "{}" } },
    });
    try store.createChildSession(20, 102, 10, 77, "child", "/work", "openrouter/child", .auto, 4);

    try store.setSessionTreeArchived(10, 200);
    const visible = try store.listSessions(false);
    defer {
        for (visible) |row| row.deinit(gpa);
        gpa.free(visible);
    }
    try std.testing.expectEqual(@as(usize, 0), visible.len);
    try std.testing.expectEqual(@as(?u64, null), try store.lastSession());

    const all = try store.listSessions(true);
    defer {
        for (all) |row| row.deinit(gpa);
        gpa.free(all);
    }
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expect(all[0].archived);
    try std.testing.expect(all[1].archived);

    const child = try store.getSession(20);
    defer store.freeSession(child);
    try std.testing.expect(child.archived);

    try store.setSessionTreeArchived(10, null);
    const restored = try store.listSessions(false);
    defer {
        for (restored) |row| row.deinit(gpa);
        gpa.free(restored);
    }
    try std.testing.expectEqual(@as(usize, 2), restored.len);
    try std.testing.expect(!restored[0].archived);
    try std.testing.expect(!restored[1].archived);
}
