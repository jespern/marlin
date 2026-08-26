# Software review — 2026-08-26

Point-in-time review of Marlin as it stood on this date: tree on `main` (20 commits ahead of origin), plus the uncommitted Claude Code approval bridge and web PWA work. Treat that uncommitted pile as part of the product — it is clearly where the project was going.

This is not the councils design (`REVIEW.md`). It is a top-down product/architecture review.

---

## Verdict

Marlin is no longer “a very good personal harness with a 9k TUI.” It is a **session multiplexer that can host two different agent loops**: its own (OpenRouter / Anthropic Messages / local), and Anthropic’s official `claude` binary.

That second loop is the most important thing in the tree. It is also the thing most likely to eat the first.

The last two days of commits — `task_batch`, image paste, MCP lifecycle, durable plans, `claudecode/`, web search, the uncommitted permission bridge — are the right *kind* of work. They are why a daily Claude Code user would stay. They are also how the “tiny Zig core, churn at process boundaries” story starts to strain: `loop.zig` is 2112 lines because it now contains a second agent runtime.

---

## What got better, specifically

**Concurrent children are real.** `task_batch` is 2–8 durable read-only children, join-in-order, spawn-fail falls back to serial, e2e scenario 17 plus a unit test that checks the peak. That was the M6a remaining exit. Councils can be a specialization of this; they should not be a new system.

**Image attachments are the designed feature, not a hack.** Clipboard/path capture in the client, protocol upload, content-addressed blobs, vision mapping on both OpenAI-compat and Anthropic. The Claude Code path *honestly* says the images are stored in Marlin and unavailable to the delegated binary. That honesty is rare and correct.

**MCP is a product surface, not a checkbox.** Isolated discovery (one dead server no longer kills the daemon), `/mcp` add/remove/restart/reload, per-tool policy, e2e 18–21. Daily-use proof is still the remaining M5 exit, but the mechanics are no longer theater.

**Plans are the Architecture §8 strip, actually built.** `plan_update`, one in_progress, pinned above the composer, durable across reboot/compaction, child activity can attach to a step. Small, constrained, tested. This is how you add UX without a dashboard.

**Claude Code delegation is the pragmatic billing move**, and the file header is the most honest comment in the repo: marlin’s gate, Seatbelt, network screening, and redaction do **not** reach inside the subprocess. Context/compaction is Claude Code’s. Marlin is multiplexer + transcript. That is a real product, as long as you do not pretend it is the same loop.

The uncommitted `cc_approve` bridge is the thing that makes `claudecode/` *daily-drivable* instead of “headless auto-deny.” Routing CC permission prompts onto the same approval bar, auto-allowing workspace edits the way native auto-inside does, failing closed to *ask* on heuristics — that is the right shape. Dropping a parked prompt when the bridge client dies is the kind of teardown discipline this codebase is good at.

---

## The actual problem now

A lot of product shipped while the **safety contracts** and a couple of **load-bearing shutdown/ownership** bugs stayed where they were. The Claude Code path makes those contracts *more* important, not less, because the daily driver may now be a subprocess Marlin cannot sandbox.

### 1. The unpaid safety invoices are still unpaid

- **No capture-time redaction.** `loop.zig` still hashes and appends tool output as-is. Architecture §7 still describes `[REDACTED:<name>]`. Combined with an append-only store, one workspace `.env` read is immortal.
- **`read_file` / `grep` still do not consult `isProtectedPath`.** The classifier and tests exist. The tools ignore them. `read_file ~/.ssh/id_ed25519` still works on the *native* loop.
- **`marlin run` / `/permissions full` is still yolo before sandbox.** `policyFor(.auto)` returns `.run` for everything.
- **`11_task_child.json` still asserts `"edit_file"`.** The tool is `"edit"`. That exclusion cannot fail.

The uncommitted CC bridge **auto-allows `Read` of `/etc/hosts`** — the unit test says so on purpose, matching native read-only policy. So the delegated path has the same hole, plus `WebFetch`/`WebSearch`/`Task` auto-allow. Edits and bash are containment-checked; reads are not a security boundary. Fine if documented. Not fine if Architecture still says protected reads are refused.

Linux still has no kernel sandbox. Native Seatbelt still wraps **bash only**. Direct file tools are still the hole.

If `claudecode/` becomes how you actually work, Marlin’s Seatbelt story is a property of the *other* loop. Say that in the README, or pay the invoices on the native loop so switching models does not silently change the threat model.

### 2. `/quit` is still not the SIGTERM path

`Event.shutdown` closes the queue, then flips `running`. Protocol `.shutdown` (what `/quit` sends) still:

```zig
.shutdown => {
    self.sendTo(client, .{ .ok = .{} });
    self.running = false;
    self.nudgeAcceptLoop();
},
```

(`src/daemon/daemon.zig`, around the protocol `.shutdown` arm.)

No `events.close`. A turn that `finishTurn`s after `/quit` can leak payloads into an open MPSC whose `deinit` does not free interiors. Same family as the zombie-daemon-after-`!rb` bugs. `/quit` is the path you press.

### 3. `claudecode/` is a second product inside the first

This is not a nit. `runTurn` now branches at the top: if dialect is `claude_code`, skip context assembly, HTTP, marlin tools, L0/L1/L2. Persist CC’s event stream as blocks. 60-minute wall clock. Steers become follow-up `-p` invocations. Images get a footnote.

What you gain: subscription Fable, the model you actually want, without violating Anthropic’s OAuth wall.

What you pay:

- Two permission systems, two tool vocabularies, two context engines, two compaction stories.
- The TUI has to render a transcript it did not produce (semantic tool rendering, relative paths — those commits exist *because* of this).
- Compaction, `task`/`task_batch`, MCP tools, Seatbelt, marlin fetch/blocklist — none of that is the agent when the tab is `claudecode/…`.
- `loop.zig` 1363 → 2112. `daemon.zig` 2743 → 3304, plus ~150 uncommitted for the bridge.

That is a coherent multiplexer product (“I have marlin sessions; some of them are Claude Code”). It is **not** the README’s “third shape” unless you rewrite the pitch. Right now the pitch still says kitchen-sink-vs-monolith and does not mention you shell out to `claude -p`.

**Keep it, own it, bound it.** Do not let native-loop features (councils, more markdown, more vim) and CC-loop features (bridge, PWA approve-from-phone) silently compete for the same weeks. Pick which loop you daily-drive and make the other honest about being second.

The bridge should ship. The heuristic bash scanner (`commandStaysInWorkspace`) is fine *because* failure is ask, not allow — do not be tempted to make it deny. Do not pretend it parses shell.

### 4. The web UI is being productized while still a landmine

Uncommitted as of this review: PWA manifest, apple-mobile-web-app, icons, session rename, a **persistent sidebar**.

The TUI’s whole M4 decision was “no persistent sidebar.” The web client now has one. Two clients, two philosophies. That can be fine — phone is not a terminal — but it is a product fork, not “just another protocol client.”

Still: bind 127.0.0.1, no auth, no Origin check, `POST /send` forwards any `ClientMsg` including shutdown. Adding “Add to Home Screen” chrome is how an opt-in debug surface becomes something you actually leave running. Default-off still saves a fresh install. Anyone who enables it for phone-on-the-LAN via a tunnel has a CSRF gun with a nice icon.

M6_PLAN said decide PWA after a remote trust boundary. This is PWA chrome *without* that decision. Either put a token on it (even a local one in the URL, checked on every POST) or keep the POC ugly on purpose.

### 5. Ownership leftovers, still there

- `session.zig` is still a 34-line ghost (`max_rounds = 32`, “turns only talk via the queue”). Both false. Delete it.
- `clients_mutex` is still a file-level `var`.
- `marlin gc` still opens SQLite from `client/headless.zig`.
- `permissions_full` is still an `App` bool, not per session. Switch A (full) → B (default) and the bar still lies.
- Child `!` still paints on the parent tab; click still focuses the root; `y`/`n` still require the parked session focused. The CC bridge will park on the *delegated* session, which is at least the tab you are looking at — better than child-task approvals. Native child approvals are still a trap.

Config-driven extra providers still do not exist. Registry is `openrouter` / `anthropic` / `claudecode` / `local`. The no-SPOF paragraph is still a doc. `claudecode/` *is* a second billing path, which is the part that actually mattered.

---

## What to do next

**Ship, don’t expand:**

1. Finish and commit the CC permission bridge. It is the difference between “I can select Fable” and “I can work.” Keep fail-closed-to-ask. Add an e2e or at least a daemon-level test that a dying bridge client unparks the session.
2. Make protocol `.shutdown` take the `Event.shutdown` path (`events.close` then `running = false`). Same commit, ten lines.
3. Fix `"edit_file"` → `"edit"` in scenario 11. Same afternoon as (2).
4. **Pay one safety invoice on the native loop:** protected-path refusals on `read_file`/`grep` as tool-result data, and exact-value redaction of secrets the daemon actually loaded, before `appendBlock`. Then the Architecture paragraph is true. The CC loop will still auto-allow `Read`; document that as “CC’s policy, not ours.”

**Then stop adding surfaces for a bit and dogfood:**

5. One real MCP in daily use (M5’s actual remaining exit). Restart/reload were built — use them.
6. Daily-drive `claudecode/` with the bridge *and* a native OpenRouter tab in the same TUI. The bugs you want are: approval UX, transcript fidelity, steer-as-follow-up, image footnote, reboot with a live `claude -p`.
7. `task_batch` from the native loop on a real repo. Councils wait until that is boring.

**Do not, until the above is boring:**

- `/review` / councils. The primitive exists. The product does not need a fourth orchestration layer this week.
- More vim, more markdown, more `tui.zig` extraction.
- Landlock. Say “sandbox is macOS” or schedule it; don’t half-do it.
- PWA-as-product without auth. Manifest+icons without a token is how the POC escapes.
- Config-driven providers, unless OpenRouter actually dies on you. `claudecode/` + `anthropic/` + `local/` is three paths. Enough.
- Splits. `Transcript` made them cheap. Dogfood has not demanded them.

---

## Positioning

Against Claude Code the *app*: Marlin now can **be** Claude Code, plus a real multiplexer, durable log, `!rb`, tabs, and a native loop for everything that is not Fable. That is a sharp product if you say it.

Against Claude Code the *habit*: you still lose on Linux sandbox, path-scoped native permissions, and “the agent and the permissions are one system.” Wrapping `claude -p` inherits CC’s permissions for that tab and Marlin’s holes for the other tabs.

The failure mode to worry about is not code quality. It is **two daily drivers in one binary**, each generating a week of work, while `/quit` still leaks, `read_file` still opens `.ssh`, and `session.zig` still lies to the next person who reads `MILESTONES.md`.

This is past “make the architecture real.” This is “choose which product this is.” `claudecode/` + multiplexer + native loop as fallback is a good product. Kitchen-sink-but-Zig is not, and the file sizes will get there if every designed door (councils, PWA, worktrees, Mode B) opens because the last door felt good.
