const std = @import("std");
const store = @import("asset_store");
const assets = @import("assets.zig");
pub const digest_hex = "48a17a44839db3375b23068233bb426efbd4905557d91ce6b94681c1c2730e75";
pub const filename = "mk.pak";
pub const repository_path = "assets/" ++ filename;
pub const url = "https://raw.githubusercontent.com/jespern/marlin/main/" ++ repository_path;
pub const spec = store.Spec{ .filename = filename, .sha256 = digest_hex, .url = url, .max_bytes = 8 * 1024 * 1024, .validate = validate };
fn validate(a: std.mem.Allocator, bytes: []const u8) !void {
    var set = try assets.load(a, bytes);
    set.deinit();
}
pub fn cachePath(a: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    return store.cachePath(a, env, spec);
}
pub fn acquire(a: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]u8 {
    const path = try cachePath(a, env);
    defer a.free(path);
    const old_name = digest_hex ++ ".mkassets";
    const base = if (env.get("XDG_CACHE_HOME")) |dir| try a.dupe(u8, dir) else try std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingCacheDirectory, ".cache" });
    defer a.free(base);
    const old = try std.fs.path.join(a, &.{ base, "marlin", "mk64", old_name });
    defer a.free(old);
    try store.migrate(a, io, spec, old, path);
    var progress = store.Progress{};
    return store.acquireAt(a, io, spec, path, &progress);
}
