//! Unit tests for tail.zig: live output of background commands and subagents.
const std = @import("std");
const Io = std.Io;
const tail = @import("tail.zig");
const guest_activity = @import("activity.zig");
const proto = @import("../../core/proto.zig");
const temp_dir = @import("../../testing/temp_dir.zig");

const uuid = "11111111-2222-4333-8444-555555555555";

test "a background command's output path is read from its tool result" {
    try std.testing.expectEqualStrings(
        "/private/tmp/claude-501/p/s/tasks/b2zjre03x.output",
        tail.backgroundOutputPath("Command running in background with ID: b2zjre03x. Output is being written to: /private/tmp/claude-501/p/s/tasks/b2zjre03x.output.").?,
    );
    try std.testing.expect(tail.backgroundOutputPath("exit code 0") == null);
    try std.testing.expect(tail.backgroundOutputPath("Output is being written to: relative/x.output") == null);
}

test "only this session's task outputs and subagent transcripts are tailed" {
    try std.testing.expect(tail.isTaskOutput("/tmp/claude-501/proj/" ++ uuid ++ "/tasks/b2zjre03x.output", uuid));
    try std.testing.expect(!tail.isTaskOutput("/tmp/claude-501/proj/other-session/tasks/b2zjre03x.output", uuid));
    try std.testing.expect(!tail.isTaskOutput("/home/me/.ssh/id_ed25519", uuid));
    try std.testing.expect(!tail.isTaskOutput("/tmp/claude-501/proj/" ++ uuid ++ "/tasks/../../x.output", uuid));
    try std.testing.expect(!tail.isTaskOutput("/tmp/claude-501/proj/" ++ uuid ++ "/tasks/a.b.output", uuid));

    const projects = "/home/me/.claude/projects";
    try std.testing.expect(tail.isSubagentTranscript(projects ++ "/-work-app/" ++ uuid ++ "/subagents/agent-a97a32.jsonl", projects, uuid));
    try std.testing.expect(!tail.isSubagentTranscript(projects ++ "/-work-app/" ++ uuid ++ "/subagents/notes.jsonl", projects, uuid));
    try std.testing.expect(!tail.isSubagentTranscript("/elsewhere/-work-app/" ++ uuid ++ "/subagents/agent-a.jsonl", projects, uuid));
    try std.testing.expect(!tail.isSubagentTranscript(projects ++ "/a/b/" ++ uuid ++ "/subagents/agent-a.jsonl", projects, uuid));
}

test "a subagent transcript condenses to prose, tool calls and their results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    // The prompt is the task itself, shown elsewhere: left out.
    try tail.condenseTranscriptLine(arena, "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Map the pipeline\"}}", &out);
    try tail.condenseTranscriptLine(arena,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"Looking at layout.zig."},{"type":"tool_use","name":"Bash","input":{"command":"rg -n Stream src\nsecond line"}}]}}
    , &out);
    try tail.condenseTranscriptLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"src/a.zig:1: Stream\nmore"}]}]}}
    , &out);
    try tail.condenseTranscriptLine(arena,
        \\{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"no such file"}]}}
    , &out);
    try tail.condenseTranscriptLine(arena, "not json", &out);
    try std.testing.expectEqualStrings(
        "Looking at layout.zig.\n→ Bash rg -n Stream src\n  ↳ src/a.zig:1: Stream\n  ✗ no such file\n",
        out.items,
    );
}

const Seen = struct {
    output: std.ArrayList(u8) = .empty,

    fn publish(ctx: ?*anyopaque, items: []const proto.GuestActivity) void {
        const self: *Seen = @ptrCast(@alignCast(ctx.?));
        for (items) |item| if (std.mem.eql(u8, item.id, "toolu_1")) {
            self.output.clearRetainingCapacity();
            self.output.appendSlice(std.testing.allocator, item.output) catch {};
        };
    }
};

fn writeFile(io: Io, path: []const u8, data: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn appendFile(io: Io, path: []const u8, data: []const u8) !void {
    const file = try Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.seekTo(try file.length(io));
    try w.interface.writeAll(data);
    try w.interface.flush();
}

test "the tailer follows a background command's output while it runs" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try temp_dir.Dir.initFromProcess(gpa, io, "marlin-tail");
    defer temp.deinit();

    var seen: Seen = .{};
    defer seen.output.deinit(gpa);
    var tracker = guest_activity.Tracker.init(gpa, Seen.publish, &seen);
    tracker.io = io;
    defer tracker.deinit();
    try tracker.start("toolu_1", "", .process, "Bash", "make test", 0);
    var tailer = tail.Tailer.init(gpa, io, &tracker, uuid, "/work/app", null);
    defer tailer.deinit();

    const output = try std.fs.path.join(gpa, &.{ temp.path, "proj", uuid, "tasks", "b1.output" });
    defer gpa.free(output);
    try writeFile(io, output, "building\n");
    tailer.watchTaskOutput("toolu_1", output);
    tailer.refresh();
    try std.testing.expectEqualStrings("building\n", seen.output.items);
    try appendFile(io, output, "tests pass\n");
    tailer.refresh();
    try std.testing.expectEqualStrings("building\ntests pass\n", seen.output.items);

    // A reported path that leaves the session's tasks folder is never opened,
    // symlinks included.
    const secret = try std.fs.path.join(gpa, &.{ temp.path, "secret.txt" });
    defer gpa.free(secret);
    try writeFile(io, secret, "do not read\n");
    const link = try std.fs.path.join(gpa, &.{ temp.path, "proj", uuid, "tasks", "evil.output" });
    defer gpa.free(link);
    try Io.Dir.cwd().symLink(io, secret, link, .{});
    try tracker.start("toolu_2", "", .process, "Bash", "x", 0);
    tailer.watchTaskOutput("toolu_2", link);
    tailer.watchTaskOutput("toolu_2", secret);
    tailer.refresh();
    try std.testing.expect(!tailer.tailsTranscript("toolu_2"));
    try std.testing.expectEqual(@as(usize, 1), tailer.watched.items.len);
}

test "the tailer finds a subagent's transcript and condenses what it gains" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try temp_dir.Dir.initFromProcess(gpa, io, "marlin-tail-agent");
    defer temp.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("CLAUDE_CONFIG_DIR", temp.path);

    var seen: Seen = .{};
    defer seen.output.deinit(gpa);
    var tracker = guest_activity.Tracker.init(gpa, Seen.publish, &seen);
    tracker.io = io;
    defer tracker.deinit();
    try tracker.start("toolu_1", "", .agent, "Agent", "Map the pipeline", 0);
    var tailer = tail.Tailer.init(gpa, io, &tracker, uuid, "/work/app", &env);
    defer tailer.deinit();

    // Watched before Claude Code writes the transcript: found once it does.
    tailer.watchSubagent("toolu_1");
    tailer.refresh();
    try std.testing.expect(!tailer.tailsTranscript("toolu_1"));

    const sub = try std.fs.path.join(gpa, &.{ temp.path, "projects", "-work-app", uuid, "subagents" });
    defer gpa.free(sub);
    const meta = try std.fs.path.join(gpa, &.{ sub, "agent-a97a.meta.json" });
    defer gpa.free(meta);
    try writeFile(io, meta, "{\"agentType\":\"Explore\",\"toolUseId\":\"toolu_1\"}");
    const transcript = try std.fs.path.join(gpa, &.{ sub, "agent-a97a.jsonl" });
    defer gpa.free(transcript);
    // The second line arrives in two writes: the half line waits for the rest.
    try writeFile(io, transcript, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Reading.\"}]}}\n{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",");
    tailer.refresh();
    try std.testing.expect(tailer.tailsTranscript("toolu_1"));
    try std.testing.expectEqualStrings("Reading.\n", seen.output.items);
    try appendFile(io, transcript, "\"input\":{\"file_path\":\"src/layout.zig\"}}]}}\n");
    tailer.refresh();
    try std.testing.expectEqualStrings("Reading.\n→ Read src/layout.zig\n", seen.output.items);

    // Finished: read one last time, then let go.
    tailer.unwatch("toolu_1");
    try std.testing.expect(!tailer.tailsTranscript("toolu_1"));
}

test "a project's folder name is its working directory with non-alphanumerics as dashes" {
    const gpa = std.testing.allocator;
    const slug = try tail.projectSlug(gpa, "/Users/jespern/Work/marlin.dev");
    defer gpa.free(slug);
    try std.testing.expectEqualStrings("-Users-jespern-Work-marlin-dev", slug);
}

/// Set from the tailer's thread when the watched item's output holds `want`.
const Arrived = struct {
    want: []const u8,
    seen: std.atomic.Value(bool) = .init(false),

    fn publish(ctx: ?*anyopaque, items: []const proto.GuestActivity) void {
        const self: *Arrived = @ptrCast(@alignCast(ctx.?));
        for (items) |item| if (std.mem.indexOf(u8, item.output, self.want) != null) self.seen.store(true, .release);
    }

    /// Whether it arrived within ms, without anyone calling refresh().
    fn within(self: *Arrived, io: Io, ms: u32) bool {
        var waited: u32 = 0;
        while (waited < ms) : (waited += 20) {
            if (self.seen.load(.acquire)) return true;
            io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
        return self.seen.load(.acquire);
    }
};

test "output is read when the OS reports the write, not on a timer" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try temp_dir.Dir.initFromProcess(gpa, io, "marlin-tail-react");
    defer temp.deinit();

    var arrived: Arrived = .{ .want = "line two" };
    var tracker = guest_activity.Tracker.init(gpa, Arrived.publish, &arrived);
    tracker.io = io;
    defer tracker.deinit();
    try tracker.start("toolu_1", "", .process, "Bash", "make test", 0);
    var tailer = tail.Tailer.init(gpa, io, &tracker, uuid, "/work/app", null);
    if (!tailer.notifier.available()) {
        tailer.deinit();
        return error.SkipZigTest;
    }
    // The safety net is far beyond the test's patience: only an event can
    // deliver the line in time.
    tailer.safety_ms = 60_000;
    tailer.start();
    defer tailer.deinit();

    const output = try std.fs.path.join(gpa, &.{ temp.path, "proj", uuid, "tasks", "b1.output" });
    defer gpa.free(output);
    try writeFile(io, output, "line one\n");
    tailer.watchTaskOutput("toolu_1", output);
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    try appendFile(io, output, "line two\n");
    try std.testing.expect(arrived.within(io, 3000));
}

test "a subagent's transcript is found the moment its folders appear" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try temp_dir.Dir.initFromProcess(gpa, io, "marlin-tail-discover");
    defer temp.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("CLAUDE_CONFIG_DIR", temp.path);
    var arrived: Arrived = .{ .want = "→ Read src/x.zig" };
    var tracker = guest_activity.Tracker.init(gpa, Arrived.publish, &arrived);
    tracker.io = io;
    defer tracker.deinit();
    try tracker.start("toolu_1", "", .agent, "Agent", "scout", 0);
    var tailer = tail.Tailer.init(gpa, io, &tracker, uuid, "/work/app", &env);
    if (!tailer.notifier.available()) {
        tailer.deinit();
        return error.SkipZigTest;
    }
    tailer.safety_ms = 60_000;
    tailer.start();
    defer tailer.deinit();

    // Nothing of the session exists yet: the watch walks down as Claude Code
    // creates the project, session and subagents folders.
    tailer.watchSubagent("toolu_1");
    io.sleep(.fromMilliseconds(100), .awake) catch {};
    const sub = try std.fs.path.join(gpa, &.{ temp.path, "projects", "-work-app", uuid, "subagents" });
    defer gpa.free(sub);
    const meta = try std.fs.path.join(gpa, &.{ sub, "agent-z.meta.json" });
    defer gpa.free(meta);
    try writeFile(io, meta, "{\"toolUseId\":\"toolu_1\"}");
    const transcript = try std.fs.path.join(gpa, &.{ sub, "agent-z.jsonl" });
    defer gpa.free(transcript);
    try writeFile(io, transcript, "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Read\",\"input\":{\"file_path\":\"src/x.zig\"}}]}}\n");
    try std.testing.expect(arrived.within(io, 3000));
}
