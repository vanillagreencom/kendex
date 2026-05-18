# Flightdeck schema reference

Reference doc extracted from `SKILL.md`. See [`SKILL.md`](./SKILL.md) for the load-bearing rules; this file holds detailed reference content for on-demand consultation.

## Schema — master state

Master state lives at `<project-root>/<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION_NAME>.json` (default `tmp/`). Activity history lives beside it as `flightdeck-activity-<TMUX_SESSION_NAME>.jsonl` and is exposed through `flightdeck-state activity path|append|tail|export`. Both survive compaction; terminate rotates state to `*-<terminated_at>.json.archive` and activity to `*-<terminated_at>.jsonl.archive` in the same `flightdeck-state archive` flow (see `terminate.md § 6`). The archive preserves the full session history (including merged-issue `decisions_log`, `pr_number`, `merge_commit`) so post-completion dashboards and post-mortem inspection have the whole session history — do not call `pane-registry remove-merged` between `set terminated true` and `archive`. Dashboard snapshot loaders fall back to the newest matching `*.json.archive` when the live file is gone, so the completed-session view keeps rendering until a new `flightdeck linear start` rewrites the live file. Daemon-private files in `FD_STATE_DIR` are keyed by `SESSION_KEY=s<N>` instead (see `patterns/tmux-monitoring.md`).

Auto-archive on session start: `flightdeck-session start` rolls the live file to a `.json.archive` sibling before fresh init when (a) `terminated == true` or (b) the file has tracked entries but ZERO `pane_id` is currently alive in tmux. Removes the need to manually prune leftover state from prior tmux sessions or crashed masters. `flightdeck-session start` also exports `FLIGHTDECK_ENTRY_ID` into the launched child environment (consumed by `github.sh` / `linear.sh` wrappers to auto-bind activity events to the right entry) and captures the current `git rev-parse --abbrev-ref HEAD` of the entry's cwd into `entry.branch` (informational; not refreshed when the agent switches branches mid-session) and onto every `pr.*` activity row's `refs.branch`.

Readers call `readTrackedEntries(state)` to get the canonical `TrackedEntry` map. Malformed non-object entry values are skipped with a stderr warning; malformed internal `entry.id` values warn and fall back to the map key. `writeTrackedEntry(state, id, entry)` validates non-empty ids (including `entry.domain.issue.id` when present), accepts the optional `entry.domain.github_issue` shape, rejects unknown `entry.domain.*` sub-keys, rejects entries that set both `domain.issue` and `domain.github_issue`, and writes `.entries[id]`. Linear issue-mode metadata lives under `entry.domain.issue` (`pr_number`, `worktree`, `merge_commit`, etc.). GitHub issue-mode metadata lives under `entry.domain.github_issue` (`number`, `url`, `worktree`, `pr_number`, `merge_commit`, `scope_files_actual`). Generic `adhoc`/`workflow` rows may also carry top-level `pr_number` and `worktree` for traceability without becoming issue-mode entries; readers must keep those separate from issue-domain routing. Dashboard renderers surface the nested issue views and generic top-level traceability fields without changing issue-domain routing.

```json
{
  "session_id": "<TMUX_SESSION_NAME>",
  "started_at": "<ISO8601>",
  "activity_path": "<project-root>/tmp/flightdeck-activity-<TMUX_SESSION_NAME>.jsonl",
  "activity_archive_path": null,
  "activity_schema_version": 1,
  "terminated": false,
  "owner": {
    "harness": "claude|opencode|codex|pi|unknown",
    "pane_id": "%25",
    "pane_target": "<TMUX_SESSION>:<window>.<pane>",
    "cwd": "<absolute cwd>",
    "pid": 1752875,
    "pi_session_id": "<pi-session-id-or-null>",
    "pi_bridge_socket": "<pi-bridge-socket-or-null>",
    "discovery_error": "<warning-or-null>"
  },
  "entries": {
    "<ENTRY_ID>": {
      "id": "<ENTRY_ID>",
      "title": "<human label>",
      "kind": "adhoc|issue|workflow",
      "state": "waiting|prompting|submitting|ready|complete|cancelled|dead",
      "substate": null,
      "harness": "claude|opencode|codex|pi|unknown",
      "cwd": "<absolute cwd>",
      "window": "<window-name-or-index>",
      "pane_target": "<TMUX_SESSION>:<window>.<pane>",
      "pane_id": "%403",
      "pr_number": null,
      "worktree": null,
      "launch": {
        "model": "<resolved-model-or-null>",
        "effort": "<resolved-effort-or-thinking-or-null>",
        "requested_model": "<explicit-or-env-model-or-null>",
        "requested_effort": "<explicit-or-env-effort-or-null>",
        "resolved_model": "<resolved-model-or-null>",
        "resolved_effort": "<resolved-effort-or-thinking-or-null>",
        "model_source": "explicit|env|auto|null",
        "effort_source": "explicit|env|auto|null",
        "argv": ["<resolved>", "<harness>", "argv>"],
        "reasoning_status": "configured|recorded|unsupported|not-applicable",
        "unsupported_reason": "<reason-or-null>",
        "cmd": "<command-or-null>"
      },
      "adapter": {
        "pi_bridge_pid": 0, "pi_bridge_socket": "<path-or-null>", "pi_session_id": "<id-or-null>",
        "oc_url": "<server-url-or-null>", "oc_session_id": "<id-or-null>",
        "cc_url": "<server-url-or-null>", "cc_transcript": "<path-or-null>",
        "cx_ws": "<ws-url-or-null>", "cx_thread_id": "<id-or-null>"
      },
      "domain": {
        "issue": {
          "id": "<ISSUE_ID>",
          "worktree": "<absolute path>",
          "pr_number": 0,
          "scope_files_declared": 5,
          "scope_files_actual": 27,
          "orchestration_started": true
        },
        "github_issue": {
          "number": 120,
          "url": "https://github.com/OWNER/REPO/issues/120",
          "worktree": "<absolute path>",
          "pr_number": 0,
          "merge_commit": null,
          "scope_files_actual": 27
        }
      },
      "branch": "<git-branch-or-null>",
      "last_capture_hash": "sha256:...",
      "last_response_at": "<ISO8601>",
      "spawned_at": "<ISO8601>",
      "last_polled_at": "<ISO8601>",
      "decisions_log": []
    }
  },
  "merge_queue": ["<ISSUE_ID>", "<ISSUE_ID>"],
  "conflict_graph": {
    "edges": [["<ISSUE_A>", "<ISSUE_B>"]],
    "computed_at": "<ISO8601>"
  },
  "paused_for_user": null
}
```

Tracked entry state enum: `state ∈ {waiting, prompting, submitting, ready, complete, cancelled, dead}`. Issue-mode workflows additionally use `{merge-ready, merged, aborted}` for issue-specific lifecycle states; these map onto the generic enum via `domain.issue.phase` / `domain.issue.outcome` for Linear or `domain.github_issue.phase` / `domain.github_issue.outcome` for GitHub (e.g. `merged → complete + outcome="merged"`). `entryIdForIssue(issueId)` returns the issue id unchanged after validation (empty/invalid ids return null); `issueIdForEntry(entry)` reads `entry.domain.issue.id` or, for `kind: "issue"`, `entry.id`. GitHub entries use numeric `domain.github_issue.number` for lane-specific routing. `owner` is metadata written by `flightdeck-state init`; `owner.pid` is the owner harness PID supplied by `FLIGHTDECK_OWNER_PID` (falling back to parent PID), and `owner.discovery_error` records Pi bridge metadata lookup failures when the owner harness is Pi. Dashboard renderers use `owner.pane_id` to keep the persistent dashboard owner-scoped by default. `paused_for_user` carries `{entry_id|issue_id, reason, prompt_text}` when a guard or issue-mode pause fires.
