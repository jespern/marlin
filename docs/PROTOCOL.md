# marlin wire protocol

NDJSON over a unix socket (optionally TCP + token auth). One JSON object per
line, `t` discriminator. Source of truth: `src/core/proto.zig` — this document
tracks it and records semantics that don't fit in types.

Status: types sketched (proto_version 1); encode/decode + golden transcript
tests land in M1. See docs/ARCHITECTURE.md §3 for the message list and the two
stream disciplines (deltas are ephemeral / from_seq resume).

## Notes for implementers

- Unknown fields are ignored on read; unknown `t` values are an error.
- The daemon never blocks on a slow client: per-client outbound queues with a
  drop-and-mark-stale policy for delta messages (blocks are never dropped —
  a stale client re-syncs via from_seq).
- `hello` is mandatory before anything else; version mismatch → `err` + close.
