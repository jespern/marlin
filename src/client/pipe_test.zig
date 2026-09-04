//! Unit tests for pipe.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in pipe.zig.

const std = @import("std");
const Io = std.Io;
const proto = @import("../core/proto.zig");
const attach = @import("attach.zig");

const pipe = @import("pipe.zig");

test {
    std.testing.refAllDecls(pipe);
}
