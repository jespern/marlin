//! Linux Landlock backend: the `marlin landlock_exec` helper that sandboxes
//! one shell invocation, plus the cross-platform cover-set planner.
//!
//! Landlock is strictly additive — there are no deny rules — so the Seatbelt
//! contract ("read everything EXCEPT the protected roots") must be expressed
//! as a computed allowlist: walk down from `/`, granting read+execute on
//! every entry that is not on an ancestor path of a protected root, and
//! recursing into the ones that are. The protected roots themselves are
//! simply never granted. Writes are granted only on the workspace and the
//! Marlin-owned temp root, matching the SBPL profile.
//!
//! Two honesty caveats versus Seatbelt, both acceptable for one bash call
//! and both proven live by the canary before the backend is ever claimed:
//!   - a directory created *during* the call inside a partially-granted
//!     ancestor (typically $HOME) is not readable until the next call;
//!   - rule granularity is the rule set at exec time, not live policy.
//!
//! The helper applies the ruleset to ITSELF (no_new_privs + restrict_self)
//! and then execs the target, so the daemon never changes its own state.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const permissions = @import("permissions.zig");

// linux/landlock.h — kept local: std exposes only the syscall numbers.
pub const ACCESS_FS_EXECUTE: u64 = 1 << 0;
pub const ACCESS_FS_WRITE_FILE: u64 = 1 << 1;
pub const ACCESS_FS_READ_FILE: u64 = 1 << 2;
pub const ACCESS_FS_READ_DIR: u64 = 1 << 3;
pub const ACCESS_FS_REMOVE_DIR: u64 = 1 << 4;
pub const ACCESS_FS_REMOVE_FILE: u64 = 1 << 5;
pub const ACCESS_FS_MAKE_CHAR: u64 = 1 << 6;
pub const ACCESS_FS_MAKE_DIR: u64 = 1 << 7;
pub const ACCESS_FS_MAKE_REG: u64 = 1 << 8;
pub const ACCESS_FS_MAKE_SOCK: u64 = 1 << 9;
pub const ACCESS_FS_MAKE_FIFO: u64 = 1 << 10;
pub const ACCESS_FS_MAKE_BLOCK: u64 = 1 << 11;
pub const ACCESS_FS_MAKE_SYM: u64 = 1 << 12;
pub const ACCESS_FS_REFER: u64 = 1 << 13; // ABI 2
pub const ACCESS_FS_TRUNCATE: u64 = 1 << 14; // ABI 3

const abi1_rights: u64 = (1 << 13) - 1; // EXECUTE..MAKE_SYM
const read_exec_rights: u64 = ACCESS_FS_EXECUTE | ACCESS_FS_READ_FILE | ACCESS_FS_READ_DIR;
/// Rights a rule on a NON-directory may carry (dir-only bits are EINVAL).
const file_compatible_rights: u64 =
    ACCESS_FS_EXECUTE | ACCESS_FS_WRITE_FILE | ACCESS_FS_READ_FILE | ACCESS_FS_TRUNCATE;

const RULE_PATH_BENEATH: u32 = 1;
const CREATE_RULESET_VERSION: u32 = 1 << 0;

/// Exit codes distinct from anything a shell canary uses, so verification
/// failures are attributable.
pub const exit_unsupported: u8 = 40;
pub const exit_setup_failed: u8 = 41;

/// `marlin landlock_exec --workspace W --temp T [--protect P]... -- argv...`
/// Applies the ruleset to this process, then execs argv. Internal; spawned
/// by the daemon's bash adapter and by the verification canary.
pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    args: []const [:0]const u8,
) !u8 {
    if (builtin.os.tag != .linux) {
        std.log.err("landlock_exec is Linux-only", .{});
        return exit_unsupported;
    } else {
        var workspace: ?[]const u8 = null;
        var temp_root: ?[]const u8 = null;
        var protects: std.ArrayList([]const u8) = .empty;
        defer protects.deinit(gpa);
        var exec_args: []const [:0]const u8 = &.{};

        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--")) {
                exec_args = args[i + 1 ..];
                break;
            } else if (std.mem.eql(u8, arg, "--workspace") and i + 1 < args.len) {
                i += 1;
                workspace = args[i];
            } else if (std.mem.eql(u8, arg, "--temp") and i + 1 < args.len) {
                i += 1;
                temp_root = args[i];
            } else if (std.mem.eql(u8, arg, "--protect") and i + 1 < args.len) {
                i += 1;
                try protects.append(gpa, args[i]);
            } else {
                std.log.err("landlock_exec: unknown argument '{s}'", .{arg});
                return exit_setup_failed;
            }
        }
        const ws = workspace orelse return exit_setup_failed;
        const tmp = temp_root orelse return exit_setup_failed;
        if (exec_args.len == 0) return exit_setup_failed;

        restrictSelf(gpa, io, ws, tmp, protects.items) catch |e| {
            std.log.err("landlock setup failed: {t}", .{e});
            return if (e == error.LandlockUnsupported) exit_unsupported else exit_setup_failed;
        };

        // Exec the target with the current (already daemon-scrubbed) env.
        var argv_z = try gpa.alloc(?[*:0]const u8, exec_args.len + 1);
        for (exec_args, 0..) |a, j| argv_z[j] = a.ptr;
        argv_z[exec_args.len] = null;
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        _ = std.os.linux.execve(exec_args[0].ptr, @ptrCast(argv_z.ptr), envp);
        std.log.err("landlock_exec: exec '{s}' failed", .{exec_args[0]});
        return exit_setup_failed;
    }
}

fn restrictSelf(
    gpa: std.mem.Allocator,
    io: Io,
    workspace: []const u8,
    temp_root: []const u8,
    protects: []const []const u8,
) !void {
    if (builtin.os.tag != .linux) return error.LandlockUnsupported;
    const linux = std.os.linux;

    const abi_ret = linux.syscall3(.landlock_create_ruleset, 0, 0, CREATE_RULESET_VERSION);
    const abi = abiFromRet(abi_ret) orelse return error.LandlockUnsupported;

    var handled: u64 = abi1_rights;
    if (abi >= 2) handled |= ACCESS_FS_REFER;
    if (abi >= 3) handled |= ACCESS_FS_TRUNCATE;

    const attr = extern struct { handled_access_fs: u64 }{ .handled_access_fs = handled };
    const fd_ret = linux.syscall3(
        .landlock_create_ruleset,
        @intFromPtr(&attr),
        @sizeOf(@TypeOf(attr)),
        0,
    );
    if (linux.errno(fd_ret) != .SUCCESS) return error.LandlockUnsupported;
    const ruleset_fd: i32 = @intCast(fd_ret);
    defer _ = linux.close(ruleset_fd);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Full rights on the write roots; read+exec on the computed cover.
    try grant(arena, ruleset_fd, workspace, handled);
    try grant(arena, ruleset_fd, temp_root, handled);
    const cover = try coverPlan(arena, io, protects);
    for (cover) |path| {
        // A cover entry that vanished between planning and granting is not
        // an error; the rule simply is not needed anymore.
        grant(arena, ruleset_fd, path, read_exec_rights) catch continue;
    }
    // Shells write /dev/null constantly; grant the usual device files.
    for ([_][]const u8{ "/dev/null", "/dev/zero", "/dev/urandom", "/dev/tty" }) |dev| {
        grant(arena, ruleset_fd, dev, ACCESS_FS_READ_FILE | ACCESS_FS_WRITE_FILE) catch continue;
    }

    if (linux.errno(linux.prctl(38, 1, 0, 0, 0)) != .SUCCESS) // PR_SET_NO_NEW_PRIVS
        return error.SetupFailed;
    if (linux.errno(linux.syscall2(.landlock_restrict_self, @intCast(ruleset_fd), 0)) != .SUCCESS)
        return error.SetupFailed;
}

fn abiFromRet(ret: usize) ?u32 {
    if (builtin.os.tag != .linux) return null;
    if (std.os.linux.errno(ret) != .SUCCESS) return null;
    const abi: u32 = @intCast(ret);
    return if (abi >= 1) abi else null;
}

fn grant(arena: std.mem.Allocator, ruleset_fd: i32, path: []const u8, rights: u64) !void {
    if (builtin.os.tag != .linux) return error.LandlockUnsupported;
    const linux = std.os.linux;
    const path_z = try arena.dupeZ(u8, path);
    const open_ret = linux.open(path_z, .{ .PATH = true, .CLOEXEC = true }, 0);
    if (linux.errno(open_ret) != .SUCCESS) return error.OpenFailed;
    const fd: i32 = @intCast(open_ret);
    defer _ = linux.close(fd);

    // Directory-only bits on a non-directory rule are EINVAL; rather than
    // stat-ing, try the full grant and fall back to the file-compatible
    // subset (kernel semantics, not a guess).
    switch (addRule(ruleset_fd, fd, rights)) {
        .SUCCESS => return,
        .INVAL => {
            const narrowed = rights & file_compatible_rights;
            if (narrowed == 0 or narrowed == rights) return error.AddRuleFailed;
            if (addRule(ruleset_fd, fd, narrowed) != .SUCCESS) return error.AddRuleFailed;
        },
        else => return error.AddRuleFailed,
    }
}

fn addRule(ruleset_fd: i32, parent_fd: i32, rights: u64) std.os.linux.E {
    if (builtin.os.tag != .linux) return .INVAL;
    const linux = std.os.linux;
    // linux/landlock.h declares landlock_path_beneath_attr __packed (12
    // bytes); build it by hand rather than trusting struct layout.
    var attr: [12]u8 align(8) = undefined;
    std.mem.writeInt(u64, attr[0..8], rights, .little);
    std.mem.writeInt(i32, attr[8..12], parent_fd, .little);
    return linux.errno(linux.syscall4(
        .landlock_add_rule,
        @intCast(ruleset_fd),
        RULE_PATH_BENEATH,
        @intFromPtr(&attr),
        0,
    ));
}

/// Compute the read+exec allowlist that emulates "everything except the
/// exclusions": every entry of `/` (recursively, but only descending along
/// exclusion ancestor chains) that is neither an exclusion nor an ancestor
/// of one. Pure planning — no Landlock — so it is testable on any OS.
/// Exclusion paths must be absolute and symlink-resolved by the caller.
pub fn coverPlan(
    arena: std.mem.Allocator,
    io: Io,
    exclusions: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(arena);
    try pending.append(arena, "/");

    while (pending.pop()) |dir_path| {
        var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            const full = if (std.mem.eql(u8, dir_path, "/"))
                try std.fmt.allocPrint(arena, "/{s}", .{entry.name})
            else
                try std.fs.path.join(arena, &.{ dir_path, entry.name });
            if (isExcluded(full, exclusions)) continue;
            if (isAncestorOfAny(full, exclusions)) {
                try pending.append(arena, full);
            } else {
                try out.append(arena, full);
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn isExcluded(path: []const u8, exclusions: []const []const u8) bool {
    for (exclusions) |excl| {
        if (permissions.isWithin(excl, path)) return true;
    }
    return false;
}

fn isAncestorOfAny(path: []const u8, exclusions: []const []const u8) bool {
    for (exclusions) |excl| {
        if (!std.mem.eql(u8, excl, path) and permissions.isWithin(path, excl)) return true;
    }
    return false;
}

// ---------------------------------------------------------------- tests --

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

test {
    std.testing.refAllDecls(@This());
}
