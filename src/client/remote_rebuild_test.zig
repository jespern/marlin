//! Unit tests for remote_rebuild.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in remote_rebuild.zig.

const std = @import("std");
const Io = std.Io;
const attach = @import("attach.zig");
const self_build = @import("self_build.zig");

const remote_rebuild = @import("remote_rebuild.zig");

test {
    std.testing.refAllDecls(remote_rebuild);
}
