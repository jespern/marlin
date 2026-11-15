//! The phone's live shell (`/shell`): one WebSocket per view, for paired
//! devices only.
//!
//! The bridge attaches to the daemon as a viewer that follows the shell's
//! size (shell_attach `follow_size`), keeps its own libghostty-vt copy of the
//! terminal, and sends the phone frames: the rows as SGR-styled text, as the
//! daemon records a finished shell, plus the cursor. The phone sends what is
//! typed; typing takes the shell to the phone's size, and typing in the
//! terminal client takes it back.
//!
//! Two threads per view, each blocked on one socket: this one reads the
//! phone, a pump reads the daemon. Whichever side ends first shuts the other
//! socket down so its reader wakes.
const std = @import("std");
const Io = std.Io;
const vt = @import("ghostty-vt");
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");
const shell_term = @import("shell_term.zig");

/// Scrollback rows above the screen in each frame of a shell at its prompt.
pub const history_rows: usize = 200;
/// Largest message the phone may send (one paste); the bridge's read buffer
/// bounds it too.
pub const max_input_bytes: usize = 8 * 1024;

pub const Params = struct {
    /// Attach to this running shell...
    shell_id: ?u64 = null,
    /// ...or make session `sid` a shell (`!!`), running `command` if any.
    sid: ?u64 = null,
    command: []const u8 = "",
    cols: u16 = 80,
    rows: u16 = 24,
};

/// `/shell?shell_id=N&cols=C&rows=R` or `/shell?sid=N&command=…&cols=C&rows=R`.
pub fn parseQuery(arena: std.mem.Allocator, target: []const u8) !Params {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse return error.BadQuery;
    var params: Params = .{};
    var it = std.mem.splitScalar(u8, target[q + 1 ..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = pair[0..eq];
        const value = try arena.dupe(u8, pair[eq + 1 ..]);
        for (value) |*c| if (c.* == '+') {
            c.* = ' ';
        };
        const decoded = std.Uri.percentDecodeInPlace(value);
        if (std.mem.eql(u8, name, "shell_id")) {
            params.shell_id = std.fmt.parseInt(u64, decoded, 10) catch return error.BadQuery;
        } else if (std.mem.eql(u8, name, "sid")) {
            params.sid = std.fmt.parseInt(u64, decoded, 10) catch return error.BadQuery;
        } else if (std.mem.eql(u8, name, "command")) {
            params.command = decoded;
        } else if (std.mem.eql(u8, name, "cols")) {
            params.cols = std.math.clamp(std.fmt.parseInt(u16, decoded, 10) catch return error.BadQuery, 10, 500);
        } else if (std.mem.eql(u8, name, "rows")) {
            params.rows = std.math.clamp(std.fmt.parseInt(u16, decoded, 10) catch return error.BadQuery, 4, 300);
        }
    }
    if ((params.shell_id == null) == (params.sid == null)) return error.BadQuery;
    return params;
}

/// One frame as the JSON the phone reads: rows of SGR-styled text (newest
/// scrollback first when at a prompt, then the screen), and the cursor on
/// the screen. `history` is how many rows precede the screen.
pub fn frame(gpa: std.mem.Allocator, t: *vt.Terminal) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const screen = t.screens.active;
    // A full-screen program owns the screen; scrollback is not its.
    const alternate = t.screens.active_key == .alternate;
    const top = screen.pages.pin(.{ .active = .{} }) orelse return error.NoScreen;
    var start = top;
    var history: usize = 0;
    if (!alternate) while (history < history_rows) : (history += 1) {
        start = start.up(1) orelse break;
    };
    const end = screen.pages.pin(.{ .active = .{ .x = t.cols - 1, .y = t.rows - 1 } }) orelse return error.NoScreen;
    var formatter: vt.formatter.ScreenFormatter = .init(screen, .{ .emit = .vt });
    formatter.content = .{ .selection = vt.Selection.init(start, end, false) };
    var styled: Io.Writer.Allocating = .init(arena);
    try formatter.format(&styled.writer);

    var lines: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.splitSequence(u8, styled.written(), "\r\n");
    while (rows.next()) |row| try lines.append(arena, row);
    // Blank rows at the end are left out; the phone draws them empty.
    const total = history + t.rows;
    if (lines.items.len > total) lines.shrinkRetainingCapacity(total);

    const cursor = screen.cursor;
    return std.json.Stringify.valueAlloc(gpa, .{
        .frame = .{
            .cols = t.cols,
            .rows = t.rows,
            .alternate = alternate,
            .history = history,
            .lines = lines.items,
            .cursor = .{ .x = cursor.x, .y = cursor.y, .visible = t.modes.get(.cursor_visible) },
            // Arrow keys as ESC O A rather than ESC [ A (vim, less).
            .app_cursor = t.modes.get(.cursor_keys),
            .title = t.getTitle() orelse "",
        },
    }, .{});
}

/// What the phone sends: `{"input":"…"}` (keystrokes, a paste, or a line
/// with its Enter) or `{"resize":{"cols":C,"rows":R}}` (it turned).
pub const PhoneMsg = struct {
    input: ?[]const u8 = null,
    resize: ?struct { cols: u16, rows: u16 } = null,
};

const View = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn: *attach.Conn,
    /// The phone's side: written by both threads (frames, pongs).
    ws: *std.http.Server.WebSocket,
    ws_mutex: Io.Mutex = .init,
    /// The daemon's side: written by both threads (input, acks).
    conn_mutex: Io.Mutex = .init,
    phone: Io.net.Stream,
    shell_id: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn sendDaemon(self: *View, msg: proto.ClientMsg) void {
        self.conn_mutex.lockUncancelable(self.io);
        defer self.conn_mutex.unlock(self.io);
        self.conn.send(msg) catch {};
    }

    fn sendPhone(self: *View, data: []const u8, op: std.http.Server.WebSocket.Opcode) void {
        self.ws_mutex.lockUncancelable(self.io);
        defer self.ws_mutex.unlock(self.io);
        self.ws.writeMessage(data, op) catch {};
    }

    fn sendPhoneJson(self: *View, value: anytype) void {
        const text = std.json.Stringify.valueAlloc(self.gpa, value, .{}) catch return;
        defer self.gpa.free(text);
        self.sendPhone(text, .text);
    }

    /// Daemon → phone, on its own thread, until the shell ends or either
    /// side goes away.
    fn pump(self: *View) void {
        defer {
            self.done.store(true, .release);
            // Wake the phone reader: the view is over.
            self.phone.shutdown(self.io, .both) catch {};
        }
        var emulator: ?*shell_term.Emulator = null;
        defer if (emulator) |e| e.destroy();
        var dirty = false;
        while (true) {
            const line = self.conn.readLine() catch return;
            defer self.gpa.free(line);
            var arena_state = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const msg = proto.decode(proto.DaemonMsg, arena, line) catch continue;
            switch (msg) {
                .shell_opened => |o| if (o.request_id == 1) {
                    self.shell_id.store(o.shell_id, .release);
                    self.sendPhoneJson(.{ .opened = .{ .shell_id = o.shell_id } });
                },
                .shell_snapshot => |s| if (s.shell_id == self.shell_id.load(.acquire)) {
                    const bytes = decode(arena, s.data_base64) orelse continue;
                    const restored = shell_term.Emulator.fromSnapshot(self.gpa, self.io, bytes) catch continue;
                    if (emulator) |e| e.destroy();
                    emulator = restored;
                    dirty = true;
                },
                .shell_output => |o| if (o.shell_id == self.shell_id.load(.acquire)) {
                    const bytes = decode(arena, o.data_base64) orelse continue;
                    if (emulator) |e| e.feed(bytes);
                    self.sendDaemon(.{ .shell_ack = .{ .shell_id = o.shell_id, .bytes = bytes.len } });
                    dirty = true;
                },
                .shell_resized => |r| if (r.shell_id == self.shell_id.load(.acquire)) {
                    if (emulator) |e| e.resize(r.cols, r.rows) catch {};
                    dirty = true;
                },
                .shell_exited => |e| if (e.shell_id == self.shell_id.load(.acquire)) {
                    self.sendPhoneJson(.{ .exited = .{ .code = e.code, .signal = e.signal } });
                    return;
                },
                .err => |e| if (e.request_id == 1) {
                    self.sendPhoneJson(.{ .err = .{ .code = e.code, .msg = e.msg } });
                    return;
                },
                else => {},
            }
            // One frame per burst: draw once the daemon has nothing more
            // waiting, not once per output chunk.
            if (dirty and std.mem.indexOfScalar(u8, self.conn.reader.buffered(), '\n') == null) {
                const e = emulator orelse continue;
                const json = frame(self.gpa, &e.terminal) catch continue;
                defer self.gpa.free(json);
                self.sendPhone(json, .text);
                dirty = false;
            }
        }
    }
};

fn decode(arena: std.mem.Allocator, data: []const u8) ?[]u8 {
    const decoder = std.base64.standard.Decoder;
    const bytes = arena.alloc(u8, decoder.calcSizeForSlice(data) catch return null) catch return null;
    decoder.decode(bytes, data) catch return null;
    return bytes;
}

/// Serve one upgraded `/shell` request until the shell ends or the phone
/// leaves. The caller has checked the device is paired.
pub fn serve(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    self_exe: []const u8,
    phone: Io.net.Stream,
    ws: *std.http.Server.WebSocket,
    params: Params,
) !void {
    const conn = try attach.connect(gpa, io, environ, self_exe);
    defer conn.deinit();
    var view: View = .{ .gpa = gpa, .io = io, .conn = conn, .ws = ws, .phone = phone };
    if (!conn.remote_shell) {
        view.sendPhoneJson(.{ .err = .{ .code = "no_shells", .msg = "the daemon has no shell sessions; update it" } });
        return;
    }
    if (params.shell_id) |id| {
        view.shell_id.store(id, .release);
        view.sendDaemon(.{ .shell_attach = .{ .request_id = 1, .shell_id = id, .cols = params.cols, .rows = params.rows, .follow_size = true } });
    } else {
        view.sendDaemon(.{ .shell_open = .{
            .request_id = 1,
            .sid = params.sid.?,
            .cols = params.cols,
            .rows = params.rows,
            .command = if (params.command.len > 0) params.command else null,
            .follow_size = true,
        } });
    }
    const pump = try std.Thread.spawn(.{}, View.pump, .{&view});
    defer pump.join();
    defer {
        // The phone left (or the shell ended): stop viewing, and wake the
        // pump if it is still reading the daemon.
        const id = view.shell_id.load(.acquire);
        if (id != 0 and !view.done.load(.acquire)) view.sendDaemon(.{ .shell_detach = .{ .shell_id = id } });
        conn.shutdown();
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    while (true) {
        const msg = ws.readSmallMessage() catch return;
        switch (msg.opcode) {
            .ping => {
                view.sendPhone(msg.data, .pong);
                continue;
            },
            .text => {},
            else => continue,
        }
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        const parsed = std.json.parseFromSliceLeaky(PhoneMsg, arena, msg.data, .{ .ignore_unknown_fields = true }) catch continue;
        const id = view.shell_id.load(.acquire);
        if (id == 0) continue;
        if (parsed.input) |input| {
            const encoder = std.base64.standard.Encoder;
            const encoded = try arena.alloc(u8, encoder.calcSize(input.len));
            view.sendDaemon(.{ .shell_input = .{ .shell_id = id, .data_base64 = encoder.encode(encoded, input) } });
        }
        if (parsed.resize) |r| view.sendDaemon(.{ .shell_resize = .{ .shell_id = id, .cols = r.cols, .rows = r.rows } });
    }
}
