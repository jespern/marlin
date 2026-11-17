//! Unit tests for shell_intent.zig: which Bash calls are only file reads or
//! changes, from commands agents really send.
const std = @import("std");
const shell_intent = @import("shell_intent.zig");

test {
    std.testing.refAllDecls(shell_intent);
}

fn expectIntent(command: []const u8, kind: ?shell_intent.Kind, paths: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try shell_intent.classify(arena.allocator(), command);
    if (kind == null) {
        if (got != null) {
            std.debug.print("expected Bash, got {t} for: {s}\n", .{ got.?.kind, command });
            return error.TestUnexpectedResult;
        }
        return;
    }
    const intent = got orelse {
        std.debug.print("expected {t}, got Bash for: {s}\n", .{ kind.?, command });
        return error.TestUnexpectedResult;
    };
    try std.testing.expectEqual(kind.?, intent.kind);
    try std.testing.expectEqual(paths.len, intent.paths.len);
    for (paths, intent.paths) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "reads: line ranges, cat, head and tail, also several and after a cd" {
    try expectIntent("sed -n 1,80p src/client/voice.zig", .read, &.{"src/client/voice.zig"});
    try expectIntent("sed -n '2370,2520p' src/client/layout.zig; sed -n 1,10p src/main.zig", .read, &.{ "src/client/layout.zig", "src/main.zig" });
    try expectIntent("cd /Users/j/Work/marlin && sed -n 590,640p src/client/render.zig", .read, &.{"/Users/j/Work/marlin/src/client/render.zig"});
    try expectIntent("cat ~/.config/marlin/config.toml", .read, &.{"~/.config/marlin/config.toml"});
    try expectIntent("head -n 40 README.md\ntail -20 docs/USING.md 2>/dev/null", .read, &.{ "README.md", "docs/USING.md" });
}

test "changes: sed -i, cat > file, and python scripts that rewrite a file" {
    try expectIntent("sed -i '' 's/errdefer out/defer out/' src/core/config.zig", .edit, &.{"src/core/config.zig"});
    try expectIntent("sed -i 's/a/b/' x.txt y.txt", .edit, &.{ "x.txt", "y.txt" });
    try expectIntent("cat > src/daemon/voice_host_test.zig <<'EOF'\nconst std = @import(\"std\");\nEOF", .write, &.{"src/daemon/voice_host_test.zig"});
    try expectIntent("cat >> notes.md <<EOF\nmore\nEOF\n", .edit, &.{"notes.md"});
    // The rep() pattern: the paths are first arguments; text inside the
    // triple-quoted replacements (other file names, code) is not.
    try expectIntent(
        \\cd /Users/j/Work/marlin && python3 - <<'EOF'
        \\def rep(p, old, new):
        \\    s=open(p).read(); assert s.count(old)==1, (p, old[:60]); open(p,'w').write(s.replace(old,new))
        \\rep('src/client/tui.zig', '''const voice = @import("voice.zig");''', '''const voice = @import("../core/voice.zig");''')
        \\rep('src/client/keys.zig', """x = 'a.zig'""", """x = 'b.zig'""")
        \\EOF
    , .edit, &.{ "/Users/j/Work/marlin/src/client/tui.zig", "/Users/j/Work/marlin/src/client/keys.zig" });
    try expectIntent(
        \\python3 - <<'EOF'
        \\p='src/client/attach.zig'
        \\s=open(p).read()
        \\print(s.count('remote'))
        \\EOF
    , .read, &.{"src/client/attach.zig"});
    try expectIntent(
        \\python3 - <<'EOF'
        \\import os
        \\p=os.path.expanduser('~/.config/marlin/config.toml')
        \\open(p,'a').write('[voice]\\n')
        \\open('out.txt','w').write('x')
        \\EOF
    , .write, &.{ "~/.config/marlin/config.toml", "out.txt" });
}

test "anything else in the command keeps it a Bash call" {
    for ([_][]const u8{
        "sed -n 1,80p src/x.zig | head",
        "sed -n 1,5p src/x.zig && zig build test",
        "python3 - <<'EOF'\np='a.zig'\nopen(p,'w').write('x')\nEOF\nzig build",
        "python3 - <<'EOF'\nimport subprocess\np='a.zig'\nopen(p).read()\nEOF",
        "python3 -c 'print(1)'",
        "rg -n x src",
        "cat src/x.zig | wc -l",
        "cat > notes.md",
        "echo hi > notes.md",
        "tail -f daemon.log",
        "sed -n '/x/p' src/x.zig",
        "sed -n 1,5p $FILE",
        "cat $(ls *.zig)",
        "sed -n 1,5p f 2>err.log",
        "cd /tmp",
        "> notes.md",
        "python3 - <<'EOF'\nprint('hello')\nEOF",
    }) |command| try expectIntent(command, null, &.{});
}
