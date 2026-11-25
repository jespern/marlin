//! Unit tests for agy_watch.zig: live task log tailing and `.system_generated`
//! subagent lifecycle tracking.
const std = @import("std");
const agy_watch = @import("agy_watch.zig");
const guest_activity = @import("activity.zig");
const proto = @import("../../core/proto.zig");

const Snapshot = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Owned) = .empty,

    const Owned = struct {
        id: []u8,
        kind: proto.GuestActivityKind,
        name: []u8,
        model: []u8,
        output: []u8,
    };

    fn deinit(self: *Snapshot) void {
        self.clear();
        self.items.deinit(self.gpa);
    }

    fn clear(self: *Snapshot) void {
        for (self.items.items) |it| {
            self.gpa.free(it.id);
            self.gpa.free(it.name);
            self.gpa.free(it.model);
            self.gpa.free(it.output);
        }
        self.items.clearRetainingCapacity();
    }

    fn publish(ctx: ?*anyopaque, items: []const proto.GuestActivity) void {
        const self: *Snapshot = @ptrCast(@alignCast(ctx.?));
        self.clear();
        for (items) |it| {
            self.items.append(self.gpa, .{
                .id = self.gpa.dupe(u8, it.id) catch return,
                .kind = it.kind,
                .name = self.gpa.dupe(u8, it.name) catch return,
                .model = self.gpa.dupe(u8, it.model) catch return,
                .output = self.gpa.dupe(u8, it.output) catch return,
            }) catch return;
        }
    }

    fn find(self: *const Snapshot, id: []const u8) ?Owned {
        for (self.items.items) |it| if (std.mem.eql(u8, it.id, id)) return it;
        return null;
    }
};

test "parseTaskLogNumber matches task-<n>.log only" {
    try std.testing.expectEqual(@as(?u64, 2), agy_watch.parseTaskLogNumber("task-2.log"));
    try std.testing.expectEqual(@as(?u64, 157), agy_watch.parseTaskLogNumber("task-157.log"));
    try std.testing.expectEqual(@as(?u64, null), agy_watch.parseTaskLogNumber("task-.log"));
    try std.testing.expectEqual(@as(?u64, null), agy_watch.parseTaskLogNumber("other.log"));
}

test "condenseTranscriptLine extracts model, tool calls, and prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    const model = try agy_watch.condenseTranscriptLine(
        arena,
        \\{"step_index":1,"type":"PLANNER_RESPONSE","model":"gemini-3.5-flash-lite","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"sleep 6 && echo SUB_DONE\""}}]}
    ,
        &out,
    );
    try std.testing.expectEqualStrings("gemini-3.5-flash-lite", model.?);
    try std.testing.expectEqualStrings("→ run_command sleep 6 && echo SUB_DONE\n", out.items);
}

test "watcher tails new task logs and tracks subagent spawn, transcript, and reply" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const brain = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(brain);

    // Pre-existing task log from an earlier turn must be ignored.
    try tmp.dir.createDirPath(io, "sess-1/.system_generated/tasks");
    try tmp.dir.createDirPath(io, "sess-1/.system_generated/subagents");
    try tmp.dir.createDirPath(io, "sess-1/.system_generated/messages");
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-1/.system_generated/tasks/task-1.log", .data = "old output\n" });

    var snap = Snapshot{ .gpa = gpa };
    defer snap.deinit();
    var tracker = guest_activity.Tracker.init(gpa, Snapshot.publish, &snap);
    tracker.io = io;
    defer tracker.deinit();

    var watcher = try agy_watch.Watcher.init(gpa, io, &tracker, "sess-1", brain, null);
    defer watcher.deinit();

    // Start a background run_command and emit task-2.log.
    try tracker.start("call_cmd", "", .process, "Bash", "zig build test", 10);
    watcher.noteCommandStart("call_cmd");
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-1/.system_generated/tasks/task-2.log", .data = "building...\n" });
    watcher.refresh();
    try std.testing.expectEqualStrings("building...\n", snap.find("call_cmd").?.output);

    watcher.noteCommandFinish("call_cmd");
    tracker.finish("call_cmd");

    // Spawn a subagent: descriptor appears, then transcript, then reply message.
    try tmp.dir.writeFile(io, .{
        .sub_path = "sess-1/.system_generated/subagents/sub-1.json",
        .data =
        \\{"conversationId":"sub-1","subagentDescriptor":{"typeName":"self","role":"Sleeper"},"state":"SUBAGENT_STATE_ALIVE"}
        ,
    });
    watcher.refresh();
    try std.testing.expectEqual(@as(usize, 1), watcher.activeSubagentCount());
    var name_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Sleeper", watcher.firstActiveSubagentName(&name_buf).?);
    try std.testing.expectEqual(proto.GuestActivityKind.agent, snap.find("sub-1").?.kind);

    try tmp.dir.createDirPath(io, "sub-1/.system_generated/logs");
    try tmp.dir.writeFile(io, .{
        .sub_path = "sub-1/.system_generated/logs/transcript.jsonl",
        .data =
        \\{"step_index":1,"type":"PLANNER_RESPONSE","model":"gemini-3.5-flash-lite","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"echo hi\""}}]}
        ++ "\n",
    });
    watcher.refresh();
    try std.testing.expectEqualStrings("gemini-3.5-flash-lite", snap.find("sub-1").?.model);
    try std.testing.expectEqualStrings("→ run_command echo hi\n", snap.find("sub-1").?.output);

    // Subagent replies -> no longer active, activity node removed, subagent_replied set.
    try tmp.dir.writeFile(io, .{
        .sub_path = "sess-1/.system_generated/messages/msg-1.json",
        .data =
        \\{"id":"msg-1","sender":"sub-1","recipient":"sess-1","content":"SUB_DONE"}
        ,
    });
    watcher.refresh();
    try std.testing.expectEqual(@as(usize, 0), watcher.activeSubagentCount());
    try std.testing.expect(snap.find("sub-1") == null);
    try std.testing.expect(watcher.takeSubagentReply());
    try std.testing.expect(!watcher.takeSubagentReply());

    // Messaging the same subagent re-arms it until another reply arrives.
    watcher.noteSubagentMessaged("sub-1");
    try std.testing.expectEqual(@as(usize, 1), watcher.activeSubagentCount());
    watcher.noteSubagentKilled("sub-1");
    try std.testing.expectEqual(@as(usize, 0), watcher.activeSubagentCount());
}

test "parseParentTranscriptIdle distinguishes idle text reply from active work steps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(?bool, true), agy_watch.parseParentTranscriptIdle(
        arena,
        \\{"step_index":670,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","content":"All done."}
        ,
    ));
    try std.testing.expectEqual(@as(?bool, false), agy_watch.parseParentTranscriptIdle(
        arena,
        \\{"step_index":668,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"run_command"}]}
        ,
    ));
    try std.testing.expectEqual(@as(?bool, false), agy_watch.parseParentTranscriptIdle(
        arena,
        \\{"step_index":671,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","content":"task-669 finished"}
        ,
    ));
    try std.testing.expectEqual(@as(?bool, false), agy_watch.parseParentTranscriptIdle(
        arena,
        \\{"step_index":669,"source":"MODEL","type":"GENERIC","status":"RUNNING","content":"running"}
        ,
    ));
    try std.testing.expectEqual(@as(?bool, false), agy_watch.parseParentTranscriptIdle(
        arena,
        \\{"step_index":672,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","content":"hi"}
        ,
    ));
}

test "isWakeupMessage accepts background tasks and subagents but ignores low-priority system notices" {
    const gpa = std.testing.allocator;
    const task_msg = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"id":"m1","sender":"sess/task-669","priority":"MESSAGE_PRIORITY_HIGH","content":"done"}
    ,
        .{},
    );
    defer task_msg.deinit();
    try std.testing.expect(agy_watch.isWakeupMessage(task_msg.value));

    const sub_msg = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"id":"m2","sender":"sub-1","content":"SUB_DONE"}
    ,
        .{},
    );
    defer sub_msg.deinit();
    try std.testing.expect(agy_watch.isWakeupMessage(sub_msg.value));

    const sys_notice = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        \\{"id":"m3","sender":"system","priority":"MESSAGE_PRIORITY_LOW","hideFromUser":true,"content":"restarted"}
    ,
        .{},
    );
    defer sys_notice.deinit();
    try std.testing.expect(!agy_watch.isWakeupMessage(sys_notice.value));
}

test "watcher tracks parent transcript busy state, undelivered messages, and read.json delivery" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const brain = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(brain);

    try tmp.dir.createDirPath(io, "sess-p/.system_generated/logs");
    try tmp.dir.createDirPath(io, "sess-p/.system_generated/messages/undelivered");
    // Pre-existing trailing SYSTEM_MESSAGE from an earlier crashed turn must NOT mark this turn busy.
    const transcript_rel = "sess-p/.system_generated/logs/transcript.jsonl";
    const prior = "{\"step_index\":1,\"source\":\"SYSTEM\",\"type\":\"SYSTEM_MESSAGE\",\"status\":\"DONE\"}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = transcript_rel, .data = prior });
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-p/.system_generated/messages/read.json", .data = "{}" });

    var snap = Snapshot{ .gpa = gpa };
    defer snap.deinit();
    var tracker = guest_activity.Tracker.init(gpa, Snapshot.publish, &snap);
    tracker.io = io;
    defer tracker.deinit();

    var watcher = try agy_watch.Watcher.init(gpa, io, &tracker, "sess-p", brain, null);
    defer watcher.deinit();
    watcher.refresh();
    try std.testing.expect(!watcher.isParentBusy());
    try std.testing.expect(!watcher.hasPendingPromptWakeup());

    // Background task completes mid-step: writes message + undelivered marker.
    try tmp.dir.writeFile(io, .{
        .sub_path = "sess-p/.system_generated/messages/m-669.json",
        .data =
        \\{"id":"m-669","sender":"sess-p/task-669","priority":"MESSAGE_PRIORITY_HIGH","content":"ok"}
        ,
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-p/.system_generated/messages/undelivered/m-669.json", .data = "{}" });
    watcher.refresh();
    try std.testing.expect(watcher.isParentBusy());
    try std.testing.expect(watcher.hasPendingPromptWakeup());

    // agy delivers m-669: removes from undelivered, marks read.json, appends SYSTEM_MESSAGE to transcript.jsonl.
    try tmp.dir.deleteFile(io, "sess-p/.system_generated/messages/undelivered/m-669.json");
    try tmp.dir.writeFile(io, .{ .sub_path = "sess-p/.system_generated/messages/read.json", .data = "{\"m-669\":true}" });
    const step_delivered = prior ++
        "{\"step_index\":670,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"waiting\"}\n" ++
        "{\"step_index\":671,\"source\":\"SYSTEM\",\"type\":\"SYSTEM_MESSAGE\",\"status\":\"DONE\",\"content\":\"task-669 finished\"}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = transcript_rel, .data = step_delivered });
    watcher.clearWakeupSignal();
    watcher.refresh();
    try std.testing.expect(watcher.isParentBusy());
    try std.testing.expect(watcher.hasPendingPromptWakeup());

    // Reactive LLM step completes with a tool-less PLANNER_RESPONSE -> parent is idle again.
    const step_done = step_delivered ++
        "{\"step_index\":672,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"content\":\"commit landed\"}\n";
    try tmp.dir.writeFile(io, .{ .sub_path = transcript_rel, .data = step_done });
    watcher.refresh();
    try std.testing.expect(!watcher.isParentBusy());
    try std.testing.expect(!watcher.hasPendingPromptWakeup());
}
