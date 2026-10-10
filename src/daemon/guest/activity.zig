//! Ephemeral activity tree shared by delegated guest adapters.

const std = @import("std");
const proto = @import("../../core/proto.zig");

pub const PublishFn = *const fn (?*anyopaque, []const proto.GuestActivity) void;

const Owned = struct {
    id: []u8,
    parent_id: []u8,
    kind: proto.GuestActivityKind,
    name: []u8,
    detail: []u8,
    started_at_ms: i64,

    fn deinit(self: Owned, gpa: std.mem.Allocator) void {
        gpa.free(self.id);
        gpa.free(self.parent_id);
        gpa.free(self.name);
        gpa.free(self.detail);
    }
};

pub const Tracker = struct {
    gpa: std.mem.Allocator,
    callback: ?PublishFn,
    ctx: ?*anyopaque,
    items: std.ArrayList(Owned) = .empty,

    pub fn init(gpa: std.mem.Allocator, callback: ?PublishFn, ctx: ?*anyopaque) Tracker {
        return .{ .gpa = gpa, .callback = callback, .ctx = ctx };
    }

    pub fn deinit(self: *Tracker) void {
        if (self.items.items.len > 0) {
            self.clearItems();
            self.publish();
        }
        self.items.deinit(self.gpa);
    }

    pub fn start(
        self: *Tracker,
        id: []const u8,
        parent_id: []const u8,
        kind: proto.GuestActivityKind,
        name: []const u8,
        detail: []const u8,
        started_at_ms: i64,
    ) !void {
        if (id.len == 0) return;
        for (self.items.items) |*item| if (std.mem.eql(u8, item.id, id)) {
            const new_parent = try self.gpa.dupe(u8, parent_id);
            errdefer self.gpa.free(new_parent);
            const new_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(new_name);
            const new_detail = try self.gpa.dupe(u8, detail);
            self.gpa.free(item.parent_id);
            self.gpa.free(item.name);
            self.gpa.free(item.detail);
            item.parent_id = new_parent;
            item.name = new_name;
            item.detail = new_detail;
            item.kind = kind;
            self.publish();
            return;
        };
        const owned_id = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned_id);
        const owned_parent = try self.gpa.dupe(u8, parent_id);
        errdefer self.gpa.free(owned_parent);
        const owned_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned_name);
        const owned_detail = try self.gpa.dupe(u8, detail);
        errdefer self.gpa.free(owned_detail);
        const owned = Owned{
            .id = owned_id,
            .parent_id = owned_parent,
            .kind = kind,
            .name = owned_name,
            .detail = owned_detail,
            .started_at_ms = started_at_ms,
        };
        try self.items.append(self.gpa, owned);
        self.publish();
    }

    pub fn isNested(self: *const Tracker, id: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.id, id)) return item.parent_id.len > 0;
        }
        return false;
    }

    pub fn contains(self: *const Tracker, id: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.id, id)) return true;
        }
        return false;
    }

    pub fn finish(self: *Tracker, id: []const u8) void {
        var removed = false;
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            const item = self.items.items[i];
            if (!std.mem.eql(u8, item.id, id) and !descendsFrom(self.items.items, item.parent_id, id)) continue;
            self.items.orderedRemove(i).deinit(self.gpa);
            removed = true;
        }
        if (removed) self.publish();
    }

    pub fn clearKind(self: *Tracker, kind: proto.GuestActivityKind) void {
        var changed = false;
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            if (self.items.items[i].kind != kind) continue;
            self.items.orderedRemove(i).deinit(self.gpa);
            changed = true;
        }
        if (changed) self.publish();
    }

    fn clearItems(self: *Tracker) void {
        for (self.items.items) |item| item.deinit(self.gpa);
        self.items.clearRetainingCapacity();
    }

    fn publish(self: *Tracker) void {
        const callback = self.callback orelse return;
        var snapshot: std.ArrayList(proto.GuestActivity) = .empty;
        defer snapshot.deinit(self.gpa);
        snapshot.ensureTotalCapacity(self.gpa, self.items.items.len) catch return;
        for (self.items.items) |item| snapshot.appendAssumeCapacity(.{
            .id = item.id,
            .parent_id = item.parent_id,
            .kind = item.kind,
            .name = item.name,
            .detail = item.detail,
            .started_at_ms = item.started_at_ms,
        });
        callback(self.ctx, snapshot.items);
    }
};

fn descendsFrom(items: []const Owned, parent_id: []const u8, ancestor_id: []const u8) bool {
    var cursor = parent_id;
    var depth: usize = 0;
    while (cursor.len > 0 and depth < items.len) : (depth += 1) {
        if (std.mem.eql(u8, cursor, ancestor_id)) return true;
        var next: []const u8 = "";
        for (items) |item| if (std.mem.eql(u8, item.id, cursor)) {
            next = item.parent_id;
            break;
        };
        cursor = next;
    }
    return false;
}

test "finishing an agent removes its active descendants" {
    var seen: usize = 99;
    const Sink = struct {
        fn publish(ctx: ?*anyopaque, items: []const proto.GuestActivity) void {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            count.* = items.len;
        }
    };
    var tracker = Tracker.init(std.testing.allocator, Sink.publish, &seen);
    defer tracker.deinit();
    try tracker.start("agent", "", .agent, "Agent", "inspect", 1);
    try tracker.start("tool", "agent", .tool, "Bash", "tests", 2);
    try std.testing.expectEqual(@as(usize, 2), seen);
    tracker.finish("agent");
    try std.testing.expectEqual(@as(usize, 0), seen);
}
