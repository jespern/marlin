//! Daemon side of a shell tab: the PTY plus a libghostty-vt mirror of its
//! terminal. The mirror outlives any one viewer, so clients can detach,
//! reconnect, and reattach to a running shell, and several clients can watch
//! one. It is also the shell's only terminal: it answers the program's
//! queries (cursor position, device attributes, sizes) however many viewers
//! there are. A snapshot of the mirror brings a newly attached viewer, or
//! one that fell behind, up to date.
//!
//! Dispatcher thread only, apart from the PTY's own reader thread.
const std = @import("std");
const Io = std.Io;
const vt = @import("ghostty-vt");
const shell_pty = @import("shell_pty.zig");
const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");

/// Output a viewer may have unacknowledged before it stops receiving live
/// bytes; once it catches up it is resynced with a snapshot.
pub const viewer_window: usize = 4 * 1024 * 1024;
/// Scrollback the mirror keeps, and therefore what reattaching restores.
pub const scrollback_bytes: usize = 16 * 1024 * 1024;
/// Largest unfinished escape sequence carried across a snapshot.
const max_continuation_bytes: usize = 64 * 1024;

pub const Viewer = struct {
    client_id: u64,
    unacked: usize = 0,
    /// Dropped live bytes while behind; owed a snapshot.
    stale: bool = false,
};

pub const Geometry = struct {
    cols: u16,
    rows: u16,
    /// Cell size in pixels; zero when the viewer's terminal does not say.
    cell_width: u16 = 0,
    cell_height: u16 = 0,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    id: u64,
    /// The session this shell turned into a shell.
    sid: u64,
    pty: ?*shell_pty.Shell = null,
    terminal: vt.Terminal,
    stream: vt.TerminalStream,
    geometry: Geometry,
    viewers: std.ArrayList(Viewer) = .empty,
    cwd: []u8,
    created_at_ms: i64,
    /// Title last announced in a shell list, to notice OSC title changes.
    announced_title: std.ArrayList(u8) = .empty,
    /// What programs signalled during the last feed, for the daemon to send
    /// on (owned strings; see takeSignals).
    signals: std.ArrayList(proto.ShellSignal) = .empty,
    /// Commands the shell reported running (OSC 133), oldest first, the
    /// newest `max_commands` kept; owned text.
    commands: std.ArrayList(block.ShellCommand) = .empty,

    /// Heap-allocated: the stream's handler points at `terminal`. The PTY is
    /// spawned by `start` once the host is at its final address.
    pub fn create(gpa: std.mem.Allocator, io: Io, id: u64, sid: u64, cwd: []const u8, created_at_ms: i64, geometry: Geometry) !*Host {
        const self = try gpa.create(Host);
        errdefer gpa.destroy(self);
        const owned_cwd = try gpa.dupe(u8, cwd);
        errdefer gpa.free(owned_cwd);
        self.* = .{
            .gpa = gpa,
            .id = id,
            .sid = sid,
            .terminal = try .init(io, gpa, .{
                .cols = @max(geometry.cols, 1),
                .rows = @max(geometry.rows, 1),
                .max_scrollback_bytes = scrollback_bytes,
            }),
            .stream = undefined,
            .geometry = geometry,
            .cwd = owned_cwd,
            .created_at_ms = created_at_ms,
        };
        var handler = self.terminal.vtHandler();
        handler.effects.write_pty = writePty;
        handler.effects.device_attributes = deviceAttributes;
        handler.effects.size = sizeReport;
        handler.effects.bell = onBell;
        handler.effects.desktop_notification = onNotification;
        handler.effects.progress_report = onProgress;
        handler.effects.semantic_prompt = onSemanticPrompt;
        self.stream = .init(.{ .allocator = gpa, .handler = handler, .continuation_max_bytes = max_continuation_bytes });
        self.applyCellSize();
        return self;
    }

    pub fn start(self: *Host, io: Io, opts: shell_pty.Options, sink: shell_pty.Sink) !void {
        self.pty = try shell_pty.Shell.spawn(self.gpa, io, self.id, opts, sink);
    }

    pub fn destroy(self: *Host) void {
        const gpa = self.gpa;
        if (self.pty) |pty| pty.destroy();
        self.stream.deinit();
        self.terminal.deinit(gpa);
        self.viewers.deinit(gpa);
        self.announced_title.deinit(gpa);
        self.freeSignals();
        self.signals.deinit(gpa);
        for (self.commands.items) |command| gpa.free(command.command);
        self.commands.deinit(gpa);
        gpa.free(self.cwd);
        gpa.destroy(self);
    }

    /// Mirror PTY output; replies to queries go straight back to the PTY.
    pub fn feed(self: *Host, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    pub fn write(self: *Host, bytes: []const u8) !void {
        const pty = self.pty orelse return error.ShellGone;
        try pty.write(bytes);
    }

    /// The latest viewer to size the shell wins, as in tmux.
    /// A viewer's terminal colors as this shell's defaults (the latest
    /// viewer wins, as for size), so OSC 4/10/11 queries are answered with
    /// the colors on screen. A program's own color settings still win.
    pub fn setTheme(self: *Host, theme: proto.ShellTheme) void {
        const colors = &self.terminal.colors;
        if (theme.foreground) |rgb| colors.foreground.default = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        if (theme.background) |rgb| colors.background.default = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        var palette = colors.palette.original.*;
        for (theme.palette, 0..) |maybe, i| if (maybe) |rgb| {
            palette[i] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2] };
        };
        colors.palette.changeDefault(self.gpa, palette) catch {};
    }

    pub fn resize(self: *Host, geometry: Geometry) void {
        const cols = @max(geometry.cols, 1);
        const rows = @max(geometry.rows, 1);
        self.geometry = .{ .cols = cols, .rows = rows, .cell_width = geometry.cell_width, .cell_height = geometry.cell_height };
        self.terminal.resize(self.gpa, .{ .cols = cols, .rows = rows }) catch {};
        self.applyCellSize();
        if (self.pty) |pty| pty.resize(.{
            .cols = cols,
            .rows = rows,
            .width_px = @as(u32, cols) * geometry.cell_width,
            .height_px = @as(u32, rows) * geometry.cell_height,
        });
    }

    fn applyCellSize(self: *Host) void {
        if (self.geometry.cell_width == 0 or self.geometry.cell_height == 0) return;
        self.terminal.resize(self.gpa, .{
            .cols = self.terminal.cols,
            .rows = self.terminal.rows,
            .cell_size_px = .{ .width = self.geometry.cell_width, .height = self.geometry.cell_height },
        }) catch {};
    }

    /// The shell's scrollback and screen as plain text, soft wraps joined
    /// and trailing blank lines dropped, keeping the newest `max_bytes`.
    pub fn transcript(self: *Host, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
        const screen = self.terminal.screens.get(.primary) orelse self.terminal.screens.active;
        const full = try screen.dumpStringAllocUnwrapped(gpa, .{ .screen = .{} });
        defer gpa.free(full);
        const trimmed = std.mem.trimEnd(u8, full, " \n");
        var cut = trimmed.len -| max_bytes;
        // Start on a line boundary when cutting.
        if (cut > 0) if (std.mem.indexOfScalarPos(u8, trimmed, cut, '\n')) |nl| {
            cut = nl + 1;
        };
        return gpa.dupe(u8, trimmed[cut..]);
    }

    /// The transcript with colors and attributes as VT (SGR) text, soft wraps
    /// joined, newest `max_bytes` kept (cut at a line boundary).
    pub fn styledTranscript(self: *Host, gpa: std.mem.Allocator, max_bytes: usize) ![]u8 {
        const screen = self.terminal.screens.get(.primary) orelse self.terminal.screens.active;
        // Inline SGR (and OSC 8) per cell run; no trailing cursor/mode state.
        const formatter: vt.formatter.ScreenFormatter = .init(screen, .{ .emit = .vt, .unwrap = true });
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try formatter.format(&out.writer);
        const full = std.mem.trimEnd(u8, out.written(), " \r\n");
        var cut = full.len -| max_bytes;
        if (cut > 0) if (std.mem.indexOfScalarPos(u8, full, cut, '\n')) |nl| {
            cut = nl + 1;
        };
        return gpa.dupe(u8, full[cut..]);
    }

    pub fn title(self: *const Host) []const u8 {
        return self.terminal.getTitle() orelse "";
    }

    /// True once per change of the program-set title.
    pub fn titleChanged(self: *Host) bool {
        const current = self.title();
        if (std.mem.eql(u8, current, self.announced_title.items)) return false;
        self.announced_title.clearRetainingCapacity();
        self.announced_title.appendSlice(self.gpa, current) catch {};
        return true;
    }

    pub fn viewer(self: *Host, client_id: u64) ?*Viewer {
        for (self.viewers.items) |*v| if (v.client_id == client_id) return v;
        return null;
    }

    pub fn attach(self: *Host, client_id: u64) !void {
        if (self.viewer(client_id)) |v| {
            v.* = .{ .client_id = client_id };
            return;
        }
        try self.viewers.append(self.gpa, .{ .client_id = client_id });
    }

    pub fn detach(self: *Host, client_id: u64) void {
        for (self.viewers.items, 0..) |v, i| if (v.client_id == client_id) {
            _ = self.viewers.swapRemove(i);
            return;
        };
    }

    /// The whole terminal (screen, modes, scrollback, images, and any
    /// half-parsed sequence), for a viewer to restore before live bytes.
    pub fn snapshot(self: *Host, gpa: std.mem.Allocator) ![]u8 {
        var continuation: std.Io.Writer.Allocating = .init(gpa);
        defer continuation.deinit();
        const resume_state: vt.snapshot.Continuation = if (self.stream.ground()) .ground else blk: {
            self.stream.writeContinuation(&continuation.writer) catch break :blk .ground;
            break :blk .{ .bytes = continuation.written() };
        };
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        try vt.snapshot.encode(gpa, &out.writer, &self.terminal, .{ .continuation = resume_state });
        return out.toOwnedSlice();
    }

    fn fromHandler(handler: *vt.TerminalStream.Handler) *Host {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", handler);
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// The signals from the last feed; valid until the next takeSignals.
    pub fn takeSignals(self: *Host) []const proto.ShellSignal {
        return self.signals.items;
    }

    /// Drop signals already sent on.
    pub fn freeSignals(self: *Host) void {
        for (self.signals.items) |sent| {
            self.gpa.free(sent.title);
            self.gpa.free(sent.body);
        }
        self.signals.clearRetainingCapacity();
    }

    fn signal(self: *Host, value: proto.ShellSignal) void {
        var owned = value;
        owned.sid = self.sid;
        owned.shell_id = self.id;
        owned.title = self.gpa.dupe(u8, value.title) catch return;
        owned.body = self.gpa.dupe(u8, value.body) catch {
            self.gpa.free(owned.title);
            return;
        };
        self.signals.append(self.gpa, owned) catch {
            self.gpa.free(owned.title);
            self.gpa.free(owned.body);
        };
    }

    fn onBell(handler: *vt.TerminalStream.Handler) void {
        fromHandler(handler).signal(.{ .sid = 0, .shell_id = 0, .kind = .bell });
    }

    fn onNotification(handler: *vt.TerminalStream.Handler, note: vt.TerminalStream.Action.ShowDesktopNotification) void {
        fromHandler(handler).signal(.{ .sid = 0, .shell_id = 0, .kind = .notification, .title = note.title, .body = note.body });
    }

    fn onProgress(handler: *vt.TerminalStream.Handler, report: vt.osc.Command.ProgressReport) void {
        fromHandler(handler).signal(.{
            .sid = 0,
            .shell_id = 0,
            .kind = .progress,
            .progress = switch (report.state) {
                .remove => .remove,
                .set => .set,
                .@"error" => .@"error",
                .indeterminate => .indeterminate,
                .pause => .pause,
            },
            .percent = report.progress,
        });
    }

    pub const max_commands = 64;

    /// OSC 133: a command starts (C, with its command line when the shell
    /// sends it) and ends (D, with its exit code).
    fn onSemanticPrompt(handler: *vt.TerminalStream.Handler, event: vt.TerminalStream.Handler.SemanticPrompt) void {
        const self = fromHandler(handler);
        switch (event.kind) {
            .output_start => {
                if (self.commands.items.len == max_commands) {
                    self.gpa.free(self.commands.items[0].command);
                    _ = self.commands.orderedRemove(0);
                }
                // Shells that do not send the command line (Ghostty's own zsh
                // integration) typed it into cells marked as input.
                var typed: [1024]u8 = undefined;
                const command = if (event.command.len > 0) event.command else self.typedCommand(&typed);
                const text = self.gpa.dupe(u8, std.mem.trim(u8, command, " \t\r\n")) catch return;
                self.commands.append(self.gpa, .{ .command = text }) catch self.gpa.free(text);
            },
            .command_end => if (self.commands.items.len > 0) {
                const last = &self.commands.items[self.commands.items.len - 1];
                if (last.exit_code == null) last.exit_code = event.exit_code;
            },
            else => {},
        }
    }

    /// The command line just entered: the input-marked cells (OSC 133 B to
    /// C) on the rows ending at the cursor, up to the row its prompt began
    /// on (a command that printed nothing sits right above), joined.
    fn typedCommand(self: *Host, buf: []u8) []const u8 {
        const screen = self.terminal.screens.active;
        var pin = screen.cursor.page_pin.*;
        var rows: [8][]const u8 = undefined;
        var row_bufs: [8][256]u8 = undefined;
        var count: usize = 0;
        var seen_input = false;
        for (0..rows.len) |_| {
            const row = inputText(pin, &row_bufs[count]);
            if (row.text.len > 0) {
                rows[count] = row.text;
                count += 1;
                seen_input = true;
                if (row.prompted) break;
            } else if (seen_input) break;
            if (count == rows.len) break;
            pin = pin.up(1) orelse break;
        }
        var w: std.Io.Writer = .fixed(buf);
        var i = count;
        while (i > 0) {
            i -= 1;
            w.writeAll(rows[i]) catch break;
        }
        return w.buffered();
    }

    /// A row's input-marked text, and whether a prompt starts on it.
    fn inputText(pin: vt.Pin, buf: []u8) struct { text: []const u8, prompted: bool } {
        var w: std.Io.Writer = .fixed(buf);
        var prompted = false;
        for (pin.cells(.all)) |*cell| {
            if (cell.semantic_content == .prompt) prompted = true;
            if (cell.semantic_content != .input or !cell.hasText()) continue;
            var cp_buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cell.codepoint(), &cp_buf) catch continue;
            w.writeAll(cp_buf[0..n]) catch break;
        }
        return .{ .text = w.buffered(), .prompted = prompted };
    }

    fn writePty(handler: *vt.TerminalStream.Handler, bytes: []const u8) void {
        fromHandler(handler).write(bytes) catch {};
    }

    fn deviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }

    fn sizeReport(handler: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.terminal.rows,
            .columns = self.terminal.cols,
            .cell_width = self.geometry.cell_width,
            .cell_height = self.geometry.cell_height,
        };
    }
};
