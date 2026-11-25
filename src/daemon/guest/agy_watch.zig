//! Live output and subagent lifecycle tracking for an Antigravity (`agy acp`)
//! guest turn.
//!
//! `agy acp` leaves background `run_command` tool calls open (`in_progress`)
//! while writing live stdout/stderr to
//! `~/.gemini/antigravity-cli/brain/<sessionId>/.system_generated/tasks/task-<n>.log`.
//! Subagents (`invoke_subagent`) complete their launch tool call immediately on
//! ACP, write `<sessionId>/.system_generated/subagents/<subId>.json` and their
//! own `<subId>/.system_generated/logs/transcript.jsonl`, and report back via
//! `<sessionId>/.system_generated/messages/<msgId>.json`.
//!
//! Like Claude Code's `tail.zig`, this watcher is event-driven via `file_watch`
//! (kqueue / inotify, with a safety-net timeout only) and feeds both live task
//! logs and subagent progress into the shared `guest_activity.Tracker`.
const std = @import("std");
const Io = std.Io;
const guest_activity = @import("activity.zig");
const file_watch = @import("file_watch.zig");
const nowMs = @import("../loop.zig").nowMs;

const fallback_poll_ms: i64 = 400;
const max_read_bytes: usize = 256 * 1024;
const max_line_bytes: usize = 4 * 1024 * 1024;
const max_meta_bytes: usize = 256 * 1024;

/// Antigravity's brain folder: `$HOME/.gemini/antigravity-cli/brain`.
pub fn brainDir(gpa: std.mem.Allocator, environ: ?*const std.process.Environ.Map) !?[]u8 {
    const env = environ orelse return null;
    const home = env.get("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fs.path.join(gpa, &.{ home, ".gemini", "antigravity-cli", "brain" });
}

/// Numeric task index for `task-<n>.log`, or null for any other filename.
pub fn parseTaskLogNumber(name: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, name, "task-") or !std.mem.endsWith(u8, name, ".log")) return null;
    const digits = name["task-".len .. name.len - ".log".len];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}

pub const CondensedLine = struct {
    model: ?[]const u8 = null,
    text: []const u8 = "",
};

/// Condense one line of an agy subagent's `transcript.jsonl` into model +
/// concise progress rows (`→ tool gist` or prose first line).
pub fn condenseTranscriptLine(arena: std.mem.Allocator, line: []const u8, out: *std.ArrayList(u8)) !?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    if (parsed != .object) return null;
    const kind = strField(parsed, "type") orelse return null;
    if (!std.mem.eql(u8, kind, "PLANNER_RESPONSE")) return null;
    const model = strField(parsed, "model");
    if (parsed.object.get("tool_calls")) |tc| if (tc == .array) {
        for (tc.array.items) |call| {
            const name = strField(call, "name") orelse continue;
            try out.print(arena, "→ {s}", .{name});
            if (call.object.get("args")) |args| if (toolGist(args)) |gist| {
                try out.print(arena, " {s}", .{firstLine(unquote(gist), 160)});
            };
            try out.append(arena, '\n');
        }
    };
    if (strField(parsed, "content")) |content| {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (trimmed.len > 0) {
            try out.appendSlice(arena, firstLine(trimmed, 200));
            try out.append(arena, '\n');
        }
    }
    return model;
}

/// Returns whether a line from the parent session's `transcript.jsonl` leaves
/// `agy` idle (`true`) or actively working on a next step (`false`). Only a
/// completed `PLANNER_RESPONSE` with no `tool_calls` is idle; `SYSTEM_MESSAGE`,
/// `GENERIC`, `USER_INPUT`, `CHECKPOINT`, and tool-calling responses mean `agy`
/// still has work in flight.
pub fn parseParentTranscriptIdle(arena: std.mem.Allocator, line: []const u8) ?bool {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch return null;
    if (parsed != .object) return null;
    const kind = strField(parsed, "type") orelse return null;
    if (std.mem.eql(u8, kind, "PLANNER_RESPONSE")) {
        const status = strField(parsed, "status") orelse "";
        if (!std.mem.eql(u8, status, "DONE")) return false;
        if (parsed.object.get("tool_calls")) |tc| {
            if (tc == .array and tc.array.items.len > 0) return false;
        }
        return true;
    }
    return false;
}

/// True when a `.system_generated/messages/<id>.json` message triggers a
/// reactive wakeup (background command completion, subagent reply, timer),
/// false for low-priority system notices such as restart banners.
pub fn isWakeupMessage(value: std.json.Value) bool {
    if (value != .object) return false;
    const priority = strField(value, "priority") orelse "";
    if (std.mem.eql(u8, priority, "MESSAGE_PRIORITY_HIGH")) return true;
    const sender = strField(value, "sender") orelse "";
    if (std.mem.eql(u8, sender, "system") or std.mem.eql(u8, priority, "MESSAGE_PRIORITY_LOW")) return false;
    return sender.len > 0;
}

fn strField(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return if (field == .string) field.string else null;
}

fn toolGist(args: std.json.Value) ?[]const u8 {
    for ([_][]const u8{ "CommandLine", "toolSummary", "Path", "query", "Pattern", "Prompt", "Message", "Recipient" }) |key| {
        if (strField(args, key)) |v| if (v.len > 0) return v;
    }
    return null;
}

/// agy's transcript.jsonl sometimes JSON-quotes string args inside `args`.
fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    return s;
}

fn firstLine(text: []const u8, max: usize) []const u8 {
    const trimmed = std.mem.trimStart(u8, text, " \t\r\n");
    const line = trimmed[0 .. std.mem.indexOfAny(u8, trimmed, "\r\n") orelse trimmed.len];
    if (line.len <= max) return line;
    var end = max;
    while (end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
    return line[0..end];
}

const DirWatch = struct {
    path: []u8,
    handle: file_watch.Handle,
};

const OpenCommand = struct {
    call_id: []u8,
    log_path: ?[]u8 = null,
    handle: ?file_watch.Handle = null,
    offset: u64 = 0,

    fn deinit(self: *OpenCommand, gpa: std.mem.Allocator) void {
        gpa.free(self.call_id);
        if (self.log_path) |p| gpa.free(p);
    }
};

const Subagent = struct {
    id: []u8,
    role: []u8,
    type_name: []u8,
    active: bool = true,
    transcript_path: ?[]u8 = null,
    transcript_handle: ?file_watch.Handle = null,
    transcript_offset: u64 = 0,
    partial: std.ArrayList(u8) = .empty,
    /// Deepest existing directory watched while waiting for transcript.jsonl to appear.
    discovery: ?DirWatch = null,

    fn deinit(self: *Subagent, gpa: std.mem.Allocator, notifier: *file_watch.Notifier) void {
        if (self.transcript_handle) |h| notifier.unwatch(h);
        if (self.discovery) |d| {
            notifier.unwatch(d.handle);
            gpa.free(d.path);
        }
        gpa.free(self.id);
        gpa.free(self.role);
        gpa.free(self.type_name);
        if (self.transcript_path) |p| gpa.free(p);
        self.partial.deinit(gpa);
    }
};

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    io: Io,
    tracker: *guest_activity.Tracker,
    brain_dir: ?[]u8,
    session_id: []u8,
    notifier: file_watch.Notifier,
    safety_ms: u32 = 30_000,
    mutex: Io.Mutex = .init,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Directory watches for `.system_generated/{tasks,subagents,messages}`
    /// (each points at the deepest existing ancestor until the folder appears).
    tasks_watch: ?DirWatch = null,
    subagents_watch: ?DirWatch = null,
    messages_watch: ?DirWatch = null,
    undelivered_watch: ?DirWatch = null,

    /// Parent session's own `.system_generated/logs/transcript.jsonl` tail.
    parent_transcript_path: ?[]u8 = null,
    parent_transcript_handle: ?file_watch.Handle = null,
    parent_transcript_discovery: ?DirWatch = null,
    parent_transcript_offset: u64 = 0,
    parent_partial: std.ArrayList(u8) = .empty,
    parent_skip_long: bool = false,
    parent_transcript_busy: bool = false,

    /// Filenames already present before this turn started (or already processed).
    seen_tasks: std.StringHashMapUnmanaged(void) = .empty,
    seen_subagents: std.StringHashMapUnmanaged(void) = .empty,
    seen_messages: std.StringHashMapUnmanaged(void) = .empty,
    /// Wakeup message IDs seen this turn not yet marked read in `read.json`.
    unread_bg_messages: std.StringHashMapUnmanaged(void) = .empty,
    /// Senders whose reply message arrived before we scanned `subagents/`.
    early_replies: std.StringHashMapUnmanaged(void) = .empty,

    commands: std.ArrayList(OpenCommand) = .empty,
    subagents: std.ArrayList(Subagent) = .empty,
    subagent_replied: bool = false,
    has_undelivered: bool = false,
    read_json_exists: bool = false,
    saw_bg_message: bool = false,
    bg_message_arrived: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        tracker: *guest_activity.Tracker,
        session_id: []const u8,
        brain_override: ?[]const u8,
        environ: ?*const std.process.Environ.Map,
    ) !Watcher {
        const brain: ?[]u8 = if (brain_override) |dir|
            try gpa.dupe(u8, dir)
        else
            brainDir(gpa, environ) catch null;
        errdefer if (brain) |b| gpa.free(b);
        var self = Watcher{
            .gpa = gpa,
            .io = io,
            .tracker = tracker,
            .brain_dir = brain,
            .session_id = try gpa.dupe(u8, session_id),
            .notifier = .init(),
        };
        self.seedExisting();
        return self;
    }

    pub fn start(self: *Watcher) void {
        if (self.brain_dir == null or self.session_id.len == 0) return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    pub fn deinit(self: *Watcher) void {
        self.stop.store(true, .release);
        self.notifier.wake();
        if (self.thread) |t| t.join();
        for (self.commands.items) |*cmd| {
            if (cmd.handle) |h| self.notifier.unwatch(h);
            cmd.deinit(self.gpa);
        }
        self.commands.deinit(self.gpa);
        for (self.subagents.items) |*sub| sub.deinit(self.gpa, &self.notifier);
        self.subagents.deinit(self.gpa);
        self.dropDirWatch(&self.tasks_watch);
        self.dropDirWatch(&self.subagents_watch);
        self.dropDirWatch(&self.messages_watch);
        self.dropDirWatch(&self.undelivered_watch);
        if (self.parent_transcript_handle) |h| self.notifier.unwatch(h);
        self.dropDirWatch(&self.parent_transcript_discovery);
        if (self.parent_transcript_path) |p| self.gpa.free(p);
        self.parent_partial.deinit(self.gpa);
        freeKeys(self.gpa, &self.seen_tasks);
        freeKeys(self.gpa, &self.seen_subagents);
        freeKeys(self.gpa, &self.seen_messages);
        freeKeys(self.gpa, &self.unread_bg_messages);
        freeKeys(self.gpa, &self.early_replies);
        self.notifier.deinit();
        if (self.brain_dir) |b| self.gpa.free(b);
        self.gpa.free(self.session_id);
    }

    fn freeKeys(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged(void)) void {
        var it = map.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        map.deinit(gpa);
    }

    fn markSeen(gpa: std.mem.Allocator, map: *std.StringHashMapUnmanaged(void), name: []const u8) !bool {
        if (map.contains(name)) return false;
        try map.put(gpa, try gpa.dupe(u8, name), {});
        return true;
    }

    fn seedDir(self: *Watcher, subdir: []const u8, map: *std.StringHashMapUnmanaged(void)) void {
        const brain = self.brain_dir orelse return;
        if (self.session_id.len == 0) return;
        const path = std.fs.path.join(self.gpa, &.{ brain, self.session_id, ".system_generated", subdir }) catch return;
        defer self.gpa.free(path);
        var dir = Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            _ = markSeen(self.gpa, map, entry.name) catch {};
        }
    }

    fn seedExisting(self: *Watcher) void {
        self.seedDir("tasks", &self.seen_tasks);
        self.seedDir("subagents", &self.seen_subagents);
        self.seedDir("messages", &self.seen_messages);
        self.seedParentTranscript();
    }

    fn seedParentTranscript(self: *Watcher) void {
        const brain = self.brain_dir orelse return;
        if (self.session_id.len == 0) return;
        const path = std.fs.path.join(self.gpa, &.{ brain, self.session_id, ".system_generated", "logs", "transcript.jsonl" }) catch return;
        self.parent_transcript_path = path;
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return;
        defer file.close(self.io);
        self.parent_transcript_offset = file.length(self.io) catch 0;
    }

    pub fn noteCommandStart(self: *Watcher, call_id: []const u8) void {
        if (self.brain_dir == null or call_id.len == 0) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.commands.items) |cmd| if (std.mem.eql(u8, cmd.call_id, call_id)) return;
            const owned = self.gpa.dupe(u8, call_id) catch return;
            self.commands.append(self.gpa, .{ .call_id = owned }) catch {
                self.gpa.free(owned);
                return;
            };
        }
        self.notifier.wake();
    }

    pub fn noteCommandFinish(self: *Watcher, call_id: []const u8) void {
        if (call_id.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.commands.items, 0..) |*cmd, i| {
            if (!std.mem.eql(u8, cmd.call_id, call_id)) continue;
            self.readCommandLog(cmd);
            if (cmd.handle) |h| self.notifier.unwatch(h);
            var removed = self.commands.orderedRemove(i);
            removed.deinit(self.gpa);
            return;
        }
    }

    /// Re-arm a previously spawned subagent when the parent sends it a message.
    pub fn noteSubagentMessaged(self: *Watcher, recipient_id: []const u8) void {
        if (self.brain_dir == null or recipient_id.len == 0) return;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            // If it was already known from this turn, re-activate it; if it
            // came from a prior turn, load its descriptor from disk.
            for (self.subagents.items) |*sub| if (std.mem.eql(u8, sub.id, recipient_id)) {
                sub.active = true;
                self.tracker.start(sub.id, "", .agent, sub.role, sub.type_name, nowMs(self.io)) catch {};
                self.armSubagentTranscript(sub);
                self.notifier.wake();
                return;
            };
            self.loadSubagentByIdLocked(recipient_id);
        }
        self.notifier.wake();
    }

    pub fn noteSubagentKilled(self: *Watcher, subagent_id: []const u8) void {
        if (subagent_id.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.subagents.items) |*sub| if (std.mem.eql(u8, sub.id, subagent_id)) {
            if (sub.active) {
                sub.active = false;
                self.tracker.finish(sub.id);
                if (sub.transcript_handle) |h| {
                    self.notifier.unwatch(h);
                    sub.transcript_handle = null;
                }
            }
        };
    }

    pub fn noteAllSubagentsKilled(self: *Watcher) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.subagents.items) |*sub| {
            if (sub.active) {
                sub.active = false;
                self.tracker.finish(sub.id);
                if (sub.transcript_handle) |h| {
                    self.notifier.unwatch(h);
                    sub.transcript_handle = null;
                }
            }
        }
    }

    pub fn activeSubagentCount(self: *Watcher) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.subagents.items) |sub| if (sub.active) {
            count += 1;
        };
        return count;
    }

    pub fn firstActiveSubagentName(self: *Watcher, buf: []u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.subagents.items) |sub| if (sub.active) {
            const label = if (sub.role.len > 0) sub.role else "subagent";
            const n = @min(label.len, buf.len);
            @memcpy(buf[0..n], label[0..n]);
            return buf[0..n];
        };
        return null;
    }

    pub fn takeSubagentReply(self: *Watcher) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const replied = self.subagent_replied;
        self.subagent_replied = false;
        return replied;
    }

    pub fn clearSubagentReply(self: *Watcher) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.subagent_replied = false;
    }

    /// True while agy's on-disk state shows a reactive step or undelivered
    /// background completion message still in flight for the parent session.
    pub fn isParentBusy(self: *Watcher) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.isParentBusyLocked();
    }

    fn isParentBusyLocked(self: *const Watcher) bool {
        return self.has_undelivered or
            (self.read_json_exists and self.unread_bg_messages.count() > 0) or
            self.parent_transcript_busy;
    }

    /// True at `session/prompt` end when a background task or subagent finished
    /// mid-prompt and still has a reactive wakeup pending. False on ordinary
    /// prompts that never received a background message.
    pub fn hasPendingPromptWakeup(self: *Watcher) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.has_undelivered or
            (self.read_json_exists and self.unread_bg_messages.count() > 0) or
            self.bg_message_arrived or
            self.subagent_replied or
            (self.saw_bg_message and self.parent_transcript_busy);
    }

    /// Consumes the one-shot wakeup signal (subagent reply or background task
    /// completion message newly seen on disk).
    pub fn takeWakeupSignal(self: *Watcher) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const hit = self.subagent_replied or self.bg_message_arrived;
        self.subagent_replied = false;
        self.bg_message_arrived = false;
        return hit;
    }

    pub fn clearWakeupSignal(self: *Watcher) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.subagent_replied = false;
        self.bg_message_arrived = false;
    }

    fn run(self: *Watcher) void {
        while (!self.stop.load(.acquire)) {
            self.refresh();
            if (self.notifier.available())
                self.notifier.wait(self.safety_ms)
            else
                self.io.sleep(.fromMilliseconds(fallback_poll_ms), .awake) catch {};
        }
    }

    /// Scan tasks/, subagents/, messages/, and tail any open logs/transcripts.
    pub fn refresh(self: *Watcher) void {
        if (self.brain_dir == null or self.session_id.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // Move directory watches deeper as agy creates `.system_generated/*`.
        for (0..8) |_| {
            self.scanTasksLocked();
            self.scanMessagesLocked();
            self.scanSubagentsLocked();
            self.armParentTranscript();
            self.readParentTranscript();
            for (self.commands.items) |*cmd| self.readCommandLog(cmd);
            for (self.subagents.items) |*sub| if (sub.active) {
                self.armSubagentTranscript(sub);
                self.readSubagentTranscript(sub);
            };
            const moved = self.watchSessionSubdir("tasks", &self.tasks_watch) or
                self.watchSessionSubdir("subagents", &self.subagents_watch) or
                self.watchSessionSubdir("messages", &self.messages_watch) or
                self.watchSessionSubdir("messages/undelivered", &self.undelivered_watch);
            if (!moved) break;
        }
    }

    fn watchSessionSubdir(self: *Watcher, subdir: []const u8, slot: *?DirWatch) bool {
        const brain = self.brain_dir orelse return false;
        const target = std.fs.path.join(self.gpa, &.{ brain, self.session_id, ".system_generated", subdir }) catch return false;
        defer self.gpa.free(target);
        return self.watchDeepest(target, slot);
    }

    fn watchDeepest(self: *Watcher, target: []const u8, slot: *?DirWatch) bool {
        var dir: []const u8 = target;
        while (true) {
            if (slot.*) |existing| if (std.mem.eql(u8, existing.path, dir)) return false;
            const z = self.gpa.dupeSentinel(u8, dir, 0) catch return false;
            defer self.gpa.free(z);
            if (self.notifier.watch(z)) |handle| {
                self.dropDirWatch(slot);
                const owned = self.gpa.dupe(u8, dir) catch {
                    self.notifier.unwatch(handle);
                    return false;
                };
                slot.* = .{ .path = owned, .handle = handle };
                return true;
            }
            dir = std.fs.path.dirname(dir) orelse return false;
        }
    }

    fn dropDirWatch(self: *Watcher, slot: *?DirWatch) void {
        const existing = slot.* orelse return;
        self.notifier.unwatch(existing.handle);
        self.gpa.free(existing.path);
        slot.* = null;
    }

    fn scanTasksLocked(self: *Watcher) void {
        const brain = self.brain_dir orelse return;
        const tasks_dir = std.fs.path.join(self.gpa, &.{ brain, self.session_id, ".system_generated", "tasks" }) catch return;
        defer self.gpa.free(tasks_dir);
        var dir = Io.Dir.cwd().openDir(self.io, tasks_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        const Entry = struct { num: u64, name: []u8 };
        var found: std.ArrayList(Entry) = .empty;
        defer {
            for (found.items) |e| self.gpa.free(e.name);
            found.deinit(self.gpa);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const num = parseTaskLogNumber(entry.name) orelse continue;
            if (self.seen_tasks.contains(entry.name)) continue;
            const copy = self.gpa.dupe(u8, entry.name) catch continue;
            found.append(self.gpa, .{ .num = num, .name = copy }) catch self.gpa.free(copy);
        }
        if (found.items.len == 0) return;
        std.mem.sort(Entry, found.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.num < b.num;
            }
        }.less);

        for (found.items) |entry| {
            // Pair with the oldest open command that does not yet have a log.
            var paired = false;
            for (self.commands.items) |*cmd| {
                if (cmd.log_path != null) continue;
                const full = std.fs.path.join(self.gpa, &.{ tasks_dir, entry.name }) catch break;
                cmd.log_path = full;
                const z = self.gpa.dupeSentinel(u8, full, 0) catch null;
                if (z) |zp| {
                    defer self.gpa.free(zp);
                    cmd.handle = self.notifier.watch(zp);
                }
                paired = true;
                break;
            }
            if (paired) _ = markSeen(self.gpa, &self.seen_tasks, entry.name) catch {};
        }
    }

    fn readCommandLog(self: *Watcher, cmd: *OpenCommand) void {
        const path = cmd.log_path orelse return;
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return;
        defer file.close(self.io);
        const size = file.length(self.io) catch return;
        if (size < cmd.offset) cmd.offset = 0;
        if (size == cmd.offset) return;
        const want: usize = @intCast(@min(size - cmd.offset, max_read_bytes));
        const buf = self.gpa.alloc(u8, want) catch return;
        defer self.gpa.free(buf);
        const n = file.readPositionalAll(self.io, buf, cmd.offset) catch return;
        if (n == 0) return;
        cmd.offset += n;
        self.tracker.appendOutput(cmd.call_id, buf[0..n]) catch {};
    }

    fn scanMessagesLocked(self: *Watcher) void {
        const brain = self.brain_dir orelse return;
        const msg_dir = std.fs.path.join(self.gpa, &.{ brain, self.session_id, ".system_generated", "messages" }) catch return;
        defer self.gpa.free(msg_dir);
        var dir = Io.Dir.cwd().openDir(self.io, msg_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json") or std.mem.eql(u8, entry.name, "read.json")) continue;
            if (self.seen_messages.contains(entry.name)) continue;
            const raw = dir.readFileAlloc(self.io, entry.name, self.gpa, .limited(max_meta_bytes)) catch continue;
            defer self.gpa.free(raw);
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, raw, .{}) catch continue;
            defer parsed.deinit();
            _ = markSeen(self.gpa, &self.seen_messages, entry.name) catch {};
            const wakeup = isWakeupMessage(parsed.value);
            if (wakeup) {
                self.saw_bg_message = true;
                self.bg_message_arrived = true;
                const msg_id = strField(parsed.value, "id") orelse entry.name[0 .. entry.name.len - ".json".len];
                _ = markSeen(self.gpa, &self.unread_bg_messages, msg_id) catch {};
            }
            const sender = strField(parsed.value, "sender") orelse continue;
            var matched = false;
            for (self.subagents.items) |*sub| {
                if (!std.mem.eql(u8, sub.id, sender)) continue;
                matched = true;
                if (sub.active) {
                    self.readSubagentTranscript(sub);
                    sub.active = false;
                    self.tracker.finish(sub.id);
                    if (sub.transcript_handle) |h| {
                        self.notifier.unwatch(h);
                        sub.transcript_handle = null;
                    }
                    self.dropDirWatch(&sub.discovery);
                    self.subagent_replied = true;
                    self.saw_bg_message = true;
                    self.bg_message_arrived = true;
                }
                break;
            }
            if (!matched) {
                // Subagent replied before we scanned subagents/: remember so
                // it is not mistakenly marked active when its descriptor loads.
                _ = markSeen(self.gpa, &self.early_replies, sender) catch {};
            }
        }
        self.scanUndeliveredLocked(dir);
        self.pruneReadMessagesLocked(dir);
    }

    fn scanUndeliveredLocked(self: *Watcher, msg_dir: Io.Dir) void {
        var sub = msg_dir.openDir(self.io, "undelivered", .{ .iterate = true }) catch {
            self.has_undelivered = false;
            return;
        };
        defer sub.close(self.io);
        var it = sub.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind == .file) {
                self.has_undelivered = true;
                return;
            }
        }
        self.has_undelivered = false;
    }

    fn pruneReadMessagesLocked(self: *Watcher, msg_dir: Io.Dir) void {
        if (self.unread_bg_messages.count() == 0) return;
        const raw = msg_dir.readFileAlloc(self.io, "read.json", self.gpa, .limited(max_meta_bytes)) catch return;
        defer self.gpa.free(raw);
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, raw, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        self.read_json_exists = true;
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(self.gpa);
        var it = self.unread_bg_messages.keyIterator();
        while (it.next()) |key| {
            const flag = parsed.value.object.get(key.*) orelse continue;
            if (flag == .bool and flag.bool) to_remove.append(self.gpa, key.*) catch {};
        }
        for (to_remove.items) |key| {
            if (self.unread_bg_messages.fetchRemove(key)) |kv| self.gpa.free(kv.key);
        }
    }

    fn armParentTranscript(self: *Watcher) void {
        if (self.parent_transcript_handle != null) return;
        const path = self.parent_transcript_path orelse return;
        const z = self.gpa.dupeSentinel(u8, path, 0) catch return;
        defer self.gpa.free(z);
        if (self.notifier.watch(z)) |handle| {
            self.parent_transcript_handle = handle;
            self.dropDirWatch(&self.parent_transcript_discovery);
        } else if (std.fs.path.dirname(path)) |parent| {
            _ = self.watchDeepest(parent, &self.parent_transcript_discovery);
        }
    }

    fn readParentTranscript(self: *Watcher) void {
        const path = self.parent_transcript_path orelse return;
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return;
        defer file.close(self.io);
        const size = file.length(self.io) catch return;
        if (size < self.parent_transcript_offset) {
            self.parent_transcript_offset = 0;
            self.parent_partial.clearRetainingCapacity();
            self.parent_skip_long = false;
        }
        if (size == self.parent_transcript_offset) return;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        var rounds: usize = 0;
        while (self.parent_transcript_offset < size and rounds < 32) : (rounds += 1) {
            const want: usize = @intCast(@min(size - self.parent_transcript_offset, max_read_bytes));
            const buf = self.gpa.alloc(u8, want) catch return;
            defer self.gpa.free(buf);
            const n = file.readPositionalAll(self.io, buf, self.parent_transcript_offset) catch return;
            if (n == 0) return;
            self.parent_transcript_offset += n;

            var rest = buf[0..n];
            while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                const piece = rest[0..nl];
                rest = rest[nl + 1 ..];
                if (self.parent_skip_long) {
                    self.parent_skip_long = false;
                    self.parent_partial.clearRetainingCapacity();
                    continue;
                }
                _ = arena_state.reset(.retain_capacity);
                const arena = arena_state.allocator();
                const line = if (self.parent_partial.items.len > 0) blk: {
                    self.parent_partial.appendSlice(self.gpa, piece) catch {
                        self.parent_partial.clearRetainingCapacity();
                        continue;
                    };
                    defer self.parent_partial.clearRetainingCapacity();
                    break :blk arena.dupe(u8, self.parent_partial.items) catch continue;
                } else piece;
                if (parseParentTranscriptIdle(arena, line)) |idle| {
                    self.parent_transcript_busy = !idle;
                }
            }
            if (rest.len > 0 and !self.parent_skip_long) {
                if (self.parent_partial.items.len + rest.len <= max_line_bytes) {
                    self.parent_partial.appendSlice(self.gpa, rest) catch {
                        self.parent_partial.clearRetainingCapacity();
                        self.parent_skip_long = true;
                    };
                } else {
                    self.parent_partial.clearRetainingCapacity();
                    self.parent_skip_long = true;
                }
            }
        }
    }

    fn scanSubagentsLocked(self: *Watcher) void {
        const brain = self.brain_dir orelse return;
        const sub_dir = std.fs.path.join(self.gpa, &.{ brain, self.session_id, ".system_generated", "subagents" }) catch return;
        defer self.gpa.free(sub_dir);
        var dir = Io.Dir.cwd().openDir(self.io, sub_dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        // Check existing active subagents for state change or deletion.
        for (self.subagents.items) |*sub| if (sub.active) {
            const filename = std.fmt.allocPrint(self.gpa, "{s}.json", .{sub.id}) catch continue;
            defer self.gpa.free(filename);
            const raw = dir.readFileAlloc(self.io, filename, self.gpa, .limited(max_meta_bytes)) catch {
                sub.active = false;
                self.tracker.finish(sub.id);
                if (sub.transcript_handle) |h| {
                    self.notifier.unwatch(h);
                    sub.transcript_handle = null;
                }
                self.dropDirWatch(&sub.discovery);
                continue;
            };
            defer self.gpa.free(raw);
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, raw, .{}) catch continue;
            defer parsed.deinit();
            const state = strField(parsed.value, "state") orelse "";
            if (!std.mem.eql(u8, state, "SUBAGENT_STATE_ALIVE")) {
                self.readSubagentTranscript(sub);
                sub.active = false;
                self.tracker.finish(sub.id);
                if (sub.transcript_handle) |h| {
                    self.notifier.unwatch(h);
                    sub.transcript_handle = null;
                }
                self.dropDirWatch(&sub.discovery);
            }
        };

        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (self.seen_subagents.contains(entry.name)) continue;
            const raw = dir.readFileAlloc(self.io, entry.name, self.gpa, .limited(max_meta_bytes)) catch continue;
            defer self.gpa.free(raw);
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, raw, .{}) catch continue;
            defer parsed.deinit();
            _ = markSeen(self.gpa, &self.seen_subagents, entry.name) catch {};
            self.registerSubagentLocked(parsed.value);
        }
    }

    fn loadSubagentByIdLocked(self: *Watcher, id: []const u8) void {
        const brain = self.brain_dir orelse return;
        const filename = std.fmt.allocPrint(self.gpa, "{s}.json", .{id}) catch return;
        defer self.gpa.free(filename);
        const path = std.fs.path.join(self.gpa, &.{ brain, self.session_id, ".system_generated", "subagents", filename }) catch return;
        defer self.gpa.free(path);
        const raw = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(max_meta_bytes)) catch return;
        defer self.gpa.free(raw);
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, raw, .{}) catch return;
        defer parsed.deinit();
        self.registerSubagentLocked(parsed.value);
    }

    fn registerSubagentLocked(self: *Watcher, value: std.json.Value) void {
        const id = strField(value, "conversationId") orelse return;
        for (self.subagents.items) |sub| if (std.mem.eql(u8, sub.id, id)) return;
        const state = strField(value, "state") orelse "";
        const desc = if (value == .object) value.object.get("subagentDescriptor") else null;
        const role = if (desc) |d| strField(d, "role") orelse "Agent" else "Agent";
        const type_name = if (desc) |d| strField(d, "typeName") orelse "" else "";
        const already_replied = self.early_replies.contains(id);
        const active = std.mem.eql(u8, state, "SUBAGENT_STATE_ALIVE") and !already_replied;
        const owned_id = self.gpa.dupe(u8, id) catch return;
        errdefer self.gpa.free(owned_id);
        const owned_role = self.gpa.dupe(u8, role) catch return;
        errdefer self.gpa.free(owned_role);
        const owned_type = self.gpa.dupe(u8, type_name) catch return;
        errdefer self.gpa.free(owned_type);
        self.subagents.append(self.gpa, .{
            .id = owned_id,
            .role = owned_role,
            .type_name = owned_type,
            .active = active,
        }) catch return;
        if (active) {
            const sub = &self.subagents.items[self.subagents.items.len - 1];
            self.tracker.start(sub.id, "", .agent, sub.role, sub.type_name, nowMs(self.io)) catch {};
            self.armSubagentTranscript(sub);
        }
    }

    fn armSubagentTranscript(self: *Watcher, sub: *Subagent) void {
        if (sub.transcript_handle != null) return;
        const brain = self.brain_dir orelse return;
        if (sub.transcript_path == null) {
            sub.transcript_path = std.fs.path.join(self.gpa, &.{ brain, sub.id, ".system_generated", "logs", "transcript.jsonl" }) catch return;
        }
        const path = sub.transcript_path.?;
        const z = self.gpa.dupeSentinel(u8, path, 0) catch return;
        defer self.gpa.free(z);
        if (self.notifier.watch(z)) |handle| {
            sub.transcript_handle = handle;
            self.dropDirWatch(&sub.discovery);
        } else if (std.fs.path.dirname(path)) |parent| {
            _ = self.watchDeepest(parent, &sub.discovery);
        }
    }

    fn readSubagentTranscript(self: *Watcher, sub: *Subagent) void {
        const path = sub.transcript_path orelse return;
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch return;
        defer file.close(self.io);
        const size = file.length(self.io) catch return;
        if (size < sub.transcript_offset) {
            sub.transcript_offset = 0;
            sub.partial.clearRetainingCapacity();
        }
        if (size == sub.transcript_offset) return;
        const want: usize = @intCast(@min(size - sub.transcript_offset, max_read_bytes));
        const buf = self.gpa.alloc(u8, want) catch return;
        defer self.gpa.free(buf);
        const n = file.readPositionalAll(self.io, buf, sub.transcript_offset) catch return;
        if (n == 0) return;
        sub.transcript_offset += n;

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var formatted: std.ArrayList(u8) = .empty;
        var rest = buf[0..n];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const piece = rest[0..nl];
            rest = rest[nl + 1 ..];
            const line = if (sub.partial.items.len > 0) blk: {
                sub.partial.appendSlice(self.gpa, piece) catch {
                    sub.partial.clearRetainingCapacity();
                    continue;
                };
                defer sub.partial.clearRetainingCapacity();
                break :blk arena.dupe(u8, sub.partial.items) catch continue;
            } else piece;
            if (condenseTranscriptLine(arena, line, &formatted) catch null) |model| {
                self.tracker.setModel(sub.id, model) catch {};
            }
        }
        if (rest.len > 0) {
            if (sub.partial.items.len + rest.len <= max_line_bytes) {
                sub.partial.appendSlice(self.gpa, rest) catch sub.partial.clearRetainingCapacity();
            } else {
                sub.partial.clearRetainingCapacity();
            }
        }
        if (formatted.items.len > 0) self.tracker.appendOutput(sub.id, formatted.items) catch {};
    }
};
