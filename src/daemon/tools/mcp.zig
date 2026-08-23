//! MCP client: stdio transport first (JSON-RPC over child process pipes),
//! HTTP later. Config lists servers; their tools register namespaced as
//! `mcp:<server>:<tool>` with the same approval policy machinery.

const std = @import("std");

// TODO(M5): handshake (initialize), tools/list → Spec mapping, tools/call,
//           server lifecycle (restart on crash, kill on daemon exit).

test {
    std.testing.refAllDecls(@This());
}
