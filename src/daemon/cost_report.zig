//! Scans the guests' own request logs for `marlin diagnostics --cost`:
//! Claude Code writes every response's usage to ~/.claude/projects/**.jsonl,
//! Codex every model call's to ~/.codex/sessions/**.jsonl, Antigravity every
//! request's to its conversation databases
//! (~/.gemini/antigravity-cli/conversations/*.db). Comparing Marlin's
//! guests with the vendors' own terminal UIs needs exactly these: they are the
//! only per-request record of both. Runs on a worker thread; files untouched
//! since `since_ms` are skipped without opening them.
const std = @import("std");
const Io = std.Io;
const cost = @import("../core/cost.zig");
const c = @import("sqlite3_c");

/// Which logged sessions are Marlin's, and what to call them.
pub const Marlin = struct {
    /// Claude Code session id (claude_code.sessionUuid) → Marlin session.
    claude: std.StringHashMapUnmanaged(u64) = .empty,
    /// Codex thread id → Marlin session.
    codex: std.StringHashMapUnmanaged(u64) = .empty,
    /// Antigravity conversation id → Marlin session.
    agy: std.StringHashMapUnmanaged(u64) = .empty,
    names: std.AutoHashMapUnmanaged(u64, Name) = .empty,

    pub const Name = struct { handle: []const u8, title: []const u8 };
};

/// Lines longer than this (a pasted image, a huge tool result) are skipped:
/// usage lines are far shorter.
const max_line_bytes: usize = 8 * 1024 * 1024;
const top_sessions: usize = 8;

const Scan = struct {
    arena: std.mem.Allocator,
    io: Io,
    since_ms: i64,
    since_iso: []const u8,
    marlin: *const Marlin,
    /// One line buffer for every file.
    line_buf: []u8 = &.{},
    groups: std.ArrayList(cost.Group) = .empty,
    sessions: std.AutoArrayHashMapUnmanaged(u64, cost.Session) = .empty,
    files: u64 = 0,

    fn group(self: *Scan, backend: []const u8, client: []const u8, model: []const u8) !*cost.Group {
        for (self.groups.items) |*g| {
            if (std.mem.eql(u8, g.backend, backend) and std.mem.eql(u8, g.client, client) and std.mem.eql(u8, g.model, model)) return g;
        }
        try self.groups.append(self.arena, .{ .backend = backend, .client = client, .model = try self.arena.dupe(u8, model) });
        return &self.groups.items[self.groups.items.len - 1];
    }
};

pub fn scan(arena: std.mem.Allocator, io: Io, home: []const u8, since_ms: i64, marlin: *const Marlin) !cost.Report {
    var iso_buf: [32]u8 = undefined;
    var s = Scan{ .arena = arena, .io = io, .since_ms = since_ms, .since_iso = isoUtc(&iso_buf, since_ms), .marlin = marlin };
    s.line_buf = try arena.alloc(u8, max_line_bytes);
    const claude_root = try std.fs.path.join(arena, &.{ home, ".claude", "projects" });
    const codex_root = try std.fs.path.join(arena, &.{ home, ".codex", "sessions" });
    try walk(&s, claude_root, .claude_code);
    try walk(&s, codex_root, .codex);
    try scanAgy(&s, try std.fs.path.join(arena, &.{ home, ".gemini", "antigravity-cli" }));

    std.mem.sort(cost.Group, s.groups.items, {}, struct {
        fn lessThan(_: void, a: cost.Group, b: cost.Group) bool {
            const order = std.mem.order(u8, a.backend, b.backend);
            if (order != .eq) return order == .lt;
            if (rank(a.client) != rank(b.client)) return rank(a.client) < rank(b.client);
            return a.requests > b.requests;
        }
        fn rank(client: []const u8) u8 {
            return if (std.mem.eql(u8, client, "marlin")) 0 else if (std.mem.eql(u8, client, "interactive")) 1 else 2;
        }
    }.lessThan);
    const sessions = s.sessions.values();
    std.mem.sort(cost.Session, sessions, {}, struct {
        fn lessThan(_: void, a: cost.Session, b: cost.Session) bool {
            return a.cost_units > b.cost_units;
        }
    }.lessThan);
    return .{
        .since_ms = since_ms,
        .files = s.files,
        .groups = s.groups.items,
        .sessions = sessions[0..@min(sessions.len, top_sessions)],
    };
}

const Backend = enum { claude_code, codex };

fn walk(s: *Scan, root: []const u8, backend: Backend) !void {
    var dir = Io.Dir.cwd().openDir(s.io, root, .{ .iterate = true }) catch return;
    defer dir.close(s.io);
    var walker = try dir.walk(s.arena);
    defer walker.deinit();
    while (walker.next(s.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
        const st = dir.statFile(s.io, entry.path, .{}) catch continue;
        if (@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms) < s.since_ms) continue;
        var file = dir.openFile(s.io, entry.path, .{}) catch continue;
        defer file.close(s.io);
        s.files += 1;
        switch (backend) {
            .claude_code => scanClaude(s, file) catch {},
            .codex => scanCodex(s, file) catch {},
        }
    }
}

/// Each complete line of `file`, skipping any longer than max_line_bytes.
const Lines = struct {
    reader: Io.File.Reader,

    fn next(self: *Lines) ?[]const u8 {
        while (true) {
            const line = self.reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    _ = self.reader.interface.discardDelimiterInclusive('\n') catch return null;
                    continue;
                },
                else => return null,
            };
            return line;
        }
    }
};

const ClaudeLine = struct {
    type: []const u8 = "",
    sessionId: []const u8 = "",
    entrypoint: []const u8 = "",
    timestamp: []const u8 = "",
    message: ?struct {
        id: ?[]const u8 = null,
        model: []const u8 = "",
        usage: ?struct {
            input_tokens: u64 = 0,
            cache_read_input_tokens: u64 = 0,
            cache_creation_input_tokens: u64 = 0,
            output_tokens: u64 = 0,
            cache_creation: ?struct {
                ephemeral_5m_input_tokens: u64 = 0,
                ephemeral_1h_input_tokens: u64 = 0,
            } = null,
        } = null,
    } = null,
};

fn scanClaude(s: *Scan, file: Io.File) !void {
    var lines = Lines{ .reader = file.reader(s.io, s.line_buf) };
    var line_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer line_arena.deinit();
    // One response is logged once per content block, each with its usage.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var seen_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer seen_arena.deinit();
    while (lines.next()) |raw| {
        if (std.mem.indexOf(u8, raw, "\"usage\"") == null or std.mem.indexOf(u8, raw, "\"assistant\"") == null) continue;
        _ = line_arena.reset(.retain_capacity);
        const line = std.json.parseFromSliceLeaky(ClaudeLine, line_arena.allocator(), raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (!std.mem.eql(u8, line.type, "assistant")) continue;
        if (line.timestamp.len > 0 and std.mem.order(u8, line.timestamp, s.since_iso) == .lt) continue;
        const message = line.message orelse continue;
        const usage = message.usage orelse continue;
        if (message.model.len == 0 or message.model[0] == '<') continue;
        if (message.id) |id| {
            const gop = try seen.getOrPut(seen_arena.allocator(), id);
            if (gop.found_existing) continue;
            gop.key_ptr.* = try seen_arena.allocator().dupe(u8, id);
        }
        const sid = s.marlin.claude.get(line.sessionId);
        const client: []const u8 = if (sid != null) "marlin" else if (std.mem.eql(u8, line.entrypoint, "cli")) "interactive" else "other";
        var w5m = usage.cache_creation_input_tokens;
        var w1h: u64 = 0;
        if (usage.cache_creation) |split| {
            w5m = split.ephemeral_5m_input_tokens;
            w1h = split.ephemeral_1h_input_tokens;
        }
        const g = try s.group("claude_code", client, message.model);
        const context = usage.input_tokens + usage.cache_read_input_tokens + w5m + w1h;
        const rewrite = cost.isRewrite(context, w5m + w1h + usage.input_tokens);
        g.requests += 1;
        g.input += usage.input_tokens;
        g.cache_read += usage.cache_read_input_tokens;
        g.cache_write_5m += w5m;
        g.cache_write_1h += w1h;
        g.output += usage.output_tokens;
        if (rewrite) {
            g.rewrites += 1;
            g.rewrite_tokens += w5m + w1h;
        }
        const id = sid orelse continue;
        const gop = try s.sessions.getOrPut(s.arena, id);
        if (!gop.found_existing) {
            const name = s.marlin.names.get(id) orelse Marlin.Name{ .handle = "", .title = "" };
            gop.value_ptr.* = .{ .sid = id, .handle = name.handle, .title = name.title, .model = g.model };
        }
        const entry = gop.value_ptr;
        entry.requests += 1;
        entry.context += context;
        entry.cost_units += cost.claudeCostUnits(usage.input_tokens, usage.cache_read_input_tokens, w5m, w1h, usage.output_tokens);
        if (rewrite) {
            entry.rewrites += 1;
            entry.rewrite_tokens += w5m + w1h;
        }
    }
}

const CodexLine = struct {
    timestamp: []const u8 = "",
    type: []const u8 = "",
    payload: ?struct {
        type: []const u8 = "",
        id: []const u8 = "",
        originator: []const u8 = "",
        model: []const u8 = "",
        info: ?struct {
            total_token_usage: ?struct { total_tokens: u64 = 0 } = null,
            last_token_usage: ?struct {
                input_tokens: u64 = 0,
                cached_input_tokens: u64 = 0,
                output_tokens: u64 = 0,
            } = null,
        } = null,
    } = null,
};

fn scanCodex(s: *Scan, file: Io.File) !void {
    var lines = Lines{ .reader = file.reader(s.io, s.line_buf) };
    var line_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer line_arena.deinit();
    var client: []const u8 = "other";
    var model_buf: [128]u8 = undefined;
    var model: []const u8 = "?";
    var last_total: u64 = 0;
    while (lines.next()) |raw| {
        const meta = std.mem.indexOf(u8, raw, "\"session_meta\"") != null;
        const turn = std.mem.indexOf(u8, raw, "\"turn_context\"") != null;
        const tokens = std.mem.indexOf(u8, raw, "\"token_count\"") != null;
        if (!meta and !turn and !tokens) continue;
        _ = line_arena.reset(.retain_capacity);
        const line = std.json.parseFromSliceLeaky(CodexLine, line_arena.allocator(), raw, .{ .ignore_unknown_fields = true }) catch continue;
        const payload = line.payload orelse continue;
        if (std.mem.eql(u8, line.type, "session_meta")) {
            client = if (std.mem.eql(u8, payload.originator, "marlin") or s.marlin.codex.get(payload.id) != null)
                "marlin"
            else if (std.mem.startsWith(u8, payload.originator, "codex-tui") or std.mem.eql(u8, payload.originator, "codex_cli_rs"))
                "interactive"
            else
                "other";
            continue;
        }
        if (std.mem.eql(u8, line.type, "turn_context")) {
            const n = @min(payload.model.len, model_buf.len);
            @memcpy(model_buf[0..n], payload.model[0..n]);
            model = model_buf[0..n];
            continue;
        }
        if (!std.mem.eql(u8, payload.type, "token_count")) continue;
        if (line.timestamp.len > 0 and std.mem.order(u8, line.timestamp, s.since_iso) == .lt) continue;
        const info = payload.info orelse continue;
        const last = info.last_token_usage orelse continue;
        // A repeated report (rate limits refreshed) is the same call.
        const total = if (info.total_token_usage) |t| t.total_tokens else 0;
        if (total != 0 and total == last_total) continue;
        last_total = total;
        const cached = @min(last.cached_input_tokens, last.input_tokens);
        const g = try s.group("codex", client, model);
        g.requests += 1;
        g.input += last.input_tokens - cached;
        g.cache_read += cached;
        g.output += last.output_tokens;
        if (cost.isRewrite(last.input_tokens, last.input_tokens - cached)) {
            g.rewrites += 1;
            g.rewrite_tokens += last.input_tokens - cached;
        }
    }
}

/// Antigravity's conversations: one SQLite file each, the usage only in its
/// own undocumented protobuf. A step's metadata holds the request's time
/// (field 1, a Timestamp) and usage (field 9: 2 uncached input, 5 cache
/// read, 3 output, 7 response id); the response's model is in gen_metadata
/// (1.19, keyed by the same response id at 1.4.7). These were matched
/// against the usage agy reports over ACP for the same requests; anything
/// that does not decode is skipped.
fn scanAgy(s: *Scan, root: []const u8) !void {
    const conversations = try std.fs.path.join(s.arena, &.{ root, "conversations" });
    var dir = Io.Dir.cwd().openDir(s.io, conversations, .{ .iterate = true }) catch return;
    defer dir.close(s.io);
    const interactive = try agyInteractive(s, root);
    var it = dir.iterate();
    while (it.next(s.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".db")) continue;
        // agy writes through a WAL: the database file can be older than
        // the conversation's last request.
        const wal = try std.fmt.allocPrint(s.arena, "{s}-wal", .{entry.name});
        const st = dir.statFile(s.io, wal, .{}) catch dir.statFile(s.io, entry.name, .{}) catch continue;
        if (@divTrunc(st.mtime.nanoseconds, std.time.ns_per_ms) < s.since_ms) continue;
        const id = entry.name[0 .. entry.name.len - ".db".len];
        const path = try std.fs.path.join(s.arena, &.{ conversations, entry.name });
        const db = openAgy(s.arena, path) orelse continue;
        defer _ = c.sqlite3_close(db);
        s.files += 1;
        const client: []const u8 = if (s.marlin.agy.get(id) != null) "marlin" else if (interactive.contains(id)) "interactive" else "other";
        scanAgyConversation(s, db, client) catch {};
    }
}

/// Conversations typed into agy's own terminal UI: its prompt history
/// names them.
fn agyInteractive(s: *Scan, root: []const u8) !std.StringHashMapUnmanaged(void) {
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    const path = try std.fs.path.join(s.arena, &.{ root, "history.jsonl" });
    var file = Io.Dir.cwd().openFile(s.io, path, .{}) catch return ids;
    defer file.close(s.io);
    var lines = Lines{ .reader = file.reader(s.io, s.line_buf) };
    var line_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer line_arena.deinit();
    while (lines.next()) |raw| {
        _ = line_arena.reset(.retain_capacity);
        const line = std.json.parseFromSliceLeaky(struct { conversationId: []const u8 = "" }, line_arena.allocator(), raw, .{ .ignore_unknown_fields = true }) catch continue;
        if (line.conversationId.len == 0 or ids.contains(line.conversationId)) continue;
        try ids.put(s.arena, try s.arena.dupe(u8, line.conversationId), {});
    }
    return ids;
}

/// Opens agy's database without writing to it. While agy has it open, a
/// read-only connection reads its write-ahead log too; when nothing does,
/// there is no shared-memory file for one to use, and the database file is
/// complete on its own, so it is read as immutable.
fn openAgy(arena: std.mem.Allocator, path: []const u8) ?*c.sqlite3 {
    for ([_][]const u8{ "mode=ro", "immutable=1" }) |param| {
        var uri: std.ArrayList(u8) = .empty;
        uri.appendSlice(arena, "file:") catch return null;
        for (path) |byte| switch (byte) {
            '%', '?', '#' => uri.print(arena, "%{X:0>2}", .{byte}) catch return null,
            else => uri.append(arena, byte) catch return null,
        };
        uri.print(arena, "?{s}\x00", .{param}) catch return null;
        var db: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(uri.items.ptr, &db, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_URI, null) == c.SQLITE_OK) {
            // A read-only open that cannot use the log fails on first read.
            var stmt: ?*c.sqlite3_stmt = null;
            if (c.sqlite3_prepare_v2(db, "SELECT 1 FROM steps LIMIT 0", -1, &stmt, null) == c.SQLITE_OK) {
                _ = c.sqlite3_finalize(stmt);
                return db;
            }
        }
        _ = c.sqlite3_close(db);
    }
    return null;
}

fn scanAgyConversation(s: *Scan, db: *c.sqlite3, client: []const u8) !void {
    // The model of each response, and the last one as the fallback for a
    // request agy logged no generation for (its own compaction).
    var models: std.StringHashMapUnmanaged([]const u8) = .empty;
    var last_model: []const u8 = "?";
    {
        const stmt = try agyQuery(db, "SELECT data FROM gen_metadata ORDER BY idx");
        defer _ = c.sqlite3_finalize(stmt);
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const generation = proto.bytes(columnBlob(stmt), 1) orelse continue;
            const model = proto.bytes(generation, 19) orelse continue;
            last_model = try s.arena.dupe(u8, model);
            const usage = proto.bytes(generation, 4) orelse continue;
            const id = proto.bytes(usage, 7) orelse continue;
            try models.put(s.arena, try s.arena.dupe(u8, id), last_model);
        }
    }
    const stmt = try agyQuery(db, "SELECT metadata FROM steps ORDER BY idx");
    defer _ = c.sqlite3_finalize(stmt);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const metadata = columnBlob(stmt);
        const usage = proto.bytes(metadata, 9) orelse continue;
        if (proto.bytes(metadata, 1)) |created| if (proto.int(created, 1)) |seconds| {
            if (@as(i64, @intCast(@min(seconds, std.math.maxInt(i64) / std.time.ms_per_s))) * std.time.ms_per_s < s.since_ms) continue;
        };
        const uncached = proto.int(usage, 2) orelse 0;
        const cached = proto.int(usage, 5) orelse 0;
        const output = proto.int(usage, 3) orelse 0;
        if (uncached + cached + output == 0) continue;
        const model = if (proto.bytes(usage, 7)) |id| models.get(id) orelse last_model else last_model;
        const g = try s.group("agy", client, model);
        g.requests += 1;
        g.input += uncached;
        g.cache_read += cached;
        g.output += output;
        if (cost.isRewrite(uncached + cached, uncached)) {
            g.rewrites += 1;
            g.rewrite_tokens += uncached;
        }
    }
}

fn agyQuery(db: *c.sqlite3, sql: [:0]const u8) !*c.sqlite3_stmt {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.AgyQueryFailed;
    return stmt.?;
}

fn columnBlob(stmt: *c.sqlite3_stmt) []const u8 {
    const ptr = c.sqlite3_column_blob(stmt, 0) orelse return &.{};
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

/// The first value of a protobuf message's field, for the few read from
/// agy's records. Malformed input reads as absent.
pub const proto = struct {
    const Value = union(enum) { int: u64, bytes: []const u8 };

    fn find(message: []const u8, number: u64) ?Value {
        var pos: usize = 0;
        while (pos < message.len) {
            const key = varint(message, &pos) orelse return null;
            const value: Value = switch (@as(u3, @truncate(key))) {
                0 => .{ .int = varint(message, &pos) orelse return null },
                1 => .{ .int = fixed(message, &pos, 8) orelse return null },
                5 => .{ .int = fixed(message, &pos, 4) orelse return null },
                2 => blk: {
                    const len = varint(message, &pos) orelse return null;
                    if (len > message.len - pos) return null;
                    defer pos += @intCast(len);
                    break :blk .{ .bytes = message[pos..][0..@intCast(len)] };
                },
                else => return null,
            };
            if (key >> 3 == number) return value;
        }
        return null;
    }

    pub fn int(message: []const u8, number: u64) ?u64 {
        return switch (find(message, number) orelse return null) {
            .int => |v| v,
            .bytes => null,
        };
    }

    pub fn bytes(message: []const u8, number: u64) ?[]const u8 {
        return switch (find(message, number) orelse return null) {
            .bytes => |v| v,
            .int => null,
        };
    }

    fn varint(message: []const u8, pos: *usize) ?u64 {
        var result: u64 = 0;
        var shift: u7 = 0;
        while (pos.* < message.len and shift < 64) : (shift += 7) {
            const byte = message[pos.*];
            pos.* += 1;
            result |= @as(u64, byte & 0x7f) << @intCast(shift);
            if (byte & 0x80 == 0) return result;
        }
        return null;
    }

    fn fixed(message: []const u8, pos: *usize, comptime n: usize) ?u64 {
        if (message.len - pos.* < n) return null;
        defer pos.* += n;
        return std.mem.readInt(@Int(.unsigned, n * 8), message[pos.*..][0..n], .little);
    }
};

/// "2026-11-22T09:41:07" for comparing with the logs' UTC timestamps.
pub fn isoUtc(buf: *[32]u8, ms: i64) []const u8 {
    const secs: u64 = @intCast(@max(@divTrunc(ms, 1000), 0));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch "";
}
