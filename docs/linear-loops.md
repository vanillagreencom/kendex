# Linear Loops — Triage Janitor

Source of truth for our Linear Loop definitions. Loops have no public GraphQL
API (verified 2026-08-08 by schema introspection: no `loop*`/`agentAutomation*`
CRUD; only leaked enums `AgentAutomationUsageLimitScope`, `WorkflowTrigger`,
`WorkflowTriggerType`), so they are configured manually in the Linear UI at
**Loops → New loop**. When this file changes, re-paste the affected sections
into the UI.

Scope boundary: Loops handle cheap per-issue hygiene only (labels, team
routing, duplicate flagging, actionability nudges). Batch work — bundling,
consolidation, cancellation, obsolete detection with code verification — stays
with the tpm audit workflow (`skills/project-management/workflows/tpm-audit.md`),
which has repo access and a review gate. Loops must never cancel, merge, or
consolidate issues.

---

## Loop 1 — Triage Janitor

Runs once per newly created issue.

### Trigger

| Setting | Value |
|---------|-------|
| Event | An issue is **created** (NOT "created or updated") |
| Teams | drovr, hyprtrade, memsira, vg-shell, vstack |
| Filter: Status | Triage, Backlog, Todo |
| Filter: Agent Session (if available) | none — skip issues an agent is actively working |

Created-only is deliberate: an "updated" trigger fires on every GitHub-sync
refresh, every `linear.sh` mutation from orch/tpm, and the loop's own edits.
Re-triage is handled by Loop 2.

Do not add a Creator filter — GitHub-synced issues have an integration
creator, and those are exactly the ones needing triage.

### Permissions

| Setting | Value | Why |
|---------|-------|-----|
| Team access | All public teams | Duplicate check needs cross-team view |
| Allow changes outside triggering issue | ON | Needed only for `related` relations and duplicate comments; instructions hard-limit everything else |
| Web search | OFF | Not needed |
| Externally synced issues and comments | ON | Instructions forbid title/description edits on synced issues; sync is one-way GitHub→Linear so Linear-side comments don't propagate back |
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
  issue. Never edit the title or description of the triggering issue if it is
  synced from GitHub (has a GitHub link/attachment) — for synced issues,
  restrict yourself to labels, team, priority, relations, and comments.
- Never change assignees, cycles, or projects.
- On issues other than the triggering issue, you may only add "related"
  relations and comments — no field edits of any kind.
- If nothing needs changing, do nothing at all. Do not post repeat comments.

## Team ownership map

Use this map for routing decisions. It overrides guesses from team names.

- vstack (VST): the agent-stack infrastructure repo — skills/, agents/,
  hooks/, pi-extensions, the Rust vstack CLI (add/refresh/report,
  vstack.toml), and propagation into consuming repos.
- hyprtrade (HT): the hyprtrade trading application itself. NOT the
  hyprtrade.io marketing website — website work belongs to vg-shell.
- vg-shell (VGS): the shell/capture pipeline repo and the hyprtrade.io
  website.
- drovr (DRO): the drovr product.
- memsira (MEM): the memsira product.

An issue about agent workflows, skills, hooks, CI harness behavior, or the
vstack CLI belongs in vstack even if it was filed on a product team, and vice
versa: product bugs filed on vstack belong on the product team.

## Task 1 — Labels

Apply missing labels from the issue's team's existing label set only. Never
invent labels; if no existing label fits, skip. Read each label's description
to decide fit against the issue's title and description. Remove a label only
when it is plainly contradicted by the issue content; otherwise leave
existing labels alone.

## Task 2 — Team routing

If the issue clearly belongs to a different team per the ownership map, move
it to that team and add a one-sentence comment stating why. If ownership is
ambiguous, do not move it — add a comment naming the candidate team and ask
for confirmation.

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
janitor pass. Requires the workspace label `re-triage` to exist.

### Trigger

| Setting | Value |
|---------|-------|
| Event | An issue is **updated** |
| Teams | drovr, hyprtrade, memsira, vg-shell, vstack |
| Filter: Labels | contains `re-triage` |
| Filter: Status | Triage, Backlog, Todo |

Self-disarming: the loop removes the label when done; label absent means the
filter fails, so its own final update does not re-fire it.

### Permissions

Identical to Loop 1.

### Instructions

The full Loop 1 instructions text, with this section appended at the end:

```text
## Completion

When finished, remove the "re-triage" label from the triggering issue. This
is mandatory — the label is the trigger, and removing it prevents re-runs.
```

---

## Deliberate non-loops

- **No per-team loop copies** — the ownership map inside one instructions
  text covers team differences; five copies drift.
- **No "updated" catch-all loop** — sync and orchestration churn would fire
  it constantly.
- **No consolidation/cancel/bundle loop** — stays with tpm audit (repo
  verification, batch view, review gate).
- **No priority/estimate loop** — orch and cycle planning own those.
