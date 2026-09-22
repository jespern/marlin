//! Unit tests for dsml.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in dsml.zig.

const std = @import("std");
const dsml = @import("dsml.zig");

test {
    std.testing.refAllDecls(dsml);
}

const leak =
    \\I'll pick up where the checkpoint left off.
    \\
    \\<｜DSML｜ calls>
    \\<｜DSML｜ invoke name="bash">
    \\<｜DSML｜ parameter name="command" string="true">cd /w && git status --short && echo "=== HEAD ==="</｜DSML｜ parameter>
    \\<｜DSML｜ parameter name="description" string="true">Check working tree state</｜DSML｜ parameter>
    \\</｜DSML｜ invoke>
    \\<｜DSML｜ invoke name="edit">
    \\<｜DSML｜ parameter name="path" string="true">/w/a.zig</｜DSML｜ parameter>
    \\<｜DSML｜ parameter name="count">3</｜DSML｜ parameter>
    \\</｜DSML｜ invoke>
    \\</｜DSML｜ calls>
;

test "containsMarkup spots the fullwidth-bar marker and nothing else" {
    try std.testing.expect(dsml.containsMarkup(leak));
    try std.testing.expect(dsml.containsMarkup("stray ｜DSML｜ parameter name=\"x\">"));
    try std.testing.expect(!dsml.containsMarkup("plain prose about DSML without the bars"));
    try std.testing.expect(!dsml.containsMarkup("## Goal\nship it\n## Next\ntest it"));
}

test "extractCalls lifts complete invokes into JSON args and strips the markup from prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ex = try dsml.extractCalls(arena, leak);
    try std.testing.expectEqual(@as(usize, 2), ex.calls.len);
    try std.testing.expectEqualStrings("bash", ex.calls[0].name);
    try std.testing.expectEqualStrings(
        "{\"command\":\"cd /w && git status --short && echo \\\"=== HEAD ===\\\"\",\"description\":\"Check working tree state\"}",
        ex.calls[0].args_json,
    );
    try std.testing.expectEqualStrings("edit", ex.calls[1].name);
    try std.testing.expectEqualStrings("{\"path\":\"/w/a.zig\",\"count\":3}", ex.calls[1].args_json);
    // Args must be valid JSON objects the tool registry can parse.
    for (ex.calls) |c| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, c.args_json, .{});
        defer parsed.deinit();
        try std.testing.expect(parsed.value == .object);
    }
    try std.testing.expectEqualStrings("I'll pick up where the checkpoint left off.", ex.prose);
}

test "partial leaks yield no calls but still leave clean prose" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const partial =
        \\Reading the config.
        \\
        \\｜DSML｜ parameter name="command" string="true">cat ~/.config/x.json
        \\ name="command" string="true">ls -d ~/.local/share
    ;
    const ex = try dsml.extractCalls(arena, partial);
    try std.testing.expectEqual(@as(usize, 0), ex.calls.len);
    try std.testing.expectEqualStrings("Reading the config.\n\n name=\"command\" string=\"true\">ls -d ~/.local/share", ex.prose);
}

test "an unterminated invoke drops the tail rather than inventing a call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cut = "Working.\n<｜DSML｜ invoke name=\"bash\">\n<｜DSML｜ parameter name=\"command\" string=\"true\">rm -rf /";
    const ex = try dsml.extractCalls(arena, cut);
    try std.testing.expectEqual(@as(usize, 0), ex.calls.len);
    try std.testing.expectEqualStrings("Working.", ex.prose);
}
