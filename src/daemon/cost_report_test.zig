const std = @import("std");
const Io = std.Io;
const cost_report = @import("cost_report.zig");
const cost = @import("../core/cost.zig");

fn write(io: Io, root: []const u8, rel: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

test "cost report counts each response once, finds rewrites, and tells Marlin's guests from the vendors' own UIs" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cost");
    defer temp.deinit();
    const home = temp.path;

    // A Marlin session's Claude Code log: one response logged per content
    // block (same message id), then a full rewrite of a 300K context.
    try write(io, home, ".claude/projects/-w/aaaaaaaa-0000-4000-8000-000000000001.jsonl",
        \\{"type":"assistant","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","entrypoint":"sdk-cli","timestamp":"2099-01-01T00:00:00Z","message":{"id":"m1","model":"claude-fable-5-2","usage":{"input_tokens":2,"cache_read_input_tokens":200000,"cache_creation_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000}}}}
        \\{"type":"assistant","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","entrypoint":"sdk-cli","timestamp":"2099-01-01T00:00:00Z","message":{"id":"m1","model":"claude-fable-5-2","usage":{"input_tokens":2,"cache_read_input_tokens":200000,"cache_creation_input_tokens":1000,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000}}}}
        \\{"type":"assistant","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","entrypoint":"sdk-cli","timestamp":"2099-01-01T00:10:00Z","message":{"id":"m2","model":"claude-fable-5-2","usage":{"input_tokens":2,"cache_read_input_tokens":14000,"cache_creation_input_tokens":286000,"output_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":286000,"ephemeral_1h_input_tokens":0}}}}
        \\{"type":"user","sessionId":"aaaaaaaa-0000-4000-8000-000000000001","message":{"content":"next"}}
        \\
    );
    // An interactive session, and a line from before the window.
    try write(io, home, ".claude/projects/-w/bbbbbbbb-0000-4000-8000-000000000002.jsonl",
        \\{"type":"assistant","sessionId":"bbbbbbbb-0000-4000-8000-000000000002","entrypoint":"cli","timestamp":"2099-01-01T00:00:00Z","message":{"id":"i1","model":"claude-fable-5-2","usage":{"input_tokens":5,"cache_read_input_tokens":90000,"cache_creation_input_tokens":2000,"output_tokens":10}}}
        \\{"type":"assistant","sessionId":"bbbbbbbb-0000-4000-8000-000000000002","entrypoint":"cli","timestamp":"1999-01-01T00:00:00Z","message":{"id":"old","model":"claude-fable-5-2","usage":{"input_tokens":5,"cache_read_input_tokens":90000,"cache_creation_input_tokens":2000,"output_tokens":10}}}
        \\
    );
    // A Codex rollout driven by Marlin: a repeated report is one call.
    try write(io, home, ".codex/sessions/2099/01/01/rollout-x.jsonl",
        \\{"timestamp":"2099-01-01T00:00:00Z","type":"session_meta","payload":{"id":"thread-1","originator":"marlin"}}
        \\{"timestamp":"2099-01-01T00:00:00Z","type":"turn_context","payload":{"model":"gpt-6-sol"}}
        \\{"timestamp":"2099-01-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120100},"last_token_usage":{"input_tokens":120000,"cached_input_tokens":118000,"output_tokens":100}}}}
        \\{"timestamp":"2099-01-01T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":120100},"last_token_usage":{"input_tokens":120000,"cached_input_tokens":118000,"output_tokens":100}}}}
        \\{"timestamp":"2099-01-01T00:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":360300},"last_token_usage":{"input_tokens":240000,"cached_input_tokens":20000,"output_tokens":200}}}}
        \\
    );

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var marlin = cost_report.Marlin{};
    try marlin.claude.put(arena, "aaaaaaaa-0000-4000-8000-000000000001", 7);
    try marlin.names.put(arena, 7, .{ .handle = "be4719c6", .title = "postgres" });
    // Since 2000: the 1999 line is outside the window.
    const report = try cost_report.scan(arena, io, home, 946_684_800_000, &marlin);

    try std.testing.expectEqual(@as(u64, 3), report.files);
    var marlin_claude: ?cost.Group = null;
    var interactive: ?cost.Group = null;
    var codex: ?cost.Group = null;
    for (report.groups) |g| {
        if (std.mem.eql(u8, g.backend, "claude_code") and std.mem.eql(u8, g.client, "marlin")) marlin_claude = g;
        if (std.mem.eql(u8, g.backend, "claude_code") and std.mem.eql(u8, g.client, "interactive")) interactive = g;
        if (std.mem.eql(u8, g.backend, "codex")) codex = g;
    }
    try std.testing.expectEqual(@as(u64, 2), marlin_claude.?.requests);
    try std.testing.expectEqual(@as(u64, 1), marlin_claude.?.rewrites);
    try std.testing.expectEqual(@as(u64, 286_000), marlin_claude.?.rewrite_tokens);
    try std.testing.expectEqual(@as(u64, 286_000), marlin_claude.?.cache_write_5m);
    try std.testing.expectEqual(@as(u64, 1_000), marlin_claude.?.cache_write_1h);
    try std.testing.expectEqual(@as(u64, 1), interactive.?.requests);
    try std.testing.expectEqualStrings("marlin", codex.?.client);
    try std.testing.expectEqualStrings("gpt-6-sol", codex.?.model);
    try std.testing.expectEqual(@as(u64, 2), codex.?.requests);
    try std.testing.expectEqual(@as(u64, 1), codex.?.rewrites);

    try std.testing.expectEqual(@as(usize, 1), report.sessions.len);
    try std.testing.expectEqualStrings("postgres", report.sessions[0].title);
    try std.testing.expectEqual(@as(u64, 2), report.sessions[0].requests);
}
