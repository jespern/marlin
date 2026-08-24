//! File tools: read_file (M0), write_file + edit (M2).
//!
//! read_file: line-windowed (offset/limit), 1-indexed "N|content" output like
//! every agent expects; binary detection; byte cap.
//! write_file: full overwrite, parent dirs created.
//! edit: exact string-replace with a whitespace-tolerant fuzzy fallback;
//! old_string must match exactly once (unless replace_all).

const std = @import("std");
const Io = std.Io;

pub const read_spec_name = "read_file";
pub const read_spec_description =
    "Read a text file with line numbers. Returns lines as 'N|content'. " ++
    "Use offset (1-indexed first line) and limit for large files.";
pub const read_spec_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","minimum":1},"limit":{"type":"integer","minimum":1}},"required":["path"]}
;

pub const ReadArgs = struct {
    path: []const u8,
    offset: u64 = 1,
    limit: u64 = 2000,
};

pub const max_read_bytes: usize = 2 * 1024 * 1024;

/// Returns formatted output (caller frees). Errors are returned as text so
/// the model can react (missing file, binary, etc.) — tool errors are data.
pub fn readFile(gpa: std.mem.Allocator, io: Io, args: ReadArgs, cwd: []const u8) ![]u8 {
    // Resolve relative to session cwd.
    const abs = if (std.fs.path.isAbsolute(args.path))
        try gpa.dupe(u8, args.path)
    else
        try std.fs.path.join(gpa, &.{ cwd, args.path });
    defer gpa.free(abs);

    var dir = Io.Dir.cwd();
    const contents = dir.readFileAlloc(io, abs, gpa, .limited(max_read_bytes)) catch |e| {
        return std.fmt.allocPrint(gpa, "error: cannot read '{s}': {t}", .{ args.path, e });
    };
    defer gpa.free(contents);

    // Binary sniff: NUL byte in the first 4k.
    const sniff = contents[0..@min(contents.len, 4096)];
    if (std.mem.indexOfScalar(u8, sniff, 0) != null) {
        return std.fmt.allocPrint(gpa, "error: '{s}' looks binary ({d} bytes)", .{ args.path, contents.len });
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var line_no: u64 = 0;
    var shown: u64 = 0;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        line_no += 1;
        if (line_no < args.offset) continue;
        if (shown >= args.limit) {
            const w = try std.fmt.allocPrint(gpa, "... [truncated at line {d}; more lines follow]", .{line_no - 1});
            defer gpa.free(w);
            try out.appendSlice(gpa, w);
            break;
        }
        const prefix = try std.fmt.allocPrint(gpa, "{d}|", .{line_no});
        defer gpa.free(prefix);
        try out.appendSlice(gpa, prefix);
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
        shown += 1;
    }
    if (out.items.len == 0) try out.appendSlice(gpa, "(empty file)");
    return out.toOwnedSlice(gpa);
}

// ------------------------------------------------------------ write_file --

pub const write_spec_name = "write_file";
pub const write_spec_description =
    "Write content to a file, replacing it entirely. Creates parent directories. " ++
    "Use edit for targeted changes to existing files.";
pub const write_spec_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}
;

pub const WriteArgs = struct {
    path: []const u8,
    content: []const u8,
};

pub fn writeFile(gpa: std.mem.Allocator, io: Io, args: WriteArgs, cwd: []const u8) ![]u8 {
    const abs = try resolvePath(gpa, args.path, cwd);
    defer gpa.free(abs);

    const dir = Io.Dir.cwd();
    if (std.fs.path.dirname(abs)) |parent| {
        dir.createDirPath(io, parent) catch |e| {
            return std.fmt.allocPrint(gpa, "error: cannot create parent dirs for '{s}': {t}", .{ args.path, e });
        };
    }
    dir.writeFile(io, .{ .sub_path = abs, .data = args.content }) catch |e| {
        return std.fmt.allocPrint(gpa, "error: cannot write '{s}': {t}", .{ args.path, e });
    };
    return std.fmt.allocPrint(gpa, "wrote {d} bytes to {s}", .{ args.content.len, args.path });
}

// ------------------------------------------------------------------ edit --

pub const edit_spec_name = "edit";
pub const edit_spec_description =
    "Replace old_string with new_string in a file. old_string must match exactly once " ++
    "(include surrounding context to disambiguate), or set replace_all:true. " ++
    "Falls back to a whitespace-tolerant match when no exact match exists.";
pub const edit_spec_schema =
    \\{"type":"object","properties":{"path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean"}},"required":["path","old_string","new_string"]}
;

pub const EditArgs = struct {
    path: []const u8,
    old_string: []const u8,
    new_string: []const u8,
    replace_all: bool = false,
};

pub fn editFile(gpa: std.mem.Allocator, io: Io, args: EditArgs, cwd: []const u8) ![]u8 {
    if (args.old_string.len == 0)
        return gpa.dupe(u8, "error: old_string must not be empty");
    if (std.mem.eql(u8, args.old_string, args.new_string))
        return gpa.dupe(u8, "error: old_string and new_string are identical");

    const abs = try resolvePath(gpa, args.path, cwd);
    defer gpa.free(abs);

    const dir = Io.Dir.cwd();
    const contents = dir.readFileAlloc(io, abs, gpa, .limited(max_read_bytes)) catch |e| {
        return std.fmt.allocPrint(gpa, "error: cannot read '{s}': {t}", .{ args.path, e });
    };
    defer gpa.free(contents);

    const rr = replaceExact(gpa, contents, args.old_string, args.new_string, args.replace_all) catch |e| switch (e) {
        error.NotFound => blk: {
            // Fuzzy fallback: match ignoring per-line leading/trailing blanks.
            break :blk fuzzyReplace(gpa, contents, args.old_string, args.new_string) catch |fe| switch (fe) {
                error.NotFound => return std.fmt.allocPrint(gpa,
                    \\error: old_string not found in '{s}' (also tried whitespace-tolerant match). Re-read the file and retry with exact text.
                , .{args.path}),
                error.Ambiguous => return ambiguousMsg(gpa, args.path),
                else => return fe,
            };
        },
        error.Ambiguous => return ambiguousMsg(gpa, args.path),
        else => return e,
    };
    defer gpa.free(rr.text);

    dir.writeFile(io, .{ .sub_path = abs, .data = rr.text }) catch |e| {
        return std.fmt.allocPrint(gpa, "error: cannot write '{s}': {t}", .{ args.path, e });
    };

    // Single-site edits get a mini unified diff (with enclosing-declaration
    // context, git-style) appended: confirmation for the model, and the TUI
    // renders it as a colored diff. Multi-site (replace_all) keeps the
    // one-line summary — N scattered hunks are noise in both places.
    if (rr.count == 1) {
        if (unifiedDiff(gpa, contents, rr.at, rr.old_len, args.new_string)) |diff| {
            defer gpa.free(diff);
            return std.fmt.allocPrint(gpa, "replaced 1 occurrence(s) in {s}\n{s}", .{ args.path, diff });
        } else |_| {}
    }
    return std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s}", .{ rr.count, args.path });
}

fn ambiguousMsg(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\error: old_string matches more than once in '{s}'. Add surrounding context to make it unique, or set replace_all:true.
    , .{path});
}

const ReplaceResult = struct {
    text: []u8,
    count: usize,
    /// Byte offset of the (first) match in the ORIGINAL text + its length —
    /// what the diff renderer needs to window the change.
    at: usize = 0,
    old_len: usize = 0,
};

fn replaceExact(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    old: []const u8,
    new: []const u8,
    replace_all: bool,
) !ReplaceResult {
    const n = std.mem.count(u8, haystack, old);
    if (n == 0) return error.NotFound;
    if (n > 1 and !replace_all) return error.Ambiguous;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = haystack;
    var count: usize = 0;
    var first_at: usize = 0;
    while (std.mem.indexOf(u8, rest, old)) |at| {
        if (count == 0) first_at = (haystack.len - rest.len) + at;
        try out.appendSlice(gpa, rest[0..at]);
        try out.appendSlice(gpa, new);
        rest = rest[at + old.len ..];
        count += 1;
        if (!replace_all) break;
    }
    try out.appendSlice(gpa, rest);
    return .{ .text = try out.toOwnedSlice(gpa), .count = count, .at = first_at, .old_len = old.len };
}

/// Whitespace-tolerant single replace: finds a run of lines in `haystack`
/// whose trimmed forms equal the trimmed lines of `old`, exactly once, and
/// splices `new` in their place (verbatim). Restores nothing fancier —
/// indentation of the replacement is the model's responsibility.
fn fuzzyReplace(
    gpa: std.mem.Allocator,
    haystack: []const u8,
    old: []const u8,
    new: []const u8,
) !ReplaceResult {
    var old_lines: std.ArrayList([]const u8) = .empty;
    defer old_lines.deinit(gpa);
    var oit = std.mem.splitScalar(u8, std.mem.trim(u8, old, "\n"), '\n');
    while (oit.next()) |l| try old_lines.append(gpa, std.mem.trim(u8, l, " \t\r"));
    if (old_lines.items.len == 0) return error.NotFound;

    // Index haystack line offsets.
    var lines: std.ArrayList(struct { start: usize, end: usize }) = .empty;
    defer lines.deinit(gpa);
    {
        var start: usize = 0;
        var i: usize = 0;
        while (i <= haystack.len) : (i += 1) {
            if (i == haystack.len or haystack[i] == '\n') {
                try lines.append(gpa, .{ .start = start, .end = i });
                start = i + 1;
            }
        }
    }

    var match_at: ?usize = null;
    var i: usize = 0;
    outer: while (i + old_lines.items.len <= lines.items.len) : (i += 1) {
        for (old_lines.items, 0..) |ol, j| {
            const hl = lines.items[i + j];
            const trimmed = std.mem.trim(u8, haystack[hl.start..hl.end], " \t\r");
            if (!std.mem.eql(u8, trimmed, ol)) continue :outer;
        }
        if (match_at != null) return error.Ambiguous;
        match_at = i;
    }
    const at = match_at orelse return error.NotFound;

    const first = lines.items[at];
    const last = lines.items[at + old_lines.items.len - 1];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, haystack[0..first.start]);
    try out.appendSlice(gpa, new);
    try out.appendSlice(gpa, haystack[last.end..]);
    return .{ .text = try out.toOwnedSlice(gpa), .count = 1, .at = first.start, .old_len = last.end - first.start };
}

// -------------------------------------------------------------- diffing --

/// Render a git-style mini unified diff for a single replacement at byte
/// offset `at` (length `old_len`) in `original`, replaced by `new_text`.
/// 3 lines of context each side; hunk header carries the enclosing
/// declaration (git's -p behavior): the nearest preceding line that starts
/// at column 0 with an identifier-ish character.
///
///   @@ -12,7 +12,7 @@ pub fn editFile(...)
///    context
///   -old line
///   +new line
///    context
fn unifiedDiff(
    gpa: std.mem.Allocator,
    original: []const u8,
    at: usize,
    old_len: usize,
    new_text: []const u8,
) ![]u8 {
    const ctx_lines = 3;

    // Expand [at, at+old_len) to whole-line boundaries.
    const repl_start = if (std.mem.lastIndexOfScalar(u8, original[0..at], '\n')) |p| p + 1 else 0;
    const repl_end_raw = at + old_len;
    const repl_end = if (std.mem.indexOfScalarPos(u8, original, @min(repl_end_raw, original.len), '\n')) |p| p + 1 else original.len;

    // Walk lines to find: hunk start (ctx_lines before), line numbers, and
    // the enclosing declaration for the header.
    var line_no: usize = 1; // 1-based line number of `pos`
    var pos: usize = 0;
    var ctx_ring: [ctx_lines]usize = @splat(0);
    var ring_len: usize = 0;
    var func_ctx: []const u8 = "";
    while (pos < repl_start) {
        const eol = std.mem.indexOfScalarPos(u8, original, pos, '\n') orelse original.len;
        const line = original[pos..eol];
        // git's default "function name" heuristic: line starts at col 0
        // with a letter/underscore (covers fn/pub fn/def/class/impl...).
        if (line.len > 0 and (std.ascii.isAlphabetic(line[0]) or line[0] == '_')) {
            func_ctx = line;
        }
        // Ring of the last ctx_lines line-start offsets.
        ctx_ring[ring_len % ctx_lines] = pos;
        ring_len += 1;
        pos = eol + 1;
        line_no += 1;
    }
    const repl_start_line = line_no; // line number where the change begins
    const n_ctx_before = @min(ring_len, ctx_lines);
    const hunk_start_off = if (n_ctx_before == 0) repl_start else ctx_ring[(ring_len - n_ctx_before) % ctx_lines];
    const hunk_start_line = repl_start_line - n_ctx_before;

    // Collect the changed region's old lines.
    var old_count: usize = 0;
    {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, original[repl_start..repl_end], "\n"), '\n');
        while (it.next()) |_| old_count += 1;
    }
    // New region: prefix-of-line + new_text + suffix-of-line.
    const suffix_end = if (repl_end > 0 and original[repl_end - 1] == '\n') repl_end - 1 else repl_end;
    const new_region = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{
        original[repl_start..at],
        new_text,
        original[@min(repl_end_raw, suffix_end)..suffix_end],
    });
    defer gpa.free(new_region);
    var new_count: usize = 0;
    if (new_region.len > 0) {
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, new_region, "\n"), '\n');
        while (it.next()) |_| new_count += 1;
    }

    // Context after.
    var after_end = repl_end;
    var n_ctx_after: usize = 0;
    while (n_ctx_after < ctx_lines and after_end < original.len) {
        const eol = std.mem.indexOfScalarPos(u8, original, after_end, '\n') orelse original.len;
        after_end = @min(eol + 1, original.len);
        n_ctx_after += 1;
    }

    // Cap pathological hunks (giant old_string): bail rather than spam.
    if (old_count + new_count > 80) return error.DiffTooBig;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const old_total = n_ctx_before + old_count + n_ctx_after;
    const new_total = n_ctx_before + new_count + n_ctx_after;
    try out.print(gpa, "@@ -{d},{d} +{d},{d} @@", .{ hunk_start_line, old_total, hunk_start_line, new_total });
    if (func_ctx.len > 0) {
        try out.print(gpa, " {s}", .{func_ctx[0..@min(func_ctx.len, 60)]});
    }
    try out.append(gpa, '\n');

    // Leading context.
    try emitLines(gpa, &out, original[hunk_start_off..repl_start], ' ');
    // Old / new.
    try emitLines(gpa, &out, original[repl_start..repl_end], '-');
    if (new_region.len > 0) try emitLines(gpa, &out, new_region, '+');
    // Trailing context.
    try emitLines(gpa, &out, original[repl_end..after_end], ' ');

    return out.toOwnedSlice(gpa);
}

fn emitLines(gpa: std.mem.Allocator, out: *std.ArrayList(u8), region: []const u8, marker: u8) !void {
    if (region.len == 0) return;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, region, "\n"), '\n');
    while (it.next()) |line| {
        try out.append(gpa, marker);
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
}

/// Resolve a possibly-relative path against the session cwd. Caller frees.
pub fn resolvePath(gpa: std.mem.Allocator, path: []const u8, cwd: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return gpa.dupe(u8, path);
    return std.fs.path.join(gpa, &.{ cwd, path });
}

// ---------------------------------------------------------------- tests --

test "replaceExact: unique, ambiguous, replace_all" {
    const gpa = std.testing.allocator;
    const r1 = try replaceExact(gpa, "a b c", "b", "X", false);
    defer gpa.free(r1.text);
    try std.testing.expectEqualStrings("a X c", r1.text);

    try std.testing.expectError(error.Ambiguous, replaceExact(gpa, "b b", "b", "X", false));
    try std.testing.expectError(error.NotFound, replaceExact(gpa, "a", "z", "X", false));

    const r2 = try replaceExact(gpa, "b b", "b", "X", true);
    defer gpa.free(r2.text);
    try std.testing.expectEqualStrings("X X", r2.text);
    try std.testing.expectEqual(@as(usize, 2), r2.count);
}

test "fuzzyReplace: matches despite indentation drift" {
    const gpa = std.testing.allocator;
    const hay = "fn main() {\n    let x = 1;\n    let y = 2;\n}\n";
    const r = try fuzzyReplace(gpa, hay, "let x = 1;\nlet y = 2;", "    let x = 10;", );
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings("fn main() {\n    let x = 10;\n}\n", r.text);
}

test "write + edit + read round trip on disk" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/marlin-files-test-{x}", .{std.mem.readInt(u64, &rand, .little)});
    defer gpa.free(dir_path);
    defer Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    const w = try writeFile(gpa, io, .{ .path = "sub/f.txt", .content = "hello world\n" }, dir_path);
    defer gpa.free(w);
    try std.testing.expect(std.mem.startsWith(u8, w, "wrote "));

    const e = try editFile(gpa, io, .{ .path = "sub/f.txt", .old_string = "world", .new_string = "marlin" }, dir_path);
    defer gpa.free(e);
    try std.testing.expect(std.mem.startsWith(u8, e, "replaced 1"));

    const r = try readFile(gpa, io, .{ .path = "sub/f.txt" }, dir_path);
    defer gpa.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "hello marlin") != null);
}

test "unifiedDiff: hunk header carries enclosing declaration" {
    const gpa = std.testing.allocator;
    const src =
        "const std = @import(\"std\");\n" ++
        "\n" ++
        "pub fn greet(name: []const u8) void {\n" ++
        "    const msg = \"hello\";\n" ++
        "    print(msg, name);\n" ++
        "}\n";
    const at = std.mem.indexOf(u8, src, "\"hello\"").?;
    const diff = try unifiedDiff(gpa, src, at, "\"hello\"".len, "\"howdy\"");
    defer gpa.free(diff);
    try std.testing.expect(std.mem.indexOf(u8, diff, "@@ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "pub fn greet(name: []const u8) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "-    const msg = \"hello\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, diff, "+    const msg = \"howdy\";") != null);
    // context lines present with leading space
    try std.testing.expect(std.mem.indexOf(u8, diff, " }\n") != null or std.mem.endsWith(u8, diff, " }\n"));
}

test "editFile result embeds a colored-diff-ready hunk" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const dir_path = try std.fmt.allocPrint(gpa, "/tmp/marlin-difftest-{x}", .{std.mem.readInt(u64, &rand, .little)});
    defer gpa.free(dir_path);
    defer Io.Dir.cwd().deleteTree(io, dir_path) catch {};

    const w = try writeFile(gpa, io, .{ .path = "m.zig", .content = "fn main() void {\n    var x = 1;\n}\n" }, dir_path);
    gpa.free(w);
    const e = try editFile(gpa, io, .{ .path = "m.zig", .old_string = "var x = 1;", .new_string = "var x = 2;" }, dir_path);
    defer gpa.free(e);
    try std.testing.expect(std.mem.indexOf(u8, e, "replaced 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "@@ ") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "fn main() void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "-    var x = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "+    var x = 2;") != null);
}

test {
    std.testing.refAllDecls(@This());
}
