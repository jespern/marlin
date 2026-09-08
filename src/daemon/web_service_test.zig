const std = @import("std");
const service = @import("web_service.zig");
test {
    std.testing.refAllDecls(service);
}
test "companion log is bounded, strips controls, and only trusts the tailnet startup URL" {
    const gpa = std.testing.allocator;
    var io: std.Io.Threaded = .init(gpa, .{});
    defer io.deinit();
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var s = service.Service{ .gpa = gpa, .io = io.io(), .environ = &env, .exe = "", .port = 8377 };
    for (0..140) |_| s.append("access /send");
    s.append("refused: https://admin.example/");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var snapshot = try s.snapshot(arena.allocator());
    try std.testing.expectEqual(@as(usize, 128), snapshot.logs.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:8377/", snapshot.url);
    s.append("tailnet: https://box.example/ (fixed URL)");
    s.append("bad\x1b[31m\rlog");
    snapshot = try s.snapshot(arena.allocator());
    try std.testing.expectEqualStrings("https://box.example/", snapshot.url);
    try std.testing.expectEqualStrings("bad [31m log", snapshot.logs[127]);
}
test "companion owns the real child process and reaps it on stop" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-companion");
    defer temp.deinit();
    const file = try std.fmt.allocPrintSentinel(gpa, "{s}/peer", .{temp.path}, 0);
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "#!/bin/sh\ntest \"$1\" = _web || exit 9\nprintf 'web access GET /events\\n' >&2\nexec /bin/sleep 30\n" });
    try std.testing.expectEqual(@as(c_int, 0), std.c.chmod(file, 0o700));
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    var s = service.Service{ .gpa = gpa, .io = io, .environ = &env, .exe = file, .port = 8377 };
    try s.start();
    defer s.stop();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var ready = false;
    for (0..200) |_| {
        const snapshot = try s.snapshot(arena.allocator());
        if (snapshot.logs.len > 0) {
            ready = true;
            break;
        }
        try io.sleep(.fromMilliseconds(5), .awake);
    }
    try std.testing.expect(ready);
    s.stop();
    const snapshot = try s.snapshot(arena.allocator());
    try std.testing.expectEqualStrings("stopped", snapshot.state);
    try std.testing.expectEqualStrings("web access GET /events", snapshot.logs[0]);
    try std.testing.expect(s.pid == null);
}
