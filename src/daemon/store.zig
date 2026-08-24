//! The store: SQLite. THE ONLY FILE THAT KNOWS SQL.
//!
//! Schema (docs/ARCHITECTURE.md §2). WAL mode for crash safety. Blocks are
//! INSERT-only; the sessions row is the only thing UPDATEd. Blob writes are
//! idempotent (content-hash PK). FTS5 deferred to M1 (search lands with ls).
//!
//! DB path: ~/.local/state/marlin/marlin.db (respects XDG_STATE_HOME).

const std = @import("std");
const block = @import("../core/block.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// We always sqlite3_step() before the bound Zig slices go out of scope, so
/// SQLITE_STATIC (no copy, null destructor) is safe and avoids the
/// SQLITE_TRANSIENT translate-c problem (it's `(void(*)(void*))-1`, which
/// Zig rejects as an unaligned fn pointer).
const static_destructor: c.sqlite3_destructor_type = null;

pub const Error = error{
    SqliteOpen,
    SqliteExec,
    SqlitePrepare,
    SqliteStep,
    NotFound,
    OutOfMemory,
};

const schema_sql =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
    \\PRAGMA foreign_keys=ON;
    \\CREATE TABLE IF NOT EXISTS kv(
    \\  key TEXT PRIMARY KEY, value TEXT NOT NULL
    \\) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS sessions(
    \\  id INTEGER PRIMARY KEY,
    \\  title TEXT NOT NULL DEFAULT '',
    \\  created_at INTEGER NOT NULL,
    \\  cwd TEXT NOT NULL,
    \\  model TEXT NOT NULL,
    \\  status TEXT NOT NULL DEFAULT 'idle',
    \\  pinned_context TEXT NOT NULL DEFAULT '',
    \\  tokens_in INTEGER NOT NULL DEFAULT 0,
    \\  tokens_out INTEGER NOT NULL DEFAULT 0
    \\);
    \\CREATE TABLE IF NOT EXISTS blocks(
    \\  id INTEGER PRIMARY KEY,
    \\  session_id INTEGER NOT NULL REFERENCES sessions(id),
    \\  turn_id INTEGER NOT NULL,
    \\  seq INTEGER NOT NULL,
    \\  kind TEXT NOT NULL,
    \\  ts INTEGER NOT NULL,
    \\  body_json TEXT NOT NULL,
    \\  UNIQUE(session_id, seq)
    \\);
    \\CREATE INDEX IF NOT EXISTS blocks_by_session ON blocks(session_id, seq);
    \\CREATE TABLE IF NOT EXISTS blobs(
    \\  hash TEXT PRIMARY KEY,
    \\  bytes BLOB NOT NULL
    \\) WITHOUT ROWID;
    \\INSERT OR IGNORE INTO kv(key,value) VALUES('schema_version','1');
;

pub const SessionRow = struct {
    id: u64,
    title: []const u8,
    cwd: []const u8,
    model: []const u8,
    status: []const u8,
    tokens_in: u64,
    tokens_out: u64,
};

pub const Store = struct {
    db: *c.sqlite3,
    gpa: std.mem.Allocator,

    /// Open (creating schema if needed). `path` null → in-memory (tests).
    pub fn open(gpa: std.mem.Allocator, path: ?[:0]const u8) Error!Store {
        var db: ?*c.sqlite3 = null;
        const p: [*c]const u8 = if (path) |pp| pp.ptr else ":memory:";
        if (c.sqlite3_open(p, &db) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpen;
        }
        const store = Store{ .db = db.?, .gpa = gpa };
        try store.execAll(schema_sql);
        return store;
    }

    pub fn close(self: *Store) void {
        _ = c.sqlite3_close(self.db);
    }

    fn execAll(self: Store, sql: [:0]const u8) Error!void {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(self.db, sql.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            if (errmsg != null) c.sqlite3_free(errmsg);
            return error.SqliteExec;
        }
    }

    // ---------------------------------------------------------- sessions --

    pub fn createSession(self: Store, id: u64, created_at: i64, cwd: []const u8, model: []const u8) Error!void {
        const stmt = try self.prepare(
            "INSERT INTO sessions(id, created_at, cwd, model) VALUES(?,?,?,?)",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        bindInt(stmt, 2, created_at);
        bindText(stmt, 3, cwd);
        bindText(stmt, 4, model);
        try stepDone(stmt);
    }

    pub fn updateSessionUsage(self: Store, id: u64, tokens_in: u64, tokens_out: u64) Error!void {
        const stmt = try self.prepare(
            "UPDATE sessions SET tokens_in=?, tokens_out=? WHERE id=?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @intCast(tokens_in));
        bindInt(stmt, 2, @intCast(tokens_out));
        bindInt(stmt, 3, @bitCast(id));
        try stepDone(stmt);
    }

    pub const SessionListing = struct {
        id: u64,
        title: []const u8,
        model: []const u8,
        status: []const u8,
        created_at: i64,

        pub fn deinit(self: SessionListing, gpa: std.mem.Allocator) void {
            gpa.free(self.title);
            gpa.free(self.model);
            gpa.free(self.status);
        }
    };

    /// All sessions, newest first. Caller deinits each entry + frees slice.
    pub fn listSessions(self: Store) Error![]SessionListing {
        const stmt = try self.prepare(
            "SELECT id, title, model, status, created_at FROM sessions ORDER BY created_at DESC, id DESC",
        );
        defer finalize(stmt);
        var out: std.ArrayList(SessionListing) = .empty;
        errdefer {
            for (out.items) |s| s.deinit(self.gpa);
            out.deinit(self.gpa);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            try out.append(self.gpa, .{
                .id = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                .title = try self.dupeCol(stmt, 1),
                .model = try self.dupeCol(stmt, 2),
                .status = try self.dupeCol(stmt, 3),
                .created_at = c.sqlite3_column_int64(stmt, 4),
            });
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Most recently created session id, if any (for `marlin run --continue`).
    pub fn lastSession(self: Store) Error!?u64 {
        const stmt = try self.prepare(
            "SELECT id FROM sessions ORDER BY created_at DESC, id DESC LIMIT 1",
        );
        defer finalize(stmt);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_ROW) return @bitCast(c.sqlite3_column_int64(stmt, 0));
        if (rc == c.SQLITE_DONE) return null;
        return error.SqliteStep;
    }

    /// Fetch one session row. Strings are allocated with gpa; caller frees.
    pub fn getSession(self: Store, id: u64) Error!SessionRow {
        const stmt = try self.prepare(
            "SELECT title, cwd, model, status, tokens_in, tokens_out FROM sessions WHERE id=?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.NotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        return .{
            .id = id,
            .title = try self.dupeCol(stmt, 0),
            .cwd = try self.dupeCol(stmt, 1),
            .model = try self.dupeCol(stmt, 2),
            .status = try self.dupeCol(stmt, 3),
            .tokens_in = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .tokens_out = @intCast(c.sqlite3_column_int64(stmt, 5)),
        };
    }

    pub fn freeSession(self: Store, row: SessionRow) void {
        self.gpa.free(row.title);
        self.gpa.free(row.cwd);
        self.gpa.free(row.model);
        self.gpa.free(row.status);
    }

    // ------------------------------------------------------------ blocks --

    /// Append a block. body is serialized to JSON here.
    pub fn appendBlock(self: Store, blk: block.Block) Error!void {
        const body_json = std.json.Stringify.valueAlloc(self.gpa, blk.body, .{}) catch
            return error.OutOfMemory;
        defer self.gpa.free(body_json);

        const stmt = try self.prepare(
            "INSERT INTO blocks(id, session_id, turn_id, seq, kind, ts, body_json) VALUES(?,?,?,?,?,?,?)",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(blk.id));
        bindInt(stmt, 2, @bitCast(blk.session_id));
        bindInt(stmt, 3, @bitCast(blk.turn_id));
        bindInt(stmt, 4, @bitCast(blk.seq));
        bindText(stmt, 5, @tagName(blk.kind()));
        bindInt(stmt, 6, blk.ts);
        bindText(stmt, 7, body_json);
        try stepDone(stmt);
    }

    pub const LoadedBlock = struct {
        blk: block.Block,
        /// Arena holding all strings referenced by blk.body.
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *LoadedBlock) void {
            self.arena.deinit();
        }
    };

    /// Load blocks for a session with seq >= from_seq, ascending, up to limit.
    /// Caller deinits each LoadedBlock and frees the returned slice.
    pub fn getBlocks(self: Store, session_id: u64, from_seq: u64, limit: u32) Error![]LoadedBlock {
        const stmt = try self.prepare(
            "SELECT id, turn_id, seq, ts, body_json FROM blocks WHERE session_id=? AND seq>=? ORDER BY seq ASC LIMIT ?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(from_seq));
        bindInt(stmt, 3, @intCast(limit));

        var out: std.ArrayList(LoadedBlock) = .empty;
        errdefer {
            for (out.items) |*lb| lb.deinit();
            out.deinit(self.gpa);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;

            var arena = std.heap.ArenaAllocator.init(self.gpa);
            errdefer arena.deinit();
            const a = arena.allocator();

            const body_ptr = c.sqlite3_column_text(stmt, 4);
            const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            // Copy into the arena: sqlite's column memory dies at finalize,
            // and parseFromSliceLeaky returns strings pointing into its input.
            const body_json = try a.dupe(u8, body_ptr[0..body_len]);

            const body = std.json.parseFromSliceLeaky(block.Body, a, body_json, .{
                .ignore_unknown_fields = true,
            }) catch return error.SqliteStep;

            try out.append(self.gpa, .{
                .blk = .{
                    .id = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                    .session_id = session_id,
                    .turn_id = @bitCast(c.sqlite3_column_int64(stmt, 1)),
                    .seq = @bitCast(c.sqlite3_column_int64(stmt, 2)),
                    .ts = c.sqlite3_column_int64(stmt, 3),
                    .body = body,
                },
                .arena = arena,
            });
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Highest seq in a session (0 when empty).
    pub fn lastSeq(self: Store, session_id: u64) Error!u64 {
        const stmt = try self.prepare(
            "SELECT COALESCE(MAX(seq),0) FROM blocks WHERE session_id=?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        const rc = c.sqlite3_step(stmt);
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        return @bitCast(c.sqlite3_column_int64(stmt, 0));
    }

    // ------------------------------------------------------------- blobs --

    /// Store bytes content-addressed; returns hex hash (allocated, caller frees).
    pub fn putBlob(self: Store, bytes: []const u8) Error![]const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.allocPrint(self.gpa, "{x}", .{&digest}) catch
            return error.OutOfMemory;
        errdefer self.gpa.free(hex);

        const stmt = try self.prepare("INSERT OR IGNORE INTO blobs(hash, bytes) VALUES(?,?)");
        defer finalize(stmt);
        bindText(stmt, 1, hex);
        _ = c.sqlite3_bind_blob(stmt, 2, bytes.ptr, @intCast(bytes.len), static_destructor);
        try stepDone(stmt);
        return hex;
    }

    pub fn getBlob(self: Store, hash: []const u8) Error![]const u8 {
        const stmt = try self.prepare("SELECT bytes FROM blobs WHERE hash=?");
        defer finalize(stmt);
        bindText(stmt, 1, hash);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.NotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        const ptr = c.sqlite3_column_blob(stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (len == 0) return try self.gpa.dupe(u8, "");
        const bytes: [*]const u8 = @ptrCast(ptr.?);
        return try self.gpa.dupe(u8, bytes[0..len]);
    }

    // ----------------------------------------------------------- helpers --

    fn prepare(self: Store, comptime sql: [:0]const u8) Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return error.SqlitePrepare;
        return stmt.?;
    }

    fn dupeCol(self: Store, stmt: *c.sqlite3_stmt, col: c_int) Error![]const u8 {
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return self.gpa.dupe(u8, ptr[0..len]);
    }
};

fn finalize(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

fn bindInt(stmt: *c.sqlite3_stmt, idx: c_int, v: i64) void {
    _ = c.sqlite3_bind_int64(stmt, idx, v);
}

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, s: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, idx, s.ptr, @intCast(s.len), static_destructor);
}

fn stepDone(stmt: *c.sqlite3_stmt) Error!void {
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteStep;
}

/// Resolve the default DB path: $XDG_STATE_HOME/marlin/marlin.db or
/// ~/.local/state/marlin/marlin.db. Creates directories. Caller frees.
pub fn defaultDbPath(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) ![:0]u8 {
    var state_home_owned: ?[]u8 = null;
    defer if (state_home_owned) |s| gpa.free(s);
    const state_home: []const u8 = blk: {
        if (environ.get("XDG_STATE_HOME")) |x| {
            if (x.len > 0) break :blk x;
        }
        const home = environ.get("HOME") orelse return error.NoHome;
        state_home_owned = try std.fs.path.join(gpa, &.{ home, ".local", "state" });
        break :blk state_home_owned.?;
    };
    const dir = try std.fs.path.join(gpa, &.{ state_home, "marlin" });
    defer gpa.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    return std.fmt.allocPrintSentinel(gpa, "{s}/marlin.db", .{dir}, 0);
}

// ---------------------------------------------------------------- tests --

test "session + block round trip (in-memory)" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try store.createSession(42, 1700000000000, "/tmp", "openrouter/foo");
    try std.testing.expectEqual(@as(?u64, 42), try store.lastSession());

    const blk1 = block.Block{
        .id = 1,
        .session_id = 42,
        .turn_id = 1,
        .seq = 1,
        .ts = 1700000000001,
        .body = .{ .user_msg = .{ .text = "hello world" } },
    };
    try store.appendBlock(blk1);
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

    try std.testing.expectEqual(@as(u64, 2), try store.lastSeq(42));

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
    try store.createSession(1, 0, "/", "m");
    const mk = struct {
        fn blk(seq: u64) block.Block {
            return .{ .id = seq, .session_id = 1, .turn_id = 1, .seq = seq, .ts = 0, .body = .{ .user_msg = .{ .text = "x" } } };
        }
    };
    try store.appendBlock(mk.blk(1));
    try std.testing.expectError(error.SqliteStep, store.appendBlock(mk.blk(1)));
}

test "blob round trip is content-addressed and idempotent" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    const h1 = try store.putBlob("big tool output");
    defer gpa.free(h1);
    const h2 = try store.putBlob("big tool output");
    defer gpa.free(h2);
    try std.testing.expectEqualStrings(h1, h2);

    const bytes = try store.getBlob(h1);
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("big tool output", bytes);

    try std.testing.expectError(error.NotFound, store.getBlob("nope"));
}
