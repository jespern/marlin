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
    "MARLIN_LOCAL_BASE_URL",
    "MARLIN_LOCAL_API_KEY",
};

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
        var known = false;
        for (cred_keys) |k| {
            if (std.mem.eql(u8, k, key)) known = true;
        }
        if (!known) continue;
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

fn chmod600(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = std.c.chmod(buf[0..path.len :0], 0o600);
}

// ---------------------------------------------------------------- tests --

test "store then load round trip, env wins" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const tmp = try std.fmt.allocPrint(gpa, "/tmp/marlin-cred-{x}", .{std.mem.readInt(u64, &rand, .little)});
    defer gpa.free(tmp);
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(arena);
    try env.put("XDG_CONFIG_HOME", tmp);

    try store(arena, io, &env, "OPENROUTER_API_KEY", "sk-test-123");
    try store(arena, io, &env, "OPENROUTER_API_KEY", "sk-test-456"); // replace
    try loadInto(arena, io, &env);
    try std.testing.expectEqualStrings("sk-test-456", env.get("OPENROUTER_API_KEY").?);

    // Env wins over file.
    var env2 = std.process.Environ.Map.init(arena);
    try env2.put("XDG_CONFIG_HOME", tmp);
    try env2.put("OPENROUTER_API_KEY", "from-env");
    try loadInto(arena, io, &env2);
    try std.testing.expectEqualStrings("from-env", env2.get("OPENROUTER_API_KEY").?);
}
