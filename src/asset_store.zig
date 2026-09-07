//! Shared transport/cache policy. Container decoding belongs to each consumer.
const std = @import("std");
const Io = std.Io;
pub const Progress = struct {
    done: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
};
pub const Spec = struct {
    filename: []const u8,
    sha256: []const u8,
    url: []const u8,
    max_bytes: usize,
    validate: *const fn (std.mem.Allocator, []const u8) anyerror!void,
};
pub fn cachePath(a: std.mem.Allocator, env: *const std.process.Environ.Map, spec: Spec) ![]u8 {
    const root = if (env.get("XDG_CACHE_HOME")) |p| if (std.fs.path.isAbsolute(p)) p else null else null;
    const base = if (root) |p| try a.dupe(u8, p) else try std.fs.path.join(a, &.{ env.get("HOME") orelse return error.MissingCacheDirectory, ".cache" });
    defer a.free(base);
    return std.fs.path.join(a, &.{ base, "marlin", "assets", spec.sha256, spec.filename });
}
pub fn verify(a: std.mem.Allocator, spec: Spec, bytes: []const u8) !void {
    if (bytes.len > spec.max_bytes) return error.AssetTooLarge;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), spec.sha256)) return error.AssetChecksumMismatch;
    try spec.validate(a, bytes);
}
/// A missing or invalid cache is a miss; filesystem/allocator failures propagate.
pub fn readCached(a: std.mem.Allocator, io: Io, spec: Spec, path: []const u8) !?[]u8 {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(spec.max_bytes + 1)) catch |err| switch (err) {
        error.FileNotFound, error.StreamTooLong => return null,
        else => return err,
    };
    verify(a, spec, bytes) catch |err| {
        a.free(bytes);
        if (err == error.OutOfMemory) return err;
        return null;
    };
    return bytes;
}
const Fetch = *const fn (std.mem.Allocator, Io, Spec, *Progress) anyerror![]u8;
pub fn acquireAt(a: std.mem.Allocator, io: Io, spec: Spec, path: []const u8, progress: *Progress) ![]u8 {
    return acquireWith(a, io, spec, path, progress, download);
}
fn acquireWith(a: std.mem.Allocator, io: Io, spec: Spec, path: []const u8, progress: *Progress, fetch: Fetch) ![]u8 {
    if (progress.cancel.load(.acquire)) return error.Cancelled;
    if (try readCached(a, io, spec, path)) |bytes| {
        progress.done.store(bytes.len, .release);
        progress.total.store(bytes.len, .release);
        return bytes;
    }
    if (try readCheckout(a, io, spec)) |bytes| {
        errdefer a.free(bytes);
        try install(a, io, path, bytes, progress);
        progress.done.store(bytes.len, .release);
        progress.total.store(bytes.len, .release);
        return bytes;
    }
    const bytes = try fetch(a, io, spec, progress);
    errdefer a.free(bytes);
    if (progress.cancel.load(.acquire)) return error.Cancelled;
    try verify(a, spec, bytes);
    try install(a, io, path, bytes, progress);
    return bytes;
}
fn install(a: std.mem.Allocator, io: Io, path: []const u8, bytes: []const u8, progress: *Progress) !void {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const temp = try std.fmt.allocPrint(a, "{s}.{x}.part", .{ path, std.mem.readInt(u64, &nonce, .little) });
    defer a.free(temp);
    errdefer Io.Dir.cwd().deleteFile(io, temp) catch {};
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = temp, .data = bytes });
    if (progress.cancel.load(.acquire)) return error.Cancelled;
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), path, io);
}
/// A source checkout running `zig-out/bin/marlin` has the bundle at
/// `<checkout>/assets/<filename>`. It is held to the same digest and
/// validator as a download, so it only ever substitutes for the network,
/// never for verification; anything else is a miss.
fn readCheckout(a: std.mem.Allocator, io: Io, spec: Spec) !?[]u8 {
    if (std.process.executablePathAlloc(io, a)) |exe| {
        defer a.free(exe);
        if (std.fs.path.dirname(exe)) |bin_dir| {
            const path = try std.fs.path.join(a, &.{ bin_dir, "..", "..", "assets", spec.filename });
            defer a.free(path);
            if (try readCached(a, io, spec, path)) |bytes| return bytes;
        }
    } else |_| {}
    // `zig build run` and the test runner execute from the checkout root.
    const local = try std.fs.path.join(a, &.{ "assets", spec.filename });
    defer a.free(local);
    return readCached(a, io, spec, local);
}

/// Copy an old cache only after verifying it against the current pinned bundle.
pub fn migrate(a: std.mem.Allocator, io: Io, spec: Spec, old: []const u8, dest: []const u8) !void {
    if (try readCached(a, io, spec, dest)) |bytes| {
        a.free(bytes);
        return;
    }
    const bytes = try readCached(a, io, spec, old) orelse return;
    defer a.free(bytes);
    var progress = Progress{};
    try install(a, io, dest, bytes, &progress);
}

fn download(a: std.mem.Allocator, io: Io, spec: Spec, progress: *Progress) ![]u8 {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, try std.Uri.parse(spec.url), .{ .redirect_behavior = @enumFromInt(3) });
    defer request.deinit();
    try request.sendBodiless();
    var head: [4096]u8 = undefined;
    var response = try request.receiveHead(&head);
    if (response.head.status != .ok) return error.AssetDownloadHttpStatus;
    if (response.head.content_length) |n| {
        if (n > spec.max_bytes) return error.AssetTooLarge;
        progress.total.store(n, .release);
    }
    var transfer: [8192]u8 = undefined;
    const reader = response.reader(&transfer);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    var chunk: [8192]u8 = undefined;
    while (true) {
        if (progress.cancel.load(.acquire)) return error.Cancelled;
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        if (n > spec.max_bytes - bytes.items.len) return error.AssetTooLarge;
        try bytes.appendSlice(a, chunk[0..n]);
        progress.done.store(bytes.items.len, .release);
    }
    return bytes.toOwnedSlice(a);
}
fn fixture(a: std.mem.Allocator, _: Io, _: Spec, _: *Progress) ![]u8 {
    return a.dupe(u8, "abc");
}
fn offline(_: std.mem.Allocator, _: Io, _: Spec, _: *Progress) ![]u8 {
    return error.Offline;
}
fn corrupt(a: std.mem.Allocator, _: Io, _: Spec, _: *Progress) ![]u8 {
    return a.dupe(u8, "bad");
}
fn valid(_: std.mem.Allocator, _: []const u8) !void {}
const test_spec = Spec{ .filename = "test.pak", .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", .url = "https://invalid.invalid", .max_bytes = 3, .validate = valid };
test "verified download, offline reuse, repair, bounds and cancellation" {
    const a = std.testing.allocator;
    var threaded: Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/test.pak", .{tmp.sub_path});
    defer a.free(path);
    var p = Progress{};
    try std.testing.expectError(error.Offline, acquireWith(a, io, test_spec, path, &p, offline));
    try std.testing.expectError(error.AssetChecksumMismatch, acquireWith(a, io, test_spec, path, &p, corrupt));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, path, .{}));
    a.free(try acquireWith(a, io, test_spec, path, &p, fixture));
    a.free(try acquireWith(a, io, test_spec, path, &p, offline));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "bad" });
    a.free(try acquireWith(a, io, test_spec, path, &p, fixture));
    try std.testing.expectError(error.AssetTooLarge, verify(a, test_spec, "abcd"));
    p.cancel.store(true, .release);
    try std.testing.expectError(error.Cancelled, acquireWith(a, io, test_spec, path, &p, fixture));
}
test "cache path namespaces revisions and honors absolute XDG" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("HOME", "/home/test");
    try env.put("XDG_CACHE_HOME", "relative");
    const first = try cachePath(a, &env, test_spec);
    defer a.free(first);
    try std.testing.expect(std.mem.startsWith(u8, first, "/home/test/.cache/marlin/assets/"));
    try env.put("XDG_CACHE_HOME", "/tmp/cache");
    const second = try cachePath(a, &env, test_spec);
    defer a.free(second);
    try std.testing.expect(std.mem.startsWith(u8, second, "/tmp/cache/marlin/assets/"));
}

fn rejectFormat(_: std.mem.Allocator, _: []const u8) !void {
    return error.BadFormat;
}
fn cancelFetch(a: std.mem.Allocator, _: Io, _: Spec, p: *Progress) ![]u8 {
    p.cancel.store(true, .release);
    return a.dupe(u8, "abc");
}
test "format rejection, interrupted fetch and verified legacy migration" {
    const a = std.testing.allocator;
    var threaded: Io.Threaded = .init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const old = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/old.pak", .{tmp.sub_path});
    defer a.free(old);
    const dest = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/new.pak", .{tmp.sub_path});
    defer a.free(dest);
    var spec = test_spec;
    spec.validate = rejectFormat;
    var p = Progress{};
    try std.testing.expectError(error.BadFormat, acquireWith(a, io, spec, dest, &p, fixture));
    try std.testing.expectError(error.Cancelled, acquireWith(a, io, test_spec, dest, &p, cancelFetch));
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, dest, .{}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = old, .data = "bad" });
    try migrate(a, io, test_spec, old, dest);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().statFile(io, dest, .{}));
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = old, .data = "abc" });
    try migrate(a, io, test_spec, old, dest);
    p.cancel.store(false, .release);
    a.free(try acquireWith(a, io, test_spec, dest, &p, offline));
}
