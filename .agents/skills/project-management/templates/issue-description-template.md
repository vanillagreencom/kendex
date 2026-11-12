# Issue Description Template

```markdown
> **Story:** [Who this is about.] [What happens today.] [What happens after the change, and its consequence.]

> **Why this matters:** [The harm or cost today, and what the change buys.]

## Done when

- [ ] [OBSERVABLE_ACCEPTANCE]

## Requirements

* [REQUIREMENT_1]
* [REQUIREMENT_2]

## Filing record

**Source**: [ORIGIN_CONTEXT]

**Reached by**: [REACH]

**Owner**: [OWNER]

**Symptom**: [SYMPTOM]

**Supersession**: [SUPERSESSION]

**Code-quality evaluation**: [EVALUATION_LINE]

**Expected delta**: [N] lines

**Regressed-by**: [REGRESSED_BY]

**Research**: [RESEARCH_REF]

**Decision [DXXX]**: [DECISION_PATH]

## Context

**Location**: `[FILE_PATH]`

## Owner directive (verbatim)

[OWNER_DIRECTIVE]

## Evidence

- [One fact and the link that shows it]
```

## Field Mapping

| Placeholder | Source | Notes |
|-------------|--------|-------|
| `[ORIGIN_CONTEXT]` | Caller — e.g. `PR review suggestion ([found_by])`, `architecture planning` | Always include provenance |
| `[REACH]` | `create_fields.reach`, else the caller — the user action, run, check, or shipped producer that arrives at the defect; an owner-directed item names the ask | **Required on every issue** — the rule and what it refuses are [SKILL.md](../SKILL.md) § Disposition; `linear.sh issues create` enforces it |
| `[N]` in **Expected delta** | Caller: estimated production lines for the planned change | `item-tier` reads it with the launch estimate and Location paths to choose a tier. Drop the line when no estimate is useful. It places no limit on the committed diff |
| `[REGRESSED_BY]` | `create_fields.regressed_by`, else the caller: the pull request that caused the defect, as `#N`, several comma-separated | Only when that pull request is known; drop the line otherwise. A review-born item that names its source PR in `[ORIGIN_CONTEXT]` leaves it empty. `oversee-report`'s Escapes count reads this line and no other `#N` |
| `[SUPERSESSION]` | `create_fields.supersession`, else the caller's own comparison of the item with the open issues before the create | **Required on every issue**: each matched open item with the action taken on it and its identifier, or `none found; searched: [TERMS]`, in the form [audit-output.md](../schemas/audit-output.md) § ISSUE Mode gives; `linear.sh issues create` refuses a body without one |
| `[SYMPTOM]` | Caller — the run, the user, or the red check that already showed the defect | Required on a review-born filing at priority 2, which is the reported tier; drop the line otherwise |
| `[EVALUATION_LINE]` | The filed finding's code-quality evaluation line, as the finding carries it | Only when the finding carries one; drop the line otherwise. Its form is code-quality's `SKILL.md` § Finding Evaluation |
| `[OWNER]` | Caller: the person or request that authorizes the work | Omit when absent |
| Story / Why this matters | `items[].description`, or `create_fields.description` in analyzed mode | Story is a simple user or agent story in three or four everyday sentences: who is affected, what they notice today, what changes and its consequence. Why this matters states the big-picture cost and benefit in time, money, failed work or the owner's attention, without retelling the sequence. Authors and reviewers judge the prose |
| `[OBSERVABLE_ACCEPTANCE]` | Description and requirements | List observable checks under Done when, per [SKILL.md](../SKILL.md) § Disposition. A box is a one-line `Post-merge:` box, in the form that section gives with `Deadline: +Nh`, only when it needs a deployment or installation, live use over time, or a person's screen or hands. Branch proof comes first. Each checked box keeps its immediately following indented plain `Evidence:` line |
| `[REQUIREMENT_*]` | `items[].recommendation` | Use as written — already a `* bullet` list — less what [SKILL.md](../SKILL.md) § Disposition cuts before filing |
| `[OWNER_DIRECTIVE]` | The marked block in `items[].description` | Include this section after Context when present, copied unchanged. The Requirements row's Disposition cuts never apply to it; omit the section when absent |
| `[FILE_PATH]` | `items[].location` | Backticked path. **Never line numbers**; name the function or struct |
| `--project` (create flag, not body text) | `project.recommended` in the audit output, or the caller | Under a declared project map, the map project [project-map.md § Routing](../references/project-map.md#routing) routes the item to, a child included, or none: the item is `project_needed` and is not created |
| `[RESEARCH_REF]` / `[DXXX]` / `[DECISION_PATH]` | Input `research_ref` / `decision_ref`, else inherited from the parent's description | Filing record; omit the line when absent. Decision references use decider's `schemas/decision-format.md` § Cross-references |

## Rules

1. Drop any header line with no value except `**Reached by**` and `**Supersession**`. Fill `**Reached by**`, or do not create the issue — an item with nothing to name is a decline. Always fill `**Supersession**`, using `none found; searched: [TERMS]` when nothing matched.
2. Write the body to a file with the harness file-write tool and pass `--description-file` (Linear) or `--body-file` (GitHub). Never an inline string, heredoc, or command substitution. The same flags work on update.
3. Before creating, check the governing decision with `.agents/skills/decider/scripts/decisions search "[KEYWORDS]"` and reference it in Filing record. A description must not contradict an active decision.
4. Every create passes the validated final `labels[]` from the label preflight.
5. Under a declared project map, every create passes `--project` with the map project [project-map.md § Routing](../references/project-map.md#routing) routes the item to, a child included; an item it routes to none is held as `project_needed`.
6. Write Story and Why this matters for the non-engineer product owner who reads only those two blocks. Story includes no file, function, variable, test, fixture, package or command names, code-site counts or engineering jargon. Name a system by what it does. Put technical details in Requirements, Context or Evidence. Keep the quoted blocks before every heading, with an unquoted blank line between them and before the first heading. Keep the section order shown above. Requirements constrain the solution without repeating acceptance checks.
7. Keep each `**Key**:` header at line start, with a blank line between every filing-record field and around every section heading. Each prose header value is one sentence with links. Keep Expected delta in the numeric form its reader accepts. A run, log or pull request is its URL and the one fact it shows. Keep published Artifacts links under Context. Move longer filing evidence and owner quotations outside the marked directive to short Evidence list items. Omit Evidence when empty. Paste no log lines. Mailbox and Slack ids outside the marked directive appear only in Source.

## Opening example

### Before

The bad opening named lane_host, check-lane-host, altered, mutant_module, Package.mutant, m, a stub SDK, fixture/site counts, needles, moved callbacks and reddened this lane. Keep those engineering facts below the opening.

### After

> **Story:** Fleet has an automatic test for the code that runs agents on cloud machines. To prove the test catches real faults, it breaks that code on purpose in small ways. Today it does that by editing the code's exact text, so when someone moves or tidies the code, the test fails even though nothing is wrong. After this change, the test breaks the code in a way that does not depend on its exact text, so it fails only when something is really wrong.

> **Why this matters:** Each false failure stops the work and spends test runs while an agent looks for a problem that does not exist. This happened on FLT-1408. Fewer false failures means changes finish sooner and cost less.

This is the owner's accepted wording. The underlying Fleet incident and its stated cause have not been independently checked here.
