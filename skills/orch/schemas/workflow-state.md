# Workflow State Schema

Orch workflows read and write these records: one record per item, and the fleet's record under the key `oversee`. Read this file when a step, a reply or a refusal names a member.

**Location**:

- An item's record is `<state-dir>/items/[ISSUE_ID]/workflow-state-[ISSUE_ID].json`. Its folder also holds the item's lock file and mutex.
- The fleet record is `<state-dir>/workflow-state-oversee.json`.
- `<state-dir>` is the global `--state-dir` flag, else `ORCH_STATE_DIR` ([settings.md § Repository and tools](../references/settings.md#repository-and-tools)). A relative path joins the main checkout.
- `orch-runtime state path --item [ISSUE_ID]` prints the record's path.
- A confined lane writes only its own item's folder of the state directory.

The runtime declares the record's typed views in [`state.rs`](../runtime/src/state.rs) and each member's owner in [`ops/records.rs`](../runtime/src/ops/records.rs) (`owned_fields`). A pointer write (`state set`, `append`, `set-file`) into an owned member must hold a value the owner writes.

## Keys

`[ISSUE_ID]` is the workflow-state key, never a bare GitHub issue number. Its forms:

- the tracker identifier, `PROJ-123`, for a tracked issue;
- `issue-<N>` for a GitHub issue;
- `pr-<N>` for a pull request whose branch carries no issue id;
- `directive-<ID>` for an owner-directed micro change, `<ID>` the directive's id;
- `local-<epoch>-<pid>-<random>` for any other work. `orch-runtime state new-local-key` mints it and writes nothing.

A workflow that creates a record under a local key owns it. The workflow passes the key to every round it stamps and removes the record when it ends. The runtime puts the key into the path as given, so every command uses the spelling `state init` was given.

A command addresses an item as `--item [ISSUE_ID]`, and the fleet record, key `oversee` ([§ Oversee state](#oversee-state)), as `--fleet`.

## Schema

`orch-runtime state init --item [ISSUE_ID]` writes the init object, `init_document` in [`state.rs`](../runtime/src/state.rs). `--agent`, `--worktree` and `--branch` fill their members; `--qa-labels` and `--sub-issues` take JSON arrays. Later operations add the other members of [§ Field Definitions](#field-definitions).

## Field Definitions

The Owner column names the writer. An `op` request is `orch-runtime op --item [ISSUE_ID] --request [FILE]` with the request's `op` and, where shown, its `step` or `entry` ([§ CLI](#cli)). A `state` verb is `orch-runtime state ...`.

| Field | Type | Owner | Meaning |
|---|---|---|---|
| `issue_id` | string | `state init` | The key. |
| `agent` | string | `state init` | The primary dev agent type. |
| `worktree` | string | `state init`, then `record-route` | The item's worktree, an absolute path. |
| `branch` | string | `state init`, then `record-route` | The item's branch. |
| `tier` | string | `record-route` | The cycle the item runs: `micro`, `small` or `standard`. Absent, no tier bound applies. On a `small` item, `state cap` reads `REVIEW_MAX_CYCLES` as at most 1 and `REVIEW_MAX_EXTERNAL_ROUNDS` as at most 2. |
| `review_floor` | string | `record-route` | The lowest tier a directed change's review keeps, one of the three tier words. |
| `sub_issues`, `qa_labels`, `near_ceiling` | string[] | `state init`, then `record-dev-return` | The last recorded dev round's return: the bundled child issues, the QA trigger labels, and the `byte-ceiling` `near-ceiling=` lines that name a blob near the byte ceiling. `record-dev-return` replaces each member it names and keeps the others. The next round's delegation renders one `Near-ceiling:` line per entry. |
| `child_sessions` | object | `record-agents` steps `child-open`, `children-closed`, `slots` | Per logical agent name: `{status, agent_id, runtime_agent_type, agent_type_fallback, opened_by, runs_in}`. `child-open` sets `status` to `active`; `children-closed` sets it to `closed`. `opened_by` is the lead process that opened the child, `{session_id, session_since, pid, start}`. `runs_in` is `lead` for a Claude Code or Codex child, `own` otherwise. `slots` closes an in-lead child whose opener reads gone (`ended: holder-gone`) and reports the slots the others hold. |
| `review_agents` | string[] | `record-agents` steps `active`, `cleared` | The reviewers the current wave runs. `cleared` empties it, `review_agent_ids` and `review_wave_done` for the next wave. |
| `review_agent_ids` | object | `record-agents` steps `active`, `cleared` | Reviewer name to session id. Reuse an id before spawning. |
| `review_agent_runtime_types` | object | `record-agents` step `active` | Reviewer name to the runtime agent type it was spawned as. |
| `review_wave_done` | string[] | `record-agents` steps `wave-start`, `returned`, `cleared` | The reviewers whose artifact returned in the current wave. `wave-start` empties it. |
| `reviewer_slots_observed` | number | `record-agents` step `wave-start` | The spawn count the harness allowed, `slots_observed`. While set, it is the wave size. |
| `json_paths` | string[] | `record-agents` step `returned` | Every accepted review artifact path, each once. |
| `pre_delegate_sha` | string or null | `record-round` step `base` | The worktree's HEAD before the delegation, as the runtime read it. It scopes a re-review's diff range. |
| `review_fix_round` | boolean | `record-round` step `base` with `review_fix: true` | `true` once the review's fix round ran; never cleared. At a `REVIEW_MAX_CYCLES` of 0, `state cap --item` reads `below` until it is set and `at-cap` after. |
| `dev_delegated_at`, `review_delegated_at` | number | `record-round` step `delegated` with `round: dev`, `ci` or `review` | The delegation's epoch second: a dev or CI round's, or a review round's. `review-artifact check --delegated-at` takes the review round's as the freshness boundary. |
| `cycles` | number | `record-round` step `counted` with `counter: fix` | Fix rounds run. Summaries read it; it decides no cap. |
| `rereview_cycles` | number | `record-panel` with `panel: rereview` | Re-review cycles entered. Recording the rereview panel raises it in the same write, and refuses at the `REVIEW_MAX_CYCLES` limit. |
| `first_panel`, `rereview_panel`, `verification_panel` | object | `record-panel` with `panel: first`, `rereview` or `verification` | `{agents, reason, external?, domain_reasons?}`: distinct reviewers and a non-empty reason. On a `small` item, a panel carries a boolean `external` and at most three reviewers, the external lane counted. A later panel that holds every `first_panel` reviewer needs `domain_reasons` saying why the fix diff concerns each. |
| `submit_cycles` | number | `state increment` from [submit-pr.md](../workflows/submit-pr.md) | Re-submit loops run. |
| `dev_round_id`, `review_round_id`, `ci_round_id` | string | `begin-round` with `kind: dev`, `review` or `ci` | The round token, minted before each delegation and carried in it. A `dev` or `review` round opens a stage. A `ci` round opens none and keys its cleanup in `round_prunes`. The dev token is the completion artifact's identity ([dev-return.md](dev-return.md)) and, on a fix round, the delegated-item record's ([dev-round.md](dev-round.md)). |
| `stages` | object[] | `begin-round`, `record-validation-admission`, `accept-result`, `reconcile-round`, `validate stop`, `record-push`, `orch-runtime validate start`, `dev-return check` | One entry per round or validation run ([§ Stages](#stages)). |
| `validate_rounds` | object[] | `dev-return check`, `record-push` | One `{round_id, receipt, kind, mode, seconds, lanes?, selection?}` row per schema-valid dev receipt with validation time; a recovery's receipt takes its own row. A push records one more row per restack run, with `round_id` `restack-<run id>`. |
| `round_prunes` | object | `prune-round` | Round id to `{action, used_pct, mark_pct, bytes}` for the round's Cargo cleanup. `action` is `pruning` until the cleanup answers, then `pruned`, `failed` or `unknown`. `below-mark`, `target-elsewhere` and `no-worktree` record a cleanup that did not run. |
| `recovery_round_id`, `round_recovery` | string, object | `orch-runtime round recover` | The round a recovery minted for a stalled round, and `{from, to, reason}`. A repeated recovery of the same round gives the same answer. |
| `summary_comment` | object | `accept-result` with `summary_file` | `{id, at, attachments}`: the item's `## Completion Summary` comment on the tracker, created once and updated in place by its id. `attachments` is `{name, url, image}` per link the body carries, rendered on every update. |
| `verification` | object | `record-verification`, through `verify-head` and `verify-pr` | `{head, verdict, reason, source, at}` for a published head. `verdict` is `pass`, `fail` or `none`. `none` holds only where `reason` gives affirmative evidence of absence. A newer head's record replaces the older one. [submit-pr.md](../workflows/submit-pr.md) reads it before the merge step. |
| `fixed_items`, `escalated_items`, `declined_items` | object[] | `record-disposition`, `state bucket`; `record-push` rewrites `commit` | The disposition buckets, each entry keyed by `location` and `description`. A move first drops the entry from each named `drop` bucket, so an item stands in one bucket. A `commit` of `dropped:<sha>` marks a fix whose commit a rebase dropped: cite the upstream equivalent, never the SHA. An `escalated_items` entry's `outcome` is `blocked` or `skipped`; absent reads as blocked. |
| `pr_comment_review` | object | `record-comment-ledger`; `record-round` step `counted` with `counter: external` | The comment triage ledger. `iterations` counts the bot triage passes `REVIEW_MAX_EXTERNAL_ROUNDS` bounds. The arrays, each with its entry kind: `fixes[]` (`fix`), `issues_created[]` (`issue` with `origin: triage`), `skipped[]` (`skip`), `replied[]` (`reply`), `proposed_rules[]` (`proposed-rule`, each rule once), `patched_causes[]` (`patched-cause`, `{cause, commit, location, owner?}`) and `frozen_causes[]` (`frozen-cause`, `{cause, issue}`). [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) reads the cause entries. |
| `pr_review_baseline` | object or null | `record-comment-ledger` entry `baseline` | `{last_threads}`: the unresolved review-thread ids at the end of the last triage pass. A thread whose id is absent here is new. |
| `audit_issues_created` | string[] | `record-comment-ledger` entry `issue` with `origin: audit` | The issue ids the review's audit filed. |
| `rebase_map` | object | `record-push` | Pre-rebase SHA to post-rebase SHA, or `dropped`, read from the worktree's `kendex-rebase-map`. The same write rewrites `fixed_items[].commit` and `pr_comment_review.fixes[].commit`. Resolve an artifact's SHA through the map until no key matches. |
| `restacks` | number | `record-push` | Restack hops reconciled. A hop the map already holds adds none. Absent reads 0. |
| `push_attempt` | object | `record-push` | The push, written `attempted` before it starts. A push whose answer was lost is settled from the remote before the next push. |
| `restack_skips` | object[] | `record-pr-progress` step `restack-skip` | `{head, condition, validated_head, paths}` per restack whose re-test was skipped; a new entry replaces one of the same `head`. `condition` is `no-conflict` or `version-only`. |
| `pr_order` | string | `record-pr-progress` step `order` | When the lane opens its pull request: `review-first`, `open-first`, `open-first-returned`, `open-first-pushed`, `push-first`, `push-first-returned` or `push-first-pushed`. Absent, the item runs review-first. |
| `pr_approval` | object | `record-pr-progress` steps `forced`, `reviewer-down` | `forced`: the user chose Force merge; item-wide, never cleared. `reviewer_down`: every reviewer stayed silent past the period, and `PR_REVIEW_ON_TIMEOUT=proceed` proceeded. |
| `children_detached` | boolean | `record-pr-progress` step `children-detached` | `true` once the children's detach ran before the arm, so it runs once. |
| `ci_rerun` | object | `record-pr-progress` steps `ci-rerun`, `ci-rerun-run` | `{head, run, at}`: the one automatic rerun of a transient CI failure on `head`. It is recorded before the rerun is asked for; `run` is null until the rerun's run is known. A head with a record is never rerun again. |
| `pauses` | object[] | `record-pr-progress` steps `merge-asked`, `merge-answered` | `{from, to, cause: "merge-hold"}`: the lane's merge question, open from its ask to its answer. At most one stands open. |
| `queue_watch` | object | `record-queue-watch` | The merge-queue wait's memory for one head and one arm, written before each poll. |
| `qa_decision` | object | `record-qa-decision` | The review's QA routing and the QA reviews recorded. [review-pr.md](../workflows/review-pr.md) owns its steps. |
| `skip_qa` | boolean | `state init`, `state set` by the user and [review-pr.md](../workflows/review-pr.md) § 5 | `true` skips QA once. The verdict pass sets it back to `false`, records `record-qa-decision` step `skip` and goes to § 7. |
| `post_pr_budgets` | object | `state head-budget take`, `state head-budget reset` | `review_wait` and `ci_fix`, each null or `{head, attempts}`. `take` spends one attempt in one write and answers `continue`, or answers `at-cap` and writes nothing. `review-wait` restarts its count on a new head; `ci-fix` counts across heads. `reset` sets the budget null. |
| `post_pr_stop` | object or null | `state post-pr-stop record`, `record-if-empty`, `clear` | `{name, gate, remaining[], at}`, posted to the pull request as the `## Orchestration stopped` comment `--comment-file` names. `record-if-empty` keeps a standing stop and restamps its `at`. `at` is the epoch second of the last recording, so a reader can tell a stop the lane's current session reached. `clear` lifts the stop. |
| `head_approvals` | object | `approve-head` | The overseer's exact-head approvals, per pull request `owner/repo#pr` (the repository lowercased), then per full head SHA: `{login, attempt, comment}`. `attempt` is null, `{state: attempted}` from before the POST, or `{state: confirmed, review}`. `comment`, where the request names `comment_file`, is `{state: attempted}` or `{state: posted, id}`. The request names the live head. Where the configured login differs from an entry's, a confirmed approval stands, and an entry holding no act takes the configured login. An entry holding an `attempted` attempt or a comment refuses the changed login. |
| `pr_review` | object | `verify-review` | The review gate's record: its mode, per head SHA, and its last verdict, as [gates.md § The review call](../references/gates.md#the-review-call) and [§ Copilot requests](../references/gates.md#copilot-requests) read it. |
| `handoff` | object | `record-handoff`, `resume-handoff` | [§ Handoff](#handoff). |
| `model_checks`, `lane_session`, `model_reset` | object | `state model-check`, the turn end | [§ Model checks](#model-checks). |
| `finding_occurrences` | object | `state init`, `state findings record`, `dev-return check` | [§ Finding occurrences](#finding-occurrences). |

### Stages

A `stages[]` entry is `{kind, round_id, start, end}` in epoch seconds, with `outcome` once closed. `kind` is `dev`, `review`, `implement`, `fix` or `validate`.

- `begin-round {kind, body_revision?, group?, exception?}` opens a `dev` or `review` entry in the same write as the token. It closes every earlier open entry of the kind at the new start, with `superseded: true`.
- `body_revision` is the item body's `updatedAt` as the caller read it. The reply's `body_moved` is `true` where it is later than the kind's previous recorded revision. `group` is `{n, of}`. `exception` is `{by, id, excused}`: the known failing checks the round may end with.
- `orch-runtime dev-return check` sets the dev entry's kind to `implement` or `fix`.
- `record-validation-admission {round_id, run_dir?, attempt?}` opens `{kind: "validate", round_id, run_dir, start, end: null}` before the run. Without `run_dir`, the runtime mints the run id, and `run_dir` is `<worktree>/tmp/dev-validate-<run_id>`. A repeat while an admitted run of the round stands open returns that run; `attempt: next` mints another.
- `orch-runtime validate start` writes the run's `proof` and `job` on its entry before the launch. `validate stop --item [ISSUE_ID] --run-dir [RUN_DIR]` writes `stop: {at}` before it ends the job.
- `accept-result {round_id, outcome, run_dir?, end?, authorization?, summary_file?, attachments?}` closes the round's own entry, or with `run_dir` the run's `validate` entry. `outcome` is required: `pass`, `fail`, `no-verdict`, `lost`, `stopped`, `no-change`, `handed-over` or `pass-excused`. `end: {from_artifact: PATH}` takes the file's modification time, bounded to `[start, now]`; without it, the entry ends now. A repeat changes nothing and reports the recorded close. A superseded entry cannot be accepted.
- `reconcile-round {round_id}` closes each open `validate` entry of the round whose run will not end itself. The outcome is the run's sentinel word; `stopped` for a run never started or one a `stop` stands on; `lost` for a gone run with no sentinel and no `stop`. A run still running, or one that cannot be read, stays open.
- `record-push` writes `{kind: "validate", reason: "restack", round_id: null, run_dir, start, end, outcome, proof}` once per finished restack run directory.

`stages[].authorization` is `{by, id}`, `by` being `overseer` or `owner-directive`. A round's own `accept-result` writes it, as part of the acceptance's identity: a repeat names the same one. A `directive-[ID]` item's round must name `{by: owner-directive, id: [ID]}`. `{by: overseer, id}` names the inbox envelope that answers the lane's own `lane-question`, or an owner's directive the overseer relayed. It never names a launch ruling, a fleet-log row or a session id.

`orch-runtime cycle stages [ITEM]` prints the item's `stage item=` rows, sorted by start. The close's merge cycle copies the entries to `lanes[].cycle.stages`.

### Handoff

`handoff` is the lane's hand-off record. `record-handoff` writes `{written_at, round_id, merged, remaining, branch, worktree, open_pr, traps, context, relaunch}`. On a model switch it also writes `session_id`, `pane_key`, `cause` and `model`.

- `round_id` names a stage the item ran.
- `relaunch` is `fresh` or `resume`, the session route a relaunch takes. Absent reads `fresh`.
- `context` is the context decision that caused the hand-off, as the turn end judged it.
- `written_at` is the request's ISO 8601 UTC time, no later than the clock, else the runtime's clock.
- While the record carries no `resumed_at`, every field but `written_at` is its identity. The same content again reports `recorded_now: false`. Other content needs `supersede: true`. The next `record-handoff` replaces a record that carries `resumed_at` whole.
- No pointer write reaches an item record's `/handoff`.

`orch-runtime state handoff-standing --item [ISSUE_ID] [--worktree PATH]` reads the item's record in the state directory, then in `<root>/tmp`. `<root>` is `--worktree`; without it, and with no `--state-dir`, it is the linked worktree the caller runs in. The reply's `standing` is the answer, not the exit status:

- `stands`, with the `file` and the `record`;
- `none`, with the first place holding the item's record;
- `unreadable`, with the first place that could not be read.

A lane whose launch forbids writing the main checkout keeps its record in its worktree's `tmp`.

`orch-runtime state handoff-resume --item [ISSUE_ID] [--worktree PATH]` runs `resume-handoff` on every place the record stands. It stamps `resumed_at` once, in epoch seconds. It reports the round, its route, the `remaining` steps and the round's open validation runs, which the continuation waits on. A second resume reports the first stamp. With no standing record it refuses. The watch reports a record with no `resumed_at` as `handoff`.

### Model checks

A model check is a Claude Code session's switch away from its launch model, or a model the turn end cannot read. It is recorded once per launch.

- A lane's turn end keeps its check on its own item record, as `model_checks[session_id]`: `{outcome, session_id, launch_identity, launched, observed, at, cause}`, `outcome` being `switched` or `unavailable`. On a switch, the turn end writes the `handoff` the replacement resumes from, then marks the check `recovery_started`.
- The turn end also keeps `lane_session`, `{session_id, launch: {pid, start}}`: the session a cleared start's harness began. At a replacement's first turn end it keeps `model_reset`, `{session_id, launch_identity}`.
- The watch's lane pass reads these three members of a local lane's item record. It binds the fleet lane to `lane_session`. It writes the lane record's `model_check` with a `model-switched` or `model-unavailable` fleet-log row, and starts `recover-lane-model` for a started switch. From `model_reset`, it writes the check `passed` and a `model-recovery-reset` row.
- `recover-lane-model` counts the lane's recoveries since its last `model-recovery-reset` row. At `ORCH_MODEL_RECOVERY_LIMIT` ([settings.md § Fleet lanes](../references/settings.md#fleet-lanes)) it relaunches nothing and appends one `model-recovery-limit` row.
- A hosted lane's switch is kept on the item record on its host; the hook finds the host through the lane's launch record. A failed stop of the predecessor is kept as `handoff.stop_failure`.
- `orch-runtime state model-check slot|record|reset|start` make these writes. `slot` holds the once-only notice of an unavailable model per session.

The fleet record's `controller` member keeps the controller's check by the same rule.

## Oversee state

The fleet record `workflow-state-oversee.json` holds the init object and the members below. `orch-runtime state init --fleet` creates it. The watch reads it as its `--file` ([oversee.md § Lane record](../workflows/oversee.md#lane-record)).

| Field | Type | Owner | Meaning |
|---|---|---|---|
| `lanes` | object[] | `launch-lane`, `close-lane`, `park-lane`, `reserve-lane`, `release-lane`, `admit`, `state merge`, `record-surface-lane`, the watch | One record per lane ([§ Lane records](#lane-records)). |
| `tmux` | object | `launch-lane` | `{session}`: the tmux session the fleet's lane windows open in. The first launch writes it. Later launches read it where `AGENT_RUNTIME_TMUX_SESSION` names none ([lane-directive.md § Tmux session](../references/lane-directive.md#tmux-session)). |
| `controller` | object | agent-runtime's controller transitions, `orch-runtime register --fleet` | The overseer session ([§ Controller](#controller)). |
| `intents` | object[] | agent-runtime's journal | One row per lane or controller operation with a live effect: its phase, obligations and outcome. `orch-runtime state inspect --fleet` lists the open ones under `open_intents`. |
| `handoff` | object | `record-overseer-ledger` entry `handoff` | The overseer's own hand-off: `{handoff_file, pane_key, session_id, context, written_at}`. `written_at` is stamped under the fleet log's time rule. |
| `last_backlog_audit` | object | `record-overseer-ledger` entry `backlog-audit` | `{at, backlog}`: the team Backlog count at the last full audit, stamped by the runtime. The [heartbeat audit](../references/heartbeat-audit.md) reads it. |
| `launch_queue` | string[] | `record-overseer-ledger` entry `launch-queue` | The items the last selection chose and has not launched, in launch order, replaced whole. It holds the order, never the membership: the watch names each owed tracker item under every heartbeat. |
| `triaged` | object[] | `record-overseer-ledger` entry `triage` | `{issue, reason, verdict}` per issue the triage verifier judged, `verdict` being `kept` or `canceled`. The watch rebuilds its acknowledged triage keys from it. |
| `alerts_triaged` | object[] | `record-overseer-ledger` entry `alert-verdict` | `{repo, kind, number, verdict, item, reason}` per security alert judged. `verdict` is `filed` with its fix item, or `dismissed` with `item` null ([security-alerts.md § Triage](../references/security-alerts.md#triage)). The watch reports no alert it names. |
| `standing` | object[] | `state standing add`, `state standing lift` | The owner's standing instructions, `{at, id, scope, end, text}`. `add` appends one row and stamps an absent `at`. `lift` replaces the array with the file's and appends one `ruling` row naming the ids that left. [communication-modes.md § Recording](../references/communication-modes.md#recording) says when to write a row. |
| `fleet_log` | object[] | `state log append`, and the writers named below | One `{at, kind, item, text}` row per entry ([§ Recording policy](#recording-policy)). |

`fleet_log` kinds are `proposal`, `ruling`, `close`, `peer`, `use1`, `cycle`, `token`, `landing-disposed`, `model-switched`, `model-unavailable`, `model-recovery-limit` and `model-recovery-reset`.

- The confirmed close writes `close`, `cycle` and `landing-disposed`. `orch-runtime cycle rollup` writes `cycle`. The model checks write the `model-` kinds.
- Every other row goes through `state log append`, never a pointer `append`. It stamps an absent `at`. A given `at` is `YYYY-MM-DDThh:mm:ssZ` and no later than the clock, and `text` is at most `ORCH_FLEET_LOG_ROW_BYTES`.
- `text` is one line and never a token value. A `use1` row also carries `outcome`.
- [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules) says when to write each kind.

A cloud lane's close writes one more `close` row: `cloud lane closed; session=ID account=ACCOUNT`, with `none` for a member the record lacks. Where the lane recorded a directive send, the row continues with ` send=RESULT credit=DOLLARS locked=REASON cli=TEXT`, the CLI's words cut to 300 characters. The archive list in [§ Recording policy](#recording-policy) parses that form.

### Controller

`controller` is the overseer session's record. Agent-runtime's `controller` module owns the shape:

- its launch identity: `harness`, `account`, `home`, `model`, `class`, `effort`, `cwd`, `permission`, `extra_args`;
- its pane: `server`, `server_start`, `server_socket`, `pane`, `window`, `session_rows`;
- its process, `harness_pid` and `harness_start`, and its native `session_id`;
- `generation`, `pending`, `exit`, `off` and `watch`.

The writers:

- A confirmed `start-controller` or `request-transfer` publishes the record at the next `generation`, from its typed `pending` controller and the identity it observed.
- `orch-runtime register --fleet` records a hand-opened session through `adopt-controller`. Where the record names the same pane on the same server, the adoption keeps the record and its generation, replaces each launch field the request names, and drops `pending`, `exit` and `off`. Otherwise it writes the session's record at the next generation.
- A succession carries no `watch` and leaves the member as it stands.

`watch` names the fleet watch a confirmed `start-controller` launched or found claimed. The watch's claim `oversee-watch.pid`, beside the fleet record, stays the watch's liveness record.

| `watch` | When |
|---|---|
| `{runner: systemd, unit}` | The job launcher started the watch as a user unit. |
| `{runner: setsid, pid, start}` | The launcher started it as a process group; `pid` and `start` are the group leader's. |
| `{runner: setsid, pid}` | The launcher's record names the group without its leader's start. |
| `{runner: unread}` | The launcher's record names nothing of the job yet. |
| `{runner: claimed, pid, start}` | The start found the watch already claimed; `pid` and `start` are the claim's own identity. |

### Lane records

A first `launch-lane` appends the record `{item, tracker, repo, harness, window, account, host, kind, mail_root, surface, model, effort, class, class_reason, permission, session_id, session_since, launched_at, running_at, status, over_cap, allow_all, tier, tier_inputs, launch}`, with `status` `preparing`. `item` is the record's identity. [state.rs](../runtime/src/state.rs) `Lane` is the typed view; [`ops/lane.rs`](../runtime/src/ops/lane.rs) holds the writes.

A relaunch keeps every member its request leaves out. `host` and `kind` are always the launch's own. `harness`, `account`, `model` and `effort` reach the record when the launch confirms, each null where the request named none. A relaunch keeps `tier` and `tier_inputs`; a launch over a `done` record writes its own brief's.

| Member | Meaning |
|---|---|
| `tracker`, `repo`, `harness` | What the close reads the item and stops the harness by. Where the record and the request both leave `tracker` empty, a tracker-identifier key derives `linear`. An `issue-N` key derives none, so the request names one. |
| `window`, `launch` | The lane's tmux window and its confirmed identity `{pane, server, server_start, pid, start}`; null at `preparing` and on a cloud lane. The close stops a local harness by `pid` and `start`. |
| `account`, `home`, `home_implicit` | The account the lane spends, the home its sessions ran under, and `true` where the launch named no home. |
| `host`, `kind`, `mail_root`, `checkout`, `checkout_common` | Where the lane runs. `host` is null for this machine, `claude-cloud`, or a provider path. `kind` is `local`, `claude-cloud` or `ssh` ([lane-host.md § Host kinds](lane-host.md#host-kinds)). `mail_root` is the lane's worktree as its host sees it. `checkout` is the checkout a hosted lane launched from. `checkout_common` is the canonical common git folder admission read from the checkout at `mail_root`. A launch writes it on a new record or a changed `mail_root`; a relaunch over the same `mail_root` keeps it. It is absent where admission read no checkout, where the launch reads no settings or grants, and where the folder lies under another `.git`, the lane's root or a folder the lane's grants make writable. The close removes a clean, merged worktree only from the main checkout of this folder, else of the overseer's own. |
| `surface` | `tmux`, the lane operations' one surface. A record a harness's own launcher runs carries another, which `record-surface-lane` steps `create` and `merge` write. |
| `model`, `effort`, `permission`, `allow_all` | The launch line's model, effort word and permission word, each null where the line names none. `allow_all` is whether a Copilot lane's line grants the full allow-all mode; it is null on every other harness. |
| `class`, `class_reason`, `class_missed` | The model class the assignment runs at (`top`, `standard`, `light`, `fast`) and its reason. `class_missed`, `{class, cause, at}`, stands after a `no_landing` close retired an attempt below `standard`. While it stands, no launch below `standard` runs the item. |
| `session_id`, `session_since`, `launched_at`, `running_at` | The bound harness session; the UTC time the launch or relaunch started; the first launch's time; the time the lane read `running`. The first record's `launched_at` is the fleet start the watch's `--since` takes. |
| `status` | `preparing`, `running`, `stopped`, `parked` or `done`. |
| `over_cap`, `reservation` | The over-cap reason a launch passed. `reservation`, `{reason, until}`, is a finite hold on the cap slot that `reserve-lane` or `park-lane` writes; a relaunch, `release-lane` and a confirmed close drop it. |
| `touched`, `in_scope`, `carried` | The touched set the admission judged; the append-only paths left out of the overlap judgement; and `{item, tracker, repo, at}` per item the admission joined to this lane. [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) and [§ Caps](../references/lane-directive.md#caps) state the judgement. |
| `obligation` | `{repo, item, parent_repo, parent_item}`, the item's original lineage; the parent pair is named together or null together. A launch binds it on a record that carries none. A first launch that names none but names `repo` records the item as its own parent. A differing one refuses ([lane-directive.md § Obligation lineage](../references/lane-directive.md#obligation-lineage)). |
| `tier`, `tier_inputs` | The tier the first launch's brief states, and `{estimate, delta, paths}`. The brief states it by its workflow verb (`start` is `standard`) or by its one whole `item-tier` line. |
| `refresh`, `desktop` | `refresh` is `true` on a refresh lane. `desktop` is `true` where the overseer granted the owner's live display; every later launch keeps it. |
| `parked`, `park_owed`, `sandbox` | `parked`, `{head, repo, at, pr?, until_pr?, until_repo?}`, is a hosted lane's park after its sandbox stop. `park_owed` and `sandbox: "standing"` mark a stopped lane whose park's sandbox stop has not confirmed. |
| `pending_pr`, `pauses`, `capacity_wait`, `walled` | A relaunch moves `parked`'s pull request into `pending_pr`, `{pr, repo, head, until_pr?, until_repo?}`, and its span into `pauses` as `{from, to, cause: "parked"}`. `capacity_wait`, `{at}`, stands from a relaunch's first capacity refusal, then closes into `pauses` with `cause: "capacity"`. `walled`, `{at}`, stands while the watch sees a usage wall, then closes into `pauses` with `cause: "walled"`. The merge cycle reads `pauses` as paused time. |
| `wake` | `{pid, start}` of a detached print-mode turn beside the lane's pane. A relaunch beside a live wake refuses. |
| `directive_send` | A cloud lane's last directive send. `orch-runtime send` writes it through `record-directive-send`: `owed` before the send, settled from the mailbox's receipt after. A send whose outcome is unknown is refused rather than sent twice. |
| `kept`, `kept_mail` | The reason a close kept the lane's worktree, and the path where the worktree package kept a lane mailbox it could not join. The close writes both. |
| `model_check` | [§ Model checks](#model-checks). |
| `cycle` | The merge cycle the confirmed close writes from the delivery; later launches keep it. [`ops/cycle.rs`](../runtime/src/ops/cycle.rs) owns its fields, among them `obligation`, `stages` and `rounds`. |

A lane this runtime did not launch, surface 2 or 3, has its record written whole by `record-surface-lane` step `create` and changed by step `merge`. Neither step applies to a tmux lane. `orch-runtime state merge --fleet --lane [ITEM] [FILE]` replaces the members the file names and binds `obligation` as the launch does.

A cloud launch's confirmed outcome carries `cloud_repo_access`, `{repositories, url}`: the repositories to check by hand, and the session URL where the overseer answers repository-access cards.

## Recording policy

The retention is `ORCH_RECORD_RETENTION_DAYS` days past a record's stamp. [settings.md § Recording](../references/settings.md#recording) holds it, `ORCH_FLEET_LOG_ROW_BYTES`, `ORCH_TAKEOVER_ROWS` and `ORCH_PROGRESS_REPORT_DIR`. [§ Repository and tools](../references/settings.md#repository-and-tools) holds `ORCH_ARCHIVE_ROOT`. [§ Where a setting is set](../references/settings.md#where-a-setting-is-set) gives where the runtime reads each.

| Record | Readers | Retention |
|---|---|---|
| Fleet log rows, `fleet_log[]` | The successor overseer reads the last `ORCH_TAKEOVER_ROWS` rows, `cycle` and `token` rows excepted, through `orch-runtime state log takeover --fleet`; with no fleet record it answers `rows: []`. Audits read the `proposal` and `ruling` rows through `state log audit --fleet`. `orch-runtime report render` reads the `use1` and `cycle` rows. | A row whose `at` is past the retention moves into the prune archive. A row with no ISO 8601 UTC `at` stays. |
| Standing instructions, `standing[]` | The successor overseer, through `orch-runtime state get --fleet /standing`. | None: a row leaves when the overseer lifts it. |
| Overseer handoff file, `handoffs/OVERSEER-HANDOFF.md` | The successor overseer, at [oversee-takeover.md § 1](../workflows/oversee-takeover.md#1-read-the-mailbox-and-handoff). Its shape is [communication-modes.md § Handoff](../references/communication-modes.md#handoff). | None. A file under `handoffs/` named for an item leaves at the item's close-out. |
| Lane records, `lanes[]` | The watch, the close, the overseer, and every rollup of a lane's times. | Judged by the record's recorded end: the latest confirmed close of its session, else its item's latest `close` row, else its `launched_at`. A record leaves once it reads ended, that end is past the retention, and its worktree reads released or `kept`. Ended is status `done`, or a confirmed close of the current session on a record neither `stopped` nor `parked`. The kept worktree stays. Once every record of an item has left, the item's record leaves too. The fleet's first record stays. |
| Lane status file, `tmp/lane-status-[ISSUE_ID].md` under the lane's `mail_root` | The overseer, through [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads), and the watch. Its shape is [oversee.md § Lane directive](../workflows/oversee.md#lane-directive)'s. | Leaves with the lane's worktree. The item's close-out removes one standing directly in the state directory. |
| Lane mailbox, `tmp/lane-mail/[ISSUE_ID]/` | The lane and the overseer, through `lane-mail`, whose `--help` defines the envelope. | `worktree remove` moves it to the main checkout's `tmp/lane-mail/` (`worktree remove --help`). The close-out archives it and removes nothing. No retention removes it. |
| Overseer mailbox, `tmp/lane-mail/overseer/` | The overseer, the owner relay and peers, through `lane-mail`. | Each retention pass runs `lane-mail compact --item overseer` before its prune. A refused compaction fails the pass; the prune still runs. |
| Overseer session rows, `session-[SERVER_PID]-[PANE].jsonl` in the overseer mailbox | The watch, registration and succession. The fleet repository's store writer reads the `SessionStart` rows to find the overseer's transcript. Before changing this shape or path, tell the fleet overseer (`lane-mail peer send --repo fleet --file [PATH]`). | [§ Prune](#prune). |
| Context reading, `context.json` in a lane's mailbox and in the overseer mailbox | `orch-runtime turn-end` writes it at each turn end that reads a transcript, with a reading or with `gap` naming why it took none. A Copilot session's is written at each usage reading. The watch judges the overseer's reading. Read and judge a lane's between its turn ends as [oversee-events.md § Hand off a lane before it runs out](../references/oversee-events.md#hand-off-a-lane-before-it-runs-out) says. | Follows its mailbox. |
| Lane session rows, `session-rows.jsonl` in a lane's mailbox | The watch and `orch-runtime lane status` judge local lanes from their prompt, tool and turn-end rows, with the pane and hosted-lane exceptions [oversee-events.md § `idle-after-return`](../references/oversee-events.md#idle-after-return) states. With no row, Claude Code, Codex and Copilot CLI use the pane; Pi stays unjudged as `rows-none`. | Follows its mailbox. |
| Lane report state, `sent-count` in a lane's mailbox | `orch-runtime turn-end`'s idle judge, its one writer and reader. | Follows its mailbox. |
| Owner progress report, `MM-DD-HH-MM.md` under `ORCH_PROGRESS_REPORT_DIR` | The owner, and `orch-runtime report`, which reads the reports' names and modification times but none of their content ([`watch/report.rs`](../runtime/src/watch/report.rs)). [communication-modes.md § Status report](../references/communication-modes.md#status-report) gives its shape, and what a written file and a confirmed receipt each advance. Each decision names the paths it chose between and the outcome of each. | Pruned past the retention. |

List the closed cloud sessions by account for the archive relay. For closes after UTC time T, add `select(.at > "T")` before `.text`:

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --fleet /fleet_log)" && jq -r '[.result.value[] | select(.kind == "close") | .text | capture("session=(?<session>[^ ]+) account=(?<account>[^ ]+)")] | group_by(.account)[] | "\(.[0].account) \(map(.session) | join(" "))"' <<<"$STATE_READ"
```

`orch-runtime state progress-report-path [--succession]` answers a progress report's path as `result.path` and creates its directory. The name is `MM-DD-HH-MM.md` in UTC, or `MM-DD-HH-MM-succession.md` for a succession's report. [oversee.md § 5](../workflows/oversee.md#5-stop), [§ Succession](../workflows/oversee.md#succession) and the [`report-due`](../references/oversee-events.md#report-due) event say when to write one.

### Prune

The watch's retention duty prunes the fleet record and its state directory on its cadence; no step prunes by hand. Where no fleet record stands, `state remove` runs the same pass after its close-out.

The duty removes only these:

- An item's record, once every lane record of the item has left, as the Lane records row states.
- An item's record no lane record names, last written past the retention. It stays while it names a linked worktree that stands, by its `worktree` or by its `branch` checked out there.
- A closed intent's `intents/[ID].pane`, `intents/[ID].request` and `intents/[ID].job`, once the intent's end and the file's own last write are past the retention. An open intent's files and a `.notice` stay.
- An owner progress report last written past the retention.
- A session rows file whose pane is gone: the tmux server answering at the ambient socket is that pid and holds no such pane. A file that `controller.session_rows`, `controller.pending.session_rows` or `pending.session_rows` names stays, as do a link and a file whose server does not answer.
- Lane records and fleet-log rows past the retention.

Every other entry stays, whatever its age: a lane's files, every file under `handoffs/`, the mailboxes, the claim store, the watch's own records `oversee-watch.log` and `oversee-watch.err`, every lock file, a waiter's run directory and operator scratch. An entry [§ Item close-out](#item-close-out) names leaves at the item's close-out; any other leaves by hand.

The duty archives each unit before it goes, into `ORCH_ARCHIVE_ROOT/[REPO]/oversee/prune-[EPOCH]-[SUFFIX].tgz`, with the dropped rows as `records.json`. `[REPO]` is the main checkout's directory name. With `ORCH_ARCHIVE_ROOT` empty, nothing is archived. The duty reads each leaving record again under its lock. A record that moved keeps its item for the next pass. A record whose lock the duty cannot take stays until a later pass, and fails this one.

### Item close-out

`orch-runtime state remove --item ITEM [--archive PATH]...` closes an ended item out of the state directory. It removes:

- every entry of the item's folder `items/[ITEM]/` but the record's lock file and mutex;
- every other direct entry of the state directory named for the item;
- every file under `handoffs/` named for it.

The item's lane mailbox, the fleet record and the watch's records stay. A lane's round artifacts live under its worktree's `tmp/` and leave with the worktree.

Before it removes anything, `remove` writes one archive at `ORCH_ARCHIVE_ROOT/[REPO]/oversee/close-[ITEM]-[EPOCH]-[SUFFIX].tgz`. The archive holds every path `remove` removes, the lane mailbox, and each `--archive PATH` that stands, which the caller removes after. A relative `--archive` path is the caller's directory's. The archive's `records.json` lists each packed path as a member, with role `state` for the item's record and `along` for the rest. With `ORCH_ARCHIVE_ROOT` empty, `remove` removes with no copy. It holds the item record's lock across the archive and the removals.

The reply's `result` carries `removed`, the paths that left; `kept`, the archive or null; and `pruned`, the retention pass it ran where no fleet record stands, else null. A configured root a removal would take along, or an archive `remove` cannot build, refuses the call, and nothing is removed.

A lane runs `remove` at [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 6. A confined lane's call answers `state-remove: left cause=confined owner=overseer`, exits 0 and changes nothing: the overseer's terminal close removes the item's files. The runtime's close runs the same close-out at a close that ends the item: a terminal tracker verdict, or a terminal close of a sandbox its provider does not list. A park, a `keep-sandbox` close, or a close of an item still open keeps the files a relaunch resumes into.

## CLI

A workflow reads and writes records through `.agents/skills/orch/scripts/orch-runtime`. `orch-runtime --help` and `orch-runtime state --help` are the contract. Every verb prints one JSON reply: `ok` true with its `result`, or `ok` false with `refusal.key`, a keyed line on stderr and exit 1. Hold a reply in a variable, and project it only after exit 0.

The `state` family names a member by JSON pointer, such as `/pr_review/mode`. `inspect` answers the record under `.result.state`. `get` answers the value at the pointer as `.result.value`, `null` where absent, and the whole record with no pointer. The pointer writes are `set`, `append`, `set-file`, `append-file`, `upsert`, `increment`, `set-now`, `set-git-head`, `close-all` and `merge`, each one locked write. `orch-runtime state --help` names every verb and what it reads or writes.

`orch-runtime state set --help` states which values `set` and `append` read as JSON. Pass a plain string bare: `approval`, never `'"approval"'`, which stores the quotes.

An operation runs as `.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [FILE]`, or with `--request-json [JSON]`. `[FILE]` is one JSON object tagged by `op`, written with the harness file tool. A fleet operation takes `--fleet`. The named record writes are `record-round`, `record-panel`, `record-agents`, `record-disposition`, `record-comment-ledger`, `record-route`, `record-dev-return`, `record-pr-progress`, `record-surface-lane` and `record-overseer-ledger`; [`ops/mod.rs`](../runtime/src/ops/mod.rs) `Request` lists the others. A transition's typed result is `.result.report`. `verify-head` reads GitHub before it records. Its `.result.status` is `complete`, `pending` or `unreadable`, and `.result.verdict` stands only on `complete`. [submit-pr.md](../workflows/submit-pr.md) routes each status.

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

`finding_occurrences` is `{prior, records}`. `init` writes `prior: "none"`. Three cases leave `prior: "unknown"`: a record that lacks the member, a batch with unavailable provenance, and an unusable failed-check list. Later successful records do not undo it. The member is archived and removed with the item's record.

### Record verified findings

This is the admission and completion contract for a review producer that feeds an item's fix or filing route. The caller supplies the item key and worktree, the local or native identity, the dry-run status, and its own launch, acceptance and disposition routes. The caller keeps its panels, deadlines, continuation proofs, advisory failures and round allowances.

1. **Admission, before launch.** Ensure the item's record exists through the caller's initialization route. Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "review"}`. Then mint the batch token and stamp its freshness boundary:

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

3. **Completion, before routing away.** Apply the caller's finding-disposition pass, Step 0 first. Then write the batch file below with the harness file tool, from every accepted source. Write it before display deduplication, and before any fix delegation, issue filing, empty-result exit or return, reply-only and bounded confirming passes included. Record each verified true finding that survived Step 0, including one tracked instead of fixed. False claims, questions and Step 0 exclusions add no record. An accepted clean batch is `{"records": []}`. Under dry-run, report the proposed observations and unavailable provenance, and write nothing.

```json
{"records":[{"kind":"review","location":"src/x.rs (`f`)","owner":"src/shared.rs (`rule`)","source":{"round_id":"R","artifact":"tmp/review-reviewer-correctness-T.json","array":"blockers","index":0,"identity":["artifact","tmp/review-reviewer-correctness-T.json","blockers",0]}}]}
```

Leave out an absent `owner`. Set `source.round_id` from the original batch token. The identity takes one of these forms:

- an original local review: `["artifact", original_path, array, index]`;
- an inline or PR-level copy: `["native", source_type, original_id]`, preferring the original comment id and using a thread-only id once;
- a review-body entry: `["native", "review-body", original_review_or_comment_id, entry_token]`.

A bare `file:line` supplies no native identity, and a copied native finding never takes a local artifact identity. An unavailable round, class or native binding sets `"unknown": true` and leaves that observation out; the other bound records stay. With none bound, the batch is `{"unknown":true,"records":[]}`. Outside dry-run, record it:

```bash
.agents/skills/orch/scripts/orch-runtime state findings record --item [ISSUE_ID] [BATCH_FILE]
```

The recorder keeps the first source provenance. A known identity under the same class adds nothing, even after a new round token or a native retriage. A known identity under another class refuses: none of the batch lands, and coverage stays unknown. A refused record is unread coverage. Record an unknown batch through the caller's route before any later query claims complete coverage.

`orch-runtime dev-return check` records a schema-valid receipt's validation refusals the same way, a failed original and its recovery separately. It writes one `{kind: "validation", check, source: {round_id, receipt, identity: ["receipt", round_id, receipt, check]}}` per distinct name in the receipt's `FAILING:` list. An empty name leaves coverage unknown. A pass, a pending CI, a no-verdict, a missing or invalid receipt, and a live run supply no refusal.

### Query and admission

Write a request file as an array. Each entry is `{kind: "review", location, owner?}`, copied from the proposed fix's source finding, or `{kind: "validation", check}`, copied exactly from the failed source receipt. Never derive a check name from review prose.

`orch-runtime state findings query --item [ISSUE_ID] [REQUEST_FILE]` answers `{prior, classes: [{class, observed_count, prior, sources}]}` as the reply's `result`. With no request file, it reports every known class. A review request matches a record that shares a location or owner cause key, with no transitive aliases. A validation request matches the exact check name. A request with no usable key reports `observed_count: null` and `prior: "unknown"`. Under unknown prior coverage, a count is a lower bound; two attributable sources still establish recurrence. A failed query is unread.

Both direct fix owners read that result before stamping, pruning or changing delegation time, under [design-review.md](../references/design-review.md). Carry the reply's `result` unchanged in the ask or status and in the next delegation. Give the file holding it to `orch-runtime round stamp --finding-occurrences-file`. No observation interrupts active work, changes a disposition, or grants another round or validation start.
