//! Agents talking across sessions, whatever model each runs: list the other
//! sessions, read one's recent transcript, message one, and wait for one's
//! turn to end. The same four tools reach the native agent (registry) and
//! guests (the `marlin cc_approve` MCP server, as mcp__marlin__<name>).
//! Execution is daemon-owned (daemon.zig agentTool); this module holds the
//! specs and the text the tools return.
const std = @import("std");
const block = @import("../../core/block.zig");

pub const list_name = "sessions";
pub const read_name = "read_session";
pub const message_name = "message_session";
pub const wait_name = "wait_for_session";
pub const names = [_][]const u8{ list_name, read_name, message_name, wait_name };

/// A message chain stops after this many agent-to-agent hops (A tells B,
/// B tells C or answers A, …): two agents must not ping-pong forever.
pub const max_hops: u8 = 5;
/// Messages one turn may send.
pub const max_messages_per_turn: u32 = 10;
/// read_session: blocks shown by default and at most, and the text cap.
pub const default_read_blocks: usize = 20;
pub const max_read_blocks: usize = 100;
pub const max_read_bytes: usize = 16 * 1024;
/// Longest single block text shown by read_session.
const max_block_chars: usize = 2000;

pub fn isTool(name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

pub const Spec = struct { name: []const u8, description: []const u8, schema: []const u8, mutating: bool };

pub const specs = [_]Spec{
    .{
        .name = list_name,
        .description = "List the other Marlin sessions you can talk to: their handle, state (idle, running, waiting on the user), model, title, and folder. Other sessions are other agents working for the same user, possibly on other models.",
        .schema =
        \\{"type":"object","properties":{}}
        ,
        .mutating = false,
    },
    .{
        .name = read_name,
        .description = "Read the recent transcript of another Marlin session: what its user asked and what its agent answered, with one line per tool call. Use the handle from `sessions`.",
        .schema =
        \\{"type":"object","properties":{"handle":{"type":"string","description":"The session's handle (at least 4 characters of it)"},"last":{"type":"integer","minimum":1,"maximum":100,"description":"How many recent transcript entries (default 20)"}},"required":["handle"]}
        ,
        .mutating = false,
    },
    .{
        .name = message_name,
        .description = "Send a message to another Marlin session's agent. An idle session starts working on it; a busy one receives it between its steps. It arrives marked as from you, so it can answer with message_session. To get its answer back in this turn, call wait_for_session after. Chains of agent messages stop after a few hops.",
        .schema =
        \\{"type":"object","properties":{"handle":{"type":"string","description":"The session's handle (at least 4 characters of it)"},"text":{"type":"string","description":"The message, written for another agent with none of your context"}},"required":["handle","text"]}
        ,
        .mutating = true,
    },
    .{
        .name = wait_name,
        .description = "Wait until another Marlin session finishes its current turn, then return its last reply. Returns at once when it is idle. Use after message_session to get the answer.",
        .schema =
        \\{"type":"object","properties":{"handle":{"type":"string","description":"The session's handle (at least 4 characters of it)"}},"required":["handle"]}
        ,
        .mutating = false,
    },
};

pub const ReadArgs = struct { handle: []const u8, last: ?u32 = null };
pub const MessageArgs = struct { handle: []const u8, text: []const u8 };
pub const HandleArgs = struct { handle: []const u8 };

/// How a message from another agent reads in the receiving session: who sent
/// it and how to answer, then the text.
pub fn messageText(gpa: std.mem.Allocator, from_handle: []const u8, from_title: []const u8, from_model: []const u8, text: []const u8) ![]u8 {
    const title = if (from_title.len > 0) from_title else "(untitled)";
    return std.fmt.allocPrint(gpa,
        \\[Message from another Marlin session: "{s}" ({s}), handle {s}. Answer with message_session to that handle if it needs an answer.]
        \\
        \\{s}
    , .{ title, from_model, from_handle, text });
}

/// Who a session message is from, as its receiver's transcript names it.
pub fn senderLabel(gpa: std.mem.Allocator, handle: []const u8, title: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} · {s}", .{ if (title.len > 0) title else "(untitled)", handle });
}

/// A message from the user's assistant outside Marlin (the MCP server):
/// it reads the answer from this session, so there is no handle to reply to.
pub fn outsideMessageText(gpa: std.mem.Allocator, from: []const u8, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\[Message from {s}, the user's assistant outside Marlin. It reads your reply here.]
        \\
        \\{s}
    , .{ from, text });
}

/// The newest assistant reply in `blocks` (oldest first), or null.
pub fn lastReply(blocks: []const block.Block) ?[]const u8 {
    var i = blocks.len;
    while (i > 0) {
        i -= 1;
        switch (blocks[i].body) {
            .assistant_msg => |a| if (a.text.len > 0) return a.text,
            else => {},
        }
    }
    return null;
}

/// The transcript tail as plain text for another agent: who said what, one
/// line per tool call, newest last, the oldest entries dropped first when
/// over `max_read_bytes`.
pub fn transcriptTail(arena: std.mem.Allocator, blocks: []const block.Block) ![]const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    for (blocks) |b| {
        const entry: ?[]const u8 = switch (b.body) {
            .user_msg => |u| if (u.synthetic) null else if (u.from) |from|
                try labelled(arena, try std.fmt.allocPrint(arena, "message from {s}", .{from}), u.display_text orelse u.text)
            else
                try labelled(arena, "user", u.display_text orelse u.text),
            .steer => |s| if (s.from) |from|
                try labelled(arena, try std.fmt.allocPrint(arena, "message from {s} (while it worked)", .{from}), s.display_text orelse s.text)
            else
                try labelled(arena, "user (while it worked)", s.display_text orelse s.text),
            .assistant_msg => |a| try labelled(arena, "agent", a.text),
            .reasoning => |r| if (r.commentary) try labelled(arena, "agent (note)", r.text) else null,
            .tool_call => |tc| try std.fmt.allocPrint(arena, "tool: {s} {s}", .{ tc.name, clip(tc.args_json, 200) }),
            .tool_result => |tr| if (tr.status == .ok) null else try std.fmt.allocPrint(arena, "tool failed: {s}", .{clip(tr.inline_body, 300)}),
            .shell_transcript => |st| try labelled(arena, if (st.ran) |ran| try std.fmt.allocPrint(arena, "shell `{s}`", .{ran}) else "shell", st.text),
            .system_note => |n| try labelled(arena, "note", n.text),
            else => null,
        };
        if (entry) |text| try entries.append(arena, text);
    }
    var total: usize = 0;
    var first = entries.items.len;
    while (first > 0) {
        const len = entries.items[first - 1].len + 2;
        if (total + len > max_read_bytes and first < entries.items.len) break;
        total += len;
        first -= 1;
    }
    var out: std.ArrayList(u8) = .empty;
    if (first > 0) try out.print(arena, "[{d} earlier entries left out]\n\n", .{first});
    for (entries.items[first..], 0..) |entry, i| {
        if (i > 0) try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, entry);
    }
    return out.items;
}

fn labelled(arena: std.mem.Allocator, label: []const u8, text: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ label, clip(std.mem.trim(u8, text, " \t\r\n"), max_block_chars) });
}

/// At most `max` bytes, cut on a UTF-8 boundary.
fn clip(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}
