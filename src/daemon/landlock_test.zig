//! Unit tests for landlock.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in landlock.zig.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const permissions = @import("permissions.zig");

const landlock = @import("landlock.zig");
const coverPlan = landlock.coverPlan;
const grant = landlock.grant;

test {
    std.testing.refAllDecls(landlock);
}

test "cover plan grants siblings along exclusion chains and never the roots" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-landlock-plan");
    defer temp.deinit();
    const base = try Io.Dir.realPathFileAbsoluteAlloc(io, temp.path, gpa);
    defer gpa.free(base);

    // base/{work, home/{user/{.ssh, project}, other}}
    inline for (.{ "work", "home/user/.ssh", "home/user/project", "home/other" }) |sub| {
        const p = try std.fs.path.join(gpa, &.{ base, sub });
        defer gpa.free(p);
        try Io.Dir.cwd().createDirPath(io, p);
    }
    const excl_ssh = try std.fs.path.join(gpa, &.{ base, "home", "user", ".ssh" });
    defer gpa.free(excl_ssh);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const plan = try coverPlan(arena_state.allocator(), io, &.{excl_ssh});

    const work = try std.fs.path.join(gpa, &.{ base, "work" });
    defer gpa.free(work);
    const project = try std.fs.path.join(gpa, &.{ base, "home", "user", "project" });
    defer gpa.free(project);
    const home = try std.fs.path.join(gpa, &.{ base, "home" });
    defer gpa.free(home);

    var saw_work = false;
    var saw_project = false;
    for (plan) |p| {
        // Never the exclusion itself, never a bare grant of an ancestor dir.
        try std.testing.expect(!std.mem.eql(u8, p, excl_ssh));
        try std.testing.expect(!std.mem.eql(u8, p, home));
        if (std.mem.eql(u8, p, work)) saw_work = true;
        if (std.mem.eql(u8, p, project)) saw_project = true;
    }
    // Siblings on and off the exclusion chain are both covered.
    try std.testing.expect(saw_work);
    try std.testing.expect(saw_project);
}
