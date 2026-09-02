# Marlin — repo instructions

Marlin is a daemon-based AI coding agent in Zig (0.16): `marlind` owns all
state (sessions, agent loop, sqlite store, provider connections); the TUI and
headless CLI are thin socket clients. Docs are the contract — start with
`docs/ARCHITECTURE.md`, then the active milestone plan in `docs/`.

## Product discipline

Marlin is a **daily driver, not a kitchen sink**. Before adding a surface,
tool, protocol message, or dependency, answer three questions: does daily
use demand it (not "would it be nice"), can it live at a process boundary
instead of in the Zig core, and what existing thing stops earning its keep
to pay for it? "The last feature felt good" is not a reason; the default
answer is no. Standing walls: README Principles, and ARCHITECTURE
"Native vs guest" (frozen guest adapter — do not chase parity).

## Build and test

- `zig build fmt` — format all Zig source and `build.zig`. Run this while
  editing, before tests and handoff; do not leave formatting for CI.
- `zig build fmt-check` — verify formatting without changing files. The
  repo-owned pre-commit hook checks the equivalent staged snapshot, and CI
  runs this step against the checked-out commit.
- `zig build` — build AND install `zig-out/bin/marlin`, defaulting to
  ReleaseFast for source installs. Official release artifacts are built
  ReleaseSafe (safety checks stay on in a long-running daemon); the
  ReleaseFast/ReleaseSafe delta is unmeasured, and a Debug install is
  noticeably slower. Pass `-Doptimize=Debug` only for debugging the binary.
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
  (native turn loop; guest Claude Code turns also live here today — a
  wall leak, see ARCHITECTURE.md Native vs guest), `context.zig`,
  `store.zig` (sqlite), `tools/`, `sandbox.zig`, `permissions.zig`,
  `network_policy.zig`. `provider/claude_code.zig` is a guest adapter, not
  a third wire dialect.
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

- Run `scripts/install-git-hooks.sh` once per clone. The pre-commit hook
  rejects unformatted Zig changes before they enter history.
- Do not commit, push, or branch unless explicitly asked.
