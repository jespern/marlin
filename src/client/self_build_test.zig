//! Unit tests for self_build.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in self_build.zig.

const std = @import("std");
const Io = std.Io;

const self_build = @import("self_build.zig");
const isMarlinManifest = self_build.isMarlinManifest;
const sourceRootFromExecutable = self_build.sourceRootFromExecutable;

test {
    std.testing.refAllDecls(self_build);
}

test "source root requires the active zig-out binary" {
    try std.testing.expectEqualStrings(
        "/work/marlin",
        sourceRootFromExecutable("/work/marlin/zig-out/bin/marlin").?,
    );
    try std.testing.expect(sourceRootFromExecutable("/opt/homebrew/bin/marlin") == null);
    try std.testing.expect(sourceRootFromExecutable("/work/marlin/marlin") == null);
}

test "source checkout manifest must name marlin" {
    try std.testing.expect(isMarlinManifest(".{\n    .name = .marlin,\n}"));
    try std.testing.expect(!isMarlinManifest(".{\n    .name = .another_project,\n}"));
    try std.testing.expect(!isMarlinManifest(".{ .version = \"1.0\" }"));
}
