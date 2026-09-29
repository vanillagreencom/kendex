# Review gate on GitHub rulesets and Copilot approvals

GitHub now enforces everything the review gate exists for. The ruleset `pull_request` rule requires approvals, dismisses a stale approval on push and requires every review thread resolved, and the `copilot_code_review` rule requests a Copilot review on every push. Since 2026-09-01, Copilot's approval can count toward the approval rule. The owner's organization ruleset 24148602 already requires threads resolved, a Copilot review on push and squash merges on every PR-flow repository but the sandbox. The target is a delta on it: one approval, stale approvals dismissed, and Copilot approvals counting on every path. Under it the gate's writer, predicate, class policy, override, carry-forward and every `REVIEW_GATE_*` key are deleted. No consumer of the package lacks the feature: all nine PR-flow repositories are in the organization, on Enterprise Cloud, with Copilot. Kept are the parts GitHub has no answer for: the reviewer wait that detects Copilot's silence, the failure handling in the queue and CI waiters, the multi-PR reducer, and the organization-standard report. When Copilot is down or the enterprise AI-credit budget stops, the overseer approves the pull request as its own GitHub App (Use 1, § Copilot-down fallback), and no ruleset changes.

Design note, 2026-09-29, for KEN-2067 under owner direction 1790636017, owner audit decisions 1790636210 and owner direction 1790636279, rewritten on owner note 1790641164, which set the organization layout the target starts from, and amended on owner note 1790642054, which added the overseer's GitHub App. Read: [D003](../decisions/D003-one-merge-path.md), [merge-rail.md](../architecture/merge-rail.md), [park-and-resume.md § Admin merge route](park-and-resume.md#admin-merge-route), `skills/review-gate/` (SKILL.md, README.md, `references/settings.md`, `references/adoption.md`, each script's `--help`), `skills/orch/scripts/approval-wait`, `queue-wait`, `ci-wait`, `item-tier`, `skills/github/scripts/commands/pr-merge.sh` and `await-mergeable.sh`, and the kendex rulesets as the lanes app reads them on 2026-09-29.

## Sources

- [Copilot code review can now approve pull requests](https://github.blog/changelog/2026-09-01-copilot-code-review-can-now-approve-pull-requests), 2026-09-01. Approvals are off by default and are set at the enterprise, organization and repository level. An enabled approval counts toward the required-approvals rule. A push after the approval dismisses it like a person's. The approval assessment in every review's overview comment counts for nothing on its own. Public preview, on Copilot Pro, Pro+, Max, Business and Enterprise.
- docs.github.com, configure code review, read by the lane on 2026-09-29. The repository settings sit at Settings > Copilot > Code review > Auto-approval: "Allow Copilot to approve pull requests", "Allow Copilot approvals to count toward merge requirements", and "File paths", one glob per line and at most 15. An approval counts only when every changed file matches a glob, and a blank list counts every file. The organization setting sits at Settings > Copilot > Code review > Approvals, "Count Copilot approvals toward merge requirements", with the values Enabled everywhere, Let repositories decide, Enable for selected repositories and Disabled everywhere. The enterprise setting sits under AI controls, "Allow Copilot to approve pull requests", with the values Let organizations decide, Enable for selected organizations and Disabled everywhere; Disabled everywhere is the default.
- docs.github.com, use code review, read by the lane on 2026-09-29. By default Copilot leaves a Comment review. Once approvals are configured it leaves Approve reviews. Without `review_on_push` Copilot does not review a new push. Copilot reads its instructions from the head branch.
- docs.github.com, available rules for rulesets, read by the lane on 2026-09-29. The `pull_request` rule's parameters: required approvals, dismiss stale approvals on push, code owner review, dismissal restriction, last-push approval, thread resolution, allowed merge methods, required reviewers by team and file pattern, and the extra approval for unattributed Copilot pull requests.
- Owner note 1790641164, relayed as overseer directive 1790641270-2014629-2305, 2026-09-29: the organization layout the owner applied. Organization ruleset 24148602 targets hyprtrade, fleet, hyprtrade-io, kendex, vsys, memsira, drovr and vg. Each of them holds exactly two repository rulesets, `main required checks` and `main merge queue`, and every other repository ruleset is deleted. The admin-role bypass is gone everywhere. The lanes app (actor id 4925608) bypasses each `main merge queue`. The sandbox keeps its trial ruleset 24147461 until KEN-2067 lands. The lanes app cannot read the targets or the bypass actors (below), so those facts are the note's.
- Owner note 1790642054, relayed as overseer directive 1790642187-2311523-20885, 2026-09-29: the overseer's GitHub App `vanillagreen-overseer`, app id 5115517, owned by vanillagreencom and installed on all repositories (installation 165975211). Its permissions are Pull requests write and Contents write, and Checks, Statuses and Metadata read; it has no webhooks. It is a bypass actor in `pull_request` mode, which records every use on the pull request and in the audit log, on each working repository's `main required checks` (kendex 24148610) and `main merge queue` (kendex 20569265). 24148602 has no bypass actor. The checks rulesets lost the `(zero-bypass)` suffix, ids unchanged. The lanes app reads 24148610's new name and `bypass_actors` as null, so the app and bypass facts are the note's.
- kendex today, as the lanes app reads it on 2026-09-29 through `repos/vanillagreencom/kendex/rulesets?includes_parents=true` and each ruleset. All three are on `~DEFAULT_BRANCH`, and `rules/branches/main` draws every rule from them:
  - 24148602 `main protections (zero-bypass)`, organization ruleset: `deletion`, `non_fast_forward`; `pull_request` with `required_approving_review_count` 0, `dismiss_stale_reviews_on_push` false, `required_review_thread_resolution` true, `require_last_push_approval` false, `require_code_owner_review` false, `require_extra_approval_for_unattributed_changes` true, `allowed_merge_methods` `["squash"]` and `required_reviewers` empty; `copilot_code_review` with `review_on_push` true and `review_draft_pull_requests` false. `current_user_can_bypass` is `never`. The organization read of it answers 403 to the lanes app.
  - 24148610 `main required checks`, repository ruleset: `required_status_checks` for `Review gate` and seven CI job names, none bound to an app, `strict` false, `do_not_enforce_on_create` true. `current_user_can_bypass` is `never`.
  - 20569265 `main merge queue`, repository ruleset: `merge_queue` only (SQUASH, ALLGREEN, 5 entries, 90-minute check timeout). `current_user_can_bypass` is `always`, the admin merge route. GitHub withholds its `bypass_actors` from the lanes app.
  - The layout replaced two repository rulesets of 2026-09-28, both deleted and answering 404: 16519713 (`copilot_code_review`, `deletion`, `non_fast_forward`) and 20569268 (`pull_request` with 0 approvals, `required_status_checks` for `Review gate` and seven CI job names, `deletion`, `non_fast_forward`, zero bypass). 20569265 held the same `merge_queue` rule before, and was updated at 2026-09-29T00:17:41Z.
- docs.github.com, about Copilot code review, read by the lane on 2026-09-29. AI credits that members without a Copilot license consume are billed to the organization or enterprise as paid usage. When the enterprise or cost-center spending limit is exhausted, GitHub blocks code reviews.
- Sandbox proof on `vanillagreencom/review-gate-sandbox`, 2026-09-28: the owner's two notes, relayed as overseer directives 1790638858-1231047-24163 (the settings applied) and 1790639192-1327983-1295 (owner note 1790639174, the PR results). § Sandbox proof holds the values.

## Target

The target starts from the layout the owner applied on 2026-09-29 (§ Sources, § Organization rule set) and changes only what this section names.

### Organization ruleset 24148602

`main protections (zero-bypass)` takes one delta, on its `pull_request` rule:

| Parameter | Now | Target |
|---|---|---|
| `required_approving_review_count` | 0 | 1 |
| `dismiss_stale_reviews_on_push` | false | true |

Every other rule and parameter of 24148602 stays as § Sources reads it, zero bypass included.

- The approval and thread rules sit in 24148602, which nobody bypasses, the overseer app included. The admin merge (`gh pr merge N --squash --admin`, [park-and-resume.md § Admin merge route](park-and-resume.md#admin-merge-route)) therefore skips only the queue, and the overseer's emergency merge (Use 2) only the required checks and the queue. GitHub still refuses either without an approval of the current head and with an open thread.
- `require_last_push_approval` stays false. With stale approvals dismissed on every push, the only case it adds is a pusher approving their own push. No pusher in the fleet's flow approves its own push: lanes and the refresh workflow push as the lanes app, which never approves.
- The extra approval for unattributed Copilot pull requests keeps GitHub's default. No flow opens a pull request under Copilot's own identity.
- When no Copilot approval arrives, the overseer app's approval satisfies the same rule (Use 1, § Copilot-down fallback).

### Repository rulesets

Each repository keeps its two repository rulesets.

| Ruleset | Holds | Bypass | Delta |
|---|---|---|---|
| `main required checks`, kendex 24148610 | `required_status_checks`: the repository's own contexts, `strict` false, `do_not_enforce_on_create` true | the overseer app, `pull_request` mode, for Use 2 alone | `Review gate` leaves the list, and each remaining context is bound to the app that reports it: the GitHub Actions app (`integration_id` 15368) for every Actions job. One edit does both when P1 reaches the repository (§ Owner steps, step 6). |
| `main merge queue`, kendex 20569265 | `merge_queue` only | the lanes app `vanillagreen-fleet-lanes` (actor id 4925608), the admin merge route; the overseer app, `pull_request` mode, for Use 2 alone | none |

- `Review gate` leaves when P1 reaches the repository. Until then the writer posts it, and the gate holds beside the approval rule. P1 deletes the writer, so a merge group without the writer never reports `Review gate`. In kendex the edit therefore precedes queuing P1's own pull request, and in a consumer it precedes queuing the refresh pull request that carries P1.
- The binding is decided, not optional. P1 deletes the trust lists by name (the B3 row), and an unbound required context is satisfied by a check run or commit status of that name from any source that can post one to the repository. Binding closes that. It rides the `Review gate` edit, so each `main required checks` changes once.

### Copilot approval settings

- Enterprise: "Allow Copilot to approve pull requests" is Let organizations decide, in force since the sandbox proof.
- Organization: "Count Copilot approvals toward merge requirements" is Enable for selected repositories, with the nine PR-flow repositories selected: hyprtrade, fleet, hyprtrade-io, kendex, vsys, memsira, drovr, vg and review-gate-sandbox.
- Each of the nine repositories: "Allow Copilot to approve pull requests" on, "Allow Copilot approvals to count toward merge requirements" on, and "File paths" blank. GitHub puts these switches in each repository, so they are the one Copilot step a repository takes.
- File paths are blank, so a Copilot approval counts for every path. Today's gate accepts one bot review of any path, `standard` class included (`REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS` and `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE = "any"` in `kendex.settings.toml`), so a blank list keeps today's bar. A glob list would move every path outside it to the overseer's Use 1, which no direction asks for. Policy-bearing paths lose nothing: `REVIEW_GATE_CARRY_FORWARD_EXCLUDE` existed to force a fresh review on them, and dismissing stale approvals now forces a fresh approval on every path.

### What merges a pull request

A lane arms auto-merge at pull request creation, as it does today. Copilot reviews each push. An approval of the current head, zero open threads and green required checks let GitHub enroll the pull request in the queue, and the queue merges it. A push dismisses the approval, and Copilot's review of that push can approve it again. A changes-requested review from anyone with write access blocks the merge until that person approves or the review is dismissed.

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
| Outage attestation (A2) | `REVIEW_GATE_OVERRIDE_CONTEXT`, the predicate's override read | a write-access approval, the overseer app's included, counts toward the `pull_request` rule | Delete (P1). The overseer app's Use 1 replaces it (§ Copilot-down fallback). |
| Reviewer-down proceed | `PR_REVIEW_ON_TIMEOUT`, `approval-wait` `proceeded` | none | Keep: a lane-side choice between stopping and arming. An armed PR still waits on GitHub for an approval, so `proceed` merges nothing by itself. |
| Writer workflow | `scripts/review-writer.sh`, `templates/review-gate-writer.yml`: relay, converge and schedule legs | the `pull_request` rule is the status | Delete (P1). |
| Merge-queue success leg | `review-writer.sh` `merge_group` leg | none needed | Delete (P1). The audit kept it while the queue required `Review gate`, and under the target no queue requires it. |
| Predicate | `scripts/review-predicate.sh`, `review-predicate-selftest.sh` | `reviewDecision` under the approval rule | Delete (P1). |
| The gate status itself | `REVIEW_GATE_CONTEXT`, the required `Review gate` context | the approval rule | Delete (P1, owner steps). Superseded: Copilot approvals count as approvals (owner audit). |
| Gate switches | `REVIEW_GATE_MODE`, `REVIEW_GATE_WRITER` | none needed | Delete (P1, P2). There is no gate to switch off. |
| Bot wait | `approval-wait`, `PR_REVIEW_WAIT_SECS`, `pr-watch.sh` `awaiting-stale` | none: GitHub reports no reviewer silence | Keep: it detects Copilot's silence and starts the overseer's Use 1. Reads `reviewDecision` (P2, P4). |
| Evidence: review object | `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS`, `REVIEW_GATE_REVIEW_OBJECT_MIN_STATE` | Approve reviews from Copilot or from a person with write access | Delete (P1). A Comment review, a CodeRabbit, Codex or Qodo review among them, counts toward nothing. Its threads still block. |
| Evidence: trusted check or status | `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`, `REVIEW_GATE_CHECKRUN_SKIP_PATTERNS`, `REVIEW_GATE_STATUS_PUBLISHER_REJECT`, the `REVIEW_GATE_CHECK_RUN_NAME` repository variable | none: no check counts as an approval | Delete (P1). |
| Evidence: comment form | `REVIEW_GATE_COMMENT_REVIEWERS`, `REVIEW_GATE_SHA_PREFIX_FLOOR` | none | Delete (P1). |
| Errored review filter | `REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS` | an errored Copilot run submits no approval | Delete (P1). The refresh workflow's use of it goes in P6. |
| Evidence-read retries and deadline | `REVIEW_GATE_API_ATTEMPTS`, `REVIEW_GATE_API_RETRY_DELAY_SECONDS`, `REVIEW_GATE_PR_DEADLINE_SECONDS` | none needed | Delete (P1) with the reads. |
| Objection (`changes-requested`) | predicate term; `pr-merge --check` readiness | a changes-requested review from anyone with write access blocks while approvals are required | Delete the predicate term (P1). `pr-merge`'s readiness report of `reviewDecision` stays. |
| Threads (A1) | `REVIEW_GATE_THREADS`, the predicate's thread term, `pr-merge.sh` § Review-thread gate | `required_review_thread_resolution`, zero bypass | Delete all three (P1, P3). `pr-watch.sh` `threads-open` stays as the lane's early signal; it enforces nothing. |
| Bot-thread resolving (C2) | `pr-merge.sh` waiver resolve and reopen, `scripts/lib/waiver.sh` | the thread rule it got past | Delete (P3, P1). A bot nitpick on a small PR is fixed in the review instructions `bot-instructions` renders into `.github/instructions/`, which Copilot reads from the head branch. |
| Mode keys (B1) | `PR_REVIEW_GATE`, `PR_APPROVAL_GATE`, `REVIEW_GATE_MODE`, `PR_REVIEW_CHECK` | `required_approving_review_count` | Delete (P2). `approval-wait` derives the mode: `approval` where the base's rules require at least 1 approval, `off` where they require 0, exit 2 when the rules cannot be read. |
| Trust lists by name (B3) | `REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS`, `REVIEW_GATE_TRUSTED_STATUS_CONTEXTS` | GitHub counts approvals by identity, never by name | Delete (P1). Nothing is left to match by name. Owner step 6 binds each required context to the app that reports it (§ Repository rulesets). |
| `untracked-claim`, `unreasoned-decline` | predicate thread-content terms, `pr-watch.sh` | none: no setting reads reply text | Delete (P1, P4). Without a required status they block nothing. The rule stays in orch's `references/finding-disposition.md`. |
| `suppressed-findings` | predicate review-body term, `pr-watch.sh`, `scripts/lib/review-findings.sh` | none | Delete (P1, P4). Copilot's approval assessment judges its own suppressed comments. Another bot's review body counts toward nothing. |
| Carry-forward, docs-only carry included | `REVIEW_GATE_CARRY_FORWARD`, `REVIEW_GATE_VENDORED_PATHS`, `REVIEW_GATE_CARRY_FORWARD_EXCLUDE`, `REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC` | `dismiss_stale_reviews_on_push`, which is its opposite | Delete (P1). The owner's direction asks for stale approvals dismissed, and under that rule a carry cannot exist. Each docs push costs one Copilot re-review, which `review_on_push` starts. |
| Install validation | `scripts/validate.sh`, `scripts/validate-workflow.sh` | none needed | Delete (P1). Both judge only the engine's install and settings. |
| `validate-standard` | `scripts/validate-standard.sh`, `standard.json` | none: GitHub reports no repository against an organization standard | Keep. It reports a rule from a source the layout of § Target does not sanction, classic protection, and the environment and secrets [D003](../decisions/D003-one-merge-path.md) places. P5 moves its rows to the target, KEN-2070 moves its values out of the package, and KEN-2069 owns its bypass row. |
| Reviewer wait (D3) | `skills/orch/scripts/approval-wait` | `reviewDecision` | Keep, reduced (P2). What stays is failure handling: the early `comments` return that sends the lane to fix a finding, `changes_requested`, the `unreviewable` stacked base, and the timeout that starts the overseer's Use 1. P2 puts the `comments` return ahead of `approved`, so an approval beside an unresolved thread returns `comments`. Today's approval mode checks the approval first and returns `approved` whatever threads stand open. |
| Queue wait (D3) | `skills/orch/scripts/queue-wait` | none for ejection | Keep. `ejected`, `disarmed`, `conflicting` and `not_queued` are failures GitHub does not push to the lane. The late-findings guard stays for a thread opened while a PR waits in the queue; the sandbox proof does not test GitHub's answer to it. |
| CI wait (D3) | `skills/orch/scripts/ci-wait`, `skills/github/scripts/lib/ci-run-correlation.sh` | `gh pr checks --required --watch` waits, but does not say which run is current after a rerun | Keep: run matching is the part GitHub lacks. |
| Merge-state wait (D3) | `skills/github/scripts/commands/await-mergeable.sh` | auto-merge computes the state itself | Delete (P3). Its one caller, `merge-pr.md` § 3.1's `unknown:` row, arms with `pr-merge --auto` instead. |
| Multi-PR reducer | `scripts/pr-watch.sh` | none | Keep, reduced (P4): `threads-open`, `changes-requested`, `awaiting-stale`, `disarmed` and `head-moved`, all read from GitHub state. `gate-stale`, `--heal` and the writer dispatch go with the writer. |

The audit's other kept items, the byte ceiling, the commit-message shape and change-class selection inside CI jobs, are not review-gate behaviours, and this design leaves them as they are. So are the consumer refresh workflow, `provision-environment.sh` and `dispatch-refresh.sh` ([D003](../decisions/D003-one-merge-path.md) item 2), which live in the package without being part of the gate.

## Adjustments to the owner notes

- **Required contexts.** Direction 1790636279 says every repository reports `CI` and `Review gate`. The target drops `Review gate`. The audit ruling in the same session supersedes the gate status: Copilot approvals now count as approvals. Each repository keeps its own contexts in `main required checks`, and whether a list shrinks to `CI` is KEN-1906's.
- **A2.** The override's replacement is the overseer app's approval (Use 1), not a bypass. With no `Review gate` context there is nothing for a bypass to skip. An approval satisfies the only rule a Copilot outage leaves unmet.
- **Docs-only carry.** The audit kept it. Dismissing stale approvals, which direction 1790636017 asks for, leaves nothing for a carry to act on, so it goes with the engine.
- **Merge-queue success leg.** The audit kept it while `Review gate` was a queue context. It goes with the writer.
- **B3.** It needs no app-id matching in the package. The trust lists go with the engine, and owner step 6 binds each required context to the app that reports it.
- **B1.** The derived mode has two values, `approval` and `off`, because no repository in the fleet has a gate context to wait on.
- **Stand-down.** Direction 1790636017 keeps a guard for a consumer whose plan lacks the feature. No consumer does: the nine PR-flow repositories all carry Copilot under Enterprise Cloud. The engine is deleted rather than kept for an absent consumer, and git history holds it. A consumer without Copilot approvals is this design's revisit condition.
- **Sandbox globs.** The sandbox proof sets File paths to `**/*.md`, and the target leaves them blank. Every proof PR changes one `.md` file only, so the glob covers every change and the proof reads the same as it would under a blank list.

## Organization rule set

The owner applied this layout on 2026-09-29 (owner note 1790641164, § Sources). The Before column is the master's read of nine repositories and 27 rulesets on 2026-09-28.

| Item | Before | Applied on 2026-09-29 |
|---|---|---|
| `copilot_code_review` `{review_on_push true, drafts false}` | uniform, per repository | In 24148602. |
| `deletion`, `non_fast_forward` | uniform, per repository | In 24148602. |
| Thread resolution | uniform, with 0 approvals | In 24148602, with 0 approvals. The approval delta is § Target's. |
| Allowed merge methods | squash only in 6, all three in 3 | Squash only, in 24148602. The queue takes one merge method per ruleset, and `pr-merge`, `tools/lock-record` and the refresh workflow squash (KEN-2071 reads the method from GitHub). |
| Queue ruleset bypass | lanes app in fleet and kendex; admin role in hyprtrade, vsys, memsira, drovr and the sandbox; none in hyprtrade-io and vg | The lanes app, in each repository's `main merge queue`: the admin merge route of owner decision 1790633650. The overseer app joined it in `pull_request` mode (owner note 1790642054). The sandbox's 20539568 keeps its admin-role bypass until owner step 4. |
| Admin role bypassing required checks | 5 repositories | Gone everywhere. The overseer app, in `pull_request` mode, is the only bypass actor of `main required checks` (owner note 1790642054). The owner holds no standing bypass. |
| Required check names | per repository | Per repository, in `main required checks`. `Review gate` leaves each list at owner step 6. |

- Targets: 24148602 names the eight repositories (§ Sources). The sandbox joins it at owner step 4.
- The two repository rulesets are the only per-repository pieces. A repository holds no other ruleset and no classic branch protection.

## Copilot-down fallback

When Copilot is down, or the enterprise AI-credit budget stops, no Copilot approval arrives. The budget is the enterprise's because Copilot code review for members without a Copilot license bills its AI credits to the enterprise (§ Sandbox proof), and GitHub blocks code reviews once the enterprise spending limit is exhausted (§ Sources). The standing route is the overseer's GitHub App (owner note 1790642054, § Sources):

- `vanillagreen-overseer`, app id 5115517, owned by vanillagreencom, installed on all repositories (installation 165975211). Permissions: Pull requests write and Contents write; Checks, Statuses and Metadata read; no webhooks.
- Its private key sits on the control VM, mode 600. The control VM mints short-lived installation tokens for overseer sessions only. Lanes never hold it; FLT-426 scopes the lanes app tokens.
- It bypasses, in `pull_request` mode, each working repository's `main required checks` and `main merge queue`, and nothing on 24148602, so thread resolution, deletion and force-push hold even for it.

The app has two uses, and only these:

1. **Use 1, fallback approval.** When the ruleset requires an approval, no review bot has approved the head within its window (Copilot down, out of credits, a path outside the approval globs, or no verdict), and the lane's own internal review passed with no open blocker, the overseer approves the head as the app, and the approval satisfies 24148602 like Copilot's would. It sends one notice, to the master while one runs. No ruleset or setting changes. The signal is `approval-wait`'s timeout for a lane, and `pr-watch.sh`'s `awaiting-stale` line for the overseer (P4). The app authors no pull request, so an owner-authored one takes its approval too.
2. **Use 2, emergency merge.** When a required check itself cannot pass (a broken review gate, broken CI, a GitHub outage), the overseer merges the verified head as the app through its `pull_request`-mode bypass on `main required checks` and `main merge queue`, and posts a notice naming the pull request, the head, the broken check and the reason. 24148602 still holds the approval and the threads. Use 2 replaces the gate-repair break-glass of [review-gate SKILL.md § 4. Operations](../../skills/review-gate/SKILL.md#4-operations), and no one adds a temporary bypass entry.

The owner's own approval still counts, as any write-access approval does. The owner holds no standing bypass anywhere. The orch merge and approval steps that name this identity, with the merge-rail, [adoption.md](../../skills/review-gate/references/adoption.md) and review-gate SKILL.md § 4 rewrite, are KEN-2069's; this note rewrites none of them.

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
- A new decision record supersedes [D003](../decisions/D003-one-merge-path.md) item 3's `Review gate` context and its gate-repair break-glass, naming the overseer app's bypass and Use 2 (§ Copilot-down fallback) in their place.

## Consumer configuration in GitHub

A fleet repository configures only the following. Everything else it inherits from 24148602.

1. The owner adds the repository to 24148602's targets.
2. Settings > Copilot > Code review > Auto-approval: turn on "Allow Copilot to approve pull requests" and "Allow Copilot approvals to count toward merge requirements", and leave "File paths" blank.
3. Repository ruleset `main required checks` on `~DEFAULT_BRANCH`, the overseer app its only bypass actor, in `pull_request` mode: `required_status_checks` with the repository's own contexts, no `Review gate`, each context bound to the app that reports it, `strict` false, `do_not_enforce_on_create` true. A context list that shrinks to `CI` follows [harness-ci wiring.md § The CI context](../../skills/harness-ci/references/wiring.md#the-ci-context).
4. Repository ruleset `main merge queue` on `~DEFAULT_BRANCH`: `merge_queue` only, with the lanes app and the overseer app, in `pull_request` mode, its bypass actors.
5. No other ruleset and no classic branch protection.
6. Disable the `Review gate writer` workflow. After P1, the consumer's refresh pull request deletes its file.

A repository outside the organization copies 24148602 as a third repository ruleset and takes step 2.

## Sandbox proof

The master ran the proof on `vanillagreencom/review-gate-sandbox` on 2026-09-28, answering lane ask 1790638314-34793-24782. The lane's token reaches only kendex (FLT-426). Every value below is from the owner's two notes (§ Sources).

### Settings applied

| Setting | Value |
|---|---|
| New ruleset | Organization ruleset 24147461, `review-gate-sandbox: platform review target (zero-bypass)`: condition `repository_name` include `[review-gate-sandbox]`, ref `~DEFAULT_BRANCH`, zero bypass. |
| Rules of 24147461 | `pull_request`: `required_approving_review_count` 1, `dismiss_stale_reviews_on_push` true, `required_review_thread_resolution` true, `require_last_push_approval` false, `require_code_owner_review` false, `allowed_merge_methods` `["squash"]`; `copilot_code_review`: `review_on_push` true, `review_draft_pull_requests` false; `required_status_checks`: `CI Required`, `strict` false, `do_not_enforce_on_create` true; `deletion`; `non_fast_forward`. |
| Not set on 24147461 | `require_extra_approval_for_unattributed_changes`: the master found no API name for it. 24148602 carries it under that name (§ Sources). |
| Sandbox repository rulesets | 20539569 (`pull_request`, thread resolution) is disabled. 20539568 stays as the merge-queue ruleset and holds `merge_queue` only; its `required_status_checks` and `non_fast_forward` moved into 24147461. Its admin-role bypass stays, and it is what let the owner account take the admin route. |
| Workflows | `Review gate writer` is disabled; it was the only workflow posting `Review gate`. The sandbox `ci.yml` only reads the gate predicate, and with no verdict its heavy jobs fail open and run. |
| Copilot approvals | Enterprise "Allow Copilot to approve pull requests" = Let organizations decide; it was unset, which meant disabled. Organization = Enable for selected repositories: review-gate-sandbox. Sandbox approvals On by organization policy, File paths `**/*.md`. |
| Copilot review without a license | Enterprise policy "Allow members without a Copilot license to use Copilot code review" is On, and its AI credits bill to the enterprise. |
| Visibility and plan | The sandbox is private. The organization plan is enterprise (GitHub Enterprise Cloud). |

24147461 carries the delta 24148602 takes, 1 approval and stale approvals dismissed, on the same rule shape: thread resolution, no last-push or code-owner approval, squash only, `copilot_code_review` on push, `deletion` and `non_fast_forward`, zero bypass. The proof therefore covers the delta.

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

- A head Copilot does not approve. All three PRs were one-line `.md` changes inside the `**/*.md` limit. The design: no approval of the head exists, so 24148602 holds the merge. A finding sends the lane to fix it through `approval-wait`'s early `comments` return, and once P2 orders that return ahead of `approved`, a Copilot approval carrying an inline finding does too; today's approval mode returns `approved` beside an open thread. The fix push draws a new Copilot review under `review_on_push`. When no approval arrives, `approval-wait`'s timeout and `pr-watch.sh`'s `awaiting-stale` start the overseer's Use 1 (§ Copilot-down fallback). No proof PR shows the overseer app's approval counting under 24148602.
- A change outside `.md`. Under the sandbox's `**/*.md` limit, Copilot's approval of it would not count, so it needs another approval: the same Use 1, reached through the reviewer wait and `awaiting-stale`. The target leaves File paths blank, so there a Copilot approval counts for every path; no proof PR shows that.

## Issues the design makes moot

Each is moot once the item named lands. The lane dispositions them.

- KEN-2054 (approval-wait counts Copilot's error answer as review evidence): P2 deletes the `review` mode.
- KEN-2017 (withhold merge-group success over an open thread): P1 deletes the writer.
- KEN-1852 (the writer's `pull_request_review` relay leg): P1.
- KEN-1562 (kendex-web reaches gate success only by timeout): P1.
- KEN-1766 (change classes named by the review evidence they need): P1 deletes the class policy, and the classes stay CI job selection's.
- KEN-1929 (high-risk paths classify `standard` so the class policy keeps full review): its review half is moot under P1, while its CI job-selection half stands.

## Implementation items

Each is filed as a proposal comment on KEN-2067 with source PR vanillagreencom/kendex#3111, and its comment id follows its title. After this PR merges, the proposal sweep files each one and records the issue id, or the decline, as a reply on its comment. P2, P3, P4 and P6 land before P1: each removes a caller of a script P1 deletes. Nothing lands before owner steps 1 to 5 have been applied. Owner steps 6 and 7 go with P1, repository by repository (§ Owner steps).

1. **P1. review-gate: the gate engine goes and the package keeps the reducer, the standard report and the consumer refresh.** Proposal `622ef116-c72d-4b24-9bd0-72797562115f`. Scope: the `skills/review-gate/` deletions, the P1 keys and kendex's own wiring in § Deletion list, and the decision record superseding D003 item 3. Done when: outside `docs/plans/` and `docs/decisions/`, no tracked file names `review-predicate.sh`, `review-writer.sh`, `review-policy` or a P1 key; `kendex verify` passes; and a consumer refresh PR under the target removes the writer copy and its inventory entry and merges on a Copilot approval.
2. **P2. orch: the reviewer wait reads GitHub's approval rule.** Proposal `d005fdc2-2397-4adb-a3d0-c30aa7d624f1`. Scope: `approval-wait` derives `approval` or `off` from the base branch's rules and exits 2 on a failed read; in approval mode it returns `comments` while any review thread stands unresolved, ahead of `approved`, the case sandbox PR B #96 shows (a Copilot approval beside an open thread); the `review` and `exempt` modes and the P2 keys go; `item-tier`, `micro.md` and `review-pr.md` read `change-class`; and the orch documents in § Deletion list follow. Done when: `approval-wait --resolve-mode` prints `approval` against rules requiring 1 approval, `off` against 0, and exits 2 on an unreadable rules read, each row with its must-fail control; an approved head with an unresolved thread returns `comments` in approval mode, with a must-fail control replacing the `skills/orch/tests/approval_wait.sh` case that pins it as `approved`; and no orch file names `review-policy` or a P2 key.
3. **P3. github: pr-merge leaves threads and approvals to GitHub.** Proposal `716c0ec6-50d4-4d52-be61-f66f9f03f969`. Scope: the pr-merge deletions and `await-mergeable.sh` in § Deletion list. `--auto` arms only where the base's rules require at least 1 approval (`arm: no-merge-gate=required_approval`), replacing `--require-context`. Done when: `pr-merge --check` JSON carries no thread term; `--auto` refuses on a base requiring 0 approvals and arms on 1, with a must-fail control; and `github.sh` routes no `await-mergeable`. It edits the same file as KEN-2069, and either lands first.
4. **P4. review-gate: pr-watch reports GitHub's review state only.** Proposal `78dfa054-4765-4111-866d-8891f7dc7b20`. Scope: `pr-watch.sh` keeps `threads-open`, `changes-requested`, `awaiting-stale`, `disarmed` and `head-moved`, each read from GitHub; `awaiting-stale` and `disarmed` read `reviewDecision` in place of the gate status. Orch's watch routes `awaiting-stale` to the overseer's Use 1 (§ Copilot-down fallback). The P4 deletions in § Deletion list go. Done when: the pr-watch suite covers each kept kind with a must-fail control, and the script calls no predicate.
5. **P5. review-gate: validate-standard reports the target layout.** Proposal `56ef9976-c2b2-4c06-8abc-c37e0bd8d2c7`. Scope: `skills/review-gate/scripts/validate-standard.sh` accepts the layout of § Target and reports every departure from it. `standard-ruleset-source` requires `pull_request`, `copilot_code_review`, `deletion` and `non_fast_forward` from an organization ruleset, and accepts `required_status_checks` from the repository ruleset `main required checks` and `merge_queue` from `main merge queue` as repository sources, not failures. `standard-required-contexts` compares the required contexts to the repository's own context list, which KEN-2070 moves out of the package, and fails when `Review gate` is required or when the repository declares no list. The new rows `standard-required-approvals` and `standard-stale-dismissal` read 24148602's delta: the organization-sourced `pull_request` rule requires at least 1 approval and dismisses stale approvals on push. Lands after KEN-2070; the bypass row stays KEN-2069's. Done when: each new or changed row has a must-fail control in `skills/review-gate/tests/validate-standard.test.sh`, namely a repository-sourced `pull_request` rule failing `standard-ruleset-source` beside repository-sourced `required_status_checks` and `merge_queue` reading `ok`, a required `Review gate` and a missing context list each failing `standard-required-contexts`, 0 approvals failing `standard-required-approvals`, and stale approvals kept failing `standard-stale-dismissal`. On kendex after owner step 6, `standard-ruleset-source`, `standard-merge-queue`, `standard-required-contexts`, `standard-required-approvals`, `standard-stale-dismissal`, `standard-conversation-resolution`, `standard-copilot-review` and `standard-classic-protection` read `ok`, and `standard-ci-context` reads `ok` once the head of `main` came through the merge queue. `standard-ci-context` stays red on a repository that does not report `CI` until it does: the sandbox reports `CI Required`.
6. **P6. review-gate: the refresh workflow answers findings without the gate.** Proposal `958464ca-6815-42aa-8750-1b8af585dbd1`. Scope: `refresh-reviews.sh` proves the `render` class through harness-ci's `change-class`, and finds automatic reviewers by GitHub's `Bot` author type in place of the two settings. It resolves a thread only after its reply names the upstream issue it filed, and leaves the thread open when filing fails. The `Dispositions at <sha>` comment goes. Done when: the refresh suites cover a filed-and-resolved thread and a failed filing that leaves the thread open, each with a must-fail control.
7. **P7. fleet consumers: the dead review-gate keys go.** Proposal `0cf57c43-34ad-4411-877f-aecb52971e6b`. Scope: each of the eight consumers deletes the P1 and P2 keys from its own `kendex.settings.toml` once P1 and P2 have reached it through its refresh. Done when: no consumer's `kendex.settings.toml` assigns a deleted key.

## Owner steps, in order

The master applies these in order. The sandbox proof has run (§ Sandbox proof). The enterprise setting "Allow Copilot to approve pull requests" = Let organizations decide has been in force since the proof and takes no step. Steps 1 and 2 come before step 3, so no pull request waits on the overseer's Use 1 while a Copilot approval cannot count.

1. Organization Settings > Copilot > Code review > Approvals > "Count Copilot approvals toward merge requirements" stays Enable for selected repositories, and its selection widens from review-gate-sandbox to the eight repositories and the sandbox.
2. In each of those nine repositories: Settings > Copilot > Code review > Auto-approval: "Allow Copilot to approve pull requests" on, "Allow Copilot approvals to count toward merge requirements" on, "File paths" blank. In the sandbox this replaces `**/*.md` with a blank list.
3. Organization ruleset 24148602: set `required_approving_review_count` to 1 and `dismiss_stale_reviews_on_push` to true. Change nothing else.
4. Sandbox: add review-gate-sandbox to 24148602's targets, and give it the two repository rulesets of § Target. Create `main required checks` requiring `CI Required`, with the overseer app its bypass actor in `pull_request` mode. 20539568, which already holds `merge_queue` only, becomes `main merge queue`: rename it and replace its admin-role bypass with the lanes app and the overseer app, in `pull_request` mode. Then delete 24147461 and every other sandbox ruleset, 20539569 among them. The admin-role bypass that carried the proof's admin merges ends here.
5. On every open pull request in the nine repositories, request a Copilot review (`gh pr edit N --add-reviewer @copilot`), so it can draw an approval under 24148602.
6. When P1 reaches a repository, edit its `main required checks` once: delete the `Review gate` context, and bind each remaining context to the app that reports it, the GitHub Actions app (`integration_id` 15368) for every Actions job. In kendex the edit precedes queuing P1's pull request. In a consumer it precedes queuing the refresh pull request that carries P1. The sandbox, whose list holds no `Review gate`, takes the binding with kendex.
7. In the same repository, right after step 6, disable the `Review gate writer` workflow and delete the repository variable `REVIEW_GATE_CHECK_RUN_NAME` where it is set.
8. Tell the lane the ids of the sandbox's two repository rulesets from step 4, so it records them here.
