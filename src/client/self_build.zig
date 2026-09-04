//! Source-checkout rebuild support for the self-hosting workflow.
//! Release/package installations deliberately fail the gate instead of trying
//! to guess how their package manager should update them.

const std = @import("std");
const Io = std.Io;

const binary_suffix = "/zig-out/bin/marlin";

/// Build and sanity-check the checkout that owns the running executable.
/// Caller owns the returned candidate path.
pub fn build(gpa: std.mem.Allocator, io: Io, label: []const u8) ![]u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try std.process.executablePath(io, &exe_buf);
    const exe = exe_buf[0..exe_len];
    const root = sourceRootFromExecutable(exe) orelse return error.NotSourceBuild;
    try verifyCheckout(gpa, io, root);

    try eprint(io, "marlin: building {s} in {s}...\n", .{ label, root });
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zig", "build", "-Doptimize=ReleaseFast" },
        .cwd = .{ .path = root },
    });
    const term = try child.wait(io);
    if (term != .exited or term.exited != 0) return error.BuildFailed;

    const candidate = try std.fs.path.join(gpa, &.{ root, "zig-out", "bin", "marlin" });
    errdefer gpa.free(candidate);
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ candidate, "version" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0 or
        !std.mem.startsWith(u8, result.stdout, "marlin "))
    {
        return error.CandidateFailed;
    }
    try eprint(io, "marlin: {s} build complete\n", .{label});
    return candidate;
}

pub fn sourceRootFromExecutable(exe: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, exe, binary_suffix)) return null;
    const root = exe[0 .. exe.len - binary_suffix.len];
    if (root.len == 0) return "/";
    return root;
}

fn verifyCheckout(gpa: std.mem.Allocator, io: Io, root: []const u8) !void {
    const markers = [_][]const u8{ ".git", "build.zig", "src/main.zig" };
    for (markers) |marker| {
        const path = try std.fs.path.join(gpa, &.{ root, marker });
        defer gpa.free(path);
        Io.Dir.accessAbsolute(io, path, .{ .read = true }) catch return error.NotSourceBuild;
    }

    const manifest_path = try std.fs.path.join(gpa, &.{ root, "build.zig.zon" });
    defer gpa.free(manifest_path);
    const manifest = Io.Dir.cwd().readFileAlloc(io, manifest_path, gpa, .limited(64 * 1024)) catch
        return error.NotSourceBuild;
    defer gpa.free(manifest);
    if (!isMarlinManifest(manifest)) return error.NotSourceBuild;
}

pub fn isMarlinManifest(contents: []const u8) bool {
    const name_at = std.mem.indexOf(u8, contents, ".name") orelse return false;
    const line_end = std.mem.indexOfScalarPos(u8, contents, name_at, '\n') orelse contents.len;
    return std.mem.indexOf(u8, contents[name_at..line_end], ".marlin") != null;
}

fn eprint(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var writer: Io.File.Writer = .init(.stderr(), io, &buf);
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}
