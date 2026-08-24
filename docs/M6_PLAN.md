# M6 execution plan

Status: **active**. The first M6a vertical slice (one durable synchronous
read-only child) is implemented and verified. M4 is verified; M5 mechanics are
verified and still need a short real-server/hook dogfood pass. The workspace
recovery/isolation track formerly called M4.5 is deliberately Later.

## What exists now

- The daemon already owns concurrent durable sessions, status watch/fan-out,
  approvals, reconnect replay, cancellation flags, and per-session UI state.
- M5 supplies one dynamic tool-schema and dispatch path for exec, MCP, and
  skills. MCP calls serialize safely per server; hooks run outside turn and
  dispatcher critical paths.
- Schema v4 and the protocol carry `parent_sid`, `kind`, `parent_block_id`, and
  the child round budget. Existing sessions migrate as roots; stale in-flight
  state becomes `err` after daemon restart.
- `task` creates one child through a typed dispatcher event/future, waits for
  its structured result, cascades parent cancellation, and limits children to
  a read-only tool profile with no recursive `task`. Children are ordinary
  attachable sessions grouped beneath their root in session listings.
- Council product behavior is specified in `REVIEW.md`, but `/council`,
  `/review`, concurrent child fan-out, and review blocks are not implemented.
- `parallel_safe` is metadata only today: the loop still runs every tool call
  serially. This no longer blocks proving the child ownership path; it is the
  next M6a widening step.
- The daemon listens only on its local Unix socket. Raw TCP/token auth and a
  PWA remain architectural doors, not partially shipped surfaces.

## Entry gate: finish proving M5

During M6, run one useful stdio MCP server and one notification hook during
ordinary work. Capture only actionable fixes: config
diagnostics, lifecycle/restart behavior, output rendering, and approval
classification. This is operational proof, not another feature phase.

Also close these bounded hardening debts when they intersect M6 work:

1. After the single-child path is stable, honor `parallel_safe` by executing
   consecutive safe calls concurrently, retaining provider-call result order
   and per-call cancellation.
2. Give built-in bash and extension subprocesses one cancellation/deadline
   primitive (TERM, grace, KILL) instead of a mixture of blocking helpers.
3. Make config/MCP startup errors name the table, server/tool, and bad field.
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
  turn threads never create session/store hierarchy state directly. The first
  slice deliberately waits on one child. Multiple calls and council seats are
  the next concurrency step.
- Lifecycle: parent interrupt cancels children it is awaiting; daemon restart
  reconstructs hierarchy and marks genuinely orphaned work honestly. Child
  failures are result data and do not crash the parent turn.
- UX: picker, short stable session handles, and `marlin ls` indentation are
  implemented. The status bar shows
  a parent's child count and actionable child activity, or the parent tag when
  a child is focused. Children remain ordinary attachable sessions; no
  permanent sidebar.

Verified checkpoint: one parent completes a child through the real daemon and
fake provider; the E2E asserts that task/bash/write/edit are absent from the
child schema, the structured result returns to the parent, and hierarchy plus
round budget are durable in SQLite.

Remaining exit: one parent launches at least three children concurrently,
survives client disconnect/reconnect, receives ordered results, and
cancellation/budgets hold under E2E fixtures.

## M6b — councils as specialized tasks

Build `REVIEW.md` on M6a instead of creating a second orchestration system:

1. Durable named council config with daemon-mediated atomic writes and
   `/council` list/create/edit/delete UI.
2. `/review [council] <focus>` asks the primary to formulate the shared brief,
   then shows a user-editable preview before fan-out.
3. Spawn read-only `review_child` sessions in parallel with immutable model,
   stance, deliberation, and budget settings recorded on the review run.
4. Parse structured findings, retain unstructured fallbacks, cluster claims,
   and have the primary verify evidence in the parent.
5. Add the single-rebuttal deliberation path only after independent mode is
   useful; `deep` is a budget/policy choice, not an unbounded group chat.

Exit: a named council can adversarially review a real repository with a custom
focus, all reviewer sessions are inspectable/resumable, and the parent renders
an evidence-backed triage table without granting reviewer write authority.

## M6c — remote door, scheduled on evidence

Do not let transport delay children/councils. If remote attach becomes a real
near-term workflow, decide the trust boundary first:

- Prefer SSH-carried NDJSON for machine-to-machine use already protected by
  SSH configuration.
- If TCP remains necessary, bind explicitly, authenticate before any session
  metadata, use constant-time token checks and strict permissions, rate-limit
  failures, and state where transport encryption comes from. A bearer token on
  plaintext public TCP is not an acceptable remote story.
- Only then evaluate a PWA as a sibling protocol client.

## Explicitly Later

COW snapshots, drift/undo, write leases, worktree isolation, `/land`, and
`/discard` remain together in `WORKSPACE.md`. M6 child sessions use today's
workspace/permission behavior and must not smuggle in a half-built workspace
phase.
