//! The experimental shell tab (`!!`): a login shell on the daemon's host,
//! drawn full-screen above a one-line status bar. Every key goes to the
//! shell except Ctrl+], which returns to Marlin; `!!` brings the shell back.
//! The shell lives as long as this connection to the daemon.
const std = @import("std");
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const render = @import("render.zig");
const shell_term = @import("shell_term.zig");
const App = @import("tui.zig").App;

const Palette = render.Palette;

/// Ctrl+] leaves the shell, as it does telnet.
pub const leave_key: u21 = ']';

pub const ShellTab = struct {
    emulator: *shell_term.Emulator,
    request_id: u64,
    /// Null until the daemon confirms the shell.
    shell_id: ?u64 = null,
    visible: bool = true,
    /// Input typed before the shell was confirmed.
    pending: std.ArrayList(u8) = .empty,

    pub fn destroy(self: *ShellTab, gpa: std.mem.Allocator) void {
        self.emulator.destroy();
        self.pending.deinit(gpa);
        gpa.destroy(self);
    }
};

const GridSize = struct { cols: u16, rows: u16 };

/// The shell gets the whole terminal except the status row.
fn gridSize(app: *const App) GridSize {
    return .{
        .cols = @intCast(std.math.clamp(app.term_cols, 1, std.math.maxInt(u16))),
        .rows = @max(app.term_rows, 2) - 1,
    };
}

pub fn visible(app: *const App) bool {
    const tab = app.shell orelse return false;
    return tab.visible;
}

/// `!!`: show the shell tab, starting the shell on first use.
pub fn open(app: *App) void {
    if (app.shell) |tab| {
        tab.visible = true;
        app.refresh_requested = true;
        return;
    }
    if (!app.conn.remote_shell) {
        app.setNotice("the daemon has no shell tab yet — rebuild it with !rb", .{});
        return;
    }
    const size = gridSize(app);
    const emulator = shell_term.Emulator.create(app.gpa, app.io, size.cols, size.rows) catch {
        app.setNotice("could not start the terminal emulator", .{});
        return;
    };
    const tab = app.gpa.create(ShellTab) catch {
        emulator.destroy();
        return;
    };
    tab.* = .{ .emulator = emulator, .request_id = app.next_input_request_id };
    app.next_input_request_id += 1;
    app.conn.send(.{ .shell_open = .{ .request_id = tab.request_id, .sid = app.view.sid, .cols = size.cols, .rows = size.rows } }) catch {
        tab.destroy(app.gpa);
        app.setNotice("could not reach the daemon to open a shell", .{});
        return;
    };
    app.shell = tab;
    app.refresh_requested = true;
}

/// Route a key press while the shell is showing. Returns false to let
/// Marlin handle it.
pub fn key(app: *App, k: vaxis.Key) bool {
    const tab = app.shell orelse return false;
    if (!tab.visible) return false;
    if (k.matches(leave_key, .{ .ctrl = true })) {
        tab.visible = false;
        app.refresh_requested = true;
        return true;
    }
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    tab.emulator.encodeKey(&out.writer, k) catch return true;
    sendInput(app, tab, out.written());
    return true;
}

/// Route a paste while the shell is showing. `text` is rewritten in place.
pub fn paste(app: *App, text: []u8) bool {
    const tab = app.shell orelse return false;
    if (!tab.visible) return false;
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    tab.emulator.encodePaste(&out.writer, text) catch return true;
    sendInput(app, tab, out.written());
    return true;
}

pub fn resize(app: *App) void {
    const tab = app.shell orelse return;
    const size = gridSize(app);
    tab.emulator.resize(size.cols, size.rows) catch return;
    const id = tab.shell_id orelse return;
    app.conn.send(.{ .shell_resize = .{ .shell_id = id, .cols = size.cols, .rows = size.rows } }) catch {};
}

pub fn opened(app: *App, msg: anytype) void {
    const tab = app.shell orelse return;
    if (tab.shell_id != null or tab.request_id != msg.request_id) return;
    tab.shell_id = msg.shell_id;
    // The terminal may have been resized while the request was in flight.
    resize(app);
    if (tab.pending.items.len > 0) {
        sendInput(app, tab, tab.pending.items);
        tab.pending.clearRetainingCapacity();
    }
}

pub fn output(app: *App, msg: anytype) void {
    const tab = app.shell orelse return;
    const id = tab.shell_id orelse return;
    if (id != msg.shell_id) return;
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(msg.data_base64) catch return;
    const bytes = app.gpa.alloc(u8, len) catch return;
    defer app.gpa.free(bytes);
    decoder.decode(bytes, msg.data_base64) catch return;
    tab.emulator.feed(bytes);
    if (tab.emulator.replies.items.len > 0) {
        sendInput(app, tab, tab.emulator.replies.items);
        tab.emulator.replies.clearRetainingCapacity();
    }
    app.conn.send(.{ .shell_ack = .{ .shell_id = id, .bytes = len } }) catch {};
}

pub fn exited(app: *App, msg: anytype) void {
    const tab = app.shell orelse return;
    if (tab.shell_id != msg.shell_id) return;
    close(app);
    if (msg.signal) |signal|
        app.setNotice("shell killed by signal {d}", .{signal})
    else if (msg.code) |code| if (code != 0)
        app.setNotice("shell exited with status {d}", .{code})
    else
        app.setNotice("shell exited", .{});
}

/// An err reply to our shell_open. Returns true when it was ours.
pub fn failed(app: *App, request_id: u64, message: []const u8) bool {
    const tab = app.shell orelse return false;
    if (request_id == 0 or tab.shell_id != null or tab.request_id != request_id) return false;
    close(app);
    app.setNotice("{s}", .{message});
    return true;
}

/// The daemon hangs up a connection's shells when the connection drops.
pub fn connectionLost(app: *App) void {
    if (app.shell == null) return;
    close(app);
    app.setNotice("shell closed: the connection to the daemon was lost", .{});
}

pub fn close(app: *App) void {
    const tab = app.shell orelse return;
    if (tab.shell_id) |id| app.conn.send(.{ .shell_close = .{ .shell_id = id } }) catch {};
    tab.destroy(app.gpa);
    app.shell = null;
    app.refresh_requested = true;
}

pub fn draw(app: *App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const tab = app.shell.?;
    const grid = win.child(.{ .height = win.height -| 1 });
    try tab.emulator.draw(arena, grid);

    const status = win.child(.{ .y_off = @intCast(win.height -| 1), .height = 1 });
    status.fill(.{ .style = Palette.status_bar });
    const host = app.conn.hostname();
    const state: []const u8 = if (tab.shell_id == null) "starting shell…" else "shell";
    const left = try std.fmt.allocPrint(arena, " {s}{s}{s} ", .{ state, if (host.len > 0) " · " else "", host });
    const right = " ctrl+] back to marlin ";
    _ = status.printSegment(.{ .text = left, .style = Palette.status_model }, .{ .wrap = .none });
    if (status.width > left.len + right.len)
        _ = status.printSegment(.{ .text = right, .style = Palette.status_muted }, .{ .col_offset = @intCast(status.width - right.len), .wrap = .none });
}

fn sendInput(app: *App, tab: *ShellTab, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const id = tab.shell_id orelse {
        tab.pending.appendSlice(app.gpa, bytes) catch {};
        return;
    };
    const encoder = std.base64.standard.Encoder;
    const buf = app.gpa.alloc(u8, encoder.calcSize(bytes.len)) catch return;
    defer app.gpa.free(buf);
    app.conn.send(.{ .shell_input = .{ .shell_id = id, .data_base64 = encoder.encode(buf, bytes) } }) catch {};
}
