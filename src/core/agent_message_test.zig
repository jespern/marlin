const std = @import("std");
const agent_message = @import("agent_message.zig");

test "legacy agent messages are recognized by their delivery header" {
    const gpa = std.testing.allocator;
    // Titles are written raw, so they may hold quotes and parentheses.
    const session = (try agent_message.parseLegacy(gpa,
        \\[Message from another Marlin session: "phone/voice (v2) "draft"" (claudecode/claude-opus-5-5), handle 2e96c9d3. Answer with message_session to that handle if it needs an answer.]
        \\
        \\From phone/voice, answers:
    )).?;
    defer gpa.free(session.from);
    try std.testing.expectEqualStrings("phone/voice (v2) \"draft\" · 2e96c9d3", session.from);
    try std.testing.expectEqualStrings("From phone/voice, answers:", session.body);

    const outside = (try agent_message.parseLegacy(gpa,
        \\[Message from Robin, the user's assistant outside Marlin. It reads your reply here.]
        \\
        \\Can you check the build?
    )).?;
    defer gpa.free(outside.from);
    try std.testing.expectEqualStrings("Robin", outside.from);
    try std.testing.expectEqualStrings("Can you check the build?", outside.body);

    // What the user typed is never mistaken for one.
    try std.testing.expect((try agent_message.parseLegacy(gpa, "[Message from me] hello")) == null);
    try std.testing.expect((try agent_message.parseLegacy(gpa, "[Message from me]\n\nhello")) == null);
    try std.testing.expect((try agent_message.parseLegacy(gpa, "fix the parser")) == null);
}
