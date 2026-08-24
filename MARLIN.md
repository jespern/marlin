# Marlin — repo instructions

Marlin is a daemon-based AI coding agent in Zig (0.16): `marlind` owns all
state (sessions, agent loop, sqlite store, provider connections); the TUI and
headless CLI are thin socket clients. Docs are the contract — start with
`docs/ARCHITECTURE.md`, then the active milestone plan in `docs/`.

## Build and test

- `zig build` — build AND install `zig-out/bin/marlin`, defaulting to
  ReleaseFast (the installed binary is the daily driver; a Debug install is
  5-10x slower). Pass `-Doptimize=Debug` only for debugging the binary.
  Unit tests always compile Debug regardless. `zig build test` and
  `zig build e2e` do NOT install; a running daemon only picks up changes
  after an install + reboot (`!rb` in the TUI).
- `zig build test` — unit + fixture tests. Always use this, never bare
  `zig test <file>` (module graph and deps won't resolve).
- `zig build e2e` — end-to-end scenarios: real binary against the fake
  provider (`src/testing/scenarios/*.json`).
- `zig build converge` — reboot vs kill-9 state convergence.
- `zig build smoke` — hits the real OpenRouter API and costs money; run only
  when explicitly asked.
- Zig's cache is content-based: an unchanged tree reports cached test
  results; `touch` does not force a re-run.

## Layout

- `src/core/` — shared: wire protocol (`proto.zig`), config, block model,
  credentials. Protocol changes must stay decode-compatible: new fields need
  defaults; unknown fields are ignored on read.
- `src/daemon/` — `daemon.zig` (threads/ownership: Store and Session structs
  are dispatcher-thread only — read the header before touching), `loop.zig`
  (turn loop), `context.zig` (system prompt + context assembly),
  `store.zig` (sqlite), `tools/`, `sandbox.zig`, `permissions.zig`,
  `network_policy.zig`.
- `src/client/` — TUI and headless. DEPENDENCY RULE: `client/` imports only
  `core/`, never `daemon/`.
- `src/testing/` — e2e runner, fake provider, scenarios.
- `zig-pkg/` — vendored deps; never edit.

## Conventions

- New source files must be added to the test import block in `src/main.zig`
  or their tests will silently not run.
- Tests live in-file in `test` blocks; prefer real filesystem/e2e probes
  over mocks (see the Seatbelt canary tests for the house style).
- Tool/runtime errors are data returned to the model, never crashes.
- Comments are sparse and explain constraints the code can't express; no
  change-narration.
- When behavior changes, update the relevant `docs/*.md` in the same change
  — the milestone docs track "implemented vs verified" honestly; don't
  claim verified without a test or live probe.

## Gotchas

- macOS `/tmp` and `/var` are symlinks into `/private`; Seatbelt `subpath`
  parameters match real paths only — always realpath before building
  sandbox profile parameters.
- The e2e runner pins `MARLIN_PERMISSIONS=0` (scenarios assert the legacy
  approval transcript); per-scenario `env` can override.
- SBPL rule conflicts resolve last-match-wins; the startup canary in
  `sandbox.zig` pins this — keep it passing rather than reasoning from
  documentation.

## Git

- Do not commit, push, or branch unless explicitly asked.
