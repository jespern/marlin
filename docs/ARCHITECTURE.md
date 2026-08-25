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
- `marlin ls / attach <handle> / archive <handle> / unarchive <handle> /
  kill <handle>` —
  thin protocol clients for scripting.

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

**Mode B — protocol over ssh (PRIMARY).** A local `marlin` client speaks
the wire protocol to a remote daemon, ssh carrying NDJSON instead of
terminal frames:

```
marlin attach work      # ssh work ... → daemon.sock; blocks stream back
marlin ls work
```

Transport is `ssh <host> nc -U <sock>` (or an equivalent stdio bridge
subcommand, `marlin _pipe`, to drop the nc dependency). Named remotes in
config:

```toml
[remote.work]
host = "work"           # ssh config name; keys/agent/jump hosts all apply
```

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

**Mode A — ssh as terminal transport (fallback).** `ssh -t box marlin` /
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
   `/reboot --build` restores the terminal, runs
   `zig build -Doptimize=ReleaseFast` with live output there, and proceeds only
   on success. Either way the candidate is sanity-exec'd (`--version`) before committing —
   exec-into-broken-binary is the one unrecoverable failure (daemon gone,
   nothing to reattach), so it must be impossible.
2. **Quiesce.** Default: wait for running turns to reach a block boundary.
   `/reboot!` interrupts instead: finalized blocks are truth, partial delta
   buffers are discardable; interrupted sessions get a `system_note`
   ("interrupted by reboot") and resume with `--continue`. Running
   background bash tasks are listed for confirmation (they get orphaned).
3. **Daemon exit.** Persist, stop accepting clients, unlink the public socket,
   then ACK and exit. Removing the socket before the ACK makes the client-side
   exec a clean handoff rather than a race with a dying listener. No exec on
   the daemon side — the client's autostart path brings up the new binary.
   Connection setup also retries transient EOF/reset errors during `hello`, so
   it remains compatible with an older daemon that ACKs before releasing its
   socket. One restart mechanism, not two.
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
  content-addressed blob in SQLite. `!c` and
  scrollback read the full blob; context assembly reads `inline_body`. The cap
  happens at capture time for the *inline* copy only — the full output is never
  lost. (Hermes pattern.)
- **`compaction` is a block, not an edit.** It records "blocks [a..b] are
  represented by this summary in context from now on." History is untouched.
- **Synthetic `user_msg` blocks are model context, not user authorship.** File
  windows rehydrated after compaction carry `synthetic=true`; clients collapse
  them to a filename note and exclude them from input history. The default is
  false so logs and clients from before the marker remain compatible.
- **Turn grouping**: blocks carry `turn_id` so the UI can collapse/expand a
  whole turn (user msg → reasoning → N tool roundtrips → assistant msg).

### Storage: SQLite, one DB

`~/.local/state/marlin/marlin.db` (WAL mode). Tables:

```
sessions(id, title, created_at, cwd, model, effort, provider, status,
         pinned_context, config_json, parent_sid, kind, parent_block_id,
         max_rounds)
blocks(id, session_id, turn_id, seq, kind, ts, body_json)
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

Local and test builds link the platform SQLite library to keep rebuilds fast.
Official release builds pass `-Dembedded-sqlite=true` and compile the vendored
amalgamation into the distributable binary. FTS5 is not compiled in or used
today.

### Future: cross-session search

A future `/search <query>` (with a headless `marlin search` equivalent) can use
an SQLite FTS5 virtual table over user and assistant text plus compact tool
summaries. Raw multi-megabyte tool blobs should stay out of the default index.
Results should carry the session handle, turn/sequence, timestamp, and a short
highlighted snippet so selecting one can attach to the session and jump to the
matching block.

This should land as a schema migration with a batched backfill, not as an
unadvertised table in the initial schema. At implementation time the embedded
release build can add `SQLITE_ENABLE_FTS5`; system-linked development builds
must capability-check FTS5 or provide a slower scan fallback so local builds do
not depend on platform-specific SQLite compile options.

### Growth & trimming

Text blocks are cheap (~1GB/yr worst case); **blobs and images are the
growers**. A future FTS index will add another copy of indexed text. The append-only
invariant protects *causal block structure*, not every 400KB build log
forever — same insight as L1 pruning, applied to disk: blob bodies are
regenerable/low-value with age; block structure is not.

**Day-one schema commitments** (cost nothing now, painful to retrofit):

- `PRAGMA auto_vacuum = INCREMENTAL` set at DB creation — cannot be enabled
  retroactively without a full vacuum rewrite.
- Blobs carry `created_at` + `tombstone`; refs live in `blob_refs` so
  orphan detection is a join, not a scan of block bodies.

**Trimming design (post-v1, lands when the DB first annoys someone):**

- **Session lifecycle: archive → delete.** Archive is implemented: `/archive`
  and `marlin archive <session>` hide a durable session hierarchy from default
  navigation while retaining its complete log; `marlin ls --all` and
  `marlin unarchive <session>` provide recovery. Permanent
  `marlin rm <session>` remains future work; it will delete blocks + decrement
  blob refs.
  Optional retention config (`delete_archived_after = "180d"`, off by default)
  remains future work. Explicit or policy-driven, never silent.
- **Blob demotion.** Blobs past an age horizon whose only referents sit in
  idle sessions get truncated to a tombstone ("full output expired <date>,
  was 412KB, hash …"). Every block and ref stays resolvable — scrollback
  never breaks, `!c` on ancient output says "expired" instead of lying.
  Images get their own (shorter) horizon or thumbnail-only demotion.
- **`marlin gc`**: orphan-blob sweep → expired-blob demotion →
  `PRAGMA incremental_vacuum` → future search-index optimize → WAL checkpoint; reports
  bytes freed. Optionally auto-runs on daemon idle at low cadence.
- DB size surfaces in `marlin ls` / dump-state — not the status bar (it is
  never a mid-turn decision).
- Test hooks: tombstones are first-class in the dump-state oracle (a
  tombstone survives reboot as a tombstone); gc→reboot→dump joins the
  reboot matrix.

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
      → emit coalesced text/reasoning delta events as text arrives
      → collect tool_calls (may be several)
    if no tool_calls: finalize assistant_msg block; done
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
  Consecutive safe calls overlap; mutations and unknown tools remain ordering
  barriers. Calls and results are each persisted as contiguous ordered groups,
  matching the provider transcript even when completion order differs.
- **Cancellation**: interrupt sets an atomic flag; the HTTP read loop and tool
  subprocess waits poll it. Every tool subprocess owns a process group, so
  interrupt/timeout sends SIGTERM → grace → SIGKILL to the complete
  pipeline and its descendants, then reaps the direct child. The half-finished
  turn is finalized as an interrupted `system_note` + whatever blocks completed
  (the log stays consistent). Forced kills first snapshot live descendants
  via `ps`, so processes that left the group via setpgid (`timeout(1)` is
  the canonical case) are terminated individually instead of orphaning.
- **bash wall-clock limit**: commands are killed after `timeout_seconds`
  (default 600, max 3600 — the model raises it for long builds). Timeout is
  a Result, not an error: everything captured before the deadline reaches
  the model with a note naming the limit, so a timed-out build is
  debuggable instead of a blank failure.
- **Graceful SIGTERM/SIGINT**: a self-pipe watcher thread turns the signal
  into the ordinary `.shutdown` dispatcher event — socket removed, store
  closed — the same path `/quit` and reboot use. (SIGHUP stays ignored so
  the daemon survives its spawning terminal.)
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
- Every OpenRouter request carries the Marlin session's stable `session_id`.
  OpenRouter therefore keeps a session on the same provider/cache and groups
  its generations in Activity. `[providers.openrouter] sort` defaults to
  `"throughput"` (`"latency"`, `"price"`, or `null` are supported).

### No single point of failure

Four distinct failure layers, four distinct answers:

1. **Aggregator outage** (OpenRouter: one auth endpoint, one billing
   account, one proxy — every model gone at once). Mitigation: 2-3 DIRECT
   provider entries alongside it. Pure config, zero code — xAI, DeepSeek,
   Z.ai, Mistral, OpenAI, Gemini's compat endpoint are all
   `base_url + api_key_cmd` in the openai_compat dialect. The council
   models (sol / fable / grok / glm) all have direct endpoints: councils
   survive an OpenRouter outage on config alone.
2. **Model-family outage** (Anthropic having a bad day). Mitigated by
   holding keys for ≥2 families; the anthropic dialect (already planned
   for cache_control) doubles as the direct line to the most-used family.
3. **Account failure** (credits, revoked key, tier limits). Only a second
   billing path fixes this — direct keys are that path, not a second
   protocol.
4. **No internet.** `[providers.local]` (llama.cpp/vLLM/Ollama) is spec'd;
   exercise it in the smoke suite once so it's KNOWN working, not
   theoretically working.

**Failover policy** (the one piece of real code):

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
auth for platforms not in use. The two-dialect rule holds.

**Accounting footnote:** OpenRouter reports $ directly; direct providers
report only tokens. The status-bar `$` needs a small local price table
for direct routes (or degrades to tokens-only) — don't let it lie.

- **Usage accounting is provider-reported**: every response's `usage` field is
  stored on the session (`session.meta` event carries it to clients). Token
  estimates for un-sent deltas use bytes/4 — good enough because true usage
  resyncs every turn. No tokenizers in the binary.
- OpenRouter requests set explicit `cache_control` breakpoints on the stable
  system prompt, the last stable message before the live environment, and a
  completed tool batch for Claude/Gemini/Qwen families. Models with automatic
  caching use the same append-only prefix without extra parameters. Returned
  cached/write/reasoning token counts and generation/provider ids are decoded
  for diagnostics; OpenRouter remains the observability system of record.
- HTTP uses a daemon-owned `std.http.Client` pool shared by provider requests,
  bounded fetches, catalogs, and network blocklists. It retains reusable
  connections across rounds while the transport remains isolated behind one
  interface.

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
  and attachable) and the multiplexer groups them beneath the parent. The
  first slice waits on one child and forbids recursive task calls; concurrent
  ordered fan-out is the next widening step.

Cache discipline, stated once: between L1/L2 events the stable prefix is
strictly append-only. Volatile date/git/sandbox state is inserted immediately
before the newest user/steer input, so it cannot invalidate cached prior
history. L1/L2 are the only deliberate stable-prefix breaks; both are rare and
logged as `system_note` blocks so cost anomalies are explainable.

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
- An `ask` emits `approval.request` to *all* subscribed clients; first decision
  wins; timeout (default: none — turn parks in `awaiting_approval`, exactly the
  state the session picker, actionable status summary, and phone surface).
- bash sandboxing (M3.5, stolen from zag): Seatbelt profile on macOS, Landlock
  + seccomp on Linux; deny-by-default on `~/.ssh`, key files, browser profiles.
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
  layers: (a) known-value scrub — the daemon greps tool output for the
  literal bytes of every secret it loaded and replaces with
  `[REDACTED:<name>]`; exact match, zero false positives; (b) pattern
  scrub for secret-shaped strings (sk-*, AKIA*, PEM blocks, JWTs),
  configurable since build logs hit false positives. Redaction runs
  before persistence AND context assembly: the model never sees the
  bytes, so injection cannot make it repeat them. (Same principle as
  1Password-for-Claude's zero-exposure framework: the agent may USE a
  credential, it never HOLDS it in context.)
- **Config holds no plaintext.** `api_key_env` (existing) or
  `api_key_cmd = "op read op://..."` — run at daemon start and /reboot,
  cached in memory. op/pass/security(1) become the vault; marlin never
  writes a key to disk.
- **Protected paths enforced, not requested.** read_file/grep on
  `.env*`, `*_rsa`, `*.pem`, `~/.aws/credentials` etc. returns
  refusal-as-data ("blocked by secrets policy; /allow to override") —
  policy in the tool layer, not a plea in the system prompt.
- **(v2 door) Credential brokering:** daemon as forward proxy injecting
  auth headers for allowlisted hosts, so agent-written code calling
  external APIs never holds tokens (Agent Vault pattern). Needs TLS
  interception + CA management; wrong cost/benefit for v1, right shape
  for the daemon if it ever matters.

**Extension tools — process boundaries only:**

- **MCP client** (v1): stdio transport first, HTTP later. Config lists servers;
  their tools appear in the registry with provider-safe names
  (`mcp__playwright__click`). Approval policy applies identically. The client
  speaks the current stateless protocol and falls back to the deployed legacy
  initialize lifecycle.
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

**No persistent sidebar.** Session navigation is occasional; it must not tax
every frame with permanent horizontal chrome. `/sessions` opens a fuzzy picker
showing title, workspace, recency, and state. J/K switches recent sessions in
normal mode. The status bar reports background sessions only when actionable
(`2 running · 1 approval`), and narrow terminals lose nothing. A split pane
identifies its session with a compact pane label.

```
┌─ main: api-fix ● ───────────────────────────────────┐
│ blocks rendered as cards:                           │
│ user / assistant md / collapsed tools               │
│ [streaming region at bottom]                        │
├─ todo (when present) ───────────────────────────────┤
│ ✓ parse args   ▸ wire store   · tui                  │
├─ input ─────────────────────────────────────────────┤
│ > _                                                  │
└─ status: model · ctx% · $ · state · 1 approval ─────┘
```

- **Modes**: insert (typing → input box), normal (j/k scroll blocks, J/K
  recent sessions, `a` archive the focused session and advance, `A` archive
  every finished child while preserving active children, `/sessions` for
  arbitrary attach, v visual-select, y yank, s/x split, tab cycle panes).
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
- **Command namespace**: `/` = session & harness commands (`/sessions`,
  `/model`, `/compact`, `/new`, `/archive`, `/allow`); `!` = terse aliases for
  frequent actions (`!rb` expands to `/reboot --build`, `!c` copies the last
  output). Plain text = message to agent. `Esc` during a turn = queue steer
  text; `Ctrl+C` = interrupt.
- Tool blocks render collapsed by default (name + one-line summary + status),
  expand on demand. Approvals render as inline prompt cards.

### Image / asset paste

Bracketed paste is text-only, so complex assets are grabbed out-of-band
(the Claude Code approach):

- **Capture (client).** On paste keystroke, check the OS clipboard for image
  data before falling back to text: NSPasteboard/pngpaste (macOS),
  `wl-paste -t image/png` (Wayland), `xclip -t image/png` (X11). Pasted TEXT
  that resolves to an existing image/PDF path (which is what drag-onto-
  terminal produces) offers attach-by-path — that variant works over ssh too.
- **Wire + store.** Chunked attachment-upload protocol message (base64 body,
  stays nc+jq debuggable); daemon writes to the existing blob store (an
  image is a blob with a mime type). `user_msg` gains
  `attachments: []BlobRef` — a pasted image is part of the message, not a
  new block kind.
- **Context assembly.** Provider layer maps attachments to image content
  parts (both dialects take base64). Non-vision model → degrade to
  `[image: 1.2MB png]` + status-line warning. Images are prime L1 prune
  targets: huge in tokens, regenerable from the blob — old image parts get
  stubbed first.
- **Rendering.** Kitty graphics protocol where available (Ghostty/Kitty/
  WezTerm/iTerm2; vaxis has support) for inline thumbnails; elsewhere a
  placeholder card `▣ image.png 1.4MB [o: open]` with `o` → open/xdg-open
  on the blob. No sixel — the terminal set that has sixel but not kitty
  protocol is not worth the code.
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
| SQLite (C) | durable block/session/blob store; future FTS5 search | system-linked locally, embedded in releases |
| libvaxis (Zig) | TUI: input, mouse, OSC52, unicode width | active, Ghostty-adjacent |
| focused internal TOML decoder | config | only supported Marlin shapes; no runtime dep |
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
