const std = @import("std");
const Io = std.Io;
const plugins = @import("plugins.zig");
const skills = @import("skills.zig");
const commands = @import("../core/plugin_command.zig");

fn write(a: std.mem.Allocator, io: Io, root: []const u8, relative: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ root, relative });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn git(a: std.mem.Allocator, io: Io, repo: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "git", "-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" });
    try argv.appendSlice(a, args);
    const result = try @import("process_io.zig").run(a, io, .{ .argv = argv.items });
    defer result.deinit(a);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

fn command(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, root: []const u8, action: commands.Action, argument: []const u8, ok: bool, contains: []const u8) !void {
    const result = try plugins.run(gpa, io, env, root, "/", .{ .action = action, .argument = argument }, null);
    defer gpa.free(result.message);
    if (result.ok != ok or std.mem.indexOf(u8, result.message, contains) == null) std.debug.print("unexpected plugin result: {s}\n", .{result.message});
    try std.testing.expectEqual(ok, result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.message, contains) != null);
}

const marketplace =
    \\{"name":"fixture-market","owner":{"name":"Fixture"},"plugins":[{"name":"demo","source":"./plugins/demo"}]}
;
const manifest = "{\"name\":\"demo\",\"version\":\"1.0.0\"}";
const skill = "---\nname: review\ndescription: Review a change\n---\nPLUGIN_V1: read references/guide.md then review $ARGUMENTS.\n";

test "plugin commands parse strictly and names cannot be filesystem paths" {
    try std.testing.expectEqual(commands.Action.list, commands.parse(&.{}).?.action);
    try std.testing.expectEqual(commands.Action.marketplace_add, commands.parse(&.{ "marketplace", "add", "owner/repo" }).?.action);
    try std.testing.expectEqualStrings("demo@fixture-market", commands.parse(&.{ "install", "demo@fixture-market" }).?.argument);
    try std.testing.expect(commands.parse(&.{"install"}) == null);
    try std.testing.expect(commands.parse(&.{ "marketplace", "update", "x", "extra" }) == null);
    try std.testing.expect(!plugins.validName("../escape"));
    try std.testing.expect(!plugins.validName("--upload-pack=bad"));
    try std.testing.expect(!plugins.validName("x/y"));
    try std.testing.expect(plugins.validName("miradorlabs"));
}

test "skill-only marketplace install update rollback and uninstall use immutable snapshots" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-plugins");
    defer temp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const repo = try std.fs.path.join(a, &.{ temp.path, "repo" });
    const root = try std.fs.path.join(a, &.{ temp.path, "installed" });
    try write(a, io, repo, ".claude-plugin/marketplace.json", marketplace);
    try write(a, io, repo, "plugins/demo/.claude-plugin/plugin.json", manifest);
    try write(a, io, repo, "plugins/demo/skills/review/SKILL.md", skill);
    try write(a, io, repo, "plugins/demo/skills/review/references/guide.md", "RESOURCE_V1");
    try git(gpa, io, repo, &.{ "init", "-q" });
    try git(gpa, io, repo, &.{ "add", "." });
    try git(gpa, io, repo, &.{ "commit", "-qm", "first" });
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", temp.path);
    try command(gpa, io, &env, root, .marketplace_add, repo, true, "demo@fixture-market");
    try command(gpa, io, &env, root, .install, "demo@fixture-market", true, "Installed");
    try command(gpa, io, &env, root, .marketplace_remove, "fixture-market", false, "Uninstall");
    var base = try skills.Index.load(gpa, io, &.{});
    defer base.deinit();
    base.plugin_root = try gpa.dupe(u8, root);
    var first = try base.forProject(io, temp.path);
    defer first.deinit();
    const loaded = first.get("demo:review").?;
    try std.testing.expect(first.get("review") == null);
    const rendered = try first.renderInvocation(gpa, "demo:review", "parser");
    defer gpa.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "then review parser.") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.schema_json, "demo:review") != null);
    const old_resource = try std.fs.path.join(a, &.{ std.fs.path.dirname(loaded.path).?, "references", "guide.md" });

    try write(a, io, repo, "plugins/demo/.claude-plugin/plugin.json", "{\"name\":\"demo\",\"version\":\"2.0.0\"}");
    try write(a, io, repo, "plugins/demo/skills/review/SKILL.md", "---\nname: review\ndescription: Updated review\n---\nPLUGIN_V2\n");
    try write(a, io, repo, "plugins/demo/skills/review/references/guide.md", "RESOURCE_V2");
    try git(gpa, io, repo, &.{ "add", "." });
    try git(gpa, io, repo, &.{ "commit", "-qm", "second" });
    try command(gpa, io, &env, root, .marketplace_update, "fixture-market", true, "Updated");
    var second = try base.forProject(io, temp.path);
    defer second.deinit();
    try std.testing.expectEqualStrings("PLUGIN_V2\n", second.get("demo:review").?.content);
    const old_bytes = try Io.Dir.cwd().readFileAlloc(io, old_resource, gpa, .limited(1024));
    defer gpa.free(old_bytes);
    try std.testing.expectEqualStrings("RESOURCE_V1", old_bytes);
    try std.testing.expect(std.mem.startsWith(u8, loaded.content, "PLUGIN_V1"));

    try write(a, io, repo, "plugins/demo/.mcp.json", "{\"mcpServers\":{}}");
    try git(gpa, io, repo, &.{ "add", "." });
    try git(gpa, io, repo, &.{ "commit", "-qm", "unsupported" });
    try command(gpa, io, &env, root, .marketplace_update, "fixture-market", false, "Only skill-only plugins");
    var after_failure = try base.forProject(io, temp.path);
    defer after_failure.deinit();
    try std.testing.expectEqualStrings(second.get("demo:review").?.path, after_failure.get("demo:review").?.path);
    try command(gpa, io, &env, root, .list, "", true, "2.0.0");
    try command(gpa, io, &env, root, .uninstall, "demo@fixture-market", true, "Uninstalled");
    var removed = try base.forProject(io, temp.path);
    defer removed.deinit();
    try std.testing.expect(removed.get("demo:review") == null);
    try command(gpa, io, &env, root, .marketplace_remove, "fixture-market", true, "Removed");
}

test "plugin installer rejects remote plugin sources and path escapes without changing registry" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-plugin-reject");
    defer temp.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const repo = try std.fs.path.join(a, &.{ temp.path, "repo" });
    const root = try std.fs.path.join(a, &.{ temp.path, "installed" });
    try write(a, io, repo, ".claude-plugin/marketplace.json",
        \\{"name":"bad-market","plugins":[{"name":"escape","source":"../outside"},{"name":"remote","source":{"source":"github","repo":"owner/repo"}},{"name":"hooks","source":"plugins/hooks","hooks":{}},{"name":"linked","source":"plugins/linked"},{"name":"resource","source":"plugins/resource"}]}
    );
    try write(a, io, repo, "outside/secret.md", "outside the plugin");
    try write(a, io, repo, "plugins/resource/.claude-plugin/plugin.json", "{\"name\":\"resource\"}");
    try write(a, io, repo, "plugins/resource/skills/review/SKILL.md", skill);
    try Io.Dir.cwd().symLink(io, "../../../../outside/secret.md", try std.fs.path.join(a, &.{ repo, "plugins/resource/skills/review/reference.md" }), .{});
    try Io.Dir.cwd().symLink(io, temp.path, try std.fs.path.join(a, &.{ repo, "plugins/linked" }), .{ .is_directory = true });
    try git(gpa, io, repo, &.{ "init", "-q" });
    try git(gpa, io, repo, &.{ "add", "." });
    try git(gpa, io, repo, &.{ "commit", "-qm", "fixture" });
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("HOME", temp.path);
    try command(gpa, io, &env, root, .marketplace_add, repo, true, "bad-market");
    try command(gpa, io, &env, root, .install, "escape@bad-market", false, "UnsafePluginPath");
    try command(gpa, io, &env, root, .install, "remote@bad-market", false, "Only plugin sources");
    try command(gpa, io, &env, root, .install, "hooks@bad-market", false, "Only skill-only plugins");
    try command(gpa, io, &env, root, .install, "linked@bad-market", false, "UnsafePluginPath");
    try command(gpa, io, &env, root, .install, "resource@bad-market", false, "UnsafePluginPath");
    try command(gpa, io, &env, root, .marketplace_add, "-bad-option", false, "InvalidMarketplaceSource");
    try command(gpa, io, &env, root, .marketplace_remove, "bad-market", true, "Removed");
}
