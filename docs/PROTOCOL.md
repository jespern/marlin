# marlin wire protocol

NDJSON over a unix socket. One JSON object per line, encoded as std.json's
tagged-union form: `{"<type>":{...payload}}`. Source of truth:
`src/core/proto.zig` (types) — this document records semantics.

Each complete record, including its newline, is capped at 32 MiB. Readers use
small scratch buffers plus bounded dynamic assembly, so scratch capacity is
never an accidental wire limit. Clients reject oversized outbound messages
before optimistic UI state; the daemon drains an oversized inbound record and
returns `err{line_too_long}` instead of silently dropping the connection.

proto_version: 1

## Connection lifecycle

1. Client connects to the socket (`$MARLIN_SOCKET` > `$XDG_RUNTIME_DIR/marlin/
   daemon.sock` > `~/.local/state/marlin/daemon.sock`).
2. First message MUST be `hello`; anything else → `err{no_hello}`.
   Version mismatch → `err{version}` and the client should disconnect.
3. Daemon replies `hello_ok`. After that, messages flow freely both ways.
4. Disconnect is detected by EOF on either side. All client state
   (subscriptions) dies with the connection; sessions do NOT.

An accepted socket has two seconds to complete `hello`; the client shuts down
both directions and reports `DaemonHandshakeTimedOut` if a listener accepts but
never speaks. This prevents a wedged daemon from presenting a blank terminal.

Autostart: clients try to connect; on failure they spawn `marlin daemon`,
poll the socket (50ms × 100), then handshake. The daemon holds a single
instance with a non-blocking advisory lock beside the socket. Only the lock
owner may remove a stale socket and bind; crashes release ownership in the
kernel. Coordinated reboot removes the old socket and releases the lock before
acknowledging the handoff, so the replacement can bind immediately.

`hello_ok.network_configured` reports whether a blocklist or explicit deny was
requested, while `network_filtering` reports whether blocking rules actually
loaded. This lets clients distinguish an intentional opt-out from a configured
policy that failed open. Both default false when decoding an older daemon.

## Client → daemon

| message | payload | reply |
|---|---|---|
| hello | proto_version, client_kind | hello_ok or err |
| session_create | cwd, model, effort?, title?, approvals? | session_created{sid} |
| session_list | include_archived? | session_list_result{sessions}; archived omitted by default |
| session_watch | incremental? | initial session_list_result, then structural catalog updates; incremental clients receive session_upsert/session_remove, legacy clients receive refreshed snapshots |
| session_kill | sid | ok (sets the turn's cancel flag, denies pending approval) |
| session_archive | sid, archived? | ok; archives/restores the session and descendants, err{busy} if archiving active work |
| session_set_model | sid, model | ok, or err{busy} mid-turn. Crossing native↔guest (`claudecode/` prefix) is a regime change; a dedicated err lands with the durable agent field (ARCHITECTURE.md, Native vs guest). Today the prefix is inferred from the model string and the switch is allowed — a known leak. |
| session_set_effort | sid, effort | ok, or err{busy} mid-turn |
| session_set_sandbox | sid, enabled | ok, or err when busy/unavailable |
| session_set_network_filtering | sid, enabled | ok, or err when busy/no policy loaded |
| sub | sid, from_seq, tail_limit?, before_seq?, replay_limit?, replay_done? | replayed blk×N, optional replay_done marker, then status once live |
| unsub | sid | ok |
| input | sid, text, request_id?, attachments? | ok/err echoing request_id; uploads bounded image media and starts a turn (idle), or queues a text-only steer (running/awaiting approval) |
| mcp_list | — | mcp_list_result with per-server readiness, tool count, and discovery error |
| mcp_add | name, cmd[] | mcp_list_result after atomically persisting config and rebuilding extensions; err{busy} while any turn is live |
| mcp_remove | name | mcp_list_result after atomically persisting config and rebuilding extensions; err{busy} while any turn is live |
| mcp_restart | name | mcp_list_result after rediscovery; failure is reported as server health, not daemon failure |
| mcp_reload | — | mcp_list_result after atomic registry replacement; old registry survives invalid config/build failure |
| approve | sid, approval_id, decision | ok (first decision wins; stale ids ignored) |
| session_compact | sid | ok; runs L2 compaction on a turn-like lifecycle (running → idle), err{busy} mid-turn. Guest sessions must refuse (no Marlin-assembled context); today they fail as an internal DelegatedContext after starting a turn — a leak. |
| interrupt | sid, report? | ok, or interrupt_result with phase/elapsed diagnostics when report=true (cooperative cancel; also denies a pending approval) |
| reboot | force? | quiesce (wait for turns; force interrupts), retire the listening socket, then ok RIGHT BEFORE daemon exit — requester's cue to re-exec; non-force returns err{approval_pending} rather than wait on an approval with no client |
| shutdown | — | ok, then daemon exits cleanly |

`session_create.approvals`: `"default"` (mutating tools ask) or `"auto"`
(everything auto-approved — what `marlin run` uses; `--ask` opts back in).

`effort`: `"auto"` omits the provider parameter and preserves the model's
default. Explicit values are `"none"`, `"minimal"`, `"low"`, `"medium"`,
`"high"`, `"xhigh"`, and `"max"`; support is model-dependent. Guest
(`claudecode/`) sessions ignore Marlin effort; the protocol should refuse
`session_set_effort` on them once the durable agent field exists.

Guest vs native is a session regime (ARCHITECTURE.md), not a `SessionKind`.
`kind` remains hierarchy (`root`, `task_child`, `review_child`). The guest
adapter persists Claude Code stream-json as ordinary blocks; `cc_approval`
is multiplexer UX for their permission prompts, not Marlin tool dispatch.

`sub.from_seq`: 0 = live-only. N ≥ 1 = replay stored blocks with seq ≥ N
first, then live. Clients that reconnect pass last_seen_seq + 1.

`sub.tail_limit`: when non-zero, replay only the newest N stored blocks in
ascending transcript order (the daemon caps N at 512). With `before_seq=N`,
the window is additionally restricted to blocks with seq < N. This keeps both
initial attach and backwards scrollback independent of session length: Marlin
requests 256 blocks at a time and atomically prepends another page when the
user reaches the loaded top. Every bounded replay ends with
`replay_done{oldest_seq,newest_seq,has_older,plan_items}`. `plan_items` carries
the latest durable plan revision independently of the bounded block window, so
the pinned plan is correct immediately after attach.

`sub.replay_limit`: when non-zero with `from_seq`, replay at most 512 blocks
forward and return `replay_done{...,has_newer,forward:true}`. If `has_newer` is
true the client requests the next page from `newest_seq+1`. The daemon does not
make that connection live until the final page: because replay and fan-out share
the dispatcher, the final durable query → subscription handoff is gap-free.
Forward and tail pages also target a 16 MiB encoded-byte budget (one exceptional
record may consume a page alone), so a handful of large pastes cannot overflow
the bounded client outbox.

`sub.replay_done`: requests the same terminal marker for a normal from-seq
replay. It defaults false so a new daemon never sends an unknown union tag to
an older client. Older daemons ignore the additive request fields; the client
still gets a correct, possibly unbounded replay.

`input.request_id` is an additive client-generated correlation id. For every
non-zero id the daemon sends exactly one terminal `ok` or `err` carrying the
same id, including load/allocation/start failures that previously escaped as
dispatcher logs. This lets a client optimistically render immediately, then
remove only the rejected echo and restore its prior state. Zero is the legacy
untracked value; all three fields default to zero when talking to older peers.
Inputs within 4 KiB of the 32 MiB record ceiling are rejected with
`input_too_large`: the persisted block envelope is slightly larger than the
command envelope, and every accepted message must remain replayable.

`blk.reasoning.commentary` defaults to false. True marks the model's
deliberate mid-turn narration (content emitted alongside tool calls), which
clients keep visible; false is the raw provider reasoning stream, which
clients fold out of the default transcript (some models draft entire replies
inside it). Blocks persisted before the field decode as raw reasoning.

`blk.user_msg.synthetic` defaults to false. When true, the text is internal
model context rehydrated after compaction: clients render a compact note and
must not treat it as user-authored input or add it to command history. For
compatibility, clients should recognize the legacy
`[rehydrated after compaction]` prefix as synthetic too. `compaction.summary`
is likewise model context; transcript UIs render only a compaction marker.

`session_archive.archived` defaults to true. Archiving is durable and
non-destructive: blocks and blobs remain available, but archived sessions are
read-only and omitted from ordinary list/watch snapshots. Send `archived:false`
to restore the hierarchy. Parent archive/restore operations include all
descendants.

## Daemon → client

| message | when |
|---|---|
| hello_ok | handshake |
| session_created | reply to session_create |
| session_list_result | reply to session_list |
| session_upsert {session} | one added/restored/changed catalog row for an incremental session watcher |
| session_remove {sid} | one archived catalog row removed from an incremental session watcher |
| blk {sid, b} | a block was persisted (replay AND live fan-out) |
| delta {sid, turn_id, text} | streaming assistant text (ephemeral) |
| reasoning_delta {sid, turn_id, text} | provider reasoning stream (ephemeral, rendered separately from assistant text) |
| stream_status {sid, bytes, quiet_ms} | stream liveness while receiving from the provider: cumulative body bytes this round + ms since the last visible delta; throttled to ~1/s (ephemeral) |
| replay_done {sid, oldest_seq, newest_seq, has_older, has_newer, forward, plan_items} | requested replay page finished; bounded clients page backward with `has_older` or forward with `has_newer`; the final page restores the latest plan |
| status {sid, state} | session state change: idle/running/awaiting_approval/err/done |
| approval_request {sid, approval_id, call_id, tool, args_json} | a mutating tool call parked on the gate; answer with `approve` |
| session_meta {sid, tokens_in, tokens_out, context_used, context_limit} | after each turn; ALWAYS sent before the closing status. context_* feed the status-bar gauge (0 = unmeasured) |
| model_list_result {models, pricing} | reply to `model_list`; `pricing` optionally supplies input/output USD per million tokens and a tiered-rate flag keyed by model id |
| interrupt_result {sid, active, already_requested, request_count, pending_ms, phase_ms, phase} | opt-in cancellation acknowledgement; reports the current starting/context/provider/approval/tool/child/compaction/finishing phase and its age; repeated interrupts also report elapsed cancellation time |
| ok {request_id?} | generic ack; non-zero for a correlated input reply |
| err {code, msg, request_id?} | bad_msg, no_hello, version, no_session, busy, archived, bad_approval, approval_pending, reboot_pending, line_too_long, response_too_large; non-zero for a correlated input rejection |

Each entry in `session_list_result.sessions` includes `sid`, `title`, `cwd`,
`model`, `effort`, persisted `status`, `created_at`, whether the session is
currently `running`, and the effective `sandboxed` and `network_filtering`
states. M6 hierarchy fields are `parent_sid` (null for roots), `kind` (`root`,
`task_child`, or reserved `review_child`), `parent_block_id`, and `max_rounds`.
`archived` is true only in inclusive list results. Older clients may ignore
these fields; older entries decode as active roots.

`model_list_result.models` remains the compatibility source of registry-form
model ids. `pricing` is additive and may be empty: clients must treat a
missing rate as unknown, never as free. OpenRouter's per-token catalog rates
are normalized to USD per million tokens by the daemon.

`sid` remains the durable numeric protocol identity. Clients derive the
human-facing session handle from it (domain-separated SHA-256, eight hex
characters unless collision extension is needed) and resolve unique prefixes
locally against an inclusive session list; the daemon protocol itself does not
trade readability for a second identity or a storage migration.

## Approval flow (M2)

1. Turn thread hits a mutating tool call in an `approvals="default"` session.
2. The turn thread arms the gate, then `approval_request` fans out to ALL
   subscribed clients and session-watch clients; session status flips to
   `awaiting_approval`. The turn thread then parks. Arming before publication
   means an immediate answer cannot be lost.
3. Any client answers with `approve{approval_id, granted|denied}`. First
   decision wins; later/stale answers get `ok` but are ignored.
4. An `approval` block is persisted with the decision; status returns to
   `running`; execution continues (granted) or the tool result is a denial
   error the model sees (denied).
5. `interrupt`/`session_kill`/daemon shutdown deny the pending gate so the
   turn never hangs. No timeout otherwise — parked is a feature (phone hook
   in M5 surfaces it).
6. The daemon retains the complete live request until resolution. `sub`
   replays it for a focused reconnect and `session_watch` replays background
   requests, so `awaiting_approval` always has an actionable card.

## Ordering guarantees

- Per session, `blk` messages arrive in seq order (single dispatcher thread).
- `delta`s are interleaved between `blk`s but carry no ordering promise
  beyond arrival order; they are presentation sugar. Blocks are truth.
- End of turn is: `session_meta` then `status{idle|err}`. Clients treating
  status as end-of-turn will already have the usage numbers.
- A correlated `input` receives one `ok` or `err` with its request id. Session
  status and durable blocks may precede the `ok`; `err` means no turn/steer was
  accepted for that request.
- Replay (`sub` with from_seq ≥ 1 or tail_limit > 0) and its requested marker
  complete before any live message for that session reaches the client. A
  partial forward page is not subscribed at all; the final page and live
  registration are one serialized dispatcher operation.

## Slow clients

Each memory-backed client outbox is capped at 64 MiB (two maximum records). If
a client stops reading and crosses the cap, the daemon shuts down its socket
and releases the queue; reconnect replays durable blocks with `from_seq`.
Blocks are therefore never silently dropped while daemon memory remains
bounded. Teardown calls `shutdown(2)` before joining both the writer and reader
threads, so a kernel-blocked write cannot wedge daemon shutdown or leave the
socket owned by a zombie process.

## Testing

- Unit round-trips: src/core/proto.zig tests.
- Live behavior: e2e scenarios drive `marlin run` (a real protocol client)
  against the daemon with the fake provider behind it.
- TODO (from docs/TESTING.md M1 rules): scripted protocol-client mode in the
  e2e runner for golden transcripts (multi-client fan-out, replay, steer).
