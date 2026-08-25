//! The store: SQLite. THE ONLY FILE THAT KNOWS SQL.
//!
//! Schema (docs/ARCHITECTURE.md §2). WAL mode for crash safety. Blocks are
//! INSERT-only; the sessions row is the only thing UPDATEd. Blob writes are
//! idempotent (content-hash PK). FTS5 is a future cross-session search feature.
//!
//! DB path: ~/.local/state/marlin/marlin.db (respects XDG_STATE_HOME).

const std = @import("std");
const block = @import("../core/block.zig");
const Effort = @import("../core/effort.zig").Effort;
const proto = @import("../core/proto.zig");

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
    \\PRAGMA auto_vacuum=INCREMENTAL;
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
    \\  effort TEXT NOT NULL DEFAULT 'auto',
    \\  status TEXT NOT NULL DEFAULT 'idle',
    \\  pinned_context TEXT NOT NULL DEFAULT '',
    \\  tokens_in INTEGER NOT NULL DEFAULT 0,
    \\  tokens_out INTEGER NOT NULL DEFAULT 0,
    \\  parent_sid INTEGER REFERENCES sessions(id),
    \\  kind TEXT NOT NULL DEFAULT 'root',
    \\  parent_block_id INTEGER REFERENCES blocks(id),
    \\  max_rounds INTEGER,
    \\  archived_at INTEGER
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
    \\  bytes BLOB NOT NULL,
    \\  created_at INTEGER NOT NULL DEFAULT 0,
    \\  tombstone INTEGER NOT NULL DEFAULT 0
    \\) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS blob_refs(
    \\  hash TEXT NOT NULL,
    \\  block_id INTEGER NOT NULL,
    \\  PRIMARY KEY(hash, block_id)
    \\) WITHOUT ROWID;
    \\INSERT OR IGNORE INTO kv(key,value) VALUES('schema_version','5');
;

pub const SessionRow = struct {
    id: u64,
    parent_sid: ?u64,
    kind: proto.SessionKind,
    parent_block_id: ?u64,
    max_rounds: u32,
    title: []const u8,
    cwd: []const u8,
    model: []const u8,
    effort: Effort,
    status: []const u8,
    tokens_in: u64,
    tokens_out: u64,
    archived: bool,
};

pub const Store = struct {
    db: *c.sqlite3,
    gpa: std.mem.Allocator,

    /// Open (creating schema if needed). `path` null → in-memory (tests).
    pub fn open(gpa: std.mem.Allocator, path: ?[:0]const u8) Error!Store {
        var db: ?*c.sqlite3 = null;
        const p: [*c]const u8 = if (path) |pp| pp.ptr else ":memory:";
        // This one connection is shared across threads: turn threads append
        // blocks while the dispatcher answers queries. FULLMUTEX forces
        // sqlite's serialized mode regardless of how the system library was
        // compiled — plain sqlite3_open left that to the library default,
        // and concurrent prepare/step corrupted the heap (observed live:
        // parser segfault dereferencing the SQL text as a pointer the
        // moment a turn start overlapped a session-list broadcast).
        if (c.sqlite3_open_v2(
            p,
            &db,
            c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX,
            null,
        ) != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpen;
        }
        // A coordinated reboot deliberately lets the replacement process
        // start as soon as the old daemon has quiesced and acknowledged. The
        // old connection may still be in its final close path, so wait out
        // that short handoff instead of turning SQLITE_BUSY into a failed
        // daemon start. This also protects rapid CLI readers/writers from
        // transient WAL/schema locks.
        if (c.sqlite3_busy_timeout(db.?, 5000) != c.SQLITE_OK) {
            _ = c.sqlite3_close(db.?);
            return error.SqliteOpen;
        }
        const store = Store{ .db = db.?, .gpa = gpa };
        try store.execAll(schema_sql);
        try store.migrate();
        return store;
    }

    /// Bring pre-existing DBs up to the current schema. New DBs are created
    /// current by schema_sql (which stamps the version via INSERT OR IGNORE).
    fn migrate(self: Store) Error!void {
        const ver = try self.kvGetInt("schema_version");
        if (ver < 2) {
            // v1 → v2: blob GC columns + retroactive auto_vacuum.
            // ALTERs must not re-run, so they are guarded by the version check.
            // VACUUM rewrites the DB so the INCREMENTAL auto_vacuum PRAGMA
            // (set by schema_sql above) actually takes effect on old files.
            try self.execAll(
                \\ALTER TABLE blobs ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
                \\ALTER TABLE blobs ADD COLUMN tombstone INTEGER NOT NULL DEFAULT 0;
                \\UPDATE kv SET value='2' WHERE key='schema_version';
                \\VACUUM;
            );
        }
        if (ver < 3) {
            // v2 → v3: reasoning effort is durable session state. `auto`
            // preserves the provider/model default for every existing row.
            try self.execAll(
                \\ALTER TABLE sessions ADD COLUMN effort TEXT NOT NULL DEFAULT 'auto';
                \\UPDATE kv SET value='3' WHERE key='schema_version';
            );
        }
        if (ver < 4) {
            // v3 → v4: durable one-level session hierarchy and child budget.
            // Existing sessions become roots through the column defaults.
            try self.execAll(
                \\ALTER TABLE sessions ADD COLUMN parent_sid INTEGER REFERENCES sessions(id);
                \\ALTER TABLE sessions ADD COLUMN kind TEXT NOT NULL DEFAULT 'root';
                \\ALTER TABLE sessions ADD COLUMN parent_block_id INTEGER REFERENCES blocks(id);
                \\ALTER TABLE sessions ADD COLUMN max_rounds INTEGER;
                \\UPDATE kv SET value='4' WHERE key='schema_version';
            );
        }
        if (ver < 5) {
            // v4 → v5: archived sessions remain fully durable but disappear
            // from default navigation and continuation queries.
            try self.execAll(
                \\ALTER TABLE sessions ADD COLUMN archived_at INTEGER;
                \\UPDATE kv SET value='5' WHERE key='schema_version';
            );
        }
    }

    fn kvGetInt(self: Store, key: []const u8) Error!i64 {
        const stmt = try self.prepare("SELECT value FROM kv WHERE key=?");
        defer finalize(stmt);
        bindText(stmt, 1, key);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return 0;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        const ptr = c.sqlite3_column_text(stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        return std.fmt.parseInt(i64, ptr[0..len], 10) catch 0;
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

    pub fn createSession(self: Store, id: u64, created_at: i64, cwd: []const u8, model: []const u8, effort: Effort) Error!void {
        const stmt = try self.prepare(
            "INSERT INTO sessions(id, created_at, cwd, model, effort) VALUES(?,?,?,?,?)",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        bindInt(stmt, 2, created_at);
        bindText(stmt, 3, cwd);
        bindText(stmt, 4, model);
        bindText(stmt, 5, @tagName(effort));
        try stepDone(stmt);
    }

    pub fn createChildSession(
        self: Store,
        id: u64,
        created_at: i64,
        parent_sid: u64,
        parent_block_id: u64,
        title: []const u8,
        cwd: []const u8,
        model: []const u8,
        effort: Effort,
        max_rounds: u32,
    ) Error!void {
        const stmt = try self.prepare(
            "INSERT INTO sessions(id, title, created_at, cwd, model, effort, parent_sid, kind, parent_block_id, max_rounds) VALUES(?,?,?,?,?,?,?,?,?,?)",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        bindText(stmt, 2, title);
        bindInt(stmt, 3, created_at);
        bindText(stmt, 4, cwd);
        bindText(stmt, 5, model);
        bindText(stmt, 6, @tagName(effort));
        bindInt(stmt, 7, @bitCast(parent_sid));
        bindText(stmt, 8, "task_child");
        bindInt(stmt, 9, @bitCast(parent_block_id));
        bindInt(stmt, 10, @intCast(max_rounds));
        try stepDone(stmt);
    }

    pub fn setSessionStatus(self: Store, id: u64, status: []const u8) Error!void {
        const stmt = try self.prepare("UPDATE sessions SET status=? WHERE id=?");
        defer finalize(stmt);
        bindText(stmt, 1, status);
        bindInt(stmt, 2, @bitCast(id));
        try stepDone(stmt);
    }

    /// Archive or restore a session and every descendant as one visible
    /// hierarchy. Blocks and blobs remain untouched.
    pub fn setSessionTreeArchived(self: Store, id: u64, archived_at: ?i64) Error!void {
        const stmt = try self.prepare(
            \\WITH RECURSIVE session_tree(id) AS (
            \\  SELECT id FROM sessions WHERE id=?
            \\  UNION ALL
            \\  SELECT s.id FROM sessions s JOIN session_tree t ON s.parent_sid=t.id
            \\)
            \\UPDATE sessions SET archived_at=? WHERE id IN (SELECT id FROM session_tree)
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        if (archived_at) |ts|
            bindInt(stmt, 2, ts)
        else
            bindNull(stmt, 2);
        try stepDone(stmt);
    }

    /// A process restart cannot resume an in-flight provider stream. Preserve
    /// the durable hierarchy but report those sessions as interrupted.
    pub fn recoverInterruptedSessions(self: Store) Error!void {
        try self.execAll("UPDATE sessions SET status='err' WHERE status IN ('running','awaiting_approval');");
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

    pub fn setSessionModel(self: Store, id: u64, model: []const u8) Error!void {
        const stmt = try self.prepare("UPDATE sessions SET model=? WHERE id=?");
        defer finalize(stmt);
        bindText(stmt, 1, model);
        bindInt(stmt, 2, @bitCast(id));
        try stepDone(stmt);
    }

    pub fn setSessionEffort(self: Store, id: u64, effort: Effort) Error!void {
        const stmt = try self.prepare("UPDATE sessions SET effort=? WHERE id=?");
        defer finalize(stmt);
        bindText(stmt, 1, @tagName(effort));
        bindInt(stmt, 2, @bitCast(id));
        try stepDone(stmt);
    }

    pub const SessionListing = struct {
        id: u64,
        parent_sid: ?u64,
        kind: proto.SessionKind,
        parent_block_id: ?u64,
        max_rounds: u32,
        title: []const u8,
        cwd: []const u8,
        model: []const u8,
        effort: Effort,
        status: []const u8,
        created_at: i64,
        archived: bool,

        pub fn deinit(self: SessionListing, gpa: std.mem.Allocator) void {
            gpa.free(self.title);
            gpa.free(self.cwd);
            gpa.free(self.model);
            gpa.free(self.status);
        }
    };

    /// Sessions, newest hierarchy first. Archived rows are omitted unless
    /// requested. Caller deinits each entry + frees the returned slice.
    pub fn listSessions(self: Store, include_archived: bool) Error![]SessionListing {
        const stmt = try self.prepare(
            \\SELECT s.id, s.parent_sid, s.kind, s.parent_block_id, COALESCE(s.max_rounds, 0),
            \\       s.title, s.cwd, s.model, s.effort, s.status, s.created_at,
            \\       s.archived_at IS NOT NULL
            \\FROM sessions s
            \\WHERE (? OR s.archived_at IS NULL)
            \\ORDER BY COALESCE((SELECT p.created_at FROM sessions p WHERE p.id=s.parent_sid), s.created_at) DESC,
            \\         COALESCE(s.parent_sid, s.id) DESC,
            \\         CASE WHEN s.parent_sid IS NULL THEN 0 ELSE 1 END,
            \\         s.created_at ASC, s.id ASC
        );
        defer finalize(stmt);
        bindInt(stmt, 1, if (include_archived) 1 else 0);
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
                .parent_sid = columnOptionalU64(stmt, 1),
                .kind = std.meta.stringToEnum(proto.SessionKind, columnText(stmt, 2)) orelse .root,
                .parent_block_id = columnOptionalU64(stmt, 3),
                .max_rounds = @intCast(c.sqlite3_column_int64(stmt, 4)),
                .title = try self.dupeCol(stmt, 5),
                .cwd = try self.dupeCol(stmt, 6),
                .model = try self.dupeCol(stmt, 7),
                .effort = Effort.parse(columnText(stmt, 8)) orelse .auto,
                .status = try self.dupeCol(stmt, 9),
                .created_at = c.sqlite3_column_int64(stmt, 10),
                .archived = c.sqlite3_column_int64(stmt, 11) != 0,
            });
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Most recently created session id, if any (for `marlin run --continue`).
    pub fn lastSession(self: Store) Error!?u64 {
        const stmt = try self.prepare(
            "SELECT id FROM sessions WHERE parent_sid IS NULL AND archived_at IS NULL ORDER BY created_at DESC, id DESC LIMIT 1",
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
            "SELECT parent_sid, kind, parent_block_id, COALESCE(max_rounds, 0), title, cwd, model, effort, status, tokens_in, tokens_out, archived_at IS NOT NULL FROM sessions WHERE id=?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.NotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        return .{
            .id = id,
            .parent_sid = columnOptionalU64(stmt, 0),
            .kind = std.meta.stringToEnum(proto.SessionKind, columnText(stmt, 1)) orelse .root,
            .parent_block_id = columnOptionalU64(stmt, 2),
            .max_rounds = @intCast(c.sqlite3_column_int64(stmt, 3)),
            .title = try self.dupeCol(stmt, 4),
            .cwd = try self.dupeCol(stmt, 5),
            .model = try self.dupeCol(stmt, 6),
            .effort = Effort.parse(columnText(stmt, 7)) orelse .auto,
            .status = try self.dupeCol(stmt, 8),
            .tokens_in = @intCast(c.sqlite3_column_int64(stmt, 9)),
            .tokens_out = @intCast(c.sqlite3_column_int64(stmt, 10)),
            .archived = c.sqlite3_column_int64(stmt, 11) != 0,
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
    /// `now_ms` stamps created_at on first insert (dedup keeps the original).
    pub fn putBlob(self: Store, bytes: []const u8, now_ms: i64) Error![]const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const hex = std.fmt.allocPrint(self.gpa, "{x}", .{&digest}) catch
            return error.OutOfMemory;
        errdefer self.gpa.free(hex);

        const stmt = try self.prepare("INSERT OR IGNORE INTO blobs(hash, bytes, created_at) VALUES(?,?,?)");
        defer finalize(stmt);
        bindText(stmt, 1, hex);
        _ = c.sqlite3_bind_blob(stmt, 2, bytes.ptr, @intCast(bytes.len), static_destructor);
        bindInt(stmt, 3, now_ms);
        try stepDone(stmt);
        return hex;
    }

    /// Record that `block_id` references blob `hash` (for GC refcounting).
    pub fn addBlobRef(self: Store, hash: []const u8, block_id: u64) Error!void {
        const stmt = try self.prepare("INSERT OR IGNORE INTO blob_refs(hash, block_id) VALUES(?,?)");
        defer finalize(stmt);
        bindText(stmt, 1, hash);
        bindInt(stmt, 2, @bitCast(block_id));
        try stepDone(stmt);
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

fn columnText(stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return ptr[0..len];
}

fn columnOptionalU64(stmt: *c.sqlite3_stmt, col: c_int) ?u64 {
    if (c.sqlite3_column_type(stmt, col) == c.SQLITE_NULL) return null;
    return @bitCast(c.sqlite3_column_int64(stmt, col));
}

fn bindInt(stmt: *c.sqlite3_stmt, idx: c_int, v: i64) void {
    _ = c.sqlite3_bind_int64(stmt, idx, v);
}

fn bindNull(stmt: *c.sqlite3_stmt, idx: c_int) void {
    _ = c.sqlite3_bind_null(stmt, idx);
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
    try store.createSession(1, 0, "/", "m", .auto);
    const mk = struct {
        fn blk(seq: u64) block.Block {
            return .{ .id = seq, .session_id = 1, .turn_id = 1, .seq = seq, .ts = 0, .body = .{ .user_msg = .{ .text = "x" } } };
        }
    };
    try store.appendBlock(mk.blk(1));
    try std.testing.expectError(error.SqliteStep, store.appendBlock(mk.blk(1)));
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

test "schema is v5 with session archiving and auto_vacuum incremental" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try std.testing.expectEqual(@as(i64, 5), try store.kvGetInt("schema_version"));
    // migrate() must be a no-op on a current DB (idempotent open).
    try store.migrate();
    try std.testing.expectEqual(@as(i64, 5), try store.kvGetInt("schema_version"));
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
