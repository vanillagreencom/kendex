# Workflow State Schema

The records orch workflows read and write: one record per item, and the fleet's own record under the key `oversee`. Read this file when a step, a reply or a refusal names a member. A record outlives the session that wrote it.

**Location**: an item's record is `<state-dir>/items/[ISSUE_ID]/workflow-state-[ISSUE_ID].json`, in a folder of the item's own that also holds its lock file and mutex. The fleet record is `<state-dir>/workflow-state-oversee.json`. `<state-dir>` is the global `--state-dir` flag, else `ORCH_STATE_DIR`, else `tmp`; a relative path joins the main checkout. `orch-runtime state path --item [ISSUE_ID]` prints the record's path. A confined lane writes only its own item's folder of the state directory.

The runtime declares the record's typed views in [`state.rs`](../runtime/src/state.rs) and the owner of each member in [`ops/records.rs`](../runtime/src/ops/records.rs) (`owned_fields`). A pointer write (`state set`, `append`, `set-file`) into an owned member is held to its owner's check and refused `field-owned` naming the member and the owner where the value is not one the owner writes.

## Keys

`[ISSUE_ID]` is the workflow-state key, never a bare GitHub issue number. It takes one of these forms:

- the tracker identifier, `PROJ-123`, for a tracked issue;
- `issue-<N>` for a GitHub issue;
- `pr-<N>` for a pull request whose branch carries no issue id;
- `directive-<ID>` for an owner-directed micro change, `<ID>` the directive's id;
- `local-<epoch>-<pid>-<random>` for work with none of these, minted by `orch-runtime state new-local-key`, which writes nothing.

A workflow that creates a record under a local key owns it: it passes the key to every round it stamps and removes the record when it ends. The runtime puts the key into the path exactly as given, so every command uses the spelling `state init` was given.

The fixed key `oversee` names the fleet record ([§ Oversee state](#oversee-state)). A command addresses an item as `--item [ISSUE_ID]` and the fleet record as `--fleet`.

## Schema

`orch-runtime state init --item [ISSUE_ID]` writes this object, refusing `state-exists` where a record stands. `--agent`, `--worktree` and `--branch` fill their members, and `--qa-labels` and `--sub-issues` take JSON arrays. Later operations add the other members of [§ Field Definitions](#field-definitions).

```json
{
  "issue_id": "PROJ-123",
  "sub_issues": [],
  "agent": "backend",
  "worktree": "/absolute/path/to/worktree",
  "branch": "user/proj-123",
  "qa_labels": [],
  "near_ceiling": [],
  "finding_occurrences": {"prior": "none", "records": []},
  "child_sessions": {},
  "review_agents": [],
  "review_agent_ids": {},
  "review_agent_runtime_types": {},
  "pre_delegate_sha": null,
  "skip_qa": false,
  "cycles": 0,
  "rereview_cycles": 0,
  "json_paths": [],
  "fixed_items": [],
  "escalated_items": [],
  "audit_issues_created": [],
  "pr_review_baseline": null,
  "pr_comment_review": {"iterations": 0, "fixes": [], "issues_created": [], "skipped": []},
  "post_pr_budgets": {"review_wait": null, "ci_fix": null},
  "post_pr_stop": null
}
```

A record keeps its keys in the order it was written; an operation patches named members and appends a member it adds.

## Field Definitions

The Owner column names the writer: an `op` request is `orch-runtime op --item [ISSUE_ID] --request [FILE]` with the request's `op` and, where shown, its `step` or `entry` ([§ CLI](#cli)); a `state` verb is `orch-runtime state ...`.

| Field | Type | Owner | Meaning |
|---|---|---|---|
| `issue_id` | string | `state init` | The key. |
| `agent` | string | `state init` | The primary dev agent type. |
| `worktree` | string | `state init`, then `record-route` | The item's worktree, an absolute path; `record-route` refuses another as `worktree-invalid`. |
| `branch` | string | `state init`, then `record-route` | The item's branch; `record-route` refuses an empty one as `branch-invalid`. |
| `tier` | string | `record-route` | The cycle the item runs: `micro`, `small` or `standard`; another word refuses `tier-value`. Absent, no tier bound applies. A `small` item holds `REVIEW_MAX_CYCLES` to at most 1 and `REVIEW_MAX_EXTERNAL_ROUNDS` to at most 2, as `state cap` reads them. |
| `review_floor` | string | `record-route` | The lowest tier a directed change's review keeps, one of the three tier words; another refuses `review-floor-value`. |
| `sub_issues`, `qa_labels`, `near_ceiling` | string[] | `state init`, then `record-dev-return` | What the last recorded dev round returned: the bundled child issues, the QA trigger labels, and the `byte-ceiling` `near-ceiling=` lines naming a blob near the byte ceiling. `record-dev-return` replaces each member it names and keeps one it leaves out; an empty line refuses `dev-return-field`. The next round's delegation renders one `Near-ceiling:` line per entry. |
| `child_sessions` | object | `record-agents` steps `child-open`, `children-closed`, `slots` | Per logical agent name: `{status, agent_id, runtime_agent_type, agent_type_fallback, opened_by, runs_in}`. `status` is `active` from `child-open` and `closed` from `children-closed`. `opened_by` is the lead process that opened the child, `{session_id, session_since, pid, start}`, and `runs_in` is `lead` for a Claude Code or Codex child and `own` otherwise. `slots` closes an in-lead child whose opener reads gone (`ended: holder-gone`) and reports the slots the others hold. |
| `review_agents` | string[] | `record-agents` steps `active`, `cleared` | The reviewers the current wave runs; `cleared` empties it, `review_agent_ids` and `review_wave_done` for the next wave. |
| `review_agent_ids` | object | `record-agents` steps `active`, `cleared` | Reviewer name to session id; reuse an id before spawning. |
| `review_agent_runtime_types` | object | `record-agents` step `active` | Reviewer name to the runtime agent type it was spawned as. |
| `review_wave_done` | string[] | `record-agents` steps `wave-start`, `returned`, `cleared` | The reviewers whose artifact returned in the current wave. `wave-start` empties it. |
| `reviewer_slots_observed` | number | `record-agents` step `wave-start` | The spawn count the harness allowed, `slots_observed`; the wave size while set. |
| `json_paths` | string[] | `record-agents` step `returned` | Every accepted review artifact path, each recorded once. |
| `pre_delegate_sha` | string or null | `record-round` step `base` | The worktree's HEAD before the delegation, read by the runtime; it scopes a re-review's diff range. |
| `review_fix_round` | boolean | `record-round` step `base` with `review_fix: true` | `true` once the review's fix round ran; never cleared. At a `REVIEW_MAX_CYCLES` of 0, `state cap --item` reads `below` until it is set and `at-cap` after. |
| `dev_delegated_at`, `review_delegated_at` | number | `record-round` step `delegated` with `round: dev`, `ci` or `review` | Epoch second of the delegation: a dev or CI round's, or a review round's, which `review-artifact check --delegated-at` takes as the freshness boundary. |
| `cycles` | number | `record-round` step `counted` with `counter: fix` | Fix rounds run, read by summaries; it decides no cap. |
| `rereview_cycles` | number | `record-panel` with `panel: rereview` | Re-review cycles entered. Recording the rereview panel raises it in the same write and refuses `cycle-cap` at the `REVIEW_MAX_CYCLES` limit. |
| `first_panel`, `rereview_panel`, `verification_panel` | object | `record-panel` with `panel: first`, `rereview` or `verification` | `{agents, reason, external?, domain_reasons?}`. A reviewer named twice refuses `panel-agents`, an empty reason `panel-reason`. On a `small` item a panel with no boolean `external` refuses `panel-external`, and one of more than three reviewers, the external lane counted, `panel-bound`. A later panel holding every `first_panel` reviewer refuses `panel-copy` unless `domain_reasons` names why the fix diff concerns each. |
| `submit_cycles` | number | `state increment` from [submit-pr.md](../workflows/submit-pr.md) | Re-submit loops run. |
| `dev_round_id`, `review_round_id`, `ci_round_id` | string | `begin-round` with `kind: dev`, `review` or `ci` | The round token, minted before each delegation and carried in it. A `dev` or `review` round opens a stage; a `ci` round opens none and keys its cleanup in `round_prunes`. The dev token is the completion artifact's identity ([dev-return.md](dev-return.md)) and, on a fix round, the delegated-item record's ([dev-round.md](dev-round.md)). |
| `stages` | object[] | `begin-round`, `record-validation-admission`, `accept-result`, `reconcile-round`, `validate stop`, `record-push`, `orch-runtime validate start`, `dev-return check` | One entry per round or validation run, [§ Stages](#stages). |
| `validate_rounds` | object[] | `dev-return check`, `record-push` | One `{round_id, receipt, kind, mode, seconds, lanes?, selection?}` per schema-valid dev receipt with validation time, a recovery's receipt in its own row; and one row with `round_id` `restack-<run id>` per restack run a push records. |
| `round_prunes` | object | `prune-round` | Round id to `{action, used_pct, mark_pct, bytes}` for the round's Cargo cleanup. `action` is `pruning` until the cleanup answers, then `pruned`, `failed` or `unknown`; `below-mark`, `target-elsewhere` and `no-worktree` record a cleanup not run. |
| `recovery_round_id`, `round_recovery` | string, object | `orch-runtime round recover` | The round a recovery minted for a stalled round, and `{from, to, reason}`; a repeated recovery of the same round answers the same. |
| `summary_comment` | object | `accept-result` with `summary_file` | `{id, at, attachments}`: the item's `## Completion Summary` comment on the tracker, created once and updated in place by its id. `attachments` is `{name, url, image}` per link the body carries, rendered on every update. |
| `verification` | object | `record-verification`, through `verify-head` and `verify-pr` | `{head, verdict, reason, source, at}` for a published head. `verdict` is `pass`, `fail` or `none`; `none` holds only with affirmative absence evidence in `reason`. A newer head's record replaces the one before. [submit-pr.md](../workflows/submit-pr.md) reads it before the merge step. |
| `fixed_items`, `escalated_items`, `declined_items` | object[] | `record-disposition`, `state bucket`; `record-push` rewrites `commit` | The disposition buckets, each entry keyed by `location` and `description`. A move drops the entry from each named `drop` bucket first, so an item stands in one bucket. A `commit` of `dropped:<sha>` marks a fix whose commit a rebase dropped: cite the upstream equivalent, never the SHA. An `escalated_items` entry's `outcome` is `blocked` or `skipped`, absent read as blocked. |
| `pr_comment_review` | object | `record-comment-ledger`; `record-round` step `counted` with `counter: external` | The comment triage ledger: `iterations`, the bot triage passes `REVIEW_MAX_EXTERNAL_ROUNDS` counts, `fixes[]` (entry `fix`), `issues_created[]` (entry `issue` with `origin: triage`), `skipped[]` (`skip`), `replied[]` (`reply`), `proposed_rules[]` (`proposed-rule`, each rule once), `patched_causes[]` (`patched-cause`, `{cause, commit, location, owner?}`) and `frozen_causes[]` (`frozen-cause`, `{cause, issue}`). [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) reads the cause entries. |
| `pr_review_baseline` | object or null | `record-comment-ledger` entry `baseline` | `{last_threads}`: the unresolved review-thread ids at the end of the last triage pass. A thread is new when its id is absent here. |
| `audit_issues_created` | string[] | `record-comment-ledger` entry `issue` with `origin: audit` | Issue ids the review's audit filed. |
| `rebase_map` | object | `record-push` | Pre-rebase SHA to post-rebase SHA, or `dropped`, read from the worktree's `kendex-rebase-map`. The same write rewrites `fixed_items[].commit` and `pr_comment_review.fixes[].commit`. Resolve an artifact's SHA through it until no key matches. |
| `restacks` | number | `record-push` | Restack hops reconciled; a hop the map already holds adds none. Absent reads 0. |
| `push_attempt` | object | `record-push` | The push written `attempted` before it starts, so a push whose answer was lost is settled from the remote before the next one. |
| `restack_skips` | object[] | `record-pr-progress` step `restack-skip` | `{head, condition, validated_head, paths}` per restack whose re-test was skipped, replacing an entry of the same `head`; `condition` is `no-conflict` or `version-only`. |
| `pr_order` | string | `record-pr-progress` step `order` | When the lane opens its pull request: `review-first`, `open-first`, `open-first-returned`, `open-first-pushed`, `push-first`, `push-first-returned` or `push-first-pushed`; another word refuses `pr-order-value`. Absent, the item runs review-first. |
| `pr_approval` | object | `record-pr-progress` steps `forced`, `reviewer-down` | `forced`: the user chose Force merge, item-wide and never cleared. `reviewer_down`: every reviewer stayed silent past the period and `PR_REVIEW_ON_TIMEOUT=proceed` proceeded. |
| `children_detached` | boolean | `record-pr-progress` step `children-detached` | `true` once the children's detach ran before the arm, so it runs once. |
| `ci_rerun` | object | `record-pr-progress` steps `ci-rerun`, `ci-rerun-run` | `{head, run, at}`: the one automatic rerun of a transient CI failure on `head`, recorded before it is asked for, `run` null until the rerun's run is known. A head with a record is never rerun again. |
| `pauses` | object[] | `record-pr-progress` steps `merge-asked`, `merge-answered` | `{from, to, cause: "merge-hold"}`: the lane's merge question open from its ask to its answer; at most one stands open. |
| `queue_watch` | object | `record-queue-watch` | The merge-queue wait's memory for one head and one arm, written before each poll. |
| `qa_decision` | object | `record-qa-decision` | The review's QA routing and the QA reviews recorded; [review-pr.md](../workflows/review-pr.md) owns its steps. |
| `post_pr_budgets` | object | `state head-budget take`, `state head-budget reset` | `review_wait` and `ci_fix`, each null or `{head, attempts}`. `take` spends one attempt in one write and answers `continue`, or `at-cap` with nothing written; `review-wait` restarts its count on a new head and `ci-fix` counts across heads. `reset` sets the budget null. |
| `post_pr_stop` | object or null | `state post-pr-stop record`, `record-if-empty`, `clear` | `{name, gate, remaining[], at}`, posted to the pull request as an `## Orchestration stopped` comment that `--comment-file` names. `record-if-empty` keeps a standing stop and restamps its `at`. `at` is the epoch second of the last recording, so a reader tells a stop the lane's current session reached. `clear` lifts it. |
| `head_approvals` | object | `approve-head` | The overseer's exact-head approvals, per pull request `owner/repo#pr` (the repository lowercased), then per full head SHA: `{login, attempt, comment}`. `attempt` is null, `{state: attempted}` from before the POST, or `{state: confirmed, review}`; `comment`, where the request names `comment_file`, is `{state: attempted}` or `{state: posted, id}`. The request refuses `head-moved` for a head other than the live one. Where the configured login differs from an entry's, a confirmed approval stands, an entry holding no act takes the configured login, and one holding an `attempted` attempt or a comment refuses `approval-login-changed`. |
| `pr_review` | object | `verify-review` | The review gate's record: its mode, per head SHA, and its last verdict, as [gates.md § The review call](../references/gates.md#the-review-call) and [§ Copilot requests](../references/gates.md#copilot-requests) read it. |
| `handoff` | object | `record-handoff`, `resume-handoff` | [§ Handoff](#handoff). |
| `model_checks`, `lane_session`, `model_reset` | object | `state model-check`, the turn end | [§ Model checks](#model-checks). |
| `finding_occurrences` | object | `state init`, `state findings record`, `dev-return check` | [§ Finding occurrences](#finding-occurrences). |

### Stages

One `stages[]` entry is `{kind, round_id, start, end}` in epoch seconds, with `outcome` once closed. `kind` is `dev`, `review`, `implement`, `fix` or `validate`.

- `begin-round {kind, body_revision?, group?, exception?}` opens a `dev` or `review` entry in the same write as the token, and closes every earlier open entry of the kind at the new start with `superseded: true`. `body_revision` is the item body's `updatedAt` as the caller read it; the reply's `body_moved` is `true` where it is later than the kind's previous recorded revision. `group` is `{n, of}`. `exception` is `{by, id, excused}`, the known failing checks the round may end with.
- `orch-runtime dev-return check` sets the dev entry's kind to `implement` or `fix`.
- `record-validation-admission {round_id, run_dir?, attempt?}` opens `{kind: "validate", round_id, run_dir, start, end: null}` before the run. Without `run_dir` the runtime mints the run id and `run_dir` is `<worktree>/tmp/dev-validate-<run_id>`. A repeat while an admitted run of the round stands open returns that run; `attempt: next` mints another.
- `orch-runtime validate start` writes the run's `proof` and `job` on its entry before the launch; `validate stop --item [ISSUE_ID] --run-dir [RUN_DIR]` writes `stop: {at}` before it ends the job.
- `accept-result {round_id, outcome, run_dir?, end?, authorization?, summary_file?, attachments?}` closes the round's own entry, or with `run_dir` the run's `validate` entry. `outcome` is required: `pass`, `fail`, `no-verdict`, `lost`, `stopped`, `no-change`, `handed-over` or `pass-excused`. `end: {from_artifact: PATH}` takes the file's modification time, bounded to `[start, now]`; without it the entry ends now. A repeat changes nothing and reports the recorded close; a superseded entry refuses `round-superseded`.
- `reconcile-round {round_id}` closes each open `validate` entry of the round whose run will not end itself: with its sentinel's word; `stopped` for a run never started or one a `stop` stands on; `lost` for a gone run with no sentinel and no `stop`. A run still running, or one that cannot be read, stays open.
- `record-push` writes `{kind: "validate", reason: "restack", round_id: null, run_dir, start, end, outcome, proof}` once per finished restack run directory.

`stages[].authorization` is `{by, id}`, `by` `overseer` or `owner-directive`, written by a round's own `accept-result` and part of the acceptance's identity: a repeat naming another refuses `authorization-differs`. A `directive-[ID]` item's round must name `{by: owner-directive, id: [ID]}`, else it refuses `authorization-missing`. `{by: overseer, id}` names the inbox envelope that answers the lane's own `lane-question`, or an owner's directive the overseer relayed; never a launch ruling, a fleet-log row or a session id.

`orch-runtime cycle stages [ITEM]` prints the item's `stage item=` rows sorted by start. The close's merge cycle copies the entries to `lanes[].cycle.stages`.

### Handoff

`handoff` is the lane's hand-off record. `record-handoff` writes `{written_at, round_id, merged, remaining, branch, worktree, open_pr, traps, context, relaunch}`, and on a model switch also `session_id`, `pane_key`, `cause` and `model`:

- `round_id` must name a stage the item ran, else `round-unknown`.
- `relaunch` is `fresh` or `resume`, the session route a relaunch takes; absent reads `fresh`.
- `context` is the context decision that caused the hand-off, as the turn end judged it.
- `written_at` is the request's ISO 8601 UTC time, else the runtime's clock; one that does not parse refuses `handoff-written-at-invalid`, one later than the clock `handoff-written-at-future`.
- Every field but `written_at` is the record's identity while it carries no `resumed_at`: the same content again reports `recorded_now: false`, other content refuses `handoff-differs` unless the request carries `supersede: true`. A record carrying `resumed_at` is replaced whole by the next `record-handoff`.
- A pointer write at or under `/handoff` on an item record refuses `handoff-route`.

`orch-runtime state handoff-standing --item [ISSUE_ID] [--worktree PATH]` reads the item's record in the state directory, then in `<root>/tmp`, `<root>` being `--worktree`, else, with no `--state-dir`, the linked worktree the caller runs in. Its reply's `standing` is the answer, not the exit status: `stands` with the `file` and the `record`; `none` with the first place holding the item's record; `unreadable` with the first place that could not be read. A lane whose launch forbids writing the main checkout keeps its record in its worktree's `tmp`.

`orch-runtime state handoff-resume --item [ISSUE_ID] [--worktree PATH]` runs `resume-handoff` on every place the record stands. It stamps `resumed_at` once, in epoch seconds, and reports the round, its route, the `remaining` steps and the round's open validation runs, which the continuation waits on. A second resume reports the first stamp; no standing record refuses `handoff-none`. The watch reports a record with no `resumed_at` as `handoff`.

### Model checks

A Claude Code session's switch away from its launch model, or a model the turn end cannot read, is a model check, recorded once per launch.

- A lane's turn end keeps its check on its own item record: `model_checks[session_id]`, `{outcome, session_id, launch_identity, launched, observed, at, cause}`, `outcome` `switched` or `unavailable`. On a switch it writes the `handoff` the replacement resumes from, then marks the check `recovery_started`.
- The turn end also keeps `lane_session`, `{session_id, launch: {pid, start}}`, the session a cleared start's harness began, and `model_reset`, `{session_id, launch_identity}`, at a replacement's first turn end.
- The watch's lane pass reads those three members of a local lane's item record. It binds the fleet lane to `lane_session`, writes the lane record's `model_check` with a `model-switched` or `model-unavailable` fleet-log row, and starts `recover-lane-model` for a started switch. From `model_reset` it writes the check `passed` and a `model-recovery-reset` row.
- `recover-lane-model` counts the lane's recoveries since its last `model-recovery-reset` row. At `ORCH_MODEL_RECOVERY_LIMIT`, default 3, it relaunches nothing and appends one `model-recovery-limit` row.
- A hosted lane's switch is kept on the item record on its host, which the hook finds through the lane's launch record. A failed stop of its predecessor is kept as `handoff.stop_failure`.
- `orch-runtime state model-check slot|record|reset|start` are these writes; `slot` holds the once-only notice of an unavailable model per session.

The controller's check is kept on the fleet record's `controller` member by the same rule.

## Oversee state

The fleet record `workflow-state-oversee.json` holds the init object and the members below. `orch-runtime state init --fleet` creates it; a fleet operation refuses `record-missing` where it does not stand. The watch reads it as its `--file` ([oversee.md § Lane record](../workflows/oversee.md#lane-record)).

| Field | Type | Owner | Meaning |
|---|---|---|---|
| `lanes` | object[] | `launch-lane`, `close-lane`, `park-lane`, `reserve-lane`, `release-lane`, `admit`, `state merge`, `record-surface-lane`, the watch | One record per lane, [§ Lane records](#lane-records). |
| `tmux` | object | `launch-lane` | `{session}`: the tmux session the fleet's lane windows open in, written by the first launch and read by later launches where `AGENT_RUNTIME_TMUX_SESSION` names none ([lane-directive.md § Tmux session](../references/lane-directive.md#tmux-session)). |
| `controller` | object | agent-runtime's controller transitions, `orch-runtime register --fleet` | The overseer session, [§ Controller](#controller). |
| `intents` | object[] | agent-runtime's journal | One row per lane or controller operation with a live effect: its phase, obligations and outcome. `orch-runtime state inspect --fleet` lists the open ones under `open_intents`. |
| `handoff` | object | `record-overseer-ledger` entry `handoff` | The overseer's own hand-off: `{handoff_file, pane_key, session_id, context, written_at}`, `written_at` stamped under the fleet log's time rule. |
| `last_backlog_audit` | object | `record-overseer-ledger` entry `backlog-audit` | `{at, backlog}`: the team Backlog count at the last full audit, stamped by the runtime. The [heartbeat audit](../references/heartbeat-audit.md) reads it. |
| `launch_queue` | string[] | `record-overseer-ledger` entry `launch-queue` | The items the last selection chose and has not launched, in launch order, replaced whole. It holds the order, never the membership: the watch names each owed tracker item under every heartbeat. An empty or repeated entry refuses `launch-queue-entry`. |
| `triaged` | object[] | `record-overseer-ledger` entry `triage` | `{issue, reason, verdict}` per issue the triage verifier judged, `verdict` `kept` or `canceled`; the watch rebuilds its acknowledged triage keys from it. Another shape refuses `triaged-record-invalid`. |
| `alerts_triaged` | object[] | `record-overseer-ledger` entry `alert-verdict` | `{repo, kind, number, verdict, item, reason}` per security alert judged, `verdict` `filed` with its fix item or `dismissed` with `item` null ([security-alerts.md § Triage](../references/security-alerts.md#triage)); the watch reports no alert it names. |
| `standing` | object[] | `state standing add`, `state standing lift` | The owner's standing instructions, `{at, id, scope, end, text}`. `add` appends one row, its `at` stamped when absent; `lift` replaces the array with the file's and appends one `ruling` row naming the ids that left. When to write a row is [communication-modes.md § Recording](../references/communication-modes.md#recording)'s. |
| `fleet_log` | object[] | `state log append`, and the writers named below | One `{at, kind, item, text}` row per entry, [§ Recording policy](#recording-policy). |

`fleet_log` kinds: `proposal`, `ruling`, `close`, `peer`, `use1`, `cycle`, `token`, `landing-disposed`, `model-switched`, `model-unavailable`, `model-recovery-limit` and `model-recovery-reset`. The confirmed close writes `close`, `cycle` and `landing-disposed`, and `orch-runtime cycle rollup` writes `cycle`; the model checks write the `model-` kinds; every other row goes through `state log append`, which stamps an absent `at`, refuses an `at` outside `YYYY-MM-DDThh:mm:ssZ` (`fleet-log-at-invalid`) or later than the clock (`fleet-log-at-future`), and refuses text over `ORCH_FLEET_LOG_ROW_BYTES` (`fleet-log-row-bytes`). An `append` at `/fleet_log` refuses `fleet-log-append`. `text` is one line and never a token value. A `use1` row also carries `outcome`; [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules) says when to write each kind.

A cloud lane's close writes one more `close` row: `cloud lane closed; session=ID account=ACCOUNT`, `none` for a member the record lacks, followed, where the lane recorded a directive send, by ` send=RESULT credit=DOLLARS locked=REASON cli=TEXT`, the CLI's words cut to 300 characters. The archive list in [§ Recording policy](#recording-policy) parses that form.

### Controller

`controller` is the overseer session's record: its launch identity (`harness`, `account`, `home`, `model`, `class`, `effort`, `cwd`, `permission`, `extra_args`), its pane (`server`, `server_start`, `server_socket`, `pane`, `window`, `session_rows`), its process (`harness_pid`, `harness_start`) and native `session_id`, `generation`, and `pending`, `exit`, `off` and `watch`. Agent-runtime's `controller` module owns the shape.

- A confirmed `start-controller` or `request-transfer` publishes the record from its typed `pending` controller and the identity it observed, at the next `generation`.
- `orch-runtime register --fleet` records a hand-opened session through `adopt-controller`. Where the record names the same pane on the same server, the adoption keeps the record and its generation, replaces each launch field the request names and drops `pending`, `exit` and `off`; otherwise it writes the session's record at the next generation.
- `watch` is the fleet watch a confirmed `start-controller` launched or found claimed: `{runner: systemd, unit}` for a watch the job launcher started as a user unit; `{runner: setsid, pid, start}` for one it started as a process group, the group leader's pid and start; `{runner: setsid, pid}` where the launcher's record names the group without its leader's start; `{runner: unread}` where the launcher's record names nothing of the job yet; `{runner: claimed, pid, start}`, the claim's own identity, where the start found the watch already claimed.
- A succession carries no `watch` and leaves the member as it stands.
- The watch's claim `oversee-watch.pid` beside the fleet record stays the watch's liveness record; `watch` names what started it.

### Lane records

A first `launch-lane` appends the record `{item, tracker, repo, harness, window, account, host, kind, mail_root, surface, model, effort, class, class_reason, permission, session_id, session_since, launched_at, running_at, status, over_cap, allow_all, tier, tier_inputs, launch}`, `status` `preparing`. `item` is the record's identity. [state.rs](../runtime/src/state.rs) `Lane` is the typed view, and [`ops/lane.rs`](../runtime/src/ops/lane.rs) holds the writes.

A relaunch keeps every member its request leaves out. `host` and `kind` are always the launch's own. `harness`, `account`, `model` and `effort` reach the record when the launch confirms, each null where the request named none. A relaunch keeps `tier` and `tier_inputs`; a launch over a `done` record writes its own brief's.

| Member | Meaning |
|---|---|
| `tracker`, `repo`, `harness` | What the close reads the item and stops the harness by. Where the record and the request both leave `tracker` empty, a tracker-identifier key derives `linear`; an `issue-N` key derives none and the close refuses `tracker-read-failed cause=key-ambiguous` until the request names one. |
| `window`, `launch` | The lane's tmux window and its confirmed identity `{pane, server, server_start, pid, start}`, null at `preparing` and on a cloud lane. The close stops a local harness by `pid` and `start`. |
| `account`, `home`, `home_implicit` | The account the lane spends, the home its sessions ran under, and `true` where the launch named no home. |
| `host`, `kind`, `mail_root`, `checkout` | Where the lane runs: `host` null for this machine, `claude-cloud`, or a provider path; `kind` `local`, `claude-cloud` or `ssh` ([lane-host.md § Host kinds](lane-host.md#host-kinds)). `mail_root` is the lane's worktree as its host sees it; `checkout` is the checkout a hosted lane launched from. |
| `surface` | `tmux`, the lane operations' one surface. A record a harness's own launcher runs carries another, written by `record-surface-lane` steps `create` and `merge`. |
| `model`, `effort`, `permission`, `allow_all` | The launch line's model, effort word and permission word, null where it names none. `allow_all` is whether a Copilot lane's line grants the full allow-all mode, null on every other harness. |
| `class`, `class_reason`, `class_missed` | The model class the assignment runs at (`top`, `standard`, `light`, `fast`) and its reason. `class_missed` `{class, cause, at}` stands after a `no_landing` close retired an attempt below `standard`; no launch below `standard` runs the item while it stands. |
| `session_id`, `session_since`, `launched_at`, `running_at` | The harness session bound, the UTC time the launch or relaunch started, the first launch's time, and the time the lane read `running`. The first record's `launched_at` is the fleet start the watch's `--since` takes. |
| `status` | `preparing`, `running`, `stopped`, `parked` or `done`. |
| `over_cap`, `reservation` | The over-cap reason a launch passed, and `{reason, until}`, a finite hold on the cap slot that `reserve-lane` or `park-lane` writes; a relaunch, `release-lane` and a confirmed close drop it. |
| `touched`, `in_scope`, `carried` | The touched set the admission judged, the append-only paths left out of the overlap judgement, and `{item, tracker, repo, at}` per item the admission joined to this lane. [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) and [§ Caps](../references/lane-directive.md#caps) state the judgement. |
| `obligation` | `{repo, item, parent_repo, parent_item}`, the item's original lineage, the parent pair named together or null together. A launch binds it on a record that carries none, a first launch naming none and naming `repo` records the item as its own parent, and a differing one refuses `obligation-conflict` ([lane-directive.md § Obligation lineage](../references/lane-directive.md#obligation-lineage)). |
| `tier`, `tier_inputs` | The tier the first launch's brief states, from its workflow verb (`start` is `standard`) or its one whole `item-tier` line, and `{estimate, delta, paths}`. |
| `refresh`, `desktop` | `true` on a refresh lane, and where the overseer granted the owner's live display; every later launch keeps `desktop`. |
| `parked`, `park_owed`, `sandbox` | `parked` `{head, repo, at, pr?, until_pr?, until_repo?}` is a hosted lane's park after its sandbox stop. `park_owed` and `sandbox: "standing"` mark a stopped lane whose park's sandbox stop has not confirmed. |
| `pending_pr`, `pauses`, `capacity_wait`, `walled` | A relaunch moves `parked`'s pull request into `pending_pr` `{pr, repo, head, until_pr?, until_repo?}` and its span into `pauses` as `{from, to, cause: "parked"}`. `capacity_wait` `{at}` stands from a relaunch's first capacity refusal and closes into `pauses` with `cause: "capacity"`. `walled` `{at}` stands while the watch sees a usage wall, then closes into `pauses` with `cause: "walled"`. The merge cycle reads `pauses` as paused time. |
| `wake` | `{pid, start}` of a detached print-mode turn beside the lane's pane; a relaunch beside a live wake refuses. |
| `directive_send` | A cloud lane's last directive send. `orch-runtime send` writes it through `record-directive-send` as `owed` before the send and settles it from the mailbox's receipt after, so a send whose outcome is unknown is refused rather than sent twice. |
| `kept`, `kept_mail` | The reason a close kept the lane's worktree, and the path where the worktree package kept a lane mailbox it could not join; the close writes both. |
| `model_check` | [§ Model checks](#model-checks). |
| `cycle` | The merge cycle the confirmed close writes from the delivery, kept by later launches; [`ops/cycle.rs`](../runtime/src/ops/cycle.rs) owns its fields, among them `obligation`, `stages` and `rounds`. |

A lane whose launch this runtime did not run, surface 2 or 3, has its record written whole by `record-surface-lane` step `create` and changed by step `merge`; either refuses `surface-lane` on a tmux lane. `orch-runtime state merge --fleet --lane [ITEM] [FILE]` replaces the members the file names and binds `obligation` as the launch does.

A cloud launch's confirmed outcome carries `cloud_repo_access`, `{repositories, url}`: the repositories to check by hand and the session URL where the overseer answers repository-access cards.

## Recording policy

Each durable record below has its readers, its shape and a retention rule. The runtime reads these settings from the caller's environment, then the private env file (`.env.local`, or the file `KENDEX_ENV_FILE` names), then the `[env]` of `.kendex/settings.toml`, then of `kendex.settings.toml`, then the default; an empty value is unset:

| Setting | Meaning | Default |
|---|---|---|
| `ORCH_FLEET_LOG_ROW_BYTES` | Most bytes one fleet-log row's `text` carries | `600` |
| `ORCH_TAKEOVER_ROWS` | Fleet-log rows a successor overseer reads at takeover | `10` |
| `ORCH_RECORD_RETENTION_DAYS` | Days past a record's stamp before the retention duty removes it | `5` |
| `ORCH_PROGRESS_REPORT_DIR` | Owner progress report directory; a relative path joins the main checkout | `tmp/progress-reports` |
| `ORCH_ARCHIVE_ROOT` | Absolute directory the prune and close-out archive into; empty keeps no archive ([settings.md](../references/settings.md)) | empty |

| Record | Readers | Retention |
|---|---|---|
| Fleet log rows, `fleet_log[]` | The successor overseer reads the last `ORCH_TAKEOVER_ROWS` rows but `cycle` and `token` through `orch-runtime state log takeover --fleet`, which answers `rows: []` with no fleet record. Audits read the `proposal` and `ruling` rows through `state log audit --fleet`. `orch-runtime report render` reads the `use1` rows and the `cycle` rows. | A row whose `at` is past the retention moves into the prune archive. A row with no ISO 8601 UTC `at` stays. |
| Standing instructions, `standing[]` | The successor overseer, through `orch-runtime state get --fleet /standing`. | None: a row leaves when the overseer lifts it. |
| Overseer handoff file, `handoffs/OVERSEER-HANDOFF.md` | The successor overseer, at [oversee-takeover.md § 1](../workflows/oversee-takeover.md#1-read-the-mailbox-and-handoff); its shape is [communication-modes.md § Handoff](../references/communication-modes.md#handoff). | None. A file under `handoffs/` named for an item leaves at the item's close-out. |
| Lane records, `lanes[]` | The watch, the close, the overseer, and every rollup of a lane's times. | Judged by the record's recorded end: the latest confirmed close of its session, else its item's latest `close` row, else its `launched_at`. A record leaves once it reads ended (status `done`, or a confirmed close of its current session stands), that end is past the retention, and its worktree reads released or `kept`; the kept worktree stays. Once every record of an item has left, the item's record leaves too. The fleet's first record stays. |
| Lane status file, `tmp/lane-status-[ISSUE_ID].md` under the lane's `mail_root` | The overseer, through [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads), and the watch. Its shape is [oversee.md § Lane directive](../workflows/oversee.md#lane-directive)'s. | Leaves with the lane's worktree. The item's close-out removes one standing directly in the state directory. |
| Lane mailbox, `tmp/lane-mail/[ISSUE_ID]/` | The lane and the overseer, through `lane-mail`, whose `--help` defines the envelope. | `worktree remove` moves it to the main checkout's `tmp/lane-mail/` (`worktree remove --help`). The close-out archives it and removes nothing; no retention removes it. |
| Overseer mailbox, `tmp/lane-mail/overseer/` | The overseer, the owner relay and peers, through `lane-mail`. | Each retention pass runs `lane-mail compact --item overseer` before its prune; a refused compaction fails the pass and the prune still runs. |
| Overseer session rows, `session-[SERVER_PID]-[PANE].jsonl` in the overseer mailbox | The watch, registration and succession; the fleet repository's store writer reads the `SessionStart` rows to find the overseer's transcript. Tell the fleet overseer first (`lane-mail peer send --repo fleet`) before changing this shape or path. | [§ Prune](#prune). |
| Context reading, `context.json` in a lane's mailbox and in the overseer mailbox | Written by `orch-runtime turn-end` at each turn end that reads a transcript, with a reading or with `gap` naming why it took none; a Copilot session's at each usage reading. The watch judges the overseer's reading. Read a lane's between its turn ends under its `mail_root`, a hosted lane's through `orch-runtime host --host [HOST] cat --item [ITEM] [PATH]`. Treat no record, another session's record, an unreadable record and a stale one as unknown, never as room, and apply [oversee-events.md § Hand off a lane before it runs out](../references/oversee-events.md#hand-off-a-lane-before-it-runs-out). | Follows its mailbox. |
| Lane session rows, `session-rows.jsonl` in a lane's mailbox | The watch and `orch-runtime lane status` judge local lanes from their prompt, tool and turn-end rows. Pane dialogs and walls take priority except on Pi. Codex's current failed-turn pane can end a Working row. With no row, Claude Code, Codex and Copilot CLI use the pane; Pi stays unjudged as `rows-none`. Hosted Pi lanes use their Stop rows; other hosted lanes use their provider's pane. | Follows its mailbox. |
| Lane report state, `sent-count` in a lane's mailbox | `orch-runtime turn-end`'s idle judge, its one writer and reader. | Follows its mailbox. |
| Owner progress report, `MM-DD-HH-MM.md` under `ORCH_PROGRESS_REPORT_DIR` | The owner, and `orch-runtime report`, which reads the reports' names and modification times and none of their content. A report file advances the report cadence; only the receipt of a report sent to the owner through the overseer mailbox advances the owner report's window, so a report written and never sent is never counted as received ([`watch/report.rs`](../runtime/src/watch/report.rs)). Its shape is [communication-modes.md § Status report](../references/communication-modes.md#status-report); each decision names the paths it chose between and the outcome of each. | Pruned past the retention. |

List the closed cloud sessions by account for the archive relay; add `select(.at > "T")` before `.text` for closes after UTC time T:

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --fleet /fleet_log)" && jq -r '[.result.value[] | select(.kind == "close") | .text | capture("session=(?<session>[^ ]+) account=(?<account>[^ ]+)")] | group_by(.account)[] | "\(.[0].account) \(map(.session) | join(" "))"' <<<"$STATE_READ"
```

`orch-runtime state progress-report-path [--succession]` answers a progress report's path as `result.path` and creates its directory: `MM-DD-HH-MM.md` in UTC, `MM-DD-HH-MM-succession.md` for a succession's. When to write one is [oversee.md § 5](../workflows/oversee.md#5-stop), [§ Succession](../workflows/oversee.md#succession) and the [`report-due`](../references/oversee-events.md#report-due) event's.

### Prune

The watch's retention duty prunes the fleet record and its state directory on its cadence; no step prunes by hand. Where no fleet record stands, `state remove` runs the same pass after its close-out.

The duty removes these kinds alone:

- An item's record once every lane record of the item has left, as the lane records row states.
- An item's record no lane record names, last written past the retention, unless it names a linked worktree that stands by its `worktree` or by its `branch` checked out there.
- A closed intent's `intents/[ID].pane`, `intents/[ID].request` and `intents/[ID].job`, once the intent's end and the file's own last write are past the retention. An open intent's files and a `.notice` stay.
- An owner progress report last written past the retention.
- A session rows file whose pane is gone: the tmux server answering at the ambient socket is that pid and holds no such pane. A file `controller.session_rows`, `controller.pending.session_rows` or `pending.session_rows` names stays, as do a link and a file whose server does not answer.
- Lane records and fleet-log rows past the retention.

Every other entry stays whatever its age: a lane's files, every file under `handoffs/`, the mailboxes, the claim store, the watch's own records `oversee-watch.log` and `oversee-watch.err`, every lock file, a waiter's run directory and operator scratch. An entry [§ Item close-out](#item-close-out) names leaves at the item's close-out; any other leaves by hand.

Each unit is archived before it goes, into `ORCH_ARCHIVE_ROOT/[REPO]/oversee/prune-[EPOCH]-[SUFFIX].tgz` with the dropped rows as `records.json`, `[REPO]` the main checkout's directory name. With `ORCH_ARCHIVE_ROOT` empty nothing is archived. Under each leaving record's lock the duty reads it again: a record that moved keeps its item for the next pass, and one whose lock it cannot take stays until a later pass and fails this one. A failed pass is `watch-step-failed step=retention` on the watch's stderr.

### Item close-out

`orch-runtime state remove --item ITEM [--archive PATH]...` closes an ended item out of the state directory. It removes every entry of the item's folder `items/[ITEM]/` but the record's lock file and mutex, every other direct entry of the directory named for the item, and every file under `handoffs/` named for it. The item's lane mailbox, the fleet record and the watch's records stay. A lane's round artifacts live under its worktree's `tmp/` and leave with the worktree.

Before it removes anything, `remove` writes one archive at `ORCH_ARCHIVE_ROOT/[REPO]/oversee/close-[ITEM]-[EPOCH]-[SUFFIX].tgz`, holding every path it removes, the lane mailbox and each `--archive PATH` that stands, which the caller removes after; a relative `--archive` path is the caller's directory's. The archive's `records.json` lists each packed path as a member with role `state` for the item's record and `along` for the rest. With `ORCH_ARCHIVE_ROOT` empty it removes with no copy. It holds the item record's lock across the archive and the removals.

Its reply's `result` carries `removed`, the paths that left; `kept`, the archive or null; and `pruned`, the retention pass it ran where no fleet record stands, else null. A configured root a removal would take along refuses `archive-root-overlap`; an archive it cannot build refuses and removes nothing.

A lane runs it at [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 6. A confined lane's call answers `state-remove: left cause=confined owner=overseer`, exits 0 and changes nothing: the overseer's terminal close removes the item's files. The runtime's close runs the same close-out at a close that ends the item, a terminal tracker verdict or a terminal close of a sandbox its provider does not list; a park, a `keep-sandbox` close or a close of an item still open keeps the files a relaunch resumes into.

## CLI

A workflow reads and writes records through `.agents/skills/orch/scripts/orch-runtime`; `orch-runtime --help` and `orch-runtime state --help` are the contract. Every verb prints one JSON reply: `ok` true with its `result`, or `ok` false with `refusal.key`, a keyed line on stderr and exit 1. A caller holds a reply in a variable and projects it only after exit 0.

The `state` family names a member by JSON pointer, `/pr_review/mode`:

- Reads: `inspect` (the record under `.result.state`), `get` (the value at the pointer as `.result.value`, `null` where absent, the whole record with no pointer), `exists`, `path`, `cap`, `findings query`, `log takeover|audit`, `progress-report-path`, `handoff-standing`.
- Creation: `init` creates the record and refuses a standing one.
- Pointer writes, each one locked write: `set` and `append` (every pointer and value pair of the call), `set-file`, `append-file [--unique]` and `upsert --key` (the one JSON value a file holds), `increment`, `set-now`, `set-git-head`, `close-all`, `merge`.
- Owned writes: `bucket`, `head-budget take|reset`, `post-pr-stop record|record-if-empty|clear`, `standing add|lift`, `log append`, `findings record`, `new-round-id`, `model-check slot|record|reset|start`, `heal`, `handoff-resume`, `remove`.
- `new-local-key` mints a key and writes nothing.

`set` and `append` read a value as JSON only where it looks like JSON: a `{` or `[` prefix parses, refused `request-invalid` where it does not; `null`, `true`, `false` and an all-digit word are JSON; any other value is the string itself. Pass a plain string bare: `approval`, never `'"approval"'`, which stores the quotes.

The operations run as `.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [FILE]`, `[FILE]` one JSON object tagged by `op` and written with the harness file tool, or `--request-json [JSON]`; a fleet operation takes `--fleet`. The named record writes are `record-round`, `record-panel`, `record-agents`, `record-disposition`, `record-comment-ledger`, `record-route`, `record-dev-return`, `record-pr-progress`, `record-surface-lane` and `record-overseer-ledger`; [`ops/mod.rs`](../runtime/src/ops/mod.rs) `Request` lists the others. A transition's typed result is `.result.report`. `verify-head` reads GitHub before it records: `.result.status` is `complete`, `pending` or `unreadable`, and `.result.verdict` stands only on `complete`; [submit-pr.md](../workflows/submit-pr.md) routes each.

The global `--state-dir <path>`, given before the verb, is the one way a command line names another checkout's state directory. The global `--no-private-env` keeps the settings reader off the project's private env file.

```bash
.agents/skills/orch/scripts/orch-runtime state init --item PROJ-123 --agent backend --worktree /abs/worktree --branch user/proj-123
.agents/skills/orch/scripts/orch-runtime state get --item PROJ-123 /cycles
.agents/skills/orch/scripts/orch-runtime state increment --item PROJ-123 /submit_cycles
.agents/skills/orch/scripts/orch-runtime state head-budget take --item PROJ-123 --kind review-wait --head abcdef01
.agents/skills/orch/scripts/orch-runtime state post-pr-stop clear --item PROJ-123
.agents/skills/orch/scripts/orch-runtime --state-dir /abs/checkout/tmp state get --item PROJ-123 /handoff
```

## Finding occurrences

`finding_occurrences` is `{prior, records}`. `init` writes `prior: "none"`. A record that lacks the member, a batch with unavailable provenance and an unusable failed-check list leave `prior: "unknown"`, which later successful records do not undo. No total is stored: the `findings` verbs derive counts. The member is archived and removed with the item's record.

### Record verified findings

The admission and completion contract for a review producer feeding an item's fix or filing route. The caller supplies the item key and worktree, local or native identity, dry-run status, and its own launch, acceptance and disposition routes, and keeps its panels, deadlines, continuation proofs, advisory failures and round allowances.

1. **Admission, before launch.** Ensure the item's record exists through the caller's initialization route. Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "review"}`, then mint the batch token and stamp its freshness boundary:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
   .agents/skills/orch/scripts/orch-runtime state set-now --item [ISSUE_ID] /review_delegated_at
   ```

   Bind the reply's `.result.report.round_id` and the stored `review_delegated_at` to this batch's assignments. A fresh wave or QA delegation is a batch. A confirming local pass takes fresh admission under its own bound. A proved continuation of the original batch keeps its original binding. Under dry-run, make neither write and keep round provenance unavailable.

2. **Acceptance.** Check each assigned report through the acceptance owner:

   ```bash
   .agents/skills/orch/scripts/orch-runtime review-artifact --text check --file [ARTIFACT_PATH] --worktree [WORKTREE_PATH] --delegated-at [BOUND_REVIEW_DELEGATED_AT] --issue [ISSUE_ID]
   ```

   Under dry-run, leave out the unavailable `--delegated-at` and `--issue`. Keep the caller's own acceptance checks and failure route. Only accepted evidence supplies findings. Keep each finding's original path, batch token, boundary, array and index through disposition, even after another batch starts. A native report's `qa_metadata.review_round_id` must match its assigned token; a dry-run report uses `null`. A missing original binding stays unknown, never the current token. A failed or unavailable advisory review supplies no finding and no clean pass.

3. **Completion, before routing away.** Apply the caller's finding-disposition pass, Step 0 first. Then write the batch file below with the harness file tool from every accepted source, before display deduplication, and before any fix delegation, issue filing, empty-result exit or return, reply-only and bounded confirming passes included. Record each verified true finding that survived Step 0, including one tracked instead of fixed. False claims, questions and Step 0 exclusions add no record. An accepted clean batch is `{"records": []}`. Under dry-run, report the proposed observations and unavailable provenance and write nothing.

```json
{"records":[{"kind":"review","location":"src/x.rs (`f`)","owner":"src/shared.rs (`rule`)","source":{"round_id":"R","artifact":"tmp/review-reviewer-correctness-T.json","array":"blockers","index":0,"identity":["artifact","tmp/review-reviewer-correctness-T.json","blockers",0]}}]}
```

Leave out an absent `owner`. Set `source.round_id` from the original batch token. An original local review's identity is `["artifact", original_path, array, index]`; an inline or PR-level copy's is `["native", source_type, original_id]`, preferring the original comment id and using a thread-only id once. A review-body entry's is `["native", "review-body", original_review_or_comment_id, entry_token]`; a bare `file:line` supplies no native identity, and a copied native finding never takes a local artifact identity. An unavailable round, class or native binding sets `"unknown": true` and leaves that observation out while keeping the other bound records; with none bound the batch is `{"unknown":true,"records":[]}`. Outside dry-run, record it:

```bash
.agents/skills/orch/scripts/orch-runtime state findings record --item [ISSUE_ID] [BATCH_FILE]
```

The recorder keeps the first source provenance. A known identity under the same class adds nothing, even after a new round token or a native retriage. A known identity under another class refuses, lands none of the batch and leaves coverage unknown. A refused record is unread coverage: record an unknown batch through the caller's route before any later query claims complete coverage.

`orch-runtime dev-return check` records a schema-valid receipt's validation refusals in the same way, a failed original and its recovery separately: one `{kind: "validation", check, source: {round_id, receipt, identity: ["receipt", round_id, receipt, check]}}` per distinct name of the receipt's `FAILING:` list. An empty name leaves coverage unknown. A pass, a pending CI, a no-verdict, a missing or invalid receipt and a live run supply no refusal.

### Query and admission

Write a request file as an array of `{kind: "review", location, owner?}` copied from the proposed fix's source finding, or `{kind: "validation", check}` copied exactly from the failed source receipt; never derive a check name from review prose. `orch-runtime state findings query --item [ISSUE_ID] [REQUEST_FILE]` answers `{prior, classes: [{class, observed_count, prior, sources}]}` as the reply's `result`; with no request file it reports every known class. A review request matches a record sharing a location or owner cause key, with no transitive aliases; a validation request matches the exact check name. A request with no usable key reports `observed_count: null` and `prior: "unknown"`. Under unknown prior coverage a count is a lower bound; two attributable sources still establish recurrence. A failed query is unread.

Both direct fix owners read that result before stamping, pruning or changing delegation time, under [design-review.md](../references/design-review.md). Carry the reply's `result` unchanged in the ask or status and in the next delegation, and give the file holding it to `orch-runtime round stamp --finding-occurrences-file`. No observation interrupts active work, changes a disposition, or grants another round or validation start.
