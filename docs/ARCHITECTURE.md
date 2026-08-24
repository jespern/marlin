# marlin architecture

Status: pre-code design. Everything here is v1 scope unless marked (v2).

## 1. Process model

Two binaries built from one codebase (or one binary with subcommands — start
with the latter, it's simpler to ship):

- `marlin daemon` — **marlind**. Owns all state: sessions, agent loops, SQLite,
  provider connections, tool execution, MCP clients, hooks. Runs until killed.
  Autostarted on first `marlin` invocation if not running (flock + pidfile).
- `marlin` (default: attach) — the TUI client. Connects to the daemon socket,
  speaks the wire protocol, renders. Zero agent logic. Multiple clients can
  attach simultaneously, to the same or different sessions.
- `marlin run "task"` — headless one-shot: create session, run to completion,
  print result, exit nonzero on failure. Doubles as the eval harness.
- `marlin ls / attach <id> / kill <id>` — thin protocol clients for scripting.

Remote use is ssh as dumb transport, exactly herdr's pattern:

```
ssh box                 # then: marlin            (attach over unix socket)
ssh -t box marlin       # one hop
mosh box -- marlin      # roaming
```

The daemon listens on a **unix socket** (`$XDG_RUNTIME_DIR/marlin/daemon.sock`,
mode 0600) by default. An optional TCP listener (`--listen host:port`, token
auth) exists for the (v2) web client; unix-socket-only is the v1 default and
the tailnet covers remote machines via ssh.

### Self-hosting reboot (`/reboot`)

Marlin is developed from inside marlin, so daemon+client must re-exec onto a
freshly built binary without losing where you were. Design premise: **a
reboot is a voluntary, coordinated crash** — it exercises exactly the
crash-resilience path (store is truth, clients replay with from_seq). If
`/reboot` and `kill -9` + restart don't converge to the same restored state,
the reboot is lying about the crash story; e2e test both and diff.

Sequence:

1. **Binary selection.** `/reboot` re-execs the path argv[0] resolved to at
   daemon start (you `zig build` beforehand; binary lives at a stable path).
   `/reboot --build` runs `zig build` first, streams output into a
   `system_note` block, and proceeds only on success. Either way the
   candidate is sanity-exec'd (`--version`) before committing —
   exec-into-broken-binary is the one unrecoverable failure (daemon gone,
   nothing to reattach), so it must be impossible.
2. **Quiesce.** Default: wait for running turns to reach a block boundary.
   `/reboot!` interrupts instead: finalized blocks are truth, partial delta
   buffers are discardable; interrupted sessions get a `system_note`
   ("interrupted by reboot") and resume with `--continue`. Running
   background bash tasks are listed for confirmation (they get orphaned).
3. **Daemon exit.** Persist, release flock, exit. No exec on the daemon
   side — the client's autostart path (flock + pidfile, already spec'd)
   brings up the new binary. One mechanism, not two.
4. **Client re-exec.** Client writes a small lossy UI snapshot (focused
   session, split layout, input draft) to JSON, exec()s the new binary,
   which autostarts the new daemon, reattaches with from_seq replay, and
   restores the snapshot. Snapshot fails to parse across versions → default
   layout, same session: annoyance, not data loss.
5. **Version skew.** On boot the daemon runs store migrations before
   accepting clients; the handshake rejects mismatched proto_version so
   old-client/new-daemon is a clean error, never a crash.

What survives: everything durable (sessions, block logs, blobs, approvals,
config) — by construction, since store ≠ context. What's rebuilt: in-flight
turns (resumable), MCP server processes (spawn-on-use), UI state
(best-effort snapshot).

### Concurrency model

One OS thread per running agent turn (they're 99% blocked on network/subprocess),
plus the main daemon thread multiplexing client I/O with poll/kqueue/epoll.
Session state is owned by the daemon thread; agent threads communicate with it
exclusively via a mutex-protected event queue (agent thread produces events,
daemon thread applies them to state, persists, and fans out to clients).
No shared mutable session state across threads. Zig's std.Thread + a small
MPSC queue is enough; no async runtime needed in v1.

## 2. Data model: the block log

The atom of marlin is the **block**. A session is an append-only sequence of
blocks. Blocks are immutable once written; every feature (rendering, scrollback,
copy, compaction, resume, search) is a view over the block log.

```zig
const BlockKind = enum {
    user_msg,        // user input text
    assistant_msg,   // final assistant text for a turn
    reasoning,       // thinking/reasoning content (if provider surfaces it)
    tool_call,       // id, name, arguments (as sent to tool)
    tool_result,     // id, status, inline_body (capped), full_body_ref
    approval,        // request + resolution (granted/denied/timeout, by whom)
    steer,           // mid-turn user interrupt text
    compaction,      // summary text + range of blocks it replaces in context
    system_note,     // model switch, error, session config change
};
```

Key decisions:

- **`tool_result` stores full output out-of-band.** `inline_body` is the capped
  head+tail actually eligible for model context; `full_body_ref` points to a
  content-addressed blob (SQLite blob table; files on disk if >1MB). `!c` and
  scrollback read the full blob; context assembly reads `inline_body`. The cap
  happens at capture time for the *inline* copy only — the full output is never
  lost. (Hermes pattern.)
- **`compaction` is a block, not an edit.** It records "blocks [a..b] are
  represented by this summary in context from now on." History is untouched.
- **Turn grouping**: blocks carry `turn_id` so the UI can collapse/expand a
  whole turn (user msg → reasoning → N tool roundtrips → assistant msg).

### Storage: SQLite, one DB

`~/.local/state/marlin/marlin.db` (WAL mode). Tables:

```
sessions(id, title, created_at, cwd, model, provider, status,
         pinned_context, config_json)
blocks(id, session_id, turn_id, seq, kind, ts, body_json)
blobs(hash, bytes)                      -- full tool outputs, content-addressed
blocks_fts(...)                         -- FTS5 over user/assistant/tool text
kv(key, value)                          -- daemon metadata, schema version
```

WAL gives crash safety without JSONL's rewrite-on-vacuum issues, and FTS5 gives
cross-session search for free. (zag uses JSONL+tail-recovery; we get the same
crash property from WAL with better query power. If SQLite ever feels heavy,
the block log abstraction makes swapping trivial — nothing outside `store/`
knows it's SQLite.)

## 3. Wire protocol (client ⇄ daemon)

Newline-delimited JSON over the socket. Length-prefixed binary is a premature
optimization; NDJSON is debuggable with `nc` + `jq` and fast enough for
terminal-rate traffic. Every message: `{"t": "<type>", "sid": ..., ...}`.

Client → daemon:

```
hello {proto_version, client_kind}
session.create {cwd, model?, title?}
session.list / session.kill / session.rename
sub {sid, from_seq}        // subscribe; daemon replays blocks from seq, then live
unsub {sid}
input {sid, text}          // user message (or steer, if a turn is running)
approve {sid, approval_id, decision}
interrupt {sid}            // cancel in-flight turn (Ctrl+C semantics)
compact {sid, instructions?}
copy.query {sid, what}     // "last_tool_result" | "last_msg" | "last_code" | ...
                           // returns full text; client does OSC 52 locally
```

Daemon → client:

```
block {sid, block}             // a finalized block was appended
delta {sid, turn_id, text}     // streaming assistant/reasoning text
status {sid, state}            // idle | running | awaiting_approval | error
approval.request {sid, approval_id, tool, args_preview, risk}
session.meta {sid, title, model, token_usage, ...}
err {code, msg}
```

Two stream disciplines worth locking in now:

- **Deltas are ephemeral; blocks are truth.** Clients render deltas for
  liveness, then replace the streaming region with the finalized block. A
  client that attaches mid-turn gets replayed blocks + current partial delta
  buffer. This makes reconnect/multi-client trivial.
- **`from_seq` resume.** Clients remember the last block seq they've seen per
  session; reattach replays only the gap. Scrollback beyond what's in client
  memory is fetched with `blocks.get {sid, before_seq, limit}`.

## 4. Agent loop

Per running turn, in its own thread:

```
assemble context (see §6)
loop:
    stream POST to provider (SSE)
      → emit delta events as text arrives
      → collect tool_calls (may be several)
    if no tool_calls: finalize assistant_msg block; done
    for each tool_call (parallel where safe, see below):
      approval gate (§7) — may block on client response w/ timeout
      execute tool → tool_result block (cap inline, blob full)
    check steer queue: if user typed mid-turn, inject steer block
      as a user-role message before next request   [zag's pattern]
    loop
```

- **Parallel tool execution**: read-only tools (read/grep/glob/fetch) run
  concurrently; anything mutating (bash, write, edit) serializes. Tools declare
  `.parallel_safe` in their spec.
- **Cancellation**: interrupt sets an atomic flag; the HTTP read loop and tool
  subprocess waits poll it. Subprocesses get SIGTERM → grace → SIGKILL. The
  half-finished turn is finalized as an interrupted `system_note` + whatever
  blocks completed (the log stays consistent).
- **Retry/backoff**: on 429/5xx/mid-stream disconnect: exponential backoff w/
  jitter, max N attempts. A turn that dies mid-stream discards the partial
  assistant text (deltas were never truth) and re-requests — context is
  unchanged, so this is safe and cache-friendly.
- **Malformed tool JSON**: lenient repair pass (strip trailing commas/garbage,
  balance braces, unescape common damage) before failing; on failure, feed the
  parse error back to the model as the tool result — models self-correct.

## 5. Providers

One internal chat representation (blocks → messages), three wire dialects:

```
provider/
  openai_compat.zig   // OpenRouter, OpenAI, DeepSeek, Groq, local llama.cpp, ...
  anthropic.zig       // Messages API: explicit cache_control breakpoints
  registry.zig        // model string "openrouter/anthropic/claude-..." → dialect + base_url + key env
```

- OpenRouter is the default registry entry; `base_url` + `api_key_env` in
  config adds any OpenAI-compatible endpoint without code.
- **Usage accounting is provider-reported**: every response's `usage` field is
  stored on the session (`session.meta` event carries it to clients). Token
  estimates for un-sent deltas use bytes/4 — good enough because true usage
  resyncs every turn. No tokenizers in the binary.
- Anthropic dialect sets `cache_control` on the system prompt and on the last
  stable message before the tail. OpenAI-compat relies on implicit prefix
  caching, which our append-only discipline (§6) maximizes automatically.
- HTTP: libcurl via C interop for v1 (TLS, HTTP/2, proxies, battle-tested SSE
  chunking). `std.http.Client` can replace it later behind the same interface;
  pragmatism beats purity while std matures.

## 6. Context assembly & compaction

Context for each request is **derived** from the block log at turn start:

```
[system prompt]  (stable per session: base + skills index + pinned context)
[compaction summaries, oldest first]      // from compaction blocks
[blocks after last compaction point, mapped to messages]
```

The cascade (in order; each layer only fires if the previous wasn't enough):

- **L0 — capture caps (always on).** Inline tool bodies capped (default 8k
  chars head+tail w/ elision marker + "full output: !c / blob ref"). Nothing
  bulky ever enters the assembly path raw.
- **L1 — mechanical pruning (no LLM).** When assembled size > soft threshold:
  walk tool_result blocks oldest-first, replacing inline bodies with a one-line
  stub ("[output elided — re-run or read <path>]"), *protecting* the most
  recent ~40k tokens of tool output. Never touches user/assistant text
  (irregenerable). Constants stolen from OpenCode: PROTECT=40k, MIN_RECLAIM=20k.
  NOTE: pruning changes assembled context → it is a cache break. Fire it
  rarely (hysteresis: prune down to well below threshold, then strict
  append-only again), never per-turn.
- **L2 — summarization compaction (LLM).** Trigger: headroom accounting —
  compact when `context_limit - used < output_headroom + compaction_headroom`
  (defaults: 16k + 8k), checked at turn boundaries; effective trigger lands
  around 80–85% on big-window models. Also manual: `/compact [instructions]`.
  Mechanics:
    1. Summarize blocks [start..cut] with the structured contract: accomplished /
       in-progress / files touched (paths!) / next steps / user constraints &
       decisions. Cheap model configurable (`compaction_model`).
    2. Append `compaction` block; context assembly now emits summary + tail.
    3. **Rehydrate**: re-inject head+tail of the N most recently *written*
       files (from tool_call history) + open todos + a continuation note.
       (Claude Code's insight: summary-only compaction is amnesia.)
  Don't compact tiny sessions (< min_blocks); don't compact twice in a row
  without progress between.
- **L3 — subagents (architectural).** `task` tool spawns a child session with
  its own context, allowlisted tools, and model; only its final summary enters
  the parent as a tool_result. Child sessions are ordinary sessions (visible
  in `marlin ls`, attachable read-only) — the multiplexer shows them nested
  under the parent.

Cache discipline, stated once: between L1/L2 events the assembly is strictly
append-only with a byte-stable prefix. L1/L2 are the only cache breaks, both
rare and both logged as `system_note` blocks so cost anomalies are explainable.

## 7. Tools & safety

Built-in (pi-minimalist, ~7):

```
bash        (mutating, approval-gated by default)
read_file   (parallel_safe)
write_file  (mutating)
edit        (string-replace w/ fuzzy fallback; mutating)
grep        (ripgrep if present, else internal; parallel_safe)
glob        (parallel_safe)
fetch       (HTTP GET → markdown-ish text; parallel_safe)
task        (subagent spawn; v1.5)
```

**Approval system** (designed in from day one — every execution flows through it):

- Policy per tool per session: `auto | ask | deny`. Default: read-only tools
  auto, mutating tools ask. `--yolo` flips everything to auto for a session.
- Allowlist patterns promote repeated approvals: approving `git status` offers
  "always allow `git *` in this session".
- An `ask` emits `approval.request` to *all* subscribed clients; first decision
  wins; timeout (default: none — turn parks in `awaiting_approval`, exactly the
  state the sidebar/phone surfaces).
- bash sandboxing (v1.5, stolen from zag): seatbelt profile on macOS, Landlock
  + seccomp on Linux; deny-by-default on `~/.ssh`, key files, browser profiles.

**Extension tools — process boundaries only:**

- **MCP client** (v1): stdio transport first, HTTP later. Config lists servers;
  their tools appear in the registry namespaced (`mcp:playwright:click`).
  Approval policy applies identically.
- **Exec tools**: a config entry maps name+JSON-schema → executable; marlin
  passes args as JSON on stdin, stdout is the result. A shell script is a tool.
- **Hooks**: `on_session_done`, `on_approval_needed`, `on_error`, `on_turn_done`
  → run script with JSON event on stdin. This is the notification story
  (ntfy/Telegram/say) without a gateway in the core.

**Skills** (v1, because it's cheap and high-value): markdown files with YAML
frontmatter in `~/.config/marlin/skills/`; index (name + one-line description)
injected into the system prompt; `skill` tool loads full content on demand.
Compatible with the emerging cross-tool skills convention.

## 8. TUI client

libvaxis. Modal, vim-flavored, herdr-lookalike layout:

### UX principles (taste decisions, decided early — Aug 2026)

Learned from daily-driving Claude Code, Codex CLI, and Hermes (the first two
get these right; Hermes is the counter-example):

- **Full-screen alt-screen TUI, always.** Cell-grid rendering, never
  line-by-line append to the scrollback. Line-oriented output is the root
  cause of janky buffering; owning the whole screen is why Claude Code's
  "fullscreen" mode feels solid. (libvaxis gives us this for free — treat it
  as a commitment, not an implementation detail.)
- **Status bar is signal-only.** Model, context %, cost, session state —
  things that change a decision *right now*. No session-duration counters, no
  feature-toggle indicators, no diagnostic chrome. Every candidate status item
  answers "would I act on this mid-turn?" or it stays out.
- **Todo/plan list pinned above the input** when the agent maintains one:
  current step highlighted, done items dimmed/checked. Always visible without
  scrolling — "where is it in the plan" must never require leaving the live
  region. Collapses to nothing when there's no plan.
- **Progress chrome is a capped stack of live strips.** The region between
  session view and input holds one-line strips: the todo strip, a review
  fan-out row (`sol ✓ · grok … · glm ✓`), later background-task rows. Rules
  that keep it from becoming a dashboard: (1) each strip has a collapsed
  one-glyph form (`▸ wire store (3/7)`, `review 3/4 ✓`); only the most
  recently changed (or focused) strip renders expanded. (2) Hard cap ~3
  strips; overflow demotes to a status-bar segment. (3) **Attach before
  stacking**: if a long-running activity corresponds to a plan step, its
  progress renders inline on that todo line
  (`▸ adversarial review  sol ✓ grok … glm ✓`) instead of spawning its own
  strip — the common case stays at exactly one strip. A strip must be live
  (recently changed, potentially actionable) to hold vertical space.
- **Liveness via text shimmer.** While a turn runs, the working indicator is
  an animated gradient/shimmer on the status word (the Claude/Codex rainbow
  effect), not spinner characters and not log lines. Cheap in a cell grid:
  cycle fg color across the word per frame.
- **Diffs render like a diff tool, not like raw patch output.** Foreground
  green/red on the normal background, gutter `+`/`-`, dim line numbers,
  optional word-level emphasis within changed lines. Never full-line
  colored backgrounds — jarring and unreadable with syntax coloring.
  Lives in the block renderer next to markdown.zig; edit-tool results render
  as diffs by default.

```
┌ sidebar ──────┬─ main: session view ────────────────┐
│ ● 1 api-fix   │  blocks rendered as cards:          │
│ ◐ 2 refactor  │  user / assistant md / tool collapse│
│ ⚠ 3 deploy    │  [streaming region at bottom]       │
│   (⚠ = needs  │                                     │
│    approval)  ├─ todo (when present) ───────────────┤
│               │ ✓ parse args   ▸ wire store   · tui │
│               ├─ input ─────────────────────────────┤
│               │ > _                                 │
└───────────────┴─ status: model · ctx% · $ · state ──┘
```

- **Modes**: insert (typing → input box), normal (j/k scroll blocks, J/K
  sessions, Enter attach, v visual-select, y yank, s/x split, tab cycle panes).
  Prefix-key compat layer later if muscle memory demands it.
- **Splits**: binary-tree layout, each pane = a session view (or the same
  session twice). No VTE anywhere.
- **Scrollback**: virtual list over the block log; lazy `blocks.get` when
  scrolling past memory. Selection is ours (mouse mode on): drag selects
  logical text within/across blocks; double-click = word, triple = block.
  Copy → OSC 52 (works through ssh/mosh); shift+drag falls through to the
  terminal for native selection as escape hatch.
- **Copy commands**: `!c` last tool result (full blob, not inline cap),
  `!c msg` / `!c code` / `!c cmd` / `!c all`; `!y` / `!p [sid]` for the
  daemon-side register (cross-session paste, no OS clipboard).
- **Command namespace**: `/` = session & harness commands (`/model`, `/compact`,
  `/new`, `/allow`), `!` = copy/clipboard family. Plain text = message to agent.
  `Esc` during a turn = queue steer text; `Ctrl+C` = interrupt.
- Tool blocks render collapsed by default (name + one-line summary + status),
  expand on demand. Approvals render as inline prompt cards.

## 9. Config

`~/.config/marlin/config.toml` (TOML: comments + zig-toml exists; no YAML dep):

```toml
[daemon]
socket = "default"            # or a path; "tcp:0.0.0.0:7777" enables token auth

[model]
default = "openrouter/anthropic/claude-sonnet-4-5"
compaction = "openrouter/google/gemini-2.5-flash"

[providers.openrouter]
api_key_env = "OPENROUTER_API_KEY"

[providers.local]             # any OpenAI-compatible endpoint
base_url = "http://localhost:8080/v1"
api_key_env = "NONE"

[context]
output_headroom = 16000
compaction_headroom = 8000
inline_tool_cap = 8000

[approval]
default_mutating = "ask"

[[tools.exec]]
name = "deploy_status"
cmd = "~/.config/marlin/tools/deploy-status.sh"
schema = '{"type":"object","properties":{}}'

[[mcp]]
name = "playwright"
cmd = ["npx", "@playwright/mcp"]

[hooks]
on_approval_needed = "~/.config/marlin/hooks/notify.sh"
on_session_done = "~/.config/marlin/hooks/notify.sh"
```

## 10. Dependencies (deliberate, few)

| Dep | Why | Risk hedge |
|---|---|---|
| libcurl (C) | HTTPS/SSE/HTTP2, everywhere already | swap for std.http later behind iface |
| SQLite (C) | store + FTS5, everywhere already | block-log iface hides it |
| libvaxis (Zig) | TUI: input, mouse, OSC52, unicode width | active, Ghostty-adjacent |
| zig-toml (Zig) | config | tiny; vendor it |
| std.json | strict parse + our lenient-repair layer on top | — |

Everything else: std. No async framework, no allocator exotica (GPA +
arena-per-turn; blocks are write-once so arenas fit naturally).

## 11. Testing strategy (from day one, zag-inspired)

- **Protocol golden tests**: recorded NDJSON daemon⇄client transcripts replayed
  against the daemon.
- **Provider fixture tests**: recorded SSE streams (happy path, mid-stream
  drop, malformed tool JSON, 429s) replayed into the dialect parsers. No
  network in unit tests.
- **Headless e2e**: `marlin run` against a scripted fake provider binary
  (speaks OpenAI wire format over localhost) exercising the full daemon path:
  tools, approvals (auto), compaction trigger, resume.
- **The eval escape hatch**: `marlin run --provider real` smoke suite, run
  manually/CI-nightly, never in the inner loop.
```
