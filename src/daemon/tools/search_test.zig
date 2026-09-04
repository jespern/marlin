//! Unit tests for search.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in search.zig.

const std = @import("std");
const Io = std.Io;
const regex_mod = @import("regex");
const files = @import("files.zig");
const permissions = @import("../permissions.zig");
const process_io = @import("../process_io.zig");

const search = @import("search.zig");
const glob = search.glob;
const globMatch = search.globMatch;
const globMatchAlloc = search.globMatchAlloc;
const grep = search.grep;
const internalGrep = search.internalGrep;

test {
    std.testing.refAllDecls(search);
}

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
