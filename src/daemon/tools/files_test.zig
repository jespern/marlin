//! Unit tests for files.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in files.zig.

const std = @import("std");
const Io = std.Io;
const permissions = @import("../permissions.zig");

const files = @import("files.zig");
const editFile = files.editFile;
const fuzzyReplace = files.fuzzyReplace;
const readFile = files.readFile;
const replaceExact = files.replaceExact;
const unifiedDiff = files.unifiedDiff;
const writeFile = files.writeFile;

test {
    std.testing.refAllDecls(files);
}

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
    const r = try fuzzyReplace(
        gpa,
        hay,
        "let x = 1;\nlet y = 2;",
        "    let x = 10;",
    );
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings("fn main() {\n    let x = 10;\n}\n", r.text);
}

test "write + edit + read round trip on disk" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-files-test");
    defer temp.deinit();
    const dir_path = temp.path;

    const w = try writeFile(gpa, io, .{ .path = "sub/f.txt", .content = "hello world\n" }, dir_path);
    defer gpa.free(w);
    // A new file reports creation with an all-additions diff.
    try std.testing.expect(std.mem.startsWith(u8, w, "created "));
    try std.testing.expect(std.mem.indexOf(u8, w, "+hello world") != null);

    // Overwriting renders the change as a reviewable diff, not a byte count.
    const w2 = try writeFile(gpa, io, .{ .path = "sub/f.txt", .content = "hello there\n" }, dir_path);
    defer gpa.free(w2);
    try std.testing.expect(std.mem.startsWith(u8, w2, "wrote "));
    try std.testing.expect(std.mem.indexOf(u8, w2, "-hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, w2, "+hello there") != null);

    const w3 = try writeFile(gpa, io, .{ .path = "sub/f.txt", .content = "hello there\n" }, dir_path);
    defer gpa.free(w3);
    try std.testing.expect(std.mem.indexOf(u8, w3, "(content unchanged)") != null);

    const w4 = try writeFile(gpa, io, .{ .path = "sub/f.txt", .content = "hello world\n" }, dir_path);
    defer gpa.free(w4);

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

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-difftest");
    defer temp.deinit();
    const dir_path = temp.path;

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

test "creation diffs cap at a head preview" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-files-cap");
    defer temp.deinit();

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(gpa);
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        var buf: [24]u8 = undefined;
        try content.appendSlice(gpa, try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    }

    const w = try writeFile(gpa, io, .{ .path = "big.txt", .content = content.items }, temp.path);
    defer gpa.free(w);
    try std.testing.expect(std.mem.startsWith(u8, w, "created "));
    try std.testing.expect(std.mem.indexOf(u8, w, "+line 39") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "+line 41") == null);
    try std.testing.expect(std.mem.indexOf(u8, w, "more new lines") != null);
}

test "read_file refuses protected paths as tool-result data" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const refusal = try readFile(gpa, io, .{ .path = "/tmp/definitely/.env" }, "/tmp");
    defer gpa.free(refusal);
    try std.testing.expect(std.mem.indexOf(u8, refusal, "refusing to read protected path") != null);

    const rel = try readFile(gpa, io, .{ .path = ".ssh/id_ed25519" }, "/tmp");
    defer gpa.free(rel);
    try std.testing.expect(std.mem.indexOf(u8, rel, "refusing to read protected path") != null);
}

test "write and edit refuse protected paths and never leak prior contents" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-protected-write");
    defer temp.deinit();
    const dir_path = temp.path;

    // Seed a protected file with a secret-looking body.
    const env_path = try std.fs.path.join(gpa, &.{ dir_path, ".env" });
    defer gpa.free(env_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = env_path, .data = "API_KEY=hunter2\n" });

    const wrote = try writeFile(gpa, io, .{ .path = ".env", .content = "overwritten\n" }, dir_path);
    defer gpa.free(wrote);
    try std.testing.expect(std.mem.indexOf(u8, wrote, "refusing to write protected path") != null);
    try std.testing.expect(std.mem.indexOf(u8, wrote, "hunter2") == null);

    const edited = try editFile(gpa, io, .{
        .path = ".env",
        .old_string = "hunter2",
        .new_string = "x",
    }, dir_path);
    defer gpa.free(edited);
    try std.testing.expect(std.mem.indexOf(u8, edited, "refusing to edit protected path") != null);
    try std.testing.expect(std.mem.indexOf(u8, edited, "hunter2") == null);

    // The file was truly untouched.
    const still = try Io.Dir.cwd().readFileAlloc(io, env_path, gpa, .limited(64));
    defer gpa.free(still);
    try std.testing.expectEqualStrings("API_KEY=hunter2\n", still);
}

test "symlink to protected material is refused for reads" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-protected-symlink");
    defer temp.deinit();
    const dir_path = temp.path;

    const secret = try std.fs.path.join(gpa, &.{ dir_path, "id_ed25519" });
    defer gpa.free(secret);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = secret, .data = "PRIVATE KEY" });
    const link = try std.fs.path.join(gpa, &.{ dir_path, "innocent.txt" });
    defer gpa.free(link);
    try Io.Dir.cwd().symLink(io, secret, link, .{});

    const refused = try readFile(gpa, io, .{ .path = "innocent.txt" }, dir_path);
    defer gpa.free(refused);
    try std.testing.expect(std.mem.indexOf(u8, refused, "refusing to read protected path") != null);
    try std.testing.expect(std.mem.indexOf(u8, refused, "PRIVATE KEY") == null);
}
