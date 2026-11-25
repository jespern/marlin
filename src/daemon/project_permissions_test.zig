const std = @import("std");
const Io = std.Io;
const project_permissions = @import("project_permissions.zig");
const Store = @import("store.zig").Store;
const TempDir = @import("../testing/temp_dir.zig").Dir;
const sandbox = @import("sandbox.zig");

test {
    std.testing.refAllDecls(project_permissions);
}

fn protectedRoots(arena: std.mem.Allocator, root: []const u8) !sandbox.ProtectedRoots {
    return .{
        .ssh = try std.fs.path.join(arena, &.{ root, "home/.ssh" }),
        .aws = try std.fs.path.join(arena, &.{ root, "home/.aws" }),
        .gnupg = try std.fs.path.join(arena, &.{ root, "home/.gnupg" }),
        .marlin_credentials = try std.fs.path.join(arena, &.{ root, "home/.config/marlin/credentials" }),
    };
}

test "project roots survive reopening, apply to new sessions and revoke durably" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try TempDir.initFromProcess(gpa, io, "marlin-project-grants");
    defer temp.deinit();
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, temp.path, arena);
    const checkout = try std.fs.path.join(arena, &.{ base, "checkout" });
    const nested = try std.fs.path.join(arena, &.{ checkout, "src" });
    const other = try std.fs.path.join(arena, &.{ base, "checkout-other" });
    const cache = try std.fs.path.join(arena, &.{ base, "build-cache" });
    for ([_][]const u8{ nested, other, cache, try std.fs.path.join(arena, &.{ checkout, ".git" }) }) |dir|
        try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.joinZ(arena, &.{ base, "state.db" });
    const protected = try protectedRoots(arena, base);
    {
        var db = try Store.open(gpa, path);
        defer db.close();
        try db.createSession(1, 0, nested, "codex/default", .auto);
        _ = try project_permissions.update(arena, io, &db, checkout, .allow, cache, protected);
        _ = try project_permissions.update(arena, io, &db, checkout, .allow, cache, protected);
        const saved = (try project_permissions.load(arena, io, &db, nested)).?;
        try std.testing.expectEqual(@as(usize, 1), saved.write_roots.len);
        try std.testing.expectEqualStrings(cache, saved.write_roots[0]);
        try std.testing.expect(try project_permissions.load(arena, io, &db, other) == null);
    }
    {
        var db = try Store.open(gpa, path);
        defer db.close();
        try db.createSession(2, 1, checkout, "claudecode/default", .auto);
        const restored = (try project_permissions.load(arena, io, &db, checkout)).?;
        try std.testing.expect(project_permissions.allowsPath(arena, io, restored.write_roots, checkout, try std.fs.path.join(arena, &.{ cache, "new/entry" })));
        try std.testing.expect(!project_permissions.allowsPath(arena, io, restored.write_roots, checkout, other));
        _ = try project_permissions.update(arena, io, &db, checkout, .revoke, cache, protected);
    }
    var db = try Store.open(gpa, path);
    defer db.close();
    try std.testing.expect(try project_permissions.load(arena, io, &db, nested) == null);
}

test "a gitdir pointer cannot inherit another project's saved access" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try TempDir.initFromProcess(gpa, io, "marlin-project-identity");
    defer temp.deinit();
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, temp.path, arena);
    const victim = try std.fs.path.join(arena, &.{ base, "victim" });
    const claimant = try std.fs.path.join(arena, &.{ base, "claimant" });
    try Io.Dir.cwd().createDirPath(io, victim);
    try Io.Dir.cwd().createDirPath(io, claimant);
    const marker = try std.fs.path.join(arena, &.{ claimant, ".git" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = try std.fmt.allocPrint(arena, "gitdir: {s}/.git\n", .{victim}) });
    var db = try Store.open(gpa, null);
    defer db.close();
    const cache = try std.fs.path.join(arena, &.{ base, "cache" });
    try Io.Dir.cwd().createDirPath(io, cache);
    _ = try project_permissions.update(arena, io, &db, victim, .allow, cache, try protectedRoots(arena, base));
    try std.testing.expect(try project_permissions.load(arena, io, &db, claimant) == null);
}

test "a grant made through a directory alias can be revoked through that alias" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try TempDir.initFromProcess(gpa, io, "marlin-project-revoke-alias");
    defer temp.deinit();
    var memory = std.heap.ArenaAllocator.init(gpa);
    defer memory.deinit();
    const arena = memory.allocator();
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, temp.path, arena);
    const cache = try std.fs.path.join(arena, &.{ base, "cache" });
    const alias = try std.fs.path.join(arena, &.{ base, "alias" });
    try Io.Dir.cwd().createDirPath(io, cache);
    const ln = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/ln", "-s", cache, alias } });
    defer gpa.free(ln.stdout);
    defer gpa.free(ln.stderr);
    var db = try Store.open(gpa, null);
    defer db.close();
    const protected = try protectedRoots(arena, base);
    const saved = try project_permissions.update(arena, io, &db, base, .allow, alias, protected);
    try std.testing.expectEqualStrings(cache, saved.write_roots[0]);
    _ = try project_permissions.update(arena, io, &db, base, .revoke, alias, protected);
    try std.testing.expect(try project_permissions.load(arena, io, &db, base) == null);
}

test "a linked worktree shares grants only with a matching backlink in the main checkout" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try TempDir.initFromProcess(gpa, io, "marlin-project-worktree");
    defer temp.deinit();
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, temp.path, arena);
    const main = try std.fs.path.join(arena, &.{ base, "main" });
    const linked = try std.fs.path.join(arena, &.{ base, "topic" });
    const record = try std.fs.path.join(arena, &.{ main, ".git/worktrees/topic" });
    try Io.Dir.cwd().createDirPath(io, linked);
    try Io.Dir.cwd().createDirPath(io, record);
    const marker = try std.fs.path.join(arena, &.{ linked, ".git" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = marker, .data = try std.fmt.allocPrint(arena, "gitdir: {s}\n", .{record}) });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ record, "commondir" }), .data = "../..\n" });
    const back = try std.fs.path.join(arena, &.{ record, "gitdir" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = back, .data = try std.fmt.allocPrint(arena, "{s}\n", .{marker}) });
    var db = try Store.open(gpa, null);
    defer db.close();
    const cache = try std.fs.path.join(arena, &.{ base, "cache" });
    try Io.Dir.cwd().createDirPath(io, cache);
    _ = try project_permissions.update(arena, io, &db, main, .allow, cache, try protectedRoots(arena, base));
    try std.testing.expect(try project_permissions.load(arena, io, &db, linked) != null);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = back, .data = "some-other-worktree/.git\n" });
    try std.testing.expect(try project_permissions.load(arena, io, &db, linked) == null);
}

test "protected ancestors and a symlink substituted after a grant stay denied" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try TempDir.initFromProcess(gpa, io, "marlin-project-symlink");
    defer temp.deinit();
    var state = std.heap.ArenaAllocator.init(gpa);
    defer state.deinit();
    const arena = state.allocator();
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, temp.path, arena);
    const protected = try protectedRoots(arena, base);
    try std.testing.expectError(error.ProtectedPath, project_permissions.validateGrant("/", protected));
    try std.testing.expectError(error.ProtectedPath, project_permissions.validateGrant(try std.fs.path.join(arena, &.{ base, "home" }), protected));
    try std.testing.expectError(error.ProtectedPath, project_permissions.validateGrant(protected.ssh, protected));
    const checkout = try std.fs.path.join(arena, &.{ base, "checkout" });
    const cache = try std.fs.path.join(arena, &.{ base, "cache" });
    const other = try std.fs.path.join(arena, &.{ base, "other" });
    try Io.Dir.cwd().createDirPath(io, checkout);
    try Io.Dir.cwd().createDirPath(io, other);
    try Io.Dir.cwd().createDirPath(io, cache);
    var db = try Store.open(gpa, null);
    defer db.close();
    _ = try project_permissions.update(arena, io, &db, checkout, .allow, cache, protected);
    try Io.Dir.cwd().deleteTree(io, cache);
    const ln = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/ln", "-s", other, cache } });
    defer gpa.free(ln.stdout);
    defer gpa.free(ln.stderr);
    try std.testing.expectError(error.ProjectPermissionPathChanged, project_permissions.load(arena, io, &db, checkout));
    _ = try project_permissions.update(arena, io, &db, checkout, .revoke, cache, protected);
    try std.testing.expect(try project_permissions.load(arena, io, &db, checkout) == null);
}
