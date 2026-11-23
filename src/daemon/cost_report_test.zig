const std = @import("std");
const Io = std.Io;
const cost_report = @import("cost_report.zig");
const cost = @import("../core/cost.zig");
const c = @import("sqlite3_c");

fn write(io: Io, root: []const u8, rel: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

test "cost report counts each response once, finds rewrites, and tells Marlin's guests from the vendors' own UIs" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cost");
    defer temp.deinit();
    const home = temp.path;

    // A Marlin session's Claude Code log: one response logged per content
    // block (same message id), then a full rewrite of a 300K context.
    try write(io, home, ".claude/projects/-w/aaaaaaaa-0000-4000-8000-000000000001.jsonl",
        \\{"type":"assistant","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","entrypoint":"sdk-cli","timestamp":"2099-01-01T00:00:00Z","message":{"id":"m1","model":"claude-fable-5-2","usage":{"input_tokens":2,"cache_read_input_tokens":200000,"cache_creation_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000}}}}
        \\{"type":"assistant","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","entrypoint":"sdk-cli","timestamp":"2099-01-01T00:00:00Z","message":{"id":"m1","model":"claude-fable-5-2","usage":{"input_tokens":2,"cache_read_input_tokens":200000,"cache_creation_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000}}}}
        \\{"type":"assistant","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","entrypoint":"sdk-cli","timestamp":"2099-01-01T00:10:00Z","message":{"id":"m2","model":"claude-fable-5-2","usage":{"input_tokens":2,"cache_read_input_tokens":14000,"cache_creation_input_tokens":286000,"output_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":286000,"ephemeral_1h_input_tokens":0}}}}
        \\{"type":"user","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","message":{"content":"next"}}
        \\
    );
    // An interactive session, and a line from before the window.
    try write(io, home, ".claude/projects/-w/bbbbbbbb-0000-4000-8000-000000000002.jsonl",
        \\{"type":"assistant","sessionId":"bbbbbbbb-0000-4000-8000-000000000002","entrypoint":"cli","timestamp":"2099-01-01T00:00:00Z","message":{"id":"i1","model":"claude-fable-5-2","usage":{"input_tokens":5,"cache_read_input_tokens":90000,"cache_creation_input_tokens":2000,"output_tokens":10}}}
        \\{"type":"assistant","sessionId":"bbbbbbbb-0000-4000-8000-000000000002","entrypoint":"cli","timestamp":"1999-01-01T00:00:00Z","message":{"id":"old","model":"claude-fable-5-2","usage":{"input_tokens":5,"cache_read_input_tokens":90000,"cache_creation_input_tokens":2000,"output_tokens":10}}}
        \\
    );
    // A Codex rollout driven by Marlin: a repeated report is one call.
    try write(io, home, ".codex/sessions/2099/01/01/rollout-x.jsonl",
        \\{"timestamp":"2099-01-01T00:00:00Z","type":"session_meta","payload":{"id":"thread-1","originator":"marlin"}}
        \\{"timestamp":"2099-01-01T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6-sol"}}
        \\{"timestamp":"2099-01-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120100},"last_token_usage":{"input_tokens":120000,"cached_input_tokens":118000,"output_tokens":100}}}}
        \\{"timestamp":"2099-01-01T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120100},"last_token_usage":{"input_tokens":120000,"cached_input_tokens":118000,"output_tokens":100}}}}
        \\{"timestamp":"2099-01-01T00:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":360300},"last_token_usage":{"input_tokens":240000,"cached_input_tokens":20000,"output_tokens":200}}}}
        \\
    );

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var marlin = cost_report.Marlin{};
    try marlin.claude.put(arena, "aaaaaaaa-0000-4000-8000-000000000001", 7);
    try marlin.names.put(arena, 7, .{ .handle = "be4719c6", .title = "postgres" });
    // Since 2000: the 1999 line is outside the window.
    const report = try cost_report.scan(arena, io, home, 946_684_800_000, &marlin);

    try std.testing.expectEqual(@as(u64, 3), report.files);
    var marlin_claude: ?cost.Group = null;
    var interactive: ?cost.Group = null;
    var codex: ?cost.Group = null;
    for (report.groups) |g| {
        if (std.mem.eql(u8, g.backend, "claude_code") and std.mem.eql(u8, g.client, "marlin")) marlin_claude = g;
        if (std.mem.eql(u8, g.backend, "claude_code") and std.mem.eql(u8, g.client, "interactive")) interactive = g;
        if (std.mem.eql(u8, g.backend, "codex")) codex = g;
    }
    try std.testing.expectEqual(@as(u64, 2), marlin_claude.?.requests);
    try std.testing.expectEqual(@as(u64, 1), marlin_claude.?.rewrites);
    try std.testing.expectEqual(@as(u64, 286_000), marlin_claude.?.rewrite_tokens);
    try std.testing.expectEqual(@as(u64, 286_000), marlin_claude.?.cache_write_5m);
    try std.testing.expectEqual(@as(u64, 1_000), marlin_claude.?.cache_write_1h);
    try std.testing.expectEqual(@as(u64, 1), interactive.?.requests);
    try std.testing.expectEqualStrings("marlin", codex.?.client);
    try std.testing.expectEqualStrings("gpt-6-sol", codex.?.model);
    try std.testing.expectEqual(@as(u64, 2), codex.?.requests);
    try std.testing.expectEqual(@as(u64, 1), codex.?.rewrites);

    try std.testing.expectEqual(@as(usize, 1), report.sessions.len);
    try std.testing.expectEqualStrings("postgres", report.sessions[0].title);
    try std.testing.expectEqual(@as(u64, 2), report.sessions[0].requests);
}

/// Protobuf fields as agy writes them: varints, and nested messages or
/// strings.
fn pb(arena: std.mem.Allocator, fields: anytype) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    inline for (fields) |f| {
        const number: u64 = f[0];
        if (@TypeOf(f[1]) == comptime_int) {
            try varint(arena, &out, number << 3);
            try varint(arena, &out, f[1]);
        } else {
            try varint(arena, &out, number << 3 | 2);
            try varint(arena, &out, f[1].len);
            try out.appendSlice(arena, f[1]);
        }
    }
    return out.items;
}

fn varint(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    var v = value;
    while (v >= 0x80) : (v >>= 7) try out.append(arena, @as(u8, @truncate(v)) | 0x80);
    try out.append(arena, @truncate(v));
}

const Step = struct { metadata: []const u8 };
const Generation = struct { data: []const u8 };

/// An agy conversation database in WAL mode, as agy keeps them. Returns the
/// connection open when `keep_open`: a live writer with its rows still in
/// the log.
fn agyDb(arena: std.mem.Allocator, path: []const u8, generations: []const []const u8, steps: []const []const u8, keep_open: bool) !?*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(try arena.dupeSentinel(u8, path, 0), &db));
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db,
        \\PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        \\CREATE TABLE steps (idx integer, step_type integer, metadata blob, PRIMARY KEY (idx));
        \\CREATE TABLE gen_metadata (idx integer, data blob, PRIMARY KEY (idx));
    , null, null, null));
    for ([_][]const []const u8{ generations, steps }, [_][:0]const u8{ "INSERT INTO gen_metadata VALUES (?, ?)", "INSERT INTO steps VALUES (?, 15, ?)" }) |rows, sql| {
        for (rows, 0..) |row, idx| {
            var stmt: ?*c.sqlite3_stmt = null;
            try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null));
            defer _ = c.sqlite3_finalize(stmt);
            _ = c.sqlite3_bind_int64(stmt, 1, @intCast(idx));
            _ = c.sqlite3_bind_blob(stmt, 2, row.ptr, @intCast(row.len), null);
            try std.testing.expectEqual(c.SQLITE_DONE, c.sqlite3_step(stmt));
        }
    }
    if (keep_open) return db;
    _ = c.sqlite3_close(db);
    return null;
}

test "cost report reads agy's conversation databases, live or closed, and tells Marlin's from agy's own" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cost-agy");
    defer temp.deinit();
    const home = temp.path;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const root = try std.fs.path.join(arena, &.{ home, ".gemini", "antigravity-cli" });
    try write(io, root, "history.jsonl",
        \\{"display":"/model","timestamp":1795400174925,"type":"slash_command"}
        \\{"display":"hi","timestamp":1795400301281,"conversationId":"tui","type":"prompt"}
        \\
    );
    const conversations = try std.fs.path.join(arena, &.{ root, "conversations" });
    try Io.Dir.cwd().createDirPath(io, conversations);

    const in_window = try pb(arena, .{.{ 1, 4_102_444_800 }}); // 2100
    const too_old = try pb(arena, .{.{ 1, 915_148_800 }}); // 1999
    // Marlin's: three requests, one answered by Argon, one with no
    // generation logged (agy's compaction), one outside the window, and a
    // step without usage. The writer is still open: its rows are only in the
    // write-ahead log.
    const live = try agyDb(arena, try std.fs.path.join(arena, &.{ conversations, "marlin-conv.db" }), &.{
        try pb(arena, .{.{ 1, try pb(arena, .{ .{ 4, try pb(arena, .{.{ 7, "r1" }}) }, .{ 19, "gemini-4-neon" } }) }}),
        try pb(arena, .{.{ 1, try pb(arena, .{ .{ 4, try pb(arena, .{.{ 7, "r2" }}) }, .{ 19, "gemini-4-argon" } }) }}),
    }, &.{
        try pb(arena, .{ .{ 1, in_window }, .{ 9, try pb(arena, .{ .{ 1, 1532 }, .{ 2, 11847 }, .{ 3, 173 }, .{ 7, "r1" } }) } }),
        try pb(arena, .{ .{ 1, in_window }, .{ 9, try pb(arena, .{ .{ 2, 2426 }, .{ 3, 79 }, .{ 5, 9790 }, .{ 7, "r1" } }) } }),
        try pb(arena, .{ .{ 1, in_window }, .{ 9, try pb(arena, .{ .{ 2, 2150 }, .{ 3, 654 }, .{ 5, 11674 }, .{ 7, "compaction" } }) } }),
        try pb(arena, .{ .{ 1, too_old }, .{ 9, try pb(arena, .{ .{ 2, 5 }, .{ 3, 5 }, .{ 7, "r1" } }) } }),
        try pb(arena, .{.{ 1, in_window }}),
    }, true);
    defer _ = c.sqlite3_close(live);
    // agy's own terminal session and another headless one, both closed.
    _ = try agyDb(arena, try std.fs.path.join(arena, &.{ conversations, "tui.db" }), &.{
        try pb(arena, .{.{ 1, try pb(arena, .{ .{ 4, try pb(arena, .{.{ 7, "t1" }}) }, .{ 19, "gemini-4-neon" } }) }}),
    }, &.{
        try pb(arena, .{ .{ 1, in_window }, .{ 9, try pb(arena, .{ .{ 2, 120_000 }, .{ 3, 10 }, .{ 7, "t1" } }) } }),
    }, false);
    _ = try agyDb(arena, try std.fs.path.join(arena, &.{ conversations, "other.db" }), &.{}, &.{
        try pb(arena, .{ .{ 1, in_window }, .{ 9, try pb(arena, .{ .{ 2, 100 }, .{ 3, 1 } }) } }),
    }, false);

    var marlin = cost_report.Marlin{};
    try marlin.agy.put(arena, "marlin-conv", 7);
    const report = try cost_report.scan(arena, io, home, 946_684_800_000, &marlin);
    try std.testing.expectEqual(@as(u64, 3), report.files);

    const Want = struct { client: []const u8, model: []const u8, requests: u64, input: u64, cache_read: u64, output: u64, rewrites: u64 };
    const want = [_]Want{
        .{ .client = "marlin", .model = "gemini-4-neon", .requests = 2, .input = 11847 + 2426, .cache_read = 9790, .output = 173 + 79, .rewrites = 0 },
        .{ .client = "marlin", .model = "gemini-4-argon", .requests = 1, .input = 2150, .cache_read = 11674, .output = 654, .rewrites = 0 },
        .{ .client = "interactive", .model = "gemini-4-neon", .requests = 1, .input = 120_000, .cache_read = 0, .output = 10, .rewrites = 1 },
        .{ .client = "other", .model = "?", .requests = 1, .input = 100, .cache_read = 0, .output = 1, .rewrites = 0 },
    };
    var agy_groups: usize = 0;
    for (report.groups) |g| {
        if (!std.mem.eql(u8, g.backend, "agy")) continue;
        agy_groups += 1;
        const w = for (want) |w| {
            if (std.mem.eql(u8, w.client, g.client) and std.mem.eql(u8, w.model, g.model)) break w;
        } else return error.UnexpectedGroup;
        try std.testing.expectEqual(w.requests, g.requests);
        try std.testing.expectEqual(w.input, g.input);
        try std.testing.expectEqual(w.cache_read, g.cache_read);
        try std.testing.expectEqual(w.output, g.output);
        try std.testing.expectEqual(w.rewrites, g.rewrites);
    }
    try std.testing.expectEqual(want.len, agy_groups);
}

test "agy's protobuf reads the first value of a field, and malformed input as absent" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const message = try pb(arena, .{ .{ 2, 300 }, .{ 7, "id" }, .{ 2, 5 } });
    try std.testing.expectEqual(@as(?u64, 300), cost_report.proto.int(message, 2));
    try std.testing.expectEqualStrings("id", cost_report.proto.bytes(message, 7).?);
    try std.testing.expectEqual(@as(?u64, null), cost_report.proto.int(message, 7));
    try std.testing.expectEqual(@as(?[]const u8, null), cost_report.proto.bytes(message, 9));
    // A length running past the end, and a varint that never ends.
    try std.testing.expectEqual(@as(?[]const u8, null), cost_report.proto.bytes(&.{ 7 << 3 | 2, 9, 'x' }, 7));
    try std.testing.expectEqual(@as(?u64, null), cost_report.proto.int(&.{ 2 << 3, 0xff, 0xff }, 2));
}
