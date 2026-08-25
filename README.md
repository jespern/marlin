# marlin

**A fast, simple AI agent harness in Zig — a session multiplexer that actually understands its sessions.**

One static binary. A daemon that owns your agent sessions and keeps them running;
thin clients that attach from anywhere. herdr's ergonomics, but the multiplexer
sees structured events instead of scraping a character grid.

## Install

Install the latest macOS or Linux release in `~/.local/bin` without sudo:

```sh
curl -fsSL https://marlin.wtf/install.sh | sh
```

The installer selects the release for your architecture and verifies its
SHA-256 checksum. To pin a version, pipe into `MARLIN_VERSION=0.1.0 sh`.

Or use [Homebrew](https://brew.sh/) on macOS or Linux:

```sh
brew install jespern/tap/marlin
```

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
- Unarchived root sessions are always visible as clickable tabs; child work
  rolls up into the root's running, approval, or error indicator.
- Sessions have short stable handles: `marlin ls` prints eight characters and
  `marlin attach 63df` accepts any unique prefix of four or more.
- The multiplexer knows "session 3 is awaiting approval for `rm -rf`" as a
  *typed event*, not a guess from terminal output. Tap-to-approve from a phone
  becomes a protocol message, not a screen-scrape.
- Copy the last tool output with `!c` — a query over structured blocks, not a
  rectangle of screen cells. Paste it into another session without touching the
  OS clipboard.
- OpenRouter sessions can search the web with the same API key and preserve
  cited source URLs; `fetch` opens known pages for deeper reading.
- Paste an image with Ctrl+V or attach one by path. The client uploads it to
  the daemon through the protocol—no shared path assumption—and images remain
  durable, content-addressed transcript attachments.
- ssh/mosh remain the transport. We never reinvent them; we just put structure
  on the wire above them.

## Principles

1. **Speed and simplicity are features.** Single static binary, instant startup,
   tiny memory footprint. `scp` it to a server and run it. No node_modules, no
   venv, no runtime.
2. **The store is append-only truth; context is a derived view.** Compaction,
   truncation, and pruning shape what the model sees — never what's on disk.
   Scrollback and copy always operate on full data.
3. **Keep prompt-cache breaks rare and explainable.** Context is prefix-stable
   between explicit pruning and compaction boundaries. Both are coarse-grained,
   logged events rather than incidental per-turn rewrites.
4. **Extensibility at process boundaries.** MCP servers for tools, hook scripts
   for events, executables as custom tools. The Zig core stays small and stable;
   churn lives in scripts.
5. **OpenRouter first, providers as a thin interface.** OpenAI-compatible wire
   format covers 90% of the world; Anthropic Messages is the one worth
   special-casing (prompt-cache control).
6. **Agent panes only — no VTE.** Splits show marlin sessions, which are
   structured data we render ourselves. No terminal emulation tarpit. (If an
   embedded terminal is ever truly needed: libghostty-vt, not hand-rolled.)

## Context management today

Marlin implements a three-stage structural cascade:

1. Tool output is capped before it enters model context; the complete output
   remains available in the SQLite blob store.
2. Once context crosses a soft threshold, old inline tool results are replaced
   with short stubs while a recent-output window is protected.
3. Near the model's context limit, Marlin writes an LLM-generated continuation
   summary, preserves a recent tail, and rehydrates windows from recently
   written files plus a continuation note.

That is useful layered context management, but it is not yet a claim of mature
semantic "microcompaction." Fixture tests cover the mechanics and boundary
invariants; long-running quality and cost behavior still need M3 burn-in.

## What v1 deliberately does NOT do

- No messaging gateway (Telegram/Discord/...) — hook scripts cover notification.
- No supported web UI. (`marlin web` exists as an opt-in POC: a
  localhost-only, **unauthenticated** HTTP/SSE bridge — anything reaching the
  port can drive marlin, including reboot/shutdown. It's just another client
  on the same protocol, and it is not a deploy surface.)
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
  │  PWA)    │      │  │  indexed logs, full outputs  │    │
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
| **Claude Code** | Layered context reduction, headroom-triggered compaction, and continuation rehydration |
| **KrillClaw / graff** | Proof of tiny Zig core; lenient JSON repair; SSE parsing in Zig |

## SQLite and local builds

SQLite remains Marlin's canonical store: WAL, indexed session/block queries,
migrations, hierarchy, and content-addressed blobs would otherwise become a
home-grown database layer around JSONL. FTS5 search is **not** implemented
today; a cross-session `/search` is a future feature described in the
[architecture notes](docs/ARCHITECTURE.md#future-cross-session-search).

For fast local iteration, `zig build` and `zig build test` link the system
SQLite library. Official release builds compile the vendored amalgamation into
the binary. To reproduce that configuration locally:

```sh
zig build -Doptimize=ReleaseSafe -Dembedded-sqlite=true
```

## License

Marlin is licensed under the [Apache License 2.0](LICENSE).
Copyright 2026 Jesper Noehr <jesper@noehr.org>.

Third-party attributions are listed in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
