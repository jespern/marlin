//! First-run download; content-addressed cache survives offline launches.
const std = @import("std");
const assets = @import("assets.zig");
const Io = std.Io;
pub const digest_hex = "48a17a44839db3375b23068233bb426efbd4905557d91ce6b94681c1c2730e75";
pub const filename = digest_hex ++ ".mkassets";
pub const repository_path = "assets/mk64/" ++ filename;
pub const url = "https://raw.githubusercontent.com/jespern/marlin/main/" ++ repository_path;
const max_bytes = 8 * 1024 * 1024;

pub fn cachePath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_CACHE_HOME")) |dir| if (std.fs.path.isAbsolute(dir)) return std.fs.path.join(gpa, &.{ dir, "marlin", "mk64", filename });
    const home = env.get("HOME") orelse return error.MissingCacheDirectory;
    return std.fs.path.join(gpa, &.{ home, ".cache", "marlin", "mk64", filename });
}
fn validate(gpa: std.mem.Allocator, bytes: []const u8) !void {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, &hex, digest_hex)) return error.AssetDownloadChecksumMismatch;
    var set = try assets.load(gpa, bytes);
    set.deinit();
}
pub fn acquire(gpa: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) ![]u8 {
    const path = try cachePath(gpa, env);
    defer gpa.free(path);
    return acquireAt(gpa, io, path, download);
}
fn acquireAt(gpa: std.mem.Allocator, io: Io, path: []const u8, fetch: *const fn (std.mem.Allocator, Io) anyerror![]u8) ![]u8 {
    const cached = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => null,
        else => return err,
    };
    if (cached) |bytes| {
        if (validate(gpa, bytes)) |_| return bytes else |_| gpa.free(bytes);
    }
    const bytes = try fetch(gpa, io);
    errdefer gpa.free(bytes);
    try validate(gpa, bytes);
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const temp = try std.fmt.allocPrint(gpa, "{s}.{x}.part", .{ path, std.mem.readInt(u64, &nonce, .little) });
    defer gpa.free(temp);
    errdefer Io.Dir.cwd().deleteFile(io, temp) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes });
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), path, io);
    return bytes;
}
fn download(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var message_buf: [512]u8 = undefined;
    var message = Io.File.stderr().writer(io, &message_buf);
    try message.interface.writeAll("Downloading Mario Kart assets (235 KiB)…\n");
    try message.interface.flush();
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(url), .{ .redirect_behavior = @enumFromInt(3) });
    defer request.deinit();
    try request.sendBodiless();
    var head: [4096]u8 = undefined;
    var response = try request.receiveHead(&head);
    if (response.head.status != .ok) return error.AssetDownloadHttpStatus;
    if (response.head.content_length) |n| if (n > max_bytes) return error.AssetDownloadTooLarge;
    var transfer: [8192]u8 = undefined;
    return response.reader(&transfer).allocRemaining(gpa, .limited(max_bytes));
}
fn fixture(gpa: std.mem.Allocator, io: Io) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, repository_path, gpa, .limited(max_bytes));
}
fn offline(_: std.mem.Allocator, _: Io) ![]u8 {
    return error.Offline;
}
fn corrupt(gpa: std.mem.Allocator, _: Io) ![]u8 {
    return gpa.dupe(u8, "not an asset bundle");
}

test "first download, offline cache reuse, corruption repair and failed download" {
    const a = std.testing.allocator;
    var threaded: Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/assets.mkassets", .{tmp.sub_path});
    defer a.free(path);
    try std.testing.expectError(error.Offline, acquireAt(a, io, path, offline));
    try std.testing.expectError(error.AssetDownloadChecksumMismatch, acquireAt(a, io, path, corrupt));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
    a.free(try acquireAt(a, io, path, fixture));
    a.free(try acquireAt(a, io, path, offline));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "damaged" });
    try std.testing.expectError(error.Offline, acquireAt(a, io, path, offline));
    a.free(try acquireAt(a, io, path, fixture));
    a.free(try acquireAt(a, io, path, offline));
}
