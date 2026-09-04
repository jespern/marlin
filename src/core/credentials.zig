//! Credentials: ~/.config/marlin/credentials — KEY=value lines, chmod 600.
//!
//! Until TOML config lands (M4) this is the only config file marlin writes.
//! Precedence: real environment ALWAYS wins; the file only fills gaps.
//! The daemon loads it at startup into its Environ.Map copy; `marlin
//! bootstrap` (and the TUI first-run prompt) writes it.

const std = @import("std");
const Io = std.Io;

pub const cred_keys = [_][]const u8{
    "OPENROUTER_API_KEY",
    "AI_GATEWAY_API_KEY",
    "ANTHROPIC_API_KEY",
    "LITELLM_API_KEY",
    "MARLIN_LOCAL_BASE_URL",
    "MARLIN_LOCAL_API_KEY",
};

/// Credentials may name custom-provider secrets, but the file must never
/// become a general-purpose environment injection mechanism. This mirrors
/// the daemon's secret boundary and config provider validation.
pub fn allowedKey(name: []const u8) bool {
    for (cred_keys) |known| if (std.mem.eql(u8, known, name)) return true;
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    return startsWithIgnoreCase(name, "AWS_") or
        endsWithIgnoreCase(name, "_API_KEY") or
        endsWithIgnoreCase(name, "_TOKEN") or
        endsWithIgnoreCase(name, "_SECRET");
}

/// Resolve ~/.config/marlin (respecting XDG_CONFIG_HOME). Caller frees.
pub fn configDir(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_CONFIG_HOME")) |x| {
        if (x.len > 0) return std.fs.path.join(gpa, &.{ x, "marlin" });
    }
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".config", "marlin" });
}

pub fn credentialsPath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const dir = try configDir(gpa, environ);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "credentials" });
}

/// Load the credentials file into `environ` for keys not already set.
/// Missing file is fine. Malformed lines are skipped.
pub fn loadInto(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
) !void {
    const path = try credentialsPath(gpa, environ);
    defer gpa.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(bytes);

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t\"");
        if (key.len == 0 or val.len == 0) continue;
        // Only known keys (this file is not a general env mechanism), and
        // the real environment always wins.
        if (!allowedKey(key)) continue;
        if (environ.get(key)) |existing| {
            if (existing.len > 0) continue;
        }
        // Environ.Map.put does not copy; dupe with the MAP's allocator so
        // lifetime matches the map, not our transient gpa scope.
        try environ.put(try environ.allocator.dupe(u8, key), try environ.allocator.dupe(u8, val));
    }
}

/// Append-or-replace `key=value` in the credentials file; creates the file
/// (and dir) with 0600 when missing.
pub fn store(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    key: []const u8,
    value: []const u8,
) !void {
    if (!allowedKey(key)) return error.UnsupportedCredentialName;
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\r\n\x00") != null)
        return error.InvalidCredentialValue;
    const dir_path = try configDir(gpa, environ);
    defer gpa.free(dir_path);
    Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    const path = try credentialsPath(gpa, environ);
    defer gpa.free(path);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const existing = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch null;
    defer if (existing) |e| gpa.free(e);

    var replaced = false;
    if (existing) |bytes| {
        var it = std.mem.splitScalar(u8, bytes, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=');
            const line_key = if (eq) |e| std.mem.trim(u8, line[0..e], " \t") else "";
            if (eq != null and std.mem.eql(u8, line_key, key)) {
                try out.print(gpa, "{s}={s}\n", .{ key, value });
                replaced = true;
            } else {
                try out.print(gpa, "{s}\n", .{line});
            }
        }
    }
    if (!replaced) try out.print(gpa, "{s}={s}\n", .{ key, value });

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    chmod600(path);
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn chmod600(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.c.chmod(buf[0..path.len :0], 0o600);
}

// ---------------------------------------------------------------- tests --
