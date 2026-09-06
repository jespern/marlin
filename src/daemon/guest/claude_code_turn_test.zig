//! Unit tests for claude_code_turn.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in claude_code_turn.zig.

const std = @import("std");
const Io = std.Io;
const block = @import("../../core/block.zig");
const proto = @import("../../core/proto.zig");
const ids = @import("../../core/ids.zig");
const telemetry_ids = @import("../../core/telemetry.zig");
const config = @import("../../core/config.zig");
const Store = @import("../store.zig").Store;
const process_io = @import("../process_io.zig");
const context = @import("../context.zig");
const approval = @import("../approval.zig");
const permissions = @import("../permissions.zig");
const sandbox = @import("../sandbox.zig");
const provider = @import("../provider/provider.zig");
const anthropic = @import("../provider/anthropic.zig");
const claude_code = @import("../provider/claude_code.zig");
const codex = @import("../provider/codex.zig");
const http = @import("../provider/http.zig");
const build_options = @import("build_options");

const claude_code_turn = @import("claude_code_turn.zig");

test {
    std.testing.refAllDecls(claude_code_turn);
}

test "generic Claude connection errors name the missing detail" {
    const note = try claude_code_turn.claudeErrorNote(
        std.testing.allocator,
        "ConnectFailed",
        "",
    );
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "claude code connection failed: ConnectFailed (no transport detail reported by Claude Code)",
        note,
    );
}

test "generic Claude connection errors include captured stderr" {
    const note = try claude_code_turn.claudeErrorNote(
        std.testing.allocator,
        "SocketUnconnected",
        "  network changed\nwhile connecting\n",
    );
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "claude code connection failed: SocketUnconnected (stderr: network changed while connecting)",
        note,
    );
}

test "specific Claude errors keep their original text" {
    const note = try claude_code_turn.claudeErrorNote(
        std.testing.allocator,
        "Not logged in · Please run /login",
        "ignored",
    );
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "claude code error: Not logged in · Please run /login",
        note,
    );
}
