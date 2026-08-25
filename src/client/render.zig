//! Terminal rendering primitives shared by the Marlin TUI.

const std = @import("std");
const Io = std.Io;
const vaxis = @import("vaxis");

pub const Palette = struct {
    /// Calm informational accent. Yellow is reserved for warnings and
    /// approval states that actually require the user's attention.
    pub const soft_blue: vaxis.Color = .{ .rgb = .{ 0x8a, 0xa6, 0xbf } };
    pub const user: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true }; // cyan
    // Sampled from the Codex composer in the same terminal (#42454b), so
    // the raised surface has the same contrast instead of approximating it
    // through theme-dependent ANSI grays.
    pub const prompt_bg: vaxis.Color = .{ .rgb = .{ 0x42, 0x45, 0x4b } };
    pub const prompt_panel: vaxis.Style = .{ .bg = prompt_bg };
    pub const prompt_text: vaxis.Style = .{ .bg = prompt_bg };
    pub const prompt_mark: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 6 }, .bold = true };
    pub const command_bg: vaxis.Color = .{ .rgb = .{ 0x2d, 0x30, 0x35 } };
    pub const tab_bar: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 8 } };
    pub const tab_inactive: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 7 } };
    pub const tab_active: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 7 }, .bold = true };
    pub const tab_overflow: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 8 }, .dim = true };
    pub const command_menu: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 7 } };
    pub const command_name: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 6 }, .bold = true };
    pub const command_description: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 8 }, .dim = true };
    pub const command_selected: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 7 } };
    pub const command_selected_name: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 6 }, .bold = true };
    pub const command_selected_description: vaxis.Style = .{ .bg = prompt_bg, .fg = .{ .index = 7 } };
    pub const shortcut_panel: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 7 } };
    pub const shortcut_key: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 6 }, .bold = true };
    pub const shortcut_text: vaxis.Style = .{ .bg = command_bg, .fg = .{ .index = 7 } };
    pub const shortcut_border: vaxis.Style = .{ .fg = .{ .index = 6 } };
    pub const assistant: vaxis.Style = .{};
    pub const md_heading_1: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } }, .bold = true };
    pub const md_heading_2: vaxis.Style = .{ .fg = .{ .index = 6 }, .bold = true };
    pub const md_heading_3: vaxis.Style = .{ .bold = true };
    pub const md_lead: vaxis.Style = .{ .fg = .{ .index = 7 }, .bold = true };
    pub const md_inline_code_bg: vaxis.Color = .{ .rgb = .{ 0x2d, 0x30, 0x35 } };
    pub const md_code: vaxis.Style = .{ .fg = soft_blue, .bg = md_inline_code_bg };
    pub const md_code_panel: vaxis.Style = .{ .bg = md_inline_code_bg };
    pub const md_code_border: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = md_inline_code_bg, .dim = true };
    pub const md_table_header_bg: vaxis.Color = .{ .rgb = .{ 0x32, 0x35, 0x3b } };
    /// Table borders and cell separators recede; bright default-fg chrome
    /// made every table louder than its contents.
    pub const md_table_border: vaxis.Style = .{ .fg = .{ .index = 8 } };
    pub const md_table_header: vaxis.Style = .{ .fg = .{ .index = 7 }, .bg = md_table_header_bg, .bold = true };
    pub const md_quote: vaxis.Style = .{ .fg = .{ .index = 8 }, .italic = true };
    pub const md_rule: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };
    pub const md_callout_bg: vaxis.Color = .{ .rgb = .{ 0x28, 0x2c, 0x32 } };
    pub const md_callout: vaxis.Style = .{ .bg = md_callout_bg };
    pub const reasoning_bg: vaxis.Color = .{ .rgb = .{ 0x30, 0x33, 0x39 } };
    pub const reasoning_panel: vaxis.Style = .{ .bg = reasoning_bg };
    /// Reasoning commentary sits one step ABOVE body text, never below it:
    /// the same words were just streamed in the default style, and
    /// dimming/italicizing them on completion reads as the text degrading.
    /// Emphasis comes from WEIGHT, not color: measured on a real theme, the
    /// default foreground is already pure white, so no fg value can be
    /// brighter — but bold strokes light more pixels per glyph and read as
    /// brighter at terminal sizes. RGB white is kept to pin the floor on
    /// themes whose default fg actually is grey.
    pub const reasoning: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xff, 0xff, 0xff } }, .bg = reasoning_bg, .bold = true };
    pub const reasoning_mark: vaxis.Style = .{ .fg = .{ .index = 6 }, .bg = reasoning_bg, .bold = true };
    /// Tool machinery (the ⚙ glyph, arg previews, result bodies): dimmed
    /// gray so it reads as background activity, never as user input or as
    /// assistant prose meant for the human.
    pub const tool: vaxis.Style = .{ .fg = .{ .index = 8 } };
    /// File-tool targets remain a single emphasized value. Bash previews use
    /// the semantic shell roles below instead of rendering as one blue blob.
    pub const tool_cmd: vaxis.Style = .{ .fg = .{ .index = 4 }, .bold = true }; // blue
    pub const shell_command: vaxis.Style = .{ .fg = .{ .index = 7 } };
    pub const shell_executable: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x82, 0xaa, 0xff } }, .bold = true };
    pub const shell_flag: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } } };
    pub const shell_operator: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc7, 0x92, 0xea } }, .bold = true };
    pub const shell_string: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc3, 0xe8, 0x8d } } };
    pub const shell_path: vaxis.Style = .{ .fg = soft_blue };
    pub const shell_variable: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf7, 0x8c, 0x6c } } };
    pub const tool_out: vaxis.Style = .{ .fg = .{ .index = 8 }, .dim = true };
    /// Secondary text on collapse-summary and Working lines. Deliberately
    /// NOT tool_out: index-8+dim is near-invisible on dark themes, and these
    /// lines are the only live signal while a turn runs.
    pub const collapse_hint: vaxis.Style = .{ .fg = .{ .index = 7 } };
    pub const working: vaxis.Style = .{ .fg = .{ .index = 7 }, .bold = true };
    pub const tool_err: vaxis.Style = .{ .fg = .{ .index = 1 } }; // red
    pub const git_subject: vaxis.Style = .{ .fg = .{ .index = 7 } };
    pub const git_hash: vaxis.Style = .{ .fg = soft_blue };
    pub const git_ref: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } }, .bold = true };
    // Fixed dark surfaces match the current Codex-like composer and keep the
    // add/delete signal restrained enough for syntax colors to remain legible.
    pub const diff_add_bg: vaxis.Color = .{ .rgb = .{ 0x1f, 0x37, 0x29 } };
    pub const diff_del_bg: vaxis.Color = .{ .rgb = .{ 0x3b, 0x24, 0x29 } };
    pub const diff_add: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x73, 0xd0, 0x91 } }, .bg = diff_add_bg, .bold = true };
    pub const diff_del: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf0, 0x71, 0x78 } }, .bg = diff_del_bg, .bold = true };
    pub const diff_add_code: vaxis.Style = .{ .bg = diff_add_bg };
    pub const diff_del_code: vaxis.Style = .{ .bg = diff_del_bg };
    pub const diff_context: vaxis.Style = .{ .fg = .{ .index = 8 } };
    pub const diff_hunk: vaxis.Style = .{ .fg = .{ .index = 6 } }; // cyan @@ + decl ctx
    pub const syntax_keyword: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc7, 0x92, 0xea } }, .bold = true };
    pub const syntax_string: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xc3, 0xe8, 0x8d } } };
    pub const syntax_number: vaxis.Style = .{ .fg = .{ .rgb = .{ 0xf7, 0x8c, 0x6c } } };
    pub const syntax_comment: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x69, 0x70, 0x98 } }, .italic = true };
    pub const syntax_type: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x89, 0xdd, 0xff } } };
    pub const syntax_function: vaxis.Style = .{ .fg = .{ .rgb = .{ 0x82, 0xaa, 0xff } } };
    pub const syntax_constant: vaxis.Style = .{ .fg = soft_blue };
    pub const note: vaxis.Style = .{ .fg = soft_blue };
    pub const steer: vaxis.Style = .{ .fg = .{ .index = 5 } }; // magenta
    pub const status_bg: vaxis.Color = .{ .index = 0 };
    pub const status_bar: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 7 } };
    pub const status_sep: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 8 }, .dim = true };
    pub const status_idle: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 2 } };
    pub const status_running: vaxis.Style = .{ .bg = status_bg, .fg = soft_blue, .bold = true };
    pub const status_approval: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 }, .bold = true };
    pub const status_error: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 1 }, .bold = true };
    pub const status_model: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 6 } };
    pub const status_effort: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 5 } };
    pub const status_child: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 6 }, .bold = true };
    pub const status_context: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 4 } };
    pub const status_context_warn: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 3 } };
    pub const status_context_hot: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 1 } };
    pub const status_cwd: vaxis.Style = .{ .bg = status_bg, .fg = .{ .index = 2 } };
    pub const status_notice: vaxis.Style = .{ .bg = status_bg, .fg = soft_blue };
    pub const approval_card: vaxis.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    pub const delta_style: vaxis.Style = .{};
};

pub const LinkSpan = struct {
    /// Byte offsets in the concatenated visible text of a Line.
    start: usize,
    end: usize,
    /// OSC 8 destination. Always an allowlisted http(s) URL.
    uri: []const u8,
};

pub const SyntaxSpan = struct {
    /// Byte offsets in the concatenated visible text of a Line.
    start: usize,
    end: usize,
    style: vaxis.Style,
};

/// One logical display line: 1..3 styled segments (segments never wrap
/// independently; the line is the wrap unit). Slices point into the App's
/// block storage or the frame arena (valid for the frame).
pub const Line = struct {
    text: []const u8,
    style: vaxis.Style,
    /// When set, paint the complete terminal row before printing segments.
    /// Prompt cards use this to retain their background past the text.
    fill_style: ?vaxis.Style = null,
    /// A bounded Markdown surface can fill only its content measure. A null
    /// width retains the historical full-row behavior used by prompt cards.
    fill_start: u16 = 0,
    fill_width: ?u16 = null,
    /// Optional second/third segment printed after `text` on the same row.
    text2: []const u8 = "",
    style2: vaxis.Style = .{},
    text3: []const u8 = "",
    style3: vaxis.Style = .{},
    /// Hyperlinks over the concatenated text/text2/text3 byte stream.
    links: []const LinkSpan = &.{},
    /// Foreground-only code syntax overlays. The underlying row background
    /// remains intact for added/deleted diff lines.
    syntax: []const SyntaxSpan = &.{},
    /// Wrapped message lines resolve links against the unbroken source URL.
    /// Other line kinds are scanned once after layout is complete.
    links_resolved: bool = false,
};

pub const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Grayscale ramp for the Working shimmer: a crest of white travels through
/// otherwise mid-grey letters as the animation tick advances the phase —
/// monochrome movement, not a color cycle.
pub const shimmer_shades = [_]vaxis.Color{
    .{ .rgb = .{ 0x6e, 0x6e, 0x6e } },
    .{ .rgb = .{ 0x7e, 0x7e, 0x7e } },
    .{ .rgb = .{ 0x96, 0x96, 0x96 } },
    .{ .rgb = .{ 0xb6, 0xb6, 0xb6 } },
    .{ .rgb = .{ 0xdc, 0xdc, 0xdc } },
    .{ .rgb = .{ 0xff, 0xff, 0xff } },
    .{ .rgb = .{ 0xdc, 0xdc, 0xdc } },
    .{ .rgb = .{ 0xb6, 0xb6, 0xb6 } },
    .{ .rgb = .{ 0x96, 0x96, 0x96 } },
    .{ .rgb = .{ 0x7e, 0x7e, 0x7e } },
};

/// One bold shimmer span per code point of `text`, phase-shifted by `frame`
/// so successive animation ticks move the brightness crest. `offset` is the
/// byte position of `text` within the line's concatenated visible text.
pub fn shimmerSpans(
    arena: std.mem.Allocator,
    text: []const u8,
    offset: usize,
    frame: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var i: usize = 0;
    var char_index: usize = 0;
    while (i < text.len) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + seq, text.len);
        try spans.append(arena, .{
            .start = offset + i,
            .end = offset + end,
            .style = .{
                .fg = shimmer_shades[(char_index + frame) % shimmer_shades.len],
                .bold = true,
            },
        });
        i = end;
        char_index += 1;
    }
    return spans.toOwnedSlice(arena);
}

/// Codepoint end for byte index i (module-local mirror of the editor's).
pub fn nextCpEndFor(t: []const u8, i: usize) usize {
    if (i >= t.len) return t.len;
    var j = i + 1;
    while (j < t.len and (t[j] & 0b1100_0000) == 0b1000_0000) : (j += 1) {}
    return j;
}

/// Next word start at or after `col` (ASCII word boundaries over the
/// rendered line text; columns approximate bytes, which holds for the
/// transcript's overwhelmingly ASCII content).
pub fn nextWordCol(text: []const u8, col: usize) usize {
    var i = @min(col, text.len);
    while (i < text.len and text[i] != ' ') i += 1;
    while (i < text.len and text[i] == ' ') i += 1;
    return if (i == text.len and text.len > 0) text.len - 1 else i;
}

/// Previous word start strictly before `col`.
pub fn prevWordCol(text: []const u8, col: usize) usize {
    var i = @min(col, text.len);
    while (i > 0 and (i > text.len - 1 or i >= text.len or text[i - 1] == ' ')) i -= 1;
    while (i > 0 and text[i - 1] != ' ') i -= 1;
    return i;
}

/// Freshest complete-ish line of a streaming text (for the reasoning ticker).
pub fn lastNonEmptyLine(text: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return text;
}

/// Largest byte index <= max that does not split a UTF-8 sequence.
pub fn utf8Floor(text: []const u8, max: usize) usize {
    var end = @min(max, text.len);
    while (end > 0 and end < text.len and (text[end] & 0xc0) == 0x80) end -= 1;
    return end;
}

/// Clip long text at a UTF-8-safe boundary with an ellipsis; short text
/// passes through untouched.
pub fn clipText(arena: std.mem.Allocator, text: []const u8, max: usize) ![]const u8 {
    if (text.len <= max) return text;
    return std.fmt.allocPrint(arena, "{s} …", .{text[0..utf8Floor(text, max)]});
}

pub const legacy_rehydration_prefix = "[rehydrated after compaction]";

pub fn isLegacyRehydration(text: []const u8) bool {
    return std.mem.startsWith(u8, text, legacy_rehydration_prefix);
}

pub fn rehydrationLabel(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (!isLegacyRehydration(text))
        return allocator.dupe(u8, "rehydrated file context");
    const rest = std.mem.trimStart(u8, text[legacy_rehydration_prefix.len..], " \t");
    const first_line = if (std.mem.indexOfScalar(u8, rest, '\n')) |end| rest[0..end] else rest;
    const path = std.mem.trim(u8, std.mem.trimEnd(u8, first_line, ":"), " \t");
    if (path.len == 0) return allocator.dupe(u8, "rehydrated file context");
    return std.fmt.allocPrint(allocator, "rehydrated {s}", .{path});
}

pub fn isCompactionStatusNote(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "context compacted automatically") or
        std.mem.startsWith(u8, text, "context compacted by /compact");
}

pub fn nowWallMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

pub fn lineWidth(win: vaxis.Window, line: Line) usize {
    return @as(usize, win.gwidth(line.text)) +
        @as(usize, win.gwidth(line.text2)) +
        @as(usize, win.gwidth(line.text3));
}

pub fn lineText(arena: std.mem.Allocator, line: Line) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ line.text, line.text2, line.text3 });
}

pub const SyntaxLanguage = enum {
    generic,
    zig,
    rust,
    javascript,
    python,
    shell,
    json,
    toml,
    yaml,
    c_like,
    go,
    ruby,
    markdown,
};

pub fn languageForPath(path: []const u8) SyntaxLanguage {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or
        std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
        std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return .javascript;
    if (std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".pyi")) return .python;
    if (std.mem.eql(u8, ext, ".sh") or std.mem.eql(u8, ext, ".bash") or
        std.mem.eql(u8, ext, ".zsh") or std.mem.eql(u8, ext, ".fish")) return .shell;
    if (std.mem.eql(u8, ext, ".json") or std.mem.eql(u8, ext, ".jsonc")) return .json;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or
        std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".cxx") or std.mem.eql(u8, ext, ".hpp") or
        std.mem.eql(u8, ext, ".java") or std.mem.eql(u8, ext, ".swift") or
        std.mem.eql(u8, ext, ".kt")) return .c_like;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".rb")) return .ruby;
    if (std.mem.eql(u8, ext, ".md") or std.mem.eql(u8, ext, ".mdx")) return .markdown;
    return .generic;
}

/// Edit results start with `replaced ... in path`; regular git diffs expose
/// the target in a `+++ b/path` line. Supporting both keeps bash-produced
/// diffs useful too.
pub fn diffLanguage(text: []const u8) SyntaxLanguage {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.lastIndexOf(u8, line, " in ")) |at| {
            const path = std.mem.trim(u8, line[at + 4 ..], " \t\r");
            const lang = languageForPath(path);
            if (lang != .generic) return lang;
        }
        if (std.mem.startsWith(u8, line, "+++ ")) {
            var path = std.mem.trim(u8, line[4..], " \t\r");
            if (std.mem.startsWith(u8, path, "b/")) path = path[2..];
            if (!std.mem.eql(u8, path, "/dev/null")) return languageForPath(path);
        }
    }
    return .generic;
}

pub fn wordIn(word: []const u8, words: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, words, ' ');
    while (it.next()) |candidate| {
        if (std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

pub fn isKeyword(lang: SyntaxLanguage, word: []const u8) bool {
    const words: []const u8 = switch (lang) {
        .zig => "align allowzero and anyframe anytype asm async await break catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while",
        .rust => "as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait type unsafe use where while",
        .javascript => "async await break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof let new of return static super switch this throw try typeof var void while with yield interface type enum implements namespace private protected public readonly",
        .python => "and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case",
        .shell => "case do done elif else esac fi for function if in select then time until while",
        .c_like => "alignas alignof auto break case catch class const constexpr continue default delete do else enum explicit export extern final for friend goto if import inline interface namespace new noexcept operator override private protected public register return signed sizeof static struct switch template this throw try typedef typename union unsigned using virtual volatile while",
        .go => "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        .ruby => "alias and begin break case class def defined do else elsif end ensure false for if in module next not or redo rescue retry return self super then true undef unless until when while yield",
        else => "",
    };
    return wordIn(word, words);
}

pub fn isBuiltinType(word: []const u8) bool {
    return wordIn(
        word,
        "anyerror anyopaque bool byte c_int char comptime_float comptime_int f16 f32 f64 f80 f128 i8 i16 i32 i64 i128 isize noreturn str string String u8 u16 u32 u64 u128 usize void",
    );
}

pub fn isConstant(word: []const u8) bool {
    return wordIn(word, "false true null undefined nil None True False");
}

pub fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c == '@' or c == '$';
}

pub fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

pub fn lineCommentMarker(lang: SyntaxLanguage) ?[]const u8 {
    return switch (lang) {
        .python, .shell, .toml, .yaml, .ruby => "#",
        .zig, .rust, .javascript, .c_like, .go => "//",
        else => null,
    };
}

pub fn appendSyntaxSpan(
    arena: std.mem.Allocator,
    spans: *std.ArrayList(SyntaxSpan),
    start: usize,
    end: usize,
    offset: usize,
    style: vaxis.Style,
) !void {
    try spans.append(arena, .{ .start = offset + start, .end = offset + end, .style = style });
}

/// Lightweight, line-local lexer. It intentionally recognizes broad lexical
/// classes rather than pretending to be a parser; malformed/incomplete diff
/// lines still receive stable highlighting and never affect stored text.
pub fn syntaxSpans(
    arena: std.mem.Allocator,
    code: []const u8,
    lang: SyntaxLanguage,
    offset: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var i: usize = 0;
    while (i < code.len) {
        if (lineCommentMarker(lang)) |marker| {
            if (std.mem.startsWith(u8, code[i..], marker)) {
                try appendSyntaxSpan(arena, &spans, i, code.len, offset, Palette.syntax_comment);
                break;
            }
        }
        if (std.mem.startsWith(u8, code[i..], "/*")) {
            const close = std.mem.indexOfPos(u8, code, i + 2, "*/");
            const end = if (close) |at| at + 2 else code.len;
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_comment);
            i = end;
            continue;
        }
        const c = code[i];
        if (c == '"' or c == '\'' or c == '`') {
            const quote = c;
            var end = i + 1;
            while (end < code.len) : (end += 1) {
                if (code[end] == '\\') {
                    end = @min(end + 1, code.len);
                    continue;
                }
                if (code[end] == quote) {
                    end += 1;
                    break;
                }
            }
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_string);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var end = i + 1;
            while (end < code.len and (std.ascii.isAlphanumeric(code[end]) or
                code[end] == '.' or code[end] == '_')) : (end += 1)
            {}
            try appendSyntaxSpan(arena, &spans, i, end, offset, Palette.syntax_number);
            i = end;
            continue;
        }
        if (isIdentStart(c)) {
            var end = i + 1;
            while (end < code.len and isIdentContinue(code[end])) : (end += 1) {}
            const word = code[i..end];
            var style: ?vaxis.Style = null;
            if (isKeyword(lang, word) or c == '@')
                style = Palette.syntax_keyword
            else if (isConstant(word))
                style = Palette.syntax_constant
            else if (isBuiltinType(word) or std.ascii.isUpper(c))
                style = Palette.syntax_type
            else {
                var next = end;
                while (next < code.len and (code[next] == ' ' or code[next] == '\t')) next += 1;
                if (next < code.len and code[next] == '(') style = Palette.syntax_function;
            }
            if (style) |token_style| try appendSyntaxSpan(arena, &spans, i, end, offset, token_style);
            i = end;
            continue;
        }
        i += 1;
    }
    return spans.items;
}

pub fn isShellOperator(c: u8) bool {
    return switch (c) {
        '&', '|', ';', '<', '>', '(', ')' => true,
        else => false,
    };
}

/// Return the end of a shell operator, including a leading file descriptor
/// (`2>&1`). Keeping the whole redirection together makes it read as syntax,
/// not as a number followed by unrelated punctuation.
pub fn shellOperatorEnd(command: []const u8, start: usize) ?usize {
    var at = start;
    while (at < command.len and std.ascii.isDigit(command[at])) at += 1;
    if (at == command.len or !isShellOperator(command[at])) return null;
    if (at > start and command[at] != '<' and command[at] != '>') return null;

    at += 1;
    while (at < command.len and
        (isShellOperator(command[at]) or std.ascii.isDigit(command[at])))
    {
        at += 1;
    }
    return at;
}

pub fn shellOperatorExpectsCommand(operator: []const u8) bool {
    if (operator.len == 0 or std.ascii.isDigit(operator[0]) or
        operator[0] == '<' or operator[0] == '>') return false;
    if (std.mem.startsWith(u8, operator, "&>")) return false;
    return std.mem.indexOfAny(u8, operator, "|;&()") != null;
}

pub fn isShellWrapper(word: []const u8) bool {
    return wordIn(word, "command builtin env exec nohup sudo");
}

pub fn isShellPath(word: []const u8) bool {
    return (word.len > 0 and (word[0] == '.' or word[0] == '~' or word[0] == '/')) or
        std.mem.indexOfScalar(u8, word, '/') != null;
}

/// Shell-aware styling for bash tool previews. This is deliberately lexical:
/// it separates the landmarks people scan for (programs, flags, operators,
/// strings, paths, and variables) without trying to execute or fully parse
/// arbitrary shell input.
pub fn shellCommandSpans(
    arena: std.mem.Allocator,
    command: []const u8,
    offset: usize,
) ![]const SyntaxSpan {
    var spans: std.ArrayList(SyntaxSpan) = .empty;
    var at: usize = 0;
    var expect_command = true;

    while (at < command.len) {
        while (at < command.len and (command[at] == ' ' or command[at] == '\t')) at += 1;
        if (at >= command.len) break;

        if (command[at] == '#') {
            try appendSyntaxSpan(arena, &spans, at, command.len, offset, Palette.syntax_comment);
            break;
        }

        if (command[at] == '"' or command[at] == '\'' or command[at] == '`') {
            const quote = command[at];
            var end = at + 1;
            while (end < command.len) {
                if (command[end] == '\\' and quote != '\'') {
                    end = @min(end + 2, command.len);
                    continue;
                }
                if (command[end] == quote) {
                    end += 1;
                    break;
                }
                end += 1;
            }
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_string);
            expect_command = false;
            at = end;
            continue;
        }

        if (command[at] == '$') {
            var end = at + 1;
            if (end < command.len and command[end] == '{') {
                end += 1;
                while (end < command.len and command[end] != '}') end += 1;
                if (end < command.len) end += 1;
            } else {
                while (end < command.len and
                    (std.ascii.isAlphanumeric(command[end]) or command[end] == '_')) end += 1;
            }
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_variable);
            at = end;
            continue;
        }

        if (shellOperatorEnd(command, at)) |end| {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_operator);
            if (shellOperatorExpectsCommand(command[at..end])) expect_command = true;
            at = end;
            continue;
        }

        var end = at + 1;
        while (end < command.len and command[end] != ' ' and command[end] != '\t' and
            command[end] != '"' and command[end] != '\'' and command[end] != '`' and
            !isShellOperator(command[end]))
        {
            end += 1;
        }
        const word = command[at..end];
        const assignment = std.mem.indexOfScalar(u8, word, '=') != null and word[0] != '-';

        if (expect_command and assignment) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_variable);
        } else if (isKeyword(.shell, word)) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.syntax_keyword);
            expect_command = wordIn(word, "do elif else for function if select then time until while");
        } else if (expect_command) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_executable);
            expect_command = isShellWrapper(word);
        } else if (word.len > 1 and word[0] == '-') {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_flag);
        } else if (isShellPath(word)) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_path);
        } else if (assignment) {
            try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.shell_variable);
        } else if (std.ascii.isDigit(word[0])) {
            var all_numeric = true;
            for (word) |c| {
                if (!std.ascii.isDigit(c)) {
                    all_numeric = false;
                    break;
                }
            }
            if (all_numeric) try appendSyntaxSpan(arena, &spans, at, end, offset, Palette.syntax_number);
        }
        at = end;
    }
    return spans.items;
}

/// Recognize the stable `git log --oneline` shape without depending on the
/// originating command. This also handles useful stdout from a compound shell
/// command whose final step failed: the error glyph stays red, while the log
/// itself remains legible.
pub fn gitLogSpans(
    arena: std.mem.Allocator,
    line: []const u8,
    offset: usize,
) ![]const SyntaxSpan {
    var hash_end: usize = 0;
    while (hash_end < line.len and hash_end < 40 and std.ascii.isHex(line[hash_end])) hash_end += 1;
    if (hash_end < 7 or hash_end >= line.len or line[hash_end] != ' ') return &.{};

    var spans: std.ArrayList(SyntaxSpan) = .empty;
    try appendSyntaxSpan(arena, &spans, 0, hash_end, offset, Palette.git_hash);

    var refs_start = hash_end + 1;
    while (refs_start < line.len and line[refs_start] == ' ') refs_start += 1;
    if (refs_start < line.len and line[refs_start] == '(') {
        if (std.mem.indexOfScalarPos(u8, line, refs_start + 1, ')')) |close| {
            try appendSyntaxSpan(arena, &spans, refs_start, close + 1, offset, Palette.git_ref);
        }
    }
    return spans.items;
}

pub fn isUrlStart(text: []const u8, at: usize) bool {
    return std.mem.startsWith(u8, text[at..], "https://") or
        std.mem.startsWith(u8, text[at..], "http://");
}

pub fn isUrlTerminator(c: u8) bool {
    return c <= ' ' or c == '<' or c == '>' or c == '"' or c == '\'' or c == '`';
}

pub fn countByte(text: []const u8, needle: u8) usize {
    var count: usize = 0;
    for (text) |c| if (c == needle) {
        count += 1;
    };
    return count;
}

/// End of a plain http(s) URL, excluding prose/Markdown punctuation.
pub fn urlEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and !isUrlTerminator(text[end])) end += 1;

    // Sentence punctuation is almost never intended to be part of a URL.
    while (end > start and std.mem.indexOfScalar(u8, ".,;:!?", text[end - 1]) != null) end -= 1;

    // Keep balanced delimiters inside URLs, but drop unmatched prose or
    // Markdown closers: `(https://example.test/foo)` -> URL without final `)`.
    const pairs = [_][2]u8{ .{ '(', ')' }, .{ '[', ']' }, .{ '{', '}' } };
    inline for (pairs) |pair| {
        while (end > start and text[end - 1] == pair[1] and
            countByte(text[start..end], pair[1]) > countByte(text[start..end], pair[0]))
        {
            end -= 1;
        }
    }
    return end;
}

/// Find visible spans that should carry OSC 8 metadata. Markdown stays
/// visible for now, but both its label and destination become clickable.
pub fn findLinkSpans(arena: std.mem.Allocator, text: []const u8) ![]const LinkSpan {
    var spans: std.ArrayList(LinkSpan) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '[') {
            if (std.mem.indexOfPos(u8, text, i + 1, "](")) |label_end| {
                const uri_start = label_end + 2;
                if (uri_start < text.len and isUrlStart(text, uri_start)) {
                    const uri_end = urlEnd(text, uri_start);
                    if (uri_end > uri_start and uri_end < text.len and text[uri_end] == ')') {
                        const uri = text[uri_start..uri_end];
                        if (label_end > i + 1) try spans.append(arena, .{
                            .start = i + 1,
                            .end = label_end,
                            .uri = uri,
                        });
                        try spans.append(arena, .{
                            .start = uri_start,
                            .end = uri_end,
                            .uri = uri,
                        });
                        i = uri_end + 1;
                        continue;
                    }
                }
            }
        }

        if (isUrlStart(text, i)) {
            const end = urlEnd(text, i);
            if (end > i) try spans.append(arena, .{ .start = i, .end = end, .uri = text[i..end] });
            i = @max(end, i + 1);
            continue;
        }
        i += 1;
    }
    return spans.items;
}

/// Intersect source-text links with one hard-wrapped chunk. Each resulting
/// span keeps the full URI even when only part of its label/URL is visible.
pub fn linksForChunk(
    arena: std.mem.Allocator,
    source_links: []const LinkSpan,
    chunk_start: usize,
    chunk_end: usize,
    prefix_len: usize,
) ![]const LinkSpan {
    var spans: std.ArrayList(LinkSpan) = .empty;
    for (source_links) |link| {
        const start = @max(link.start, chunk_start);
        const end = @min(link.end, chunk_end);
        if (start < end) try spans.append(arena, .{
            .start = prefix_len + start - chunk_start,
            .end = prefix_len + end - chunk_start,
            .uri = link.uri,
        });
    }
    return spans.items;
}

pub fn resolveLineLinks(arena: std.mem.Allocator, lines: []Line) !void {
    for (lines) |*line| {
        if (line.links_resolved) continue;
        const text = try lineText(arena, line.*);
        line.links = try findLinkSpans(arena, text);
        line.links_resolved = true;
    }
}

pub fn linkForBytes(links: []const LinkSpan, start: usize, end: usize) ?[]const u8 {
    for (links) |link| {
        if (start < link.end and end > link.start) return link.uri;
    }
    return null;
}

pub fn syntaxForBytes(spans: []const SyntaxSpan, start: usize, end: usize) ?vaxis.Style {
    for (spans) |span| {
        if (start < span.end and end > span.start) return span.style;
    }
    return null;
}

/// Overlay syntax or inline-Markdown attributes. A non-default background is
/// intentional (inline-code chips); a default background preserves any block
/// surface already painted underneath, including diff and code-panel rows.
pub fn applyLineSyntax(win: vaxis.Window, row: u16, line: Line) void {
    if (line.syntax.len == 0) return;
    const parts = [_][]const u8{ line.text, line.text2, line.text3 };
    var byte_offset: usize = 0;
    var col: usize = 0;
    for (parts) |part| {
        var part_offset: usize = 0;
        var it = vaxis.unicode.graphemeIterator(part);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(part);
            const start = byte_offset + part_offset;
            const end = start + bytes.len;
            const cell_width: usize = @intCast(win.gwidth(bytes));
            if (syntaxForBytes(line.syntax, start, end)) |style| {
                if (col < @as(usize, win.width)) {
                    if (win.readCell(@intCast(col), row)) |cell| {
                        var highlighted = cell;
                        if (!vaxis.Color.eql(style.fg, .default)) highlighted.style.fg = style.fg;
                        if (!vaxis.Color.eql(style.bg, .default)) highlighted.style.bg = style.bg;
                        highlighted.style.bold = style.bold;
                        highlighted.style.dim = style.dim;
                        highlighted.style.italic = style.italic;
                        highlighted.style.strikethrough = style.strikethrough;
                        win.writeCell(@intCast(col), row, highlighted);
                    }
                }
            }
            part_offset += bytes.len;
            col += cell_width;
        }
        byte_offset += part.len;
    }
}

/// Attach OSC 8 metadata after styled segments have been painted. This keeps
/// syntax colors and selection independent from the link parser.
pub fn applyLineLinks(win: vaxis.Window, row: u16, line: Line) void {
    if (line.links.len == 0) return;
    const parts = [_][]const u8{ line.text, line.text2, line.text3 };
    var byte_offset: usize = 0;
    var col: usize = 0;
    for (parts) |part| {
        var part_offset: usize = 0;
        var it = vaxis.unicode.graphemeIterator(part);
        while (it.next()) |grapheme| {
            const bytes = grapheme.bytes(part);
            const start = byte_offset + part_offset;
            const end = start + bytes.len;
            const cell_width: usize = @intCast(win.gwidth(bytes));
            if (linkForBytes(line.links, start, end)) |uri| {
                if (col < @as(usize, win.width)) {
                    if (win.readCell(@intCast(col), row)) |cell| {
                        var linked = cell;
                        linked.link = .{ .uri = uri };
                        linked.style.fg = .{ .index = 6 }; // cyan
                        linked.style.ul_style = .single;
                        win.writeCell(@intCast(col), row, linked);
                    }
                }
            }
            part_offset += bytes.len;
            col += cell_width;
        }
        byte_offset += part.len;
    }
}

/// Append every complete grapheme intersecting [start_col, end_col).
pub const SelectionPoint = struct {
    line: usize,
    /// Terminal cell column, not a byte offset.
    col: usize,

    fn before(a: SelectionPoint, b: SelectionPoint) bool {
        return a.line < b.line or (a.line == b.line and a.col <= b.col);
    }
};

pub const Selection = struct {
    lo: SelectionPoint,
    hi: SelectionPoint,

    pub fn init(a: SelectionPoint, b: SelectionPoint) Selection {
        return if (a.before(b)) .{ .lo = a, .hi = b } else .{ .lo = b, .hi = a };
    }

    /// Selected terminal-cell interval on `line`, end-exclusive and clamped
    /// to the rendered text width. Mouse endpoints themselves are inclusive.
    pub fn columns(self: Selection, line: usize, line_width: usize) ?struct { start: usize, end: usize } {
        if (line < self.lo.line or line > self.hi.line) return null;
        const start = if (line == self.lo.line) @min(self.lo.col, line_width) else 0;
        const wanted_end = if (line == self.hi.line) self.hi.col +| 1 else line_width;
        return .{ .start = start, .end = @min(wanted_end, line_width) };
    }
};

pub fn appendColumns(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    win: vaxis.Window,
    text: []const u8,
    start_col: usize,
    end_col: usize,
) !void {
    var it = vaxis.unicode.graphemeIterator(text);
    var col: usize = 0;
    while (it.next()) |grapheme| {
        const bytes = grapheme.bytes(text);
        const next = col + @as(usize, win.gwidth(bytes));
        if (next > start_col and col < end_col) try out.appendSlice(arena, bytes);
        col = next;
        if (col >= end_col) break;
    }
}

pub fn selectedText(
    arena: std.mem.Allocator,
    win: vaxis.Window,
    lines: []const Line,
    selection: Selection,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    if (selection.lo.line >= lines.len) return out.items;
    const last = @min(selection.hi.line, lines.len - 1);
    var line_idx = selection.lo.line;
    while (line_idx <= last) : (line_idx += 1) {
        if (line_idx > selection.lo.line) try out.append(arena, '\n');
        const line = lines[line_idx];
        const text = try lineText(arena, line);
        const cols = selection.columns(line_idx, lineWidth(win, line)) orelse continue;
        try appendColumns(arena, &out, win, text, cols.start, cols.end);
    }
    return out.items;
}

pub fn blankLine(arena: std.mem.Allocator, lines: *std.ArrayList(Line)) !void {
    try lines.append(arena, .{ .text = "", .style = .{} });
}

/// The one argument worth reading in a tool call: bash's command, file
/// tools' path, grep/glob's pattern, fetch's url. Returns a slice into
/// args_json (JSON-escaped — good enough for a one-line preview; commands
/// with heavy escaping still show faithfully enough to recognize).
pub fn wrapInto(arena: std.mem.Allocator, lines: *std.ArrayList(Line), _: []const u8, line: Line) !void {
    try lines.append(arena, line);
}

/// Wrap auxiliary transcript text onto the same visual rail as assistant
/// prose. Continuations hang beneath the text instead of snapping to column
/// zero, and cell-aware breaks keep Unicode intact.
pub fn wrapPrefixed(
    arena: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    prefix: []const u8,
    text: []const u8,
    style: vaxis.Style,
    width: usize,
) !void {
    const continuation = try spaces(arena, displayWidth(prefix));
    var first = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const source_links = try findLinkSpans(arena, raw_line);
        if (raw_line.len == 0) {
            try lines.append(arena, .{ .text = "", .style = style });
            continue;
        }
        var start: usize = 0;
        while (start < raw_line.len) {
            const line_prefix = if (first) prefix else continuation;
            const body_width = width -| displayWidth(line_prefix);
            if (body_width == 0) return;
            var end = wordBreak(raw_line, start, body_width);
            if (end == start) end = hardCellBreak(raw_line, start, body_width);
            const chunk = raw_line[start..end];
            const full = if (line_prefix.len > 0)
                try std.fmt.allocPrint(arena, "{s}{s}", .{ line_prefix, chunk })
            else
                chunk;
            const links = try linksForChunk(
                arena,
                source_links,
                start,
                end,
                line_prefix.len,
            );
            try lines.append(arena, .{
                .text = full,
                .style = style,
                .links = links,
                .links_resolved = true,
            });
            first = false;
            start = end;
            while (start < raw_line.len and (raw_line[start] == ' ' or raw_line[start] == '\t')) start += 1;
        }
    }
}

pub fn displayWidth(text: []const u8) usize {
    return @intCast(vaxis.gwidth.gwidth(text, .unicode));
}

pub fn hardCellBreak(text: []const u8, start: usize, capacity: usize) usize {
    if (start >= text.len or capacity == 0) return start;
    var it = vaxis.unicode.graphemeIterator(text[start..]);
    var bytes_used: usize = 0;
    var cells_used: usize = 0;
    while (it.next()) |grapheme| {
        const bytes = grapheme.bytes(text[start..]);
        const cells = displayWidth(bytes);
        if (bytes_used > 0 and cells_used + cells > capacity) break;
        bytes_used += bytes.len;
        cells_used += cells;
        if (cells_used >= capacity) break;
    }
    return start + bytes_used;
}

pub fn wordBreak(text: []const u8, start: usize, capacity: usize) usize {
    const hard_end = hardCellBreak(text, start, capacity);
    if (hard_end >= text.len) return text.len;
    var at = hard_end;
    while (at > start) : (at -= 1) {
        if (text[at - 1] == ' ' or text[at - 1] == '\t') return at - 1;
    }
    return hard_end;
}

pub fn spaces(arena: std.mem.Allocator, count: usize) ![]const u8 {
    const out = try arena.alloc(u8, count);
    @memset(out, ' ');
    return out;
}

pub fn appendGlyphNTimes(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    glyph: []const u8,
    count: usize,
) !void {
    for (0..count) |_| try out.appendSlice(arena, glyph);
}

test "informational accents are blue while attention states remain yellow" {
    try std.testing.expect(vaxis.Color.eql(Palette.note.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.md_code.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.shell_path.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.git_hash.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.syntax_constant.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.status_running.fg, Palette.soft_blue));
    try std.testing.expect(vaxis.Color.eql(Palette.status_notice.fg, Palette.soft_blue));

    const attention_yellow: vaxis.Color = .{ .index = 3 };
    try std.testing.expect(vaxis.Color.eql(Palette.status_approval.fg, attention_yellow));
    try std.testing.expect(vaxis.Color.eql(Palette.status_context_warn.fg, attention_yellow));
    try std.testing.expect(vaxis.Color.eql(Palette.approval_card.fg, attention_yellow));
}

test {
    std.testing.refAllDecls(@This());
}
