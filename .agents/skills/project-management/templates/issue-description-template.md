# Issue Description Template

```markdown
[OUTCOME: one or two plain sentences saying what changes and why it matters]

[DONE: one sentence saying how we know the work is complete]

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
**Expected delta**: [N] lines
**Regressed-by**: [REGRESSED_BY]
**Research**: [RESEARCH_REF]
**Decision [DXXX]**: [DECISION_PATH]

## Context

**Location**: `[FILE_PATH]`

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
| `[SYMPTOM]` | Caller — the run, the user, or the red check that already showed the defect | Required on a review-born filing at priority 2, which is the reported tier; drop the line otherwise |
| `[OWNER]` | Caller: the person or request that authorizes the work | Omit when absent |
| `[OUTCOME]` | `items[].description`, or `create_fields.description` in analyzed mode | State the change and its impact in plain words |
| `[DONE]` / `[OBSERVABLE_ACCEPTANCE]` | Description and requirements | Summarize completion in one sentence; list its observable checks under Done when, per [SKILL.md](../SKILL.md) § Disposition |
| `[REQUIREMENT_*]` | `items[].recommendation` | Use as written — already a `* bullet` list — less what [SKILL.md](../SKILL.md) § Disposition cuts before filing |
| `[FILE_PATH]` | `items[].location` | Backticked path. **Never line numbers**; name the function or struct |
| `[RESEARCH_REF]` / `[DXXX]` / `[DECISION_PATH]` | Input `research_ref` / `decision_ref`, else inherited from the parent's description | Filing record; omit the line when absent. Decision references use decider's `schemas/decision-format.md` § Cross-references |

## Rules

1. Drop any header line with no value. `**Reached by**` is not one of them: fill it, or do not create the issue — an item with nothing to name is a decline.
2. Write the body to a file with the harness file-write tool and pass `--description-file` (Linear) or `--body-file` (GitHub). Never an inline string, heredoc, or command substitution. The same flags work on update.
3. Before creating, check the governing decision with `.agents/skills/decider/scripts/decisions search "[KEYWORDS]"` and reference it in Filing record. A description must not contradict an active decision.
4. Every create passes the validated final `labels[]` from the label preflight.
5. The opening outcome and done sentences explain the issue without the filing record. Keep the section order shown above. A body over 1500 characters has `##` headings.
6. Keep each `**Key**:` header at line start. Each prose header value is one sentence with links. Keep Expected delta in the numeric form its reader accepts. A run, log or pull request is its URL and the one fact it shows. Move longer evidence to short Evidence list items. Omit Evidence when empty. Paste no log lines. Mailbox and Slack ids appear only in Source.
