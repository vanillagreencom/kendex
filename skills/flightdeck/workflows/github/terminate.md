# Workflow: `github terminate` — GitHub Lane Summary + Mixed-Mode Unwind

End-of-session unwind for GitHub issue entries. Generic session entries still use the generic summary path; Linear entries keep the Linear summary path. Mixed sessions produce all applicable lane summaries.

**Inputs**: master state after debounce confirms terminal entries.

**Pre-conditions**:
- `github/watch.md` confirmed GitHub entries are terminal (`merged | aborted | dead`).
- Generic entries, if any, are terminal enough for `workflows/shared/session-watch.md`.

**Post-condition**: `tmp/flightdeck-summary-<SESSION>-<TS>.md` written, master state terminated/archived, user-visible summaries emitted.

---

## § 0: Partition tracked entries by domain key

Read canonical entries:

```bash
ENTRIES_JSON=$(flightdeck-state tracked-entries)
```

Partition:

- `GITHUB_ISSUE_ENTRIES`: entries with `entry.domain.github_issue` present.
- `LINEAR_ISSUE_ENTRIES`: entries with `entry.domain.issue` present and no `domain.github_issue`.
- `GENERIC_ENTRIES`: entries with `kind == "adhoc"`, `kind == "workflow"`, or future non-issue kind and no issue-domain markers.
- `MALFORMED_ISSUE_ENTRIES`: `kind == "issue"` with neither domain key, or issue-shaped fields at top level. Fail closed: warn and pause rather than silently route to generic.

Rules:

1. GitHub entries are summarized here.
2. Linear entries continue to use `workflows/linear/terminate.md`; this file must not read or mutate `domain.issue` except for partitioning.
3. Generic entries use the generic session summary from `workflows/linear/terminate.md` § 1 / TS generic renderer, with no GitHub or Linear calls.
4. Mixed sessions produce BOTH lane summaries: generic first (if present), GitHub issue summary, then Linear issue summary if Linear entries are present.

---

## § 1: Compose generic session outcomes

If `GENERIC_ENTRIES` is non-empty, gather only local state: id, title, kind, state, harness, elapsed, decisions count, last prompt, last answer. Do not call `gh`, `linear`, worktree helpers, or project-management for generic entries.

For empty tracked-entry set, emit the explicit empty-session diagnostic from the generic termination path.

---

## § 2: Compose GitHub issue outcomes

For each GitHub entry:

| Field | Source |
|-------|--------|
| `number` | `domain.github_issue.number` |
| `state` | entry state (`merged | aborted | dead`) |
| `url` | `domain.github_issue.url` |
| `pr_number` | `domain.github_issue.pr_number` |
| `merge_commit` | `domain.github_issue.merge_commit`; if missing and state is merged, `gh pr view <PR> --json mergeCommit` with retry policy |
| `worktree` | `domain.github_issue.worktree` |
| `scope_files_actual` | `domain.github_issue.scope_files_actual`; if missing and PR exists, `gh pr view <PR> --json files` with retry policy |
| `decisions_count` | `decisions_log | length` |

Any mid-termination `gh` failure follows the GitHub lane policy: retry once after 2s; on second failure, record `gh-cli-unavailable` and include `unknown` for that field rather than throwing away the whole summary.

---

## § 3: Compose GitHub follow-up report

GitHub lane does not have Linear audit relation semantics. It does not create next-cycle Linear recommendations.

Gather only GitHub follow-ups explicitly recorded in `decisions_log` by the child or handler, such as:

- follow-up issue URLs the child opened;
- deferred review suggestions captured by a GitHub handler;
- scope-creep notes that were paused for the user.

Do not infer project/cycle priority. Do not call `project-management`.

---

## § 4: Write summary file

Write `tmp/flightdeck-summary-<SESSION>-<TS>.md`.

When generic entries exist, include generic section first:

```markdown
## Tracked Sessions
| Entry | Kind | State | Harness | Elapsed | Decisions | Last prompt | Answer |
|-------|------|-------|---------|---------|-----------|-------------|--------|
| ...
```

When GitHub entries exist, append:

```markdown
## GitHub Issue Outcomes
| Issue | State | PR | Merge Commit | Worktree | Decisions |
|-------|-------|----|--------------|----------|-----------|
| #<N> | merged | #<PR> | <sha> | <path> | <count> |

## GitHub Follow-ups
- <item or "None recorded">

## GitHub Counts
- Merged: <N>
- Aborted: <N>
- Dead: <N>
- Follow-ups: <N>
```

When Linear entries exist too, append a handoff note that `workflows/linear/terminate.md` owns Linear issue/new-issue/next-cycle recommendation sections.

---

## § 5: Finalize master state

Only finalize after all applicable lane summaries are written.

```bash
flightdeck-state set terminated true
flightdeck-state set terminated_at '"<ISO8601>"'
flightdeck-state set summary_path '"<tmp/flightdeck-summary-<SESSION>-<TS>.md>"'
flightdeck-daemon stop --session "$SESSION"
flightdeck-state archive
```

Do not remove GitHub entries before archive. Archive preserves `decisions_log`, `pr_number`, `merge_commit`, `unknown_since`, and worktree history for dashboard/post-mortem inspection.

---

## § 6: User-visible output

Emit generic block first when applicable, then GitHub block.

<github_output_format>
### ✈️ Flightdeck GitHub issues complete

**Outcomes**

| Issue | State | PR | Merge commit | Decisions |
|-------|-------|----|--------------|-----------|
| #[N] | [merged | aborted | dead] | #[PR or —] | [SHORT_SHA or —] | [N] |

**Follow-ups**
[If follow-ups exist:]
- [FOLLOW_UP]

[If none:]
- None recorded.

**Counts**: [N] merged · [N] aborted · [N] dead · [N] follow-ups

Summary file: `tmp/flightdeck-summary-<SESSION>-<TS>.md`
</github_output_format>

For mixed sessions, emit generic output, then `<github_output_format>`, then the Linear issue output from `linear/terminate.md` if Linear entries exist. Never collapse to a one-liner.

---

## § 7: Pane lifecycle

Do not close additional panes here. `github/close-issue.md` already tore down terminal GitHub issue panes after authoritative PR merge verification. Generic/ad-hoc panes remain available for transcript inspection unless the user explicitly stops/removes them.

## Returns

To the Flightdeck session loop after summary emission and archive.