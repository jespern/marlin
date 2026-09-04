//! Allow-by-default hostname policy for Marlin-owned network tools.
//!
//! This is intentionally not an egress sandbox. Structured tools such as
//! `fetch` can enforce it because their destination is explicit; arbitrary
//! subprocess sockets remain outside its coverage until a proxy or platform
//! network filter exists. See docs/PERMISSIONS.md.

const std = @import("std");
const Io = std.Io;

const http = @import("provider/http.zig");

pub const Feed = struct {
    id: []const u8,
    title: []const u8,
    url: [:0]const u8,
    homepage: []const u8,
    license: []const u8,
    refresh_ns: i96,
};

/// Security-only starter catalog. Newly generated config selects the mini TIF;
/// Marlin does not select advertising/tracker lists because those create
/// unrelated developer-tool breakage. The mini feed is intentionally preferred
/// over the 2M-entry full feed for a daemon-resident first version.
pub const catalog = [_]Feed{
    .{
        .id = "hagezi-tif-mini",
        .title = "HaGeZi Threat Intelligence Feeds (mini)",
        .url = "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/tif.mini-onlydomains.txt",
        .homepage = "https://github.com/hagezi/dns-blocklists",
        .license = "GPL-3.0",
        .refresh_ns = 12 * std.time.ns_per_hour,
    },
};

pub const Settings = struct {
    /// Comma-separated catalog ids, e.g. `hagezi-tif-mini`.
    blocklists: ?[]const u8 = null,
    /// Comma-separated domains. An explicit allow overrides subscribed feeds.
    allow: ?[]const u8 = null,
    /// Comma-separated domains. Explicit deny has highest priority.
    deny: ?[]const u8 = null,
};

pub const Match = struct {
    source: []const u8,
    domain: []const u8,
};

pub const Policy = struct {
    gpa: std.mem.Allocator,
    /// Keys point into `buffers`; values index `catalog`.
    blocked: std.StringHashMapUnmanaged(u16) = .empty,
    explicit_allow: std.StringHashMapUnmanaged(void) = .empty,
    explicit_deny: std.StringHashMapUnmanaged(void) = .empty,
    buffers: std.ArrayList([]u8) = .empty,
    loaded_feeds: std.ArrayList(usize) = .empty,

    pub fn init(
        gpa: std.mem.Allocator,
        io: Io,
        environ: *const std.process.Environ.Map,
        settings: Settings,
    ) Policy {
        var self = Policy{ .gpa = gpa };

        self.addOverrides(&self.explicit_allow, settings.allow) catch |err|
            std.log.warn("network allow overrides unavailable: {t}", .{err});
        self.addOverrides(&self.explicit_deny, settings.deny) catch |err|
            std.log.warn("network deny overrides unavailable: {t}", .{err});

        const selected = settings.blocklists orelse return self;
        var ids = std.mem.splitScalar(u8, selected, ',');
        while (ids.next()) |raw_id| {
            const id = std.mem.trim(u8, raw_id, " \t\r\n");
            if (id.len == 0) continue;
            const feed_index = findFeed(id) orelse {
                std.log.warn("unknown network blocklist '{s}' (ignored)", .{id});
                continue;
            };
            self.loadFeed(io, environ, feed_index) catch |err| {
                // Default networking is allow. A missing optional feed must
                // remain visible without taking the daemon or fetches down.
                std.log.warn("network blocklist '{s}' unavailable; failing open: {t}", .{
                    catalog[feed_index].id,
                    err,
                });
            };
        }
        return self;
    }

    pub fn deinit(self: *Policy) void {
        self.blocked.deinit(self.gpa);
        self.explicit_allow.deinit(self.gpa);
        self.explicit_deny.deinit(self.gpa);
        for (self.buffers.items) |buffer| self.gpa.free(buffer);
        self.buffers.deinit(self.gpa);
        self.loaded_feeds.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn feedCount(self: *const Policy) usize {
        return self.loaded_feeds.items.len;
    }

    pub fn domainCount(self: *const Policy) usize {
        return self.blocked.count();
    }

    /// Number of rules capable of blocking a host. Explicit allows are not
    /// counted because they only subtract from feed matches.
    pub fn ruleCount(self: *const Policy) usize {
        return self.blocked.count() + self.explicit_deny.count();
    }

    /// True when any blocking rule is in effect (feed domains or explicit
    /// denies). Allow-only settings filter nothing.
    pub fn isActive(self: *const Policy) bool {
        return self.blocked.count() > 0 or self.explicit_deny.count() > 0;
    }

    /// Returns the highest-priority blocking rule for `host`. Domain rules
    /// cover the domain itself and all subdomains. Matching is ASCII
    /// case-insensitive; URL hosts arrive in punycode for IDN matching.
    pub fn checkHost(self: *const Policy, host: []const u8) ?Match {
        var normalized_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const normalized = normalizeHost(host, &normalized_buf) orelse return null;

        if (suffixMatch(void, &self.explicit_deny, normalized)) |domain| {
            return .{ .source = "explicit deny", .domain = domain };
        }
        if (suffixMatch(void, &self.explicit_allow, normalized) != null) return null;
        if (suffixMatch(u16, &self.blocked, normalized)) |domain| {
            const feed_index: usize = self.blocked.get(domain).?;
            return .{ .source = catalog[feed_index].id, .domain = domain };
        }
        return null;
    }

    pub fn checkUrl(self: *const Policy, url: []const u8) !?Match {
        const uri = try std.Uri.parse(url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and
            !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedScheme;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_buf);
        return self.checkHost(host.bytes);
    }

    pub fn addOverrides(
        self: *Policy,
        map: *std.StringHashMapUnmanaged(void),
        raw: ?[]const u8,
    ) !void {
        const value = raw orelse return;
        const buffer = try self.gpa.dupe(u8, value);
        errdefer self.gpa.free(buffer);
        lowercaseAscii(buffer);
        try self.buffers.append(self.gpa, buffer);

        var parts = std.mem.splitScalar(u8, buffer, ',');
        while (parts.next()) |part| {
            const domain = normalizeRule(part) orelse continue;
            try map.put(self.gpa, domain, {});
        }
    }

    fn loadFeed(self: *Policy, io: Io, environ: *const std.process.Environ.Map, feed_index: usize) !void {
        const feed = catalog[feed_index];
        for (self.loaded_feeds.items) |loaded| if (loaded == feed_index) return;

        const cache_path = try feedCachePath(self.gpa, io, environ, feed.id);
        defer self.gpa.free(cache_path);

        const cwd = Io.Dir.cwd();
        const stat = cwd.statFile(io, cache_path, .{}) catch null;
        const now = Io.Timestamp.now(io, .real).nanoseconds;
        const fresh = if (stat) |s|
            now >= s.mtime.nanoseconds and now - s.mtime.nanoseconds < feed.refresh_ns
        else
            false;

        var body: ?[]u8 = null;
        if (fresh) body = cwd.readFileAlloc(io, cache_path, self.gpa, .limited(max_feed_bytes)) catch null;

        if (body == null) {
            const response = http.get(self.gpa, io, environ, feed.url, max_feed_bytes, 20_000, null) catch null;
            if (response) |res| {
                defer if (res.content_type) |ct| self.gpa.free(ct);
                if (res.status >= 200 and res.status < 300) {
                    body = res.body;
                    cacheFeed(self.gpa, io, cache_path, res.body) catch |err|
                        std.log.warn("could not cache blocklist '{s}': {t}", .{ feed.id, err });
                } else {
                    self.gpa.free(res.body);
                }
            }
        }

        // A stale last-known-good list is preferable to no protection. This
        // still fails open if no valid cache has ever been obtained.
        if (body == null and stat != null) {
            body = cwd.readFileAlloc(io, cache_path, self.gpa, .limited(max_feed_bytes)) catch null;
        }
        const owned = body orelse return error.FeedUnavailable;
        errdefer self.gpa.free(owned);

        const before = self.blocked.count();
        try self.addFeedBuffer(feed_index, owned);
        try self.loaded_feeds.append(self.gpa, feed_index);
        std.log.info("network blocklist '{s}': {d} domains loaded", .{
            feed.id,
            self.blocked.count() - before,
        });
    }

    pub fn addFeedBuffer(self: *Policy, feed_index: usize, buffer: []u8) !void {
        lowercaseAscii(buffer);
        var entry_count: usize = 0;
        var counting = std.mem.splitScalar(u8, buffer, '\n');
        while (counting.next()) |line| if (parseFeedLine(line) != null) {
            entry_count += 1;
        };
        try self.blocked.ensureUnusedCapacity(self.gpa, @intCast(entry_count));
        try self.buffers.append(self.gpa, buffer);

        var lines = std.mem.splitScalar(u8, buffer, '\n');
        while (lines.next()) |raw_line| {
            const domain = parseFeedLine(raw_line) orelse continue;
            const result = self.blocked.getOrPutAssumeCapacity(domain);
            if (!result.found_existing) result.value_ptr.* = @intCast(feed_index);
        }
    }
};

const max_feed_bytes: usize = 16 * 1024 * 1024;

fn findFeed(id: []const u8) ?usize {
    for (catalog, 0..) |feed, i| {
        if (std.mem.eql(u8, feed.id, id)) return i;
    }
    return null;
}

fn normalizeHost(host: []const u8, out: *[std.Io.net.HostName.max_len]u8) ?[]const u8 {
    var trimmed = std.mem.trim(u8, host, " \t\r\n");
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '.') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0 or trimmed.len > out.len) return null;
    for (trimmed, 0..) |ch, i| {
        if (ch >= 0x80) return null; // callers should provide IDNA/punycode
        out[i] = std.ascii.toLower(ch);
    }
    return out[0..trimmed.len];
}

fn normalizeRule(raw: []const u8) ?[]const u8 {
    var domain = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.startsWith(u8, domain, "*.")) domain = domain[2..];
    while (domain.len > 0 and domain[domain.len - 1] == '.') domain = domain[0 .. domain.len - 1];
    if (!validDomain(domain)) return null;
    return domain;
}

fn parseFeedLine(raw: []const u8) ?[]const u8 {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] == '#') return null;
    if (std.mem.indexOfScalar(u8, line, '#')) |comment| line = std.mem.trimEnd(u8, line[0..comment], " \t");

    // Accept both one-domain-per-line and hosts-file feeds.
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    const first = fields.next() orelse return null;
    var candidate = first;
    if (std.mem.eql(u8, first, "0.0.0.0") or std.mem.eql(u8, first, "127.0.0.1") or
        std.mem.eql(u8, first, "::") or std.mem.eql(u8, first, "::1"))
    {
        candidate = fields.next() orelse return null;
    }
    return normalizeRule(candidate);
}

fn validDomain(domain: []const u8) bool {
    if (domain.len == 0 or domain.len > std.Io.net.HostName.max_len) return false;
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return false;
    var label_len: usize = 0;
    for (domain) |ch| {
        if (ch == '.') {
            if (label_len == 0 or label_len > 63) return false;
            label_len = 0;
            continue;
        }
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
        label_len += 1;
    }
    return label_len > 0 and label_len <= 63;
}

fn suffixMatch(comptime V: type, map: *const std.StringHashMapUnmanaged(V), host: []const u8) ?[]const u8 {
    var candidate = host;
    while (true) {
        if (map.getKey(candidate)) |stored| return stored;
        const dot = std.mem.indexOfScalar(u8, candidate, '.') orelse return null;
        candidate = candidate[dot + 1 ..];
    }
}

fn lowercaseAscii(bytes: []u8) void {
    for (bytes) |*ch| ch.* = std.ascii.toLower(ch.*);
}

fn feedCachePath(
    gpa: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    id: []const u8,
) ![]u8 {
    var cache_home_owned: ?[]u8 = null;
    defer if (cache_home_owned) |value| gpa.free(value);
    const cache_home: []const u8 = blk: {
        if (environ.get("XDG_CACHE_HOME")) |value| if (value.len > 0) break :blk value;
        const home = environ.get("HOME") orelse return error.NoHome;
        cache_home_owned = try std.fs.path.join(gpa, &.{ home, ".cache" });
        break :blk cache_home_owned.?;
    };
    const dir = try std.fs.path.join(gpa, &.{ cache_home, "marlin", "blocklists" });
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    return std.fmt.allocPrint(gpa, "{s}/{s}.txt", .{ dir, id });
}

fn cacheFeed(gpa: std.mem.Allocator, io: Io, path: []const u8, body: []const u8) !void {
    const temp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(temp);
    const cwd = Io.Dir.cwd();
    errdefer cwd.deleteFile(io, temp) catch {};
    try cwd.writeFile(io, .{ .sub_path = temp, .data = body });
    try cwd.rename(temp, cwd, path, io);
}

// ---------------------------------------------------------------- tests --
