---
name: council
description: Convene a multi-model review council — fan one review prompt to several models with task_batch, then consolidate their findings into a decision.
---

# Council: multi-model review

Use when the user asks for a council, a multi-model review, second opinions,
or "ask X and Y what they think". This replaces the manual loop of pasting
one review prompt into several vendor CLIs and consolidating by hand.

## Procedure

1. **Roster.** Use the models the user named. If they named none, use the
   default roster below. Two or three reviewers is the sweet spot; never more
   than four. Guest models (`claudecode/...`) cannot sit on a council yet —
   reviewers must be native registry models; if the user asks for a guest
   reviewer, say so and offer the native roster instead.

2. **Write ONE self-contained review prompt** and send the identical text to
   every reviewer. It must stand alone:
   - the question to answer, and the decision it feeds;
   - exact file paths — reviewers run read-only in this workspace and can
     read_file/grep/glob, so name every relevant path rather than pasting
     whole files;
   - for uncommitted work, paste the relevant diff hunks into the prompt
     (reviewers have no shell and cannot run `git diff`);
   - the required output shape: verdict (one line) · top findings
     (file:line, severity, why it matters) · what you would do differently ·
     confidence (low/medium/high).

3. **Fan out** with a single `task_batch` call: one task per reviewer,
   identical `prompt`, a distinct `model` per task, `max_rounds` 12. Tell
   reviewers to budget their reading (a handful of targeted reads, then
   answer) — a reviewer that burns its rounds on exploration returns
   nothing.

4. **Consolidate** — never paste raw responses back at the user. Produce:
   - agreements: findings two or more reviewers raised, deduplicated;
   - disagreements, each side's argument in one line, attributed by model;
   - findings you judge false positives, and why;
   - your own recommendation and the concrete next step.
   If a reviewer errored or returned nothing, say so rather than silently
   dropping it.

## Default roster

- openrouter/x-ai/grok-4.6
- openrouter/z-ai/glm-5.3

(Edit this list to change the standing roster — this file is plain config.)

## Constraints

- Reviewers are read-only child sessions: no writes, no shell. Anything a
  reviewer must see that is not on disk goes into the prompt.
- One round only: no follow-up interrogation of reviewers. If the council
  splits with low confidence, report the split and let the user decide
  whether to re-run with a sharper question.
