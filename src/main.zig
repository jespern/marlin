//! marlin — a fast, simple AI agent harness.
//!
//! Entry point: parses the subcommand and dispatches.
//!   marlin                → attach (TUI client; autostarts daemon)   [M2]
//!   marlin daemon         → run the daemon in the foreground         [M1]
//!   marlin run "task"     → headless one-shot session                [M0]
//!   marlin ls [--all]     → list sessions                            [M1]
//!   marlin attach <handle>    → attach TUI to a session               [M2]
//!   marlin archive <handle>   → hide a durable session hierarchy      [M6]
//!   marlin unarchive <handle> → restore an archived hierarchy         [M6]
//!   marlin kill <handle>      → interrupt a session                   [M1]
//!
//! See docs/ARCHITECTURE.md §1 for the process model.
//!
//! NOTE Zig 0.16: main receives `std.process.Init` (arena, gpa, io, args);
//! the `Io` instance is threaded explicitly to everything that does I/O.

const std = @import("std");
const cli = @import("cli.zig");
const credentials = @import("core/credentials.zig");

/// Debug builds default unexpected_error_tracing=true, which makes ANY
/// unmapped errno (e.g. ECONNREFUSED from a stale daemon socket — an
/// expected, handled condition in tryConnect's autostart path) dump a
/// stack trace to stderr before the error is even returned to us. We
/// handle our errors; stderr is not a debug channel in a TUI app.
pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const self_exe = if (args.len > 0) args[0] else "marlin";
    // std.process.Init.gpa is the SMP allocator in ReleaseFast. Its small
    // frees return to the *freeing thread's* private lists, but Marlin's
    // message ownership intentionally crosses threads (dispatcher allocates,
    // socket writers free). That asymmetry strands slabs indefinitely. libc's
    // process-wide allocator preserves cross-thread reuse and releases large
    // transient buffers normally.
    const runtime_allocator = std.heap.c_allocator;
    // Fill env gaps from ~/.config/marlin/credentials (env always wins).
    credentials.loadInto(runtime_allocator, init.io, init.environ_map) catch {};
    return cli.dispatch(
        runtime_allocator,
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
    _ = @import("core/session_handle.zig");
    _ = @import("core/queue.zig");
    _ = @import("daemon/store.zig");
    _ = @import("daemon/loop.zig");
    _ = @import("daemon/context.zig");
    _ = @import("daemon/approval.zig");
    _ = @import("daemon/permissions.zig");
    _ = @import("daemon/sandbox.zig");
    _ = @import("daemon/landlock.zig");
    _ = @import("daemon/network_policy.zig");
    _ = @import("daemon/extensions.zig");
    _ = @import("daemon/hooks.zig");
    _ = @import("daemon/skills.zig");
    _ = @import("daemon/tools/registry.zig");
    _ = @import("daemon/tools/bash.zig");
    _ = @import("daemon/tools/files.zig");
    _ = @import("daemon/tools/search.zig");
    _ = @import("daemon/tools/fetch.zig");
    _ = @import("daemon/tools/plan.zig");
    _ = @import("daemon/tools/exec_tool.zig");
    _ = @import("daemon/tools/mcp.zig");
    _ = @import("daemon/provider/provider.zig");
    _ = @import("daemon/provider/openai_compat.zig");
    _ = @import("daemon/provider/anthropic.zig");
    _ = @import("daemon/provider/sse.zig");
    _ = @import("daemon/provider/http.zig");
    _ = @import("daemon/provider/registry.zig");
    _ = @import("client/attach.zig");
    _ = @import("client/cc_approve.zig");
    _ = @import("client/web.zig");
    _ = @import("testing/fixture_tests.zig");
    _ = @import("client/render.zig");
    _ = @import("client/markdown.zig");
    _ = @import("client/layout.zig");
    _ = @import("client/media.zig");
    _ = @import("client/tui.zig");
}
