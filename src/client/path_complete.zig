//! Directory completion for `/cwd`: the argument typed so far — relative to
//! the session's working directory, under `~`, or absolute — becomes the
//! matching subdirectories, each in the form the user was typing so Tab
//! walks down a tree one segment at a time.
const std = @import("std");
const Io = std.Io;

pub const Candidate = struct {
    /// The whole argument after acceptance: typed prefix + name + '/'.
    arg: []const u8,
    name: []const u8,
};

pub const max_candidates = 12;

/// Matching directories for `typed`. Unknown directories and unreadable
/// entries yield nothing rather than an error: this runs on every keystroke.
pub fn directories(arena: std.mem.Allocator, io: Io, session_cwd: []const u8, home: ?[]const u8, typed: []const u8) ![]Candidate {
    return matchingDirectories(arena, io, session_cwd, home, typed, max_candidates);
}

/// Complete against every match, including entries beyond the visible menu.
/// Never choose an arbitrary child when more than one directory matches.
pub fn complete(arena: std.mem.Allocator, io: Io, session_cwd: []const u8, home: ?[]const u8, typed: []const u8) ![]const u8 {
    const matches = try matchingDirectories(arena, io, session_cwd, home, typed, std.math.maxInt(usize));
    if (matches.len == 0) return typed;
    var prefix = matches[0].arg;
    for (matches[1..]) |candidate| {
        var n: usize = 0;
        while (n < prefix.len and n < candidate.arg.len and prefix[n] == candidate.arg[n]) : (n += 1) {}
        // A byte prefix may end inside a multibyte filename character.
        while (n > 0 and n < prefix.len and prefix[n] & 0xc0 == 0x80) n -= 1;
        prefix = prefix[0..n];
    }
    return if (prefix.len > typed.len) prefix else typed;
}

fn matchingDirectories(arena: std.mem.Allocator, io: Io, session_cwd: []const u8, home: ?[]const u8, typed: []const u8, limit: usize) ![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    if (std.mem.eql(u8, typed, "~")) {
        if (home != null) try out.append(arena, .{ .arg = "~/", .name = "~" });
        return out.items;
    }
    const split = if (std.mem.lastIndexOfScalar(u8, typed, '/')) |i| i + 1 else 0;
    const prefix = typed[0..split];
    const base = typed[split..];

    const lookup: []const u8 = if (std.mem.startsWith(u8, prefix, "~/"))
        try std.fs.path.join(arena, &.{ home orelse return out.items, prefix[1..] })
    else if (prefix.len > 0 and prefix[0] == '/')
        prefix
    else
        try std.fs.path.join(arena, &.{ if (session_cwd.len > 0) session_cwd else ".", prefix });

    var dir = Io.Dir.cwd().openDir(io, lookup, .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.name.len == 0) continue;
        if (entry.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;
        if (entry.name.len < base.len or !std.mem.eql(u8, entry.name[0..base.len], base)) continue;
        const is_dir = switch (entry.kind) {
            .directory => true,
            .sym_link => blk: {
                var target = dir.openDir(io, entry.name, .{}) catch break :blk false;
                target.close(io);
                break :blk true;
            },
            else => false,
        };
        if (!is_dir) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    for (names.items[0..@min(names.items.len, limit)]) |name| {
        try out.append(arena, .{
            .arg = try std.fmt.allocPrint(arena, "{s}{s}/", .{ prefix, name }),
            .name = name,
        });
    }
    return out.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}
