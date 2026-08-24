//! Temporary directories for tests and test runners.
//!
//! Marlin's Seatbelt profile grants write access to the session's TMPDIR,
//! not to the global /tmp directory. Test fixtures must therefore derive
//! their scratch paths from TMPDIR as well.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub fn rootFromEnvironment(value: ?[]const u8) []const u8 {
    if (value) |root| {
        if (root.len > 0) return root;
    }
    return if (builtin.os.tag == .macos) "/private/tmp" else "/tmp";
}

pub const Dir = struct {
    allocator: std.mem.Allocator,
    io: Io,
    path: []u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        temp_root: []const u8,
        prefix: []const u8,
    ) !Dir {
        var random: [8]u8 = undefined;
        io.random(&random);
        const leaf = try std.fmt.allocPrint(allocator, "{s}-{x}", .{
            prefix,
            std.mem.readInt(u64, &random, .little),
        });
        defer allocator.free(leaf);
        const path = try std.fs.path.join(allocator, &.{ temp_root, leaf });
        errdefer allocator.free(path);
        try Io.Dir.cwd().createDirPath(io, path);
        return .{ .allocator = allocator, .io = io, .path = path };
    }

    /// Convenience for unit tests, whose entry points do not receive an
    /// `std.process.Init` environment map.
    pub fn initFromProcess(
        allocator: std.mem.Allocator,
        io: Io,
        prefix: []const u8,
    ) !Dir {
        const value: ?[]const u8 = if (std.c.getenv("TMPDIR")) |raw| std.mem.span(raw) else null;
        const temp_root = rootFromEnvironment(value);
        return init(allocator, io, temp_root, prefix);
    }

    pub fn deinit(self: *Dir) void {
        Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.allocator.free(self.path);
        self.* = undefined;
    }
};

test "temporary roots prefer TMPDIR and reject an empty value" {
    try std.testing.expectEqualStrings("/custom/scratch", rootFromEnvironment("/custom/scratch"));
    try std.testing.expect(rootFromEnvironment("").len > 0);
    try std.testing.expect(rootFromEnvironment(null).len > 0);
}
