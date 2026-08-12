# Orchestration — Development Notes

Implementation details and contributor notes. End-user setup: [`README.md`](./README.md). Agent-facing instructions: [`SKILL.md`](./SKILL.md).

## Bundle Containers — Convention Inversion & Migration

The bundle default inverted: a parent with children is now a CONTAINER — never orchestrated directly, never a PR; each child is the PR unit, selection operates on unblocked children, and the container completes LAST (merge-pr closes it when the final child merges). The old delegate-the-parent reading survives only as the explicit single-PR opt-in: a `(one PR)` title marker, or a leaf issue with an internal checklist. Completion validation inverted with it: a container child validates alone as its own session root, and the container validates via `validate-completion --container` (children all Done gate it; its own summary is posted at completion time).

**Migration is per-bundle, no flag-day.** Live bundles created under either reading cut over via the marker alone: an unmarked parent with children now reads as a container; a bundle that must keep the old single-session/single-PR flow (e.g. one already mid-flight with a shared branch) opts out by adding `(one PR)` to its title. The `(one PR)` marker takes precedence over the `agent:multi` label in every container check — that precedence is what lets a legacy multi-domain (`agent:multi`) bundle opt into single-PR by title. No state, script, or cache migration is required — the markers are evaluated at selection/validation time.

## Container Close: Prose Transaction, Deliberately

merge-pr's container-close sequence (per-parent lock, snapshots, recovery,
validation, completion, repair) is agent-interpreted prose, not a helper
script — reviewed and kept that way on purpose while the container
convention is young: every step is lock-guarded and fail-closed, each exit
path names its cleanup, and the prose is the format the orchestration layer
executes natively. Mechanizing it into a tested helper is the intended
evolution once the convention stabilizes; grow that helper from this
sequence rather than re-deriving it.

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
- Wait budget: when the caller passes no `max_wait` positional arg, `PR_REVIEW_WAIT_SECS` resolves it through the same `orch-env` precedence (default 900) — the per-repo review quiet-period knob, so a repo can tune how long genuine reviewer silence lasts before the `PR_REVIEW_ON_TIMEOUT` policy applies without touching every call site. An explicit positional arg always wins.

Statuses: `approved` / `reviewed` (exit 0); `proceeded` (exit 0 — the `PR_REVIEW_ON_TIMEOUT=proceed` reviewer-down degrade: a deadline reached with zero unresolved threads and no reviewer evidence, so a credit-exhausted reviewer that posted nothing never blocks the fleet, while an open thread — which returns `comments` before the deadline — never reaches this path and a `changes_requested` verdict always blocks; the `--on-timeout block|proceed` flag overrides the setting); `changes_requested`, `comments`, `timeout` (exit 1); `error` (exit 1, or 3 on auth failure — same auth contract as `ci-wait`). Every exit path emits a final stdout result; `--json` always prints one well-formed object (review mode adds `mode`, `head_sha`, `reviews_at_head`, plus `review_evidence` — `"review"` or `"check"` — when the gate passes; with `"check"` evidence, `review_evidence_surface` additionally pins which API surface matched — `"check_run"` or `"status"`).

## Reviewer Slot Budget

`REVIEWER_SLOT_BUDGET` (project `vstack.settings.toml` `[env]`, default `0`) bounds reviewer fanout for runtimes that cap concurrent agent threads (vstack#644). The value is the runtime's total agent-session budget counting the primary session; `0` means unlimited and keeps the original semantics — every reviewer launches before coordinated delegation and persists through fix/re-review cycles. When the enumerated reviewer set exceeds the available slots (budget minus the primary minus live persistent dev/QA sessions), `review-pr` runs reviewers in sequential waves: launch up to the available slots, validate each on-disk report artifact, retire the completed session to release its slot, launch the next wave. One runtime accounting caveat behind that computation: completed subagent threads can keep counting against the cap until they are explicitly shut down (openai/codex#22779) — the mechanism behind the stale-slot accounting observed in vstack#701 — which is why waves retire each completed session rather than merely collecting its result. Re-review cycles reuse the same wave mechanics — a retired reviewer is recreated fresh and its delegation points it at the current diff plus its prior report artifact. The invariant that makes retirement safe: review state lives in on-disk artifacts and workflow state, never in reviewer session memory, and `review_delegated_at` is re-stamped per wave so `review-artifact-check` freshness gating is unchanged. Explicit configuration only — no harness detection; the Codex collaboration runtime's cap (a spawn beyond it fails with `collab spawn failed: agent thread limit reached`) is not a fixed runtime property but MultiAgentV2's configurable default of 4 total threads counting the primary — `features.multi_agent_v2.max_concurrent_threads_per_session` in `~/.codex/config.toml` — so Codex projects set `REVIEWER_SLOT_BUDGET` to whatever cap the machine config declares (`"4"` on a default config). Raising it means editing that V2 key: the legacy `agents.max_threads` is silently ignored while MultiAgentV2 is active, so raising only it changes nothing (openai/codex#33447, #33039) — set both keys to keep the legacy path consistent, and restart the session, because a running session keeps the cap it started with. The key reads through `orch-env`, so process env > `vstack.settings.toml` > default. The configured budget is advisory, the runtime cap authoritative (vstack#715): a persistent (unlimited) launch that hits the thread-limit error demotes to wave mode in place — the reviewers that did spawn become the first wave, the observed spawn count becomes the persisted wave size (`reviewer_slots_observed`), re-review cycles stay in waves, and the user receives a one-line recommendation to set `REVIEWER_SLOT_BUDGET` to the observed runtime budget. What used to be a manual workaround (running the wave invariant by hand with persisted artifacts) is the documented automatic behavior.

## CI Triggering Patterns

The `defer-ci` label pattern is retired — orch never defers, queues, or labels CI. The workflow contract that replaces it: `submit-pr.md` orders the approval gate (§ 4) before CI verification (§ 5), universally and with no repo detection, so CI that only starts after an approval can never deadlock the workflow. The portable repo-side patterns below build on that contract. They describe the **review-gate v2** architecture (canonical fleet-wide since the v2 cutover; the v1 shapes — per-run classifier gate jobs, repo-side convergence/re-fire scripts, heavy lanes keyed on an `approved` output — are retired, and their history lives in this file's git log):

- **The pending-status gate, v2** (any GitHub plan): one replaceable **commit status** (e.g. `Review gate`) is the ONLY review-gate enforcement point, required via branch protection / the merge-queue ruleset — and ONE default-branch-defined workflow (the review-gate skill's `templates/review-gate-writer.yml`) owns every write to it. The writer evaluates the vendored predicate on its own event legs (PR events, review events, status evidence, merge-group, a cron floor) and converges the status: **`pending`** while awaiting review or with unresolved threads (blocks merge exactly as hard as red, with zero false signal), **`failure`** only on a standing changes-requested, **`success`** only when the exact head is reviewed. CI's own workflows hold NO review coupling: they never evaluate the predicate, never post the gate context, and product jobs must NOT read review state to decide whether to run (`skills/review-gate/references/adoption.md` — the adoption precondition is that whether untested code can merge is branch protection's job: a merge queue running the full suite on the merged result, or no held-back jobs at all). The field data that forced the v1→v2 flip: memsira (pre-migration) measured 33 of its last 33 failed CI runs as approval-gate fail-fast — zero real failures — and every sampled merged hyprtrade PR carried 1–2 failure + 7–26 cancelled check runs from gate red and duplicate triggers. Red regains meaning: a failure is a human objection or a genuinely broken build, nothing else. Cheap lint/unit jobs can still run unconditionally on `pull_request`.
- **Merge queue** (GitHub Enterprise / public repos): run heavy CI on `merge_group`, minimal CI on `pull_request`, and require the gate context for queue entry via the ruleset. `merge-pr.md` § 5 handles the queued merge portably with `pr-merge --auto` (exit 75 = queued/armed), watches queue membership, and on ejection (failed merge-group run) routes back into ci-fix automatically — bounded, per-PR, with no cross-session coordination.
- **Review evidence surfaces are predicate configuration, not repo-side code.** Commenting-only review bots (`PR_REVIEW_GATE = "review"`) submit a review object only when they have findings; a clean re-analysis may surface only as a check-run or a commit status (vstack#654/#681). Under v2 that multiplicity is handled entirely inside the vendored predicate — review objects, trusted check-runs/statuses (`REVIEW_GATE_TRUSTED_STATUS_CONTEXTS`, skip-pattern-filtered, newest-row-decides), comment-form evidence, and the override attestation are its evidence OR-group, configured per repo in `vstack.settings.toml`. Do not hand-write gate jobs or evidence readers in a consumer repo; adjust the settings. (Orch's own `approval-wait` keeps its separate wait-side reading of the same surfaces — § Approval Wait above — but that is orch polling for its workflow, never merge enforcement.)
- **Thread resolution has no Actions trigger — the writer's cron floor is the convergence path (vstack#804).** Resolving a review thread emits NO Actions-triggerable event: `pull_request_review_thread` is webhook-only, confirmed dead across three repos (`GET /actions/runs?event=pull_request_review_thread` returns `total_count: 0` for all time on drovr, hyprtrade, and memsira — each had it configured, watched it never fire, and removed it; drovr reports `actionlint` rejects it outright). **Name the trap that canonized the dead trigger:** a workflow declaring an event Actions has never heard of still reports `state=active` — `active` means the FILE is enabled, not that its triggers are recognized; the only proof a trigger works is a run whose `event` field carries that name. Under v2 nothing needs that trigger: a PR held back purely by unresolved threads converges when the writer's cron floor (≤15 min) next evaluates the head, or immediately via a manual dispatch of the writer workflow. `pr-merge` additionally applies its own local hard gate on actionable review threads before any merge or queue mutation — bypassable only by an explicit `--force` — so thread hygiene is enforced at merge time as well wherever the documented merge path routes through the skill.
- **Convergence is the writer, not repo-side machinery.** A `success` commit status re-fires no PR workflow, so v1 needed repo-side convergence/re-fire scripts to make review-state transitions reach the gate. The v2 writer IS that convergence: its own `status`/`check_run`/review event legs and cron floor re-evaluate live state and post directly — downward transitions (dismissed review, reopened thread, changes-requested) close the gate event-fast, and the writer never re-runs CI because nothing is held back (heavy lanes execute in the merge queue regardless of review state). Its safety conventions — fail loud act never on read failure, ordering guard on success posts, converge-all enumeration so no head is stranded — are engine-internal and pinned by the skill's own tests, not consumer obligations.

- **Review-gate engine** (vendor, don't fork): the canonical implementation is the vstack **review-gate skill** — `review-predicate.sh` (the single source of truth for "is this PR head reviewed?", fail-loud contract: exit 2 = take no action, never "awaiting") and `review-writer.sh` (the single writer that converges the gate status to the predicate's verdict), vendored into consumers at `.agents/skills/review-gate/scripts/` via `vstack refresh`. See that skill's SKILL.md and references/ for the adoption procedure and settings. (The pre-v2 consumer script pair this skill used to carry — `scripts/ci/review-predicate.sh` + `scripts/ci/approval-refire.sh` — existed only for pre-v2 hyprtrade and was removed with the fleet's v2 cutover.)

- **No orch-side outage attestation.** Orch's reviewer-outage attestation (`PR_REVIEW_OUTAGE_CONTEXT`) was removed — owner decision 2026-08-08: orch never manufactures review evidence; a `proceed` stays a LOCAL verdict, the sanctioned no-review posture is the engine's `REVIEW_GATE_MODE=off`, and the engine's manual operator override (`REVIEW_GATE_OVERRIDE_CONTEXT`) remains for human use.

- **Tiered CI** (agent-fleet repos where full CI per PR is too slow/expensive, especially pre-release): CI's job in autonomous development is protecting `main` from the fleet — a broken `main` poisons every branch cut from it and every queue group stacked on it — so spend runtime where that protection lives, not uniformly per PR. Three tiers:

  | Tier | Trigger | Contents |
  |---|---|---|
  | small | `pull_request` (behind the review gate) | lint, typecheck, unit tests for changed areas only (path-filter via a changes-detect job); target < 8 min |
  | medium | `merge_group` | small + the full unit/integration suite on the queue's merged preview — the last check before something becomes everyone's problem |
  | full | `schedule` (nightly) ONLY — never `push` to `main` | cross-platform matrix, benchmarks, sanitizers/hermetic lanes, mobile builds — expensive lanes where a one-day detection delay is acceptable pre-release |

  Two waste guards: **no full tier on `push` to `main`** — on a merge-queue repo the queue already ran the medium suite on the exact merged tree, so a per-merge full run recreates the cost tiering exists to kill. Main-push may run the MEDIUM tier when it is nearly free (e.g. a tier resolver that reuses the queue run's proofs — hyprtrade #333's refinement), which preserves post-merge signal at medium cost; non-queue repos should run medium on main-push. Any failure-REPORTER job goes schedule-only so ordinary merges never page the issue queue. And **skip-if-unchanged nightlies** — the full-tier workflow's first job compares `main`'s HEAD against the last successful nightly's `head_sha` (`gh api repos/:owner/:repo/actions/workflows/<file>/runs?status=success&per_page=1`) and ends the run early when identical, so idle days cost one API call, not a matrix build. The guard FAILS OPEN — an API error runs the nightly rather than skipping it (a wasted run is bounded; a silently skipped regression is not).

  One implementation hazard, hit the first time the pattern shipped (hyprtrade #339): once the workflow contains a guard/classifier job that runs on only some trigger events — the tier resolver, the skip-if-unchanged guard — its `skipped` result propagates through the `needs` chain. GitHub Actions skips any job whose `needs` include a skipped job unless that job's `if` explicitly overrides the default, so on ordinary `pull_request` events every downstream product job silently skips while the workflow still reads green: CI that tests nothing and reports success. Every direct consumer of the classifier job therefore carries an explicit `if: ${{ !cancelled() && needs.<classifier>.result == 'success' }}` (`!cancelled()` restores evaluation past a skipped need; the result check still refuses to run downstream of a failed classifier) — and under the v2 fast/full split the same `if:` also carries the classifier's TIER term (the product gate, e.g. a `gate_open` output derived from the tier dial), which is what makes heavy lanes skip on fast-tier PR heads; review state never appears in these conditions. And because the guard is branch logic that decides whether CI runs at all, validate it as code: extract the guard decision into a script with a truth-table test (hyprtrade ships this as `tools/test-ci-nightly-guard`) instead of leaving it inline in YAML.

  Small-tier PR heads SKIP their product lanes via `if:` on the classifier's tier decision — never on review state; the writer-owned gate status is the review enforcement point (§ The pending-status gate, v2 above), and the merge queue runs the full suite on the merged result — so no per-job gate step, no billed-minute minimums on unapproved pushes, and comment hygiene enforces through the predicate's unresolved-thread term rather than a red job; `merge_group` runs the full tier by construction. (The retired fail-red shape put a gate step at the top of every small-tier job and billed ~4-8 dead minutes per pre-evidence push; its per-job shape existed only to keep `rerun-failed-jobs` viable — a constraint the convergence full-rerun removes, along with the keep-in-sync obligation it created between this note and the bridge's mode selection.) **Nightly failures self-file**: no session waits for a scheduled run, so the full-tier workflow's `on-failure` step files the report into the repo's issue queue, where the normal steward/overseer triage loop picks it up next cycle. Dedupe with a stable marker title — search first, comment on the existing issue instead of stacking duplicates:

  ```bash
  gh issue list --repo "$REPO" --state open --search 'in:title "nightly-ci:"' --label ci-nightly --json number --jq '.[0].number // empty'
  ```

  Create with a routing label and the run link (`gh issue create --label ci-nightly --title "nightly-ci: <lane> failed on main@<sha>" --body-file ...`); comment the new run URL on the existing issue when the search hits. **Tracker note**: repos with Linear's GitHub Issues sync enabled need nothing extra — the GitHub issue is ingested into the Linear team automatically (verified on hyprtrade: synced issues arrive in Backlog with no project/labels/assignee, and the repo's tracker-routed audit loop — `audit-issues` § 1.2/§ 7 — owns that routing as its normal job). Do not dual-write from CI to Linear's API: it duplicates the synced issue and puts tracker credentials in workflows for no gain. Repos without the sync file to GitHub only; their audit loop reads GitHub directly (tracker routing, vstack#655). Tiering is a dial, not a one-way door — ratchet heavy lanes back toward per-PR as release approaches.

- **Aggregate required-check publisher** (any protected branch; load-bearing once CI is tiered): protected branches require exactly ONE stable aggregate commit-status context, published by a truth-table publisher job — hyprtrade #339 is the origin implementation and the reference shape: every job family selected for the event must succeed, every excluded family must be skipped, an unexplained skip is a failure, and publication/API errors fail closed. Listing raw job names in branch protection instead creates a standing rename hazard: any ci.yml retune that renames or re-tiers a job desynchronizes the required checks and forces an admin required-checks sync at merge time (observed on memsira, 2026-07-19) — and retunes are exactly what tiering makes routine, while renames behind a stable aggregate context never touch branch protection. Migration is one line: add the publisher job → flip protection to the single aggregate context → drop the raw job names. Two pending-status refinements, both learned from hyprtrade's field state: **awaiting-review posts `pending`, never `failure`** — a publisher that posts its required context as failure while awaiting review recreates the fail-red gate one level up; and **the publisher JOB must not exit 1 on awaiting** — a red job per gated attempt stacks failed check runs on the head (1–2 failure + up to 26 cancelled runs on every sampled merged hyprtrade PR), exactly the residue class that blocks merge-queue enqueue. Awaiting is a pending status from a green job. And **pin the status context to the Actions app**: GitHub infers `app_id` on the branch-protection PATCH, so set it explicitly to the Actions app so only workflow-posted statuses can satisfy the required context — without the pin, any statuses-scoped token can post a satisfying status under the context's name.

- **Two named traps** — each nearly shipped a silently open or silently untested gate; name them so they stay named:
  1. **`neutral` counts as PASSING for required checks**, exactly like `skipped`. A "report the gate as neutral instead of red" design (costed on memsira's roadmap pre-migration) would have silently opened the gate: rulesets treat a neutral conclusion as satisfied. The ONLY awaiting-state that blocks merge without a false red is a `pending` commit status — which is why the pending-status gate is a status, not a check conclusion.
  2. **Never post `success` without proof.** A gate-context `success` may only be posted by (or on the evidence of) a run attempt that evaluated the gate open and executed its lanes — the convergence fast path requires a prior success for the gate context on the same sha before posting success directly (§ Status convergence above). Any shortcut here merges untested code behind a green gate.

  **Owner directive — a migration deletes the machinery it obsoletes, in the same PR.** The pending-status shape makes whole subsystems unreachable, and leaving them live is how the next session re-canonizes them as load-bearing. Worked examples: drovr's repair-evidence complex (`ci-required-check-evidence.yml`, `ci-required-check-repair.sh`/`.yml` — a 426-line trusted verifier — plus its `repair-probe`/`repair-evidence` jobs) exists entirely to recover heads whose required aggregate went red pre-review, a state the pending gate makes impossible: it deletes with the migration, replaced by the convergence proof read. hyprtrade's `pull_request_review` + `pull_request_review_comment` duplicate same-head triggers (the source of its cancelled-run residue in one cancel-in-progress group) go in the same change that fixes its publisher's awaiting semantics.

Always-on CI (everything on `pull_request`) needs no change — § 5 just verifies checks that already ran. `ci-wait` tolerates post-approval dispatch latency via `CI_WAIT_NO_CHECKS_GRACE` (default 180s) before reporting "no checks registered". It scopes the current-head check rollup to the latest substantive run per workflow, so a later all-skipped `COMMENTED` review dispatch cannot hide an active approved run. A custom aggregate status still pointing at the pre-approval run stays pending while a newer non-failing substantive run exists; the newer run must publish its own status before the waiter can pass, and a failed run or missing replacement remains fail-closed. GitHub's check rollup can also omit a newer same-head dispatch entirely (observed for a `pull_request_review_comment` run whose same-second `pull_request_review` sibling was cancelled by concurrency, vstack#650), so a settled failure attributable only to superseded runs is correlated against the head's Actions run list before it can terminate: any queued or in-progress substantive-event run on the head keeps the wait pending — a rerun executes as a new attempt under its original run id, so this cannot rely on run-id order (vstack#699) — a newest same-workflow run that completed successfully discards the stale failures, and a failed newest run — or a cancelled run with no newer or fresher sibling — stays terminal. This section is guidance for consuming repos; vstack's own CI is unaffected.

## Dev Completion Artifact (round-id identity)

Dev/QA implement, fix, and analysis completions are accepted from an on-disk artifact so a missing
return message — routine when a long validation outlasts the agent's turn
(vstack#770, vstack#818) — never forces re-delegation. `dev-return-write` writes it;
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

- Required: `--worktree --kind implement|fix|analysis --issue --round-id --branch`, plus `--commit --validate` for implement/fix.
- `--issue`/`--round-id` must match `^[A-Za-z0-9._-]+$` with no `..` (they form the filename — path-safe grammar); `--validate` is `pass` or begins with `FAILING:`.
- `--kind fix` OR `--bundled` requires ≥1 `--item N DECISION REASONING` — `DECISION ∈ {Applied,Skipped,Blocked}`, `N` a non-negative integer, `REASONING` non-empty. `implement` without `--bundled` may have zero items (`items: []`).
- `--kind analysis` (a read-only investigate-and-recommend round): requires exactly one of `--summary TEXT` or `--summary-file PATH` (the recommendation/evidence; the inline form exists because a harness can refuse the file write) and rejects `--commit`, `--validate`, `--validate-note`, `--item`, and `--bundled` with an error naming why; the artifact omits the `commit`/`validate`/`validate_note` keys entirely, so a validation outcome that did not occur is unrepresentable.
- Optional: `--qa-label` (repeatable), `--bundled`, `--no-summary` (sets `summary_posted:false`), `--summary TEXT` or `--summary-file PATH` (mutually exclusive; embeds inline text or file content as `summary` — for GitHub/ad-hoc rounds whose summary isn't posted to a tracker, so a lost return is recoverable).
- Writes `round_id` and `schema_version: 1`; builds the JSON with `jq` (never string concat) to a same-dir temp file and `mv`s it over the target (atomic — a concurrent checker never sees a partial artifact, and a failed generation leaves any prior receipt intact).
- Any usage/validation error → stderr + exit 2 (bad `--kind`, missing required arg, malformed `--validate`, path-unsafe `--issue`/`--round-id`, bad `--item` DECISION, empty REASONING, non-integer `N`, a missing or explicitly empty `--summary-file` value, a whitespace-only `--summary`, `--summary` combined with `--summary-file` (presence-based — an empty value still counts as supplied), a single-valued flag supplied twice, a value slot filled by one of the script's own flag tokens (a forgotten value), a `fix`/`--bundled` invocation with no `--item`, or an analysis invocation carrying a rejected flag); on success prints the artifact's absolute path.

### `dev-round-write` — the round's input record

The orchestrator-side twin of `dev-return-write`, run at stamp time (immediately
after `new-round-id`, before delegating a fix round): it persists the delegated
item set to `tmp/dev-round-[ISSUE]-[RID].json` so the set survives the
orchestrator's context — the gap that made a mid-round respawn's receipt
unrecoverable when the delegation existed only in session memory.

- Required: `--worktree --issue --round-id` plus exactly one item source —
  inline `--item N TEXT` (repeatable; `N` a canonical non-negative integer, no
  leading zeros, unique across items; `TEXT` the item's formatted block
  verbatim, non-empty) or `--items-file JSON_PATH` (a non-empty JSON array of
  `{n, text}` under the same rules, built with the harness file-write tool —
  the route for shell-hostile item text, since a literal backtick in a command
  is rejected by strict harness classifiers even quoted; extra element keys
  are dropped on normalization).
- Same path-safe `--issue`/`--round-id` grammar, atomic temp+`mv` write, and
  exit-2 error contract as `dev-return-write`; prints the record's absolute
  path.
- **Immutable per round**: an identical re-invocation is an idempotent success
  (byte-compared — jq output is deterministic); different content under the
  same round id exits 2, because a retry with a partial list must never
  silently shrink the authoritative delegated set. A changed delegation mints
  a new round id.
- Read by `dev-artifact-check --expect-items-from-round`, by a respawned dev
  agent recovering its items (`dev/workflows/dev-fix.md` § 6), and by the
  `ok==false` tail-reconciliation nudge. Canonical schema:
  [`schemas/dev-round.md`](./schemas/dev-round.md).

### `dev-artifact-check` — gates, ordered

`{ok, path, reason}`, first failing gate wins: **missing → invalid → incomplete → valid**.

- `missing` — no file at the resolved path.
- `invalid` — internal `round_id` != expected; OR not parseable JSON; OR a required field wrong-typed/empty: `.kind ∈ {implement,fix,analysis}`; `.issue`/`.branch` non-empty **strings** (arrays/objects/bools/numbers fail, not just `""`); `.round_id` a non-empty string; `.schema_version` a number. implement/fix additionally require `.commit`/`.validate` non-empty strings; kind `analysis` requires the **inverse** — no `.commit`, `.validate`, or `.validate_note` key present at all (an analysis round runs no validation, so their presence is a fabricated claim — vstack#952).
- `incomplete` — items rule fails:
  - with `--expect-items N,N,...` (fix rounds — the orchestrator passes the delegated item numbers): `items[]` must cover **exactly** that set (each expected `n` once, no unknown/duplicate, `decision ∈ {Applied,Skipped,Blocked}`, `reasoning` non-empty). A 1-item artifact cannot satisfy a 10-item delegation.
  - without `--expect-items` (kind `fix` OR `bundled: true`): a non-empty, well-formed `items[]`. Bundled sub-issue *completeness* is covered by the orchestrator's Linear `validate-completion --include-children-of` (the git/tracker "B" check; explicit single-PR bundles only — container children validate alone), not the artifact.
  - kind `implement` without `bundled` allows `items: []`.
  - kind `analysis` is complete-without-code: its gate is `.summary` being a non-empty string (the recommendation/evidence — the round's deliverable), not items.

Modes: round mode `--worktree WT --issue ISSUE --round-id RID [--expect-items ...
| --expect-items-from-round]` (the production path) and `--file <path>
[--round-id RID] [--expect-items ...]` (a test/parity affordance for
explicit-path / round-trip checks — no production caller).
`--expect-items-from-round` (round mode only, mutually exclusive with
`--expect-items`) derives the expected set from the `dev-round-write` record at
`WT/tmp/dev-round-ISSUE-RID.json`, validating the record's full schema —
parseable JSON, internal `round_id == RID`, `issue` matching `--issue`,
`schema_version` a number, non-empty `items[]` of unique integer `n` with
non-empty `text` — and exits 2 (refuses to run, never silently downgrades to
the weaker fallback gate) when the record is missing or unusable. The
count-vs-set `hint` diagnoses a typed `--expect-items` count only and is never
emitted for a from-round set. There is one identity model — round id — with no mtime gate and no legacy
positional mode. All four dev/QA delegation paths (dev-start, dev-fix,
review-pr-comments, ci-fix) mint a fresh `dev_round_id` before delegating and accept
via round mode; ci-fix's agent writes no artifact, so its check is expectedly
`missing` (the fresh token makes any prior round's leftover artifact un-matchable).
The script never runs git/tracker checks; git/tracker corroboration and exact-commit
binding (`.commit == git rev-parse HEAD`) live in the orch acceptance decision table
(`dev-start.md` § 3 / `dev-fix.md`).

## Launch Lanes (multi-account fleet selection)

`lanes` answers "which harness account should this session launch under" for
machines carrying more than one. The failure it exists for is account-level, not
session-level: when one account hits its limit mid-fleet, **every** session on it
stalls at once. Observed 2026-07-26 on hyprtrade — an account limit froze 5 of 7
workers simultaneously, each migrated by hand (vstack#894).

**Mechanism upstream, policy downstream.** `lanes` enumerates, measures, and
offers one default chooser. Which model/effort tier a lane should run, per-lane
preferences, and reserve thresholds are per-project and belong in each
consumer's own wrapper. The upstream surface deliberately exposes the numbers
instead of deciding with them.

### Headroom is the binding bucket

`headroom_pct = 100 - max(session_5h, weekly, model_weekly)`.

Not an average. An account at 5% session and 95% weekly has **5%** headroom;
averaging calls it 50% free and sends the fleet into exactly the wall this
helper exists to avoid.

### Everything unmeasurable is refused, never assumed idle

A lane is only pickable at `status: ok` with at least one parsed window. These
all yield `headroom_pct: null` and are skipped by `pick`:

| status | meaning |
|---|---|
| `no_credentials` | config dir present, no credential file or no token |
| `expired` | access token past its expiry (see below) |
| `unreachable` | usage query failed — offline, rate-limited, or rejected |
| `no_usage_data` | authenticated, but the response carried no session/weekly window (observed on an enterprise plan) |
| `error` | credential or response was not parseable |

`pick` exits **3** when nothing qualifies, distinct from 1 for a real failure, so
a caller can tell "every account is full" (wait, or raise the threshold) from
"the helper broke". `open-terminal --lane auto` maps that to a refusal that
launches nothing.

### Token refresh is opt-in

Refreshing rotates the refresh token in the credentials file, which other tools
on the machine share — a Waybar usage widget doing the same thing is the
reference case, and it already carries a lock-and-re-read for the peer-rotation
race. A lane chooser that silently rotates OAuth tokens during a fleet launch
trades a visible `expired` for an invisible auth failure across every session,
so the default is to report and let the operator decide. `--refresh` opts in and
takes the same flock, re-reading the credentials inside it.

### Two API shapes, one gotcha each

- **Claude** — `five_hour` / `seven_day` carry `utilization` + `resets_at`. The
  model-scoped weekly window moved OUT of the legacy `seven_day_sonnet` /
  `seven_day_opus` fields into `limits[]` entries with `kind == "weekly_scoped"`;
  take the most-consumed one, fall back to the legacy fields, and read the label
  from `scope.model.display_name` rather than hard-coding a model name.
- **Codex** — `primary_window` / `secondary_window` do **not** map to
  session/weekly by position. Their durations vary by account and shift over
  time: a weekly-only account reports its 7-day limit as the *primary* window
  with a null secondary. Routing by position then labels a 7-day window "5h" and
  invents a phantom 0% weekly. Route each window by its own
  `limit_window_seconds`.

### Testing

The network layer is the only impure part and is injected via
`ORCH_LANES_FETCH_CMD` (a command receiving `<harness> <config_dir>` and printing
raw usage JSON), so the suite runs offline against fixed responses. Asserting
against live accounts would pin whatever today's usage happens to be.

Bearer tokens never reach argv — anything on the box can read
`/proc/<pid>/cmdline` — so they go to curl over stdin via `-K -`.

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
