# Flightdeck schema reference

Reference doc extracted from `SKILL.md`. See [`SKILL.md`](./SKILL.md) for the load-bearing rules; this file holds detailed reference content for on-demand consultation.

## Schema — master state

Master state lives at `<project-root>/<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION_NAME>.json` (default `tmp/`). Activity history lives beside it as `flightdeck-activity-<TMUX_SESSION_NAME>.jsonl` and is exposed through `flightdeck-state activity path|append|tail|export`. Both survive compaction; terminate rotates state to `*-<terminated_at>.json.archive` and activity to `*-<terminated_at>.jsonl.archive` in the same `flightdeck-state archive` flow (see `terminate.md § 6`). The archive preserves the full session history (including merged-issue `decisions_log`, `pr_number`, `merge_commit`) so post-completion dashboards and post-mortem inspection have the whole session history — do not call `pane-registry remove-merged` between `set terminated true` and `archive`. Dashboard startup no longer falls back to the newest matching `*.json.archive` when no active durable run exists; it shows a no-active-run state and requires explicit History (`H`), `--run-id`, or `--archive` selection for archived data. Daemon-private files in `FD_STATE_DIR` are keyed by `SESSION_KEY=s<N>` instead (see `patterns/tmux-monitoring.md`).

## Schema — durable run store

Durable run history lives outside project `tmp/` so it survives cleanup:

```text
~/.vstack/flightdeck/projects/<project-id>/
  project.json
  active-run.json                 # optional
  runs/
    <run-id>/
      metadata.json
      state.json
      activity.jsonl
      summary.md                  # optional
      snapshots/
        <timestamp>.json
        <timestamp>.activity.jsonl
```

`<project-id>` is stable and human-safe. With Git remotes, the id is based on `remote.origin.url` when present, otherwise the first configured remote, plus a SHA-256 hash of the absolute project root. Without a remote it falls back to the absolute project-root hash. The human-readable prefix comes from the remote repo name or project directory name. Durable readers derive the current project identity from the resolved project root and reject mutable `project.json` contents that do not match that context.

`project.json`:

```jsonc
{
  "schema_version": 1,
  "project_id": "<safe-name>-<16hex>",
  "name": "<display-name>",
  "root_path": "<absolute-project-root>",
  "root_hash": "<sha256-root-path>",
  "remote_url": "<git-remote-or-null>",
  "id_source": "git-remote+root|root",
  "created_at": "<ISO8601>",
  "last_seen_at": "<ISO8601>"
}
```

`active-run.json` is absent when no run is active:

```jsonc
{
  "schema_version": 1,
  "project_id": "<project-id>",
  "run_id": "<run-id>",
  "tmux_session": "<TMUX_SESSION_NAME>",
  "state_path": "<absolute-home>/.vstack/flightdeck/projects/<project-id>/runs/<run-id>/state.json",
  "activity_path": "<absolute-home>/.vstack/flightdeck/projects/<project-id>/runs/<run-id>/activity.jsonl",
  "updated_at": "<ISO8601>"
}
```

`metadata.json`:

```jsonc
{
  "schema_version": 1,
  "project_id": "<project-id>",
  "run_id": "<run-id>",
  "project_root": "<absolute-project-root>",
  "tmux_session": "<TMUX_SESSION_NAME>",
  "state_path": "<durable-run>/state.json",
  "activity_path": "<durable-run>/activity.jsonl",
  "summary_path": null,
  "snapshots_path": "<durable-run>/snapshots",
  "started_at": "<ISO8601>",
  "last_seen_at": "<ISO8601>",
  "terminated": false,
  "terminated_at": null,
  "imported": false,
  "imported_from": null,
  "legacy_activity_path": null
}
```

`flightdeck-state run create` writes `metadata.json`, `state.json`, `activity.jsonl`, and `active-run.json`. `flightdeck-state run ensure` is the lifecycle entry point used by `flightdeck-session start` / `attach`: it reuses a non-terminated active run only when the active pointer and metadata both match the requested tmux session, creates one when none exists, creates a fresh one when the active run is already terminated, and finalizes a stale active run before creating a replacement only after tmux liveness succeeds and every recorded pane id is absent. It fails closed on active-session mismatch, missing active metadata, or tmux liveness failure. Durable readers validate `metadata.json` against its containing project and requested/path-derived run id before returning or mutating a run. `run terminate` sets `terminated=true`, writes `terminated_at`, creates a final `snapshots/<timestamp>.json`, copies a matching activity snapshot when present, copies `summary_path` / `--summary-path` to the run `summary.md` when the summary file is present under the project root, and clears `active-run.json` only when it still points at the requested run. Invalid explicit `--summary-path` values fail with diagnostics; invalid optional `state.summary_path` values warn and continue. `run terminate-active --tmux-session <name>` applies the same termination path only when both the active pointer and run metadata match the requested tmux session, and syncs the matching project-local state/activity before the final durable snapshot. `run import-legacy` copies `flightdeck-state-*.json.archive` and matching activity archives into deterministic imported run ids without deleting source archives.

Auto-archive on session start: `flightdeck-session start` and `attach` roll the live file to a `.json.archive` sibling before fresh init when (a) `terminated == true`, (b) the file has tracked entries with at least one recorded `pane_id`, tmux liveness was queried successfully, and ZERO recorded `pane_id` values are currently alive in tmux, or (c) the file has no `.entries` map but a legacy pre-purge `.issues` map exists. No-pane graph rows, such as dependency-blocked plan items waiting for their first spawn, are not stale. If the tmux liveness query or archive command fails, `start` / `attach` abort before creating/reusing a durable run or spawning/attaching a new entry. If a later pre-registration launch step fails after `run ensure` created a fresh active run, the launcher terminates that new run and clears its active pointer; reused active runs are not rolled back. The archive command first emits completion activity, terminates the matching active durable run, syncs the project-local state/activity into the durable run snapshot, clears the active pointer, then leaves the legacy `.json.archive` / `.jsonl.archive` files readable for old tooling. Dashboard self-launch is the only start-path exception: it passes `--no-active-run` / `FLIGHTDECK_SKIP_ACTIVE_RUN=1`, registers the `flightdeck-dashboard` entry, and intentionally does not create a user active run. This removes the need to manually prune leftover state from prior tmux sessions or crashed masters. `flightdeck-session start` also exports `FLIGHTDECK_ENTRY_ID` into the launched child environment (consumed by `github.sh` / `linear.sh` wrappers to auto-bind activity events to the right entry) and captures the current `git rev-parse --abbrev-ref HEAD` of the entry's cwd into `entry.branch` (informational; not refreshed when the agent switches branches mid-session) and onto every `pr.*` activity row's `refs.branch`.

Readers call `readTrackedEntries(state)` to get the canonical `TrackedEntry` map. Malformed non-object entry values are skipped with a stderr warning; malformed internal `entry.id` values warn and fall back to the map key. The `flightdeck-state tracked-entries` CLI uses strict plan-item validation and exits non-zero instead of silently omitting invalid `domain.plan_item` entries, so plan/pane workflows fail loud on unsafe brief metadata. `writeTrackedEntry(state, id, entry)` validates non-empty ids (including `entry.domain.issue.id` and `entry.domain.plan_item.item_id` when present), accepts the optional `entry.domain.github_issue` and `entry.domain.plan_item` shapes, rejects unknown `entry.domain.*` sub-keys, rejects entries that set more than one of `domain.issue`, `domain.github_issue`, or `domain.plan_item`, and writes `.entries[id]`. Linear issue-mode metadata lives under `entry.domain.issue` (`pr_number`, `worktree`, `merge_commit`, etc.). GitHub issue-mode metadata lives under `entry.domain.github_issue` (`number`, `url`, `worktree`, `pr_number`, `merge_commit`, `scope_files_actual`). Plan-file metadata lives under `entry.domain.plan_item` (`plan_path`, `plan_title`, `item_id`, `item_title`, `depends_on`, `worktree`, `pr_number`, `merge_commit`, plus immutable brief fields `parse_mode`, `plan_snapshot_sha256`, `brief_artifact_path`, `brief_sha256`, and optional `omitted_context`). New plan-lane entries must write those immutable brief fields after dry-run confirmation so dependency-spawned items consume the sanitized artifact instead of rereading a mutable plan file; legacy entries without them are read for compatibility, but dependent spawns require the artifact fields. `brief_artifact_path` must be an absolute normalized path under the canonical state-owned root `<project-root>/<FLIGHTDECK_STATE_DIR or tmp>/plan-briefs/.../<item_id>.md`, not merely any path containing a `plan-briefs` segment. Validators reject control characters, traversal, wrong filename, paths outside the canonical brief root (including missing paths outside it), symlinked state directories or `plan-briefs` roots, and symlink escape; they also require `plan_snapshot_sha256` whenever a brief path/hash is stored. Generic `adhoc`/`workflow` rows may also carry top-level `pr_number` and `worktree` for traceability without becoming domain-routed entries; readers must keep those separate from Linear/GitHub/plan domain routing. Dashboard renderers surface the nested domain views and generic top-level traceability fields without changing domain routing.

```jsonc
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
      "window_name_current": "<current-tmux-window-name-or-null>",
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
        "oc_url": "<server-url-or-null>", "oc_session_id": "<id-or-null>", "oc_port": 0,
        "cc_url": "<server-url-or-null>", "cc_transcript": "<path-or-null>",
        "cc_session_uuid": "<uuid-or-null>", "cc_port": 0,
        "cc_channel_token": "<bearer-token-or-null>",
        "cx_ws": "<ws-url-or-null>", "cx_thread_id": "<id-or-null>"
      },
      "domain": {
        // Exactly one of these keys may be present on a single entry.
        "issue": {
          "id": "<ISSUE_ID>",
          "worktree": "<absolute path>",
          "pr_number": 0,
          "scope_files_declared": 5,
          "scope_files_actual": 27,
          "orchestration_started": true
        }
        // Alternative for GitHub issue lane:
        // "github_issue": {
        //   "number": 120,
        //   "url": "https://github.com/OWNER/REPO/issues/120",
        //   "worktree": "<absolute path>",
        //   "pr_number": 0,
        //   "merge_commit": null,
        //   "scope_files_actual": 27
        // }
        // Alternative for plan lane:
        // "plan_item": {
        //   "plan_path": "<absolute plan path>",
        //   "plan_snapshot_sha256": "sha256:<64-hex frozen plan text hash>",
        //   "plan_title": "<plan title>",
        //   "item_id": "<item-id>",
        //   "item_title": "<item title>",
        //   "depends_on": ["<item-id>"],
        //   "worktree": "<absolute path>",
        //   "parse_mode": "explicit-items|inferred-items|mixed-items", // legacy rows may say h2-items or phase-style
        //   "brief_artifact_path": "<absolute sanitized item brief artifact path>",
        //   "brief_sha256": "sha256:<64-hex sanitized brief hash>",
        //   "omitted_context": ["<supervisor-only context title/label sanitized from child brief>"],
        //   "pr_number": 0,
        //   "merge_commit": null,
        //   "scope_files_actual": 27
        // }
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

`entry.window_name_current` is optional live tmux metadata refreshed from `tmux display-message -p -t <pane> '#W'` by `pane-poll` callers and the daemon reconcile loop. Dashboard title rendering prefers this current window name over the original spawn `title` when present.

`entry.pane_id` (the tmux `%NNN` id) is the source of truth for tracked entries. tmux allocates it once and keeps it stable for the life of the pane. `entry.pane_target` / `entry.window` / `entry.window_index` are cached views of `pane_id`'s current location and go stale whenever tmux renumbers windows (close, swap, move). `pane-registry refresh-window-names` recomputes `pane_target` and `window_index` from a live tmux snapshot whenever the entry's `pane_id` still resolves to a live pane at different coords; `entry.window` is also refreshed when its stored value is numeric (the form `flightdeck-session` writes — `--window <window_index>`), while legacy entries that stored a window-name string keep their name because tmux renumbers never change a window's name. The refresh runs on every daemon reconcile tick, on every `pane-registry reconcile`, and after every `flightdeck-session start` / `attach`. Callers that already hold a `%pane_id` (`pane-respond`, `pane-poll`) prefer a live `tmux display-message -p -t <%pane_id>` lookup over the registry's cached target so a renumber-staled `pane_target` can't misroute the operation; `pane-clear-bell` takes a window-target string and does not resolve a `%pane_id` itself, but `pane-respond` derives the window-target it passes from its already-live target so the bell clear inherits the same safety.

### Pi-subscriber binder required fields

The `flightdeck-daemon` pi-subscriber binder reads adapter metadata from `pane-registry list --format json` (the flattened view that surfaces `entry.adapter.*` at the top level). For `harness="pi"` entries the daemon requires `entry.cwd` and `entry.adapter.pi_session_id` (both hard requirements; missing either skips the bind). `entry.adapter.pi_bridge_pid` and `entry.adapter.pi_bridge_socket` are persisted as a fast-path: when present and live, the daemon binds directly; when missing or stale, it discovers candidates via `pi-bridge list` filtered by `cwd` + `pi_session_id` and validates each via `validateCandidate` (see `lib/flightdeck-core/src/daemon/pi-binding.ts`). Discovery costs an extra `pi-bridge list` round-trip per reconcile tick and one `[pi-subscriber-bind-skip]` log row throttled by `FD_PI_BIND_SKIP_LOG_INTERVAL_SEC`, so launch paths SHOULD still persist all three fields up front:

- `flightdeck-session start --prompt --harness pi` resolves them through `pi_discover_after_launch` and passes them to `pane-registry init-entry` as `--pi-bridge-pid` / `--pi-bridge-socket` / `--pi-session-id`.
- `flightdeck-session attach --harness pi` resolves them through `pi_discover_for_pane` and follows the same `register_entry` path.
- `scripts/open-terminal`'s `spawn_pi_bridge_tmux` writes `pi-spawn-<issue>.json` AFTER `pane-registry init-entry` runs (the pid is only known once Pi is up), so it must invoke `pane-registry hydrate-pi <issue>` immediately after the spawn file is written to copy the discovered metadata into `.entries[id].adapter.*`.

New launch paths (Codex JSON-RPC adapter for Pi, future per-pane Pi attach commands, etc.) MUST land their adapter fields through one of these routes, not assume the daemon will re-discover from `pi-bridge list` independently.

`entry.adapter` writes that affect more than one field (e.g. `pane-registry hydrate-pi` writing `pi_bridge_pid` + `pi_bridge_socket` + `pi_session_id` together) MUST go through `flightdeck-state write-entry` so the daemon's reconcile read never observes a half-hydrated entry; chaining multiple `flightdeck-state set` calls is not atomic across the registry lock.

### Claude / OpenCode / Codex subscriber binder required fields (vstack#216)

The daemon's per-harness subscriber binders read the same flattened adapter view used by the pi binder above. Each harness has a hard-required field set; missing any of them causes the binder to emit `[<harness>-subscriber-bind-skip]` (throttled by `FD_SUB_BIND_SKIP_LOG_INTERVAL_SEC`, default 60s) and, after `FD_SUB_BIND_SKIP_STUCK_THRESHOLD` consecutive misses (default 12), a one-shot `[<harness>-subscriber-bind-stuck]` warning naming the missing fields.

| Harness | Required adapter fields | Optional |
| --- | --- | --- |
| `claude` | `cc_url`, `cc_transcript`, `cc_session_uuid`, `cc_port` | `cc_channel_token` (bearer auth on webhook POSTs; absence keeps webhook in legacy-accept mode) |
| `opencode` | `oc_url`, `oc_session_id` | `oc_port` |
| `codex` | `cx_ws`, `cx_thread_id` | — |
| `pi` | see "Pi-subscriber binder required fields" above | — |

`scripts/open-terminal`'s `spawn_cc_channel_tmux` writes `cc-spawn-<issue>.json` **before** calling `open_tmux` (so the synchronous `pane-registry init-entry` triggered by `flightdeck-session start` hydrates the entry directly), and additionally calls `pane-registry hydrate-claude <issue>` afterwards as a belt-and-suspenders second-chance writer (mirrors the pi hydrate path).

### Subscriber-status snapshot (vstack#216)

`<state_dir>/fd-daemon-<sessionKey>.subscribers.json` is rewritten by the daemon every heartbeat and at startup. `flightdeck-daemon health` reads it to surface per-pane binding state. Shape:

```json
{
  "session_id": "$0",
  "session_key": "s0",
  "daemon_pid": 12345,
  "updated_at_epoch": 1700000000,
  "panes": [
    {
      "pane_id": "%101",
      "harness": "claude",
      "status": "bound|skipped|stuck|dead",
      "subscriber_pid": 99001,
      "consecutive_bind_skips": 0,
      "last_bind_skip_reason": null
    }
  ]
}
```

`status` semantics:

- `bound` — subscriber process is alive and events flow.
- `skipped` — tracked entry registered but adapter metadata missing; daemon will retry every reconcile tick.
- `stuck` — same as `skipped` past the stuck threshold; one-shot warning has fired.
- `dead` — pid was recorded but is no longer alive; reconcile respawns next tick.

The file is cleaned up alongside other per-session state on daemon stop and gc sweeps. Missing snapshot is reported by `health` as `subscriber_status=(missing — daemon hasn't written snapshot yet)` rather than silently omitted.

Tracked entry state enum: `state ∈ {waiting, prompting, submitting, ready, complete, cancelled, dead}`. Issue and plan workflows additionally use `{merge-ready, merged, aborted}` for PR lifecycle states; these map onto the generic enum via `domain.issue.phase` / `domain.issue.outcome` for Linear, `domain.github_issue.phase` / `domain.github_issue.outcome` for GitHub, or `domain.plan_item.phase` / `domain.plan_item.outcome` for plan items (e.g. `merged → complete + outcome="merged"`). `entryIdForIssue(issueId)` returns the issue id unchanged after validation (empty/invalid ids return null); `issueIdForEntry(entry)` reads `entry.domain.issue.id` or, for `kind: "issue"`, `entry.id`. GitHub entries use numeric `domain.github_issue.number` for lane-specific routing. Plan entries use `domain.plan_item.item_id` and normally keep `kind="workflow"` because their child panes receive self-contained item briefs. `owner` is metadata written by `flightdeck-state init`; `owner.pid` is the owner harness PID supplied by `FLIGHTDECK_OWNER_PID` (falling back to parent PID), and `owner.discovery_error` records Pi bridge metadata lookup failures when the owner harness is Pi. Dashboard renderers use `owner.pane_id` to keep the persistent dashboard owner-scoped by default. `paused_for_user` carries `{entry_id|issue_id, reason, prompt_text}` when a guard or issue/plan-mode pause fires.
