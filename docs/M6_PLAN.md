# M6 execution plan

Status: **active**. M6a's durable synchronous read-only child and bounded
fan-out primitives are implemented and verified. M4 is verified; M5 is
productized and still needs a short real-server/hook dogfood pass. The workspace
recovery/isolation track formerly called M4.5 is deliberately Later.

Guest Claude Code sessions (ARCHITECTURE.md, Native vs guest) are a
multiplexer feature, not an M6 workstream. Do not schedule guest-parity
work (wrapping Seatbelt around `claude -p`, Marlin `task` inside their
loop, CC plan sync, extra guest agents) as M6. The adapter remains bounded;
councils may seat guest models only through bridge-enforced read-only
children. Marlin tools still do not enter the guest loop.

## What exists now

- The daemon already owns concurrent durable sessions, status watch/fan-out,
  approvals, reconnect replay, cancellation flags, and per-session UI state.
- M5 supplies one dynamic tool-schema and dispatch path for exec, MCP, and
  skills. MCP calls serialize safely per server; discovery failures are
  isolated, lifecycle/config changes are daemon-owned and atomic, and hooks run
  outside turn and dispatcher critical paths.
- Schema v4 and the protocol carry `parent_sid`, `kind`, `parent_block_id`, and
  the child round budget. Existing sessions migrate as roots; stale in-flight
  state becomes `err` after daemon restart.
- `task` creates one child through a typed dispatcher event/future, waits for
  its structured result, cascades parent cancellation, and limits children to
  a read-only tool profile with no recursive `task`. Children are ordinary
  attachable sessions grouped beneath their root in session listings.
- `task_batch` launches two to eight of those durable children concurrently,
  joins every child, and returns structured results in requested task order.
  A failed thread spawn joins existing workers before serial fallback.
- Named councils are shipped: daemon-owned atomic config, `/council`
  management, `/review` fan-out, durable `review_child` sessions, parent
  synthesis, and bridge-enforced read-only Claude Code seats.
- `parallel_safe` is **enforced** (this superseded the earlier
  "metadata-only" state): `loop.zig` runs each maximal consecutive safe group
  in chunks of at most eight worker threads and joins before persisting results
  in provider-call order. A spawn failure joins the partial chunk before the
  remaining calls fall back to serial execution. E2e scenario
  15_parallel_tool_batch covers ordering and overlap; Architecture §4 is the
  current description.
- The daemon still listens only on its local Unix socket. Remote clients use
  SSH-carried NDJSON (`--remote`/`_pipe`), while `marlin web` exposes the
  tokenless browser UI through Tailscale Serve with Host/Origin validation.

## Entry gate: finish proving M5

During M6, run one useful stdio MCP server and one notification hook during
ordinary work. Capture only actionable fixes: config
diagnostics, lifecycle/restart behavior, output rendering, and approval
classification. This is operational proof, not another feature phase.

Also close these bounded hardening debts when they intersect M6 work:

1. **Done:** cap consecutive `parallel_safe` execution at eight workers while
   retaining provider-call result order and per-call cancellation.
2. Give built-in bash and extension subprocesses one cancellation/deadline
   primitive (TERM, grace, KILL) instead of a mixture of blocking helpers.
3. **Partly done:** `/mcp` reports the named server and isolated discovery
   failure. Parser diagnostics still need the exact TOML table/field location.
4. Keep Fable's permission matrix separate; do not make child sessions a way
   around sandbox, protected-path, network, or secret-environment policy.

## M6a — durable child sessions and `task`

The smallest general primitive councils can reuse now exists:

- Store/protocol: `parent_sid`, `kind` (`task_child`, later `review_child`),
  `parent_block_id`, budget, and child state. Migrate existing sessions as
  roots. The `/sessions` snapshot becomes a hierarchy without a second state
  store.
- Tool contract: `task` takes a focused prompt plus optional model, effort, and
  round budget. The daemon—not the model—creates the read-only child, starts
  its turn, and returns `{child_sid,status,final_text,error_message}` as the
  parent tool result.
- Runtime: child creation crosses the dispatcher through a typed event/future;
  turn threads never create session/store hierarchy state directly. `task`
  waits on one child; `task_batch` manages a bounded group of two to eight.
- Lifecycle: parent interrupt cancels children it is awaiting; daemon restart
  reconstructs hierarchy and marks genuinely orphaned work honestly. Child
  failures are result data and do not crash the parent turn.
- UX: picker, short stable session handles, and `marlin ls` indentation are
  implemented. The status bar shows
  a parent's child count and actionable child activity, or the parent tag when
  a child is focused. Children remain ordinary attachable sessions; no
  permanent sidebar.

Verified checkpoint: one parent completes both a single child and a three-child
batch through the real daemon and fake provider. E2E asserts that delegation,
bash, and write tools are absent from child schemas, structured results return
to the parent, and hierarchy plus round budgets are durable in SQLite. A unit
concurrency probe proves overlap, the eight-child ceiling, and result ordering.

Remaining exit hardening: exercise batch disconnect/reconnect and cancellation
while several children are live.

## M6b — councils as specialized tasks

Implemented on M6a rather than as a second orchestration system:

1. Durable named council config with daemon-mediated atomic writes and
   `/council` list/set/remove UI.
2. `/review [council] <focus>` resolves a configured roster and launches the
   shared review mission from the parent session.
3. Read-only `review_child` sessions run in parallel with their model and
   budget recorded durably; Claude Code seats use the permission bridge to
   enforce the same no-write boundary.
4. The parent receives ordered reviewer outputs, gathers empirical evidence,
   and produces the final synthesis and recommendation.

Verified in unit/e2e coverage for named config, fan-out, durable review
children, and guest read-only enforcement. A real-repository council dogfood
also found and drove a sandbox fix. Interactive brief editing, claim clustering,
and a rebuttal mode remain optional follow-up work, not exit blockers.

## M6c — remote door: DECIDED and shipped (2026-08)

The trust boundary decision, recorded:

- Terminals: SSH-carried NDJSON (`marlin --remote <host> …` → `ssh <host>
  marlin _pipe`). SSH configuration is the entire naming and auth story;
  marlin keeps no host registry and adds no credentials.
- Phone/PWA: the tailnet. `marlin web` runs `tailscale serve` automatically
  (opt-out via `[web] tailscale = false`), giving a fixed tokenless https
  URL; the web layer validates Host and Origin to stop DNS rebinding and
  cross-site POSTs, and that is ALL it does — device identity and transport
  encryption belong to the tailnet.
- marlin never grows its own TCP listener, TLS, or bearer tokens. A hostile
  local user remains out of scope (single-user machines; loopback is
  machine-wide, so do not enable [web] on shared boxes).

## Explicitly Later

COW snapshots, drift/undo, write leases, worktree isolation, `/land`, and
`/discard` remain together in `WORKSPACE.md`. M6 child sessions use today's
workspace/permission behavior and must not smuggle in a half-built workspace
phase.
