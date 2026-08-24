# marlin wire protocol

NDJSON over a unix socket. One JSON object per line, encoded as std.json's
tagged-union form: `{"<type>":{...payload}}`. Source of truth:
`src/core/proto.zig` (types) — this document records semantics.

proto_version: 1

## Connection lifecycle

1. Client connects to the socket (`$MARLIN_SOCKET` > `$XDG_RUNTIME_DIR/marlin/
   daemon.sock` > `~/.local/state/marlin/daemon.sock`).
2. First message MUST be `hello`; anything else → `err{no_hello}`.
   Version mismatch → `err{version}` and the client should disconnect.
3. Daemon replies `hello_ok`. After that, messages flow freely both ways.
4. Disconnect is detected by EOF on either side. All client state
   (subscriptions) dies with the connection; sessions do NOT.

Autostart: clients try to connect; on failure they spawn `marlin daemon`,
poll the socket (50ms × 100), then handshake. The daemon holds a single
instance implicitly: a second daemon fails to bind the socket... after
deleting it. KNOWN GAP (M1): concurrent autostart can race; flock-based
single-instancing is listed for hardening.

## Client → daemon

| message | payload | reply |
|---|---|---|
| hello | proto_version, client_kind | hello_ok or err |
| session_create | cwd, model, title? | session_created{sid} |
| session_list | — | session_list_result{sessions} |
| session_kill | sid | ok (sets the turn's cancel flag) |
| sub | sid, from_seq | replayed blk×N (if from_seq ≥ 1), then status |
| unsub | sid | ok |
| input | sid, text | ok; starts a turn (idle) or queues steer (running) |
| interrupt | sid | ok (cooperative cancel; system_note lands when it takes) |
| shutdown | — | ok, then daemon exits cleanly |

`sub.from_seq`: 0 = live-only. N ≥ 1 = replay stored blocks with seq ≥ N
first, then live. Clients that reconnect pass last_seen_seq + 1.

## Daemon → client

| message | when |
|---|---|
| hello_ok | handshake |
| session_created | reply to session_create |
| session_list_result | reply to session_list |
| blk {sid, b} | a block was persisted (replay AND live fan-out) |
| delta {sid, turn_id, text} | streaming assistant text (ephemeral) |
| status {sid, state} | session state change: idle/running/awaiting_approval/err/done |
| session_meta {sid, tokens_in, tokens_out} | after each turn; ALWAYS sent before the closing status |
| ok | generic ack |
| err {code, msg} | bad_msg, no_hello, version, no_session |

## Ordering guarantees

- Per session, `blk` messages arrive in seq order (single dispatcher thread).
- `delta`s are interleaved between `blk`s but carry no ordering promise
  beyond arrival order; they are presentation sugar. Blocks are truth.
- End of turn is: `session_meta` then `status{idle|err}`. Clients treating
  status as end-of-turn will already have the usage numbers.
- Replay (`sub` with from_seq ≥ 1) completes before any live message for
  that session reaches the client (both are written by the dispatcher in
  order onto the same outbox).

## Slow clients

Per-client outbox is unbounded in M1 (memory-backed). A wedged client's
outbox grows until the daemon OOMs in theory; hardening item: cap outbox
depth, drop deltas first, mark the client stale and force re-sync via
from_seq. Blocks are never silently dropped — a stale client is disconnected
instead.

## Testing

- Unit round-trips: src/core/proto.zig tests.
- Live behavior: e2e scenarios drive `marlin run` (a real protocol client)
  against the daemon with the fake provider behind it.
- TODO (from docs/TESTING.md M1 rules): scripted protocol-client mode in the
  e2e runner for golden transcripts (multi-client fan-out, replay, steer).
