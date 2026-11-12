# marlin

[![shadybin](https://img.shields.io/endpoint?url=https://shadybin.dev/registry/github.com/jespern/marlin/badge.json)](https://shadybin.dev/registry/github.com/jespern/marlin/)

**Keep your coding agents running after you close the terminal.**

Marlin is a daemon that owns your agent sessions, and a fast terminal UI that
attaches to them. Run Claude Code and Codex on the subscriptions you already
pay for, or Marlin's own agent on any model with an API key, side by side in
tabs. Close the laptop and the work continues. Come back from another
terminal, over SSH, or from your phone.

One static binary, written in Zig. No Node, no Python, no terminal scraping.

## Install

macOS or Linux, into `~/.local/bin`, without sudo:

```sh
curl -fsSL https://marlin.wtf/install.sh | sh
```

The installer picks the release for your architecture and verifies its
SHA-256 checksum. To pin a release, pipe into `MARLIN_VERSION=0.2.1 sh`.

Or with [Homebrew](https://brew.sh/):

```sh
brew install jespern/tap/marlin
```

## Start

```sh
marlin
```

The first screen asks where inference should run:

- **Claude Code or Codex.** Marlin hosts the CLI you already have installed
  and uses its login, so the work runs on your subscription. If the CLI is
  not logged in, Marlin tells you the exact command.
- **Marlin's native agent.** Enter a key for OpenRouter, Anthropic, Vercel AI
  Gateway, LiteLLM, or any OpenAI-compatible endpoint.

You can mix them: every session picks its own agent and model with `/model`.

## If you use Claude Code or Codex today

Marlin runs the official binaries. They keep their own tools, context, and
permissions. What Marlin adds is everything around them:

- **Work that outlives the terminal.** The daemon owns the turn. Closing the
  window, a dropped SSH connection, or a daemon restart does not lose it.
  `/pause` and `/resume` survive reboots.
- **Every agent in one place.** Sessions are tabs. `Ctrl+S` shows all of
  them with their live work underneath: subagents, running commands, and
  background jobs, each with inspectable output.
- **Steer while it works.** Type while the agent is running; your message is
  queued, stays visible, and can carry images.
- **Reach it from anywhere.** `marlin --remote <host>` attaches over SSH,
  and `marlin discover` finds the Marlins on your LAN. The web companion
  lets you watch sessions and answer approvals from your phone over your
  own tailnet ([setup](docs/MOBILE.md)).
- **A real shell in every session.** `!!` turns a session into a login shell
  on the daemon's host. It survives detaching and restarts, and `Ctrl+D`
  hands the session back with the shell's output in the transcript.
- **Long runs you can leave alone.** `/runtime 12h` sets how long a guest
  may run, `/compact` compacts its context, and a gauge shows how full that
  context is.
- **Nothing is thrown away.** Messages, tool calls, and full tool output are
  structured records in SQLite. `/search` covers every session, including
  archived ones, and compaction never deletes history.
- **Scriptable.** `marlin run`, `marlin ls`, `marlin inspect --json`, and
  `marlin top` work from ordinary shell scripts.

## Native agent or guest

| | Guest (Claude Code, Codex) | Native |
|---|---|---|
| Inference | the vendor's binary, on your subscription | any model by API key |
| Tools and context | the vendor's | Marlin's tools, MCP servers, skills, and plugins |
| Permissions | the vendor's, with approvals bridged into Marlin | Marlin's approvals and shell sandbox |
| Context management | the vendor's, with `/compact` and a gauge | output caps, pruning, and compaction |
| Delegation | the vendor's subagents, shown in the work tree | durable child tasks and multi-model review councils |

Both kinds share the same sessions, transcript, search, steering, shells,
and clients. Switching a session between them hands the context over; see
[native and guest sessions](docs/ARCHITECTURE.md#native-vs-guest-agents).

## Everyday commands

```sh
marlin                         # the session rooted in this directory, or a new one
marlin ls                      # list sessions and their short handles
marlin attach 63df             # reattach by a unique handle prefix
marlin --remote host           # attach to a daemon on another machine over SSH
marlin top                     # live session tree, including child work
marlin inspect 63df --json     # state, recent blocks, and diagnostics
marlin watch 63df --json       # current status, then live status and finalized blocks
marlin watch 63df --until-idle # wait for the current turn to finish
marlin run "fix the failing test"   # headless turn
```

`watch` subscribes to the daemon's event stream without polling or replaying
history. `--json` writes one JSON object per line, with an `event` of `status`,
`block`, or `error` and the session's short handle in `session`. Status events
include `state`, `phase`, `pause`, and `err_text`; block events include `seq`,
`ts` (Unix milliseconds), and the typed `body`. The stream is read-only;
approvals and questions stay with the interactive client. `--until-idle`
exits 0 on `idle` or `done` (including an already-idle session), 1 on a failed
session or a lost connection, and 2 for invalid arguments. Without that flag,
it keeps watching across turns until interrupted or disconnected. As with
other commands, `--remote <host>` routes the subscription over SSH.

Inside the TUI:

| | |
|---|---|
| `/new`, `Ctrl+N` | new session |
| `/model` | pick the agent and model |
| `Ctrl+S`, `/top` | live work tree and session switcher |
| `/search <query>` | search every transcript |
| `/cwd <path>` | change the session's directory |
| `!!` | turn the session into a shell; `Ctrl+D` hands it back |
| `!<command>` | run one command in the session's workspace |
| `Shift+Tab` | Plan mode |
| `Alt+S`, `/screenshot` | copy a PNG of the window |
| `/pause`, `/resume` | suspend and continue work |
| `/detach` | leave; sessions keep running |

Editing is modal, with Vim navigation in the transcript and the composer.

## Documentation

- [Using Marlin](docs/USING.md): first run, sessions, recaps, the status line
- [Skills, plugins, and project instructions](docs/SKILLS.md)
- [Providers, MCP servers, and limits](docs/CONFIGURATION.md)
- [Phone companion](docs/MOBILE.md)
- [Permissions and the secret boundary](docs/PERMISSIONS.md)
- [Review councils](docs/REVIEW.md)
- [Observability](docs/OBSERVABILITY.md)
- [Terminal effects](docs/TERMINAL_EFFECTS.md), the optional playful bits
- [Architecture](docs/ARCHITECTURE.md), [protocol](docs/PROTOCOL.md), and
  [testing](docs/TESTING.md)
- [Development builds](docs/DEVELOPMENT.md)

## Architecture at a glance

```
                    ┌──────────────────────────────────────┐
                    │            marlind (daemon)          │
   ssh/mosh/tailnet │  ┌─────────┐ ┌─────────┐ ┌─────────┐ │
  ┌──────────┐      │  │session 1│ │session 2│ │session N│ │
  │marlin TUI├──────┼─▶│agent    │ │agent    │ │shell    │ │
  └──────────┘ unix │  │loop     │ │loop     │ │         │ │
  ┌──────────┐ sock │  └────┬────┘ └────┬────┘ └────┬────┘ │
  │marlin web├──────┤       ▼           ▼           ▼      │
  │ (phone,  │      │  ┌──────────────────────────────┐    │
  │  tail-   │      │  │  SQLite: blocks, sessions,   │    │
  │  net)    │      │  │  indexed logs, full outputs  │    │
  └──────────┘      │  └──────────────────────────────┘    │
                    │  native loop  ·  guests: claude · codex │
                    └──────────────────┬──────────────────────┘
                                       ▼
                    OpenRouter / Anthropic / configured providers
                         (guest sessions: their binary)
```

The TUI, the headless CLI, and the web companion are thin clients of the
same structured protocol. Session state is typed events, not text scraped
from a terminal.

## Principles

1. **Speed and simplicity are features.** Single static binary, instant
   startup, tiny memory footprint. `scp` it to a server and run it.
2. **The store is append-only truth; context is a derived view.**
   Compaction, truncation, and pruning shape what the model sees, never
   what is on disk. Scrollback and copy always operate on full data.
3. **Keep prompt-cache breaks rare and explainable.** Context is
   prefix-stable between explicit pruning and compaction boundaries.
4. **Extensibility at process boundaries.** MCP servers for tools, hook
   scripts for events, executables as custom tools. The Zig core stays
   small and stable; churn lives in scripts.
5. **Two native wire dialects, not N.** OpenAI-compatible covers most
   models; Anthropic Messages is the one extra wire. Claude Code and Codex
   are guests, not dialects: their official binaries own inference,
   context, and tools.
6. **Borrow the terminal emulator.** Agent sessions are structured data
   Marlin renders itself. Shell sessions are emulated by libghostty-vt;
   Marlin does not hand-roll a VT.
7. **Daily driver, not kitchen sink.** A feature earns its place by
   surviving daily use, not by being well designed, and a surface that
   stops earning its keep gets deleted. When in doubt, the answer is no.

## What Marlin deliberately does not do

- No messaging gateway (Telegram, Discord, and so on). Hook scripts cover
  notification.
- No hosted or multi-user web product. The web companion listens on
  localhost only and is reached through `tailscale serve`; the tailnet is
  the gate.
- No voice stack. `/voice setup` configures local, offline push-to-talk
  dictation into the composer, and that is all.
- No OCR or video pipelines, themes, or cron.
- No editor panes.
- No Tailscale embedding. Your tailnet already reaches the daemon.

## Status

Marlin is a development preview and a daily driver. It is self-hosting:
Marlin is developed from inside Marlin. Config and protocol details may
still move. Releases and their notes are on
[marlin.wtf](https://marlin.wtf).

## Prior art and what we steal

| Project | What we take |
|---|---|
| **herdr** | The UX bar: daemon and attach ergonomics, mobile-aware layout |
| **zag** (Zig) | Tail recovery, compaction cascade, lossless mid-turn steering, headless mode, Seatbelt/Landlock sandboxing of bash |
| **pi** | Minimal-tool philosophy, simplicity discipline |
| **Hermes** | Skills as Markdown, store-full and truncate-at-assembly, output caps with file pointers |
| **OpenCode** | Pruning constants and algorithm |
| **Claude Code** | Layered context reduction, headroom-triggered compaction, continuation rehydration |
| **KrillClaw / graff** | Proof of a tiny Zig core; lenient JSON repair; SSE parsing in Zig |

## License

Marlin is licensed under the [Apache License 2.0](LICENSE).
Copyright 2026 Jesper Noehr <jesper@noehr.org>.

Third-party attributions are listed in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
