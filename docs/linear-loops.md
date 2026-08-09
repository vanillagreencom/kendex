# Linear Loops — Triage Janitor (template)

Loops have no public GraphQL API (verified 2026-08-08 by schema
introspection: no `loop*`/`agentAutomation*` CRUD; only leaked enums
`AgentAutomationUsageLimitScope`, `WorkflowTrigger`, `WorkflowTriggerType`),
so they are configured manually in the Linear UI at **Loops → New loop**.

**How to use this template:** copy this file to `docs/linear-loops-local.md`
(the `docs/*-local.md` gitignore rule keeps it out of version control), fill
in every `[BRACKETED]` placeholder — each one says what to put there — and
paste the finished sections into the Linear UI. Angle-bracket `<...>` slots
inside the instructions text are runtime values the loop substitutes per
issue — leave those untouched. Your filled copy is the working document;
this template only changes when the loop design changes.

Scope boundary: Loops own per-issue hygiene AND routing — labels, team
routing, project assignment, `agent:*` routing labels, duplicate flagging,
actionability nudges, and same-PR bundling under a new template parent
(janitor Task 6) — plus, in the scheduled Loop 3 sweep only, comment-only
FLAGGING of likely-obsolete issues via Code Intelligence. The line is
constructive versus destructive: cancellation, merging issues away, and
acting on an obsolete flag stay with the audit workflow
(`skills/project-management/workflows/audit-issues.md` — the user-facing
wrapper that owns the approval gate and those mutations, with the
repo-access analysis in `workflows/tpm-audit.md` underneath). Loops must
never cancel, merge, or consolidate issues; Loop 3's obsolete check feeds
that workflow, it never decides for it.

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
| Allow changes outside triggering issue | ON | Needed for `related` relations, duplicate comments, and setting the parent on Task 6 bundle children; instructions hard-limit everything else |
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
- Never create new issues, with ONE exception: the bundle parent of Task 6,
  built from the template embedded there. At most one per run.
- Never edit the title or description of any issue other than the triggering
  issue. Remember that edits and comments on issues synced from an external
  tracker propagate to that tracker.
- Never change assignees or cycles. Project may be SET where it is empty
  (Task 5) — never changed or cleared once set.
- Routing labels are add-only: never change or remove an existing `agent:*`
  label (activation re-checks routing and owns corrections).
- On issues other than the triggering issue, you may only add "related"
  relations, comments, and — for Task 6 bundle children only — set their
  parent to the bundle parent you just created. No other field edits.
- If nothing needs changing, do nothing at all. Do not post repeat comments.

## Team ownership map

Use this map for routing decisions. It overrides guesses from team names.

[One bullet per team, format: "- TEAM_NAME (KEY): WHAT_IT_OWNS — repos,
components, work types". Where two teams sound alike or share a product
name, add an explicit "NOT ..." disambiguation. Close with any
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
against the issue's title and description. Remove a
label only when it is plainly contradicted by the issue content or invalid
for the destination team; otherwise leave existing labels alone.

Agent routing label: if the issue carries no `agent:*` label, assign exactly
ONE from the team's declared set below, chosen by which definition best fits
the issue's scope. Add-only — never change or remove an existing `agent:*`
label; the TPM pipeline and activation own corrections. If no definition
clearly fits, assign nothing and name the gap in your Task 4 comment
instead.

[AGENT LABEL DEFINITIONS — one bullet per label the team declares, format:
"- agent:NAME: what scope it owns — components, file types, work kinds".
Copy these from the team's label descriptions / taxonomy doc and keep them
in sync.]

## Task 3 — Duplicate flagging

Search existing issues (all states, all accessible teams) for issues
describing the same problem or the same component change. Match on component
or module names, not just title keywords. If a likely duplicate exists:
- Add a "related" relation between the two issues.
- Comment on the triggering issue: "Possible duplicate of <ID> — <one-line
  reason>", substituting the issue you found and why.
Do not close, merge, or mark either issue as a duplicate yourself. Flag only.

## Task 4 — Actionability nudge

If the issue lacks clear scope, acceptance criteria, or a concrete
deliverable (for example a vague one-line description with no target
component), add one comment listing what is missing. One comment maximum.

## Task 5 — Project assignment

If the triggering issue has no project, pick the best-fitting ACTIVE
project of its team (the destination team after Task 1) by matching the
issue's content against project names and descriptions, and set it. Never
invent a project, never move an issue that already has one, and skip when
no project clearly fits — name the gap in your Task 4 comment instead.

## Task 6 — Same-PR bundling

Search open, unstarted issues (Triage, Backlog, Todo) of the SAME team and
SAME project as the triggering issue. If the triggering issue plus one to
four of them would plausibly ship as a single pull request — same component
or surface, complementary small changes, no conflicting approaches — create
ONE new parent issue from the template below and set each child's parent to
it. Skip entirely when in doubt; never re-parent an issue that already has
a parent; never bundle across teams or projects.

Parent issue format (from the project-management skill's
parent-issue-template — keep this embedded copy faithful to it):

  [SUMMARY — 1-2 sentences describing the bundle's overall goal,
  synthesized from the children, not copied from one of them]

  ## Sub-Issues

  - [ISSUE_ID]: [title] (agent:X)
  - [ISSUE_ID]: [title] (agent:Y)

  ## Acceptance Criteria

  - [ ] [Criterion from child [ISSUE_ID]]

  ## Context

  - [Key constraints shared by the children, 1-3 bullets]

Parent rules: title names the bundle's goal, not a child's; label the
parent `agent:multi` when children span two or more `agent:*` domains,
otherwise give it the children's shared agent label; the parent carries NO
estimate; omit the Acceptance Criteria section when children have none; no
implementation detail — requirements live in the children; add no blocking
relations unless a child's own text states one.

## Tone

Comments are short, factual, and neutral. No greetings, no sign-offs.
```

---

## Loop 2 — Re-triage on demand

Re-run handle: apply the `re-triage` label to any issue to get one janitor
pass. Sources of the label: manual (an operator or a local agent) and
Loop 3's weekly sweep. Create the workspace label `re-triage` first.

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

## Loop 3 — Backlog sweep (scheduled, flag-only)

Weekly repo-grounded staleness sweep. Flags; never fixes or cancels. Chains
Loop 2 by applying `re-triage` instead of duplicating the janitor logic.
Requires workspace Code Intelligence enabled with Loops access.

### Trigger

| Setting | Value |
|---------|-------|
| Event | On a **schedule** — [pick a weekly slot, e.g. Monday 09:00 workspace time] |
| Teams | [Same teams as Loop 1] |
| Eligibility | No UI filter exists for scheduled loops — the instructions text below enforces it: Backlog/Todo state, not updated in 60 days, oldest first, at most 10 issues per run, skip issues an agent session is actively working |

### Permissions

| Setting | Value | Why |
|---------|-------|-----|
| Team access | All public teams | Duplicate check needs cross-team view |
| Allow changes outside triggering issue | ON | Scheduled loop touches multiple issues |
| Web search | OFF | Not needed |
| Externally synced issues and comments | ON | Same trade-off as Loop 1 |
| Code Intelligence | ON | The obsolete check reads workspace-connected repos |
| Coding sessions | OFF | Flag-only; no code changes |

### Instructions

```text
You are a weekly backlog auditor. You flag; you never fix, cancel, or close.
Work through at most 10 issues per run: Backlog or Todo state, not updated
in the last 60 days, oldest first. Skip issues an agent session is actively
working.

## Hard limits

- Never cancel, close, archive, merge, or delete any issue.
- Never create new issues.
- Never edit any issue's title, description, assignees, cycles, projects,
  priority, or estimate.
- Allowed mutations: comments, "related" relations, and adding the
  "re-triage" label. Nothing else.
- At most one comment per issue per run — when several checks match the
  same issue, combine them into that single comment (Check 1's obsolete
  finding first, then Check 3's duplicate note as a second line). If you
  commented on an issue in a previous run and nothing changed, skip it
  entirely.
- Edits and comments on issues synced from an external tracker propagate to
  that tracker.

## Check 1 — Likely obsolete

Using code intelligence on the workspace-connected repositories, check
whether the issue's described deliverable already exists in the owning
repo (named function, component, config, or behavior). If it clearly does,
comment: "Likely obsolete — <file or symbol you found>. Flagged for local
audit confirmation; not closing." Do not cancel the issue yourself.

## Check 2 — Stale or incomplete metadata

If the issue lacks a type label, a project, or an `agent:*` routing label,
has labels contradicted by its content, or clearly belongs to another team,
add the "re-triage" label — the re-triage pass performs the actual cleanup
(including project/agent assignment and Task 6 bundling). Do not fix the
metadata inline.

## Check 3 — Duplicates

If another issue (any state, any accessible team) describes the same
problem, add a "related" relation and comment: "Possible duplicate of
<ID> — <one-line reason>", substituting the issue you found and why.

## Tone

Comments are short, factual, and neutral. No greetings, no sign-offs.
```

---

## Deliberate non-loops

- **No per-team loop copies** — the ownership map inside one instructions
  text covers team differences; copies drift.
- **No "updated" catch-all loop** — tracker sync and orchestration churn
  would fire it constantly.
- **No cancel/consolidation loop** — the scheduled sweep FLAGS obsolete
  candidates, but cancellation and merging issues away stay with the gated
  audit workflow (batch view, approval, deterministic repo verification).
  Same-PR bundling is NOT this: it lives in janitor Task 6, creates only a
  template parent, and destroys nothing.
- **No priority/estimate loop** — orchestration and cycle planning own those.
