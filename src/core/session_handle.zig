//! Human-facing session handles.
//!
//! Durable session identity remains the sortable u64 used by SQLite and the
//! protocol.  Humans see a stable, opaque SHA-256 handle instead: eight hex
//! characters normally, extended only when another known session shares that
//! prefix.  Commands accept any unique prefix of at least four characters.

const std = @import("std");

pub const full_len = std.crypto.hash.sha2.Sha256.digest_length * 2;
pub const default_len: usize = 8;
pub const min_prefix_len: usize = 4;
pub const Full = [full_len]u8;

const domain = "marlin/session-handle/v1\x00";

/// The complete stable handle for a durable numeric session id.
pub fn full(sid: u64) Full {
    var input: [domain.len + @sizeOf(u64)]u8 = undefined;
    @memcpy(input[0..domain.len], domain);
    std.mem.writeInt(u64, input[domain.len..][0..@sizeOf(u64)], sid, .big);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&input, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Write the shortest unambiguous display handle (at least eight characters)
/// into `buf`. `known` should contain every session in the relevant catalog.
pub fn display(buf: *Full, sid: u64, known: []const u64) []const u8 {
    buf.* = full(sid);
    var len = default_len;
    for (known) |other_sid| {
        if (other_sid == sid) continue;
        const other = full(other_sid);
        const common = commonPrefix(buf, &other);
        if (common >= len) len = @min(common + 1, full_len);
    }
    return buf[0..len];
}

pub const ResolveError = error{
    PrefixTooShort,
    InvalidHandle,
    NotFound,
    Ambiguous,
};

/// Resolve a public handle prefix. Exact legacy decimal ids remain accepted;
/// `@<decimal>` is reserved for Marlin's own lossless reboot handoff.
pub fn resolve(query: []const u8, known: []const u64) ResolveError!u64 {
    if (std.mem.startsWith(u8, query, "@")) {
        return resolveDecimal(query[1..], known) orelse error.InvalidHandle;
    }

    // Exact legacy ids win over a coincidental all-numeric hash prefix.
    if (resolveDecimal(query, known)) |sid| return sid;

    const public_syntax = query.len <= full_len and isHex(query);
    if (public_syntax and query.len >= min_prefix_len) {
        var found: ?u64 = null;
        for (known) |sid| {
            const candidate = full(sid);
            if (!eqlPrefixIgnoreCase(&candidate, query)) continue;
            if (found != null and found.? != sid) return error.Ambiguous;
            found = sid;
        }
        if (found) |sid| return sid;
    }

    if (public_syntax and query.len < min_prefix_len) return error.PrefixTooShort;
    if (!public_syntax) return error.InvalidHandle;
    return error.NotFound;
}

pub fn matchesPrefix(query: []const u8, sid: u64) bool {
    if (query.len < min_prefix_len or query.len > full_len or !isHex(query)) return false;
    const candidate = full(sid);
    return eqlPrefixIgnoreCase(&candidate, query);
}

fn resolveDecimal(query: []const u8, known: []const u64) ?u64 {
    if (query.len == 0) return null;
    const sid = std.fmt.parseInt(u64, query, 10) catch return null;
    for (known) |candidate| {
        if (candidate == sid) return sid;
    }
    return null;
}

fn isHex(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn eqlPrefixIgnoreCase(candidate: *const Full, query: []const u8) bool {
    for (query, 0..) |c, i| {
        if (std.ascii.toLower(c) != candidate[i]) return false;
    }
    return true;
}

fn commonPrefix(a: *const Full, b: *const Full) usize {
    var i: usize = 0;
    while (i < full_len and a[i] == b[i]) : (i += 1) {}
    return i;
}

test "session handles are stable, opaque, and distinct" {
    try std.testing.expectEqualStrings("be4719c63bf340496d2547fd913f84dfa9c1ad54589e9c9ecb922f4588d32d08", &full(42));
    try std.testing.expect(!std.mem.eql(u8, &full(42), &full(43)));
}

test "resolve accepts unique prefixes, uppercase, and legacy decimal ids" {
    const known = [_]u64{ 42, 43, 1_874_397_504_305_914_847 };
    const handle = full(42);
    var upper: [default_len]u8 = undefined;
    for (handle[0..default_len], 0..) |c, i| upper[i] = std.ascii.toUpper(c);

    try std.testing.expectEqual(@as(u64, 42), try resolve(handle[0..min_prefix_len], &known));
    try std.testing.expectEqual(@as(u64, 42), try resolve(&upper, &known));
    try std.testing.expectEqual(@as(u64, 42), try resolve("42", &known));
    try std.testing.expectEqual(@as(u64, 43), try resolve("@43", &known));
    try std.testing.expectError(error.PrefixTooShort, resolve("abc", &known));
    try std.testing.expectError(error.InvalidHandle, resolve("nope", &known));
    try std.testing.expectError(error.NotFound, resolve("ffffffff", &known));
}

test "ambiguous prefixes are rejected and display handles extend" {
    // This deterministic pair shares `71dbabd7` and differs at character 9.
    const display_known = [_]u64{ 62_757, 64_176 };
    const handle = full(display_known[0]);
    try std.testing.expectEqualStrings("71dbabd7", handle[0..default_len]);
    try std.testing.expectError(error.Ambiguous, resolve(handle[0..4], &display_known));
    try std.testing.expectError(error.Ambiguous, resolve(handle[0..default_len], &display_known));
    var buf: Full = undefined;
    try std.testing.expectEqual(@as(usize, default_len + 1), display(&buf, display_known[0], &display_known).len);
}
