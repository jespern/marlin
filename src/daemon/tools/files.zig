//! File tools: read_file (M0), write_file + edit (M2).
//!
//! read_file: line-windowed (offset/limit), 1-indexed "N|content" output like
//! every agent expects; binary detection; byte cap.

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

test {
    std.testing.refAllDecls(@This());
}
