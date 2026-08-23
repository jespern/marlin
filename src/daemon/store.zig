//! The store: SQLite. THE ONLY FILE THAT KNOWS SQL.
//!
//! Schema (docs/ARCHITECTURE.md §2):
//!   sessions(id, title, created_at, cwd, model, provider, status,
//!            pinned_context, config_json)
//!   blocks(id, session_id, turn_id, seq, kind, ts, body_json)
//!   blobs(hash, bytes)          -- full tool outputs, content-addressed
//!   blocks_fts                  -- FTS5 over user/assistant/tool text
//!   kv(key, value)              -- schema_version, daemon metadata
//!
//! WAL mode for crash safety. Blocks are INSERT-only; sessions row is the
//! only thing UPDATEd. Blob writes are idempotent (content hash PK).
//!
//! DB path: ~/.local/state/marlin/marlin.db (respect XDG_STATE_HOME).

const std = @import("std");
const block = @import("../core/block.zig");

pub const Store = struct {
    // db: *c.sqlite3,

    // TODO(M0) — the minimal M0 surface:
    //   open(path) / close()                     (create schema, WAL, migrate)
    //   createSession(...) → u64
    //   appendBlock(Block) → void                (single tx w/ fts insert)
    //   getBlocks(sid, from_seq, limit) → []Block
    //   putBlob(bytes) → hash / getBlob(hash)
    //   lastSession() → ?u64                     (for `marlin run --continue`)
    // TODO(M1): listSessions, updateSessionMeta, FTS search query.
};

test {
    std.testing.refAllDecls(@This());
}
