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
    try std.testing.expect(std.mem.endsWith(u8, content, "Check the diff and run tests."));
    try std.testing.expect(std.mem.indexOf(u8, content, nested) != null);

    const invocation = try index.renderInvocation(gpa, "review", "src/parser.zig");
    defer gpa.free(invocation);
    try std.testing.expect(std.mem.indexOf(u8, invocation, "Check the diff and run tests.") != null);
    try std.testing.expect(std.mem.indexOf(u8, invocation, review_path) != null);
    try std.testing.expect(std.mem.endsWith(u8, invocation, "ARGUMENTS: src/parser.zig"));
    try std.testing.expectError(error.UnknownSkill, index.renderInvocation(gpa, "missing", ""));
}

test "skill arguments expand once with quoted positional values and literal shell text" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { body: []const u8, args: []const u8, want: []const u8 }{
        .{ .body = "Review $ARGUMENTS", .args = "issue 123", .want = "Review issue 123" },
        .{ .body = "$0 / $ARGUMENTS[1] / $2 / $9", .args = "'two words' \"three words\" four\\ five", .want = "two words / three words / four five / " },
        .{ .body = "$ARGUMENTS", .args = "$ARGUMENTS $0 $(touch sentinel)", .want = "$ARGUMENTS $0 $(touch sentinel)" },
        .{ .body = "Review $ARGUMENTS", .args = "", .want = "Review " },
        .{ .body = "No placeholders.", .args = "line one\nline two", .want = "No placeholders.\n\nARGUMENTS: line one\nline two" },
        .{ .body = "No placeholders.", .args = "", .want = "No placeholders." },
        .{ .body = "$ARGUMENTS_EXTRA $ARGUMENTS[x]", .args = "literal", .want = "$ARGUMENTS_EXTRA $ARGUMENTS[x]\n\nARGUMENTS: literal" },
        .{ .body = "!`echo hello` $HOME $0", .args = "''", .want = "!`echo hello` $HOME " },
    };
    for (cases) |case| {
        const got = try skills.renderArguments(gpa, case.body, case.args);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case.want, got);
    }
    const huge = try gpa.alloc(u8, 600 * 1024);
    defer gpa.free(huge);
    @memset(huge, 'x');
    try std.testing.expectError(error.SkillTooLarge, skills.renderArguments(gpa, "$ARGUMENTS$ARGUMENTS", huge));
}

fn fixture(arena: std.mem.Allocator, io: Io, root: []const u8, relative: []const u8, contents: []const u8) ![]const u8 {
    const path = try std.fs.path.join(arena, &.{ root, relative });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
    return path;
}

test "Agent Skills YAML scalars, nested metadata, optional fields and CRLF" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try skills.parseFrontmatter(arena,
        \\---
        \\name: 'pdf-processing' # comment
        \\description: >-
        \\  Extract PDFs: text and tables.
        \\  Use for document analysis.
        \\license: Apache-2.0
        \\compatibility: "Requires Python\n3.14+"
        \\allowed-tools: Bash(git:*) Read
        \\metadata:
        \\  name: not-the-skill-name
        \\  description: not-the-description
        \\  version: "1.0"
        \\custom-field: {nested: [one, two]}
        \\---
        \\Read references/guide.md, then run scripts/extract.py.
    );
    try std.testing.expectEqualStrings("pdf-processing", parsed.name);
    try std.testing.expectEqualStrings("Extract PDFs: text and tables. Use for document analysis.", parsed.description);
    try std.testing.expect(std.mem.startsWith(u8, parsed.content, "Read references/guide.md"));
    try std.testing.expect(std.mem.indexOf(u8, parsed.frontmatter, "allowed-tools: Bash(git:*) Read") != null);
    const literal = try skills.parseFrontmatter(arena, "---\r\nname: demo\r\ndescription: |\r\n  line one\r\n  ---\r\n  line three\r\n---\r\nbody\r\n");
    try std.testing.expectEqualStrings("line one\n---\nline three\n", literal.description);
    try std.testing.expectEqualStrings("body\r\n", literal.content);
    const quoted = try skills.parseFrontmatter(arena, "\xef\xbb\xbf---\nname: demo\ndescription: \"A \\\"quoted\\\" value: \\u00e9\" # trailing comment\n---\n");
    try std.testing.expectEqualStrings("A \"quoted\" value: é", quoted.description);
    const single = try skills.parseFrontmatter(arena, "---\nname: demo\ndescription: 'It''s a skill'\n---\n");
    try std.testing.expectEqualStrings("It's a skill", single.description);
}

test "invalid skill metadata is rejected without nested fields becoming the name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.MissingSkillName, skills.parseFrontmatter(arena, "---\nmetadata:\n  name: hidden\ndescription: desc\n---\n"));
    try std.testing.expectError(error.EmptySkillMetadata, skills.parseFrontmatter(arena, "---\nname: empty\ndescription: ' '\n---\n"));
    try std.testing.expectError(error.InvalidSkillMetadata, skills.parseFrontmatter(arena, "---\nname: bad\ndescription: [not, text]\n---\n"));
    try std.testing.expectError(error.DuplicateMetadataKey, skills.parseFrontmatter(arena, "---\nname: one\nname: two\ndescription: text\n---\n"));
    try std.testing.expectError(error.InvalidYaml, skills.parseFrontmatter(arena, "---\nname: bad\ndescription: [unfinished\n---\n"));
    try std.testing.expectError(error.UnclosedFrontmatter, skills.parseFrontmatter(arena, "---\nname: bad\ndescription: text\n"));
    const large = try arena.alloc(u8, 65537);
    @memset(large, 'x');
    const too_big = try std.fmt.allocPrint(arena, "---\nname: big\ndescription: {s}\n---\n", .{large});
    try std.testing.expectError(error.FrontmatterTooLarge, skills.parseFrontmatter(arena, too_big));
}

test "bundle discovery follows symlinks, ignores resources and bounds cycles" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-skill-bundles");
    defer temp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try std.fs.path.join(arena, &.{ temp.path, "skills" });
    const body = "---\nname: review\ndescription: Review code\n---\nRead references/guide.md.\n";
    _ = try fixture(arena, io, root, "group/review/SKILL.md", body);
    _ = try fixture(arena, io, root, "group/review/references/SKILL.md", "---\nname: resource\ndescription: Bundled resource\n---\n");
    _ = try fixture(arena, io, root, "group/notes.md", "---\nname: notes\ndescription: Not a skill\n---\n");
    _ = try fixture(arena, io, root, "README.md", "---\nname: readme\ndescription: Not a skill\n---\n");
    _ = try fixture(arena, io, root, "node_modules/ignored/SKILL.md", "---\nname: ignored\ndescription: Not a skill\n---\n");
    _ = try fixture(arena, io, temp.path, "external/linked/SKILL.md", "---\nname: linked\ndescription: Linked skill\n---\nLinked instructions.\n");
    try Io.Dir.cwd().symLink(io, "../external/linked", try std.fs.path.join(arena, &.{ root, "linked" }), .{ .is_directory = true });
    try Io.Dir.cwd().symLink(io, ".", try std.fs.path.join(arena, &.{ root, "cycle" }), .{ .is_directory = true });
    var index = try Index.load(gpa, io, &.{root});
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.items.items.len);
    try std.testing.expect(index.get("review") != null);
    const linked = index.get("linked").?;
    try std.testing.expect(std.mem.indexOf(u8, linked.path, "external/linked/SKILL.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, index.prompt, "Linked instructions") == null);
    try std.testing.expect(std.mem.indexOf(u8, index.schema_json, "\"enum\":[\"linked\",\"review\"]") != null);
}

test "project skills override user skills, refresh each turn and stay isolated by cwd" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-project-skills");
    defer temp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user_root = try std.fs.path.join(arena, &.{ temp.path, "user" });
    const one = try std.fs.path.join(arena, &.{ temp.path, "one" });
    const two = try std.fs.path.join(arena, &.{ temp.path, "two" });
    const header = "---\nname: review\ndescription: Review code\n---\n";
    _ = try fixture(arena, io, user_root, "review/SKILL.md", header ++ "user");
    const project_path = try fixture(arena, io, one, ".agents/skills/review/SKILL.md", header ++ "project one");
    _ = try fixture(arena, io, two, ".agents/skills/review/SKILL.md", header ++ "shared project two");
    _ = try fixture(arena, io, two, ".marlin/skills/review/SKILL.md", header ++ "native project two");
    var user = try Index.load(gpa, io, &.{user_root});
    defer user.deinit();
    var first = try user.forProject(io, one);
    defer first.deinit();
    var second = try user.forProject(io, two);
    defer second.deinit();
    try std.testing.expectEqualStrings("user", user.get("review").?.content);
    try std.testing.expectEqualStrings("project one", first.get("review").?.content);
    try std.testing.expectEqualStrings("native project two", second.get("review").?.content);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = project_path, .data = header ++ "edited" });
    var refreshed = try user.forProject(io, one);
    defer refreshed.deinit();
    try std.testing.expectEqualStrings("edited", refreshed.get("review").?.content);
    try std.testing.expectEqualStrings("project one", first.get("review").?.content);
    var empty = try Index.load(gpa, io, &.{});
    defer empty.deinit();
    try std.testing.expectEqualStrings("", empty.prompt);
    var project_only = try empty.forProject(io, one);
    defer project_only.deinit();
    const loaded = try project_only.loadContent(gpa, "{\"name\":\"review\"}");
    defer gpa.free(loaded);
    try std.testing.expect(std.mem.endsWith(u8, loaded, "edited"));
    try std.testing.expect(std.mem.indexOf(u8, loaded, ".agents/skills/review") != null);
}
