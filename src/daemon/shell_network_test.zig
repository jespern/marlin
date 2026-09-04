//! Unit tests for shell_network.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in shell_network.zig.

const std = @import("std");
const network_policy = @import("network_policy.zig");

const shell_network = @import("shell_network.zig");
const inspect = shell_network.inspect;

test {
    std.testing.refAllDecls(shell_network);
}

test "screens supported network commands and shell forms" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var policy = network_policy.Policy.init(gpa, io, &environ, .{ .deny = "bad.test" });
    defer policy.deinit();

    const Case = struct {
        command: []const u8,
        tool: []const u8,
        host: []const u8,
    };
    const cases = [_]Case{
        .{ .command = "curl https://bad.test/upload", .tool = "curl", .host = "bad.test" },
        .{ .command = "curl -sS --url='https://sub.bad.test/a'", .tool = "curl", .host = "sub.bad.test" },
        .{ .command = "printf ok; /usr/bin/wget https://bad.test/payload", .tool = "wget", .host = "bad.test" },
        .{ .command = "env MODE=test curl bad.test/path", .tool = "curl", .host = "bad.test" },
        .{ .command = "command curl https://bad.test/command-wrapper", .tool = "curl", .host = "bad.test" },
        .{ .command = "http GET https://bad.test/api", .tool = "http", .host = "bad.test" },
        .{ .command = "aria2c https://bad.test/archive", .tool = "aria2c", .host = "bad.test" },
        .{ .command = "git clone https://bad.test/owner/repo.git", .tool = "git", .host = "bad.test" },
        .{ .command = "git clone git@bad.test:owner/repo.git", .tool = "git", .host = "bad.test" },
        .{ .command = "ssh user@bad.test", .tool = "ssh", .host = "bad.test" },
        .{ .command = "sftp bad.test", .tool = "sftp", .host = "bad.test" },
        .{ .command = "nc -v bad.test 443", .tool = "nc", .host = "bad.test" },
        .{ .command = "scp file user@bad.test:/tmp/file", .tool = "scp", .host = "bad.test" },
        .{ .command = "rsync file bad.test:/srv/file", .tool = "rsync", .host = "bad.test" },
        .{ .command = "bash -c 'curl https://bad.test/nested'", .tool = "curl", .host = "bad.test" },
        .{ .command = "echo before | zsh -c 'wget https://bad.test/nested'", .tool = "wget", .host = "bad.test" },
        .{ .command = "2>/dev/null curl https://bad.test/stderr", .tool = "curl", .host = "bad.test" },
    };
    for (cases) |case| {
        var blocked = (try inspect(gpa, case.command, &policy)) orelse {
            std.debug.print("missed command: {s}\n", .{case.command});
            return error.TestUnexpectedResult;
        };
        defer blocked.deinit(gpa);
        try std.testing.expectEqualStrings(case.tool, blocked.tool);
        try std.testing.expectEqualStrings(case.host, blocked.host);
        try std.testing.expectEqualStrings("bad.test", blocked.domain);
        try std.testing.expectEqualStrings("explicit deny", blocked.source);
    }
}

test "does not block inert text, option payloads, local paths, or dynamic hosts" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var policy = network_policy.Policy.init(gpa, io, &environ, .{ .deny = "bad.test" });
    defer policy.deinit();

    const cases = [_][]const u8{
        "echo https://bad.test/example",
        "printf '%s' https://bad.test/example",
        "rg https://bad.test fixtures/",
        "curlish https://bad.test/example",
        "curl --data https://bad.test https://safe.test",
        "curl --data=https://bad.test https://safe.test",
        "curl --header https://bad.test https://safe.test",
        "curl --resolve bad.test:443:127.0.0.1 https://safe.test",
        "curl 'https://$HOST/path'",
        "curl https://${HOST}/path",
        "curl https://safe.test/path",
        "git clone /tmp/bad.test",
        "scp bad.test local-copy",
        "echo ok > curl https://bad.test",
        "echo ok # curl https://bad.test",
        "URL=https://bad.test echo configured",
        "",
    };
    for (cases) |command| {
        if (try inspect(gpa, command, &policy)) |found| {
            var blocked = found;
            defer blocked.deinit(gpa);
            std.debug.print("false positive for command: {s} (tool={s}, host={s})\n", .{
                command,
                blocked.tool,
                blocked.host,
            });
            return error.TestUnexpectedResult;
        }
    }
}
