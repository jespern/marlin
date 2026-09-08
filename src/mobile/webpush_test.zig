//! Unit tests for webpush.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in webpush.zig.

const std = @import("std");
const Io = std.Io;
const webpush = @import("webpush.zig");
const temp_dir = @import("../testing/temp_dir.zig");
const b64 = std.base64.url_safe_no_pad;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

fn decode(comptime n: usize, text: []const u8) ![n]u8 {
    var out: [n]u8 = undefined;
    try std.testing.expectEqual(n, try b64.Decoder.calcSizeForSlice(text));
    try b64.Decoder.decode(&out, text);
    return out;
}

test "RFC 8291 Appendix A vector encrypts byte-for-byte" {
    const plaintext = "When I grow up, I want to be a watermelon";
    const ua_public = try decode(65, "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4");
    const auth = try decode(16, "BTBZMqHH6r4Tts7J_aSIgg");
    const as_secret = try decode(32, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    const salt = try decode(16, "DGv6ra1nlYgDCS1FRnbzlw");

    var out: [512]u8 = undefined;
    const message = try webpush.encryptRecord(&out, ua_public, auth, as_secret, salt, plaintext);

    const expected_header = try decode(86, "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8");
    const expected_body = try decode(58, "8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ");
    try std.testing.expectEqual(expected_header.len + expected_body.len, message.len);
    try std.testing.expectEqualSlices(u8, &expected_header, message[0..86]);
    try std.testing.expectEqualSlices(u8, &expected_body, message[86..]);

    // A payload at the record boundary still fits; one byte more does not.
    var big: [webpush.record_size - 17]u8 = @splat('a');
    var big_out: [webpush.record_size + 128]u8 = undefined;
    _ = try webpush.encryptRecord(&big_out, ua_public, auth, as_secret, salt, &big);
    const bigger = big ++ [_]u8{'a'};
    try std.testing.expectError(error.PayloadTooLarge, webpush.encryptRecord(&big_out, ua_public, auth, as_secret, salt, &bigger));
}

test "VAPID authorization is a verifiable ES256 JWT with the helper's claims" {
    const gpa = std.testing.allocator;
    const d = try decode(32, "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw");
    const vapid = try webpush.Vapid.fromSecret(d);

    const header = try webpush.authorization(gpa, vapid, "web.push.apple.com", 1_788_872_825);
    defer gpa.free(header);

    try std.testing.expect(std.mem.startsWith(u8, header, "vapid t="));
    const comma = std.mem.indexOf(u8, header, ", k=").?;
    const token = header["vapid t=".len..comma];
    const key_b64 = header[comma + ", k=".len ..];
    try std.testing.expectEqualStrings(&vapid.public_b64, key_b64);

    var parts = std.mem.splitScalar(u8, token, '.');
    const jwt_header = parts.next().?;
    const jwt_claims = parts.next().?;
    const jwt_sig = parts.next().?;
    try std.testing.expect(parts.next() == null);

    var header_json: [64]u8 = undefined;
    const header_len = try b64.Decoder.calcSizeForSlice(jwt_header);
    try b64.Decoder.decode(header_json[0..header_len], jwt_header);
    try std.testing.expectEqualStrings("{\"typ\":\"JWT\",\"alg\":\"ES256\"}", header_json[0..header_len]);

    var claims_json: [256]u8 = undefined;
    const claims_len = try b64.Decoder.calcSizeForSlice(jwt_claims);
    try b64.Decoder.decode(claims_json[0..claims_len], jwt_claims);
    try std.testing.expectEqualStrings(
        "{\"aud\":\"https://web.push.apple.com\",\"exp\":1788876425,\"sub\":\"https://github.com/jespern/marlin\"}",
        claims_json[0..claims_len],
    );

    // Signature must verify as raw r||s over "<header>.<claims>".
    const raw_sig = try decode(64, jwt_sig);
    const signature = Ecdsa.Signature.fromBytes(raw_sig);
    const signed_len = jwt_header.len + 1 + jwt_claims.len;
    try signature.verify(token[0..signed_len], vapid.key_pair.public_key);
}

test "endpoint gate admits real push services and nothing else" {
    try std.testing.expectEqualStrings("web.push.apple.com", try webpush.validateEndpoint("https://web.push.apple.com/QOX"));
    _ = try webpush.validateEndpoint("https://sub.push.apple.com/x");
    _ = try webpush.validateEndpoint("https://fcm.googleapis.com/fcm/send/abc");
    _ = try webpush.validateEndpoint("https://updates.push.services.mozilla.com/wpush/v2/x");
    _ = try webpush.validateEndpoint("https://db5p.notify.windows.com/w/?token=x");

    const bad = [_][]const u8{
        "http://web.push.apple.com/QOX", // not https
        "https://evil.example.com/QOX", // foreign host
        "https://web.push.apple.com.evil.com/x", // suffix spoof
        "https://user@web.push.apple.com/x", // credentials
        "https://web.push.apple.com:8443/x", // explicit port
        "https://web.push.apple.com/x#frag", // fragment
        "", // empty
    };
    for (bad) |endpoint| {
        try std.testing.expectError(error.UnsupportedPushService, webpush.validateEndpoint(endpoint));
    }
}

test "subscription validation decodes keys and rejects malformed material" {
    const good = webpush.Subscription{
        .endpoint = "https://web.push.apple.com/test",
        .keys = .{
            .auth = "BTBZMqHH6r4Tts7J_aSIgg",
            .p256dh = "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4",
        },
    };
    const valid = try webpush.validateSubscription(good);
    try std.testing.expectEqualStrings("web.push.apple.com", valid.host);
    try std.testing.expectEqual(@as(u8, 4), valid.p256dh[0]);

    var short_auth = good;
    short_auth.keys.auth = "BTBZ";
    try std.testing.expectError(error.InvalidSubscription, webpush.validateSubscription(short_auth));

    var bad_point = good;
    bad_point.keys.p256dh = "BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
    try std.testing.expectError(error.InvalidSubscription, webpush.validateSubscription(bad_point));

    var bad_endpoint = good;
    bad_endpoint.endpoint = "https://evil.example.com/x";
    try std.testing.expectError(error.UnsupportedPushService, webpush.validateSubscription(bad_endpoint));
}

test "subscription filenames are the sha256 of the endpoint" {
    const name = webpush.subscriptionFilename("https://web.push.apple.com/test");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("https://web.push.apple.com/test", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(&hex, name[0..64]);
    try std.testing.expectEqualStrings(".subscription", name[64..]);
}

test "vapid.json round-trips: create once, reload the same key, JWK on disk" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try temp_dir.Dir.initFromProcess(gpa, io, "webpush-test");
    defer tmp.deinit();

    const created = try webpush.loadOrCreateVapid(gpa, io, tmp.path);
    const reloaded = try webpush.loadOrCreateVapid(gpa, io, tmp.path);
    try std.testing.expectEqualStrings(&created.public_b64, &reloaded.public_b64);

    // The file is the Node helper's JWK shape — a downgrade keeps working.
    const file = try std.fs.path.join(gpa, &.{ tmp.path, "vapid.json" });
    defer gpa.free(file);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(4096));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"kty\":\"EC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"crv\":\"P-256\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"d\":\"") != null);
}
