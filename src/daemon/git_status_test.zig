const std = @import("std");
const git_status = @import("git_status.zig");
const temp_dir = @import("../testing/temp_dir.zig");
const gpa = std.testing.allocator;

test {
    std.testing.refAllDecls(git_status);
}

fn git(io: std.Io, cwd: []const u8, env: *const std.process.Environ.Map, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ "git", "-c", "user.name=Git Status Test", "-c", "user.email=status@example.test", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null" });
    try argv.appendSlice(gpa, args);
    const result = try std.process.run(gpa, io, .{ .argv = argv.items, .cwd = .{ .path = cwd }, .environ_map = env });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("git failed: {s}\n", .{result.stderr});
        return error.GitFailed;
    }
}

test "git metadata covers absence, unborn, origin divergence, upstream names, worktrees and detached HEAD" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try temp_dir.Dir.initFromProcess(gpa, io, "marlin-git-status");
    defer tmp.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("PATH", if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin");
    try env.put("HOME", tmp.path);
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    var cancel: std.atomic.Value(bool) = .init(false);
    var result = git_status.probe(gpa, io, tmp.path, &env, &cancel, null);
    try std.testing.expectEqualStrings("", result.branch());

    try git(io, tmp.path, &env, &.{ "init", "--initial-branch=main" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqualStrings("main", result.branch());
    try std.testing.expect(result.counts == null);
    try git(io, tmp.path, &env, &.{ "commit", "--allow-empty", "-m", "base" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expect(result.counts == null);
    try git(io, tmp.path, &env, &.{ "remote", "add", "origin", "." });
    try git(io, tmp.path, &env, &.{ "update-ref", "refs/remotes/origin/main", "HEAD" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqual(git_status.Counts{ .ahead = 0, .behind = 0 }, result.counts.?);
    try git(io, tmp.path, &env, &.{ "commit", "--allow-empty", "-m", "ours" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqual(git_status.Counts{ .ahead = 1, .behind = 0 }, result.counts.?);
    try git(io, tmp.path, &env, &.{ "checkout", "-b", "remote", "refs/remotes/origin/main" });
    try git(io, tmp.path, &env, &.{ "commit", "--allow-empty", "-m", "theirs" });
    try git(io, tmp.path, &env, &.{ "update-ref", "refs/remotes/origin/main", "HEAD" });
    try git(io, tmp.path, &env, &.{ "checkout", "main" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqual(git_status.Counts{ .ahead = 1, .behind = 1 }, result.counts.?);

    // Disable subprocess execution through the cooperative cancellation gate.
    // Metadata-only refreshes retain cached counts and still read branches.
    cancel.store(true, .release);
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqualStrings("main", result.branch());
    try std.testing.expectEqual(git_status.Counts{ .ahead = 1, .behind = 1 }, result.counts.?);
    const without_git = git_status.probe(gpa, io, tmp.path, &env, &cancel, null);
    try std.testing.expectEqualStrings("main", without_git.branch());
    try std.testing.expect(without_git.counts == null);
    cancel.store(false, .release);

    try git(io, tmp.path, &env, &.{ "update-ref", "refs/remotes/origin/trunk", "HEAD" });
    try git(io, tmp.path, &env, &.{ "branch", "--set-upstream-to=origin/trunk", "main" });
    try git(io, tmp.path, &env, &.{ "pack-refs", "--all" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqual(git_status.Counts{ .ahead = 0, .behind = 0 }, result.counts.?);

    // Branch tracking configured through an include must invalidate too.
    try git(io, tmp.path, &env, &.{ "config", "--unset", "branch.main.merge" });
    try git(io, tmp.path, &env, &.{ "config", "include.path", "tracking" });
    const tracking = try std.fs.path.join(gpa, &.{ tmp.path, ".git", "tracking" });
    defer gpa.free(tracking);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tracking, .data = "[branch \"main\"]\n merge = refs/heads/trunk\n" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqual(git_status.Counts{ .ahead = 0, .behind = 0 }, result.counts.?);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tracking, .data = "[branch \"main\"]\n merge = refs/heads/main\n" });
    result = git_status.probe(gpa, io, tmp.path, &env, &cancel, result);
    try std.testing.expectEqual(git_status.Counts{ .ahead = 1, .behind = 1 }, result.counts.?);

    const worktree = try std.fs.path.join(gpa, &.{ tmp.path, "linked" });
    defer gpa.free(worktree);
    try git(io, tmp.path, &env, &.{ "worktree", "add", "-b", "feature", worktree });
    const nested = try std.fs.path.join(gpa, &.{ worktree, "nested" });
    defer gpa.free(nested);
    try std.Io.Dir.cwd().createDirPath(io, nested);
    try env.put("GIT_DIR", "/nonexistent/override");
    result = git_status.probe(gpa, io, nested, &env, &cancel, result);
    try std.testing.expectEqualStrings("feature", result.branch());
    try std.testing.expect(result.counts == null);
    _ = env.swapRemove("GIT_DIR");
    try git(io, worktree, &env, &.{ "checkout", "--detach" });
    result = git_status.probe(gpa, io, worktree, &env, &cancel, result);
    try std.testing.expect(std.mem.startsWith(u8, result.branch(), "detached "));
    try std.testing.expect(result.counts == null);
}
