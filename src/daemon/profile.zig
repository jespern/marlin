//! The user's standing preferences: `~/.config/marlin/profile.md`, shared
//! with every agent regardless of regime. Native turns get it in the system
//! prompt; Claude Code through `--append-system-prompt`; Codex through
//! `developerInstructions`. Those channels are re-sent on every invocation,
//! so the profile survives the guest's own compaction, unlike a user message.
//!
//! Text before the first `## project: <names>` heading applies everywhere.
//! A project section (comma-separated names) applies when any component of
//! the session cwd equals one of its names, so `## project: mirador` covers
//! every repo under `~/Work/mirador/`. A section ends at the next `#`/`##`
//! heading. Read fresh each turn so edits apply immediately, like MARLIN.md.
const std = @import("std");
const Io = std.Io;
const credentials = @import("../core/credentials.zig");

pub const file_name = "profile.md";
pub const max_bytes = 48 * 1024;

const project_prefix = "## project:";

pub const header =
    "USER PROFILE (the user's standing preferences across all sessions and agents; " ++
    "follow them unless the user says otherwise in this session)\n";

/// The model-facing profile section for a session cwd, or null when the file
/// is missing, unreadable, oversized, or nothing in it applies. Caller frees.
pub fn load(gpa: std.mem.Allocator, io: Io, environ: ?*const std.process.Environ.Map, cwd: []const u8) ?[]u8 {
    const env = environ orelse return null;
    const dir = credentials.configDir(gpa, env) catch return null;
    defer gpa.free(dir);
    const path = std.fs.path.join(gpa, &.{ dir, file_name }) catch return null;
    defer gpa.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes)) catch return null;
    defer gpa.free(bytes);
    return render(gpa, bytes, cwd) catch null;
}

/// `header` plus the scoped text, or null when nothing applies.
pub fn render(gpa: std.mem.Allocator, text: []const u8, cwd: []const u8) !?[]u8 {
    const scoped = try select(gpa, text, cwd);
    defer gpa.free(scoped);
    const body = std.mem.trim(u8, scoped, " \t\r\n");
    if (body.len == 0) return null;
    return try std.mem.concat(gpa, u8, &.{ header, body });
}

/// The global text plus every project section that matches `cwd`.
pub fn select(gpa: std.mem.Allocator, text: []const u8, cwd: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var keep = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, project_prefix)) {
            keep = sectionMatches(line[project_prefix.len..], cwd);
        } else if (std.mem.startsWith(u8, line, "# ") or std.mem.startsWith(u8, line, "## ")) {
            keep = true;
        }
        if (!keep) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

fn sectionMatches(names: []const u8, cwd: []const u8) bool {
    var it = std.mem.splitScalar(u8, names, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\r");
        if (name.len > 0 and hasComponent(cwd, name)) return true;
    }
    return false;
}

/// True when `name` is one whole path component of `cwd`.
pub fn hasComponent(cwd: []const u8, name: []const u8) bool {
    var parts = std.mem.splitScalar(u8, cwd, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
