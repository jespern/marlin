//! Web Push delivery in Zig: VAPID (RFC 8292) + aes128gcm content encoding
//! (RFC 8291), replacing the Node.js helper. On-disk state is byte-compatible
//! with the old helper — the same vapid.json JWK and <sha256>.subscription
//! files — so phones paired before the port keep receiving without
//! re-subscribing. Runs as `marlin _push <action> <input>`: a bounded
//! subprocess exactly like the old `node -e` invocation, so a hang or crash
//! still never touches the daemon (the parent enforces the hard timeout).

const std = @import("std");
const Io = std.Io;

const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const P256 = std.crypto.ecc.P256;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

pub const max_subscriptions = 32;
/// RFC 8188 single-record limit the receiving browsers enforce.
pub const record_size = 4096;
const vapid_sub = "https://github.com/jespern/marlin";

// ------------------------------------------------------------- endpoints --

/// The push services browsers actually hand out. Anything else in a
/// subscription is a lie and never sees a request from us.
pub fn endpointHostAllowed(host: []const u8) bool {
    var lower_buf: [256]u8 = undefined;
    if (host.len == 0 or host.len > lower_buf.len) return false;
    const h = std.ascii.lowerString(&lower_buf, host);
    return std.mem.eql(u8, h, "web.push.apple.com") or
        std.mem.endsWith(u8, h, ".push.apple.com") or
        std.mem.eql(u8, h, "fcm.googleapis.com") or
        std.mem.eql(u8, h, "updates.push.services.mozilla.com") or
        std.mem.endsWith(u8, h, ".notify.windows.com");
}

/// Validated endpoint host (slice into `endpoint`). Rejects everything the
/// old helper rejected: non-https, credentials, explicit ports, fragments,
/// unknown services, oversized URLs.
pub fn validateEndpoint(endpoint: []const u8) ![]const u8 {
    if (endpoint.len == 0 or endpoint.len > 4096) return error.UnsupportedPushService;
    const uri = std.Uri.parse(endpoint) catch return error.UnsupportedPushService;
    if (!std.mem.eql(u8, uri.scheme, "https")) return error.UnsupportedPushService;
    if (uri.user != null or uri.password != null or uri.port != null or uri.fragment != null)
        return error.UnsupportedPushService;
    const host = switch (uri.host orelse return error.UnsupportedPushService) {
        .raw, .percent_encoded => |h| h,
    };
    if (!endpointHostAllowed(host)) return error.UnsupportedPushService;
    return host;
}

// ------------------------------------------------------------------ state --

/// XDG_STATE_HOME (or ~/.local/state) + marlin/push — the old helper's root.
pub fn stateRoot(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("XDG_STATE_HOME")) |dir| {
        if (dir.len > 0) return std.fs.path.join(gpa, &.{ dir, "marlin", "push" });
    }
    const home = environ.get("HOME") orelse return error.MissingStateDirectory;
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "marlin", "push" });
}

/// sha256(endpoint) hex + ".subscription", the old helper's naming.
pub fn subscriptionFilename(endpoint: []const u8) [77]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(endpoint, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var name: [77]u8 = undefined;
    @memcpy(name[0..64], &hex);
    @memcpy(name[64..], ".subscription");
    return name;
}

/// 0600 exclusive write via a unique temp name. `first_wins` links (keeps an
/// existing file — VAPID keys must never be replaced once a phone has paired
/// against them); otherwise renames (subscriptions update in place).
fn writePrivateFile(io: Io, dir_path: []const u8, name: []const u8, bytes: []const u8, first_wins: bool) !void {
    var path_buf: [1024]u8 = undefined;
    var tmp_buf: [1024]u8 = undefined;
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return error.NameTooLong;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}/{s}.{x}.part", .{ dir_path, name, std.mem.readInt(u64, &nonce, .little) }) catch return error.NameTooLong;

    const file = try Io.Dir.cwd().createFile(io, tmp, .{ .exclusive = true, .permissions = @enumFromInt(0o600) });
    defer Io.Dir.cwd().deleteFile(io, tmp) catch {};
    {
        errdefer file.close(io);
        try file.writeStreamingAll(io, bytes);
    }
    file.close(io);

    if (first_wins) {
        Io.Dir.cwd().hardLink(tmp, Io.Dir.cwd(), path, io, .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        try Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, io);
    }
}

// ------------------------------------------------------------------ VAPID --

pub const Vapid = struct {
    key_pair: Ecdsa.KeyPair,
    /// base64url(0x04 || x || y) — what the browser gets as applicationServerKey.
    public_b64: [b64.Encoder.calcSize(65)]u8,

    pub fn fromSecret(d: [32]u8) !Vapid {
        const key_pair = try Ecdsa.KeyPair.fromSecretKey(try Ecdsa.SecretKey.fromBytes(d));
        var self = Vapid{ .key_pair = key_pair, .public_b64 = undefined };
        const sec1 = key_pair.public_key.toUncompressedSec1();
        _ = b64.Encoder.encode(&self.public_b64, &sec1);
        return self;
    }
};

const Jwk = struct { d: []const u8, x: []const u8 = "", y: []const u8 = "" };

fn decode32(field: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    const size = b64.Decoder.calcSizeForSlice(field) catch return error.InvalidJwk;
    if (size != 32) return error.InvalidJwk;
    b64.Decoder.decode(&out, field) catch return error.InvalidJwk;
    return out;
}

/// Read the helper-compatible vapid.json, creating it (0600, first-wins
/// atomic) on first use. The JWK's d is authoritative; x/y are re-derived.
pub fn loadOrCreateVapid(gpa: std.mem.Allocator, io: Io, root: []const u8) !Vapid {
    try Io.Dir.cwd().createDirPath(io, root);
    const file = try std.fs.path.join(gpa, &.{ root, "vapid.json" });
    defer gpa.free(file);

    for (0..2) |_| {
        if (Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(4096))) |bytes| {
            defer gpa.free(bytes);
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const jwk = std.json.parseFromSliceLeaky(Jwk, arena_state.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidJwk;
            return try Vapid.fromSecret(try decode32(jwk.d));
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const key_pair = Ecdsa.KeyPair.generate(io);
        const d = key_pair.secret_key.toBytes();
        const sec1 = key_pair.public_key.toUncompressedSec1();
        var d64: [b64.Encoder.calcSize(32)]u8 = undefined;
        var x64: [b64.Encoder.calcSize(32)]u8 = undefined;
        var y64: [b64.Encoder.calcSize(32)]u8 = undefined;
        _ = b64.Encoder.encode(&d64, &d);
        _ = b64.Encoder.encode(&x64, sec1[1..33]);
        _ = b64.Encoder.encode(&y64, sec1[33..65]);
        const json = try std.json.Stringify.valueAlloc(gpa, .{
            .kty = "EC",
            .crv = "P-256",
            .d = @as([]const u8, &d64),
            .x = @as([]const u8, &x64),
            .y = @as([]const u8, &y64),
        }, .{});
        defer gpa.free(json);
        // first-wins: if a concurrent creator landed first, loop reads theirs.
        try writePrivateFile(io, root, "vapid.json", json, true);
    }
    return error.InvalidJwk;
}

/// `vapid t=<ES256 JWT>, k=<public key>` for one push-service origin.
/// `now_s` injectable for tests; claims match the old helper exactly.
pub fn authorization(gpa: std.mem.Allocator, vapid: Vapid, host: []const u8, now_s: i64) ![]u8 {
    const header_json = "{\"typ\":\"JWT\",\"alg\":\"ES256\"}";
    var header_b64: [b64.Encoder.calcSize(header_json.len)]u8 = undefined;
    _ = b64.Encoder.encode(&header_b64, header_json);
    var aud_buf: [8 + 256]u8 = undefined;
    const aud = std.fmt.bufPrint(&aud_buf, "https://{s}", .{host}) catch return error.UnsupportedPushService;
    const claims = try std.json.Stringify.valueAlloc(gpa, .{
        .aud = aud,
        .exp = now_s + 3600,
        .sub = vapid_sub,
    }, .{});
    defer gpa.free(claims);
    const claims_b64 = try gpa.alloc(u8, b64.Encoder.calcSize(claims.len));
    defer gpa.free(claims_b64);
    _ = b64.Encoder.encode(claims_b64, claims);

    const token = try std.mem.join(gpa, ".", &.{ &header_b64, claims_b64 });
    defer gpa.free(token);
    const signature = try vapid.key_pair.sign(token, null);
    const raw = signature.toBytes(); // r||s: the IEEE-P1363 encoding JWT wants
    var sig64: [b64.Encoder.calcSize(64)]u8 = undefined;
    _ = b64.Encoder.encode(&sig64, &raw);

    return std.fmt.allocPrint(gpa, "vapid t={s}.{s}, k={s}", .{ token, sig64, vapid.public_b64 });
}

// -------------------------------------------------------------------- ECE --

/// aes128gcm ciphertext length for one payload (header + keyid + body + pad
/// delimiter + tag).
pub fn encryptedLength(payload_len: usize) usize {
    return 21 + 65 + payload_len + 1 + Aes128Gcm.tag_length;
}

/// RFC 8291 single-record encryption. The sender keypair and salt are
/// injectable so the RFC's Appendix A vector can drive the test; production
/// callers pass fresh randomness per message.
pub fn encryptRecord(
    out: []u8,
    ua_public: [65]u8,
    auth_secret: [16]u8,
    as_secret: [32]u8,
    salt: [16]u8,
    payload: []const u8,
) ![]const u8 {
    if (payload.len + 1 + Aes128Gcm.tag_length > record_size) return error.PayloadTooLarge;
    if (out.len < encryptedLength(payload.len)) return error.BufferTooSmall;

    const ua_point = P256.fromSec1(&ua_public) catch return error.InvalidSubscription;
    const as_point = P256.basePoint.mul(as_secret, .big) catch return error.InvalidSubscription;
    const as_public = as_point.toUncompressedSec1();
    const shared = ua_point.mul(as_secret, .big) catch return error.InvalidSubscription;
    const ecdh_secret = shared.affineCoordinates().x.toBytes(.big);

    // ikm = HKDF-Expand(HKDF-Extract(auth, ecdh), "WebPush: info"||0||ua||as, 32)
    var key_info: [14 + 65 + 65]u8 = undefined;
    @memcpy(key_info[0..14], "WebPush: info\x00");
    @memcpy(key_info[14..79], &ua_public);
    @memcpy(key_info[79..144], &as_public);
    var ikm: [32]u8 = undefined;
    HkdfSha256.expand(&ikm, &key_info, HkdfSha256.extract(&auth_secret, &ecdh_secret));

    const prk = HkdfSha256.extract(&salt, &ikm);
    var cek: [16]u8 = undefined;
    HkdfSha256.expand(&cek, "Content-Encoding: aes128gcm\x00", prk);
    var nonce: [12]u8 = undefined;
    HkdfSha256.expand(&nonce, "Content-Encoding: nonce\x00", prk);

    // Record header: salt(16) || rs(4, BE) || keyid len(1) || as_public(65).
    @memcpy(out[0..16], &salt);
    std.mem.writeInt(u32, out[16..20], record_size, .big);
    out[20] = 65;
    @memcpy(out[21..86], &as_public);

    // Plaintext gains the final-record pad delimiter 0x02 before sealing.
    var plain_buf: [record_size]u8 = undefined;
    @memcpy(plain_buf[0..payload.len], payload);
    plain_buf[payload.len] = 0x02;
    const plain = plain_buf[0 .. payload.len + 1];

    const total = encryptedLength(payload.len);
    const ciphertext = out[86 .. total - Aes128Gcm.tag_length];
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(ciphertext, &tag, plain, "", nonce, cek);
    @memcpy(out[total - Aes128Gcm.tag_length .. total], &tag);
    return out[0..total];
}

// ---------------------------------------------------------- subscriptions --

pub const Subscription = struct {
    endpoint: []const u8,
    keys: struct { auth: []const u8 = "", p256dh: []const u8 = "" },
};

pub const ValidSubscription = struct {
    host: []const u8, // slice into the source JSON
    endpoint: []const u8,
    auth: [16]u8,
    p256dh: [65]u8,
};

pub fn validateSubscription(s: Subscription) !ValidSubscription {
    const host = try validateEndpoint(s.endpoint);
    var out = ValidSubscription{ .host = host, .endpoint = s.endpoint, .auth = undefined, .p256dh = undefined };
    if ((b64.Decoder.calcSizeForSlice(s.keys.auth) catch return error.InvalidSubscription) != 16)
        return error.InvalidSubscription;
    b64.Decoder.decode(&out.auth, s.keys.auth) catch return error.InvalidSubscription;
    if ((b64.Decoder.calcSizeForSlice(s.keys.p256dh) catch return error.InvalidSubscription) != 65)
        return error.InvalidSubscription;
    b64.Decoder.decode(&out.p256dh, s.keys.p256dh) catch return error.InvalidSubscription;
    _ = P256.fromSec1(&out.p256dh) catch return error.InvalidSubscription;
    return out;
}

fn countSubscriptions(gpa: std.mem.Allocator, io: Io, root: []const u8) !usize {
    var names = try listSubscriptions(gpa, io, root);
    defer names.deinit(gpa);
    defer for (names.items) |n| gpa.free(n);
    return names.items.len;
}

fn listSubscriptions(gpa: std.mem.Allocator, io: Io, root: []const u8) !std.ArrayList([]u8) {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return names,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".subscription")) continue;
        if (names.items.len >= max_subscriptions) break;
        try names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    return names;
}

// --------------------------------------------------------------- delivery --

const DeliveryJob = struct {
    gpa: std.mem.Allocator,
    io: Io,
    root: []const u8,
    name: []const u8,
    vapid: Vapid,
    payload: []const u8,
    ok: bool = false,

    fn main(job: *DeliveryJob) void {
        job.ok = deliverOne(job) catch false;
    }
};

fn deliverOne(job: *DeliveryJob) !bool {
    const gpa = job.gpa;
    const io = job.io;
    const path = try std.fs.path.join(gpa, &.{ job.root, job.name });
    defer gpa.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8192));
    defer gpa.free(bytes);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const parsed = std.json.parseFromSliceLeaky(Subscription, arena_state.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch return error.InvalidSubscription;
    const sub = try validateSubscription(parsed);

    var as_secret: [32]u8 = undefined;
    io.random(&as_secret);
    var salt: [16]u8 = undefined;
    io.random(&salt);
    const body_buf = try gpa.alloc(u8, encryptedLength(job.payload.len));
    defer gpa.free(body_buf);
    const body = try encryptRecord(body_buf, sub.p256dh, sub.auth, as_secret, salt, job.payload);

    const auth_header = try authorization(gpa, job.vapid, sub.host, nowSeconds(io));
    defer gpa.free(auth_header);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var request = try client.request(.POST, try std.Uri.parse(sub.endpoint), .{
        .redirect_behavior = .not_allowed,
        .keep_alive = false,
        .headers = .{ .content_type = .{ .override = "application/octet-stream" } },
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "ttl", .value = "300" },
            .{ .name = "urgency", .value = "normal" },
            .{ .name = "content-encoding", .value = "aes128gcm" },
        },
    });
    defer request.deinit();
    try request.sendBodyComplete(@constCast(body));
    var head_buf: [4096]u8 = undefined;
    const response = try request.receiveHead(&head_buf);
    const status = response.head.status;
    if (status == .not_found or status == .gone) {
        // The phone unsubscribed; the service says so durably. Drop the file.
        Io.Dir.cwd().deleteFile(io, path) catch {};
        return true;
    }
    return @intFromEnum(status) >= 200 and @intFromEnum(status) < 300;
}

fn nowSeconds(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

// ------------------------------------------------------------ CLI actions --

/// `marlin _push <info|subscribe|unsubscribe|deliver> [input]`. Prints one
/// JSON object on success (the old helper's shapes), exits 1 on failure.
/// The parent process enforces the hard wall-clock timeout.
pub fn run(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const [:0]const u8) u8 {
    return runAction(gpa, io, environ, args) catch |err| {
        var buf: [256]u8 = undefined;
        var writer = Io.File.stderr().writer(io, &buf);
        writer.interface.print("marlin push helper failed: {t}\n", .{err}) catch {};
        writer.interface.flush() catch {};
        return 1;
    };
}

fn runAction(gpa: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, args: []const [:0]const u8) !u8 {
    if (args.len < 1) return error.MissingAction;
    const action = args[0];
    const input: []const u8 = if (args.len > 1) args[1] else "";
    const root = try stateRoot(gpa, environ);
    defer gpa.free(root);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (std.mem.eql(u8, action, "info")) {
        const vapid = try loadOrCreateVapid(gpa, io, root);
        return printJson(gpa, io, .{ .publicKey = @as([]const u8, &vapid.public_b64) });
    }
    if (std.mem.eql(u8, action, "subscribe")) {
        const parsed = std.json.parseFromSliceLeaky(Subscription, arena, input, .{ .ignore_unknown_fields = true }) catch return error.InvalidSubscription;
        const sub = try validateSubscription(parsed);
        try Io.Dir.cwd().createDirPath(io, root);
        const name = subscriptionFilename(sub.endpoint);
        var exists = true;
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, name }) catch return error.NameTooLong;
        Io.Dir.cwd().access(io, path, .{}) catch {
            exists = false;
        };
        if (!exists and try countSubscriptions(gpa, io, root) >= max_subscriptions)
            return error.SubscriptionLimitReached;
        // Canonical re-encode: stored files carry exactly what delivery needs.
        const canonical = try std.json.Stringify.valueAlloc(arena, .{
            .endpoint = parsed.endpoint,
            .keys = .{ .auth = parsed.keys.auth, .p256dh = parsed.keys.p256dh },
        }, .{});
        try writePrivateFile(io, root, &name, canonical, false);
        return printJson(gpa, io, .{ .ok = true });
    }
    if (std.mem.eql(u8, action, "unsubscribe")) {
        const parsed = std.json.parseFromSliceLeaky(struct { endpoint: []const u8 }, arena, input, .{ .ignore_unknown_fields = true }) catch return error.InvalidSubscription;
        _ = try validateEndpoint(parsed.endpoint);
        const name = subscriptionFilename(parsed.endpoint);
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, name }) catch return error.NameTooLong;
        Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return printJson(gpa, io, .{ .ok = true });
    }
    if (!std.mem.eql(u8, action, "deliver")) return error.UnknownAction;

    const vapid = try loadOrCreateVapid(gpa, io, root);
    var names = try listSubscriptions(gpa, io, root);
    defer names.deinit(gpa);
    defer for (names.items) |n| gpa.free(n);
    if (names.items.len == 0) return printJson(gpa, io, .{ .ok = true });

    // One thread per endpoint (bounded by max_subscriptions), like the old
    // helper's parallel fetches: one stuck push service cannot starve the
    // rest inside the parent's timeout window.
    const jobs = try arena.alloc(DeliveryJob, names.items.len);
    const threads = try arena.alloc(?std.Thread, names.items.len);
    for (names.items, jobs, threads) |name, *job, *thread| {
        job.* = .{ .gpa = gpa, .io = io, .root = root, .name = name, .vapid = vapid, .payload = input };
        thread.* = std.Thread.spawn(.{}, DeliveryJob.main, .{job}) catch null;
    }
    var failures: usize = 0;
    for (jobs, threads) |*job, thread| {
        if (thread) |t| t.join() else {
            job.ok = deliverOne(job) catch false;
        }
        if (!job.ok) failures += 1;
    }
    if (failures > 0) return error.PushDeliveryFailed;
    return printJson(gpa, io, .{ .ok = true });
}

fn printJson(gpa: std.mem.Allocator, io: Io, value: anytype) u8 {
    const json = std.json.Stringify.valueAlloc(gpa, value, .{}) catch return 1;
    defer gpa.free(json);
    var buf: [256]u8 = undefined;
    var writer = Io.File.stdout().writer(io, &buf);
    writer.interface.print("{s}\n", .{json}) catch return 1;
    writer.interface.flush() catch return 1;
    return 0;
}
