//! Search tools: grep (ripgrep subprocess when available, internal fallback)
//! and glob (std.fs walker + pattern match). Both parallel_safe.

const std = @import("std");

// TODO(M2).

test {
    std.testing.refAllDecls(@This());
}
