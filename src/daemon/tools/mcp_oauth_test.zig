const std = @import("std");
const oauth = @import("mcp_oauth.zig");

test "Bearer challenge params parse from quoted and bare values, other schemes ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const c = try oauth.parseChallenge(arena,
        \\Basic realm="x", Bearer error="insufficient_scope", scope="files:read files:write", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"
    );
    try std.testing.expectEqualStrings("insufficient_scope", c.@"error".?);
    try std.testing.expectEqualStrings("files:read files:write", c.scope.?);
    try std.testing.expectEqualStrings("https://mcp.example.com/.well-known/oauth-protected-resource", c.resource_metadata.?);
    const bare = try oauth.parseChallenge(arena, "Bearer resource_metadata=https://a.example/prm, scope=read");
    try std.testing.expectEqualStrings("https://a.example/prm", bare.resource_metadata.?);
    try std.testing.expectEqualStrings("read", bare.scope.?);
    const other = try oauth.parseChallenge(arena, "Basic scope=\"nope\"");
    try std.testing.expect(other.scope == null);
}

test "well-known metadata URLs follow the spec's order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prm = try oauth.resourceMetadataUrls(arena, "https://Example.com/public/mcp");
    try std.testing.expectEqual(@as(usize, 2), prm.len);
    try std.testing.expectEqualStrings("https://example.com/.well-known/oauth-protected-resource/public/mcp", prm[0]);
    try std.testing.expectEqualStrings("https://example.com/.well-known/oauth-protected-resource", prm[1]);
    const root = try oauth.resourceMetadataUrls(arena, "https://example.com/");
    try std.testing.expectEqual(@as(usize, 1), root.len);

    const plain = try oauth.authServerMetadataUrls(arena, "https://auth.example.com");
    try std.testing.expectEqualStrings("https://auth.example.com/.well-known/oauth-authorization-server", plain[0]);
    try std.testing.expectEqualStrings("https://auth.example.com/.well-known/openid-configuration", plain[1]);
    const tenant = try oauth.authServerMetadataUrls(arena, "https://auth.example.com/tenant1");
    try std.testing.expectEqual(@as(usize, 3), tenant.len);
    try std.testing.expectEqualStrings("https://auth.example.com/.well-known/oauth-authorization-server/tenant1", tenant[0]);
    try std.testing.expectEqualStrings("https://auth.example.com/.well-known/openid-configuration/tenant1", tenant[1]);
    try std.testing.expectEqualStrings("https://auth.example.com/tenant1/.well-known/openid-configuration", tenant[2]);
}

test "canonical resource lowercases scheme and host and drops a bare trailing slash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("https://mcp.linear.app/mcp", try oauth.canonicalResource(arena, "HTTPS://MCP.Linear.app/mcp#frag"));
    try std.testing.expectEqualStrings("https://mcp.example.com", try oauth.canonicalResource(arena, "https://mcp.example.com/"));
    try std.testing.expectEqualStrings("https://mcp.example.com:8443", try oauth.canonicalResource(arena, "https://mcp.example.com:8443"));
}

test "PKCE S256 matches the RFC 7636 appendix B vector" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        try oauth.codeChallenge(arena_state.allocator(), "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
    );
}

fn testFlow(iss_supported: bool) oauth.Flow {
    return .{
        .server_url = "https://mcp.example.com/mcp",
        .discovery = .{
            .resource = "https://mcp.example.com/mcp",
            .issuer = "https://auth.example.com",
            .authorization_endpoint = "https://auth.example.com/authorize",
            .token_endpoint = "https://auth.example.com/token",
            .registration_endpoint = "https://auth.example.com/register",
            .iss_parameter_supported = iss_supported,
            .scope = "read offline_access",
        },
        .registration = .{ .client_id = "abc", .client_secret = null, .token_auth_method = "none" },
        .redirect_uri = "http://127.0.0.1:5555/callback",
        .verifier = "v",
        .state = "s1",
        .authorization_url = "",
    };
}

test "the authorization URL carries PKCE, state, resource, and scope, all encoded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const flow = testFlow(false);
    const url = try oauth.authorizationUrl(arena, flow.discovery, "abc", flow.redirect_uri, "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "s1");
    try std.testing.expectEqualStrings(
        "https://auth.example.com/authorize?response_type=code&client_id=abc&redirect_uri=http%3A%2F%2F127.0.0.1%3A5555%2Fcallback&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&state=s1&resource=https%3A%2F%2Fmcp.example.com%2Fmcp&scope=read%20offline_access",
        url,
    );
}

test "callbacks check the issuer before state, and never trust a mismatched error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const flow = testFlow(true);
    try std.testing.expectEqualStrings("c0de", try oauth.callbackCode(arena, flow, "http://127.0.0.1:5555/callback?code=c0de&state=s1&iss=https%3A%2F%2Fauth.example.com"));
    try std.testing.expectError(error.IssuerMissing, oauth.callbackCode(arena, flow, "http://127.0.0.1:5555/callback?code=c0de&state=s1"));
    try std.testing.expectError(error.IssuerMismatch, oauth.callbackCode(arena, flow, "/callback?error=access_denied&state=s1&iss=https%3A%2F%2Fevil.example"));
    try std.testing.expectError(error.StateMismatch, oauth.callbackCode(arena, flow, "/callback?code=c0de&state=other&iss=https%3A%2F%2Fauth.example.com"));
    try std.testing.expectError(error.AuthorizationDenied, oauth.callbackCode(arena, flow, "/callback?error=access_denied&error_description=No+thanks&state=s1&iss=https%3A%2F%2Fauth.example.com"));
    try std.testing.expectEqualStrings("No thanks", oauth.failureDetail());
    // An AS that does not advertise iss may omit it.
    try std.testing.expectEqualStrings("c0de", try oauth.callbackCode(arena, testFlow(false), "/callback?code=c0de&state=s1"));
}

test "credentials store is 0600 and keyed by name and URL" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const path = try std.fs.path.join(arena, &.{ dir, "mcp-auth.json" });
    const creds: oauth.Credentials = .{
        .url = "https://mcp.example.com/mcp",
        .resource = "https://mcp.example.com/mcp",
        .issuer = "https://auth.example.com",
        .token_endpoint = "https://auth.example.com/token",
        .client_id = "abc",
        .access_token = "tok",
        .refresh_token = "ref",
        .expires_at_ms = 1_000_000,
    };
    try oauth.save(std.testing.allocator, io, path, "linear", creds);
    try oauth.save(std.testing.allocator, io, path, "other", creds);
    const loaded = oauth.load(arena, io, path, "linear", "https://mcp.example.com/mcp").?;
    try std.testing.expectEqualStrings("tok", loaded.access_token);
    try std.testing.expect(loaded.expired(1_000_000 - oauth.expiry_margin_ms));
    try std.testing.expect(!loaded.expired(0));
    // A changed endpoint never receives the old token.
    try std.testing.expect(oauth.load(arena, io, path, "linear", "https://elsewhere.example/mcp") == null);
    try oauth.save(std.testing.allocator, io, path, "linear", null);
    try std.testing.expect(oauth.load(arena, io, path, "linear", "https://mcp.example.com/mcp") == null);
    try std.testing.expect(oauth.load(arena, io, path, "other", "https://mcp.example.com/mcp") != null);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(stat.permissions.toMode() & 0o777)));
}
