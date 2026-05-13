# Workflow: `terminate` — Final Summary + Mode-Aware Unwind

End-of-session unwind. Routes by tracked-entry kind, writes the summary file, marks master state terminated, archives state, and returns control to flightdeck's dashboard. Issue entries keep the existing issue/PR/new-issue recommendation behavior from this markdown workflow; ad-hoc/workflow entries get a generic session summary with no issue-system side effects. Any TS helper under `lib/flightdeck-core/src/terminate/` owns the generic/empty summary path only — never replace the issue/PR/new-issue recommendation path with hard-coded TS output.

Mode-aware boundary workflow. Generic-only sessions arrive from `workflows/session-watch.md` / `workflows/session-handle-prompt.md`; issue or mixed sessions arrive through `workflows/watch.md`, which adds issue summaries, merge history, and follow-up recommendations.

**Inputs**: master state after debounce confirms every tracked entry is terminal enough to end the session.

**Pre-conditions**:
- `session-watch.md` confirmed generic entries are `complete | cancelled | dead` (or intentionally removed from active watch).
- When issue entries exist, `watch.md` § 7 confirmed every tracked issue is terminal (`merged | aborted | dead`) across consecutive poll cycles.

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

Issue-shaped markers are: legacy/top-level `pr_number`, `worktree`, `merge_commit`, issue-domain `pr_number`, `worktree`, `merge_commit`, `scope_files_declared`, `scope_files_actual`, `orchestration_started`, issue-only states (`merge-ready`, `merged`, `aborted`), or issue-only substates (`merge-now`, `audit-relation-prompt`, `bot-review-wait-stuck`, `rebase-multi-choice`, `force-push-prompt`, `cleanup-prompt`, `stale-no-pr-branch`, `stale-orphan-worktree`, `descope-related`, `scope-creep-detected`, fix-suggestion tags). If any marker appears without `kind == "issue"` / `domain.issue.id`, emit a warning naming the entry id and markers, then route through `ISSUE_ENTRIES`. This fails closed so malformed issue-shaped entries cannot silently skip merge/new-issue history.

Routing rules:

1. If `ISSUE_ENTRIES` is non-empty, run the issue summary path (§§ 2-4) and preserve the current issue/PR/new-issue recommendation summary behavior.
2. If `ISSUE_ENTRIES` is empty and `GENERIC_ENTRIES` is non-empty, run only the generic session summary path (§ 1). Do not call `gh`, `linear`, worktree helpers, merge planning, or `project-management`.
3. If both partitions are empty, write the empty-session summary in § 1 and continue finalization. This is an explicit diagnostic, not a silent success.
4. For mixed sessions, run both paths: generic session summary for `GENERIC_ENTRIES`, then issue/PR/new-issue recommendation summary for `ISSUE_ENTRIES`.

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

Generic sessions must not query GitHub, Linear, PR state, worktree metadata, or project-management workflows. They do not produce merge ordering, issue cleanup, new issue reports, or next-cycle recommendations. If there are zero tracked entries, write `Session terminated with no tracked entries.` plus zero counts.

---

## § 2: Compose Per-Issue Outcomes

**Skip this section** when `ISSUE_ENTRIES` is empty.

For each issue entry, gather:

| Field | Source |
|-------|--------|
| `id` | `domain.issue.id` or legacy registry key |
| `state` | `merged | aborted | dead` |
| `pr_number` | `domain.issue.pr_number` / legacy registry |
| `merge_commit` | cached `domain.issue.merge_commit` / legacy `merge_commit`; if missing and `state == merged`, `gh pr view <PR> --json mergeCommit` |
| `time_elapsed` | `now - spawned_at` per issue, fallback session elapsed |
| `decisions_count` | length of `decisions_log` |
| `scope_files_declared` | `domain.issue.scope_files_declared` / legacy registry |
| `scope_files_actual` | `domain.issue.scope_files_actual` / legacy registry; if missing and PR exists, fetch from `gh pr view --json files` |

Issue-mode lookups may use `github`, `linear`, `worktree`, and `project-management` because § 0 already proved at least one tracked issue exists.

---

## § 3: Compose New-Issues Report

**Skip this section** when `ISSUE_ENTRIES` is empty.

Walk every issue entry's `decisions_log` for `audit-relation-prompt` entries. For each created issue captured during the session, gather:

| Field | Source |
|-------|--------|
| `id` | the new issue's id |
| `title` | from Linear (cached at creation time) |
| `parent` | parent issue id, or `null` |
| `project` | Linear project name |
| `priority` | Linear priority |
| `relation_kind` | `child` (parent absorbed it into the parent's PR) or `follow-up` (related/standalone) |
| `creating_session_issue` | which tracked issue's audit produced this new issue |

Group by `relation_kind`:
- **Children absorbed into parent PR** — these landed in the parent's branch and are already merged (or aborted with the parent).
- **Standalone follow-ups** — unblocked work that was deferred for separate handling.

---

## § 4: Compose Next-Cycle Recommendation

**Skip this section** when `ISSUE_ENTRIES` is empty.

For each standalone follow-up (the `relation_kind: follow-up` set):

1. Compare its priority and tags to the user's current cycle / todo set:
   ```
   linear issues list --status Todo --max 100
   linear issues list --cycle current --max 100
   ```
2. Recommend picking up a follow-up before existing cycle/todo work iff at least one of:
   - The follow-up's priority is higher than any current-cycle issue.
   - The follow-up blocks an issue already in the current cycle (`linear issues list-relations <follow-up>` shows blocking edge).
   - The follow-up represents a critical discovery from this session (e.g., a P2 from a `bot-review-wait-stuck` cleanup, a scope-creep correction).
3. Build the recommendation list with one-line rationale per recommended issue.

If no follow-ups warrant precedence, the recommendation is "stick with planned cycle".

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

When issue entries exist, append the existing issue-mode sections after any generic section:

```markdown
## Outcomes
| Issue | State | PR | Merge Commit | Elapsed | Decisions |
|-------|-------|----|--------------|---------|-----------|
| ...

## New Issues Created
### Children absorbed into parent PRs
| Issue | Title | Parent | Project | Priority |
|-------|-------|--------|---------|----------|
| ...

### Standalone follow-ups
| Issue | Title | Project | Priority |
|-------|-------|---------|----------|
| ...

## Next-Cycle Recommendation
- **Pick up next**: <ISSUE> — <one-line rationale>
- **Pick up next**: <ISSUE> — <one-line rationale>
... or "Stick with planned cycle — no created issues warrant precedence."

## Issue Counts
- Merged: <N>
- Aborted: <N>
- New issues (children): <N>
- New issues (follow-ups): <N>
- Recommended next: <N>
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

Do NOT call `pane-registry remove-merged` here. Earlier revisions did, but `close-issue.md § 4` has already killed every terminal-state issue's tmux window by the time terminate runs, so `remove-merged` would unconditionally delete every `merged|aborted|dead` issue's history — including `decisions_log`, `pr_number`, and `merge_commit` — from the file that is about to be archived. The pi-flightdeck dashboard depends on those records to render the post-completion `Overview`, `Decisions`, and `Conflicts & merges` tabs; deleting them collapses the dashboard to an empty `0 issues` state immediately after a successful session. The archive's value is precisely the full session history (see [[issue-17]]).

`flightdeck-daemon stop` terminates the external wake daemon (validates PID + flock holder before killing; refuses on stale PID file). `archive` rotates the live state file to `tmp/flightdeck-state-<SESSION>-<terminated_at>.json.archive` so the next session in the same tmux name (e.g. `HT`) starts clean instead of inheriting this session's entries, issue map, merge queue, and `terminated` flag. The archive preserves the full `.entries` map and full `.issues` map for post-mortem inspection and dashboard rendering.

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

For issue entries, emit the existing issue summary block only when `ISSUE_ENTRIES` is non-empty:

<issue_output_format>
### ✈️ Flightdeck session complete

**Outcomes**

| Issue | State | PR | Merge commit | Decisions |
|-------|-------|----|--------------|-----------|
| [ISSUE_ID] | [merged | aborted | dead] | #[N] | [SHORT_SHA] | [N] |

**Issues created this session**

Children absorbed into parent PRs:
| Issue | Title | Parent | Project | Priority |
|-------|-------|--------|---------|----------|
| [ISSUE_ID] | [TITLE] | [PARENT_ID] | [PROJECT] | [PRIORITY] |

Standalone follow-ups:
| Issue | Title | Project | Priority | Linear state |
|-------|-------|---------|----------|--------------|
| [ISSUE_ID] | [TITLE] | [PROJECT] | [PRIORITY] | [Backlog | Todo] |

**Next-cycle recommendation**

[For each recommended issue from § 4:]
- **[ISSUE_ID]** ([PRIORITY], [PROJECT]) — [ONE_LINE_RATIONALE]

[Or, if no follow-ups warrant precedence:]
- Stick with planned cycle — no created issues warrant precedence.

**Counts**: [N] merged · [N] aborted · [N] children · [N] follow-ups · [N] recommended next

Summary file: `tmp/flightdeck-summary-<SESSION>-<TS>.md`
</issue_output_format>

For mixed sessions, emit `<generic_output_format>` first, then `<issue_output_format>`. For empty sessions, emit only `<empty_output_format>`. Sections with no data (e.g., no children created, no standalone follow-ups, no recommendations) are omitted entirely per the format-tags rule. Never substitute a one-liner.

---

## § 8: Launch Recommended Follow-ups

**Skip if** `ISSUE_ENTRIES` is empty or § 4 produced an empty recommendation list.

Ask the user whether to launch any of the recommended follow-ups now and continue the flightdeck issue session. The new issue(s) are spawned via `start.md`'s spawn path; the watch loop resumes with the new pane(s) added to the registry.

Use the harness's user-question primitive (Claude Code: `AskUserQuestion`) with options derived from § 4's recommendation list:

<launch_now_format>
**Launch follow-ups now?**

Recommended issues from this session:
[For each recommended issue:]
- [ISSUE_ID] — [TITLE]

Options:
- Launch [ISSUE_ID] (one option per recommended issue)
- Launch all recommended
- Stick with planned cycle / Done
</launch_now_format>

On launch:
1. For each issue chosen, if its Linear state is `Backlog`, promote to `Todo` first:
   ```
   linear issues update <ISSUE_ID> --status Todo
   ```
2. Invoke the spawn path: `⤵ workflows/start.md § 1.4 → § 5` (or equivalent — same flow `flightdeck start <ISSUE_ID>` would take).
3. The new pane is added to the registry; the watch loop's next cycle picks it up.
4. Re-enter `watch.md § 2`. Do NOT proceed to § 9 (Pane Lifecycle) — session continues.

On "Stick with planned cycle / Done": proceed to § 9.

---

## § 9: Pane Lifecycle

Do **not** close any additional panes here. Terminal issue windows were already closed by `close-issue.md` after the two-signal check; generic/ad-hoc windows remain available for transcript inspection or manual resume unless the user explicitly runs `session stop` / `session remove`.

§ 6's `flightdeck-state archive` rotated the live state away, so a subsequent `flightdeck start` (or bare `watch`) in the same tmux session creates a fresh master-state file — no stale entries, issue map, merge queue, or `terminated` flag carryover. Past sessions remain inspectable via `tmp/flightdeck-state-<SESSION>-<TS>.json.archive` and the summary file. pi-flightdeck's `buildSnapshot` falls back to the newest `flightdeck-state-<SESSION>-*.json.archive` with `terminated: true` whenever the live file is missing for the current `$TMUX` session name, so the dashboard keeps rendering the completed session until the user dismisses the widget via `Alt+M` or a new `flightdeck start` writes a fresh live file.

---

## Returns

To flightdeck's dashboard loop (`workflows/start.md` or `workflows/session-watch.md`), after summary emission and state archive.
