# Panes, per-pane status, and scriptable environments

Status: **design note, not scheduled (2026-09-04).** Written after a
feasibility review so the findings survive. Nothing here is committed work;
the gate in `docs/M4_PLAN.md` §1 (splits only after dogfooding proves
side-by-side sessions beat fast tab switching) still applies to the layout
half. The Marlinfile and per-pane status bar do not need that gate.

## The ask

1. A per-project file (working name: Marlinfile) that declares sessions and a
   layout, so `marlin` in a repo brings up a reproducible environment.
2. tmux-style splits in any direction, for Marlin session views only. No PTY
   or terminal emulation inside Marlin, ever.
3. Each pane carries its own status bar: state, model, context, cwd.
4. Panes resize by mouse drag and vim-style keys, and any pane can be zoomed
   to full size and back.

## What the code says today

These are the facts that determine cost. Verify them against
`src/client/tui.zig` before starting; the file churns.

- **App is the pane.** Roughly forty per-session fields (editor, blocks,
  deltas, plan, state, model, effort, cwd, token counters, scroll, selection,
  pending approval, turn/phase timers, seq cursors) live directly on `App`.
  They are touched as `app.blocks`, `app.editor`, `app.scroll_up` and so on in
  about 500 places across a 12,600-line file.
- **The event handler assumes one live session.** Block, delta, status, and
  result handlers early-return when the message's `sid` differs from
  `app.sid`. Only session-list, approval, and meta events are processed for
  other sessions (feeding the tab bar and `background_approvals`).
- **`SavedSessionView` is a cache, not a pane abstraction.** It holds the same
  field list for dormant sessions, moves them in and out of `App` wholesale on
  switch, and evicts beyond eight entries (MRU). It is the *field list* that
  is reusable; the mechanism is the opposite of what two hot panes need.
- **The daemon already supports multiple subscriptions per client.** Each
  `Client` keeps a `subs` list of session ids and fans blocks out to every
  subscribed client. Two panes are two `sub` messages without the intervening
  `unsub`. No protocol or daemon change is needed for panes.
- **Transcript layout is width-parameterised.** `layout.layoutLines` takes a
  width, so laying out a narrow pane is not new work. But the three layout
  caches (`layout_cache`, `tail_layout_cache`, `stream_layout_cache`) are
  singletons on `App`, and `draw()` computes composer height, plan surface,
  tab bar rows, and scroll anchoring against the whole window.
- **Mouse plumbing exists.** vaxis mouse mode is on; tab bar hit-testing
  (`tab_hits`) and drag selection (`sel_anchor`/`sel_dragging`) are the
  patterns a divider-drag would copy.
- **`session_create` already carries everything a Marlinfile needs**: cwd,
  model, effort, title, approvals, and a `request_id` for correlating the
  reply. Config parsing is TOML via `config_toml.zig`.

## Dependency order

The four asks do not ship in the order listed. Each slice below stands alone
and leaves the codebase better even if the next never happens.

### 1. Extract `SessionView` (prerequisite for everything)

**Status: merged to main (2026-09-04) as "Extract SessionView from App" and
"Fold SavedSessionView into SessionView".** The field move, the cache move,
and the `SavedSessionView` fold-in below all landed; unit and e2e were green
at merge. Still open from this slice: the event handler continues to compare
against `app.view.sid` and drop non-focused traffic rather than looking a
view up by sid; and the two near-identical switch sequences (in
`switchSession` and the search-result jump) could share one helper.

Move the per-session fields off `App` into one struct. `App` holds exactly one
`SessionView` plus the global chrome (tab bar, notices, modals, search,
setup prompts, animation). `SavedSessionView` becomes redundant: a dormant
view and a live view are the same type, and the MRU cache stores
`SessionView` directly.

Rules: zero behaviour change, protected by the existing layout and TUI tests.
The three layout caches move into the view. The event handler dispatches on
`sid` to a view lookup instead of comparing against `app.sid`, even while
there is only one view.

This is a multi-day mechanical refactor across a large fraction of the file.
**Land any outstanding `tui.zig` work first**; rebasing across it will hurt.

### 2. Per-pane status bar (cheap once views exist)

The status bar already renders state, model, context, and cwd from what are
about to become view fields. It becomes a one-row footer inside each pane.
New work is only truncation priority for narrow panes (state and context
first, cwd last) and deciding what the global bar keeps (background
actionable counts, notices, mode).

### 3. Layout tree

A binary tree: internal nodes are `{ direction: h|v, ratio: f32 }`, leaves
are `SessionView`s (the same session may appear twice). Two panes and
arbitrary tmux nesting are the same code; a two-pane fixed split is just the
first tree shape exposed to the user. Each leaf gets its own rectangle, and
`draw()` becomes "walk the tree, draw each leaf into its window".

Per-leaf: transcript, plan surface, composer, status row. The focused leaf
owns the keyboard; unfocused leaves draw their composer draft dimmed and stay
read-only but keep their own scroll position and selection. Global modals
(command menu, `/sessions`, top view, search, setup prompts, shortcut help)
stay App-level and render over the whole window.

Subscriptions: every leaf's session is subscribed while it is in the tree.
Removing the last leaf for a session sends `unsub` and moves the view into
the MRU cache, exactly like today's tab switch.

Approvals: an approval arriving for an unfocused pane renders in that pane
rather than parking in `background_approvals`. Answering it still requires
focus, so the focus keybinding must be cheap.

Persistence: the tree serialises to the same shape the Marlinfile uses, so
`/reboot --build` restores layout best-effort and `marlin layout save` (or
similar) writes a Marlinfile from the live TUI.

### 4. Focus, resize, zoom

- Focus: a prefix (or normal-mode `Ctrl+W`-style chord) plus `h/j/k/l`, and
  mouse click in a pane. Wheel events route to the pane under the cursor,
  not the focused one.
- Resize: prefix plus `H/J/K/L` adjusts the enclosing split's ratio by a
  fixed step. Mouse drag on a divider cell adjusts it continuously. The only
  real hazard is disambiguating divider drag from selection drag: hit-test
  the divider before the transcript.
- Zoom: a flag on App naming one leaf. When set, `draw()` renders only that
  leaf at full size and ignores the tree; the tree is untouched, so unzoom is
  clearing the flag. Zoom should follow focus changes or drop automatically,
  pick one and document it.
- Minimum pane size: below roughly 20 columns or 4 rows a leaf draws a
  placeholder label instead of a transcript (mirrors the existing `draw()`
  early return).

### 5. Marlinfile

Two halves with different dependencies.

**Sessions half (no pane work needed).** A per-project TOML file naming
sessions with cwd (relative to the file), model, effort, title, approvals,
and an optional first prompt. `marlin up` (or plain `marlin` detecting the
file) creates missing sessions and attaches.

The design question that matters is **idempotency**. Sessions are durable, so
running the file twice must attach to the existing sessions, not create
duplicates. Title matching is too fragile (titles are auto-generated and
user-renamable). This needs a daemon-side label, set at creation, that
survives restarts and is queryable in `session_list`. That is the one
protocol addition in this whole plan. The first prompt runs only on
creation, never on reattach.

**Layout half (after §3).** A `[layout]` section describing the tree, with
leaves referencing session names from the sessions half. Same serialisation
`marlin layout save` writes. Unknown or archived session names fall back to
a single-pane layout with a notice rather than failing.

Open questions: file name and location (`Marlinfile`, `.marlin.toml`,
`.marlin/env.toml`); whether workspace-root discovery walks up to a Git root
(M4_PLAN's later workspace track says session identity should *not*); how a
`--remote` client resolves relative cwds against the daemon host.

## Rough cost

| Slice | Effort |
|---|---|
| §1 `SessionView` extraction, zero behaviour change | 3 to 5 days |
| §2 per-pane status bar | 1 day |
| §3 layout tree, two-pane first, then arbitrary | 1 to 2 weeks |
| §4 focus, resize, zoom | 3 to 5 days |
| §5a Marlinfile, sessions only, plus daemon label | 2 to 3 days |
| §5b Marlinfile layout section | 1 to 2 days |

About five to six weeks of focused work end to end. §1, §2, and §5a are worth
doing regardless of whether splits ever land.

## Explicitly out of scope

- **An embedded interactive shell pane.** That is a PTY plus terminal
  emulator, a different product from anything above. Shell escapes stay as
  they are: `! <command>` and bare `!` tear the TUI down, run the child with
  inherited stdio in the focused session cwd, and reattach on exit. This
  already gives SSH password prompts, host-key confirmation, `sudo`, and
  full-screen programs a real terminal. Direct `--remote` refuses shell
  escapes on purpose (see `docs/ARCHITECTURE.md` §8). If interactive input in
  `!` ever appears broken, reproduce the exact command and read
  `runShellRequest` in `src/cli.zig` before designing anything new.
- **Arbitrary tiling before two panes prove useful** (M4_PLAN §1).
- **Pane-per-agent auto-layout** when a session spawns subagents. Tempting,
  but decide it after manual splits exist.
