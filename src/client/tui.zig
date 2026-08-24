//! TUI client: libvaxis. Modal (insert/normal), single pane (M2).
//! See docs/ARCHITECTURE.md §8 for the target layout; splits/sidebar/mouse
//! land in M4. This client is a pure protocol consumer: attach.Conn in,
//! blocks out. Deltas are ephemeral; finalized blocks replace them.
//!
//! Layout (M3):
//!   ┌─ session view: blocks, streaming region ─┐
//!   ├─ prompt panel (3-10 lines, grows with content) ┤
//!   └─ status: state · model · tokens · ctx ────┤
//!
//! Keys:
//!   insert:  type → input; Enter send; Shift+Enter/Alt+Enter/Ctrl+J newline;
//!            Up/Down or Ctrl+P/N move lines or walk history at the edges;
//!            readline/macOS movement and deletion chords are supported;
//!            Esc → normal (draft survives); Ctrl+C interrupt/quit
//!   normal:  i insert; j/k scroll; g/G top/bottom; q quit; Ctrl+C same
//!   approval pending: y approve, n deny (both modes, input empty)
//!   commands: /model <m>, /new, /compact, /reboot [--build], /help, /quit
//!   paste:   bracketed paste; large pastes become [paste #N: X lines]
//!            chips, expanded into the message on send.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const config = @import("../core/config.zig");
const attach = @import("attach.zig");
const credentials = @import("../core/credentials.zig");
const Editor = @import("editor.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    /// Animation clock; posted only while a turn is running.
    tick,
    /// Bracketed paste text (allocated by the loop's paste allocator = gpa;
    /// handler frees).
    paste: []const u8,
    /// One raw NDJSON line from the daemon (gpa-owned; handler frees).
    daemon_line: []u8,
    daemon_gone,
};

const Mode = enum { insert, normal };

pub const RebootRequest = enum { none, plain, build };

/// A block reduced to what the renderer needs (owned copies).
const RenderBlock = struct {
    kind: block.BlockKind,
    /// Primary text (message text, tool output, note...).
    text: []u8,
    /// tool_call: "name" — used for the collapsed header line.
    label: []u8,
    status: block.ToolStatus = .ok,
    /// Locally inserted for instant submit feedback. The matching durable
    /// block clears this bit instead of producing a duplicate render block.
    pending_echo: bool = false,

    fn deinit(self: *RenderBlock, gpa: std.mem.Allocator) void {
        gpa.free(self.text);
        gpa.free(self.label);
    }
};

fn reconcilePendingEcho(blocks: []RenderBlock, kind: block.BlockKind, text: []const u8) bool {
    for (blocks) |*rendered| {
        if (rendered.pending_echo and rendered.kind == kind and std.mem.eql(u8, rendered.text, text)) {
            rendered.pending_echo = false;
            return true;
        }
    }
    return false;
}

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

const SelectionPoint = struct {
    line: usize,
    /// Terminal cell column, not a byte offset.
    col: usize,

    fn before(a: SelectionPoint, b: SelectionPoint) bool {
        return a.line < b.line or (a.line == b.line and a.col <= b.col);
    }
};

const Selection = struct {
    lo: SelectionPoint,
    hi: SelectionPoint,

    fn init(a: SelectionPoint, b: SelectionPoint) Selection {
        return if (a.before(b)) .{ .lo = a, .hi = b } else .{ .lo = b, .hi = a };
    }

    /// Selected terminal-cell interval on `line`, end-exclusive and clamped
    /// to the rendered text width. Mouse endpoints themselves are inclusive.
    fn columns(self: Selection, line: usize, line_width: usize) ?struct { start: usize, end: usize } {
        if (line < self.lo.line or line > self.hi.line) return null;
        const start = if (line == self.lo.line) @min(self.lo.col, line_width) else 0;
        const wanted_end = if (line == self.hi.line) self.hi.col +| 1 else line_width;
        return .{ .start = start, .end = @min(wanted_end, line_width) };
    }
};

const App = struct {
    gpa: std.mem.Allocator,
    io: Io,
    conn: *attach.Conn,
    sid: u64,
    editor: Editor,

    mode: Mode = .insert,
    /// Terminal columns (updated on every winsize event); used by handleKey
    /// for the editor's vertical-move edge detection so it matches draw().
    term_cols: usize = 80,
    blocks: std.ArrayList(RenderBlock) = .empty,
    delta: std.ArrayList(u8) = .empty,
    state: proto.SessionState = .idle,
    model: std.ArrayList(u8) = .empty,
    /// Session root from daemon metadata, not necessarily the attach
    /// process's current directory.
    cwd: std.ArrayList(u8) = .empty,
    /// Used only to render cwd with a compact ~/ prefix.
    home: std.ArrayList(u8) = .empty,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    context_used: u64 = 0,
    context_limit: u64 = 0,
    /// 0 = pinned to bottom; N = scrolled up N lines.
    scroll_up: usize = 0,
    /// Line count of the last rendered frame; used to keep the view
    /// anchored (not sliding) when new lines arrive while scrolled up.
    last_total_lines: usize = 0,
    /// View geometry of the last frame (for mouse row → line mapping).
    last_first_visible: usize = 0,
    last_view_h: usize = 0,
    pending: ?PendingApproval = null,
    /// Model picker overlay: null = closed; value = highlighted index into
    /// the FILTERED list (see pickerItems).
    picker: ?usize = null,
    /// Type-to-filter query while the picker is open.
    picker_filter: std.ArrayList(u8) = .empty,
    /// Full model catalog from the daemon (owned copies). Empty until
    /// model_list_result arrives; picker falls back to cfg.model_favorites.
    catalog: std.ArrayList([]u8) = .empty,
    /// Character-precise mouse selection over the session view. Lines are
    /// absolute layout indices; columns are terminal cells within the line.
    sel_anchor: ?SelectionPoint = null,
    sel_head: SelectionPoint = .{ .line = 0, .col = 0 },
    sel_dragging: bool = false,
    /// Set when a selection was completed (mouse released): next frame
    /// copies the selected cells via OSC52 and clears the flag.
    copy_pending: bool = false,
    spinner_frame: usize = 0,
    animation_active: std.atomic.Value(bool) = .init(false),
    animation_stop: std.atomic.Value(bool) = .init(false),
    cfg: config.Config = .{},
    /// Transient one-line notice shown in the status bar.
    notice: std.ArrayList(u8) = .empty,
    should_quit: bool = false,
    awaiting_new_session: bool = false,
    /// Set by /reboot: after clean TUI teardown, run() returns this to
    /// cli.zig which execs `marlin reboot [--build] --then attach <sid>`.
    reboot_request: RebootRequest = .none,

    fn deinit(self: *App) void {
        self.picker_filter.deinit(self.gpa);
        for (self.catalog.items) |m| self.gpa.free(m);
        self.catalog.deinit(self.gpa);
        for (self.blocks.items) |*rb| rb.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.delta.deinit(self.gpa);
        self.model.deinit(self.gpa);
        self.cwd.deinit(self.gpa);
        self.home.deinit(self.gpa);
        self.notice.deinit(self.gpa);
        self.editor.deinit();
    }

    fn setNotice(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.notice.clearRetainingCapacity();
        self.notice.print(self.gpa, fmt, args) catch {};
    }

    fn setModelStr(self: *App, m: []const u8) void {
        self.model.clearRetainingCapacity();
        self.model.appendSlice(self.gpa, m) catch {};
    }

    fn setCwdStr(self: *App, cwd: []const u8) void {
        self.cwd.clearRetainingCapacity();
        self.cwd.appendSlice(self.gpa, cwd) catch {};
    }

    fn setHomeStr(self: *App, home: []const u8) void {
        self.home.clearRetainingCapacity();
        self.home.appendSlice(self.gpa, home) catch {};
    }

    fn pushBlock(self: *App, kind: block.BlockKind, text: []const u8, label: []const u8, status: block.ToolStatus) void {
        self.pushBlockPending(kind, text, label, status, false);
    }

    fn pushBlockPending(
        self: *App,
        kind: block.BlockKind,
        text: []const u8,
        label: []const u8,
        status: block.ToolStatus,
        pending_echo: bool,
    ) void {
        const t = self.gpa.dupe(u8, text) catch return;
        const l = self.gpa.dupe(u8, label) catch {
            self.gpa.free(t);
            return;
        };
        self.blocks.append(self.gpa, .{
            .kind = kind,
            .text = t,
            .label = l,
            .status = status,
            .pending_echo = pending_echo,
        }) catch {
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
                if (s.state == .running and self.state != .running) self.spinner_frame = 0;
                self.state = s.state;
                self.animation_active.store(s.state == .running, .release);
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
            .model_list_result => |ml| {
                for (self.catalog.items) |old| self.gpa.free(old);
                self.catalog.clearRetainingCapacity();
                for (ml.models) |m| {
                    const copy = self.gpa.dupe(u8, m) catch continue;
                    self.catalog.append(self.gpa, copy) catch self.gpa.free(copy);
                }
            },
            .session_meta => |m| {
                if (m.sid != self.sid) return;
                self.tokens_in = m.tokens_in;
                self.tokens_out = m.tokens_out;
                if (m.context_used > 0) self.context_used = m.context_used;
                if (m.context_limit > 0) self.context_limit = m.context_limit;
            },
            .err => |e| {
                self.setNotice("daemon error {s}: {s}", .{ e.code, e.msg });
            },
            else => {},
        }
    }

    fn applyBlock(self: *App, b: block.Block) void {
        switch (b.body) {
            .user_msg => |u| {
                if (!reconcilePendingEcho(self.blocks.items, .user_msg, u.text))
                    self.pushBlock(.user_msg, u.text, "", .ok);
                // Seed input history from the log (replay covers pre-reboot
                // messages; live blocks cover this session's submits).
                self.editor.pushHistory(u.text);
            },
            .steer => |s| {
                if (!reconcilePendingEcho(self.blocks.items, .steer, s.text))
                    self.pushBlock(.steer, s.text, "", .ok);
            },
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
            // Commands are client actions rather than durable user_msg
            // blocks, but they still belong in the local editor history so
            // Up then Enter can repeat them during this client lifetime.
            self.editor.pushHistory(trimmed);
            self.runCommand(trimmed);
            return;
        }
        const was_running = self.state == .running;
        self.conn.send(.{ .input = .{ .sid = self.sid, .text = trimmed } }) catch {
            self.setNotice("send failed — daemon gone?", .{});
            return;
        };
        if (was_running) {
            self.pushBlockPending(.steer, trimmed, "", .ok, true);
            self.setNotice("queued as steer (turn running)", .{});
        } else {
            // The composer becomes a scrollback card immediately. The turn
            // thread's persisted user_msg will reconcile this local echo.
            self.pushBlockPending(.user_msg, trimmed, "", .ok, true);
            self.state = .running;
            self.spinner_frame = 0;
            self.animation_active.store(true, .release);
        }
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
                self.picker = 0;
                self.picker_filter.clearRetainingCapacity();
                // Ask the daemon for the full catalog (async; picker shows
                // favorites until the reply lands).
                if (self.catalog.items.len == 0) {
                    self.conn.send(.{ .model_list = .{} }) catch {};
                }
                return;
            }
            self.applyModel(m);
        } else if (std.mem.eql(u8, head, "/new")) {
            self.newSession() catch {
                self.setNotice("could not create session", .{});
            };
        } else if (std.mem.eql(u8, head, "/reboot")) {
            const arg = it.rest();
            if (self.state == .running or self.state == .awaiting_approval) {
                self.setNotice("turn running — /reboot waits for it (interrupt first if you want force)", .{});
            }
            self.reboot_request = if (std.mem.eql(u8, arg, "--build")) .build else .plain;
            self.should_quit = true;
        } else if (std.mem.eql(u8, head, "/compact")) {
            if (self.state == .running or self.state == .awaiting_approval) {
                self.setNotice("cannot compact mid-turn", .{});
                return;
            }
            self.conn.send(.{ .session_compact = .{ .sid = self.sid } }) catch return;
            self.setNotice("compacting…", .{});
        } else if (std.mem.eql(u8, head, "/help")) {
            self.setNotice("/model <m> · /new · /compact · /reboot [--build] · /quit — Esc normal, i insert, j/k scroll, Ctrl+C interrupt", .{});
        } else {
            self.setNotice("unknown command {s} (try /help)", .{head});
        }
    }

    fn selection(self: *const App) ?Selection {
        const a = self.sel_anchor orelse return null;
        return Selection.init(a, self.sel_head);
    }

    /// The picker's source list: full catalog when loaded, else favorites.
    fn pickerSource(self: *const App) []const []const u8 {
        if (self.catalog.items.len > 0) return @ptrCast(self.catalog.items);
        return self.cfg.model_favorites;
    }

    /// Filtered picker items (arena-allocated indices into pickerSource).
    /// Filter: case-insensitive substring; multiple space-separated words
    /// must ALL match ("son 4.5" → claude-sonnet-4.5).
    fn pickerItems(self: *const App, arena: std.mem.Allocator) ![]const []const u8 {
        const source = self.pickerSource();
        const q = self.picker_filter.items;
        if (q.len == 0) return source;
        var out: std.ArrayList([]const u8) = .empty;
        outer: for (source) |m| {
            var words = std.mem.tokenizeScalar(u8, q, ' ');
            while (words.next()) |word| {
                if (containsIgnoreCase(m, word) == null) continue :outer;
            }
            try out.append(arena, m);
        }
        return out.items;
    }

    fn applyModel(self: *App, m: []const u8) void {
        if (self.state == .running or self.state == .awaiting_approval) {
            self.setNotice("cannot switch model mid-turn", .{});
            return;
        }
        self.conn.send(.{ .session_set_model = .{ .sid = self.sid, .model = m } }) catch return;
        self.setModelStr(m);
        self.setNotice("model → {s}", .{m});
    }

    fn newSession(self: *App) !void {
        var cwd_buf: [4096]u8 = undefined;
        const cwd_len = try std.process.currentPath(self.io, &cwd_buf);
        try self.conn.send(.{ .session_create = .{
            .cwd = cwd_buf[0..cwd_len],
            .model = self.model.items,
        } });
        self.setCwdStr(cwd_buf[0..cwd_len]);
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
        self.context_used = 0;
        self.context_limit = 0;
        self.pending = null;
        self.state = .idle;
        self.animation_active.store(false, .release);
        self.spinner_frame = 0;
        self.sel_anchor = null;
        self.sel_dragging = false;
        self.copy_pending = false;
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
    // Sampled from the Codex composer in the same terminal (#42454b), so
    // the raised surface has the same contrast instead of approximating it
    // through theme-dependent ANSI grays.
    const prompt_bg: vaxis.Color = .{ .rgb = .{ 0x42, 0x45, 0x4b } };
    const prompt_panel: vaxis.Style = .{ .bg = prompt_bg };
    const prompt_text: vaxis.Style = .{ .bg = prompt_bg };
    const prompt_mark: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 6 }, .bold = true };
    const assistant: vaxis.Style = .{};
    const reasoning: vaxis.Style = .{ .fg = .{ .index = 8 }, .italic = true };
    /// Tool machinery (the ⚙ glyph, arg previews, result bodies): dimmed
    /// gray so it reads as background activity, never as user input or as
    /// assistant prose meant for the human.
    const tool: vaxis.Style = .{ .fg = .{ .index = 8 } };
    /// The command itself inside a bash call: brighter than the machinery
    /// so the eye can pick out WHAT ran while skimming (codex/claude do
    /// this; it's the one part of a tool line worth reading).
    const tool_cmd: vaxis.Style = .{ .fg = .{ .index = 4 }, .bold = true }; // blue
    const tool_out: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };
    const tool_err: vaxis.Style = .{ .fg = .{ .index = 1 } }; // red
    // Fixed dark surfaces match the current Codex-like composer and keep the
    // add/delete signal restrained enough for syntax colors to remain legible.
    const diff_add_bg: vaxis.Color = .{ .rgb = .{ 0x1f, 0x37, 0x29 } };
    const diff_del_bg: vaxis.Color = .{ .rgb = .{ 0x3b, 0x24, 0x29 } };
    const diff_add: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x73, 0xd0, 0x91 } }, .bg = diff_add_bg, .bold = true };
    const diff_del: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf0, 0x71, 0x78 } }, .bg = diff_del_bg, .bold = true };
    const diff_add_code: vaxis.Style = .{ .bg = diff_add_bg };
    const diff_del_code: vaxis.Style = .{ .bg = diff_del_bg };
    const diff_context: vaxis.Style = .{ .fg = .{ .index = 8 } };
    const diff_hunk: vaxis.Style = .{ .fg = .{ .index = 6 } }; // cyan @@ + decl ctx
    const syntax_keyword: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc7, 0x92, 0xea } }, .bold = true };
    const syntax_string: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc3, 0xe8, 0x8d } } };
    const syntax_number: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf7, 0x8c, 0x6c } } };
    const syntax_comment: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x69, 0x70, 0x98 } }, .italic = true };
    const syntax_type: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } } };
    const syntax_function: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x82, 0xaa, 0xff } } };
    const syntax_constant: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xff, 0xcb, 0x6b } } };
    const note: vaxis.Style = .{ .fg = .{ .index = 3 } }; // yellow
    const steer: vaxis.Style = .{ .fg = .{ .index = 5 } }; // magenta
    const status_bg: vaxis.Color = .{ .index = 0 };
    const status_bar: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 7 } };
    const status_sep: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 8 }, .dim = true };
    const status_idle: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 2 } };
    const status_running: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 }, .bold = true };
    const status_approval: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 }, .bold = true };
    const status_error: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 1 }, .bold = true };
    const status_model: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 6 } };
    const status_context: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 4 } };
    const status_context_warn: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 } };
    const status_context_hot: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 1 } };
    const status_cwd: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 2 } };
    const status_notice: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 } };
    const approval_card: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    const delta_style: vaxis.Style = .{};
};

fn statusModel(model: []const u8) []const u8 {
    const gateway = "openrouter/";
    return if (std.mem.startsWith(u8, model, gateway)) model[gateway.len..] else model;
}

fn statusCwd(arena: std.mem.Allocator, cwd: []const u8, home: []const u8) ![]const u8 {
    if (cwd.len == 0) return "cwd ?";
    if (home.len > 0 and
        std.mem.startsWith(u8, cwd, home) and
        (cwd.len == home.len or cwd[home.len] == '/'))
    {
        return std.fmt.allocPrint(arena, "~{s}", .{cwd[home.len..]});
    }
    return cwd;
}

const LinkSpan = struct {
    /// Byte offsets in the concatenated visible text of a Line.
    start: usize,
    end: usize,
    /// OSC 8 destination. Always an allowlisted http(s) URL.
    uri: []const u8,
};

const SyntaxSpan = struct {
    /// Byte offsets in the concatenated visible text of a Line.
    start: usize,
    end: usize,
    style: vaxis.Style,
};

/// One logical display line: 1..3 styled segments (segments never wrap
/// independently; the line is the wrap unit). Slices point into the App's
/// block storage or the frame arena (valid for the frame).
const Line = struct {
    text: []const u8,
    style: vaxis.Style,
    /// When set, paint the complete terminal row before printing segments.
    /// Prompt cards use this to retain their background past the text.
    fill_style: ?vaxis.Style = null,
    /// Optional second/third segment printed after `text` on the same row.
    text2: []const u8 = "",
    style2: vaxis.Style = .{},
    text3: []const u8 = "",
    style3: vaxis.Style = .{},
    /// Hyperlinks over the concatenated text/text2/text3 byte stream.
    links: []const LinkSpan = &.{},
    /// Foreground-only code syntax overlays. The underlying row background
    /// remains intact for added/deleted diff lines.
    syntax: []const SyntaxSpan = &.{},
    /// Wrapped message lines resolve links against the unbroken source URL.
    /// Other line kinds are scanned once after layout is complete.
    links_resolved: bool = false,
};

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn lineWidth(win: vaxis.Window, line: Line) usize {
    return @as(usize, win.gwidth(line.text)) +
        @as(usize, win.gwidth(line.text2)) +
        @as(usize, win.gwidth(line.text3));
}

fn lineText(arena: std.mem.Allocator, line: Line) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ line.text, line.text2, line.text3 });
}

const SyntaxLanguage = enum {
    generic,
    zig,
    rust,
    javascript,
    python,
    shell,
    json,
    toml,
    yaml,
    c_like,
    go,
    ruby,
    markdown,
};

fn languageForPath(path: []const u8) SyntaxLanguage {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or
        std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return .javascript;
    if (std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".pyi")) return .python;
    if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash") or
        std.mem.eql(u8, ext, ".zsh") or std.mem.eql(u8, ext, ".fish")) return .shell;
    if (std.mem.eql(u8, ext, ".json") or std.mem.eql(u8, ext, ".jsonc")) return .json;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".cxx") or std.mem.eql(u8, ext, ".hpp") or
        std.mem.eql(u8, ext, ".java") or std.mem.eql(u8, ext, ".swift") or
        std.mem.eql(u8, ext, ".kt")) return .c_like;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".rb")) return .ruby;
    if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".mdx")) return .markdown;
    return .generic;
}

/// Edit results start with `replaced ... in path`; regular git diffs expose
/// the target in a `+++ b/path` line. Supporting both keeps bash-produced
/// diffs useful too.
fn diffLanguage(text: []const u8) SyntaxLanguage {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.lastIndexOf(u8, line, " in ")) |at| {
            const path = std.mem.trim(u8, line[at + 4 ..], " \t\r");
            const lang = languageForPath(path);
            if (lang != .generic) return lang;
        }
        if (std.mem.startsWith(u8, line, "+++ ")) {
            var path = std.mem.trim(u8, line[4..], " \t\r");
            if (std.mem.startsWith(u8, path, "b/")) path = path[2..];
            if (!std.mem.eql(u8, path, "/dev/null")) return languageForPath(path);
        }
    }
    return .generic;
}

fn wordIn(word: []const u8, words: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, words, ' ');
    while (it.next()) |candidate| {
        if (std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

fn isKeyword(lang: SyntaxLanguage, word: []const u8) bool {
    const words: []const u8 = switch (lang) {
        .zig => "align allowzero and anyframe anytype asm async await break catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while",
        .rust => "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while",
        .javascript => "async await break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return static super switch this throw try typeof var void while with yield interface type enum implements namespace private protected public readonly",
        .python => "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
        .shell => "case do done elif else esac fi for function if in select then time until while",
        .c_like => "alignas alignof auto break case catch class const constexpr continue default delete do else enum explicit export extern final for friend goto if import inline interface namespace new noexcept operator override private protected public register return signed sizeof static struct switch template this throw try typedef typename union unsigned using virtual volatile while",
        .go => "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        .ruby => "alias and begin break case class def defined do else elsif end ensure false for if in module next not or redo rescue retry return self super then true undef unless until when while yield",
        else => "",
    };
    return wordIn(word, words);
}

fn isBuiltinType(word: []const u8) bool {
    return wordIn(
        word,
        "anyerror anyopaque bool byte c_int char comptime_float comptime_int f16 f32 f64 f80 f128 i8 i16 i32 i64 i128 isize noreturn str string String u8 u16 u32 u64 u128 usize void",
    );
}

fn isConstant(word: []const u8) bool {
    return wordIn(word, "false true null undefined nil None True False");
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '@' or c == '$';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn lineCommentMarker(lang: SyntaxLanguage) ?[]const u8 {
    return switch (lang) {
        .python, .shell, .toml, .yaml, .ruby => "#",
        .zig, .rust, .javascript, .c_like, .go => "//",
        else => null,
    };
}

fn appendSyntaxSpan(
    arena: std.mem.Allocator,
    spans: *std.ArrayList(SyntaxSpan),
    start: usize,
    end: usize,
    offset: usize,
    style: vaxis.Style,
) !void {
    try spans.append(arena, .{ .start = offset + start, .end = offset + end, .style = style });
}

/// Lightweight, line-local lexer. It intentionally recognizes broad lexical
/// classes rather than pretending to be a parser; malformed/incomplete diff
/// lines still receive stable highlighting and never affect stored text.
fn syntaxSpans(
    arena: std.mem.Allocator,
    code: []const u8,
    lang: SyntaxLanguage,
    offset: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var i: usize = 0;
    while (i < code.len) {
        if (lineCommentMarker(lang)) |marker| {
            if (std.mem.startsWith(u8, code[i..], marker)) {
                try appendSyntaxSpan(arena, &spans, i, code.len, offset, Palette.syntax_comment);
                break;
            }
        }
        if (std.mem.startsWith(u8, code[i..], "/*")) {
            const close = std.mem.indexOfPos(u8, code, i + 2, "*/");
            const end = if (close) |at| at + 2 else code.len;
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_comment);
            i = end;
            continue;
        }
        const c = code[i];
        if (c == '"' or c == '\'' or c == '`') {
            const quote = c;
            var end = i + 1;
            while (end < code.len) : (end += 1) {
                if (code[end] == '\\') {
                    end = @min(end + 1, code.len);
                    continue;
                }
                if (code[end] == quote) {
                    end += 1;
                    break;
                }
            }
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_string);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var end = i + 1;
            while (end < code.len and (std.ascii.isAlphanumeric(code[end]) or
                code[end] == '.' or code[end] == '_')) : (end += 1)
            {}
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_number);
            i = end;
            continue;
        }
        if (isIdentStart(c)) {
            var end = i + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            const word = code[i..end];
            var style: ?vaxis.Style = null;
            if (isKeyword(lang, word) or c == '@')
                style = Palette.syntax_keyword
            else if (isConstant(word))
                style = Palette.syntax_constant
            else if (isBuiltinType(word) or std.ascii.isUpper(c))
                style = Palette.syntax_type
            else {
                var next = end;
                while (next < code.len and (code[next] == ' ' or code[next] == '\t')) next += 1;
                if (next < code.len and code[next] == '(') style = Palette.syntax_function;
            }
            if (style) |token_style| try appendSyntaxSpan(arena, &spans, i, end, offset, token_style);
            i = end;
            continue;
        }
        i += 1;
    }
    return spans.items;
}

fn isUrlStart(text: []const u8, at: usize) bool {
    return std.mem.startsWith(u8, text[at..], "https://") or
        std.mem.startsWith(u8, text[at..], "http://");
}

fn isUrlTerminator(c: u8) bool {
    return c <= ' ' or c == '<' or c == '>' or c == '"' or c == '\'' or c == '`';
}

fn countByte(text: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (text) |c| if (c == needle) {
        count += 1;
    };
    return count;
}

/// End of a plain http(s) URL, excluding prose/Markdown punctuation.
fn urlEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and !isUrlTerminator(text[end])) end += 1;

    // Sentence punctuation is almost never intended to be part of a URL.
    while (end > start and std.mem.indexOfScalar(u8, ".,;:!?", text[end - 1]) != null) end -= 1;

    // Keep balanced delimiters inside URLs, but drop unmatched prose or
    // Markdown closers: `(https://example.test/foo)` -> URL without final `)`.
    const pairs = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };
    inline for (pairs) |pair| {
        while (end > start and text[end - 1] == pair[1] and
            countByte(text[start..end], pair[1]) > countByte(text[start..end], pair[0]))
        {
            end -= 1;
        }
    }
    return end;
}

/// Find visible spans that should carry OSC 8 metadata. Markdown stays
/// visible for now, but both its label and destination become clickable.
fn findLinkSpans(arena: std.mem.Allocator, text: []const u8) ![]const LinkSpan {
    var spans: std.ArrayList(LinkSpan) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') {
            if (std.mem.indexOfPos(u8, text, i + 1, "](")) |label_end| {
                const uri_start = label_end + 2;
                if (uri_start < text.len and isUrlStart(text, uri_start)) {
                    const uri_end = urlEnd(text, uri_start);
                    if (uri_end > uri_start and uri_end < text.len and text[uri_end] == ')') {
                        const uri = text[uri_start..uri_end];
                        if (label_end > i + 1) try spans.append(arena, .{
                            .start = i + 1,
                            .end = label_end,
                            .uri = uri,
                        });
                        try spans.append(arena, .{
                            .start = uri_start,
                            .end = uri_end,
                            .uri = uri,
                        });
                        i = uri_end + 1;
                        continue;
                    }
                }
            }
        }

        if (isUrlStart(text, i)) {
            const end = urlEnd(text, i);
            if (end > i) try spans.append(arena, .{ .start = i, .end = end, .uri = text[i..end] });
            i = @max(end, i + 1);
            continue;
        }
        i += 1;
    }
    return spans.items;
}

/// Intersect source-text links with one hard-wrapped chunk. Each resulting
/// span keeps the full URI even when only part of its label/URL is visible.
fn linksForChunk(
    arena: std.mem.Allocator,
    source_links: []const LinkSpan,
    chunk_start: usize,
    chunk_end: usize,
    prefix_len: usize,
) ![]const LinkSpan {
    var spans: std.ArrayList(LinkSpan) = .empty;
    for (source_links) |link| {
        const start = @max(link.start, chunk_start);
        const end = @min(link.end, chunk_end);
        if (start < end) try spans.append(arena, .{
            .start = prefix_len + start - chunk_start,
            .end = prefix_len + end - chunk_start,
            .uri = link.uri,
        });
    }
    return spans.items;
}

fn resolveLineLinks(arena: std.mem.Allocator, lines: []Line) !void {
    for (lines) |*line| {
        if (line.links_resolved) continue;
        const text = try lineText(arena, line.*);
        line.links = try findLinkSpans(arena, text);
        line.links_resolved = true;
    }
}

fn linkForBytes(links: []const LinkSpan, start: usize, end: usize) ?[]const u8 {
    for (links) |link| {
        if (start < link.end and end > link.start) return link.uri;
    }
    return null;
}

fn syntaxForBytes(spans: []const SyntaxSpan, start: usize, end: usize) ?vaxis.Style {
    for (spans) |span| {
        if (start < span.end and end > span.start) return span.style;
    }
    return null;
}

/// Overlay only syntax foreground/attributes. In particular, never replace
/// the add/delete background already present on the rendered cell.
fn applyLineSyntax(win: vaxis.Window, row: u16, line: Line) void {
    if (line.syntax.len == 0) return;
    const parts = [_][]const u8{ line.text, line.text2, line.text3 };
    var byte_offset: usize = 0;
    var col: usize = 0;
    for (parts) |part| {
        var part_offset: usize = 0;
        var it = vaxis.unicode.graphemeIterator(part);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(part);
            const start = byte_offset + part_offset;
            const end = start + bytes.len;
            const cell_width: usize = @intCast(win.gwidth(bytes));
            if (syntaxForBytes(line.syntax, start, end)) |style| {
                if (col < @as(usize, win.width)) {
                    if (win.readCell(@intCast(col), row)) |cell| {
                        var highlighted = cell;
                        highlighted.style.fg = style.fg;
                        highlighted.style.bold = style.bold;
                        highlighted.style.dim = style.dim;
                        highlighted.style.italic = style.italic;
                        highlighted.style.strikethrough = style.strikethrough;
                        win.writeCell(@intCast(col), row, highlighted);
                    }
                }
            }
            part_offset += bytes.len;
            col += cell_width;
        }
        byte_offset += part.len;
    }
}

/// Attach OSC 8 metadata after styled segments have been painted. This keeps
/// syntax colors and selection independent from the link parser.
fn applyLineLinks(win: vaxis.Window, row: u16, line: Line) void {
    if (line.links.len == 0) return;
    const parts = [_][]const u8{ line.text, line.text2, line.text3 };
    var byte_offset: usize = 0;
    var col: usize = 0;
    for (parts) |part| {
        var part_offset: usize = 0;
        var it = vaxis.unicode.graphemeIterator(part);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(part);
            const start = byte_offset + part_offset;
            const end = start + bytes.len;
            const cell_width: usize = @intCast(win.gwidth(bytes));
            if (linkForBytes(line.links, start, end)) |uri| {
                if (col < @as(usize, win.width)) {
                    if (win.readCell(@intCast(col), row)) |cell| {
                        var linked = cell;
                        linked.link = .{ .uri = uri };
                        linked.style.fg = .{ .index = 6 }; // cyan
                        linked.style.ul_style = .single;
                        win.writeCell(@intCast(col), row, linked);
                    }
                }
            }
            part_offset += bytes.len;
            col += cell_width;
        }
        byte_offset += part.len;
    }
}

/// Append every complete grapheme intersecting [start_col, end_col).
fn appendColumns(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    win: vaxis.Window,
    text: []const u8,
    start_col: usize,
    end_col: usize,
) !void {
    var it = vaxis.unicode.graphemeIterator(text);
    var col: usize = 0;
    while (it.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const next = col + @as(usize, win.gwidth(bytes));
        if (next > start_col and col < end_col) try out.appendSlice(arena, bytes);
        col = next;
        if (col >= end_col) break;
    }
}

fn selectedText(
    arena: std.mem.Allocator,
    win: vaxis.Window,
    lines: []const Line,
    selection: Selection,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (selection.lo.line >= lines.len) return out.items;
    const last = @min(selection.hi.line, lines.len - 1);
    var line_idx = selection.lo.line;
    while (line_idx <= last) : (line_idx += 1) {
        if (line_idx > selection.lo.line) try out.append(arena, '\n');
        const line = lines[line_idx];
        const text = try lineText(arena, line);
        const cols = selection.columns(line_idx, lineWidth(win, line)) orelse continue;
        try appendColumns(arena, &out, win, text, cols.start, cols.end);
    }
    return out.items;
}

fn wrapPromptCard(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    text: []const u8,
    width: usize,
) !void {
    const first_prefix = " ❯ ";
    const continuation = "   ";
    const prefix_cells: usize = 3;
    const body_width = width -| (prefix_cells + 1); // keep right padding
    if (body_width < 8) return;

    try lines.append(arena, .{ .text = "", .style = Palette.prompt_text, .fill_style = Palette.prompt_panel });
    var first = true;
    var logical = std.mem.splitScalar(u8, text, '\n');
    while (logical.next()) |raw_line| {
        const source_links = try findLinkSpans(arena, raw_line);
        var rest = raw_line;
        while (true) {
            const take = @min(rest.len, body_width);
            const chunk_start = raw_line.len - rest.len;
            const prefix = if (first) first_prefix else continuation;
            const links = try linksForChunk(
                arena,
                source_links,
                chunk_start,
                chunk_start + take,
                prefix.len,
            );
            try lines.append(arena, .{
                .text = prefix,
                .style = if (first) Palette.prompt_mark else Palette.prompt_text,
                .text2 = rest[0..take],
                .style2 = Palette.prompt_text,
                .fill_style = Palette.prompt_panel,
                .links = links,
                .links_resolved = true,
            });
            first = false;
            if (take == rest.len) break;
            rest = rest[take..];
        }
    }
    try lines.append(arena, .{ .text = "", .style = Palette.prompt_text, .fill_style = Palette.prompt_panel });
}

/// Flatten blocks + delta into wrapped display lines for a given width.
/// Returned list and its line slices use `arena` (per-frame).
fn layoutLines(arena: std.mem.Allocator, app: *App, width: u16) !std.ArrayList(Line) {
    var lines: std.ArrayList(Line) = .empty;
    const w: usize = if (width == 0) 80 else width;

    for (app.blocks.items) |rb| {
        switch (rb.kind) {
            .user_msg => {
                try blankLine(arena, &lines);
                try wrapPromptCard(arena, &lines, rb.text, w);
            },
            .assistant_msg => {
                try blankLine(arena, &lines);
                try wrapPrefixed(arena, &lines, "", rb.text, Palette.assistant, w);
            },
            .reasoning => try wrapPrefixed(arena, &lines, "· ", rb.text, Palette.reasoning, w),
            .tool_call => {
                // "⚙ bash " dim + the command bright + trailing args dim.
                // For file tools the highlighted part is the path.
                const hi = extractHighlightArg(rb.label, rb.text);
                const head = try std.fmt.allocPrint(arena, "⚙ {s} ", .{rb.label});
                if (hi) |h| {
                    const hi_capped = h[0..@min(h.len, w -| (head.len + 2))];
                    try lines.append(arena, .{
                        .text = head,
                        .style = Palette.tool,
                        .text2 = hi_capped,
                        .style2 = Palette.tool_cmd,
                    });
                } else {
                    const preview_len = @min(rb.text.len, @min(w -| (rb.label.len + 4), 120));
                    try lines.append(arena, .{
                        .text = head,
                        .style = Palette.tool,
                        .text2 = rb.text[0..preview_len],
                        .style2 = Palette.tool,
                    });
                }
            },
            .tool_result => {
                const base_style = if (rb.status == .ok) Palette.tool_out else Palette.tool_err;
                const glyph: []const u8 = switch (rb.status) {
                    .ok => "  ",
                    .err => "  ✗ ",
                    .denied => "  ⊘ ",
                    .interrupted => "  ⏹ ",
                };
                // Collapsed: show at most 8 lines — but a diff hunk shows
                // whole (up to 24) because a truncated diff misleads.
                const is_diff = std.mem.indexOf(u8, rb.text, "\n@@ ") != null or std.mem.startsWith(u8, rb.text, "@@ ");
                const max_shown: usize = if (is_diff) 24 else 8;
                const language = if (is_diff) diffLanguage(rb.text) else SyntaxLanguage.generic;
                var shown: usize = 0;
                var total: usize = 0;
                var it = std.mem.splitScalar(u8, rb.text, '\n');
                while (it.next()) |l| {
                    total += 1;
                    if (shown < max_shown) {
                        if (rb.status == .ok and is_diff) {
                            try appendDiffLine(arena, &lines, glyph, l, language, base_style);
                        } else {
                            const prefixed = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, l });
                            try lines.append(arena, .{ .text = prefixed, .style = base_style });
                        }
                        shown += 1;
                    }
                }
                if (total > shown) {
                    const more = try std.fmt.allocPrint(arena, "  … {d} more lines", .{total - shown});
                    try lines.append(arena, .{ .text = more, .style = Palette.tool_out });
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
        const loading = try std.fmt.allocPrint(arena, "{s} Working…", .{
            spinner_frames[app.spinner_frame % spinner_frames.len],
        });
        try wrapInto(arena, &lines, loading, .{ .text = loading, .style = Palette.tool_out });
    }

    // Approval card.
    if (app.pending) |*p| {
        try blankLine(arena, &lines);
        const card = try std.fmt.allocPrint(arena, "⚠ approve {s} {s} ?  [y]es / [n]o", .{ p.tool(), p.args() });
        try wrapPrefixed(arena, &lines, "", card, Palette.approval_card, w);
    }
    try resolveLineLinks(arena, lines.items);
    return lines;
}

fn blankLine(arena: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    try lines.append(arena, .{ .text = "", .style = .{} });
}

/// The one argument worth reading in a tool call: bash's command, file
/// tools' path, grep/glob's pattern, fetch's url. Returns a slice into
/// args_json (JSON-escaped — good enough for a one-line preview; commands
/// with heavy escaping still show faithfully enough to recognize).
fn extractHighlightArg(tool_name: []const u8, args_json: []const u8) ?[]const u8 {
    const key: []const u8 = if (std.mem.eql(u8, tool_name, "bash"))
        "command"
    else if (std.mem.eql(u8, tool_name, "grep") or std.mem.eql(u8, tool_name, "glob"))
        "pattern"
    else if (std.mem.eql(u8, tool_name, "fetch"))
        "url"
    else if (std.mem.eql(u8, tool_name, "read_file") or
        std.mem.eql(u8, tool_name, "write_file") or
        std.mem.eql(u8, tool_name, "edit"))
        "path"
    else
        return null;
    return extractJsonStringRaw(args_json, key);
}

/// Find "key":"..." and return the raw (still-escaped) string contents.
fn extractJsonStringRaw(json: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [32]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\":", .{key}) catch return null;
    var at = std.mem.indexOf(u8, json, needle) orelse return null;
    at += needle.len;
    while (at < json.len and (json[at] == ' ' or json[at] == '\t')) at += 1;
    if (at >= json.len or json[at] != '"') return null;
    at += 1;
    var end = at;
    while (end < json.len) : (end += 1) {
        if (json[end] == '\\') {
            end += 1;
            continue;
        }
        if (json[end] == '"') break;
    }
    if (end > json.len) return null;
    return json[at..end];
}

fn hunkContextStart(line: []const u8) ?usize {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const close = std.mem.indexOfPos(u8, line, 2, "@@") orelse return null;
    var start = close + 2;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    return if (start < line.len) start else null;
}

/// Turn a raw unified-diff line into a gutter + code row. Changed rows carry
/// a subtle full-width surface; syntax is an independent foreground overlay.
fn appendDiffLine(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    glyph: []const u8,
    line: []const u8,
    language: SyntaxLanguage,
    fallback_style: vaxis.Style,
) !void {
    if (std.mem.startsWith(u8, line, "@@ ")) {
        const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, line });
        const syntax = if (hunkContextStart(line)) |start|
            try syntaxSpans(arena, line[start..], language, glyph.len + start)
        else
            &.{};
        try lines.append(arena, .{ .text = text, .style = Palette.diff_hunk, .syntax = syntax });
        return;
    }

    const is_add = std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++");
    const is_del = std.mem.startsWith(u8, line, "-") and !std.mem.startsWith(u8, line, "---");
    const is_context = std.mem.startsWith(u8, line, " ");
    if (is_add or is_del or is_context) {
        const gutter = try std.fmt.allocPrint(arena, "{s}{c}", .{ glyph, line[0] });
        const code = line[1..];
        const code_style = if (is_add)
            Palette.diff_add_code
        else if (is_del)
            Palette.diff_del_code
        else
            Palette.diff_context;
        const marker_style = if (is_add)
            Palette.diff_add
        else if (is_del)
            Palette.diff_del
        else
            Palette.diff_context;
        const syntax = try syntaxSpans(arena, code, language, gutter.len);
        try lines.append(arena, .{
            .text = gutter,
            .style = marker_style,
            .text2 = code,
            .style2 = code_style,
            .fill_style = if (is_add or is_del) code_style else null,
            .syntax = syntax,
        });
        return;
    }

    const text = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, line });
    try lines.append(arena, .{ .text = text, .style = fallback_style });
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
        const source_links = try findLinkSpans(arena, raw_line);
        var rest = raw_line;
        while (true) {
            const take = @min(rest.len, body_width);
            const chunk_start = raw_line.len - rest.len;
            const chunk = rest[0..take];
            const has_prefix = first and prefix.len > 0;
            const full = if (has_prefix)
                try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix, chunk })
            else if (prefix.len > 0)
                try std.fmt.allocPrint(arena, "{s}{s}", .{ " " ** 0, chunk }) // continuation, no prefix
            else
                chunk;
            const links = try linksForChunk(
                arena,
                source_links,
                chunk_start,
                chunk_start + take,
                if (has_prefix) prefix.len else 0,
            );
            try lines.append(arena, .{
                .text = full,
                .style = style,
                .links = links,
                .links_resolved = true,
            });
            first = false;
            if (take == rest.len) break;
            rest = rest[take..];
        }
        if (raw_line.len == 0) try lines.append(arena, .{ .text = "", .style = style });
    }
}

fn inputPanelHeight(content_height: usize) usize {
    return content_height + 2; // one blank row above and below the editor
}

fn draw(app: *App, vx: *vaxis.Vaxis, arena: std.mem.Allocator) !void {
    const win = vx.window();
    win.clear();
    const h = win.height;
    const w = win.width;
    if (h < 4 or w < 20) return;

    // The composer is a three-row panel for a one-line prompt (padding,
    // content, padding) and grows with multiline input.
    const prompt: []const u8 = if (app.mode == .insert) "❯ " else ": ";
    const panel_inner_w = w -| 2; // one cell of horizontal padding
    const content_h: u16 = @intCast(app.editor.displayHeight(panel_inner_w -| 2));
    const input_h: u16 = @intCast(inputPanelHeight(content_h));
    const input_gap: u16 = 1;
    const view_h: u16 = h -| (input_h + input_gap + 1); // input + gap + status

    // ---- session view ----
    var lines = try layoutLines(arena, app, w);
    const total = lines.items.len;
    // Anchor while reading: scroll_up counts from the BOTTOM, so content
    // arriving while scrolled up would slide the view. Compensate by the
    // growth delta; pinned (scroll_up == 0) stays pinned.
    if (app.scroll_up > 0 and total > app.last_total_lines) {
        app.scroll_up +|= total - app.last_total_lines;
    }
    app.last_total_lines = total;
    const max_scroll = total -| view_h;
    if (app.scroll_up > max_scroll) app.scroll_up = max_scroll;
    const first_visible = (total -| view_h) -| app.scroll_up;
    app.last_first_visible = first_visible;
    app.last_view_h = view_h;
    const visible = lines.items[first_visible..@min(first_visible + view_h, total)];

    for (visible, 0..) |ln, row| {
        const abs_line = first_visible + row;
        if (ln.fill_style) |fill_style| {
            const row_win = win.child(.{
                .y_off = @intCast(row),
                .height = 1,
                .width = w,
            });
            row_win.fill(.{ .style = fill_style });
        }
        var segs_buf: [3]vaxis.Segment = undefined;
        var n: usize = 0;
        segs_buf[n] = .{ .text = ln.text, .style = ln.style };
        n += 1;
        if (ln.text2.len > 0) {
            segs_buf[n] = .{ .text = ln.text2, .style = ln.style2 };
            n += 1;
        }
        if (ln.text3.len > 0) {
            segs_buf[n] = .{ .text = ln.text3, .style = ln.style3 };
            n += 1;
        }
        _ = win.print(segs_buf[0..n], .{
            .row_offset = @intCast(row),
            .wrap = .none,
        });
        applyLineSyntax(win, @intCast(row), ln);
        applyLineLinks(win, @intCast(row), ln);
        // Apply selection after printing so partial-cell highlighting keeps
        // each segment's original syntax color and other style attributes.
        if (app.selection()) |sel| {
            if (sel.columns(abs_line, lineWidth(win, ln))) |cols| {
                var col = cols.start;
                while (col < cols.end and col < @as(usize, w)) : (col += 1) {
                    const cell = win.readCell(@intCast(col), @intCast(row)) orelse continue;
                    var selected_cell = cell;
                    selected_cell.style.reverse = true;
                    win.writeCell(@intCast(col), @intCast(row), selected_cell);
                }
            }
        }
    }

    // ---- input box ----
    const input_panel = win.child(.{ .y_off = h - 1 - input_h, .height = input_h, .width = w });
    input_panel.fill(.{ .style = Palette.prompt_panel });
    const input_win = input_panel.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = panel_inner_w,
        .height = content_h,
    });
    app.editor.draw(input_win, prompt, Palette.prompt_mark, Palette.prompt_text);
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
    const state_style: vaxis.Style = switch (app.state) {
        .idle, .done => Palette.status_idle,
        .running => Palette.status_running,
        .awaiting_approval => Palette.status_approval,
        .err => Palette.status_error,
    };
    const context_percent = if (app.context_limit > 0)
        app.context_used * 100 / app.context_limit
    else
        0;
    const ctx_txt = try std.fmt.allocPrint(arena, "ctx {d}%", .{context_percent});
    const ctx_style = if (context_percent >= 90)
        Palette.status_context_hot
    else if (context_percent >= 70)
        Palette.status_context_warn
    else
        Palette.status_context;
    const cwd_txt = try statusCwd(arena, app.cwd.items, app.home.items);
    const session_txt = try std.fmt.allocPrint(arena, "#{x:0>4}", .{app.sid & 0xFFFF});
    const scroll_txt = try std.fmt.allocPrint(arena, "↕ {d} (G: bottom)", .{app.scroll_up});

    // Session tag: last 4 hex digits of the id — enough to tell sessions
    // apart in `marlin ls` (which shows the same suffix) without eating
    // half the status bar with a u64.
    var status_segments: [19]vaxis.Segment = undefined;
    var status_n: usize = 0;
    status_segments[status_n] = .{ .text = " ", .style = Palette.status_bar };
    status_n += 1;
    status_segments[status_n] = .{ .text = state_txt, .style = state_style };
    status_n += 1;
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = statusModel(app.model.items), .style = Palette.status_model };
    status_n += 1;
    if (app.context_limit > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = ctx_txt, .style = ctx_style };
        status_n += 1;
    }
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = cwd_txt, .style = Palette.status_cwd };
    status_n += 1;
    if (app.scroll_up > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = scroll_txt, .style = Palette.status_bar };
        status_n += 1;
    }
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = session_txt, .style = Palette.status_sep };
    status_n += 1;
    if (app.notice.items.len > 0) {
        status_segments[status_n] = .{ .text = "  ", .style = Palette.status_bar };
        status_n += 1;
        status_segments[status_n] = .{ .text = app.notice.items, .style = Palette.status_notice };
        status_n += 1;
    }
    _ = status_win.print(status_segments[0..status_n], .{ .wrap = .none });

    // ---- model picker overlay ----
    if (app.picker) |sel| {
        const items = try app.pickerItems(arena);
        const total_src = app.pickerSource().len;

        var widest: u16 = 30;
        for (items) |f| widest = @max(widest, @as(u16, @intCast(@min(f.len, 70))));
        const box_w: u16 = @min(widest + 8, w -| 4);
        const list_max: u16 = @min(@as(u16, 14), h -| 6);
        const shown: u16 = @intCast(@min(items.len, list_max));
        const box_h: u16 = shown + 3; // filter line + list + hint line
        const px: i17 = @intCast((w -| box_w) / 2);
        const py: i17 = @intCast((h -| box_h) / 2);
        const box = win.child(.{
            .x_off = px,
            .y_off = py,
            .width = box_w,
            .height = box_h,
            .border = .{ .where = .all, .style = Palette.tool },
        });
        box.fill(.{ .style = .{} });

        // Filter line (acts as a mini prompt).
        const src_note: []const u8 = if (app.catalog.items.len == 0) " (favorites — catalog loading…)" else "";
        const fline = try std.fmt.allocPrint(arena, " filter: {s}▏{s}", .{ app.picker_filter.items, src_note });
        _ = box.printSegment(.{ .text = fline, .style = Palette.user }, .{ .wrap = .none });

        // Windowed list around the selection.
        const win_start = if (sel >= list_max) sel + 1 - list_max else 0;
        var row: u16 = 1;
        var i: usize = win_start;
        while (i < items.len and row <= shown) : (i += 1) {
            const f = items[i];
            const cur = std.mem.eql(u8, f, app.model.items);
            const line = try std.fmt.allocPrint(arena, " {s}{s}", .{ f[0..@min(f.len, box_w -| 4)], if (cur) " ●" else "" });
            const style: vaxis.Style = if (i == sel)
                .{ .fg = .{ .index = 6 }, .bold = true, .reverse = true }
            else if (cur)
                .{ .fg = .{ .index = 6 } }
            else
                .{};
            _ = box.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .wrap = .none });
            row += 1;
        }
        const hint = try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter · Esc", .{ items.len, total_src });
        _ = box.printSegment(.{ .text = hint, .style = Palette.tool_out }, .{ .row_offset = shown + 1, .wrap = .none });
    }
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

fn animationThread(app: *App, loop: *vaxis.Loop(Event)) void {
    while (!app.animation_stop.load(.acquire)) {
        if (app.animation_active.load(.acquire)) {
            loop.postEvent(.tick) catch return;
            app.io.sleep(.fromMilliseconds(90), .awake) catch {};
        } else {
            app.io.sleep(.fromMilliseconds(200), .awake) catch {};
        }
    }
}

pub const RebootPlan = struct {
    request: RebootRequest = .none,
    sid: u64 = 0,
};

/// First-run bootstrap: prompt for an OpenRouter key on plain stdio (before
/// any TUI), store it in ~/.config/marlin/credentials (0600), and inject it
/// into this process's environ so the autostarted daemon inherits it.
/// Returns false when the user gave nothing usable.
fn bootstrapKey(gpa: std.mem.Allocator, io: Io, environ: *std.process.Environ.Map) !bool {
    var obuf: [1024]u8 = undefined;
    var ow: Io.File.Writer = .init(.stderr(), io, &obuf);
    try ow.interface.print(
        \\marlin needs a provider to talk to.
        \\
        \\  OpenRouter (one key, every model): https://openrouter.ai/keys
        \\  (or set MARLIN_LOCAL_BASE_URL for any OpenAI-compatible endpoint)
        \\
        \\Paste your OpenRouter API key (stored in ~/.config/marlin/credentials,
        \\chmod 600; the env var OPENROUTER_API_KEY always overrides): 
    , .{});
    try ow.interface.flush();

    var ibuf: [512]u8 = undefined;
    var reader: Io.File.Reader = .init(.stdin(), io, &ibuf);
    const line = reader.interface.takeDelimiterExclusive('\n') catch {
        try ow.interface.print("\nno input — aborting.\n", .{});
        try ow.interface.flush();
        return false;
    };
    const key = std.mem.trim(u8, line, " \t\r\n");
    if (key.len < 8) {
        try ow.interface.print("that doesn't look like a key — aborting.\n", .{});
        try ow.interface.flush();
        return false;
    }
    try credentials.store(gpa, io, environ, "OPENROUTER_API_KEY", key);
    try environ.put(
        try environ.allocator.dupe(u8, "OPENROUTER_API_KEY"),
        try environ.allocator.dupe(u8, key),
    );
    try ow.interface.print("saved. starting marlin…\n", .{});
    try ow.interface.flush();
    return true;
}

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    self_exe: []const u8,
    sid_arg: ?u64,
    reboot_out: ?*RebootPlan,
) !u8 {
    // -- first-run bootstrap: no provider key → prompt before the TUI --
    if (environ.get("OPENROUTER_API_KEY") == null and environ.get("MARLIN_LOCAL_BASE_URL") == null) {
        if (!try bootstrapKey(gpa, io, environ)) return 1;
    }

    // -- connect + pick session BEFORE entering the TUI --
    const conn = attach.connect(gpa, io, environ, self_exe) catch |e| {
        std.log.err("cannot reach daemon: {t}", .{e});
        return 1;
    };
    defer conn.deinit();

    const cfg = config.defaults();
    var model_at_start: []const u8 = cfg.model_default;
    var model_buf: [256]u8 = undefined;
    var cwd_at_start: []const u8 = "";
    var cwd_buf: [4096]u8 = undefined;

    var sid: u64 = 0;
    {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Fetch metadata even for an explicit attach: the session may have
        // been created from another directory (or another client process).
        try conn.send(.{ .session_list = .{} });
        const list = try conn.recvUntil(arena, .session_list_result);
        var selected: ?usize = null;
        if (sid_arg) |requested| {
            sid = requested;
            for (list.sessions, 0..) |session, i| {
                if (session.sid == requested) {
                    selected = i;
                    break;
                }
            }
        } else if (list.sessions.len > 0) {
            sid = list.sessions[0].sid;
            selected = 0;
        }

        if (selected) |i| {
            const m = list.sessions[i].model;
            const model_len = @min(m.len, model_buf.len);
            @memcpy(model_buf[0..model_len], m[0..model_len]);
            model_at_start = model_buf[0..model_len];

            const session_cwd = list.sessions[i].cwd;
            const cwd_len = @min(session_cwd.len, cwd_buf.len);
            @memcpy(cwd_buf[0..cwd_len], session_cwd[0..cwd_len]);
            cwd_at_start = cwd_buf[0..cwd_len];
        } else if (sid_arg == null) {
            const cwd_len = try std.process.currentPath(io, &cwd_buf);
            cwd_at_start = cwd_buf[0..cwd_len];
            try conn.send(.{ .session_create = .{ .cwd = cwd_at_start, .model = cfg.model_default } });
            const created = try conn.recvUntil(arena, .session_created);
            sid = created.sid;
        }
        // Full replay: seq 1 onward.
        try conn.send(.{ .sub = .{ .sid = sid, .from_seq = 1 } });
    }

    var app = App{ .gpa = gpa, .io = io, .conn = conn, .sid = sid, .editor = Editor.init(gpa), .cfg = cfg };
    defer app.deinit();
    app.setModelStr(model_at_start);
    app.setCwdStr(cwd_at_start);
    if (environ.get("HOME")) |home| app.setHomeStr(home);

    // -- vaxis init --
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(io, gpa, environ, .{
        // Doubles as the bracketed-paste allocator: Loop passes it when
        // parsing paste bodies into .paste events.
        .system_clipboard_allocator = gpa,
    });
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.setBracketedPaste(writer, true);
    // Mouse: wheel scrolls the session view; native cell-precise selection
    // copies through OSC52. Shift+drag remains the terminal's escape hatch.
    try vx.setMouseMode(writer, true);
    try writer.flush();

    // Initial size: not all paths deliver a winsize event up-front (and a
    // PTY may report late); fetch it directly so the first frame renders.
    {
        var ws = tty.getWinsize() catch vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        if (ws.rows == 0 or ws.cols == 0) ws = .{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
        app.term_cols = ws.cols;
        try vx.resize(gpa, tty.writer(), ws);
    }

    // -- daemon reader thread --
    const rt = try std.Thread.spawn(.{}, readerThread, .{ &app, &loop });
    // Joined at exit: we shutdown() the socket which EOFs the reader —
    // closing the fd under a live read is a BADF panic on the Threaded Io.
    defer rt.join();
    defer conn.stream.shutdown(io, .both) catch {};

    const animation_thread = try std.Thread.spawn(.{}, animationThread, .{ &app, &loop });
    defer animation_thread.join();
    defer app.animation_stop.store(true, .release);

    // First frame before any event arrives.
    {
        var frame_arena = std.heap.ArenaAllocator.init(gpa);
        defer frame_arena.deinit();
        try draw(&app, &vx, frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }

    // -- main event loop --
    while (!app.should_quit) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| try handleKey(&app, key),
            .mouse => |m| handleMouse(&app, m),
            .tick => app.spinner_frame +%= 1,
            .winsize => |ws| {
                app.term_cols = ws.cols;
                try vx.resize(gpa, tty.writer(), ws);
            },
            .paste => |text| {
                app.editor.paste(text);
                gpa.free(@constCast(text));
            },
            .daemon_line => |line| {
                app.handleDaemonLine(line);
                // Drain any additional queued lines before redrawing.
                while (try loop.tryEvent()) |ev2| {
                    switch (ev2) {
                        .daemon_line => |l2| app.handleDaemonLine(l2),
                        .daemon_gone => app.should_quit = true,
                        .key_press => |k2| try handleKey(&app, k2),
                        .mouse => |m2| handleMouse(&app, m2),
                        .tick => app.spinner_frame +%= 1,
                        .winsize => |ws2| {
                            app.term_cols = ws2.cols;
                            try vx.resize(gpa, tty.writer(), ws2);
                        },
                        .paste => |t2| {
                            app.editor.paste(t2);
                            gpa.free(@constCast(t2));
                        },
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

        // Completed mouse selection → OSC52 copy (before draw so the
        // notice shows this frame; selection stays highlighted).
        if (app.copy_pending) {
            app.copy_pending = false;
            if (app.selection()) |selection| {
                const farena = frame_arena.allocator();
                const sel_lines = try layoutLines(farena, &app, @intCast(app.term_cols));
                const text = try selectedText(farena, vx.window(), sel_lines.items, selection);
                if (text.len > 0) {
                    var copied = true;
                    vx.copyToSystemClipboard(writer, text, farena) catch {
                        copied = false;
                    };
                    if (copied)
                        app.setNotice("copied selection", .{})
                    else
                        app.setNotice("clipboard copy failed", .{});
                }
            }
        }

        try draw(&app, &vx, frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }
    if (reboot_out) |ro| ro.* = .{ .request = app.reboot_request, .sid = app.sid };
    return 0;
}

/// Mouse: the wheel ALWAYS scrolls the session view — never the input box,
/// never history. Left press/drag/release selects terminal-cell ranges in
/// the session view; release copies the precise range via OSC52.
fn handleMouse(app: *App, m: vaxis.Mouse) void {
    // Some terminals report the release button as `none`, so complete an
    // active left-button drag based on event type before switching on button.
    if (m.type == .release and app.sel_dragging) {
        if (app.last_view_h > 0) {
            const raw_row: usize = if (m.row < 0) 0 else @intCast(m.row);
            const row = @min(raw_row, app.last_view_h - 1);
            const col: usize = if (m.col < 0) 0 else @intCast(m.col);
            app.sel_head = .{ .line = app.last_first_visible + row, .col = col };
        }
        app.sel_dragging = false;
        if (app.sel_anchor) |anchor| {
            if (anchor.line != app.sel_head.line or anchor.col != app.sel_head.col) {
                app.copy_pending = true;
            } else {
                app.sel_anchor = null;
            }
        }
        return;
    }

    switch (m.button) {
        .wheel_up => app.scroll_up +|= 3,
        .wheel_down => app.scroll_up -|= 3,
        .left => {
            const row: usize = if (m.row < 0) 0 else @intCast(m.row);
            // Only rows inside the session view participate.
            if (row >= app.last_view_h) {
                if (m.type == .press) app.sel_anchor = null; // click below view clears
                return;
            }
            const point = SelectionPoint{
                .line = app.last_first_visible + row,
                .col = if (m.col < 0) 0 else @intCast(m.col),
            };
            switch (m.type) {
                .press => {
                    app.sel_anchor = point;
                    app.sel_head = point;
                    app.sel_dragging = true;
                },
                .drag => {
                    if (app.sel_dragging) app.sel_head = point;
                },
                .release => {}, // active drags are completed above
                .motion => {},
            }
        },
        else => {},
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn isNewlineKey(key: vaxis.Key) bool {
    // Key.matches intentionally consumes Shift for printable text, which
    // could make plain Enter look shifted when a terminal attaches text to
    // control keys. Modifier-sensitive Enter handling must be exact.
    return (key.codepoint == vaxis.Key.enter and (key.mods.shift or key.mods.alt)) or
        (key.codepoint == 'j' and key.mods.ctrl and !key.mods.alt);
}

/// Common readline bindings plus their native terminal-key equivalents. Keep
/// this translation separate from Editor so key compatibility can be tested
/// without constructing a complete TUI App.
const EditCommand = enum {
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    delete_before,
    delete_after,
    delete_word_before,
    delete_word_before_whitespace,
    delete_word_after,
    delete_to_line_start,
    delete_to_line_end,
};

fn editCommand(key: vaxis.Key) ?EditCommand {
    if (key.matches(vaxis.Key.left, .{ .alt = true }) or key.matches('b', .{ .alt = true }))
        return .move_word_left;
    if (key.matches(vaxis.Key.right, .{ .alt = true }) or key.matches('f', .{ .alt = true }))
        return .move_word_right;
    if (key.matches(vaxis.Key.left, .{}) or key.matches('b', .{ .ctrl = true }))
        return .move_left;
    if (key.matches(vaxis.Key.right, .{}) or key.matches('f', .{ .ctrl = true }))
        return .move_right;
    if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true }))
        return .move_line_start;
    if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true }))
        return .move_line_end;
    if (key.matches(vaxis.Key.backspace, .{ .alt = true }))
        return .delete_word_before;
    if (key.matches(vaxis.Key.delete, .{ .alt = true }) or key.matches('d', .{ .alt = true }))
        return .delete_word_after;
    if (key.matches(vaxis.Key.backspace, .{}) or key.matches('h', .{ .ctrl = true }))
        return .delete_before;
    if (key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true }))
        return .delete_after;
    if (key.matches('k', .{ .ctrl = true }))
        return .delete_to_line_end;
    if (key.matches('u', .{ .ctrl = true }))
        return .delete_to_line_start;
    if (key.matches('w', .{ .ctrl = true }))
        return .delete_word_before_whitespace;
    return null;
}

fn isPreviousInputRowKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true });
}

fn isNextInputRowKey(key: vaxis.Key) bool {
    return key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true });
}

fn applyEditCommand(ed: *Editor, command: EditCommand) void {
    switch (command) {
        .move_left => ed.moveLeft(),
        .move_right => ed.moveRight(),
        .move_word_left => ed.moveWordLeft(),
        .move_word_right => ed.moveWordRight(),
        .move_line_start => ed.moveLineStart(),
        .move_line_end => ed.moveLineEnd(),
        .delete_before => ed.deleteBefore(),
        .delete_after => ed.deleteAfter(),
        .delete_word_before => ed.deleteWordBefore(),
        .delete_word_before_whitespace => ed.deleteWordBeforeWhitespace(),
        .delete_word_after => ed.deleteWordAfter(),
        .delete_to_line_start => ed.deleteToLineStart(),
        .delete_to_line_end => ed.deleteToLineEnd(),
    }
}

fn handleKey(app: *App, key: vaxis.Key) !void {
    // Ctrl+C: interrupt a running turn; quit when idle.
    if (key.matches('c', .{ .ctrl = true })) {
        if (app.state == .running or app.state == .awaiting_approval) {
            app.interrupt();
        } else {
            app.should_quit = true;
        }
        return;
    }

    // Model picker overlay swallows all keys while open. Typing filters;
    // Up/Down or Ctrl+n/p navigate; Enter applies; Esc closes.
    if (app.picker) |sel| {
        if (key.matches(vaxis.Key.escape, .{})) {
            app.picker = null;
            app.picker_filter.clearRetainingCapacity();
            return;
        }
        // Count filtered items to clamp navigation (cheap stack arena).
        var fb: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&fb);
        const items = app.pickerItems(fba.allocator()) catch app.pickerSource();
        const n = items.len;

        if (key.matches(vaxis.Key.enter, .{})) {
            if (n > 0) {
                const pick = items[@min(sel, n - 1)];
                app.picker = null;
                app.applyModel(pick);
                app.picker_filter.clearRetainingCapacity();
            }
        } else if (key.matches(vaxis.Key.down, .{}) or key.matches('n', .{ .ctrl = true })) {
            if (n > 0) app.picker = if (sel + 1 < n) sel + 1 else 0;
        } else if (key.matches(vaxis.Key.up, .{}) or key.matches('p', .{ .ctrl = true })) {
            if (n > 0) app.picker = if (sel > 0) sel - 1 else n - 1;
        } else if (key.matches(vaxis.Key.backspace, .{})) {
            if (app.picker_filter.items.len > 0) {
                _ = app.picker_filter.pop();
                app.picker = 0;
            }
        } else if (key.text) |txt| {
            if (txt.len > 0 and txt[0] >= 0x20 and txt[0] != 0x7f) {
                app.picker_filter.appendSlice(app.gpa, txt) catch {};
                app.picker = 0;
            }
        }
        return;
    }

    // Approval hotkeys work in both modes when the input is empty.
    if (app.pending != null and app.editor.isEmpty()) {
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
            const ed = &app.editor;
            // Same width draw() gives the editor: terminal minus the prompt.
            const edit_w: usize = app.term_cols -| 2;
            if (key.matches(vaxis.Key.escape, .{})) {
                app.mode = .normal; // draft survives: editor state untouched
                app.sel_anchor = null;
            } else if (isNewlineKey(key)) {
                ed.insertNewline();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const text = try ed.takeExpanded();
                defer app.gpa.free(text);
                app.submitInput(text);
            } else if (isPreviousInputRowKey(key)) {
                if (!ed.moveUp(edit_w)) ed.histUp();
            } else if (isNextInputRowKey(key)) {
                if (!ed.moveDown(edit_w)) ed.histDown();
            } else if (editCommand(key)) |command| {
                applyEditCommand(ed, command);
            } else if (key.text) |text| {
                ed.insertSlice(text);
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

test {
    std.testing.refAllDecls(@This());
}

test "modified enter inserts a newline while plain enter submits" {
    try std.testing.expect(isNewlineKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true } }));
    try std.testing.expect(isNewlineKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .alt = true } }));
    try std.testing.expect(isNewlineKey(.{ .codepoint = 'j', .mods = .{ .ctrl = true } }));
    try std.testing.expect(!isNewlineKey(.{ .codepoint = vaxis.Key.enter }));
    try std.testing.expect(!isNewlineKey(.{ .codepoint = vaxis.Key.enter, .text = "\r" }));
}

test "standard editor key bindings map to commands" {
    const Case = struct { key: vaxis.Key, command: EditCommand };
    const cases = [_]Case{
        .{ .key = .{ .codepoint = vaxis.Key.left }, .command = .move_left },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .ctrl = true } }, .command = .move_left },
        .{ .key = .{ .codepoint = vaxis.Key.right }, .command = .move_right },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .ctrl = true } }, .command = .move_right },
        .{ .key = .{ .codepoint = vaxis.Key.left, .mods = .{ .alt = true } }, .command = .move_word_left },
        .{ .key = .{ .codepoint = 'b', .mods = .{ .alt = true } }, .command = .move_word_left },
        .{ .key = .{ .codepoint = vaxis.Key.right, .mods = .{ .alt = true } }, .command = .move_word_right },
        .{ .key = .{ .codepoint = 'f', .mods = .{ .alt = true } }, .command = .move_word_right },
        .{ .key = .{ .codepoint = vaxis.Key.home }, .command = .move_line_start },
        .{ .key = .{ .codepoint = 'a', .mods = .{ .ctrl = true } }, .command = .move_line_start },
        .{ .key = .{ .codepoint = vaxis.Key.end }, .command = .move_line_end },
        .{ .key = .{ .codepoint = 'e', .mods = .{ .ctrl = true } }, .command = .move_line_end },
        .{ .key = .{ .codepoint = vaxis.Key.backspace }, .command = .delete_before },
        .{ .key = .{ .codepoint = 'h', .mods = .{ .ctrl = true } }, .command = .delete_before },
        .{ .key = .{ .codepoint = vaxis.Key.delete }, .command = .delete_after },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .ctrl = true } }, .command = .delete_after },
        .{ .key = .{ .codepoint = vaxis.Key.backspace, .mods = .{ .alt = true } }, .command = .delete_word_before },
        .{ .key = .{ .codepoint = 'w', .mods = .{ .ctrl = true } }, .command = .delete_word_before_whitespace },
        .{ .key = .{ .codepoint = vaxis.Key.delete, .mods = .{ .alt = true } }, .command = .delete_word_after },
        .{ .key = .{ .codepoint = 'd', .mods = .{ .alt = true } }, .command = .delete_word_after },
        .{ .key = .{ .codepoint = 'u', .mods = .{ .ctrl = true } }, .command = .delete_to_line_start },
        .{ .key = .{ .codepoint = 'k', .mods = .{ .ctrl = true } }, .command = .delete_to_line_end },
    };
    for (cases) |case| try std.testing.expectEqual(case.command, editCommand(case.key).?);

    try std.testing.expect(isPreviousInputRowKey(.{ .codepoint = vaxis.Key.up }));
    try std.testing.expect(isPreviousInputRowKey(.{ .codepoint = 'p', .mods = .{ .ctrl = true } }));
    try std.testing.expect(isNextInputRowKey(.{ .codepoint = vaxis.Key.down }));
    try std.testing.expect(isNextInputRowKey(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }));
}

test "selection is character precise on one or many lines" {
    const same = Selection.init(.{ .line = 4, .col = 8 }, .{ .line = 4, .col = 2 });
    const same_cols = same.columns(4, 20).?;
    try std.testing.expectEqual(@as(usize, 2), same_cols.start);
    try std.testing.expectEqual(@as(usize, 9), same_cols.end);

    const multi = Selection.init(.{ .line = 2, .col = 3 }, .{ .line = 4, .col = 5 });
    const first = multi.columns(2, 10).?;
    try std.testing.expectEqual(@as(usize, 3), first.start);
    try std.testing.expectEqual(@as(usize, 10), first.end);
    const middle = multi.columns(3, 10).?;
    try std.testing.expectEqual(@as(usize, 0), middle.start);
    try std.testing.expectEqual(@as(usize, 10), middle.end);
    const last = multi.columns(4, 10).?;
    try std.testing.expectEqual(@as(usize, 0), last.start);
    try std.testing.expectEqual(@as(usize, 6), last.end);
    try std.testing.expect(multi.columns(1, 10) == null);
}

test "one-line composer and scrollback prompt cards are three rows" {
    try std.testing.expectEqual(@as(usize, 3), inputPanelHeight(1));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;
    try wrapPromptCard(arena, &lines, "ship it", 80);

    try std.testing.expectEqual(@as(usize, 3), lines.items.len);
    try std.testing.expect(lines.items[0].fill_style != null);
    try std.testing.expectEqualStrings(" ❯ ", lines.items[1].text);
    try std.testing.expectEqualStrings("ship it", lines.items[1].text2);
    try std.testing.expect(lines.items[2].fill_style != null);
}

test "status metadata is compact without losing its identity" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "anthropic/claude-sonnet-4.5",
        statusModel("openrouter/anthropic/claude-sonnet-4.5"),
    );
    try std.testing.expectEqualStrings(
        "~/Work/marlin",
        try statusCwd(arena, "/Users/jespern/Work/marlin", "/Users/jespern"),
    );
    try std.testing.expectEqualStrings(
        "/opt/marlin",
        try statusCwd(arena, "/opt/marlin", "/Users/jespern"),
    );
}

test "diff language comes from edit summaries or git target paths" {
    try std.testing.expectEqual(
        SyntaxLanguage.zig,
        diffLanguage("replaced 1 occurrence(s) in src/client/tui.zig\n@@ -1,2 +1,2 @@"),
    );
    try std.testing.expectEqual(
        SyntaxLanguage.javascript,
        diffLanguage("diff --git a/web/app.ts b/web/app.ts\n--- a/web/app.ts\n+++ b/web/app.ts\n@@ -1 +1 @@"),
    );
    try std.testing.expectEqual(SyntaxLanguage.generic, diffLanguage("@@ -1 +1 @@"));
}

test "diff rows combine subtle surfaces with syntax foregrounds" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var lines: std.ArrayList(Line) = .empty;

    try appendDiffLine(arena, &lines, "  ", "+    const msg = \"hello\";", .zig, Palette.tool_out);
    try appendDiffLine(arena, &lines, "  ", "@@ -4,1 +4,1 @@ pub fn greet() void {", .zig, Palette.tool_out);
    try std.testing.expectEqual(@as(usize, 2), lines.items.len);

    const added = lines.items[0];
    try std.testing.expectEqualStrings("  +", added.text);
    try std.testing.expectEqualStrings("    const msg = \"hello\";", added.text2);
    try std.testing.expect(added.fill_style != null);
    try std.testing.expect(vaxis.Color.eql(added.fill_style.?.bg, Palette.diff_add_bg));
    try std.testing.expect(added.syntax.len >= 2); // `const` + string

    const hunk = lines.items[1];
    try std.testing.expect(std.mem.indexOf(u8, hunk.text, "pub fn greet") != null);
    try std.testing.expect(hunk.syntax.len >= 3); // pub + fn + greet

    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 48,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 48,
        .height = 1,
        .screen = &screen,
    };
    win.fill(.{ .style = added.fill_style.? });
    _ = win.print(&.{
        .{ .text = added.text, .style = added.style },
        .{ .text = added.text2, .style = added.style2 },
    }, .{ .wrap = .none });
    applyLineSyntax(win, 0, added);

    // Three gutter cells + four spaces puts the `c` in `const` at column 7.
    const keyword_cell = win.readCell(7, 0).?;
    try std.testing.expect(vaxis.Color.eql(keyword_cell.style.bg, Palette.diff_add_bg));
    try std.testing.expect(vaxis.Color.eql(keyword_cell.style.fg, Palette.syntax_keyword.fg));
}

test "plain and Markdown URLs become safe clickable spans" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "See https://marlin.wtf/docs, then [the repo](https://github.com/jespern/marlin).";
    const spans = try findLinkSpans(arena, text);

    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("https://marlin.wtf/docs", spans[0].uri);
    try std.testing.expectEqualStrings("the repo", text[spans[1].start..spans[1].end]);
    try std.testing.expectEqualStrings("https://github.com/jespern/marlin", spans[1].uri);
    try std.testing.expectEqualStrings(spans[1].uri, spans[2].uri);

    const unsafe = try findLinkSpans(arena, "[nope](javascript:alert(1)) file:///tmp/secret");
    try std.testing.expectEqual(@as(usize, 0), unsafe.len);
}

test "wrapped URL pieces retain the complete OSC 8 destination" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const uri = "https://example.test/really/long/path";
    const text = "see " ++ uri;
    var lines: std.ArrayList(Line) = .empty;
    try wrapPrefixed(arena, &lines, "", text, Palette.assistant, 16);

    var linked_lines: usize = 0;
    for (lines.items) |line| {
        if (line.links.len == 0) continue;
        linked_lines += 1;
        for (line.links) |link| try std.testing.expectEqualStrings(uri, link.uri);
    }
    try std.testing.expect(linked_lines >= 2);
}

test "link spans attach OSC 8 metadata to rendered cells" {
    const gpa = std.testing.allocator;
    var screen = try vaxis.Screen.init(gpa, .{
        .rows = 1,
        .cols = 32,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(gpa);
    const win = vaxis.Window{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = 32,
        .height = 1,
        .screen = &screen,
    };

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const text = "go https://marlin.wtf";
    const line = Line{
        .text = text,
        .style = Palette.assistant,
        .links = try findLinkSpans(arena_state.allocator(), text),
        .links_resolved = true,
    };
    _ = win.printSegment(.{ .text = text }, .{ .wrap = .none });
    applyLineLinks(win, 0, line);

    const linked = win.readCell(3, 0).?;
    try std.testing.expectEqualStrings("https://marlin.wtf", linked.link.uri);
    try std.testing.expectEqual(vaxis.Cell.Style.Underline.single, linked.style.ul_style);
    try std.testing.expectEqualStrings("", win.readCell(0, 0).?.link.uri);
}

test "URL punctuation trimming keeps balanced path delimiters" {
    const text = "https://example.test/wiki/Foo_(bar)).";
    const end = urlEnd(text, 0);
    try std.testing.expectEqualStrings("https://example.test/wiki/Foo_(bar)", text[0..end]);
}

test "durable user block reconciles optimistic local echo" {
    const gpa = std.testing.allocator;
    var rendered = [_]RenderBlock{.{
        .kind = .user_msg,
        .text = try gpa.dupe(u8, "hello"),
        .label = try gpa.dupe(u8, ""),
        .pending_echo = true,
    }};
    defer rendered[0].deinit(gpa);

    try std.testing.expect(reconcilePendingEcho(&rendered, .user_msg, "hello"));
    try std.testing.expect(!rendered[0].pending_echo);
    try std.testing.expect(!reconcilePendingEcho(&rendered, .user_msg, "hello"));
}

test "slash commands enter local editor history" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var app = App{
        .gpa = gpa,
        .io = threaded.io(),
        .conn = undefined, // /help is entirely client-local
        .sid = 1,
        .editor = Editor.init(gpa),
    };
    defer app.deinit();

    app.submitInput("/help");
    try std.testing.expectEqual(@as(usize, 1), app.editor.history.items.len);
    app.editor.histUp();
    try std.testing.expectEqualStrings("/help", app.editor.text.items);
}
