//! Asset root resolution and whole-file loading.
//!
//! The on-disk layout mirrors the original game (`<root>/wipeout/track01/…`)
//! so the same tree can feed both this port and the reference C build.
//! The default root is `$XDG_DATA_HOME/marlin/wipeout-data`, falling back to
//! `~/.local/share/marlin/wipeout-data`; a first-run downloader will populate
//! that directory later.

const std = @import("std");
const Io = std.Io;

pub const max_asset_bytes: usize = 32 * 1024 * 1024;

pub const Assets = struct {
    io: Io,
    gpa: std.mem.Allocator,
    root: []const u8,

    pub fn init(io: Io, gpa: std.mem.Allocator, root: []const u8) Assets {
        return .{ .io = io, .gpa = gpa, .root = root };
    }

    /// Read `<root>/<sub_path>` fully. Caller owns the returned bytes.
    pub fn load(self: *const Assets, sub_path: []const u8) ![]u8 {
        const full = try std.fs.path.join(self.gpa, &.{ self.root, sub_path });
        defer self.gpa.free(full);
        return Io.Dir.cwd().readFileAlloc(self.io, full, self.gpa, .limited(max_asset_bytes));
    }

    pub fn exists(self: *const Assets, sub_path: []const u8) bool {
        const full = std.fs.path.join(self.gpa, &.{ self.root, sub_path }) catch return false;
        defer self.gpa.free(full);
        _ = Io.Dir.cwd().statFile(self.io, full, .{}) catch return false;
        return true;
    }

    /// Join a track directory with a file name: ("wipeout/track01/", "track.trf").
    pub fn path(self: *const Assets, dir: []const u8, name: []const u8) ![]u8 {
        return std.fs.path.join(self.gpa, &.{ dir, name });
    }
};

/// Resolve the default data root. Caller owns the result.
pub fn defaultRoot(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("MARLIN_WIPEOUT_DATA")) |explicit| {
        if (explicit.len > 0) return gpa.dupe(u8, explicit);
    }
    if (env.get("XDG_DATA_HOME")) |xdg| {
        if (xdg.len > 0) return std.fs.path.join(gpa, &.{ xdg, "marlin", "wipeout-data" });
    }
    const home = env.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(gpa, &.{ home, ".local", "share", "marlin", "wipeout-data" });
}
