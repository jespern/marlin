//! Unit tests for headless.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in headless.zig.

const std = @import("std");
const Io = std.Io;
const block = @import("../core/block.zig");
const proto = @import("../core/proto.zig");
const session_handle = @import("../core/session_handle.zig");
const attach = @import("attach.zig");
const media = @import("media.zig");
const self_build = @import("self_build.zig");

const headless = @import("headless.zig");
const RebuildActions = headless.RebuildActions;
const RebuildScope = headless.RebuildScope;
const inspect = headless.inspect;
const parseFlags = headless.parseFlags;
const parseInspectOptions = headless.parseInspectOptions;
const parseRebootOptions = headless.parseRebootOptions;
const reboot = headless.reboot;
const rebuildActions = headless.rebuildActions;

test {
    std.testing.refAllDecls(headless);
}

test "reboot scopes map to local and remote actions" {
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = false, .reboot_daemon = true },
        rebuildActions(.attached, false),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = false, .remote = true, .reboot_daemon = true },
        rebuildActions(.attached, true),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = false, .reboot_daemon = false },
        rebuildActions(.client, true),
    );
    try std.testing.expectEqual(
        RebuildActions{ .local = true, .remote = true, .reboot_daemon = true },
        rebuildActions(.both, true),
    );
}

test "reboot option parsing preserves follow-up arguments" {
    const args = [_][:0]const u8{ "--build-both", "--force", "--then", "attach", "@7" };
    const options = try parseRebootOptions(&args);
    try std.testing.expectEqual(RebuildScope.both, options.rebuild);
    try std.testing.expect(options.force);
    try std.testing.expectEqual(@as(?usize, 3), options.follow_up_at);
    try std.testing.expectError(error.InvalidArgument, parseRebootOptions(&.{"--bogus"}));
}

test "flag parsing" {
    const args = [_][:0]const u8{ "--continue", "--model", "openrouter/x", "do stuff" };
    const f = try parseFlags(&args);
    try std.testing.expect(f.continue_last);
    try std.testing.expectEqualStrings("openrouter/x", f.model.?);
    try std.testing.expectEqualStrings("do stuff", f.task.?);
}

test "inspect option parsing" {
    const args = [_][:0]const u8{ "63df", "--json", "--kind", "tool_result", "--limit", "40", "--around", "12", "--turn", "latest" };
    const options = try parseInspectOptions(&args);
    try std.testing.expectEqualStrings("63df", options.handle.?);
    try std.testing.expect(options.json);
    try std.testing.expectEqual(block.BlockKind.tool_result, options.kind.?);
    try std.testing.expectEqual(@as(u32, 40), options.limit);
    try std.testing.expectEqual(@as(u64, 12), options.around_seq);
    try std.testing.expect(options.latest_turn);
}

test "inspect option parsing rejects unsafe or contradictory bounds" {
    try std.testing.expectError(error.InvalidLimit, parseInspectOptions(&.{ "63df", "--limit", "0" }));
    try std.testing.expectError(error.InvalidKind, parseInspectOptions(&.{ "63df", "--kind", "bogus" }));
    try std.testing.expectError(error.ConflictingOptions, parseInspectOptions(&.{ "63df", "--plan", "--turn", "latest" }));
    try std.testing.expectError(error.MissingHandle, parseInspectOptions(&.{"--json"}));
}

test "watch accepts flags in either order and rejects missing or extra handles" {
    const options = try headless.parseWatchOptions(&.{ "--json", "63df", "--until-idle" });
    try std.testing.expectEqualStrings("63df", options.handle.?);
    try std.testing.expect(options.json and options.until_idle);
    try std.testing.expectError(error.MissingHandle, headless.parseWatchOptions(&.{"--json"}));
    try std.testing.expectError(error.InvalidArgument, headless.parseWatchOptions(&.{ "63df", "beef" }));
    try std.testing.expectError(error.InvalidArgument, headless.parseWatchOptions(&.{ "63df", "--wat" }));
}

/// The peer is outside the client: it checks the actual subscription on the
/// wire and fails if watching sends input, answers an approval, or polls.
const WatchPeer = struct {
    io: Io,
    server: *Io.net.Server,
    messages: []const proto.DaemonMsg,
    disconnect: bool,
    failed: std.atomic.Value(bool) = .init(false),

    fn serve(self: *WatchPeer) !void {
        var stream = try self.server.accept(self.io);
        defer stream.close(self.io);
        var read_buffer: [4096]u8 = undefined;
        var reader = Io.net.Stream.Reader.init(stream, self.io, &read_buffer);
        const line = try reader.interface.takeDelimiterInclusive('\n');
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const request = try proto.decode(proto.ClientMsg, arena.allocator(), line);
        if (request != .sub or request.sub.sid != 7 or request.sub.from_seq != 0)
            return error.NotLiveOnly;
        var write_buffer: [8192]u8 = undefined;
        var writer = Io.net.Stream.Writer.init(stream, self.io, &write_buffer);
        for (self.messages) |message| {
            const encoded = try proto.encode(arena.allocator(), message);
            try writer.interface.writeAll(encoded);
        }
        try writer.interface.flush();
        if (self.disconnect) return;
        _ = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        return error.WatcherSentAnotherCommand;
    }

    fn run(self: *WatchPeer) void {
        self.serve() catch self.failed.store(true, .release);
    }
};

fn watchFixture(messages: []const proto.DaemonMsg, options: headless.WatchOptions, disconnect: bool) !struct { code: u8, output: []u8 } {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-watch");
    defer temp.deinit();
    const path = try std.fs.path.join(gpa, &.{ temp.path, "daemon.sock" });
    defer gpa.free(path);
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    try environ.put("MARLIN_SOCKET", path);
    const address = try Io.net.UnixAddress.init(path);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    var peer = WatchPeer{ .io = io, .server = &server, .messages = messages, .disconnect = disconnect };
    const thread = try std.Thread.spawn(.{}, WatchPeer.run, .{&peer});
    var joined = false;
    defer if (!joined) {
        if (address.connect(io)) |wake| wake.close(io) else |_| {}
        thread.join();
    };
    var output: Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    const code = blk: {
        const conn = (try attach.tryConnect(gpa, io, &environ)) orelse return error.CannotConnect;
        defer conn.deinit();
        var stream = headless.WatchStream{ .sid = 7, .handle = "abcdef12", .options = options, .writer = &output.writer };
        break :blk try headless.streamWatch(gpa, conn, &stream);
    };
    thread.join();
    joined = true;
    try std.testing.expect(!peer.failed.load(.acquire));
    return .{ .code = code, .output = try gpa.dupe(u8, output.written()) };
}

test "watch streams finalized NDJSON and waits through approvals without answering them" {
    const text = "done\nwith \"quotes\"";
    const result = try watchFixture(&.{
        .{ .status = .{ .sid = 8, .state = .idle } },
        .{ .status = .{ .sid = 7, .state = .running, .phase = .provider } },
        .{ .delta = .{ .sid = 7, .turn_id = 2, .text = text } },
        .{ .status = .{ .sid = 7, .state = .awaiting_approval } },
        .{ .approval_request = .{ .sid = 7, .approval_id = "approval", .call_id = "call", .tool = "bash", .args_json = "" } },
        .{ .question_request = .{ .sid = 7, .question_id = "question", .question = "Continue?", .options = &.{ "Yes", "No" } } },
        .{ .status = .{ .sid = 7, .state = .running } },
        .{ .blk = .{ .sid = 7, .b = .{ .id = 1, .session_id = 7, .turn_id = 2, .seq = 9, .ts = 123, .body = .{ .assistant_msg = .{ .text = text } } } } },
        .{ .status = .{ .sid = 7, .state = .idle } },
    }, .{ .json = true, .until_idle = true }, false);
    defer std.testing.allocator.free(result.output);
    try std.testing.expectEqual(@as(u8, 0), result.code);
    var lines = std.mem.tokenizeScalar(u8, result.output, '\n');
    const states = [_][]const u8{ "running", "awaiting_approval", "running", "block", "idle" };
    for (states) |expected| {
        const line = lines.next() orelse return error.MissingEvent;
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqualStrings("abcdef12", object.get("session").?.string);
        if (std.mem.eql(u8, expected, "block")) {
            try std.testing.expectEqualStrings("block", object.get("event").?.string);
            try std.testing.expectEqual(@as(i64, 9), object.get("seq").?.integer);
            try std.testing.expectEqualStrings(text, object.get("body").?.object.get("assistant_msg").?.object.get("text").?.string);
        } else {
            try std.testing.expectEqualStrings("status", object.get("event").?.string);
            try std.testing.expectEqualStrings(expected, object.get("state").?.string);
        }
    }
    try std.testing.expect(lines.next() == null);
}

test "watch ends immediately for an idle session and fails for session errors" {
    for ([_]proto.SessionState{ .idle, .done, .err }) |state| {
        const result = try watchFixture(&.{.{ .status = .{ .sid = 7, .state = state, .err_text = if (state == .err) "provider failed" else null } }}, .{ .until_idle = true }, false);
        defer std.testing.allocator.free(result.output);
        try std.testing.expectEqual(@as(u8, if (state == .err) 1 else 0), result.code);
        if (state == .err) try std.testing.expect(std.mem.indexOf(u8, result.output, "provider failed") != null);
    }
}

test "watch keeps following across turns and reports EOF instead of claiming completion" {
    const result = try watchFixture(&.{
        .{ .status = .{ .sid = 7, .state = .idle } },
        .{ .status = .{ .sid = 7, .state = .running } },
    }, .{ .json = true }, true);
    defer std.testing.allocator.free(result.output);
    try std.testing.expectEqual(@as(u8, 1), result.code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"state\":\"idle\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"state\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"event\":\"error\"") != null);
}

test "watch reports daemon errors and deliberate shutdown" {
    for ([_]proto.DaemonMsg{
        .{ .err = .{ .code = "no_session", .msg = "session no longer exists" } },
        .{ .daemon_stopping = .{} },
    }) |message| {
        const result = try watchFixture(&.{message}, .{ .json = true }, false);
        defer std.testing.allocator.free(result.output);
        try std.testing.expectEqual(@as(u8, 1), result.code);
        try std.testing.expect(std.mem.indexOf(u8, result.output, "\"event\":\"error\"") != null);
    }
}
