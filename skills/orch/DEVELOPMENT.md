# Orchestration — Development Notes

Implementation details and contributor notes. End-user setup: [`README.md`](./README.md). Agent-facing instructions: [`SKILL.md`](./SKILL.md).

## GitHub Auth Fallback

`approval-wait` and `ci-wait` use `scripts/lib/gh-auth.sh`, which wraps the GitHub skill's shared `scripts/lib/gh-auth.sh` helpers. Each candidate source is probed at most once during startup:

1. **Selected env token.** If `GH_TOKEN` or `GITHUB_TOKEN` is set, validate it with bounded `gh api user`.
2. **Keyring fallback.** If that env token fails, try `env -u GH_TOKEN -u GITHUB_TOKEN gh auth status` once. If it succeeds, warn on stderr and unset the stale env token.
3. **Bot-token load.** If keyring does not recover, unset stale `GH_TOKEN`/`GITHUB_TOKEN` before loading a `GH_BOT_TOKEN` candidate from process env or project config/secrets. `op://` references resolve via `op read` only after the final token source is selected. The `github.sh` router separately prefers resolved `GH_BOT_TOKEN` before resolved `GITHUB_TOKEN` so bot access is not blocked by a user token.
4. **No-env keyring.** If no env token was present at startup and no bot token loads, probe keyring auth once.
5. **Hard fail.** No path works → exit `3` with diagnostic. Callers do not poll against empty output.

The `op` CLI service-account/token setup is intentionally outside orch. Launchers may inject resolved secrets before starting Codex, Claude, or Pi; orch preserves those values instead of clobbering them with local `op://` references.

## Git HTTPS Fallback

Merge and submit workflows should use targeted `origin` git operations through
the GitHub skill's `scripts/git-https-auth` helper instead of broad remote
enumeration. The helper is a per-command fallback for SSH-backed GitHub remotes:
it validates selected env-token or keyring `gh` auth, then supplies temporary
`credential.helper=!gh auth git-credential` and `url.https://github.com/.insteadOf`
config so GitHub SSH URLs work over HTTPS. It does not persist config.

Do not use `git fetch --all --prune` for current-PR closure. Secondary remotes
may be useful for a project but optional for syncing `origin` after merge, and
their SSH failures should not block branch cleanup or tracker closure.

## Approval Wait

`PR_REVIEW_GATE` (project `vstack.settings.toml` `[env]`, default `approval`) selects the reviewer-gate mode: `approval` waits for a GitHub-native approval verdict; `review` (vstack#642) waits for a formal review of the current head — for repos whose review bots only post COMMENTED reviews and never approve; `off` is for repos with no review bots and no reviewer policy — submit-pr § 4 skips the wait and records the gate as not applicable, and merge-pr demotes `not_approved` to informational. The legacy `PR_APPROVAL_GATE` remains the documented alias: when `PR_REVIEW_GATE` is unset, `on` maps to `approval` and `off` to `off`. The derivation is implemented once — `approval-wait --resolve-mode` prints the effective mode with orch-env precedence (process env > settings > default) and workflows read it from there. Explicit configuration only: an empty requested-reviewer list cannot distinguish "no review bot" from "bot has not reviewed yet," so the tool never auto-detects.

`approval-wait` replaced `bot-review-wait` in #538. The old waiter parsed bot-specific signals — sticky-comment verdicts, checklist state, emoji reactions — which coupled the merge path to each bot's signaling dialect and provider quota. The new poller reads only GitHub-native review state:

- Approval mode: `gh pr view --json reviewDecision,latestReviews` — approved when `reviewDecision == "APPROVED"`, or, when `reviewDecision` is empty because no required-review branch protection exists, when at least one reviewer's latest review is APPROVED and none is CHANGES_REQUESTED. `REVIEW_REQUIRED` never falls back to `latestReviews` — branch protection is still waiting on required approvals. COMMENTED and DISMISSED latest reviews neither approve nor block. Any reviewer counts — human or bot — as long as it posts a formal GitHub review.
- Review mode (`--mode review`): the REST `pulls/{n}/reviews` listing (it carries `commit_id`; `latestReviews` does not) — reviewed when a submitted review is pinned to the current `headRefOid` (re-read every poll, so a force-push resets the wait), is not DISMISSED/PENDING, and is not the PR author's own. Any state counts; an approval is also a review. A non-author reviewer whose latest submitted review stands at CHANGES_REQUESTED blocks until dismissed or re-reviewed, and the gate additionally requires zero unresolved threads. When `PR_REVIEW_CHECK` names the trusted review bot's check (vstack#654), a successful signal of exactly that name on the current head (consulted only when no review object is pinned there) is accepted as alternative review evidence on EITHER surface — the newest check-run with that name concluding `success` (REST `commits/{sha}/check-runs`), or, only when no check-run matched, the head's combined commit status carrying a context of that name at state `success` (REST `commits/{sha}/status`, vstack#681 — some review bots publish statuses, not check-runs; live-verified on Devin, whose `Devin Review` evidence appears only in the statuses API) — for bots that submit a review object only when they have findings, whose clean re-analyses would otherwise deadlock the gate — under the same standing-CHANGES_REQUESTED and zero-unresolved-threads conditions. Both surfaces are matched by NAME/context, and any GitHub App, Actions workflow, or statuses-scoped token can publish under any name, so the setting must name a signal produced by the trusted review bot — the same user-configured trust model as `PR_REVIEW_NUDGE`; the matched check-run's `app.slug` (or the matched status's `creator.login`) is reported in the text output for auditing, never filtered on. No reviewer-name-specific logic anywhere — the mode is configuration, not bot detection.
- A `reviewThreads` GraphQL count of unresolved threads (paginated past 100), emitted with every result and used for a `status: "comments"` early return so callers triage new feedback instead of idling to the deadline.
- Nudging (both modes): after `PR_REVIEW_NUDGE_SECS` (default 600, `0` disables) without the mode's signal since the wait started or the head last changed, the poller nudges once per head SHA and keeps waiting inside the unchanged max_wait bound. The nudge is the user-configured `PR_REVIEW_NUDGE` comment body; when empty it falls back to a GitHub-native re-review request (`POST pulls/{n}/requested_reviewers`) to the PR's requested and past reviewers, or stays silent with nobody to re-request. A push restarts the clock and re-arms the nudge for the new head; the same head is never nudged twice. Both keys read through `orch-env`, so process env > `vstack.settings.toml` > default.

Statuses: `approved` / `reviewed` (exit 0); `proceeded` (exit 0 — the `PR_REVIEW_ON_TIMEOUT=proceed` reviewer-down degrade: a deadline reached with zero unresolved threads and no reviewer evidence, so a credit-exhausted reviewer that posted nothing never blocks the fleet, while an open thread — which returns `comments` before the deadline — never reaches this path and a `changes_requested` verdict always blocks; the `--on-timeout block|proceed` flag overrides the setting); `changes_requested`, `comments`, `timeout` (exit 1); `error` (exit 1, or 3 on auth failure — same auth contract as `ci-wait`). Every exit path emits a final stdout result; `--json` always prints one well-formed object (review mode adds `mode`, `head_sha`, `reviews_at_head`, plus `review_evidence` — `"review"` or `"check"` — when the gate passes; with `"check"` evidence, `review_evidence_surface` additionally pins which API surface matched — `"check_run"` or `"status"`).

## Reviewer Slot Budget

`REVIEWER_SLOT_BUDGET` (project `vstack.settings.toml` `[env]`, default `0`) bounds reviewer fanout for runtimes that cap concurrent agent threads (vstack#644). The value is the runtime's total agent-session budget counting the primary session; `0` means unlimited and keeps the original semantics — every reviewer launches before coordinated delegation and persists through fix/re-review cycles. When the enumerated reviewer set exceeds the available slots (budget minus the primary minus live persistent dev/QA sessions), `review-pr` runs reviewers in sequential waves: launch up to the available slots, validate each on-disk report artifact, retire the completed session to release its slot, launch the next wave. One runtime accounting caveat behind that computation: completed subagent threads can keep counting against the cap until they are explicitly shut down (openai/codex#22779) — the mechanism behind the stale-slot accounting observed in vstack#701 — which is why waves retire each completed session rather than merely collecting its result. Re-review cycles reuse the same wave mechanics — a retired reviewer is recreated fresh and its delegation points it at the current diff plus its prior report artifact. The invariant that makes retirement safe: review state lives in on-disk artifacts and workflow state, never in reviewer session memory, and `review_delegated_at` is re-stamped per wave so `review-artifact-check` freshness gating is unchanged. Explicit configuration only — no harness detection; the Codex collaboration runtime's cap (a spawn beyond it fails with `collab spawn failed: agent thread limit reached`) is not a fixed runtime property but MultiAgentV2's configurable default of 4 total threads counting the primary — `features.multi_agent_v2.max_concurrent_threads_per_session` in `~/.codex/config.toml` — so Codex projects set `REVIEWER_SLOT_BUDGET` to whatever cap the machine config declares (`"4"` on a default config). Raising it means editing that V2 key: the legacy `agents.max_threads` is silently ignored while MultiAgentV2 is active, so raising only it changes nothing (openai/codex#33447, #33039) — set both keys to keep the legacy path consistent, and restart the session, because a running session keeps the cap it started with. The key reads through `orch-env`, so process env > `vstack.settings.toml` > default. The configured budget is advisory, the runtime cap authoritative (vstack#715): a persistent (unlimited) launch that hits the thread-limit error demotes to wave mode in place — the reviewers that did spawn become the first wave, the observed spawn count becomes the persisted wave size (`reviewer_slots_observed`), re-review cycles stay in waves, and the user receives a one-line recommendation to set `REVIEWER_SLOT_BUDGET` to the observed runtime budget. What used to be a manual workaround (running the wave invariant by hand with persisted artifacts) is the documented automatic behavior.

## CI Triggering Patterns

The `defer-ci` label pattern is retired — orch never defers, queues, or labels CI. The workflow contract that replaces it: `submit-pr.md` orders the approval gate (§ 4) before CI verification (§ 5), universally and with no repo detection, so CI that only starts after an approval can never deadlock the workflow. Two portable repo-side patterns build on that contract:

- **Approval-gated jobs** (any GitHub plan): trigger the workflow on `pull_request` plus `pull_request_review: types: [submitted]`. A cheap gate job checks the PR's `reviewDecision` (or latest-review approval when no required-review protection exists); heavy jobs declare `needs:` on the gate. Cheap lint/unit jobs can still run unconditionally on `pull_request`.
- **Merge queue** (GitHub Enterprise / public repos): run heavy CI on `merge_group`, minimal CI on `pull_request`, and require the approval for queue entry via branch protection. `merge-pr.md` § 5 handles the queued merge portably with `pr-merge --auto` (exit 75 = queued/armed), watches queue membership, and on ejection (failed merge-group run) routes back into ci-fix automatically — bounded, per-PR, with no cross-session coordination.
- **Review-mode gate condition** (repos with commenting-only review bots, `PR_REVIEW_GATE = "review"`): the repo-side gate job must accept **any** of three signals — a non-author review object pinned to the current head, a `success` conclusion of the trusted review bot's check-run on that head, **or** a `success` commit status with the trusted context on that head. Such bots submit a review object only when they have findings; a clean re-analysis passes their check without posting a review, so a gate requiring a review object alone deadlocks every PR that becomes clean after a push (vstack#654) — and some bots publish their evidence as a commit STATUS (statuses API), never a check-run, so a gate reading check-runs alone misses them too (vstack#681). Trigger on `pull_request`, `pull_request_review: types: [submitted]`, `pull_request_review_thread: types: [resolved, unresolved]`, and `check_run: types: [completed]` — there is no PR-attached trigger for the status surface; that is the re-fire bridge below. The `pull_request_review_thread` trigger is load-bearing and easy to miss: resolving a review thread is the ONLY signal for the gate's zero-unresolved-threads condition, and it emits no other event (no `pull_request_review`, `check_run`, or `status`). Without it a PR held red purely by unresolved threads sits red forever after the last thread is resolved — nothing re-fires the gate to flip it green — until someone pushes, re-reviews, or manually reruns CI (the thread-resolution dead-end; memsira #251, then propagated to drovr #243 / hyprtrade #386). It IS a valid Actions trigger (activity types `resolved`, `unresolved`) — live-confirmed, a workflow using it reports `state=active`; an earlier belief that it was invalid is what produced the dead-end. Keep the `unresolved` type too, symmetrically: reopening a thread must re-gate red so it cannot ride a stale green into the merge queue. Do NOT add `pull_request_review_comment` to cover resolution — it fires on new comments only (never resolution), and for GitHub App reviewers (Copilot/Devin) every inline comment spawns an `action_required` run with zero jobs, pure Actions-tab noise; `pull_request_review: [submitted]` already covers re-review. The name is repo configuration and is matched by name/context only — gate on the trusted bot's signal (the same trust model as orch's `PR_REVIEW_CHECK` setting), e.g. with `Devin Review` as the configured name:

  ```bash
  SHA=$(gh pr view "$PR" --json headRefOid -q .headRefOid)
  gh api "repos/$REPO/pulls/$PR/reviews" --paginate | jq -s 'add // []' \
    | jq -e --arg sha "$SHA" --arg author "$PR_AUTHOR" '[.[]
        | select(.commit_id == $sha and .state != "DISMISSED" and .state != "PENDING"
                 and (.user.login // "") != $author)] | length > 0' >/dev/null \
  || gh api "repos/$REPO/commits/$SHA/check-runs" \
    | jq -e '[.check_runs[] | select(.name == "Devin Review" and .conclusion == "success")]
        | length > 0' >/dev/null \
  || gh api "repos/$REPO/commits/$SHA/status" \
    | jq -e '[.statuses[] | select(.context == "Devin Review" and .state == "success")]
        | length > 0' >/dev/null
  ```

- **Status re-fire bridge** (repos whose gate reads review evidence a status-only reviewer publishes, vstack#680/#681): a `success` commit status re-fires **no** PR workflow — `pull_request`, `pull_request_review`, and `check_run` triggers all ignore it — so a gate run that failed while the trusted status was still pending stays failed forever once the status turns green. The repo needs a bridge workflow on the `status` event that filters the trusted context at state `success`, resolves the PR(s) whose **current** head equals the event SHA, and re-runs that head's failed gate runs **in place**. The `status` event runs against the DEFAULT branch's workflow file and its own checks never attach to the PR head — which is exactly why the bridge is a rerun-in-place of the head's existing runs, never a substitute CI run of its own. It is single-fire and loop-free by construction: it only touches runs with `conclusion: failure`, and a rerun emits no `status` event for the trusted context, so the bridge can never retrigger itself. Two field-proven caveats (drovr, 2026-07-18), one shared remedy: (1) a rerun replays the run's ORIGINAL event payload — stale `base.sha` and all — so a run created before a gate/verifier fix merged re-executes against the pre-fix state and can reject valid evidence; the bridge is fully correct only for runs whose original event postdates the current gate. (2) Evidence-chain CI (a verifier that requires a prior successful attempt-1 full-CI run for the candidate) can never be satisfied by rerunning after a force-push — the pushed head has no attempt-1 evidence to verify. In both cases the remedy is one fresh review event (a new attempt-1 run of the branch's gate), not another rerun. E.g. with `Devin Review` as the trusted context:

  ```yaml
  name: review-status-bridge
  on:
    status
  permissions:
    actions: write
    pull-requests: read
  jobs:
    refire:
      if: github.event.context == 'Devin Review' && github.event.state == 'success'
      runs-on: ubuntu-latest
      steps:
        - name: Rerun failed gate runs for PRs at this head
          env:
            GH_TOKEN: ${{ github.token }}
            SHA: ${{ github.event.sha }}
          run: |
            for pr in $(gh api "repos/$GITHUB_REPOSITORY/commits/$SHA/pulls" --jq '.[].number'); do
              head=$(gh pr view "$pr" --repo "$GITHUB_REPOSITORY" --json headRefOid --jq .headRefOid)
              [ "$head" = "$SHA" ] || continue
              for run in $(gh api "repos/$GITHUB_REPOSITORY/actions/runs?head_sha=$SHA" \
                  --jq '.workflow_runs[] | select(.conclusion == "failure") | .id'); do
                gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$run/rerun-failed-jobs" \
                  || gh api -X POST "repos/$GITHUB_REPOSITORY/actions/runs/$run/rerun"
              done
            done
  ```

  Conventions carried over from the memsira approval-rerun bridge (the prior art for this pattern): **quiesce** before dispatching — the failed-conclusion filter already skips runs that are queued or in progress, so a head whose gate is mid-rerun is never double-dispatched, and the current-head equality check drops superseded SHAs instead of rerunning stale runs; and **fail loud** — rerun API errors fall through `rerun-failed-jobs` to a full `rerun`, and if both fail the step (and the bridge run) fails visibly rather than swallowing the error, so a bridge that stops working is discoverable on the Actions tab. Narrow the rerun loop to the gate workflow(s) by name if unrelated workflows also fail on the head. A rerun re-executes the workflow definition pinned at the original event (see § 5.2 of `submit-pr.md`) — correct here, because the gate logic is unchanged and only the evidence it queries has since turned green.

- **Reviewer-outage recognition** (repos that gate CI on review evidence AND want `PR_REVIEW_ON_TIMEOUT=proceed` to be end-to-end, vstack#795): the `proceed` setting governs only orch's `approval-wait` — the orch-side wait stops idling and records a reviewer-down override. It does NOT by itself unblock a merge on a repo whose CI/branch-protection gate independently blocks on review evidence (the "Review-mode gate condition" above): that gate runs on GitHub events, never on orch's wait deadline, so it has no notion of "orch decided the reviewer is genuinely down". Without a corresponding CI-side signal, `proceed` is inert-for-merge there — CI Required stays red on total reviewer silence regardless of the orch setting (verified on drovr, 2026-07-23). The bridge: orch attests the outage as a commit STATUS. Set orch's `PR_REVIEW_OUTAGE_CONTEXT` to a dedicated context (e.g. `vstack-reviewer-outage`); when `approval-wait` proceeds in **review mode** — and ONLY then, so it inherits the proceed path's genuine-silence guarantee (zero unresolved threads, no review/check/status engagement at head, head unchanged during the wait) — it posts that context as `success` on the proceeded head. (The marker is review-mode only: approval mode's engagement signal excludes reviewer check-runs/statuses, and a commit status cannot satisfy native required-approvals branch protection anyway — this pattern is inherently the review-gated-CI shape.) The repo side then needs two one-line extensions, both reusing machinery it already has for `Devin Review`:
  1. **Gate predicate** — add the outage context as a fourth accepted review-evidence surface, alongside the review object / check-run / status. Concretely, add an `outageok` term to the approval OR-group so `(got || checkok || statusok || outageok)`, where `outageok` reads `repos/$REPO/commits/$SHA/status` for the outage context at state `success` on the CURRENT head. Every other condition still applies — a standing `changes_requested` and any unresolved thread still fail-close, exactly as `proceed` itself blocks on them.
  2. **Status re-fire bridge** — extend the bridge's context filter to also fire on the outage context: `github.event.context == 'Devin Review' || github.event.context == 'vstack-reviewer-outage'`. The outage status is a `status` event like any trusted-context success, so the existing rerun-in-place path re-runs the failed gate → CI Required turns green → merge.

  **SECURITY — this is a deliberate branch-protection relaxation:** the outage status lets a merge complete with no human/bot review. Three bounds make it acceptable, and all three must hold: (a) orch only attests on the hardened genuine-silence predicate (a pending or failed reviewer check is engagement, not silence, so an in-flight reviewer never triggers it; a force-push invalidates the head-pinned status); (b) the status is match-by-context and posted by orch's trusted bot token — so enable it ONLY on repos where every status publisher is trusted, the same trust model as `PR_REVIEW_CHECK`; and (c) it is a triple opt-in — `PR_REVIEW_ON_TIMEOUT=proceed` AND `PR_REVIEW_OUTAGE_CONTEXT` set AND the repo-side gate/bridge extended. Leaving `PR_REVIEW_OUTAGE_CONTEXT` empty keeps `proceed` orch-side-only (no marker, gate untouched). The status names orch as its creator, so a reviewer-outage merge is auditable in the commit's status history.

  One caller-side caveat to verify per repo: on a repo whose CI gate is red-while-awaiting-review, confirm `ci-wait` treats that red gate as **pending**, not a fixable CI failure — otherwise a `proceed` that posts the marker but whose gate has not yet re-fired green would spin `ci-fix` on a non-fixable gate-await (worse than `block`). The marker + bridge close the window (the gate goes green), but the transient red must read as pending.

- **Tiered CI** (agent-fleet repos where full CI per PR is too slow/expensive, especially pre-release): CI's job in autonomous development is protecting `main` from the fleet — a broken `main` poisons every branch cut from it and every queue group stacked on it — so spend runtime where that protection lives, not uniformly per PR. Three tiers:

  | Tier | Trigger | Contents |
  |---|---|---|
  | small | `pull_request` (behind the review gate) | lint, typecheck, unit tests for changed areas only (path-filter via a changes-detect job); target < 8 min |
  | medium | `merge_group` | small + the full unit/integration suite on the queue's merged preview — the last check before something becomes everyone's problem |
  | full | `schedule` (nightly) ONLY — never `push` to `main` | cross-platform matrix, benchmarks, sanitizers/hermetic lanes, mobile builds — expensive lanes where a one-day detection delay is acceptable pre-release |

  Two waste guards: **no full tier on `push` to `main`** — on a merge-queue repo the queue already ran the medium suite on the exact merged tree, so a per-merge full run recreates the cost tiering exists to kill. Main-push may run the MEDIUM tier when it is nearly free (e.g. a tier resolver that reuses the queue run's proofs — hyprtrade #333's refinement), which preserves post-merge signal at medium cost; non-queue repos should run medium on main-push. Any failure-REPORTER job goes schedule-only so ordinary merges never page the issue queue. And **skip-if-unchanged nightlies** — the full-tier workflow's first job compares `main`'s HEAD against the last successful nightly's `head_sha` (`gh api repos/:owner/:repo/actions/workflows/<file>/runs?status=success&per_page=1`) and ends the run early when identical, so idle days cost one API call, not a matrix build. The guard FAILS OPEN — an API error runs the nightly rather than skipping it (a wasted run is bounded; a silently skipped regression is not).

  One implementation hazard, hit the first time the pattern shipped (hyprtrade #339): once the workflow contains a guard/classifier job that runs on only some trigger events — the tier resolver, the skip-if-unchanged guard — its `skipped` result propagates through the `needs` chain. GitHub Actions skips any job whose `needs` include a skipped job unless that job's `if` explicitly overrides the default, so on ordinary `pull_request` events every downstream product job silently skips while the workflow still reads green: CI that tests nothing and reports success. Every direct consumer of the classifier job therefore carries an explicit `if: ${{ !cancelled() && needs.<classifier>.result == 'success' }}` (`!cancelled()` restores evaluation past a skipped need; the result check still refuses to run downstream of a failed classifier). And because the guard is branch logic that decides whether CI runs at all, validate it as code: extract the guard decision into a script with a truth-table test (hyprtrade ships this as `tools/test-ci-nightly-guard`) instead of leaving it inline in YAML.

  The review gate stays the first step of small-tier jobs (it costs seconds and is the comment-hygiene enforcement); `merge_group` passes through it post-review by construction. Known cost trade-off: each pre-evidence push produces a fast-fail run where every gated job bills GitHub's one-minute minimum (~4-8 billed minutes per dead run) — the per-job gate shape is load-bearing because `rerun-failed-jobs` cannot resurrect SKIPPED jobs, so a single-gate-with-`needs` design would break rerun-in-place; tiering shrinks the cost by shrinking the small tier's job count. **Nightly failures self-file**: no session waits for a scheduled run, so the full-tier workflow's `on-failure` step files the report into the repo's issue queue, where the normal steward/overseer triage loop picks it up next cycle. Dedupe with a stable marker title — search first, comment on the existing issue instead of stacking duplicates:

  ```bash
  gh issue list --repo "$REPO" --state open --search 'in:title "nightly-ci:"' --label ci-nightly --json number --jq '.[0].number // empty'
  ```

  Create with a routing label and the run link (`gh issue create --label ci-nightly --title "nightly-ci: <lane> failed on main@<sha>" --body-file ...`); comment the new run URL on the existing issue when the search hits. **Tracker note**: repos with Linear's GitHub Issues sync enabled need nothing extra — the GitHub issue is ingested into the Linear team automatically (verified on hyprtrade: synced issues arrive in Backlog with no project/labels/assignee, and the repo's tracker-routed audit loop — `audit-issues` § 1.2/§ 7 — owns that routing as its normal job). Do not dual-write from CI to Linear's API: it duplicates the synced issue and puts tracker credentials in workflows for no gain. Repos without the sync file to GitHub only; their audit loop reads GitHub directly (tracker routing, vstack#655). Tiering is a dial, not a one-way door — ratchet heavy lanes back toward per-PR as release approaches.

- **Aggregate required-check publisher** (any protected branch; load-bearing once CI is tiered): protected branches require exactly ONE stable aggregate commit-status context, published by a truth-table publisher job — hyprtrade #339 is the origin implementation and the reference shape: every job family selected for the event must succeed, every excluded family must be skipped, an unexplained skip is a failure, and publication/API errors fail closed. Listing raw job names in branch protection instead creates a standing rename hazard: any ci.yml retune that renames or re-tiers a job desynchronizes the required checks and forces an admin required-checks sync at merge time (observed on memsira, 2026-07-19) — and retunes are exactly what tiering makes routine, while renames behind a stable aggregate context never touch branch protection. Migration is one line: add the publisher job → flip protection to the single aggregate context → drop the raw job names.

Always-on CI (everything on `pull_request`) needs no change — § 5 just verifies checks that already ran. `ci-wait` tolerates post-approval dispatch latency via `CI_WAIT_NO_CHECKS_GRACE` (default 180s) before reporting "no checks registered". It scopes the current-head check rollup to the latest substantive run per workflow, so a later all-skipped `COMMENTED` review dispatch cannot hide an active approved run. A custom aggregate status still pointing at the pre-approval run stays pending while a newer non-failing substantive run exists; the newer run must publish its own status before the waiter can pass, and a failed run or missing replacement remains fail-closed. GitHub's check rollup can also omit a newer same-head dispatch entirely (observed for a `pull_request_review_comment` run whose same-second `pull_request_review` sibling was cancelled by concurrency, vstack#650), so a settled failure attributable only to superseded runs is correlated against the head's Actions run list before it can terminate: any queued or in-progress substantive-event run on the head keeps the wait pending — a rerun executes as a new attempt under its original run id, so this cannot rely on run-id order (vstack#699) — a newest same-workflow run that completed successfully discards the stale failures, and a failed newest run — or a cancelled run with no newer or fresher sibling — stays terminal. This section is guidance for consuming repos; vstack's own CI is unaffected.

## Dev Completion Artifact (round-id identity)

Dev/QA implement-or-fix completions are accepted from an on-disk artifact so a lost
return message — a long validation exceeding the harness tool timeout mid-tail
(vstack#770) — never forces re-delegation. `dev-return-write` writes it;
`dev-artifact-check` validates it. The canonical schema is
[`schemas/dev-return.md`](./schemas/dev-return.md); the developer-facing mechanics
are below.

### Round-id identity (vstack#776)

Each delegation mints a unique token via `workflow-state new-round-id [ISSUE]
dev_round_id` (`date +%s%N`-`$RANDOM` — a nanosecond timestamp plus random
suffix, distinct even across rapid re-stamps) and embeds it in the delegation.
`dev-return-write --round-id RID` names the file `tmp/dev-return-[ISSUE]-[RID].json`
and writes `"round_id": RID` inside; `dev-artifact-check --round-id RID` resolves that
exact path and requires the internal `round_id` to match. This replaced the earlier
`mtime >= dev_delegated_at` freshness gate (dropped entirely), which proved only
*when* bytes were written — so a same-second re-stamp, a timed-out old-round agent
rewriting late, a bundle group-A receipt consumed by group-B, or a cross-round
ci-fix receipt could all be mis-accepted at the single reused path. `dev_delegated_at`
remains, now solely as the stall watchdog deadline.

### `dev-return-write` — deterministic, atomic

- Required: `--worktree --kind implement|fix --issue --round-id --branch --commit --validate`.
- `--issue`/`--round-id` must match `^[A-Za-z0-9._-]+$` with no `..` (they form the filename — path-safe grammar); `--validate` is `pass` or begins with `FAILING:`.
- `--kind fix` OR `--bundled` requires ≥1 `--item N DECISION REASONING` — `DECISION ∈ {Applied,Skipped,Blocked}`, `N` a non-negative integer, `REASONING` non-empty. `implement` without `--bundled` may have zero items (`items: []`).
- Optional: `--qa-label` (repeatable), `--bundled`, `--no-summary` (sets `summary_posted:false`), `--summary-file PATH` (embeds file content as `summary` — for GitHub/ad-hoc rounds whose summary isn't posted to a tracker, so a lost return is recoverable).
- Writes `round_id` and `schema_version: 1`; builds the JSON with `jq` (never string concat) to a same-dir temp file and `mv`s it over the target (atomic — a concurrent checker never sees a partial artifact, and a failed generation leaves any prior receipt intact).
- Any usage/validation error → stderr + exit 2 (bad `--kind`, missing required arg, malformed `--validate`, path-unsafe `--issue`/`--round-id`, bad `--item` DECISION, empty REASONING, non-integer `N`, a missing `--summary-file`, or a `fix`/`--bundled` invocation with no `--item`); on success prints the artifact's absolute path.

### `dev-artifact-check` — gates, ordered

`{ok, path, reason}`, first failing gate wins: **missing → invalid → incomplete → valid**.

- `missing` — no file at the resolved path.
- `invalid` — internal `round_id` != expected; OR not parseable JSON; OR a required field wrong-typed/empty: `.kind ∈ {implement,fix}`; `.issue`/`.branch`/`.commit`/`.validate` non-empty **strings** (arrays/objects/bools/numbers fail, not just `""`); `.round_id` a non-empty string; `.schema_version` a number.
- `incomplete` — items rule fails:
  - with `--expect-items N,N,...` (fix rounds — the orchestrator passes the delegated item numbers): `items[]` must cover **exactly** that set (each expected `n` once, no unknown/duplicate, `decision ∈ {Applied,Skipped,Blocked}`, `reasoning` non-empty). A 1-item artifact cannot satisfy a 10-item delegation.
  - without `--expect-items` (kind `fix` OR `bundled: true`): a non-empty, well-formed `items[]`. Bundled sub-issue *completeness* is covered by the orchestrator's Linear `validate-completion --include-children-of` (the git/tracker "B" check), not the artifact.
  - kind `implement` without `bundled` allows `items: []`.

Modes: round mode `--worktree WT --issue ISSUE --round-id RID [--expect-items ...]`
(the production path) and `--file <path> [--round-id RID] [--expect-items ...]` (a
test/parity affordance for explicit-path / round-trip checks — no production
caller). There is one identity model — round id — with no mtime gate and no legacy
positional mode. All four dev/QA delegation paths (dev-start, dev-fix,
review-pr-comments, ci-fix) mint a fresh `dev_round_id` before delegating and accept
via round mode; ci-fix's agent writes no artifact, so its check is expectedly
`missing` (the fresh token makes any prior round's leftover artifact un-matchable).
The script never runs git/tracker checks; git/tracker corroboration and exact-commit
binding (`.commit == git rev-parse HEAD`) live in the orch acceptance decision table
(`dev-start.md` § 3 / `dev-fix.md`).

## Tests

```bash
bash skills/orch/tests/run-all.sh
# Filter:
bash skills/orch/tests/run-all.sh session_init
```

Tests stage isolated repos/worktrees with parametrized CLI stubs on `PATH`. Each `tests/*.sh` is self-contained and prints `pass: N fail: M`. Suites:

- `approval_wait.sh` — GitHub-native approval verdict detection, review-mode gating (head pinning, author/DISMISSED exclusion, standing CHANGES_REQUESTED, thread resolution, `PR_REVIEW_CHECK` check-run and commit-status evidence), `--resolve-mode` precedence + output contract.
- `ci_wait.sh` — CI-wait state machine + auth ladder.
- `session_init.sh` — worktree Linear auth diagnostic preservation.
- `review_artifact_check.sh` — deterministic reviewer artifact acceptance (`review-artifact-check`), including `--file` freshness with an optional delegated-at boundary, plus review-pr and submit-pr `--file` wiring assertions.

All tests discovered by `run-all.sh` are part of the installed orch skill and
must pass in downstream projects without access to the vstack source checkout.
The source-only CLI/generator regression runs through
`cli/scripts/integration-check.sh`; it validates install/refresh byte identity,
markdownlint, idempotence, the refreshed downstream `run-all.sh` suite, and the
installed dev work-item cache-preflight contract.

## Codex App Worktree Routing

Codex Desktop handoff starts each child thread in an app-managed worktree, often on detached `HEAD`. App handoff must first run `codex-app-agent-preflight`; generated Codex agent TOMLs must be tracked under `.codex/agents/*.toml` in the saved project branch for generated agent types to be visible before child creation. Local ignored/generated files are not enough: setup hooks, `WORKTREE_SYMLINKS`, and `codex-setup` run too late for subagent type discovery. Missing or ignored agent TOMLs are a warning gate, not a hard blocker: show the warning and continue only after explicit user acceptance of the `worker` fallback risk.

When preflight passes, create the app worktree from the resolved base branch (`startingState: {type: "branch", branchName: "[BASE_BRANCH]"}`), not from the controller `working-tree` snapshot. The branch path avoids dirty controller state; the tracked-agent preflight documents whether generated Codex agent types should be available before first delegation.

`session-init --json github OWNER/REPO#N` is the normalization boundary: it converts the GitHub ref to `issue-N`, calls the worktree skill's `codex-branch` helper when the cwd is under `~/.codex/worktrees`, and returns the normalized issue context to `start-worktree.md`.

The managed lifecycle relies on committed branch diffs. `dev-start.md`, `review-pr.md`, and `submit-pr.md` must reject dirty or detached worktrees before review/submission so uncommitted edits cannot be treated as "no changes".
