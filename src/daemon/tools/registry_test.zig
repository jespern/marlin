//! Unit tests for registry.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in registry.zig.

const std = @import("std");
const Io = std.Io;
const block = @import("../../core/block.zig");
const permissions = @import("../permissions.zig");
const sandbox = @import("../sandbox.zig");
const network_policy = @import("../network_policy.zig");
const shell_network = @import("../shell_network.zig");
const bash = @import("bash.zig");
const files = @import("files.zig");
const search = @import("search.zig");
const fetch_tool = @import("fetch.zig");
const task = @import("task.zig");
const plan = @import("plan.zig");

const registry = @import("registry.zig");
const configureSandboxEnvironment = registry.configureSandboxEnvironment;
const dispatch = registry.dispatch;
const find = registry.find;
const specs = registry.specs;

test {
    std.testing.refAllDecls(registry);
}

test "find: all specs resolvable, unknown is null" {
    for (&specs) |*s| {
        try std.testing.expect(find(s.name) != null);
    }
    try std.testing.expect(find("nope") == null);
    try std.testing.expect(find("bash").?.mutating);
    try std.testing.expect(!find("read_file").?.mutating);
    try std.testing.expect(find("grep").?.parallel_safe);
    try std.testing.expect(!find("task").?.parallel_safe);
}

test "dispatch: unknown tool returns error text, not crash" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const r = dispatch(gpa, io, "bogus", "{}", "/tmp", null, .{}, null, null);
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.err, r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.output, "unknown tool") != null);
}

test "dispatch: bad args json returns error text" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const r = dispatch(gpa, io, "read_file", "{not json", "/tmp", null, .{}, null, null);
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.err, r.status);
}

test "sandbox subprocess environment routes XDG cache into writable temp" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-tool-cache");
    defer temp.deinit();

    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("TMPDIR", "/host/tmp");
    try environ.put("XDG_CACHE_HOME", "/host/cache");
    try configureSandboxEnvironment(gpa, io, &environ, temp.path);

    const expected = try std.fs.path.join(gpa, &.{ temp.path, "cache" });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(temp.path, environ.get("TMPDIR").?);
    try std.testing.expectEqualStrings(expected, environ.get("XDG_CACHE_HOME").?);
    _ = try Io.Dir.cwd().statFile(io, expected, .{});
}

test "dispatch: file tools observe a turn already cancelled" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var cancel: std.atomic.Value(bool) = .init(true);
    const r = dispatch(
        gpa,
        threaded.io(),
        "read_file",
        "{\"path\":\"never-opened\"}",
        "/tmp",
        null,
        .{},
        null,
        &cancel,
    );
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.interrupted, r.status);
}

test "dispatch: bash policy denies atomically and null policy bypasses screening" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var policy = network_policy.Policy.init(gpa, io, &environ, .{ .deny = "blocked.test" });
    defer policy.deinit();

    var temp = try @import("../../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-network-dispatch");
    defer temp.deinit();
    const cwd = temp.path;

    const denied = dispatch(
        gpa,
        io,
        "bash",
        \\{"command":"printf touched > marker; curl https://sub.blocked.test/upload"}
    ,
        cwd,
        null,
        .{},
        &policy,
        null,
    );
    defer gpa.free(denied.output);
    try std.testing.expectEqual(block.ToolStatus.denied, denied.status);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "sub.blocked.test") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "shell command was not run") != null);
    try std.testing.expect(std.mem.indexOf(u8, denied.output, "explicit deny") != null);

    const marker = try std.fs.path.join(gpa, &.{ cwd, "marker" });
    defer gpa.free(marker);
    try std.testing.expect(Io.Dir.cwd().statFile(io, marker, .{}) catch null == null);

    // This defines a local shell function, so the disabled-policy path proves
    // the dispatch behavior without making a real network connection.
    const bypassed = dispatch(
        gpa,
        io,
        "bash",
        \\{"command":"curl() { printf bypassed; }; curl https://sub.blocked.test/upload"}
    ,
        cwd,
        null,
        .{},
        null,
        null,
    );
    defer gpa.free(bypassed.output);
    try std.testing.expectEqual(block.ToolStatus.ok, bypassed.status);
    try std.testing.expectEqualStrings("bypassed", bypassed.output);
}

test "dispatch: tool subprocess cannot see provider credentials" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var source_environ = std.process.Environ.Map.init(gpa);
    defer source_environ.deinit();
    try source_environ.put("OPENROUTER_API_KEY", "must-not-cross-boundary");
    try source_environ.put("PUBLIC_VALUE", "visible");

    const r = dispatch(
        gpa,
        io,
        "bash",
        \\{"command":"printf '%s|%s' \"${OPENROUTER_API_KEY-unset}\" \"$PUBLIC_VALUE\""}
    ,
        "/tmp",
        &source_environ,
        .{},
        null,
        null,
    );
    defer gpa.free(r.output);

    try std.testing.expectEqual(block.ToolStatus.ok, r.status);
    try std.testing.expectEqualStrings("unset|visible", r.output);
}

test "dispatch: cancelled subprocess and walker tools are reported as interrupted" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var cancel = std.atomic.Value(bool).init(true);

    const r = dispatch(
        gpa,
        threaded.io(),
        "bash",
        \\{"command":"sleep 30"}
    ,
        "/tmp",
        null,
        .{},
        null,
        &cancel,
    );
    defer gpa.free(r.output);
    try std.testing.expectEqual(block.ToolStatus.interrupted, r.status);
    try std.testing.expectEqualStrings("command interrupted by user", r.output);

    const globbed = dispatch(
        gpa,
        threaded.io(),
        "glob",
        \\{"pattern":"*.zig"}
    ,
        "/tmp",
        null,
        .{},
        null,
        &cancel,
    );
    defer gpa.free(globbed.output);
    try std.testing.expectEqual(block.ToolStatus.interrupted, globbed.status);
    try std.testing.expectEqualStrings("tool interrupted by user", globbed.output);
}
