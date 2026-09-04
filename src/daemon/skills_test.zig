//! Unit tests for skills.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in skills.zig.

const std = @import("std");
const Io = std.Io;

const skills = @import("skills.zig");
const Index = skills.Index;

test {
    std.testing.refAllDecls(skills);
}

test "skills scan recursively, sort stably, and load on demand" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-skills");
    defer temp.deinit();
    const root = temp.path;
    const nested = try std.fs.path.join(gpa, &.{ root, "review" });
    defer gpa.free(nested);
    try Io.Dir.cwd().createDirPath(io, nested);
    const review_path = try std.fs.path.join(gpa, &.{ nested, "SKILL.md" });
    defer gpa.free(review_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = review_path, .data =
        \\---
        \\name: review
        \\description: Review changes carefully
        \\---
        \\Check the diff and run tests.
    });
    const alpha_path = try std.fs.path.join(gpa, &.{ root, "alpha.md" });
    defer gpa.free(alpha_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = alpha_path, .data =
        \\---
        \\name: alpha
        \\description: First skill
        \\---
        \\Alpha instructions.
    });

    var index = try Index.load(gpa, io, &.{root});
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.items.items.len);
    try std.testing.expectEqualStrings("alpha", index.items.items[0].name);
    try std.testing.expect(std.mem.indexOf(u8, index.prompt, "review: Review changes carefully") != null);
    const content = try index.loadContent(gpa, "{\"name\":\"review\"}");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("Check the diff and run tests.", std.mem.trim(u8, content, "\n"));
}
