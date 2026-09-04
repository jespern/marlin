//! Unit tests for extensions.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in extensions.zig.

const std = @import("std");
const Io = std.Io;
const config = @import("../core/config.zig");
const block = @import("../core/block.zig");
const hooks = @import("hooks.zig");
const permissions = @import("permissions.zig");
const skills = @import("skills.zig");
const exec_tool = @import("tools/exec_tool.zig");
const mcp = @import("tools/mcp.zig");
const registry = @import("tools/registry.zig");
const Spec = registry.Spec;
const ExecOut = registry.ExecOut;

const extensions = @import("extensions.zig");
const Runtime = extensions.Runtime;

test {
    std.testing.refAllDecls(extensions);
}

test "runtime registers and dispatches exec tools and skills" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-extension");
    defer temp.deinit();
    const root = temp.path;
    const skill_path = try std.fs.path.join(gpa, &.{ root, "demo.md" });
    defer gpa.free(skill_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = skill_path, .data =
        \\---
        \\name: demo
        \\description: Demonstrate runtime skills
        \\---
        \\Follow the demo instructions.
    });

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");
    const cfg = config.Config{
        .skill_directories = &.{root},
        .exec_tools = &.{.{
            .name = "echo_json",
            .cmd = &.{ "sh", "-c", "cat" },
            .description = "Echo JSON",
            .schema = "{\"type\":\"object\"}",
            .mutating = false,
            .parallel_safe = true,
            .timeout_ms = 2_000,
        }},
    };
    const runtime = try Runtime.init(gpa, io, cfg, &environ);
    defer runtime.deinit();
    try std.testing.expect(runtime.find("echo_json") != null);
    try std.testing.expect(runtime.find("skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime.systemPromptSuffix(), "demo: Demonstrate") != null);
    const result = runtime.dispatch("echo_json", "{\"ok\":true}", "/tmp", null).?;
    defer gpa.free(result.output);
    try std.testing.expectEqual(block.ToolStatus.ok, result.status);
    try std.testing.expectEqualStrings("{\"ok\":true}", result.output);
}

test "MCP discovery failures are isolated and tool policy is per-tool" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/bin:/bin");

    const script =
        \\while IFS= read -r line; do
        \\  case "$line" in
        \\    *'"method":"tools/list"'*) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete","tools":[{"name":"inspect","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true}},{"name":"change","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":false}},{"name":"forced_read","inputSchema":{"type":"object"}},{"name":"forced_write","inputSchema":{"type":"object"}}]}}' ;;
        \\  esac
        \\done
    ;
    const cfg = config.Config{ .mcp_servers = &.{
        .{
            .name = "healthy",
            .cmd = &.{ "sh", "-c", script },
            .mutating = true,
            .readonly_tools = &.{"forced_read"},
            .mutating_tools = &.{"forced_write"},
        },
        .{ .name = "broken", .cmd = &.{ "sh", "-c", "exit 7" }, .mutating = true },
    } };
    var runtime = try Runtime.init(gpa, threaded.io(), cfg, &environ);
    defer runtime.deinit();

    const statuses = try runtime.mcpStatuses(gpa);
    defer gpa.free(statuses);
    try std.testing.expectEqual(@as(usize, 2), statuses.len);
    try std.testing.expect(statuses[0].ready);
    try std.testing.expect(!statuses[1].ready);
    try std.testing.expect(!runtime.find("mcp__healthy__inspect").?.mutating);
    try std.testing.expect(runtime.find("mcp__healthy__change").?.mutating);
    try std.testing.expect(!runtime.find("mcp__healthy__forced_read").?.mutating);
    try std.testing.expect(runtime.find("mcp__healthy__forced_write").?.mutating);
    try std.testing.expectError(error.UnknownMcpServer, runtime.restartMcp("missing"));
    try std.testing.expect(runtime.find("mcp__healthy__inspect") != null);
}
