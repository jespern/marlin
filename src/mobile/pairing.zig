//! Phone pairing for the web companion. A phone that reaches the bridge
//! under a public name (`[web] hosts`) must present a device cookie; it gets
//! one by typing a short-lived code the terminal shows (/web, `p`).
//!
//! The daemon issues codes (so a remote TUI can ask for one over the
//! protocol); the web bridge redeems them and verifies cookies. Both are
//! processes on the daemon's host and share one private file:
//! `$XDG_STATE_HOME/marlin/web/pairing.json` (default ~/.local/state). Only
//! a SHA-256 of each device token is stored. Writes are atomic renames, so a
//! reader never sees a torn file; a code issued in the same instant as a
//! redemption can lose one of the two updates, which costs a retry.

const std = @import("std");
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const webpush = @import("webpush.zig");

pub const code_digits = 6;
pub const code_ttl_ms: i64 = 5 * 60 * 1000;
/// Wrong guesses before the outstanding code is burned: 5 tries against
/// 10^6 codes per issued code.
pub const max_failures: u8 = 5;
/// Pairing past this drops the oldest device.
pub const max_devices = 16;
pub const cookie_name = "marlin_device";
/// Chrome caps cookie lifetimes at 400 days; the bridge renews on each visit.
pub const cookie_max_age_s: u64 = 400 * 24 * 60 * 60;
pub const token_len = 64;
const file_name = "pairing.json";

pub const Code = struct { digits: []const u8, expires_ms: i64, failures: u8 = 0 };
pub const Device = struct { id: u32, name: []const u8, token_sha256: []const u8, paired_ms: i64 };
pub const State = struct { code: ?Code = null, devices: []const Device = &.{} };

/// XDG_STATE_HOME (or ~/.local/state) + marlin/web, beside marlin/push.
pub fn stateRoot(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_STATE_HOME")) |dir| {
        if (dir.len > 0) return std.fs.path.join(gpa, &.{ dir, "marlin", "web" });
    }
    const home = environ.get("HOME") orelse return error.MissingStateDirectory;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "marlin", "web" });
}

/// Missing file = nothing paired yet.
pub fn load(arena: std.mem.Allocator, io: Io, root: []const u8) !State {
    const path = try std.fs.path.join(arena, &.{ root, file_name });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(256 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(State, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn save(gpa: std.mem.Allocator, io: Io, root: []const u8, state: State) !void {
    try Io.Dir.cwd().createDirPath(io, root);
    const json = try std.json.Stringify.valueAlloc(gpa, state, .{});
    defer gpa.free(json);
    try webpush.writePrivateFile(io, root, file_name, json, false);
}

/// Replace any outstanding code with a fresh one and return it.
pub fn issue(gpa: std.mem.Allocator, io: Io, root: []const u8, now_ms: i64) ![code_digits]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var state = try load(arena_state.allocator(), io, root);
    var digits = randomDigits(io);
    state.code = .{ .digits = &digits, .expires_ms = now_ms + code_ttl_ms };
    try save(gpa, io, root, state);
    return digits;
}

/// The live code, or null when none is outstanding or it expired.
pub fn activeCode(state: State, now_ms: i64) ?Code {
    const code = state.code orelse return null;
    return if (now_ms < code.expires_ms) code else null;
}

/// Pure half of redeem: consume the code on a match, count a failure
/// otherwise. Returns true when `token` was registered as a new device.
pub fn redeemState(arena: std.mem.Allocator, state: *State, attempt: []const u8, name: []const u8, now_ms: i64, token: *const [token_len]u8) !bool {
    const code = activeCode(state.*, now_ms) orelse {
        state.code = null;
        return false;
    };
    if (!codeMatches(code.digits, attempt)) {
        const failures = code.failures + 1;
        state.code = if (failures >= max_failures) null else .{ .digits = code.digits, .expires_ms = code.expires_ms, .failures = failures };
        return false;
    }
    state.code = null;
    var next_id: u32 = 1;
    for (state.devices) |device| next_id = @max(next_id, device.id + 1);
    const dropped = (state.devices.len + 1) -| max_devices;
    const keep = state.devices[dropped..];
    const devices = try arena.alloc(Device, keep.len + 1);
    @memcpy(devices[0..keep.len], keep);
    const hash = tokenHash(token);
    devices[keep.len] = .{ .id = next_id, .name = try arena.dupe(u8, name), .token_sha256 = try arena.dupe(u8, &hash), .paired_ms = now_ms };
    state.devices = devices;
    return true;
}

pub const Redeemed = struct { token: [token_len]u8, id: u32 };

/// Redeem `attempt` for a new device token, or null for a wrong, expired,
/// or burned code. The caller serializes redemptions within its process.
pub fn redeem(gpa: std.mem.Allocator, io: Io, root: []const u8, attempt: []const u8, name: []const u8, now_ms: i64) !?Redeemed {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try load(arena, io, root);
    if (state.code == null) return null;
    var raw: [32]u8 = undefined;
    io.random(&raw);
    const token = std.fmt.bytesToHex(raw, .lower);
    const paired = try redeemState(arena, &state, attempt, name, now_ms, &token);
    try save(gpa, io, root, state);
    if (!paired) return null;
    return .{ .token = token, .id = state.devices[state.devices.len - 1].id };
}

/// Whether `token` belongs to a paired device. Read fresh on every call, so
/// a revocation applies to the next request.
pub fn verify(gpa: std.mem.Allocator, io: Io, root: []const u8, token: []const u8) !bool {
    if (token.len != token_len) return false;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const state = try load(arena_state.allocator(), io, root);
    return stateHasToken(state, token[0..token_len]);
}

pub fn stateHasToken(state: State, token: *const [token_len]u8) bool {
    const want = tokenHash(token);
    var found = false;
    for (state.devices) |device| {
        if (device.token_sha256.len != want.len) continue;
        found = found or std.crypto.timing_safe.eql([want.len]u8, want, device.token_sha256[0..want.len].*);
    }
    return found;
}

/// Forget one device. False when no device has that id.
pub fn revoke(gpa: std.mem.Allocator, io: Io, root: []const u8, id: u32) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try load(arena, io, root);
    var kept: std.ArrayList(Device) = .empty;
    for (state.devices) |device| {
        if (device.id != id) try kept.append(arena, device);
    }
    if (kept.items.len == state.devices.len) return false;
    state.devices = kept.items;
    try save(gpa, io, root, state);
    return true;
}

pub fn tokenHash(token: *const [token_len]u8) [64]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(token, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Digits only, so "482 913" and "482-913" both count; any other length
/// is a miss. Constant-time over the digits.
pub fn codeMatches(code: []const u8, attempt: []const u8) bool {
    var typed: [code_digits]u8 = undefined;
    var n: usize = 0;
    for (attempt) |ch| {
        if (!std.ascii.isDigit(ch)) continue;
        if (n == code_digits) return false;
        typed[n] = ch;
        n += 1;
    }
    if (n != code_digits or code.len != code_digits) return false;
    return std.crypto.timing_safe.eql([code_digits]u8, typed, code[0..code_digits].*);
}

/// Uniform decimal digits by rejection sampling.
fn randomDigits(io: Io) [code_digits]u8 {
    var out: [code_digits]u8 = undefined;
    var n: usize = 0;
    while (n < code_digits) {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        for (bytes) |byte| {
            if (byte >= 250 or n == code_digits) continue;
            out[n] = '0' + byte % 10;
            n += 1;
        }
    }
    return out;
}

/// A short label for the Web tab's device list, from the User-Agent.
pub fn deviceName(user_agent: ?[]const u8) []const u8 {
    const ua = user_agent orelse return "browser";
    const names = [_][2][]const u8{
        .{ "iPhone", "iPhone" }, .{ "iPad", "iPad" },       .{ "Android", "Android" },
        .{ "Macintosh", "Mac" }, .{ "Windows", "Windows" }, .{ "Linux", "Linux" },
    };
    for (names) |entry| {
        if (std.mem.indexOf(u8, ua, entry[0]) != null) return entry[1];
    }
    return "browser";
}
