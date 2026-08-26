//! Search tools: grep (ripgrep, then system grep, then internal fallback) and
//! glob (recursive walker + pattern match). Both parallel_safe.

const std = @import("std");
const Io = std.Io;
const regex_mod = @import("regex");

const files = @import("files.zig");
const permissions = @import("../permissions.zig");
const process_io = @import("../process_io.zig");

fn cancelled(flag: ?*const std.atomic.Value(bool)) bool {
    return if (flag) |f| f.load(.acquire) else false;
}

// ------------------------------------------------------------------ grep --

pub const grep_spec_name = "grep";
pub const grep_spec_description =
    "Search file contents for a regex pattern. Returns matching " ++
    "lines as 'path:line:content'. Searches the given directory recursively " ++
    "(default: session cwd).";
pub const grep_spec_schema =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"file or directory to search (default: cwd)"},"glob":{"type":"string","description":"only search files matching this glob, e.g. *.zig"},"limit":{"type":"integer","minimum":1}},"required":["pattern"]}
;

pub const GrepArgs = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
    glob: ?[]const u8 = null,
    limit: u64 = 100,
};

pub const max_output_bytes: usize = 2 * 1024 * 1024;

pub fn grep(
    gpa: std.mem.Allocator,
    io: Io,
    args: GrepArgs,
    cwd: []const u8,
    child_environ: ?*const std.process.Environ.Map,
    cancel: ?*const std.atomic.Value(bool),
) ![]u8 {
    if (cancelled(cancel)) return error.Cancelled;
    const search_path = try files.resolvePath(gpa, args.path orelse ".", cwd);
    defer gpa.free(search_path);

    // Protected-path refusal (ARCHITECTURE §7): searching credential
    // material directly is refused as data; matches from protected files
    // inside an ordinary tree are filtered out below (see capLines).
    if (try files.protectedReadRefusal(gpa, io, search_path, args.path orelse ".")) |refusal| return refusal;

    // ripgrep is the ideal path. A platform grep is still orders of magnitude
    // faster than interpreting a regex once per line, and is present on every
    // currently supported Marlin target. Keep the native walker as the final
    // dependency-free fallback for minimal environments.
    if (try rgAvailable(gpa, io, child_environ, cancel)) return rgGrep(gpa, io, args, search_path, child_environ, cancel);
    if (try systemGrepAvailable(gpa, io, child_environ, cancel)) {
        return systemGrep(gpa, io, args, search_path, child_environ, cancel) catch |err| switch (err) {
            error.Cancelled => return err,
            else => internalGrep(gpa, io, args, search_path, cancel),
        };
    }
    return internalGrep(gpa, io, args, search_path, cancel);
}

var rg_checked = std.atomic.Value(u8).init(0); // 0=unknown 1=yes 2=no
var system_grep_checked = std.atomic.Value(u8).init(0);

fn rgAvailable(
    gpa: std.mem.Allocator,
    io: Io,
    child_environ: ?*const std.process.Environ.Map,
    cancel: ?*const std.atomic.Value(bool),
) !bool {
    if (cancelled(cancel)) return error.Cancelled;
    switch (rg_checked.load(.acquire)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    const res = process_io.run(gpa, io, .{
        .argv = &.{ "rg", "--version" },
        .environ_map = child_environ,
        .stdout_limit = 4096,
        .stderr_limit = 4096,
        .timeout_ms = 2_000,
        .cancel = cancel,
    }) catch |err| {
        if (err == error.Cancelled) return err;
        rg_checked.store(2, .release);
        return false;
    };
    defer res.deinit(gpa);
    const ok = res.term == .exited and res.term.exited == 0;
    rg_checked.store(if (ok) 1 else 2, .release);
    return ok;
}

fn systemGrepAvailable(
    gpa: std.mem.Allocator,
    io: Io,
    child_environ: ?*const std.process.Environ.Map,
    cancel: ?*const std.atomic.Value(bool),
) !bool {
    if (cancelled(cancel)) return error.Cancelled;
    switch (system_grep_checked.load(.acquire)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    const res = process_io.run(gpa, io, .{
        .argv = &.{ "grep", "--version" },
        .environ_map = child_environ,
        .stdout_limit = 4096,
        .stderr_limit = 4096,
        .timeout_ms = 2_000,
        .cancel = cancel,
    }) catch |err| {
        if (err == error.Cancelled) return err;
        system_grep_checked.store(2, .release);
        return false;
    };
    defer res.deinit(gpa);
    const ok = res.term == .exited and res.term.exited == 0;
    system_grep_checked.store(if (ok) 1 else 2, .release);
    return ok;
}

fn rgGrep(
    gpa: std.mem.Allocator,
    io: Io,
    args: GrepArgs,
    search_path: []const u8,
    child_environ: ?*const std.process.Environ.Map,
    cancel: ?*const std.atomic.Value(bool),
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "rg", "--line-number", "--no-heading", "--color=never", "--max-count=1000" });
    if (args.glob) |g| {
        try argv.append(gpa, "--glob");
        try argv.append(gpa, g);
    }
    try argv.append(gpa, "--");
    try argv.append(gpa, args.pattern);
    try argv.append(gpa, search_path);

    const res = process_io.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = child_environ,
        .stdout_limit = max_output_bytes,
        .stderr_limit = 64 * 1024,
        .timeout_ms = null,
        .cancel = cancel,
    }) catch |e| {
        if (e == error.Cancelled) return e;
        return std.fmt.allocPrint(gpa, "error: failed to run rg: {t}", .{e});
    };
    defer res.deinit(gpa);

    const code: i64 = switch (res.term) {
        .exited => |cd| cd,
        else => -1,
    };
    if (code == 1) return gpa.dupe(u8, "no matches");
    if (code != 0) {
        return std.fmt.allocPrint(gpa, "error: rg failed: {s}", .{res.stderr[0..@min(res.stderr.len, 1000)]});
    }
    return capLines(gpa, res.stdout, args.limit);
}

/// Fast fallback for supported Unix targets. GNU and BSD grep both support
/// these options; explicit excludes approximate rg's ignore behavior without
/// making the last-resort Zig walker pay the regex-engine cost.
fn systemGrep(
    gpa: std.mem.Allocator,
    io: Io,
    args: GrepArgs,
    search_path: []const u8,
    child_environ: ?*const std.process.Environ.Map,
    cancel: ?*const std.atomic.Value(bool),
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{
        "grep",                "-R",                         "-n",                       "-I",                    "-E",
        "--exclude-dir=.git",  "--exclude-dir=node_modules", "--exclude-dir=.zig-cache", "--exclude-dir=zig-out", "--exclude-dir=target",
        "--exclude-dir=.venv", "--exclude-dir=__pycache__",  "--exclude-dir=.cache",     "--exclude=*.sock",
    });

    var include_arg: ?[]u8 = null;
    defer if (include_arg) |value| gpa.free(value);
    if (args.glob) |glob_pattern| {
        include_arg = try std.fmt.allocPrint(gpa, "--include={s}", .{glob_pattern});
        try argv.append(gpa, include_arg.?);
    }
    try argv.append(gpa, "--");
    try argv.append(gpa, args.pattern);
    try argv.append(gpa, search_path);

    const res = try process_io.run(gpa, io, .{
        .argv = argv.items,
        .environ_map = child_environ,
        .stdout_limit = max_output_bytes,
        .stderr_limit = 64 * 1024,
        .timeout_ms = null,
        .cancel = cancel,
    });
    defer res.deinit(gpa);

    const code: i64 = switch (res.term) {
        .exited => |exit_code| exit_code,
        else => -1,
    };
    if (code == 1) return gpa.dupe(u8, "no matches");
    // BSD grep reports traversal oddities (notably Unix sockets) as exit 2.
    // Let the caller fall through to the native file-only walker rather than
    // turning an irrelevant filesystem entry into a failed tool call.
    if (code != 0) return error.SystemGrepFailed;
    return capLines(gpa, res.stdout, args.limit);
}

/// Internal fallback: recursive walk + regex match (zig-regex engine).
/// Feature-parity goal with the rg path: real regex, skip list for bulky
/// dirs (rg gets this from .gitignore), binary sniff, same output format.
/// A pattern the engine cannot compile degrades to literal substring with
/// an explicit note — tool errors are data.
fn internalGrep(
    gpa: std.mem.Allocator,
    io: Io,
    args: GrepArgs,
    search_path: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) ![]u8 {
    if (cancelled(cancel)) return error.Cancelled;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var matches: u64 = 0;

    // Literal search (including `foo|bar|baz`) is both the common agent case
    // and dramatically faster than invoking zig-regex for every line.
    var literal_set = try LiteralSet.parse(gpa, args.pattern);
    defer if (literal_set) |*set| set.deinit(gpa);
    var compiled: ?regex_mod.Regex = if (literal_set == null)
        regex_mod.Regex.compile(gpa, args.pattern) catch null
    else
        null;
    defer if (compiled) |*r| r.deinit();
    if (compiled == null and looksLikeRegex(args.pattern)) {
        try out.appendSlice(gpa, "note: pattern did not compile as regex; matched as a LITERAL substring instead.\n");
    }
    const matcher = Matcher{
        .re = if (compiled) |*r| r else null,
        .literals = if (literal_set) |*set| set.items.items else null,
        .literal_fallback = args.pattern,
    };

    // Single file?
    const stat = Io.Dir.cwd().statFile(io, search_path, .{}) catch |e| {
        out.deinit(gpa);
        return std.fmt.allocPrint(gpa, "error: cannot access '{s}': {t}", .{ search_path, e });
    };
    if (stat.kind == .file) {
        try grepOneFile(gpa, io, &out, &matches, matcher, args.limit, search_path, search_path, cancel);
    } else {
        var dir = Io.Dir.cwd().openDir(io, search_path, .{ .iterate = true }) catch |e| {
            out.deinit(gpa);
            return std.fmt.allocPrint(gpa, "error: cannot open '{s}': {t}", .{ search_path, e });
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (cancelled(cancel)) return error.Cancelled;
            if (matches >= args.limit) break;
            if (entry.kind != .file) continue;
            if (skipPath(entry.path)) continue;
            if (permissions.isProtectedPath(entry.path)) continue;
            if (args.glob) |g| {
                if (!try globMatchAlloc(gpa, g, std.fs.path.basename(entry.path), cancel)) continue;
            }
            const full = try std.fs.path.join(gpa, &.{ search_path, entry.path });
            defer gpa.free(full);
            grepOneFile(gpa, io, &out, &matches, matcher, args.limit, full, entry.path, cancel) catch |err| switch (err) {
                error.Cancelled => return err,
                else => continue,
            };
        }
    }
    if (matches == 0) {
        out.deinit(gpa);
        return gpa.dupe(u8, "no matches");
    }
    return out.toOwnedSlice(gpa);
}

/// Line matcher: compiled regex when available, literal substring otherwise.
const Matcher = struct {
    re: ?*regex_mod.Regex,
    literals: ?[]const []const u8,
    literal_fallback: []const u8,

    fn matches(self: Matcher, gpa: std.mem.Allocator, line: []const u8) bool {
        if (self.literals) |alternatives| {
            for (alternatives) |literal| {
                if (std.mem.indexOf(u8, line, literal) != null) return true;
            }
            return false;
        }
        if (self.re) |r| {
            const m = r.find(line) catch return false;
            if (m) |found| {
                var mut = found;
                mut.deinit(gpa);
                return true;
            }
            return false;
        }
        return std.mem.indexOf(u8, line, self.literal_fallback) != null;
    }
};

/// Recognize the regex subset that dominates source searches: literals and
/// top-level literal alternatives. Escaped punctuation is unescaped; regex
/// classes/operators and semantic escapes fall through to the regex engine.
const LiteralSet = struct {
    items: std.ArrayList([]u8) = .empty,

    fn parse(gpa: std.mem.Allocator, pattern: []const u8) !?LiteralSet {
        var set = LiteralSet{};
        errdefer set.deinit(gpa);
        var current: std.ArrayList(u8) = .empty;
        defer current.deinit(gpa);

        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            const byte = pattern[i];
            if (byte == '|') {
                try set.appendCurrent(gpa, &current);
                continue;
            }
            if (byte == '\\') {
                if (i + 1 >= pattern.len) {
                    set.deinit(gpa);
                    return null;
                }
                const escaped = pattern[i + 1];
                if (std.mem.indexOfScalar(u8, ".[](){}^$|+*?\\", escaped) == null) {
                    set.deinit(gpa);
                    return null;
                }
                try current.append(gpa, escaped);
                i += 1;
                continue;
            }
            if (std.mem.indexOfScalar(u8, ".[](){}^$+*?", byte) != null) {
                set.deinit(gpa);
                return null;
            }
            try current.append(gpa, byte);
        }
        try set.appendCurrent(gpa, &current);
        return set;
    }

    fn appendCurrent(self: *LiteralSet, gpa: std.mem.Allocator, current: *std.ArrayList(u8)) !void {
        const owned = try current.toOwnedSlice(gpa);
        errdefer gpa.free(owned);
        try self.items.append(gpa, owned);
    }

    fn deinit(self: *LiteralSet, gpa: std.mem.Allocator) void {
        for (self.items.items) |item| gpa.free(item);
        self.items.deinit(gpa);
    }
};

fn grepOneFile(
    gpa: std.mem.Allocator,
    io: Io,
    out: *std.ArrayList(u8),
    matches: *u64,
    matcher: Matcher,
    limit: u64,
    full_path: []const u8,
    display_path: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !void {
    if (cancelled(cancel)) return error.Cancelled;
    const contents = Io.Dir.cwd().readFileAlloc(io, full_path, gpa, .limited(files.max_read_bytes)) catch return;
    defer gpa.free(contents);
    if (std.mem.indexOfScalar(u8, contents[0..@min(contents.len, 4096)], 0) != null) return; // binary

    var line_no: u64 = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (cancelled(cancel)) return error.Cancelled;
        line_no += 1;
        if (matches.* >= limit) return;
        if (!matcher.matches(gpa, line)) continue;
        matches.* += 1;
        const entry = try std.fmt.allocPrint(gpa, "{s}:{d}:{s}\n", .{ display_path, line_no, line });
        defer gpa.free(entry);
        try out.appendSlice(gpa, entry);
    }
}

fn skipPath(path: []const u8) bool {
    const skip_dirs = [_][]const u8{
        ".git/",        "node_modules/", ".zig-cache/", "zig-out/",
        ".hg/",         ".svn/",         "target/",     ".venv/",
        "__pycache__/", ".cache/",
    };
    for (skip_dirs) |d| {
        if (std.mem.startsWith(u8, path, d) or std.mem.indexOf(u8, path, "/") != null and std.mem.indexOf(u8, path, d) != null) return true;
    }
    return false;
}

/// Heuristic: does the pattern contain regex metacharacters that the literal
/// fallback cannot honor? (Used only to warn the model, never to reject.)
fn looksLikeRegex(pattern: []const u8) bool {
    for (pattern) |ch| switch (ch) {
        '\\', '[', ']', '(', ')', '{', '}', '^', '$', '|', '+', '*', '?', '.' => return true,
        else => {},
    };
    return false;
}

fn capLines(gpa: std.mem.Allocator, text: []const u8, limit: u64) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n: u64 = 0;
    var hidden: u64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // rg/system grep have no protected-path concept; both funnel their
        // "path:line:content" output through here, so filter matches from
        // protected files (a .env in an ordinary tree) at the choke point.
        if (lineFromProtectedFile(line)) {
            hidden += 1;
            continue;
        }
        if (n >= limit) {
            try out.appendSlice(gpa, "[... more matches truncated; refine the pattern ...]\n");
            break;
        }
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
        n += 1;
    }
    if (hidden > 0) {
        var note_buf: [96]u8 = undefined;
        const note = std.fmt.bufPrint(
            &note_buf,
            "[{d} matches in protected files hidden; see docs/PERMISSIONS.md]\n",
            .{hidden},
        ) catch unreachable;
        try out.appendSlice(gpa, note);
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return gpa.dupe(u8, "no matches");
    }
    return out.toOwnedSlice(gpa);
}

/// True when a "path:line:content" result line names a protected file.
fn lineFromProtectedFile(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    return permissions.isProtectedPath(line[0..colon]);
}

// ------------------------------------------------------------------ glob --

pub const glob_spec_name = "glob";
pub const glob_spec_description =
    "Find files by name pattern (e.g. '*.zig', 'src/**/*.json'). Returns matching " ++
    "paths relative to the search directory, sorted by modification time (newest first).";
pub const glob_spec_schema =
    \\{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string","description":"directory to search (default: cwd)"},"limit":{"type":"integer","minimum":1}},"required":["pattern"]}
;

pub const GlobArgs = struct {
    pattern: []const u8,
    path: ?[]const u8 = null,
    limit: u64 = 200,
};

pub fn glob(
    gpa: std.mem.Allocator,
    io: Io,
    args: GlobArgs,
    cwd: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) ![]u8 {
    if (cancelled(cancel)) return error.Cancelled;
    const search_path = try files.resolvePath(gpa, args.path orelse ".", cwd);
    defer gpa.free(search_path);

    var dir = Io.Dir.cwd().openDir(io, search_path, .{ .iterate = true }) catch |e| {
        return std.fmt.allocPrint(gpa, "error: cannot open '{s}': {t}", .{ search_path, e });
    };
    defer dir.close(io);

    const Hit = struct { path: []u8, mtime: i128 };
    var hits: std.ArrayList(Hit) = .empty;
    defer {
        for (hits.items) |h| gpa.free(h.path);
        hits.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (walker.next(io) catch null) |entry| {
        if (cancelled(cancel)) return error.Cancelled;
        if (entry.kind != .file) continue;
        if (skipPath(entry.path)) continue;
        const target = if (std.mem.indexOfScalar(u8, args.pattern, '/') != null)
            entry.path
        else
            std.fs.path.basename(entry.path);
        if (!try globMatchAlloc(gpa, args.pattern, target, cancel)) continue;
        const st = dir.statFile(io, entry.path, .{}) catch continue;
        try hits.append(gpa, .{ .path = try gpa.dupe(u8, entry.path), .mtime = st.mtime.nanoseconds });
        if (hits.items.len >= 5000) break; // hard safety cap pre-sort
    }

    if (hits.items.len == 0) return gpa.dupe(u8, "no files match");

    std.mem.sort(Hit, hits.items, {}, struct {
        fn newerFirst(_: void, a: Hit, b: Hit) bool {
            return a.mtime > b.mtime;
        }
    }.newerFirst);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (hits.items, 0..) |h, i| {
        if (i >= args.limit) {
            try out.appendSlice(gpa, "[... more files truncated ...]\n");
            break;
        }
        try out.appendSlice(gpa, h.path);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// Glob matcher: *, ?, ** (across separators). The allocator-backed engine
/// is O(pattern * path), avoiding the recursive/exponential `**` backtracking
/// that used to make a malicious pattern effectively uninterruptible.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return globMatchAlloc(std.heap.page_allocator, pattern, name, null) catch false;
}

fn globMatchAlloc(
    gpa: std.mem.Allocator,
    pat: []const u8,
    str: []const u8,
    cancel: ?*const std.atomic.Value(bool),
) !bool {
    var current = try gpa.alloc(bool, str.len + 1);
    defer gpa.free(current);
    var next = try gpa.alloc(bool, str.len + 1);
    defer gpa.free(next);
    @memset(current, false);
    current[0] = true;

    var p: usize = 0;
    var work: usize = 0;
    while (p < pat.len) {
        if (cancelled(cancel)) return error.Cancelled;
        @memset(next, false);
        if (pat[p] == '*' and p + 1 < pat.len and pat[p + 1] == '*') {
            if (p + 2 < pat.len and pat[p + 2] == '/') {
                // `**/` consumes zero path segments, or a prefix ending in
                // '/'. Treating the slash as part of this token is what lets
                // src/**/*.zig also match src/main.zig.
                for (current, 0..) |reachable, start| {
                    if (!reachable) continue;
                    next[start] = true;
                    var end = start;
                    while (end < str.len) {
                        end += 1;
                        if (str[end - 1] == '/') next[end] = true;
                        work += 1;
                        if (work & 0x3ff == 0 and cancelled(cancel)) return error.Cancelled;
                    }
                }
                p += 3;
            } else {
                // Bare `**` may consume any byte, including separators.
                var reachable = false;
                for (current, 0..) |value, i| {
                    reachable = reachable or value;
                    next[i] = reachable;
                }
                p += 2;
            }
        } else if (pat[p] == '*') {
            // A single star cannot cross a path separator.
            for (current, 0..) |reachable, start| {
                if (!reachable) continue;
                next[start] = true;
                var end = start;
                while (end < str.len and str[end] != '/') {
                    end += 1;
                    next[end] = true;
                    work += 1;
                    if (work & 0x3ff == 0 and cancelled(cancel)) return error.Cancelled;
                }
            }
            p += 1;
        } else {
            const token = pat[p];
            for (current[0..str.len], 0..) |reachable, i| {
                if (reachable and (token == str[i] or (token == '?' and str[i] != '/'))) next[i + 1] = true;
            }
            p += 1;
        }
        std.mem.swap([]bool, &current, &next);
    }
    return current[str.len];
}

// ---------------------------------------------------------------- tests --

test "globMatch basics" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(!globMatch("*.zig", "main.zig.bak"));
    try std.testing.expect(globMatch("ma?n.zig", "main.zig"));
    try std.testing.expect(!globMatch("*.zig", "src/main.zig")); // * stops at /
    try std.testing.expect(globMatch("src/**/*.zig", "src/a/b/main.zig"));
    try std.testing.expect(globMatch("src/**/*.zig", "src/main.zig")); // **/ can be empty
    try std.testing.expect(globMatch("**/*.json", "a/b/c.json"));
    try std.testing.expect(globMatch("**/*.json", "c.json"));
    try std.testing.expect(!globMatch("**/*.json", "c.jsonx"));
}

test "globMatch remains bounded for many globstars and observes cancellation" {
    const pattern = "**/**/**/**/**/**/**/**/**/**/missing";
    const path = "a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/a/file";
    try std.testing.expect(!globMatch(pattern, path));

    var cancel: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(
        error.Cancelled,
        globMatchAlloc(std.testing.allocator, pattern, path, &cancel),
    );
}

test "internal grep diagnostic path releases any partial output" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const result = try internalGrep(
        gpa,
        threaded.io(),
        .{ .pattern = "(" },
        "/definitely/not/a/marlin/path",
        null,
    );
    defer gpa.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "cannot access") != null);
}

test "internal grep + glob on a temp tree" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-search-test");
    defer temp.deinit();
    const dir_path = temp.path;

    const w1 = try files.writeFile(gpa, io, .{ .path = "a/one.txt", .content = "hello needle here\nplain line\n" }, dir_path);
    gpa.free(w1);
    const w2 = try files.writeFile(gpa, io, .{ .path = "b/two.log", .content = "no match\n" }, dir_path);
    gpa.free(w2);

    // Force the internal path (don't depend on rg in CI).
    const g = try internalGrep(gpa, io, .{ .pattern = "needle" }, dir_path, null);
    defer gpa.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "one.txt:1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "note:") == null);

    // Real regex works in the internal engine now.
    const gr = try internalGrep(gpa, io, .{ .pattern = "hel+o nee.le" }, dir_path, null);
    defer gpa.free(gr);
    try std.testing.expect(std.mem.indexOf(u8, gr, "one.txt:1:") != null);

    const alternatives = try internalGrep(gpa, io, .{ .pattern = "missing|needle|also-missing" }, dir_path, null);
    defer gpa.free(alternatives);
    try std.testing.expect(std.mem.indexOf(u8, alternatives, "one.txt:1:") != null);

    // Regex that matches nothing really is no matches (not a dialect artifact).
    const gn = try internalGrep(gpa, io, .{ .pattern = "^needle$" }, dir_path, null);
    defer gpa.free(gn);
    try std.testing.expect(std.mem.indexOf(u8, gn, "no matches") != null);

    const gl = try glob(gpa, io, .{ .pattern = "*.txt" }, dir_path, null);
    defer gpa.free(gl);
    try std.testing.expect(std.mem.indexOf(u8, gl, "one.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, gl, "two.log") == null);
}

test {
    std.testing.refAllDecls(@This());
}
