//! Read repository/branch metadata directly. Git only computes divergence
//! after relevant metadata changes; steady-state polling never spawns it.
const std = @import("std");
const process_io = @import("process_io.zig");
const Io = std.Io;

pub const ttl_ms = 5_000;
pub const Counts = struct { ahead: u64, behind: u64 };
pub const Snapshot = struct {
    branch_buf: [1024]u8 = undefined,
    branch_len: usize = 0,
    counts: ?Counts = null,
    origin_buf: [2048]u8 = undefined,
    origin_len: usize = 0,
    // NUL-separated effective config paths, including conditional includes.
    config_buf: [8192]u8 = undefined,
    config_len: usize = 0,
    metadata: ?u64 = null,

    pub fn branch(self: *const Snapshot) []const u8 {
        return self.branch_buf[0..self.branch_len];
    }

    fn origin(self: *const Snapshot) []const u8 {
        return self.origin_buf[0..self.origin_len];
    }
};

const Repository = struct { git: []const u8, common: []const u8 };

pub fn probe(gpa: std.mem.Allocator, io: Io, cwd: []const u8, environ: *const std.process.Environ.Map, cancel: *const std.atomic.Value(bool), previous: ?Snapshot) Snapshot {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();
    const repo = discover(alloc, io, cwd) orelse return .{};
    const head = read(alloc, io, repo.git, "HEAD", 4096) orelse return .{};
    var snapshot: Snapshot = .{};
    if (objectId(head)) {
        const label = std.fmt.bufPrint(&snapshot.branch_buf, "detached {s}", .{head[0..7]}) catch return .{};
        snapshot.branch_len = label.len;
        return snapshot;
    }
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, head, prefix)) return .{};
    const branch = head[prefix.len..];
    if (branch.len == 0 or branch.len > snapshot.branch_buf.len or !validRef(head[5..])) return .{};
    snapshot.branch_len = branch.len;
    @memcpy(snapshot.branch_buf[0..branch.len], branch);
    if (previous) |old| {
        if (std.mem.eql(u8, branch, old.branch())) {
            snapshot.origin_buf = old.origin_buf;
            snapshot.origin_len = old.origin_len;
            snapshot.config_buf = old.config_buf;
            snapshot.config_len = old.config_len;
            const key = fingerprint(alloc, io, repo, head, environ, &snapshot);
            if (key != null and key == old.metadata) return old;
        }
    }

    // Only the change path launches Git. It understands upstream mapping and
    // commit storage (packs, shallow repositories, reftables, etc.).
    var env = std.process.Environ.Map.init(alloc);
    var it = environ.iterator();
    while (it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.key_ptr.*, "GIT_"))
            env.put(entry.key_ptr.*, entry.value_ptr.*) catch return snapshot;
    }
    env.put("GIT_OPTIONAL_LOCKS", "0") catch return snapshot;
    env.put("GIT_NO_LAZY_FETCH", "1") catch return snapshot;
    const upstream = run(alloc, io, cwd, &env, cancel, &.{ "git", "for-each-ref", "--format=%(upstream)", head[5..] }) orelse "";
    const origin = if (std.mem.startsWith(u8, upstream, "refs/remotes/origin/") and validRef(upstream)) upstream else std.fmt.allocPrint(alloc, "refs/remotes/origin/{s}", .{branch}) catch return snapshot;
    if (origin.len > snapshot.origin_buf.len) return snapshot;
    @memcpy(snapshot.origin_buf[0..origin.len], origin);
    snapshot.origin_len = origin.len;
    snapshot.config_len = 0;
    if (run(alloc, io, cwd, &env, cancel, &.{ "git", "config", "--null", "--show-origin", "--list" })) |configs|
        rememberConfigs(alloc, cwd, environ, configs, &snapshot);

    // Capture before the graph walk. If refs change during it, the next poll
    // sees a different fingerprint and recomputes instead of caching stale counts.
    snapshot.metadata = fingerprint(alloc, io, repo, head, environ, &snapshot);
    const range = std.fmt.allocPrint(alloc, "HEAD...{s}", .{origin}) catch return snapshot;
    const counts = run(alloc, io, cwd, &env, cancel, &.{ "git", "rev-list", "--left-right", "--count", range, "--" }) orelse return snapshot;
    var cols = std.mem.tokenizeAny(u8, counts, " \t\r\n");
    const ahead = std.fmt.parseInt(u64, cols.next() orelse return snapshot, 10) catch return snapshot;
    const behind = std.fmt.parseInt(u64, cols.next() orelse return snapshot, 10) catch return snapshot;
    snapshot.counts = .{ .ahead = ahead, .behind = behind };
    return snapshot;
}

fn read(alloc: std.mem.Allocator, io: Io, base: []const u8, name: []const u8, limit: usize) ?[]const u8 {
    const path = std.fs.path.join(alloc, &.{ base, name }) catch return null;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(limit)) catch return null;
    return std.mem.trim(u8, bytes, " \t\r\n");
}

fn discover(alloc: std.mem.Allocator, io: Io, cwd: []const u8) ?Repository {
    var dir: []const u8 = Io.Dir.realPathFileAbsoluteAlloc(io, cwd, alloc) catch return null;
    while (true) {
        const marker = std.fs.path.join(alloc, &.{ dir, ".git" }) catch return null;
        if (Io.Dir.cwd().statFile(io, marker, .{})) |st| {
            const git = if (st.kind == .directory) marker else blk: {
                const pointer = read(alloc, io, dir, ".git", 4096) orelse return null;
                if (!std.mem.startsWith(u8, pointer, "gitdir: ")) return null;
                break :blk std.fs.path.resolve(alloc, &.{ dir, pointer[8..] }) catch return null;
            };
            return repository(alloc, io, git);
        } else |_| {}
        if (repository(alloc, io, dir)) |repo| return repo; // bare repository
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

fn repository(alloc: std.mem.Allocator, io: Io, git: []const u8) ?Repository {
    const head = read(alloc, io, git, "HEAD", 4096) orelse return null;
    if (!objectId(head) and !(std.mem.startsWith(u8, head, "ref: ") and validRef(head[5..]))) return null;
    const common = if (read(alloc, io, git, "commondir", 4096)) |relative|
        std.fs.path.resolve(alloc, &.{ git, relative }) catch return null
    else
        git;
    const objects = std.fs.path.join(alloc, &.{ common, "objects" }) catch return null;
    const st = Io.Dir.cwd().statFile(io, objects, .{}) catch return null;
    if (st.kind != .directory) return null;
    return .{ .git = git, .common = common };
}

fn objectId(text: []const u8) bool {
    if (text.len != 40 and text.len != 64) return false;
    for (text) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

fn validRef(ref: []const u8) bool {
    if (!std.mem.startsWith(u8, ref, "refs/") or std.mem.indexOf(u8, ref, "..") != null) return false;
    for (ref) |c| if (c <= ' ' or c == 127 or c == '\\') return false;
    return true;
}

fn fingerprint(alloc: std.mem.Allocator, io: Io, repo: Repository, head: []const u8, env: *const std.process.Environ.Map, snapshot: *const Snapshot) ?u64 {
    var hash = std.hash.Wyhash.init(0);
    hash.update(repo.git);
    hash.update(repo.common);
    hash.update(head);
    // Loose refs override packed refs. Symbolic ref chains are followed with
    // a fixed bound; packed-refs and reftable changes invalidate globally.
    for ([_][]const u8{ head[5..], snapshot.origin() }) |ref| {
        if (ref.len == 0) continue;
        var current = ref;
        for (0..8) |_| {
            const path = std.fs.path.join(alloc, &.{ repo.common, current }) catch return null;
            stamp(io, &hash, path);
            const value = read(alloc, io, repo.common, current, 4096) orelse break;
            if (!std.mem.startsWith(u8, value, "ref: ") or !validRef(value[5..])) break;
            current = value[5..];
        }
    }
    for ([_][]const u8{ "packed-refs", "reftable/tables.list", "config", "shallow", "info/grafts", "refs/replace" }) |name| {
        stamp(io, &hash, std.fs.path.join(alloc, &.{ repo.common, name }) catch return null);
    }
    stamp(io, &hash, std.fs.path.join(alloc, &.{ repo.git, "config.worktree" }) catch return null);
    if (env.get("HOME")) |home| {
        stamp(io, &hash, std.fs.path.join(alloc, &.{ home, ".gitconfig" }) catch return null);
        const xdg = env.get("XDG_CONFIG_HOME") orelse (std.fs.path.join(alloc, &.{ home, ".config" }) catch return null);
        stamp(io, &hash, std.fs.path.join(alloc, &.{ xdg, "git/config" }) catch return null);
    }
    stamp(io, &hash, "/etc/gitconfig");
    var paths = std.mem.tokenizeScalar(u8, snapshot.config_buf[0..snapshot.config_len], 0);
    while (paths.next()) |path| stamp(io, &hash, path);
    return hash.final();
}

fn stamp(io: Io, hash: *std.hash.Wyhash, path: []const u8) void {
    hash.update(path);
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch {
        hash.update("missing");
        return;
    };
    hash.update(std.mem.asBytes(&stat.inode));
    hash.update(std.mem.asBytes(&stat.size));
    // Timestamp uses i96, whose in-memory representation has padding.
    // Widen before hashing so uninitialized padding cannot invalidate a cache.
    const mtime: i128 = stat.mtime.nanoseconds;
    const ctime: i128 = stat.ctime.nanoseconds;
    hash.update(std.mem.asBytes(&mtime));
    hash.update(std.mem.asBytes(&ctime));
}

fn rememberConfigs(alloc: std.mem.Allocator, cwd: []const u8, env: *const std.process.Environ.Map, configs: []const u8, snapshot: *Snapshot) void {
    var entries = std.mem.splitScalar(u8, configs, 0);
    while (entries.next()) |origin| {
        const entry = entries.next() orelse break;
        if (!std.mem.startsWith(u8, origin, "file:")) continue;
        const path = std.fs.path.resolve(alloc, &.{ cwd, origin[5..] }) catch continue;
        rememberPath(snapshot, path);
        const newline = std.mem.indexOfScalar(u8, entry, '\n') orelse continue;
        const key = entry[0..newline];
        if (!std.mem.eql(u8, key, "include.path") and !(std.mem.startsWith(u8, key, "includeif.") and std.mem.endsWith(u8, key, ".path"))) continue;
        const value = entry[newline + 1 ..];
        const included = if (std.mem.startsWith(u8, value, "~/"))
            std.fs.path.join(alloc, &.{ env.get("HOME") orelse continue, value[2..] }) catch continue
        else
            std.fs.path.resolve(alloc, &.{ std.fs.path.dirname(path) orelse continue, value }) catch continue;
        rememberPath(snapshot, included);
    }
}

fn rememberPath(snapshot: *Snapshot, path: []const u8) void {
    var paths = std.mem.tokenizeScalar(u8, snapshot.config_buf[0..snapshot.config_len], 0);
    while (paths.next()) |existing| if (std.mem.eql(u8, existing, path)) return;
    if (path.len + 1 > snapshot.config_buf.len - snapshot.config_len) return;
    @memcpy(snapshot.config_buf[snapshot.config_len..][0..path.len], path);
    snapshot.config_len += path.len;
    snapshot.config_buf[snapshot.config_len] = 0;
    snapshot.config_len += 1;
}

fn run(gpa: std.mem.Allocator, io: Io, cwd: []const u8, env: *const std.process.Environ.Map, cancel: *const std.atomic.Value(bool), argv: []const []const u8) ?[]const u8 {
    if (cancel.load(.acquire)) return null;
    const result = process_io.run(gpa, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .stdout_limit = 64 * 1024,
        .stderr_limit = 4096,
        .timeout_ms = 300,
        .cancel = cancel,
    }) catch return null;
    if (result.timed_out or result.term != .exited or result.term.exited != 0) return null;
    return std.mem.trim(u8, result.stdout, "\r\n");
}
