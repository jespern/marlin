//! fetch tool: HTTP GET → readable text. Uses the shared std.http transport.
//! For HTML responses, tags are
//! stripped crudely (script/style dropped, block tags → newlines, links kept
//! as "text (url)"). parallel_safe.

const std = @import("std");

const http = @import("../provider/http.zig");
const network_policy = @import("../network_policy.zig");

pub const spec_name = "fetch";
pub const spec_description =
    "Fetch a URL with HTTP GET and return the response as readable text. " ++
    "HTML is converted to plain text; JSON and plain text are returned as-is.";
pub const spec_schema =
    \\{"type":"object","properties":{"url":{"type":"string","description":"http(s) URL"}},"required":["url"]}
;

pub const Args = struct { url: []const u8 };

pub const max_fetch_bytes: usize = 4 * 1024 * 1024;

pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    args: Args,
    policy: ?*const network_policy.Policy,
    cancel: ?*std.atomic.Value(bool),
    payload_bytes_out: ?*u64,
) ![]u8 {
    if (payload_bytes_out) |out| out.* = 0;
    if (!std.mem.startsWith(u8, args.url, "http://") and !std.mem.startsWith(u8, args.url, "https://")) {
        return std.fmt.allocPrint(gpa, "error: only http(s) URLs are supported, got '{s}'", .{args.url});
    }
    var current_url = try gpa.dupe(u8, args.url);
    defer gpa.free(current_url);

    var res: http.GetOneResult = undefined;
    var have_response = false;
    var redirects: usize = 0;
    while (redirects <= max_redirects) : (redirects += 1) {
        if (policy) |active| {
            const matched = active.checkUrl(current_url) catch |err| {
                return std.fmt.allocPrint(gpa, "error: invalid fetch URL: {t}", .{err});
            };
            if (matched) |rule| {
                return std.fmt.allocPrint(
                    gpa,
                    "error: network policy blocked '{s}' via {s} (matched {s})",
                    .{ current_url, rule.source, rule.domain },
                );
            }
        }

        const url_z = try gpa.dupeZ(u8, current_url);
        defer gpa.free(url_z);
        var next = http.getOne(gpa, io, environ, url_z, max_fetch_bytes, 60_000, cancel) catch |err| {
            return std.fmt.allocPrint(gpa, "error: fetch failed: {t}", .{err});
        };

        if (!isRedirect(next.status)) {
            res = next;
            have_response = true;
            break;
        }
        const location = next.location orelse {
            freeGetOne(gpa, &next);
            return gpa.dupe(u8, "error: redirect response had no Location header");
        };
        const resolved = resolveRedirect(gpa, current_url, location) catch |err| {
            freeGetOne(gpa, &next);
            return std.fmt.allocPrint(gpa, "error: invalid redirect URL: {t}", .{err});
        };
        freeGetOne(gpa, &next);
        gpa.free(current_url);
        current_url = resolved;
    }
    if (!have_response) return gpa.dupe(u8, "error: too many redirects");

    defer gpa.free(res.body);
    defer if (res.content_type) |ct| gpa.free(ct);
    defer if (res.location) |location| gpa.free(location);

    if (res.status >= 400) {
        return std.fmt.allocPrint(gpa, "error: HTTP {d}\n{s}", .{
            res.status, res.body[0..@min(res.body.len, 2000)],
        });
    }

    if (payload_bytes_out) |out| out.* = @intCast(res.body.len);

    const is_html = blk: {
        if (res.content_type) |ct| {
            if (indexOfIgnoreCase(ct, "text/html") != null) break :blk true;
            if (indexOfIgnoreCase(ct, "xhtml") != null) break :blk true;
        }
        // Sniff when content-type is missing/vague.
        const head = res.body[0..@min(res.body.len, 512)];
        break :blk indexOfIgnoreCase(head, "<html") != null or
            indexOfIgnoreCase(head, "<!doctype html") != null;
    };

    if (is_html) return htmlToText(gpa, res.body);

    // Binary sniff on non-HTML: refuse rather than spew garbage into context.
    if (std.mem.indexOfScalar(u8, res.body[0..@min(res.body.len, 4096)], 0) != null) {
        return std.fmt.allocPrint(gpa, "error: response looks binary ({d} bytes, content-type {s})", .{
            res.body.len, res.content_type orelse "unknown",
        });
    }
    return gpa.dupe(u8, res.body);
}

const max_redirects: usize = 5;

fn isRedirect(status: i64) bool {
    return status == 300 or status == 301 or status == 302 or status == 303 or
        status == 307 or status == 308;
}

fn freeGetOne(gpa: std.mem.Allocator, result: *http.GetOneResult) void {
    gpa.free(result.body);
    if (result.content_type) |value| gpa.free(value);
    if (result.location) |value| gpa.free(value);
}

pub fn resolveRedirect(gpa: std.mem.Allocator, base_text: []const u8, location: []const u8) ![]u8 {
    const base = try std.Uri.parse(base_text);
    const storage = try gpa.alloc(u8, location.len + base_text.len + 1);
    defer gpa.free(storage);
    @memcpy(storage[0..location.len], location);
    var aux = storage;
    const resolved = try base.resolveInPlace(location.len, &aux);
    return std.fmt.allocPrint(gpa, "{f}", .{resolved.fmt(.all)});
}

/// Crude but effective HTML → text: drops script/style/head, breaks on block
/// tags, decodes the common entities, keeps hrefs as "text (url)".
pub fn htmlToText(gpa: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    var pending_href: ?[]const u8 = null;
    var last_was_newline = true;

    while (i < html.len) {
        if (html[i] == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse break;
            const tag_full = html[i + 1 .. close];
            i = close + 1;

            const tag_name = tagName(tag_full);

            // Skip whole containers we never want.
            inline for (.{ "script", "style", "head", "noscript", "svg", "template" }) |skip| {
                if (std.ascii.eqlIgnoreCase(tag_name, skip)) {
                    i = skipUntilClose(html, i, skip);
                    break;
                }
            }

            if (std.ascii.eqlIgnoreCase(tag_name, "a")) {
                pending_href = extractAttr(tag_full, "href");
            } else if (std.ascii.eqlIgnoreCase(tag_name, "/a")) {
                if (pending_href) |href| {
                    if (href.len > 0 and !std.mem.startsWith(u8, href, "#")) {
                        try out.appendSlice(gpa, " (");
                        try out.appendSlice(gpa, href);
                        try out.appendSlice(gpa, ")");
                    }
                    pending_href = null;
                }
            } else if (isBlockTag(tag_name)) {
                if (!last_was_newline) {
                    try out.append(gpa, '\n');
                    last_was_newline = true;
                }
            }
            continue;
        }
        // Text run until next tag.
        const next_tag = std.mem.indexOfScalarPos(u8, html, i, '<') orelse html.len;
        const text = html[i..next_tag];
        i = next_tag;

        // Collapse whitespace runs; decode entities.
        var j: usize = 0;
        while (j < text.len) {
            const ch = text[j];
            if (ch == '&') {
                if (decodeEntity(text[j..])) |de| {
                    try out.appendSlice(gpa, de.text);
                    j += de.len;
                    last_was_newline = false;
                    continue;
                }
            }
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                if (!last_was_newline and out.items.len > 0 and out.items[out.items.len - 1] != ' ') {
                    try out.append(gpa, ' ');
                }
                j += 1;
                continue;
            }
            try out.append(gpa, ch);
            last_was_newline = false;
            j += 1;
        }
    }

    // Squeeze >2 consecutive newlines.
    var squeezed: std.ArrayList(u8) = .empty;
    errdefer squeezed.deinit(gpa);
    var nl_run: usize = 0;
    for (out.items) |ch| {
        if (ch == '\n') {
            nl_run += 1;
            if (nl_run > 2) continue;
        } else nl_run = 0;
        try squeezed.append(gpa, ch);
    }
    out.deinit(gpa);
    return squeezed.toOwnedSlice(gpa);
}

/// std.ascii lost indexOfIgnoreCase in the 0.16 refactor; local replacements.
fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    return indexOfIgnoreCasePos(haystack, 0, needle);
}

fn indexOfIgnoreCasePos(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    if (start >= haystack.len or haystack.len - start < needle.len) return null;
    var i: usize = start;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn tagName(tag_full: []const u8) []const u8 {
    var end: usize = 0;
    while (end < tag_full.len) : (end += 1) {
        const ch = tag_full[end];
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') break;
    }
    return tag_full[0..end];
}

fn skipUntilClose(html: []const u8, from: usize, comptime tag: []const u8) usize {
    const needle = "</" ++ tag;
    var i = from;
    while (i < html.len) {
        const at = indexOfIgnoreCasePos(html, i, needle) orelse return html.len;
        const after = at + needle.len;
        if (after < html.len and (html[after] == '>' or html[after] == ' ')) {
            const gt = std.mem.indexOfScalarPos(u8, html, after, '>') orelse return html.len;
            return gt + 1;
        }
        i = after;
    }
    return html.len;
}

fn extractAttr(tag_full: []const u8, comptime name: []const u8) ?[]const u8 {
    const at = indexOfIgnoreCase(tag_full, name ++ "=") orelse return null;
    var rest = tag_full[at + name.len + 1 ..];
    if (rest.len == 0) return null;
    const quote = rest[0];
    if (quote == '"' or quote == '\'') {
        rest = rest[1..];
        const end = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
        return rest[0..end];
    }
    const end = std.mem.indexOfAny(u8, rest, " \t>") orelse rest.len;
    return rest[0..end];
}

fn isBlockTag(tag_name: []const u8) bool {
    const blocks = [_][]const u8{
        "p",      "/p",      "div",        "/div",        "br",      "br/",      "li",      "/li",      "ul",     "/ul",
        "ol",     "/ol",     "h1",         "/h1",         "h2",      "/h2",      "h3",      "/h3",      "h4",     "/h4",
        "h5",     "/h5",     "h6",         "/h6",         "tr",      "/tr",      "td",      "/td",      "th",     "/th",
        "table",  "/table",  "pre",        "/pre",        "section", "/section", "article", "/article", "header", "/header",
        "footer", "/footer", "blockquote", "/blockquote",
    };
    for (blocks) |b| {
        if (std.ascii.eqlIgnoreCase(tag_name, b)) return true;
    }
    return false;
}

const Entity = struct { text: []const u8, len: usize };

fn decodeEntity(s: []const u8) ?Entity {
    const table = .{
        .{ "&amp;", "&" }, .{ "&lt;", "<" },   .{ "&gt;", ">" },   .{ "&quot;", "\"" },
        .{ "&#39;", "'" }, .{ "&apos;", "'" }, .{ "&nbsp;", " " },
        .{ "&mdash;", "—" },
        .{ "&ndash;", "–" },
        .{ "&hellip;", "…" },
        .{ "&copy;", "©" },
    };
    inline for (table) |e| {
        if (std.mem.startsWith(u8, s, e[0])) return .{ .text = e[1], .len = e[0].len };
    }
    return null;
}

// ---------------------------------------------------------------- tests --
