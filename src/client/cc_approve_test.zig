//! Unit tests for cc_approve.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in cc_approve.zig.

const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

const cc_approve = @import("cc_approve.zig");
const Decision = cc_approve.Decision;
const Decider = cc_approve.Decider;
const handleLine = cc_approve.handleLine;

test {
    std.testing.refAllDecls(cc_approve);
}

const TestDecider = struct {
    var last_tool: [64]u8 = undefined;
    var last_tool_len: usize = 0;
    var last_input: [256]u8 = undefined;
    var last_input_len: usize = 0;
    var answer: proto.ApprovalAnswer = .granted;
    var answer_message: ?[]const u8 = null;

    fn decide(_: ?*anyopaque, tool_name: []const u8, input_json: []const u8) Decision {
        last_tool_len = @min(tool_name.len, last_tool.len);
        @memcpy(last_tool[0..last_tool_len], tool_name[0..last_tool_len]);
        last_input_len = @min(input_json.len, last_input.len);
        @memcpy(last_input[0..last_input_len], input_json[0..last_input_len]);
        return Decision.init(answer, answer_message);
    }
};

test "mcp handshake: initialize echoes protocol version, tools/list declares approve" {
    const gpa = std.testing.allocator;
    const decider = Decider{ .decide = TestDecider.decide };

    const init_reply = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}
    , decider).?;
    defer gpa.free(init_reply);
    try std.testing.expect(std.mem.indexOf(u8, init_reply, "\"id\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, init_reply, "\"protocolVersion\":\"2024-11-05\"") != null);

    // Notifications never get replies.
    try std.testing.expect(handleLine(gpa,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    , decider) == null);

    const list_reply = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    , decider).?;
    defer gpa.free(list_reply);
    try std.testing.expect(std.mem.indexOf(u8, list_reply, "\"name\":\"approve\"") != null);
}

test "tools/call forwards the prompt and wraps the verdict for Claude Code" {
    const gpa = std.testing.allocator;
    const decider = Decider{ .decide = TestDecider.decide };

    TestDecider.answer = .granted;
    const allow = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{"command":"zig build test"}}}}
    , decider).?;
    defer gpa.free(allow);
    try std.testing.expectEqualStrings("Bash", TestDecider.last_tool[0..TestDecider.last_tool_len]);
    try std.testing.expect(std.mem.indexOf(u8, TestDecider.last_input[0..TestDecider.last_input_len], "zig build test") != null);
    // The behavior payload is json-in-json: escaped inside the text block.
    try std.testing.expect(std.mem.indexOf(u8, allow, "\\\"behavior\\\":\\\"allow\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, allow, "updatedInput") != null);

    TestDecider.answer = .denied;
    const deny = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{}}}}
    , decider).?;
    defer gpa.free(deny);
    try std.testing.expect(std.mem.indexOf(u8, deny, "\\\"behavior\\\":\\\"deny\\\"") != null);

    // A call without a tool_name cannot be judged: deny, never allow.
    TestDecider.answer = .granted;
    const malformed = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"approve","arguments":{}}}
    , decider).?;
    defer gpa.free(malformed);
    try std.testing.expect(std.mem.indexOf(u8, malformed, "\\\"behavior\\\":\\\"deny\\\"") != null);

    const unknown = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":10,"method":"nope"}
    , decider).?;
    defer gpa.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "-32601") != null);
}

test "bridge ask_user: listed, forwards to the picker, and reports dismissal" {
    const gpa = std.testing.allocator;
    const AskStub = struct {
        fn decide(_: ?*anyopaque, _: []const u8, _: []const u8) cc_approve.Decision {
            return cc_approve.Decision.init(.denied, null);
        }
        fn answered(_: ?*anyopaque, question: []const u8, options_json: []const u8) cc_approve.QuestionAnswer {
            std.testing.expectEqualStrings("Tabs or spaces?", question) catch unreachable;
            std.testing.expect(std.mem.indexOf(u8, options_json, "Tabs") != null) catch unreachable;
            return cc_approve.QuestionAnswer.init("Spaces");
        }
        fn dismissed(_: ?*anyopaque, _: []const u8, _: []const u8) cc_approve.QuestionAnswer {
            return cc_approve.QuestionAnswer.init(null);
        }
    };

    const list_reply = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    , .{ .decide = AskStub.decide, .ask_question = AskStub.answered }).?;
    defer gpa.free(list_reply);
    try std.testing.expect(std.mem.indexOf(u8, list_reply, "\"ask_user\"") != null);

    const call =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask_user","arguments":{"question":"Tabs or spaces?","options":["Tabs","Spaces"]}}}
    ;
    const answered = handleLine(gpa, call, .{ .decide = AskStub.decide, .ask_question = AskStub.answered }).?;
    defer gpa.free(answered);
    try std.testing.expect(std.mem.indexOf(u8, answered, "Spaces") != null);

    const dismissed = handleLine(gpa, call, .{ .decide = AskStub.decide, .ask_question = AskStub.dismissed }).?;
    defer gpa.free(dismissed);
    try std.testing.expect(std.mem.indexOf(u8, dismissed, "dismissed the question") != null);
}

test "bridge: the tools for other sessions are listed and forwarded, failures flagged as errors" {
    const gpa = std.testing.allocator;
    const Probe = struct {
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;
        var args_buf: [256]u8 = undefined;
        var args_len: usize = 0;
        var ok = true;
        fn decide(_: ?*anyopaque, _: []const u8, _: []const u8) Decision {
            return Decision.init(.denied, null);
        }
        fn agent(_: ?*anyopaque, alloc: std.mem.Allocator, name: []const u8, args_json: []const u8) ?cc_approve.AgentToolResult {
            name_len = name.len;
            @memcpy(name_buf[0..name.len], name);
            args_len = args_json.len;
            @memcpy(args_buf[0..args_json.len], args_json);
            return .{ .text = alloc.dupe(u8, "Delivered to ab12cd34.") catch return null, .ok = ok };
        }
    };
    const decider = Decider{ .decide = Probe.decide, .agent_tool = Probe.agent };

    const listed = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    , decider).?;
    defer gpa.free(listed);
    for ([_][]const u8{ "\"approve\"", "\"ask_user\"", "\"sessions\"", "\"read_session\"", "\"message_session\"", "\"wait_for_session\"" }) |name|
        try std.testing.expect(std.mem.indexOf(u8, listed, name) != null);
    // Without a daemon behind it, the bridge offers only what it had.
    const bare = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    , Decider{ .decide = Probe.decide }).?;
    defer gpa.free(bare);
    try std.testing.expect(std.mem.indexOf(u8, bare, "message_session") == null);

    const reply = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"message_session","arguments":{"handle":"ab12","text":"hi"}}}
    , decider).?;
    defer gpa.free(reply);
    try std.testing.expectEqualStrings("message_session", Probe.name_buf[0..Probe.name_len]);
    try std.testing.expectEqualStrings("{\"handle\":\"ab12\",\"text\":\"hi\"}", Probe.args_buf[0..Probe.args_len]);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Delivered to ab12cd34.") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"isError\":false") != null);

    Probe.ok = false;
    const failed = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"read_session","arguments":{"handle":"zz"}}}
    , decider).?;
    defer gpa.free(failed);
    try std.testing.expect(std.mem.indexOf(u8, failed, "\"isError\":true") != null);
}

test "a bridge without approve neither lists it nor runs it" {
    const gpa = std.testing.allocator;
    const Probe = struct {
        var decided = false;
        fn decide(_: ?*anyopaque, _: []const u8, _: []const u8) cc_approve.Decision {
            decided = true;
            return cc_approve.Decision.init(.granted, null);
        }
        fn agent(_: ?*anyopaque, alloc: std.mem.Allocator, _: []const u8, _: []const u8) ?cc_approve.AgentToolResult {
            return .{ .text = alloc.dupe(u8, "ok") catch return null, .ok = true };
        }
    };
    const decider = Decider{ .decide = Probe.decide, .agent_tool = Probe.agent, .approve = false };
    const listed = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    , decider).?;
    defer gpa.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"approve\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"ask_user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "\"wait_for_session\"") != null);
    const called = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"approve","arguments":{"tool_name":"Bash","input":{}}}}
    , decider).?;
    defer gpa.free(called);
    try std.testing.expect(std.mem.indexOf(u8, called, "unknown tool") != null);
    try std.testing.expect(!Probe.decided);
}

const ImageDecider = struct {
    fn load(_: ?*anyopaque, gpa: std.mem.Allocator, path: []const u8) anyerror!@import("../daemon/tools/show_image.zig").Loaded {
        if (!std.mem.eql(u8, path, "chart.png")) return error.FileNotFound;
        return .{ .bytes = try gpa.dupe(u8, "\x89PNG\r\n\x1a\nDATA"), .mime = "image/png", .name = "chart.png" };
    }
};

test "show_image over the bridge returns MCP image content Claude Code echoes" {
    const gpa = std.testing.allocator;
    const decider = Decider{ .decide = TestDecider.decide, .load_image = ImageDecider.load };
    const list = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list"}
    , decider).?;
    defer gpa.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"name\":\"show_image\"") != null);

    const shown = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_image","arguments":{"path":"chart.png"}}}
    , decider).?;
    defer gpa.free(shown);
    try std.testing.expect(std.mem.indexOf(u8, shown, "{\"type\":\"image\",\"data\":\"iVBORw0KGgpEQVRB\",\"mimeType\":\"image/png\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, shown, "Shown to the user: chart.png") != null);

    const missing = handleLine(gpa,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"show_image","arguments":{"path":"gone.png"}}}
    , decider).?;
    defer gpa.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "gone.png does not exist") != null);
}
