//! The original's menu machinery as plain data: a stack of pages, each a
//! list of buttons and toggles with a layout, drawn with the bitmap fonts.
//! Entries carry an action code and a data value that the owning screen
//! interprets, so the whole thing lives in the snapshot.

const std = @import("std");
const math = @import("math.zig");
const input = @import("input.zig");
const render = @import("render.zig");
const ui_mod = @import("ui.zig");
const Vec2i = math.Vec2i;
const Rgba = math.Rgba;
const Ui = ui_mod.Ui;
const Anchor = ui_mod.Anchor;

pub const max_pages = 8;
pub const max_entries = 32;
pub const label_len = 24;

pub const Layout = struct {
    pub const vertical: u8 = 1 << 0;
    pub const horizontal: u8 = 1 << 1;
    pub const fixed: u8 = 1 << 2;
    pub const align_center: u8 = 1 << 3;
    pub const align_block: u8 = 1 << 4;
};

pub const EntryKind = enum(u8) { button, toggle };

pub const Entry = extern struct {
    kind: EntryKind,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Screen-defined action code; 0 means nothing happens.
    action: u16,
    /// For buttons: payload. For toggles: the current option index.
    data: i32,
    /// For toggles: screen-defined option set id and option count.
    options: u16,
    options_len: u16,
    label: [label_len]u8,
};

pub const Page = extern struct {
    title: [32]u8,
    subtitle: [32]u8,
    layout: u8,
    /// Screen-defined page id for custom drawing (0 = none).
    kind: u16,
    entries_len: u8,
    index: i32,
    block_width: i32,
    title_pos: Vec2i,
    title_anchor: u8,
    items_pos: Vec2i,
    items_anchor: u8,
    entries: [max_entries]Entry,

    pub fn addButton(page: *Page, data: i32, text: []const u8, action: u16) *Entry {
        if (page.entries_len >= max_entries - 1) return &page.entries[max_entries - 1];
        const entry = &page.entries[page.entries_len];
        page.entries_len += 1;
        entry.* = std.mem.zeroes(Entry);
        entry.kind = .button;
        entry.data = data;
        entry.action = action;
        setLabel(&entry.label, text);
        return entry;
    }

    pub fn addToggle(page: *Page, data: i32, text: []const u8, options: u16, options_len: u16, action: u16) void {
        addToggleTo(page, data, text, options, options_len, action);
    }
};

pub const Event = union(enum) {
    none,
    back,
    /// A button was chosen or a toggle changed.
    select: struct { action: u16, data: i32 },
};

pub fn setLabel(buf: []u8, text: []const u8) void {
    @memset(buf, 0);
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
}

pub fn label(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

pub const Menu = extern struct {
    pages: [max_pages]Page,
    index: i32,

    pub fn reset(self: *Menu) void {
        self.index = -1;
    }

    pub fn depth(self: *const Menu) usize {
        return @intCast(@max(self.index + 1, 0));
    }

    pub fn current(self: *Menu) ?*Page {
        if (self.index < 0) return null;
        return &self.pages[@intCast(self.index)];
    }

    pub fn push(self: *Menu, title: []const u8, kind: u16) *Page {
        if (self.index >= max_pages - 1) self.index = max_pages - 2;
        self.index += 1;
        const page = &self.pages[@intCast(self.index)];
        page.* = std.mem.zeroes(Page);
        page.layout = Layout.vertical | Layout.align_center;
        page.block_width = 320;
        setLabel(&page.title, title);
        page.kind = kind;
        page.title_anchor = Anchor.middle | Anchor.center;
        page.items_anchor = Anchor.middle | Anchor.center;
        return page;
    }

    /// Two-button question laid out horizontally; `yes` carries data 1,
    /// `no` data 0, both with `action`. The cursor starts on `no`.
    pub fn confirm(self: *Menu, title: []const u8, subtitle: []const u8, yes: []const u8, no: []const u8, action: u16) *Page {
        const page = self.push(title, 0);
        page.layout = Layout.horizontal;
        setLabel(&page.subtitle, subtitle);
        _ = page.addButton(1, yes, action);
        _ = page.addButton(0, no, action);
        page.index = 1;
        return page;
    }

    pub fn pop(self: *Menu) void {
        if (self.index > 0) self.index -= 1;
    }

    /// Navigate, toggle, and report what happened this step.
    pub fn update(self: *Menu, in: *const input.State) Event {
        const page = self.current() orelse return .none;
        if (page.entries_len > 0) {
            const last = page.index;
            if (page.layout & Layout.horizontal != 0) {
                if (in.isPressed(.menu_left)) page.index -= 1;
                if (in.isPressed(.menu_right)) page.index += 1;
            } else {
                if (in.isPressed(.menu_up)) page.index -= 1;
                if (in.isPressed(.menu_down)) page.index += 1;
            }
            page.index = wrap(page.index, 0, page.entries_len);
            _ = last;
        }

        if (in.isPressed(.menu_back)) {
            if (self.index != 0) self.pop();
            return .back;
        }
        if (page.entries_len == 0) return .none;

        const entry = &page.entries[@intCast(page.index)];
        if (entry.kind == .toggle) {
            if (in.isPressed(.menu_left)) {
                entry.data = wrap(entry.data - 1, 0, entry.options_len);
                return .{ .select = .{ .action = entry.action, .data = entry.data } };
            }
            if (in.isPressed(.menu_right) or in.isPressed(.menu_select) or in.isPressed(.menu_start)) {
                entry.data = wrap(entry.data + 1, 0, entry.options_len);
                return .{ .select = .{ .action = entry.action, .data = entry.data } };
            }
        } else if (in.isPressed(.menu_select) or in.isPressed(.menu_start)) {
            return .{ .select = .{ .action = entry.action, .data = entry.data } };
        }
        return .none;
    }

    pub const OptionText = *const fn (set: u16, index: i32) []const u8;

    /// Draw title and entries; the screen draws page-specific content
    /// itself before calling this. `blink_on` is the original's 15 Hz
    /// cursor blink.
    pub fn draw(self: *Menu, r: *render.Renderer, ui: *const Ui, blink_on: bool, option_text: OptionText) void {
        const page = self.current() orelse return;
        r.setView2d();
        r.setCullBackface(false);
        defer r.setCullBackface(true);

        if (page.layout & Layout.horizontal != 0) {
            var pos = Vec2i.init(0, -20);
            ui.drawTextCentered(r, label(&page.title), ui.pos(page.title_anchor, pos), .px8, ui_mod.color_default);
            if (page.subtitle[0] != 0) {
                pos.y += 12;
                ui.drawTextCentered(r, label(&page.subtitle), ui.pos(page.title_anchor, pos), .px8, ui_mod.color_default);
            }
            pos.y += 16;
            pos.x = -50;
            for (page.entries[0..page.entries_len], 0..) |*entry, i| {
                const color = if (@as(i32, @intCast(i)) == page.index and blink_on) ui_mod.color_accent else ui_mod.color_default;
                ui.drawTextCentered(r, label(&entry.label), ui.pos(page.items_anchor, pos), .px16, color);
                pos.x = 60;
            }
            return;
        }

        var title_pos: Vec2i = undefined;
        var items_pos: Vec2i = undefined;
        if (page.layout & Layout.fixed == 0) {
            const height: i32 = 20 + @as(i32, page.entries_len) * 12;
            title_pos = Vec2i.init(0, -@divTrunc(height, 2));
            items_pos = Vec2i.init(0, -@divTrunc(height, 2) + 20);
        } else {
            title_pos = page.title_pos;
            items_pos = page.items_pos;
        }
        if (page.layout & Layout.align_center != 0) {
            ui.drawTextCentered(r, label(&page.title), ui.pos(page.title_anchor, title_pos), .px12, ui_mod.color_accent);
        } else {
            ui.drawText(r, label(&page.title), ui.pos(page.title_anchor, title_pos), .px12, ui_mod.color_accent);
        }
        for (page.entries[0..page.entries_len], 0..) |*entry, i| {
            const color = if (@as(i32, @intCast(i)) == page.index and blink_on) ui_mod.color_accent else ui_mod.color_default;
            if (page.layout & Layout.align_center != 0) {
                ui.drawTextCentered(r, label(&entry.label), ui.pos(page.items_anchor, items_pos), .px8, color);
            } else {
                ui.drawText(r, label(&entry.label), ui.pos(page.items_anchor, items_pos), .px8, color);
            }
            if (entry.kind == .toggle) {
                const text = option_text(entry.options, entry.data);
                var toggle_pos = items_pos;
                toggle_pos.x += page.block_width - Ui.textWidth(text, .px8);
                ui.drawText(r, text, ui.pos(page.items_anchor, toggle_pos), .px8, color);
            }
            items_pos.y += 12;
        }
    }
};

pub fn wrap(value: i32, min: i32, max: i32) i32 {
    if (max <= min) return min;
    if (value >= max) return min;
    if (value < min) return max - 1;
    return value;
}

pub fn addToggleTo(page: *Page, data: i32, text: []const u8, options: u16, options_len: u16, action: u16) void {
    if (page.entries_len >= max_entries - 1) return;
    const entry = &page.entries[page.entries_len];
    page.entries_len += 1;
    entry.* = std.mem.zeroes(Entry);
    entry.kind = .toggle;
    entry.data = data;
    entry.action = action;
    entry.options = options;
    entry.options_len = options_len;
    setLabel(&entry.label, text);
}

test "menu navigation wraps and reports selection" {
    var m: Menu = undefined;
    m.reset();
    const page = m.push("TEST", 0);
    _ = page.addButton(10, "A", 1);
    _ = page.addButton(20, "B", 1);
    var in = input.State{};
    in.set(.menu_up, true);
    try std.testing.expect(m.update(&in) == .none);
    try std.testing.expectEqual(@as(i32, 1), m.current().?.index);
    in.endFrame();
    in.set(.menu_select, true);
    const ev = m.update(&in);
    try std.testing.expectEqual(@as(i32, 20), ev.select.data);
}
