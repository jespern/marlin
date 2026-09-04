//! Unit tests for provider.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in provider.zig.

const std = @import("std");
const guest = @import("../../core/guest.zig");

const provider = @import("provider.zig");

test {
    std.testing.refAllDecls(provider);
}
