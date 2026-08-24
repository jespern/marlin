//! Context assembly + the compaction cascade (docs/ARCHITECTURE.md §6).
//!
//! M0 scope: blocks → provider messages with L0 caps applied. The cascade's
//! L1/L2 land in M3; the shape here is built so they slot in.
//!
//! Cache discipline: assembly is strictly append-only between compaction
//! events — same blocks in, byte-identical prefix out.

const std = @import("std");
const config = @import("../core/config.zig");
const block = @import("../core/block.zig");
const provider = @import("provider/provider.zig");

/// Estimate tokens for text not yet measured by the provider.
pub fn estimateTokens(bytes: []const u8) u64 {
    return bytes.len / 4 + 1;
}

pub const system_prompt_base =
    \\You are marlin, a fast and direct AI agent running in a terminal harness.
    \\You have tools to run shell commands and read files. Use them to complete
    \\the user's task; verify with real output rather than assuming. Be concise.
    \\When done, state the result plainly.
;

/// Apply the L0 inline cap to a tool output destined for context: head+tail
/// window with an elision marker. Returns a slice of `full` or an allocation.
pub fn capInline(gpa: std.mem.Allocator, full: []const u8, cap: usize) ![]const u8 {
    if (full.len <= cap) return full;
    const head = cap * 2 / 3;
    const tail = cap - head;
    return std.fmt.allocPrint(gpa, "{s}\n[... {d} bytes elided — full output stored ...]\n{s}", .{
        full[0..head],
        full.len - cap,
        full[full.len - tail ..],
    });
}

/// Assemble provider messages from a block log slice. All returned message
/// payloads reference either `blocks` memory or `arena` allocations — use an
/// arena scoped to the turn.
pub fn assemble(
    arena: std.mem.Allocator,
    blocks: []const block.Block,
) ![]provider.Message {
    var msgs: std.ArrayList(provider.Message) = .empty;
    try msgs.append(arena, .{ .role = .system, .payload = .{ .text = system_prompt_base } });

    // Walk blocks; group tool_calls emitted in one assistant turn.
    var i: usize = 0;
    while (i < blocks.len) : (i += 1) {
        const b = blocks[i];
        switch (b.body) {
            .user_msg => |u| try msgs.append(arena, .{ .role = .user, .payload = .{ .text = u.text } }),
            .steer => |s| try msgs.append(arena, .{ .role = .user, .payload = .{ .text = s.text } }),
            .assistant_msg => |a| try msgs.append(arena, .{ .role = .assistant, .payload = .{ .text = a.text } }),
            .tool_call => {
                // Collect consecutive tool_call blocks of this turn.
                var calls: std.ArrayList(provider.ToolCall) = .empty;
                var j = i;
                while (j < blocks.len) : (j += 1) {
                    switch (blocks[j].body) {
                        .tool_call => |tc| try calls.append(arena, .{
                            .call_id = tc.call_id,
                            .name = tc.name,
                            .args_json = tc.args_json,
                        }),
                        else => break,
                    }
                }
                try msgs.append(arena, .{ .role = .assistant, .payload = .{
                    .assistant_tool_calls = .{ .text = "", .calls = calls.items },
                } });
                // Then their results (interleaved tool_result blocks).
                while (j < blocks.len) : (j += 1) {
                    switch (blocks[j].body) {
                        .tool_result => |tr| try msgs.append(arena, .{ .role = .tool, .payload = .{
                            .tool_result = .{ .call_id = tr.call_id, .text = tr.inline_body },
                        } }),
                        else => break,
                    }
                }
                i = j - 1;
            },
            .tool_result => |tr| {
                // Orphan result (shouldn't happen; be tolerant).
                try msgs.append(arena, .{ .role = .tool, .payload = .{
                    .tool_result = .{ .call_id = tr.call_id, .text = tr.inline_body },
                } });
            },
            .reasoning, .approval, .system_note => {}, // not sent to the model
            .compaction => |cp| {
                // M3: summaries replace covered ranges. M0: emit as system text.
                try msgs.append(arena, .{ .role = .user, .payload = .{ .text = cp.summary } });
            },
        }
    }
    return msgs.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- tests --

test "cap inline: small output untouched, big output windowed" {
    const gpa = std.testing.allocator;
    const small = try capInline(gpa, "tiny", 100);
    try std.testing.expectEqualStrings("tiny", small);

    const big_src = "A" ** 300;
    const capped = try capInline(gpa, big_src, 100);
    defer gpa.free(capped);
    try std.testing.expect(capped.len < 200);
    try std.testing.expect(std.mem.indexOf(u8, capped, "elided") != null);
}

test "assemble: user → tool round trip shape" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const blocks = [_]block.Block{
        .{ .id = 1, .session_id = 1, .turn_id = 1, .seq = 1, .ts = 0, .body = .{ .user_msg = .{ .text = "do it" } } },
        .{ .id = 2, .session_id = 1, .turn_id = 1, .seq = 2, .ts = 0, .body = .{ .tool_call = .{ .call_id = "c1", .name = "bash", .args_json = "{}" } } },
        .{ .id = 3, .session_id = 1, .turn_id = 1, .seq = 3, .ts = 0, .body = .{ .tool_result = .{ .call_id = "c1", .status = .ok, .inline_body = "done", .full_body_ref = null } } },
        .{ .id = 4, .session_id = 1, .turn_id = 1, .seq = 4, .ts = 0, .body = .{ .assistant_msg = .{ .text = "finished" } } },
    };
    const msgs = try assemble(arena, &blocks);
    // system, user, assistant(tool_calls), tool, assistant
    try std.testing.expectEqual(@as(usize, 5), msgs.len);
    try std.testing.expectEqual(provider.Role.system, msgs[0].role);
    try std.testing.expectEqual(provider.Role.user, msgs[1].role);
    try std.testing.expect(msgs[2].payload == .assistant_tool_calls);
    try std.testing.expect(msgs[3].payload == .tool_result);
    try std.testing.expectEqual(provider.Role.assistant, msgs[4].role);
}
