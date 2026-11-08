//! Live output of a Claude Code guest's background work, while it runs.
//!
//! A background command writes its output to a file whose path Claude Code
//! reports in the tool result ("Output is being written to: …"), and each
//! subagent writes its transcript to `<config>/projects/<project>/<session>/
//! subagents/agent-<id>.jsonl`, named with the tool-use id that launched it in
//! a `.meta.json` beside it. The Tailer reads what those files gain into the
//! activity tree the moment the OS reports a change (kqueue, inotify), so
//! `top` and its output view (Ctrl+S, Enter) show the work as it happens
//! instead of only when it ends.
//!
//! A reported path is model-controlled text, so only files inside the guest
//! session's own task and subagent folders are ever opened, after symlinks are
//! resolved.
const std = @import("std");
const Io = std.Io;
const guest_activity = @import("activity.zig");
const file_watch = @import("file_watch.zig");

/// How often files are read where the OS offers no change events (neither
/// kqueue nor inotify). Elsewhere every read follows an event.
const fallback_poll_ms: i64 = 400;
/// Most bytes read from one file per poll; the tracker keeps the newest anyway.
const max_read_bytes: usize = 256 * 1024;
/// A transcript line longer than this is skipped rather than buffered.
const max_line_bytes: usize = 4 * 1024 * 1024;

pub const Kind = enum {
    /// Plain output, shown as written.
    text,
    /// A subagent's JSONL transcript, condensed to readable rows.
    transcript,
};

/// The output path a background command's tool result names, if any.
pub fn backgroundOutputPath(result: []const u8) ?[]const u8 {
    const marker = "Output is being written to: ";
    const start = (std.mem.indexOf(u8, result, marker) orelse return null) + marker.len;
    var end = start;
    while (end < result.len and !std.ascii.isWhitespace(result[end])) end += 1;
    const path = std.mem.trimEnd(u8, result[start..end], ".");
    if (path.len == 0 or path[0] != '/') return null;
    return path;
}

/// Whether a resolved path is a task output of this guest session:
/// `…/<session>/tasks/<name>.output`, with a plain file name.
pub fn isTaskOutput(real: []const u8, session_uuid: []const u8) bool {
    const name = std.fs.path.basename(real);
    if (!std.mem.endsWith(u8, name, ".output") or !plainName(name[0 .. name.len - ".output".len])) return false;
    const tasks = std.fs.path.dirname(real) orelse return false;
    if (!std.mem.eql(u8, std.fs.path.basename(tasks), "tasks")) return false;
    const session = std.fs.path.dirname(tasks) orelse return false;
    return std.mem.eql(u8, std.fs.path.basename(session), session_uuid);
}

/// Whether a resolved path is a subagent transcript of this guest session:
/// `<projects>/<project>/<session>/subagents/agent-<id>.jsonl`.
pub fn isSubagentTranscript(real: []const u8, projects: []const u8, session_uuid: []const u8) bool {
    const name = std.fs.path.basename(real);
    if (!std.mem.startsWith(u8, name, "agent-") or !std.mem.endsWith(u8, name, ".jsonl")) return false;
    if (!plainName(name[0 .. name.len - ".jsonl".len])) return false;
    const subagents = std.fs.path.dirname(real) orelse return false;
    if (!std.mem.eql(u8, std.fs.path.basename(subagents), "subagents")) return false;
    const session = std.fs.path.dirname(subagents) orelse return false;
    if (!std.mem.eql(u8, std.fs.path.basename(session), session_uuid)) return false;
    const project = std.fs.path.dirname(session) orelse return false;
    const parent = std.fs.path.dirname(project) orelse return false;
    return std.mem.eql(u8, parent, std.mem.trimEnd(u8, projects, "/"));
}

/// path with its symlinks resolved, owned by gpa; null if it does not resolve.
fn resolve(gpa: std.mem.Allocator, io: Io, path: []const u8) ?[]u8 {
    const real = Io.Dir.cwd().realPathFileAlloc(io, path, gpa) catch return null;
    defer gpa.free(real);
    return gpa.dupe(u8, real) catch null;
}

fn plainName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
    return true;
}

/// Claude Code's projects folder: `$CLAUDE_CONFIG_DIR/projects`, else
/// `$HOME/.claude/projects`.
pub fn projectsDir(gpa: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]u8 {
    const env = environ orelse return null;
    if (env.get("CLAUDE_CONFIG_DIR")) |dir| if (dir.len > 0) return try std.fs.path.join(gpa, &.{ dir, "projects" });
    const home = env.get("HOME") orelse return null;
    return try std.fs.path.join(gpa, &.{ home, ".claude", "projects" });
}

/// The transcript of the subagent tool_use_id launched in this session, found
/// by its `.meta.json`, or null while Claude Code has not written it yet.
pub fn findSubagentTranscript(
    gpa: std.mem.Allocator,
    io: Io,
    projects: []const u8,
    session_uuid: []const u8,
    tool_use_id: []const u8,
) !?[]u8 {
    var root = Io.Dir.cwd().openDir(io, projects, .{ .iterate = true }) catch return null;
    defer root.close(io);
    var projects_it = root.iterate();
    while (projects_it.next(io) catch null) |project| {
        if (project.kind != .directory) continue;
        const sub = try std.fs.path.join(gpa, &.{ projects, project.name, session_uuid, "subagents" });
        defer gpa.free(sub);
        var dir = Io.Dir.cwd().openDir(io, sub, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".meta.json")) continue;
            const meta = dir.readFileAlloc(io, entry.name, gpa, .limited(64 * 1024)) catch continue;
            defer gpa.free(meta);
            const parsed = std.json.parseFromSlice(std.json.Value, gpa, meta, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const id = parsed.value.object.get("toolUseId") orelse continue;
            if (id != .string or !std.mem.eql(u8, id.string, tool_use_id)) continue;
            const stem = entry.name[0 .. entry.name.len - ".meta.json".len];
            const jsonl = try std.fmt.allocPrint(gpa, "{s}.jsonl", .{stem});
            defer gpa.free(jsonl);
            return try std.fs.path.join(gpa, &.{ sub, jsonl });
        }
    }
    return null;
}

/// One transcript line as readable rows: the subagent's prose, its tool calls
/// (→ name and their gist) and their results (↳ first line). Its prompt and
/// anything unrecognised are left out.
pub fn condenseTranscriptLine(arena: std.mem.Allocator, line: []const u8, out: *std.ArrayList(u8)) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return;
    if (parsed != .object) return;
    const kind = parsed.object.get("type") orelse return;
    if (kind != .string) return;
    const message = parsed.object.get("message") orelse return;
    if (message != .object) return;
    const content = message.object.get("content") orelse return;
    if (content != .array) return;
    for (content.array.items) |block| {
        if (block != .object) continue;
        const block_type = block.object.get("type") orelse continue;
        if (block_type != .string) continue;
        if (std.mem.eql(u8, block_type.string, "text")) {
            const text = stringField(block, "text") orelse continue;
            const trimmed = std.mem.trim(u8, text, " \n");
            if (trimmed.len == 0) continue;
            try out.appendSlice(arena, trimmed);
            try out.append(arena, '\n');
        } else if (std.mem.eql(u8, block_type.string, "tool_use")) {
            const name = stringField(block, "name") orelse "tool";
            try out.print(arena, "→ {s}", .{name});
            if (block.object.get("input")) |input| if (toolGist(input)) |gist| {
                try out.print(arena, " {s}", .{firstLine(gist, 160)});
            };
            try out.append(arena, '\n');
        } else if (std.mem.eql(u8, block_type.string, "tool_result")) {
            const failed = if (block.object.get("is_error")) |e| e == .bool and e.bool else false;
            const text = resultText(block) orelse "";
            try out.print(arena, "  {s} {s}\n", .{ if (failed) "✗" else "↳", firstLine(text, 160) });
        }
    }
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return if (field == .string) field.string else null;
}

/// What a tool call is about, by the fields its tools use most.
fn toolGist(input: std.json.Value) ?[]const u8 {
    for ([_][]const u8{ "command", "file_path", "pattern", "path", "url", "query", "description", "prompt" }) |name| {
        if (stringField(input, name)) |value| if (value.len > 0) return value;
    }
    return null;
}

fn resultText(block: std.json.Value) ?[]const u8 {
    const content = block.object.get("content") orelse return null;
    switch (content) {
        .string => |s| return s,
        .array => |items| for (items.items) |item| if (stringField(item, "text")) |text| return text,
        else => {},
    }
    return null;
}

fn firstLine(text: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \n");
    const line = trimmed[0 .. std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len];
    if (line.len <= max) return line;
    var end = max;
    while (end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
    return line[0..end];
}

/// Claude Code's folder name for a project: its working directory with every
/// character that is not an ASCII letter or digit replaced by '-'.
pub fn projectSlug(gpa: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = (std.unicode.Utf8View.init(cwd) catch return gpa.dupe(u8, cwd)).iterator();
    while (it.nextCodepoint()) |cp| {
        const keep = cp < 0x80 and std.ascii.isAlphanumeric(@intCast(cp));
        try out.append(gpa, if (keep) @intCast(cp) else '-');
    }
    return out.toOwnedSlice(gpa);
}

/// Tails watched files into a shared activity tree from its own thread, woken
/// by the OS the moment one of them changes (file_watch).
pub const Tailer = struct {
    gpa: std.mem.Allocator,
    io: Io,
    tracker: *guest_activity.Tracker,
    session_uuid: []const u8,
    /// Claude Code's projects folder, as configured (resolved when used: it
    /// may not exist yet); null when unknown.
    projects: ?[]u8,
    /// This project's folder name in it.
    project_slug: ?[]u8,
    notifier: file_watch.Notifier,
    /// While a subagent's transcript is awaited, the folder watched for it: the
    /// deepest one that exists on the way to the session's subagents folder.
    discovery: ?Discovery = null,
    /// A safety net only: the longest wait between reads, should an event be
    /// missed. Changes are read as their events arrive.
    safety_ms: u32 = 30_000,
    mutex: Io.Mutex = .init,
    watched: std.ArrayList(Watched) = .empty,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    const Discovery = struct { path: []u8, handle: file_watch.Handle };

    const Watched = struct {
        id: []u8,
        kind: Kind,
        /// Null for a subagent whose transcript has not appeared yet.
        path: ?[]u8,
        handle: ?file_watch.Handle = null,
        offset: u64 = 0,
        /// An unfinished transcript line, carried to the next read.
        partial: std.ArrayList(u8) = .empty,

        fn deinit(self: *Watched, gpa: std.mem.Allocator) void {
            gpa.free(self.id);
            if (self.path) |p| gpa.free(p);
            self.partial.deinit(gpa);
        }
    };

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        tracker: *guest_activity.Tracker,
        session_uuid: []const u8,
        cwd: []const u8,
        environ: ?*const std.process.Environ.Map,
    ) Tailer {
        return .{
            .gpa = gpa,
            .io = io,
            .tracker = tracker,
            .session_uuid = session_uuid,
            .projects = projectsDir(gpa, environ) catch null,
            .project_slug = projectSlug(gpa, cwd) catch null,
            .notifier = .init(),
        };
    }

    pub fn start(self: *Tailer) void {
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    pub fn deinit(self: *Tailer) void {
        self.stop.store(true, .release);
        self.notifier.wake();
        if (self.thread) |t| t.join();
        for (self.watched.items) |*w| {
            if (w.handle) |h| self.notifier.unwatch(h);
            w.deinit(self.gpa);
        }
        self.watched.deinit(self.gpa);
        self.dropDiscovery();
        self.notifier.deinit();
        if (self.projects) |p| self.gpa.free(p);
        if (self.project_slug) |s| self.gpa.free(s);
    }

    /// Tail a background command's output, if the path its tool result names
    /// is a task output of this session.
    pub fn watchTaskOutput(self: *Tailer, id: []const u8, reported: []const u8) void {
        const real = resolve(self.gpa, self.io, reported) orelse return;
        if (!isTaskOutput(real, self.session_uuid)) {
            self.gpa.free(real);
            return;
        }
        self.add(id, .text, real) catch self.gpa.free(real);
    }

    /// Tail a subagent's transcript once Claude Code writes it.
    pub fn watchSubagent(self: *Tailer, id: []const u8) void {
        if (self.projects == null) return;
        self.add(id, .transcript, null) catch {};
    }

    /// Whether a subagent's transcript is being tailed, so its forwarded
    /// prose would only repeat it.
    pub fn tailsTranscript(self: *Tailer, id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.watched.items) |w| if (w.kind == .transcript and w.path != null and std.mem.eql(u8, w.id, id)) return true;
        return false;
    }

    /// Stop tailing id (its work finished), after a last read.
    pub fn unwatch(self: *Tailer, id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.watched.items, 0..) |*w, i| if (std.mem.eql(u8, w.id, id)) {
            self.read(w);
            if (w.handle) |h| self.notifier.unwatch(h);
            var removed = self.watched.swapRemove(i);
            removed.deinit(self.gpa);
            return;
        };
    }

    fn add(self: *Tailer, id: []const u8, kind: Kind, path: ?[]u8) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.watched.items) |w| if (std.mem.eql(u8, w.id, id)) {
                if (path) |p| self.gpa.free(p);
                return;
            };
            const owned_id = try self.gpa.dupe(u8, id);
            errdefer self.gpa.free(owned_id);
            try self.watched.append(self.gpa, .{ .id = owned_id, .kind = kind, .path = path });
            self.arm(&self.watched.items[self.watched.items.len - 1]);
        }
        // Read what is already there, and start watching for a transcript.
        self.notifier.wake();
    }

    fn run(self: *Tailer) void {
        while (!self.stop.load(.acquire)) {
            self.refresh();
            if (self.notifier.available())
                self.notifier.wait(self.safety_ms)
            else // no kqueue or inotify on this system: the only fallback
                self.io.sleep(.fromMilliseconds(fallback_poll_ms), .awake) catch {};
        }
    }

    /// Read what every file gained, find transcripts that appeared, and keep
    /// the right folder watched for those still awaited.
    pub fn refresh(self: *Tailer) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Watching a deeper folder can race with what is created in it, so
        // look again whenever the watched folder moves (one level per pass).
        for (0..16) |_| {
            var pending = false;
            for (self.watched.items) |*w| {
                if (w.path == null) {
                    w.path = self.locate(w.id);
                    if (w.path != null) self.arm(w);
                }
                if (w.path == null) pending = true;
                self.read(w);
            }
            if (!self.watchDiscovery(pending)) break;
        }
    }

    fn arm(self: *Tailer, w: *Watched) void {
        const path = w.path orelse return;
        if (w.handle != null) return;
        const z = self.gpa.dupeSentinel(u8, path, 0) catch return;
        defer self.gpa.free(z);
        w.handle = self.notifier.watch(z);
    }

    /// Watch the deepest existing folder on the way to the session's
    /// subagents folder while a transcript is awaited, however far up that
    /// is (a first-ever session has no projects folder yet). True when the
    /// watched folder moved.
    fn watchDiscovery(self: *Tailer, pending: bool) bool {
        if (!pending) {
            self.dropDiscovery();
            return false;
        }
        const projects = self.projects orelse return false;
        const target = std.fs.path.join(self.gpa, &.{ projects, self.project_slug orelse "", self.session_uuid, "subagents" }) catch return false;
        defer self.gpa.free(target);
        var dir: []const u8 = target;
        while (true) {
            const z = self.gpa.dupeSentinel(u8, dir, 0) catch return false;
            defer self.gpa.free(z);
            if (self.discovery) |d| if (std.mem.eql(u8, d.path, dir)) return false;
            if (self.notifier.watch(z)) |handle| {
                self.dropDiscovery();
                const owned = self.gpa.dupe(u8, dir) catch {
                    self.notifier.unwatch(handle);
                    return false;
                };
                self.discovery = .{ .path = owned, .handle = handle };
                return true;
            }
            dir = std.fs.path.dirname(dir) orelse return false;
        }
    }

    fn dropDiscovery(self: *Tailer) void {
        const d = self.discovery orelse return;
        self.notifier.unwatch(d.handle);
        self.gpa.free(d.path);
        self.discovery = null;
    }

    fn locate(self: *Tailer, id: []const u8) ?[]u8 {
        const projects = resolve(self.gpa, self.io, self.projects orelse return null) orelse return null;
        defer self.gpa.free(projects);
        const found = (findSubagentTranscript(self.gpa, self.io, projects, self.session_uuid, id) catch return null) orelse return null;
        defer self.gpa.free(found);
        const real = resolve(self.gpa, self.io, found) orelse return null;
        if (!isSubagentTranscript(real, projects, self.session_uuid)) {
            self.gpa.free(real);
            return null;
        }
        return real;
    }

    fn read(self: *Tailer, w: *Watched) void {
        const path = w.path orelse return;
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return;
        defer file.close(self.io);
        const size = file.length(self.io) catch return;
        if (size < w.offset) w.offset = 0; // truncated or replaced
        if (size == w.offset) return;
        const want: usize = @intCast(@min(size - w.offset, max_read_bytes));
        const buf = self.gpa.alloc(u8, want) catch return;
        defer self.gpa.free(buf);
        const n = file.readPositionalAll(self.io, buf, w.offset) catch return;
        w.offset += n;
        switch (w.kind) {
            .text => self.tracker.appendOutput(w.id, buf[0..n]) catch {},
            .transcript => self.condense(w, buf[0..n]),
        }
    }

    fn condense(self: *Tailer, w: *Watched, bytes: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var out: std.ArrayList(u8) = .empty;
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const piece = rest[0..nl];
            rest = rest[nl + 1 ..];
            if (w.partial.items.len > 0) {
                w.partial.appendSlice(self.gpa, piece) catch {};
                condenseTranscriptLine(arena, w.partial.items, &out) catch {};
                w.partial.clearRetainingCapacity();
            } else condenseTranscriptLine(arena, piece, &out) catch {};
        }
        if (w.partial.items.len + rest.len <= max_line_bytes)
            w.partial.appendSlice(self.gpa, rest) catch {}
        else
            w.partial.clearRetainingCapacity();
        if (out.items.len > 0) self.tracker.appendOutput(w.id, out.items) catch {};
    }
};
