//! Conservative hostname preflight for the `bash` tool.
//!
//! This is deliberately a guardrail, not an egress boundary. It recognizes
//! literal destinations supplied to common network programs without running
//! shell expansion. Variables, generated commands, scripts, interpreters,
//! aliases, custom resolvers, and redirects inside subprocesses can bypass it.

const std = @import("std");

const network_policy = @import("network_policy.zig");

pub const Blocked = struct {
    tool: []u8,
    host: []u8,
    source: []const u8,
    domain: []const u8,

    pub fn deinit(self: *Blocked, gpa: std.mem.Allocator) void {
        gpa.free(self.tool);
        gpa.free(self.host);
        self.* = undefined;
    }
};

const Token = union(enum) {
    word: []const u8,
    boundary,
    redirect,
};

const ToolKind = enum {
    url_args,
    git,
    host_arg,
    remote_spec,
    shell,
};

/// Return the first high-confidence literal destination denied by `policy`.
/// The caller owns the returned tool/host strings.
pub fn inspect(
    gpa: std.mem.Allocator,
    command: []const u8,
    policy: *const network_policy.Policy,
) std.mem.Allocator.Error!?Blocked {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tokens = try tokenize(arena, command);
    return inspectTokens(gpa, arena, tokens, policy, 0);
}

fn inspectTokens(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    tokens: []const Token,
    policy: *const network_policy.Policy,
    depth: u8,
) std.mem.Allocator.Error!?Blocked {
    var start: usize = 0;
    for (tokens, 0..) |token, i| {
        if (token == .boundary) {
            if (try inspectSimple(gpa, arena, tokens[start..i], policy, depth)) |blocked| return blocked;
            start = i + 1;
        }
    }
    return inspectSimple(gpa, arena, tokens[start..], policy, depth);
}

fn inspectSimple(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    tokens: []const Token,
    policy: *const network_policy.Policy,
    depth: u8,
) std.mem.Allocator.Error!?Blocked {
    var words: std.ArrayList([]const u8) = .empty;
    var skip_redirect_target = false;
    for (tokens, 0..) |token, i| switch (token) {
        .boundary => unreachable,
        .redirect => skip_redirect_target = true,
        .word => |word| {
            // In `2>file`, the numeric file-descriptor is syntax rather than
            // the command name. Ordinary redirection targets are also not
            // command arguments.
            if (i + 1 < tokens.len and tokens[i + 1] == .redirect and allDigits(word)) continue;
            if (skip_redirect_target) {
                skip_redirect_target = false;
                continue;
            }
            try words.append(arena, word);
        },
    };
    if (words.items.len == 0) return null;

    const command_index = findCommand(words.items) orelse return null;
    const command_word = words.items[command_index];
    const tool = std.fs.path.basename(command_word);
    const kind = classify(tool) orelse return null;
    const args = words.items[command_index + 1 ..];

    if (kind == .shell) {
        if (depth >= 2) return null;
        for (args, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "-c") and i + 1 < args.len) {
                const nested = try tokenize(arena, args[i + 1]);
                return inspectTokens(gpa, arena, nested, policy, depth + 1);
            }
        }
        return null;
    }

    switch (kind) {
        .url_args => {
            var skip_value = false;
            var expect_url = false;
            for (args) |arg| {
                if (skip_value) {
                    skip_value = false;
                    continue;
                }
                if (expect_url) {
                    expect_url = false;
                    if (try checkCandidate(gpa, tool, arg, policy, true, false)) |blocked| return blocked;
                    continue;
                }
                if (std.mem.eql(u8, arg, "--url")) {
                    expect_url = true;
                    continue;
                }
                if (std.mem.startsWith(u8, arg, "--url=")) {
                    if (try checkCandidate(gpa, tool, arg["--url=".len..], policy, true, false)) |blocked| return blocked;
                    continue;
                }
                if (arg.len > 0 and arg[0] == '-') {
                    skip_value = optionConsumesValue(arg);
                    continue;
                }
                if (try checkCandidate(gpa, tool, arg, policy, true, false)) |blocked| return blocked;
            }
        },
        .git => for (args) |arg| {
            if (try checkCandidate(gpa, tool, arg, policy, false, true)) |blocked| return blocked;
        },
        .host_arg => for (args) |arg| {
            if (arg.len == 0 or arg[0] == '-') continue;
            if (try checkCandidate(gpa, tool, arg, policy, true, true)) |blocked| return blocked;
        },
        .remote_spec => for (args) |arg| {
            if (arg.len == 0 or arg[0] == '-') continue;
            if (try checkCandidate(gpa, tool, arg, policy, false, true)) |blocked| return blocked;
        },
        .shell => unreachable,
    }
    return null;
}

fn checkCandidate(
    gpa: std.mem.Allocator,
    tool: []const u8,
    raw: []const u8,
    policy: *const network_policy.Policy,
    allow_bare: bool,
    allow_remote: bool,
) std.mem.Allocator.Error!?Blocked {
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = candidateHost(raw, &host_buf, allow_bare, allow_remote) orelse return null;
    const matched = policy.checkHost(host) orelse return null;
    const owned_tool = try gpa.dupe(u8, tool);
    errdefer gpa.free(owned_tool);
    return .{
        .tool = owned_tool,
        .host = try gpa.dupe(u8, host),
        .source = matched.source,
        .domain = matched.domain,
    };
}

fn candidateHost(
    raw_arg: []const u8,
    host_buf: *[std.Io.net.HostName.max_len]u8,
    allow_bare: bool,
    allow_remote: bool,
) ?[]const u8 {
    const raw = std.mem.trim(u8, raw_arg, " \t\r\n");
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, "$`") != null) return null;

    if (std.mem.indexOf(u8, raw, "://") != null) {
        const uri = std.Uri.parse(raw) catch return null;
        const host = uri.getHost(host_buf) catch return null;
        return host.bytes;
    }

    if (allow_remote and (std.mem.indexOfScalar(u8, raw, '@') != null or
        std.mem.indexOfScalar(u8, raw, ':') != null))
    {
        var start: usize = 0;
        if (std.mem.lastIndexOfScalar(u8, raw, '@')) |at| start = at + 1;
        var end = raw.len;
        if (std.mem.indexOfScalarPos(u8, raw, start, ':')) |colon| end = colon;
        if (std.mem.indexOfScalarPos(u8, raw, start, '/')) |slash| end = @min(end, slash);
        if (end <= start) return null;
        return stripBrackets(raw[start..end]);
    }

    if (!allow_bare or raw[0] == '-' or std.mem.indexOfScalar(u8, raw, '=') != null) return null;
    var end = std.mem.indexOfScalar(u8, raw, '/') orelse raw.len;
    if (std.mem.indexOfScalarPos(u8, raw, 0, ':')) |colon| end = @min(end, colon);
    const host = stripBrackets(raw[0..end]);
    if (host.len == 0 or (std.mem.indexOfScalar(u8, host, '.') == null and
        !std.mem.eql(u8, host, "localhost"))) return null;
    return host;
}

fn stripBrackets(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') return host[1 .. host.len - 1];
    return host;
}

fn classify(tool: []const u8) ?ToolKind {
    if (wordIn(tool, "curl wget aria2c http https httpie")) return .url_args;
    if (std.mem.eql(u8, tool, "git")) return .git;
    if (wordIn(tool, "ssh sftp telnet nc ncat netcat ftp lftp")) return .host_arg;
    if (wordIn(tool, "scp rsync")) return .remote_spec;
    if (wordIn(tool, "bash sh zsh")) return .shell;
    return null;
}

fn findCommand(words: []const []const u8) ?usize {
    var i: usize = 0;
    while (i < words.len and isAssignment(words[i])) i += 1;
    while (i < words.len) {
        const tool = std.fs.path.basename(words[i]);
        if (std.mem.eql(u8, tool, "env")) {
            i += 1;
            while (i < words.len and (words[i][0] == '-' or isAssignment(words[i]))) {
                const consumes = std.mem.eql(u8, words[i], "-u") or std.mem.eql(u8, words[i], "--unset");
                i += 1;
                if (consumes and i < words.len) i += 1;
            }
            continue;
        }
        if (wordIn(tool, "command exec nohup")) {
            i += 1;
            while (i < words.len and words[i].len > 0 and words[i][0] == '-') i += 1;
            continue;
        }
        return i;
    }
    return null;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    if (eq == 0 or (!std.ascii.isAlphabetic(word[0]) and word[0] != '_')) return false;
    for (word[1..eq]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Common options whose following token is data/configuration rather than a
/// destination. Unknown options are not assumed to consume a value: this
/// preserves the ordinary `curl -s URL` case without maintaining every flag.
fn optionConsumesValue(arg: []const u8) bool {
    return wordIn(arg, "-d --data --data-ascii --data-binary --data-raw --data-urlencode " ++
        "-H --header -A --user-agent -e --referer -F --form --form-string " ++
        "-b --cookie -c --cookie-jar -o --output --output-document " ++
        "-T --upload-file -u --user -x --proxy --proxy-user --resolve " ++
        "--connect-to --cert --key --cacert --capath --interface " ++
        "--request-target -w --write-out -X --request --post-data --post-file " ++
        "--password --http-user --http-password --method --max-time " ++
        "--connect-timeout --retry --limit-rate");
}

fn wordIn(word: []const u8, list: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    while (it.next()) |candidate| if (std.mem.eql(u8, word, candidate)) return true;
    return false;
}

fn allDigits(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn tokenize(arena: std.mem.Allocator, command: []const u8) ![]Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < command.len) {
        if (command[i] == ' ' or command[i] == '\t' or command[i] == '\r') {
            i += 1;
            continue;
        }
        if (command[i] == '\n') {
            try out.append(arena, .boundary);
            i += 1;
            continue;
        }
        if (command[i] == '#') {
            while (i < command.len and command[i] != '\n') i += 1;
            continue;
        }
        if (isBoundary(command[i])) {
            try out.append(arena, .boundary);
            while (i < command.len and isBoundary(command[i])) i += 1;
            continue;
        }
        if (command[i] == '<' or command[i] == '>') {
            try out.append(arena, .redirect);
            const op = command[i];
            i += 1;
            if (i < command.len and command[i] == op) i += 1;
            continue;
        }

        var word: std.ArrayList(u8) = .empty;
        var started = false;
        while (i < command.len) {
            const c = command[i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n' or
                isBoundary(c) or c == '<' or c == '>') break;
            started = true;
            if (c == '\'' or c == '"') {
                const quote = c;
                i += 1;
                while (i < command.len and command[i] != quote) {
                    if (quote == '"' and command[i] == '\\' and i + 1 < command.len) i += 1;
                    try word.append(arena, command[i]);
                    i += 1;
                }
                if (i < command.len) i += 1;
                continue;
            }
            if (c == '\\' and i + 1 < command.len) {
                i += 1;
                try word.append(arena, command[i]);
                i += 1;
                continue;
            }
            try word.append(arena, c);
            i += 1;
        }
        if (started) try out.append(arena, .{ .word = try word.toOwnedSlice(arena) });
    }
    return out.toOwnedSlice(arena);
}

fn isBoundary(c: u8) bool {
    return c == ';' or c == '|' or c == '&' or c == '(' or c == ')';
}

test "screens literal destinations only for recognized network commands" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var policy = network_policy.Policy.init(gpa, io, &environ, .{ .deny = "bad.test" });
    defer policy.deinit();

    const cases = [_][]const u8{
        "curl https://bad.test/upload",
        "curl -sS --url='https://sub.bad.test/a'",
        "printf ok; wget https://bad.test/payload",
        "env MODE=test curl bad.test/path",
        "git clone git@bad.test:owner/repo.git",
        "ssh user@bad.test",
        "scp file user@bad.test:/tmp/file",
        "bash -c 'curl https://bad.test/nested'",
    };
    for (cases) |command| {
        var blocked = (try inspect(gpa, command, &policy)) orelse {
            std.debug.print("missed command: {s}\n", .{command});
            return error.TestUnexpectedResult;
        };
        defer blocked.deinit(gpa);
        try std.testing.expectEqualStrings("bad.test", blocked.domain);
    }

    try std.testing.expect((try inspect(gpa, "echo https://bad.test/example", &policy)) == null);
    try std.testing.expect((try inspect(gpa, "curl --data https://bad.test https://safe.test", &policy)) == null);
    try std.testing.expect((try inspect(gpa, "curl 'https://$HOST/path'", &policy)) == null);
    try std.testing.expect((try inspect(gpa, "curl https://safe.test/path", &policy)) == null);
}

test "shell comments and redirections do not become commands" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var environ = std.process.Environ.Map.init(gpa);
    defer environ.deinit();
    var policy = network_policy.Policy.init(gpa, io, &environ, .{ .deny = "bad.test" });
    defer policy.deinit();

    try std.testing.expect((try inspect(gpa, "echo ok > curl https://bad.test", &policy)) == null);
    try std.testing.expect((try inspect(gpa, "echo ok # curl https://bad.test", &policy)) == null);
}

test {
    std.testing.refAllDecls(@This());
}
