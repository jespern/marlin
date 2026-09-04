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
    return realPathInWorkspace(gpa, io, cwd, parsed.value.path);
}

/// Symlink-safe workspace containment for one requested path: lexical
/// normalization first, then realpath of the deepest EXISTING ancestor
/// (nonexistent trailing components cannot be symlinks). True only when the
/// REAL target provably stays inside the REAL workspace.
pub fn realPathInWorkspace(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    requested: []const u8,
) bool {
    var assessed = assessPath(gpa, cwd, requested) catch return false;
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

/// Auto-approval policy for the Claude Code permission bridge
/// (`marlin cc_approve`): mirror the native auto-inside posture for prompts a
/// delegated `claude -p` routes to marlin. Reads and searches are always auto
/// (native read-only policy). Edits must provably stay inside the real
/// workspace and off protected paths. Shell commands are approved unless they
/// mention a path outside the workspace or a protected name. Honest posture:
/// a token the scan cannot place ASKS, but a shape it does not look for
/// ALLOWS — this is guest-mux convenience under the wall's rules
/// (ARCHITECTURE, Native vs guest), not a security boundary, and it must not
/// grow toward one.
pub fn ccAutoAllow(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    tool_name: []const u8,
    input_json: []const u8,
) bool {
    const read_only = [_][]const u8{
        "Read",     "Glob",      "Grep", "LS",           "NotebookRead",
        "WebFetch", "WebSearch", "Task", "ExitPlanMode", "TodoWrite",
    };
    for (read_only) |name| if (std.mem.eql(u8, tool_name, name)) return true;

    const edit_tools = [_][]const u8{ "Edit", "Write", "MultiEdit", "NotebookEdit" };
    for (edit_tools) |name| {
        if (!std.mem.eql(u8, tool_name, name)) continue;
        const parsed = std.json.parseFromSlice(
            struct {
                file_path: ?[]const u8 = null,
                notebook_path: ?[]const u8 = null,
                path: ?[]const u8 = null,
            },
            gpa,
            input_json,
            .{ .ignore_unknown_fields = true },
        ) catch return false;
        defer parsed.deinit();
        const path = parsed.value.file_path orelse
            parsed.value.notebook_path orelse
            parsed.value.path orelse return false;
        if (isProtectedPath(path)) return false;
        return realPathInWorkspace(gpa, io, cwd, path);
    }

    if (std.mem.eql(u8, tool_name, "Bash")) {
        const parsed = std.json.parseFromSlice(
            struct { command: ?[]const u8 = null },
            gpa,
            input_json,
            .{ .ignore_unknown_fields = true },
        ) catch return false;
        defer parsed.deinit();
        const command = parsed.value.command orelse return false;
        return commandStaysInWorkspace(gpa, cwd, command);
    }
    return false;
}

/// Bridge policy for GUEST CHILD sessions (council reviewers spawned via
/// task/task_batch with a claudecode/ model): read-only by enforcement, the
/// same posture marlin's dispatch loop hard-codes for native children.
/// Marlin cannot reach inside the `claude -p` subprocess, but every one of
/// its tool prompts flows through cc_approval — so the child policy DENIES
/// mutations outright (never asks, never auto-allows). No shell at all:
/// native read-only children have none either, and reads-vs-writes cannot
/// be told apart in bash.
pub fn ccReadOnlyAllow(tool_name: []const u8) bool {
    const read_only = [_][]const u8{
        "Read",     "Glob",      "Grep",      "LS", "NotebookRead",
        "WebFetch", "WebSearch", "TodoWrite",
    };
    for (read_only) |name| if (std.mem.eql(u8, tool_name, name)) return true;
    return false;
}

/// Lexical scan of a shell command for paths that leave the workspace or
/// name protected files. Tokens that resolve inside the cwd (or into the
/// usual scratch locations) pass; `~`, escaping relatives, and any other
/// absolute path make the command ask instead.
fn commandStaysInWorkspace(gpa: std.mem.Allocator, cwd: []const u8, command: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, command, " \t\r\n");
    while (it.next()) |raw| {
        const tok = strippedPathToken(raw);
        if (tok.len == 0) continue;
        if (isProtectedPath(tok)) return false;
        if (tok[0] == '~') return false;
        // A dotted token is never benign: /tmp/../etc/passwd must reach
        // assessPath (found by the first council review — the shortcut used
        // to fire before the escape check).
        if (tok[0] == '/' and benignAbsolutePrefix(tok) and
            std.mem.indexOf(u8, tok, "..") == null) continue;
        if (tok[0] == '/' or std.mem.indexOf(u8, tok, "..") != null) {
            var assessed = assessPath(gpa, cwd, tok) catch return false;
            defer assessed.deinit(gpa);
            if (assessed.location != .workspace) return false;
        }
    }
    return true;
}

/// Strip shell noise so a token's path core is visible to the scan:
/// surrounding quotes/grouping, redirection prefixes (2>/dev/null, >>out),
/// and `--flag=/path` values.
fn strippedPathToken(raw: []const u8) []const u8 {
    var tok = std.mem.trim(u8, raw, "\"'`();,");
    var i: usize = 0;
    while (i < tok.len) : (i += 1) {
        switch (tok[i]) {
            '0'...'9', '<', '>', '&' => continue,
            else => break,
        }
    }
    if (i > 0 and i < tok.len and
        (std.mem.indexOfScalar(u8, tok[0..i], '<') != null or
            std.mem.indexOfScalar(u8, tok[0..i], '>') != null))
    {
        tok = tok[i..];
    }
    if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
        const rhs = tok[eq + 1 ..];
        if (rhs.len > 0 and (rhs[0] == '/' or rhs[0] == '~')) return rhs;
    }
    return tok;
}

/// Scratch locations every build tool touches; referencing them is not
/// "leaving the workspace" in any sense a human would recognize.
fn benignAbsolutePrefix(path: []const u8) bool {
    const prefixes = [_][]const u8{
        "/dev/", "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/",
    };
    if (std.mem.eql(u8, path, "/dev/null") or std.mem.eql(u8, path, "/tmp")) return true;
    for (prefixes) |p| if (std.mem.startsWith(u8, path, p)) return true;
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
    if (std.ascii.eqlIgnoreCase(name, "OTEL_EXPORTER_OTLP_HEADERS")) return true;

    if (startsWithIgnoreCase(name, "AWS_")) return true;
    if (endsWithIgnoreCase(name, "_API_KEY")) return true;
    if (endsWithIgnoreCase(name, "_TOKEN")) return true;
    if (endsWithIgnoreCase(name, "_SECRET")) return true;
    return false;
}

/// One secret value this process actually holds, for exact-value capture-time
/// redaction of tool output (ARCHITECTURE §7).
pub const Secret = struct { name: []const u8, value: []const u8 };

/// Collect the secret values loaded into this process (provider keys and
/// friends, by the same name policy the environment boundary uses). Values
/// shorter than 8 bytes are skipped: redacting "1" would shred ordinary
/// output. Returned slice references `source`'s memory; caller frees the
/// slice only.
pub fn collectSecrets(gpa: std.mem.Allocator, source: *const std.process.Environ.Map) ![]Secret {
    var out: std.ArrayList(Secret) = .empty;
    errdefer out.deinit(gpa);
    var it = source.iterator();
    while (it.next()) |entry| {
        if (!isSecretEnvironmentName(entry.key_ptr.*)) continue;
        if (entry.value_ptr.len < 8) continue;
        try out.append(gpa, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    }
    return out.toOwnedSlice(gpa);
}

/// Replace every occurrence of any collected secret value in `text` with
/// [REDACTED:<NAME>]. Returns null when nothing matched, so the common case
/// costs one scan and zero allocations.
pub fn redactSecrets(gpa: std.mem.Allocator, secrets: []const Secret, text: []const u8) !?[]u8 {
    var current: ?[]u8 = null;
    errdefer if (current) |c| gpa.free(c);
    for (secrets) |secret| {
        const haystack: []const u8 = current orelse text;
        if (std.mem.indexOf(u8, haystack, secret.value) == null) continue;
        const marker = try std.fmt.allocPrint(gpa, "[REDACTED:{s}]", .{secret.name});
        defer gpa.free(marker);
        const replaced = try std.mem.replaceOwned(u8, gpa, haystack, secret.value, marker);
        if (current) |c| gpa.free(c);
        current = replaced;
    }
    return current;
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
