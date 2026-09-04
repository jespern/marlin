//! Unit tests for permissions.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in permissions.zig.

const std = @import("std");

const permissions = @import("permissions.zig");
const Capability = permissions.Capability;
const PathLocation = permissions.PathLocation;
const assessPath = permissions.assessPath;
const ccAutoAllow = permissions.ccAutoAllow;
const ccReadOnlyAllow = permissions.ccReadOnlyAllow;
const collectSecrets = permissions.collectSecrets;
const isProtectedPath = permissions.isProtectedPath;
const isSecretEnvironmentName = permissions.isSecretEnvironmentName;
const redactSecrets = permissions.redactSecrets;
const toolEnvironment = permissions.toolEnvironment;
const workspaceWriteAllowed = permissions.workspaceWriteAllowed;

test {
    std.testing.refAllDecls(permissions);
}

test "workspace write authorization is symlink-safe" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const base = try std.fmt.allocPrint(gpa, "/tmp/marlin-wswrite-test-{x}", .{std.mem.readInt(u64, &rand, .little)});
    defer gpa.free(base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    const ws = try std.fs.path.join(gpa, &.{ base, "ws" });
    defer gpa.free(ws);
    const outside = try std.fs.path.join(gpa, &.{ base, "outside" });
    defer gpa.free(outside);
    try std.Io.Dir.cwd().createDirPath(io, ws);
    try std.Io.Dir.cwd().createDirPath(io, outside);

    // A symlink inside the workspace pointing out of it.
    const link = try std.fs.path.join(gpa, &.{ ws, "escape" });
    defer gpa.free(link);
    const ln = try std.process.run(gpa, io, .{
        .argv = &.{ "/bin/ln", "-s", outside, link },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(ln.stdout);
    defer gpa.free(ln.stderr);

    // Ordinary workspace targets: existing dirs and yet-to-exist files.
    try std.testing.expect(workspaceWriteAllowed(gpa, io, ws, "{\"path\":\"src/main.zig\"}"));
    try std.testing.expect(workspaceWriteAllowed(gpa, io, ws, "{\"path\":\"deep/new/dir/file.txt\"}"));
    // Lexical escapes and absolute outside targets.
    try std.testing.expect(!workspaceWriteAllowed(gpa, io, ws, "{\"path\":\"../outside/x\"}"));
    try std.testing.expect(!workspaceWriteAllowed(gpa, io, ws, "{\"path\":\"/etc/hosts\"}"));
    // The symlink escape: lexically inside, physically outside.
    try std.testing.expect(!workspaceWriteAllowed(gpa, io, ws, "{\"path\":\"escape/x\"}"));
    // Garbage arguments fail closed.
    try std.testing.expect(!workspaceWriteAllowed(gpa, io, ws, "{not json"));
    try std.testing.expect(!workspaceWriteAllowed(gpa, io, ws, "{}"));
}

test "secret environment names cover provider keys and configured patterns" {
    try std.testing.expect(isSecretEnvironmentName("OPENROUTER_API_KEY"));
    try std.testing.expect(isSecretEnvironmentName("openai_api_key"));
    try std.testing.expect(isSecretEnvironmentName("GITHUB_TOKEN"));
    try std.testing.expect(isSecretEnvironmentName("DEPLOY_SECRET"));
    try std.testing.expect(isSecretEnvironmentName("AWS_ACCESS_KEY_ID"));
    try std.testing.expect(isSecretEnvironmentName("OTEL_EXPORTER_OTLP_HEADERS"));

    try std.testing.expect(!isSecretEnvironmentName("PATH"));
    try std.testing.expect(!isSecretEnvironmentName("HOME"));
    try std.testing.expect(!isSecretEnvironmentName("MARLIN_SOCKET"));
    try std.testing.expect(!isSecretEnvironmentName("TOKENIZER_PATH"));
}

test "tool environment retains process context and removes secrets" {
    const gpa = std.testing.allocator;
    var source = std.process.Environ.Map.init(gpa);
    defer source.deinit();
    try source.put("PATH", "/usr/bin:/bin");
    try source.put("HOME", "/tmp/example-home");
    try source.put("OPENROUTER_API_KEY", "never-in-child");
    try source.put("GH_TOKEN", "also-never-in-child");
    try source.put("OTEL_EXPORTER_OTLP_HEADERS", "Authorization=Bearer%20mir_srv_secret");
    try source.put("AWS_REGION", "also-stripped-by-policy");

    var child = try toolEnvironment(gpa, &source);
    defer child.deinit();

    try std.testing.expectEqualStrings("/usr/bin:/bin", child.get("PATH").?);
    try std.testing.expectEqualStrings("/tmp/example-home", child.get("HOME").?);
    try std.testing.expect(child.get("OPENROUTER_API_KEY") == null);
    try std.testing.expect(child.get("GH_TOKEN") == null);
    try std.testing.expect(child.get("OTEL_EXPORTER_OTLP_HEADERS") == null);
    try std.testing.expect(child.get("AWS_REGION") == null);
}

test "path assessment keeps exact cwd boundary and resolves dot segments" {
    const gpa = std.testing.allocator;

    var inside = try assessPath(gpa, "/work/api", "src/../src/main.zig");
    defer inside.deinit(gpa);
    try std.testing.expectEqual(PathLocation.workspace, inside.location);
    try std.testing.expectEqual(Capability.fs_read, inside.capability(.read));
    try std.testing.expectEqual(Capability.fs_write_workspace, inside.capability(.write));
    try std.testing.expectEqualStrings("/work/api/src/main.zig", inside.resolved);

    var sibling = try assessPath(gpa, "/work/api", "../api-client/out.txt");
    defer sibling.deinit(gpa);
    try std.testing.expectEqual(PathLocation.outside, sibling.location);
    try std.testing.expectEqual(Capability.fs_write_outside, sibling.capability(.write));

    var prefix_collision = try assessPath(gpa, "/work/api", "/work/api-other/file");
    defer prefix_collision.deinit(gpa);
    try std.testing.expectEqual(PathLocation.outside, prefix_collision.location);
}

test "protected path policy recognizes credential material by component and basename" {
    const gpa = std.testing.allocator;
    const protected = [_][]const u8{
        "/work/api/.env",
        "/work/api/.env.production",
        "/Users/example/.ssh/config",
        "/Users/example/.aws/credentials",
        "/Users/example/.config/marlin/credentials",
        "/work/api/certs/client.pem",
        "/work/api/certs/signing.key",
        "/work/api/id_ed25519",
    };
    for (protected) |path| {
        try std.testing.expect(isProtectedPath(path));
    }
    try std.testing.expect(!isProtectedPath("/work/api/src/environment.zig"));
    try std.testing.expect(!isProtectedPath("/work/api/docs/credentials.md"));
    try std.testing.expect(!isProtectedPath("/work/marlin/credentials"));

    var assessed = try assessPath(gpa, "/work/api", ".env.local");
    defer assessed.deinit(gpa);
    try std.testing.expect(assessed.protected);
    try std.testing.expectEqual(Capability.fs_read, assessed.capability(.read));

    var external = try assessPath(gpa, "/work/api", "/Users/example/.ssh/config");
    defer external.deinit(gpa);
    try std.testing.expectEqual(Capability.fs_read_protected, external.capability(.read));
}

test "cc bridge policy: reads auto, edits containment-checked, unknown asks" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try std.testing.expect(ccAutoAllow(gpa, io, "/work/api", "Read", "{\"file_path\":\"/etc/hosts\"}"));
    try std.testing.expect(ccAutoAllow(gpa, io, "/work/api", "Grep", "{\"pattern\":\"x\"}"));
    try std.testing.expect(ccAutoAllow(gpa, io, "/work/api", "WebFetch", "{\"url\":\"https://x\"}"));

    // Edits outside the workspace or on protected names must ask.
    try std.testing.expect(!ccAutoAllow(gpa, io, "/work/api", "Write", "{\"file_path\":\"/etc/hosts\"}"));
    try std.testing.expect(!ccAutoAllow(gpa, io, "/work/api", "Edit", "{\"file_path\":\"/work/api/.env\"}"));
    try std.testing.expect(!ccAutoAllow(gpa, io, "/work/api", "Edit", "{}"));

    // Unknown tools (MCP and future ones) always ask.
    try std.testing.expect(!ccAutoAllow(gpa, io, "/work/api", "mcp__x__y", "{}"));
}

test "cc bridge policy: workspace edits allowed on a real tree" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var rand: [8]u8 = undefined;
    io.random(&rand);
    const ws = try std.fmt.allocPrint(gpa, "/tmp/marlin-ccpolicy-{x}", .{std.mem.readInt(u64, &rand, .little)});
    defer gpa.free(ws);
    defer std.Io.Dir.cwd().deleteTree(io, ws) catch {};
    try std.Io.Dir.cwd().createDirPath(io, ws);

    const args = try std.fmt.allocPrint(gpa, "{{\"file_path\":\"{s}/src/new.zig\"}}", .{ws});
    defer gpa.free(args);
    try std.testing.expect(ccAutoAllow(gpa, io, ws, "Write", args));
}

test "cc bridge policy: shell commands inside the root run, escapes ask" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cwd = "/work/api";

    const allowed = [_][]const u8{
        "zig build test",
        "zig build test 2>/dev/null",
        "git log --oneline -5 | head",
        "rg -n 'pattern' src/main.zig",
        "python3 /tmp/scratch.py",
        "make -C src all",
        "cat src/../README.md",
        "git commit -m \"fix: paths like a/b in messages\"",
    };
    for (allowed) |cmd| {
        const args = try std.json.Stringify.valueAlloc(gpa, .{ .command = cmd }, .{});
        defer gpa.free(args);
        try std.testing.expect(ccAutoAllow(gpa, io, cwd, "Bash", args));
    }

    const asks = [_][]const u8{
        "rm -rf /Users/example/other-project",
        "cat ~/.ssh/id_ed25519",
        "cat ../sibling/secrets.txt",
        "cp x.pem /work/api/", // protected basename mention
        "git -C /work/other status",
        "echo hi > ~/notes.txt",
        "cat /tmp/../etc/passwd", // benign prefix must not mask an escape
        "echo x > /dev/../etc/cron.d/evil",
    };
    for (asks) |cmd| {
        const args = try std.json.Stringify.valueAlloc(gpa, .{ .command = cmd }, .{});
        defer gpa.free(args);
        try std.testing.expect(!ccAutoAllow(gpa, io, cwd, "Bash", args));
    }
}

test "secret collection and exact-value redaction" {
    const gpa = std.testing.allocator;
    var source = std.process.Environ.Map.init(gpa);
    defer source.deinit();
    try source.put("OPENROUTER_API_KEY", "sk-or-v1-abcdef123456");
    try source.put("GH_TOKEN", "ghp_zyxwvut987654");
    try source.put("SHORT_TOKEN", "x"); // too short to redact safely
    try source.put("PATH", "/usr/bin");

    const secrets = try collectSecrets(gpa, &source);
    defer gpa.free(secrets);
    try std.testing.expectEqual(@as(usize, 2), secrets.len);

    const dirty = "key=sk-or-v1-abcdef123456 and ghp_zyxwvut987654 twice ghp_zyxwvut987654";
    const clean = (try redactSecrets(gpa, secrets, dirty)).?;
    defer gpa.free(clean);
    try std.testing.expect(std.mem.indexOf(u8, clean, "sk-or-v1") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "ghp_") == null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "[REDACTED:OPENROUTER_API_KEY]") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean, "[REDACTED:GH_TOKEN]") != null);

    // The common case (no secrets present) allocates nothing.
    try std.testing.expectEqual(@as(?[]u8, null), try redactSecrets(gpa, secrets, "ordinary tool output"));
}

test "guest child bridge policy: reads and searches only, nothing else" {
    const allowed = [_][]const u8{ "Read", "Glob", "Grep", "WebFetch", "TodoWrite" };
    for (allowed) |tool| try std.testing.expect(ccReadOnlyAllow(tool));
    const denied = [_][]const u8{ "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Task", "mcp__x__y", "" };
    for (denied) |tool| try std.testing.expect(!ccReadOnlyAllow(tool));
}
