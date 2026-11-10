//! Drawing the TUI frame: the tab bar, transcript surfaces, plan table,
//! composer, status bar, and overlays. Everything here paints from `App`
//! state; `tui.zig` owns that state and the event loop.

const std = @import("std");
const build_options = @import("build_options");
const vaxis = @import("vaxis");
const proto = @import("../core/proto.zig");
const block = @import("../core/block.zig");
const daybreak = @import("daybreak.zig");
const render = @import("render.zig");
const top_view = @import("top.zig");
const shell_tab = @import("shell_tab.zig");
const layout_mod = @import("layout.zig");
const commands = @import("commands.zig");
const session_view = @import("session_view.zig");
const tui = @import("tui.zig");
const layoutBlockRange = layout_mod.layoutBlockRange;
const Palette = render.Palette;
const Line = render.Line;
const nowWallMs = render.nowWallMs;
const lineWidth = render.lineWidth;
const lineText = render.lineText;
const applyLineSyntax = render.applyLineSyntax;
const applyLineLinks = render.applyLineLinks;
const displayWidth = render.displayWidth;
const hardCellBreak = render.hardCellBreak;
const spaces = render.spaces;
const spinner_frames = render.spinner_frames;
const composer_commands = commands.composer_commands;
const PlanItemOwned = session_view.PlanItemOwned;
const commandQuery = commands.commandQuery;
const commandSuggestions = commands.commandSuggestions;
const transient_animation_frames = tui.transient_animation_frames;
const fast_transient_animation_frames = tui.fast_transient_animation_frames;
const council_done_item = tui.council_done_item;
const SessionSummary = tui.SessionSummary;
const tab_bar_height = tui.tab_bar_height;
const tab_label_max_cells = tui.tab_label_max_cells;
const TabActivity = tui.TabActivity;
const TabLayoutItem = tui.TabLayoutItem;
const TabLayout = tui.TabLayout;
const App = tui.App;
const statusModel = tui.statusModel;
const statusGuestProcess = tui.statusGuestProcess;
const statusContext = tui.statusContext;
const statusLocation = tui.statusLocation;
const transcriptView = tui.transcriptView;
const formatModelPricing = tui.formatModelPricing;
const pickerModelLine = tui.pickerModelLine;
const pickerTextPreview = tui.pickerTextPreview;
const tabActivityForState = tui.tabActivityForState;
const tabActivityText = tui.tabActivityText;
const TabCandidate = tui.TabCandidate;

fn tabLabel(app: *const App, summary: ?*const SessionSummary) []const u8 {
    const identity = if (summary) |session|
        if (session.shell_label.len > 0)
            session.shell_label
        else if (session.title.len > 0)
            session.title
        else if (std.fs.path.basename(session.cwd).len > 0)
            std.fs.path.basename(session.cwd)
        else
            "session"
    else if (std.fs.path.basename(app.view.cwd.items).len > 0)
        std.fs.path.basename(app.view.cwd.items)
    else
        "session";
    return identity[0..hardCellBreak(identity, 0, tab_label_max_cells)];
}

/// Build a chronological, root-only tab window. When the full strip does not
/// fit, retain a contiguous neighborhood around the active root and reserve
/// two cells at either edge for overflow markers.
pub fn layoutTabBar(arena: std.mem.Allocator, app: *const App, width: usize) !TabLayout {
    if (width == 0) return .{ .items = &.{} };

    const active_root = app.rootSessionId(app.view.sid);
    var candidates: std.ArrayList(TabCandidate) = .empty;
    for (app.sessions.items) |*session| {
        if (session.parent_sid != null or session.kind != .root) continue;
        try candidates.append(arena, .{
            .sid = session.sid,
            .label = tabLabel(app, session),
            .activity = app.tabActivity(session.sid),
            .active = session.sid == active_root,
            .shell = session.shell_id != 0,
            .created_at = session.created_at,
        });
    }
    if (candidates.items.len == 0) {
        try candidates.append(arena, .{
            .sid = app.view.sid,
            .label = tabLabel(app, null),
            .activity = if (app.view.pause == .paused) .paused else if (app.unread_completions.contains(app.view.sid)) .done else tabActivityForState(app.view.state),
            .active = true,
            .shell = app.view.shell != null,
            .created_at = 0,
        });
    }
    std.mem.sort(TabCandidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: TabCandidate, b: TabCandidate) bool {
            return a.created_at < b.created_at or (a.created_at == b.created_at and a.sid < b.sid);
        }
    }.lessThan);
    for (candidates.items, 1..) |*candidate, index| candidate.index = index;

    var active_index: usize = 0;
    var total_width: usize = candidates.items.len - 1; // one-cell gaps
    for (candidates.items, 0..) |candidate, i| {
        total_width += candidate.width();
        if (candidate.active) active_index = i;
    }

    var start: usize = 0;
    var end: usize = candidates.items.len;
    if (total_width > width) {
        const budget = width -| 4;
        start = active_index;
        end = active_index + 1;
        var used = @min(candidates.items[active_index].width(), budget);
        while (true) {
            var changed = false;
            if (end < candidates.items.len) {
                const cost = 1 + candidates.items[end].width();
                if (used + cost <= budget) {
                    used += cost;
                    end += 1;
                    changed = true;
                }
            }
            if (start > 0) {
                const cost = 1 + candidates.items[start - 1].width();
                if (used + cost <= budget) {
                    used += cost;
                    start -= 1;
                    changed = true;
                }
            }
            if (!changed) break;
        }
    }

    const hidden_left = start > 0;
    const hidden_right = end < candidates.items.len;
    const right_limit = width -| (if (hidden_right) @as(usize, 2) else 0);
    var x: usize = if (hidden_left) 2 else 0;
    var items: std.ArrayList(TabLayoutItem) = .empty;
    for (candidates.items[start..end], 0..) |candidate, i| {
        if (x >= right_limit) break;
        const item_width = @min(candidate.width(), right_limit - x);
        try items.append(arena, .{
            .sid = candidate.sid,
            .index = candidate.index,
            .label = candidate.label,
            .activity = candidate.activity,
            .active = candidate.active,
            .shell = candidate.shell,
            .x = x,
            .width = item_width,
        });
        x += item_width;
        if (i + 1 < end - start and x < right_limit) x += 1;
    }
    return .{ .items = items.items, .hidden_left = hidden_left, .hidden_right = hidden_right };
}

/// Word-aware cell-width break for prose. Long tokens fall back to a hard
/// grapheme break, so emoji and CJK never corrupt wrapping or table sizing.
pub fn inputPanelHeight(content_height: usize) usize {
    return content_height + 2; // one blank row above and below the editor
}

pub fn drawCommandMenu(
    app: *App,
    win: vaxis.Window,
    arena: std.mem.Allocator,
    input_top: u16,
    width: u16,
) !void {
    if (app.mode != .insert or app.picker != null or app.view.editor.isWalkingHistory() or commandQuery(&app.view.editor) == null) return;
    app.requestCwdCompletion();
    const suggestions = try commandSuggestions(app, arena);
    if (suggestions.len == 0) return;

    const directory_menu = commands.cwdArgument(&app.view.editor) != null;
    const limit = if (directory_menu) @import("../core/path_complete.zig").max_candidates else composer_commands.len;
    const shown: u16 = @intCast(@min(suggestions.len, limit, input_top -| 1));
    if (shown == 0) return;
    const menu_h = shown + 1;
    app.command_selection = @min(app.command_selection, suggestions.len - 1);
    const selection_active = !directory_menu or app.cwdMenuSelected();
    const start = if (selection_active) app.command_selection + 1 -| shown else 0;

    const menu = win.child(.{
        .x_off = 1,
        .y_off = @intCast(input_top - menu_h),
        .width = width -| 2,
        .height = menu_h,
    });
    menu.fill(.{ .style = Palette.command_menu });

    const pad = "                        ";
    var row: usize = 0;
    while (row < shown) : (row += 1) {
        const index = start + row;
        const suggestion = suggestions[index];
        const selected = selection_active and index == app.command_selection;
        const row_style = if (selected) Palette.command_selected else Palette.command_menu;
        const name_style = if (selected) Palette.command_selected_name else Palette.command_name;
        const description_style = if (selected) Palette.command_selected_description else Palette.command_description;
        const row_win = menu.child(.{ .y_off = @intCast(row), .height = 1, .width = menu.width });
        row_win.fill(.{ .style = row_style });

        const label = try std.fmt.allocPrint(arena, " {s}{s}", .{ suggestion.label, suggestion.usage });
        const pad_len: usize = if (label.len < pad.len) pad.len - label.len else 1;
        const segments = [_]vaxis.Segment{
            .{ .text = label, .style = name_style },
            .{ .text = pad[0..pad_len], .style = row_style },
            .{ .text = suggestion.description, .style = description_style },
        };
        _ = row_win.print(&segments, .{ .wrap = .none });
    }

    const hint = menu.child(.{ .y_off = @intCast(shown), .height = 1, .width = menu.width });
    _ = hint.printSegment(.{
        .text = if (directory_menu and !selection_active) " ↑↓ select · Tab complete · Enter use typed path" else " ↑↓ select · Tab complete · Enter choose",
        .style = Palette.command_description,
    }, .{ .wrap = .none });
}

const ShortcutHelpRow = struct {
    key: []const u8 = "",
    description: []const u8,
    heading: bool = false,
};

pub const shortcut_help_rows = [_]ShortcutHelpRow{
    .{ .key = "Esc / i", .description = "return to insert mode (Esc first cancels a pending count/operator)" },
    .{ .key = ":", .description = "open the command menu" },
    .{ .key = "</> or ←/→", .description = "previous / next tab (normal mode)" },
    .{ .key = "⌥← / ⌥→", .description = "previous / next tab (works in insert mode too)" },
    .{ .key = "⌥1–⌥9", .description = "jump to Nth tab (works in insert mode too)" },
    .{ .key = "Ctrl+V", .description = "attach clipboard image (Control, not Command)" },
    .{ .key = "gt / gT", .description = "switch sessions · Ngt = Nth recent" },
    .{ .key = "gs", .description = "start the configured screensaver effect" },
    .{ .key = "J", .description = "join lines" },
    .{ .key = "a / A / I", .description = "insert after cursor / line end / line start" },
    .{ .key = "j / k", .description = "scroll one line" },
    .{ .key = "Ctrl+d / Ctrl+u", .description = "scroll one page" },
    .{ .key = "gg / G", .description = "jump to top / bottom" },
    .{ .key = "/ · n/N", .description = "search transcript · next/previous match" },
    .{ .key = "?", .description = "toggle shortcut help" },
    .{ .key = "q", .description = "detach (sessions keep running)" },
    .{ .description = "COMPOSER (vim)", .heading = true },
    .{ .key = "h l w b e W B E 0 ^ $ %", .description = "move in the input line" },
    .{ .key = "x / D", .description = "delete char / to line end" },
    .{ .key = "d c y + motion", .description = "operators: w b e W B E 0 ^ $ % f t, dd/cc/yy, iw aW i\" i( i< …" },
    .{ .key = "counts f t ; ,", .description = "3w d2w 2dd · find char, repeat" },
    .{ .key = "u / Ctrl+R", .description = "undo / redo (normal mode)" },
    .{ .key = "s S C Y o O r ~", .description = "vim synonyms, open line, replace, case" },
    .{ .key = "p", .description = "paste the yank register" },
    .{ .description = "COPY MODE", .heading = true },
    .{ .key = "v", .description = "enter copy mode (cursor over transcript)" },
    .{ .key = "hjkl w b 0 $ g G", .description = "move the cursor" },
    .{ .key = "v / V", .description = "select char-wise / line-wise" },
    .{ .key = "y", .description = "yank: clipboard + paste register" },
    .{ .key = "arrows", .description = "scroll the view" },
    .{ .description = "GLOBAL", .heading = true },
    .{ .key = "Ctrl+R (insert)", .description = "fuzzy-search authored input history" },
    .{ .key = "Enter while working", .description = "steer the active turn" },
    .{ .key = "Ctrl+N", .description = "create a new session" },
    .{ .key = "Ctrl+S", .description = "open the live session and process tree" },
    .{ .key = "Ctrl+W (empty)", .description = "archive the current session" },
    .{ .key = "␣text", .description = "leading space sends a /… or !… message verbatim" },
    .{ .key = "Ctrl+L", .description = "redraw and return to bottom" },
    .{ .key = "Ctrl+T", .description = "toggle tool transcript" },
    .{ .key = "Opt+←/→", .description = "switch tabs; moves by word while the composer has text" },
    .{ .key = "Ctrl+Backspace", .description = "start the orb screensaver" },
    .{ .key = "Ctrl+C", .description = "interrupt the active turn" },
};

fn drawCouncilDetail(app: *const App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const council = app.councilByName(app.council_detail_name.items) orelse return;
    const h = win.height;
    const w = win.width;
    if (h < 8 or w < 32) return;

    var widest: usize = displayWidth(council.name) + 10;
    for (council.models.items) |model| widest = @max(widest, displayWidth(model) + 4);
    const box_w: u16 = @intCast(@min(@max(widest, 44) + 4, @as(usize, w -| 4)));
    const shown: u16 = @intCast(@min(council.models.items.len, h -| 7));
    const box_h: u16 = shown + 4;
    const box = win.child(.{
        .x_off = @intCast((w -| box_w) / 2),
        .y_off = @intCast((h -| box_h) / 2),
        .width = box_w,
        .height = box_h,
        .border = .{ .where = .all, .style = Palette.tool },
    });
    box.fill(.{ .style = .{} });

    const title = try std.fmt.allocPrint(arena, " council {s} · {d} models", .{ council.name, council.models.items.len });
    _ = box.printSegment(.{ .text = title, .style = Palette.user }, .{ .wrap = .none });
    for (council.models.items[0..shown], 0..) |model, i| {
        const line = try std.fmt.allocPrint(arena, " {d}. {s}", .{ i + 1, model });
        _ = box.printSegment(.{ .text = line, .style = Palette.tool_out }, .{
            .row_offset = @intCast(i + 1),
            .wrap = .none,
        });
    }
    if (shown < council.models.items.len) {
        const remaining = try std.fmt.allocPrint(arena, " … {d} more", .{council.models.items.len - shown});
        _ = box.printSegment(.{ .text = remaining, .style = Palette.status_muted }, .{
            .row_offset = shown + 1,
            .wrap = .none,
        });
    }
    _ = box.printSegment(.{
        .text = " e edit · Esc close",
        .style = Palette.tool_out,
    }, .{ .row_offset = box_h -| 2, .wrap = .none });
}

/// Static key rows plus a COMMANDS section generated from the composer
/// catalog, in one scrollable panel: on a 24-row terminal only half the rows
/// fit, and silently truncating the help was the one place a user could not
/// discover the surface.
fn drawShortcutHelp(app: *App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const h = win.height;
    const w = win.width;
    if (h < 8 or w < 32) return;

    var rows: std.ArrayList(ShortcutHelpRow) = .empty;
    try rows.appendSlice(arena, &shortcut_help_rows);
    try rows.append(arena, .{ .description = "COMMANDS", .heading = true });
    for (composer_commands) |cmd| {
        if (cmd.hidden) continue;
        try rows.append(arena, .{
            .key = try std.fmt.allocPrint(arena, "{s}{s}", .{ cmd.name, cmd.usage }),
            .description = cmd.description,
        });
    }
    const total = rows.items.len;
    const capacity: usize = @min(total, h -| 6);
    const max_scroll = total - capacity;
    if (app.help_scroll > max_scroll) app.help_scroll = max_scroll;
    const first = app.help_scroll;
    const remaining = total - (first + capacity);

    const shown: u16 = @intCast(capacity);
    const box_h = shown + 3; // title + rows + close hint
    const box_w: u16 = @min(@as(u16, 76), w -| 4);
    const box = win.child(.{
        .x_off = @intCast((w -| box_w) / 2),
        .y_off = @intCast((h -| box_h) / 2),
        .width = box_w,
        .height = box_h,
        .border = .{ .where = .all, .style = Palette.shortcut_border },
    });
    box.fill(.{ .style = Palette.shortcut_panel });
    _ = box.printSegment(.{
        .text = " NORMAL MODE · shortcuts",
        .style = Palette.shortcut_key,
    }, .{ .wrap = .none });

    const key_column: usize = 26;
    var row: u16 = 0;
    while (row < shown) : (row += 1) {
        const item = rows.items[first + row];
        const row_win = box.child(.{ .y_off = @intCast(row + 1), .height = 1, .width = box.width });
        if (item.heading) {
            const heading = try std.fmt.allocPrint(arena, " {s}", .{item.description});
            _ = row_win.printSegment(.{ .text = heading, .style = Palette.shortcut_key }, .{ .wrap = .none });
            continue;
        }
        const key = try std.fmt.allocPrint(arena, " {s}", .{item.key});
        const padding = try spaces(arena, if (key.len < key_column) key_column - key.len else 1);
        const segments = [_]vaxis.Segment{
            .{ .text = key, .style = Palette.shortcut_key },
            .{ .text = padding, .style = Palette.shortcut_panel },
            .{ .text = item.description, .style = Palette.shortcut_text },
        };
        _ = row_win.print(&segments, .{ .wrap = .none });
    }

    const footer = if (remaining > 0)
        try std.fmt.allocPrint(arena, " Esc · ? · q close · j/k scroll · {d} more", .{remaining})
    else if (first > 0)
        " Esc · ? · q close · j/k scroll"
    else
        " Esc · ? · q close";
    _ = box.printSegment(.{
        .text = footer,
        .style = Palette.shortcut_text,
    }, .{ .row_offset = shown + 1, .wrap = .none });
}

/// Empty-session welcome card, centered in the transcript area: identity
/// (version + daemon build), the session's model, and first steps. Rendered
/// only while the session has zero transcript lines; any content reclaims
/// the space. No box, no mode — orientation, not chrome.
fn drawWelcome(app: *const App, win: vaxis.Window, top_rows: usize, view_h: usize, arena: std.mem.Allocator) !void {
    if (view_h < 6 or win.width < 40) return;

    const Row = struct { key: []const u8 = "", text: []const u8, style: vaxis.Style = Palette.welcome_dim };
    var rows: std.ArrayList(Row) = .empty;

    try rows.append(arena, .{ .key = "marlin", .text = "v" ++ build_options.version, .style = Palette.welcome_dim });
    const daemon_ver = app.welcome_daemon_version[0..app.welcome_daemon_version_len];
    if (daemon_ver.len > 0) {
        try rows.append(arena, .{ .text = try std.fmt.allocPrint(arena, "daemon v{s} · sandbox {s} · dnsblock {s}", .{
            daemon_ver,
            if (app.welcome_sandbox) "✓" else "off",
            if (app.welcome_dnsblock_rules > 0)
                try std.fmt.allocPrint(arena, "{d} rules", .{app.welcome_dnsblock_rules})
            else
                "off",
        }) });
    }
    if (app.build_mismatch) {
        try rows.append(arena, .{ .text = "⚠ daemon runs a different build — /reboot to sync", .style = Palette.welcome_warn });
    }
    try rows.append(arena, .{ .text = "" });
    if (app.setup.required) {
        try rows.append(arena, .{ .key = "setup", .text = "choose a provider or guest agent", .style = Palette.welcome_title });
        try rows.append(arena, .{ .key = "Enter", .text = "reopen backend selection" });
        try rows.append(arena, .{ .key = "/quit", .text = "leave without configuring" });
        return drawWelcomeRows(win, top_rows, view_h, arena, rows.items);
    }
    try rows.append(arena, .{ .key = "model", .text = app.view.model.items });
    try rows.append(arena, .{ .text = "" });
    try rows.append(arena, .{ .key = "Enter", .text = "send a prompt" });
    try rows.append(arena, .{ .key = "/", .text = "slash commands · /model switches model" });
    try rows.append(arena, .{ .key = "Ctrl+N", .text = "new session · ⌥1–⌥9 to switch" });
    try rows.append(arena, .{ .key = "Esc ?", .text = "all keyboard shortcuts" });

    return drawWelcomeRows(win, top_rows, view_h, arena, rows.items);
}

fn drawWelcomeRows(win: vaxis.Window, top_rows: usize, view_h: usize, arena: std.mem.Allocator, rows: anytype) !void {
    const key_column: usize = 8;
    var block_w: usize = 0;
    for (rows) |item| block_w = @max(block_w, key_column + displayWidth(item.text));
    block_w = @min(block_w, @as(usize, win.width) -| 2);

    const shown: usize = @min(rows.len, view_h);
    const x_off: usize = (@as(usize, win.width) -| block_w) / 2;
    const y_off: usize = top_rows + (view_h -| shown) / 2;
    for (rows[0..shown], 0..) |item, i| {
        if (item.text.len == 0 and item.key.len == 0) continue;
        const padding = try spaces(arena, key_column -| displayWidth(item.key));
        const segments = [_]vaxis.Segment{
            .{ .text = item.key, .style = Palette.welcome_title },
            .{ .text = padding, .style = .{} },
            .{ .text = item.text, .style = item.style },
        };
        const row_win = win.child(.{
            .x_off = @intCast(x_off),
            .y_off = @intCast(y_off + i),
            .height = 1,
            .width = @intCast(block_w),
        });
        _ = row_win.print(&segments, .{ .wrap = .none });
    }
}

fn tabActivityStyle(activity: TabActivity, active: bool) vaxis.Style {
    var style: vaxis.Style = switch (activity) {
        .idle, .paused => .{ .fg = .{ .index = 8 }, .dim = true },
        .done => .{ .fg = .{ .index = 2 } },
        .running => .{ .fg = .{ .index = 3 }, .bold = true },
        .err => .{ .fg = .{ .index = 1 }, .bold = true },
        .approval => .{ .fg = .{ .index = 3 }, .bold = true },
    };
    style.bg = if (active) Palette.prompt_bg else Palette.command_bg;
    return style;
}

fn drawTabBar(app: *App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const bar = win.child(.{ .height = tab_bar_height, .width = win.width });
    bar.fill(.{ .style = Palette.tab_bar });
    app.tab_hits.clearRetainingCapacity();

    const available_width = win.width -| @as(u16, if (app.web_available) 7 else 0);
    const layout = try layoutTabBar(arena, app, available_width);
    if (app.web_available and win.width >= 7) {
        _ = bar.printSegment(.{ .text = " web ", .style = if (app.web_view) Palette.tab_active else Palette.tab_inactive }, .{ .col_offset = available_width, .wrap = .none });
        try app.tab_hits.append(app.gpa, .{ .start_col = available_width, .end_col = win.width, .sid = 0 });
    }
    if (layout.hidden_left) {
        _ = bar.printSegment(.{ .text = "‹ ", .style = Palette.tab_overflow }, .{ .wrap = .none });
    }
    if (layout.hidden_right and available_width >= 2) {
        _ = bar.printSegment(.{ .text = " ›", .style = Palette.tab_overflow }, .{
            .col_offset = available_width - 2,
            .wrap = .none,
        });
    }

    for (layout.items) |item| {
        if (item.width == 0) continue;
        const style = if (item.active and !app.web_view) Palette.tab_active else Palette.tab_inactive;
        const tab = bar.child(.{
            .x_off = @intCast(item.x),
            .width = @intCast(item.width),
            .height = 1,
        });
        tab.fill(.{ .style = style });
        const index_text = try std.fmt.allocPrint(arena, "{d}", .{item.index});
        var index_style = style;
        index_style.bold = false;
        index_style.dim = true;
        const label_capacity = item.width -| (7 + displayWidth(index_text));
        const label_end = hardCellBreak(item.label, 0, label_capacity);
        const segments = [_]vaxis.Segment{
            .{ .text = " ", .style = style },
            // Agent tabs wear the composer's prompt, shells their own.
            .{ .text = if (item.shell) "$" else "❯", .style = index_style },
            .{ .text = " ", .style = style },
            .{ .text = index_text, .style = index_style },
            .{ .text = " ", .style = style },
            .{ .text = item.label[0..label_end], .style = style },
            .{ .text = tabActivityText(item.activity), .style = tabActivityStyle(item.activity, item.active) },
            .{ .text = " ", .style = style },
        };
        _ = tab.print(&segments, .{ .wrap = .none });
        app.tab_hits.append(app.gpa, .{
            .start_col = item.x,
            .end_col = item.x + item.width,
            .sid = item.sid,
        }) catch {};
    }
}

const PlanDisplayRange = struct { start: usize = 0, len: usize = 0 };
const max_plan_items: usize = 5;
const plan_frame_rows: usize = 2; // top border + open-bottom padding row
const surface_gap_rows: u16 = 1;

pub fn planDisplayRange(items: []const PlanItemOwned, max_rows: usize) PlanDisplayRange {
    if (max_rows == 0 or items.len == 0) return .{};
    var focus: ?usize = null;
    for (items, 0..) |item, index| {
        if (item.status == .in_progress) {
            focus = index;
            break;
        }
        if (focus == null and item.status == .pending) focus = index;
    }
    // Completed plans normally leave live chrome immediately; retain this
    // fallback so a restored legacy view remains inspectable.
    const at = focus orelse items.len - 1;
    const len = @min(items.len, max_rows);
    var start = at -| (len / 2);
    if (start + len > items.len) start = items.len - len;
    return .{ .start = start, .len = len };
}

const PlanSurfaceLayout = struct {
    plan_h: u16,
    view_h: u16,
};

pub fn planSurfaceLayout(
    height: u16,
    top_rows: usize,
    input_h: u16,
    items: []const PlanItemOwned,
) PlanSurfaceLayout {
    const fixed_h = @as(u16, @intCast(top_rows)) + input_h + surface_gap_rows + 1;
    const plan_capacity = height -| (fixed_h + 2);
    const item_capacity = @min(max_plan_items, plan_capacity -| plan_frame_rows);
    const range = planDisplayRange(items, item_capacity);
    const plan_h: u16 = @intCast(if (range.len > 0) range.len + plan_frame_rows else 0);
    return .{
        .plan_h = plan_h,
        .view_h = height -| (fixed_h + plan_h),
    };
}

const PlanMarker = struct {
    glyph: []const u8,
    glyph_style: vaxis.Style,
    text_style: vaxis.Style,
};

pub fn planMarker(status: block.PlanStatus, session_state: proto.SessionState, spinner_frame: usize) PlanMarker {
    return switch (status) {
        .pending => .{
            .glyph = "·",
            .glyph_style = Palette.plan_pending,
            .text_style = Palette.plan_pending,
        },
        .in_progress => switch (session_state) {
            .running => .{
                .glyph = spinner_frames[spinner_frame % spinner_frames.len],
                .glyph_style = Palette.plan_active,
                .text_style = Palette.plan_active,
            },
            .err => .{
                .glyph = "×",
                .glyph_style = Palette.plan_error,
                .text_style = Palette.plan_pending,
            },
            .idle, .awaiting_approval, .done => .{
                .glyph = "⏸",
                .glyph_style = Palette.plan_pending,
                .text_style = Palette.plan_pending,
            },
        },
        .completed => .{
            .glyph = "✔",
            .glyph_style = Palette.plan_done_mark,
            // Completion changes only the mark. Keep the task readable
            // instead of fading the whole line into the panel background.
            .text_style = Palette.plan_pending,
        },
    };
}

// The pinned panel and the transcript's closed plan table must agree on
// geometry and duration text; layout.zig owns both (the two copies once
// diverged on how a zero duration rendered).
pub const formatPlanDuration = layout_mod.formatPlanDuration;
const PlanTableWidths = layout_mod.PlanTableWidths;
pub const planTableWidths = layout_mod.planTableWidths;

pub fn planRule(arena: std.mem.Allocator, width: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var used: usize = 0;
    while (used < width) : (used += 1) try out.appendSlice(arena, "─");
    return out.toOwnedSlice(arena);
}

pub fn planItemTimeMs(app: *const App, item: PlanItemOwned, now_ms: i64) ?u64 {
    if (item.status == .completed)
        return if (item.duration_ms > 0) item.duration_ms else null;
    if (item.status != .in_progress) return null;

    var elapsed = item.duration_ms;
    if (app.view.state == .running) {
        const started = if (item.started_at_ms > 0) item.started_at_ms else app.view.turn_started_ms;
        if (started > 0 and now_ms > started) elapsed +|= @intCast(now_ms - started);
        // Render immediate feedback instead of a blank cell for the first ms.
        if (elapsed == 0) elapsed = 1;
    }
    return if (elapsed > 0) elapsed else null;
}

fn drawPlan(
    app: *App,
    win: vaxis.Window,
    arena: std.mem.Allocator,
    top: u16,
    height: u16,
) !void {
    if (height == 0) return;
    const panel = win.child(.{ .y_off = top, .height = height, .width = win.width });
    panel.fill(.{ .style = Palette.plan_panel });
    const item_rows = @as(usize, height) -| plan_frame_rows;
    const range = planDisplayRange(app.view.plan.items, item_rows);
    const widths = planTableWidths(win.width);
    const task_header = try planRule(arena, widths.task);
    const time_header = try planRule(arena, widths.time);
    const top_border = [_]vaxis.Segment{
        .{ .text = "┌", .style = Palette.plan_header },
        .{ .text = task_header, .style = Palette.plan_header },
        .{ .text = "┬", .style = Palette.plan_header },
        .{ .text = time_header, .style = Palette.plan_header },
        .{ .text = "┐", .style = Palette.plan_header },
    };
    _ = panel.print(&top_border, .{ .wrap = .none });

    const now_ms = nowWallMs(app.io);
    for (app.view.plan.items[range.start .. range.start + range.len], 0..) |item, row| {
        const marker = planMarker(item.status, app.view.state, app.view.spinner_frame);
        const available = widths.task -| 3;
        const end = hardCellBreak(item.step, 0, available);
        const left = [_]vaxis.Segment{
            .{ .text = "│ ", .style = Palette.plan_header },
            .{ .text = marker.glyph, .style = marker.glyph_style },
            .{ .text = " ", .style = marker.text_style },
            .{ .text = item.step[0..end], .style = marker.text_style },
        };
        const row_offset: u16 = @intCast(row + 1);
        _ = panel.print(&left, .{ .row_offset = row_offset, .wrap = .none });
        _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
            .row_offset = row_offset,
            .col_offset = @intCast(widths.task + 1),
            .wrap = .none,
        });
        if (planItemTimeMs(app, item, now_ms)) |time_ms| {
            const time = try formatPlanDuration(arena, time_ms);
            const time_cells = displayWidth(time);
            _ = panel.printSegment(.{ .text = time, .style = marker.text_style }, .{
                .row_offset = row_offset,
                .col_offset = @intCast(widths.task + 2 + widths.time -| (time_cells + 1)),
                .wrap = .none,
            });
        }
        _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
            .row_offset = row_offset,
            .col_offset = win.width - 1,
            .wrap = .none,
        });
    }

    // The final row is breathing room inside the open-bottom table. Keep all
    // three vertical rules so its frame reaches the composer below.
    const padding_row = height - 1;
    _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
        .row_offset = padding_row,
        .wrap = .none,
    });
    _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
        .row_offset = padding_row,
        .col_offset = @intCast(widths.task + 1),
        .wrap = .none,
    });
    _ = panel.printSegment(.{ .text = "│", .style = Palette.plan_header }, .{
        .row_offset = padding_row,
        .col_offset = win.width - 1,
        .wrap = .none,
    });
}

fn drawTop(app: *App, win: vaxis.Window, arena: std.mem.Allocator) !void {
    const rows = try top_view.orderedRows(arena, try app.topRows(arena));
    const groups = try app.topActivityGroups(arena);
    var scroll_top: usize = if (app.top_view) |view| view.scroll_top else 0;
    try top_view.drawCatalog(
        win,
        arena,
        rows,
        groups,
        app.known_session_ids.items,
        if (app.top_view) |view| view.selected_sid else null,
        if (app.top_view) |view| view.selected_activity else null,
        &scroll_top,
        nowWallMs(app.io),
        false,
        app.notice.items,
        if (app.top_view) |view| view.confirm_kill != null else false,
        true,
        if (app.top_view) |view| view.inspecting_activity else false,
        if (app.top_view) |*view| &view.activity_output_scroll else unreachable,
    );
    if (app.top_view) |*view| view.scroll_top = scroll_top;
}

/// Use the transcript's OSC 8 renderer so operational output has the same
/// terminal hyperlinks and mouse activation as ordinary session output.
pub fn drawWebLine(win: vaxis.Window, arena: std.mem.Allocator, text: []const u8, row: u16) !void {
    _ = win.printSegment(.{ .text = text, .style = Palette.tab_inactive }, .{ .row_offset = row, .wrap = .none });
    render.applyLineLinks(win, row, .{
        .text = text,
        .style = Palette.tab_inactive,
        .links = try render.findLinkSpans(arena, text),
        .links_resolved = true,
    });
}

pub fn draw(app: *App, vx: *vaxis.Vaxis, arena: std.mem.Allocator) !void {
    const win = vx.window();
    win.clear();
    app.tab_hits.clearRetainingCapacity();
    const h = win.height;
    const w = win.width;
    if (h < 4 or w < 20) return;
    shell_tab.sync(app);
    if (app.top_view != null) return drawTop(app, win, arena);

    if (app.show_tab_bar) try drawTabBar(app, win, arena);
    const top_rows = app.tabBarRows();
    if (app.web_view) {
        win.hideCursor();
        const rows = h -| top_rows;
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, app.web_text.items, '\n');
        while (it.next()) |line| try lines.append(arena, line);
        const pinned = @min(@as(usize, 3), @min(rows, lines.items.len));
        for (lines.items[0..pinned], 0..) |line, row| {
            try drawWebLine(win, arena, line, @intCast(row + top_rows));
        }
        const log_rows = rows - pinned;
        const max_scroll = (lines.items.len - pinned) -| log_rows;
        app.web_scroll = @min(app.web_scroll, max_scroll);
        const first = pinned + max_scroll - app.web_scroll;
        for (lines.items[first..], 0..) |line, row| {
            if (row >= log_rows) break;
            try drawWebLine(win, arena, line, @intCast(row + top_rows + pinned));
        }
        return;
    }

    // The composer is a three-row panel for a one-line prompt (padding,
    // content, padding) and grows with multiline input.
    const prompt: []const u8 = if (app.history_search.active) search_prompt: {
        const query = app.history_search.query.items;
        const query_end = hardCellBreak(query, 0, @max(@as(usize, w) / 3, 1));
        break :search_prompt try std.fmt.allocPrint(arena, "⌕ '{s}'▏: ", .{query[0..query_end]});
    } else if (app.setup.prompt != .none)
        switch (app.setup.prompt) {
            .none => unreachable,
            .credential => "API key ❯ ",
            .base_url => "base URL ❯ ",
            .model => "model ❯ ",
            .provider_name => "provider ❯ ",
        }
    else if (app.otel_header_prompt)
        "OTLP headers ❯ "
    else if (app.view.plan_mode)
        if (app.mode == .insert) "PLAN ❯ " else "PLAN : "
    else if (app.mode == .insert)
        "❯ "
    else
        ": ";
    const panel_inner_w = w -| 2; // one cell of horizontal padding
    const editor_body_w = @max(panel_inner_w -| displayWidth(prompt), 1);
    const content_h: u16 = @intCast(app.view.editor.displayHeight(editor_body_w));
    const proposal_ready = app.view.plan_mode and app.view.plan_proposal_ready and app.view.state == .idle;
    const input_h: u16 = @intCast(inputPanelHeight(content_h) + @intFromBool(proposal_ready));
    // The plan's final framed row provides breathing room before the composer;
    // the ordinary transcript gap remains above the lowest surface.
    // A shell session has no composer or plan: its terminal fills the
    // transcript area down to a blank row above the status line.
    const shell_session = shell_tab.active(app);
    const shell_full_screen = shell_tab.showingFullScreen(app);
    const surfaces = planSurfaceLayout(h, top_rows, if (shell_session) 0 else input_h, if (shell_session) &.{} else app.view.plan.items);
    const plan_h = if (shell_session) 0 else surfaces.plan_h;
    const view_h = if (shell_session) @as(@TypeOf(surfaces.view_h), @intCast(@as(usize, h) -| top_rows -| shell_tab.bottom_rows)) else surfaces.view_h;
    if (shell_session) shell_tab.fit(app, w, @intCast(view_h));

    // ---- session view ----
    var transcript = transcriptView(app);
    // On very short terminals the TODO panel may not fit; keep the ordinary
    // ticker in that case so liveness never disappears with the panel.
    transcript.show_working_ticker = plan_h == 0;
    if (shell_tab.live(app)) |shell| if (!shell_full_screen) {
        transcript.extra_lines = try shell_tab.transcriptLines(shell, w);
    };
    var lines: std.ArrayList(Line) = if (shell_full_screen) .empty else try layout_mod.layoutLines(arena, app.gpa, &transcript, w);
    if (shell_full_screen) try shell_tab.drawFullScreen(app, arena, win.child(.{ .y_off = @intCast(top_rows), .height = @intCast(view_h) }));
    const total = lines.items.len;
    if (app.search.target_seq > 0 and !app.view.history_loading) {
        var target_index: ?usize = null;
        for (app.view.blocks.items, 0..) |rendered, index| {
            if (rendered.seq == app.search.target_seq) {
                target_index = index;
                break;
            }
        }
        if (target_index) |index| {
            var prefix_lines: std.ArrayList(Line) = .empty;
            var last_tool_label: []const u8 = "";
            try layoutBlockRange(
                arena,
                &transcript,
                &prefix_lines,
                0,
                index + 1,
                w,
                &last_tool_label,
                true,
            );
            const target_line = prefix_lines.items.len -| 1;
            const max_scroll = total -| view_h;
            const desired_first = target_line -| (@as(usize, view_h) / 3);
            app.view.scroll_up = max_scroll -| @min(desired_first, max_scroll);
            app.search.highlight_line = target_line;
            // Avoid treating this deliberate reposition as transcript growth.
            app.view.last_total_lines = total;
            app.view.last_view_h = view_h;
        }
        app.search.target_seq = 0;
    }
    if (app.view.history_target_seq > 0 and !app.view.history_loading) {
        var target_index: ?usize = null;
        for (app.view.blocks.items, 0..) |rendered, index| {
            if (rendered.seq == app.view.history_target_seq) {
                target_index = index;
                break;
            }
        }
        if (target_index) |index| {
            var prefix_lines: std.ArrayList(Line) = .empty;
            var last_tool_label: []const u8 = "";
            try layoutBlockRange(arena, &transcript, &prefix_lines, 0, index + 1, w, &last_tool_label, true);
            const target_line = prefix_lines.items.len -| 1;
            const max_scroll = total -| view_h;
            const desired_first = target_line -| (@as(usize, view_h) / 3);
            app.view.scroll_up = max_scroll -| @min(desired_first, max_scroll);
            app.view.last_total_lines = total;
            app.view.last_view_h = view_h;
        }
        app.view.history_target_seq = 0;
    }
    const max_scroll = total -| view_h;
    // Preserve the first visible row in both directions: activity cards and
    // streaming previews can disappear as well as grow. Composer/plan height
    // changes also alter the distance from that row to the bottom.
    if (app.view.scroll_up > 0 and app.view.last_total_lines > 0) {
        const previous_first = (app.view.last_total_lines -| app.view.last_view_h) -| app.view.scroll_up;
        app.view.scroll_up = max_scroll -| previous_first;
    }
    app.view.last_total_lines = total;
    if (app.view.scroll_up > max_scroll) app.view.scroll_up = max_scroll;

    const DisplayLine = struct {
        line: Line,
        abs_line: usize,
        selectable: bool,
    };
    var visible: std.ArrayList(DisplayLine) = .empty;
    const prompt_range = layout_mod.activePromptLineRange(&transcript);
    const ordinary_first = total -| view_h;
    // Include truncation and the separator in the budget. Recompute from
    // the live terminal height on every draw, including after a resize.
    // Also leave room for the answer when an expanded composer reduces view_h.
    const pinned_budget = @min(@as(usize, 10), @min(h / 4, view_h / 2));
    const pin_prompt = app.view.scroll_up == 0 and prompt_range != null and
        pinned_budget >= 4 and ordinary_first >= prompt_range.?.start;
    if (pin_prompt) {
        const sticky_prompt = prompt_range.?;
        const displayed_len = @min(sticky_prompt.len, pinned_budget - 1);
        const truncated = displayed_len < sticky_prompt.len;
        const copied_len = displayed_len - @intFromBool(truncated);
        for (lines.items[sticky_prompt.start..][0..copied_len], sticky_prompt.start..) |ln, abs_line| {
            var pinned_line = ln;
            // The sticky copy is navigation chrome rather than an editable
            // composer. Give its first content row a distinct anchored mark;
            // the durable prompt in ordinary scrollback keeps the usual ❯.
            if (abs_line == sticky_prompt.start + 1) {
                pinned_line.text = " # ";
                pinned_line.style = Palette.pinned_prompt_mark;
            }
            try visible.append(arena, .{ .line = pinned_line, .abs_line = abs_line, .selectable = false });
        }
        if (truncated) try visible.append(arena, .{
            .line = .{
                .text = " … scroll up for the full prompt",
                .style = Palette.prompt_text,
                .fill_style = Palette.prompt_panel,
                .timestamp_ms = lines.items[sticky_prompt.start + copied_len].timestamp_ms,
            },
            .abs_line = sticky_prompt.start + copied_len,
            .selectable = false,
        });
        // One blank, non-selectable row keeps the pinned surface visually
        // separate from the live scrollback immediately below it.
        try visible.append(arena, .{
            .line = .{ .text = "", .style = .{} },
            .abs_line = sticky_prompt.start + sticky_prompt.len,
            .selectable = false,
        });
        const pinned_rows = displayed_len + 1;
        const body_capacity = view_h - pinned_rows;
        const body_floor = sticky_prompt.start + sticky_prompt.len;
        const body_first = @max(body_floor, total -| body_capacity);
        const body_end = @min(body_first + body_capacity, total);
        for (lines.items[body_first..body_end], body_first..) |ln, abs_line| {
            try visible.append(arena, .{ .line = ln, .abs_line = abs_line, .selectable = true });
        }
        app.view.last_pinned_start = sticky_prompt.start;
        app.view.last_pinned_rows = pinned_rows;
        app.view.last_body_first = body_first;
        app.view.last_body_rows = body_end - body_first;
        app.view.last_first_visible = body_first;
    } else {
        const first_visible = (total -| view_h) -| app.view.scroll_up;
        const end_visible = @min(first_visible + view_h, total);
        for (lines.items[first_visible..end_visible], first_visible..) |ln, abs_line| {
            try visible.append(arena, .{ .line = ln, .abs_line = abs_line, .selectable = true });
        }
        app.view.last_pinned_start = 0;
        app.view.last_pinned_rows = 0;
        app.view.last_body_first = first_visible;
        app.view.last_body_rows = end_visible - first_visible;
        app.view.last_first_visible = first_visible;
    }
    // Keep terminal viewport geometry even when the transcript has fewer
    // rows; mouse/copy mapping separately rejects blank rows.
    app.view.last_view_h = view_h;

    // Empty-session welcome card: only when there is genuinely nothing to
    // show (fresh session, replay finished, no turn running).
    if (total == 0 and !app.view.history_loading and app.view.state == .idle and !shell_session)
        try drawWelcome(app, win, top_rows, view_h, arena);

    var hovered_timestamp: ?i64 = null;
    for (visible.items, 0..) |display, row| {
        const ln = display.line;
        const abs_line = display.abs_line;
        if (app.hover_mouse) |mouse| {
            if (mouse.row == top_rows + row and mouse.col >= 0 and mouse.col < w and
                !app.view.sel_dragging)
                hovered_timestamp = ln.timestamp_ms;
        }
        if (ln.fill_style) |fill_style| {
            const fill_start = @min(ln.fill_start, w);
            const fill_width = @min(ln.fill_width orelse (w -| fill_start), w -| fill_start);
            const row_win = win.child(.{
                .x_off = @intCast(fill_start),
                .y_off = @intCast(top_rows + row),
                .height = 1,
                .width = fill_width,
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
            .row_offset = @intCast(top_rows + row),
            .wrap = .none,
        });
        applyLineSyntax(win, @intCast(top_rows + row), ln);
        applyLineLinks(win, @intCast(top_rows + row), ln);
        if (display.selectable and app.search.highlight_line == abs_line) {
            var col: usize = 0;
            const width = @min(lineWidth(win, ln), @as(usize, w));
            while (col < width) : (col += 1) {
                const cell = win.readCell(@intCast(col), @intCast(top_rows + row)) orelse continue;
                var highlighted = cell;
                highlighted.style.reverse = true;
                win.writeCell(@intCast(col), @intCast(top_rows + row), highlighted);
            }
        }
        // Apply selection after printing so partial-cell highlighting keeps
        // each segment's original syntax color and other style attributes.
        if (display.selectable) {
            if (app.selection()) |sel| {
                if (sel.columns(abs_line, lineWidth(win, ln))) |cols| {
                    var col = cols.start;
                    while (col < cols.end and col < @as(usize, w)) : (col += 1) {
                        const cell = win.readCell(@intCast(col), @intCast(top_rows + row)) orelse continue;
                        var selected_cell = cell;
                        selected_cell.style.reverse = true;
                        win.writeCell(@intCast(col), @intCast(top_rows + row), selected_cell);
                    }
                }
            }
        }
        if (display.selectable) {
            if (app.copy_cursor) |cursor| {
                if (cursor.line == abs_line) {
                    // Capture the cursor line's geometry for $/w/b, then draw a
                    // block cursor (reverse; inside a selection the un-reversed
                    // cell reads as the cursor, exactly like vim).
                    app.copy_cursor_line_width = lineWidth(win, ln);
                    app.copy_cursor_line_text.clearRetainingCapacity();
                    if (lineText(arena, ln)) |txt| {
                        app.copy_cursor_line_text.appendSlice(app.gpa, txt) catch {};
                    } else |_| {}
                    const col = @min(cursor.col, @max(app.copy_cursor_line_width, 1) - 1);
                    if (col < @as(usize, w)) {
                        if (win.readCell(@intCast(col), @intCast(top_rows + row))) |cell| {
                            var cursor_cell = cell;
                            cursor_cell.style.reverse = !cursor_cell.style.reverse;
                            win.writeCell(@intCast(col), @intCast(top_rows + row), cursor_cell);
                        }
                    }
                }
            }
        }
    }

    // A shell session draws the composer (over its bottom rows, without
    // resizing the shell) only while a Marlin command is being typed.
    if (shell_session and !shell_tab.commandLineOpen(app)) {
        if (!shell_full_screen) shell_tab.placeCursor(app, win, @intCast(top_rows), @intCast(view_h), total);
    } else try drawComposer(app, win, arena, .{
        .h = h,
        .w = w,
        .input_h = input_h,
        .plan_h = plan_h,
        .content_h = content_h,
        .panel_inner_w = panel_inner_w,
        .prompt = prompt,
        .proposal_ready = proposal_ready,
    });

    // ---- status bar ----
    // Hover timestamps overlay the composer row; a shell session has none.
    const timestamp_row: ?u16 = if (shell_session) null else h - input_h;
    try drawStatusBar(app, win, arena, h, w, if (timestamp_row != null) hovered_timestamp else null, timestamp_row orelse 0);
}

const ComposerGeometry = struct {
    h: u16,
    w: u16,
    input_h: u16,
    plan_h: u16,
    content_h: u16,
    panel_inner_w: u16,
    prompt: []const u8,
    proposal_ready: bool,
};

fn drawComposer(app: *App, win: vaxis.Window, arena: std.mem.Allocator, g: ComposerGeometry) !void {
    const h = g.h;
    const w = g.w;
    const input_h = g.input_h;
    const plan_h = g.plan_h;
    const content_h = g.content_h;
    const panel_inner_w = g.panel_inner_w;
    const prompt = g.prompt;
    const proposal_ready = g.proposal_ready;
    const input_top = h - 1 - input_h;
    const plan_top = input_top -| plan_h;
    try drawPlan(app, win, arena, plan_top, plan_h);

    // ---- input box ----
    const input_panel = win.child(.{ .y_off = input_top, .height = input_h, .width = w });
    input_panel.fill(.{ .style = Palette.prompt_panel });
    const input_win = input_panel.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = panel_inner_w,
        .height = content_h,
    });
    if (app.otel_header_prompt or app.setup.prompt == .credential)
        app.view.editor.drawMasked(input_win, prompt, Palette.prompt_mark, Palette.prompt_text)
    else
        app.view.editor.draw(input_win, prompt, if (app.view.plan_mode) Palette.plan_active else Palette.prompt_mark, Palette.prompt_text);
    if (proposal_ready) {
        _ = input_panel.printSegment(.{
            .text = " Enter implement · e revise · Esc/q dismiss",
            .style = Palette.plan_active,
        }, .{ .row_offset = input_h - 1, .wrap = .none });
    }
    if (app.mode == .normal or app.history_search.active) win.hideCursor();
    if (app.setup.prompt == .none and !app.otel_header_prompt)
        try drawCommandMenu(app, win, arena, input_top, w);
}

fn drawStatusBar(app: *App, win: vaxis.Window, arena: std.mem.Allocator, h: u16, w: u16, hovered_timestamp: ?i64, timestamp_row: u16) !void {
    const status_win = win.child(.{ .y_off = h - 1, .height = 1, .width = w });
    status_win.fill(.{ .style = Palette.status_bar });
    // The shell prefix waits for its command: the whole line says which.
    if (app.shell_prefix_pending and shell_tab.active(app)) {
        _ = status_win.print(&.{
            .{ .text = " shell ▸ ", .style = Palette.status_approval },
            .{ .text = "1-9 tab · n/p next/prev · c new session · [ normal mode · : command · prefix again sends it", .style = Palette.status_bar },
        }, .{ .wrap = .none });
        return;
    }
    const state_txt: []const u8 = if (shell_tab.active(app)) "shell" else if (app.view.login_required) "LOGIN REQUIRED" else if (app.view.pause != .none) @tagName(app.view.pause) else switch (app.view.state) {
        .idle => "idle",
        .running => "running",
        .awaiting_approval => "APPROVAL?",
        .err => "error",
        .done => "done",
    };
    const state_style: vaxis.Style = if (app.view.pause != .none) Palette.status_muted else switch (app.view.state) {
        .idle, .done => Palette.status_idle,
        .running => Palette.status_running,
        .awaiting_approval => Palette.status_approval,
        .err => Palette.status_error,
    };
    const guest = proto.isGuestModel(app.view.model.items);
    const context_percent = if (app.view.context_limit > 0)
        app.view.context_used * 100 / app.view.context_limit
    else
        0;
    const ctx_txt = try statusContext(
        arena,
        guest,
        app.view.usage_credits,
        app.view.context_used,
        app.view.context_limit,
    );
    const ctx_style = if (guest and app.view.context_limit == 0)
        Palette.status_muted
    else if (context_percent >= 90)
        Palette.status_context_hot
    else if (context_percent >= 70)
        Palette.status_context_warn
    else
        Palette.status_context;
    const cwd_txt = try statusLocation(arena, app.daemon_hostname, app.view.cwd.items, app.home.items);
    const scroll_txt = if (app.view.history_has_newer)
        if (app.view.scroll_up > 0)
            try std.fmt.allocPrint(arena, "↕ {d} (G: latest)", .{app.view.scroll_up})
        else
            "older history (G: latest)"
    else
        try std.fmt.allocPrint(arena, "↕ {d} (G: bottom)", .{app.view.scroll_up});
    const focused_parent_sid = if (app.sessionSummary(app.view.sid)) |summary| summary.parent_sid else null;
    var child_count: usize = 0;
    var child_running: usize = 0;
    var child_approvals: usize = 0;
    var child_errors: usize = 0;
    for (app.sessions.items) |session| {
        if (session.parent_sid != app.view.sid) continue;
        child_count += 1;
        switch (session.state) {
            .running => child_running += 1,
            .awaiting_approval => child_approvals += 1,
            .err => child_errors += 1,
            else => {},
        }
    }
    const child_txt: []const u8 = if (focused_parent_sid != null)
        "child session"
    else if (child_count > 0)
        if (child_approvals > 0)
            try std.fmt.allocPrint(arena, "{d} child{s} · {d} approval{s}", .{
                child_count,
                if (child_count == 1) "" else "ren",
                child_approvals,
                if (child_approvals == 1) "" else "s",
            })
        else if (child_errors > 0)
            try std.fmt.allocPrint(arena, "{d} child{s} · {d} error{s}", .{
                child_count,
                if (child_count == 1) "" else "ren",
                child_errors,
                if (child_errors == 1) "" else "s",
            })
        else if (child_running > 0)
            try std.fmt.allocPrint(arena, "{d} child{s} · {d} running", .{
                child_count,
                if (child_count == 1) "" else "ren",
                child_running,
            })
        else
            try std.fmt.allocPrint(arena, "{d} child{s}", .{
                child_count,
                if (child_count == 1) "" else "ren",
            })
    else
        "";
    const child_style = if (child_approvals > 0)
        Palette.status_approval
    else if (child_errors > 0)
        Palette.status_error
    else if (child_running > 0)
        Palette.status_running
    else
        Palette.status_child;
    var work_agents: usize = 0;
    var work_processes: usize = 0;
    for (app.view.guest_activity) |item| switch (item.kind) {
        .agent => work_agents += 1,
        .process => work_processes += 1,
        .tool => {},
    };
    const work_txt: []const u8 = if (work_agents > 0 and work_processes > 0)
        try std.fmt.allocPrint(arena, "{d} agent{s} · {d} proc{s}", .{
            work_agents,
            if (work_agents == 1) "" else "s",
            work_processes,
            if (work_processes == 1) "" else "s",
        })
    else if (work_agents > 0)
        try std.fmt.allocPrint(arena, "{d} agent{s}", .{ work_agents, if (work_agents == 1) "" else "s" })
    else if (work_processes > 0)
        try std.fmt.allocPrint(arena, "{d} proc{s}", .{ work_processes, if (work_processes == 1) "" else "s" })
    else
        "";
    var background_running: usize = 0;
    var background_approvals: usize = 0;
    for (app.sessions.items) |session| {
        if (session.sid == app.view.sid) continue;
        // The hierarchy segment owns the focused parent/child relationship;
        // keep the generic background counter for unrelated sessions and
        // running siblings rather than showing the same activity twice.
        if (session.parent_sid == app.view.sid) continue;
        if (focused_parent_sid != null and session.sid == focused_parent_sid.?) continue;
        switch (session.state) {
            .running => background_running += 1,
            .awaiting_approval => background_approvals += 1,
            else => {},
        }
    }
    const background_txt = if (background_running > 0 or background_approvals > 0)
        try std.fmt.allocPrint(arena, "{d} running · {d} approval{s}", .{
            background_running,
            background_approvals,
            if (background_approvals == 1) "" else "s",
        })
    else
        "";

    var status_segments: [41]vaxis.Segment = undefined;
    var status_n: usize = 0;
    status_segments[status_n] = .{ .text = " ", .style = Palette.status_bar };
    status_n += 1;
    status_segments[status_n] = .{ .text = state_txt, .style = state_style };
    status_n += 1;
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = try statusModel(arena, app.view.model.items), .style = Palette.status_model };
    status_n += 1;
    if (app.view.effort != .auto) {
        status_segments[status_n] = .{
            .text = try std.fmt.allocPrint(arena, " {s}", .{@tagName(app.view.effort)}),
            .style = Palette.status_effort,
        };
        status_n += 1;
    }
    if (ctx_txt.len > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = ctx_txt, .style = ctx_style };
        status_n += 1;
    }
    if (try statusGuestProcess(arena, app.view.model.items, app.view.guest_pid)) |process_txt| {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = process_txt, .style = Palette.status_muted };
        status_n += 1;
    }
    status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
    status_n += 1;
    status_segments[status_n] = .{ .text = cwd_txt, .style = Palette.status_cwd };
    status_n += 1;
    if (app.git_supported and app.git_sid == app.view.sid and std.mem.eql(u8, app.git_cwd.items, app.view.cwd.items) and app.git_label.items.len > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        const git_label = app.git_label.items;
        const counts_at = std.mem.indexOf(u8, git_label, " ↑") orelse git_label.len;
        status_segments[status_n] = .{ .text = git_label[0..counts_at], .style = Palette.status_cwd };
        status_n += 1;
        var git_parts = std.mem.tokenizeScalar(u8, git_label[counts_at..], ' ');
        while (git_parts.next()) |part| {
            const ahead = std.mem.startsWith(u8, part, "↑");
            if (!ahead and !std.mem.startsWith(u8, part, "↓")) continue;
            status_segments[status_n] = .{
                .text = if (ahead) " ↑" else " ↓",
                .style = if (ahead) Palette.status_git_ahead else Palette.status_git_behind,
            };
            status_n += 1;
            status_segments[status_n] = .{ .text = part["↑".len..], .style = Palette.status_bar };
            status_n += 1;
        }
    }
    if (app.view.scroll_up > 0 or app.view.history_has_newer) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = scroll_txt, .style = Palette.status_bar };
        status_n += 1;
    }
    if (child_txt.len > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = child_txt, .style = child_style };
        status_n += 1;
    }
    if (work_txt.len > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{ .text = work_txt, .style = Palette.status_running };
        status_n += 1;
    }
    if (background_txt.len > 0) {
        status_segments[status_n] = .{ .text = " · ", .style = Palette.status_sep };
        status_n += 1;
        status_segments[status_n] = .{
            .text = background_txt,
            .style = if (background_approvals > 0) Palette.status_approval else Palette.status_running,
        };
        status_n += 1;
    }
    if (app.reconnecting or app.notice.items.len > 0) {
        status_segments[status_n] = .{ .text = "  ", .style = Palette.status_bar };
        status_n += 1;
        status_segments[status_n] = .{ .text = if (app.reconnecting) "offline — reconnecting…" else app.notice.items, .style = Palette.status_notice };
        status_n += 1;
    }
    _ = status_win.print(status_segments[0..status_n], .{ .wrap = .none });

    // Far-right indicators: shell sandbox state and DNS blocklist filtering.
    // Their colors carry state; keeping them to one glyph apiece leaves room
    // for the session-specific status. Guest sessions cannot use either, so
    // both glyphs are muted rather than reading as toggled off.
    const sandboxed_now = app.currentSandboxed();
    const sandbox_txt = "⛨";
    const sandbox_style = if (guest)
        Palette.status_muted
    else if (sandboxed_now)
        Palette.status_running
    else if (app.conn.sandbox_available)
        Palette.status_context_warn
    else
        Palette.status_sep;
    const sandbox_cols: u16 = @intCast(displayWidth(sandbox_txt));
    const dns_available = app.conn.network_filtering;
    const dns_on = app.currentNetworkFiltering();
    const dns_txt = "⊘";
    const dns_style = if (guest)
        Palette.status_muted
    else if (dns_on)
        Palette.status_running
    else if (dns_available or app.conn.network_configured)
        Palette.status_context_warn
    else
        Palette.status_sep;
    const dns_cols: u16 = @intCast(displayWidth(dns_txt));
    const mode_txt: []const u8 = if (app.view.plan_mode) "PLAN" else if (app.view.permissions_full) "FULL ACCESS" else "";
    // Voice dictation state. Invisible until /voice setup enables it —
    // dormant means dormant — then a quiet armed hint that turns loud
    // while a capture or transcription is in flight.
    var voice_buf: [24]u8 = undefined;
    var voice_txt: []const u8 = "";
    var voice_cols: u16 = 0;
    var voice_style: vaxis.Style = Palette.status_sep;
    if (app.voice_rt.enabled) switch (app.voice_rt.phase) {
        .idle => {
            const ptt = if (app.voice_rt.setup) |st|
                st.mode == .ptt and app.voice_rt.kitty_release
            else
                false;
            voice_txt = if (ptt) "mic·ptt" else "mic·tap";
            voice_cols = 7; // "·" renders one cell
        },
        .recording => {
            const secs = @divTrunc(@max(0, nowWallMs(app.io) - app.voice_rt.record_started_ms), 1000);
            voice_txt = std.fmt.bufPrint(&voice_buf, "● rec {d}s", .{secs}) catch "● rec";
            voice_cols = @intCast(voice_txt.len - "●".len + 1);
            voice_style = Palette.status_approval;
        },
        .transcribing => {
            voice_txt = "… stt";
            voice_cols = 5;
            voice_style = Palette.status_running;
        },
    };
    // OTLP export indicator: one quiet glyph, green while spans flow, the
    // approval yellow when conversation CONTENT is being shipped too — the
    // one telemetry state worth a louder color. Absent when off.
    const otel_on = app.conn.otel_enabled;
    const otel_style = if (app.conn.otel_content) Palette.status_approval else Palette.status_running;
    var right_w: u16 = sandbox_cols + 1 + dns_cols + 3;
    if (mode_txt.len > 0) right_w += @intCast(mode_txt.len + 3);
    if (voice_txt.len > 0) right_w += voice_cols + 3;
    if (otel_on) right_w += 1 + 3;
    if (status_win.width > right_w) {
        const right_win = status_win.child(.{
            .x_off = @intCast(status_win.width - right_w),
            .width = right_w,
        });
        var right_segments: [10]vaxis.Segment = undefined;
        var right_n: usize = 0;
        if (otel_on) {
            right_segments[right_n] = .{ .text = "∿", .style = otel_style };
            right_n += 1;
            right_segments[right_n] = .{ .text = " · ", .style = Palette.status_sep };
            right_n += 1;
        }
        if (voice_txt.len > 0) {
            right_segments[right_n] = .{ .text = voice_txt, .style = voice_style };
            right_n += 1;
            right_segments[right_n] = .{ .text = " · ", .style = Palette.status_sep };
            right_n += 1;
        }
        if (mode_txt.len > 0) {
            right_segments[right_n] = .{ .text = mode_txt, .style = if (app.view.plan_mode) Palette.plan_active else Palette.status_approval };
            right_n += 1;
            right_segments[right_n] = .{ .text = " · ", .style = Palette.status_sep };
            right_n += 1;
        }
        right_segments[right_n] = .{ .text = dns_txt, .style = dns_style };
        right_n += 1;
        right_segments[right_n] = .{ .text = " · ", .style = Palette.status_sep };
        right_n += 1;
        right_segments[right_n] = .{ .text = sandbox_txt, .style = sandbox_style };
        right_n += 1;
        right_segments[right_n] = .{ .text = " ", .style = Palette.status_bar };
        right_n += 1;
        _ = right_win.print(right_segments[0..right_n], .{ .wrap = .none });
    }

    // ---- model / reasoning-effort selector overlay ----
    if (app.picker) |sel| {
        const items = try app.pickerItems(arena);
        const total_src = app.pickerSourceCount();
        const current = app.pickerCurrent();
        const picker_label: []const u8 = switch (app.picker_kind) {
            .model => "model",
            .effort => "effort",
            .session => "sessions",
            .search_prompt => if (app.search.scope_sid == 0) "search all sessions" else "search this session",
            .search => if (app.search.scope_sid == 0) "search results" else "session matches",
            .council => try std.fmt.allocPrint(arena, "council {s} · {d} selected", .{
                app.council_edit_name.items,
                app.council_edit_models.items.len,
            }),
            .council_list => "councils",
            .voice_engine => "voice engine",
            .voice_mode => "voice input mode",
            .setup_provider => "setup · choose a backend",
        };

        const list_max: u16 = @min(@as(u16, 14), h -| 6);
        const win_start = if (sel >= list_max) sel + 1 - list_max else 0;
        const visible_end = @min(items.len, win_start + list_max);
        var widest: usize = 30;
        for (items[win_start..visible_end]) |f| {
            const displayed = if (app.picker_kind == .search)
                try pickerTextPreview(arena, f)
            else
                f;
            var row_width = displayWidth(displayed);
            if (app.picker_kind == .setup_provider) row_width += displayWidth(app.setupProviderNote(f));
            if (app.picker_kind == .council and !std.mem.eql(u8, f, council_done_item)) row_width += 2;
            if (app.picker_kind == .model or app.picker_kind == .council) {
                if (proto.isGuestModel(f)) row_width += displayWidth("(guest) ");
                if (app.pricingForModel(f)) |pricing| {
                    row_width += 2 + displayWidth(try formatModelPricing(arena, pricing));
                }
            }
            widest = @max(widest, @min(row_width, 96));
        }
        const box_w: u16 = @intCast(@min(widest + 8, @as(usize, w -| 4)));
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
        const src_note: []const u8 = if ((app.picker_kind == .model or app.picker_kind == .council) and app.catalog.items.len == 0)
            " (favorites — catalog loading…)"
        else if (app.typedModelFallback(items.len) != null)
            " (not listed — Enter uses it as typed)"
        else
            "";
        const fline = try std.fmt.allocPrint(arena, " {s} · filter: {s}▏{s}", .{
            picker_label,
            app.picker_filter.items,
            src_note,
        });
        _ = box.printSegment(.{ .text = fline, .style = Palette.user }, .{ .wrap = .none });

        // Windowed list around the selection.
        var row: u16 = 1;
        var i: usize = win_start;
        while (i < items.len and row <= shown) : (i += 1) {
            const f = items[i];
            const done = app.picker_kind == .council and std.mem.eql(u8, f, council_done_item);
            const cur = if (app.picker_kind == .session)
                (app.sessionIdForLabel(f) orelse 0) == app.view.sid
            else if (app.picker_kind == .council)
                !done and app.councilModelSelected(f)
            else
                std.mem.eql(u8, f, current);
            const line = if (app.picker_kind == .model)
                try pickerModelLine(arena, f, app.pricingForModel(f), if (cur) " ●" else "", box_w -| 4)
            else if (app.picker_kind == .council)
                if (done)
                    try std.fmt.allocPrint(arena, " ✓ Done ({d} selected)", .{app.council_edit_models.items.len})
                else
                    try pickerModelLine(arena, f, app.pricingForModel(f), if (cur) " ☑" else " ☐", box_w -| 4)
            else if (app.picker_kind == .council_list)
                if (app.councilByName(f)) |council|
                    try std.fmt.allocPrint(arena, " {s} · {d} models", .{ f, council.models.items.len })
                else
                    f
            else if (app.picker_kind == .search)
                try std.fmt.allocPrint(arena, " {s}", .{try pickerTextPreview(arena, f)})
            else if (app.picker_kind == .setup_provider)
                try std.fmt.allocPrint(arena, " {s}{s}", .{ f, app.setupProviderNote(f) })
            else
                try std.fmt.allocPrint(arena, " {s}{s}", .{ f[0..@min(f.len, box_w -| 4)], if (cur) " ●" else "" });
            const style: vaxis.Style = if (i == sel)
                .{ .fg = .{ .index = 6 }, .bold = true, .reverse = true }
            else if (cur)
                .{ .fg = .{ .index = 6 } }
            else
                .{};
            _ = box.printSegment(.{ .text = line, .style = style }, .{ .row_offset = row, .wrap = .none });
            row += 1;
        }
        const hint = switch (app.picker_kind) {
            .session => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter · Del/Ctrl+D archive · Esc", .{ items.len, total_src }),
            .search_prompt => if (app.search.pending) " searching… · Esc" else " type query · Enter search · Esc",
            .search => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter jump · Esc", .{ items.len, total_src }),
            .council => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter toggle/Done · Esc cancel", .{ items.len -| 1, total_src }),
            .council_list => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter inspect · Esc", .{ items.len, total_src }),
            .setup_provider => " type=filter · ↑↓ · Enter choose · Esc close",
            else => try std.fmt.allocPrint(arena, " {d}/{d} · type=filter · ↑↓ · Enter · Esc", .{ items.len, total_src }),
        };
        _ = box.printSegment(.{ .text = hint, .style = Palette.tool_out }, .{ .row_offset = shown + 1, .wrap = .none });
    }

    if (app.council_detail_name.items.len > 0 and app.picker == null)
        try drawCouncilDetail(app, win, arena)
    else if (app.shortcut_help and app.picker == null)
        try drawShortcutHelp(app, win, arena);

    // The whole normal UI is in the window right now and the effect overlay
    // is about to cover it: the moment a live backdrop can be captured.
    if (app.screensaver_active) {
        if (app.effect_engine) |*engine| engine.refreshBackdrop(win);
    }
    drawUiAnimation(app, win);
    if (!app.screensaver_active) {
        if (hovered_timestamp) |timestamp|
            try drawTimestampOverlay(win, arena, timestamp_row, timestamp);
    }
}

pub fn drawTimestampOverlay(win: vaxis.Window, arena: std.mem.Allocator, row: u16, timestamp: i64) !void {
    if (win.width < 10 or row >= win.height) return;
    var buf: [80]u8 = undefined;
    const full = daybreak.formatLocalTimestamp(&buf, timestamp) orelse return;
    const capacity = win.width - 2;
    const label = if (displayWidth(full) <= capacity) full else if (displayWidth(full[11..]) <= capacity) full[11..] else full[11..19];
    const width: u16 = @intCast(displayWidth(label) + 2);
    const badge = win.child(.{ .x_off = win.width - width, .y_off = row, .width = width, .height = 1 });
    badge.fill(.{ .style = Palette.timestamp });
    _ = badge.printSegment(.{
        .text = try std.fmt.allocPrint(arena, " {s} ", .{label}),
        .style = Palette.timestamp,
    }, .{ .wrap = .none });
}

fn transientAnimationOpacity(frame: usize, fast: bool) u8 {
    const fade_frames: usize = if (fast) 36 else 18;
    if (frame < fade_frames) return @intCast(frame * 255 / fade_frames);
    const frame_limit = if (fast) fast_transient_animation_frames else transient_animation_frames;
    const remaining = (frame_limit - 1) -| frame;
    if (remaining < fade_frames) return @intCast(remaining * 255 / fade_frames);
    return 255;
}

pub fn drawUiAnimation(app: *const App, win: vaxis.Window) void {
    const engine = if (app.effect_engine) |*value| value else return;
    if (app.screensaver_active) {
        engine.draw(win, .full_screen, 255);
        win.hideCursor();
        return;
    }
    if (app.ui_animation != null) {
        // Pixel images and game boards cannot interleave with text: a transient
        // /animate of those runs opaque for its duration instead.
        if (engine.kind().fullScreenOnly()) {
            engine.draw(win, .full_screen, 255);
            win.hideCursor();
        } else {
            engine.draw(win, .interleaved, transientAnimationOpacity(app.ui_animation_frame, app.fast_effect_active.load(.acquire)));
        }
    }
}

// ------------------------------------------------------------ entry point --
