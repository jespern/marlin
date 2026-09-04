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
