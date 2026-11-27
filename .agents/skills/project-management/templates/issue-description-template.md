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

> "[OWNER_DIRECTIVE]" ([DIRECTIVE_SOURCE])

## Evidence

- [One fact and the link that shows it]
```

## Field Mapping

- Story / Why this matters: `items[].description`, or `create_fields.description` in analyzed mode.
  - Story is a simple user or agent story in three or four everyday sentences: who is affected, what they notice today, what changes and its consequence.
  - Name the person's result. Name a package, program, file or storage location only when the reader must act on it.
  - Why this matters states the big-picture cost and benefit in time, money, failed work or the owner's attention, without retelling the sequence.
  - Authors and reviewers judge the prose.
- `[OBSERVABLE_ACCEPTANCE]`: the description and requirements.
  - List observable checks under Done when, per [filing.md](../references/filing.md) § Done when.
  - A box is a one-line `Post-merge:` box, in the form that section gives with `Deadline: +Nh`, only when it needs a deployment or installation, live use over time, or a person's screen or hands.
  - Branch proof comes first.
  - Each checked box keeps its immediately following indented plain `Evidence:` line.
- `[REQUIREMENT_*]`: `items[].recommendation`.
  - Use it as written, already a `* bullet` list, less what [filing.md](../references/filing.md) § Requirements cuts before filing.
- `[ORIGIN_CONTEXT]`: the caller, e.g. `PR review suggestion ([found_by])`, `architecture planning`.
  - Always include provenance.
- `[REACH]`: `create_fields.reach`, else the caller.
  - The user action, run, check, or shipped producer that arrives at the defect. An owner-directed item names the ask.
  - Required on every issue: fill it, or do not create the issue. An item with nothing to name is a decline. The rule is [filing.md](../references/filing.md) § Name what reaches it.
- `[OWNER]`: the caller, naming the person or request that authorizes the work.
  - Omit when absent.
- `[SYMPTOM]`: the caller.
  - The run, the user, or the red check that already showed the defect.
  - Required on a review-born filing at priority 2, which is the reported tier.
  - Drop the line otherwise.
- `[SUPERSESSION]`: `create_fields.supersession`, else the caller's own comparison of the item with the open issues before the create.
  - Required on every issue.
  - It holds each matched open item with the action taken on it and its identifier, or `none found; searched: [TERMS]` when nothing matched, in the form [audit-output.md](../schemas/audit-output.md) § ISSUE Mode gives.
- `[EVALUATION_LINE]`: the filed finding's code-quality evaluation line, as the finding carries it.
  - Only when the finding carries one. Drop the line otherwise.
  - Its form is code-quality's `SKILL.md` § Finding Evaluation.
- `[N]` in **Expected delta**: the caller's estimate of production lines for the planned change.
  - `orch-runtime tier` reads it with the launch estimate and Location paths to choose a tier.
  - Drop the line when no estimate is useful.
  - It places no limit on the committed diff.
- `[REGRESSED_BY]`: `create_fields.regressed_by`, else the caller.
  - The pull request that caused the defect, as `#N`, several comma-separated.
  - Only when that pull request is known. Drop the line otherwise.
  - A review-born item that names its source PR in `[ORIGIN_CONTEXT]` leaves it empty.
  - `orch-runtime report render`'s Escapes count reads this line and no other `#N`.
- `[RESEARCH_REF]` / `[DXXX]` / `[DECISION_PATH]`: input `research_ref` / `decision_ref`, else inherited from the parent's description.
  - Filing record lines. Omit the line when absent.
  - Decision references use decider's `schemas/decision-format.md` § Cross-references.
- `[FILE_PATH]`: `items[].location`.
  - A backticked path.
  - **Never line numbers.**
  - Name the function or struct.
- `[OWNER_DIRECTIVE]`: the quoted sentence in the marked block of `items[].description`.
  - Include this section after Context when present, copied unchanged.
  - It is one sentence of the owner's text, the one that states the ask, quoted byte for byte.
  - The `[REQUIREMENT_*]` cuts never apply to it.
  - Omit the section when absent.
- `[DIRECTIVE_SOURCE]`: the source the marked block names, where the owner's full text is.
  - It is the source message's id, a mailbox or Slack id, when that message holds the full text.
  - Otherwise, on Linear, it is the repository path of a file holding the full text, which the filer attaches to the created issue with `linear.sh issues update [ISSUE_ID] --attach [PATH]`. The description never holds the full text.
  - Otherwise, on GitHub, where this route attaches nothing, the body keeps the full text in a fenced block below the quote line, and `[DIRECTIVE_SOURCE]` reads `full text below`.
- `--project` (create flag, not body text): `project.recommended` in the audit output, or the caller. Rule 5 below.

## Rules

1. Header lines:
   - Drop any header line with no value except `**Reached by**` and `**Supersession**`, which § Field Mapping requires.
2. The body:
   - Write the body to a file with the harness file-write tool.
   - Pass `--description-file` (Linear) or `--body-file` (GitHub). Never an inline string, heredoc, or command substitution.
   - The same flags work on update.
3. Decisions:
   - Before creating, check the governing decision with `.agents/skills/decider/scripts/decisions search "[KEYWORDS]"`.
   - Reference it in Filing record.
   - A description must not contradict an active decision.
4. Every create passes the validated final `labels[]` from the label preflight.
5. Every create passes `--project` with the project [project-map.md § Routing](../references/project-map.md#routing) routes the item to from the team's live projects, a child included; an item it routes to `project_needed` is held.
6. Opening and sections:
   - Write Story and Why this matters for the non-engineer product owner who reads only those two blocks.
   - Keep function, variable, test, fixture and command names, code-site counts and engineering jargon out of Story.
   - Name a system by what it does.
   - Put technical details in Requirements, Context or Evidence.
   - Keep the quoted blocks before every heading, with an unquoted blank line between them and before the first heading.
   - Keep the section order shown above.
   - Requirements constrain the solution without repeating acceptance checks.
7. Headers and evidence:
   - Keep each `**Key**:` header at line start, with a blank line between every filing-record field and around every section heading.
   - Each prose header value is one sentence with links.
   - Keep Expected delta in the numeric form its reader accepts.
   - A run, log or pull request is its URL and the one fact it shows.
   - Keep published Artifacts links under Context.
   - Move longer filing evidence and owner quotations outside the marked directive to short Evidence list items.
   - Omit Evidence when empty.
   - Paste no log lines.
   - Mailbox and Slack ids outside the marked directive appear only in Source.
8. Splitting:
   - When to split one body into several items, and when one design's items go under a parent or a project: [filing.md](../references/filing.md) § One landing per subsystem.

## Opening example

### Before

The bad opening named lane_host, check-lane-host, altered, mutant_module, Package.mutant, m, a stub SDK, fixture/site counts, needles, moved callbacks and reddened this lane. Keep those engineering facts below the opening.

### After

> **Story:** Fleet has an automatic test for the code that runs agents on cloud machines. To prove the test catches real faults, it breaks that code on purpose in small ways. Today it does that by editing the code's exact text, so when someone moves or tidies the code, the test fails even though nothing is wrong. After this change, the test breaks the code in a way that does not depend on its exact text, so it fails only when something is really wrong.

> **Why this matters:** Each false failure stops the work and spends test runs while an agent looks for a problem that does not exist. This happened on FLT-1408. Fewer false failures means changes finish sooner and cost less.
