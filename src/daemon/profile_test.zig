const std = @import("std");
const profile = @import("profile.zig");

test {
    std.testing.refAllDecls(profile);
}

const sample =
    \\# Profile
    \\Prefer events over polling.
    \\
    \\## project: marlin
    \\Tests live in sibling _test.zig files.
    \\
    \\## project: mirador, terma-cli
    \\Work repo: keep PRs small.
    \\
    \\## Communication
    \\Keep updates short.
    \\
;

test "global text and the matching project section are kept" {
    const gpa = std.testing.allocator;
    const out = try profile.select(gpa, sample, "/Users/j/Work/marlin");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Prefer events over polling.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sibling _test.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep PRs small") == null);
    // A later ordinary heading reopens global text.
    try std.testing.expect(std.mem.indexOf(u8, out, "Keep updates short.") != null);
}

test "a project section matches any cwd component and any listed name" {
    const gpa = std.testing.allocator;
    const out = try profile.select(gpa, sample, "/Users/j/Work/mirador/terma-frontend/src");
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "keep PRs small") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "sibling _test.zig") == null);
}

test "component matching is whole-name, not substring" {
    try std.testing.expect(profile.hasComponent("/Users/j/Work/marlin", "marlin"));
    try std.testing.expect(!profile.hasComponent("/Users/j/Work/marlin-raster", "marlin"));
    try std.testing.expect(!profile.hasComponent("/Users/j/Work/marlin", "Work/marlin"));
}

test "render adds the header and drops an empty profile" {
    const gpa = std.testing.allocator;
    const rendered = (try profile.render(gpa, "Be terse.\n", "/tmp")).?;
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.startsWith(u8, rendered, profile.header));
    try std.testing.expect(std.mem.endsWith(u8, rendered, "Be terse."));

    try std.testing.expect((try profile.render(gpa, " \n\n", "/tmp")) == null);
    // Only a non-matching project section: nothing applies.
    try std.testing.expect((try profile.render(gpa, "## project: other\nx\n", "/tmp")) == null);
}

test "load without an environment yields nothing" {
    try std.testing.expect(profile.load(std.testing.allocator, std.testing.io, null, "/tmp") == null);
}
