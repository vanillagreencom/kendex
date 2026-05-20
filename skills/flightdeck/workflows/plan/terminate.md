# Workflow: `plan terminate` — Plan Lane Summary + Mixed-Mode Unwind

End-of-session unwind for plan item entries. Generic session entries still use the generic summary path; Linear and GitHub issue entries keep their lane summary paths. Mixed sessions produce all applicable lane summaries.

**Inputs**: master state after debounce confirms terminal entries.

**Pre-conditions**:
- `plan/watch.md` confirmed plan entries are terminal (`merged | aborted | failed | dead`).
- Generic entries, if any, are terminal enough for `workflows/shared/session-watch.md`.

**Post-condition**: `<FLIGHTDECK_STATE_DIR>/flightdeck-summary-<SESSION>-<TS>.md` written, master state terminated/archived, user-visible summaries emitted.

---

## § 0: Partition tracked entries by domain key

Read canonical entries:

```bash
ENTRIES_JSON=$(flightdeck-state tracked-entries)
```

Partition:

- `PLAN_ITEM_ENTRIES`: entries with `entry.domain.plan_item` present.
- `GITHUB_ISSUE_ENTRIES`: entries with `entry.domain.github_issue` present.
- `LINEAR_ISSUE_ENTRIES`: entries with `entry.domain.issue` present.
- `GENERIC_ENTRIES`: entries with `kind == "adhoc"`, `kind == "workflow"`, or future non-issue kind and no domain markers.
- `MALFORMED_DOMAIN_ENTRIES`: entries with multiple domain keys, missing plan item required fields, or issue-shaped fields outside their domain key. Fail closed: warn and pause rather than silently route to generic.

Rules:

1. Plan entries are summarized here.
2. GitHub issue entries continue to use `workflows/github/terminate.md`; this file must not read or mutate `domain.github_issue` except for partitioning.
3. Linear entries continue to use `workflows/linear/terminate.md`; this file must not read or mutate `domain.issue` except for partitioning.
4. Generic entries use the generic session summary path with no GitHub, Linear, worktree, or project-management calls.
5. Mixed sessions produce lane summaries in this order: generic, plan, GitHub issue, Linear issue.

---

## § 1: Compose generic session outcomes

If `GENERIC_ENTRIES` is non-empty, gather only local state: id, title, kind, state, harness, elapsed, decisions count, last prompt, last answer. Do not call `gh`, Linear, worktree helpers, or project-management for generic entries.

For empty tracked-entry set, emit the explicit empty-session diagnostic from the generic termination path.

---

## § 2: Compose plan item outcomes

For each plan entry:

| Field | Source |
|-------|--------|
| `plan_title` | `domain.plan_item.plan_title` |
| `plan_path` | `domain.plan_item.plan_path` |
| `item_id` | `domain.plan_item.item_id` |
| `item_title` | `domain.plan_item.item_title` |
| `depends_on` | `domain.plan_item.depends_on` |
| `state` | entry state (`merged | aborted | failed | dead`) |
| `pr_number` | `domain.plan_item.pr_number` |
| `merge_commit` | `domain.plan_item.merge_commit`; if missing and state is merged, `gh pr view <PR> --json mergeCommit` with retry policy |
| `worktree` | `domain.plan_item.worktree` |
| `decisions_count` | `decisions_log | length` |

Any mid-termination `gh` failure follows the plan lane policy: retry once after 2s; on second failure, record `gh-cli-unavailable` and include `unknown` for that field rather than throwing away the whole summary.

---

## § 3: Compose plan follow-up report

Gather only follow-ups explicitly recorded in `decisions_log` by the child or handler, such as:

- follow-up issue URLs the child opened;
- deferred review suggestions captured by a GitHub handler;
- scope-creep notes that were paused for the user;
- dependency items skipped or blocked.

Do not infer project/cycle priority. Do not call `project-management`.

---

## § 4: Write summary file

Write `<FLIGHTDECK_STATE_DIR>/flightdeck-summary-<SESSION>-<TS>.md`.

When generic entries exist, include generic section first:

```markdown
## Tracked Sessions
| Entry | Kind | State | Harness | Elapsed | Decisions | Last prompt | Answer |
|-------|------|-------|---------|---------|-----------|-------------|--------|
| ...
```

When plan entries exist, append:

```markdown
## Plan Item Outcomes
Plan: <PLAN_TITLE>
Source: <PLAN_PATH>

| Item | Title | State | PR | Merge Commit | Depends On | Worktree | Decisions |
|------|-------|-------|----|--------------|------------|----------|-----------|
| <ITEM_ID> | <ITEM_TITLE> | merged | #<PR> | <sha> | <items or —> | <path> | <count> |

## Plan Follow-ups
- <item or "None recorded">

## Plan Counts
- Merged: <N>
- Aborted: <N>
- Failed: <N>
- Dead: <N>
- Follow-ups: <N>
```

When GitHub or Linear entries exist too, append a handoff note that their lane terminate workflows own their sections.

---

## § 5: Finalize master state

Only finalize after all applicable lane summaries are written.

```bash
flightdeck-state set terminated true
flightdeck-state set terminated_at '"<ISO8601>"'
flightdeck-state set summary_path '"<FLIGHTDECK_STATE_DIR>/flightdeck-summary-<SESSION>-<TS>.md"'
flightdeck-daemon stop --session "$SESSION"
flightdeck-state archive
```

Do not remove plan entries before archive. `archive` emits completion activity before syncing the final state/activity and summary into the durable run, clears the active pointer, leaves the project-local archive for compatibility, and preserves `decisions_log`, `pr_number`, `merge_commit`, `unknown_since`, dependencies, and worktree history for dashboard/post-mortem inspection.

---

## § 6: User-visible output

Emit generic block first when applicable, then plan block.

<plan_output_format>
### ✈️ Flightdeck plan complete

**Plan**: [PLAN_TITLE]
**Source**: `[PLAN_PATH]`

**Outcomes**

| Item | State | PR | Merge commit | Decisions | Depends on |
|------|-------|----|--------------|-----------|------------|
| [ITEM_ID] | [merged | aborted | failed | dead] | #[PR or —] | [SHORT_SHA or —] | [N] | [ITEM_ID, ... or —] |

**Follow-ups**
[If follow-ups exist:]
- [FOLLOW_UP]

[If none:]
- None recorded.

**Counts**: [N] merged · [N] aborted · [N] failed · [N] dead · [N] follow-ups

Summary file: `<FLIGHTDECK_STATE_DIR>/flightdeck-summary-<SESSION>-<TS>.md`
</plan_output_format>

For mixed sessions, emit generic output, then `<plan_output_format>`, then GitHub and Linear outputs if those entries exist. Never collapse to a one-liner.

---

## § 7: Pane lifecycle

Do not close additional panes here. `plan/close-item.md` already tore down terminal plan item panes after authoritative PR merge verification. Generic/ad-hoc panes remain available for transcript inspection unless the user explicitly stops/removes them.

## Returns

To the Flightdeck session loop after summary emission and archive.
