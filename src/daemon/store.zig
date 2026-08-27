//! The store: SQLite. THE ONLY FILE THAT KNOWS SQL.
//!
//! Schema (docs/ARCHITECTURE.md §2). WAL mode for crash safety. Blocks are
//! INSERT-only; the sessions row is the only thing UPDATEd. Blob writes are
//! idempotent (content-hash PK). Searchable block text is projected into a
//! compact side table and, when supported by SQLite, an FTS5 index.
//!
//! DB path: ~/.local/state/marlin/marlin.db (respects XDG_STATE_HOME).

const std = @import("std");
const block = @import("../core/block.zig");
const Effort = @import("../core/effort.zig").Effort;
const proto = @import("../core/proto.zig");
const telemetry_ids = @import("../core/telemetry.zig");

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
    \\  archived_at INTEGER,
    \\  plan_mode INTEGER NOT NULL DEFAULT 0,
    \\  codex_thread_id TEXT
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
    \\CREATE TABLE IF NOT EXISTS search_docs(
    \\  block_id INTEGER PRIMARY KEY REFERENCES blocks(id),
    \\  session_id INTEGER NOT NULL,
    \\  seq INTEGER NOT NULL,
    \\  kind TEXT NOT NULL,
    \\  ts INTEGER NOT NULL,
    \\  text TEXT NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS search_docs_by_session ON search_docs(session_id, seq);
    \\CREATE TABLE IF NOT EXISTS telemetry_turns(
    \\  session_id INTEGER NOT NULL REFERENCES sessions(id),
    \\  turn_id INTEGER NOT NULL,
    \\  model TEXT NOT NULL,
    \\  session_kind TEXT NOT NULL,
    \\  started_at_ms INTEGER NOT NULL,
    \\  ended_at_ms INTEGER,
    \\  outcome TEXT NOT NULL DEFAULT 'running',
    \\  error_text TEXT NOT NULL DEFAULT '',
    \\  rounds INTEGER NOT NULL DEFAULT 0,
    \\  tool_calls INTEGER NOT NULL DEFAULT 0,
    \\  tokens_in INTEGER NOT NULL DEFAULT 0,
    \\  tokens_out INTEGER NOT NULL DEFAULT 0,
    \\  exported_at_ms INTEGER,
    \\  export_attempts INTEGER NOT NULL DEFAULT 0,
    \\  export_after_ms INTEGER NOT NULL DEFAULT 0,
    \\  export_error TEXT NOT NULL DEFAULT '',
    \\  PRIMARY KEY(session_id, turn_id)
    \\) WITHOUT ROWID;
    \\CREATE INDEX IF NOT EXISTS telemetry_turns_export ON telemetry_turns(exported_at_ms, export_after_ms, ended_at_ms);
    \\CREATE TABLE IF NOT EXISTS telemetry_rounds(
    \\  session_id INTEGER NOT NULL,
    \\  turn_id INTEGER NOT NULL,
    \\  round_index INTEGER NOT NULL,
    \\  span_id TEXT NOT NULL,
    \\  started_at_ms INTEGER NOT NULL,
    \\  first_byte_at_ms INTEGER NOT NULL DEFAULT 0,
    \\  first_visible_at_ms INTEGER NOT NULL DEFAULT 0,
    \\  ended_at_ms INTEGER NOT NULL,
    \\  status TEXT NOT NULL,
    \\  http_status INTEGER NOT NULL DEFAULT 0,
    \\  response_bytes INTEGER NOT NULL DEFAULT 0,
    \\  provider TEXT NOT NULL DEFAULT '',
    \\  generation_id TEXT NOT NULL DEFAULT '',
    \\  tokens_in INTEGER NOT NULL DEFAULT 0,
    \\  tokens_out INTEGER NOT NULL DEFAULT 0,
    \\  cached_tokens INTEGER NOT NULL DEFAULT 0,
    \\  cache_write_tokens INTEGER NOT NULL DEFAULT 0,
    \\  reasoning_tokens INTEGER NOT NULL DEFAULT 0,
    \\  PRIMARY KEY(session_id, turn_id, round_index),
    \\  FOREIGN KEY(session_id, turn_id) REFERENCES telemetry_turns(session_id, turn_id)
    \\) WITHOUT ROWID;
    \\CREATE TABLE IF NOT EXISTS telemetry_tools(
    \\  session_id INTEGER NOT NULL,
    \\  turn_id INTEGER NOT NULL,
    \\  round_index INTEGER NOT NULL,
    \\  call_id TEXT NOT NULL,
    \\  span_id TEXT NOT NULL,
    \\  name TEXT NOT NULL,
    \\  started_at_ms INTEGER NOT NULL,
    \\  ended_at_ms INTEGER NOT NULL,
    \\  status TEXT NOT NULL,
    \\  PRIMARY KEY(session_id, turn_id, call_id),
    \\  FOREIGN KEY(session_id, turn_id) REFERENCES telemetry_turns(session_id, turn_id)
    \\) WITHOUT ROWID;
    \\INSERT OR IGNORE INTO kv(key,value) VALUES('schema_version','10');
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
    plan_mode: bool,
};

pub const GcReport = struct {
    orphan_blobs: u64,
    expired_blobs: u64,
    bytes_reclaimed: u64,
};

pub const TelemetryRound = struct {
    round: u32,
    span_id: []const u8,
    started_at_ms: i64,
    first_byte_at_ms: i64,
    first_visible_at_ms: i64,
    ended_at_ms: i64,
    status: []const u8,
    http_status: u16,
    response_bytes: u64,
    provider: []const u8,
    generation_id: []const u8,
    tokens_in: u64,
    tokens_out: u64,
    cached_tokens: u64,
    cache_write_tokens: u64,
    reasoning_tokens: u64,
};

pub const TelemetryTool = struct {
    round: u32,
    call_id: []const u8,
    span_id: []const u8,
    name: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
    status: []const u8,
};

pub const TelemetryTrace = struct {
    session_id: u64,
    turn_id: u64,
    model: []const u8,
    session_kind: []const u8,
    started_at_ms: i64,
    ended_at_ms: i64,
    outcome: []const u8,
    error_text: []const u8,
    rounds_count: u32,
    tool_calls: u32,
    tokens_in: u64,
    tokens_out: u64,
    rounds: []const TelemetryRound,
    tools: []const TelemetryTool,
};

pub const Store = struct {
    db: *c.sqlite3,
    gpa: std.mem.Allocator,
    statements: *StatementCache,
    fts5: bool,

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
        var store = Store{ .db = db.?, .gpa = gpa, .statements = statements, .fts5 = false };
        errdefer store.close();
        try store.execAll(schema_sql);
        try store.migrate();
        try store.initializeSearch();
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
        if (ver < 7) {
            // The ordinary projection powers a portable slow-scan fallback
            // when the platform SQLite library was compiled without FTS5.
            try self.execAll(
                \\CREATE TABLE IF NOT EXISTS search_docs(
                \\  block_id INTEGER PRIMARY KEY REFERENCES blocks(id),
                \\  session_id INTEGER NOT NULL,
                \\  seq INTEGER NOT NULL,
                \\  kind TEXT NOT NULL,
                \\  ts INTEGER NOT NULL,
                \\  text TEXT NOT NULL
                \\);
                \\CREATE INDEX IF NOT EXISTS search_docs_by_session ON search_docs(session_id, seq);
                \\UPDATE kv SET value='7' WHERE key='schema_version';
            );
        }
        if (ver < 8) {
            // Plan mode is collaboration state, not a client preference. It
            // survives reconnects and daemon restarts with the session.
            try self.execAll(
                \\ALTER TABLE sessions ADD COLUMN plan_mode INTEGER NOT NULL DEFAULT 0;
                \\UPDATE kv SET value='8' WHERE key='schema_version';
            );
        }
        if (ver < 9) {
            // schema_sql creates the additive telemetry tables before this
            // migration runs. Advancing the marker makes the operation
            // idempotent for existing databases without rewriting blocks.
            try self.execAll("UPDATE kv SET value='9' WHERE key='schema_version';");
        }
        if (ver < 10) {
            // Codex app-server threads are durable independently of Marlin's
            // process. Persist the mapping so a guest turn can resume after
            // daemon or client restarts without replaying the transcript.
            try self.execAll(
                \\ALTER TABLE sessions ADD COLUMN codex_thread_id TEXT;
                \\UPDATE kv SET value='10' WHERE key='schema_version';
            );
        }
    }

    fn initializeSearch(self: *Store) Error!void {
        if (try self.kvGetInt("search_docs_version") < 1) {
            try self.backfillSearchDocs();
            try self.kvSetInt("search_docs_version", 1);
        }

        self.execAll(
            \\CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
            \\  text,
            \\  content='search_docs',
            \\  content_rowid='block_id',
            \\  tokenize='unicode61 remove_diacritics 2'
            \\);
        ) catch {
            // Some system SQLite builds omit FTS5. search_docs remains fully
            // maintained and search() falls back to a bounded LIKE scan.
            self.fts5 = false;
            return;
        };
        self.fts5 = true;
        if (try self.kvGetInt("search_fts_version") < 1) {
            try self.execAll("INSERT INTO search_fts(search_fts) VALUES('rebuild');");
            try self.kvSetInt("search_fts_version", 1);
        }
    }

    fn backfillSearchDocs(self: Store) Error!void {
        const select = try self.prepare(
            "SELECT id, session_id, turn_id, seq, ts, body_json FROM blocks ORDER BY id",
        );
        defer finalize(select);
        const insert = try self.prepare(
            "INSERT OR IGNORE INTO search_docs(block_id, session_id, seq, kind, ts, text) VALUES(?,?,?,?,?,?)",
        );
        defer finalize(insert);
        try self.execAll("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.execAll("ROLLBACK;") catch {};

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        while (true) {
            const rc = c.sqlite3_step(select);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            _ = arena_state.reset(.retain_capacity);
            const arena = arena_state.allocator();
            const body_json = columnText(select, 5);
            const body = std.json.parseFromSliceLeaky(block.Body, arena, body_json, .{
                .ignore_unknown_fields = true,
            }) catch continue;
            const blk = block.Block{
                .id = @bitCast(c.sqlite3_column_int64(select, 0)),
                .session_id = @bitCast(c.sqlite3_column_int64(select, 1)),
                .turn_id = @bitCast(c.sqlite3_column_int64(select, 2)),
                .seq = @bitCast(c.sqlite3_column_int64(select, 3)),
                .ts = c.sqlite3_column_int64(select, 4),
                .body = body,
            };
            const text_value = try searchTextAlloc(arena, blk);
            const text = text_value orelse continue;
            bindInt(insert, 1, @bitCast(blk.id));
            bindInt(insert, 2, @bitCast(blk.session_id));
            bindInt(insert, 3, @bitCast(blk.seq));
            bindText(insert, 4, @tagName(blk.kind()));
            bindInt(insert, 5, blk.ts);
            bindText(insert, 6, text);
            try stepDone(insert);
            resetStatement(insert);
        }
        try self.execAll("COMMIT;");
        committed = true;
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

    fn kvSetInt(self: Store, key: []const u8, value: i64) Error!void {
        var value_buf: [32]u8 = undefined;
        const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{value}) catch return error.OutOfMemory;
        const stmt = try self.prepare(
            "INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        );
        defer finalize(stmt);
        bindText(stmt, 1, key);
        bindText(stmt, 2, value_text);
        try stepDone(stmt);
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

    // ------------------------------------------------------- telemetry --

    pub fn telemetryBeginTurn(
        self: Store,
        session_id: u64,
        turn_id: u64,
        model: []const u8,
        session_kind: proto.SessionKind,
        started_at_ms: i64,
    ) Error!void {
        const stmt = try self.prepare(
            "INSERT OR IGNORE INTO telemetry_turns(session_id,turn_id,model,session_kind,started_at_ms) VALUES(?,?,?,?,?)",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        bindText(stmt, 3, model);
        bindText(stmt, 4, @tagName(session_kind));
        bindInt(stmt, 5, started_at_ms);
        try stepDone(stmt);
    }

    pub fn telemetryFinishTurn(
        self: Store,
        session_id: u64,
        turn_id: u64,
        ended_at_ms: i64,
        outcome: []const u8,
        error_text: []const u8,
        tokens_in: u64,
        tokens_out: u64,
    ) Error!void {
        const stmt = try self.prepare(
            \\UPDATE telemetry_turns SET ended_at_ms=?, outcome=?, error_text=?,
            \\ rounds=(SELECT count(*) FROM telemetry_rounds WHERE session_id=? AND turn_id=?),
            \\ tokens_in=CASE WHEN EXISTS(SELECT 1 FROM telemetry_rounds WHERE session_id=? AND turn_id=?)
            \\   THEN (SELECT COALESCE(sum(tokens_in),0) FROM telemetry_rounds WHERE session_id=? AND turn_id=?) ELSE ? END,
            \\ tokens_out=CASE WHEN EXISTS(SELECT 1 FROM telemetry_rounds WHERE session_id=? AND turn_id=?)
            \\   THEN (SELECT COALESCE(sum(tokens_out),0) FROM telemetry_rounds WHERE session_id=? AND turn_id=?) ELSE ? END,
            \\ tool_calls=(SELECT count(*) FROM telemetry_tools WHERE session_id=? AND turn_id=?)
            \\ WHERE session_id=? AND turn_id=?
        );
        defer finalize(stmt);
        bindInt(stmt, 1, ended_at_ms);
        bindText(stmt, 2, outcome);
        bindText(stmt, 3, error_text);
        bindInt(stmt, 4, @bitCast(session_id));
        bindInt(stmt, 5, @bitCast(turn_id));
        bindInt(stmt, 6, @bitCast(session_id));
        bindInt(stmt, 7, @bitCast(turn_id));
        bindInt(stmt, 8, @bitCast(session_id));
        bindInt(stmt, 9, @bitCast(turn_id));
        bindInt(stmt, 10, @intCast(tokens_in));
        bindInt(stmt, 11, @bitCast(session_id));
        bindInt(stmt, 12, @bitCast(turn_id));
        bindInt(stmt, 13, @bitCast(session_id));
        bindInt(stmt, 14, @bitCast(turn_id));
        bindInt(stmt, 15, @intCast(tokens_out));
        bindInt(stmt, 16, @bitCast(session_id));
        bindInt(stmt, 17, @bitCast(turn_id));
        bindInt(stmt, 18, @bitCast(session_id));
        bindInt(stmt, 19, @bitCast(turn_id));
        try stepDone(stmt);
    }

    pub fn telemetryRecordRound(
        self: Store,
        session_id: u64,
        turn_id: u64,
        row: TelemetryRound,
    ) Error!void {
        const stmt = try self.prepare(
            \\INSERT OR REPLACE INTO telemetry_rounds(
            \\ session_id,turn_id,round_index,span_id,started_at_ms,first_byte_at_ms,
            \\ first_visible_at_ms,ended_at_ms,status,http_status,response_bytes,provider,
            \\ generation_id,tokens_in,tokens_out,cached_tokens,cache_write_tokens,reasoning_tokens
            \\) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        bindInt(stmt, 3, row.round);
        bindText(stmt, 4, row.span_id);
        bindInt(stmt, 5, row.started_at_ms);
        bindInt(stmt, 6, row.first_byte_at_ms);
        bindInt(stmt, 7, row.first_visible_at_ms);
        bindInt(stmt, 8, row.ended_at_ms);
        bindText(stmt, 9, row.status);
        bindInt(stmt, 10, row.http_status);
        bindInt(stmt, 11, @intCast(row.response_bytes));
        bindText(stmt, 12, row.provider);
        bindText(stmt, 13, row.generation_id);
        bindInt(stmt, 14, @intCast(row.tokens_in));
        bindInt(stmt, 15, @intCast(row.tokens_out));
        bindInt(stmt, 16, @intCast(row.cached_tokens));
        bindInt(stmt, 17, @intCast(row.cache_write_tokens));
        bindInt(stmt, 18, @intCast(row.reasoning_tokens));
        try stepDone(stmt);
    }

    pub fn telemetryRecordTool(
        self: Store,
        session_id: u64,
        turn_id: u64,
        row: TelemetryTool,
    ) Error!void {
        const stmt = try self.prepare(
            \\INSERT OR REPLACE INTO telemetry_tools(
            \\ session_id,turn_id,round_index,call_id,span_id,name,started_at_ms,ended_at_ms,status
            \\) VALUES(?,?,?,?,?,?,?,?,?)
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        bindInt(stmt, 3, row.round);
        bindText(stmt, 4, row.call_id);
        bindText(stmt, 5, row.span_id);
        bindText(stmt, 6, row.name);
        bindInt(stmt, 7, row.started_at_ms);
        bindInt(stmt, 8, row.ended_at_ms);
        bindText(stmt, 9, row.status);
        try stepDone(stmt);
    }

    /// Mark unfinished telemetry honestly when daemon recovery marks the
    /// corresponding sessions failed.
    pub fn recoverInterruptedTelemetry(self: Store, now_ms: i64) Error!void {
        const stmt = try self.prepare(
            "UPDATE telemetry_turns SET ended_at_ms=?, outcome='abandoned', error_text='daemon stopped during turn' WHERE ended_at_ms IS NULL",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, now_ms);
        try stepDone(stmt);
    }

    pub fn diagnostics(
        self: Store,
        allocator: std.mem.Allocator,
        session_id: u64,
        turn_limit: u32,
        now_ms: i64,
        otlp_enabled: bool,
    ) Error!proto.Diagnostics {
        const limit = @max(@min(turn_limit, 500), 1);
        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);

        var result = proto.Diagnostics{ .sid = session_id, .sample_turns = 0, .successful_turns = 0, .failed_turns = 0, .interrupted_turns = 0, .abandoned_turns = 0, .checkpoint_turns = 0, .provider_requests = 0, .tool_calls = 0, .provider_p50_ms = 0, .provider_p95_ms = 0, .ttft_p50_ms = 0, .ttft_p95_ms = 0, .otlp_enabled = otlp_enabled };

        const counts = try self.prepare(
            \\SELECT count(*),
            \\ sum(CASE WHEN outcome='ok' THEN 1 ELSE 0 END),
            \\ sum(CASE WHEN outcome='error' THEN 1 ELSE 0 END),
            \\ sum(CASE WHEN outcome='interrupted' THEN 1 ELSE 0 END),
            \\ sum(CASE WHEN outcome='abandoned' THEN 1 ELSE 0 END),
            \\ sum(CASE WHEN outcome='checkpoint' THEN 1 ELSE 0 END),
            \\ COALESCE(sum(tool_calls),0)
            \\FROM (SELECT outcome,tool_calls FROM telemetry_turns WHERE session_id=? ORDER BY started_at_ms DESC LIMIT ?)
        );
        defer finalize(counts);
        bindInt(counts, 1, @bitCast(session_id));
        bindInt(counts, 2, limit);
        if (c.sqlite3_step(counts) != c.SQLITE_ROW) return error.SqliteStep;
        result.sample_turns = @intCast(c.sqlite3_column_int64(counts, 0));
        result.successful_turns = @intCast(c.sqlite3_column_int64(counts, 1));
        result.failed_turns = @intCast(c.sqlite3_column_int64(counts, 2));
        result.interrupted_turns = @intCast(c.sqlite3_column_int64(counts, 3));
        result.abandoned_turns = @intCast(c.sqlite3_column_int64(counts, 4));
        result.checkpoint_turns = @intCast(c.sqlite3_column_int64(counts, 5));
        result.tool_calls = @intCast(c.sqlite3_column_int64(counts, 6));

        var provider_durations: std.ArrayList(u64) = .empty;
        defer provider_durations.deinit(allocator);
        var ttft_durations: std.ArrayList(u64) = .empty;
        defer ttft_durations.deinit(allocator);
        const timings = try self.prepare(
            \\SELECT r.started_at_ms,r.ended_at_ms,r.first_visible_at_ms,r.first_byte_at_ms
            \\FROM telemetry_rounds r JOIN (
            \\ SELECT turn_id FROM telemetry_turns WHERE session_id=? ORDER BY started_at_ms DESC LIMIT ?
            \\) recent ON recent.turn_id=r.turn_id
            \\WHERE r.session_id=? ORDER BY r.started_at_ms
        );
        defer finalize(timings);
        bindInt(timings, 1, @bitCast(session_id));
        bindInt(timings, 2, limit);
        bindInt(timings, 3, @bitCast(session_id));
        while (true) switch (c.sqlite3_step(timings)) {
            c.SQLITE_ROW => {
                const started = c.sqlite3_column_int64(timings, 0);
                const ended = c.sqlite3_column_int64(timings, 1);
                const first_visible = c.sqlite3_column_int64(timings, 2);
                const first_byte = c.sqlite3_column_int64(timings, 3);
                try provider_durations.append(allocator, @intCast(@max(0, ended - started)));
                const first = if (first_visible > 0) first_visible else first_byte;
                if (first > 0) try ttft_durations.append(allocator, @intCast(@max(0, first - started)));
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStep,
        };
        result.provider_requests = @intCast(provider_durations.items.len);
        sortDurations(&provider_durations);
        sortDurations(&ttft_durations);
        result.provider_p50_ms = percentile(provider_durations.items, 50);
        result.provider_p95_ms = percentile(provider_durations.items, 95);
        result.ttft_p50_ms = percentile(ttft_durations.items, 50);
        result.ttft_p95_ms = percentile(ttft_durations.items, 95);

        const latest = try self.prepare(
            \\SELECT turn_id,started_at_ms,COALESCE(ended_at_ms,?),outcome,error_text
            \\FROM telemetry_turns WHERE session_id=? ORDER BY started_at_ms DESC LIMIT 1
        );
        defer finalize(latest);
        bindInt(latest, 1, now_ms);
        bindInt(latest, 2, @bitCast(session_id));
        const latest_rc = c.sqlite3_step(latest);
        if (latest_rc == c.SQLITE_ROW) {
            result.last_turn_id = @bitCast(c.sqlite3_column_int64(latest, 0));
            const started = c.sqlite3_column_int64(latest, 1);
            const ended = c.sqlite3_column_int64(latest, 2);
            result.last_duration_ms = @intCast(@max(0, ended - started));
            result.last_outcome = try dupeColumn(allocator, latest, 3);
            result.last_error = try dupeColumn(allocator, latest, 4);
            const trace = telemetry_ids.traceId(session_id, result.last_turn_id);
            result.last_trace_id = try allocator.dupe(u8, &trace);

            result.last_rounds = try self.diagnosticRounds(allocator, session_id, result.last_turn_id);
            result.last_tools = try self.diagnosticTools(allocator, session_id, result.last_turn_id);
        } else if (latest_rc != c.SQLITE_DONE) return error.SqliteStep;

        const export_status = try self.prepare(
            \\SELECT count(*),COALESCE((SELECT export_error FROM telemetry_turns
            \\ WHERE session_id=? AND export_error<>'' ORDER BY started_at_ms DESC LIMIT 1),'')
            \\FROM telemetry_turns WHERE session_id=? AND ended_at_ms IS NOT NULL AND exported_at_ms IS NULL
        );
        defer finalize(export_status);
        bindInt(export_status, 1, @bitCast(session_id));
        bindInt(export_status, 2, @bitCast(session_id));
        if (c.sqlite3_step(export_status) != c.SQLITE_ROW) return error.SqliteStep;
        result.otlp_pending = @intCast(c.sqlite3_column_int64(export_status, 0));
        result.otlp_last_error = try dupeColumn(allocator, export_status, 1);
        return result;
    }

    fn diagnosticRounds(self: Store, allocator: std.mem.Allocator, session_id: u64, turn_id: u64) Error![]const proto.DiagnosticRound {
        var rows: std.ArrayList(proto.DiagnosticRound) = .empty;
        const stmt = try self.prepare(
            \\SELECT round_index,started_at_ms,ended_at_ms,first_visible_at_ms,first_byte_at_ms,
            \\ response_bytes,status,provider,generation_id,tokens_in,tokens_out,cached_tokens,reasoning_tokens
            \\FROM telemetry_rounds WHERE session_id=? AND turn_id=? ORDER BY round_index
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                const started = c.sqlite3_column_int64(stmt, 1);
                const ended = c.sqlite3_column_int64(stmt, 2);
                const visible = c.sqlite3_column_int64(stmt, 3);
                const first_byte = c.sqlite3_column_int64(stmt, 4);
                const first = if (visible > 0) visible else first_byte;
                try rows.append(allocator, .{
                    .round = @intCast(c.sqlite3_column_int64(stmt, 0)),
                    .duration_ms = @intCast(@max(0, ended - started)),
                    .ttft_ms = if (first > 0) @intCast(@max(0, first - started)) else 0,
                    .bytes = @intCast(c.sqlite3_column_int64(stmt, 5)),
                    .status = try dupeColumn(allocator, stmt, 6),
                    .provider = try dupeColumn(allocator, stmt, 7),
                    .generation_id = try dupeColumn(allocator, stmt, 8),
                    .tokens_in = @intCast(c.sqlite3_column_int64(stmt, 9)),
                    .tokens_out = @intCast(c.sqlite3_column_int64(stmt, 10)),
                    .cached_tokens = @intCast(c.sqlite3_column_int64(stmt, 11)),
                    .reasoning_tokens = @intCast(c.sqlite3_column_int64(stmt, 12)),
                });
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStep,
        };
        return rows.toOwnedSlice(allocator) catch error.OutOfMemory;
    }

    fn diagnosticTools(self: Store, allocator: std.mem.Allocator, session_id: u64, turn_id: u64) Error![]const proto.DiagnosticTool {
        var rows: std.ArrayList(proto.DiagnosticTool) = .empty;
        const stmt = try self.prepare(
            "SELECT name,status,started_at_ms,ended_at_ms FROM telemetry_tools WHERE session_id=? AND turn_id=? ORDER BY started_at_ms,call_id",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => {
                const started = c.sqlite3_column_int64(stmt, 2);
                const ended = c.sqlite3_column_int64(stmt, 3);
                try rows.append(allocator, .{
                    .name = try dupeColumn(allocator, stmt, 0),
                    .status = try dupeColumn(allocator, stmt, 1),
                    .duration_ms = @intCast(@max(0, ended - started)),
                });
            },
            c.SQLITE_DONE => break,
            else => return error.SqliteStep,
        };
        return rows.toOwnedSlice(allocator) catch error.OutOfMemory;
    }

    pub fn nextTelemetryTrace(self: Store, allocator: std.mem.Allocator, now_ms: i64) Error!?TelemetryTrace {
        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);
        const stmt = try self.prepare(
            \\SELECT session_id,turn_id,model,session_kind,started_at_ms,ended_at_ms,outcome,
            \\ error_text,rounds,tool_calls,tokens_in,tokens_out
            \\FROM telemetry_turns
            \\WHERE ended_at_ms IS NOT NULL AND exported_at_ms IS NULL AND export_after_ms<=?
            \\ORDER BY started_at_ms LIMIT 1
        );
        defer finalize(stmt);
        bindInt(stmt, 1, now_ms);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        const session_id: u64 = @bitCast(c.sqlite3_column_int64(stmt, 0));
        const turn_id: u64 = @bitCast(c.sqlite3_column_int64(stmt, 1));
        return .{
            .session_id = session_id,
            .turn_id = turn_id,
            .model = try dupeColumn(allocator, stmt, 2),
            .session_kind = try dupeColumn(allocator, stmt, 3),
            .started_at_ms = c.sqlite3_column_int64(stmt, 4),
            .ended_at_ms = c.sqlite3_column_int64(stmt, 5),
            .outcome = try dupeColumn(allocator, stmt, 6),
            .error_text = try dupeColumn(allocator, stmt, 7),
            .rounds_count = @intCast(c.sqlite3_column_int64(stmt, 8)),
            .tool_calls = @intCast(c.sqlite3_column_int64(stmt, 9)),
            .tokens_in = @intCast(c.sqlite3_column_int64(stmt, 10)),
            .tokens_out = @intCast(c.sqlite3_column_int64(stmt, 11)),
            .rounds = try self.loadTelemetryRounds(allocator, session_id, turn_id),
            .tools = try self.loadTelemetryTools(allocator, session_id, turn_id),
        };
    }

    fn loadTelemetryRounds(self: Store, allocator: std.mem.Allocator, session_id: u64, turn_id: u64) Error![]const TelemetryRound {
        var rows: std.ArrayList(TelemetryRound) = .empty;
        const stmt = try self.prepare(
            \\SELECT round_index,span_id,started_at_ms,first_byte_at_ms,first_visible_at_ms,
            \\ ended_at_ms,status,http_status,response_bytes,provider,generation_id,tokens_in,
            \\ tokens_out,cached_tokens,cache_write_tokens,reasoning_tokens
            \\FROM telemetry_rounds WHERE session_id=? AND turn_id=? ORDER BY round_index
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try rows.append(allocator, .{
                .round = @intCast(c.sqlite3_column_int64(stmt, 0)),
                .span_id = try dupeColumn(allocator, stmt, 1),
                .started_at_ms = c.sqlite3_column_int64(stmt, 2),
                .first_byte_at_ms = c.sqlite3_column_int64(stmt, 3),
                .first_visible_at_ms = c.sqlite3_column_int64(stmt, 4),
                .ended_at_ms = c.sqlite3_column_int64(stmt, 5),
                .status = try dupeColumn(allocator, stmt, 6),
                .http_status = @intCast(c.sqlite3_column_int64(stmt, 7)),
                .response_bytes = @intCast(c.sqlite3_column_int64(stmt, 8)),
                .provider = try dupeColumn(allocator, stmt, 9),
                .generation_id = try dupeColumn(allocator, stmt, 10),
                .tokens_in = @intCast(c.sqlite3_column_int64(stmt, 11)),
                .tokens_out = @intCast(c.sqlite3_column_int64(stmt, 12)),
                .cached_tokens = @intCast(c.sqlite3_column_int64(stmt, 13)),
                .cache_write_tokens = @intCast(c.sqlite3_column_int64(stmt, 14)),
                .reasoning_tokens = @intCast(c.sqlite3_column_int64(stmt, 15)),
            }),
            c.SQLITE_DONE => break,
            else => return error.SqliteStep,
        };
        return rows.toOwnedSlice(allocator) catch error.OutOfMemory;
    }

    fn loadTelemetryTools(self: Store, allocator: std.mem.Allocator, session_id: u64, turn_id: u64) Error![]const TelemetryTool {
        var rows: std.ArrayList(TelemetryTool) = .empty;
        const stmt = try self.prepare(
            \\SELECT round_index,call_id,span_id,name,started_at_ms,ended_at_ms,status
            \\FROM telemetry_tools WHERE session_id=? AND turn_id=? ORDER BY started_at_ms,call_id
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        while (true) switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => try rows.append(allocator, .{
                .round = @intCast(c.sqlite3_column_int64(stmt, 0)),
                .call_id = try dupeColumn(allocator, stmt, 1),
                .span_id = try dupeColumn(allocator, stmt, 2),
                .name = try dupeColumn(allocator, stmt, 3),
                .started_at_ms = c.sqlite3_column_int64(stmt, 4),
                .ended_at_ms = c.sqlite3_column_int64(stmt, 5),
                .status = try dupeColumn(allocator, stmt, 6),
            }),
            c.SQLITE_DONE => break,
            else => return error.SqliteStep,
        };
        return rows.toOwnedSlice(allocator) catch error.OutOfMemory;
    }

    pub fn markTelemetryExported(self: Store, session_id: u64, turn_id: u64, now_ms: i64) Error!void {
        const stmt = try self.prepare(
            "UPDATE telemetry_turns SET exported_at_ms=?,export_error='' WHERE session_id=? AND turn_id=?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, now_ms);
        bindInt(stmt, 2, @bitCast(session_id));
        bindInt(stmt, 3, @bitCast(turn_id));
        try stepDone(stmt);
    }

    pub fn markTelemetryExportFailed(
        self: Store,
        session_id: u64,
        turn_id: u64,
        retry_at_ms: i64,
        message: []const u8,
    ) Error!void {
        const stmt = try self.prepare(
            \\UPDATE telemetry_turns SET export_attempts=export_attempts+1,export_after_ms=?,export_error=?
            \\WHERE session_id=? AND turn_id=?
        );
        defer finalize(stmt);
        bindInt(stmt, 1, retry_at_ms);
        bindText(stmt, 2, message[0..@min(message.len, 512)]);
        bindInt(stmt, 3, @bitCast(session_id));
        bindInt(stmt, 4, @bitCast(turn_id));
        try stepDone(stmt);
    }

    pub fn setSessionModel(self: Store, id: u64, model: []const u8) Error!void {
        const stmt = try self.prepare("UPDATE sessions SET model=? WHERE id=?");
        defer finalize(stmt);
        bindText(stmt, 1, model);
        bindInt(stmt, 2, @bitCast(id));
        try stepDone(stmt);
    }

    pub fn sessionHasBlocks(self: Store, id: u64) Error!bool {
        const stmt = try self.prepare("SELECT 1 FROM blocks WHERE session_id=? LIMIT 1");
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        return switch (c.sqlite3_step(stmt)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.SqliteStep,
        };
    }

    pub fn setSessionTitle(self: Store, id: u64, title: []const u8) Error!void {
        const stmt = try self.prepare("UPDATE sessions SET title=? WHERE id=?");
        defer finalize(stmt);
        bindText(stmt, 1, title);
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

    pub fn setSessionPlanMode(self: Store, id: u64, enabled: bool) Error!void {
        const stmt = try self.prepare("UPDATE sessions SET plan_mode=? WHERE id=?");
        defer finalize(stmt);
        bindInt(stmt, 1, if (enabled) 1 else 0);
        bindInt(stmt, 2, @bitCast(id));
        try stepDone(stmt);
    }

    pub fn setCodexThreadId(self: Store, id: u64, thread_id: ?[]const u8) Error!void {
        const stmt = try self.prepare("UPDATE sessions SET codex_thread_id=? WHERE id=?");
        defer finalize(stmt);
        if (thread_id) |value| bindText(stmt, 1, value) else bindNull(stmt, 1);
        bindInt(stmt, 2, @bitCast(id));
        try stepDone(stmt);
    }

    /// Caller owns the returned thread id.
    pub fn getCodexThreadId(self: Store, id: u64) Error!?[]const u8 {
        const stmt = try self.prepare("SELECT codex_thread_id FROM sessions WHERE id=?");
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.NotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
        return try self.dupeCol(stmt, 0);
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
        plan_mode: bool,

        pub fn deinit(self: SessionListing, gpa: std.mem.Allocator) void {
            gpa.free(self.title);
            gpa.free(self.cwd);
            gpa.free(self.model);
            gpa.free(self.status);
        }
    };

    fn sessionListingFromRow(self: Store, stmt: *c.sqlite3_stmt) Error!SessionListing {
        const title = try self.dupeCol(stmt, 5);
        errdefer self.gpa.free(title);
        const cwd = try self.dupeCol(stmt, 6);
        errdefer self.gpa.free(cwd);
        const model = try self.dupeCol(stmt, 7);
        errdefer self.gpa.free(model);
        const status = try self.dupeCol(stmt, 9);
        errdefer self.gpa.free(status);
        return .{
            .id = @bitCast(c.sqlite3_column_int64(stmt, 0)),
            .parent_sid = columnOptionalU64(stmt, 1),
            .kind = std.meta.stringToEnum(proto.SessionKind, columnText(stmt, 2)) orelse .root,
            .parent_block_id = columnOptionalU64(stmt, 3),
            .max_rounds = @intCast(c.sqlite3_column_int64(stmt, 4)),
            .title = title,
            .cwd = cwd,
            .model = model,
            .effort = Effort.parse(columnText(stmt, 8)) orelse .auto,
            .status = status,
            .created_at = c.sqlite3_column_int64(stmt, 10),
            .archived = c.sqlite3_column_int64(stmt, 11) != 0,
            .plan_mode = c.sqlite3_column_int64(stmt, 12) != 0,
        };
    }

    /// Sessions, newest hierarchy first. Archived rows are omitted unless
    /// requested. Caller deinits each entry + frees the returned slice.
    pub fn listSessions(self: Store, include_archived: bool) Error![]SessionListing {
        const stmt = try self.prepare(
            \\SELECT s.id, s.parent_sid, s.kind, s.parent_block_id, COALESCE(s.max_rounds, 0),
            \\       s.title, s.cwd, s.model, s.effort, s.status, s.created_at,
            \\       s.archived_at IS NOT NULL, s.plan_mode
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
            const row = try self.sessionListingFromRow(stmt);
            errdefer row.deinit(self.gpa);
            try out.append(self.gpa, row);
        }
        return out.toOwnedSlice(self.gpa);
    }

    /// Fetch one catalog row without scanning the durable session table.
    /// The caller owns the returned strings via SessionListing.deinit().
    pub fn getSessionListing(self: Store, id: u64) Error!SessionListing {
        const stmt = try self.prepare(
            \\SELECT s.id, s.parent_sid, s.kind, s.parent_block_id, COALESCE(s.max_rounds, 0),
            \\       s.title, s.cwd, s.model, s.effort, s.status, s.created_at,
            \\       s.archived_at IS NOT NULL, s.plan_mode
            \\FROM sessions s WHERE s.id=?
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.NotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        return self.sessionListingFromRow(stmt);
    }

    /// Fetch a hierarchy for the rare archive/unarchive catalog mutation.
    /// Ordinary single-session changes use getSessionListing and remain O(1).
    pub fn listSessionTree(self: Store, id: u64) Error![]SessionListing {
        const stmt = try self.prepare(
            \\WITH RECURSIVE session_tree(id) AS (
            \\  SELECT id FROM sessions WHERE id=?
            \\  UNION ALL
            \\  SELECT s.id FROM sessions s JOIN session_tree t ON s.parent_sid=t.id
            \\)
            \\SELECT s.id, s.parent_sid, s.kind, s.parent_block_id, COALESCE(s.max_rounds, 0),
            \\       s.title, s.cwd, s.model, s.effort, s.status, s.created_at,
            \\       s.archived_at IS NOT NULL, s.plan_mode
            \\FROM sessions s JOIN session_tree t ON t.id=s.id
            \\ORDER BY CASE WHEN s.parent_sid IS NULL THEN 0 ELSE 1 END,
            \\         s.created_at ASC, s.id ASC
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(id));
        var out: std.ArrayList(SessionListing) = .empty;
        errdefer {
            for (out.items) |row| row.deinit(self.gpa);
            out.deinit(self.gpa);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            const row = try self.sessionListingFromRow(stmt);
            errdefer row.deinit(self.gpa);
            try out.append(self.gpa, row);
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
            "SELECT parent_sid, kind, parent_block_id, COALESCE(max_rounds, 0), title, cwd, model, effort, status, tokens_in, tokens_out, archived_at IS NOT NULL, plan_mode FROM sessions WHERE id=?",
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
            .plan_mode = c.sqlite3_column_int64(stmt, 12) != 0,
        };
    }

    pub fn freeSession(self: Store, row: SessionRow) void {
        self.gpa.free(row.title);
        self.gpa.free(row.cwd);
        self.gpa.free(row.model);
        self.gpa.free(row.status);
    }

    // ------------------------------------------------------------ blocks --

    fn insertSearchDocLocked(self: Store, blk: block.Block, text: ?[]const u8) Error!void {
        const searchable = text orelse return;
        const doc_stmt = try self.cachedStatement(
            &self.statements.append_search_doc,
            "INSERT INTO search_docs(block_id, session_id, seq, kind, ts, text) VALUES(?,?,?,?,?,?)",
        );
        defer resetStatement(doc_stmt);
        bindInt(doc_stmt, 1, @bitCast(blk.id));
        bindInt(doc_stmt, 2, @bitCast(blk.session_id));
        bindInt(doc_stmt, 3, @bitCast(blk.seq));
        bindText(doc_stmt, 4, @tagName(blk.kind()));
        bindInt(doc_stmt, 5, blk.ts);
        bindText(doc_stmt, 6, searchable);
        try stepDone(doc_stmt);

        if (self.fts5) {
            const fts_stmt = try self.cachedStatement(
                &self.statements.append_search_fts,
                "INSERT INTO search_fts(rowid, text) VALUES(?,?)",
            );
            defer resetStatement(fts_stmt);
            bindInt(fts_stmt, 1, @bitCast(blk.id));
            bindText(fts_stmt, 2, searchable);
            try stepDone(fts_stmt);
        }
    }

    /// Append a block. body is serialized to JSON here.
    pub fn appendBlock(self: Store, blk: block.Block) Error!void {
        const body_json = std.json.Stringify.valueAlloc(self.gpa, blk.body, .{}) catch
            return error.OutOfMemory;
        defer self.gpa.free(body_json);
        var search_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer search_arena_state.deinit();
        const search_text = try searchTextAlloc(search_arena_state.allocator(), blk);

        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);
        try self.execAll("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.execAll("ROLLBACK;") catch {};
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
        try self.insertSearchDocLocked(blk, search_text);
        try self.execAll("COMMIT;");
        committed = true;
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
        return self.appendBlockWithBlobs(blk, &.{.{ .hash = hash, .bytes = bytes }});
    }

    pub const BlobPayload = struct {
        hash: []const u8,
        bytes: []const u8,
    };

    /// Persist a block and all binary content it references in one SQLite
    /// transaction. A crash can leave neither dangling attachment metadata
    /// nor an unreferenced just-written media blob.
    pub fn appendBlockWithBlobs(
        self: Store,
        blk: block.Block,
        blobs: []const BlobPayload,
    ) Error!void {
        const body_json = std.json.Stringify.valueAlloc(self.gpa, blk.body, .{}) catch
            return error.OutOfMemory;
        defer self.gpa.free(body_json);
        var search_arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer search_arena_state.deinit();
        const search_text = try searchTextAlloc(search_arena_state.allocator(), blk);

        const db_mutex = c.sqlite3_db_mutex(self.db);
        c.sqlite3_mutex_enter(db_mutex);
        defer c.sqlite3_mutex_leave(db_mutex);
        try self.execAll("BEGIN IMMEDIATE;");
        var committed = false;
        defer if (!committed) self.execAll("ROLLBACK;") catch {};

        for (blobs) |blob_value| {
            const stmt = try self.prepare(
                \\INSERT INTO blobs(hash, bytes, created_at) VALUES(?,?,?)
                \\ON CONFLICT(hash) DO UPDATE SET
                \\  bytes=excluded.bytes, created_at=excluded.created_at, tombstone=0
                \\WHERE blobs.tombstone=1
            );
            defer finalize(stmt);
            bindText(stmt, 1, blob_value.hash);
            _ = c.sqlite3_bind_blob(stmt, 2, blob_value.bytes.ptr, @intCast(blob_value.bytes.len), static_destructor);
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
        try self.insertSearchDocLocked(blk, search_text);
        for (blobs) |blob_value| {
            const stmt = try self.prepare("INSERT OR IGNORE INTO blob_refs(hash, block_id) VALUES(?,?)");
            defer finalize(stmt);
            bindText(stmt, 1, blob_value.hash);
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

    /// Load one forward replay page without first materializing `limit` large
    /// rows. Returns true when another row exists (or the body-byte budget
    /// stopped this page). One first row may exceed max_body_bytes so every
    /// durable block remains reachable.
    pub fn loadForwardPageInto(
        self: Store,
        arena: std.mem.Allocator,
        out: *std.ArrayList(block.Block),
        session_id: u64,
        from_seq: u64,
        limit: u32,
        max_body_bytes: usize,
    ) Error!bool {
        const stmt = try self.prepare(
            "SELECT id, turn_id, seq, ts, body_json FROM blocks WHERE session_id=? AND seq>=? ORDER BY seq ASC LIMIT ?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(from_seq));
        bindInt(stmt, 3, @intCast(limit +| 1));

        var loaded: u32 = 0;
        var body_bytes: usize = 0;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) return false;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            if (loaded >= limit) return true;
            const body_ptr = c.sqlite3_column_text(stmt, 4);
            const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            if (loaded > 0 and body_len > max_body_bytes -| body_bytes) return true;
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
            loaded += 1;
            body_bytes +|= body_len;
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
            \\), latest_plan(value) AS (
            \\  SELECT COALESCE(MAX(seq), 0) FROM blocks WHERE session_id=? AND kind='plan'
            \\)
            \\SELECT id, turn_id, seq, ts, body_json
            \\FROM blocks, frontier, latest_plan
            \\WHERE session_id=? AND (kind='compaction' OR seq>frontier.value OR seq=latest_plan.value)
            \\ORDER BY seq ASC LIMIT ?
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(session_id));
        bindInt(stmt, 3, @bitCast(session_id));
        bindInt(stmt, 4, @intCast(limit));

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

    pub const LatestPlan = struct {
        items: []const block.PlanItem,
        /// Only unfinished work belongs in the live panel.
        pinned: bool,
    };

    /// Decode the newest durable plan revision for a freshly subscribed
    /// client. This is independent of its bounded transcript replay window.
    pub fn loadLatestPlan(
        self: Store,
        arena: std.mem.Allocator,
        session_id: u64,
    ) Error!?LatestPlan {
        const stmt = try self.prepare(
            \\SELECT body_json FROM blocks
            \\WHERE session_id=? AND kind='plan'
            \\ORDER BY seq DESC LIMIT 1
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        const body_ptr = c.sqlite3_column_text(stmt, 0);
        const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        const body_json = try arena.dupe(u8, body_ptr[0..body_len]);
        const body = std.json.parseFromSliceLeaky(block.Body, arena, body_json, .{
            .ignore_unknown_fields = true,
        }) catch return error.SqliteStep;
        return switch (body) {
            .plan => |plan| blk: {
                var complete = plan.items.len > 0;
                for (plan.items) |item| complete = complete and item.status == .completed;
                break :blk .{
                    .items = plan.items,
                    .pinned = !complete,
                };
            },
            else => error.SqliteStep,
        };
    }

    pub const TurnTimeBounds = struct { start_ms: i64, end_ms: i64 };

    /// Durable active-time boundaries for one turn. Plan timers use these to
    /// exclude the wall-clock gap while a session waits for the next prompt.
    pub fn turnTimeBounds(self: Store, session_id: u64, turn_id: u64) Error!?TurnTimeBounds {
        const stmt = try self.prepare(
            "SELECT MIN(ts), MAX(ts) FROM blocks WHERE session_id=? AND turn_id=?",
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(turn_id));
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.SqliteStep;
        if (c.sqlite3_column_type(stmt, 0) == c.SQLITE_NULL) return null;
        return .{
            .start_ms = c.sqlite3_column_int64(stmt, 0),
            .end_ms = c.sqlite3_column_int64(stmt, 1),
        };
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

    /// Recent authored text for Ctrl+R. Fuzzy ranking remains client-side;
    /// this query only provides a bounded, newest-first durable corpus.
    pub fn recentInputs(
        self: Store,
        arena: std.mem.Allocator,
        current_session_id: u64,
        limit: u32,
    ) Error![]const proto.InputHistoryEntry {
        const stmt = try self.prepare(
            \\SELECT session_id, seq, ts, text FROM search_docs
            \\WHERE kind IN ('user_msg','steer')
            \\ORDER BY (session_id=?) DESC, ts DESC, block_id DESC LIMIT ?
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(current_session_id));
        bindInt(stmt, 2, @intCast(@min(limit, 1024)));
        var entries: std.ArrayList(proto.InputHistoryEntry) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            try entries.append(arena, .{
                .sid = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                .seq = @bitCast(c.sqlite3_column_int64(stmt, 1)),
                .ts = c.sqlite3_column_int64(stmt, 2),
                .text = try arena.dupe(u8, columnText(stmt, 3)),
            });
        }
        return entries.items;
    }

    /// Search durable rendered text. FTS5 is preferred; search_docs provides
    /// a portable bounded fallback for system SQLite builds without it.
    pub fn search(
        self: Store,
        arena: std.mem.Allocator,
        query: []const u8,
        session_id: u64,
        limit: u32,
    ) Error![]const proto.SearchHit {
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return &.{};
        const capped_limit = @min(limit, 200);
        if (capped_limit == 0) return &.{};

        const stmt = if (self.fts5) fts: {
            const expression = try ftsQueryAlloc(arena, trimmed);
            const value = expression orelse return &.{};
            const prepared = try self.prepare(
                \\SELECT d.session_id, d.block_id, d.seq, d.ts, d.kind,
                \\       s.title, s.cwd,
                \\       snippet(search_fts, 0, '[', ']', ' … ', 24)
                \\FROM search_fts
                \\JOIN search_docs d ON d.block_id=search_fts.rowid
                \\JOIN sessions s ON s.id=d.session_id
                \\WHERE search_fts MATCH ? AND (?=0 OR d.session_id=?)
                \\ORDER BY bm25(search_fts), d.ts DESC LIMIT ?
            );
            bindText(prepared, 1, value);
            bindInt(prepared, 2, @bitCast(session_id));
            bindInt(prepared, 3, @bitCast(session_id));
            bindInt(prepared, 4, @intCast(capped_limit));
            break :fts prepared;
        } else fallback: {
            const prepared = try self.prepare(
                \\SELECT d.session_id, d.block_id, d.seq, d.ts, d.kind,
                \\       s.title, s.cwd, substr(d.text, 1, 320)
                \\FROM search_docs d JOIN sessions s ON s.id=d.session_id
                \\WHERE (?=0 OR d.session_id=?) AND d.text LIKE '%' || ? || '%' COLLATE NOCASE
                \\ORDER BY d.ts DESC LIMIT ?
            );
            bindInt(prepared, 1, @bitCast(session_id));
            bindInt(prepared, 2, @bitCast(session_id));
            bindText(prepared, 3, trimmed);
            bindInt(prepared, 4, @intCast(capped_limit));
            break :fallback prepared;
        };
        defer finalize(stmt);

        var hits: std.ArrayList(proto.SearchHit) = .empty;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            try hits.append(arena, .{
                .sid = @bitCast(c.sqlite3_column_int64(stmt, 0)),
                .block_id = @bitCast(c.sqlite3_column_int64(stmt, 1)),
                .seq = @bitCast(c.sqlite3_column_int64(stmt, 2)),
                .ts = c.sqlite3_column_int64(stmt, 3),
                .kind = std.meta.stringToEnum(block.BlockKind, columnText(stmt, 4)) orelse .system_note,
                .title = try arena.dupe(u8, columnText(stmt, 5)),
                .cwd = try arena.dupe(u8, columnText(stmt, 6)),
                .snippet = try arena.dupe(u8, columnText(stmt, 7)),
            });
        }
        return hits.items;
    }

    /// Load a newest suffix directly in DESC order, stopping before parsing
    /// an over-budget older row, then reverse only the bounded result into
    /// transcript order. `before_seq=0` means the live tail.
    pub fn loadTailPageInto(
        self: Store,
        arena: std.mem.Allocator,
        out: *std.ArrayList(block.Block),
        session_id: u64,
        before_seq: u64,
        limit: u32,
        max_body_bytes: usize,
    ) Error!bool {
        const stmt = try self.prepare(
            \\SELECT id, turn_id, seq, ts, body_json FROM blocks
            \\WHERE session_id=? AND (?=0 OR seq<?)
            \\ORDER BY seq DESC LIMIT ?
        );
        defer finalize(stmt);
        bindInt(stmt, 1, @bitCast(session_id));
        bindInt(stmt, 2, @bitCast(before_seq));
        bindInt(stmt, 3, @bitCast(before_seq));
        bindInt(stmt, 4, @intCast(limit +| 1));

        const start = out.items.len;
        var loaded: u32 = 0;
        var body_bytes: usize = 0;
        var has_older = false;
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.SqliteStep;
            if (loaded >= limit) {
                has_older = true;
                break;
            }
            const body_ptr = c.sqlite3_column_text(stmt, 4);
            const body_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 4));
            if (loaded > 0 and body_len > max_body_bytes -| body_bytes) {
                has_older = true;
                break;
            }
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
            loaded += 1;
            body_bytes +|= body_len;
        }
        std.mem.reverse(block.Block, out.items[start..]);
        return has_older;
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
        return self.getBlobAlloc(self.gpa, hash);
    }

    pub fn getBlobAlloc(self: Store, allocator: std.mem.Allocator, hash: []const u8) Error![]const u8 {
        const stmt = try self.prepare("SELECT bytes, tombstone FROM blobs WHERE hash=?");
        defer finalize(stmt);
        bindText(stmt, 1, hash);
        const rc = c.sqlite3_step(stmt);
        if (rc == c.SQLITE_DONE) return error.NotFound;
        if (rc != c.SQLITE_ROW) return error.SqliteStep;
        if (c.sqlite3_column_int(stmt, 1) != 0) return error.NotFound;
        const ptr = c.sqlite3_column_blob(stmt, 0);
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
        if (len == 0) return try allocator.dupe(u8, "");
        const bytes: [*]const u8 = @ptrCast(ptr.?);
        return try allocator.dupe(u8, bytes[0..len]);
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

const max_search_text_bytes: usize = 256 * 1024;

fn ftsQueryAlloc(allocator: std.mem.Allocator, query: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (words.next()) |word| {
        if (out.items.len > 0) try out.append(allocator, ' ');
        try out.append(allocator, '"');
        for (word) |byte| {
            if (byte == '"') try out.append(allocator, '"');
            try out.append(allocator, byte);
        }
        try out.appendSlice(allocator, "\"*");
    }
    return if (out.items.len > 0) out.items else null;
}

fn appendSearchPart(out: *std.ArrayList(u8), allocator: std.mem.Allocator, part: []const u8) !void {
    if (part.len == 0 or out.items.len >= max_search_text_bytes) return;
    if (out.items.len > 0) try out.append(allocator, '\n');
    const available = max_search_text_bytes - out.items.len;
    try out.appendSlice(allocator, part[0..@min(part.len, available)]);
}

/// Project a durable block into the text users actually saw. Binary payloads,
/// blob bodies, and synthetic compaction rehydration are deliberately absent.
fn searchTextAlloc(allocator: std.mem.Allocator, blk: block.Block) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    switch (blk.body) {
        .user_msg => |user| {
            if (user.synthetic) return null;
            try appendSearchPart(&out, allocator, user.text);
            for (user.attachments) |attachment| try appendSearchPart(&out, allocator, attachment.name);
        },
        .assistant_msg => |assistant| try appendSearchPart(&out, allocator, assistant.text),
        .reasoning => |reasoning| try appendSearchPart(&out, allocator, reasoning.text),
        .steer => |steer| try appendSearchPart(&out, allocator, steer.text),
        .tool_call => |call| {
            try appendSearchPart(&out, allocator, call.name);
            try appendSearchPart(&out, allocator, call.args_json);
        },
        .tool_result => |result| {
            try appendSearchPart(&out, allocator, result.inline_body);
            for (result.attachments) |attachment| try appendSearchPart(&out, allocator, attachment.name);
        },
        .plan => |plan| for (plan.items) |item| try appendSearchPart(&out, allocator, item.step),
        .compaction => |compaction| try appendSearchPart(&out, allocator, compaction.summary),
        .system_note => |note| try appendSearchPart(&out, allocator, note.text),
        .approval => return null,
    }
    return if (out.items.len > 0) out.items else null;
}

const StatementCache = struct {
    append_block: ?*c.sqlite3_stmt = null,
    append_search_doc: ?*c.sqlite3_stmt = null,
    append_search_fts: ?*c.sqlite3_stmt = null,
    set_session_status: ?*c.sqlite3_stmt = null,
    update_session_usage: ?*c.sqlite3_stmt = null,

    fn deinit(self: *StatementCache) void {
        inline for (.{
            self.append_block,
            self.append_search_doc,
            self.append_search_fts,
            self.set_session_status,
            self.update_session_usage,
        }) |stmt|
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

fn dupeColumn(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt, col: c_int) Error![]const u8 {
    const value = columnText(stmt, col);
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn sortDurations(values: *std.ArrayList(u64)) void {
    std.mem.sort(u64, values.items, {}, struct {
        fn lessThan(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lessThan);
}

fn percentile(sorted: []const u64, p: u64) u64 {
    if (sorted.len == 0) return 0;
    const rank = @divFloor(sorted.len * p + 99, 100);
    return sorted[@max(rank, 1) - 1];
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

test "schema is v10 with guest identity, plan mode, search, and telemetry" {
    const gpa = std.testing.allocator;
    var store = try Store.open(gpa, null);
    defer store.close();

    try std.testing.expectEqual(@as(i64, 10), try store.kvGetInt("schema_version"));
    // migrate() must be a no-op on a current DB (idempotent open).
    try store.migrate();
    try std.testing.expectEqual(@as(i64, 10), try store.kvGetInt("schema_version"));
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
        .provider = "test-provider",
        .generation_id = "gen-1",
        .tokens_in = 20,
        .tokens_out = 5,
        .cached_tokens = 10,
        .cache_write_tokens = 0,
        .reasoning_tokens = 2,
    });
    try store.telemetryRecordTool(42, 100, .{
        .round = 0,
        .call_id = "call-1",
        .span_id = "0000000000000066",
        .name = "read_file",
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
    try std.testing.expectEqual(@as(usize, 1), report.last_rounds.len);
    try std.testing.expectEqual(@as(usize, 1), report.last_tools.len);
    try std.testing.expectEqualStrings("read_file", report.last_tools[0].name);
    try std.testing.expectEqual(@as(u32, 1), report.otlp_pending);

    const trace = (try store.nextTelemetryTrace(arena, 1_300)).?;
    try std.testing.expectEqual(@as(u64, 100), trace.turn_id);
    try std.testing.expectEqualStrings("gen-1", trace.rounds[0].generation_id);
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
