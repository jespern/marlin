//! Experimental shell tabs (`!!`): login shells on the daemon's host, drawn
//! full-screen above a one-line bar listing them. Shells belong to the
//! daemon, so they keep running when this client detaches, quits, or loses
//! its connection; reattaching restores screen and scrollback from the
//! daemon's snapshot.
//!
//! Every key goes to the shell except Ctrl+], which opens a one-key menu:
//! Esc/]/q back to Marlin, n new shell, 1-9 or ←/→ switch, x kill, d detach,
//! Ctrl+] sends a literal Ctrl+]. Shift+PgUp/PgDn and the mouse wheel scroll
//! back unless the program asked for mouse reports.
const std = @import("std");
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const render = @import("render.zig");
const shell_term = @import("shell_term.zig");
const App = @import("tui.zig").App;

const Palette = render.Palette;

/// Ctrl+] opens the shell menu, as it escapes telnet. Terminals speaking
/// the Kitty keyboard protocol report it as ']' with ctrl; legacy ones send
/// the GS byte, which vaxis passes through as codepoint 0x1d.
fn isMenuKey(k: vaxis.Key) bool {
    return k.matches(']', .{ .ctrl = true }) or (k.codepoint == 0x1d and !k.mods.alt);
}

pub const ShellTab = struct {
    request_id: u64,
    /// Null until the daemon confirms the shell.
    shell_id: ?u64 = null,
    /// Null until the first snapshot arrives.
    emulator: ?*shell_term.Emulator = null,
    /// False while the connection is down, until reattached.
    attached: bool = true,
    /// Input typed before the shell was confirmed.
    pending: std.ArrayList(u8) = .empty,

    pub fn destroy(self: *ShellTab, gpa: std.mem.Allocator) void {
        if (self.emulator) |emulator| emulator.destroy();
        self.pending.deinit(gpa);
        gpa.destroy(self);
    }
};

/// A shell the daemon reported, attached here or not.
/// `title` is the program-set title, else the shell's directory name.
const Known = struct { shell_id: u64, title: []u8 };

pub const Tabs = struct {
    items: std.ArrayList(*ShellTab) = .empty,
    active: usize = 0,
    visible: bool = false,
    /// Ctrl+] was pressed: the next key is a menu command.
    menu: bool = false,
    known: std.ArrayList(Known) = .empty,

    pub fn deinit(self: *Tabs, gpa: std.mem.Allocator) void {
        for (self.items.items) |tab| tab.destroy(gpa);
        self.items.deinit(gpa);
        for (self.known.items) |known| gpa.free(known.title);
        self.known.deinit(gpa);
    }

    fn current(self: *Tabs) ?*ShellTab {
        if (self.items.items.len == 0) return null;
        return self.items.items[@min(self.active, self.items.items.len - 1)];
    }

    fn byShell(self: *Tabs, shell_id: u64) ?*ShellTab {
        for (self.items.items) |tab| if (tab.shell_id == shell_id) return tab;
        return null;
    }

    fn title(self: *const Tabs, shell_id: ?u64) []const u8 {
        const id = shell_id orelse return "";
        for (self.known.items) |known| if (known.shell_id == id) return known.title;
        return "";
    }
};

const Geometry = struct { cols: u16, rows: u16, cell_width: u16, cell_height: u16 };

/// The shell gets the whole terminal except the bar.
fn geometry(app: *const App) Geometry {
    return .{
        .cols = @intCast(std.math.clamp(app.term_cols, 1, std.math.maxInt(u16))),
        .rows = @max(app.term_rows, 2) - 1,
        .cell_width = @intCast(@min(app.cell_px_w, std.math.maxInt(u16))),
        .cell_height = @intCast(@min(app.cell_px_h, std.math.maxInt(u16))),
    };
}

pub fn visible(app: *const App) bool {
    return app.shells.visible and app.shells.items.items.len > 0;
}

/// After the handshake (startup or reconnect): learn which shells the
/// daemon runs, and reattach tabs that were open before a reconnect.
pub fn connected(app: *App) void {
    if (!app.conn.remote_shell) return;
    app.conn.send(.{ .shell_list = .{} }) catch return;
    for (app.shells.items.items) |tab| {
        const id = tab.shell_id orelse continue;
        tab.request_id = nextRequestId(app);
        const g = geometry(app);
        app.conn.send(.{ .shell_attach = .{
            .request_id = tab.request_id,
            .shell_id = id,
            .cols = g.cols,
            .rows = g.rows,
            .cell_width = g.cell_width,
            .cell_height = g.cell_height,
        } }) catch return;
    }
}

/// The connection dropped: tabs stay (the shells keep running on the
/// daemon) and reattach once it is back.
pub fn connectionLost(app: *App) void {
    for (app.shells.items.items) |tab| tab.attached = false;
}

/// `!!`: show the shell tabs. With none open, attach every shell the daemon
/// is already running, or start a new one.
pub fn open(app: *App) void {
    if (!app.conn.remote_shell) {
        app.setNotice("the daemon has no shell tabs yet — rebuild it with !rb", .{});
        return;
    }
    if (app.shells.items.items.len == 0) {
        if (app.shells.known.items.len == 0) return openNew(app);
        for (app.shells.known.items) |known| attachExisting(app, known.shell_id);
        app.shells.active = app.shells.items.items.len -| 1;
    }
    app.shells.visible = true;
    app.refresh_requested = true;
}

/// `!! new` or the menu's n: start another shell and switch to it.
pub fn openNew(app: *App) void {
    if (!app.conn.remote_shell) {
        app.setNotice("the daemon has no shell tabs yet — rebuild it with !rb", .{});
        return;
    }
    const tab = app.gpa.create(ShellTab) catch return;
    tab.* = .{ .request_id = nextRequestId(app) };
    app.shells.items.append(app.gpa, tab) catch {
        tab.destroy(app.gpa);
        return;
    };
    const g = geometry(app);
    app.conn.send(.{ .shell_open = .{
        .request_id = tab.request_id,
        .sid = app.view.sid,
        .cols = g.cols,
        .rows = g.rows,
        .cell_width = g.cell_width,
        .cell_height = g.cell_height,
    } }) catch {
        removeTab(app, tab);
        app.setNotice("could not reach the daemon to open a shell", .{});
        return;
    };
    app.shells.active = app.shells.items.items.len - 1;
    app.shells.visible = true;
    app.refresh_requested = true;
}

fn attachExisting(app: *App, shell_id: u64) void {
    if (app.shells.byShell(shell_id) != null) return;
    const tab = app.gpa.create(ShellTab) catch return;
    tab.* = .{ .request_id = nextRequestId(app), .shell_id = shell_id };
    app.shells.items.append(app.gpa, tab) catch {
        tab.destroy(app.gpa);
        return;
    };
    const g = geometry(app);
    app.conn.send(.{ .shell_attach = .{
        .request_id = tab.request_id,
        .shell_id = shell_id,
        .cols = g.cols,
        .rows = g.rows,
        .cell_width = g.cell_width,
        .cell_height = g.cell_height,
    } }) catch removeTab(app, tab);
}

fn nextRequestId(app: *App) u64 {
    const id = app.next_input_request_id;
    app.next_input_request_id += 1;
    return id;
}

/// Route a key press while the shells are showing. Returns false to let
/// Marlin handle it.
pub fn key(app: *App, k: vaxis.Key) bool {
    if (!visible(app)) return false;
    if (app.shells.menu) {
        app.shells.menu = false;
        app.refresh_requested = true;
        menuCommand(app, k);
        return true;
    }
    if (isMenuKey(k)) {
        app.shells.menu = true;
        app.refresh_requested = true;
        return true;
    }
    const tab = app.shells.current() orelse return true;
    if (tab.emulator) |emulator| {
        const page: isize = @max(emulator.terminal.rows / 2, 1);
        if (k.matches(vaxis.Key.page_up, .{ .shift = true })) {
            emulator.scroll(-page);
            return true;
        }
        if (k.matches(vaxis.Key.page_down, .{ .shift = true })) {
            emulator.scroll(page);
            return true;
        }
        // Typing returns to the live screen, as in any terminal.
        emulator.scrollToBottom();
    }
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    if (tab.emulator) |emulator|
        emulator.encodeKey(&out.writer, k) catch return true
    else if (k.text) |text|
        out.writer.writeAll(text) catch return true;
    sendInput(app, tab, out.written());
    return true;
}

fn menuCommand(app: *App, k: vaxis.Key) void {
    const tabs = &app.shells;
    if (isMenuKey(k)) {
        if (tabs.current()) |tab| sendInput(app, tab, "\x1d");
        return;
    }
    if (k.matches(vaxis.Key.escape, .{}) or k.matches(']', .{}) or k.matches('q', .{})) {
        tabs.visible = false;
        return;
    }
    if (k.matches('n', .{}) or k.matches('c', .{})) return openNew(app);
    if (k.matches(vaxis.Key.left, .{}) or k.matches('h', .{}) or k.matches('p', .{})) {
        tabs.active = if (tabs.active == 0) tabs.items.items.len - 1 else tabs.active - 1;
        return resizeActive(app);
    }
    if (k.matches(vaxis.Key.right, .{}) or k.matches('l', .{})) {
        tabs.active = (tabs.active + 1) % tabs.items.items.len;
        return resizeActive(app);
    }
    if (k.codepoint >= '1' and k.codepoint <= '9' and k.mods.ctrl == false and k.mods.alt == false) {
        const index = k.codepoint - '1';
        if (index < tabs.items.items.len) {
            tabs.active = index;
            resizeActive(app);
        }
        return;
    }
    const tab = tabs.current() orelse return;
    if (k.matches('x', .{})) {
        if (tab.shell_id) |id| app.conn.send(.{ .shell_close = .{ .shell_id = id } }) catch {};
        // shell_exited removes the tab; a never-confirmed one goes now.
        if (tab.shell_id == null) removeTab(app, tab);
        return;
    }
    if (k.matches('d', .{})) {
        if (tab.shell_id) |id| app.conn.send(.{ .shell_detach = .{ .shell_id = id } }) catch {};
        removeTab(app, tab);
        app.setNotice("shell detached — it keeps running; !! reattaches", .{});
        return;
    }
}

/// Route a paste while the shells are showing. `text` is rewritten in place.
pub fn paste(app: *App, text: []u8) bool {
    if (!visible(app)) return false;
    const tab = app.shells.current() orelse return true;
    const emulator = tab.emulator orelse return true;
    emulator.scrollToBottom();
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    emulator.encodePaste(&out.writer, text) catch return true;
    sendInput(app, tab, out.written());
    return true;
}

/// Route a mouse event while the shells are showing: to the program when
/// it tracks the mouse, otherwise the wheel scrolls back.
pub fn mouse(app: *App, m: vaxis.Mouse) bool {
    if (!visible(app)) return false;
    const tab = app.shells.current() orelse return true;
    const emulator = tab.emulator orelse return true;
    if (m.row < 0 or m.col < 0 or m.row >= emulator.terminal.rows) return true;
    if (emulator.tracksMouse() and !emulator.scrolledBack()) {
        const g = geometry(app);
        var out: std.Io.Writer.Allocating = .init(app.gpa);
        defer out.deinit();
        emulator.encodeMouse(&out.writer, m, @intCast(m.col), @intCast(m.row), g.cell_width, g.cell_height) catch return true;
        sendInput(app, tab, out.written());
        return true;
    }
    switch (m.button) {
        .wheel_up => emulator.scroll(-3),
        .wheel_down => emulator.scroll(3),
        else => {},
    }
    return true;
}

/// The terminal changed size: every shell tab follows it.
pub fn resize(app: *App) void {
    const g = geometry(app);
    for (app.shells.items.items) |tab| {
        if (tab.emulator) |emulator| emulator.resize(g.cols, g.rows) catch {};
        const id = tab.shell_id orelse continue;
        if (!tab.attached) continue;
        app.conn.send(.{ .shell_resize = .{
            .shell_id = id,
            .cols = g.cols,
            .rows = g.rows,
            .cell_width = g.cell_width,
            .cell_height = g.cell_height,
        } }) catch {};
    }
}

/// A shell sizes to its latest viewer; switching to a tab reclaims it in
/// case another client resized it meanwhile.
fn resizeActive(app: *App) void {
    const tab = app.shells.current() orelse return;
    const id = tab.shell_id orelse return;
    const g = geometry(app);
    if (tab.emulator) |emulator| emulator.resize(g.cols, g.rows) catch {};
    app.conn.send(.{ .shell_resize = .{ .shell_id = id, .cols = g.cols, .rows = g.rows, .cell_width = g.cell_width, .cell_height = g.cell_height } }) catch {};
}

pub fn opened(app: *App, msg: anytype) void {
    for (app.shells.items.items) |tab| {
        if (tab.request_id != msg.request_id) continue;
        if (tab.shell_id) |id| if (id != msg.shell_id) continue;
        tab.shell_id = msg.shell_id;
        tab.attached = true;
        if (tab.pending.items.len > 0) {
            sendInput(app, tab, tab.pending.items);
            tab.pending.clearRetainingCapacity();
        }
        return;
    }
}

pub fn snapshot(app: *App, msg: anytype) void {
    const tab = app.shells.byShell(msg.shell_id) orelse return;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(msg.data_base64) catch return;
    const bytes = app.gpa.alloc(u8, len) catch return;
    defer app.gpa.free(bytes);
    decoder.decode(bytes, msg.data_base64) catch return;
    const emulator = shell_term.Emulator.fromSnapshot(app.gpa, app.io, bytes) catch |err| {
        app.setNotice("could not restore shell {d}: {t} (client and daemon builds differ?)", .{ msg.shell_id, err });
        return;
    };
    if (tab.emulator) |old| old.destroy();
    tab.emulator = emulator;
    // The snapshot carries the shell's size; follow this terminal's.
    const g = geometry(app);
    emulator.resize(g.cols, g.rows) catch {};
    app.refresh_requested = true;
}

pub fn output(app: *App, msg: anytype) void {
    const tab = app.shells.byShell(msg.shell_id) orelse return;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(msg.data_base64) catch return;
    defer app.conn.send(.{ .shell_ack = .{ .shell_id = msg.shell_id, .bytes = len } }) catch {};
    const emulator = tab.emulator orelse return;
    const bytes = app.gpa.alloc(u8, len) catch return;
    defer app.gpa.free(bytes);
    decoder.decode(bytes, msg.data_base64) catch return;
    emulator.feed(bytes);
}

pub fn exited(app: *App, msg: anytype) void {
    const tab = app.shells.byShell(msg.shell_id) orelse return;
    removeTab(app, tab);
    if (msg.signal) |signal|
        app.setNotice("shell {d} ended (signal {d})", .{ msg.shell_id, signal })
    else if (msg.code) |code| if (code != 0)
        app.setNotice("shell {d} exited with status {d}", .{ msg.shell_id, code })
    else
        app.setNotice("shell {d} exited", .{msg.shell_id});
}

pub fn listed(app: *App, msg: anytype) void {
    const known = &app.shells.known;
    for (known.items) |entry| app.gpa.free(entry.title);
    known.clearRetainingCapacity();
    for (msg.shells) |info| {
        const name = if (info.title.len > 0) info.title else std.fs.path.basename(info.cwd);
        const title = app.gpa.dupe(u8, name) catch continue;
        known.append(app.gpa, .{ .shell_id = info.shell_id, .title = title }) catch app.gpa.free(title);
    }
    app.refresh_requested = true;
}

/// An err reply to our shell_open or shell_attach. Returns true when ours.
pub fn failed(app: *App, request_id: u64, message: []const u8) bool {
    if (request_id == 0) return false;
    for (app.shells.items.items) |tab| {
        if (tab.request_id != request_id or (tab.attached and tab.emulator != null)) continue;
        removeTab(app, tab);
        app.setNotice("{s}", .{message});
        return true;
    }
    return false;
}

fn removeTab(app: *App, tab: *ShellTab) void {
    const tabs = &app.shells;
    for (tabs.items.items, 0..) |candidate, i| if (candidate == tab) {
        _ = tabs.items.orderedRemove(i);
        if (tabs.active >= i and tabs.active > 0) tabs.active -= 1;
        break;
    };
    tab.destroy(app.gpa);
    if (tabs.items.items.len == 0) {
        tabs.visible = false;
        tabs.menu = false;
    }
    app.refresh_requested = true;
}

pub fn draw(app: *App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const tabs = &app.shells;
    const tab = tabs.current().?;
    const grid = win.child(.{ .height = win.height -| 1 });
    if (tab.emulator) |emulator| try emulator.draw(arena, grid) else grid.hideCursor();

    const bar = win.child(.{ .y_off = @intCast(win.height -| 1), .height = 1 });
    bar.fill(.{ .style = Palette.status_bar });
    var col: u16 = 0;
    for (tabs.items.items, 0..) |item, i| {
        const name = tabs.title(item.shell_id);
        const label = try std.fmt.allocPrint(arena, " {d} {s} ", .{ i + 1, if (item.shell_id == null) "starting…" else if (name.len > 0) name else "shell" });
        const style: vaxis.Style = if (i == tabs.active) Palette.status_running else Palette.status_bar;
        const shown = label[0..@min(label.len, bar.width -| col)];
        _ = bar.printSegment(.{ .text = shown, .style = style }, .{ .col_offset = col, .wrap = .none });
        col +|= @intCast(shown.len);
    }
    const scrolled = if (tab.emulator) |emulator| emulator.scrolledBack() else false;
    const hint: []const u8 = if (tabs.menu)
        " esc back · n new · 1-9 ←→ switch · x kill · d detach · ^] send ^] "
    else if (!tab.attached)
        " reconnecting… "
    else if (scrolled)
        " scrollback · type to return · ctrl+] menu "
    else
        " ctrl+] menu ";
    const host = app.conn.hostname();
    const right = try std.fmt.allocPrint(arena, "{s}{s}", .{ hint, if (host.len > 0 and !tabs.menu) host else "" });
    if (bar.width > col + right.len)
        _ = bar.printSegment(.{ .text = right, .style = if (tabs.menu) Palette.status_approval else Palette.status_muted }, .{ .col_offset = @intCast(bar.width - right.len), .wrap = .none });
}

fn sendInput(app: *App, tab: *ShellTab, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const id = tab.shell_id orelse {
        tab.pending.appendSlice(app.gpa, bytes) catch {};
        return;
    };
    if (!tab.attached) return;
    const encoder = std.base64.standard.Encoder;
    const buf = app.gpa.alloc(u8, encoder.calcSize(bytes.len)) catch return;
    defer app.gpa.free(buf);
    app.conn.send(.{ .shell_input = .{ .shell_id = id, .data_base64 = encoder.encode(buf, bytes) } }) catch {};
}
