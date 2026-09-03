# Testing marlin

marlin's bar: **`zig build test && zig build e2e` green is the definition of
"works"** — a successful manual run is anecdote, not evidence. Features land
with their tests in the same commit. Expect more test code than core code;
that is intended, not accidental.

Run `scripts/install-git-hooks.sh` once after cloning. The repo-owned
pre-commit hook checks the complete staged snapshot with Zig's canonical
formatter, the same formatting gate as CI. Use `zig build fmt` during
implementation to format all Zig source and `build.zig`.

## The pyramid

| Layer | Command | What it proves | Network | When it runs |
|---|---|---|---|---|
| 0. Format | `zig build fmt-check` | Zig source matches the canonical formatter | none | every commit |
| 1. Unit | `zig build test` | each module's logic, inline `test` blocks | none | every save |
| 2. Fixture | `zig build test` (same step) | real recorded provider streams still parse | none | every save |
| 3. e2e | `zig build e2e` | the REAL binary against a scripted fake provider | localhost only | every commit |
| 4. Smoke | `zig build smoke` | live provider behavior hasn't drifted | real OpenRouter (~1¢) | nightly / manual |

**No mocks inside marlin — ever.** The binary under e2e test is the same one
users run; what we fake is the network peer (the fake provider), never an
internal component. If something can't be tested without an internal mock,
that's an architecture smell to fix, not a mock to write.

## Layer 1 — unit tests

Inline `test` blocks next to the code they test. Every file is forced through
the compiler by the import block at the bottom of `src/main.zig` — when you
add a file, add it there or its tests silently never run.

**The bug rule: every bug found at a higher layer gets reproduced as a test at
the LOWEST layer that can express it** — a protocol bug becomes a unit test on
proto.zig, not another e2e scenario. e2e catches regressions; unit tests
explain them.

## Layer 2 — fixture tests (recorded reality)

`src/testing/fixture_tests.zig` replays real captured SSE streams through the
parser pipeline at pathological chunk sizes (1 byte, primes, huge).

Recording a new fixture:

```bash
export OPENROUTER_API_KEY=...
scripts/record-fixture.sh <name> [model]     # → src/testing/fixtures/sse/<name>.sse
```

Review the capture (no secrets — generation IDs are fine), commit it, add a
replay test asserting the semantic content (text, calls, usage). When a
provider changes their stream format: re-record, watch what breaks, fix, keep
BOTH fixtures (old format + new) — providers roll back too.

Wanted-but-not-yet-recorded: mid-stream disconnect, 429 with Retry-After, and
real reasoning deltas (o-series / Claude via OpenRouter). Parallel tool calls
are covered synthetically and by the full-binary e2e batch scenario.

Guest adapters are tested at their process boundary in `loop.zig`: executable
fixture peers validate argv and JSONL in both directions. The Codex fixture
covers initialize/account checks, durable `thread/resume`, item-to-block
projection, approval responses, token usage, and secret-environment scrubbing.

## Layer 3 — e2e scenarios

```bash
zig build e2e                # all scenarios
```

For an interactive deterministic model, start the bundled fake server in one
terminal:

```bash
zig build fake-model
```

Then select `/model local/testing` in Marlin. No API key or endpoint variable
is required. The default script accepts any request, returns a stable response,
and repeats until interrupted. Pass a scenario to drive a specific sequence:

```bash
zig build fake-model -- src/testing/scenarios/02_tool_roundtrip.json
```

Each scenario is one JSON file in `src/testing/scenarios/`, consumed by two
programs at once:

- **marlin-fakeprov** (`src/testing/fake_provider_main.zig`) serves `steps`:
  for request N it validates the request body against `expect_contains` (so we
  assert what marlin SENDS — both directions are under test), then replays the
  scripted SSE events or an HTTP error.
- **e2e-runner** (`src/testing/e2e_runner.zig`) reads `check`: spawns the fake
  provider, then the real marlin binary with an isolated `XDG_STATE_HOME` temp
  dir and private dynamic endpoint overrides, then selects `local/testing` for
  provider-neutral scenarios. It asserts exit code, stdout/stderr substrings or
  exact `stdout_equals` / `stderr_equals` goldens, and — marlin's superpower —
  **the block log in the SQLite store** (`db_kinds`: the exact ordered list of
  block kinds the run must have persisted). The append-only store means every
  e2e test can verify the full causal history, not just the final output.

OpenRouter-only behavior keeps using `openrouter/test/model`; this prevents
generic scenarios from accidentally inheriting provider features such as
server-side web search.

Adding a scenario: copy an existing file, keep the naming convention
(`NN_short_name.json` — they run in sorted order), cover exactly one behavior
per scenario. If the fake provider needs a new capability (delays, dropped
connections, malformed chunks), extend `Step` in fake_provider_main.zig —
it's ~200 lines on purpose.

Current coverage: basic completion, tool round-trip (fragmented args),
--continue across invocations, provider 500 → system_note + exit 1, oversized
tool output → blob + inline elision, concurrent safe tool batches with
provider-order transcript reconstruction, and reasoning-only terminal responses
that either recover on the bounded retry or become a visible error without an
empty `assistant_msg`. A configured-provider scenario loads `[providers.acme]`,
supplies its named credential, and crosses the same real OpenAI-compatible
HTTP/SSE boundary through a dynamic test-only URL override.

The runner is fail-bounded as well as hermetic. Each Marlin invocation has a
30-second wall-clock deadline; timeout terminates its complete process group.
Per-scenario daemons inherit that group in tests, fake providers never inherit
the runner's output pipes, and every exit path terminates/reaps the provider
before attempting daemon shutdown. Unit coverage deliberately cancels a shell
whose grandchild ignores SIGTERM and proves the grandchild is gone, preventing
a failed test from keeping `tee` (or an agent turn) alive indefinitely.

Compaction regressions live at the lowest expressive layers: context unit
tests prove range edges cannot bisect a calls-first parallel turn and legacy
orphan results are omitted; TUI tests prove summaries/file contents never enter
scrollback or editor history; provider-error tests prove gateway envelopes are
reduced to a bounded actionable note.

## Layer 4 — live smoke

```bash
export OPENROUTER_API_KEY=...
zig build smoke              # skips (exit 0) when the key is unset
```

Four checks against a cheap real model: completion, tool round trip,
--continue recall. Catches the category fixtures can't: live provider drift.
CI runs it nightly and on manual dispatch, never on PRs.

## CI

`.github/workflows/ci.yml`: `zig build fmt-check` + unit/fixture + e2e on macOS and Linux
for every push/PR. Smoke is a separate job gated on schedule/dispatch with
`OPENROUTER_API_KEY` from repo secrets.

## Reboot / crash-recovery tests (lands with M3 `/reboot`)

Reboot correctness is NOT tested with hand-authored "convoluted state"
scenarios — imagined weirdness always misses field weirdness #16. Instead:
a state-snapshot oracle + a mechanically generated matrix.

1. **Oracle: canonical state dump.** `marlin dump-state` (hidden subcommand
   or runner-side) serializes everything the daemon considers durable truth
   — sessions, block logs, blob hashes, pending approvals, session state
   machines — as canonical JSON, ids/timestamps normalized. Every reboot
   test is then: `dump → reboot → dump → diff == ∅`, modulo an explicit
   allowlist (the reboot's own system_note; in-flight turn demoted to
   resumable). No per-scenario assertions; the diff catches categories
   nobody thought to assert.
2. **Matrix, not authorship.** Dimensions: turn state (idle / mid-stream /
   mid-tool / awaiting-approval) × session count/mix × background bash task
   (y/n) × reboot flavor (`/reboot` / `/reboot!` / `kill -9`+restart) ×
   store (fresh / needs-migration fixture) × UI snapshot (valid / corrupt /
   missing). The runner iterates the product; `delay_ms_between_events`
   freezes mid-stream/mid-tool states deterministically.
3. **Convergence family (the load-bearing test; `zig build converge`, run
   in CI's Linux leg).** Identical scripted
   setup; branch A `/reboot`, branch B `kill -9` at the equivalent moment;
   both restart, both dump. Dumps must be identical modulo the specified
   quiesce delta (`/reboot` may contain one more finalized block — that
   difference is pinned, not tolerated). Divergence means crash recovery
   broke or reboot does secret cleanup crashes won't get.
4. **Hand-authored scenarios only for non-matrix adversaries:** `--build`
   fails mid-compile (old daemon must keep running), candidate passes build
   but fails `--version` sanity exec, unparseable UI snapshot (default
   layout, same session), migration fails halfway (store untouched or
   cleanly rolled back), stale client vs new daemon (handshake rejects
   cleanly). One behavior per file, as usual.

Bug rule applies: matrix-found divergences get reproduced at the lowest
layer that expresses them (store recovery → store.zig unit test), never
enshrined as another e2e.

## Rules going into M1 (daemon + protocol)

1. **Every protocol message type ships with a golden transcript test** —
   recorded NDJSON exchanges replayed against the daemon, asserting responses
   byte-for-byte (modulo ids/timestamps, which get normalized).
2. The e2e runner grows a daemon mode: spawn `marlin daemon`, drive it with a
   scripted protocol client over the socket, assert both the wire traffic and
   the resulting block log.
3. Concurrency bugs get deterministic reproductions: the fake provider's
   `delay_ms_between_events` exists precisely to freeze races into scenarios.
4. Unit-test time stays under ~5s and e2e under ~30s locally. When they
   outgrow that, split steps — never skip them.
