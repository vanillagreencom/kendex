# Workflow: `github terminate` — Final Summary + GitHub Issue Unwind

End-of-session unwind for GitHub issue sessions. Routes by tracked-entry kind, writes the summary file, marks master state terminated, archives state, and returns control to flightdeck's session loop. GitHub issue entries produce PR/issue/worktree outcomes; ad-hoc/workflow entries get a generic session summary with no issue-system side effects.

Mode-aware boundary workflow. Generic-only sessions arrive from `workflows/shared/session-watch.md` / `workflows/shared/session-handle-prompt.md`; GitHub issue sessions arrive through `workflows/github/watch.md`, which adds PR state, GitHub issue closure, and worktree cleanup recommendations.

**Inputs**: master state after debounce confirms every tracked entry is terminal enough to end the session.

**Pre-conditions**:
- `session-watch.md` confirmed generic entries are `complete | cancelled | dead` (or intentionally removed from active watch).
- When GitHub issue entries exist, `github/watch.md` § 7 confirmed every tracked issue is terminal (`merged | aborted | dead`) across consecutive poll cycles.

**Post-condition**: `tmp/flightdeck-summary-<SESSION>-<TS>.md` written; `master_state.terminated = true`; user-visible summary block(s) emitted; live state archived.

---

## § 0: Partition tracked entries by kind

Read through the normalized TrackedEntry seam:

```bash
ENTRIES_JSON=$(flightdeck-state tracked-entries)
```

Partition tracked entries by kind:

- `ISSUE_ENTRIES`: entries with `kind == "issue"`, `domain.issue.id`, or issue-shaped markers.
- `GENERIC_ENTRIES`: entries with `kind == "adhoc"`, `kind == "workflow"`, or a future non-issue kind and **no** issue-shaped markers.

Issue-shaped markers are: issue-domain `pr_number`, `worktree`, `merge_commit`, `scope_files_declared`, `scope_files_actual`; issue-only states (`merge-ready`, `merged`, `aborted`); or GitHub issue-only substates (`merge-now`, `bot-review-wait-stuck`, `rebase-multi-choice`, `force-push-prompt`, `cleanup-prompt`, `force-merge-confirm`). If any marker appears without `kind == "issue"` / `domain.issue.id`, emit a warning naming the entry id and markers, then route through `ISSUE_ENTRIES`. This fails closed so malformed issue-shaped entries cannot silently skip PR/issue history.

Routing rules:

1. If `ISSUE_ENTRIES` is non-empty, run the GitHub issue summary path (§§ 2-4).
2. If `ISSUE_ENTRIES` is empty and `GENERIC_ENTRIES` is non-empty, run only the generic session summary path (§ 1). Do not call `gh` or worktree helpers.
3. If both partitions are empty, write the empty-session summary in § 1 and continue finalization. This is an explicit diagnostic, not a silent success.
4. For mixed sessions, run both paths: generic session summary for `GENERIC_ENTRIES`, then GitHub issue summary for `ISSUE_ENTRIES`.

---

## § 1: Compose Generic Session Outcomes

**Skip this section** when `GENERIC_ENTRIES` is empty and `ISSUE_ENTRIES` is non-empty. **Run this section** for an empty tracked-entry set to emit the explicit empty-session diagnostic.

For each generic entry, gather only local state:

| Field | Source |
|-------|--------|
| `id` | entry id |
| `title` | entry title, fallback id |
| `kind` | entry kind (`adhoc`, `workflow`, or future non-issue kind) |
| `state` | `complete | cancelled | dead | ready | ...` |
| `harness` | entry harness |
| `time_elapsed` | `now - entry.spawned_at`, fallback session elapsed |
| `decisions_count` | length of `decisions_log` |
| `last_prompt` | latest `decisions_log[-1].prompt_tag`, if any |
| `last_answer` | latest `decisions_log[-1].answer`, if any |

Generic sessions must not query GitHub, PR state, or worktree metadata. They do not produce issue closure, PR outcomes, or cleanup recommendations. If there are zero tracked entries, write `Session terminated with no tracked entries.` plus zero counts.

---

## § 2: Compose Per-Issue Outcomes

**Skip this section** when `ISSUE_ENTRIES` is empty.

For each GitHub issue entry, gather:

| Field | Source |
|-------|--------|
| `id` | `domain.issue.id` or entry id |
| `title` | `gh issue view <N> --json title`, fallback entry title |
| `issue_state` | `gh issue view <N> --json state` |
| `state` | `merged | aborted | dead` |
| `pr_number` | `domain.issue.pr_number` |
| `pr_state` | `gh pr view <PR> --json state` when PR exists |
| `merge_commit` | cached `domain.issue.merge_commit`; if missing and `state == merged`, `gh pr view <PR> --json mergeCommit` |
| `time_elapsed` | `now - spawned_at` per issue, fallback session elapsed |
| `decisions_count` | length of `decisions_log` |
| `scope_files_actual` | `domain.issue.scope_files_actual`; if missing and PR exists, fetch from `gh pr view --json files` |

GitHub-mode lookups may use `github` wrappers, `gh`, and `worktree` because § 0 already proved at least one tracked issue exists.

---

## § 3: Compose Follow-Up Issue Report

**Skip this section** when `ISSUE_ENTRIES` is empty.

Walk every issue entry's `decisions_log` for entries that captured created GitHub issue numbers during the session. For each captured issue, gather:

| Field | Source |
|-------|--------|
| `id` | created GitHub issue number |
| `title` | `gh issue view <N> --json title` |
| `state` | `gh issue view <N> --json state` |
| `url` | `gh issue view <N> --json url` |
| `creating_session_issue` | which tracked issue caused the follow-up |
| `reason` | captured one-line reason from decision log |

If no follow-up issues were captured, omit the follow-up issue table from user-visible output.

---

## § 4: Compose Worktree Cleanup Recommendations

**Skip this section** when `ISSUE_ENTRIES` is empty.

For each GitHub issue entry, gather:

| Field | Source |
|-------|--------|
| `worktree` | `domain.issue.worktree` |
| `branch` | `entry.branch` or `git -C <worktree> branch --show-current` if worktree exists |
| `remote_branch` | PR head ref from `gh pr view <PR> --json headRefName` |
| `safe_to_remove` | `state == merged` and PR state is `MERGED` and issue state is `CLOSED` |

Recommendations:

1. `safe_to_remove == true` → recommend normal worktree cleanup through the worktree helper.
2. `state == aborted` → recommend manual inspection before cleanup.
3. `state == dead` → recommend inspecting the pane/worktree before cleanup.
4. Do not run destructive cleanup here; this workflow reports only.

---

## § 5: Write Summary File

Emit to `tmp/flightdeck-summary-<SESSION>-<TS>.md` (TS = ISO8601, no colons).

For generic-only sessions or empty sessions, write:

```markdown
# Flightdeck Session Summary — <SESSION> — <ISO8601>

## Tracked Sessions
| Entry | Kind | State | Harness | Elapsed | Decisions | Last prompt | Answer |
|-------|------|-------|---------|---------|-----------|-------------|--------|
| ...

If no tracked entries exist, write this instead of the table rows:

Session terminated with no tracked entries.

## Counts
- Sessions: <N>
- Complete: <N>
- Cancelled: <N>
- Dead: <N>
```

When GitHub issue entries exist, append the GitHub issue sections after any generic section:

```markdown
## GitHub Issue Outcomes
| Issue | Title | State | GitHub State | PR | PR State | Merge Commit | Elapsed | Decisions |
|-------|-------|-------|--------------|----|----------|--------------|---------|-----------|
| ...

## Follow-Up Issues Created
| Issue | Title | State | Created From | Reason |
|-------|-------|-------|--------------|--------|
| ...

## Worktree Cleanup Recommendations
| Issue | Worktree | Branch | Recommendation |
|-------|----------|--------|----------------|
| ...

## GitHub Issue Counts
- Merged: <N>
- Aborted: <N>
- Dead: <N>
- Follow-ups: <N>
- Cleanup ready: <N>
```

---

## § 6: Finalize Master State

```
flightdeck-state set terminated true
flightdeck-state set terminated_at "\"<ISO8601>\""
flightdeck-state set summary_path "\"<tmp/flightdeck-summary-<SESSION>-<TS>.md>\""
flightdeck-daemon stop --session "$SESSION"
flightdeck-state archive
```

Do NOT remove terminal entries before archive. The archive preserves the full `.entries` map for post-mortem inspection and dashboard rendering.

---

## § 7: User-Visible Output

Emit the full applicable summary block(s) inline. Do not collapse to a single line. Per SKILL.md "Format Tags Are Literal": fill placeholders, omit empty sections, add nothing else.

For generic entries, emit this block when `GENERIC_ENTRIES` is non-empty:

<generic_output_format>
### ✈️ Flightdeck sessions complete

**Tracked sessions**

| Entry | Kind | State | Harness | Decisions |
|-------|------|-------|---------|-----------|
| [ENTRY_ID] | [adhoc|workflow|other] | [complete|cancelled|dead|ready|...] | [HARNESS] | [N] |

**Counts**: [N] sessions · [N] complete · [N] cancelled · [N] dead

Summary file: `tmp/flightdeck-summary-<SESSION>-<TS>.md`
</generic_output_format>

If no tracked entries exist, emit this explicit diagnostic block:

<empty_output_format>
### ✈️ Flightdeck session complete

Session terminated with no tracked entries.

**Counts**: 0 sessions · 0 complete · 0 cancelled · 0 dead

Summary file: `tmp/flightdeck-summary-<SESSION>-<TS>.md`
</empty_output_format>

For GitHub issue entries, emit this block only when `ISSUE_ENTRIES` is non-empty:

<github_issue_output_format>
### ✈️ Flightdeck GitHub session complete

**Outcomes**

| Issue | Title | State | GitHub state | PR | PR state | Merge commit | Decisions |
|-------|-------|-------|--------------|----|----------|--------------|-----------|
| #[ISSUE_ID] | [TITLE] | [merged | aborted | dead] | [OPEN|CLOSED|—] | #[N] | [MERGED|CLOSED|OPEN|—] | [SHORT_SHA] | [N] |

**Follow-up issues created this session**

| Issue | Title | State | Created from | Reason |
|-------|-------|-------|--------------|--------|
| #[ISSUE_ID] | [TITLE] | [OPEN|CLOSED] | #[SOURCE_ISSUE] | [REASON] |

**Worktree cleanup recommendations**

| Issue | Worktree | Branch | Recommendation |
|-------|----------|--------|----------------|
| #[ISSUE_ID] | [PATH] | [BRANCH] | [SAFE_TO_REMOVE or INSPECT_FIRST] |

**Counts**: [N] merged · [N] aborted · [N] dead · [N] follow-ups · [N] cleanup ready

Summary file: `tmp/flightdeck-summary-<SESSION>-<TS>.md`
</github_issue_output_format>

For mixed sessions, emit `<generic_output_format>` first, then `<github_issue_output_format>`. For empty sessions, emit only `<empty_output_format>`. Sections with no data (for example, no follow-up issues) are omitted entirely per the format-tags rule. Never substitute a one-liner.

---

## § 8: Pane Lifecycle

Do **not** close any additional panes here. Terminal GitHub issue windows were already closed by `close-issue.md` after the two-signal check; generic/ad-hoc windows remain available for transcript inspection or manual resume unless the user explicitly runs `session stop` / `session remove`.

§ 6's `flightdeck-state archive` rotated the live state away, so a subsequent `github start` (or `github watch`) in the same tmux session creates a fresh master-state file — no stale entries or `terminated` flag carryover. Past sessions remain inspectable via `tmp/flightdeck-state-<SESSION>-<TS>.json.archive` and the summary file.

---

## Returns

To flightdeck's session loop (`workflows/github/start.md` or `workflows/shared/session-watch.md`), after summary emission and state archive.
