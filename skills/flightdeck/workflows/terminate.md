# Workflow: `terminate` — Final Summary + Next-Cycle Recommendation

End-of-session unwind. Composes a per-issue summary, the new-issues report, and a next-cycle recommendation. Marks master state terminated. Returns control to flightdeck's dashboard.

**Inputs**: master state (every tracked issue is `merged | aborted | dead`; debounce satisfied).

**Pre-conditions**: `watch.md` § 6 confirmed all-done across consecutive poll cycles.

**Post-condition**: `tmp/flightdeck-summary-<SESSION>-<TS>.md` written; `master_state.terminated = true`; user-visible summary line emitted; control returned to flightdeck's dashboard loop (`workflows/start.md` § 1).

---

## § 1: Compose Per-Issue Outcomes

For each tracked issue, gather:

| Field | Source |
|-------|--------|
| `id` | registry key |
| `state` | `merged | aborted | dead` |
| `pr_number` | registry |
| `merge_commit` | `gh pr view <PR> --json mergeCommit` (when `state == merged`) |
| `time_elapsed` | `now - master_state.started_at` per-issue if tracked, else session-level |
| `decisions_count` | length of `decisions_log` |
| `scope_files_declared` | registry |
| `scope_files_actual` | registry (or fetch from `gh pr view --json files`) |

---

## § 2: Compose New-Issues Report

Walk every issue's `decisions_log` for `audit-relation-prompt` entries. For each created issue captured during the session, gather:

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

## § 3: Compose Next-Cycle Recommendation

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

## § 4: Write Summary File

Emit to `tmp/flightdeck-summary-<SESSION>-<TS>.md` (TS = ISO8601, no colons):

```markdown
# Flightdeck Session Summary — <SESSION> — <ISO8601>

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

## Counts
- Merged: <N>
- Aborted: <N>
- New issues (children): <N>
- New issues (follow-ups): <N>
- Recommended next: <N>
```

---

## § 5: Finalize Master State

```
flightdeck-state set terminated true
flightdeck-state set terminated_at "\"<ISO8601>\""
flightdeck-state set summary_path "\"<tmp/flightdeck-summary-<SESSION>-<TS>.md>\""
flightdeck-daemon stop --session "$SESSION"
flightdeck-state archive
```

Do NOT call `pane-registry remove-merged` here. Earlier revisions did, but `close-issue.md § 4` has already killed every terminal-state issue's tmux window by the time terminate runs, so `remove-merged` would unconditionally delete every `merged|aborted|dead` issue's history — including `decisions_log`, `pr_number`, and `merge_commit` — from the file that is about to be archived. The pi-flightdeck dashboard depends on those records to render the post-completion `Overview`, `Decisions`, and `Conflicts & merges` tabs; deleting them collapses the dashboard to an empty `0 issues` state immediately after a successful session. The archive's value is precisely the full session history (see [[issue-17]]).

`flightdeck-daemon stop` terminates the external wake daemon (validates PID + flock holder before killing; refuses on stale PID file). `archive` rotates the live state file to `tmp/flightdeck-state-<SESSION>-<terminated_at>.json.archive` so the next session in the same tmux name (e.g. `HT`) starts clean instead of inheriting this session's `issues` map, `merge_queue`, and `terminated` flag. The archive preserves the full `.issues` map (including merged-issue `decisions_log`, `pr_number`, `merge_commit`) for post-mortem inspection and dashboard rendering.

---

## § 6: User-Visible Output

Emit the full session summary inline using the `<output_format>` block below. Do not collapse to a single line. Do not skip the new-issues table when issues were created. Do not skip the next-cycle recommendation when § 3 produced one. Per SKILL.md "Format Tags Are Literal": fill placeholders, omit empty sections, add nothing else.

<output_format>
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

[For each recommended issue from § 3:]
- **[ISSUE_ID]** ([PRIORITY], [PROJECT]) — [ONE_LINE_RATIONALE]

[Or, if no follow-ups warrant precedence:]
- Stick with planned cycle — no created issues warrant precedence.

**Counts**: [N] merged · [N] aborted · [N] children · [N] follow-ups · [N] recommended next

Summary file: `tmp/flightdeck-summary-<SESSION>-<TS>.md`
</output_format>

Sections with no data (e.g., no children created, no standalone follow-ups, no recommendations) are omitted entirely per the format-tags rule. Never substitute a one-liner.

---

## § 7: Launch Recommended Follow-ups

**Skip if** § 3 produced an empty recommendation list.

Ask the user whether to launch any of the recommended follow-ups now and continue the flightdeck session. The new issue(s) are spawned via `start.md`'s spawn path; the watch loop resumes with the new pane(s) added to the registry.

Use the harness's user-question primitive (Claude Code: `AskUserQuestion`) with options derived from § 3's recommendation list:

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
4. Re-enter `watch.md § 2`. Do NOT proceed to § 8 (Pane Lifecycle) — session continues.

On "Stick with planned cycle / Done": proceed to § 8.

---

## § 8: Pane Lifecycle

Do **not** close any additional panes here. Terminal issue windows were already closed by `close-issue.md` after the two-signal check; any remaining paused/non-terminal panes stay with the user so they can inspect transcripts or resume manually.

§ 5's `flightdeck-state archive` rotated the live state away, so a subsequent `flightdeck start` (or bare `watch`) in the same tmux session creates a fresh master-state file — no stale `issues` / `merge_queue` carryover. Past sessions remain inspectable via `tmp/flightdeck-state-<SESSION>-<TS>.json.archive` (full `.issues` history, including merged-issue `decisions_log` / `pr_number` / `merge_commit`) and the summary file. pi-flightdeck's `buildSnapshot` falls back to the newest `flightdeck-state-<SESSION>-*.json.archive` with `terminated: true` whenever the live file is missing for the current `$TMUX` session name, so the dashboard, Overview, Decisions, and Conflicts & merges tabs keep rendering the completed session until the user dismisses the widget via `Alt+M` or a new `flightdeck start` writes a fresh live file.

---

## Returns

To flightdeck's dashboard loop (`workflows/start.md` § 1).
