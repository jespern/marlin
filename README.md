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
SHA-256 checksum. To pin this release, pipe into `MARLIN_VERSION=0.1.3 sh`.

Or use [Homebrew](https://brew.sh/) on macOS or Linux:

```sh
brew install jespern/tap/marlin
```

## First run

Run `marlin` and the first screen asks where inference should run. Choose a
native provider such as OpenRouter, Vercel AI Gateway, Anthropic, LiteLLM, or
another OpenAI-compatible endpoint, or host an installed Codex or Claude Code
agent as a guest. Native API keys are entered in a masked prompt and saved by
the daemon in `~/.config/marlin/credentials` with mode 0600. Guest choices use
the vendor CLI's existing login and tell you the exact login command when the
daemon host is not authenticated.

The setup is daemon-owned, so it works the same over `marlin --remote`: keys,
config, guest binaries, and login state are checked on the machine that will
run the turn. `/setup` reopens the flow later. `marlin run` never prompts; on a
fresh unconfigured daemon it exits with an instruction to complete interactive
setup or pass an explicit model whose credentials already exist on that host.

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
multiplexed by a TUI that is just another client.** Some of those sessions
run Marlin's own agent. Some host an official vendor agent as a *guest*:
Claude Code for subscription Fable, or Codex through `codex app-server`
using the user's existing ChatGPT login. Guest is a session regime, not
another wire dialect; the multiplexer still sees blocks, not pixels. See
[Native vs guest](docs/ARCHITECTURE.md#native-vs-guest-agents).

What that consolidates: one multiplexer over your whole model fleet. The
workflow marlin replaces is three or four vendor CLIs cycling under a
terminal multiplexer plus a desktop app on the side — each with its own UX,
each picked per task by preference or remaining credits, findings shuttled
between them by hand. In marlin that is tabs in one room: Fable and Codex
through their official binaries as guests, grok/GLM/GPT and everything else
OpenRouter carries as native sessions, switched per task. The
migration test for every feature: does it delete a reason to open one of
the old rooms?

- Sessions live in the daemon. Detach, reboot your laptop, ssh in from another
  machine, reattach — the agent never noticed.
- Unarchived root sessions are always visible as clickable tabs; child work
  rolls up into the root's running, approval, or error indicator.
- Sessions have short stable handles: `marlin ls` prints eight characters and
  `marlin attach 63df` accepts any unique prefix of four or more.
  `marlin inspect 63df --json` is the supported read-only view for metadata,
  live state, bounded blocks, the latest plan, and diagnostics—no SQLite schema
  knowledge required.
  `marlin top` opens a live chronological tree with archive/kill shortcuts;
  inside the TUI,
  `/top` or `Ctrl+S` opens the same overview as a session switcher.
- The multiplexer knows "session 3 is awaiting approval for `rm -rf`" as a
  *typed event*, not a guess from terminal output. Tap-to-approve from a phone
  becomes a protocol message, not a screen-scrape.
- Run `!<command>` (or `! <command>`) in the focused session's workspace, or
  enter bare `!` for an interactive local shell. A leading space sends a
  message that starts with `/` or `!` verbatim. Marlin leaves the alternate screen completely,
  then reattaches to the durable session when the shell exits. Direct
  `--remote` attachments refuse shell escapes; run Marlin inside SSH or mosh
  when the terminal and workspace live on another host.
- Copy the last tool output with `!c` — a query over structured blocks, not a
  rectangle of screen cells. Paste it into another session without touching the
  OS clipboard.
- Recall anything you previously wrote with insert-mode `Ctrl+R`: it searches
  inline in the composer, repeated `Ctrl+R` walks older matches, and Esc
  restores the draft. Normal-mode `/` searches the current transcript; `/search <query>` and
  `marlin search <query>` search every durable session.
- Terminal-native effects share one finite-animation/full-screen-saver surface.
  Cell effects paint the grid: `matrix` rain, `strings` dancing sine curves, a
  forward `stars` field, and color-cycling `plasma`. Pixel effects render a
  framebuffer over the Kitty graphics protocol (Kitty, Ghostty, WezTerm):
  `pacman`, a self-playing take on feiss' 1024-byte js1k entry on a maze
  generated to fit your window with the arcade's rules (mirrored, no dead
  ends, a ghost house in the middle, wrap-around tunnels; a new maze every
  board), a spinning `tunnel`, `metaballs`, a synthwave `horizon`, `demo`, a
  24-second sequence of those three, and `shadowbox`, a paper-cutout
  landscape after Jani Ylikangas' js1k entry that follows the real sun over
  your machine: it locates you from your time zone and computes the sun's
  true altitude and azimuth, so days run long in summer and short in
  winter, sunrise lands where and when it should, and a Nordic midsummer
  night keeps its twilight. `/screensaver shadowbox cycle` runs today's
  whole day every two minutes and `/screensaver shadowbox 18.5` pins an
  hour (`MARLIN_SHADOWBOX_HOUR` does the same from the environment);
  `MARLIN_SHADOWBOX_LATLON=lat,lon` overrides the place. Without graphics, Pac-Man draws its maze on
  cells and the other pixel effects start as a cell sibling; either way the
  status line says so. Run `/animate <effect>` over gaps in the current UI
  (opaque for the pixel kinds), or `/screensaver [effect]` for the
  continuous form. Normal-mode `gs` starts the configured effect and returns to
  insert mode on wake. A key or paste wakes it and is consumed; mouse activity
  is ignored. Automatic activation is off by default; `/config screensaver 10m
  strings` enables it, `/config screensaver tunnel` changes only the effect,
  and `off` disables it. The equivalent TOML keys are `[ui] screensaver_after`
  and `screensaver_effect`.
- During a turn, the live activity row distinguishes request preparation, model
  wait/streaming, tool execution, child-agent work, compaction, and finalization,
  with total and current-phase timers. Streaming shows a green up arrow while
  tokens are arriving and a red down arrow after three quiet seconds. A running
  Bash command keeps the same shell syntax highlighting used by completed tool
  rows.
- `/diagnostics` and `marlin diagnostics [handle] [--json]` separate provider
  latency, TTFT, tool time, and failures. Optional OTLP/HTTP export uses a
  durable retry outbox, supports restart-free `/otel set|off|status`, and
  correlates OpenRouter Broadcast under the same trace; see
  [docs/OBSERVABILITY.md](docs/OBSERVABILITY.md).
- OpenRouter sessions can search the web with the same API key and preserve
  cited source URLs; `fetch` opens known pages for deeper reading.
- `/model codex/default` hosts the installed Codex agent through its stable
  app-server protocol. It uses `codex login`/the existing ChatGPT session, so
  Marlin needs no additional search or inference API key. The guest route
  refuses an API-key Codex login instead of silently changing the biller.
- Paste an image with Ctrl+V (Control-V, not Command-V on macOS) or attach one
  by path. Staged images appear in the prompt as `[image #1]`, `[image #2]`, and
  so on. The client uploads them through the protocol—no shared path
  assumption—and images remain durable, content-addressed transcript
  attachments.
- Delegate one focused investigation with `task`, or fan out two to eight with
  `task_batch`; every read-only child is durable, attachable, and grouped under
  its parent while results return in requested order.
- Build a multi-model review council with `/council new core`: filter the
  model catalog, toggle as many seats as you want, then choose `Done`. After
  that, `/review core <question>` fans a self-contained review prompt to the
  roster via `task_batch` and the parent consolidates agreements, splits,
  and a recommendation. Councils are durable config (`[[council]]` in
  config.toml); the procedure is a markdown skill
  ([skills/council.md](skills/council.md)), not core machinery. The first
  live council reviewed marlin's own sandbox policy and found a real bug.
- Shift+Tab enters persistent Plan mode: the agent investigates with a
  daemon-enforced read-only tool profile, then offers Implement, Revise, Stay,
  or Dismiss. `/plan <task>` enters directly, `/plan off` exits, and `/plan
  clear` closes a stale durable execution todo.
- Substantial implementation gets a durable execution plan: the active step
  stays pinned above the composer, revisions survive reboot and compaction,
  and delegated child activity attaches to the step it is helping complete.
- Source-built self-hosting works across remote attachments: `!rb` rebuilds the
  attached daemon side, `!rb client` rebuilds only the local client, and `!rb
  both` builds both before restarting. Package-installed binaries refuse these
  builds and remain owned by install.sh or Homebrew.
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
5. **OpenRouter first for the native agent; two wire dialects, not N.**
   OpenAI-compatible covers most models; Anthropic Messages is the one
   extra wire. Claude Code and Codex are guest sessions, not dialects: their
   official binaries own inference, context, and tools.
   Do not add a third wire. OpenRouter is the default, not a hard
   dependency: `anthropic/`, `vercel/`, `litellm/`, `local/`, and configured
   `[providers.*]` entries can all route independently.
6. **Agent panes only — no VTE.** Splits show marlin sessions, which are
   structured data we render ourselves. No terminal emulation tarpit. (If an
   embedded terminal is ever truly needed: libghostty-vt, not hand-rolled.)
7. **Daily driver, not kitchen sink.** Marlin exists to be driven all day,
   and that is the whole test: a feature earns its place by surviving
   dogfood, not by being well designed, and a surface that stops earning
   its keep gets deleted rather than maintained. Designed doors (councils,
   remote transport, workspace snapshots) stay shut until daily use — not
   momentum — demands one. When in doubt, the answer is no.

## MCP servers

MCP is daemon-owned rather than a client-side plugin shim. Stdio servers are
discovered independently, so one broken server is reported as unavailable
without taking down Marlin or hiding healthy servers. Manage the durable config
from either client surface:

```sh
marlin mcp add playwright -- npx @playwright/mcp
marlin mcp list
marlin mcp restart playwright
marlin mcp remove playwright
```

The TUI equivalents are `/mcp`, `/mcp add`, `/mcp restart`, `/mcp remove`, and
`/mcp reload`. Tool read/write policy follows MCP annotations with exact
`readonly_tools` and `mutating_tools` config overrides. Image results are stored
as transcript media and sent back to vision-capable providers. Streamable HTTP
transport remains later work; stdio is the supported product path today.

## Provider routing

Model ids are `provider/model`. Marlin strips the first component before
sending the request, so `vercel/anthropic/claude-sonnet-4` sends
`anthropic/claude-sonnet-4` to Vercel AI Gateway.

The built-in native routes are:

- `openrouter/<model>` with `OPENROUTER_API_KEY`
- `vercel/<model>` with `AI_GATEWAY_API_KEY`
- `litellm/<model>` at `http://127.0.0.1:4000/v1`, optionally with
  `LITELLM_API_KEY`
- `anthropic/<model>` with `ANTHROPIC_API_KEY`
- `local/<model>` with `MARLIN_LOCAL_BASE_URL` and the optional
  `MARLIN_LOCAL_API_KEY`

Any other OpenAI Chat Completions-compatible router or direct endpoint is a
small config entry:

```toml
[providers.requesty]
base_url = "https://router.requesty.ai/v1"
api_key_env = "REQUESTY_API_KEY"

[model]
favorites = ["requesty/openai/gpt-5", "litellm/fast-code"]
```

`base_url` stops at the API root; Marlin appends `/chat/completions`. The
credential field names an environment variable and never contains the secret.
Use `api_key_env = "NONE"` for an intentionally keyless endpoint. Provider
config takes effect the next time the daemon starts. Configured favorites stay
available in the model picker alongside the fetched OpenRouter catalog. Key
variable names must end in `_API_KEY`, `_TOKEN`, or `_SECRET` so Marlin's tool
boundary strips and redacts them automatically.

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
- No hosted or multi-user web product. `marlin web` is an opt-in,
  localhost-only client on the same protocol, fronted by `tailscale serve`
  and Host/Origin-checked (no token; the tailnet is the gate) — install it to a
  phone home screen to watch sessions and answer parked approvals over your
  own tailnet. It is one embedded HTML file, and it is not a deploy surface.
- No voice *stack*: no realtime voice models, wake words, or audio in the
  protocol — ever. What exists is deliberately smaller: `/voice setup` (TUI)
  configures local, offline push-to-talk dictation into the composer —
  ffmpeg records, whisper.cpp (or parakeet-mlx) transcribes at the client
  edge, both as optional subprocesses that are never mentioned until you
  ask. Dormant until invoked; the daemon never learns audio exists.
- No OCR/video pipelines, themes, cron, profiles.
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

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design and
[docs/MILESTONES.md](docs/MILESTONES.md) for the build order.

## Prior art & what we steal

| Project | What we take |
|---|---|
| **herdr** | The UX bar: daemon+attach ergonomics, mobile-aware layout, status sidebar |
| **zag** (Zig) | Append-only JSONL w/ tail recovery, compaction cascade, lossless mid-turn steering as queued follow-up, headless eval mode, seatbelt/Landlock sandboxing of bash |
| **pi** | Minimal-tool philosophy (~6 tools is enough), simplicity discipline |
| **Hermes** | Skills-as-markdown, store-full/truncate-at-assembly, output caps w/ file pointers |
| **OpenCode** | Pruning constants & algorithm (protect recent 40k tool-output tokens, stub older) |
| **Claude Code** | Layered context reduction, headroom-triggered compaction, and continuation rehydration |
| **KrillClaw / graff** | Proof of tiny Zig core; lenient JSON repair; SSE parsing in Zig |

## SQLite and local builds

SQLite remains Marlin's canonical store: WAL, indexed session/block queries,
migrations, hierarchy, and content-addressed blobs would otherwise become a
home-grown database layer around JSONL. Searchable rendered text is projected
into a compact side table; FTS5 powers transcript search when available, with a
bounded scan fallback for system SQLite builds that omit it. Raw blobs and
binary attachments are never indexed.

For fast local iteration, `zig build` and `zig build test` link the system
SQLite library. Official release builds compile the vendored amalgamation into
the binary. To reproduce that configuration locally:

```sh
zig build -Doptimize=ReleaseSafe -Dembedded-sqlite=true
```

To temporarily replace the Marlin selected by your current `PATH` with this
checkout's ReleaseFast build:

```sh
make install
marlin reboot       # activate it in an already-running daemon
```

The install is sanity-checked and atomically replaces the resolved executable.
That means an install.sh binary in `~/.local/bin` is replaced directly; a
Homebrew entry keeps its public symlink and replaces the currently linked keg
binary. Homebrew may overwrite that development build during a later upgrade or
reinstall. For a development build that survives Homebrew upgrades, use an
explicit `~/.local/bin` target and keep that directory before Homebrew in
`PATH`. To choose an explicit destination instead of the active `PATH` entry:

```sh
make install MARLIN_INSTALL_TARGET="$HOME/.local/bin/marlin"
```

The script refuses to overwrite an existing executable that does not identify
itself as Marlin. `make install` only activates the new client executable; a
running daemon keeps its old executable until `marlin reboot` succeeds. If a
turn or approval prevents a normal reboot, resolve it first rather than forcing
an install-time shutdown.

Run `make test-install` to exercise the developer installer without touching
your real installation.

## License

Marlin is licensed under the [Apache License 2.0](LICENSE).
Copyright 2026 Jesper Noehr <jesper@noehr.org>.

Third-party attributions are listed in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
