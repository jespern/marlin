//! Owner-selected write roots, persisted outside the checkout and loaded by
//! every new turn. A checkout's files cannot grant their own permissions.
const std = @import("std");
const Io = std.Io;
const Store = @import("store.zig").Store;
const permissions = @import("permissions.zig");
const sandbox = @import("sandbox.zig");

pub const Profile = struct {
    write_roots: []const []const u8 = &.{},
};
pub const Action = enum { allow, revoke, clear };

/// Use the nearest checkout root. Linked worktrees share the main checkout
/// only when its own metadata contains the matching worktree backlink.
pub fn projectRoot(arena: std.mem.Allocator, io: Io, cwd: []const u8) ![]const u8 {
    const real = try Io.Dir.realPathFileAbsoluteAlloc(io, cwd, arena);
    var candidate: []const u8 = real;
    while (true) {
        const marker = try std.fs.path.join(arena, &.{ candidate, ".git" });
        if (Io.Dir.cwd().statFile(io, marker, .{})) |_| {
            return (try linkedProjectRoot(arena, io, candidate, marker)) orelse candidate;
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => {},
            else => return err,
        }
        candidate = std.fs.path.dirname(candidate) orelse return real;
    }
}

fn linkedProjectRoot(arena: std.mem.Allocator, io: Io, checkout: []const u8, marker: []const u8) !?[]const u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, marker, arena, .limited(16 * 1024)) catch return null;
    if (!std.mem.startsWith(u8, bytes, "gitdir:")) return null;
    const gitdir = canonicalPath(arena, io, checkout, std.mem.trim(u8, bytes[7..], " \t\r\n")) catch return null;
    const common_file = try std.fs.path.join(arena, &.{ gitdir, "commondir" });
    const common_bytes = Io.Dir.cwd().readFileAlloc(io, common_file, arena, .limited(16 * 1024)) catch return null;
    const common = canonicalPath(arena, io, gitdir, std.mem.trim(u8, common_bytes, " \t\r\n")) catch return null;
    if (!std.mem.eql(u8, std.fs.path.basename(common), ".git")) return null;
    const records = try std.fs.path.join(arena, &.{ common, "worktrees" });
    if (!std.mem.eql(u8, std.fs.path.dirname(gitdir) orelse return null, records)) return null;
    const back_file = try std.fs.path.join(arena, &.{ gitdir, "gitdir" });
    const back_bytes = Io.Dir.cwd().readFileAlloc(io, back_file, arena, .limited(16 * 1024)) catch return null;
    const back = canonicalPath(arena, io, gitdir, std.mem.trim(u8, back_bytes, " \t\r\n")) catch return null;
    // The binding must be written in the main checkout's own metadata, not
    // merely claimed by the worktree's repository-controlled pointer file.
    if (!std.mem.eql(u8, back, marker)) return null;
    return std.fs.path.dirname(common);
}

/// Resolve nonexistent trailing components through their deepest existing
/// ancestor; a lexical path alone is not a filesystem authority boundary.
pub fn canonicalPath(arena: std.mem.Allocator, io: Io, cwd: []const u8, requested: []const u8) ![]const u8 {
    if (requested.len == 0) return error.EmptyPath;
    const path = try std.fs.path.resolve(arena, &.{ cwd, requested });
    var ancestor: []const u8 = path;
    while (true) {
        if (Io.Dir.realPathFileAbsoluteAlloc(io, ancestor, arena)) |real| {
            const suffix = path[ancestor.len..];
            if (suffix.len == 0) return real;
            return std.fs.path.join(arena, &.{ real, std.mem.trimStart(u8, suffix, std.fs.path.sep_str) });
        } else |err| switch (err) {
            error.FileNotFound, error.NotDir => ancestor = std.fs.path.dirname(ancestor) orelse return err,
            else => return err,
        }
    }
}

pub fn read(arena: std.mem.Allocator, store: *Store, project: []const u8) !?Profile {
    const bytes = (try store.getProjectPermissions(project)) orelse return null;
    defer store.gpa.free(bytes);
    return try std.json.parseFromSliceLeaky(Profile, arena, bytes, .{ .allocate = .alloc_always });
}

/// A remembered path that was replaced by a symlink fails closed. The owner
/// can still revoke it: read/update deliberately do not resolve old roots.
pub fn load(arena: std.mem.Allocator, io: Io, store: *Store, cwd: []const u8) !?Profile {
    const project = try projectRoot(arena, io, cwd);
    const saved = (try read(arena, store, project)) orelse return null;
    for (saved.write_roots) |root| {
        if (root.len <= 1 or !std.fs.path.isAbsolute(root) or permissions.isProtectedPath(root)) return error.InvalidProjectPermissions;
        const current = try canonicalPath(arena, io, project, root);
        if (!std.mem.eql(u8, current, root)) return error.ProjectPermissionPathChanged;
    }
    return saved;
}

pub fn validateGrant(root: []const u8, protected: sandbox.ProtectedRoots) !void {
    if (!std.fs.path.isAbsolute(root) or permissions.isProtectedPath(root) or std.mem.indexOfAny(u8, root, "\r\n\x00") != null) return error.ProtectedPath;
    for ([_][]const u8{ protected.ssh, protected.aws, protected.gnupg, protected.marlin_credentials }) |secret| {
        if (permissions.isWithin(secret, root) or permissions.isWithin(root, secret)) return error.ProtectedPath;
    }
}

pub fn update(arena: std.mem.Allocator, io: Io, store: *Store, cwd: []const u8, action: Action, path: []const u8, protected: sandbox.ProtectedRoots) !Profile {
    const project = try projectRoot(arena, io, cwd);
    if (action == .clear) {
        try store.setProjectPermissions(project, null);
        return .{};
    }
    const saved = (try read(arena, store, project)) orelse Profile{};
    var root = if (action == .allow)
        try canonicalPath(arena, io, cwd, path)
    else
        try std.fs.path.resolve(arena, &.{ cwd, path });
    if (action == .revoke) {
        var exact = false;
        for (saved.write_roots) |existing| {
            if (std.mem.eql(u8, existing, root)) exact = true;
        }
        // Prefer the recorded spelling even if a symlink was substituted;
        // otherwise accept the same aliases used when granting the path.
        if (!exact) root = canonicalPath(arena, io, cwd, path) catch root;
    }
    if (action == .allow) {
        try validateGrant(root, protected);
        var directory = try Io.Dir.cwd().openDir(io, root, .{});
        directory.close(io);
        const created = try canonicalPath(arena, io, cwd, root);
        if (!std.mem.eql(u8, root, created)) return error.ProjectPermissionPathChanged;
    }
    var roots: std.ArrayList([]const u8) = .empty;
    for (saved.write_roots) |existing| {
        if (!std.mem.eql(u8, existing, root)) try roots.append(arena, existing);
    }
    if (action == .allow) try roots.append(arena, root);
    const result: Profile = .{ .write_roots = roots.items };
    const bytes = if (roots.items.len > 0) try std.json.Stringify.valueAlloc(arena, result, .{}) else null;
    try store.setProjectPermissions(project, bytes);
    return result;
}

pub fn allowsPath(arena: std.mem.Allocator, io: Io, roots: []const []const u8, cwd: []const u8, path: []const u8) bool {
    const real = canonicalPath(arena, io, cwd, path) catch return false;
    for (roots) |root| if (permissions.isWithin(root, real)) return true;
    return false;
}

pub fn allowsEdit(arena: std.mem.Allocator, io: Io, roots: []const []const u8, cwd: []const u8, args_json: []const u8) bool {
    const args = std.json.parseFromSliceLeaky(struct {
        path: ?[]const u8 = null,
        file_path: ?[]const u8 = null,
        notebook_path: ?[]const u8 = null,
    }, arena, args_json, .{ .ignore_unknown_fields = true }) catch return false;
    const path = args.path orelse args.file_path orelse args.notebook_path orelse return false;
    if (permissions.isProtectedPath(path)) return false;
    return allowsPath(arena, io, roots, cwd, path);
}

pub const codex_profile_name = "marlin_project";

pub fn protectedPathList(arena: std.mem.Allocator, protected: ?sandbox.ProtectedRoots) ![]const []const u8 {
    const roots = protected orelse return &.{};
    return arena.dupe([]const u8, &.{ roots.ssh, roots.aws, roots.gnupg, roots.marlin_credentials });
}

pub fn codexConfig(arena: std.mem.Allocator, saved: Profile, protected: ?sandbox.ProtectedRoots) !std.json.Value {
    var filesystem: std.json.ObjectMap = .empty;
    for (saved.write_roots) |root| try filesystem.put(arena, root, .{ .string = "write" });
    for (try protectedPathList(arena, protected)) |root| try filesystem.put(arena, root, .{ .string = "deny" });
    var network: std.json.ObjectMap = .empty;
    try network.put(arena, "enabled", .{ .bool = true });
    var policy: std.json.ObjectMap = .empty;
    try policy.put(arena, "extends", .{ .string = ":workspace" });
    try policy.put(arena, "filesystem", .{ .object = filesystem });
    try policy.put(arena, "network", .{ .object = network });
    var profiles: std.json.ObjectMap = .empty;
    try profiles.put(arena, codex_profile_name, .{ .object = policy });
    var config: std.json.ObjectMap = .empty;
    try config.put(arena, "default_permissions", .{ .string = codex_profile_name });
    try config.put(arena, "permissions", .{ .object = profiles });
    return .{ .object = config };
}

/// Claude owns the Bash sandbox. Anything it asks to run outside it still
/// reaches the bridge and must be approved, never guessed from shell text.
pub fn claudeSettings(arena: std.mem.Allocator, saved: ?Profile, protected: ?sandbox.ProtectedRoots) ![]const u8 {
    const roots = if (saved) |value| value.write_roots else &.{};
    const secrets = try protectedPathList(arena, protected);
    var deny: std.ArrayList([]const u8) = .empty;
    for (secrets) |root| {
        for ([_][]const u8{ "Read", "Edit", "Write" }) |tool| {
            try deny.append(arena, try std.fmt.allocPrint(arena, "{s}(/{s})", .{ tool, root }));
            try deny.append(arena, try std.fmt.allocPrint(arena, "{s}(/{s}/**)", .{ tool, root }));
        }
    }
    return std.json.Stringify.valueAlloc(arena, .{
        .sandbox = .{
            .enabled = true,
            .autoAllowBashIfSandboxed = true,
            .allowUnsandboxedCommands = true,
            // If the vendor cannot sandbox, default permissions and Marlin's
            // bridge retain the approval rather than silently auto-running.
            .failIfUnavailable = saved != null,
            .filesystem = .{ .allowWrite = roots, .denyRead = secrets, .denyWrite = secrets },
            // Match the existing guest's open networking; these grants scope
            // filesystem writes, not external effects or network authority.
            .network = .{ .allowedDomains = [_][]const u8{"*"}, .allowLocalBinding = true, .allowAllUnixSockets = true },
        },
        .permissions = .{ .additionalDirectories = roots, .deny = deny.items },
    }, .{});
}
