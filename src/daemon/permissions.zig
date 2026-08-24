//! Permission capabilities and the daemon/tool secret boundary.
//!
//! The approval gate still owns user interaction. This module owns the
//! vocabulary that gate will grow into and the invariants that apply even
//! before capability approvals are enabled (most importantly: provider
//! credentials never enter tool subprocesses). See docs/PERMISSIONS.md.

const std = @import("std");

/// Stable capability names used by policy, protocol, and durable approvals.
/// Scope (path/root/host) is carried separately; do not encode it into tags.
pub const Capability = enum {
    fs_read,
    fs_read_protected,
    fs_write_workspace,
    fs_write_outside,
    process_exec,
    network_fetch,
    env_secret,
};

pub const GrantLifetime = enum { once, session };

pub const Access = enum { read, write };

pub const PathLocation = enum { workspace, outside };

/// A lexical path assessment used for approval previews and as the first
/// stage of direct-tool classification. `resolved` is normalized and owned.
/// Enforcement must additionally resolve symlinks at the I/O boundary.
pub const PathAssessment = struct {
    resolved: []u8,
    location: PathLocation,
    protected: bool,

    pub fn deinit(self: *PathAssessment, gpa: std.mem.Allocator) void {
        gpa.free(self.resolved);
        self.* = undefined;
    }

    pub fn capability(self: PathAssessment, access: Access) Capability {
        return switch (access) {
            .read => if (self.protected and self.location == .outside) .fs_read_protected else .fs_read,
            .write => if (self.location == .workspace) .fs_write_workspace else .fs_write_outside,
        };
    }
};

/// Normalize a requested path against the exact session cwd and classify its
/// lexical scope. This deliberately does no filesystem I/O: direct tools must
/// perform a second, symlink-aware check immediately before opening the path.
pub fn assessPath(
    gpa: std.mem.Allocator,
    cwd: []const u8,
    requested: []const u8,
) !PathAssessment {
    const canonical_cwd = try std.fs.path.resolve(gpa, &.{cwd});
    defer gpa.free(canonical_cwd);
    const resolved = if (std.fs.path.isAbsolute(requested))
        try std.fs.path.resolve(gpa, &.{requested})
    else
        try std.fs.path.resolve(gpa, &.{ cwd, requested });
    errdefer gpa.free(resolved);

    return .{
        .resolved = resolved,
        .location = if (isWithin(canonical_cwd, resolved)) .workspace else .outside,
        .protected = isProtectedPath(resolved),
    };
}

/// Symlink-safe workspace-write authorization for the direct file tools
/// (write_file/edit): the auto-inside policy may skip the approval prompt
/// only when the REAL target provably stays inside the REAL workspace.
/// `args_json` is the tool call's raw arguments; anything unparseable or
/// unprovable answers false and the legacy prompt applies.
///
/// Symlink safety: walk up from the resolved target to the deepest EXISTING
/// ancestor and realpath it — nonexistent trailing components cannot be
/// symlinks, so ancestor containment is sufficient for paths being created.
pub fn workspaceWriteAllowed(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    args_json: []const u8,
) bool {
    const parsed = std.json.parseFromSlice(
        struct { path: []const u8 },
        gpa,
        args_json,
        .{ .ignore_unknown_fields = true },
    ) catch return false;
    defer parsed.deinit();

    var assessed = assessPath(gpa, cwd, parsed.value.path) catch return false;
    defer assessed.deinit(gpa);
    if (assessed.location != .workspace) return false;

    const real_cwd = std.Io.Dir.realPathFileAbsoluteAlloc(io, cwd, gpa) catch return false;
    defer gpa.free(real_cwd);

    var candidate: []const u8 = assessed.resolved;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        if (std.Io.Dir.realPathFileAbsoluteAlloc(io, candidate, gpa)) |real| {
            defer gpa.free(real);
            return isWithin(real_cwd, real);
        } else |_| {
            candidate = std.fs.path.dirname(candidate) orelse return false;
        }
    }
    return false;
}

/// Conservative built-in protected-path policy. Matching is component-aware
/// for credential directories and basename-aware for common secret files.
/// Configurable additions and explicit grants land with rich approvals.
pub fn isProtectedPath(path: []const u8) bool {
    var components = std.fs.path.componentIterator(path);
    while (components.next()) |component| {
        const name = component.name;
        if (std.ascii.eqlIgnoreCase(name, ".ssh")) return true;
        if (std.ascii.eqlIgnoreCase(name, ".aws")) return true;
        if (std.ascii.eqlIgnoreCase(name, ".gnupg")) return true;
    }

    const base = std.fs.path.basename(path);
    if (hasComponentSequence(path, &.{ ".config", "marlin", "credentials" })) return true;
    if (std.ascii.eqlIgnoreCase(base, ".env") or startsWithIgnoreCase(base, ".env.")) return true;
    if (std.ascii.eqlIgnoreCase(base, "id_rsa")) return true;
    if (std.ascii.eqlIgnoreCase(base, "id_dsa")) return true;
    if (std.ascii.eqlIgnoreCase(base, "id_ecdsa")) return true;
    if (std.ascii.eqlIgnoreCase(base, "id_ed25519")) return true;
    if (endsWithIgnoreCase(base, "_rsa")) return true;
    if (endsWithIgnoreCase(base, ".pem")) return true;
    if (endsWithIgnoreCase(base, ".key")) return true;
    if (endsWithIgnoreCase(base, ".p12")) return true;
    if (endsWithIgnoreCase(base, ".pfx")) return true;
    return false;
}

/// Built-in secret-name policy. This is intentionally name-based: values are
/// handled by capture-time redaction, while the environment boundary must
/// decide what to omit before a child exists.
pub fn isSecretEnvironmentName(name: []const u8) bool {
    // Current provider credentials are listed explicitly so a future rename
    // cannot accidentally fall out of a generic suffix rule.
    if (std.ascii.eqlIgnoreCase(name, "OPENROUTER_API_KEY")) return true;
    if (std.ascii.eqlIgnoreCase(name, "MARLIN_LOCAL_API_KEY")) return true;

    if (startsWithIgnoreCase(name, "AWS_")) return true;
    if (endsWithIgnoreCase(name, "_API_KEY")) return true;
    if (endsWithIgnoreCase(name, "_TOKEN")) return true;
    if (endsWithIgnoreCase(name, "_SECRET")) return true;
    return false;
}

/// Build the complete environment visible to a tool subprocess. Non-secret
/// process context is retained (PATH/HOME/locale/etc.); matching credentials
/// are omitted. Caller owns the returned map.
pub fn toolEnvironment(
    gpa: std.mem.Allocator,
    source: *const std.process.Environ.Map,
) !std.process.Environ.Map {
    var out = std.process.Environ.Map.init(gpa);
    errdefer out.deinit();

    var it = source.iterator();
    while (it.next()) |entry| {
        if (isSecretEnvironmentName(entry.key_ptr.*)) continue;
        try out.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return out;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    return value.len >= suffix.len and std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn hasComponentSequence(path: []const u8, expected: []const []const u8) bool {
    if (expected.len == 0) return true;
    var matched: usize = 0;
    var components = std.fs.path.componentIterator(path);
    while (components.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component.name, expected[matched])) {
            matched += 1;
            if (matched == expected.len) return true;
        } else {
            matched = if (std.ascii.eqlIgnoreCase(component.name, expected[0])) 1 else 0;
        }
    }
    return false;
}

/// Component-boundary containment: true when `candidate` is `root` itself
/// or lexically below it. Both sides must already be normalized (and, at
/// enforcement boundaries, symlink-resolved).
pub fn isWithin(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (root.len == 0 or candidate.len <= root.len) return false;
    if (std.fs.path.isSep(root[root.len - 1])) return true;
    return std.fs.path.isSep(candidate[root.len]);
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
    try source.put("AWS_REGION", "also-stripped-by-policy");

    var child = try toolEnvironment(gpa, &source);
    defer child.deinit();

    try std.testing.expectEqualStrings("/usr/bin:/bin", child.get("PATH").?);
    try std.testing.expectEqualStrings("/tmp/example-home", child.get("HOME").?);
    try std.testing.expect(child.get("OPENROUTER_API_KEY") == null);
    try std.testing.expect(child.get("GH_TOKEN") == null);
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
