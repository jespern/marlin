//! Exec tools: config-declared executables as tools (docs/ARCHITECTURE.md §7).
//! marlin passes args as JSON on stdin; stdout is the result. A shell script
//! is a tool. Extensibility at process boundaries.

const std = @import("std");

// TODO(M5).

test {
    std.testing.refAllDecls(@This());
}
