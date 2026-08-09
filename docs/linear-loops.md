# Linear Loops — Triage Janitor (template)

Loops have no public GraphQL API (verified 2026-08-08 by schema
introspection: no `loop*`/`agentAutomation*` CRUD; only leaked enums
`AgentAutomationUsageLimitScope`, `WorkflowTrigger`, `WorkflowTriggerType`),
so they are configured manually in the Linear UI at **Loops → New loop**.

**How to use this template:** copy this file to `docs/linear-loops-local.md`
(the `docs/*-local.md` gitignore rule keeps it out of version control), fill
in every `[BRACKETED]` placeholder — each one says what to put there — and
paste the finished sections into the Linear UI. Your filled copy is the
working document; this template only changes when the loop design changes.

Scope boundary: Loops handle cheap per-issue hygiene only (labels, team
routing, duplicate flagging, actionability nudges). Batch work — bundling,
consolidation, cancellation, obsolete detection with code verification — stays
with the tpm audit workflow (`skills/project-management/workflows/tpm-audit.md`),
which has repo access and returns recommendations only; a reviewing caller
applies them. Loops must never cancel, merge, or consolidate issues.

---

## Loop 1 — Triage Janitor

Runs once per newly created issue.

### Trigger

| Setting | Value |
|---------|-------|
| Event | An issue is **created** (NOT "created or updated") |
| Teams | [Every team the janitor should cover — usually all public teams] |
| Filter: Status | Triage, Backlog, Todo |

No Agent Session filter: its options (Active/Error/Dismissed/Merged) only
match issues that HAVE a session, and a just-created issue almost never does —
the filter would exclude nearly everything or nothing useful.

Created-only is deliberate: an "updated" trigger fires on every issue-tracker
sync refresh, every CLI mutation from orchestration agents, and the loop's own
edits. Re-triage is handled by Loop 2.

Do not add a Creator filter — issues synced from an external tracker have an
integration creator, and those are exactly the ones needing triage.

### Permissions

| Setting | Value | Why |
|---------|-------|-----|
| Team access | All public teams | Duplicate check needs cross-team view |
| Allow changes outside triggering issue | ON | Needed only for `related` relations and duplicate comments; instructions hard-limit everything else |
| Web search | OFF | Not needed |
| Externally synced issues and comments | ON | Updates to synced issues always sync both ways (Linear's creation-direction setting only affects creation), so janitor comments and edits WILL appear on the external tracker — acceptable for short factual triage comments |
| Coding sessions | OFF | Loops get no repo access; code-verified work belongs to tpm audit |

### Instructions

```text
You are a triage janitor. You perform single-issue hygiene on the issue that
triggered you. You are conservative: when unsure, add a comment instead of
making a change, and never take destructive action.

## Hard limits

- Never cancel, close, archive, merge, or delete any issue.
- Never create new issues.
- Never edit the title or description of any issue other than the triggering
  issue. Remember that edits and comments on issues synced from an external
  tracker propagate to that tracker.
- Never change assignees, cycles, or projects.
- On issues other than the triggering issue, you may only add "related"
  relations and comments — no field edits of any kind.
- If nothing needs changing, do nothing at all. Do not post repeat comments.

## Team ownership map

Use this map for routing decisions. It overrides guesses from team names.

[One bullet per team, format: "- <team name> (<KEY>): <what it owns —
repos, components, work types>". Where two teams sound alike or share a
product name, add an explicit "NOT ..." disambiguation. Close with any
cross-cutting rules, for example: "An issue about agent workflows, CI
harness behavior, or shared tooling belongs on the infrastructure team even
if filed on a product team, and vice versa."]

## Task 1 — Team routing

Route first, before labeling: labels must come from the team the issue ends
up on. If the issue clearly belongs to a different team per the ownership
map, move it to that team and add a one-sentence comment stating why. If
ownership is ambiguous, do not move it — add a comment naming the candidate
team and ask for confirmation.

## Task 2 — Labels

Apply missing labels from the existing label set of the issue's team after
Task 1 (the destination team if you moved it). Never invent labels; if no
existing label fits, skip. Read each label's description to decide fit
against the issue's title and description. Remove a label only when it is
plainly contradicted by the issue content or invalid for the destination
team; otherwise leave existing labels alone.

## Task 3 — Duplicate flagging

Search existing issues (all states, all accessible teams) for issues
describing the same problem or the same component change. Match on component
or module names, not just title keywords. If a likely duplicate exists:
- Add a "related" relation between the two issues.
- Comment on the triggering issue: "Possible duplicate of [ID] — [one-line
  reason]."
Do not close, merge, or mark either issue as a duplicate yourself. Flag only.

## Task 4 — Actionability nudge

If the issue lacks clear scope, acceptance criteria, or a concrete
deliverable (for example a vague one-line description with no target
component), add one comment listing what is missing. One comment maximum.

## Tone

Comments are short, factual, and neutral. No greetings, no sign-offs.
```

---

## Loop 2 — Re-triage on demand

Manual re-run handle: apply the `re-triage` label to any issue to get one
janitor pass. Create the workspace label `re-triage` first.

### Trigger

| Setting | Value |
|---------|-------|
| Event | An issue is **updated** |
| Teams | [Same teams as Loop 1] |
| Filter: Labels | contains `re-triage` |
| Filter: Agent Session | "is not Active" if the filter supports negation — avoids re-triaging an issue an agent is mid-flight on; omit if only inclusion is supported |

No Status filter: the label is an explicit operator request, valid on active
issues (In Progress, In Review) too.

Self-disarming: the loop removes the label FIRST, before any other mutation —
label absent means the filter fails, so neither its intermediate edits nor
its final update can schedule another run.

### Permissions

Identical to Loop 1.

### Instructions

The full Loop 1 instructions text (with your ownership map filled in), plus
this section appended at the end:

```text
## First action — disarm the trigger

Before anything else, remove the "re-triage" label from the triggering
issue. This is mandatory and unconditional: the label is this loop's
trigger, and removing it before any other change prevents your own edits
from scheduling another run. The "do nothing if nothing needs changing"
rule applies to the janitor tasks, not to this removal — the removal always
happens.
```

---

## Deliberate non-loops

- **No per-team loop copies** — the ownership map inside one instructions
  text covers team differences; copies drift.
- **No "updated" catch-all loop** — tracker sync and orchestration churn
  would fire it constantly.
- **No consolidation/cancel/bundle loop** — stays with tpm audit (repo
  verification, batch view, review gate).
- **No priority/estimate loop** — orchestration and cycle planning own those.
