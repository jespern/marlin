//! Unit tests for shell_tab.zig: shell sessions (`!!`) against a fake daemon.
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

    /// `!!`, then the daemon opens shell 5 showing `screen`.
    fn openShell(self: *Harness, screen: []const u8) !void {
        self.app.runCommand("!!");
        try self.daemonOpens((try self.sent())[0].shell_open.request_id, 5, screen);
        _ = try self.sent();
    }

    fn press(self: *Harness, k: vaxis.Key) bool {
        return shell_tab.key(&self.app, k);
    }

    fn sessionUpsert(self: *Harness, shell_id: u64) !void {
        try self.daemonSays("{{\"session_upsert\":{{\"session\":{{\"sid\":42,\"title\":\"\",\"cwd\":\"/work/proj\",\"model\":\"m\",\"status\":\"idle\",\"created_at\":1,\"running\":false,\"shell_id\":{d}}}}}}}", .{shell_id});
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
    try std.testing.expect(!shell_tab.active(&h.app));
    try std.testing.expect(std.mem.indexOf(u8, h.app.notice.items, "no shell sessions") != null);
    try std.testing.expectEqual(@as(usize, 0), h.output.written().len);
}

test "!! turns the session into a shell sized to the transcript area" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    const arena = h.arena.allocator();

    h.app.runCommand("!!");
    var msgs = try h.sent();
    const open = msgs[0].shell_open;
    try std.testing.expectEqual(@as(u64, 42), open.sid);
    try std.testing.expectEqual(@as(u16, 80), open.cols);
    try std.testing.expectEqual(@as(u16, 22), open.rows); // all but the tab bar, a blank row, and the status line
    try std.testing.expectEqual(@as(u16, 9), open.cell_width);

    // Typed before the daemon confirmed: held, then flushed in order.
    try std.testing.expect(h.press(.{ .codepoint = 'l', .text = "l" }));
    try std.testing.expect(h.press(.{ .codepoint = 's', .text = "s" }));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
    try h.daemonOpens(open.request_id, 5, "$ ");
    msgs = try h.sent();
    try std.testing.expectEqualStrings("ls", try decodedInput(arena, msgs[0]));
    try std.testing.expect(shell_tab.live(&h.app) != null);

    var out_buf: [64]u8 = undefined;
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":5,\"data_base64\":\"{s}\"}}}}", .{std.base64.standard.Encoder.encode(&out_buf, "hi")});
    try std.testing.expectEqual(@as(u64, 2), (try h.sent())[0].shell_ack.bytes);

    // A second !! does not open another shell.
    h.app.runCommand("!!");
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
}

test "Esc at the prompt enters normal mode; full-screen programs get Esc" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    const arena = h.arena.allocator();
    try h.openShell("$ ");

    try std.testing.expect(h.press(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(tui.Mode.normal, h.app.mode);
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
    // Normal-mode keys are Marlin's; i resumes the live shell.
    try std.testing.expect(!h.press(.{ .codepoint = 'k', .text = "k" }));
    try std.testing.expect(h.press(.{ .codepoint = 'i', .text = "i" }));
    try std.testing.expectEqual(tui.Mode.insert, h.app.mode);
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);

    // Alt+N stays Marlin's tab switching.
    try std.testing.expect(!h.press(.{ .codepoint = '2', .text = "2", .mods = .{ .alt = true } }));

    // vim switches to the alternate screen: now Esc is vim's.
    var out_buf: [64]u8 = undefined;
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":5,\"data_base64\":\"{s}\"}}}}", .{std.base64.standard.Encoder.encode(&out_buf, "\x1b[?1049h")});
    _ = try h.sent();
    try std.testing.expect(shell_tab.fullScreen(&h.app));
    try std.testing.expect(h.press(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expectEqual(tui.Mode.insert, h.app.mode);
    try std.testing.expectEqualStrings("\x1b", try decodedInput(arena, (try h.sent())[0]));
}

test "a session another client made a shell is attached when focused; its tab says so" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();

    try h.sessionUpsert(8);
    shell_tab.sync(&h.app);
    const msgs = try h.sent();
    try std.testing.expectEqual(@as(u64, 8), msgs[0].shell_attach.shell_id);
    try std.testing.expectEqual(@as(u16, 22), msgs[0].shell_attach.rows);
    const summary = h.app.sessionSummary(42).?;
    try std.testing.expectEqualStrings("$ proj", summary.shell_label);

    // The shell ended before this client heard: the view lets go of it.
    try h.daemonOpens(msgs[0].shell_attach.request_id, 8, "$ ");
    try h.sessionUpsert(0);
    shell_tab.sync(&h.app);
    try std.testing.expect(!shell_tab.active(&h.app));
}

test "after a lost connection the shell reattaches; exit and refusal end it" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    try h.openShell("kept");

    shell_tab.connectionLost(&h.app);
    // While down, keys are swallowed rather than sent into the void.
    try std.testing.expect(h.press(.{ .codepoint = 'a', .text = "a" }));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
    shell_tab.connected(&h.app);
    const attach_msg = (try h.sent())[0].shell_attach;
    try std.testing.expectEqual(@as(u64, 5), attach_msg.shell_id);
    try h.daemonOpens(attach_msg.request_id, 5, "restored");

    try h.daemonSays("{{\"shell_exited\":{{\"shell_id\":5,\"code\":0}}}}", .{});
    try std.testing.expect(!shell_tab.active(&h.app));
    try std.testing.expectEqual(tui.Mode.insert, h.app.mode);

    h.app.runCommand("!!");
    const request_id = (try h.sent())[0].shell_open.request_id;
    try h.daemonSays("{{\"err\":{{\"code\":\"busy\",\"msg\":\"the session is working; wait for its turn to finish\",\"request_id\":{d}}}}}", .{request_id});
    try std.testing.expect(!shell_tab.active(&h.app));
    try std.testing.expectEqualStrings("the session is working; wait for its turn to finish", h.app.notice.items);
}

test "the terminal continues the transcript: drawn rows, cursor, and search" {
    const gpa = std.testing.allocator;
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    var lines: std.ArrayList(u8) = .empty;
    for (0..40) |i| try lines.print(h.arena.allocator(), "line {d}\r\n", .{i});
    try lines.appendSlice(h.arena.allocator(), "needle here\r\n$ ");
    try h.openShell(lines.items);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var render_out: std.Io.Writer.Allocating = .init(gpa);
    defer render_out.deinit();
    var vx = try vaxis.init(h.threaded.io(), gpa, &env, .{});
    defer vx.deinit(gpa, &render_out.writer);
    try vx.resize(gpa, &render_out.writer, .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    var frame = std.heap.ArenaAllocator.init(gpa);
    defer frame.deinit();
    try tui.draw(&h.app, &vx, frame.allocator());

    // Live: the screen fills the area down to the blank row above the
    // status line, prompt last.
    const win = vx.window();
    const row_text = struct {
        fn get(w: vaxis.Window, a: std.mem.Allocator, row: u16) ![]const u8 {
            var out: std.ArrayList(u8) = .empty;
            for (0..w.width) |col| try out.appendSlice(a, w.readCell(@intCast(col), row).?.char.grapheme);
            return std.mem.trimEnd(u8, out.items, " ");
        }
    }.get;
    try std.testing.expectEqualStrings("needle here", try row_text(win, frame.allocator(), 21));
    try std.testing.expectEqualStrings("$", try row_text(win, frame.allocator(), 22));
    try std.testing.expectEqualStrings("", try row_text(win, frame.allocator(), 23));
    try std.testing.expect(vx.screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 22), vx.screen.cursor.row);

    // Search finds rows in the terminal's scrollback too.
    h.app.openSearchPrompt(42);
    try h.app.picker_filter.appendSlice(gpa, "line 3");
    h.app.submitSearch();
    // "line 3" and "line 30".."line 39": newest first.
    try std.testing.expectEqual(@as(usize, 11), h.app.search.line_hits.items.len);
    try std.testing.expectEqual(tui.Mode.normal, h.app.mode);
    const newest = h.app.search.highlight_line.?;
    // n wraps to the oldest match, far up in the scrollback.
    h.app.nextSearchHit(1);
    try std.testing.expect(h.app.search.highlight_line.? < newest);
    try std.testing.expect(h.app.view.scroll_up > 0);
}

test "Marlin's session keys work from a shell session's normal mode" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    try h.openShell("$ ");

    // Esc, then Ctrl+N: Marlin makes a new session.
    try std.testing.expect(h.press(.{ .codepoint = vaxis.Key.escape }));
    const ctrl_n: vaxis.Key = .{ .codepoint = 'n', .mods = .{ .ctrl = true } };
    try std.testing.expect(!h.press(ctrl_n));
    try tui.handleKey(&h.app, ctrl_n);
    var created = false;
    for (try h.sent()) |msg| if (msg == .session_create) {
        created = true;
    };
    try std.testing.expect(created);
}

test "Kitty images in a shell are sent once, placed over their rows, and removed when scrolled away" {
    const gpa = std.testing.allocator;
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();

    // A 2x2 RGB image shown over 4x2 cells, between two lines of text.
    var pixels_b64: [16]u8 = undefined;
    const pixels = std.base64.standard.Encoder.encode(&pixels_b64, &[_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 });
    var screen: std.ArrayList(u8) = .empty;
    try screen.print(h.arena.allocator(), "before\r\n\x1b_Ga=T,f=24,s=2,v=2,c=4,r=2;{s}\x1b\\\r\nafter\r\n$ ", .{pixels});
    try h.openShell(screen.items);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var render_out: std.Io.Writer.Allocating = .init(gpa);
    defer render_out.deinit();
    var vx = try vaxis.init(h.threaded.io(), gpa, &env, .{});
    defer vx.deinit(gpa, &render_out.writer);
    try vx.resize(gpa, &render_out.writer, .{ .rows = 25, .cols = 80, .x_pixel = 0, .y_pixel = 0 });
    var frame = std.heap.ArenaAllocator.init(gpa);
    defer frame.deinit();
    try tui.draw(&h.app, &vx, frame.allocator());

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try shell_tab.showImages(&h.app, &out.writer, frame.allocator());
    const first = out.written();
    // Sent once, as RGB, then placed at the image's row: the tab bar is row
    // 0 and "before" row 1, so the image starts on row 2 (1-based: 3).
    try std.testing.expect(std.mem.indexOf(u8, first, "a=t,f=24,s=2,v=2,") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b[3;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, ",c=4,r=2,") != null);

    // Next frame: placed again, not resent.
    out.clearRetainingCapacity();
    try shell_tab.showImages(&h.app, &out.writer, frame.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=t,") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=p,") != null);

    // A picker over the transcript hides it: the placement is deleted.
    h.app.picker = 0;
    out.clearRetainingCapacity();
    try shell_tab.showImages(&h.app, &out.writer, frame.allocator());
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=d,d=i,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "a=p,") == null);
}

test "`:` opens Marlin's command line in a shell session; Esc returns to the shell" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    try h.openShell("$ ");

    _ = h.press(.{ .codepoint = vaxis.Key.escape });
    const colon: vaxis.Key = .{ .codepoint = ':', .text = ":" };
    try std.testing.expect(!h.press(colon));
    try tui.handleKey(&h.app, colon);
    try std.testing.expect(shell_tab.commandLineOpen(&h.app));
    try std.testing.expectEqualStrings("/", h.app.view.editor.text.items);

    // Typing edits the command, not the shell.
    const q: vaxis.Key = .{ .codepoint = 'q', .text = "q" };
    try std.testing.expect(!h.press(q));
    try tui.handleKey(&h.app, q);
    try std.testing.expectEqualStrings("/q", h.app.view.editor.text.items);
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);

    // Esc discards it; keys are the shell's again.
    try std.testing.expect(h.press(.{ .codepoint = vaxis.Key.escape }));
    try std.testing.expect(!shell_tab.commandLineOpen(&h.app));
    try std.testing.expect(h.press(q));
    try std.testing.expect((try h.sent())[0] == .shell_input);
}

test "the shell prefix parses ctrl+key specs" {
    const Prefix = shell_tab.Prefix;
    const default = Prefix.parse(" C-B ").?;
    try std.testing.expectEqual(Prefix.default, default);
    try std.testing.expectEqual(@as(u8, 0x02), default.literal());
    const bracket = Prefix.parse("ctrl+]").?;
    try std.testing.expectEqual(@as(u21, ']'), bracket.codepoint);
    try std.testing.expectEqual(@as(u8, 0x1d), bracket.literal());
    try std.testing.expect(Prefix.parse("ctrl+[") == null); // that is Escape
    try std.testing.expect(Prefix.parse("ctrl+bb") == null);
    try std.testing.expect(Prefix.parse("alt+x") == null);
}

test "after the prefix, one key is a Marlin command, from anywhere in the shell" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    const arena = h.arena.allocator();
    try h.openShell("$ ");
    const prefix: vaxis.Key = .{ .codepoint = 'b', .mods = .{ .ctrl = true } };

    // prefix c: a new session.
    try std.testing.expect(h.press(prefix));
    try std.testing.expect(h.app.shell_prefix_pending);
    try std.testing.expect(h.press(.{ .codepoint = 'c', .text = "c" }));
    var created = false;
    for (try h.sent()) |msg| if (msg == .session_create) {
        created = true;
    };
    try std.testing.expect(created);
    h.app.awaiting_new_session = false;

    // prefix prefix: the program gets a literal ^B (tmux inside the shell).
    _ = h.press(prefix);
    _ = h.press(prefix);
    try std.testing.expectEqualStrings("\x02", try decodedInput(arena, (try h.sent())[0]));

    // Inside vim, prefix [ shows the scrollback in normal mode; i returns.
    var out_buf: [64]u8 = undefined;
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":5,\"data_base64\":\"{s}\"}}}}", .{std.base64.standard.Encoder.encode(&out_buf, "\x1b[?1049h")});
    _ = try h.sent();
    try std.testing.expect(shell_tab.showingFullScreen(&h.app));
    _ = h.press(prefix);
    _ = h.press(.{ .codepoint = '[', .text = "[" });
    try std.testing.expectEqual(tui.Mode.normal, h.app.mode);
    try std.testing.expect(!shell_tab.showingFullScreen(&h.app));
    _ = h.press(.{ .codepoint = 'i', .text = "i" });
    try std.testing.expect(shell_tab.showingFullScreen(&h.app));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);
}

test "a configured prefix replaces Ctrl+B, which then goes to the program" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    const arena = h.arena.allocator();
    try h.openShell("$ ");
    h.app.shell_prefix = shell_tab.Prefix.parse("ctrl+]").?;

    _ = h.press(.{ .codepoint = 'b', .mods = .{ .ctrl = true } });
    try std.testing.expect(!h.app.shell_prefix_pending);
    try std.testing.expectEqualStrings("\x02", try decodedInput(arena, (try h.sent())[0]));
    // A legacy terminal's ctrl+] arrives as the raw GS byte.
    _ = h.press(.{ .codepoint = 0x1d });
    try std.testing.expect(h.app.shell_prefix_pending);
    _ = h.press(.{ .codepoint = '[', .text = "[" });
    try std.testing.expectEqual(tui.Mode.normal, h.app.mode);
}

test "Marlin's tab keys and Ctrl+N work in a shell; the prefix passes them on" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    const arena = h.arena.allocator();
    try h.openShell("$ ");
    const prefix: vaxis.Key = .{ .codepoint = 'b', .mods = .{ .ctrl = true } };
    const alt_b: vaxis.Key = .{ .codepoint = 'b', .mods = .{ .alt = true } };

    // Alt+arrows and Alt+b/f (Option+arrows in Ghostty) switch tabs.
    try std.testing.expect(h.press(.{ .codepoint = vaxis.Key.left, .mods = .{ .alt = true } }));
    try std.testing.expect(h.press(alt_b));
    try std.testing.expectEqual(@as(usize, 0), (try h.sent()).len);

    // After the prefix, Alt+b reaches the shell: readline's word motion.
    _ = h.press(prefix);
    _ = h.press(alt_b);
    try std.testing.expectEqualStrings("\x1bb", try decodedInput(arena, (try h.sent())[0]));

    // Ctrl+N at the prompt: a new session.
    _ = h.press(.{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try std.testing.expect((try h.sent())[0] == .session_create);
    h.app.awaiting_new_session = false;

    // In a full-screen program, Ctrl+N is the program's.
    var out_buf: [64]u8 = undefined;
    try h.daemonSays("{{\"shell_output\":{{\"shell_id\":5,\"data_base64\":\"{s}\"}}}}", .{std.base64.standard.Encoder.encode(&out_buf, "\x1b[?1049h")});
    _ = try h.sent();
    _ = h.press(.{ .codepoint = 'n', .mods = .{ .ctrl = true } });
    try std.testing.expectEqualStrings("\x0e", try decodedInput(arena, (try h.sent())[0]));
}

test "a new shell starts in place: the empty screen below its prompt is not shown" {
    var h: Harness = undefined;
    h.init(true);
    defer h.deinit();
    try h.openShell("first\r\n$ ");
    const state = h.app.view.shell.?;
    const lines = try shell_tab.transcriptLines(state, 80);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("$", std.mem.trimEnd(u8, lines[1].text, " "));
    try std.testing.expectEqual(@as(usize, 2), state.screen_rows_shown);
}
