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

A workflow that creates a record under a local key owns it:

- The workflow passes the key to every round it stamps.
- The workflow removes the record when it ends.
- The runtime puts the key into the path as given, so every command uses the spelling `state init` was given.

A command addresses an item as `--item [ISSUE_ID]`, and the fleet record, key `oversee` ([§ Oversee state](#oversee-state)), as `--fleet`.

## Schema

- `orch-runtime state init --item [ISSUE_ID]` writes the init object, `init_document` in [`state.rs`](../runtime/src/state.rs).
- `--agent`, `--worktree` and `--branch` fill their members; `--qa-labels` and `--sub-issues` take JSON arrays.
- Later operations add the other members of [§ Field Definitions](#field-definitions).

## Field Definitions

The Owner column names the writer. An `op` request is `orch-runtime op --item [ISSUE_ID] --request [FILE]` with the request's `op` and, where shown, its `step` or `entry` ([§ CLI](#cli)). A `state` verb is `orch-runtime state ...`.

| Field | Type | Owner | Meaning |
|---|---|---|---|
| `issue_id` | string | `state init` | The key. |
| `agent` | string | `state init` | The primary dev agent type. |
| `worktree` | string | `state init`, then `record-route` | The item's worktree, an absolute path. |
| `branch` | string | `state init`, then `record-route` | The item's branch. |
| `tier` | string | `record-route` | The cycle the item runs: `micro`, `small` or `standard`. |
| `review_floor` | string | `record-route` | The lowest tier a directed change's review keeps, one of the three tier words. |
| `sub_issues`, `qa_labels`, `near_ceiling` | string[] | `state init`, then `record-dev-return` | The last recorded dev round's return: the bundled child issues, the QA trigger labels, and the `byte-ceiling` `near-ceiling=` lines that name a blob near the byte ceiling. |
| `child_sessions` | object | `record-agents` steps `child-open`, `children-closed`, `slots` | Per logical agent name: `{status, agent_id, runtime_agent_type, agent_type_fallback, opened_by, runs_in}`. |
| `review_agents` | string[] | `record-agents` steps `active`, `cleared` | The reviewers the current wave runs. |
| `review_agent_ids` | object | `record-agents` steps `active`, `cleared` | Reviewer name to session id. |
| `review_agent_runtime_types` | object | `record-agents` step `active` | Reviewer name to the runtime agent type it was spawned as. |
| `review_wave_done` | string[] | `record-agents` steps `wave-start`, `returned`, `cleared` | The reviewers whose artifact returned in the current wave. |
| `reviewer_slots_observed` | number | `record-agents` step `wave-start` | The spawn count the harness allowed, `slots_observed`. |
| `json_paths` | string[] | `record-agents` step `returned` | Every accepted review artifact path, each once. |
| `pre_delegate_sha` | string or null | `record-round` step `base` | The worktree's HEAD before the delegation, as the runtime read it. |
| `review_fix_round` | boolean | `record-round` step `base` with `review_fix: true` | `true` once the review's fix round ran; never cleared. |
| `dev_delegated_at`, `review_delegated_at` | number | `record-round` step `delegated` with `round: dev`, `ci` or `review` | The delegation's epoch second: a dev or CI round's, or a review round's. |
| `cycles` | number | `record-round` step `counted` with `counter: fix` | Fix rounds run. |
| `rereview_cycles` | number | `record-panel` with `panel: rereview` below the cap | Re-review cycles entered. |
| `first_panel`, `rereview_panel`, `verification_panel` | object | `record-panel` with `panel: first`, `rereview` or `verification` | `{agents, reason, external, external_skip?, domain_reasons?}`: distinct reviewers and a non-empty reason. |
| `submit_cycles` | number | `state increment` from [submit-pr.md](../workflows/submit-pr.md) | Re-submit loops run. |
| `dev_round_id`, `review_round_id`, `ci_round_id` | string | `begin-round` with `kind: dev`, `review` or `ci` | The round token, minted before each delegation and carried in it. |
| `stages` | object[] | `begin-round`, `record-round`, `record-route`, `record-validation-admission`, `accept-result`, `reconcile-round`, `validate stop`, `record-push`, `orch-runtime validate start`, `dev-return check` | One entry per round or validation run ([§ Stages](#stages)). |
| `validate_rounds` | object[] | `dev-return check`, `record-push` | One `{round_id, receipt, kind, mode, seconds, lanes?, selection?}` row per schema-valid dev receipt with validation time. |
| `round_prunes` | object | `prune-round` | Round id to `{action, used_pct, mark_pct, bytes}` for the round's Cargo cleanup. |
| `recovery_round_id`, `round_recovery` | string, object | `orch-runtime round recover` | The round a recovery minted for a stalled round, and `{from, to, reason}`. |
| `summary_comment` | object | `accept-result` with `summary_file` | `{id, at, attachments}`: the item's `## Completion Summary` comment on the tracker. |
| `verification` | object | `record-verification`, through `verify-head` and `verify-pr` | `{head, verdict, reason, source, at}` for a published head. |
| `fixed_items`, `escalated_items`, `declined_items` | object[] | `record-disposition`, `state bucket`; `record-push` rewrites `commit` | The disposition buckets, each entry keyed by `location` and `description`. |
| `pr_comment_review` | object | `record-comment-ledger`; `record-round` step `counted` with `counter: external` | The comment triage ledger. |
| `pr_review_baseline` | object or null | `record-comment-ledger` entry `baseline` | `{last_threads}`: the unresolved review-thread ids at the end of the last triage pass. |
| `audit_issues_created` | string[] | `record-comment-ledger` entry `issue` with `origin: audit` | The issue ids the review's audit filed. |
| `rebase_map` | object | `record-push` | Pre-rebase SHA to post-rebase SHA, or `dropped`, read from the worktree's `kendex-rebase-map`. |
| `restacks` | number | `record-push` | Restack hops reconciled. |
| `restack_landing` | object | `record-push` | The guarded restack's starting commit, round and time. The push consumes it with the rebase map. |
| `push_attempt` | object | `record-push` | The push, written `attempted` before it starts. |
| `restack_skips` | object[] | `record-pr-progress` step `restack-skip` | `{head, condition, validated_head, paths}` per restack whose re-test was skipped. |
| `pr_order` | string | `record-pr-progress` step `order` | When the lane opens its pull request: `review-first`, `open-first`, `open-first-returned`, `open-first-pushed`, `push-first`, `push-first-returned` or `push-first-pushed`. |
| `pr_approval` | object | `record-pr-progress` steps `forced`, `reviewer-down` | `forced` and `reviewer_down`. |
| `children_detached` | boolean | `record-pr-progress` step `children-detached` | `true` once the children's detach ran before the arm, so it runs once. |
| `ci_rerun` | object | `record-pr-progress` steps `ci-rerun`, `ci-rerun-run` | `{head, run, at}`: the one automatic rerun of a transient CI failure on `head`. |
| `pauses` | object[] | `record-pr-progress` steps `merge-asked`, `merge-answered` | `{from, to, cause: "merge-hold"}`: the lane's merge question, open from its ask to its answer. |
| `queue_watch` | object | `record-queue-watch` | The merge-queue wait's memory for one head and one arm, written before each poll. |
| `qa_decision` | object | `record-qa-decision` | The review's QA routing and the QA reviews recorded. [review-pr.md](../workflows/review-pr.md) owns its steps. |
| `skip_qa` | boolean | `state init`, `state set` by the user and [review-pr.md](../workflows/review-pr.md) § 5 | `true` skips QA once. |
| `post_pr_budgets` | object | `state head-budget take`, `state head-budget reset` | `review_wait` and `ci_fix`, each null or `{head, attempts}`. |
| `post_pr_stop` | object or null | `state post-pr-stop record`, `record-if-empty`, `clear` | `{name, gate, remaining[], at}`, posted to the pull request as the `## Orchestration stopped` comment `--comment-file` names. |
| `head_approvals` | object | `approve-head` | The overseer's exact-head approvals, per pull request `owner/repo#pr` (the repository lowercased), then per full head SHA: `{login, attempt, comment}`. |
| `pr_review` | object | `verify-review` | The review gate's record: its mode, per head SHA, and its last verdict, as [gates.md § The review call](../references/gates.md#the-review-call) and [§ Copilot requests](../references/gates.md#copilot-requests) read it. |
| `handoff` | object | `record-handoff`, `resume-handoff` | [§ Handoff](#handoff). |
| `model_checks`, `lane_session`, `model_reset` | object | `state model-check`, the turn end | [§ Model checks](#model-checks). |
| `finding_occurrences` | object | `state init`, `state findings record`, `dev-return check` | [§ Finding occurrences](#finding-occurrences). |
| `closed_out_at` | string | `state remove` in a confined lane | The UTC time the lane's close-out ran, [§ Item close-out](#item-close-out). |

The members' rules, in the table's order:

- `tier`: absent, no tier bound applies.
- `tier`: on a `small` item, `state cap` reads `REVIEW_MAX_CYCLES` as at most 1 and `REVIEW_MAX_EXTERNAL_ROUNDS` as at most 2.
- `sub_issues`, `qa_labels`, `near_ceiling`: `record-dev-return` replaces each member it names and keeps the others.
- `near_ceiling`: the next round's delegation renders one `Near-ceiling:` line per entry.
- `child_sessions`: `child-open` sets `status` to `active`; `children-closed` sets it to `closed`.
- `child_sessions`: `opened_by` is the lead process that opened the child, `{session_id, session_since, pid, start}`.
- `child_sessions`: `runs_in` is `lead` for a Claude Code or Codex child, `own` otherwise.
- `child_sessions`: `slots` closes an in-lead child whose opener reads gone (`ended: holder-gone`) and reports the slots the others hold.
- `review_agents`: `cleared` empties it, `review_agent_ids` and `review_wave_done` for the next wave.
- `review_wave_done`: `wave-start` empties it.
- `reviewer_slots_observed`: while set, it is the wave size.
- `pre_delegate_sha`: it scopes a re-review's diff range.
- `review_fix_round`: at a `REVIEW_MAX_CYCLES` of 0, `state cap --item` reads `below` until it is set and `at-cap` after.
- `review_delegated_at`: `review-artifact check --delegated-at` takes it as the freshness boundary.
- `cycles`: summaries read it; it decides no cap.
- `rereview_cycles`: recording the rereview panel raises it in the same write below the `REVIEW_MAX_CYCLES` limit. At the limit the write records `verification_panel` instead and raises nothing.
- `first_panel`, `rereview_panel`, `verification_panel`: every panel carries a boolean `external`, whether the opposite-provider review runs beside the reviewers. An older record may lack it.
- `first_panel`, `rereview_panel`, `verification_panel`: a panel with `external` false carries `external_skip`, the non-empty reason it did not run ([review-pr.md § 2.1](../workflows/review-pr.md#21-external-review-availability)); one with `external` true carries none. A write that breaks this refuses `panel-external-skip`.
- `first_panel`, `rereview_panel`, `verification_panel`: on a `small` item, a panel holds at most three reviewers, the external lane counted.
- `first_panel`, `rereview_panel`, `verification_panel`: a later panel that holds every `first_panel` reviewer needs `domain_reasons` saying why the fix diff concerns each.
- `dev_round_id`, `review_round_id`, `ci_round_id`: a `dev` or `review` round opens a stage.
- `dev_round_id`, `review_round_id`, `ci_round_id`: a `ci` round opens none and keys its cleanup in `round_prunes`.
- `dev_round_id`: the dev token is the completion artifact's identity ([dev-return.md](dev-return.md)) and, on a fix round, the delegated-item record's ([dev-round.md](dev-round.md)).
- `validate_rounds`: a recovery's receipt takes its own row.
- `validate_rounds`: a push records one more row per restack run, with `round_id` `restack-<run id>`.
- `round_prunes`: `action` is `pruning` until the cleanup answers, then `pruned`, `failed` or `unknown`.
- `round_prunes`: `below-mark`, `target-elsewhere` and `no-worktree` record a cleanup that did not run.
- `recovery_round_id`, `round_recovery`: a repeated recovery of the same round gives the same answer.
- `summary_comment`: the comment is created once and updated in place by its id.
- `summary_comment`: `attachments` is `{name, url, image}` per link the body carries, rendered on every update.
- `verification`: `verdict` is `pass`, `fail` or `none`. `none` holds only where `reason` gives affirmative evidence of absence.
- `verification`: a newer head's record replaces the older one.
- `verification`: [submit-pr.md](../workflows/submit-pr.md) reads it before the merge step.
- `fixed_items`, `escalated_items`, `declined_items`: a move first drops the entry from each named `drop` bucket, so an item stands in one bucket.
- `fixed_items`, `escalated_items`, `declined_items`: a `commit` of `dropped:<sha>` marks a fix whose commit a rebase dropped: cite the upstream equivalent, never the SHA.
- `escalated_items`: an entry's `outcome` is `blocked` or `skipped`; absent reads as blocked.
- `pr_comment_review`: `iterations` counts the bot triage passes `REVIEW_MAX_EXTERNAL_ROUNDS` bounds. The merge cycle's `lanes[].cycle.rounds.bot` copies it, so it counts those passes, not Copilot reviews.
- `pr_comment_review`: the arrays, each with its entry kind, are `fixes[]` (`fix`), `issues_created[]` (`issue` with `origin: triage`), `skipped[]` (`skip`), `replied[]` (`reply`), `proposed_rules[]` (`proposed-rule`, each rule once), `patched_causes[]` (`patched-cause`, `{cause, commit, location, owner?}`) and `frozen_causes[]` (`frozen-cause`, `{cause, issue}`).
- `pr_comment_review`: [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) reads the cause entries.
- `pr_review_baseline`: a thread whose id is absent here is new.
- `rebase_map`: the same write rewrites `fixed_items[].commit` and `pr_comment_review.fixes[].commit`.
- `rebase_map`: resolve an artifact's SHA through the map until no key matches.
- `restacks`: a hop the map already holds adds none. Absent reads 0.
- `push_attempt`: a push whose answer was lost is settled from the remote before the next push.
- `restack_skips`: a new entry replaces one of the same `head`.
- `restack_skips`: `condition` is `no-conflict` or `version-only`.
- `pr_order`: absent, the item runs review-first.
- `pr_approval`: `forced` means the user chose Force merge; it is item-wide and never cleared.
- `pr_approval`: `reviewer_down` means every reviewer stayed silent past the period, and `PR_REVIEW_ON_TIMEOUT=proceed` proceeded.
- `ci_rerun`: it is recorded before the rerun is asked for; `run` is null until the rerun's run is known.
- `ci_rerun`: a head with a record is never rerun again.
- `pauses`: at most one stands open.
- `post_pr_budgets`: `take` spends one attempt in one write and answers `continue`, or answers `at-cap` and writes nothing.
- `post_pr_budgets`: `review-wait` restarts its count on a new head; `ci-fix` counts across heads.
- `post_pr_budgets`: `reset` sets the budget null.
- `post_pr_stop`: `record-if-empty` keeps a standing stop and restamps its `at`.
- `post_pr_stop`: `at` is the epoch second of the last recording, so a reader can tell a stop the lane's current session reached.
- `post_pr_stop`: `clear` lifts the stop.
- `head_approvals`: `attempt` is null, `{state: attempted}` from before the POST, or `{state: confirmed, review}`.
- `head_approvals`: `comment`, where the request names `comment_file`, is `{state: attempted}` or `{state: posted, id}`.
- `head_approvals`: the request names the live head.
- `head_approvals`: where the configured login differs from an entry's, a confirmed approval stands, and an entry holding no act takes the configured login.
- `head_approvals`: an entry holding an `attempted` attempt or a comment refuses the changed login.

### Stages

A `stages[]` entry is `{kind, round_id, start, end}` in epoch seconds, with `outcome` once closed. `kind` is `dev`, `review`, `implement`, `fix` or `validate`.

- `begin-round {kind, body_revision?, group?, exception?}` opens a `dev` or `review` entry in the same write as the token.
- A round records the item's `tier` at its start when set. On a `small` to `standard` route change, `record-route` preserves the source tier on the current accepted dev round if that round predates tier stamping. A first-cycle review's `record-round {step: delegated, round: review, review_range: {base, head}}` records its concrete range and `delegated_at` on that stage.
- `begin-round` closes every earlier open entry of the kind at the new start, with `superseded: true`.
- `body_revision` is the item body's `updatedAt` as the caller read it. The reply's `body_moved` is `true` where it is later than the kind's previous recorded revision.
- `group` is `{n, of}`.
- `exception` is `{by, id, excused}`: the known failing checks the round may end with.
- `orch-runtime dev-return check` sets the dev entry's kind to `implement` or `fix`.
- `record-validation-admission {round_id, run_dir?, attempt?}` opens `{kind: "validate", round_id, run_dir, start, end: null}` before the run.
- Without `run_dir`, the runtime mints the run id, and `run_dir` is `<worktree>/tmp/dev-validate-<run_id>`.
- A repeat of `record-validation-admission` while an admitted run of the round stands open returns that run; `attempt: next` mints another.
- `orch-runtime validate start` writes the run's `proof` and `job` on its entry before the launch.
- `orch-runtime validate start` first closes each open entry of the round whose `job` reads gone, as `reconcile-round` closes it, and sends its end notice. That close is its own write, so it stands when the start then refuses.
- An open entry whose `job` still runs refuses the start `run-live`, and one whose `job` cannot be read refuses it `validate-unreadable`; both stay open. A named entry that has ended refuses it `run-ended`.
- A start refused before it writes the entry's `proof` and `job`, other than `run-live`, writes the refusal's key as `refused` on the open entry it was to start (the named entry, or the round's open admission when the start names none), which stays open. The next start that writes `proof` and `job` removes it.
- `validate stop --item [ISSUE_ID] --run-dir [RUN_DIR]` writes `stop: {at}` before it ends the job.
- `accept-result {round_id, outcome, run_dir?, end?, authorization?, summary_file?, attachments?}` closes the round's own entry, or with `run_dir` the run's `validate` entry.
- `accept-result`'s `outcome` is required: `pass`, `fail`, `no-verdict`, `lost`, `stopped`, `no-change`, `handed-over` or `pass-excused`.
- `accept-result`'s `end: {from_artifact: PATH}` takes the file's modification time, bounded to `[start, now]`; without it, the entry ends now.
- A repeat `accept-result` changes nothing and reports the recorded close.
- A superseded entry cannot be accepted.
- `reconcile-round {round_id}` closes each open `validate` entry of the round whose run will not end itself.
- `reconcile-round`'s outcome is the run's sentinel word; `stopped` for a run never started or one a `stop` stands on; `lost` for a gone run with no sentinel and no `stop`.
- `reconcile-round` and a launch refusal write their close's `cause` on the entry: `sentinel`, `run-dir-absent`, `process-gone`, `pid-unrecorded`, `unit-ended` or `launch-failed`.
- `reconcile-round` leaves a run still running, or one that cannot be read, open.
- `record-push` writes `{kind: "validate", reason: "restack", round_id: null, run_dir, start, end, outcome, proof}` once per finished restack run directory.

`stages[].authorization` is `{by, id}`, `by` being `overseer` or `owner-directive`:

- A round's own `accept-result` writes it, as part of the acceptance's identity: a repeat names the same one.
- A `directive-[ID]` item's round must name `{by: owner-directive, id: [ID]}`.
- `{by: overseer, id}` names the inbox envelope that answers the lane's own `lane-question`, or an owner's directive the overseer relayed. It never names a launch ruling, a fleet-log row or a session id.

`orch-runtime cycle stages [ITEM]` prints the item's `stage item=` rows, sorted by start. The close's merge cycle copies the entries to `lanes[].cycle.stages`.

### Handoff

`handoff` is the lane's hand-off record. `record-handoff` writes `{written_at, round_id, merged, remaining, branch, worktree, open_pr, traps, context, relaunch}`. On a model switch it also writes `session_id`, `pane_key`, `cause` and `model`.

- `round_id` names a stage the item ran.
- `relaunch` is `fresh` or `resume`, the session route a relaunch takes. Absent reads `fresh`.
- `context` is the context decision that caused the hand-off, as the turn end judged it.
- `written_at` is the request's ISO 8601 UTC time, no later than the clock, else the runtime's clock.
- While the record carries no `resumed_at`, every field but `written_at` is its identity.
  - The same content again reports `recorded_now: false`.
  - Other content needs `supersede: true`.
- The next `record-handoff` replaces a record that carries `resumed_at` whole.
- No pointer write reaches an item record's `/handoff`.

`orch-runtime state handoff-standing --item [ISSUE_ID] [--worktree PATH]` reads the item's record in the state directory, then in `<root>/tmp`. `<root>` is `--worktree`; without it, and with no `--state-dir`, it is the linked worktree the caller runs in. The reply's `standing` is the answer, not the exit status:

- `stands`, with the `file` and the `record`;
- `none`, with the first place holding the item's record;
- `unreadable`, with the first place that could not be read.

A lane whose launch forbids writing the main checkout keeps its record in its worktree's `tmp`.

`orch-runtime state handoff-resume --item [ISSUE_ID] [--worktree PATH]` runs `resume-handoff` on every place the record stands:

- It stamps `resumed_at` once, in epoch seconds.
- It reports the round, its route, the `remaining` steps and the round's open validation runs, which the continuation waits on.
- A second resume reports the first stamp.
- With no standing record it refuses.

The watch reports a record with no `resumed_at` as `handoff`.

### Model checks

A model check is a Claude Code session's switch away from its launch model, or a model the turn end cannot read. It is recorded once per launch.

- A lane's turn end keeps its check on its own item record, as `model_checks[session_id]`: `{outcome, session_id, launch_identity, launched, observed, at, cause}`, `outcome` being `switched` or `unavailable`.
- On a switch, the turn end writes the `handoff` the replacement resumes from, then marks the check `recovery_started`.
- The turn end also keeps `lane_session`, `{session_id, launch: {pid, start}}`: the session a cleared start's harness began.
- At a replacement's first turn end, the turn end keeps `model_reset`, `{session_id, launch_identity}`.
- The watch's lane pass reads these three members of a local lane's item record. It binds the fleet lane to `lane_session`.
- The watch's lane pass writes the lane record's `model_check` with a `model-switched` or `model-unavailable` fleet-log row, and starts `recover-lane-model` for a started switch.
- From `model_reset`, the watch's lane pass writes the check `passed` and a `model-recovery-reset` row.
- `recover-lane-model` counts the lane's recoveries since its last `model-recovery-reset` row. At `ORCH_MODEL_RECOVERY_LIMIT` ([settings.md § Fleet lanes](../references/settings.md#fleet-lanes)) it relaunches nothing and appends one `model-recovery-limit` row.
- A hosted lane's switch is kept on the item record on its host; the hook finds the host through the lane's launch record.
- A failed stop of a hosted lane's predecessor is kept as `handoff.stop_failure`.
- `orch-runtime state model-check slot|record|reset|start` make these writes. `slot` holds the once-only notice of an unavailable model per session.

The fleet record's `controller` member keeps the controller's check by the same rule.

## Oversee state

The fleet record `workflow-state-oversee.json` holds the init object and the members below. `orch-runtime state init --fleet` creates it. The watch reads it as its `--file` ([lane-launch.md § Lane record](../references/lane-launch.md#lane-record)).

| Field | Type | Owner | Meaning |
|---|---|---|---|
| `lanes` | object[] | `launch-lane`, `close-lane`, `park-lane`, `reserve-lane`, `release-lane`, `admit`, `state merge`, `record-surface-lane`, the watch | One record per lane ([§ Lane records](#lane-records)). |
| `tmux` | object | `launch-lane` | `{session}`: the tmux session the fleet's lane windows open in. |
| `controller` | object | agent-runtime's controller transitions, `orch-runtime register --fleet` | The overseer session ([§ Controller](#controller)). |
| `intents` | object[] | agent-runtime's journal | One row per lane or controller operation with a live effect: its phase, obligations and outcome. |
| `handoff` | object | `record-overseer-ledger` entry `handoff` | The overseer's own hand-off: `{handoff_file, pane_key, session_id, context, written_at}`. |
| `last_backlog_audit` | object | `record-overseer-ledger` entry `backlog-audit` | `{at, backlog}`: the team Backlog count at the last full audit, stamped by the runtime. |
| `launch_queue` | string[] | `record-overseer-ledger` entry `launch-queue` | The items the last selection chose and has not launched, in launch order, replaced whole. |
| `triaged` | object[] | `record-overseer-ledger` entry `triage` | `{issue, reason, verdict}` per issue the triage verifier judged, `verdict` being `kept` or `canceled`. |
| `alerts_triaged` | object[] | `record-overseer-ledger` entry `alert-verdict` | `{repo, kind, number, verdict, item, reason}` per security alert judged. |
| `standing` | object[] | `state standing add`, `state standing lift` | The owner's standing instructions, `{at, id, scope, end, text, holds_launches?}`. |
| `fleet_log` | object[] | `state log append`, and the writers named below | One `{at, kind, item, text}` row per entry ([§ Recording policy](#recording-policy)). |

The members' rules, in the table's order:

- `tmux`: the first launch writes it. Later launches read it where `AGENT_RUNTIME_TMUX_SESSION` names none ([lane-directive.md § Tmux session](../references/lane-directive.md#tmux-session)).
- `intents`: `orch-runtime state inspect --fleet` lists the open ones under `open_intents`.
- `handoff`: `written_at` is stamped under the fleet log's time rule.
- `last_backlog_audit`: the [heartbeat audit](../references/heartbeat-audit.md) reads it.
- `launch_queue`: it holds the order, never the membership: the watch names each owed tracker item under every heartbeat.
- `triaged`: the watch rebuilds its acknowledged triage keys from it.
- `alerts_triaged`: `verdict` is `filed` with its fix item, or `dismissed` with `item` null ([security-alerts.md § Triage](../references/security-alerts.md#triage)).
- `alerts_triaged`: the watch reports no alert it names.
- `standing`: `add` appends one row and stamps an absent `at`.
- `standing`: `lift` replaces the array with the file's and appends one `ruling` row naming the ids that left.
- `standing`: [communication-modes.md § Recording](../references/communication-modes.md#recording) says when to write a row.

`fleet_log` kinds are `proposal`, `ruling`, `close`, `peer`, `use1`, `cycle`, `token`, `landing-disposed`, `model-switched`, `model-unavailable`, `model-recovery-limit` and `model-recovery-reset`.

- The confirmed close writes `close`, `cycle` and `landing-disposed`. `orch-runtime cycle rollup` writes `cycle`. The model checks write the `model-` kinds.
- Every other row goes through `state log append`, never a pointer `append`.
- `state log append` stamps an absent `at`.
- A given `at` is `YYYY-MM-DDThh:mm:ssZ` and no later than the clock.
- `text` is at most `ORCH_FLEET_LOG_ROW_BYTES`.
- `text` is one line and never a token value.
- A `use1` row also carries `outcome`.
- [oversee-events.md](../references/oversee-events.md) says when to write each kind.

A cloud lane's close writes one more `close` row: `cloud lane closed; session=ID account=ACCOUNT`, with `none` for a member the record lacks. Where the lane recorded a directive send, the row continues with ` send=RESULT credit=DOLLARS locked=REASON cli=TEXT`, the CLI's words cut to 300 characters. The archive list in [§ Recording policy](#recording-policy) parses that form.

### Controller

`controller` is the overseer session's record. Agent-runtime's `controller` module owns the shape:

- its launch identity: `harness`, `account`, `home`, `home_implicit`, `model`, `class`, `effort`, `cwd`, `permission`, `extra_args`;
- `home_implicit`, for a Claude home: `true` for the implicit default config dir, `false` for a named one, absent when unknown;
- its pane: `server`, `server_start`, `server_socket`, `pane`, `window`, `session_rows`;
- its process, `harness_pid` and `harness_start`, and its native `session_id`;
- `generation`, `pending`, `exit`, `off` and `watch`.

The writers:

- A confirmed `start-controller` or `request-transfer` publishes the record at the next `generation`, from its typed `pending` controller and the identity it observed.
- `orch-runtime register --fleet` reads the fleet's lane records before it records a hand-opened session through `adopt-controller`. An unreadable row leaves the fleet file unchanged.
- Where the record names the same pane on the same server, the adoption keeps the record and its generation, replaces each launch field the request names, a Claude `home` excepted, and drops `pending`, `exit` and `off`.
- Otherwise the adoption writes the session's record at the next generation.
- A Claude adoption records the home its process runs on as `home`, with its mode in `home_implicit`.
  - A requested home the process does not run on is recorded as named.
  - Where the process environment is unread, the home a registration read for that process, or the record's home for that same process, stands with its mode where the request names no other home.
  - With neither, the adoption records the request's home, drops `home_implicit`, and reports `home-unread` with the cause.
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

`register --fleet` refuses the released statuses `closed`, `handed-off` and `canceled` with `released-lane-status`. The diagnostic names the fleet file, lane row, item and status. Set the named row's `status` to `done`, then retry registration.

- A relaunch keeps omitted request fields subject to the launch updates below.
- `host` and `kind` are always the launch's own.
- `harness`, `account`, `model` and `effort` reach the record when the launch confirms, each null where the request named none.
- A relaunch keeps `tier` and `tier_inputs`; a launch over a `done` record writes its own brief's.

| Member | Meaning |
|---|---|
| `tracker`, `repo`, `harness` | What the close reads the item and stops the harness by. |
| `window`, `launch` | The lane's tmux window and its confirmed identity `{pane, server, server_start, pid, start}`. |
| `account`, `home`, `home_implicit` | The account the lane spends, the home its sessions ran under, and `true` where the launch named no home. |
| `host`, `kind`, `mail_root`, `mail_root_confirmed`, `checkout`, `checkout_common` | Where the lane runs. |
| `surface` | `tmux`, the lane operations' one surface. |
| `model`, `effort`, `permission`, `allow_all` | The launch line's model, effort word and permission word, each null where the line names none, and the Copilot allow-all grant. |
| `class`, `class_reason`, `class_missed` | The model class the assignment runs at (`top`, `standard`, `light`, `fast`), its reason, and a retired attempt below `standard`. |
| `session_id`, `session_since`, `launched_at`, `running_at` | The bound harness session; the UTC time the launch or relaunch started; the first launch's time; the time the lane read `running`. |
| `status` | `preparing`, `running`, `stopped`, `parked` or `done`. |
| `restart_closed` | The intent id of the `restart-recovery` close that left the lane `stopped` with no successor launch. |
| `over_cap`, `reservation` | The over-cap reason a launch passed, and `{reason, until}`, a finite hold on the cap slot. |
| `touched`, `in_scope`, `carried` | The touched set the admission judged; the append-only paths left out of the overlap judgement; and `{item, tracker, repo, at}` per item the admission joined to this lane. |
| `obligation` | `{repo, item, parent_repo, parent_item}`, the item's original lineage. |
| `tier`, `tier_inputs` | The tier the first launch's brief states, and `{estimate, delta, paths}`. |
| `refresh`, `desktop`, `read_only` | `refresh` is `true` on a refresh lane. `desktop` is `true` where the overseer granted the owner's live display. `read_only` is `true` on a lane that changes no repository file. |
| `parked`, `park_owed`, `sandbox` | `parked`, `{head, repo, at, pr?, until_pr?, until_repo?}`, is a hosted lane's park after its sandbox stop. |
| `pending_pr`, `pauses`, `capacity_wait`, `walled` | `pending_pr`, `{pr, repo, head, until_pr?, until_repo?}`; the paused spans; `capacity_wait`, `{at}`; `walled`, `{at}`. |
| `wake` | `{pid, start}` of a detached print-mode turn beside the lane's pane. |
| `directive_send` | A cloud lane's last directive send. |
| `kept`, `kept_mail` | The reason a close kept the lane's worktree, and the path where the worktree package kept a lane mailbox it could not join. |
| `model_check` | [§ Model checks](#model-checks). |
| `cycle` | The merge cycle the confirmed close writes from the delivery. |

The members' rules, in the table's order:

- `tracker`: where the record and the request both leave `tracker` empty, a tracker-identifier key derives `linear`. An `issue-N` key derives none, so the request names one.
- `window`, `launch`: null at `preparing` and on a cloud lane.
- `launch`: the close stops a local harness by `pid` and `start`.
- `host`: null for this machine, `claude-cloud`, or a provider path.
- `kind`: `local`, `claude-cloud` or `ssh` ([lane-host.md § Host kinds](lane-host.md#host-kinds)).
- `mail_root`: the lane's worktree as its host sees it.
- A launch over an existing record clears `mail_root_confirmed` and sets `mail_root` to the request's checkout during preparation.
- A confirmed launch with a provider-backed mailbox sets `mail_root_confirmed` to `true` when its outcome names a root. Without confirmation, a root matching `checkout` is pending.
- `checkout`: the checkout a hosted lane launched from.
- `checkout_common`: the canonical common git folder admission read from the checkout at `mail_root`.
- `checkout_common`: a launch writes it on a new record or a changed `mail_root`; a relaunch over the same `mail_root` keeps it.
- `checkout_common`: it is absent where admission read no checkout, where the launch reads no settings or grants, and where the folder lies under another `.git`, the lane's root or a folder the lane's grants make writable.
- `checkout_common`: the close removes a clean, merged worktree only from the main checkout of this folder, else of the overseer's own.
- `surface`: a record a harness's own launcher runs carries another, which `record-surface-lane` steps `create` and `merge` write.
- `allow_all`: whether a Copilot lane's line grants the full allow-all mode; it is null on every other harness.
- `class_missed`, `{class, cause, at}`, stands after a `no_landing` close retired an attempt below `standard`. While it stands, no launch below `standard` runs the item.
- `launched_at`: the first record's `launched_at` is the fleet start the watch's `--since` takes.
- `restart_closed`: a confirmed `restart-recovery` close writes it. A confirmed launch and a confirmed close on any other ground remove it.
- `restart_closed`: on a `stopped` lane, `lane relaunch` sends the launch alone, and `jarvis-session resume` selects the lane beside the `running` ones ([lane-directive.md § Recovery relaunch](../references/lane-directive.md#recovery-relaunch)).
- `reservation`: `reserve-lane` or `park-lane` writes it; a relaunch, `release-lane` and a confirmed close drop it.
- `touched`, `in_scope`, `carried`: [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) and [§ Caps](../references/lane-directive.md#caps) state the judgement.
- `obligation`: the parent pair is named together or null together.
- `obligation`: a launch binds it on a record that carries none.
- `obligation`: a first launch that names none but names `repo` records the item as its own parent.
- `obligation`: a differing one refuses ([lane-directive.md § Obligation lineage](../references/lane-directive.md#obligation-lineage)).
- `tier`: the brief states it by its workflow verb (`start` is `standard`) or by its one whole `item-tier` line.
- `desktop`: every later launch keeps it.
- `read_only`: [lane-directive.md § A read-only launch](../references/lane-directive.md#a-read-only-launch) states what it grants and which launches keep it.
- `park_owed` and `sandbox: "standing"` mark a stopped lane whose park's sandbox stop has not confirmed.
- `pending_pr`: a relaunch moves `parked`'s pull request into `pending_pr`, and its span into `pauses` as `{from, to, cause: "parked"}`.
- `capacity_wait`: it stands from a relaunch's first capacity refusal, then closes into `pauses` with `cause: "capacity"`.
- `walled`: it stands while the watch sees a usage wall, then closes into `pauses` with `cause: "walled"`.
- `pauses`: the merge cycle reads `pauses` as paused time.
- `wake`: a relaunch beside a live wake refuses.
- `directive_send`: `orch-runtime send` writes it through `record-directive-send`: `owed` before the send, settled from the mailbox's receipt after.
- `directive_send`: a send whose outcome is unknown is refused rather than sent twice.
- `kept`, `kept_mail`: the close writes both.
- `cycle`: later launches keep it. [`ops/cycle.rs`](../runtime/src/ops/cycle.rs) owns its fields, among them `obligation`, `stages` and `rounds`.

A lane this runtime did not launch, surface 2 or 3, has its record written whole by `record-surface-lane` step `create` and changed by step `merge`. Neither step applies to a tmux lane.

`orch-runtime state merge --fleet --lane [ITEM] [FILE]` replaces the members the file names and binds `obligation` as the launch does.

A cloud launch's confirmed outcome carries `cloud_repo_access`, `{repositories, url}`: the repositories to check by hand, and the session URL where the overseer answers repository-access cards.

## Recording policy

The retention is `ORCH_RECORD_RETENTION_DAYS` days past a record's stamp. [settings.md § Recording](../references/settings.md#recording) holds it, `ORCH_FLEET_LOG_ROW_BYTES`, `ORCH_TAKEOVER_ROWS` and `ORCH_PROGRESS_REPORT_DIR`. [§ Repository and tools](../references/settings.md#repository-and-tools) holds `ORCH_ARCHIVE_ROOT`. [§ Where a setting is set](../references/settings.md#where-a-setting-is-set) gives where the runtime reads each.

| Record | Readers | Retention |
|---|---|---|
| Fleet log rows, `fleet_log[]` | The successor overseer, audits and `orch-runtime report render`. | A row whose `at` is past the retention moves into the prune archive. |
| Standing instructions, `standing[]` | The successor overseer, through `orch-runtime state get --fleet /standing`, and `orch-runtime report render`. | None: a row leaves when the overseer lifts it. |
| Overseer handoff file, `handoffs/OVERSEER-HANDOFF.md` | The successor overseer, at [oversee-takeover.md § 1](../workflows/oversee-takeover.md#1-read-the-mailbox-and-handoff). | None. |
| Lane records, `lanes[]` | The watch, the close, the overseer, and every rollup of a lane's times. | Judged by the record's recorded end. |
| Lane status file, `tmp/lane-status-[ISSUE_ID].md` under the lane's `mail_root` | The overseer, through [oversee-reads.md § Bounded lane reads](../references/oversee-reads.md#bounded-lane-reads), and the watch. | Leaves with the lane's worktree. |
| Lane mailbox, `tmp/lane-mail/[ISSUE_ID]/` | The lane and the overseer, through `lane-mail`, whose `--help` defines the envelope. | No retention removes it. |
| Overseer mailbox, `tmp/lane-mail/overseer/` | The overseer, the owner relay and peers, through `lane-mail`. | Each retention pass runs `lane-mail compact --item overseer` before its prune. |
| Overseer session rows, `session-[SERVER_PID]-[PANE].jsonl` in the overseer mailbox | The watch, registration and succession. | [§ Prune](#prune). |
| Context reading, `context.json` in a lane's mailbox and in the overseer mailbox | `orch-runtime turn-end`, which writes it, the watch, and the overseer. | Follows its mailbox. |
| Lane session rows, `session-rows.jsonl` in a lane's mailbox | The watch and `orch-runtime lane status`. | Follows its mailbox. |
| Lane report state, `sent-count` in a lane's mailbox | `orch-runtime turn-end`'s idle judge, its one writer and reader. | Follows its mailbox. |
| Owner progress report, `MM-DD-HH-MM.md` under `ORCH_PROGRESS_REPORT_DIR` | The owner, and `orch-runtime report`. | Pruned past the retention once sent ([§ Prune](#prune)). |

The records' rules, in the table's order:

- Fleet log rows: the successor overseer reads the last `ORCH_TAKEOVER_ROWS` rows, `cycle` and `token` rows excepted, through `orch-runtime state log takeover --fleet`; with no fleet record it answers `rows: []`.
- Fleet log rows: audits read the `proposal` and `ruling` rows through `state log audit --fleet`.
- Fleet log rows: `orch-runtime report render` reads the `use1` and `cycle` rows.
- Fleet log rows: a row with no ISO 8601 UTC `at` stays.
- Standing instructions: `orch-runtime report render` reads the rows whose `holds_launches` is set ([communication-modes.md § Recording](../references/communication-modes.md#recording)).
- Overseer handoff file: its shape is [communication-modes.md § Handoff](../references/communication-modes.md#handoff).
- Overseer handoff file: a file under `handoffs/` named for an item leaves at the item's close-out.
- Lane records: the recorded end is the latest confirmed close of the record's session, else its item's latest `close` row, else its `launched_at`.
- Lane records: a record leaves once it reads ended, that end is past the retention, and its worktree reads released or `kept`.
- Lane records: ended is status `done`, or a confirmed close of the current session on a record neither `stopped` nor `parked`.
- Lane records: the kept worktree stays.
- Lane records: once every record of an item has left, the item's record leaves too.
- Lane records: the fleet's first record stays.
- Lane status file: its shape is [lane-launch.md § Lane directive](../references/lane-launch.md#lane-directive)'s.
- Lane status file: the item's close-out removes one standing directly in the state directory.
- Lane mailbox: `worktree remove` moves it to the main checkout's `tmp/lane-mail/` (`worktree remove --help`).
- Lane mailbox: the close-out archives it and removes nothing.
- Overseer mailbox: a refused compaction fails the pass; the prune still runs.
- Overseer session rows: the fleet repository's store writer reads the `SessionStart` rows to find the overseer's transcript.
- Overseer session rows: before changing this shape or path, tell the fleet overseer (`lane-mail peer send --repo fleet --file [PATH]`).
- Context reading: `orch-runtime turn-end` writes it at each turn end that reads a transcript, with a reading or with `gap` naming why it took none.
- Context reading: a Copilot session's is written at each usage reading.
- Context reading: the watch judges the overseer's reading.
- Context reading: read and judge a lane's between its turn ends as [oversee-events.md § Hand off a lane before it runs out](../references/oversee-events.md#hand-off-a-lane-before-it-runs-out) says.
- Lane session rows: the watch and `orch-runtime lane status` judge local lanes from their prompt, tool and turn-end rows, with the pane and hosted-lane exceptions [oversee-events.md § `idle-after-return`](../references/oversee-events.md#idle-after-return) states.
- Lane session rows: with no row, Claude Code, Codex and Copilot CLI use the pane; Pi stays unjudged as `rows-none`.
- Owner progress report: `orch-runtime report` reads the reports' names and modification times but none of their content ([`watch/report.rs`](../runtime/src/watch/report.rs)).
- Owner progress report: [communication-modes.md § Status report](../references/communication-modes.md#status-report) gives its shape, and what a written file and a confirmed receipt each advance.
- Owner progress report: each decision names the paths it chose between and the outcome of each.

List the closed cloud sessions by account for the archive relay. For closes after UTC time T, add `select(.at > "T")` before `.text`:

```bash
STATE_READ="$(.agents/skills/orch/scripts/orch-runtime state get --fleet /fleet_log)" && jq -r '[.result.value[] | select(.kind == "close") | .text | capture("session=(?<session>[^ ]+) account=(?<account>[^ ]+)")] | group_by(.account)[] | "\(.[0].account) \(map(.session) | join(" "))"' <<<"$STATE_READ"
```

`orch-runtime state progress-report-path [--succession]` answers a progress report's path as `result.path` and creates its directory. The name is `MM-DD-HH-MM.md` in UTC, or `MM-DD-HH-MM-succession.md` for a succession's report. [oversee.md § 5](../workflows/oversee.md#5-stop), [§ Succession](../workflows/oversee.md#succession) and the [`report-due`](../references/oversee-events.md#report-due) event say when to write one.

### Prune

The watch's retention duty prunes the fleet record and its state directory on its cadence; no step prunes by hand. Where no fleet record stands, `state remove` runs the same pass after its close-out, less the scratch: only the watch's duty judges [§ Scratch](#scratch).

The duty removes only these:

- An item's record, once every lane record of the item has left, as the Lane records rules state.
- An item's record no lane record names, last written past the retention. It stays while it names a linked worktree that stands, by its `worktree` or by its `branch` checked out there.
- A closed intent's `intents/[ID].pane`, `intents/[ID].request` and `intents/[ID].job`, once the intent's end and the file's own last write are past the retention. An open intent's files and a `.notice` stay.
- An owner progress report last written past the retention and sent. `report write` keeps its delivery attempt, `MM-DD-HH-MM.notice.json`, beside the report until the owner's notice is sent or none is owed; a report with its attempt standing stays.
- At the watch's duty only, a scratch entry nothing uses, as [§ Scratch](#scratch) states.
- A session rows file whose pane is gone: the tmux server answering at the ambient socket is that pid and holds no such pane. A file that `controller.session_rows`, `controller.pending.session_rows` or `pending.session_rows` names stays, as do a link and a file whose server does not answer.
- Lane records and fleet-log rows past the retention.

Every other entry stays, whatever its age: an item's files while it has a record, every file under `handoffs/`, the mailboxes, the claim store, the watch's own records and every lock file. An entry [§ Item close-out](#item-close-out) names leaves at the item's close-out.

The duty archives each unit before it goes:

- The archive is `ORCH_ARCHIVE_ROOT/[REPO]/oversee/prune-[EPOCH]-[SUFFIX].tgz`, with the dropped rows as `records.json`. `[REPO]` is the main checkout's directory name.
- With `ORCH_ARCHIVE_ROOT` empty, nothing is archived.
- The duty reads each leaving record again under its lock. A record that moved keeps its item for the next pass.
- A record whose lock the duty cannot take stays until a later pass, and fails this one.

### Scratch

Scratch is each direct entry of the main checkout's `tmp/`: the files the workflows tell the overseer to write, briefs, audit inventories `tmp/inventory-*.json`, and the reader and waiter folders `tmp/waiter.*`. The watch's retention duty removes an entry once all of these hold:

- No citing text names it. The citing texts are:
  - the fleet record, its fleet-log and `standing[]` rows among it;
  - each item record;
  - each file under `handoffs/` of the state directory and of the main checkout's `tmp/`, and the handoff the controller's launch named with `--handoff`, which the fleet record keeps;
  - the main checkout's settings files, and the private env file the settings read, `KENDEX_ENV_FILE` else `.env.local`;
  - the first 256 KiB of every scratch file the duty judges and keeps, such as a lane brief.

  A text names an entry where it spells the entry's name whole, as `tmp/[NAME]` or an absolute path does. A script that `DEV_VALIDATE_CMD` names stays this way.

- No running process's command line names it. A follow names its reader folder, and a waiter's job names its run folder.
- Its name carries the key of no item with a lane record or a standing item record. Once the item's record has left, such an entry is judged like any other.
- Its last write is past the retention. A folder's is the newest write of the folder and of each file directly in it.

These stay or leave by their own rule:

- The live follow's reader folder stays: the newest `tmp/waiter.*` whose `watch.log` is the watch's log.
- An audit reads its inventory within its pass, so an inventory past the retention has served its audit.
- The duty never judges the state store's own entries (the records, the watch's files `oversee-watch.*`), a lock file, a dotfile, a name with a character outside `[A-Za-z0-9._-]`, the progress reports and their attempts, or a folder other than `tmp/waiter.*`. A folder's own write time says nothing of what it holds, and the other folders are stores with their own owner: the item records, the intents, the handoffs, the mailboxes and an item's run folders.
- A process table the duty cannot read keeps every scratch entry and fails the pass with `scratch=unjudged`.
- `ORCH_PROGRESS_REPORT_DIR` is no scratch: only its sent stamped reports leave it ([§ Prune](#prune)), and every other file there stays.

The watch's own logs:

- The duty cuts `oversee-watch.err` to its newest 512 KiB, from its first whole line, once it passes 1 MiB.
- `oversee-watch.log` stays whole: every follow numbers its lines from the log's first, a successor's handoff names its cursor by that number, and `tail -F` reads a cut or replaced file again from its start.
- A fleet's first start empties `oversee-watch.log`.

### Item close-out

`orch-runtime state remove --item ITEM [--archive PATH]...` closes an ended item out of the state directory. It removes:

- every entry of the item's folder `items/[ITEM]/` but the record's lock file and mutex;
- every other direct file of the state directory named for the item, and each direct folder named `[ITEM].[KIND]`;
- every file under `handoffs/` named for it.

These stay:

- The item's lane mailbox, the fleet record and the watch's records.
- A caller's own entry whose name holds the key: a file that begins with `[ITEM]-` or `[ITEM]_`, and any other folder, such as `[ITEM]-final/` or `final-[ITEM]/`.
- A lane's round artifacts, which live under its worktree's `tmp/` and leave with the worktree.

Before it removes anything, `remove` writes one archive at `ORCH_ARCHIVE_ROOT/[REPO]/oversee/close-[ITEM]-[EPOCH]-[SUFFIX].tgz`:

- The archive holds every path `remove` removes, the lane mailbox, and each `--archive PATH` that stands, which the caller removes after.
- A relative `--archive` path is the caller's directory's.
- The archive's `records.json` lists each packed path as a member, with role `state` for the item's record and `along` for the rest.
- With `ORCH_ARCHIVE_ROOT` empty, `remove` removes with no copy.
- `remove` holds the item record's lock across the archive and the removals.

The reply's `result` carries `removed`, the paths that left; `kept`, the archive or null; and `pruned`, the retention pass it ran where no fleet record stands, else null. A configured root a removal would take along, or an archive `remove` cannot build, refuses the call, and nothing is removed.

A lane runs `remove` at [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 6:

- A confined lane's call sets the item record's `closed_out_at` to the current UTC time (`YYYY-MM-DDThh:mm:ssZ`), the one close-out write its grants hold, then answers `state-remove: left cause=confined owner=overseer` and exits 0. It archives and removes nothing.
- The overseer's close reads that stamp as this step's end ([lane-reach.md § How a running lane is judged](../references/lane-reach.md#how-a-running-lane-is-judged)), and its terminal close removes the item's files.
- A stamp that cannot be written refuses, as any record write does.
- The runtime's close runs the same close-out at a close that ends the item: a terminal tracker verdict, or a terminal close of a sandbox its provider does not list.
- A park, a `keep-sandbox` close, or a close of an item still open keeps the files a relaunch resumes into.

## CLI

A workflow reads and writes records through `.agents/skills/orch/scripts/orch-runtime`. `orch-runtime --help` and `orch-runtime state --help` are the contract.

- Every verb prints one JSON reply: `ok` true with its `result`, or `ok` false with `refusal.key`, a keyed line on stderr and exit 1.
- Hold a reply in a variable, and project it only after exit 0.

The `state` family names a member by JSON pointer, such as `/pr_review/mode`:

- `inspect` answers the record under `.result.state`.
- `get` answers the value at the pointer as `.result.value`, `null` where absent, and the whole record with no pointer.
- The pointer writes are `set`, `append`, `set-file`, `append-file`, `upsert`, `increment`, `set-now`, `set-git-head`, `close-all` and `merge`, each one locked write.
- `orch-runtime state --help` names every verb and what it reads or writes.

`orch-runtime state set --help` states which values `set` and `append` read as JSON. Pass a plain string bare: `approval`, never `'"approval"'`, which stores the quotes.

An operation runs as `.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [FILE]`, or with `--request-json [JSON]`:

- `[FILE]` is one JSON object tagged by `op`, written with the harness file tool.
- A fleet operation takes `--fleet`.
- The named record writes are `record-round`, `record-panel`, `record-agents`, `record-disposition`, `record-comment-ledger`, `record-route`, `record-dev-return`, `record-pr-progress`, `record-surface-lane` and `record-overseer-ledger`; [`ops/mod.rs`](../runtime/src/ops/mod.rs) `Request` lists the others.
- A transition's typed result is `.result.report`.
- `verify-head` reads GitHub before it records. Its `.result.status` is `complete`, `pending` or `unreadable`, and `.result.verdict` stands only on `complete`. [base-publication.md § 5](../workflows/base-publication.md#5-verify-the-published-head) routes each status.

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

`finding_occurrences` is `{prior, records}`:

- `init` writes `prior: "none"`.
- Three cases leave `prior: "unknown"`: a record that lacks the member, a batch with unavailable provenance, and an unusable failed-check list. Later successful records do not undo it.
- The member is archived and removed with the item's record.

### Record verified findings

This is the admission and completion contract for a review producer that feeds an item's fix or filing route. The caller supplies the item key and worktree, the local or native identity, the dry-run status, and its own launch, acceptance and disposition routes. The caller keeps its panels, deadlines, continuation proofs, advisory failures and round allowances.

1. **Admission, before launch.**
   1. Ensure the item's record exists through the caller's initialization route.
   2. Write `[WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "review"}`.
   3. Then mint the batch token and stamp its freshness boundary:

      ```bash
      .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE_PATH]/tmp/orch-op-[ISSUE_ID].json
      .agents/skills/orch/scripts/orch-runtime state set-now --item [ISSUE_ID] /review_delegated_at
      ```

   4. Bind the reply's `.result.report.round_id` and the stored `review_delegated_at` to this batch's assignments.
   5. A fresh wave or QA delegation is a batch. A confirming local pass takes fresh admission under its own bound. A proved continuation of the original batch keeps its original binding.
   6. Under dry-run, make neither write and keep round provenance unavailable.

2. **Acceptance.**
   1. Check each assigned report through the acceptance owner:

      ```bash
      .agents/skills/orch/scripts/orch-runtime review-artifact --text check --file [ARTIFACT_PATH] --worktree [WORKTREE_PATH] --delegated-at [BOUND_REVIEW_DELEGATED_AT] --issue [ISSUE_ID]
      ```

   2. Under dry-run, leave out the unavailable `--delegated-at` and `--issue`.
   3. Keep the caller's own acceptance checks and failure route.
   4. Only accepted evidence supplies findings.
   5. Keep each finding's original path, batch token, boundary, array and index through disposition, even after another batch starts.
   6. A native report's `qa_metadata.review_round_id` must match its assigned token; a dry-run report uses `null`.
   7. A missing original binding stays unknown, never the current token.
   8. A failed or unavailable advisory review supplies no finding and no clean pass.

3. **Completion, before routing away.**
   1. Apply the caller's finding-disposition pass, Step 0 first.
   2. Then write the batch file below with the harness file tool, from every accepted source. Write it before display deduplication, and before any fix delegation, issue filing, empty-result exit or return, reply-only and bounded confirming passes included.
   3. Record each verified true finding that survived Step 0, including one tracked instead of fixed. False claims, questions and Step 0 exclusions add no record.
   4. An accepted clean batch is `{"records": []}`.
   5. Under dry-run, report the proposed observations and unavailable provenance, and write nothing.

```json
{"records":[{"kind":"review","location":"src/x.rs (`f`)","owner":"src/shared.rs (`rule`)","priority":2,"source":{"round_id":"R","artifact":"tmp/review-reviewer-correctness-T.json","array":"blockers","index":0,"identity":["artifact","tmp/review-reviewer-correctness-T.json","blockers",0]}}]}
```

Leave out an absent `owner`. Copy `priority` from the accepted artifact item the finding came from: the record keeps it once the artifact is gone. Set `source.round_id` from the original batch token. The identity takes one of these forms:

- an original local review: `["artifact", original_path, array, index]`;
- an inline or PR-level copy: `["native", source_type, original_id]`, preferring the original comment id and using a thread-only id once;
- a review-body entry: `["native", "review-body", original_review_or_comment_id, entry_token]`.

The batch's identity rules:

- A bare `file:line` supplies no native identity, and a copied native finding never takes a local artifact identity.
- An unavailable round, class or native binding sets `"unknown": true` and leaves that observation out; the other bound records stay.
- With none bound, the batch is `{"unknown":true,"records":[]}`.

Outside dry-run, record it:

```bash
.agents/skills/orch/scripts/orch-runtime state findings record --item [ISSUE_ID] [BATCH_FILE]
```

- The recorder keeps the first source provenance.
- A known identity under the same class adds nothing, even after a new round token or a native retriage.
- A known identity under another class refuses: none of the batch lands, and coverage stays unknown.
- A refused record is unread coverage.
- Record an unknown batch through the caller's route before any later query claims complete coverage.

`orch-runtime dev-return check` records a schema-valid receipt's validation refusals the same way, a failed original and its recovery separately:

- It writes one `{kind: "validation", check, source: {round_id, receipt, identity: ["receipt", round_id, receipt, check]}}` per distinct name in the receipt's `FAILING:` list.
- An empty name leaves coverage unknown.
- A pass, a pending CI, a no-verdict, a missing or invalid receipt, and a live run supply no refusal.

### Query and admission

Write a request file as an array. Each entry is `{kind: "review", location, owner?}`, copied from the proposed fix's source finding, or `{kind: "validation", check}`, copied exactly from the failed source receipt. Never derive a check name from review prose.

`orch-runtime state findings query --item [ISSUE_ID] [REQUEST_FILE]` answers `{prior, classes: [{class, observed_count, prior, sources}]}` as the reply's `result`:

- With no request file, it reports every known class.
- A review request matches a record that shares a location or owner cause key, with no transitive aliases.
- A validation request matches the exact check name.
- A request with no usable key reports `observed_count: null` and `prior: "unknown"`.
- Under unknown prior coverage, a count is a lower bound; two attributable sources still establish recurrence.
- A failed query is unread.

Both direct fix owners read that result before stamping, pruning or changing delegation time, under [design-review.md](../references/design-review.md):

- Carry the reply's `result` unchanged in the ask or status and in the next delegation.
- Give the file holding it to `orch-runtime round stamp --finding-occurrences-file`.
- No observation interrupts active work, changes a disposition, or grants another round or validation start.
