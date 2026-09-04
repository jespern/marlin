//! marlin — a fast, simple AI agent harness.
//!
//! Entry point: parses the subcommand and dispatches.
//!   marlin                → attach (TUI client; autostarts daemon)   [M2]
//!   marlin daemon         → run the daemon in the foreground         [M1]
//!   marlin run "task"     → headless one-shot session                [M0]
//!   marlin ls [--all]     → list sessions                            [M1]
//!   marlin inspect <handle> → inspect session state and history
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
    _ = @import("cli_test.zig");
    _ = @import("daemon/provider/claude_code_test.zig");
    _ = @import("daemon/guest/shared_test.zig");
    _ = @import("daemon/guest/codex_turn_test.zig");
    _ = @import("daemon/guest/claude_code_turn_test.zig");
    _ = @import("daemon/shell_network_test.zig");
    _ = @import("daemon/process_io_test.zig");
    _ = @import("daemon/power_test.zig");
    _ = @import("core/effort_test.zig");
    _ = @import("core/credentials_test.zig");
    _ = @import("core/config_toml_test.zig");
    _ = @import("client/pipe_test.zig");
    _ = @import("client/headless_test.zig");
    _ = @import("client/editor_test.zig");
    _ = @import("core/block_test.zig");
    _ = @import("core/guest_test.zig");
    _ = @import("core/proto_test.zig");
    _ = @import("core/config_test.zig");
    _ = @import("core/jsonx_test.zig");
    _ = @import("core/ids_test.zig");
    _ = @import("core/session_handle_test.zig");
    _ = @import("core/telemetry_test.zig");
    _ = @import("core/queue_test.zig");
    _ = @import("daemon/store_test.zig");
    _ = @import("daemon/loop_test.zig");
    _ = @import("daemon/context_test.zig");
    _ = @import("daemon/approval_test.zig");
    _ = @import("daemon/permissions_test.zig");
    _ = @import("daemon/sandbox_test.zig");
    _ = @import("daemon/landlock_test.zig");
    _ = @import("daemon/network_policy_test.zig");
    _ = @import("daemon/otel_test.zig");
    _ = @import("daemon/extensions_test.zig");
    _ = @import("daemon/hooks_test.zig");
    _ = @import("daemon/skills_test.zig");
    _ = @import("daemon/tools/registry_test.zig");
    _ = @import("daemon/tools/bash_test.zig");
    _ = @import("daemon/tools/files_test.zig");
    _ = @import("daemon/tools/search_test.zig");
    _ = @import("daemon/tools/fetch_test.zig");
    _ = @import("daemon/tools/plan_test.zig");
    _ = @import("daemon/tools/exec_tool_test.zig");
    _ = @import("daemon/tools/mcp_test.zig");
    _ = @import("daemon/provider/provider_test.zig");
    _ = @import("daemon/provider/openai_compat_test.zig");
    _ = @import("daemon/provider/anthropic_test.zig");
    _ = @import("daemon/provider/sse_test.zig");
    _ = @import("daemon/provider/http_test.zig");
    _ = @import("daemon/provider/registry_test.zig");
    _ = @import("daemon/provider/codex_test.zig");
    _ = @import("core/visual_effect_test.zig");
    _ = @import("client/attach_test.zig");
    _ = @import("client/cc_approve_test.zig");
    _ = @import("client/remote_rebuild_test.zig");
    _ = @import("client/self_build_test.zig");
    _ = @import("client/voice_test.zig");
    _ = @import("client/web_test.zig");
    _ = @import("testing/fixture_tests.zig");
    _ = @import("client/render_test.zig");
    _ = @import("client/markdown_test.zig");
    _ = @import("client/layout_test.zig");
    _ = @import("client/effect.zig");
    _ = @import("client/effects_test.zig");
    _ = @import("client/pixel_effects_test.zig");
    _ = @import("client/shadowbox_test.zig");
    _ = @import("client/media_test.zig");
    _ = @import("client/matrix_test.zig");
    _ = @import("client/pacman_test.zig");
    _ = @import("client/pixel_effects.zig");
    _ = @import("client/shadowbox.zig");
    _ = @import("client/plasma_test.zig");
    _ = @import("client/starfield_test.zig");
    _ = @import("client/strings_test.zig");
    _ = @import("client/tui_test.zig");
    _ = @import("client/commands.zig");
    _ = @import("client/keys.zig");
    _ = @import("client/setup.zig");
    _ = @import("client/search.zig");
    _ = @import("client/top_test.zig");
}
