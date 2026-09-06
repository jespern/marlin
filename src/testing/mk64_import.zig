const std = @import("std");
const mk = @import("mk64");
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("usage: zig build mk64-import -- ROM output.mkassets\n", .{});
        return error.InvalidArguments;
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(16 * 1024 * 1024));
    defer init.gpa.free(bytes);
    const bundle = try mk.assets.importRom(init.gpa, bytes);
    defer init.gpa.free(bundle);
    var loaded = try mk.assets.load(init.gpa, bundle);
    defer loaded.deinit();
    try mk.assets.verifyRom(init.gpa, bytes, &loaded);
    var nonce: [8]u8 = undefined;
    init.io.random(&nonce);
    const temp = try std.fmt.allocPrint(init.gpa, "{s}.{x}.tmp", .{ args[2], std.mem.readInt(u64, &nonce, .little) });
    defer init.gpa.free(temp);
    errdefer std.Io.Dir.cwd().deleteFile(init.io, temp) catch {};
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = temp, .data = bundle });
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), args[2], init.io);
    std.debug.print("Imported and validated {d} bytes: {d} triangles, {d} path points, {d} characters\n", .{ bundle.len, loaded.track.triangles.len, loaded.track.path.len, loaded.sprites.len });
}
