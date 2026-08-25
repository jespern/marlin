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
    \\INSERT OR IGNORE INTO kv(key,value) VALUES('schema_version','6');
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

pub const GcReport = struct {
    orphan_blobs: u64,
    expired_blobs: u64,
    bytes_reclaimed: u64,
};

pub const Store = struct {
    db: *c.sqlite3,
    gpa: std.mem.Allocator,
    statements: *StatementCache,

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
        const statements = gpa.create(StatementCache) catch {
            _ = c.sqlite3_close(db.?);
            return error.OutOfMemory;
        };
        statements.* = .{};
        var store = Store{ .db = db.?, .gpa = gpa, .statements = statements };
        errdefer store.close();
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
        if (ver < 6) {
            // UNIQUE(session_id, seq) already creates the exact covering
            // index used by block scans. The explicit duplicate doubled
            // every block insert's index work and disk footprint.
            try self.execAll(
                \\DROP INDEX IF EXISTS blocks_by_session;
                \\UPDATE kv SET value='6' WHERE key='schema_version';
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
        self.statements.deinit();
        self.gpa.destroy(self.statements);
        _ = c.sqlite3_close(self.db);
        self.* = undefined;
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
        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);
        const stmt = try self.cachedStatement(
            &self.statements.set_session_status,
            "UPDATE sessions SET status=? WHERE id=?",
        );
        defer resetStatement(stmt);
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
        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);
        const stmt = try self.cachedStatement(
            &self.statements.update_session_usage,
            "UPDATE sessions SET tokens_in=?, tokens_out=? WHERE id=?",
        );
        defer resetStatement(stmt);
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

        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);
        const stmt = try self.cachedStatement(
            &self.statements.append_block,
            "INSERT INTO blocks(id, session_id, turn_id, seq, kind, ts, body_json) VALUES(?,?,?,?,?,?,?)",
        );
        defer resetStatement(stmt);
        bindInt(stmt, 1, @bitCast(blk.id));
        bindInt(stmt, 2, @bitCast(blk.session_id));
        bindInt(stmt, 3, @bitCast(blk.turn_id));
        bindInt(stmt, 4, @bitCast(blk.seq));
        bindText(stmt, 5, @tagName(blk.kind()));
        bindInt(stmt, 6, blk.ts);
        bindText(stmt, 7, body_json);
        try stepDone(stmt);
    }

    /// Persist one oversized tool result as a single crash-consistent unit.
    /// The database mutex is recursive in FULLMUTEX mode; holding it across
    /// BEGIN..COMMIT prevents another daemon thread from interleaving work on
    /// this shared connection inside our transaction.
    pub fn appendBlockWithBlob(
        self: Store,
        blk: block.Block,
        hash: []const u8,
        bytes: []const u8,
    ) Error!void {
        const body_json = std.json.Stringify.valueAlloc(self.gpa, blk.body, .{}) catch
            return error.OutOfMemory;
        defer self.gpa.free(body_json);

        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);
        try self.execAll("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.execAll("ROLLBACK;") catch {};

        {
            const stmt = try self.prepare(
                \\INSERT INTO blobs(hash, bytes, created_at) VALUES(?,?,?)
                \\ON CONFLICT(hash) DO UPDATE SET
                \\  bytes=excluded.bytes, created_at=excluded.created_at, tombstone=0
                \\WHERE blobs.tombstone=1
            );
            defer finalize(stmt);
            bindText(stmt, 1, hash);
            _ = c.sqlite3_bind_blob(stmt, 2, bytes.ptr, @intCast(bytes.len), static_destructor);
            bindInt(stmt, 3, blk.ts);
            try stepDone(stmt);
        }
        {
            const stmt = try self.cachedStatement(
                &self.statements.append_block,
                "INSERT INTO blocks(id, session_id, turn_id, seq, kind, ts, body_json) VALUES(?,?,?,?,?,?,?)",
            );
            defer resetStatement(stmt);
            bindInt(stmt, 1, @bitCast(blk.id));
            bindInt(stmt, 2, @bitCast(blk.session_id));
            bindInt(stmt, 3, @bitCast(blk.turn_id));
            bindInt(stmt, 4, @bitCast(blk.seq));
            bindText(stmt, 5, @tagName(blk.kind()));
            bindInt(stmt, 6, blk.ts);
            bindText(stmt, 7, body_json);
            try stepDone(stmt);
        }
        {
            const stmt = try self.prepare("INSERT OR IGNORE INTO blob_refs(hash, block_id) VALUES(?,?)");
            defer finalize(stmt);
            bindText(stmt, 1, hash);
            bindInt(stmt, 2, @bitCast(blk.id));
            try stepDone(stmt);
        }
        try self.execAll("COMMIT;");
        committed = true;
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

    /// Parse a block range directly into one caller-owned arena. Turn loops
    /// use this to load an append-only history once instead of constructing
    /// one heap arena per row on every provider round.
    pub fn loadBlocksInto(
        self: Store,
        arena: std.mem.Allocator,
        out: *std.ArrayList(block.Block),
        session_id: u64,
        from_seq: u64,
        limit: u32,
    ) Error!void {
        const stmt = try self.prepare(
            "SELECT id, turn_id, seq, ts, body_json FROM blocks WHERE session_id=? AND seq>=? ORDER BY seq ASC LIMIT ?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(from_seq));
        bindInt(stmt, 3, @intCast(limit));

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            const body_ptr = c.sqlite3_column_text(stmt, 4);
            const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            const body_json = try arena.dupe(u8, body_ptr[0..body_len]);
            const body = std.json.parseFromSliceLeaky(block.Body, arena, body_json, .{
                .ignore_unknown_fields = true,
            }) catch return error.SqliteStep;
            try out.append(arena, .{
                .id = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                .session_id = session_id,
                .turn_id = @bitCast(c.sqlite3_column_int64(stmt, 1)),
                .seq = @bitCast(c.sqlite3_column_int64(stmt, 2)),
                .ts = c.sqlite3_column_int64(stmt, 3),
                .body = body,
            });
        }
    }

    /// Load exactly the context-relevant working set: every compaction record
    /// (needed to resolve nested summaries) plus blocks after the greatest
    /// compacted seq. The durable log remains untouched and full replay still
    /// uses loadBlocksInto; turn threads avoid parsing history they will skip.
    pub fn loadContextBlocksInto(
        self: Store,
        arena: std.mem.Allocator,
        out: *std.ArrayList(block.Block),
        session_id: u64,
        limit: u32,
    ) Error!void {
        const stmt = try self.prepare(
            \\WITH frontier(value) AS (
            \\  SELECT COALESCE(MAX(CAST(json_extract(body_json, '$.compaction.covers_to_seq') AS INTEGER)), 0)
            \\  FROM blocks WHERE session_id=? AND kind='compaction'
            \\)
            \\SELECT id, turn_id, seq, ts, body_json
            \\FROM blocks, frontier
            \\WHERE session_id=? AND (kind='compaction' OR seq>frontier.value)
            \\ORDER BY seq ASC LIMIT ?
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(session_id));
        bindInt(stmt, 3, @intCast(limit));

        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            const body_ptr = c.sqlite3_column_text(stmt, 4);
            const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            const body_json = try arena.dupe(u8, body_ptr[0..body_len]);
            const body = std.json.parseFromSliceLeaky(block.Body, arena, body_json, .{
                .ignore_unknown_fields = true,
            }) catch return error.SqliteStep;
            try out.append(arena, .{
                .id = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                .session_id = session_id,
                .turn_id = @bitCast(c.sqlite3_column_int64(stmt, 1)),
                .seq = @bitCast(c.sqlite3_column_int64(stmt, 2)),
                .ts = c.sqlite3_column_int64(stmt, 3),
                .body = body,
            });
        }
    }

    /// Load the newest block window while returning it in transcript order.
    pub fn loadTailInto(
        self: Store,
        arena: std.mem.Allocator,
        out: *std.ArrayList(block.Block),
        session_id: u64,
        limit: u32,
    ) Error!void {
        const stmt = try self.prepare(
            \\SELECT id, turn_id, seq, ts, body_json FROM (
            \\  SELECT id, turn_id, seq, ts, body_json
            \\  FROM blocks WHERE session_id=? ORDER BY seq DESC LIMIT ?
            \\) ORDER BY seq ASC
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @intCast(limit));
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            const body_ptr = c.sqlite3_column_text(stmt, 4);
            const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            const body_json = try arena.dupe(u8, body_ptr[0..body_len]);
            const body = std.json.parseFromSliceLeaky(block.Body, arena, body_json, .{
                .ignore_unknown_fields = true,
            }) catch return error.SqliteStep;
            try out.append(arena, .{
                .id = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                .session_id = session_id,
                .turn_id = @bitCast(c.sqlite3_column_int64(stmt, 1)),
                .seq = @bitCast(c.sqlite3_column_int64(stmt, 2)),
                .ts = c.sqlite3_column_int64(stmt, 3),
                .body = body,
            });
        }
    }

    /// Load the newest block window strictly before `before_seq`, returning
    /// it in transcript order. This is the backwards-pagination counterpart
    /// to loadTailInto; every request has bounded DB and protocol work.
    pub fn loadTailBeforeInto(
        self: Store,
        arena: std.mem.Allocator,
        out: *std.ArrayList(block.Block),
        session_id: u64,
        before_seq: u64,
        limit: u32,
    ) Error!void {
        const stmt = try self.prepare(
            \\SELECT id, turn_id, seq, ts, body_json FROM (
            \\  SELECT id, turn_id, seq, ts, body_json
            \\  FROM blocks WHERE session_id=? AND seq<? ORDER BY seq DESC LIMIT ?
            \\) ORDER BY seq ASC
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(before_seq));
        bindInt(stmt, 3, @intCast(limit));
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            const body_ptr = c.sqlite3_column_text(stmt, 4);
            const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            const body_json = try arena.dupe(u8, body_ptr[0..body_len]);
            const body = std.json.parseFromSliceLeaky(block.Body, arena, body_json, .{
                .ignore_unknown_fields = true,
            }) catch return error.SqliteStep;
            try out.append(arena, .{
                .id = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                .session_id = session_id,
                .turn_id = @bitCast(c.sqlite3_column_int64(stmt, 1)),
                .seq = @bitCast(c.sqlite3_column_int64(stmt, 2)),
                .ts = c.sqlite3_column_int64(stmt, 3),
                .body = body,
            });
        }
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
        const hex = try blobHashAlloc(self.gpa, bytes);
        errdefer self.gpa.free(hex);

        const stmt = try self.prepare(
            \\INSERT INTO blobs(hash, bytes, created_at) VALUES(?,?,?)
            \\ON CONFLICT(hash) DO UPDATE SET
            \\  bytes=excluded.bytes, created_at=excluded.created_at, tombstone=0
            \\WHERE blobs.tombstone=1
        );
        defer finalize(stmt);
        bindText(stmt, 1, hex);
        _ = c.sqlite3_bind_blob(stmt, 2, bytes.ptr, @intCast(bytes.len), static_destructor);
        bindInt(stmt, 3, now_ms);
        try stepDone(stmt);
        return hex;
    }

    pub fn blobHashAlloc(gpa: std.mem.Allocator, bytes: []const u8) Error![]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        return std.fmt.allocPrint(gpa, "{x}", .{&digest}) catch
            return error.OutOfMemory;
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
        const stmt = try self.prepare("SELECT bytes, tombstone FROM blobs WHERE hash=?");
        defer finalize(stmt);
        bindText(stmt, 1, hash);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.NotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        if (c.sqlite3_column_int(stmt, 1) != 0) return error.NotFound;
        const ptr = c.sqlite3_column_blob(stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (len == 0) return try self.gpa.dupe(u8, "");
        const bytes: [*]const u8 = @ptrCast(ptr.?);
        return try self.gpa.dupe(u8, bytes[0..len]);
    }

    /// Reclaim unreferenced blobs and, when explicitly requested, demote old
    /// full bodies whose every durable session is idle. The block/ref rows
    /// remain untouched, so scrollback and causal structure stay complete.
    pub fn gc(self: Store, expire_before_ms: ?i64) Error!GcReport {
        try self.execAll("BEGIN IMMEDIATE;");
        errdefer self.execAll("ROLLBACK;") catch {};

        const orphan = try self.blobStats(
            "SELECT count(*), COALESCE(sum(length(bytes)),0) FROM blobs " ++
                "WHERE NOT EXISTS (SELECT 1 FROM blob_refs r WHERE r.hash=blobs.hash)",
            null,
        );
        try self.execAll(
            "DELETE FROM blobs WHERE NOT EXISTS " ++
                "(SELECT 1 FROM blob_refs r WHERE r.hash=blobs.hash);",
        );

        var expired = BlobStats{};
        if (expire_before_ms) |cutoff| {
            const eligible =
                "tombstone=0 AND created_at>0 AND created_at<?1 " ++
                "AND EXISTS (SELECT 1 FROM blob_refs r WHERE r.hash=blobs.hash) " ++
                "AND NOT EXISTS (SELECT 1 FROM blob_refs r " ++
                "JOIN blocks b ON b.id=r.block_id " ++
                "JOIN sessions s ON s.id=b.session_id " ++
                "WHERE r.hash=blobs.hash AND " ++
                "(b.ts>=?1 OR s.status IN ('running','awaiting_approval')))";
            expired = try self.blobStats(
                "SELECT count(*), COALESCE(sum(length(bytes)),0) FROM blobs WHERE " ++ eligible,
                cutoff,
            );
            const stmt = try self.prepare(
                "UPDATE blobs SET bytes=X'', tombstone=1 WHERE " ++ eligible,
            );
            defer finalize(stmt);
            bindInt(stmt, 1, cutoff);
            try stepDone(stmt);
        }

        try self.execAll("COMMIT;");
        // These maintenance operations are deliberately outside the write
        // transaction so normal daemon work is not held behind them.
        try self.execAll("PRAGMA incremental_vacuum;");
        try self.execAll("PRAGMA wal_checkpoint(PASSIVE);");
        return .{
            .orphan_blobs = orphan.count,
            .expired_blobs = expired.count,
            .bytes_reclaimed = orphan.bytes +| expired.bytes,
        };
    }

    // ----------------------------------------------------------- helpers --

    fn prepare(self: Store, comptime sql: [:0]const u8) Error!*c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != c.SQLITE_OK)
            return error.SqlitePrepare;
        return stmt.?;
    }

    /// Caller holds sqlite3_db_mutex: cached statements are connection-wide
    /// and must never have their bindings interleaved by another turn thread.
    fn cachedStatement(
        self: Store,
        slot: *?*c.sqlite3_stmt,
        comptime sql: [:0]const u8,
    ) Error!*c.sqlite3_stmt {
        if (slot.* == null) slot.* = try self.prepare(sql);
        return slot.*.?;
    }

    fn dupeCol(self: Store, stmt: *c.sqlite3_stmt, col: c_int) Error![]const u8 {
        const ptr = c.sqlite3_column_text(stmt, col);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
        return self.gpa.dupe(u8, ptr[0..len]);
    }

    const BlobStats = struct { count: u64 = 0, bytes: u64 = 0 };

    fn blobStats(self: Store, comptime sql: [:0]const u8, cutoff: ?i64) Error!BlobStats {
        const stmt = try self.prepare(sql);
        defer finalize(stmt);
        if (cutoff) |value| bindInt(stmt, 1, value);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteStep;
        return .{
            .count = @intCast(c.sqlite3_column_int64(stmt, 0)),
            .bytes = @intCast(c.sqlite3_column_int64(stmt, 1)),
        };
    }
};

const StatementCache = struct {
    append_block: ?*c.sqlite3_stmt = null,
    set_session_status: ?*c.sqlite3_stmt = null,
    update_session_usage: ?*c.sqlite3_stmt = null,

    fn deinit(self: *StatementCache) void {
        inline for (.{ self.append_block, self.set_session_status, self.update_session_usage }) |stmt|
            if (stmt) |value| finalize(value);
        self.* = undefined;
    }
};

fn finalize(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_finalize(stmt);
}

fn resetStatement(stmt: *c.sqlite3_stmt) void {
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);
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

test "schema is v6 without the duplicate block index" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try std.testing.expectEqual(@as(i64, 6), try store.kvGetInt("schema_version"));
    // migrate() must be a no-op on a current DB (idempotent open).
    try store.migrate();
    try std.testing.expectEqual(@as(i64, 6), try store.kvGetInt("schema_version"));
    const stmt = try store.prepare("SELECT count(*) FROM sqlite_master WHERE type='index' AND name='blocks_by_session'");
    defer finalize(stmt);
    try std.testing.expectEqual(@as(c_int, c.SQLITE_ROW), c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, 0), c.sqlite3_column_int64(stmt, 0));
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
