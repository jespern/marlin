//! Search tools: grep (ripgrep subprocess when available, internal fallback)
//! and glob (recursive walker + pattern match). Both parallel_safe.

const std = @import("std");
const Io = std.Io;
const regex_mod = @import("regex");

const files = @import("files.zig");

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

pub fn grep(gpa: std.mem.Allocator, io: Io, args: GrepArgs, cwd: []const u8) ![]u8 {
    const search_path = try files.resolvePath(gpa, args.path orelse ".", cwd);
    defer gpa.free(search_path);

    // Prefer ripgrep when present.
    if (rgAvailable(gpa, io)) return rgGrep(gpa, io, args, search_path);
    return internalGrep(gpa, io, args, search_path);
}

var rg_checked = std.atomic.Value(u8).init(0); // 0=unknown 1=yes 2=no

fn rgAvailable(gpa: std.mem.Allocator, io: Io) bool {
    switch (rg_checked.load(.acquire)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    const res = std.process.run(gpa, io, .{
        .argv = &.{ "rg", "--version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch {
        rg_checked.store(2, .release);
        return false;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    const ok = res.term == .exited and res.term.exited == 0;
    rg_checked.store(if (ok) 1 else 2, .release);
    return ok;
}

fn rgGrep(gpa: std.mem.Allocator, io: Io, args: GrepArgs, search_path: []const u8) ![]u8 {
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

    const res = std.process.run(gpa, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(max_output_bytes),
        .stderr_limit = .limited(64 * 1024),
    }) catch |e| {
        return std.fmt.allocPrint(gpa, "error: failed to run rg: {t}", .{e});
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

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

/// Internal fallback: recursive walk + regex match (zig-regex engine).
/// Feature-parity goal with the rg path: real regex, skip list for bulky
/// dirs (rg gets this from .gitignore), binary sniff, same output format.
/// A pattern the engine cannot compile degrades to literal substring with
/// an explicit note — tool errors are data.
fn internalGrep(gpa: std.mem.Allocator, io: Io, args: GrepArgs, search_path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var matches: u64 = 0;

    var compiled: ?regex_mod.Regex = regex_mod.Regex.compile(gpa, args.pattern) catch null;
    defer if (compiled) |*r| r.deinit();
    if (compiled == null and looksLikeRegex(args.pattern)) {
        try out.appendSlice(gpa, "note: pattern did not compile as regex; matched as a LITERAL substring instead.\n");
    }
    const matcher = Matcher{ .re = if (compiled) |*r| r else null, .literal = args.pattern };

    // Single file?
    const stat = Io.Dir.cwd().statFile(io, search_path, .{}) catch |e| {
        return std.fmt.allocPrint(gpa, "error: cannot access '{s}': {t}", .{ search_path, e });
    };
    if (stat.kind == .file) {
        try grepOneFile(gpa, io, &out, &matches, matcher, args.limit, search_path, search_path);
    } else {
        var dir = Io.Dir.cwd().openDir(io, search_path, .{ .iterate = true }) catch |e| {
            return std.fmt.allocPrint(gpa, "error: cannot open '{s}': {t}", .{ search_path, e });
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (matches >= args.limit) break;
            if (entry.kind != .file) continue;
            if (skipPath(entry.path)) continue;
            if (args.glob) |g| {
                if (!globMatch(g, std.fs.path.basename(entry.path))) continue;
            }
            const full = try std.fs.path.join(gpa, &.{ search_path, entry.path });
            defer gpa.free(full);
            grepOneFile(gpa, io, &out, &matches, matcher, args.limit, full, entry.path) catch continue;
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
    literal: []const u8,

    fn matches(self: Matcher, gpa: std.mem.Allocator, line: []const u8) bool {
        if (self.re) |r| {
            const m = r.find(line) catch return false;
            if (m) |found| {
                var mut = found;
                mut.deinit(gpa);
                return true;
            }
            return false;
        }
        return std.mem.indexOf(u8, line, self.literal) != null;
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
) !void {
    const contents = Io.Dir.cwd().readFileAlloc(io, full_path, gpa, .limited(files.max_read_bytes)) catch return;
    defer gpa.free(contents);
    if (std.mem.indexOfScalar(u8, contents[0..@min(contents.len, 4096)], 0) != null) return; // binary

    var line_no: u64 = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
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
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (n >= limit) {
            try out.appendSlice(gpa, "[... more matches truncated; refine the pattern ...]\n");
            break;
        }
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
        n += 1;
    }
    if (out.items.len == 0) {
        out.deinit(gpa);
        return gpa.dupe(u8, "no matches");
    }
    return out.toOwnedSlice(gpa);
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

pub fn glob(gpa: std.mem.Allocator, io: Io, args: GlobArgs, cwd: []const u8) ![]u8 {
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
        if (entry.kind != .file) continue;
        if (skipPath(entry.path)) continue;
        const target = if (std.mem.indexOfScalar(u8, args.pattern, '/') != null)
            entry.path
        else
            std.fs.path.basename(entry.path);
        if (!globMatch(args.pattern, target)) continue;
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

/// Glob matcher: *, ?, ** (across separators). Iterative backtracking.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return globMatchInner(pattern, name);
}

fn globMatchInner(pat: []const u8, str: []const u8) bool {
    // Handle the leftmost ** by splitting: head must match a prefix, then
    // ** swallows any run (including '/'), then the tail matches a suffix.
    if (std.mem.indexOf(u8, pat, "**")) |at| {
        const head = pat[0..at];
        const tail = pat[at + 2 ..];
        // "head**/x" also matches with the '/' elided ("src/**/*.zig" must
        // match "src/main.zig"), so try the tail without its leading '/'.
        const tail_no_slash: ?[]const u8 = if (std.mem.startsWith(u8, tail, "/")) tail[1..] else null;
        var h: usize = 0;
        while (h <= str.len) : (h += 1) {
            if (!simpleMatch(head, str[0..h], false)) continue;
            // ** consumes str[h..j] for any j; tail matches the rest.
            var j: usize = h;
            while (j <= str.len) : (j += 1) {
                if (globMatchInner(tail, str[j..])) return true;
                if (tail_no_slash) |tns| {
                    if (globMatchInner(tns, str[j..])) return true;
                }
            }
        }
        return false;
    }
    return simpleMatch(pat, str, true);
}

/// Match without **: * stops at '/', ? matches one non-'/' char.
/// `full` = must consume the whole string.
fn simpleMatch(pat: []const u8, str: []const u8, full: bool) bool {
    _ = full;
    var p: usize = 0;
    var s: usize = 0;
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (s < str.len) {
        if (p < pat.len and (pat[p] == str[s] or (pat[p] == '?' and str[s] != '/'))) {
            p += 1;
            s += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star_p = p;
            star_s = s;
            p += 1;
        } else if (star_p) |sp| {
            if (str[star_s] == '/') return false; // * does not cross separators
            star_s += 1;
            s = star_s;
            p = sp + 1;
        } else {
            return false;
        }
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
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

test "internal grep + glob on a temp tree" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/marlin-search-test-{x}", .{std.mem.readInt(u64, &rand, .little)});
    defer gpa.free(dir_path);
    defer Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    const w1 = try files.writeFile(gpa, io, .{ .path = "a/one.txt", .content = "hello needle here\nplain line\n" }, dir_path);
    gpa.free(w1);
    const w2 = try files.writeFile(gpa, io, .{ .path = "b/two.log", .content = "no match\n" }, dir_path);
    gpa.free(w2);

    // Force the internal path (don't depend on rg in CI).
    const g = try internalGrep(gpa, io, .{ .pattern = "needle" }, dir_path);
    defer gpa.free(g);
    try std.testing.expect(std.mem.indexOf(u8, g, "one.txt:1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, g, "note:") == null);

    // Real regex works in the internal engine now.
    const gr = try internalGrep(gpa, io, .{ .pattern = "hel+o nee.le" }, dir_path);
    defer gpa.free(gr);
    try std.testing.expect(std.mem.indexOf(u8, gr, "one.txt:1:") != null);

    // Regex that matches nothing really is no matches (not a dialect artifact).
    const gn = try internalGrep(gpa, io, .{ .pattern = "^needle$" }, dir_path);
    defer gpa.free(gn);
    try std.testing.expect(std.mem.indexOf(u8, gn, "no matches") != null);

    const gl = try glob(gpa, io, .{ .pattern = "*.txt" }, dir_path);
    defer gpa.free(gl);
    try std.testing.expect(std.mem.indexOf(u8, gl, "one.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, gl, "two.log") == null);
}

test {
    std.testing.refAllDecls(@This());
}
