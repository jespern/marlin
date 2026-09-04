//! Unit tests for credentials.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in credentials.zig.

const std = @import("std");
const Io = std.Io;

const credentials = @import("credentials.zig");
const loadInto = credentials.loadInto;
const store = credentials.store;

test {
    std.testing.refAllDecls(credentials);
}

test "store then load round trip, env wins" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var temp = try @import("../testing/temp_dir.zig").Dir.initFromProcess(gpa, io, "marlin-cred");
    defer temp.deinit();
    const tmp = temp.path;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = std.process.Environ.Map.init(arena);
    try env.put("XDG_CONFIG_HOME", tmp);

    try store(arena, io, &env, "OPENROUTER_API_KEY", "sk-test-123");
    try store(arena, io, &env, "OPENROUTER_API_KEY", "sk-test-456"); // replace
    try loadInto(arena, io, &env);
    try std.testing.expectEqualStrings("sk-test-456", env.get("OPENROUTER_API_KEY").?);

    // Env wins over file.
    var env2 = std.process.Environ.Map.init(arena);
    try env2.put("XDG_CONFIG_HOME", tmp);
    try env2.put("OPENROUTER_API_KEY", "from-env");
    try loadInto(arena, io, &env2);
    try std.testing.expectEqualStrings("from-env", env2.get("OPENROUTER_API_KEY").?);

    var env3 = std.process.Environ.Map.init(arena);
    try env3.put("XDG_CONFIG_HOME", tmp);
    try store(arena, io, &env3, "ACME_API_KEY", "custom-secret");
    try loadInto(arena, io, &env3);
    try std.testing.expectEqualStrings("custom-secret", env3.get("ACME_API_KEY").?);
    try std.testing.expectError(error.UnsupportedCredentialName, store(arena, io, &env3, "PATH", "/malicious"));
    try std.testing.expectError(error.InvalidCredentialValue, store(arena, io, &env3, "ACME_API_KEY", "one\nOTHER_API_KEY=two"));
}
