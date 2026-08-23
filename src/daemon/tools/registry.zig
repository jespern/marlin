//! Tool registry (docs/ARCHITECTURE.md §7).
//!
//! A tool spec: name, JSON schema, parallel_safe, default policy. Sources:
//! built-ins (this dir), exec tools (config-declared executables, M5), and
//! MCP servers (namespaced `mcp:<server>:<tool>`, M5). Dispatch is uniform;
//! the approval gate applies identically regardless of source.

const std = @import("std");

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    /// JSON schema for arguments, as a raw JSON string.
    schema_json: []const u8,
    /// Read-only tools may execute concurrently within a turn.
    parallel_safe: bool,
    /// Whether the tool mutates state (drives the default approval policy).
    mutating: bool,
};

// TODO(M0): registry table, dispatch(call) → result{status, output};
//           built-ins: bash, read_file. Cancellation flag threading.
// TODO(M2): write_file, edit, grep, glob, fetch.
// TODO(M5): exec_tool.zig + mcp.zig registration.
// TODO(M6): task (subagent spawn).

test {
    std.testing.refAllDecls(@This());
}
