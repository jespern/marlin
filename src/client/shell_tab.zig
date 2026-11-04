//! Shell sessions (`!!`): typing `!!` in a session turns it into a login
//! shell on the daemon's host; exiting the shell (Ctrl+D) turns it back,
//! with the shell's output kept in the session's transcript.
//!
//! The shell's scrollback and screen continue the session's transcript, so
//! Marlin's ergonomics apply to it. Keys go to the shell, except after the
//! prefix ([ui] shell_prefix, Ctrl+] by default), which takes one command:
//! 1-9 tab, n/p next/previous tab, c new session, [ or Esc normal mode
//! (scroll, copy, search; from inside vim too, showing the scrollback), :
//! Marlin's command line, the prefix again sends it to the program. At the
//! prompt Esc also enters normal mode; i/a/Enter return to the live shell.
//! Full-screen programs (vim, htop) draw between the tab bar and status line
//! and get every key but the prefix and Alt+1-9. Shells belong to the
//! daemon: they keep running when this client leaves, and reattach when it
//! returns.
const std = @import("std");
const vaxis = @import("vaxis");
const vt = @import("ghostty-vt");
const proto = @import("../core/proto.zig");
const render = @import("render.zig");
const shell_term = @import("shell_term.zig");
const ShellState = @import("shell_state.zig").ShellState;
const shell_images = @import("shell_images.zig");
const SessionView = @import("session_view.zig").SessionView;
const tui = @import("tui.zig");
const App = tui.App;

const Line = render.Line;
const SyntaxSpan = render.SyntaxSpan;

/// Scrollback rows shown in the transcript while the shell runs; the whole
/// history is recorded in the session when it ends.
pub const transcript_history_rows: usize = 3000;

/// The focused session's shell, once it is attached and restored.
pub fn live(app: *const App) ?*ShellState {
    const state = app.view.shell orelse return null;
    _ = state.live() orelse return null;
    return state;
}

/// The focused session is a shell (perhaps still opening).
pub fn active(app: *const App) bool {
    return app.view.shell != null;
}

pub fn fullScreen(app: *const App) bool {
    const state = live(app) orelse return false;
    return state.emulator.?.onAlternateScreen();
}

/// A full-screen program is on screen: it is running, and the user is not
/// in normal mode reading the scrollback behind it.
pub fn showingFullScreen(app: *const App) bool {
    return fullScreen(app) and app.mode == .insert and app.copy_cursor == null;
}

/// The shell prefix: Ctrl plus one key.
pub const Prefix = struct {
    codepoint: u21,
    /// The C0 byte legacy terminals send, which vaxis passes through as a
    /// codepoint rather than ctrl+key (Ctrl+] arrives as 0x1d).
    raw: ?u21 = null,

    pub const default: Prefix = .{ .codepoint = ']', .raw = 0x1d };

    /// "ctrl+]", "ctrl+b", "C-a", ...; null when not a usable ctrl+key.
    pub fn parse(spec: []const u8) ?Prefix {
        const trimmed = std.mem.trim(u8, spec, " \t");
        const rest = if (std.ascii.startsWithIgnoreCase(trimmed, "ctrl+"))
            trimmed[5..]
        else if (std.ascii.startsWithIgnoreCase(trimmed, "c-"))
            trimmed[2..]
        else
            return null;
        if (rest.len != 1) return null;
        const c = std.ascii.toLower(rest[0]);
        return switch (c) {
            'a'...'z', '@' => .{ .codepoint = c },
            ']' => .{ .codepoint = c, .raw = 0x1d },
            '\\' => .{ .codepoint = c, .raw = 0x1c },
            '^' => .{ .codepoint = c, .raw = 0x1e },
            '_' => .{ .codepoint = c, .raw = 0x1f },
            else => null, // ctrl+[ is Escape itself
        };
    }

    pub fn matches(self: Prefix, k: vaxis.Key) bool {
        if (k.matches(self.codepoint, .{ .ctrl = true })) return true;
        const raw = self.raw orelse return false;
        return k.codepoint == raw and !k.mods.alt;
    }

    /// The byte the program gets when the prefix is pressed twice.
    pub fn literal(self: Prefix) u8 {
        if (self.raw) |raw| return @intCast(raw);
        return if (self.codepoint == '@') 0 else @intCast(self.codepoint & 0x1f);
    }
};

const Grid = struct { cols: u16, rows: u16, cell_width: u16, cell_height: u16 };

/// The transcript area: everything but the tab bar and the status line.
fn gridSize(app: *const App) Grid {
    return .{
        .cols = @intCast(std.math.clamp(app.term_cols, 1, std.math.maxInt(u16))),
        .rows = @max(app.term_rows -| @as(u16, @intCast(app.tabBarRows())) -| 1, 1),
        .cell_width = @intCast(@min(app.cell_px_w, std.math.maxInt(u16))),
        .cell_height = @intCast(@min(app.cell_px_h, std.math.maxInt(u16))),
    };
}

fn nextRequestId(app: *App) u64 {
    const id = app.next_input_request_id;
    app.next_input_request_id += 1;
    return id;
}

/// `!!`: turn the focused session into a shell.
pub fn open(app: *App) void {
    if (!app.conn.remote_shell) {
        app.setNotice("the daemon has no shell sessions yet — rebuild it with !rb", .{});
        return;
    }
    if (app.view.shell != null) {
        app.setNotice("this session already is a shell — Ctrl+D ends it", .{});
        return;
    }
    if (app.view.state == .running or app.view.state == .awaiting_approval) {
        app.setNotice("the session is working; wait for its turn to finish", .{});
        return;
    }
    const state = ShellState.create(app.gpa) catch return;
    state.request_id = nextRequestId(app);
    const grid = gridSize(app);
    app.conn.send(.{ .shell_open = .{
        .request_id = state.request_id,
        .sid = app.view.sid,
        .cols = grid.cols,
        .rows = grid.rows,
        .cell_width = grid.cell_width,
        .cell_height = grid.cell_height,
    } }) catch {
        state.destroy();
        app.setNotice("could not reach the daemon to open a shell", .{});
        return;
    };
    state.sent_cols = grid.cols;
    state.sent_rows = grid.rows;
    app.view.shell = state;
    enterLive(app);
}

/// Keep the focused session's shell state in step with the daemon: attach
/// when it is a shell this client is not showing yet (another client made
/// it one, or this client reconnected or was restarted).
pub fn sync(app: *App) void {
    if (!app.conn.remote_shell or app.reconnecting) return;
    const summary = app.sessionSummary(app.view.sid) orelse return;
    if (app.view.shell) |state| {
        // The shell ended while this view was not attached to hear it.
        if (state.shell_id) |id| if (summary.shell_id != id and state.attached) dropShell(app, app.view.shell.?);
        return;
    }
    if (summary.shell_id == 0) return;
    const state = ShellState.create(app.gpa) catch return;
    state.request_id = nextRequestId(app);
    state.shell_id = summary.shell_id;
    app.view.shell = state;
    sendAttach(app, state);
    enterLive(app);
}

fn sendAttach(app: *App, state: *ShellState) void {
    const id = state.shell_id orelse return;
    const grid = gridSize(app);
    app.conn.send(.{ .shell_attach = .{
        .request_id = state.request_id,
        .shell_id = id,
        .cols = grid.cols,
        .rows = grid.rows,
        .cell_width = grid.cell_width,
        .cell_height = grid.cell_height,
    } }) catch return;
    state.sent_cols = grid.cols;
    state.sent_rows = grid.rows;
}

/// Back to the live shell: insert mode, pinned to the bottom.
fn enterLive(app: *App) void {
    app.mode = .insert;
    app.copy_cursor = null;
    app.view.scroll_up = 0;
    app.refresh_requested = true;
}

/// After a (re)connect: reattach every shell this client was showing.
pub fn connected(app: *App) void {
    if (!app.conn.remote_shell) return;
    var views = Views.init(app);
    while (views.next()) |view| if (view.shell) |state| {
        if (state.shell_id == null) continue;
        state.request_id = nextRequestId(app);
        sendAttach(app, state);
    };
}

pub fn connectionLost(app: *App) void {
    var views = Views.init(app);
    while (views.next()) |view| if (view.shell) |state| {
        state.attached = false;
    };
}

/// The focused view and every saved one.
const Views = struct {
    app: *App,
    focused_done: bool = false,
    saved: std.AutoHashMapUnmanaged(u64, *SessionView).ValueIterator,

    fn init(app: *App) Views {
        return .{ .app = app, .saved = app.saved_views.valueIterator() };
    }

    fn next(self: *Views) ?*SessionView {
        if (!self.focused_done) {
            self.focused_done = true;
            return &self.app.view;
        }
        const view = self.saved.next() orelse return null;
        return view.*;
    }
};

fn findShell(app: *App, shell_id: u64) ?*ShellState {
    var views = Views.init(app);
    while (views.next()) |view| if (view.shell) |state| {
        if (state.shell_id == shell_id) return state;
    };
    return null;
}

fn findView(app: *App, state: *ShellState) ?*SessionView {
    var views = Views.init(app);
    while (views.next()) |view| if (view.shell == state) return view;
    return null;
}

fn dropShell(app: *App, state: *ShellState) void {
    if (findView(app, state)) |view| view.shell = null;
    state.destroy();
    app.refresh_requested = true;
}

/// Route a key press in a shell session. Returns false to let Marlin
/// handle it (normal mode, tab switching).
pub fn key(app: *App, k: vaxis.Key) bool {
    const state = app.view.shell orelse return false;
    const tab_switch = k.mods.alt and k.codepoint >= '1' and k.codepoint <= '9';
    if (app.shell_prefix_pending) {
        app.shell_prefix_pending = false;
        prefixCommand(app, state, k);
        return true;
    }
    if (app.shell_prefix.matches(k) and !commandLineOpen(app)) {
        app.shell_prefix_pending = true;
        app.refresh_requested = true;
        return true;
    }
    // Marlin's command line (`:` in normal mode): keys edit it until Enter
    // runs it or Esc discards it, then the shell has them again.
    if (commandLineOpen(app)) {
        if (k.matches(vaxis.Key.escape, .{})) {
            app.view.editor.clear();
            enterLive(app);
            return true;
        }
        return false;
    }
    if (app.mode != .insert or app.copy_cursor != null) {
        if (isResumeKey(k) and app.copy_cursor == null) {
            enterLive(app);
            return true;
        }
        return false;
    }
    if (tab_switch) return false;
    const emulator = state.live() orelse {
        // Opening: keep what was typed for when the shell is up. While
        // reconnecting, keys are dropped: typing blind into a shell that
        // may have moved on is not safe.
        if (state.shell_id == null) if (k.text) |text| state.pending.appendSlice(app.gpa, text) catch {};
        return true;
    };
    if (!emulator.onAlternateScreen() and k.matches(vaxis.Key.escape, .{})) {
        app.mode = .normal;
        app.refresh_requested = true;
        return true;
    }
    app.view.scroll_up = 0;
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    emulator.encodeKey(&out.writer, k) catch return true;
    sendInput(app, state, out.written());
    return true;
}

/// The key after the prefix.
fn prefixCommand(app: *App, state: *ShellState, k: vaxis.Key) void {
    app.refresh_requested = true;
    if (app.shell_prefix.matches(k)) {
        sendInput(app, state, &.{app.shell_prefix.literal()});
        return;
    }
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return;
    switch (k.codepoint) {
        '1'...'9' => app.jumpToTab(k.codepoint - '0'),
        'n' => app.cycleTab(1),
        'p' => app.cycleTab(-1),
        'c' => app.newSession() catch app.setNotice("could not create session", .{}),
        '[', vaxis.Key.escape => {
            app.mode = .normal;
            app.refresh_requested = true;
        },
        ':' => {
            app.mode = .normal;
            tui.handleKey(app, k) catch {};
        },
        else => app.setNotice("no shell command for that key", .{}),
    }
}

fn isResumeKey(k: vaxis.Key) bool {
    if (k.matches(vaxis.Key.enter, .{})) return true;
    if (k.mods.ctrl or k.mods.alt or k.mods.super) return false;
    return switch (k.codepoint) {
        'i', 'a', 'A', 'I', 'o', 'O', 's', 'S' => true,
        else => false,
    };
}

/// A shell session shows Marlin's composer only while a command is typed.
pub fn commandLineOpen(app: *const App) bool {
    return app.view.shell != null and app.mode == .insert and app.view.editor.text.items.len > 0;
}

/// Route a paste in a shell session. `text` is rewritten in place.
pub fn paste(app: *App, text: []u8) bool {
    const state = app.view.shell orelse return false;
    if (app.mode != .insert or commandLineOpen(app)) return false;
    const emulator = state.live() orelse return true;
    app.view.scroll_up = 0;
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    emulator.encodePaste(&out.writer, text) catch return true;
    sendInput(app, state, out.written());
    return true;
}

/// Mouse events in a shell session go to the program when it is full-screen
/// or asked for mouse reports at the live prompt; otherwise Marlin's
/// scrolling and selection apply, as in any session.
pub fn mouse(app: *App, m: vaxis.Mouse) bool {
    const state = live(app) orelse return false;
    const emulator = state.emulator.?;
    const full_screen = showingFullScreen(app);
    const at_prompt = app.mode == .insert and app.view.scroll_up == 0 and app.copy_cursor == null;
    if (!full_screen and !(at_prompt and emulator.tracksMouse())) return false;
    const top: i32 = @intCast(app.tabBarRows());
    const row = @as(i32, m.row) - top;
    if (row < 0 or row >= emulator.terminal.rows or m.col < 0) return true;
    if (!emulator.tracksMouse()) {
        // Full-screen programs without mouse reports (less, man) scroll
        // with the arrow keys, as terminals' alternate-scroll mode does.
        const arrow: ?u21 = switch (m.button) {
            .wheel_up => vaxis.Key.up,
            .wheel_down => vaxis.Key.down,
            else => null,
        };
        if (arrow == null or m.type != .press) return true;
        var keys: std.Io.Writer.Allocating = .init(app.gpa);
        defer keys.deinit();
        for (0..3) |_| emulator.encodeKey(&keys.writer, .{ .codepoint = arrow.? }) catch return true;
        sendInput(app, state, keys.written());
        return true;
    }
    const grid = gridSize(app);
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    emulator.encodeMouse(&out.writer, m, @intCast(m.col), @intCast(row), grid.cell_width, grid.cell_height) catch return true;
    sendInput(app, state, out.written());
    return true;
}

/// Size the focused shell to the transcript area, telling the daemon when
/// it changed.
pub fn fit(app: *App, cols: u16, rows: u16) void {
    const state = live(app) orelse return;
    state.emulator.?.resize(cols, rows) catch {};
    if (cols == state.sent_cols and rows == state.sent_rows) return;
    const id = state.shell_id orelse return;
    const grid = gridSize(app);
    app.conn.send(.{ .shell_resize = .{ .shell_id = id, .cols = cols, .rows = rows, .cell_width = grid.cell_width, .cell_height = grid.cell_height } }) catch return;
    state.sent_cols = cols;
    state.sent_rows = rows;
}

/// The terminal as transcript rows: scrollback (newest
/// `transcript_history_rows`) then the screen, one row each.
pub fn transcriptLines(state: *ShellState, width: usize) ![]const Line {
    const emulator = state.emulator orelse return &.{};
    if (state.lines_generation == emulator.generation and state.lines_width == width) return state.lines;
    _ = state.lines_arena.reset(.retain_capacity);
    const arena = state.lines_arena.allocator();
    const screen = emulator.terminal.screens.get(.primary) orelse emulator.terminal.screens.active;

    const cap = transcript_history_rows + emulator.terminal.rows;
    var pins: std.ArrayList(vt.Pin) = .empty;
    var it = screen.pages.rowIterator(.left_up, .{ .screen = .{} }, null);
    while (it.next()) |pin| {
        try pins.append(arena, pin);
        if (pins.items.len >= cap) break;
    }
    std.mem.reverse(vt.Pin, pins.items);

    const lines = try arena.alloc(Line, pins.items.len);
    var wrapped = false;
    for (pins.items, lines) |pin, *line| {
        line.* = try rowLine(arena, pin, wrapped);
        wrapped = pin.rowAndCell().row.wrap;
    }
    render.resolveLineLinks(arena, lines) catch {};
    state.lines = lines;
    state.pins = pins.items;
    state.lines_generation = emulator.generation;
    state.lines_width = width;
    return lines;
}

fn rowLine(arena: std.mem.Allocator, pin: vt.Pin, continues: bool) !Line {
    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var keep: usize = 0; // bytes worth keeping: text, or styled blanks
    var buf: [4]u8 = undefined;
    const cells = pin.cells(.all);
    for (cells) |*cell| {
        if (cell.wide == .spacer_tail) continue;
        const start = text.items.len;
        if (cell.hasText() and cell.wide != .spacer_head) {
            try text.appendSlice(arena, buf[0 .. std.unicode.utf8Encode(cell.codepoint(), &buf) catch 0]);
            if (cell.hasGrapheme()) if (pin.grapheme(cell)) |extra| for (extra) |cp| {
                try text.appendSlice(arena, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch continue]);
            };
        } else try text.append(arena, ' ');
        var style: vaxis.Style = if (cell.style_id != 0) shell_term.cellStyle(pin.style(cell)) else .{};
        switch (cell.content_tag) {
            .bg_color_palette => style.bg = .{ .index = cell.content.color_palette.data },
            .bg_color_rgb => style.bg = .{ .rgb = .{ cell.content.color_rgb.r, cell.content.color_rgb.g, cell.content.color_rgb.b } },
            else => {},
        }
        const visible = cell.hasText() or !std.meta.eql(style, vaxis.Style{});
        if (visible) keep = text.items.len;
        if (std.meta.eql(style, vaxis.Style{})) continue;
        if (spans.items.len > 0) {
            const last = &spans.items[spans.items.len - 1];
            if (last.end == start and std.meta.eql(last.style, style)) {
                last.end = text.items.len;
                continue;
            }
        }
        try spans.append(arena, .{ .start = start, .end = text.items.len, .style = style });
    }
    return .{
        .text = text.items[0..keep],
        .style = .{},
        .syntax = spans.items,
        .copy = .{ .join = if (continues) .direct else .newline },
    };
}

pub fn drawFullScreen(app: *App, arena: std.mem.Allocator, win: vaxis.Window) !void {
    const state = live(app) orelse return;
    try state.emulator.?.draw(arena, win);
}

/// Show the shell's cursor on its transcript row while typing at the live
/// prompt; elsewhere (normal mode, scrolled back) it stays hidden.
pub fn placeCursor(app: *App, win: vaxis.Window, top_rows: u16, view_h: u16, total_lines: usize) void {
    const state = live(app) orelse return;
    const t = &state.emulator.?.terminal;
    if (app.mode != .insert or app.view.scroll_up != 0 or app.copy_cursor != null or !t.modes.get(.cursor_visible)) {
        win.hideCursor();
        return;
    }
    const cursor = t.screens.active.cursor;
    const abs = total_lines -| t.rows + cursor.y;
    if (abs < app.view.last_first_visible) return win.hideCursor();
    const row = abs - app.view.last_first_visible;
    if (row >= view_h or cursor.x >= win.width) return win.hideCursor();
    win.showCursor(@intCast(cursor.x), @intCast(top_rows + row));
}

pub fn opened(app: *App, msg: anytype) void {
    var views = Views.init(app);
    while (views.next()) |view| if (view.shell) |state| {
        if (state.request_id != msg.request_id) continue;
        if (state.shell_id) |id| if (id != msg.shell_id) continue;
        state.shell_id = msg.shell_id;
        state.attached = true;
        if (state.pending.items.len > 0) {
            sendInput(app, state, state.pending.items);
            state.pending.clearRetainingCapacity();
        }
        return;
    };
}

pub fn snapshot(app: *App, msg: anytype) void {
    const state = findShell(app, msg.shell_id) orelse return;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(msg.data_base64) catch return;
    const bytes = app.gpa.alloc(u8, len) catch return;
    defer app.gpa.free(bytes);
    decoder.decode(bytes, msg.data_base64) catch return;
    const emulator = shell_term.Emulator.fromSnapshot(app.gpa, app.io, bytes) catch |err| {
        app.setNotice("could not restore the shell: {t} (client and daemon builds differ?)", .{err});
        return;
    };
    if (state.emulator) |old| old.destroy();
    state.emulator = emulator;
    // The snapshot carries the shell's size; the daemon was told ours.
    emulator.resize(state.sent_cols, state.sent_rows) catch {};
    app.refresh_requested = true;
}

pub fn output(app: *App, msg: anytype) void {
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(msg.data_base64) catch return;
    defer app.conn.send(.{ .shell_ack = .{ .shell_id = msg.shell_id, .bytes = len } }) catch {};
    const state = findShell(app, msg.shell_id) orelse return;
    const emulator = state.emulator orelse return;
    const bytes = app.gpa.alloc(u8, len) catch return;
    defer app.gpa.free(bytes);
    decoder.decode(bytes, msg.data_base64) catch return;
    emulator.feed(bytes);
}

/// The shell ended: the session is ordinary again. Its transcript arrives
/// as a block of its own.
pub fn exited(app: *App, msg: anytype) void {
    const state = findShell(app, msg.shell_id) orelse return;
    const focused = app.view.shell == state;
    dropShell(app, state);
    if (focused) enterLive(app);
}

/// An err reply to our shell_open or shell_attach. Returns true when ours.
pub fn failed(app: *App, request_id: u64, message: []const u8) bool {
    if (request_id == 0) return false;
    var views = Views.init(app);
    while (views.next()) |view| if (view.shell) |state| {
        if (state.request_id != request_id or state.emulator != null) continue;
        dropShell(app, state);
        app.setNotice("{s}", .{message});
        return true;
    };
    return false;
}

fn sendInput(app: *App, state: *ShellState, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const id = state.shell_id orelse {
        state.pending.appendSlice(app.gpa, bytes) catch {};
        return;
    };
    if (!state.attached) return;
    const encoder = std.base64.standard.Encoder;
    const buf = app.gpa.alloc(u8, encoder.calcSize(bytes.len)) catch return;
    defer app.gpa.free(buf);
    app.conn.send(.{ .shell_input = .{ .shell_id = id, .data_base64 = encoder.encode(buf, bytes) } }) catch {};
}

/// After each frame: show the focused shell's Kitty images over their rows
/// (or the full-screen grid), and drop what is no longer shown or stored.
pub fn showImages(app: *App, writer: *std.Io.Writer, arena: std.mem.Allocator) !void {
    const covered = app.picker != null or app.top_view != null or app.shortcut_help;
    const wants = if (covered) &.{} else try imageWants(app, arena);
    try app.shell_images.update(app.gpa, writer, wants);
    try app.shell_images.forget(writer, imageStored, app);
}

fn imageWants(app: *App, arena: std.mem.Allocator) ![]const shell_images.Want {
    const state = live(app) orelse return &.{};
    const emulator = state.emulator.?;
    const t = &emulator.terminal;
    const full_screen = showingFullScreen(app);
    // Normal mode during a full-screen program shows the scrollback, whose
    // images live on the primary screen.
    const screen = if (full_screen) t.screens.active else t.screens.get(.primary) orelse t.screens.active;
    const top: isize = @intCast(app.tabBarRows());
    const view_h: isize = @intCast(app.view.last_view_h);
    // Transcript index of the shell's first row (it ends the transcript).
    const shell_first: isize = @intCast(app.view.last_total_lines -| state.lines.len);
    const first_visible: isize = @intCast(app.view.last_first_visible);

    var wants: std.ArrayList(shell_images.Want) = .empty;
    const storage = &screen.kitty_images;
    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const placement = entry.value_ptr.*;
        const pin = switch (placement.location) {
            .pin => |pin| pin,
            else => continue,
        };
        if (pin.garbage) continue;
        const image = storage.images.getPtr(entry.key_ptr.image_id) orelse continue;
        const data = image.data.bytes() orelse continue;
        const grid = placement.gridSize(image.*, t);
        if (grid.rows == 0 or grid.cols == 0) continue;

        const row_top: isize = if (full_screen) row: {
            const point = screen.pages.pointFromPin(.active, pin.*) orelse continue;
            break :row @intCast(point.active.y);
        } else row: {
            const index = for (state.pins, 0..) |candidate, i| {
                if (candidate.node == pin.node and candidate.y == pin.y) break i;
            } else continue;
            break :row shell_first + @as(isize, @intCast(index)) - first_visible;
        };
        const rows: isize = @intCast(grid.rows);
        const hidden_top: isize = @max(0, -row_top);
        const visible_end = @min(row_top + rows, view_h);
        const visible_start = @max(row_top, 0);
        if (visible_end <= visible_start) continue;
        const shown_rows = visible_end - visible_start;

        // Crop the source to the rows on screen.
        const source_w = if (placement.source_width > 0) placement.source_width else image.width -| placement.source_x;
        const source_h = if (placement.source_height > 0) placement.source_height else image.height -| placement.source_y;
        const crop_y: u32 = @intCast(@divTrunc(@as(i64, hidden_top) * source_h, rows));
        const crop_h: u32 = @intCast(@divTrunc(@as(i64, shown_rows) * source_h, rows));
        if (crop_h == 0) continue;

        const id_bits = entry.key_ptr.placement_id;
        try wants.append(arena, .{
            .image = image,
            .key = .{ .owner = @intFromPtr(emulator), .image_id = image.id, .data = @intFromPtr(data.ptr), .len = data.len },
            .placement = ((id_bits.id & 0x3fffffff) | (@as(u32, @backingInt(id_bits.tag)) << 30)) + 1,
            .col = @intCast(@min(pin.x, std.math.maxInt(u16))),
            .row = @intCast(top + visible_start),
            .cols = @intCast(@min(grid.cols, std.math.maxInt(u16))),
            .rows = @intCast(shown_rows),
            .x_offset = placement.x_offset,
            .y_offset = if (hidden_top == 0) placement.y_offset else 0,
            .source = .{ .x = placement.source_x, .y = placement.source_y + crop_y, .width = source_w, .height = crop_h },
        });
    }
    return wants.items;
}

/// Whether some shell still holds this image data.
fn imageStored(ctx: ?*anyopaque, image_key: shell_images.ImageKey) bool {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    var views = Views.init(app);
    while (views.next()) |view| if (view.shell) |state| {
        const emulator = state.emulator orelse continue;
        if (@intFromPtr(emulator) != image_key.owner) continue;
        for ([_]vt.ScreenSet.Key{ .primary, .alternate }) |which| {
            const screen = emulator.terminal.screens.get(which) orelse continue;
            const image = screen.kitty_images.images.getPtr(image_key.image_id) orelse continue;
            const data = image.data.bytes() orelse continue;
            if (@intFromPtr(data.ptr) == image_key.data and data.len == image_key.len) return true;
        }
    };
    return false;
}
