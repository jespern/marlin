# marlin architecture

Status: implemented and verified through M6a (`task` plus bounded `task_batch`). This began
as the pre-code design and most of it is now law — but not all of it: anything
marked **(v2)**, **(design)**, or **(not yet implemented)** describes intent,
not the binary. When this document and the code disagree on a shipped area,
the code and the per-milestone docs (M*_PLAN.md, PERMISSIONS.md, PROTOCOL.md)
win; fix this file rather than trusting it.

Product thesis, standing over every section below: Marlin is a **daily
driver** — a session multiplexer with one native agent and one guest,
meant to be lived in all day, and nothing else. It consolidates a
heterogeneous model fleet (subscription Fable as guest; grok/GLM/GPT and
the rest as native sessions, picked per task by preference or credits)
that previously lived in separate vendor CLIs under a terminal mux.
Marlin is already the first tool open in the morning; the vendor CLIs it
replaces are the benchmark, and a feature is justified when it deletes a
reason to open one of them — not because the last door felt good. A
section of this document that reads like a second product is a bug in
the document.

## 1. Process model

Two binaries built from one codebase (or one binary with subcommands — start
with the latter, it's simpler to ship):

- `marlin daemon` — **marlind**. Owns all state: sessions, agent loops, SQLite,
  provider connections, tool execution, MCP clients, hooks. Runs until killed.
  Autostarted on first `marlin` invocation if not running (flock + pidfile).
  Autostart is a handshake, not a timer: the client spawns
  `marlin daemon --ready-stdout` and waits on the one byte the daemon writes
  right after `listen()` — patient while its child is visibly still starting
  (MCP discovery runs in parallel but still completes before the socket
  opens), failing fast if the child dies.
- `marlin` (default: attach) — the TUI client. Connects to the daemon socket,
  speaks the wire protocol, renders. Zero agent logic. Multiple clients can
  attach simultaneously, to the same or different sessions.
- `marlin run "task"` — headless one-shot: create session, run to completion,
  print result, exit nonzero on failure. Doubles as the eval harness.
- `marlin ls / inspect <handle> / attach <handle> / archive <handle> /
  unarchive <handle> / kill <handle>` — thin protocol clients for scripting.
  `inspect` is the supported read-only investigation surface: it combines the
  session catalog, bounded block replay, latest plan, live status, and local
  diagnostics without exposing SQLite schema details.

### Native vs guest agents

Marlin is a **session multiplexer with a native agent**. Some sessions
run that agent. Some sessions host someone else's.

**Native** (`openrouter/`, `anthropic/`, `local/`): Marlin owns the turn.
§4–§7 apply in full — context assembly, Marlin tools, Seatbelt, MCP,
`task`/`task_batch`, `plan_update`, L0/L1/L2. The TUI is a client of this
loop. This is the product.

**Guest** (`claudecode/`, `codex/`): an official vendor agent owns the turn.
Claude Code runs through `claude -p`; Codex runs through the stable
`codex app-server` JSONL protocol and uses the account already established by
`codex login` (including ChatGPT subscription login). Marlin's job is the
multiplexer: persist structured events as blocks, attach, interrupt, resume
the vendor thread, copy, and park *their* permission prompts on *our* approval
bar. Marlin tools, Seatbelt, network screening, MCP-as-agent-tools,
`task`/`task_batch`, `plan_update`, and L0/L1/L2 **do not reach inside the
subprocess.**

Guest is a session regime, not a model. Kitchen-sink is chasing parity so
a guest tab feels like a native tab. The guest boundary is frozen at:

1. spawn the official binary (`claude -p` or `codex app-server`)
2. map its structured event stream → blocks. One event line can be far
   larger than the reader's buffer (Claude Code embeds whole-file contents
   in Edit results), so the reader assembles oversized lines rather than
   mistaking them for end of stream; only a line over 64 MiB is dropped,
   with a visible system note (`guest/shared.zig` `takeEventLine`)
3. interrupt / reboot / resume
4. permission requests onto the existing approval bar (mux UX, not harness UX)
5. session status (running / awaiting_approval / idle)

Nothing else. Semantic rendering of unknown tools is a TUI fact, not a
guest-tool catalogue. Images stay durable in Marlin and are not smuggled
into the binary. `/compact`, `/sandbox`, session `/network`, and Marlin
tool dispatch are native-only; a guest session that receives them must
refuse at the protocol, not start a turn and fail with an internal name.
`/effort` is the exception that still applies: Marlin forwards it to the guest
when that guest/model supports the selected value.

`/new` is native. Guest is opt-in. `/model` **may cross the wall** on a
live session: that is a regime change for the *next* turn, not a new
thread. Harness verbs follow the current regime (`/compact` starts
working after guest→native; it must refuse while the session is guest).
The durable agent field updates with the model string.

The real hazard is **context continuity**, not mixing logs:

- **guest→native:** Marlin's loop already derives the next request from
  the block log. Guest tool names become history; that is fine.
- **native→guest:** the vendor agent does not read Marlin's store. `/model
  claudecode/…` or `/model codex/default` starts a **native** handover turn before the regime
  flips: the current model writes a visible briefing (streamed into the
  transcript, persisted as a `[handover]` system_note). The TUI shows
  "switching to a guest model, generating handover summary…". On
  completion (or failure — the switch is not blocked) the session
  becomes guest; the guest's first prompt is that briefing plus the
  user's next message. Empty native logs skip the LLM.
- **guest→different guest:** refused directly. Switch through a native model
  so the native handover turn can bridge the two private context stores.

Today the regime is inferred from the model prefix. See "Making the wall true."

The day Anthropic ships a subscriber-legal Messages endpoint, guest
sessions become a weekend deletion and Fable is a native model. Until
then the wall is how Marlin stays small.

**Making the wall true** (honest: not all of this is code yet):

- Backend routing is explicit (`native` dialect or named guest), rather than
  pretending a guest is a wire dialect. `SessionKind` stays hierarchy (`root` /
  `task_child` / `review_child`); agent is orthogonal.
- Protocol reject: `/compact`, `/sandbox`, `/network` (session toggle)
  **while the session is guest**. `/effort` is forwarded through the guest's
  supported protocol (`claude --effort` or Codex turn effort); `auto` omits
  the override. `/mcp` stays daemon-global.
  `/model` that crosses native→guest runs the visible native handover
  turn, then flips the model. Guest `/compact` refuses at the protocol
  (`err{guest}`).
- Picker and status name the regime: guest models keep their place in
  the list, prefixed `(guest)`. Status shows `(guest) {name}` and dims
  ctx/sandbox/dnsblock as `n/a` (unavailable, not off — Marlin does not
  own the guest's context window). Native remains the `/new` default.
- Permission bridge (`marlin cc_approve`) is mux: fail-closed to *ask*,
  never a shell parser, never applied to native `read_file`. Auto-allow
  of CC `Read` (including paths outside the workspace) is CC's policy,
  documented as such, not Marlin protected-path enforcement.
- Do not spawn Marlin `task` children from a guest parent. Do not grow
  `ccAutoAllow`. Do not add guest-specific product (CC plan sync, wrapping
  Seatbelt around their bash, vision side-channel).
- Guest models as council/task *children* are allowed (SHIPPED): the
  bridge enforces read-only for any non-root guest session —
  `permissions.ccReadOnlyAllow` grants reads/searches and DENIES
  everything else outright (never asks: a background child must not park
  surprise prompts), checked before approval mode so neither yolo nor
  /permissions can hand a reviewer write access. The deny carries a
  policy message so the model reads it as policy, not a human's no. This
  is a deny mode on the bridge, not growth of `ccAutoAllow`.
- Type-system: `Dialect` is wire (`openrouter` | `openai_compatible` |
  `anthropic`); `provider.Backend` is `native(Dialect) | guest(Guest)`.
  The guest runtimes live in `src/daemon/guest/{claude_code_turn,
  codex_turn,shared}.zig` and borrow only the block appender, turn options,
  phase/steer helpers, and approval resolution from `loop.zig` — the wall
  is a file boundary the compiler enforces, not a paragraph.

### Session identity at the human boundary

SQLite and the wire protocol keep sortable `u64` session ids. User-facing
surfaces do not expose those unwieldy numbers: they derive a stable,
domain-separated SHA-256 handle and normally show its first eight lowercase
hex characters. Commands accept any case-insensitive unique prefix of at least
four characters (`marlin attach 63df`); resolution includes archived sessions,
never silently picks an ambiguous match, and listings extend beyond eight
characters if a collision requires it. Exact decimal ids remain accepted for
backward compatibility, but new scripts should consume the handle from
`marlin ls`.

### Remote access: two modes, one blessed

**One marlind per USER (not per machine).** The daemon owns every session
for that user on that box; `$XDG_RUNTIME_DIR/marlin/daemon.sock` (0600,
per-user by construction) encodes this. Two users on one machine = two
daemons, mutually invisible. Autostart/flock logic stays inside the user's
runtime dir, never system-wide. Clients — local or remote — are ephemeral
views: nothing lives in a client but a render cache and a draft input box.

**Mode B — protocol over ssh (SHIPPED; the primary remote path).**

Decision (2026-08): Mode B is the herdr/tmux replacement. The end state is
the remote-named invocation as the ONLY terminal tool in the daily drive —
full mux (tabs, approvals, drafts), local clipboard and image paste,
OSC 52 — with ssh as a dumb pipe underneath. No new transport protocol,
ever. The web client is the companion for phones and terminal-less
machines, exposed via automatic `tailscale serve` in front of the
localhost port (Host/Origin-checked, tokenless — the tailnet is the trust
boundary) rather than marlin-grown TLS/auth machinery.

A local `marlin` client speaks the wire protocol to a remote daemon, ssh
carrying NDJSON instead of terminal frames. `--remote <host>` routes the
whole invocation, so every subcommand works remotely:

```
marlin --remote work             # TUI attached to the work box's daemon
marlin --remote work ls
marlin --remote work run "task"
marlin --remote work web         # browser UI served locally, remote daemon
```

Transport is `ssh <host> sh -lc 'exec marlin _pipe'`: an internal
stdio↔daemon.sock bridge on the remote (readiness-probed, with daemon
autostart), spawned per connection as a child of the local client. The
login shell is deliberate — non-interactive ssh shells miss ~/.local/bin
and homebrew on most setups — and ssh's stderr is inherited, so
first-connect host-key prompts, passphrase prompts, and 'command not
found' reach the terminal instead of dying invisibly into a timeout. Dispatch puts the host in
MARLIN_REMOTE, which `attach.connect` reads — so the TUI, its reconnects,
headless commands, and the web bridge all inherit remote support from the
one connect path. Marlin keeps NO host registry: `<host>` goes to ssh
verbatim, and ssh config owns naming, keys, agent, and jump hosts. A shell
alias covers the daily case (`alias mw='marlin --remote work'`). mosh
remains a Mode A transport only — it carries terminal frames, not stdio.

`marlin` must be installed on the remote and findable by a login shell (the
connect error says how to test). Source-built installations get scoped
self-hosting rebuilds: bare `!rb` rebuilds the side hosting the attached daemon,
`!rb client` rebuilds only the local client, and `!rb both` builds both before
restarting anything. Each build is gated on the running executable resolving to
`<checkout>/zig-out/bin/marlin` with Marlin checkout markers; install.sh and
Homebrew binaries refuse with package-manager guidance rather than guessing an
update mechanism. A remote client needs no local provider key — providers live
with the daemon — so first-run onboarding is skipped when MARLIN_REMOTE is set.

Why primary: from_seq replay resynchronizes STATE, not a screen — a
dropped connection reconnects with zero lost blocks (better than mosh for
this app, and mosh only ever repaired pixels). Typing/scroll/selection are
local-latency; only submits and steers cross the wire. The client runs
where the clipboard lives, so image paste works (the ssh-clipboard
limitation in §image/asset paste applies only to Mode A) and kitty
graphics / OSC 52 / OSC color queries negotiate with the user's actual
terminal.

Version skew is the tax: laptop client vs work daemon from different
builds. The proto_version handshake already rejects mismatches cleanly;
recovery should be one gesture — on mismatch, offer to copy the daemon's
binary down (or the client's up): single static binary makes the fix a
one-liner. Path semantics: tool output paths are daemon-side; any "open
file" gesture must know it's remote (scp-on-demand or just don't).

**Mode A — ssh as terminal transport (SHIPPED; the only mode today).**
`ssh -t box marlin` /
`mosh box -- marlin`: the TUI runs next to the daemon, the local terminal
just displays cells. Zero setup, works from machines that don't have
marlin installed at all (or via scp-and-run: the binary travels
trivially). Costs: every keystroke/scroll round-trips, no local clipboard
integration. Use when Mode B is degraded (skew you can't fix right now,
weird networks) or when you're already shelled in.

```
ssh box                 # then: marlin            (attach over unix socket)
ssh -t box marlin       # one hop
mosh box -- marlin      # roaming
```

The daemon listens on a **unix socket** (`$XDG_RUNTIME_DIR/marlin/daemon.sock`,
mode 0600) — that is the only listener; the TCP listener with token auth is
(v2) design that does not exist. What DOES ship today is `marlin web`: a
localhost-only HTTP/SSE bridge in front of the daemon socket (POC,
`src/client/web.zig`). It binds 127.0.0.1, has **no authentication** — anything
reaching the port can drive marlin, including reboot/shutdown — and therefore
requires the explicit `[web] enabled = true` (or `MARLIN_WEB=1`) opt-in.

### Self-hosting reboot (`/reboot`)

Marlin is developed from inside marlin, so daemon+client must re-exec onto a
freshly built binary without losing where you were. Design premise: **a
reboot is a voluntary, coordinated crash** — it exercises exactly the
crash-resilience path (store is truth, clients replay with from_seq). If
`/reboot` and `kill -9` + restart don't converge to the same restored state,
the reboot is lying about the crash story; e2e test both and diff.

Sequence:

1. **Binary selection.** `/reboot` restarts the attached daemon and re-execs
   the current client without building. `!rb` (the `/reboot --build` alias)
   rebuilds the side hosting the attached daemon; under Mode B the build runs
   through SSH on the remote. `!rb client` rebuilds/re-execs only the local
   client and leaves a remote daemon running. `!rb both` builds both candidates
   before rebooting the attached daemon, which is the protocol-change path.
   Source builds require the running executable to resolve to
   `<checkout>/zig-out/bin/marlin` and the checkout markers `.git`, `build.zig`,
   `build.zig.zon`, and `src/main.zig`; package installations refuse. Every
   candidate is sanity-exec'd (`version`) before any daemon exits.
2. **Quiesce.** Default: wait for running turns to reach a block boundary. A
   parked approval refuses a plain reboot visibly: once the requesting TUI
   exits there would be nobody left to answer it. `/reboot --force` interrupts
   instead: finalized blocks are truth, partial delta
   buffers are discardable; interrupted sessions get a `system_note`
   ("interrupted by reboot") and resume with `--continue`. Running
   background bash tasks are listed for confirmation (they get orphaned).
3. **Daemon exit.** Persist, stop accepting clients, unlink the public socket,
   then ACK and exit. Removing the socket before the ACK makes the client-side
   exec a clean handoff rather than a race with a dying listener. For a local
   reboot, the re-exec'd client autostarts the daemon. For a remote source
   rebuild, the held SSH helper starts the validated remote candidate after the
   ACK; the re-exec'd local client then reconnects normally. Connection setup
   also retries transient EOF/reset errors during `hello`, so it remains
   compatible with an older daemon that ACKs before releasing its socket.
4. **Client re-exec.** Client writes a small lossy UI snapshot (focused
   session, split layout, input draft) to JSON and exec()s the selected local
   binary. It autostarts a local daemon when needed or reconnects to the remote
   one, reattaches with from_seq replay, and restores the snapshot. Snapshot
   fails to parse across versions → default layout, same session: annoyance,
   not data loss.
5. **Version skew.** On boot the daemon runs store migrations before
   accepting clients; the handshake rejects mismatched proto_version so
   old-client/new-daemon is a clean error, never a crash.

What survives: everything durable (sessions, block logs, blobs, approvals,
config) — by construction, since store ≠ context. What's rebuilt: in-flight
turns (resumable), MCP server processes (spawn-on-use), UI state
(best-effort snapshot).

### Concurrency model

One dispatcher thread owns session lifecycle; every other thread produces
events into a mutex-protected MPSC queue that the dispatcher applies,
persists, and fans out. Producers: one thread per running agent turn (99%
blocked on network/subprocess), TWO per client connection (reader and
writer — `stopClientIo` depends on exactly that pair), the accept loop, a
shutdown watcher, and per-activity workers (compaction, handover, catalog
fetch, OTLP export, hooks, MCP watchdogs, guest subprocess watcher/drain,
tool and task-batch workers). The normative, kept-current inventory is the
header comment of `src/daemon/daemon.zig`; this paragraph is the summary.
Zig's std.Thread + a small MPSC queue; no async runtime.

The original "no shared mutable session state across threads" rule was
deliberately relaxed to ship mid-turn features (steering, live /permissions,
context gauges). The REAL protocol — normative copy in the `daemon.zig`
header, which is where it must be kept current:

- **Store is shared.** The single sqlite connection is opened FULLMUTEX
  (serialized); turn threads append blocks while the dispatcher answers
  queries.
- **Loaded sessions are a working set.** SQLite owns the durable catalog. An
  idle session is unloaded after its last subscriber leaves; running sessions
  unload after completion, and completed task children always unload. Successful
  one-shot children are also archived after their result reaches the parent, so
  they leave default navigation without losing their durable transcript. Failed
  or interrupted children remain visible and actionable. Opening an archived
  child explicitly rehydrates its small live state lazily.
- **Catalog snapshots establish authority; mutations are incremental.** A
  session watcher receives one initial list. Current clients then consume
  `session_upsert`/`session_remove`, so create/archive/model/config changes do
  not rescan the durable catalog; legacy watchers retain refreshed snapshots.
  Running/approval/idle transitions fan out compact `status{sid,state}` events.
- **Session identity/config is dispatcher-owned.** Turn threads snapshot
  those fields inside `startTurn` (still on the dispatcher thread); protocol
  mutations of them are rejected with `err{busy}` while a turn runs, which
  is what makes the snapshot sound.
- **A running turn may touch exactly the listed shared fields**, each with a
  stated discipline: atomics (`cancel`, `approval_mode_live`, `context_used`,
  `phase`, `phase_started_at_ms`), the internally-synchronized approval `gate`, the
  `steer_queue` plus `steer_accepting` under `steer_mutex`, and `prune_frontier` (turn-thread
  exclusive while running). `TurnJob.session` is a live pointer, not a copy;
  a new turn-visible field must be added to that list with its discipline.

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
    steer,           // mid-turn user follow-up text
    plan,            // immutable execution-plan revision; newest wins
    compaction,      // summary text + range of blocks it replaces in context
    system_note,     // model switch, error, session config change
};
```

Key decisions:

- **`tool_result` stores full output out-of-band.** `inline_body` is the capped
  head+tail actually eligible for model context; `full_body_ref` points to a
  content-addressed blob in SQLite. `!c` and
  scrollback read the full blob; context assembly reads `inline_body`. The cap
  happens at capture time for the *inline* copy only — the full output is never
  lost. (Hermes pattern.)
- **`compaction` is a block, not an edit.** It records "blocks [a..b] are
  represented by this summary in context from now on." History is untouched.
- **`plan` is durable state, not assistant prose.** `plan_update` appends a new
  revision; assembly retains the newest unfinished revision across compaction,
  and bounded replay restores it separately from scrollback depth. A terminal
  completed revision becomes a closed transcript table immediately. The daemon
  times only `in_progress` work and rejects `pending` → `completed` jumps, so
  every displayed completion duration has an observed start.
- **Synthetic `user_msg` blocks are model context, not user authorship.** File
  windows rehydrated after compaction carry `synthetic=true`; clients collapse
  them to a filename note and exclude them from input history. The default is
  false so logs and clients from before the marker remain compatible.
- **Turn grouping**: blocks carry `turn_id` so the UI can collapse/expand a
  whole turn (user msg → reasoning → N tool roundtrips → assistant msg).
- **Long root turns checkpoint; they do not give up.** `max_rounds` bounds one
  worker-thread segment. When a root reaches it, the daemon immediately starts
  a synthetic continuation against the durable transcript and keeps the
  session running. Task children retain a hard round budget so fan-out remains
  bounded and returns partial work to its parent.
- **A blank provider response is not a final answer.** When a native provider
  returns neither visible text nor tool calls, the loop retries once with an
  ephemeral continuation instruction. A second blank response becomes a
  durable, visible turn error; Marlin never appends an empty `assistant_msg`.
  Content-filtered blanks fail immediately.

### Storage: SQLite, one DB

`~/.local/state/marlin/marlin.db` (WAL mode). Tables:

```
sessions(id, title, created_at, cwd, model, effort, provider, status,
         pinned_context, config_json, parent_sid, kind, parent_block_id,
         max_rounds)
blocks(id, session_id, turn_id, seq, kind, ts, body_json, covers_to_seq)
blobs(hash, bytes, created_at, tombstone)  -- full tool outputs, content-addressed
blob_refs(hash, block_id)                  -- refcounting for GC
kv(key, value)                          -- daemon metadata, schema version
```

WAL gives crash safety without JSONL tail repair, while indexes support range
replay, session hierarchy, archive traversal, and blob references without
rebuilding side indexes at startup. A JSONL store would be easier to inspect
and remove the C compile, but those features would require sidecars, migration
machinery, checkpoints, and locking of their own. The block-log abstraction
still keeps the choice isolated: nothing outside `store.zig` knows SQL.

The shared connection is opened in SQLite serialized/FULLMUTEX mode. Ordinary
blocks cost one insert; an oversized tool result writes its content-addressed
blob, durable block, and blob reference in one `BEGIN IMMEDIATE` transaction,
so it is both one WAL commit and crash-atomic. The `(session_id, seq)` unique
constraint supplies the block-range index; migrations remove the historical
duplicate index rather than paying twice on every append.
The append/status/usage, context-load, and telemetry-write statements are
retained and reset under the same connection mutex, avoiding hot-path
prepare/finalize churn without allowing two turn threads to interleave bindings
on one statement. Context loading materializes its one-row compaction-frontier
and latest-plan CTEs before the indexed block scan; the frontier is also stored
as an ordinary column rather than extracted from JSON on every turn. Leaving
the frontier as a co-routine caused SQLite to recompute it per candidate row
and turned large compacted sessions into a roughly 50-second pre-provider
stall. Dedicated indexes cover block kind, turn-specific reads, session
hierarchy, recent authored input, and recent telemetry. Ctrl+R uses separate
bounded current-session and global-newest scans rather than a database-wide
expression sort.

Local and test builds link the platform SQLite library to keep rebuilds fast.
Official release builds pass `-Dembedded-sqlite=true` and compile the vendored
amalgamation into the distributable binary with `SQLITE_ENABLE_FTS5`.

### Durable transcript search

Insert-mode Ctrl+R runs an inline reverse-i-search in the composer with
client-side fuzzy matching over a bounded newest-first corpus from the daemon:
typing refines, repeated Ctrl+R walks older matches, Enter accepts, and Esc
restores the untouched draft. Normal-mode `/` searches the
current transcript; `/search <query>` and the headless `marlin search`
equivalent search across sessions. Transcript results carry the session,
sequence, timestamp, kind, location, and highlighted snippet. Selecting one
requests a bounded replay centered on that sequence, catches forward to the
live edge without a subscription gap, positions the viewport, and highlights
the matching block. Normal-mode `n`/`N` advances through the retained result
set without re-running the query.

Schema v13 adds content-free local preparation telemetry, a materialized
compaction frontier column, and the indexes that keep recent-input, hierarchy,
turn-specific, context-metadata, and diagnostics reads bounded as durable
history grows. Schema v8 persists per-session Plan mode. Schema v7 projects
visible text into `search_docs` in the same transaction as the append-only
block. User/assistant
text, reasoning, steers, plans, bounded
tool arguments/results, compaction summaries, and notes are searchable;
synthetic rehydration, approvals, binary data, base64, and uncapped blob bodies
are not. Existing databases backfill once. At startup Marlin capability-checks
FTS5 by creating the external-content index; system SQLite builds without it
use a bounded `search_docs` scan instead.

### Growth & trimming

Text blocks are cheap (~1GB/yr worst case); **blobs and images are the
growers**. The FTS index adds another copy of searchable text. The append-only
invariant protects *causal block structure*, not every 400KB build log
forever — same insight as L1 pruning, applied to disk: blob bodies are
regenerable/low-value with age; block structure is not.

**Day-one schema commitments** (cost nothing now, painful to retrofit):

- `PRAGMA auto_vacuum = INCREMENTAL` set at DB creation — cannot be enabled
  retroactively without a full vacuum rewrite.
- Blobs carry `created_at` + `tombstone`; refs live in `blob_refs` so
  orphan detection is a join, not a scan of block bodies.

**Trimming implementation and remaining design:**

- **Session lifecycle: archive → delete.** Archive is implemented: `/archive`,
  Delete/Ctrl+D on a `/sessions` row, and `marlin archive <session>` hide a
  durable session hierarchy from default navigation while retaining its complete
  log. Successful one-shot task children auto-archive; failures and interruptions
  stay visible. `marlin ls --all` and `marlin unarchive <session>` provide
  recovery. Permanent
  `marlin rm <session>` remains future work; it will delete blocks + decrement
  blob refs.
  Optional retention config (`delete_archived_after = "180d"`, off by default)
  remains future work. Explicit or policy-driven, never silent.
- **Blob demotion is explicit.** `marlin gc` safely sweeps orphan blobs. Adding
  `--expire-days N` also truncates older full bodies to tombstones, but only
  when every reference is also older than the horizon and none of their
  sessions is running or awaiting approval. Every
  block and ref remains resolvable — scrollback never breaks, and `!c` says
  "expired or missing" instead of returning empty data. There is no silent
  default retention horizon.
- The GC transaction is: orphan sweep → optional expired-body demotion →
  `PRAGMA incremental_vacuum` → WAL checkpoint; it reports logical bytes
  reclaimed. Future search indexing adds its optimize step here. Optional
  idle-time auto-GC remains future work.
- DB size in `marlin ls` / dump-state remains future work; it does not belong
  in the status bar because it is never a mid-turn decision.

## 3. Wire protocol (client ⇄ daemon)

Newline-delimited JSON over the socket. Length-prefixed binary is a premature
optimization; NDJSON is debuggable with `nc` + `jq` and fast enough for
terminal-rate traffic.

The transport has a real boundary rather than buffer-shaped accidents: one
record is at most 32 MiB, dynamically assembled through small reader scratch
buffers. Outbound encoding enforces the same cap. Each client outbox is capped
at 64 MiB; crossing it disconnects that stale client so durable blocks can be
replayed instead of consuming unbounded daemon memory. Client teardown shuts
down both socket directions before joining its owned reader/writer threads.
An accepted socket must finish the version handshake within two seconds. An
advisory instance lock serializes startup before either process can remove the
socket; reboot releases it only after retiring the old listener.

**The message catalog lives in `docs/PROTOCOL.md` (semantics) and
`src/core/proto.zig` (types) — those are the source of truth**, and the wire
shape is std.json's tagged-union form `{"<type>":{...payload}}`, not the
`{"t": ...}` sketch this section originally carried. Highlights, using the
real names: `session_create`/`session_list`/`session_kill`, `sub {sid,
from_seq, tail_limit?, before_seq?, replay_done?}`, `input` (message or steer), `approve`, `interrupt`,
`session_compact`, and `blob_get {hash}` for full tool output (`!c`); daemon
→ client is `blk`, `delta`/`reasoning_delta`/`stream_status` (ephemeral),
`status`, `approval_request`, `session_meta`, `err`. There is no
`copy.query` and no `blocks.get` — copy is content-addressed blob fetch, and
scrollback beyond client memory replays from the durable log.

Inputs carry an additive client request id. The daemon echoes it in exactly one
terminal `ok`/`err`, including internal failures, so optimistic UI is a
reconciled protocol state rather than a guess: acceptance waits for the
durable block, while rejection removes only that echo and restores its prior
session state.

Two stream disciplines worth locking in now:

- **Deltas are ephemeral; blocks are truth.** Clients render deltas for
  liveness, then replace the streaming region with the finalized block. Raw
  reasoning finalizes `reasoning_delta`; tool-round commentary finalizes
  `delta`. Clients clear that channel at every finalized block rather than
  comparing accumulated text, so residue cannot join adjacent provider rounds.
  A client that attaches mid-turn gets replayed blocks + current partial delta
  buffer. This makes reconnect/multi-client trivial.
- **Bounded attach + paged `from_seq` resume.** Clients remember the last block seq
  they've seen per session and replay only the gap when revisiting a cached
  view. A cold TUI attach asks for the newest 256 blocks; `replay_done`
  advertises whether more durable history exists and carries the newest plan
  revision. Reaching the loaded top asks
  for another 256 blocks with `before_seq=oldest_seq`, buffers them off-screen,
  then prepends the page atomically. Attach and scrollback work are therefore
  bounded without weakening the block log as source of truth. Revisiting a
  cached view pages forward in 256-block windows and becomes live only at the
  durable frontier, so live fan-out cannot leapfrog an older page.

## 4. Agent loop

This section is the **native** turn. Guest sessions do not run it; they
delegate to the official `claude` binary (Native vs guest, §1) and only
persist the resulting blocks.

Per running native turn, in its own thread:

```
assemble context (see §6)
loop:
    stream POST to provider (SSE)
      → emit coalesced text/reasoning delta events as text arrives
      → collect tool_calls (may be several)
    if no tool_calls: persist assistant_msg; drain steering; only finish after
      atomically closing an empty steer queue, otherwise request another round
    persist the complete assistant tool_call batch
    resolve approval gates (§7) — may block on client response
    execute each maximal consecutive parallel_safe group concurrently;
      serialize unsafe/mutating calls as ordering barriers
    persist tool_results in original provider-call order
    check steer queue: if user typed mid-turn, inject steer block
      as a user-role message before next request   [zag's pattern]
    loop
```

- **Parallel tool execution**: `.parallel_safe` is enforced by the scheduler.
  Consecutive safe calls overlap in chunks of at most eight workers; mutations
  and unknown tools remain ordering barriers. Calls and results are each
  persisted as contiguous ordered groups, matching the provider transcript
  even when completion order differs.
- **Cancellation**: interrupt sets an atomic flag; HTTP, MCP, search, and file
  tools observe it before/after blocking operations and during their own
  loops. A kernel filesystem syscall itself cannot be forcibly unwound; all
  user-space work and external processes remain bounded. Every tool subprocess owns a process group, so
  interrupt/timeout sends SIGTERM → grace → SIGKILL to the complete
  pipeline and its descendants, then reaps the direct child. The half-finished
  turn is finalized as an interrupted `system_note` + whatever blocks completed
  (the log stays consistent). Forced kills first snapshot live descendants
  via `ps`, so processes that left the group via setpgid (`timeout(1)` is
  the canonical case) are terminated individually instead of orphaning.
  The turn thread also publishes a coarse atomic phase. Current clients opt
  into `interrupt_result`, so the first interrupt confirms what is being
  cancelled and repeated interrupts report the same phase plus elapsed time;
  legacy clients retain the plain `ok` reply. Arbitrary native turn threads
  are never killed unsafely—true hard isolation would require subprocess turns.
- **bash wall-clock limit**: commands are killed after `timeout_seconds`
  (default 600, max 3600 — the model raises it for long builds). Timeout is
  a Result, not an error: everything captured before the deadline reaches
  the model with a note naming the limit, so a timed-out build is
  debuggable instead of a blank failure.
- **Graceful SIGTERM/SIGINT**: a self-pipe watcher thread turns the signal
  into the ordinary `.shutdown` dispatcher event — socket removed, store
  closed — the same path `/quit` and reboot use. (SIGHUP stays ignored so
  the daemon survives its spawning terminal.)
- **Transport failures**: a turn that dies mid-stream discards the partial
  assistant text because deltas were never truth, then persists a concise
  failure note. Automatic retry/backoff remains future work; Marlin does not
  currently conceal an ambiguous provider failure behind silent retries.
- **Malformed tool JSON**: lenient repair pass (strip trailing commas/garbage,
  balance braces, unescape common damage) before failing; on failure, feed the
  parse error back to the model as the tool result — models self-correct.

## 5. Providers

Native sessions: one internal chat representation (blocks → messages),
**two wire dialects**. Guest sessions are not a third dialect — they are
the Native vs guest rule in §1.

```
provider/
  openai_compat.zig   // OpenRouter, OpenAI, DeepSeek, Groq, local llama.cpp, ...
  anthropic.zig       // Messages API (SHIPPED): anthropic/<model> via
                      // ANTHROPIC_API_KEY. x-api-key auth, role-merged
                      // content blocks, native cache_control on the
                      // assembler's breakpoints, content-block SSE decode
                      // into the shared accumulator. Not yet: extended
                      // thinking (requires persisting signed thinking blocks
                      // for tool-round replay; effort is ignored on the
                      // direct dialect until then — it works via OpenRouter).
  claude_code.zig     // GUEST ADAPTER, not a wire dialect. claudecode/<model>
                      // sessions spawn the official `claude` binary; see §1.
                      // The approval bar is mux UX: `marlin cc_approve --sid N`
                      // (stdio MCP `--permission-prompt-tool`) forwards their
                      // prompts as cc_approval. Workspace-scoped calls may
                      // auto-allow (CC's read-only/auto-inside analogue);
                      // everything else parks as a normal approval_request.
                      // Auto/yolo guest sessions map to
                      // --dangerously-skip-permissions.
  codex.zig           // GUEST ADAPTER for codex/<model>. App-server JSONL
                      // uses the existing ChatGPT login; its durable thread
                      // id maps to the Marlin session. Items and approvals
                      // project onto ordinary blocks and the shared gate.
  registry.zig        // model string → native dialect+endpoint+key, or guest
```

- OpenRouter is the default registry entry and the `/new` default.
- `base_url` + `api_key_env` in `[providers.<name>]` adds arbitrary
  OpenAI-compatible endpoints without another wire dialect. The secret stays
  in the named environment variable; `"NONE"` explicitly selects keyless
  auth. Credential names must match the daemon's secret-name policy so tool
  subprocess stripping and capture-time redaction cannot drift. `vercel/` and
  `litellm/` are built-in presets, while the same table can override their
  defaults or the `openrouter` / `anthropic` / `local` routes.
- `local/testing` is the deterministic developer model. It defaults to the
  bundled fake provider on `127.0.0.1:5757`, requires no key, and still crosses
  the real OpenAI-compatible HTTP/SSE boundary. E2E uses a private dynamic-port
  override; `zig build fake-model` provides the zero-config manual endpoint.
- Every OpenRouter request carries the Marlin session's stable `session_id`.
  OpenRouter therefore keeps a session on the same provider/cache and groups
  its generations in Activity. `[providers.openrouter] sort` defaults to
  `"throughput"` (`"latency"`, `"price"`, or `null` are supported).
- Native agent turns also have stable trace ids. When OTLP export is enabled,
  OpenRouter receives that trace id plus the Marlin provider span as
  `parent_span_id`, so Broadcast can join its generation beneath the local
  trace instead of creating an unrelated one.
- Ordinary OpenRouter turns also advertise the `openrouter:web_search` server
  tool using the existing OpenRouter credential and briefly describes its use
  in the system prompt. OpenRouter executes searches inside the provider
  request; Marlin caps them at five results per search and fifteen total results
  in one search-bearing request, decodes usage, and preserves annotation-only
  source URLs in the durable assistant message. A usage count or returned
  citation spends that turn's search budget, so later local-tool rounds stop
  advertising the tool or its prompt guidance. Compaction and non-OpenRouter
  routes do not advertise the tool; known URLs remain available through
  `fetch`.

### No single point of failure

Four distinct failure layers, four distinct answers:

1. **Aggregator outage** (OpenRouter: one auth endpoint, one billing
   account, one proxy — every model gone at once). Mitigation: 2-3 DIRECT
   provider entries alongside it. Pure config, zero code — xAI, DeepSeek,
   Z.ai, Mistral, OpenAI, Gemini's compat endpoint are all
   `base_url + api_key_env` in the openai_compat dialect. The council
   models (sol / fable / grok / glm) all have direct endpoints: councils
   survive an OpenRouter outage on config alone.
2. **Model-family outage** (Anthropic having a bad day). Mitigated by
   holding keys for ≥2 families; the anthropic dialect (already planned
   for cache_control) doubles as the direct line to the most-used family.
3. **Account failure** (credits, revoked key, tier limits). Only a second
   billing path fixes this — direct keys are that path, not a second
   protocol.
4. **No internet.** `local/` and the keyless configured-provider path cover
   llama.cpp, vLLM, Ollama, and LiteLLM without leaving the OpenAI-compatible
   dialect.

**Failover policy** (design — no failover path exists in `provider/` yet;
today a persistent provider failure fails the turn visibly):

```toml
[model]
default   = "openrouter/anthropic/claude-sonnet-4-5"
fallbacks = ["anthropic/claude-sonnet-4-5", "xai/grok-4.6"]
```

On persistent provider failure (5xx/429 surviving retry-with-backoff, auth
errors), advance down the list. A failover is a VISIBLE system_note block
("openrouter failed (503×3) → anthropic direct") — it changes cost,
caching, and possibly behavior, so it belongs in the causal log; never
silent. Not sticky: next session starts at default. Mid-turn failover is
safe by construction — deltas are ephemeral, so discard the partial buffer
and re-request the same assembled context against the fallback.

**Don't build:** Gemini-native, Bedrock (SigV4), Vertex dialects — heavy
auth for platforms not in use. The two-dialect rule holds for *native*
sessions. Guest is not a dialect; do not add a third wire. The two shipped
guests are enough; do not add more (`gemini -p`, etc.) without first proving
that daily use justifies another private runtime and context store.

**Accounting footnote:** OpenRouter reports $ directly; direct providers
report only tokens. The status-bar `$` needs a small local price table
for direct routes (or degrades to tokens-only) — don't let it lie.
The `/model` catalog does not need that table: it shows OpenRouter's published
input/output rates directly and leaves local or unpublished rates unknown.

- **Usage accounting is provider-reported**: every response's `usage` field is
  stored on the session (`session.meta` event carries it to clients). Token
  estimates for un-sent deltas use bytes/4 — good enough because true usage
  resyncs every turn. No tokenizers in the binary.
- OpenRouter requests set explicit `cache_control` breakpoints on the stable
  system prompt, the last stable message before the live environment, and a
  completed tool batch for Claude/Gemini/Qwen families. Models with automatic
  caching use the same append-only prefix without extra parameters. Returned
  cached/write/reasoning token counts and generation/provider ids are decoded
  into SQLite turn/round/tool telemetry. `/diagnostics` is the deterministic
  local view. With `OTEL_EXPORTER_OTLP_ENDPOINT` (or its traces-specific
  variant), a separate persistent-connection worker drains completed traces
  from a durable outbox; `/otel set <endpoint>|off|status` can atomically replace
  that process-local exporter over the existing socket/SSH transport. Header
  entry is masked and neither persisted nor echoed. Export failures never affect
  turns. Mirador or another OTLP collector provides the cross-session view.
  The custom `marlin.turn` INTERNAL root carries no `gen_ai.*` attributes;
  GenAI CLIENT spans represent provider rounds, and INTERNAL execute-tool spans
  are parented to the round that requested them. Telemetry excludes prompts,
  completions, tool definitions, tool arguments, and tool output.
- HTTP uses a daemon-owned `std.http.Client` pool shared by provider requests,
  bounded fetches, catalogs, and network blocklists. It retains reusable
  connections across rounds while the transport remains isolated behind one
  interface. DNS/connection establishment, response-header latency, stream
  idleness, and absolute wall time have separate deadlines; a connected model
  may take up to two minutes to return headers without being mistaken for a
  ten-second connection failure. The watchdog can shut down its live socket;
  it does not consume a second threaded-I/O slot or wait for a discarded
  request to return. On Darwin, uncached DNS resolution
  is preflighted in a deadline-bound helper process because libc
  `getaddrinfo` itself is not cancellable; the resolved numeric address is
  handed to the actual connection while the original hostname remains the TLS
  SNI/certificate identity. Pre-header liveness is emitted immediately and
  refreshed while the provider is pending, so the TUI distinguishes that
  phase from an unexplained spinner. A 30-minute wall deadline cannot be
  extended by chatty bytes, and decoded assistant/reasoning/tool fields are
  capped at 4 MiB so a broken stream cannot grow the turn heap indefinitely;
  crossing a cap closes the socket and persists a visible turn failure. The
  layer's failure vocabulary is a typed `http.Error`
  (Cancelled / HttpTimeout / InvalidRequest / ConnectFailed / ReadFailed /
  UnsupportedEncoding / ConsumerAborted / ConcurrencyUnavailable / OutOfMemory), so a
  "turn failed:" system_note distinguishes user interrupt, hung provider,
  and mid-body transport death instead of leaking std.http error soup.

## 6. Context assembly & compaction

Context for each request is **derived** from the block log at turn start:

```
[system prompt]  (stable per session: base + skills index + pinned context)
[compaction summaries, oldest first]      // from compaction blocks
[stable blocks before this turn]
[current environment]                     // volatile; inserted late
[newest user/steer + subsequent tool rounds]
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
    1. Move both range edges to complete `turn_id` boundaries, then summarize
       blocks [start..cut] with the concise structured contract: accomplished /
       in-progress / continuation-critical files / next steps / durable user
       constraints. A parallel tool-call batch can therefore never be split
       from its results; automatic compaction additionally preserves the active
       newest turn. Cheap model configurable (`compaction_model`).
    2. Append `compaction` block; context assembly now emits summary + tail.
    3. **Rehydrate**: re-inject head+tail of the N most recently *written*
       files (from tool_call history) as synthetic model-visible context plus
       a continuation note. Clients show only `context compacted` and
       the rehydrated filenames, never the summary or file contents.
       (Claude Code's insight: summary-only compaction is amnesia.)
  Assembly also drops an unmatched `tool_result`: it is invalid without its
  assistant `tool_call`, and this makes sessions damaged by the old block-count
  cut recover on their next request. A dangling call takes the converse repair
  path and receives a synthetic interrupted result.
  Don't compact tiny sessions (< min_blocks); don't compact twice in a row
  without progress between.
- **L3 — subagents (M6a active).** `task` spawns a durable child through the
  dispatcher with its own context, optional model/effort, read-only tools, and
  a round budget; only its structured final result enters the parent as a
  tool_result. Child sessions are ordinary sessions (visible in `marlin ls`
  and attachable) and the multiplexer groups them beneath the parent.
  `task_batch` launches two to eight through the same dispatcher-owned path,
  waits concurrently, and returns results in input order. Child profiles still
  forbid recursive delegation.

Cache discipline, stated once: between L1/L2 events the stable prefix is
strictly append-only. Volatile date/git-branch/sandbox state is inserted immediately
before the newest user/steer input, so it cannot invalidate cached prior
history. L1/L2 are the only deliberate stable-prefix breaks; both are rare and
logged as `system_note` blocks so cost anomalies are explainable.

The turn thread loads its context working set once into one arena: every
compaction record needed to resolve nested summaries plus blocks after the
greatest compacted seq. Superseded rows remain durable but are not parsed into
the turn heap. The thread extends that slice after every persisted block, so
provider tool rounds never re-read/re-parse SQLite history.

## 7. Tools & safety

Built-in (pi-minimalist, ~7):

```
bash        (mutating, approval-gated by default)
read_file   (parallel_safe)
write_file  (mutating)
edit        (string-replace w/ fuzzy fallback; mutating)
grep        (rg → system grep → native walker; parallel_safe)
glob        (parallel_safe)
fetch       (HTTP GET → markdown-ish text; parallel_safe)
task        (durable read-only child; M6a)
task_batch  (2–8 durable read-only children; ordered result)
```

**grep engine policy.** Prefer `rg` when on PATH: best engine, native
.gitignore/hidden/binary filtering, and the `path:line:content` shape models
were trained on. If it is absent, GNU/BSD `grep` supplies an optimized regex
engine on supported Unix targets with explicit bulky-directory/socket
excludes. A platform-grep traversal error falls through to the file-only Zig
walker. That last path treats plain patterns as direct substring searches and
uses zig-regex only when syntax requires it, avoiding the former per-line
regex cliff. A pattern the engine cannot compile degrades to a literal with an
explicit note. Rejected: bundling an `rg` sidecar; Marlin remains one binary.

**Permission and approval system** (full contract: `docs/PERMISSIONS.md`):

- Every execution flows through the existing approval gate. The shipped
  legacy policy remains per-tool `auto | ask | deny` until capability mode is
  enabled: read-only tools auto, mutating tools ask.
- Capability mode asks for a typed operation and concrete scope, not a command
  prefix. Decisions are deny, allow once, or allow for this session. There is
  intentionally no `git *` allowlist: commands sharing a prefix do not share a
  risk boundary.
- `--yolo` skips legacy convenience prompts; it does not bypass protected
  paths, secret-environment isolation, or kernel sandbox boundaries.
- An `ask` arms its gate before emitting `approval.request`, so a fast answer
  cannot race the pending id. The complete live request is retained and sent
  to subscribed and session-watch clients on reconnect; first decision wins.
  Timeout defaults to none — the turn parks in `awaiting_approval`, exactly the
  state the session picker, actionable status summary, and phone surface.
- bash sandboxing (M3.5, stolen from zag): Seatbelt profile on macOS and a
  Landlock ruleset on Linux (both SHIPPED, both canary-verified at daemon
  start by the same probe: inside write succeeds, sibling write fails,
  protected reads fail, signals work). The Linux wrapper is
  `marlin landlock_exec`, which applies the ruleset to itself and execs
  bash. Landlock has no deny rules, so "read everything except protected
  roots" is a computed cover allowlist (landlock.zig `coverPlan`); the
  documented cost is that entries created under a partially-granted
  ancestor (typically $HOME) during one call are unreadable until the next
  call. seccomp remains unimplemented and unplanned absent a specific
  syscall threat model. On kernels/containers without Landlock the backend
  reports unavailable and execution falls back to legacy ask-gating —
  never claimed, never half-enforced. `marlin sandbox_probe` runs the
  startup canary standalone for diagnostics.
  The profile allows `signal (target same-sandbox)` — SBPL's `signal` is a
  distinct operation `process*` does NOT cover, and without it `kill`/`timeout`
  inside the sandbox get EPERM and hang (the canary has a leg for this).

**Secrets** (threat: prompt injection or buggy tool logic exfiltrates
credentials; hazard multiplier: the append-only store makes any leaked
secret IMMORTAL):

- **The daemon is the credential boundary.** Provider keys live in daemon
  memory only. Tool subprocesses get a scrubbed environment: every env var
  the daemon consumed as a secret is stripped at the single spawn site,
  plus a configurable deny pattern list (`*_API_KEY`, `*_TOKEN`,
  `*_SECRET`, `AWS_*`). `bash: env` must never print a provider key into
  a tool_result.
- **Redact at capture time (L0), before appendBlock.** Blocks are
  immutable, so redaction after persistence is impossible by design. Two
  layers: (a) known-value scrub (SHIPPED: `permissions.collectSecrets` +
  `redactSecrets`, applied in the loop before hashing/capping/blobbing,
  native and guest tool results alike) — the daemon greps tool output for
  the literal bytes of every secret it loaded and replaces with
  `[REDACTED:<name>]`; exact match, zero false positives; (b) pattern
  scrub for secret-shaped strings (sk-*, AKIA*, PEM blocks, JWTs),
  configurable since build logs hit false positives **(not yet
  implemented)**. Redaction runs before persistence AND context assembly:
  the model never sees the bytes, so injection cannot make it repeat
  them. (Same principle as 1Password-for-Claude's zero-exposure
  framework: the agent may USE a credential, it never HOLDS it in
  context.)
- **Config holds no plaintext.** `api_key_env` (existing) or
  `api_key_cmd = "op read op://..."` — run at daemon start and /reboot,
  cached in memory. op/pass/security(1) become the vault; marlin never
  writes a key to disk.
- **Protected paths enforced, not requested.** (SHIPPED) read_file/grep
  on `.env*`, `*_rsa`, `*.pem`, `~/.aws/credentials` etc. return
  refusal-as-data, symlink-aware; grep additionally filters matches from
  protected files inside ordinary trees — policy in the tool layer, not
  a plea in the system prompt. The `/allow` override is the designed
  escape hatch **(not yet implemented; M3.5 capability grants)**.
- **(v2 door) Credential brokering:** daemon as forward proxy injecting
  auth headers for allowlisted hosts, so agent-written code calling
  external APIs never holds tokens (Agent Vault pattern). Needs TLS
  interception + CA management; wrong cost/benefit for v1, right shape
  for the daemon if it ever matters.

**Extension tools — process boundaries only:**

- **MCP client** (v1): stdio transport is shipped; streamable HTTP remains a
  later transport. Config lists servers;
  their tools appear in the registry with provider-safe names
  (`mcp__playwright__click`). Approval policy applies identically. The client
  speaks the current stateless protocol and falls back to the deployed legacy
  initialize lifecycle. One absolute deadline spans lock acquisition, stdin
  write, and response matching; unrelated stdout cannot extend it. Turn
  cancellation kills the server process so one wedged call cannot serialize
  every session behind an uncancellable server mutex. Discovery is isolated
  per server: a broken process becomes visible health data and contributes no
  tools without preventing daemon startup. `/mcp` and `marlin mcp` list,
  add, remove, restart, and atomically reload daemon-owned configuration while
  sessions are quiescent. Failed registry rebuilds retain the old live registry
  and roll back generated config edits. MCP `readOnlyHint` annotations classify
  individual tools; exact `readonly_tools` and `mutating_tools` config overrides
  take precedence over the server default. Returned PNG/JPEG/GIF/WebP content
  is bounded, signature-checked, persisted in the blob store with the
  tool_result, rendered as media metadata, and mapped to provider-native image
  blocks on the following round.
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
- **Plan mode is collaboration state, not the todo list.** Shift+Tab toggles
  persistent per-session Plan mode; `/plan [task]`, `/plan off`, and `/plan
  clear` provide explicit entry, exit, and stale-todo recovery. Native turns
  advertise only reads, search/fetch, and read-only child tasks—no bash,
  writes, mutating extensions, or `plan_update`. Guest turns use Claude Code's
  `--permission-mode plan`. A finalized proposal offers Implement, Revise,
  Stay, and Dismiss; Implement atomically leaves Plan mode and starts a
  synthetic implementation turn, which creates the durable execution todo.
- **Todo/plan list pinned above the input** while work remains (**shipped**):
  `plan_update` appends immutable revisions to the block log; the daemon
  restores the latest unfinished revision independently of bounded replay and
  injects unfinished work after compaction. The current step is highlighted
  and done items are checked. Always visible without scrolling — "where is it
  in the plan" must never require leaving the live region. Once every item is
  checked, the closed table moves into transcript output with total active time;
  the assistant's final response follows as the human-readable recap.
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
  (recently changed, potentially actionable) to hold vertical space. Durable
  unfinished plans remain visible after a turn, but their active row shows a
  paused mark and frozen active-time duration whenever the session is idle;
  only a running turn may animate it.
- **Liveness via text shimmer.** While a turn runs, the working indicator is
  an animated gradient/shimmer on the status word (the Claude/Codex rainbow
  effect), not spinner characters and not log lines. Cheap in a cell grid:
  cycle fg color across the word per frame.
- **Optimism must reconcile.** Submitted messages/steers render immediately,
  but each has a wire request id. A matching daemon error removes precisely
  that echo and restores the pre-submit state; generic errors cannot strand a
  false running indicator. If the socket dies, the TUI restores the terminal
  first and then prints the read failure at the shell, where alt-screen teardown
  cannot erase it.
- **Diffs render like a diff tool, not like raw patch output.** Gutter
  `+`/`-`, restrained full-row green/red surfaces, and language-aware syntax
  foregrounds keep the change shape obvious without washing out the code.
  Hunk headers retain the enclosing declaration/function context produced by
  the edit tool. Lives in the block renderer next to markdown.zig; edit-tool
  results render as diffs by default.
- **No invented theme format — a semantic role map onto ANSI-16.** Every
  rendered element gets a role (`diff.add`, `diff.del`, `todo.active`,
  `status.cost`, `block.border`, `md.heading`, shimmer endpoints…), each
  resolving to an ANSI palette index by default. Marlin decides
  relationships (dim/bright/accent); the user's terminal theme supplies the
  pigments — so marlin renders natively in any iTerm2/Ghostty scheme, light
  or dark, locally or over ssh, with zero config. Layered on top:
  per-role TOML overrides (ANSI name or truecolor), and optional whole-map
  swap via **base16/base24 scheme files** (the de-facto standard; a base16 →
  role-map converter is ~50 lines — do not parse .itermcolors plists).
  Effects needing interpolation (shimmer gradient, dimmed diff variants)
  query the terminal's actual RGB for the relevant slots via OSC 4/10/11 at
  startup and derive from those — gradients match the user's theme instead
  of a hardcoded rainbow. (Check what libvaxis exposes for OSC queries;
  it's Ghostty-adjacent so likely most of it.)

**Permanent tabs; no persistent sidebar.** Every unarchived root session has a
tab in a one-row strip that remains visible even when only one session exists.
Tabs are clickable; normal-mode `>`/`<` and Right/Left move through the visible
tab order, while `gt`/`gT` (with optional count) retains MRU session navigation.
Child activity rolls up to its root tab and overflow keeps the focused tab
visible. `/sessions` remains the fuzzy complete hierarchy picker showing title,
workspace, recency, and state. `/council` opens a filtered council list, while
`/council <name>` inspects the durable roster. Contextual command completion
offers council actions and configured names for both `/council` and `/review`.
Council create/edit reuses the model
catalog as a filtered multi-select: Enter toggles seats, `Done` saves atomically
through the daemon, and Esc discards the draft. The status bar
reports background sessions only when actionable (`2 running · 1 approval`).
A split pane identifies its session with a compact pane label.

```
┌ api-fix · 63df ● │ crypto-review · a82c ! ──────────┐
├─ main: api-fix ● ───────────────────────────────────┤
│ blocks rendered as cards:                           │
│ user / assistant md / collapsed tools               │
│ [streaming region at bottom]                        │
├─ todo (when present) ───────────────────────────────┤
│ ✓ parse args   ▸ wire store   · tui                  │
├─ input ─────────────────────────────────────────────┤
│ > _                                                  │
└─ status: model · ctx% · $ · state · 1 approval ─────┘
```

- **Modes**: insert (typing → input box), normal (vim motions: j/k scroll,
  gg top, `gt`/`gT` with count for recent-session cycling, J join lines and
  a/A/I enter insert mode in the composer, a bare Esc returns to insert
  (with a count/operator pending it cancels that instead and stays),
  `:` opens the command menu,
  Ctrl+W on an empty composer or
  `/archive [children]` for explicit lifecycle changes (Ctrl+D stays
  page-down: an empty composer is the normal state while reading), `/sessions` for
  arbitrary attach, v visual-select,
  y yank).
- **Splits (not yet implemented)**: binary-tree layout, each pane = a
  session view (or the same session twice). No VTE anywhere. The daemon
  already fans blocks out to every session a client has subscribed, so splits
  are a client-only change; the prerequisite `SessionView` extraction and the
  rest of the plan are in `docs/PANES_PLAN.md`.
- **Scrollback**: virtual list over the block log. While following the bottom
  of a running turn, the initiating user prompt scrolls normally until it
  reaches the top, then stays there above the growing live tail. Scrolling up
  restores ordinary contiguous scrollback. The pinned card is a display
  duplicate, so selection and copy continue to address the
  durable transcript rows. Selection is ours (mouse mode on): drag selects
  logical text within/across blocks; double-click = word, triple = block.
  Copy → OSC 52 (works through ssh/mosh); shift+drag falls through to the
  terminal for native selection as escape hatch. The active turn's durable
  layout is cached until blocks/state/width change. During a running turn the
  daemon publishes its coarse operational phase (`starting`, `context`,
  `provider`, `tool`, `child`, `compaction`, `finishing`) as ephemeral additive
  status metadata;
  the live activity row names that work and shows total plus current-phase
  elapsed time. Provider byte/quiet telemetry and exact persisted tool calls
  refine the phase without adding durable transcript chatter. Active provider
  traffic shows a green up arrow; three quiet seconds change it to a red down
  arrow. When the active call is Bash, its command preview uses the same
  semantic shell highlighting as the durable tool row. Provisional
  assistant text wraps append-only and receives full Markdown treatment when
  its block finalizes. Spinner/token frames therefore
  do not re-layout the accumulated turn. Inactive full
  session views are an eight-entry MRU cache; evicted views reopen from a
  bounded durable tail instead of accumulating for the lifetime of the TUI.
- **Copy commands**: `!c` last tool result (full blob via `blob_get`, not
  the inline cap; the notice names the source tool since folding may hide
  it). The `!c msg`/`!c code`/`!c all` variants and the `!y`/`!p` daemon-side
  register are future work.
- **Command namespace**: `/` = session & harness commands (`/sessions`,
  `/model`, `/compact`, `/new`, `/archive`, `/animate`, `/screensaver`); `!` =
  terse frequent actions. A client-owned effect union (`client/effects.zig`)
  exposes one reset/tick/resize/draw contract over two backends declared in
  `core/visual_effect.zig`. Cell effects paint the grid: Matrix rain, dancing
  sine strings, a forward starfield, demoscene plasma. Pixel effects
  (`client/pixel_effects.zig`) render an RGB framebuffer and ship it over
  Kitty graphics: tunnel, metaballs, horizon, a 24-second `demo` sequence,
  a `shadowbox` landscape (`client/shadowbox.zig`, after Jani Ylikangas'
  js1k 2019 entry: composed in the original's 1900×900 canvas units and
  scaled per axis, rasterized with coverage anti-aliasing — the original's
  faint ranges are sub-pixel fillRect widths, which coverage reproduces.
  Its two static moods, bat and lightning are replaced by the real sun: the
  TUI locates the machine from its time zone — zone name from `TZ`, the
  `/etc/localtime` link or `/etc/timezone`; coordinates from the zone
  database's own `zone1970.tab`/`zone.tab`, else an area latitude plus a
  longitude from the UTC offset; `MARLIN_SHADOWBOX_LATLON` overrides — and
  feeds the scene a `Sky` from the NOAA solar position algorithm for the
  current instant (a trailing hour or `cycle` on `/screensaver shadowbox`,
  or `MARLIN_SHADOWBOX_HOUR`, pins or sweeps today's hours instead).
  The scene keys everything on the sine of the sun's altitude: a sky
  palette of seven keyframes, the sun placed by azimuth (the viewer faces
  the equator; a tanh keeps the path in frame) and the moon as the
  anti-sun, both with radial glows, stars and mist fading in with the dark,
  drifting soft clouds tinted from the horizon color, tree grays darkening
  at night, and the sky mirrored and dimmed below the waterline as water),
  and a self-playing Pac-Man (`client/pacman.zig`, rules and wall-bounce
  ghosts after feiss' js1k 2019 entry, a BFS eat-or-flee driver replacing
  the cursor keys). Its maze is generated per board to fit the window's
  aspect, arcade style: a mirrored half-map of 3×3-tile cells whose 2×2 wall
  blocks are merged into small tetromino-like pieces; corridors are exactly
  the seams between different pieces, which makes dead ends impossible by
  construction (three closed seams around a lattice node force the fourth
  closed too); pieces on the center line may join their mirror; a ghost
  house with a ghosts-only door sits in the middle; the house row's edge
  tiles wrap as tunnels; a BFS soundness check retries a bad draw. `Game`
  is the board, `renderBackground` draws the static maze once per generation
  as an anti-aliased outline band following the wall shape (the arcade look,
  rounded outer corners from a rectangle-distance field), `renderPixels`
  adds dots and anti-aliased sprites gliding between tiles, and a cell
  `Engine` draws the same board with glyphs where graphics are missing.
  Demoscene framebuffers are 160–400 px wide with the window's pixel aspect
  (from the winsize report); the maze uses up to 16 px per tile, letterboxed
  to the window's aspect (height ≤ 720, width ≤ 1600). Transport: the main
  loop calls `transmit` before `draw`; one new image per animation tick
  (`a=t`, 4 KiB chunks, `q=2` so the terminal stays quiet, ids from vaxis'
  counter, `o=z` zlib when smaller — the flat maze compresses ~50× and the
  shadow-box a few times, which is what pays for their resolution; the
  shadow-box ships every other tick, as do boards over 700k pixels),
  placed through the cell grid so vaxis' render() emits `a=p` inside
  the same synchronized update; the previous image is freed one tick after
  its successor is placed, so the screen never lacks an image.
  Placements use the default z-index (above text) because terminals disagree
  on where negative z sits relative to an explicit cell background.
  Capability comes from `vx.caps.kitty_graphics`; without it Pac-Man runs its
  cell renderer and the other pixel kinds start as their `fallback()` cell
  sibling, each with a notice, and a transmit failure mid-run degrades the
  same way. Pixel kinds are `fullScreenOnly`: a transient `/animate` of those
  runs opaque. The usage strings for
  `/animate`, `/screensaver`, and `/config screensaver` are generated from the
  kind list. `/animate <effect>` renders a finite 30 FPS burst through blank
  cells, preserving UI glyphs; `/screensaver [effect]` runs the same engine
  continuously as an opaque full-viewport overlay. Bare `/screensaver`,
  automatic activation, and normal-mode `gs` use `[ui] screensaver_effect`
  (default `"matrix"`). `gs` switches to insert mode before
  entering the saver. A key or paste dismisses it and is consumed; mouse events
  are ignored and do not reset inactivity. `[ui] screensaver_after = "10m"`
  enables per-client inactivity activation; absent or `"off"` disables it.
  Daemon/provider activity does not count as user activity.
  `! <command>` runs through `$SHELL -c` in the focused session cwd;
  bare `!` starts `$SHELL` interactively. The client tears the TUI down before
  spawning the inherited-stdio child and reattaches to the durable session when
  it exits, keeping terminal emulation outside Marlin. A direct `--remote`
  transport refuses shell escapes because its local terminal and the daemon
  workspace are on different hosts; running Marlin inside SSH or mosh keeps
  both co-located. `!rb` rebuilds the attached daemon side, `!rb client`
  rebuilds only the local client, `!rb both` rebuilds both, and `!c` copies the
  last output.
  Plain text + `Enter` starts a turn when idle and queues steering
  while an agent turn is active; a leading space sends text that begins
  with `/` or `!` verbatim (`!cmd` and `! cmd` are both shell escapes). `Esc` enters Vim normal mode; `Ctrl+C`
  interrupts the active turn. Native-only harness verbs (`/compact`,
  `/sandbox`, session `/network`) must refuse on a guest session rather
  than no-op or fail internally (Native vs guest, §1). `/effort` is
  forwarded as `claude -p --effort`. `/model` may cross the wall; the next
  turn runs the new regime.
- Tool blocks render collapsed by default (name + one-line summary + status),
  expand on demand. Approvals render as inline prompt cards.

### Image / asset paste

**Status: image input shipped.** Bracketed paste is text-only, so complex
assets are grabbed out-of-band:

- **Capture (client).** Ctrl+V reads PNG data from NSPasteboard on macOS and
  `wl-paste`/`xclip` on Linux. `/attach <path>` and `marlin run --image <path>`
  accept PNG, JPEG, GIF, and WebP. Each staged TUI image inserts a compact
  `[image #N]` placeholder at the cursor; intact placeholders are display-only
  and are stripped from message text at submission. Capture happens in the
  client, never the daemon, preserving the correct clipboard boundary for a
  future remote transport.
- **Wire + store.** An input carries bounded base64 upload records. The daemon
  verifies MIME signatures and writes bytes to the existing content-addressed
  blob store; `user_msg.attachments` carries only metadata and blob hashes.
  Replay therefore never inflates with base64.
- **Context assembly.** OpenAI/OpenRouter and Anthropic requests map active
  attachments to native image content blocks. L1 removes old image bodies
  from active provider context while the durable blob remains available. The
  delegated Claude Code route records an explicit unsupported note rather
  than silently dropping media.
- **Rendering.** User cards show a durable `▣ name · mime · size` attachment
  row. Inline terminal thumbnails remain optional polish over the same media
  reference; they are not required for provider vision or replay correctness.
- **Known limitation (by design):** clipboard-image paste requires the
  client to run where the clipboard lives. Under `ssh box → marlin` the
  client is remote and the local clipboard image cannot reach it (no
  terminal protocol carries it); use attach-by-path, or the (v2) web/TCP
  client which makes the local machine the client again. Not a bug.

## 9. Config

`~/.config/marlin/config.toml` (focused TOML decoder; no YAML dependency).
When absent, Marlin atomically creates a sparse starter file selecting the
security-only `hagezi-tif-mini` network feed. Existing files are never rewritten:

```toml
[daemon]
socket = "default"            # or a path; "tcp:0.0.0.0:7777" enables token auth

[model]
default = "openrouter/anthropic/claude-sonnet-4-5"
compaction = "openrouter/google/gemini-2.5-flash"

[providers.openrouter]
api_key_env = "OPENROUTER_API_KEY"
sort = "throughput"           # throughput (default), latency, price, or null

[providers.local]             # any OpenAI-compatible endpoint
base_url = "http://localhost:8080/v1"
api_key_env = "NONE"

[providers.vercel]            # optional overrides for the built-in preset
api_key_env = "AI_GATEWAY_API_KEY"

[providers.litellm]           # defaults to http://127.0.0.1:4000/v1
api_key_env = "NONE"

[providers.requesty]          # any other OpenAI-compatible router
base_url = "https://router.requesty.ai/v1"
api_key_env = "REQUESTY_API_KEY"

[context]
output_headroom = 16000
compaction_headroom = 8000
inline_tool_cap = 8000

[theme]
# Default: no theme — semantic roles map to ANSI-16 and the terminal's own
# scheme colors everything. Both keys optional.
# scheme = "~/.config/marlin/themes/gruvbox.yaml"   # base16/base24 file
# [theme.roles]                                     # per-role overrides
# diff.add = "green"          # ANSI name…
# todo.active = "#e5c07b"     # …or truecolor

[approval]
default_mutating = "ask"

[permissions]
enabled = true                # canary-gated; legacy ask fallback when unavailable
# protected_paths = ["~/.config/acme/credentials"]

[network]
# Allow-by-default, managed network tools only. Values are comma-separated.
blocklists = "hagezi-tif-mini"
allow = "false-positive.example"
deny = "local-deny.example"

[[tools.exec]]
name = "deploy_status"
cmd = ["~/.config/marlin/tools/deploy-status.sh", "--json"]
description = "Report deploy status"
schema = '{"type":"object","properties":{}}'
mutating = false
parallel_safe = true
timeout_ms = 10000

[[mcp]]
name = "playwright"
cmd = ["npx", "@playwright/mcp"]
mutating = true                 # conservative default for every server tool
readonly_tools = ["snapshot"]  # exact remote tool-name overrides
mutating_tools = ["click"]     # wins over annotation/default

[skills]
directories = ["~/.config/marlin/skills"]

[hooks]
on_approval_needed = "~/.config/marlin/hooks/notify.sh"
on_session_done = "~/.config/marlin/hooks/notify.sh"
```

## 10. Dependencies (deliberate, few)

| Dep | Why | Risk hedge |
|---|---|---|
| std.http | HTTPS/SSE and bounded fetches through one daemon-owned pool | transport stays behind one interface |
| SQLite (C) | durable block/session/blob store and FTS5 transcript search | system-linked locally, embedded in releases |
| libvaxis (Zig) | TUI: input, mouse, OSC52, unicode width | active, Ghostty-adjacent |
| focused internal TOML decoder | config | only supported Marlin shapes; no runtime dep |
| std.json | strict parse + our lenient-repair layer on top | — |

Everything else: std. No async framework or custom allocator. Runtime-owned
objects use libc's process-wide allocator because their ownership deliberately
crosses threads; turn/block parsing uses arenas because blocks are write-once.
This avoids stranding small allocations in the ReleaseFast SMP allocator's
per-thread free lists when dispatcher allocations are freed by socket writers.

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
