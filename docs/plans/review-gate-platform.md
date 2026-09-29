# Review gate on GitHub rulesets and Copilot approvals

GitHub now enforces everything the review gate exists for. The ruleset `pull_request` rule requires approvals, dismisses a stale approval on push and requires every review thread resolved, and the `copilot_code_review` rule requests a Copilot review on every push. Since 2026-09-01, Copilot's approval can count toward the approval rule. The target is one organization rule set: one approval, stale approvals dismissed, threads resolved, Copilot review on push, and Copilot approvals counting on every path. Under it the gate's writer, predicate, class policy, override, carry-forward and every `REVIEW_GATE_*` key are deleted. No consumer of the package lacks the feature: all nine PR-flow repositories are in the organization, on Enterprise Cloud, with Copilot. Kept are the parts GitHub has no answer for: the reviewer wait that detects Copilot's silence, the failure handling in the queue and CI waiters, the multi-PR reducer, and the organization-standard report. When Copilot is down or the enterprise AI-credit budget stops, the owner approves the pull request, and no ruleset changes.

Design note, 2026-09-29, for KEN-2067 under owner direction 1790636017, owner audit decisions 1790636210 and owner direction 1790636279. Read: [D003](../decisions/D003-one-merge-path.md), [merge-rail.md](../architecture/merge-rail.md), [park-and-resume.md § Admin merge route](park-and-resume.md#admin-merge-route), `skills/review-gate/` (SKILL.md, README.md, `references/settings.md`, `references/adoption.md`, each script's `--help`), `skills/orch/scripts/approval-wait`, `queue-wait`, `ci-wait`, `item-tier`, `skills/github/scripts/commands/pr-merge.sh` and `await-mergeable.sh`, and the kendex rulesets as the lanes app reads them on 2026-09-29.

## Sources

- [Copilot code review can now approve pull requests](https://github.blog/changelog/2026-09-01-copilot-code-review-can-now-approve-pull-requests), 2026-09-01. Approvals are off by default and are set at the enterprise, organization and repository level. An enabled approval counts toward the required-approvals rule. A push after the approval dismisses it like a person's. The approval assessment in every review's overview comment counts for nothing on its own. Public preview, on Copilot Pro, Pro+, Max, Business and Enterprise.
- docs.github.com, configure code review, read by the lane on 2026-09-29. The repository settings sit at Settings > Copilot > Code review > Auto-approval: "Allow Copilot to approve pull requests", "Allow Copilot approvals to count toward merge requirements", and "File paths", one glob per line and at most 15. An approval counts only when every changed file matches a glob, and a blank list counts every file. The organization setting sits at Settings > Copilot > Code review > Approvals, "Count Copilot approvals toward merge requirements", with the values Enabled everywhere, Let repositories decide, Enable for selected repositories and Disabled everywhere. The enterprise setting sits under AI controls, "Allow Copilot to approve pull requests", with the values Let organizations decide, Enable for selected organizations and Disabled everywhere; Disabled everywhere is the default.
- docs.github.com, use code review, read by the lane on 2026-09-29. By default Copilot leaves a Comment review. Once approvals are configured it leaves Approve reviews. Without `review_on_push` Copilot does not review a new push. Copilot reads its instructions from the head branch.
- docs.github.com, available rules for rulesets, read by the lane on 2026-09-29. The `pull_request` rule's parameters: required approvals, dismiss stale approvals on push, code owner review, dismissal restriction, last-push approval, thread resolution, allowed merge methods, required reviewers by team and file pattern, and the extra approval for unattributed Copilot pull requests.
- kendex today, as the lanes app reads it on 2026-09-29. All three are repository rulesets on `~DEFAULT_BRANCH`:
  - 16519713: `copilot_code_review` (`review_on_push` true, drafts false), `deletion` and `non_fast_forward`.
  - 20569268: `pull_request` with 0 approvals, `dismiss_stale_reviews_on_push` false, `required_review_thread_resolution` true, `require_extra_approval_for_unattributed_changes` true and squash only; `required_status_checks` for `Review gate` and seven CI job names, `strict` false; `deletion` and `non_fast_forward`. The lanes app cannot bypass it.
  - 20569265: `merge_queue` (SQUASH, ALLGREEN, 5 entries, 90-minute check timeout). The lanes app can always bypass it: the admin merge route.
- docs.github.com, about Copilot code review, read by the lane on 2026-09-29. AI credits that members without a Copilot license consume are billed to the organization or enterprise as paid usage. When the enterprise or cost-center spending limit is exhausted, GitHub blocks code reviews.
- Sandbox proof on `vanillagreencom/review-gate-sandbox`, 2026-09-28: the owner's two notes, relayed as overseer directives 1790638858-1231047-24163 (the settings applied) and 1790639192-1327983-1295 (owner note 1790639174, the PR results). § Sandbox proof holds the values.

## Target

### Organization rulesets

Every ruleset below is an organization ruleset on `~DEFAULT_BRANCH`. It targets the repositories whose custom property `fleet-managed` is `true`, except where a row says otherwise.

| Ruleset | Rules | Bypass |
|---|---|---|
| `fleet: review` | `pull_request`: `required_approving_review_count` 1, `dismiss_stale_reviews_on_push` true, `required_review_thread_resolution` true, `require_last_push_approval` false, `require_code_owner_review` false, `require_extra_approval_for_unattributed_changes` true, `required_reviewers` empty, `allowed_merge_methods` `["squash"]`; `copilot_code_review`: `review_on_push` true, `review_draft_pull_requests` false; `deletion`; `non_fast_forward` | none |
| `fleet: CI` | `required_status_checks`: `CI` bound to the GitHub Actions app (`integration_id` 15368), `strict_required_status_checks_policy` false, `do_not_enforce_on_create` true. It targets, by name, only the repositories that report `CI` (§ Organization rule set) | none |
| `fleet: merge queue` | `merge_queue`: `merge_method` SQUASH, `grouping_strategy` ALLGREEN, `max_entries_to_build` 5, `min_entries_to_merge` 1, `max_entries_to_merge` 5, `min_entries_to_merge_wait_minutes` 0, `check_response_timeout_minutes` 90 | the lanes app, `vanillagreen-fleet-lanes`, as an Integration actor with mode `always` |

- The approval and thread rules sit in a ruleset nobody bypasses, as `required_status_checks` does. The admin merge (`gh pr merge N --squash --admin`, [park-and-resume.md § Admin merge route](park-and-resume.md#admin-merge-route)) therefore skips only the queue. GitHub still refuses it without an approval of the current head and with an open thread.
- `require_last_push_approval` stays false. With stale approvals dismissed on every push, the only case it adds is a pusher approving their own push. No pusher in the fleet's flow approves its own push: lanes and the refresh workflow push as the lanes app, which never approves.
- The extra approval for unattributed Copilot pull requests keeps GitHub's default. No flow opens a pull request under Copilot's own identity.

### Copilot approval settings

- Enterprise: "Allow Copilot to approve pull requests" is Let organizations decide, in force since the sandbox proof.
- Organization: "Count Copilot approvals toward merge requirements" is Enable for selected repositories, with the nine PR-flow repositories selected: hyprtrade, fleet, hyprtrade-io, kendex, vsys, memsira, drovr, vg and review-gate-sandbox.
- Each of the nine repositories: "Allow Copilot to approve pull requests" on, "Allow Copilot approvals to count toward merge requirements" on, and "File paths" blank. GitHub puts these switches in each repository, so they are the one Copilot step a repository takes.
- File paths are blank, so a Copilot approval counts for every path. Today's gate accepts one bot review of any path, `standard` class included (`REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` and `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "any"` in `kendex.settings.toml`), so a blank list keeps today's bar. A glob list would move every path outside it to the owner's approval, which no direction asks for. Policy-bearing paths lose nothing: `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` existed to force a fresh review on them, and dismissing stale approvals now forces a fresh approval on every path.

### What merges a pull request

A lane arms auto-merge at pull request creation, as it does today. Copilot reviews each push. An approval of the current head, zero open threads and a green `CI` let GitHub enroll the pull request in the queue, and the queue merges it. A push dismisses the approval, and Copilot's review of that push can approve it again. A changes-requested review from anyone with write access blocks the merge until that person approves or the review is dismissed.

## Behaviour-to-setting table

One row per review-gate behaviour. A kept row names its reason. None needs a stand-down: every kept row reads GitHub's own state or handles a failure GitHub does not report. `P1` to `P7` are the items in § Implementation items.

| Behaviour | Where it lives | GitHub setting | Decision |
|---|---|---|---|
| Class policy `render` (`none`) | `REVIEW_GATE_CLASS_POLICY`, `scripts/review-policy` | none: an approval count applies per ruleset, never per change class | Delete (P1). Copilot reviews the rolling refresh PR at open under `review_on_push`, and its approval replaces the waiver. The refresh workflow answers findings as P6 states. |
| Class policy `trivial` (`none`) | same | none | Delete (P1). One Copilot approval per PR. Orch's local-review skip for `trivial` stays and reads the class from harness-ci's `change-class` (P2). |
| Class policy `micro` (`none`) | same | none | Delete (P1). Orch's micro admission reads `change-class` (P2); the armed PR waits on Copilot's approval. |
| Class policy `small` (`bot`) | same | `pull_request` 1 approval, Copilot approvals | Delete (P1): the ruleset holds it. |
| Class policy `standard` (`current`) | same | same | Delete (P1): the ruleset holds it. |
| `REVIEW_GATE_CLASS_POLICY_DECISION` | `scripts/validate.sh` | none | Delete (P1) with the class policy. |
| Legacy docs-only and render-only lanes | `REVIEW_GATE_DOCS_ONLY`, `REVIEW_GATE_RENDER_PATHS` | none | Delete (P1). Each runs only after a recorded class-policy opt-out, inside the engine P1 deletes. |
| Outage attestation (A2) | `REVIEW_GATE_OVERRIDE_CONTEXT`, the predicate's override read | a person's approval counts toward the `pull_request` rule | Delete (P1). The owner's approval replaces it (§ Copilot-down fallback). No bypass entry is needed. |
| Reviewer-down proceed | `PR_REVIEW_ON_TIMEOUT`, `approval-wait` `proceeded` | none | Keep: a lane-side choice between stopping and arming. An armed PR still waits on GitHub for an approval, so `proceed` merges nothing by itself. |
| Writer workflow | `scripts/review-writer.sh`, `templates/review-gate-writer.yml`: relay, converge and schedule legs | the `pull_request` rule is the status | Delete (P1). |
| Merge-queue success leg | `review-writer.sh` `merge_group` leg | none needed | Delete (P1). The audit kept it while the queue required `Review gate`, and no queue requires it now. |
| Predicate | `scripts/review-predicate.sh`, `review-predicate-selftest.sh` | `reviewDecision` under the approval rule | Delete (P1). |
| The gate status itself | `REVIEW_GATE_CONTEXT`, the required `Review gate` context | the approval rule | Delete (P1, owner steps). Superseded: Copilot approvals count as approvals (owner audit). |
| Gate switches | `REVIEW_GATE_MODE`, `REVIEW_GATE_WRITER` | none needed | Delete (P1, P2). There is no gate to switch off. |
| Bot wait | `approval-wait`, `PR_REVIEW_WAIT_SECS`, `pr-watch.sh` `awaiting-stale` | none: GitHub reports no reviewer silence | Keep: it detects Copilot's silence and starts the owner-approval ask. Reads `reviewDecision` (P2, P4). |
| Evidence: review object | `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS`, `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | Approve reviews from Copilot or from a person with write access | Delete (P1). A Comment review, a CodeRabbit, Codex or Qodo review among them, counts toward nothing. Its threads still block. |
| Evidence: trusted check or status | `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`, `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS`, `REVIEW_GATE_STATUS_PUBLISHER_REJECT`, the `REVIEW_GATE_CHECK_RUN_NAME` repository variable | none: no check counts as an approval | Delete (P1). |
| Evidence: comment form | `REVIEW_GATE_COMMENT_REVIEWERS`, `REVIEW_GATE_SHA_PREFIX_FLOOR` | none | Delete (P1). |
| Errored review filter | `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` | an errored Copilot run submits no approval | Delete (P1). The refresh workflow's use of it goes in P6. |
| Evidence-read retries and deadline | `REVIEW_GATE_API_ATTEMPTS`, `REVIEW_GATE_API_RETRY_DELAY_SECONDS`, `REVIEW_GATE_PR_DEADLINE_SECONDS` | none needed | Delete (P1) with the reads. |
| Objection (`changes-requested`) | predicate term; `pr-merge --check` readiness | a changes-requested review from anyone with write access blocks while approvals are required | Delete the predicate term (P1). `pr-merge`'s readiness report of `reviewDecision` stays. |
| Threads (A1) | `REVIEW_GATE_THREADS`, the predicate's thread term, `pr-merge.sh` § Review-thread gate | `required_review_thread_resolution`, zero bypass | Delete all three (P1, P3). `pr-watch.sh` `threads-open` stays as the lane's early signal; it enforces nothing. |
| Bot-thread resolving (C2) | `pr-merge.sh` waiver resolve and reopen, `scripts/lib/waiver.sh` | the thread rule it got past | Delete (P3, P1). A bot nitpick on a small PR is fixed in the review instructions `bot-instructions` renders into `.github/instructions/`, which Copilot reads from the head branch. |
| Mode keys (B1) | `PR_REVIEW_GATE`, `PR_APPROVAL_GATE`, `REVIEW_GATE_MODE`, `PR_REVIEW_CHECK` | `required_approving_review_count` | Delete (P2). `approval-wait` derives the mode: `approval` where the base's rules require at least 1 approval, `off` where they require 0, exit 2 when the rules cannot be read. |
| Trust lists by name (B3) | `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS`, `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | GitHub counts approvals by identity, never by name | Delete (P1). Nothing is left to match by name. The one check kept, `CI`, is bound to the Actions app in `fleet: CI`. |
| `untracked-claim`, `unreasoned-decline` | predicate thread-content terms, `pr-watch.sh` | none: no setting reads reply text | Delete (P1, P4). Without a required status they block nothing. The rule stays in orch's `references/finding-disposition.md`. |
| `suppressed-findings` | predicate review-body term, `pr-watch.sh`, `scripts/lib/review-findings.sh` | none | Delete (P1, P4). Copilot's approval assessment judges its own suppressed comments. Another bot's review body counts toward nothing. |
| Carry-forward, docs-only carry included | `REVIEW_GATE_CARRY_FORWARD`, `REVIEW_GATE_VENDORED_PATHS`, `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, `REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC` | `dismiss_stale_reviews_on_push`, which is its opposite | Delete (P1). The owner's direction asks for stale approvals dismissed, and under that rule a carry cannot exist. Each docs push costs one Copilot re-review, which `review_on_push` starts. |
| Install validation | `scripts/validate.sh`, `scripts/validate-workflow.sh` | none needed | Delete (P1). Both judge only the engine's install and settings. |
| `validate-standard` | `scripts/validate-standard.sh`, `standard.json` | none: GitHub reports no repository against an organization standard | Keep. It reports a repository ruleset or classic protection beside the organization set, and the environment and secrets [D003](../decisions/D003-one-merge-path.md) places. P5 moves its rows to the target, KEN-2070 moves its values out of the package, and KEN-2069 owns its bypass row. |
| Reviewer wait (D3) | `skills/orch/scripts/approval-wait` | `reviewDecision` | Keep, reduced (P2). What stays is failure handling: the early `comments` return that sends the lane to fix a finding, `changes_requested`, the `unreviewable` stacked base, and the timeout that starts the owner ask. P2 puts the `comments` return ahead of `approved`, so an approval beside an unresolved thread returns `comments`. Today's approval mode checks the approval first and returns `approved` whatever threads stand open. |
| Queue wait (D3) | `skills/orch/scripts/queue-wait` | none for ejection | Keep. `ejected`, `disarmed`, `conflicting` and `not_queued` are failures GitHub does not push to the lane. The late-findings guard stays for a thread opened while a PR waits in the queue; the sandbox proof does not test GitHub's answer to it. |
| CI wait (D3) | `skills/orch/scripts/ci-wait`, `skills/github/scripts/lib/ci-run-correlation.sh` | `gh pr checks --required --watch` waits, but does not say which run is current after a rerun | Keep: run matching is the part GitHub lacks. |
| Merge-state wait (D3) | `skills/github/scripts/commands/await-mergeable.sh` | auto-merge computes the state itself | Delete (P3). Its one caller, `merge-pr.md` § 3.1's `unknown:` row, arms with `pr-merge --auto` instead. |
| Multi-PR reducer | `scripts/pr-watch.sh` | none | Keep, reduced (P4): `threads-open`, `changes-requested`, `awaiting-stale`, `disarmed` and `head-moved`, all read from GitHub state. `gate-stale`, `--heal` and the writer dispatch go with the writer. |

The audit's other kept items, the byte ceiling, the commit-message shape and change-class selection inside CI jobs, are not review-gate behaviours, and this design leaves them as they are. So are the consumer refresh workflow, `provision-environment.sh` and `dispatch-refresh.sh` ([D003](../decisions/D003-one-merge-path.md) item 2), which live in the package without being part of the gate.

## Adjustments to the owner notes

- **Required contexts.** Direction 1790636279 says every repository reports `CI` and `Review gate`. The target requires `CI` alone. The audit ruling in the same session supersedes the gate status: Copilot approvals now count as approvals.
- **A2.** The override's replacement is the owner's approval, not a temporary bypass on the checks ruleset. With no `Review gate` context there is nothing for a bypass to skip. An approval satisfies the only rule a Copilot outage leaves unmet.
- **Docs-only carry.** The audit kept it. Dismissing stale approvals, which direction 1790636017 asks for, leaves nothing for a carry to act on, so it goes with the engine.
- **Merge-queue success leg.** The audit kept it while `Review gate` was a queue context. It goes with the writer.
- **B3.** It needs no app-id matching. The trust lists go with the engine, and the one required check is bound to the Actions app.
- **B1.** The derived mode has two values, `approval` and `off`, because no repository in the fleet has a gate context to wait on.
- **Stand-down.** Direction 1790636017 keeps a guard for a consumer whose plan lacks the feature. No consumer does: the nine PR-flow repositories all carry Copilot under Enterprise Cloud. The engine is deleted rather than kept for an absent consumer, and git history holds it. A consumer without Copilot approvals is this design's revisit condition.
- **Sandbox globs.** The sandbox proof sets File paths to `**/*.md`, and the target leaves them blank. Every proof PR changes one `.md` file only, so the glob covers every change and the proof reads the same as it would under a blank list.

## Organization rule set

Today, as the master read nine repositories and 27 rulesets on 2026-09-28:

| Item | Today | Decision |
|---|---|---|
| `copilot_code_review` `{review_on_push true, drafts false}` | uniform | Unify into `fleet: review`. |
| `deletion`, `non_fast_forward` | uniform | Unify into `fleet: review`. |
| Thread resolution | uniform, with 0 approvals | Unify into `fleet: review`, with 1 approval and stale approvals dismissed. |
| Allowed merge methods | squash only in 6, all three in 3 | Owner decides. Recommendation: unify on squash only. The queue takes one merge method per ruleset, and `pr-merge`, `tools/lock-record` and the refresh workflow squash (KEN-2071 reads the method from GitHub). |
| Queue ruleset bypass | lanes app in fleet and kendex; admin role in hyprtrade, vsys, memsira, drovr and the sandbox; none in hyprtrade-io and vg | Owner decides the standing admin bypass. Recommendation: unify on the lanes app alone, the admin merge route of owner decision 1790633650, with no admin role anywhere. An admin-role bypass lets any organization admin merge past the queue by hand, and no flow uses that. |
| Admin role bypassing required checks | 5 repositories | Unify on zero bypass. The owner's approval is an ordinary approval under the target, so the owner needs no bypass to merge during a Copilot outage. |
| Required check names | per repository | Keep per repository until the repository reports `CI` on `pull_request` and `merge_group`. An organization rule requiring `CI` would block every PR of a repository that does not report it. KEN-1906 and its per-repository items carry the aggregation. |

- Targets: the custom property `fleet-managed`, of type true/false, set `true` on the nine repositories. A new repository joins with one property value, where a name list drifts. `fleet: CI` alone targets a name list: the repositories whose `validate-standard.sh` row `standard-ci-context` reads `ok`. kendex reports `CI` from `.github/workflows/skill-tests.yml`. The sandbox reports `CI Required`, not `CI` (§ Sandbox proof), so it stays off the list. When the last of the nine joins, its target becomes the property.
- The one per-repository piece is a repository ruleset `checks`, zero bypass, holding the repository's own required check names without `Review gate`. It exists only in a repository not yet in `fleet: CI`, and it is deleted the day the repository joins. The sandbox holds one requiring `CI Required` until it reports `CI`.
- The master applies the three organization rulesets and the Copilot approval settings in one step (§ Owner steps), so the rulesets change once.

## Copilot-down fallback

When Copilot is down, or the enterprise AI-credit budget stops, no Copilot approval arrives. The budget is the enterprise's because Copilot code review for members without a Copilot license bills its AI credits to the enterprise (§ Sandbox proof), and GitHub blocks code reviews once the enterprise spending limit is exhausted (§ Sources). The owner approves the pull request in GitHub, and the approval satisfies `fleet: review` like Copilot's would. No ruleset or setting changes. The signal is `approval-wait`'s timeout for a lane, and `pr-watch.sh`'s `awaiting-stale` line for the overseer (P4). The overseer puts the pull requests to the owner as one approval ask. A pull request the owner authored cannot take the owner's approval, because GitHub refuses self-approval. It waits for Copilot, or the owner adds a one-session bypass entry to `fleet: review`, merges, and removes the entry in the same session, as the gate-repair break-glass does today ([review-gate SKILL.md § 4. Operations](../../skills/review-gate/SKILL.md#4-operations)).

## Deletion list

Paths are sources. Each deletion lands with its render under `.agents/skills/` and its `.kendex-generated.json` entry, per `skills/AGENTS.md`.

`skills/review-gate/` (P1 unless marked):

- `scripts/review-predicate.sh`, `scripts/review-predicate-selftest.sh`, `scripts/review-writer.sh`, `scripts/review-policy`, `scripts/validate.sh`, `scripts/validate-workflow.sh`, `scripts/lib/waiver.sh`.
- `scripts/lib/settings.sh`: every `REVIEW_GATE_*` judge. The loader stays, for `pr-watch.sh`'s `PR_REVIEW_WAIT_SECS`.
- `scripts/lib/review-findings.sh`: `ACCEPTED_ROWS_DEF` and the suppressed-body grammar. `AUTOMATIC_AUTHOR_DEF` stays for `refresh-reviews.sh` (P6).
- `scripts/adopt-refresh.sh`: the writer adoption and its `validate-workflow.sh` call. It removes an unedited writer copy, with its inventory entry, from a consumer.
- `scripts/pr-watch.sh`: `gate-stale`, `--heal`, `--no-evaluate`, `PR_WATCH_WRITER_WORKFLOW`, the predicate call, and the `untracked-claim`, `unreasoned-decline` and `suppressed-findings` kinds (P4).
- `scripts/refresh-reviews.sh`: its predicate call and its `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` and `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` reads (P6).
- `templates/review-gate-writer.yml`.
- `references/settings.md`.
- `references/adoption.md`: the writer, validate-job, keys, repair and v1-migration sections. Repo-side wiring is rewritten to § Target.
- `kendex.settings.toml.example`: every `REVIEW_GATE_*` line.
- `SKILL.md`, `README.md`, `DEVELOPMENT.md`: everything about the engine; each keeps what stays.
- `tests/`: `class-policy-gate`, `docs-only-lane`, `predicate-re2-engine`, `predicate-selftest-table-load`, `predicate-unknown-arg`, `render-lane`, `review-policy`, `review-writer`, `review-writer-template`, `unreasoned-decline`, `validate`, `validate-workflow`, `validate-workflow-adopt`, `validate-workflow-equality`, `validate-workflow-fold` and `vendored-class` (each `.test.sh`), with `corpus/`, `lib/predicate-selftest/` and `lib/selftest-fixtures.sh`. Every other suite drops its cases for a deleted script.

Settings keys, from `kendex.settings.toml` and every document naming them:

- P1: `REVIEW_GATE_CONTEXT`, `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`, `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS`, `REVIEW_GATE_COMMENT_REVIEWERS`, `REVIEW_GATE_SHA_PREFIX_FLOOR`, `REVIEW_GATE_OVERRIDE_CONTEXT`, `REVIEW_GATE_STATUS_PUBLISHER_REJECT`, `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS`, `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE`, `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS`, `REVIEW_GATE_THREADS`, `REVIEW_GATE_API_ATTEMPTS`, `REVIEW_GATE_API_RETRY_DELAY_SECONDS`, `REVIEW_GATE_CARRY_FORWARD`, `REVIEW_GATE_VENDORED_PATHS`, `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, `REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC`, `REVIEW_GATE_PR_DEADLINE_SECONDS`, `REVIEW_GATE_CLASS_POLICY`, `REVIEW_GATE_CLASS_POLICY_DECISION`, `REVIEW_GATE_DOCS_ONLY`, `REVIEW_GATE_RENDER_PATHS`, `REVIEW_GATE_WRITER`, and the per-invocation seam `REVIEW_GATE_STATUS_SNAPSHOT_FILE`. `REVIEW_GATE_SETTINGS_FILE` stays with the loader.
- P2: `PR_REVIEW_GATE`, `PR_APPROVAL_GATE`, `PR_REVIEW_CHECK`, `REVIEW_GATE_MODE`.
- Owner steps: the repository variable `REVIEW_GATE_CHECK_RUN_NAME`, wherever it is set.
- Kept: `PR_REVIEW_WAIT_SECS` and `PR_REVIEW_ON_TIMEOUT`.

`skills/orch/` (P2 unless marked):

- `scripts/approval-wait`: the `review` and `exempt` modes, `--mode review`, the `--base` and `--head` class-policy path, and the reads of the four P2 keys.
- `scripts/item-tier`: the `review-policy --check-config` condition on a micro answer.
- `workflows/micro.md`, `workflows/review-pr.md`: the `review-policy` calls, which become `change-class` reads through `scripts/lib/change-class.sh`.
- `workflows/submit-pr.md`, `workflows/merge-pr.md`, `workflows/ci-fix.md`, `references/gates.md`, `README.md`, `kendex.settings.toml.example`: the `review` and `exempt` routing, the `REVIEW_GATE_CONTEXT` read, and `--require-context [GATE_CONTEXT]` (P3).
- `scripts/oversee-watch`, `scripts/lib/pr-watch-pass.sh`, `scripts/lib/oversee-watch-text.sh`, `references/oversee-events.md`: `gate-stale`, the heal dispatch, and the `untracked-claim`, `unreasoned-decline` and `suppressed-findings` rows (P4).

`skills/github/` (P3):

- `scripts/commands/await-mergeable.sh`, its route in `scripts/github.sh` and its row in `SKILL.md`.
- `scripts/commands/pr-merge.sh`: § Review-thread gate, the `unresolved_threads`, `review_threads_fetch_failed` and `review_policy_unreadable` issues, the `thread_waiver` and `thread_reopen` fields, the resolve and reopen steps, and `--require-context`.
- `tests/pr-merge-thread-waiver.test.sh`, and the thread rows of `tests/pr-merge.test.sh` and `tests/lib/pr-merge-world.sh`.

kendex's own wiring (P1 unless marked):

- `.github/workflows/review-gate-writer.yml`.
- `.github/workflows/skill-tests.yml`: the `gate-selftest` job, its entry in the `CI` job's `needs`, and the comment naming `Review gate` as the other required context.
- `tools/tests/review-gate-settings.test.sh` (P2).
- `tools/ci-job-set`: the paths of deleted engine files in the `review-gate` shard.
- `crates/core/src/quality/allowance.toml`: rows for deleted files, regenerated.
- `docs/architecture/merge-rail.md`: the review-gate boundary and invariant 5, and the break-glass line under § Decisions.
- A new decision record supersedes [D003](../decisions/D003-one-merge-path.md) item 3's `Review gate` context and its gate-repair break-glass.

## Consumer configuration in GitHub

A fleet repository configures only the following. Everything else it inherits.

1. Set the custom property `fleet-managed` to `true`.
2. Settings > Copilot > Code review > Auto-approval: turn on "Allow Copilot to approve pull requests" and "Allow Copilot approvals to count toward merge requirements", and leave "File paths" blank.
3. Report a job named `CI` on `pull_request` and `merge_group` ([harness-ci wiring.md § The CI context](../../skills/harness-ci/references/wiring.md#the-ci-context)), then join `fleet: CI`'s name list. Until then, hold the repository ruleset `checks`.
4. Delete every repository ruleset that `fleet: review`, `fleet: CI` or `fleet: merge queue` now covers, and any classic branch protection.
5. Disable the `Review gate writer` workflow. After P1, the consumer's refresh pull request deletes its file.

A repository outside the organization copies the three rulesets as repository rulesets and takes step 2.

## Sandbox proof

The master ran the proof on `vanillagreencom/review-gate-sandbox` on 2026-09-28, answering lane ask 1790638314-34793-24782. The lane's token reaches only kendex (FLT-426). Every value below is from the owner's two notes (§ Sources).

### Settings applied

| Setting | Value |
|---|---|
| New ruleset | Organization ruleset 24147461, `review-gate-sandbox: platform review target (zero-bypass)`: condition `repository_name` include `[review-gate-sandbox]`, ref `~DEFAULT_BRANCH`, zero bypass. |
| Rules of 24147461 | `pull_request`: `required_approving_review_count` 1, `dismiss_stale_reviews_on_push` true, `required_review_thread_resolution` true, `require_last_push_approval` false, `require_code_owner_review` false, `allowed_merge_methods` `["squash"]`; `copilot_code_review`: `review_on_push` true, `review_draft_pull_requests` false; `required_status_checks`: `CI Required`, `strict` false, `do_not_enforce_on_create` true; `deletion`; `non_fast_forward`. |
| Not set on 24147461 | `require_extra_approval_for_unattributed_changes`: the master found no API name for it. The name `fleet: review` uses is the parameter kendex ruleset 20569268 carries (§ Sources). |
| Sandbox repository rulesets | 20539569 (`pull_request`, thread resolution) is disabled. 20539568 stays as the merge-queue ruleset and holds `merge_queue` only; its `required_status_checks` and `non_fast_forward` moved into 24147461. Its admin-role bypass stays, and it is what let the owner account take the admin route. |
| Workflows | `Review gate writer` is disabled; it was the only workflow posting `Review gate`. The sandbox `ci.yml` only reads the gate predicate, and with no verdict its heavy jobs fail open and run. |
| Copilot approvals | Enterprise "Allow Copilot to approve pull requests" = Let organizations decide; it was unset, which meant disabled. Organization = Enable for selected repositories: review-gate-sandbox. Sandbox approvals On by organization policy, File paths `**/*.md`. |
| Copilot review without a license | Enterprise policy "Allow members without a Copilot license to use Copilot code review" is On, and its AI credits bill to the enterprise. |
| Visibility and plan | The sandbox is private. The organization plan is enterprise (GitHub Enterprise Cloud). |

### Results

The owner account `bmethod` ran every merge with `gh pr merge N --squash --admin`. Its admin role bypasses the queue ruleset 20539568 only, and 24147461 has no bypass actor, so every refusal below is GitHub's own. Copilot review ids were not reported, so the table gives review states only.

| PR | Head | What GitHub showed | Merge commit |
|---|---|---|---|
| A #95 | `91b40cf1` | Copilot's review read `APPROVED` about 1 min after open (23:39:24Z to 23:40:26Z, 2026-09-28). `CI Required` was green. The admin merge succeeded. | `9adbd372` |
| B #96 | `6afe4ad8` | Copilot `APPROVED`, CI green, one unresolved review thread (comment 4128119150). The admin merge was refused: `mergeStateStatus` `BLOCKED`, a `mergePullRequest` error in `gh`. With the thread resolved, the admin merge succeeded. | `ba2d282f` |
| C #97 | `2b3117d9` | Copilot `APPROVED`. A second commit, `4c2485ca`, was pushed. 20 s later the first approval read `DISMISSED` and the admin merge was refused (`BLOCKED`). `review_on_push` re-reviewed the new head by itself, and Copilot `APPROVED` it about 1 min later (23:44:27Z). CI was green, and the admin merge succeeded. | `b95d6046` |

Proven, as measured:

- Copilot's approval counts as the required approval.
- A push dismisses the stale approval.
- Copilot re-approves the new head by itself.
- An open review thread blocks even the admin route.
- No `Review gate` context and no kendex gate workflow took part.

Not proven:

- A head Copilot does not approve. All three PRs were one-line `.md` changes inside the `**/*.md` limit. The design: no approval of the head exists, so `fleet: review` holds the merge. A finding sends the lane to fix it through `approval-wait`'s early `comments` return, and once P2 orders that return ahead of `approved`, a Copilot approval carrying an inline finding does too; today's approval mode returns `approved` beside an open thread. The fix push draws a new Copilot review under `review_on_push`. When no approval arrives, `approval-wait`'s timeout and `pr-watch.sh`'s `awaiting-stale` start the owner-approval ask (§ Copilot-down fallback).
- A change outside `.md`. Under the sandbox's `**/*.md` limit, Copilot's approval of it would not count, so it needs a person's approval: the same owner-approval ask, reached through the reviewer wait and `awaiting-stale`. The target leaves File paths blank, so there a Copilot approval counts for every path; no proof PR shows that.

## Issues the design makes moot

Each is moot once the item named lands. The lane dispositions them.

- KEN-2054 (approval-wait counts Copilot's error answer as review evidence): P2 deletes the `review` mode.
- KEN-2017 (withhold merge-group success over an open thread): P1 deletes the writer.
- KEN-1852 (the writer's `pull_request_review` relay leg): P1.
- KEN-1562 (kendex-web reaches gate success only by timeout): P1.
- KEN-1766 (change classes named by the review evidence they need): P1 deletes the class policy, and the classes stay CI job selection's.
- KEN-1929 (high-risk paths classify `standard` so the class policy keeps full review): its review half is moot under P1, while its CI job-selection half stands.

## Implementation items

Each is filed as a proposal comment on KEN-2067 with source PR vanillagreencom/kendex#3111, and its comment id follows its title. After this PR merges, the proposal sweep files each one and records the issue id, or the decline, as a reply on its comment. P2, P3, P4 and P6 land before P1: each removes a caller of a script P1 deletes. Nothing lands before the owner steps have been applied in all nine repositories.

1. **P1. review-gate: the gate engine goes and the package keeps the reducer, the standard report and the consumer refresh.** Proposal `622ef116-c72d-4b24-9bd0-72797562115f`. Scope: the `skills/review-gate/` deletions, the P1 keys and kendex's own wiring in § Deletion list, and the decision record superseding D003 item 3. Done when: outside `docs/plans/` and `docs/decisions/`, no tracked file names `review-predicate.sh`, `review-writer.sh`, `review-policy` or a P1 key; `kendex verify` passes; and a consumer refresh PR under the target removes the writer copy and its inventory entry and merges on a Copilot approval.
2. **P2. orch: the reviewer wait reads GitHub's approval rule.** Proposal `d005fdc2-2397-4adb-a3d0-c30aa7d624f1`. Scope: `approval-wait` derives `approval` or `off` from the base branch's rules and exits 2 on a failed read; in approval mode it returns `comments` while any review thread stands unresolved, ahead of `approved`, the case sandbox PR B #96 shows (a Copilot approval beside an open thread); the `review` and `exempt` modes and the P2 keys go; `item-tier`, `micro.md` and `review-pr.md` read `change-class`; and the orch documents in § Deletion list follow. Done when: `approval-wait --resolve-mode` prints `approval` against rules requiring 1 approval, `off` against 0, and exits 2 on an unreadable rules read, each row with its must-fail control; an approved head with an unresolved thread returns `comments` in approval mode, with a must-fail control replacing the `skills/orch/tests/approval_wait.sh` case that pins it as `approved`; and no orch file names `review-policy` or a P2 key.
3. **P3. github: pr-merge leaves threads and approvals to GitHub.** Proposal `716c0ec6-50d4-4d52-be61-f66f9f03f969`. Scope: the pr-merge deletions and `await-mergeable.sh` in § Deletion list. `--auto` arms only where the base's rules require at least 1 approval (`arm: no-merge-gate=required_approval`), replacing `--require-context`. Done when: `pr-merge --check` JSON carries no thread term; `--auto` refuses on a base requiring 0 approvals and arms on 1, with a must-fail control; and `github.sh` routes no `await-mergeable`. It edits the same file as KEN-2069, and either lands first.
4. **P4. review-gate: pr-watch reports GitHub's review state only.** Proposal `78dfa054-4765-4111-866d-8891f7dc7b20`. Scope: `pr-watch.sh` keeps `threads-open`, `changes-requested`, `awaiting-stale`, `disarmed` and `head-moved`, each read from GitHub; `awaiting-stale` and `disarmed` read `reviewDecision` in place of the gate status. Orch's watch routes `awaiting-stale` to the owner-approval ask. The P4 deletions in § Deletion list go. Done when: the pr-watch suite covers each kept kind with a must-fail control, and the script calls no predicate.
5. **P5. review-gate: validate-standard reports the target.** Proposal `56ef9976-c2b2-4c06-8abc-c37e0bd8d2c7`. Scope: `standard-required-contexts` expects `CI` alone; new rows read the `pull_request` rule (1 approval, stale approvals dismissed, thread resolution) and `copilot_code_review` (`review_on_push`). Lands after KEN-2070; the bypass row stays KEN-2069's. Done when: each new row has a must-fail control in `validate-standard.test.sh`, and kendex reads `ok` on every row after the owner steps.
6. **P6. review-gate: the refresh workflow answers findings without the gate.** Proposal `958464ca-6815-42aa-8750-1b8af585dbd1`. Scope: `refresh-reviews.sh` proves the `render` class through harness-ci's `change-class`, and finds automatic reviewers by GitHub's `Bot` author type in place of the two settings. It resolves a thread only after its reply names the upstream issue it filed, and leaves the thread open when filing fails. The `Dispositions at <sha>` comment goes. Done when: the refresh suites cover a filed-and-resolved thread and a failed filing that leaves the thread open, each with a must-fail control.
7. **P7. fleet consumers: the dead review-gate keys go.** Proposal `0cf57c43-34ad-4411-877f-aecb52971e6b`. Scope: each of the eight consumers deletes the P1 and P2 keys from its own `kendex.settings.toml` once P1 and P2 have reached it through its refresh. Done when: no consumer's `kendex.settings.toml` assigns a deleted key.

## Owner steps, in order

The master applies these in order. The sandbox proof has run (§ Sandbox proof).

1. Enterprise: AI controls > "Allow Copilot to approve pull requests" = Let organizations decide. In force since the sandbox proof; nothing to apply.
2. Organization Settings > Copilot > Code review > Approvals > "Count Copilot approvals toward merge requirements" stays Enable for selected repositories, and its selection widens from review-gate-sandbox to the nine PR-flow repositories.
3. In each of the nine repositories: Settings > Copilot > Code review > Auto-approval: "Allow Copilot to approve pull requests" on, "Allow Copilot approvals to count toward merge requirements" on, "File paths" blank. In the sandbox this replaces `**/*.md` with a blank list.
4. Organization Settings > Custom properties: create `fleet-managed`, of type true/false, and set it `true` on the nine repositories.
5. Decide the merge methods and the standing admin bypass (§ Organization rule set holds the recommendations).
6. Create the organization ruleset `fleet: CI` (§ Target), with its name list holding each repository whose `validate-standard.sh` `standard-ci-context` row reads `ok`.
7. Create the organization ruleset `fleet: merge queue`, with the bypass decided in step 5.
8. Create the organization ruleset `fleet: review`, with the merge methods decided in step 5 and zero bypass.
9. In the sandbox, once `fleet: review` covers it: create the repository ruleset `checks` requiring `CI Required`, then delete the organization ruleset 24147461 and the disabled repository ruleset 20539569.
10. In each of the nine repositories, delete its repository rulesets and any classic branch protection. A repository not in `fleet: CI` keeps or first gets the repository ruleset `checks` with its CI check names and no `Review gate`. In the sandbox this deletes 20539568, and `fleet: merge queue` takes over the queue with the bypass decided in step 5. Under the recommended lanes-app-only bypass, the admin-role bypass that carried the proof's admin merges ends with 20539568.
11. In each of the nine repositories, disable the `Review gate writer` workflow and delete the repository variable `REVIEW_GATE_CHECK_RUN_NAME` where it is set.
12. On every open pull request in the nine repositories, request a Copilot review (`gh pr edit N --add-reviewer @copilot`), so it can draw an approval under `fleet: review`.
13. Tell the lane the ruleset ids, so it records them here.
