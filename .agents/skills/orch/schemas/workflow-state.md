# Workflow State Schema

Persistent state file for orch workflows. Survives context compaction.

**Location**: `<state-dir>/workflow-state-[ISSUE_ID].json` — `<state-dir>` resolves to the global `--state-dir <path>` flag, then `$ORCH_STATE_DIR`, then `tmp/`.

**Key**: `[ISSUE_ID]` is the workflow-state key whose forms `workflow-state --help` § Keys enumerates, never the bare GitHub issue number. Every `workflow-state` action, `init` included, uses the key exactly as given, so the spelling passed to `init` is the spelling every later command must use.

## Schema

```json
{
  "issue_id": "PROJ-123",
  "sub_issues": ["PROJ-124", "PROJ-125"],
  "agent": "backend",
  "worktree": "/absolute/path/to/worktree",
  "branch": "user/proj-123",
  "qa_labels": ["needs-perf-test", "needs-safety-audit"],
  "near_ceiling": ["byte-ceiling: near-ceiling=crates/core/src/engine/deps.rs:189000:204800:92"],
  "child_sessions": {
    "backend": { "status": "active", "agent_id": "agent_abc123", "runtime_agent_type": "backend", "agent_type_fallback": null, "spawned_at": "[ISO_8601_UTC]" },
    "frontend": { "status": "closed", "agent_id": "agent_def456", "runtime_agent_type": "worker", "agent_type_fallback": "spawn_rejected_or_unavailable", "spawned_at": "[ISO_8601_UTC]" }
  },
  "review_agents": ["security-review", "test-review", "doc-review"],  // project-configured
  "review_agent_ids": {
    "security-review": "agent_rev123",
    "test-review": "agent_rev456",
    "doc-review": "agent_rev789"
  },
  "review_agent_runtime_types": {
    "security-review": { "agent_type": "security-review", "task_name": "security_review", "fallback": null },
    "doc-review": { "agent_type": "worker", "fallback": "spawn_rejected_or_unavailable" }
  },
  "review_wave_done": ["security-review"],
  "pre_delegate_sha": "abc123f",
  "skip_qa": false,
  "cycles": 0,
  "rereview_cycles": 0,
  "submit_cycles": 0,
  "review_delegated_at": 1769600000,
  "dev_delegated_at": 1769600000,
  "dev_round_id": "1769600000123456789-1837",
  "json_paths": [
    "tmp/review-security-20260128-100000.json"
  ],
  "fixed_items": [
    {
      "description": "Null pointer dereference in empty buffer",
      "location": "src/lib.rs:42",
      "commit": "abc123f",
      "source": "pr-review"
    }
  ],
  "escalated_items": [
    {
      "description": "Auth token refresh not implemented",
      "location": "src/auth/mod.rs",
      "reason": "Requires API design decision",
      "outcome": "blocked",
      "source": "qa-review"
    }
  ],
  "declined_items": [
    {
      "description": "Retry loop has no jitter",
      "location": "src/net/retry.rs (`backoff`)",
      "reason": "cannot affect real usage: one client per machine",
      "source": "pr-review"
    }
  ],
  "audit_issues_created": ["PROJ-200", "PROJ-201"],
  "rebase_map": {
    "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567": "76543210f9e8d7c6b5a49382716051423344abcd"
  },
  "pr": {
    "size_check": {
      "base_sha": "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567",
      "head_sha": "76543210f9e8d7c6b5a49382716051423344abcd",
      "production_lines": 214,
      "test_lines": 262,
      "mirror_lines": 140,
      "production_allowance": 250,
      "test_allowance": 300,
      "verdict": "pass",
      "reason": ""
    }
  },
  "pr_review": {
    "mode": "review",
    "head_sha": "76543210f9e8d7c6b5a49382716051423344abcd"
  },
  "pr_review_baseline": {
    "last_threads": ["PRRT_kwDOABC123", "PRRT_kwDODEF456"]
  },
  "pr_comment_review": {
    "iterations": 0,
    "fixes": [],
    "issues_created": [],
    "skipped": [],
    "replied": [],
    "proposed_rules": [],
    "patched_causes": [],
    "frozen_causes": []
  },
  "pr_approval": {
    "forced": false
  },
  "post_pr_budgets": {
    "review_wait": {"head": "abcdef0123456789", "attempts": 2},
    "ci_fix": null
  },
  "post_pr_stop": {
    "name": "review-round-cap",
    "gate": "review",
    "remaining": ["one unresolved review thread"]
  },
  "handoff": {
    "written_at": "[ISO_8601_UTC]",
    "merged": ["#2714"],
    "remaining": ["merge-pr § 5 step 3"],
    "branch": "user/proj-123",
    "worktree": "/absolute/path/to/worktree",
    "open_pr": null,
    "traps": ["the guard chain refuses the branch under main's scripts"],
    "resumed_at": 1769600000
  }
}
```

## Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `issue_id` | string | Parent issue identifier |
| `sub_issues` | string[] | Child issue IDs if bundled |
| `agent` | string | Primary dev agent type |
| `worktree` | string | Absolute path to git worktree |
| `branch` | string | Git branch name |
| `qa_labels` | string[] | QA trigger labels from dev return |
| `near_ceiling` | string[] | `byte-ceiling` `near-ceiling` lines from the last recorded dev return, each naming a file within reach of the byte ceiling. `dev-start.md` § Store Near-Ceiling Lines is the one writer, invoked by the implement and fix accept paths and by the retry path for a structurally valid artifact with a failing `validate`. It REPLACES the list, and a return whose probe did not answer (`near_ceiling: null`) leaves it as it stood: state describes the branch as the last recorded round left it, never an accumulation across rounds. The next round's delegation renders one `Near-ceiling:` line per entry |
| `child_sessions` | object | Per-agent lifecycle keyed by logical agent name: `{agent: {status, agent_id, runtime_agent_type, agent_type_fallback, spawned_at}}`. `status` is `"active"` while the session is live (`dev-start.md` § 2 stamps it at spawn) and `"closed"` once the caller's shutdown step retires it (`start-worktree.md` § 5.5). Reviewer slot accounting treats a record with a missing `status` field as active |
| `review_agents` | string[] | Reviewer names currently expected to stay alive across fix/re-review cycles; in wave mode (`REVIEWER_SLOT_BUDGET` exceeded) only the currently launched wave |
| `review_agent_ids` | object | Reviewer session IDs keyed by name — reuse before spawning `{"name":"id",...}` |
| `review_agent_runtime_types` | object | Reviewer runtime agent metadata keyed by logical reviewer name: `{name: {agent_type, task_name?, fallback}}`; records a Codex `worker` fallback and, when the runtime `task_name` schema forced a hyphens-to-underscores spelling, the translated `task_name` — without changing the logical keys |
| `review_wave_done` | string[] | Wave mode only: reviewers whose report artifact validated (or who went unresponsive) in the current review cycle. Reset at each new cycle's first wave; the next wave launches the first budget-sized batch of `[AGENTS]` not listed here |
| `reviewer_slots_observed` | number | Effective wave size proven by the runtime when a persistent (unlimited-budget) launch hit the thread limit. While set, `review-pr.md` § 2 enters wave mode at this size even though `REVIEWER_SLOT_BUDGET` is `0` |
| `pre_delegate_sha` | string\|null | HEAD before delegation — scopes re-review diffs. review-pr § 2.2 sends it to a re-review re-entry as `Diff-range`, a boundary no reviewer can derive from its own delegation. review-pr-comments § 6.1 writes it before a fix set and sends it as the verification pass's `Diff-range` |
| `skip_qa` | boolean | Skip QA for re-cycle (cleared after routing) |
| `cycles` | number | General fix-round tally — `dev-fix.md` increments it on every fix round (review-pr § 4 and § 7, plus pre-loop review/submit rounds). It fills review-pr § 1.2's previous-cycle block and the session summaries; it decides no cap |
| `rereview_cycles` | number | § 4 → § 2 re-review cycles entered, counting entries already taken. `workflow-state set … rereview_panel` raises it in the same locked write it gates, so only that re-entry spends the budget `REVIEW_MAX_CYCLES` bounds — a § 7 QA re-check (`qa_recheck_panel`), a § 2 verification pass (`verification_panel`), and any fix round do not |
| `submit_cycles` | number | Submit-PR iteration count (created-issue re-submit loops) |
| `review_delegated_at` | number | Epoch seconds of last review delegation — the freshness boundary `review-pr.md` § 3 passes to `review-artifact-check` |
| `dev_delegated_at` | number | Epoch second of the round's delegation. [`../references/skill-rules.md` § Round Closure](../references/skill-rules.md#round-closure) owns its uses |
| `dev_round_id` | string | Unique per-delegation round token, minted by `workflow-state new-round-id [ISSUE] dev_round_id` immediately before each dev/QA delegation and embedded in it. It is the completion artifact's identity ([`dev-return.md`](dev-return.md)) and, on a fix round, the delegated-item record's ([`dev-round.md`](dev-round.md)) |
| `first_panel` | object | `{agents: string[], reason}` for review-pr § 2's first-cycle panel, recorded on a § 1 entry: the reviewers the diff and the issue's Done-when give something to read, or the caller's `agents` with reason `caller panel` |
| `recovery_round_id` | string | The round id `round-recover` minted when a stalled round had no report, or a report the disk contradicts. That round's own failed recovery is exhausted, never re-delegated again |
| `rereview_panel` | object | `{agents: string[], reason}` for a § 4 fix round re-reviewed by a scoped panel instead of the full set. Setting it is the § 4 → § 2 re-review re-entry |
| `qa_recheck_panel` | object | `{agents: string[], reason}` for review-pr § 7's § 7 → § 6 QA re-check |
| `verification_panel` | object | `{agents: string[], reason}` for a pass over a fix diff no reviewer has seen, which no cap gates: review-pr § 7's § 7 → § 2 pass, review-pr § 4's pass once the budget is spent, and review-pr-comments § 6.1's pass before the push |
| `json_paths` | string[] | Accumulated review JSON file paths. review-pr § 4 Bounded Re-Review reads the reviewers named in them as the domains already reviewed |
| `fixed_items` | object[] | Blockers successfully fixed. A `commit` of the form `dropped:<sha>` marks a fix whose commit vanished in a rebase (its patch was already upstream) — publishers omit it or cite the upstream equivalent, never print it as a live SHA |
| `escalated_items` | object[] | Items dev did not apply, plus items still outstanding when review-pr's cycle cap ends the fix loop. `outcome` records the per-item decision — `"blocked"` (could not fix; the cap path always writes this) or `"skipped"` (deliberately skipped); an entry without `outcome` is treated as blocked. The audit builder maps it to a distinct `origin`. An item is never in both buckets: every dev-fix outcome write clears the item from both, matched on (location, description), before appending its own entry |
| `declined_items` | object[] | Findings review-pr § 4 or § 7 declined, one `{description, location, reason, source}` per (location, description), a re-raised decline replacing its entry. The re-review and QA delegations list them as Declined, `review-artifact-check --issue` reports a finding at a listed location under `repeats` as a candidate carrying each decline recorded there, and § 8 carries each one's reason |
| `audit_issues_created` | string[] | Issue IDs created by audit |
| `rebase_map` | object | Old→new commit SHA map accumulated by orch `worktree-push` from the worktree-private `kendex-rebase-map` file, which is the only channel it reads: it holds what a completed guarded restack recorded before the push and what the push itself recorded during it. Keys are pre-rebase SHAs; values are post-rebase SHAs, or the literal `"dropped"` when the replayed commit vanished. `worktree-push` rewrites the SHAs stored elsewhere in state at push time — `fixed_items[].commit` and `pr_comment_review.fixes[].commit` become the new SHA truncated to the recorded length, or the marked form `dropped:<recorded sha>` for a dropped mapping. The map remains for artifact-sourced references (e.g. perf QA `benchmark_commit`) — resolve through it repeatedly until no key matches |
| `pr` | object | Pull-request size state. `size_check` initializes as null and holds the latest report from `branch-size-check` without `--cut-from-round`: `base_sha` and `head_sha`, the commits it compared; `production_lines`, `test_lines` and `mirror_lines`, the added lines in each part; `production_allowance` and `test_allowance` from the issue's optional `**Expected delta**` line, null where absent; the `verdict` (`pass`, `over`, `allowance_missing`) and its `reason`, which for `allowance_missing` names which of its two causes applied: an issue that was read and states no line, or a key such as `pr-N` that names no issue to read. Cut acceptance uses the comparison in [dev-round.md § Declared cuts](dev-round.md#declared-cuts). Cut comparisons leave the record unchanged; other measurements overwrite it. A reader binds it to a head by `head_sha`; review-gate's `pr-watch.sh` annotates its `disarmed` line with the record for the PR head and reports any other as stale |
| `pr_review_baseline` | object | `last_threads[]` — the unresolved review-thread IDs present at the end of the last triage pass. `review-pr-comments.md` § 6.3 calls a thread new when its id is absent from this array; never store a count here |
| `pr_comment_review` | object | PR comment review tracking: `iterations`, `fixes[]`, `issues_created[]`, `skipped[]`, `replied[]` (thread IDs answered), `proposed_rules[]` (deduplicated rules accepted from dev artifact summaries for the PR body), `patched_causes[]` — one `{cause, commit}` per patched cause, the single record [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence) reads: this workflow writes it where the reply resolves the thread, and [dev-fix.md](../workflows/dev-fix.md) § 2 writes it for the `pr-review`, `qa-review`, and `review` loops, whose items land in `fixed_items`; `frozen_causes[]` — one `{cause, issue}` per cause frozen by [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence), written before the `Tracked:` reply; a later finding on a listed cause is declined, never re-triaged |
| `pr_approval` | object | Reviewer-gate override tracking: `forced` (the user chose Force merge past a missing verdict), `reviewer_down` (`PR_REVIEW_ON_TIMEOUT=proceed` auto-proceeded past the deadline with every reviewer silent) |
| `post_pr_budgets` | object | Automatic retry budgets owned by `workflow-state head-budget`: `review_wait` and `ci_fix` are null or `{head, attempts}`. `take` is the only action, and it spends an attempt atomically. It starts the count over on a changed authoritative head for `review_wait` only; `ci_fix` counts across heads, because every ci-fix cycle pushes one. A continuing action resets either field by clearing it with `workflow-state update` |
| `post_pr_stop` | object\|null | A post-PR cap outcome written under `auto-recommended`: `{name, gate, remaining[]}`. The same stop is posted to the PR. A continuing action clears it |
| `pr_review` | object | Reviewer-gate mode tracking: `mode` ("approval"/"review"/"exempt"/"off" as printed by `approval-wait --resolve-mode`) and `head_sha`, the commit that mode was resolved for. A mode belongs to the endpoints it was resolved over, and the class is measured over both: a push moves the head, a retarget moves the base alone. The pair is a DIAGNOSTIC — it says what the last resolution saw — and no gate is decided from it. A reader that must waive resolves again at the live endpoints first, which is why this record has no base beside the head |
| `handoff` | object | The lane's hand-off record, written by `workflow-state set [ISSUE_ID] handoff` at the mark [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules) sets: the PRs `merged`, the steps `remaining`, the `branch`, the `worktree`, the `open_pr` number or null, and the `traps` the next session must know. `written_at` is the UTC time `set` stamps from its own clock when the record carries none; one later than that clock is refused as `handoff-written-at-future`, and the `set` entry in `workflow-state --help` names the rest of what it refuses there. `oversee-watch` reports it as `handoff` while `resumed_at` is absent; `start.md` § 0 stamps `resumed_at` when the relaunched lane resumes from it. On the fleet item the record is the overseer's own, written when its succession refuses, and it carries two more fields naming the session that wrote it: `session_id`, the id that session's Stop payload gave, and `pane_key`, its `<tmux server pid> <pane id>` for a harness whose payload names no session. The turn-end hook ends its refusal on a record whose names are its own and on no other, because every overseer of the fleet in turn shares this one item |

## Oversee state

`workflow-state-oversee.json`, under the key `oversee`, is the fleet's record, at the one address every launch passes `open-terminal --state-dir` and the watch reads as `--state` ([oversee.md § 3 Lane record](../workflows/oversee.md#3-launch)). `open-terminal` creates it on the first launch of a tmux fleet; the other surfaces create it as oversee.md § 3 Lane record directs. It carries the fields above unused and these:

| Field | Type | Description |
|-------|------|-------------|
| `lanes` | object[] | One record per launched lane, written by `open-terminal` and read by `oversee-watch --state`: `{item, tracker, repo, harness, window, account, host, mail_root, surface, model, session_id, launched_at, status, over_cap}`, plus `prepare` on a hosted lane handed to a background job. `item` is the lane's workflow-state key (the Linear id, or `issue-N` for a GitHub item) and the record's identity. `tracker`, `repo` and `harness` let `lane-close` check the live work item and stop the correct harness without caller-supplied identity; a record written before those three were recorded carries none of them, and `lane-close --tracker`, `--repo` and `--harness` supply what an idle lane's close-out needs, each filling only a field the record leaves null or absent. Two of those three `lane-close` reads for itself where the record and the options both leave them empty: `tracker` from a tracker-identifier item key, which is `linear`, and `harness` from the pane the record's `window` names, where that pane runs the harness rather than a wrapper with the harness under it. An `issue-N` key derives no tracker, being what a GitHub lane is keyed by and what a Linear lane is keyed by wherever `GH_ISSUE_PATTERN` accepts that spelling, so a record under that key carrying no `tracker` refuses as `tracker-read-failed cause=key-ambiguous` and takes `--tracker linear|github`, with `--repo` besides where that answer is `github`. `repo` is derived from nothing, so a GitHub lane whose record carries none still needs `--repo`. A derived value never beats a recorded or a supplied one, and where the item key does answer the tracker, `--tracker` only pins what the key already says. A launch appends a record where none names the item and rewrites every field where one does; a relaunch rewrites every field but `item`, `launched_at` and `over_cap`; a wake rewrites `session_id` and `status`, and is refused as `record-missing` where no record names the item, since that is a lane the launcher never launched. `window` is the tmux window in tmux's `SESSION:WINDOW` target form, the session being the one the launch opened it in, which `lane-close`, `lanes state` and `oversee-watch` resolve under exactly that session. A hand-written record may carry a bare name: `lane-close` and `lanes state` resolve it on any session of the server, and `oversee-watch` in its caller's own session only. Null off tmux. `account` is the lane's config dir, null with no `--lane`. `host` is the lane-host spec, null for a lane on this host. `mail_root` is the lane's worktree as its own host sees it, what `lane-mail --root` and `oversee-watch --hosted` take. `surface` is `tmux` or `gui`. `model` is the `--model` value in the launch flags, null when none. `session_id` is the harness session the lane resumed, null until a relaunch or wake. `launched_at` is the UTC launch time; the first record's is the fleet start `oversee-watch --since` takes. `status` is `preparing` while a lane handed to a background job waits for its host, `running` while the lane is live, `stopped` after `lane-close --keep-sandbox` stops the harness and removes the window or after that job failed and closed its window, and `done` after full close-out. The watch carries only `running` records, and `open-terminal` counts them and the `preparing` ones against `ORCH_OVERSEER_LANES`. `prepare` is `{since, log, pid, reason}`: `since` is that launch's own `launched_at` stamp, read before the window opens, which a relaunch renews while the record's `launched_at` stays; `log` is the job's output file; `pid` is the job's process group, present while the record reads `preparing`, which `lane-close` stops; `reason`, on a failure only, is `wait-failed` for the host's preparation or `launch-failed` for a launch step. The status is the outcome: `preparing` is pending, `running` ready, and `stopped` with a `reason` failed. Any other launch or relaunch of the item drops the field. `oversee-watch` reports each outcome once per `since`, and a `preparing` record older than `ORCH_WATCH_PREPARE_SECS` once. `over_cap` is the caps an `open-terminal --over-cap` launch passed, `fleet`, `account` or `fleet,account`, and null for a launch inside both |
| `tmux` | object | `{session}`: the tmux session every lane window of the fleet opens in, written by the fleet's first `open-terminal` tmux launch once tmux confirms that session exists, and read by every later one where `ORCH_TMUX_SESSION` names none (`open-terminal --help` § `--tmux`) |
| `overseer` | object | The overseer session itself: `{server, pane, window, launch_line}`. `server`, `pane` and `window` record what the current watch observes. They do not authorize reuse of a command. `launch_line` is the whole successor command: lane prefix, harness, current model, effort, permission flags and brief. Each live `oversee-watch` invocation owns this field and replaces the full object once at startup through `oversee-succeed --print-launch-line`, including after a manual restart in the same pane and after the restart `oversee-succeed` makes from a successor's pane, so `pane` names the pane the running watch serves. Watch recording always receives the current model and effort, even when `ORCH_OVERSEER_PREFERENCE` is set. Live self-succession uses that preference instead. `oversee-succeed` writes the exact successor command before it launches, which covers the interval before that successor starts its watch. `oversee-watch` hands the last live-owned line back through a file on `overseer-dead` ([oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds)) |
| `triaged` | object[] | The verdict log: `{issue, verdict, reason}` per issue the triage verifier judged, `verdict` `kept` or `canceled`, appended by [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds) `heartbeat`; the watch rebuilds its acknowledged triage keys from it |
| `fleet_log` | object[] | The fleet log: `{at, kind, item, text}` per ruling, appended as [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules) directs. `at` is the UTC time `append-file` stamps from its own clock when the record carries none, one later than that clock being refused as `fleet-log-at-future` and the `append-file` entry in `workflow-state --help` naming the rest of what it refuses there, `kind` one of `proposal`, `ruling`, `close` or `peer`, `item` the issue, carrier or repository the entry is about, `text` the ruling or outcome in one line. Its byte cap and its readers are [§ Recording policy](#recording-policy) |
| `launch_queue` | string[] | The items the overseer's last selection chose and has not launched, in launch order, rewritten at each selection. `oversee-report` renders its head as the status report's Next row, less any item a `lanes[]` record shows running or preparing |
| `owner_items` | object[] | One `{id, text}` per question the overseer sent the user and has no answer to: `id` names it for removal, `text` is the question in one line. `oversee-report` renders each as the status report's Waiting on you row. The report keeps no marker here: the newest file in `progress-reports/` beside this file is the last report (`oversee-report --help`) |
| `consumer_train` | object[] | One record per consumer a train refreshed, in the shape [consumer-train.md § 4](../workflows/consumer-train.md#4-record-each-result) appends |

## Recording policy

Six durable records outlive a turn on the control host. Each has one reader, one shape and one retention, and `workflow-state prune` enforces the retention. Every setting below resolves through `orch-env` on the kendex settings ladder: process environment, then `.env.local`, then `.kendex/settings.toml` or `kendex.settings.toml` `[env]`, then the default.

| Setting | Meaning | Default |
|---------|---------|---------|
| `ORCH_FLEET_LOG_ROW_BYTES` | Most bytes one fleet log row's `text` may carry | `600` |
| `ORCH_TAKEOVER_ROWS` | Fleet log rows a successor overseer reads at takeover | `10` |
| `ORCH_RECORD_RETENTION_DAYS` | Days past the stamp each record's Retention cell names before `prune` archives and removes it: the newest write inside a path, a fleet log row's `at`, a lane record's `launched_at` | `14` |
| `ORCH_PROGRESS_REPORT_DIR` | Owner progress report directory; a relative path joins the main checkout | `tmp/progress-reports` |

| Record | Reader | Shape | Retention |
|--------|--------|-------|-----------|
| Fleet log rows, `fleet_log[]` above | The successor overseer at takeover reads the last `ORCH_TAKEOVER_ROWS` rows through `workflow-state fleet-log takeover`, which prints nothing on a first session with no fleet state yet. Audits read the `proposal` and `ruling` rows through `workflow-state fleet-log audit` | `at` stamped by `append-file`, `kind`, `item`, and one line of `text` of at most `ORCH_FLEET_LOG_ROW_BYTES` bytes. `append-file` refuses a longer row as `fleet-log-row-bytes` | A row whose `at` is past the retention is pruned. A row with no ISO 8601 UTC `at` is kept |
| Overseer handoff file, `handoffs/OVERSEER-HANDOFF.md` | The successor overseer, at [oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface) | [communication-modes.md § Handoff](../references/communication-modes.md#handoff) | The file itself is kept. Other files under `handoffs/` are pruned past the retention of their newest write |
| Lane records, `lanes[]` above | `oversee-watch`, `lane-close` and the overseer. A lane's timing stamps live in this record and nowhere else, so any rollup of them reads this record | The `lanes` row above | A `done` record whose `launched_at` is past the retention is pruned. The first record is kept whatever its age or status, since its `launched_at` is the fleet start `oversee-watch --since` takes |
| Lane status file, `tmp/lane-status-[ISSUE_ID].md` | The overseer, through [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads) | [oversee.md § 3 Lane directive](../workflows/oversee.md#lane-directive), at most 40 non-empty lines | Under the lane's `mail_root`. A local lane's leaves with its worktree when that is removed; `lane-host close` archives a hosted lane's `tmp` records and prints `kept=PATH`. `prune` reaches one only for an item that ran in the main checkout, and removes it once that lane is closed and the file is past the retention |
| Lane mailbox, `tmp/lane-mail/[ISSUE_ID]/` | The lane and the overseer, through `lane-mail` | `lane-mail --help` § Envelope | Same as the lane status file |
| Owner progress report, `MM-DD-HH-MM.md` under `ORCH_PROGRESS_REPORT_DIR` | The owner. No agent reads it | [communication-modes.md § Status report](../references/communication-modes.md#status-report). Each decision names the paths it chose between and the outcome of each path | Pruned past the retention, and counted as `progress_reports=N` |

The overseer writes one progress report beside each status report it gives in chat, and one at every succession, named `MM-DD-HH-MM-succession.md`. The time in the name is UTC. `workflow-state progress-report-path [--succession]` prints the path and creates the directory. The default directory is under `tmp/`, which the repository's `# kendex:local-state` ignore block covers, so no commit picks a report up.

### Prune

`workflow-state prune [--keep PATH]...` works on the fleet state `workflow-state-oversee.json` and the directory that holds it. With no fleet state yet, as on a first session that stops before its first launch, it prints `pruned fleet-state=none path=PATH` alone and archives, removes and writes nothing: only the lane records tell a live lane from a closed one. A progress report directory that is or holds that directory refuses as `prune-progress-overlap`. The overseer runs it at every succession and once at fleet close, as [oversee.md § 5](../workflows/oversee.md#5-stop) directs.

The keep list holds whatever the age:

- `workflow-state-oversee.json` and its lock, and the watch's own files beside it that `scripts/lib/watch-pid.sh` names: `oversee-watch.pid`, `.argv`, and the `.log` and `.err` a succession-restarted watch writes.
- `handoffs/OVERSEER-HANDOFF.md`, the `handoffs/` and progress report directories themselves, and the overseer's own mailbox `lane-mail/overseer/`.
- Each `--keep PATH`, and each path that holds it. The overseer names the current watch run directory here.
- Every path of that directory whose name carries, as a whole token, the item of a lane whose record is not `done`: a `running` lane, and a `preparing` or `stopped` lane a relaunch resumes.

Every other entry of that directory, every entry under its `handoffs/` and `lane-mail/`, and every `MM-DD-HH-MM.md` or `MM-DD-HH-MM-succession.md` in the progress report directory is a candidate when nothing inside it was written within `ORCH_RECORD_RETENTION_DAYS`. Before it removes anything, the prune writes one archive holding each candidate path and the pruned `fleet_log` rows and lane records, at `FLEET_DIR/archive/[REPO]/oversee/prune-[EPOCH]-[RANDOM].tgz`. `FLEET_DIR` defaults to `~/.fleet`, the root `lane-host close` also archives under, and `[REPO]` is the main checkout's directory name. The directory is `0700` and the archive `0600`. An archive it cannot build refuses as `prune-archive-failed` and removes nothing. It then drops the rows from the state and removes the paths. It prints `pruned path=PATH` per path, then `pruned fleet_log=N lanes=N progress_reports=N paths=N`, then `kept=ARCHIVE`, or `kept=none` where nothing was archived.

The watch log is rotated, not pruned. Each watch launch writes into a fresh run directory ([waiter-launch.md § Launch](../references/waiter-launch.md#launch)), so a successor's watch appends to a new log, and the prior run directory leaves the keep list and ages out under the same retention. A succession-restarted watch writes `oversee-watch.log` and `.err` beside the fleet state instead, which the keep list holds with the pid and argv files until the next watch start prints and removes them.

## CLI

All operations use `.agents/skills/orch/scripts/workflow-state` (run with `help` for full usage).

To target a state directory from a worktree, pass the global `--state-dir <path>` flag before the subcommand — it takes precedence over `ORCH_STATE_DIR`. Prefer it over an `ORCH_STATE_DIR=… workflow-state …` env prefix (rejected under Codex `approval=never`). `ORCH_STATE_DIR` stays supported as an environment fallback.

`set` values are JSON only when they look like it — a `{`/`[` prefix, exactly `null`/`true`/`false`, or all digits. `append` is narrower: only a `{`/`[` prefix is spliced as JSON (a bare `null`/`true`/`123` appends as a string). Every other value is stored as a raw string: pass plain strings bare — `set PROJ-123 pr_review.mode review`, never `'"review"'`. `update` always takes a jq expression.

```bash
.agents/skills/orch/scripts/workflow-state init PROJ-123 --agent backend --worktree /tmp/wt
.agents/skills/orch/scripts/workflow-state head-budget take PROJ-123 review-wait abcdef01
.agents/skills/orch/scripts/workflow-state update PROJ-123 '.post_pr_stop = null'
.agents/skills/orch/scripts/workflow-state get PROJ-123 .cycles
.agents/skills/orch/scripts/workflow-state get PROJ-123 .rereview_cycles
.agents/skills/orch/scripts/workflow-state increment PROJ-123 cycles
.agents/skills/orch/scripts/workflow-state append PROJ-123 json_paths "review.json"
.agents/skills/orch/scripts/workflow-state set PROJ-123 pr_review.mode review
.agents/skills/orch/scripts/workflow-state set PROJ-123 pr_review_baseline '{"last_threads":["PRRT_kwDOABC123","PRRT_kwDODEF456"]}'
.agents/skills/orch/scripts/workflow-state --state-dir /path/to/tmp append PROJ-123 fixed_items '{"description":"Fix"}'
```
