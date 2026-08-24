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
    return std.fmt.allocPrint(gpa, "replaced {d} occurrence(s) in {s}", .{ rr.count, args.path });
}

fn ambiguousMsg(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\error: old_string matches more than once in '{s}'. Add surrounding context to make it unique, or set replace_all:true.
    , .{path});
}

const ReplaceResult = struct { text: []u8, count: usize };

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
    while (std.mem.indexOf(u8, rest, old)) |at| {
        try out.appendSlice(gpa, rest[0..at]);
        try out.appendSlice(gpa, new);
        rest = rest[at + old.len ..];
        count += 1;
        if (!replace_all) break;
    }
    try out.appendSlice(gpa, rest);
    return .{ .text = try out.toOwnedSlice(gpa), .count = count };
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
    return .{ .text = try out.toOwnedSlice(gpa), .count = 1 };
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

test {
    std.testing.refAllDecls(@This());
}
