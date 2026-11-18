//! Bearer tokens for Marlin's MCP server (client/mcp_server.zig): how an
//! assistant outside Marlin, such as Robin, proves who it is. Each token has
//! a name (shown to sessions it messages) and scopes:
//!
//!   read  list and read sessions, wait on one, read the attention log
//!   act   message a session, answer its approvals and questions
//!
//! A token holds only the scopes it was made with, so a reader and an actor
//! can be separate tokens. The daemon makes and revokes them (so a TUI
//! attached with --remote can too); the web companion verifies them on every
//! request, reading the file fresh, so a revocation applies at once. Only a
//! SHA-256 of each token is kept, beside pairing.json:
//! `$XDG_STATE_HOME/marlin/web/mcp_tokens.json`.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const webpush = @import("webpush.zig");
const pairing = @import("pairing.zig");

pub const prefix = "marlin_";
pub const token_len = prefix.len + 64;
pub const max_tokens = 32;
pub const max_name_len = 64;
const file_name = "mcp_tokens.json";

pub const Scope = enum { read, act };

pub const Token = struct {
    id: u32,
    name: []const u8,
    scopes: []const Scope,
    token_sha256: []const u8,
    created_ms: i64,
};
pub const State = struct { tokens: []const Token = &.{} };

pub const stateRoot = pairing.stateRoot;

/// Missing file = no tokens yet.
pub fn load(arena: std.mem.Allocator, io: Io, root: []const u8) !State {
    const path = try std.fs.path.join(arena, &.{ root, file_name });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

fn save(gpa: std.mem.Allocator, io: Io, root: []const u8, state: State) !void {
    try Io.Dir.cwd().createDirPath(io, root);
    const json = try std.json.Stringify.valueAlloc(gpa, state, .{});
    defer gpa.free(json);
    try webpush.writePrivateFile(io, root, file_name, json, false);
}

/// "read", "act", or both comma-separated ("read,act"); null for anything
/// else or an empty list. Order and repeats don't matter.
pub fn parseScopes(text: []const u8) ?[]const Scope {
    var read = false;
    var act = false;
    var it = std.mem.tokenizeAny(u8, text, ", ");
    while (it.next()) |word| {
        const scope = std.meta.stringToEnum(Scope, word) orelse return null;
        switch (scope) {
            .read => read = true,
            .act => act = true,
        }
    }
    if (read and act) return &.{ .read, .act };
    if (read) return &.{.read};
    if (act) return &.{.act};
    return null;
}

pub const NameError = error{ BadName, NameTaken, TooManyTokens };

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) return false;
    return true;
}

pub const Created = struct { id: u32, token: [token_len]u8 };

/// Pure half of create: append a token with the given hash.
pub fn addToState(arena: std.mem.Allocator, state: *State, name: []const u8, scopes: []const Scope, hash: []const u8, now_ms: i64) !u32 {
    if (!validName(name)) return error.BadName;
    if (state.tokens.len >= max_tokens) return error.TooManyTokens;
    var next_id: u32 = 1;
    for (state.tokens) |token| {
        if (std.ascii.eqlIgnoreCase(token.name, name)) return error.NameTaken;
        next_id = @max(next_id, token.id + 1);
    }
    const tokens = try arena.alloc(Token, state.tokens.len + 1);
    @memcpy(tokens[0..state.tokens.len], state.tokens);
    tokens[state.tokens.len] = .{
        .id = next_id,
        .name = try arena.dupe(u8, name),
        .scopes = try arena.dupe(Scope, scopes),
        .token_sha256 = try arena.dupe(u8, hash),
        .created_ms = now_ms,
    };
    state.tokens = tokens;
    return next_id;
}

/// Make a token. The caller shows it once; only its hash is kept.
pub fn create(gpa: std.mem.Allocator, io: Io, root: []const u8, name: []const u8, scopes: []const Scope, now_ms: i64) !Created {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try load(arena, io, root);
    var raw: [32]u8 = undefined;
    io.random(&raw);
    var token: [token_len]u8 = undefined;
    @memcpy(token[0..prefix.len], prefix);
    token[prefix.len..].* = std.fmt.bytesToHex(raw, .lower);
    const hash = tokenHash(&token);
    const id = try addToState(arena, &state, name, scopes, &hash, now_ms);
    try save(gpa, io, root, state);
    return .{ .id = id, .token = token };
}

/// What a valid token may do, and whose it is.
pub const Grant = struct {
    id: u32,
    name_buf: [max_name_len]u8 = undefined,
    name_len: usize = 0,
    read: bool = false,
    act: bool = false,

    pub fn name(self: *const Grant) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub fn grantFor(state: State, token: []const u8) ?Grant {
    if (token.len != token_len) return null;
    const want = tokenHash(token[0..token_len]);
    var found: ?Token = null;
    for (state.tokens) |entry| {
        if (entry.token_sha256.len != want.len) continue;
        if (std.crypto.timing_safe.eql([want.len]u8, want, entry.token_sha256[0..want.len].*)) found = entry;
    }
    const entry = found orelse return null;
    var grant: Grant = .{ .id = entry.id };
    grant.name_len = @min(entry.name.len, max_name_len);
    @memcpy(grant.name_buf[0..grant.name_len], entry.name[0..grant.name_len]);
    for (entry.scopes) |scope| switch (scope) {
        .read => grant.read = true,
        .act => grant.act = true,
    };
    return grant;
}

/// The grant for `token`, or null. Read fresh on every call, so a
/// revocation applies to the next request.
pub fn verify(gpa: std.mem.Allocator, io: Io, root: []const u8, token: []const u8) !?Grant {
    if (token.len != token_len) return null;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    return grantFor(try load(arena_state.allocator(), io, root), token);
}

/// Pure half of revoke: drop the token with this id or name. False when
/// none matches.
pub fn removeFromState(arena: std.mem.Allocator, state: *State, which: []const u8) !bool {
    const id = std.fmt.parseInt(u32, which, 10) catch null;
    var kept: std.ArrayList(Token) = .empty;
    for (state.tokens) |token| {
        const match = if (id) |n| token.id == n else std.ascii.eqlIgnoreCase(token.name, which);
        if (!match) try kept.append(arena, token);
    }
    if (kept.items.len == state.tokens.len) return false;
    state.tokens = kept.items;
    return true;
}

/// Revoke a token by id or name. False when none matches.
pub fn revoke(gpa: std.mem.Allocator, io: Io, root: []const u8, which: []const u8) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try load(arena, io, root);
    if (!try removeFromState(arena, &state, which)) return false;
    try save(gpa, io, root, state);
    return true;
}

pub fn tokenHash(token: *const [token_len]u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// "read", "act" or "read,act", for lists.
pub fn scopesLabel(scopes: []const Scope) []const u8 {
    var read = false;
    var act = false;
    for (scopes) |scope| switch (scope) {
        .read => read = true,
        .act => act = true,
    };
    return if (read and act) "read,act" else if (act) "act" else "read";
}
