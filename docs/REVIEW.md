# Multi-model review ("councils")

Status: design; protocol and UX settled. Targets post-M4 (needs daemon, TUI,
detached child sessions).
Depends on the L3 subagent machinery (ARCHITECTURE.md §context, `task` tool) —
a review is a specialization of it, not new architecture.

## 0. The workflow this replaces

Manual loop today: finish heavy feature/crypto work → ask the main model for a
"review me" prompt with specific focus areas → copy/paste it into 3-4 other
LLMs (5.6-sol, fable 5, grok 4.6, glm-5.3) → paste responses back → main model
verifies each claimed defect against the code and produces a triage table →
human picks what to fix.

That loop is already the right *protocol* (see §1); marlin automates the
transport and makes the phases structural.

## 1. Principles (from surveying Claude Code subagents, Zen/PAL MCP,
Amp's oracle, aider, Kinney's codex-advisor — plus what our manual flow
already got right)

1. **Different model families, deliberately.** Correlated blind spots: a model
   reviewing its own family's output samples from the distribution that made
   the error. Council = 2-4 models from different lineages, reasoning effort
   pinned high per council (never let routing pick cheap for the adversary).
2. **Independent parallel reviews beat a group chat.** Shared threads cause
   anchoring and premature convergence; the diversity you pay N× for
   evaporates. The highest-signal artifact is *agreement between reviewers
   that never talked*. No free-form multi-model chat room — debate is a
   bounded, opt-in, pairwise second phase.
3. **The human owns the suspicion.** The primary agent drafts the review
   brief, but it is shown for edit/approval before fan-out. Injecting "I'm
   worried about nonce reuse under retry" at prompt-construction time is the
   part of the manual workflow worth preserving; most implementations drop it.
4. **Reviewers are read-only by construction.** Tool-registry-level
   enforcement for reviewer sessions (read/grep/glob only, no write/edit/bash
   by default), not a polite system-prompt request.
5. **Verify, then triage — never just synthesize.** The primary must
   re-derive each finding against the actual code before it reaches the
   human. Aggregating opinions ≠ adjudicating claims. This kills the two
   dominant failure modes: hallucinated defects and conflated findings.
6. **Advisory, never blocking.** Review output is evidence attached to the
   session; the human decides. No reviewer verdict gates anything.
7. **Raw critiques always one keypress away.** The primary summarizes
   critiques of *its own work* and will soften them; `refuted` is the
   self-serving verdict. Synthesis inline, source always inspectable.

## 2. Pipeline

```
brief → approve/edit → fan-out (N detached reviewer sessions, parallel)
      → collect (structured findings) → cluster (dedupe into claims)
      → verify (primary re-derives each claim w/ tools)
      → triage table → human picks → optional bounded rebuttal per claim
```

### 2.1 Brief

Built by the primary from its live context and the user's natural-language
review request. The primary interprets requests such as "review the system
from the top; adversarial, focus on crypto and UX" into a proposed scope,
stance, and evidence-gathering plan. Contents:

- **Target** (see §3): inlined diff, or file manifest + entry points.
- **Decisions-and-constraints digest**: "we deliberately chose X because Y".
  Kills the false-positive class where reviewers flag intentional choices.
  Same summary contract as L2 compaction — reuse that machinery.
- **Review mission**: the primary's concise formulation of what the council
  should attempt to prove or disprove, including the proposed stance.
- **Focus lines**: the human's original request and suspicions, verbatim. The
  primary may organize or augment these, but never silently rewrite them away.
- **Finding contract** (§2.3) the reviewer must return.

Shown in the TUI before fan-out; the user can edit the complete brief, change
the inferred scope/stance/deliberation, approve it as-is, or cancel. Inference
is an ergonomic shortcut, never authority to spend N model calls against the
wrong target.

Every reviewer receives the same core brief. Provider-specific wire formatting
may differ, but covertly tailoring the mission per model would make independent
agreement less meaningful. Explicit per-model roles are a possible later
feature and must be visible in the approved brief.

### 2.2 Fan-out

One detached child session per council model. Ordinary sessions in the store
(parent pointer set, grouped under the parent in `/sessions`, individually
attachable/resumable — you can reopen grok's review afterwards and interrogate
it: "walk me through the exploit"). Runs on the existing
one-thread-per-turn model; status glyphs in the parent:
`review #12: sol ✓ · fable ✓ · grok … · glm ✓`. Primary/user keep working.

Per-reviewer budget: `max_turns` + token cap (whole-repo scope especially —
one curious model at high effort can read the entire tree).

### 2.3 Finding contract

Reviewers return structured output, not prose:

```
verdict: SHIP | REVISE | RETHINK
findings[]:
  severity: critical | high | medium | low
  location: path:line (or subsystem)
  claim:    one-paragraph mechanism ("nonce reuse when retry fires after...")
  exploit:  optional sketch (crypto/security findings)
strengths[]: what to preserve   # cheap, and dampens reviewer negativity bias
```

Parse leniently (jsonx layer); on contract violation, one re-ask, then accept
prose and mark the reviewer's findings `unstructured` (they skip clustering,
appear as an appendix).

### 2.4 Cluster → verify → triage

- **Cluster**: dedupe findings across reviewers into claims — same root cause
  = one row with attribution ("sol + grok, independently"). Agreement count is
  a signal *on the row*, not a verdict.
- **Verify**: for each claim the primary attempts confirmation with tools:
  re-read the path, trace callers, walk the sketched exploit. Fixed
  vocabulary:
  - `confirmed` — reproduced/verified, with evidence
  - `plausible` — couldn't confirm or refute within budget
  - `conflated` — real issue, wrong mechanism (note the real one)
  - `refuted` — MUST carry concrete evidence (file:line, trace); this is the
    conflict-of-interest verdict, spot-check these rows
  - `intentional` — matches a digest decision; proposed action = document it
- **Triage table**, rendered in the parent session, sorted confirmed-first
  then by agreement count:

```
#  claim                      sev   found by      status      read / action
1  nonce reuse under retry    crit  sol,grok,glm  confirmed   real — fix
2  timing leak in memcmp      high  fable         intentional const-time via X; add comment
3  ...
```

- **Human picks**: rows are addressable. `fix 1,3`, `dismiss 2`,
  `debate 5 grok`. Accepted rows become plan/todo items in the parent session
  — review output flows into fix work without re-prompting.

### 2.5 Deliberation (opt-in)

Two named modes; do not expose an open-ended debate-round counter in the UX:

- `independent` — reviewers return one critique each; the primary still
  clusters and verifies every claim, but does not argue with reviewers.
- `rebuttal` — the primary must respond to every finding (accept or rebut).
  For a contested claim it sends the evidence-backed rebuttal to the reviewer
  that raised it; the reviewer gets one counter, then the exchange ends.

The forcing function that matters is complete coverage — no cherry-picking
easy findings. No N-way debate or arbitrary depth in v1; if contested claims
later need further adjudication, add pairwise debate on one claim as a
separate explicit verb.

## 3. Scope

Three target selectors; they differ in brief construction and reviewer needs:

| scope        | brief payload                          | reviewer tools |
|--------------|----------------------------------------|----------------|
| working diff | diff inlined + digest                  | optional       |
| subsystem    | file manifest + entry points, no inline| required       |
| whole repo   | repo map + focus lines                 | required + hard budget |

Consequences:

- Diff scope works with stateless reviewers (the manual paste flow,
  automated). Subsystem/repo scope only beats the manual flow *because*
  reviewers can grep/read — so read-only reviewer tooling is in the first cut,
  not an enhancement.
- Digest source: diff scope pulls it from the primary's live context (cheap,
  accurate). Repo scope has no session that remembers the decisions — pull
  from compaction summaries in the store and/or a durable DECISIONS.md, else
  repo reviews drown in "why isn't this configurable"-grade findings.

## 4. Config

Councils are named config, not per-invocation ceremony. Keep the surface
minimal until ~20 real reviews have been run:

```toml
[council.crypto]
models       = ["anthropic/claude-5.6-sonnet", "anthropic/claude-fable-5",
                "x-ai/grok-4.6", "z-ai/glm-5.3"]
effort       = "high"          # reasoning effort pinned per reviewer
stance       = "balanced"      # balanced | adversarial; invocation may override
deliberation = "independent"   # independent | rebuttal
tools        = "read-only"     # none | read-only
max_turns    = 12              # exploration/tool budget per reviewer
max_tokens   = 40000           # total token budget per reviewer
# Different stance per model (for/against/neutral, Zen-style) remains deferred.
```

These are intentionally separate controls:

| control | meaning |
|---------|---------|
| `effort` | how hard each model reasons per provider call |
| `stance` | how critically the initial review brief frames the target |
| `deliberation` | whether the primary and reviewer exchange one rebuttal |
| `max_turns` / `max_tokens` | how much exploration each reviewer may perform |

Council defaults can be overridden for one review, but an override is shown in
the brief preview and never mutates the named council.

Everything on OpenRouter already — reviewers are just sessions pinned to a
different model. No CLI-wrapping (the duct tape Claude Code users need to
escape single-vendor lock); this is a structural advantage of owning the
harness.

### Per-model precision scoreboard

Derivable for free from the store: findings raised / confirmed / refuted per
model per council. After enough reviews it answers "does glm earn its seat?"
Verification cost scales with claim count, not model count — a noisy 4th
model is nearly free at fan-out but doubles triage. No harness surfaces this
today; it falls out of sessions-as-data.

## 5. UX surface

Council definition and review invocation are separate surfaces: `/council`
mutates durable named configuration; `/review` creates one immutable review
run from a council plus an approved brief. Council names do not become global
slash verbs (`/crypto`) — that pollutes autocomplete and makes configuration
indistinguishable from actions.

### 5.1 Council manager

```
/council                 # list/pick councils
/council new             # open creation form
/council crypto          # inspect/edit this council
/council delete crypto   # confirm, then remove it
```

The creation/edit form contains:

```
name          crypto
models        [✓ sol] [✓ fable] [✓ grok] [✓ glm]
effort        high
stance        balanced | adversarial
deliberation  independent | rebuttal
tools         read-only
budget        12 turns / 40k tokens per reviewer
```

Use the existing model catalog as a multi-select picker. The daemon validates
model ids and writes council configuration atomically; the TUI must not edit
TOML directly. Config-file edits and `/council` edits share one source of
truth and become visible after daemon reload/acknowledgement.

### 5.2 Review invocation

```
/review
/review crypto review the system from the top; adversarial, focus on crypto and UX
```

`/review` with no arguments opens a small form:

```
council       crypto
scope         whole repo       # proposed by primary; editable
stance        adversarial      # council default or request override
deliberation  independent      # council default; editable for this run
focus         review the system from the top; focus on crypto and UX
```

The fast path treats the first argument as a council name only when it exactly
matches a configured council; otherwise the whole argument string pre-fills
`focus` and the picker requests a council. Submitting either path asks the
primary to construct the brief from §2.1, then opens the full brief preview.
Only explicit approval starts fan-out.

The primary may infer scope from the request and live context — e.g. "from the
top" suggests `whole repo`, while "review these changes" suggests
`working diff` — but scope always remains a visible structured field. This
keeps the natural-language path quick without hiding its cost or reach.

## 6. Store & protocol touchpoints

- Child sessions: already specified (L3). Add `kind = review_child` +
  `parent_block` (the review block that spawned it).
- New block kinds: `review_brief`, `review_finding(s)` (one per reviewer,
  structured), `review_table` (claims + verification + resolution). All
  immutable; the table's human resolutions append as new blocks, never mutate.
- Protocol: fan-out status events (reviewer session id + state) so any client
  can render the glyph row.

## 7. Open questions

1. Does verification run as part of the parent's turn (blocking the parent
   session) or as its own detached turn with results streaming into the
   table? Lean: detached — verification of 6 claims can take minutes.
2. Cluster step: primary-model judgment call in v1 (cheap, good enough), or
   embedding-assisted matching later if conflation-of-distinct-claims shows up?
3. Reviewer context for diff scope: diff-only, or diff + read-only tools too?
   Lean: give tools even here; reviewers grepping callers of changed functions
   was a strength of none of the manual flows.
4. Where does the scoreboard render — a live strip, `marlin review stats`, or
   just a query? (Defer until data exists; no persistent sidebar.)
5. Per-model stance steering (assign one model "argue this is broken" while
   another defends it) remains deferred. Council-wide `balanced | adversarial`
   framing is sufficient for v1 and stays visible in the approved brief.
