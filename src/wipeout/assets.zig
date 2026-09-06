//! Asset root resolution and whole-file loading.
//!
//! The on-disk layout mirrors the original game (`<root>/wipeout/track01/…`)
//! so the same tree can feed both this port and the reference C build.
//! The default root is `$XDG_DATA_HOME/marlin/wipeout-data`, falling back to
//! `~/.local/share/marlin/wipeout-data`. A root either holds the extracted
//! tree or the single-file bundle `wipeout.pak` (see `bundle.zig`), which
//! the client downloads on first run.

const std = @import("std");
const Io = std.Io;
const bundle_mod = @import("bundle.zig");

/// Where the client fetches the bundle from; `MARLIN_WIPEOUT_URL` overrides.
pub const default_bundle_url = "https://raw.githubusercontent.com/jespern/marlin/main/assets/wipeout.pak";
/// Present in every complete extracted tree; its absence means "no tree".
pub const tree_probe_file = "wipeout/common/allsh.prm";

pub const max_asset_bytes: usize = 32 * 1024 * 1024;

pub const Assets = struct {
    io: Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    /// When set, files come from the bundle instead of `<root>`.
    bundle: ?*const bundle_mod.Bundle = null,

    pub fn init(io: Io, gpa: std.mem.Allocator, root: []const u8) Assets {
        return .{ .io = io, .gpa = gpa, .root = root };
    }

    pub fn initBundle(io: Io, gpa: std.mem.Allocator, root: []const u8, bundle: *const bundle_mod.Bundle) Assets {
        return .{ .io = io, .gpa = gpa, .root = root, .bundle = bundle };
    }

    /// Read `<root>/<sub_path>` fully. Caller owns the returned bytes.
    pub fn load(self: *const Assets, sub_path: []const u8) ![]u8 {
        if (self.bundle) |b| {
            const data = b.get(sub_path) orelse return error.FileNotFound;
            return self.gpa.dupe(u8, data);
        }
        const full = try std.fs.path.join(self.gpa, &.{ self.root, sub_path });
        defer self.gpa.free(full);
        return Io.Dir.cwd().readFileAlloc(self.io, full, self.gpa, .limited(max_asset_bytes));
    }

    pub fn exists(self: *const Assets, sub_path: []const u8) bool {
        if (self.bundle) |b| return b.get(sub_path) != null;
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

/// `<root>/wipeout.pak`. Caller owns the result.
pub fn bundlePath(gpa: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ root, bundle_mod.file_name });
}

pub fn bundleUrl(env: *const std.process.Environ.Map) []const u8 {
    if (env.get("MARLIN_WIPEOUT_URL")) |url| {
        if (url.len > 0) return url;
    }
    return default_bundle_url;
}

pub const Source = union(enum) {
    /// The extracted tree is in place; read files from it.
    tree,
    /// Only the bundle is there; it is opened and owned by the caller.
    bundle: bundle_mod.Bundle,
};

/// What is available under `root`: the extracted tree wins, else the
/// bundle; `error.AssetsMissing` when there is neither.
pub fn openSource(gpa: std.mem.Allocator, io: Io, root: []const u8) !Source {
    const probe = try std.fs.path.join(gpa, &.{ root, tree_probe_file });
    defer gpa.free(probe);
    if (Io.Dir.cwd().statFile(io, probe, .{})) |_| {
        return .tree;
    } else |_| {}
    const pak = try bundlePath(gpa, root);
    defer gpa.free(pak);
    _ = Io.Dir.cwd().statFile(io, pak, .{}) catch return error.AssetsMissing;
    return .{ .bundle = try bundle_mod.Bundle.open(gpa, io, pak) };
}
