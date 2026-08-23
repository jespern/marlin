//! fetch tool: HTTP GET → readable text (strip tags crudely, keep links).
//! Uses provider/http.zig's curl wrapper. parallel_safe.

const std = @import("std");

// TODO(M2).

test {
    std.testing.refAllDecls(@This());
}
