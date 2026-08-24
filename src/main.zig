//! marlin — a fast, simple AI agent harness.
//!
//! Entry point: parses the subcommand and dispatches.
//!   marlin                → attach (TUI client; autostarts daemon)   [M2]
//!   marlin daemon         → run the daemon in the foreground         [M1]
//!   marlin run "task"     → headless one-shot session                [M0]
//!   marlin ls             → list sessions                            [M1]
//!   marlin attach <id>    → attach TUI to a session                  [M2]
//!   marlin kill <id>      → terminate a session                      [M1]
//!
//! See docs/ARCHITECTURE.md §1 for the process model.
//!
//! NOTE Zig 0.16: main receives `std.process.Init` (arena, gpa, io, args);
//! the `Io` instance is threaded explicitly to everything that does I/O.

const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const self_exe = if (args.len > 0) args[0] else "marlin";
    return cli.dispatch(
        init.gpa,
        init.io,
        init.environ_map,
        self_exe,
        if (args.len > 1) args[1..] else &.{},
    );
}

test {
    // Force the whole skeleton into the compile+test graph, including files
    // not yet imported by real code paths. Prune entries as real imports land.
    std.testing.refAllDecls(@This());
    _ = @import("core/block.zig");
    _ = @import("core/proto.zig");
    _ = @import("core/config.zig");
    _ = @import("core/jsonx.zig");
    _ = @import("core/ids.zig");
    _ = @import("core/queue.zig");
    _ = @import("daemon/session.zig");
    _ = @import("daemon/store.zig");
    _ = @import("daemon/loop.zig");
    _ = @import("daemon/context.zig");
    _ = @import("daemon/approval.zig");
    _ = @import("daemon/hooks.zig");
    _ = @import("daemon/skills.zig");
    _ = @import("daemon/tools/registry.zig");
    _ = @import("daemon/tools/bash.zig");
    _ = @import("daemon/tools/files.zig");
    _ = @import("daemon/tools/search.zig");
    _ = @import("daemon/tools/fetch.zig");
    _ = @import("daemon/tools/exec_tool.zig");
    _ = @import("daemon/tools/mcp.zig");
    _ = @import("daemon/provider/provider.zig");
    _ = @import("daemon/provider/openai_compat.zig");
    _ = @import("daemon/provider/anthropic.zig");
    _ = @import("daemon/provider/sse.zig");
    _ = @import("daemon/provider/http.zig");
    _ = @import("daemon/provider/registry.zig");
    _ = @import("client/attach.zig");
    _ = @import("testing/fixture_tests.zig");
    _ = @import("client/tui.zig");
}
