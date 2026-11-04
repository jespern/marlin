//! Unit tests for shell_tab.zig: `!!` shell tabs against a fake daemon.
const std = @import("std");
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");
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
    arena: std.heap.ArenaAllocator,

    fn init(self: *Harness, remote_shell: bool) void {
        const gpa = std.testing.allocator;
        self.threaded = .init(gpa, .{});
        self.output = .init(gpa);
        self.arena = .init(gpa);
        self.conn = undefined;
        self.conn.gpa = gpa;
        self.conn.writer = &self.output.writer;
        self.conn.remote_shell = remote_shell;
        self.conn.hostname_len = 0;
        self.app = .{ .gpa = gpa, .io = self.threaded.io(), .conn = &self.conn, .view = .{ .sid = 42, .editor = Editor.init(gpa) } };
        self.app.term_cols = 80;
        self.app.term_rows = 25;
        self.app.cell_px_w = 9;
        self.app.cell_px_h = 18;
    }

    fn deinit(self: *Harness) void {
        self.app.deinit();
        self.arena.deinit();
        self.output.deinit();
        self.threaded.deinit();
    }

    /// Client messages sent since the last call, decoded.
    fn sent(self: *Harness) ![]proto.ClientMsg {
        const arena = self.arena.allocator();
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

    /// The daemon confirms `request_id` as `shell_id` and sends a snapshot
    /// of a terminal that printed `screen`.
    fn daemonOpens(self: *Harness, request_id: u64, shell_id: u64, screen: []const u8) !void {
        try self.daemonSays("{{\"shell_opened\":{{\"shell_id\":{d},\"request_id\":{d}}}}}", .{ shell_id, request_id });
        const gpa = std.testing.allocator;
        var t: vt.Terminal = try .init(self.threaded.io(), gpa, .{ .cols = 80, .rows = 24 });
        defer t.deinit(gpa);
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(screen);
        var raw: std.Io.Writer.Allocating = .init(gpa);
        defer raw.deinit();
        try vt.snapshot.encode(gpa, &raw.writer, &t, .{ .continuation = .ground });
        const encoded = try self.arena.allocator().alloc(u8, std.base64.standard.Encoder.calcSize(raw.written().len));
        try self.daemonSays("{{\"shell_snapshot\":{{\"shell_id\":{d},\"data_base64\":\"{s}\"}}}}", .{ shell_id, std.base64.standard.Encoder.encode(encoded, raw.written()) });
    }

    fn press(self: *Harness, k: vaxis.Key) bool {
        return shell_tab.key(&self.app, k);
    }
};

fn decodedInput(arena: std.mem.Allocator, msg: proto.ClientMsg) ![]const u8 {
    const data = msg.shell_input.data_base64;
    const decoder = std.base64.standard.Decoder;
    const bytes = try arena.alloc(u8, try decoder.calcSizeForSlice(data));
    try decoder.decode(bytes, data);
    return bytes;
}

const ctrl_bracket: vaxis.Key = .{ .codepoint = ']', .mods = .{ .ctrl = true } };

test "!! explains itself when the daemon cannot serve shells" {
    var h: Harness = undefined;
    h.init(false);
    defer h.deinit();
    h.app.runCommand("!!");
    try std.testing.expect(!shell_tab.visible(&h.app));
    try std.testing.expect(std.mem.indexOf(u8, h.app.notice.items, "no shell tabs") != null);
    try std.testing.expectEqual(@as(usize, 0), h.output.written().len);
}

test "a new shell buffers early keys, restores its snapshot, and acknowledges output" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    const arena = h.arena.allocator();

    h.app.runCommand("!!");
    var msgs = try h.sent();
    const open = msgs[0].shell_open;
    try std.testing.expectEqual(@as(u64, 42), open.sid);
    try std.testing.expectEqual(@as(u16, 24), open.rows); // one row for the bar
    try std.testing.expectEqual(@as(u16, 9), open.cell_width);

    // Typed before the daemon confirmed: held, then flushed in order.
    try std.testing.expect(h.press(.{ .codepoint = 'l', .text = "l" }));
    try std.testing.expect(h.press(.{ .codepoint = 's', .text = "s" }));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
    try h.daemonOpens(open.request_id, 5, "$ ");
    msgs = try h.sent();
    try std.testing.expectEqualStrings("ls", try decodedInput(arena, msgs[0]));
    try std.testing.expect(h.app.shells.items.items[0].emulator != null);

    var out_buf: [64]u8 = undefined;
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":5,\"data_base64\":\"{s}\"}}}}", .{std.base64.standard.Encoder.encode(&out_buf, "hi")});
    msgs = try h.sent();
    try std.testing.expectEqual(@as(u64, 2), msgs[0].shell_ack.bytes);

    // Output for a shell this client is not showing is not ours.
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":9,\"data_base64\":\"aGk=\"}}}}", .{});
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
}

test "ctrl+] menu: back to marlin, new shell, switch, detach, literal ^]" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    const arena = h.arena.allocator();

    h.app.runCommand("!!");
    try h.daemonOpens((try h.sent())[0].shell_open.request_id, 5, "first");
    _ = try h.sent();

    // ctrl+] then esc: back to Marlin; keys are Marlin's again. A legacy
    // terminal's ctrl+] arrives as the raw GS byte.
    try std.testing.expect(h.press(.{ .codepoint = 0x1d }));
    try std.testing.expect(h.press(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expect(!shell_tab.visible(&h.app));
    try std.testing.expect(!h.press(.{ .codepoint = 'x', .text = "x" }));
    h.app.runCommand("!!");
    try std.testing.expect(shell_tab.visible(&h.app));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len); // same shell

    // ctrl+] n: a second shell, which becomes active.
    _ = h.press(ctrl_bracket);
    _ = h.press(.{ .codepoint = 'n', .text = "n" });
    try h.daemonOpens((try h.sent())[0].shell_open.request_id, 6, "second");
    _ = try h.sent();
    try std.testing.expectEqual(@as(usize, 1), h.app.shells.active);

    // ctrl+] 1: back to the first, which is resized to this terminal.
    _ = h.press(ctrl_bracket);
    _ = h.press(.{ .codepoint = '1', .text = "1" });
    try std.testing.expectEqual(@as(usize, 0), h.app.shells.active);
    try std.testing.expectEqual(@as(u64, 5), (try h.sent())[0].shell_resize.shell_id);

    // ctrl+] ctrl+]: the program gets a literal ^].
    _ = h.press(ctrl_bracket);
    _ = h.press(ctrl_bracket);
    try std.testing.expectEqualStrings("\x1d", try decodedInput(arena, (try h.sent())[0]));

    // ctrl+] d: detach; the shell keeps running on the daemon.
    _ = h.press(ctrl_bracket);
    _ = h.press(.{ .codepoint = 'd', .text = "d" });
    try std.testing.expectEqual(@as(u64, 5), (try h.sent())[0].shell_detach.shell_id);
    try std.testing.expectEqual(@as(usize, 1), h.app.shells.items.items.len);
    try std.testing.expectEqual(@as(?u64, 6), h.app.shells.items.items[0].shell_id);
}

test "!! with no tabs attaches every shell the daemon runs, titled from its list" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();

    shell_tab.connected(&h.app);
    try std.testing.expect((try h.sent())[0] == .shell_list);
    try h.daemonSays("{{\"shell_list_result\":{{\"shells\":[{{\"shell_id\":3,\"title\":\"htop\"}},{{\"shell_id\":4,\"cwd\":\"/home/me/vim notes\"}}]}}}}", .{});

    h.app.runCommand("!!");
    const msgs = try h.sent();
    try std.testing.expectEqual(@as(usize, 2), msgs.len);
    try std.testing.expectEqual(@as(u64, 3), msgs[0].shell_attach.shell_id);
    try std.testing.expectEqual(@as(u64, 4), msgs[1].shell_attach.shell_id);
    try std.testing.expectEqual(@as(usize, 1), h.app.shells.active); // newest
    try h.daemonOpens(msgs[0].shell_attach.request_id, 3, "a");
    try h.daemonOpens(msgs[1].shell_attach.request_id, 4, "b");

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    var render_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer render_out.deinit();
    var vx = try vaxis.init(h.threaded.io(), std.testing.allocator, &env, .{});
    defer vx.deinit(std.testing.allocator, &render_out.writer);
    try vx.resize(std.testing.allocator, &render_out.writer, .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    try tui.draw(&h.app, &vx, h.arena.allocator());
    const win = vx.window();
    try std.testing.expectEqualStrings("b", win.readCell(0, 0).?.char.grapheme);
    var bar: std.ArrayList(u8) = .empty;
    for (0..80) |col| try bar.appendSlice(h.arena.allocator(), win.readCell(@intCast(col), 24).?.char.grapheme);
    try std.testing.expect(std.mem.indexOf(u8, bar.items, "1 htop") != null);
    try std.testing.expect(std.mem.indexOf(u8, bar.items, "2 vim notes") != null);
    try std.testing.expect(std.mem.indexOf(u8, bar.items, "ctrl+] menu") != null);
}

test "after a lost connection, tabs survive and reattach" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();

    h.app.runCommand("!!");
    try h.daemonOpens((try h.sent())[0].shell_open.request_id, 5, "kept");
    _ = try h.sent();

    shell_tab.connectionLost(&h.app);
    // While down, keys are swallowed rather than sent into the void.
    try std.testing.expect(h.press(.{ .codepoint = 'a', .text = "a" }));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);

    shell_tab.connected(&h.app);
    const msgs = try h.sent();
    try std.testing.expect(msgs[0] == .shell_list);
    try std.testing.expectEqual(@as(u64, 5), msgs[1].shell_attach.shell_id);
    try h.daemonOpens(msgs[1].shell_attach.request_id, 5, "restored");
    try std.testing.expect(h.app.shells.items.items[0].attached);
}

test "exit and refusal close the tab with a reason" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();

    h.app.runCommand("!!");
    try h.daemonOpens((try h.sent())[0].shell_open.request_id, 5, "");
    try h.daemonSays("{{\"shell_exited\":{{\"shell_id\":5,\"code\":3}}}}", .{});
    try std.testing.expect(!shell_tab.visible(&h.app));
    try std.testing.expect(std.mem.indexOf(u8, h.app.notice.items, "status 3") != null);

    h.app.runCommand("!! new");
    const request_id = (try h.sent())[0].shell_open.request_id;
    try h.daemonSays("{{\"err\":{{\"code\":\"shell\",\"msg\":\"could not start a shell: PtyUnavailable\",\"request_id\":{d}}}}}", .{request_id});
    try std.testing.expectEqual(@as(usize, 0), h.app.shells.items.items.len);
    try std.testing.expectEqualStrings("could not start a shell: PtyUnavailable", h.app.notice.items);
}

test "shift+pgup scrolls back and typing returns to the live screen" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();

    h.app.runCommand("!!");
    var lines: std.ArrayList(u8) = .empty;
    for (0..60) |i| try lines.print(h.arena.allocator(), "line {d}\r\n", .{i});
    try h.daemonOpens((try h.sent())[0].shell_open.request_id, 5, lines.items);
    _ = try h.sent();
    const emulator = h.app.shells.items.items[0].emulator.?;

    try std.testing.expect(h.press(.{ .codepoint = vaxis.Key.page_up, .mods = .{ .shift = true } }));
    try std.testing.expect(emulator.scrolledBack());
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
    _ = h.press(.{ .codepoint = 'q', .text = "q" });
    try std.testing.expect(!emulator.scrolledBack());
    try std.testing.expect((try h.sent())[0] == .shell_input);
}
