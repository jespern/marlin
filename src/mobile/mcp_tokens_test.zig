const std = @import("std");
const mcp_tokens = @import("mcp_tokens.zig");

test "scopes parse in any order; anything else is refused" {
    try std.testing.expectEqualSlices(mcp_tokens.Scope, &.{.read}, mcp_tokens.parseScopes("read").?);
    try std.testing.expectEqualSlices(mcp_tokens.Scope, &.{ .read, .act }, mcp_tokens.parseScopes("act,read").?);
    try std.testing.expectEqualSlices(mcp_tokens.Scope, &.{.act}, mcp_tokens.parseScopes("act act").?);
    try std.testing.expect(mcp_tokens.parseScopes("") == null);
    try std.testing.expect(mcp_tokens.parseScopes("read,write") == null);
    try std.testing.expectEqualStrings("read,act", mcp_tokens.scopesLabel(&.{ .act, .read }));
}

test "a token is made once, verified by hash, and revoked by id or name" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-mcp-tokens");
    defer temp.deinit();

    const robin = try mcp_tokens.create(gpa, io, temp.path, "robin", &.{ .read, .act }, 1);
    try std.testing.expect(std.mem.startsWith(u8, &robin.token, mcp_tokens.prefix));
    const reader = try mcp_tokens.create(gpa, io, temp.path, "reader", &.{.read}, 2);
    try std.testing.expectError(error.NameTaken, mcp_tokens.create(gpa, io, temp.path, "Robin", &.{.read}, 3));
    try std.testing.expectError(error.BadName, mcp_tokens.create(gpa, io, temp.path, "two words", &.{.read}, 3));

    const grant = (try mcp_tokens.verify(gpa, io, temp.path, &robin.token)).?;
    try std.testing.expectEqualStrings("robin", grant.name());
    try std.testing.expect(grant.read and grant.act);
    const read_only = (try mcp_tokens.verify(gpa, io, temp.path, &reader.token)).?;
    try std.testing.expect(read_only.read and !read_only.act);

    // The file holds no token, only hashes.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const path = try std.fs.path.join(arena_state.allocator(), &.{ temp.path, "mcp_tokens.json" });
    const stored = try std.Io.Dir.cwd().readFileAlloc(io, path, arena_state.allocator(), .limited(64 * 1024));
    try std.testing.expect(std.mem.indexOf(u8, stored, robin.token[mcp_tokens.prefix.len..]) == null);

    // A wrong token, a wrong length.
    var forged = robin.token;
    forged[forged.len - 1] ^= 1;
    try std.testing.expect(try mcp_tokens.verify(gpa, io, temp.path, &forged) == null);
    try std.testing.expect(try mcp_tokens.verify(gpa, io, temp.path, "marlin_short") == null);

    try std.testing.expect(try mcp_tokens.revoke(gpa, io, temp.path, "ROBIN"));
    try std.testing.expect(try mcp_tokens.verify(gpa, io, temp.path, &robin.token) == null);
    try std.testing.expect(try mcp_tokens.revoke(gpa, io, temp.path, "2"));
    try std.testing.expect(try mcp_tokens.verify(gpa, io, temp.path, &reader.token) == null);
    try std.testing.expect(!try mcp_tokens.revoke(gpa, io, temp.path, "2"));
}
