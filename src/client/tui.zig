//! TUI client: libvaxis. Modal (insert/normal), single pane (M2).
//! See docs/ARCHITECTURE.md §8 for the target layout; splits/sidebar/mouse
//! land in M4. This client is a pure protocol consumer: attach.Conn in,
//! blocks out. Deltas are ephemeral; finalized blocks replace them.
//!
//! Layout (M3):
//!   ┌─ session view: blocks, streaming region ─┐
//!   ├─ input box (1-8 lines, grows with content)┤
//!   └─ status: state · model · tokens · ctx ────┤
//!
//! Keys:
//!   insert:  type → input; Enter send; Alt+Enter/Ctrl+J newline;
//!            Up/Down move lines or walk history at the edges;
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
const Editor = @import("editor.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
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
    editor: Editor,

    mode: Mode = .insert,
    /// Terminal columns (updated on every winsize event); used by handleKey
    /// for the editor's vertical-move edge detection so it matches draw().
    term_cols: usize = 80,
    blocks: std.ArrayList(RenderBlock) = .empty,
    delta: std.ArrayList(u8) = .empty,
    state: proto.SessionState = .idle,
    model: std.ArrayList(u8) = .empty,
    tokens_in: u64 = 0,
    tokens_out: u64 = 0,
    context_used: u64 = 0,
    context_limit: u64 = 0,
    /// 0 = pinned to bottom; N = scrolled up N lines.
    scroll_up: usize = 0,
    pending: ?PendingApproval = null,
    /// Transient one-line notice shown in the status bar.
    notice: std.ArrayList(u8) = .empty,
    should_quit: bool = false,
    awaiting_new_session: bool = false,
    /// Set by /reboot: after clean TUI teardown, run() returns this to
    /// cli.zig which execs `marlin reboot [--build] --then attach <sid>`.
    reboot_request: RebootRequest = .none,

    fn deinit(self: *App) void {
        for (self.blocks.items) |*rb| rb.deinit(self.gpa);
        self.blocks.deinit(self.gpa);
        self.delta.deinit(self.gpa);
        self.model.deinit(self.gpa);
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
                self.pushBlock(.user_msg, u.text, "", .ok);
                // Seed input history from the log (replay covers pre-reboot
                // messages; live blocks cover this session's submits).
                self.editor.pushHistory(u.text);
            },
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
        self.context_used = 0;
        self.context_limit = 0;
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
    // Diff lines inside tool output: fg-colored, diff-tool style (never
    // full-line backgrounds).
    const diff_add: vaxis.Style = .{ .fg = .{ .index = 2 } }; // green
    const diff_del: vaxis.Style = .{ .fg = .{ .index = 1 } }; // red
    const diff_hunk: vaxis.Style = .{ .fg = .{ .index = 6 } }; // cyan @@ + decl ctx
    const note: vaxis.Style = .{ .fg = .{ .index = 3 } }; // yellow
    const steer: vaxis.Style = .{ .fg = .{ .index = 5 } }; // magenta
    const status_bar: vaxis.Style = .{ .bg = .{ .index = 0 }, .fg = .{ .index = 7 } };
    const approval_card: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    const delta_style: vaxis.Style = .{};
};

/// One logical display line: 1..3 styled segments (segments never wrap
/// independently; the line is the wrap unit). Slices point into the App's
/// block storage or the frame arena (valid for the frame).
const Line = struct {
    text: []const u8,
    style: vaxis.Style,
    /// Optional second/third segment printed after `text` on the same row.
    text2: []const u8 = "",
    style2: vaxis.Style = .{},
    text3: []const u8 = "",
    style3: vaxis.Style = .{},
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
                var shown: usize = 0;
                var total: usize = 0;
                var it = std.mem.splitScalar(u8, rb.text, '\n');
                while (it.next()) |l| {
                    total += 1;
                    if (shown < max_shown) {
                        const style = if (rb.status == .ok and is_diff) diffLineStyle(l) orelse base_style else base_style;
                        const prefixed = try std.fmt.allocPrint(arena, "{s}{s}", .{ glyph, l });
                        try lines.append(arena, .{ .text = prefixed, .style = style });
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

/// Style for a diff line inside tool output, or null when it isn't one.
/// Conservative: only unambiguous markers, so shell output that happens to
/// start with '-' (flag lists etc.) rarely false-positives — we require the
/// result to contain a hunk header before any of this fires (see caller's
/// is_diff gate for the elision rule; styling itself keys per line).
fn diffLineStyle(l: []const u8) ?vaxis.Style {
    if (std.mem.startsWith(u8, l, "@@ ")) return Palette.diff_hunk;
    if (std.mem.startsWith(u8, l, "+") and !std.mem.startsWith(u8, l, "+++")) return Palette.diff_add;
    if (std.mem.startsWith(u8, l, "-") and !std.mem.startsWith(u8, l, "---")) return Palette.diff_del;
    return null;
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

fn draw(app: *App, vx: *vaxis.Vaxis, arena: std.mem.Allocator) !void {
    const win = vx.window();
    win.clear();
    const h = win.height;
    const w = win.width;
    if (h < 4 or w < 20) return;

    // Input grows 1..max_rows with content; session view yields.
    const prompt: []const u8 = if (app.mode == .insert) "> " else ": ";
    const input_h: u16 = @intCast(app.editor.displayHeight(w -| prompt.len));
    const view_h: u16 = h -| (input_h + 1); // + status line

    // ---- session view ----
    var lines = try layoutLines(arena, app, w);
    const total = lines.items.len;
    const max_scroll = total -| view_h;
    if (app.scroll_up > max_scroll) app.scroll_up = max_scroll;
    const first_visible = (total -| view_h) -| app.scroll_up;
    const visible = lines.items[first_visible..@min(first_visible + view_h, total)];

    for (visible, 0..) |ln, row| {
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
    }

    // ---- input box ----
    const input_win = win.child(.{ .y_off = h - 1 - input_h, .height = input_h, .width = w });
    app.editor.draw(input_win, prompt, Palette.user);
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
    const ctx_txt: []const u8 = if (app.context_limit > 0)
        try std.fmt.allocPrint(arena, " · ctx {d}%", .{app.context_used * 100 / app.context_limit})
    else
        "";
    const status = try std.fmt.allocPrint(arena, " {s} · {s}{s} · s{d}  {s}", .{
        state_txt,
        app.model.items,
        ctx_txt,
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

pub const RebootPlan = struct {
    request: RebootRequest = .none,
    sid: u64 = 0,
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    self_exe: []const u8,
    sid_arg: ?u64,
    reboot_out: ?*RebootPlan,
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

    var app = App{ .gpa = gpa, .io = io, .conn = conn, .sid = sid, .editor = Editor.init(gpa) };
    defer app.deinit();
    app.setModelStr(model_at_start);

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
        try draw(&app, &vx, frame_arena.allocator());
        try vx.render(writer);
        try writer.flush();
    }
    if (reboot_out) |ro| ro.* = .{ .request = app.reboot_request, .sid = app.sid };
    return 0;
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
            } else if (key.matches(vaxis.Key.enter, .{ .alt = true }) or
                key.matches('j', .{ .ctrl = true }))
            {
                ed.insertNewline();
            } else if (key.matches(vaxis.Key.enter, .{})) {
                const text = try ed.takeExpanded();
                defer app.gpa.free(text);
                app.submitInput(text);
            } else if (key.matches(vaxis.Key.up, .{})) {
                if (!ed.moveUp(edit_w)) ed.histUp();
            } else if (key.matches(vaxis.Key.down, .{})) {
                if (!ed.moveDown(edit_w)) ed.histDown();
            } else if (key.matches(vaxis.Key.left, .{}) or key.matches('b', .{ .ctrl = true })) {
                ed.moveLeft();
            } else if (key.matches(vaxis.Key.right, .{}) or key.matches('f', .{ .ctrl = true })) {
                ed.moveRight();
            } else if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true })) {
                ed.moveLineStart();
            } else if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true })) {
                ed.moveLineEnd();
            } else if (key.matches(vaxis.Key.backspace, .{})) {
                ed.deleteBefore();
            } else if (key.matches(vaxis.Key.delete, .{}) or key.matches('d', .{ .ctrl = true })) {
                ed.deleteAfter();
            } else if (key.matches('k', .{ .ctrl = true })) {
                ed.deleteToLineEnd();
            } else if (key.matches('u', .{ .ctrl = true })) {
                ed.deleteToLineStart();
            } else if (key.matches('w', .{ .ctrl = true })) {
                ed.deleteWordBefore();
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
