//! Shell commands that only read or change files, so the transcript can show
//! them as what they are ("Edit src/web.zig") instead of as a Bash script:
//! `sed -n 1,80p f`, `cat f`, `head`/`tail f`, `sed -i … f`, `cat > f <<EOF`,
//! and the `python3 - <<'EOF'` scripts that read a file, change it, and
//! write it back. Several such steps (and leading `cd`s, and `echo ----`
//! separators) joined by `&&`, `;` or newlines still count, and a read may
//! pipe through filters that only shape its output (`| head`, `| rg -v x`).
//! Anything else in the command (a build, a search of files, a write
//! elsewhere) leaves it a Bash call, so nothing it did is hidden. The JS
//! port is webui.html shellFileIntent; keep the two in step.

const std = @import("std");

pub const Kind = enum { read, write, edit };

pub const Intent = struct {
    kind: Kind,
    /// Files in the order first touched, de-duplicated; relative ones are
    /// joined to a leading `cd` directory when it is absolute.
    paths: []const []const u8,
};

/// Null unless every step of `command` is a file read or change.
pub fn classify(arena: std.mem.Allocator, command: []const u8) !?Intent {
    var lexer: Lexer = .{ .arena = arena, .src = command };
    var paths: std.ArrayList([]const u8) = .empty;
    var reads = false;
    var writes = false;
    var any = false;
    var dir: ?[]const u8 = null;
    // The previous step pipes into this one: it must be a filter, and what
    // feeds it a read.
    var piped = false;
    while (try lexer.step()) |step| {
        defer piped = step.pipe;
        if (step.words.len == 0) {
            if (step.redirect != null or step.heredoc != null or step.pipe or piped) return null;
            continue;
        }
        if (piped) {
            if (!isFilter(step)) return null;
            continue;
        }
        const name = std.fs.path.basename(step.words[0]);
        if (std.mem.eql(u8, name, "cd")) {
            if (step.words.len != 2 or step.redirect != null or step.heredoc != null or step.pipe) return null;
            dir = step.words[1];
            continue;
        }
        // `echo ----` between reads only labels the output.
        if (std.mem.eql(u8, name, "echo") or std.mem.eql(u8, name, "printf")) {
            if (step.redirect != null or step.heredoc != null or step.pipe) return null;
            continue;
        }
        const found = (try stepIntent(arena, step)) orelse return null;
        if (step.pipe and found.kind != .read) return null;
        any = true;
        switch (found.kind) {
            .read => reads = true,
            .write => writes = true,
            .edit => {
                reads = true;
                writes = true;
            },
        }
        for (found.paths) |raw| {
            const path = if (dir != null and dir.?.len > 0 and dir.?[0] == '/' and raw.len > 0 and raw[0] != '/' and raw[0] != '~')
                try std.fs.path.join(arena, &.{ dir.?, raw })
            else
                raw;
            for (paths.items) |seen| {
                if (std.mem.eql(u8, seen, path)) break;
            } else try paths.append(arena, path);
        }
    }
    if (lexer.failed or piped or !any or paths.items.len == 0) return null;
    return .{ .kind = if (!writes) .read else if (!reads) .write else .edit, .paths = paths.items };
}

const Step = struct {
    words: []const []const u8,
    /// Its output goes to the next step (`|`).
    pipe: bool = false,
    /// `> f` or `>> f` on stdout.
    redirect: ?struct { path: []const u8, append: bool } = null,
    heredoc: ?[]const u8 = null,
};

const Found = struct { kind: Kind, paths: []const []const u8 };

fn stepIntent(arena: std.mem.Allocator, step: Step) !?Found {
    const w = step.words;
    const name = std.fs.path.basename(w[0]);
    if (std.mem.eql(u8, name, "cat")) {
        if (step.redirect) |r| {
            if (w.len != 1 or step.heredoc == null) return null;
            return .{ .kind = if (r.append) .edit else .write, .paths = try one(arena, r.path) };
        }
        if (step.heredoc != null) return null;
        // Flags (-n numbers lines) change the view, not what is read.
        var files: std.ArrayList([]const u8) = .empty;
        for (w[1..]) |arg| {
            if (arg.len == 0 or std.mem.eql(u8, arg, "-")) return null;
            if (arg[0] != '-') try files.append(arena, arg);
        }
        if (files.items.len == 0) return null;
        return .{ .kind = .read, .paths = files.items };
    }
    if (step.redirect != null) return null;
    if (std.mem.eql(u8, name, "head") or std.mem.eql(u8, name, "tail")) {
        if (step.heredoc != null) return null;
        var files: std.ArrayList([]const u8) = .empty;
        var i: usize = 1;
        while (i < w.len) : (i += 1) {
            const arg = w[i];
            if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "-c")) {
                i += 1;
                if (i >= w.len or !allDigits(std.mem.trimStart(u8, w[i], "+-"))) return null;
            } else if (arg.len > 1 and arg[0] == '-') {
                if (!allDigits(arg[1..])) return null; // -f and friends are not a read
            } else try files.append(arena, arg);
        }
        if (files.items.len == 0) return null;
        return .{ .kind = .read, .paths = files.items };
    }
    if (std.mem.eql(u8, name, "sed")) return sedIntent(arena, step);
    if (std.mem.startsWith(u8, name, "python")) return pythonIntent(arena, step);
    return null;
}

fn sedIntent(arena: std.mem.Allocator, step: Step) !?Found {
    if (step.heredoc != null) return null;
    const w = step.words;
    var in_place = false;
    var quiet = false;
    var script: ?[]const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < w.len) : (i += 1) {
        const arg = w[i];
        if (std.mem.eql(u8, arg, "-n")) {
            quiet = true;
        } else if (std.mem.startsWith(u8, arg, "-i")) {
            in_place = true;
            // BSD sed: `-i ''` (or `-i .bak`) names the backup suffix.
            if (arg.len == 2 and i + 1 < w.len and (w[i + 1].len == 0 or w[i + 1][0] == '.')) i += 1;
        } else if (std.mem.eql(u8, arg, "-E") or std.mem.eql(u8, arg, "-r")) {
            continue;
        } else if (std.mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= w.len) return null;
            script = w[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            return null;
        } else if (script == null) {
            script = arg;
        } else try files.append(arena, arg);
    }
    if (files.items.len == 0 or script == null) return null;
    if (in_place) return .{ .kind = .edit, .paths = files.items };
    // Printing lines, and nothing else, is a read.
    if (!quiet or !printsOnly(script.?)) return null;
    return .{ .kind = .read, .paths = files.items };
}

/// A `sed -n` script that only prints: addresses (line numbers, `$`,
/// `/regex/`, `+N`, `!`) and `p`, nothing that writes (`w`), runs (`e`), or
/// edits.
fn printsOnly(script: []const u8) bool {
    var printed = false;
    var i: usize = 0;
    while (i < script.len) : (i += 1) {
        const c = script[i];
        if (c == '/') {
            i += 1;
            while (i < script.len and script[i] != '/') : (i += 1) {
                if (script[i] == '\\') i += 1;
            }
            if (i >= script.len) return false;
        } else if (c == 'p') {
            printed = true;
        } else if (!(std.ascii.isDigit(c) or c == ',' or c == '$' or c == ';' or c == ' ' or c == '+' or c == '!')) {
            return false;
        }
    }
    return printed;
}

/// A step a read can pipe through without touching files: it only shapes
/// what it is given (no file operands, no in-place edits).
fn isFilter(step: Step) bool {
    if (step.redirect != null or step.heredoc != null) return false;
    const w = step.words;
    const name = std.fs.path.basename(w[0]);
    var operands: usize = 0;
    var i: usize = 1;
    while (i < w.len) : (i += 1) {
        const arg = w[i];
        if (arg.len > 1 and arg[0] == '-') {
            if (std.mem.startsWith(u8, arg, "-i") or std.mem.eql(u8, arg, "-f") or std.mem.startsWith(u8, arg, "--file") or std.mem.eql(u8, arg, "-o")) return false;
            // A flag's value (`-n 40`, `-e pattern`, `-A 3`) is not a file.
            if (arg.len == 2 and i + 1 < w.len and std.mem.indexOfScalar(u8, "nceABCmkt", arg[1]) != null) i += 1;
            continue;
        }
        operands += 1;
    }
    const pattern_tools = [_][]const u8{ "grep", "rg", "sed" };
    for (pattern_tools) |tool| if (std.mem.eql(u8, name, tool)) return operands <= 1;
    const plain = [_][]const u8{ "head", "tail", "cat", "nl", "wc", "sort", "uniq" };
    for (plain) |tool| if (std.mem.eql(u8, name, tool)) return operands == 0;
    return false;
}

/// `python3 - <<'EOF'` with a script that only opens files: the paths are
/// the path-like string literals it assigns or passes first to a call
/// (`p = 'a.zig'`, `open('a.zig')`, `rep('a.zig', …)`). Writes make it a
/// write (or an edit, when it also reads).
fn pythonIntent(arena: std.mem.Allocator, step: Step) !?Found {
    const body = step.heredoc orelse return null;
    for (step.words[1..]) |arg| if (!std.mem.eql(u8, arg, "-")) return null;
    for ([_][]const u8{ "subprocess", "os.system", "socket", "urllib", "requests", "rmtree", "remove(", "unlink(", "rename(", "replace(p", "exec(", "eval(", "shutil", "popen", "chmod" }) |risky| {
        if (std.mem.indexOf(u8, body, risky) != null) return null;
    }
    const writes = std.mem.indexOf(u8, body, ".write(") != null or std.mem.indexOf(u8, body, "write_text(") != null;
    const reads = std.mem.indexOf(u8, body, ".read()") != null or std.mem.indexOf(u8, body, "read_text(") != null or std.mem.indexOf(u8, body, "readlines(") != null;
    if (!writes and !reads) return null;
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '#') {
            i = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse body.len;
            continue;
        }
        if (c != '\'' and c != '"') {
            i += 1;
            continue;
        }
        // Triple-quoted text is data (replacement code), never a path.
        if (i + 2 < body.len and body[i + 1] == c and body[i + 2] == c) {
            const close = [3]u8{ c, c, c };
            const end = std.mem.indexOfPos(u8, body, i + 3, &close) orelse return null;
            i = end + 3;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, body, i + 1, c) orelse return null;
        const literal = body[i + 1 .. end];
        const before = std.mem.trimEnd(u8, body[0..i], " \t");
        const assigned = before.len > 0 and before[before.len - 1] == '=' and (before.len < 2 or before[before.len - 2] != '=');
        const first_arg = before.len > 0 and before[before.len - 1] == '(' and (i == 0 or body[i - 1] != 'f');
        if ((assigned or first_arg) and looksLikePath(literal)) {
            for (paths.items) |seen| {
                if (std.mem.eql(u8, seen, literal)) break;
            } else try paths.append(arena, literal);
        }
        i = end + 1;
    }
    if (paths.items.len == 0) return null;
    return .{ .kind = if (writes and reads) .edit else if (writes) .write else .read, .paths = paths.items };
}

fn looksLikePath(text: []const u8) bool {
    if (text.len == 0 or text.len > 300 or text[0] == '-') return false;
    for (text) |c| if (c == ' ' or c == '\n' or c == '\t' or c == '\\' or c == '{' or c == '%') return false;
    const base = std.fs.path.basename(text);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return false;
    return dot > 0 and dot + 1 < base.len and base.len - dot <= 9;
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn one(arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, 1);
    out[0] = path;
    return out;
}

/// Splits a command into simple commands: words with quotes removed, stdout
/// redirections, and heredoc bodies. Anything it does not understand (pipes,
/// `$(…)`, backgrounding, other redirections) sets `failed`.
const Lexer = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    at: usize = 0,
    failed: bool = false,

    fn step(self: *Lexer) !?Step {
        if (self.failed) return null;
        var words: std.ArrayList([]const u8) = .empty;
        var out: Step = .{ .words = &.{} };
        var delimiter: ?[]const u8 = null;
        while (true) {
            self.skipBlanks();
            if (self.at >= self.src.len) break;
            const c = self.src[self.at];
            if (c == '\n' or c == ';') {
                self.at += 1;
                break;
            }
            if (std.mem.startsWith(u8, self.src[self.at..], "&&")) {
                self.at += 2;
                break;
            }
            if (c == '|') {
                if (std.mem.startsWith(u8, self.src[self.at..], "||") or std.mem.startsWith(u8, self.src[self.at..], "|&")) return self.fail();
                self.at += 1;
                out.pipe = true;
                break;
            }
            if (c == '&' or c == '`' or c == '(' or c == ')') return self.fail();
            if (std.mem.startsWith(u8, self.src[self.at..], "2>&1")) {
                self.at += 4;
                continue;
            }
            if (std.mem.startsWith(u8, self.src[self.at..], "2>")) {
                self.at += 2;
                self.skipBlanks();
                const target = (try self.word()) orelse return self.fail();
                if (!std.mem.eql(u8, target, "/dev/null")) return self.fail();
                continue;
            }
            if (std.mem.startsWith(u8, self.src[self.at..], "<<")) {
                self.at += 2;
                if (self.at < self.src.len and self.src[self.at] == '-') self.at += 1;
                self.skipBlanks();
                delimiter = (try self.word()) orelse return self.fail();
                continue;
            }
            if (c == '<') return self.fail();
            if (c == '>') {
                const append = std.mem.startsWith(u8, self.src[self.at..], ">>");
                self.at += if (append) 2 else 1;
                self.skipBlanks();
                const target = (try self.word()) orelse return self.fail();
                if (out.redirect != null) return self.fail();
                out.redirect = .{ .path = target, .append = append };
                continue;
            }
            const w = (try self.word()) orelse return self.fail();
            try words.append(self.arena, w);
        }
        if (delimiter) |d| {
            // The body starts on the next line and ends at a line that is
            // exactly the delimiter; the command line must end before it.
            const line_end = std.mem.lastIndexOfScalar(u8, self.src[0..self.at], '\n') orelse return self.fail();
            if (line_end + 1 != self.at) return self.fail();
            var lines = std.mem.splitScalar(u8, self.src[self.at..], '\n');
            var consumed: usize = 0;
            while (lines.next()) |line| {
                if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), d)) {
                    out.heredoc = self.src[self.at .. self.at + consumed];
                    self.at += consumed + line.len;
                    if (self.at < self.src.len) self.at += 1;
                    break;
                }
                consumed += line.len + 1;
            } else return self.fail();
        }
        out.words = words.items;
        if (words.items.len == 0 and out.redirect == null and delimiter == null and self.at >= self.src.len) return null;
        return out;
    }

    fn fail(self: *Lexer) ?Step {
        self.failed = true;
        return null;
    }

    fn skipBlanks(self: *Lexer) void {
        while (self.at < self.src.len and (self.src[self.at] == ' ' or self.src[self.at] == '\t' or
            (self.src[self.at] == '\\' and self.at + 1 < self.src.len and self.src[self.at + 1] == '\n')))
        {
            self.at += if (self.src[self.at] == '\\') 2 else 1;
        }
    }

    /// One word, quotes removed; null when it hits an operator or `$`.
    fn word(self: *Lexer) !?[]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var any = false;
        while (self.at < self.src.len) {
            const c = self.src[self.at];
            switch (c) {
                ' ', '\t', '\n', ';', '|', '&', '<', '>', '(', ')' => break,
                '$', '`' => return null,
                '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, self.src, self.at + 1, '\'') orelse return null;
                    try out.appendSlice(self.arena, self.src[self.at + 1 .. end]);
                    self.at = end + 1;
                },
                '"' => {
                    const end = std.mem.indexOfScalarPos(u8, self.src, self.at + 1, '"') orelse return null;
                    const inner = self.src[self.at + 1 .. end];
                    if (std.mem.indexOfAny(u8, inner, "$`\\") != null) return null;
                    try out.appendSlice(self.arena, inner);
                    self.at = end + 1;
                },
                '\\' => {
                    if (self.at + 1 >= self.src.len) return null;
                    try out.append(self.arena, self.src[self.at + 1]);
                    self.at += 2;
                },
                else => {
                    try out.append(self.arena, c);
                    self.at += 1;
                },
            }
            any = true;
        }
        return if (any) out.items else null;
    }
};
