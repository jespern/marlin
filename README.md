# marlin

**A fast, simple AI agent harness in Zig — a session multiplexer that actually understands its sessions.**

One static binary. A daemon that owns your agent sessions and keeps them running;
thin clients that attach from anywhere. herdr's ergonomics, but the multiplexer
sees structured events instead of scraping a character grid.

## The pitch

Every agent harness today picks one of two shapes:

1. **Monolithic TUI** (pi, Claude Code, zag) — great single-session experience,
   but persistence and remoting are outsourced to tmux/herdr, which only see
   pixels. Kill the terminal, lose the process. Status detection is heuristic
   scraping.
2. **Kitchen-sink framework** (Hermes, Wintermolt) — daemon-ish, multi-surface,
   enormously capable, and enormously large. Python/Node runtimes, hundreds of
   files, breadth over speed.

marlin takes the unclaimed third shape: **daemon-native structured sessions,
multiplexed by a TUI that is just another client.**

- Sessions live in the daemon. Detach, reboot your laptop, ssh in from another
  machine, reattach — the agent never noticed.
- The multiplexer knows "session 3 is awaiting approval for `rm -rf`" as a
  *typed event*, not a guess from terminal output. Tap-to-approve from a phone
  becomes a protocol message, not a screen-scrape.
- Copy the last tool output with `!c` — a query over structured blocks, not a
  rectangle of screen cells. Paste it into another session without touching the
  OS clipboard.
- ssh/mosh remain the transport. We never reinvent them; we just put structure
  on the wire above them.

## Principles

1. **Speed and simplicity are features.** Single static binary, instant startup,
   tiny memory footprint. `scp` it to a server and run it. No node_modules, no
   venv, no runtime.
2. **The store is append-only truth; context is a derived view.** Compaction,
   truncation, and pruning shape what the model sees — never what's on disk.
   Scrollback and copy always operate on full data.
3. **Never break prompt caching.** Append-only context between compactions;
   compaction is the one legitimate cache break, executed as a clean prefix
   rebuild.
4. **Extensibility at process boundaries.** MCP servers for tools, hook scripts
   for events, executables as custom tools. The Zig core stays small and stable;
   churn lives in scripts.
5. **OpenRouter first, providers as a thin interface.** OpenAI-compatible wire
   format covers 90% of the world; Anthropic Messages is the one worth
   special-casing (prompt-cache control).
6. **Agent panes only — no VTE.** Splits show marlin sessions, which are
   structured data we render ourselves. No terminal emulation tarpit. (If an
   embedded terminal is ever truly needed: libghostty-vt, not hand-rolled.)

## What v1 deliberately does NOT do

- No messaging gateway (Telegram/Discord/...) — hook scripts cover notification.
- No web UI (v2: it's just another client on the same protocol).
- No voice, vision pipelines, themes, cron, profiles.
- No embedded terminal emulator / editor panes.
- No Tailscale embedding — your tailnet already reaches the daemon socket.

## Architecture at a glance

```
                    ┌──────────────────────────────────────┐
                    │            marlind (daemon)          │
   ssh/mosh/tailnet │  ┌─────────┐ ┌─────────┐ ┌─────────┐ │
  ┌──────────┐      │  │session 1│ │session 2│ │session N│ │
  │marlin TUI├──────┼─▶│agent    │ │agent    │ │agent    │ │
  └──────────┘ unix │  │loop     │ │loop     │ │loop     │ │
  ┌──────────┐ sock │  └────┬────┘ └────┬────┘ └────┬────┘ │
  │marlin TUI├──────┤       ▼           ▼           ▼      │
  │ (phone,  │      │  ┌──────────────────────────────┐    │
  │  later:  │      │  │  SQLite: blocks, sessions,   │    │
  │  PWA)    │      │  │  FTS5 search, full outputs   │    │
  └──────────┘      │  └──────────────────────────────┘    │
                    │   tools ─▶ bash/files/MCP/hooks       │
                    └──────────────┬───────────────────────┘
                                   ▼
                            OpenRouter / OpenAI-compat / Anthropic
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design and
[docs/MILESTONES.md](docs/MILESTONES.md) for the build order.

## Prior art & what we steal

| Project | What we take |
|---|---|
| **herdr** | The UX bar: daemon+attach ergonomics, mobile-aware layout, status sidebar |
| **zag** (Zig) | Append-only JSONL w/ tail recovery, compaction cascade, mid-turn steering as queued interrupt, headless eval mode, seatbelt/Landlock sandboxing of bash |
| **pi** | Minimal-tool philosophy (~6 tools is enough), simplicity discipline |
| **Hermes** | Skills-as-markdown, store-full/truncate-at-assembly, output caps w/ file pointers |
| **OpenCode** | Pruning constants & algorithm (protect recent 40k tool-output tokens, stub older) |
| **Claude Code** | Layered compaction: microcompaction → headroom-triggered auto → manual at task boundaries; rehydration (files+todos+continuation) |
| **KrillClaw / graff** | Proof of tiny Zig core; lenient JSON repair; SSE parsing in Zig |
