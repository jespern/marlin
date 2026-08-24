# marlin workspace & permissions

Status: design accepted, **feature-flagged off by default** (`[workspace]
enabled = false`). Nothing below changes runtime behavior until the flag
flips; M2's approval gate (mutating tools ask) remains the shipped behavior.
Implementation target: M3.5 (snapshots + leases), M6 (sandbox escalations,
worktree isolation). This doc exists so M3+ work doesn't build UX on
semantics we intend to replace.

## 1. Why not approval prompts

The prompt is not the security boundary — the user's attention is, and
attention depletes. After the 30th `git status` dialog the user is
pattern-matching "y" without reading, which means prompts are worthless at
exactly the moments they matter: a hostile command hides inside a wall of
benign ones. Allowlist promotion ("always allow `git *`") amortizes the
nagging without fixing the model, and prefix-matching bash is unwinnable
anyway (`git push --force`, `find -delete`, `curl | sh`).

The reframe: **approve capabilities, not commands.** Make the default
execution environment safe enough that asking is unnecessary; reserve the
prompt for capability escalations.

| Concern | Mechanism | Prompt? |
|---|---|---|
| Reads | free | never |
| Writes inside workspace | COW shadow snapshot = undo | never |
| Writes outside workspace | sandbox escalation | rare, capability-grant, session-scoped |
| Two marlin sessions, one dir | write lease → park | never (park, don't ask) |
| Deliberate parallel work on one repo | worktree isolation | explicit at session create |

A dialog protects worse than an undo. When escalations are rare (a few per
week) and specific ("write outside ~/Work/api for this session?"), people
read them again. Denial is not a wall: a sandbox violation returns as a tool
error, the model sees it and re-plans.

The M2 approval machinery (gate, approval_request/approve wire messages,
awaiting_approval parking) is not discarded — it becomes the escalation
path. We built the right mechanism; this changes what flows through it.

## 2. The workspace layer

Every session gets a **workspace**: the daemon's answer to "where do writes
go and who guarantees undo." In shared mode its root is exactly the
canonicalized directory the session was launched in: never an implicitly
discovered parent Git root, and no explicit override in M3.5. One concept,
three mechanisms.

### 2.1 Copy-on-write shadow snapshots (always on, once enabled)

The daemon keeps a private snapshot set per canonical workspace. A snapshot is
a path/metadata manifest plus copy-on-write clones of regular files:
`clonefile` on APFS and `FICLONE` on supporting Linux filesystems. Snapshot and
working file initially share physical blocks; later writes allocate only the
changed blocks. The daemon never touches the user's `.git`, index, or stashes.

The clone store normally lives under
`~/.local/state/marlin/shadows/<dirhash>`. File cloning requires the store and
workspace to be on the same supporting filesystem, so capability is probed per
workspace. If cloning is unavailable or the state directory is on another
filesystem, use a real/content-addressed copy and surface the slower mode;
never silently omit files or weaken the undo guarantee. Ordinary hard links
are not a fallback: in-place writes would corrupt both names.

- Snapshot at turn start, lazily on the first mutating tool call (not on
  read-only turns; walking a high-inode tree still isn't free).
- Works identically whether the user's dir is a git repo or not — marlin
  owns the snapshot engine, so "is this a repo?" prompts don't exist. The
  user's repo stops being a dependency of marlin's guarantees.
- Clone every regular file under the workspace, including ignored files.
  The manifest also records directories, permissions, symlink targets, and
  deletions. Exclude only `.git`, Marlin's own state, and special files such
  as sockets and devices.
- Enables real undo: `/undo turn`, "restore file as of turn N" — all reads
  from the shadow, all recorded as session blocks.
- Costs: one walk and clone/copy operation per file, changed blocks after the
  snapshot, and retained history. Mitigate with lazy capture and GC past a
  horizon; add explicit cache exclusions only if rollout measurements justify
  weakening complete regular-file coverage.

**UX rule: `/undo` must show its diff before applying, never after.** In
shared mode a marlin snapshot may include external edits (§3), so a blind
restore could roll back work the user did in another tool. This is the one
place the shared-world and marlin-world genuinely collide; it is a UX rule,
not an architecture problem.

### 2.2 Write leases (marlin-internal concurrency)

All marlin writes flow through daemon tools, so the daemon enforces: a turn
takes a **write lease** on the workspace root before its first mutating
call; read-only turns take none. A second mutating turn on a leased root
**parks** (state `waiting_workspace`, visible in the on-demand session picker
and actionable status summary, steer-able) — exactly the awaiting_approval
parking with a different reason code. Most collisions are seconds long;
queueing is the right default and asks nothing.

Lease events land in the block log, so "why did this turn wait 40s" is
answerable. The **user never holds a lease** — leases order agents; user
edits are handled by drift detection (§3).

### 2.3 Worktree isolation (opt-in, later)

For deliberate long-running parallelism on one repo:
`session_create{workspace: "isolated"}` → daemon creates a `git worktree` +
session branch under `~/.local/state/marlin/worktrees/`. Distinct roots, so
the lease question vanishes. Requires a real user repo (worktrees need one);
for non-git dirs isolation is refused (or degrades to copy — decide at
implementation).

## 3. External writers: optimistic concurrency, not locking

Claude/codex in another terminal, the user's editor, a `make generate` —
none of them ask marlind for a lease, and no filesystem mechanism short of
FUSE could force them to. So the model is honest:

- **Leases** serialize the writers we control.
- **Snapshots** make the writers we don't control survivable — the pre-turn
  snapshot captures *their* state before we touch it; even a blind clobber
  is recoverable, which is strictly better than what claude/codex do to each
  other today (mutual silent destruction).
- **Drift detection** makes them visible: at mutation time the daemon diffs
  the tree against the last turn-boundary snapshot; divergence injects a
  system note into context — `[workspace: 3 files changed externally since
  last turn: src/api.ts, ...]` — and the agent re-reads before editing, the
  same discipline you'd demand of a human returning from lunch.
- **Per-file CAS already exists**: `edit` requires an exact old_string
  match; if an external tool rewrote the region, the match fails and the
  model re-reads and reconciles. `write_file` is the blunt instrument;
  a warn-on-diverged-write softening is possible later.

marlin detects external writes, absorbs them, and never destroys them
irrecoverably — but does not fantasize about preventing them. Locking is a
lie other tools tell silently by ignoring the problem.

## 4. Convergence semantics

**Shared mode (default): convergence is a non-question.** There is no second
copy — tools write the working copy directly; leases make turns interleave
at turn granularity instead of mid-edit. What you see at any idle moment is
a consistent state some turn produced. No new semantics to learn; this is
why shared stays the default.

**Isolated mode: explicit landing.** The auto-answers all fail on
inspection: *after every turn* defeats the isolation you opted into; *on
session end* doesn't exist — marlin sessions are durable daemon state with
no end-of-life moment; *on idle* steals the moment you'd use to review.
So:

- `/land` — merge back to the base branch, diff shown for review first.
- `/discard` — drop the branch; experiments become genuinely free.
- Status bar shows divergence (`⑂ +4 commits, base moved`); when the base
  hasn't moved and landing is a clean fast-forward, the nudge says so —
  one keypress on a green light.
- Conflicted landings are an M5+ story; with the block log a conflict can be
  handed back to the agent as a task ("rebase your branch; here's what
  changed under you").

Symmetry worth keeping in mind: **isolated mode is the external-writer
problem made tractable.** An external CLI is an isolated writer with no
merge protocol; a marlin worktree session is an isolated writer with one.
Same phenomenon — divergence — handled detect-and-absorb when we don't
control the writer, branch-and-land when we do.

## 5. Residual risks, stated honestly

- **Network exfiltration** is the hole sandboxing does not close: an agent
  can read `.env` inside the workspace and POST it somewhere. Mitigations
  ranked by cost: secrets hygiene (user), deny-read patterns for
  `.env`/`*.pem`/key material even inside the workspace (ship this),
  network allowlists (heavy, breaks package managers — not v1). Prompt-based
  harnesses have the same hole with more theater.
- **seatbelt is deprecated** on macOS; Chrome still rides it, zag proves the
  shape. Landlock+seccomp on Linux. Sandbox implementation is two focused
  files behind the existing bash tool.
- **COW snapshots still scale with inode count.** Large files are cheap on the
  clone fast path, but a tree containing hundreds of thousands of tiny files
  still requires a walk and clone syscall per file. Unsupported or
  cross-filesystem fallback copies may be substantially slower; expose the
  active mode and measure it during rollout.

## 6. Config & rollout

```toml
[workspace]
enabled = false        # master switch; everything in this doc is behind it
# snapshots = true     # (once enabled) shadow snapshots + /undo + drift notes
# leases = true        # (once enabled) write leases + waiting_workspace
# sandbox = "off"      # off | escalate (M4/M5): bash sandbox + capability prompts
```

Rollout order (inside-out by usefulness):
1. **M3.5 — snapshots + leases.** Daemon-internal, no TUI beyond a status
   glyph and the drift note. Snapshots before sandboxing: the sandbox denies
   damage *outside* the workspace, snapshots undo damage *inside* it.
2. **M6 — workspace phase 2: sandbox escalations** through the existing
   approval gate; per-tool ask prompts are then retired in favor of
   capability escalations (flag-guarded flip). Worktree isolation lands
   here too, once the multiplexer (M4) makes parallel sessions ergonomic
   enough to want it.

Until then: `[workspace] enabled = false` and M2 semantics hold.
