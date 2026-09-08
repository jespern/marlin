# marlin

**A durable session multiplexer for AI agents, written in Zig.**

One static binary. A daemon that owns your agent sessions and keeps them running;
thin clients that attach locally or over SSH. Run native and vendor agents
in one workspace, with searchable transcripts and structured approvals.

## Install

Install the latest macOS or Linux release in `~/.local/bin` without sudo:

```sh
curl -fsSL https://marlin.wtf/install.sh | sh
```

The installer selects the release for your architecture and verifies its
SHA-256 checksum. To pin this release, pipe into `MARLIN_VERSION=0.1.4 sh`.

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

## One place for ongoing agent work

Marlin keeps agent sessions running in a daemon. The terminal UI, headless
CLI, and optional phone web client all consume the same structured protocol.
Close a client, move to another machine, and attach again: the daemon keeps
working as long as its host stays running.

Use Marlin's native agent with OpenRouter, Anthropic, or an OpenAI-compatible
endpoint, or host installed Claude Code and Codex agents using their existing
logins. Guest agents own their inference, tools, context, and permissions;
Marlin supplies the shared session interface. Switching between native and
guest backends involves a context handover; see
[native and guest sessions](docs/ARCHITECTURE.md#native-vs-guest-agents).

```sh
marlin                         # open the TUI; setup runs on first use
marlin ls                      # list durable sessions and short handles
marlin attach 63df              # reattach using a unique handle prefix
marlin attach --session-file .marlin-session  # publish the selected full handle
marlin inspect 63df --json      # inspect state, recent blocks, and diagnostics
marlin top                     # live session tree, including child work
```

Inside the TUI, `/new` starts a session, `/model` selects its agent/model,
`/cwd <path>` changes its working directory while idle, `Ctrl+S` opens the
session switcher, and `/detach` closes the client while work
continues. `marlin --remote <host>` attaches through SSH.

## What makes it useful

- **Durable, searchable work.** Messages, tool calls, results, plans, and
  approvals are structured blocks in SQLite. Compaction changes what the
  model sees while preserving the original transcript and full tool outputs.
  `/search <query>` searches across sessions; `!c` copies the last tool output.
- **A clear view of ongoing work.** Root tabs roll up child activity and
  approvals. The activity row distinguishes model wait, streaming, tools,
  delegation, and compaction. `/diagnostics` separates provider latency,
  time to first token, tool time, and failures.
- **Approvals you can return to.** Permission requests are protocol events.
  Attach from another terminal or use the optional phone client to answer a
  parked request. Native and guest permissions have different owners; the
  interface reports that distinction.
- **Planning and delegation.** Shift+Tab enters Plan mode. Native execution
  plans survive compaction and restart; `task` and `task_batch` create durable,
  attachable children for focused read-only work. Configured review councils
  combine model perspectives through the same delegation mechanism.
- **Terminal ergonomics.** Modal editing, `Ctrl+R` input history, transcript
  search, image attachments, and shell escapes keep routine work close.
  `!<command>` runs in the session workspace; bare `!` opens a local shell.
  Direct remote attachments refuse shell escapes; use Marlin inside SSH or
  mosh when the terminal and workspace live on another host.
  See [terminal effects](docs/TERMINAL_EFFECTS.md) for the optional playful bits.
- **Small deployment footprint.** One native binary, daemon-owned setup and
  credentials, and SSH for remote transport. MCP servers, custom tools, and
  hooks extend it at process boundaries.

Marlin is a daily driver under active development. Multiple panes are
[planned](docs/PANES_PLAN.md); the current TUI uses tabs and one focused view.

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
   its keep gets deleted rather than maintained. Unshipped work, including workspace snapshots, waits until daily use
   demands it. When in doubt, the answer is no.

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
- No hosted or multi-user web product. the daemon-managed web companion is an opt-in,
  localhost-only client on the same protocol, fronted by `tailscale serve`
  and Host/Origin-checked (no token; the tailnet is the gate) — install it to a
  phone home screen to watch sessions and answer parked approvals over your
  own tailnet. See [mobile companion setup](docs/MOBILE.md) for the stable phone address
  and optional presence-aware notifications.
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
