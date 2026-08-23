//! File tools: read_file, write_file, edit.
//!
//! read_file: offset/limit windowing, line numbers, binary detection.
//! write_file: full replace, parent dir creation.
//! edit: exact string replace first, then a bounded fuzzy fallback
//!       (whitespace-insensitive match) — models mangle indentation.

const std = @import("std");

// TODO(M0): read_file. TODO(M2): write_file, edit.

test {
    std.testing.refAllDecls(@This());
}
