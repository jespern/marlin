//! LAN discovery of running marlins over Bonjour (mDNS/DNS-SD).
//!
//! The daemon advertises `_marlin._tcp` through the system responder
//! (mDNSResponder via dns_sd on macOS; Avahi is the Linux follow-up): the
//! instance is `user@host` (one marlind per user, so two users' daemons on
//! one machine must stay distinct — mDNSResponder keeps a second identical
//! registration from the same host off the wire until the first goes away),
//! the target its `.local` host, and the TXT record carries the marlin
//! version, the user to ssh as, and the live session count. `marlin discover` browses for a moment, resolves each
//! instance and prints a `--remote user@host.local` target. Attaching stays
//! ssh, so discovery is visibility, not access.
//!
//! The system responder is deliberate: a homegrown one would have to share
//! port 5353 with the OS, and would lose name-conflict handling, interface
//! changes, and Bonjour Sleep Proxy — which keeps a sleeping laptop's record
//! alive and wakes it when someone connects.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const service_type = "_marlin._tcp";
pub const supported = builtin.os.tag == .macos;
/// SRV port advertised. marlin has no port of its own: ssh is the transport.
pub const ssh_port: u16 = 22;

// ---- TXT record (RFC 6763 §6): length-prefixed `key=value` strings ----

pub const Pair = struct { key: []const u8, value: []const u8 };

pub fn buildTxt(buf: []u8, pairs: []const Pair) ![]u8 {
    var n: usize = 0;
    for (pairs) |p| {
        const len = p.key.len + 1 + p.value.len;
        if (len > 255) return error.TxtEntryTooLong;
        if (n + 1 + len > buf.len) return error.NoSpaceLeft;
        buf[n] = @intCast(len);
        n += 1;
        @memcpy(buf[n..][0..p.key.len], p.key);
        n += p.key.len;
        buf[n] = '=';
        n += 1;
        @memcpy(buf[n..][0..p.value.len], p.value);
        n += p.value.len;
    }
    return buf[0..n];
}

/// The value for `key`, or null when absent or the record is malformed.
pub fn txtValue(txt: []const u8, key: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < txt.len) {
        const len: usize = txt[i];
        i += 1;
        if (i + len > txt.len) return null;
        const entry = txt[i .. i + len];
        i += len;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], key)) return entry[eq + 1 ..];
    }
    return null;
}

pub const Peer = struct {
    /// Instance name: the machine's Bonjour name ("Jesper's MacBook").
    name: []const u8,
    /// `.local` host, trailing dot stripped: what ssh resolves.
    host: []const u8,
    port: u16,
    version: []const u8,
    user: []const u8,
    /// Advertised session count, as text (whatever the daemon said).
    sessions: []const u8,
};

/// The advertised instance name: `user@host`, host without its domain.
pub fn instanceName(buf: []u8, user: []const u8, hostname: []const u8) ![:0]const u8 {
    const host = hostname[0 .. std.mem.indexOfScalar(u8, hostname, '.') orelse hostname.len];
    if (user.len == 0) return std.fmt.bufPrintZ(buf, "{s}", .{host});
    return std.fmt.bufPrintZ(buf, "{s}@{s}", .{ user, host });
}

extern "c" fn gethostname(name: [*]u8, len: usize) c_int;

pub fn stripTrailingDot(host: []const u8) []const u8 {
    return if (host.len > 0 and host[host.len - 1] == '.') host[0 .. host.len - 1] else host;
}

/// The `--remote` argument for a peer: `user@host`, or `host` alone.
pub fn remoteTarget(buf: []u8, user: []const u8, host: []const u8) ![]const u8 {
    if (user.len == 0) return try std.fmt.bufPrint(buf, "{s}", .{host});
    return try std.fmt.bufPrint(buf, "{s}@{s}", .{ user, host });
}

fn lessByName(_: void, a: Peer, b: Peer) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn padTo(w: *Io.Writer, text: []const u8, width: usize) !void {
    try w.writeAll(text);
    var i: usize = text.len;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

/// Peers as a table, sorted by name. `peers` is reordered in place.
pub fn renderTable(w: *Io.Writer, peers: []Peer) !void {
    std.mem.sort(Peer, peers, {}, lessByName);
    var name_w: usize = "NAME".len;
    var host_w: usize = "HOST".len;
    var ver_w: usize = "VERSION".len;
    for (peers) |p| {
        name_w = @max(name_w, p.name.len);
        host_w = @max(host_w, p.host.len);
        ver_w = @max(ver_w, p.version.len);
    }
    try padTo(w, "NAME", name_w + 2);
    try padTo(w, "HOST", host_w + 2);
    try padTo(w, "SESSIONS", "SESSIONS".len + 2);
    try padTo(w, "VERSION", ver_w + 2);
    try w.writeAll("ATTACH\n");
    var target: [512]u8 = undefined;
    for (peers) |p| {
        try padTo(w, p.name, name_w + 2);
        try padTo(w, p.host, host_w + 2);
        try padTo(w, p.sessions, "SESSIONS".len + 2);
        try padTo(w, p.version, ver_w + 2);
        const t = remoteTarget(&target, p.user, p.host) catch p.host;
        try w.print("marlin --remote {s}\n", .{t});
    }
}

fn nowMs(io: Io) i64 {
    const ts = Io.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

// ---- dns_sd (libSystem on macOS; libc is linked, nothing extra) ----

const dnssd = if (supported) struct {
    const Ref = opaque {};
    const Flags = u32;
    const Err = i32;
    const flag_add: Flags = 0x2;
    const flag_share_connection: Flags = 0x4000;
    const ok: Err = 0;

    const RegisterReply = *const fn (?*Ref, Flags, Err, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void;
    const BrowseReply = *const fn (?*Ref, Flags, u32, Err, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, ?*anyopaque) callconv(.c) void;
    const ResolveReply = *const fn (?*Ref, Flags, u32, Err, ?[*:0]const u8, ?[*:0]const u8, u16, u16, ?[*]const u8, ?*anyopaque) callconv(.c) void;

    extern "c" fn DNSServiceRegister(sd_ref: *?*Ref, flags: Flags, interface_index: u32, name: ?[*:0]const u8, regtype: [*:0]const u8, domain: ?[*:0]const u8, host: ?[*:0]const u8, port: u16, txt_len: u16, txt_record: ?*const anyopaque, callback: ?RegisterReply, context: ?*anyopaque) Err;
    extern "c" fn DNSServiceUpdateRecord(sd_ref: ?*Ref, record_ref: ?*anyopaque, flags: Flags, rdlen: u16, rdata: ?*const anyopaque, ttl: u32) Err;
    extern "c" fn DNSServiceBrowse(sd_ref: *?*Ref, flags: Flags, interface_index: u32, regtype: [*:0]const u8, domain: ?[*:0]const u8, callback: BrowseReply, context: ?*anyopaque) Err;
    extern "c" fn DNSServiceResolve(sd_ref: *?*Ref, flags: Flags, interface_index: u32, name: [*:0]const u8, regtype: [*:0]const u8, domain: [*:0]const u8, callback: ResolveReply, context: ?*anyopaque) Err;
    extern "c" fn DNSServiceCreateConnection(sd_ref: *?*Ref) Err;
    extern "c" fn DNSServiceRefSockFD(sd_ref: ?*Ref) c_int;
    extern "c" fn DNSServiceProcessResult(sd_ref: ?*Ref) Err;
    extern "c" fn DNSServiceRefDeallocate(sd_ref: ?*Ref) void;
} else struct {};

/// The daemon's side: register once, update the TXT as sessions change,
/// service the responder's socket on a small thread until stop().
pub const Advertiser = if (supported) struct {
    io: Io = undefined,
    mutex: Io.Mutex = .init,
    ref: ?*dnssd.Ref = null,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    version: []const u8 = "",
    user: []const u8 = "",
    sessions: usize = 0,
    txt_buf: [512]u8 = undefined,
    name_buf: [256]u8 = undefined,

    pub fn start(self: *Advertiser, io: Io, version: []const u8, user: []const u8, sessions: usize) !void {
        self.io = io;
        self.version = version;
        self.user = user;
        self.sessions = sessions;
        const txt = try self.record();
        var ref: ?*dnssd.Ref = null;
        // Instance `user@host`; if the hostname is unavailable, null lets the
        // responder use the machine's own Bonjour name. host=null: this host.
        var host_buf: [256]u8 = undefined;
        const hostname: []const u8 = if (gethostname(&host_buf, host_buf.len) == 0) std.mem.sliceTo(&host_buf, 0) else "";
        const name: ?[:0]const u8 = if (hostname.len > 0) (instanceName(&self.name_buf, user, hostname) catch null) else null;
        const err = dnssd.DNSServiceRegister(&ref, 0, 0, if (name) |n| n.ptr else null, service_type, null, null, std.mem.nativeToBig(u16, ssh_port), @intCast(txt.len), txt.ptr, registerReply, self);
        if (err != dnssd.ok) {
            std.log.warn("discovery: DNSServiceRegister failed ({d})", .{err});
            return error.RegisterFailed;
        }
        self.ref = ref;
        self.thread = try std.Thread.spawn(.{}, serviceLoop, .{self});
    }

    fn record(self: *Advertiser) ![]u8 {
        var count: [24]u8 = undefined;
        const c = try std.fmt.bufPrint(&count, "{d}", .{self.sessions});
        return buildTxt(&self.txt_buf, &.{
            .{ .key = "v", .value = self.version },
            .{ .key = "user", .value = self.user },
            .{ .key = "sessions", .value = c },
        });
    }

    /// Live session count changed: rewrite the TXT in place (ttl 0 = default).
    pub fn setSessions(self: *Advertiser, n: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.ref == null or n == self.sessions) return;
        self.sessions = n;
        const t = self.record() catch return;
        _ = dnssd.DNSServiceUpdateRecord(self.ref, null, 0, @intCast(t.len), t.ptr, 0);
    }

    pub fn stop(self: *Advertiser) void {
        self.stopping.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.ref) |r| dnssd.DNSServiceRefDeallocate(r);
        self.ref = null;
    }

    fn serviceLoop(self: *Advertiser) void {
        const fd = dnssd.DNSServiceRefSockFD(self.ref);
        while (!self.stopping.load(.acquire)) {
            var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const n = std.posix.poll(&fds, 500) catch break;
            if (n == 0) continue;
            self.mutex.lockUncancelable(self.io);
            const err = dnssd.DNSServiceProcessResult(self.ref);
            self.mutex.unlock(self.io);
            if (err != dnssd.ok) break;
        }
    }

    fn registerReply(_: ?*dnssd.Ref, _: dnssd.Flags, err: dnssd.Err, name: ?[*:0]const u8, _: ?[*:0]const u8, _: ?[*:0]const u8, _: ?*anyopaque) callconv(.c) void {
        if (err != dnssd.ok) {
            std.log.warn("discovery: registration failed ({d})", .{err});
            return;
        }
        const n = if (name) |p| std.mem.span(p) else "?";
        std.log.info("discovery: advertising \"{s}\" as {s}", .{ n, service_type });
    }
} else struct {
    pub fn start(_: *Advertiser, _: Io, _: []const u8, _: []const u8, _: usize) !void {
        return error.Unsupported;
    }
    pub fn setSessions(_: *Advertiser, _: usize) void {}
    pub fn stop(_: *Advertiser) void {}
};

const Pending = if (supported) struct {
    name: [:0]const u8,
    domain: [:0]const u8,
    iface: u32,
    ref: ?*dnssd.Ref = null,
    done: bool = false,
    browser: *Browser,
} else struct {};
const Browser = if (supported) struct {
    arena: std.mem.Allocator,
    pending: std.ArrayList(*Pending) = .empty,
    peers: std.ArrayList(Peer) = .empty,
    last_add_ms: i64,
    io: Io,

    fn browseReply(_: ?*dnssd.Ref, flags: dnssd.Flags, iface: u32, err: dnssd.Err, name: ?[*:0]const u8, _: ?[*:0]const u8, domain: ?[*:0]const u8, ctx: ?*anyopaque) callconv(.c) void {
        const self: *Browser = @ptrCast(@alignCast(ctx orelse return));
        if (err != dnssd.ok or flags & dnssd.flag_add == 0) return;
        const n = std.mem.span(name orelse return);
        for (self.pending.items) |p| if (std.mem.eql(u8, p.name, n)) return; // same instance, another interface
        const p = self.arena.create(Pending) catch return;
        p.* = .{
            .name = self.arena.dupeZ(u8, n) catch return,
            .domain = self.arena.dupeZ(u8, std.mem.span(domain orelse "local.")) catch return,
            .iface = iface,
            .browser = self,
        };
        self.pending.append(self.arena, p) catch return;
        self.last_add_ms = nowMs(self.io);
    }

    fn resolveReply(_: ?*dnssd.Ref, _: dnssd.Flags, _: u32, err: dnssd.Err, _: ?[*:0]const u8, host: ?[*:0]const u8, port: u16, txt_len: u16, txt: ?[*]const u8, ctx: ?*anyopaque) callconv(.c) void {
        const p: *Pending = @ptrCast(@alignCast(ctx orelse return));
        if (p.done) return;
        p.done = true;
        if (err != dnssd.ok) return;
        const self = p.browser;
        const record: []const u8 = if (txt) |t| t[0..txt_len] else "";
        const dupe = struct {
            fn f(a: std.mem.Allocator, s: ?[]const u8) []const u8 {
                return a.dupe(u8, s orelse "") catch "";
            }
        }.f;
        self.peers.append(self.arena, .{
            .name = p.name,
            .host = stripTrailingDot(dupe(self.arena, if (host) |h| std.mem.span(h) else null)),
            .port = std.mem.bigToNative(u16, port),
            .version = dupe(self.arena, txtValue(record, "v")),
            .user = dupe(self.arena, txtValue(record, "user")),
            .sessions = dupe(self.arena, txtValue(record, "sessions")),
        }) catch return;
    }
} else struct {};

/// The client's side: browse for up to `wait_ms`, resolve every instance,
/// return the peers (strings owned by `arena`). Returns early once every
/// instance seen has resolved and nothing new has appeared for half a second.
pub fn browse(arena: std.mem.Allocator, io: Io, wait_ms: u32) ![]Peer {
    if (!supported) return error.Unsupported;
    var b = Browser{ .arena = arena, .last_add_ms = nowMs(io), .io = io };
    var conn: ?*dnssd.Ref = null;
    if (dnssd.DNSServiceCreateConnection(&conn) != dnssd.ok) return error.BrowseFailed;
    defer dnssd.DNSServiceRefDeallocate(conn); // also frees the subordinate refs
    var browse_ref = conn;
    if (dnssd.DNSServiceBrowse(&browse_ref, dnssd.flag_share_connection, 0, service_type, null, Browser.browseReply, &b) != dnssd.ok) return error.BrowseFailed;
    const fd = dnssd.DNSServiceRefSockFD(conn);
    const started = nowMs(io);
    const deadline = started + wait_ms;
    while (true) {
        const now = nowMs(io);
        if (now >= deadline) break;
        var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, @intCast(@min(deadline - now, 100))) catch break;
        if (n > 0 and dnssd.DNSServiceProcessResult(conn) != dnssd.ok) break;
        var all_done = b.pending.items.len > 0;
        for (b.pending.items) |p| {
            if (p.ref == null and !p.done) {
                var r = conn;
                if (dnssd.DNSServiceResolve(&r, dnssd.flag_share_connection, p.iface, p.name.ptr, service_type, p.domain.ptr, Browser.resolveReply, p) == dnssd.ok) p.ref = r else p.done = true;
            }
            if (!p.done) all_done = false;
        }
        if (all_done and nowMs(io) - b.last_add_ms >= 500) break;
    }
    return b.peers.items;
}
