//! Scans the guests' own request logs for `marlin diagnostics --cost`:
//! Claude Code writes every response's usage to ~/.claude/projects/**.jsonl,
//! Codex every model call's to ~/.codex/sessions/**.jsonl. Comparing Marlin's
//! guests with the vendors' own terminal UIs needs exactly these: they are the
//! only per-request record of both. Runs on a worker thread; files untouched
//! since `since_ms` are skipped without opening them.
const std = @import("std");
const Io = std.Io;
const cost = @import("../core/cost.zig");

/// Which logged sessions are Marlin's, and what to call them.
pub const Marlin = struct {
    /// Claude Code session id (claude_code.sessionUuid) → Marlin session.
    claude: std.StringHashMapUnmanaged(u64) = .empty,
    /// Codex thread id → Marlin session.
    codex: std.StringHashMapUnmanaged(u64) = .empty,
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
