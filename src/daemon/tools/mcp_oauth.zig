//! OAuth for remote MCP servers, client side, per the MCP authorization
//! spec (2026-07-28): a 401 challenge leads to Protected Resource Metadata
//! (RFC 9728), then Authorization Server Metadata (RFC 8414 / OIDC), then
//! Dynamic Client Registration (RFC 7591) as a native app, then an
//! authorization-code grant with PKCE (S256), `resource` (RFC 8707), and the
//! RFC 9207 issuer check on the callback. Tokens persist per server in a
//! 0600 file and refresh on expiry.

const std = @import("std");
const Io = std.Io;
const http = @import("../provider/http.zig");

pub const metadata_limit: usize = 256 * 1024;
pub const request_timeout_ms: i64 = 20_000;
/// Refresh this long before the server says the token expires.
pub const expiry_margin_ms: i64 = 60_000;
pub const client_name = "Marlin";

// ------------------------------------------------------------ challenge --

/// The parameters of a `WWW-Authenticate: Bearer …` challenge.
pub const Challenge = struct {
    resource_metadata: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

/// Parse the Bearer challenge's auth-params (RFC 9110 §11.6.1): `key=token`
/// or `key="quoted string"`, comma separated. Other schemes are skipped.
pub fn parseChallenge(arena: std.mem.Allocator, header: []const u8) !Challenge {
    var out: Challenge = .{};
    var i: usize = 0;
    var in_bearer = false;
    while (i < header.len) {
        while (i < header.len and (header[i] == ' ' or header[i] == ',' or header[i] == '\t')) i += 1;
        const start = i;
        while (i < header.len and header[i] != '=' and header[i] != ' ' and header[i] != ',') i += 1;
        const word = header[start..i];
        if (word.len == 0) break;
        if (i >= header.len or header[i] != '=') {
            // A scheme name starts a new challenge.
            in_bearer = std.ascii.eqlIgnoreCase(word, "Bearer");
            continue;
        }
        i += 1; // '='
        var value: std.ArrayList(u8) = .empty;
        if (i < header.len and header[i] == '"') {
            i += 1;
            while (i < header.len and header[i] != '"') : (i += 1) {
                if (header[i] == '\\' and i + 1 < header.len) i += 1;
                try value.append(arena, header[i]);
            }
            i += 1; // closing quote
        } else {
            while (i < header.len and header[i] != ',' and header[i] != ' ') : (i += 1) try value.append(arena, header[i]);
        }
        if (!in_bearer) continue;
        if (std.ascii.eqlIgnoreCase(word, "resource_metadata")) out.resource_metadata = value.items;
        if (std.ascii.eqlIgnoreCase(word, "scope")) out.scope = value.items;
        if (std.ascii.eqlIgnoreCase(word, "error")) out.@"error" = value.items;
    }
    return out;
}

// ------------------------------------------------------------------ URLs --

/// The MCP server's canonical URI for `resource`: lowercase scheme and host,
/// no fragment, no trailing slash on an empty path.
pub fn canonicalResource(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var out: std.ArrayList(u8) = .empty;
    for (uri.scheme) |c| try out.append(arena, std.ascii.toLower(c));
    try out.appendSlice(arena, "://");
    for (try componentRaw(arena, uri.host orelse return error.InvalidUrl)) |c| try out.append(arena, std.ascii.toLower(c));
    if (uri.port) |port| try out.print(arena, ":{d}", .{port});
    const path = try componentRaw(arena, uri.path);
    if (!std.mem.eql(u8, path, "/")) try out.appendSlice(arena, path);
    if (uri.query) |query| {
        try out.append(arena, '?');
        try out.appendSlice(arena, try componentRaw(arena, query));
    }
    return out.items;
}

fn componentRaw(arena: std.mem.Allocator, component: std.Uri.Component) ![]const u8 {
    return switch (component) {
        .raw => |raw| raw,
        .percent_encoded => |encoded| arena.dupe(u8, encoded),
    };
}

fn origin(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var out: std.ArrayList(u8) = .empty;
    for (uri.scheme) |c| try out.append(arena, std.ascii.toLower(c));
    try out.appendSlice(arena, "://");
    for (try componentRaw(arena, uri.host orelse return error.InvalidUrl)) |c| try out.append(arena, std.ascii.toLower(c));
    if (uri.port) |port| try out.print(arena, ":{d}", .{port});
    return out.items;
}

fn pathOf(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    const path = try componentRaw(arena, uri.path);
    return if (std.mem.eql(u8, path, "/")) "" else std.mem.trimEnd(u8, path, "/");
}

/// Protected Resource Metadata candidates, in spec order: the path-aware
/// well-known URI (skipped when the endpoint is the root), then the root.
pub fn resourceMetadataUrls(arena: std.mem.Allocator, server_url: []const u8) ![]const []const u8 {
    const base = try origin(arena, server_url);
    const path = try pathOf(arena, server_url);
    var out: std.ArrayList([]const u8) = .empty;
    if (path.len > 0) try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource{s}", .{ base, path }));
    try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-protected-resource", .{base}));
    return out.items;
}

/// Authorization Server Metadata candidates, in spec order: RFC 8414 then
/// OIDC, path-inserted forms first and the OIDC path-appended form last.
pub fn authServerMetadataUrls(arena: std.mem.Allocator, issuer: []const u8) ![]const []const u8 {
    const base = try origin(arena, issuer);
    const path = try pathOf(arena, issuer);
    var out: std.ArrayList([]const u8) = .empty;
    if (path.len == 0) {
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server", .{base}));
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration", .{base}));
    } else {
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/oauth-authorization-server{s}", .{ base, path }));
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}/.well-known/openid-configuration{s}", .{ base, path }));
        try out.append(arena, try std.fmt.allocPrint(arena, "{s}{s}/.well-known/openid-configuration", .{ base, path }));
    }
    return out.items;
}

/// Authorization endpoints must be HTTPS; plain HTTP only on this machine.
pub fn secureEndpoint(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return true;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return false;
    const host = switch (uri.host orelse return false) {
        inline else => |h| h,
    };
    return std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
}

/// application/x-www-form-urlencoded / query component encoding: every byte
/// outside the RFC 3986 unreserved set is percent-encoded.
pub fn appendFormValue(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~')
            try out.append(arena, c)
        else
            try out.print(arena, "%{X:0>2}", .{c});
    }
}

pub fn appendFormPair(arena: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    if (out.items.len > 0 and out.items[out.items.len - 1] != '?') try out.append(arena, '&');
    try out.appendSlice(arena, key);
    try out.append(arena, '=');
    try appendFormValue(arena, out, value);
}

/// Read one query parameter from a callback URL (or a bare query string),
/// percent-decoded with `+` as space.
pub fn queryParam(arena: std.mem.Allocator, url: []const u8, key: []const u8) !?[]const u8 {
    const q_start = if (std.mem.indexOfScalar(u8, url, '?')) |q| q + 1 else 0;
    const q_end = std.mem.indexOfScalarPos(u8, url, q_start, '#') orelse url.len;
    var pairs = std.mem.splitScalar(u8, url[q_start..q_end], '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = eq + 1;
        while (i < pair.len) : (i += 1) {
            const c = pair[i];
            if (c == '+') {
                try out.append(arena, ' ');
            } else if (c == '%' and i + 2 < pair.len) {
                const byte = std.fmt.parseInt(u8, pair[i + 1 .. i + 3], 16) catch return error.InvalidCallback;
                try out.append(arena, byte);
                i += 2;
            } else try out.append(arena, c);
        }
        return out.items;
    }
    return null;
}

// --------------------------------------------------------------- crypto --

pub fn randomToken(arena: std.mem.Allocator, io: Io, bytes: usize) ![]const u8 {
    var raw: [64]u8 = undefined;
    std.debug.assert(bytes <= raw.len);
    io.random(raw[0..bytes]);
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(bytes));
    _ = encoder.encode(out, raw[0..bytes]);
    return out;
}

/// RFC 7636 S256: BASE64URL(SHA256(ASCII(code_verifier))).
pub fn codeChallenge(arena: std.mem.Allocator, verifier: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, encoder.calcSize(digest.len));
    _ = encoder.encode(out, &digest);
    return out;
}

// --------------------------------------------------------------- store --

/// Everything needed to call and refresh one server, persisted by name and
/// bound to its URL so a changed endpoint never receives an old token.
pub const Credentials = struct {
    url: []const u8,
    resource: []const u8,
    issuer: []const u8,
    token_endpoint: []const u8,
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    /// `client_secret_basic`, `client_secret_post`, or `none`.
    token_auth_method: []const u8 = "none",
    scope: ?[]const u8 = null,
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    /// Wall-clock ms; null when the server did not say.
    expires_at_ms: ?i64 = null,

    pub fn expired(self: Credentials, now_ms: i64) bool {
        const at = self.expires_at_ms orelse return false;
        return now_ms + expiry_margin_ms >= at;
    }
};

const StoreFile = struct {
    version: u32 = 1,
    servers: []const Entry = &.{},
    const Entry = struct { name: []const u8, credentials: Credentials };
};

pub fn storePath(gpa: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    const dir = try @import("../../core/credentials.zig").configDir(gpa, environ);
    defer gpa.free(dir);
    return std.fs.path.join(gpa, &.{ dir, "mcp-auth.json" });
}

/// Load the credentials for `name` if they were issued for `url`.
pub fn load(arena: std.mem.Allocator, io: Io, path: []const u8, name: []const u8, url: []const u8) ?Credentials {
    const file = readStore(arena, io, path) catch return null;
    for (file.servers) |entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (!std.mem.eql(u8, entry.credentials.url, url)) return null;
        return entry.credentials;
    }
    return null;
}

fn readStore(arena: std.mem.Allocator, io: Io, path: []const u8) !StoreFile {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(StoreFile, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

/// Servers refresh on their own threads; their read-modify-write of the
/// shared file must not interleave.
var store_mutex: Io.Mutex = .init;

/// Replace (or with null, drop) one server's credentials. The file is
/// created 0600 before any secret is written, then renamed into place.
pub fn save(gpa: std.mem.Allocator, io: Io, path: []const u8, name: []const u8, credentials: ?Credentials) !void {
    store_mutex.lockUncancelable(io);
    defer store_mutex.unlock(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const current = readStore(arena, io, path) catch StoreFile{};
    var entries: std.ArrayList(StoreFile.Entry) = .empty;
    for (current.servers) |entry| if (!std.mem.eql(u8, entry.name, name)) try entries.append(arena, entry);
    if (credentials) |c| try entries.append(arena, .{ .name = name, .credentials = c });
    const json = try std.json.Stringify.valueAlloc(arena, StoreFile{ .servers = entries.items }, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });

    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    {
        const file = try Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        try file.writeStreamingAll(io, json);
    }
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), path, io);
}

// ----------------------------------------------------------- discovery --

pub const Discovery = struct {
    resource: []const u8,
    issuer: []const u8,
    authorization_endpoint: []const u8,
    token_endpoint: []const u8,
    registration_endpoint: ?[]const u8,
    iss_parameter_supported: bool,
    scope: ?[]const u8,
};

const Fetcher = struct {
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    cancel: ?*std.atomic.Value(bool) = null,

    fn getJson(self: Fetcher, url: []const u8) !?std.json.Value {
        if (!secureEndpoint(url)) return error.InsecureAuthEndpoint;
        const result = try http.exchange(self.client, self.gpa, .{
            .url = url,
            .accept = "application/json",
            .max_bytes = metadata_limit,
            .timeout_ms = request_timeout_ms,
            .cancel = self.cancel,
        });
        defer result.deinit(self.gpa);
        if (result.status != 200) return null;
        const value = std.json.parseFromSliceLeaky(std.json.Value, self.arena, result.body, .{ .allocate = .alloc_always }) catch return null;
        return if (value == .object) value else null;
    }
};

fn str(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn strings(arena: std.mem.Allocator, value: std.json.Value, key: []const u8) ![]const []const u8 {
    if (value != .object) return &.{};
    const v = value.object.get(key) orelse return &.{};
    if (v != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items) |item| if (item == .string) try out.append(arena, item.string);
    return out.items;
}

fn contains(list: []const []const u8, want: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, want)) return true;
    return false;
}

/// Resolve the authorization server for `server_url` from its challenge.
pub fn discover(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    server_url: []const u8,
    challenge: Challenge,
) !Discovery {
    const fetcher: Fetcher = .{ .client = client, .gpa = gpa, .arena = arena };
    var prm: ?std.json.Value = null;
    if (challenge.resource_metadata) |url| prm = try fetcher.getJson(url);
    if (prm == null) for (try resourceMetadataUrls(arena, server_url)) |url| {
        prm = fetcher.getJson(url) catch null;
        if (prm != null) break;
    };
    // Servers predating RFC 9728 metadata act as their own authorization
    // server at their origin (MCP 2025-03-26).
    const issuer = if (prm) |doc| blk: {
        const servers = try strings(arena, doc, "authorization_servers");
        if (servers.len == 0) return error.NoAuthorizationServer;
        break :blk servers[0];
    } else try origin(arena, server_url);

    var as_meta: ?std.json.Value = null;
    for (try authServerMetadataUrls(arena, issuer)) |url| {
        const doc = (fetcher.getJson(url) catch null) orelse continue;
        // The metadata must name exactly the issuer it was fetched for.
        if (!std.mem.eql(u8, str(doc, "issuer") orelse "", issuer)) continue;
        as_meta = doc;
        break;
    }
    const meta = as_meta orelse return error.NoAuthorizationServerMetadata;
    if (!contains(try strings(arena, meta, "code_challenge_methods_supported"), "S256")) return error.PkceUnsupported;
    const authorization_endpoint = str(meta, "authorization_endpoint") orelse return error.NoAuthorizationEndpoint;
    const token_endpoint = str(meta, "token_endpoint") orelse return error.NoTokenEndpoint;
    if (!secureEndpoint(authorization_endpoint) or !secureEndpoint(token_endpoint)) return error.InsecureAuthEndpoint;
    const registration = str(meta, "registration_endpoint");
    if (registration) |url| if (!secureEndpoint(url)) return error.InsecureAuthEndpoint;

    // Scope: the challenge is authoritative; else everything the resource
    // advertises. Ask for offline_access when offered so a refresh token
    // keeps the login alive.
    var scope: ?[]const u8 = challenge.scope;
    if (scope == null) if (prm) |doc| {
        const supported = try strings(arena, doc, "scopes_supported");
        if (supported.len > 0) scope = try std.mem.join(arena, " ", supported);
    };
    if (contains(try strings(arena, meta, "scopes_supported"), "offline_access")) {
        if (scope) |s| {
            var words = std.mem.tokenizeScalar(u8, s, ' ');
            const has = while (words.next()) |w| {
                if (std.mem.eql(u8, w, "offline_access")) break true;
            } else false;
            if (!has) scope = try std.fmt.allocPrint(arena, "{s} offline_access", .{s});
        } else scope = "offline_access";
    }

    const iss_supported = if (meta.object.get("authorization_response_iss_parameter_supported")) |v| v == .bool and v.bool else false;
    return .{
        .resource = try canonicalResource(arena, server_url),
        .issuer = issuer,
        .authorization_endpoint = authorization_endpoint,
        .token_endpoint = token_endpoint,
        .registration_endpoint = registration,
        .iss_parameter_supported = iss_supported,
        .scope = scope,
    };
}

// --------------------------------------------------------- registration --

pub const Registration = struct {
    client_id: []const u8,
    client_secret: ?[]const u8,
    token_auth_method: []const u8,
};

/// RFC 7591 registration as a native public client for one redirect URI.
pub fn register(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    endpoint: []const u8,
    redirect_uri: []const u8,
    scope: ?[]const u8,
) !Registration {
    const body = try std.json.Stringify.valueAlloc(arena, .{
        .client_name = client_name,
        .redirect_uris = &[_][]const u8{redirect_uri},
        .grant_types = &[_][]const u8{ "authorization_code", "refresh_token" },
        .response_types = &[_][]const u8{"code"},
        .token_endpoint_auth_method = "none",
        .application_type = "native",
        .scope = scope,
    }, .{ .emit_null_optional_fields = false });
    const result = try http.exchange(client, gpa, .{
        .method = .POST,
        .url = endpoint,
        .content_type = "application/json",
        .accept = "application/json",
        .body = body,
        .max_bytes = metadata_limit,
        .timeout_ms = request_timeout_ms,
    });
    defer result.deinit(gpa);
    if (result.status != 200 and result.status != 201) {
        lastDetail(result.body);
        return error.RegistrationRejected;
    }
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, result.body, .{ .allocate = .alloc_always }) catch return error.InvalidRegistration;
    return .{
        .client_id = try arena.dupe(u8, str(doc, "client_id") orelse return error.InvalidRegistration),
        .client_secret = if (str(doc, "client_secret")) |s| try arena.dupe(u8, s) else null,
        .token_auth_method = try arena.dupe(u8, str(doc, "token_endpoint_auth_method") orelse
            (if (str(doc, "client_secret") != null) "client_secret_basic" else "none")),
    };
}

// ---------------------------------------------------------------- flow --

/// One authorization in flight: everything the callback needs to finish it.
pub const Flow = struct {
    server_url: []const u8,
    discovery: Discovery,
    registration: Registration,
    redirect_uri: []const u8,
    verifier: []const u8,
    state: []const u8,
    authorization_url: []const u8,
};

pub fn begin(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    io: Io,
    server_url: []const u8,
    challenge: Challenge,
    redirect_uri: []const u8,
) !Flow {
    const found = try discover(client, gpa, arena, server_url, challenge);
    const endpoint = found.registration_endpoint orelse return error.NoClientRegistration;
    const registration = try register(client, gpa, arena, endpoint, redirect_uri, found.scope);
    const verifier = try randomToken(arena, io, 32);
    const state = try randomToken(arena, io, 16);
    return .{
        .server_url = server_url,
        .discovery = found,
        .registration = registration,
        .redirect_uri = redirect_uri,
        .verifier = verifier,
        .state = state,
        .authorization_url = try authorizationUrl(arena, found, registration.client_id, redirect_uri, verifier, state),
    };
}

pub fn authorizationUrl(
    arena: std.mem.Allocator,
    found: Discovery,
    client_id: []const u8,
    redirect_uri: []const u8,
    verifier: []const u8,
    state: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, found.authorization_endpoint);
    try out.append(arena, if (std.mem.indexOfScalar(u8, found.authorization_endpoint, '?') == null) '?' else '&');
    try appendFormPair(arena, &out, "response_type", "code");
    try appendFormPair(arena, &out, "client_id", client_id);
    try appendFormPair(arena, &out, "redirect_uri", redirect_uri);
    try appendFormPair(arena, &out, "code_challenge", try codeChallenge(arena, verifier));
    try appendFormPair(arena, &out, "code_challenge_method", "S256");
    try appendFormPair(arena, &out, "state", state);
    try appendFormPair(arena, &out, "resource", found.resource);
    if (found.scope) |scope| try appendFormPair(arena, &out, "scope", scope);
    return out.items;
}

/// Validate a callback against its flow and return the authorization code.
/// The issuer is checked before anything in the response is trusted, and a
/// mismatched response's error text is never shown (RFC 9207).
pub fn callbackCode(arena: std.mem.Allocator, flow: Flow, callback_url: []const u8) ![]const u8 {
    const iss = try queryParam(arena, callback_url, "iss");
    if (iss) |value| {
        if (!std.mem.eql(u8, value, flow.discovery.issuer)) return error.IssuerMismatch;
    } else if (flow.discovery.iss_parameter_supported) return error.IssuerMissing;
    const state = (try queryParam(arena, callback_url, "state")) orelse return error.StateMismatch;
    if (!std.mem.eql(u8, state, flow.state)) return error.StateMismatch;
    if (try queryParam(arena, callback_url, "error")) |code| {
        const description = (try queryParam(arena, callback_url, "error_description")) orelse code;
        lastDetail(description);
        return error.AuthorizationDenied;
    }
    return (try queryParam(arena, callback_url, "code")) orelse error.MissingCode;
}

pub fn finish(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    now_ms: i64,
    flow: Flow,
    callback_url: []const u8,
) !Credentials {
    const code = try callbackCode(arena, flow, callback_url);
    const base: Credentials = .{
        .url = flow.server_url,
        .resource = flow.discovery.resource,
        .issuer = flow.discovery.issuer,
        .token_endpoint = flow.discovery.token_endpoint,
        .client_id = flow.registration.client_id,
        .client_secret = flow.registration.client_secret,
        .token_auth_method = flow.registration.token_auth_method,
        .scope = flow.discovery.scope,
        .access_token = "",
    };
    var form: std.ArrayList(u8) = .empty;
    try appendFormPair(arena, &form, "grant_type", "authorization_code");
    try appendFormPair(arena, &form, "code", code);
    try appendFormPair(arena, &form, "redirect_uri", flow.redirect_uri);
    try appendFormPair(arena, &form, "code_verifier", flow.verifier);
    try appendFormPair(arena, &form, "resource", flow.discovery.resource);
    return tokenRequest(client, gpa, arena, now_ms, base, &form);
}

/// Exchange the refresh token for a new access token. A server that rotates
/// refresh tokens returns a new one; otherwise the old one stays.
pub fn refresh(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    now_ms: i64,
    current: Credentials,
) !Credentials {
    const token = current.refresh_token orelse return error.NoRefreshToken;
    var form: std.ArrayList(u8) = .empty;
    try appendFormPair(arena, &form, "grant_type", "refresh_token");
    try appendFormPair(arena, &form, "refresh_token", token);
    try appendFormPair(arena, &form, "resource", current.resource);
    return tokenRequest(client, gpa, arena, now_ms, current, &form);
}

fn tokenRequest(
    client: *std.http.Client,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    now_ms: i64,
    base: Credentials,
    form: *std.ArrayList(u8),
) !Credentials {
    if (!secureEndpoint(base.token_endpoint)) return error.InsecureAuthEndpoint;
    var headers: std.ArrayList(std.http.Header) = .empty;
    if (base.client_secret != null and std.mem.eql(u8, base.token_auth_method, "client_secret_basic")) {
        // RFC 6749 §2.3.1: form-encode each part before base64.
        var pair: std.ArrayList(u8) = .empty;
        try appendFormValue(arena, &pair, base.client_id);
        try pair.append(arena, ':');
        try appendFormValue(arena, &pair, base.client_secret.?);
        const encoder = std.base64.standard.Encoder;
        const encoded = try arena.alloc(u8, encoder.calcSize(pair.items.len));
        _ = encoder.encode(encoded, pair.items);
        try headers.append(arena, .{ .name = "Authorization", .value = try std.fmt.allocPrint(arena, "Basic {s}", .{encoded}) });
    } else {
        try appendFormPair(arena, form, "client_id", base.client_id);
        if (base.client_secret) |secret| try appendFormPair(arena, form, "client_secret", secret);
    }
    const result = try http.exchange(client, gpa, .{
        .method = .POST,
        .url = base.token_endpoint,
        .headers = headers.items,
        .content_type = "application/x-www-form-urlencoded",
        .accept = "application/json",
        .body = form.items,
        .max_bytes = metadata_limit,
        .timeout_ms = request_timeout_ms,
    });
    defer result.deinit(gpa);
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, result.body, .{ .allocate = .alloc_always }) catch {
        lastDetail(result.body);
        return error.InvalidTokenResponse;
    };
    if (result.status != 200) {
        lastDetail(str(doc, "error_description") orelse str(doc, "error") orelse result.body);
        return error.TokenRejected;
    }
    const access = str(doc, "access_token") orelse return error.InvalidTokenResponse;
    if (str(doc, "token_type")) |kind| if (!std.ascii.eqlIgnoreCase(kind, "bearer")) return error.UnsupportedTokenType;
    var out = base;
    out.access_token = try arena.dupe(u8, access);
    if (str(doc, "refresh_token")) |token| out.refresh_token = try arena.dupe(u8, token);
    if (str(doc, "scope")) |scope| out.scope = try arena.dupe(u8, scope);
    out.expires_at_ms = if (doc.object.get("expires_in")) |v| switch (v) {
        .integer => |n| now_ms + n * std.time.ms_per_s,
        .float => |f| now_ms + @as(i64, @intFromFloat(f * std.time.ms_per_s)),
        else => null,
    } else null;
    return out;
}

// -------------------------------------------------------------- detail --

/// The server's own words for the last failure on this thread (a rejected
/// registration, a denied authorization), for the user-facing message.
threadlocal var detail_buf: [512]u8 = undefined;
threadlocal var detail_len: usize = 0;

fn lastDetail(text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    detail_len = @min(trimmed.len, detail_buf.len);
    @memcpy(detail_buf[0..detail_len], trimmed[0..detail_len]);
}

pub fn failureDetail() []const u8 {
    return detail_buf[0..detail_len];
}

pub fn clearDetail() void {
    detail_len = 0;
}
