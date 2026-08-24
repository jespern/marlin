//! TUI client: libvaxis. Modal (insert/normal), single pane (M2).
//! See docs/ARCHITECTURE.md §8 for the target layout; splits/sidebar/mouse
//! land in M4. This client is a pure protocol consumer: attach.Conn in,
//! blocks out. Deltas are ephemeral; finalized blocks replace them.
//!
//! Layout (M2):
//!   ┌─ session view: blocks, streaming region ─┐
//!   ├─ input box (1 line) ──────────────────────┤
//!   └─ status: mode · state · model · tokens ───┘
//!
//! Keys:
//!   insert:  type → input; Enter send; Esc → normal; Ctrl+C interrupt/quit
//!   normal:  i insert; j/k scroll; g/G top/bottom; q quit; Ctrl+C same
//!   approval pending: y approve, n deny (both modes, input empty)
//!   commands: /model <m>, /new, /compact, /help, /quit

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const config = @import("../core/config.zig");
const attach = @import("attach.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    /// One raw NDJSON line from the daemon (gpa-owned; handler frees).
    daemon_line: []u8,
    daemon_gone,
};

const Mode = enum { insert, normal };

/// A block reduced to what the renderer needs (owned copies).
const RenderBlock = struct {
    kind: block.BlockKind,
    /// Primary text (message text, tool output, note...).
    text: []u8,
    /// tool_call: "name" — used for the collapsed header line.
    label: []u8,
    status: block.ToolStatus = .ok,

    fn deinit(self: *RenderBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.label);
    }
};

const PendingApproval = struct {
    id_buf: [32]u8 = undefined,
    id_len: usize = 0,
    tool_buf: [64]u8 = undefined,
    tool_len: usize = 0,
    args_buf: [256]u8 = undefined,
    args_len: usize = 0,

    fn id(self: *const PendingApproval) []const u8 {
        return self.id_buf[0..self.id_len];
    }
    fn tool(self: *const PendingApproval) []const u8 {
        return self.tool_buf[0..self.tool_len];
    }
    fn args(self: *const PendingApproval) []const u8 {
        return self.args_buf[0..self.args_len];
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn: *attach.Conn,
    sid: u64,

    mode: Mode = .insert,
    blocks: std.ArrayList(RenderBlock) = .empty,
    delta: std.ArrayList(u8) = .empty,
    state: proto.SessionState = .idle,
    model: std.ArrayList(u8) = .empty,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    /// 0 = pinned to bottom; N = scrolled up N lines.
    scroll_up: usize = 0,
    pending: ?PendingApproval = null,
    /// Transient one-line notice shown in the status bar.
    notice: std.ArrayList(u8) = .empty,
    should_quit: bool = false,
    awaiting_new_session: bool = false,

    fn deinit(self: *App) void {
        for (self.blocks.items) |*rb| rb.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.delta.deinit(self.gpa);
        self.model.deinit(self.gpa);
        self.notice.deinit(self.gpa);
    }

    fn setNotice(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.notice.clearRetainingCapacity();
        self.notice.print(self.gpa, fmt, args) catch {};
    }

    fn setModelStr(self: *App, m: []const u8) void {
        self.model.clearRetainingCapacity();
        self.model.appendSlice(self.gpa, m) catch {};
    }

    fn pushBlock(self: *App, kind: block.BlockKind, text: []const u8, label: []const u8, status: block.ToolStatus) void {
        const t = self.gpa.dupe(u8, text) catch return;
        const l = self.gpa.dupe(u8, label) catch {
            self.gpa.free(t);
            return;
        };
        self.blocks.append(self.gpa, .{ .kind = kind, .text = t, .label = l, .status = status }) catch {
            self.gpa.free(t);
            self.gpa.free(l);
        };
    }

    // ------------------------------------------------------ daemon input --

    fn handleDaemonLine(self: *App, line: []u8) void {
        defer self.gpa.free(line);
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const msg = proto.decode(proto.DaemonMsg, arena_state.allocator(), line) catch return;

        switch (msg) {
            .blk => |b| {
                if (b.sid != self.sid) return;
                self.applyBlock(b.b);
            },
            .delta => |d| {
                if (d.sid != self.sid) return;
                self.delta.appendSlice(self.gpa, d.text) catch {};
            },
            .status => |s| {
                if (s.sid != self.sid) return;
                self.state = s.state;
                if (s.state != .awaiting_approval) self.pending = null;
            },
            .approval_request => |ar| {
                if (ar.sid != self.sid) return;
                var p = PendingApproval{};
                p.id_len = @min(ar.approval_id.len, p.id_buf.len);
                @memcpy(p.id_buf[0..p.id_len], ar.approval_id[0..p.id_len]);
                p.tool_len = @min(ar.tool.len, p.tool_buf.len);
                @memcpy(p.tool_buf[0..p.tool_len], ar.tool[0..p.tool_len]);
                p.args_len = @min(ar.args_json.len, p.args_buf.len);
                @memcpy(p.args_buf[0..p.args_len], ar.args_json[0..p.args_len]);
                self.pending = p;
            },
            .session_created => |sc| self.handleSessionCreated(sc.sid),
            .session_meta => |m| {
                if (m.sid != self.sid) return;
                self.tokens_in = m.tokens_in;
                self.tokens_out = m.tokens_out;
            },
            .err => |e| {
                self.setNotice("daemon error {s}: {s}", .{ e.code, e.msg });
            },
            else => {},
        }
    }

    fn applyBlock(self: *App, b: block.Block) void {
        switch (b.body) {
            .user_msg => |u| self.pushBlock(.user_msg, u.text, "", .ok),
            .steer => |s| self.pushBlock(.steer, s.text, "", .ok),
            .assistant_msg => |a| {
                // Finalized text replaces the streaming delta.
                self.delta.clearRetainingCapacity();
                self.pushBlock(.assistant_msg, a.text, "", .ok);
            },
            .reasoning => |r| self.pushBlock(.reasoning, r.text, "", .ok),
            .tool_call => |tc| self.pushBlock(.tool_call, tc.args_json, tc.name, .ok),
            .tool_result => |tr| self.pushBlock(.tool_result, tr.inline_body, "", tr.status),
            .approval => |ap| {
                const txt = if (ap.decision) |d| @tagName(d) else "pending";
                self.pushBlock(.approval, txt, "", .ok);
            },
            .system_note => |sn| self.pushBlock(.system_note, sn.text, "", .ok),
            .compaction => |cp| self.pushBlock(.compaction, cp.summary, "", .ok),
        }
        // New content: keep pinned to bottom unless the user scrolled up.
        if (self.scroll_up > 0) self.scroll_up +|= 0; // stay where they are
    }

    // -------------------------------------------------------- user input --

    fn submitInput(self: *App, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        if (trimmed[0] == '/') {
            self.runCommand(trimmed);
            return;
        }
        self.conn.send(.{ .input = .{ .sid = self.sid, .text = trimmed } }) catch {
            self.setNotice("send failed — daemon gone?", .{});
            return;
        };
        if (self.state == .running) self.setNotice("queued as steer (turn running)", .{});
        self.scroll_up = 0;
    }

    fn runCommand(self: *App, cmd: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        const head = it.next() orelse return;

        if (std.mem.eql(u8, head, "/quit") or std.mem.eql(u8, head, "/q")) {
            self.should_quit = true;
        } else if (std.mem.eql(u8, head, "/model")) {
            const m = it.rest();
            if (m.len == 0) {
                self.setNotice("model: {s}", .{self.model.items});
                return;
            }
            self.conn.send(.{ .session_set_model = .{ .sid = self.sid, .model = m } }) catch return;
            self.setModelStr(m);
            self.setNotice("model → {s}", .{m});
        } else if (std.mem.eql(u8, head, "/new")) {
            self.newSession() catch {
                self.setNotice("could not create session", .{});
            };
        } else if (std.mem.eql(u8, head, "/compact")) {
            // M3: real compaction. Manual stub so the muscle memory exists.
            self.setNotice("compaction lands in M3", .{});
        } else if (std.mem.eql(u8, head, "/help")) {
            self.setNotice("/model <m> · /new · /compact · /quit — Esc normal, i insert, j/k scroll, Ctrl+C interrupt", .{});
        } else {
            self.setNotice("unknown command {s} (try /help)", .{head});
        }
    }

    fn newSession(self: *App) !void {
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = try std.process.currentPath(self.io, &cwd_buf);
        try self.conn.send(.{ .session_create = .{
            .cwd = cwd_buf[0..cwd_len],
            .model = self.model.items,
        } });
        // The reply is routed through the reader thread; we can't recv here.
        // Optimistic switch happens when session_created arrives — but that
        // message has no sub; simplest correct M2 flow: remember we asked.
        // Handled in handleDaemonLineCreated below via the pending flag.
        self.awaiting_new_session = true;
    }

    fn handleSessionCreated(self: *App, sid: u64) void {
        if (!self.awaiting_new_session) return;
        self.awaiting_new_session = false;
        // Switch: clear state, subscribe.
        for (self.blocks.items) |*rb| rb.deinit(self.gpa);
        self.blocks.clearRetainingCapacity();
        self.delta.clearRetainingCapacity();
        self.tokens_in = 0;
        self.tokens_out = 0;
        self.pending = null;
        self.state = .idle;
        self.sid = sid;
        self.conn.send(.{ .sub = .{ .sid = sid, .from_seq = 1 } }) catch {};
        self.setNotice("new session {d}", .{sid});
    }

    fn approveReply(self: *App, granted: bool) void {
        const p = self.pending orelse return;
        self.conn.send(.{ .approve = .{
            .sid = self.sid,
            .approval_id = p.id(),
            .decision = if (granted) .granted else .denied,
        } }) catch return;
        self.pending = null;
    }

    fn interrupt(self: *App) void {
        self.conn.send(.{ .interrupt = .{ .sid = self.sid } }) catch {};
        self.setNotice("interrupt sent", .{});
    }
};

// ------------------------------------------------------------- rendering --

const Palette = struct {
    const user: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true }; // cyan
    const assistant: vaxis.Style = .{};
    const reasoning: vaxis.Style = .{ .fg = .{ .index = 8 }, .italic = true };
    const tool: vaxis.Style = .{ .fg = .{ .index = 4 } }; // blue
    const tool_out: vaxis.Style = .{ .fg = .{ .index = 8 } }; // dim
    const tool_err: vaxis.Style = .{ .fg = .{ .index = 1 } }; // red
    const note: vaxis.Style = .{ .fg = .{ .index = 3 } }; // yellow
    const steer: vaxis.Style = .{ .fg = .{ .index = 5 } }; // magenta
    const status_bar: vaxis.Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 7 } };
    const approval_card: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    const delta_style: vaxis.Style = .{};
};

/// One logical line ready to draw: text slice + style. Slices point into
/// the App's block storage (valid for the frame).
const Line = struct {
    text: []const u8,
    style: vaxis.Style,
};

/// Flatten blocks + delta into wrapped display lines for a given width.
/// Returned list and its line slices use `arena` (per-frame).
fn layoutLines(arena: std.mem.Allocator, app: *App, width: u16) !std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    const w: usize = if (width == 0) 80 else width;

    for (app.blocks.items) |rb| {
        switch (rb.kind) {
            .user_msg => {
                try wrapInto(arena, &lines, "", .{ .text = "", .style = .{} }); // blank separator
                try wrapPrefixed(arena, &lines, "❯ ", rb.text, Palette.user, w);
            },
            .assistant_msg => {
                try blankLine(arena, &lines);
                try wrapPrefixed(arena, &lines, "", rb.text, Palette.assistant, w);
            },
            .reasoning => try wrapPrefixed(arena, &lines, "· ", rb.text, Palette.reasoning, w),
            .tool_call => {
                const preview_len = @min(rb.text.len, @min(w -| (rb.label.len + 4), 120));
                const header = try std.fmt.allocPrint(arena, "⚙ {s} {s}", .{ rb.label, rb.text[0..preview_len] });
                try wrapInto(arena, &lines, header, .{ .text = header, .style = Palette.tool });
            },
            .tool_result => {
                const style = if (rb.status == .ok) Palette.tool_out else Palette.tool_err;
                const glyph: []const u8 = switch (rb.status) {
                    .ok => "  ",
                    .err => "  ✗ ",
                    .denied => "  ⊘ ",
                    .interrupted => "  ⏹ ",
                };
                // Collapsed: show at most 8 lines of output.
                var shown: usize = 0;
                var total: usize = 0;
                var it = std.mem.splitScalar(u8, rb.text, '\n');
                while (it.next()) |l| {
                    total += 1;
                    if (shown < 8) {
                        const prefixed = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, l });
                        try wrapInto(arena, &lines, prefixed, .{ .text = prefixed, .style = style });
                        shown += 1;
                    }
                }
                if (total > shown) {
                    const more = try std.fmt.allocPrint(arena, "  … {d} more lines", .{total - shown});
                    try wrapInto(arena, &lines, more, .{ .text = more, .style = Palette.tool_out });
                }
            },
            .approval => {
                const txt = try std.fmt.allocPrint(arena, "  [approval: {s}]", .{rb.text});
                try wrapInto(arena, &lines, txt, .{ .text = txt, .style = Palette.note });
            },
            .steer => try wrapPrefixed(arena, &lines, "↪ ", rb.text, Palette.steer, w),
            .system_note => {
                const txt = try std.fmt.allocPrint(arena, "[{s}]", .{rb.text});
                try wrapPrefixed(arena, &lines, "", txt, Palette.note, w);
            },
            .compaction => try wrapPrefixed(arena, &lines, "≋ ", rb.text, Palette.note, w),
        }
    }

    // Streaming region: current delta text as an in-progress assistant msg.
    if (app.delta.items.len > 0) {
        try blankLine(arena, &lines);
        try wrapPrefixed(arena, &lines, "", app.delta.items, Palette.delta_style, w);
    } else if (app.state == .running) {
        try blankLine(arena, &lines);
        try wrapInto(arena, &lines, "…", .{ .text = "…", .style = Palette.tool_out });
    }

    // Approval card.
    if (app.pending) |*p| {
        try blankLine(arena, &lines);
        const card = try std.fmt.allocPrint(arena, "⚠ approve {s} {s} ?  [y]es / [n]o", .{ p.tool(), p.args() });
        try wrapPrefixed(arena, &lines, "", card, Palette.approval_card, w);
    }
    return lines;
}

fn blankLine(arena: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    try lines.append(arena, .{ .text = "", .style = .{} });
}

fn wrapInto(arena: std.mem.Allocator, lines: *std.ArrayList(Line), _: []const u8, line: Line) !void {
    try lines.append(arena, line);
}

/// Hard-wrap text at `width` bytes (grapheme-naive M2 wrap; vaxis print
/// could soft-wrap, but explicit lines keep scrolling simple and correct
/// enough for monospace ASCII-dominant content).
fn wrapPrefixed(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    prefix: []const u8,
    text: []const u8,
    style: vaxis.Style,
    width: usize,
) !void {
    const body_width = width -| prefix.len;
    if (body_width < 8) return;
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        var rest = raw_line;
        while (true) {
            const take = @min(rest.len, body_width);
            const chunk = rest[0..take];
            const full = if (first and prefix.len > 0)
                try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, chunk })
            else if (prefix.len > 0)
                try std.fmt.allocPrint(arena, "{s}{s}", .{ " " ** 0, chunk }) // continuation, no prefix
            else
                chunk;
            try lines.append(arena, .{ .text = full, .style = style });
            first = false;
            if (take == rest.len) break;
            rest = rest[take..];
        }
        if (raw_line.len == 0) try lines.append(arena, .{ .text = "", .style = style });
    }
}

fn draw(app: *App, vx: *vaxis.Vaxis, input: *vaxis.widgets.TextInput, arena: std.mem.Allocator) !void {
    const win = vx.window();
    win.clear();
    const h = win.height;
    const w = win.width;
    if (h < 4 or w < 20) return;

    const view_h: u16 = h - 2; // input line + status line

    // ---- session view ----
    var lines = try layoutLines(arena, app, w);
    const total = lines.items.len;
    const max_scroll = total -| view_h;
    if (app.scroll_up > max_scroll) app.scroll_up = max_scroll;
    const first_visible = (total -| view_h) -| app.scroll_up;
    const visible = lines.items[first_visible..@min(first_visible + view_h, total)];

    for (visible, 0..) |ln, row| {
        _ = win.printSegment(.{ .text = ln.text, .style = ln.style }, .{
            .row_offset = @intCast(row),
            .wrap = .none,
        });
    }

    // ---- input line ----
    const input_win = win.child(.{ .y_off = h - 2, .height = 1, .width = w });
    const prompt: []const u8 = if (app.mode == .insert) "> " else ": ";
    _ = input_win.printSegment(.{ .text = prompt, .style = Palette.user }, .{ .wrap = .none });
    const field = input_win.child(.{ .x_off = 2, .width = w -| 2, .height = 1 });
    input.draw(field);
    if (app.mode == .normal) win.hideCursor();

    // ---- status bar ----
    const status_win = win.child(.{ .y_off = h - 1, .height = 1, .width = w });
    status_win.fill(.{ .style = Palette.status_bar });
    const state_txt: []const u8 = switch (app.state) {
        .idle => "idle",
        .running => "running",
        .awaiting_approval => "APPROVAL?",
        .err => "error",
        .done => "done",
    };
    const status = try std.fmt.allocPrint(arena, " {s} · {s} · {s} · {d}↑ {d}↓ · s{d}  {s}", .{
        @tagName(app.mode),
        state_txt,
        app.model.items,
        app.tokens_in,
        app.tokens_out,
        app.sid,
        app.notice.items,
    });
    _ = status_win.printSegment(.{ .text = status, .style = Palette.status_bar }, .{ .wrap = .none });
}

// ------------------------------------------------------------ entry point --

/// Reader thread: daemon socket lines → vaxis event queue.
fn readerThread(app: *App, loop: *vaxis.Loop(Event)) void {
    while (true) {
        const line = app.conn.reader.interface.takeDelimiterInclusive('\n') catch break;
        const owned = app.gpa.dupe(u8, line) catch break;
        loop.postEvent(.{ .daemon_line = owned }) catch {
            app.gpa.free(owned);
            break;
        };
    }
    loop.postEvent(.daemon_gone) catch {};
}

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    self_exe: []const u8,
    sid_arg: ?u64,
) !u8 {
    // -- connect + pick session BEFORE entering the TUI --
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        std.log.err("cannot reach daemon: {t}", .{e});
        return 1;
    };
    defer conn.deinit();

    const cfg = config.defaults();
    var model_at_start: []const u8 = cfg.model_default;
    var model_buf: [256]u8 = undefined;

    var sid: u64 = 0;
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        if (sid_arg) |s| {
            sid = s;
        } else {
            // Newest session, or create one.
            try conn.send(.{ .session_list = .{} });
            const list = try conn.recvUntil(arena, .session_list_result);
            if (list.sessions.len > 0) {
                sid = list.sessions[0].sid;
                const m = list.sessions[0].model;
                const n = @min(m.len, model_buf.len);
                @memcpy(model_buf[0..n], m[0..n]);
                model_at_start = model_buf[0..n];
            } else {
                var cwd_buf: [4096]u8 = undefined;
                const cwd_len = try std.process.currentPath(io, &cwd_buf);
                try conn.send(.{ .session_create = .{ .cwd = cwd_buf[0..cwd_len], .model = cfg.model_default } });
                const created = try conn.recvUntil(arena, .session_created);
                sid = created.sid;
            }
        }
        // Full replay: seq 1 onward.
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 1 } });
    }

    var app = App{ .gpa = gpa, .io = io, .conn = conn, .sid = sid };
    defer app.deinit();
    app.setModelStr(model_at_start);

    // -- vaxis init --
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, environ, .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    // Initial size: not all paths deliver a winsize event up-front (and a
    // PTY may report late); fetch it directly so the first frame renders.
    {
        var ws = tty.getWinsize() catch vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        if (ws.rows == 0 or ws.cols == 0) ws = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        try vx.resize(gpa, tty.writer(), ws);
    }

    // -- daemon reader thread --
    const rt = try std.Thread.spawn(.{}, readerThread, .{ &app, &loop });
    // Joined at exit: we shutdown() the socket which EOFs the reader —
    // closing the fd under a live read is a BADF panic on the Threaded Io.
    defer rt.join();
    defer conn.stream.shutdown(io, .both) catch {};

    var input = vaxis.widgets.TextInput.init(gpa);
    defer input.deinit();

    // First frame before any event arrives.
    {
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        try draw(&app, &vx, &input, frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }

    // -- main event loop --
    while (!app.should_quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try handleKey(&app, &input, key),
            .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
            .daemon_line => |line| {
                app.handleDaemonLine(line);
                // Drain any additional queued lines before redrawing.
                while (try loop.tryEvent()) |ev2| {
                    switch (ev2) {
                        .daemon_line => |l2| app.handleDaemonLine(l2),
                        .daemon_gone => app.should_quit = true,
                        .key_press => |k2| try handleKey(&app, &input, k2),
                        .winsize => |ws2| try vx.resize(gpa, tty.writer(), ws2),
                    }
                }
            },
            .daemon_gone => {
                app.setNotice("daemon connection lost", .{});
                app.should_quit = true;
            },
        }

        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        try draw(&app, &vx, &input, frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }
    return 0;
}

fn handleKey(app: *App, input: *vaxis.widgets.TextInput, key: vaxis.Key) !void {
    // Ctrl+C: interrupt a running turn; quit when idle.
    if (key.matches('c', .{ .ctrl = true })) {
        if (app.state == .running or app.state == .awaiting_approval) {
            app.interrupt();
        } else {
            app.should_quit = true;
        }
        return;
    }

    // Approval hotkeys work in both modes when the input is empty.
    if (app.pending != null and inputEmpty(input)) {
        if (key.matches('y', .{})) {
            app.approveReply(true);
            return;
        }
        if (key.matches('n', .{})) {
            app.approveReply(false);
            return;
        }
    }

    switch (app.mode) {
        .insert => {
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal;
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const text = try input.toOwnedSlice();
                defer app.gpa.free(@constCast(text));
                app.submitInput(text);
            } else {
                try input.update(.{ .key_press = key });
            }
        },
        .normal => {
            if (key.matches('i', .{})) {
                app.mode = .insert;
            } else if (key.matches('q', .{})) {
                app.should_quit = true;
            } else if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                app.scroll_up -|= 1;
            } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                app.scroll_up +|= 1;
            } else if (key.matches('d', .{ .ctrl = true }) or key.matches(vaxis.Key.page_down, .{})) {
                app.scroll_up -|= 20;
            } else if (key.matches('u', .{ .ctrl = true }) or key.matches(vaxis.Key.page_up, .{})) {
                app.scroll_up +|= 20;
            } else if (key.matches('G', .{ .shift = true }) or key.matches('G', .{})) {
                app.scroll_up = 0;
            } else if (key.matches('g', .{})) {
                app.scroll_up = std.math.maxInt(usize); // clamped in draw
            }
        },
    }
}

fn inputEmpty(input: *vaxis.widgets.TextInput) bool {
    return input.buf.firstHalf().len == 0 and input.buf.secondHalf().len == 0;
}

test {
    std.testing.refAllDecls(@This());
}
