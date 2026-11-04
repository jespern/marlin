//! Unit tests for shell_tab.zig: the `!!` shell tab against a fake daemon.
const std = @import("std");
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");
const Editor = @import("editor.zig");
const tui = @import("tui.zig");
const shell_tab = @import("shell_tab.zig");
const App = tui.App;

const Harness = struct {
    threaded: std.Io.Threaded,
    output: std.Io.Writer.Allocating,
    conn: attach.Conn,
    app: App,

    fn init(self: *Harness, remote_shell: bool) void {
        const gpa = std.testing.allocator;
        self.threaded = .init(gpa, .{});
        self.output = .init(gpa);
        self.conn = undefined;
        self.conn.gpa = gpa;
        self.conn.writer = &self.output.writer;
        self.conn.remote_shell = remote_shell;
        self.conn.hostname_len = 0;
        self.app = .{ .gpa = gpa, .io = self.threaded.io(), .conn = &self.conn, .view = .{ .sid = 42, .editor = Editor.init(gpa) } };
        self.app.term_cols = 80;
        self.app.term_rows = 25;
    }

    fn deinit(self: *Harness) void {
        self.app.deinit();
        self.output.deinit();
        self.threaded.deinit();
    }

    /// Client messages sent since the last call, decoded.
    fn sent(self: *Harness, arena: std.mem.Allocator) ![]proto.ClientMsg {
        var msgs: std.ArrayList(proto.ClientMsg) = .empty;
        var lines = std.mem.splitScalar(u8, self.output.written(), '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try msgs.append(arena, try proto.decode(proto.ClientMsg, arena, try arena.dupe(u8, line)));
        }
        self.output.clearRetainingCapacity();
        return msgs.items;
    }

    fn daemonSays(self: *Harness, comptime json: []const u8, args: anytype) !void {
        self.app.handleDaemonLine(try std.fmt.allocPrint(std.testing.allocator, json, args));
    }
};

fn decodedInput(arena: std.mem.Allocator, msg: proto.ClientMsg) ![]const u8 {
    const data = msg.shell_input.data_base64;
    const decoder = std.base64.standard.Decoder;
    const bytes = try arena.alloc(u8, try decoder.calcSizeForSlice(data));
    try decoder.decode(bytes, data);
    return bytes;
}

test "!! explains itself when the daemon cannot serve shells" {
    var h: Harness = undefined;
    h.init(false);
    defer h.deinit();
    h.app.runCommand("!!");
    try std.testing.expect(h.app.shell == null);
    try std.testing.expect(std.mem.indexOf(u8, h.app.notice.items, "no shell tab") != null);
    try std.testing.expectEqual(@as(usize, 0), h.output.written().len);
}

test "the shell tab opens, buffers early keys, and round-trips output" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    h.app.runCommand("!!");
    const tab = h.app.shell.?;
    var msgs = try h.sent(arena);
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    const open = msgs[0].shell_open;
    try std.testing.expectEqual(@as(u64, 42), open.sid);
    try std.testing.expectEqual(@as(u16, 80), open.cols);
    try std.testing.expectEqual(@as(u16, 24), open.rows); // one row for the status bar

    // Typed before the daemon confirmed: held, then flushed in order.
    try std.testing.expect(shell_tab.key(&h.app, .{ .codepoint = 'l', .text = "l" }));
    try std.testing.expect(shell_tab.key(&h.app, .{ .codepoint = 's', .text = "s" }));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent(arena)).len);
    try h.daemonSays("{{\"shell_opened\":{{\"shell_id\":5,\"request_id\":{d}}}}}", .{open.request_id});
    try std.testing.expectEqual(@as(?u64, 5), tab.shell_id);
    msgs = try h.sent(arena);
    try std.testing.expectEqual(@as(u64, 5), msgs[0].shell_resize.shell_id);
    try std.testing.expectEqualStrings("ls", try decodedInput(arena, msgs[1]));

    // Output feeds the emulator; its query replies go back, then an ack.
    var out_buf: [64]u8 = undefined;
    const out = std.base64.standard.Encoder.encode(&out_buf, "hi\x1b[6n");
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":5,\"data_base64\":\"{s}\"}}}}", .{out});
    msgs = try h.sent(arena);
    try std.testing.expectEqualStrings("\x1b[1;3R", try decodedInput(arena, msgs[0]));
    try std.testing.expectEqual(@as(u64, 6), msgs[1].shell_ack.bytes);

    // Output for some other shell is not ours to show or acknowledge.
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":9,\"data_base64\":\"{s}\"}}}}", .{out});
    try std.testing.expectEqual(@as(usize, 0), (try h.sent(arena)).len);
}

test "ctrl+] hides the shell, !! brings it back, and exit closes it" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    h.app.runCommand("!!");
    const request_id = (try h.sent(arena))[0].shell_open.request_id;
    try h.daemonSays("{{\"shell_opened\":{{\"shell_id\":5,\"request_id\":{d}}}}}", .{request_id});
    _ = try h.sent(arena);

    try std.testing.expect(shell_tab.key(&h.app, .{ .codepoint = ']', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!shell_tab.visible(&h.app));
    // Hidden, keys belong to Marlin again.
    try std.testing.expect(!shell_tab.key(&h.app, .{ .codepoint = 'x', .text = "x" }));
    h.app.runCommand("!!");
    try std.testing.expect(shell_tab.visible(&h.app));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent(arena)).len); // same shell, no new open

    try h.daemonSays("{{\"shell_exited\":{{\"shell_id\":5,\"code\":3}}}}", .{});
    try std.testing.expect(h.app.shell == null);
    try std.testing.expect(std.mem.indexOf(u8, h.app.notice.items, "status 3") != null);
}

test "a refused shell_open closes the tab with the daemon's reason" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    h.app.runCommand("!!");
    const request_id = (try h.sent(arena_state.allocator()))[0].shell_open.request_id;
    try h.daemonSays("{{\"err\":{{\"code\":\"shell\",\"msg\":\"could not start a shell: PtyUnavailable\",\"request_id\":{d}}}}}", .{request_id});
    try std.testing.expect(h.app.shell == null);
    try std.testing.expectEqualStrings("could not start a shell: PtyUnavailable", h.app.notice.items);
}

test "the shell tab draws the grid above a status bar" {
    const gpa = std.testing.allocator;
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    h.app.runCommand("!!");
    const request_id = (try h.sent(arena))[0].shell_open.request_id;
    try h.daemonSays("{{\"shell_opened\":{{\"shell_id\":5,\"request_id\":{d}}}}}", .{request_id});
    var out_buf: [64]u8 = undefined;
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":5,\"data_base64\":\"{s}\"}}}}", .{std.base64.standard.Encoder.encode(&out_buf, "$ ls")});

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var render_out: std.Io.Writer.Allocating = .init(gpa);
    defer render_out.deinit();
    var vx = try vaxis.init(h.threaded.io(), gpa, &env, .{});
    defer vx.deinit(gpa, &render_out.writer);
    try vx.resize(gpa, &render_out.writer, .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    try tui.draw(&h.app, &vx, arena);

    const win = vx.window();
    try std.testing.expectEqualStrings("$", win.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("l", win.readCell(2, 0).?.char.grapheme);
    var status: std.ArrayList(u8) = .empty;
    for (0..80) |col| try status.appendSlice(arena, win.readCell(@intCast(col), 24).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, status.items, "ctrl+] back to marlin") != null);
}
