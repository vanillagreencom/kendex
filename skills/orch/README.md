# Orchestration

Primary-agent, single work-item orchestration for Linear and GitHub issues.

## Commands

Invoke via your AI coding harness (e.g., `/orch <command>` or `/skill:orch <command>`).

| Command | Description |
|---------|-------------|
| `start [ISSUE_ID]` | Prepare/start one Linear issue |
| `start github OWNER/REPO#N` | Prepare/start one GitHub issue |
| `start new linear\|github ...` | Create one issue, then start it |
| `handoff linear\|github ...` | Launch independent work item sessions; no monitoring |
| `plan-issues PLAN_PATH linear\|github` | Convert plan items into tracker issues |
| `dev-start [ISSUE_ID]` | Delegate implementation to specialist agents |
| `dev-fix [ISSUE_ID]` | Delegate review fix items |
| `ci-fix PR_NUMBER \| queue` | Fix CI failures |
| `review [all \| last N \| HASH]` | On-demand code review |
| `review-codebase [PATH]` | Whole-codebase reviewer fanout |
| `review-pr [PR_NUMBER]` | Pre-submission review |
| `review-pr-comments PR_NUMBER` | Triage PR review comments |
| `submit-pr [PR_NUMBER]` | Local review, push, create PR, async triage, review gate, CI verify, merge gates |
| `merge-pr PR_NUMBER \| all` | Verify and merge PR(s) |
| `parallel-check [ISSUE_IDS]` | Verify parallel work safety |

## Bundle Containers (breaking change)

A parent issue with children is a **container**: it is never orchestrated or
merged as one PR — each child is its own PR unit, and the container closes
automatically when its last child merges. To keep a bundle as a single
session/PR (the old default), add the `(one PR)` marker to the parent's
title; the marker always wins, including over the `agent:multi` label.
Migration is per-bundle via that title marker alone — no state or cache
changes; existing mid-flight bundles that share one branch should add
`(one PR)` before their next orchestration command.

## Skill Dependencies

| Skill | Purpose |
|-------|---------|
| `linear` | Linear issue tracking (CRUD, cache, comments) |
| `github` | PR operations, CI status |
| `worktree` | Git worktree management |
| `dev` | Dev-agent implementation and fix workflows — `dev-start`/`dev-fix` delegate into them |
| `reviewer` | Review/QA workflows and the finding schema — the review workflows delegate into it |
| `project-management` | TPM audit/cycle/roadmap workflows |
| `decider` | Architectural decision documents |
| `second-opinion` (optional) | Pre-PR local cross-model review — orch consumes it when installed (existence check) |
| `review-gate` (optional) | Multi-PR needs-attention watching via its `pr-watch.sh` — orch consumes it when installed (existence check) and falls back to per-PR waiter polling without it |

## Setup

1. Install dependency skills: `github`, `worktree`, `dev`, `reviewer`, `decider`, `project-management`; add `linear` for Linear workflows, `second-opinion` for pre-PR local review, and `review-gate` for the multi-PR watcher integration (both optional — orch existence-checks them and falls back without them).
2. Set non-sensitive runtime defaults in `vstack.settings.toml`; keep secrets in `.env.local`.
3. Verify each skill works from the project root before invoking a workflow.

## Configuration

Set non-sensitive values in `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` files still work; load order is `.env`, then `vstack.settings.toml`, then `.env.local`.

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | State file directory (env fallback for the `--state-dir` flag, which wins) | `tmp` |
| `ORCH_CACHE_DIR` | Parallel-group safety cache | `.cache/orch` |
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | current `gh` auth |
| `GH_BOT_TOKEN` | Bot GitHub token for worktree auth | `GH_TOKEN` / `GITHUB_TOKEN`, then current `gh` auth |
| `GH_ISSUE_PATTERN` | Issue ID regex for branch names. Matched case-insensitively; the match is then canonicalized (`issue-N` lowercase, Linear-style `ABC-N` uppercase) so review-init, session-init, and git-context derive one workflow-state key per branch | `[A-Z]+-[0-9]+` |
| `REVIEW_RISK_COMMAND` | Opt-in risk classifier. A repo-relative executable path plus optional plain arguments — a file, not a shell string; `scripts/review-risk` resolves it (and this key) from the trusted invoking checkout and runs it with the reviewed worktree as cwd. Contract: prints `high`/`medium`/`low` (exit 0); the fan-out is sized from the answer (`low` → small discovered-reviewer panel + first-clean-round convergence). Any failure or unset = full fleet — fails open to depth, never shallowness | (unset) |
| `CI_WAIT_NO_CHECKS_GRACE` | Seconds `ci-wait` keeps polling before failing when no CI checks have registered yet (covers approval-gated CI dispatch latency) | `180` |
| `QUEUE_WAIT_ARM_GRACE` | Seconds `queue-wait` keeps polling before reporting `not_queued` when no poll has yet seen the PR queued or armed (covers enqueue registration lag) | `120` |
| `QUEUE_WAIT_CONFIRM_POLLS` | Consecutive polls that must agree before `queue-wait` reports an ejection or disarm, so one eventually-consistent blip cannot trigger a recovery cycle | `2` |
| `QUEUE_WAIT_PROBE_INTERVAL` | Minimum seconds between `queue-wait`'s delegated `ci-wait` probes for the failed-required-check disarm cause | `120` |
| `PR_REVIEW_GATE` | Reviewer merge gate mode: `approval` requires a GitHub-native approval verdict; `review` requires a formal review of the current head from a non-author reviewer — any state, for commenting-only review bots that never approve — plus zero unresolved threads; `off` for repos with no review bots/reviewers — submit-pr skips the review wait and merge-pr treats `not_approved` as informational. Explicit config only; never auto-detected | `approval` |
| `PR_APPROVAL_GATE` | Legacy alias, read only when `PR_REVIEW_GATE` is unset: `on` → `approval`, `off` → `off` | `on` |
| `PR_REVIEW_WAIT_SECS` | Total review-wait budget in seconds — the per-repo quiet period before `approval-wait`'s on-timeout policy applies. Read only when the caller passes no `max_wait` positional arg; an explicit arg always wins | `900` |
| `PR_REVIEW_NUDGE_SECS` | Seconds of reviewer silence for the current head before `approval-wait` nudges — once per head SHA, clock restarts on every push; `0` disables | `600` |
| `PR_REVIEW_NUDGE` | PR comment body posted as the nudge (project-configured reviewer trigger, e.g. `@your-bot review`). Empty = fall back to a GitHub-native re-review request to the PR's requested and past reviewers | empty |
| `PR_REVIEW_CHECK` | Exact name of the check the repo's trusted review bot publishes on analyzed heads (e.g. `Devin Review`). When set, `review` mode also accepts a `success` signal of that name on the current head as review evidence — a check-run conclusion or a commit-status context, whichever surface the bot publishes — for bots that submit a review object only when they have findings, whose clean re-analyses would otherwise never satisfy the gate. Matched by name/context only, so name a signal produced by the trusted review bot | empty |
| `PR_REVIEW_ON_TIMEOUT` | Deadline behavior when the reviewer never posts (e.g. credits exhausted): `block` reports `timeout` and the workflow prompts (force/wait/stop); `proceed` reports `proceeded` and records a reviewer-down override so a dead reviewer never stalls the fleet — but only with **zero unresolved threads** (an open thread returns `comments` first, so a real comment is never bypassed), and CI plus the comment-hygiene gate still apply. Fires only when *every* reviewer is silent; a `changes_requested` always blocks | `block` |
| `CI_FIX_MAX_CYCLES` | Max automated ci-fix cycles per PR submission (`submit-pr`) or merge recovery (`merge-pr`) before the workflow reports the persistent CI failure — failing checks, last error, per-cycle attempts — back to the user | `6` |
| `PR_REVIEW_REFIX_MAX_LINES` | Total changed lines (insertions + deletions) a support-scope fix round may reach before `review-pr` re-reviews it anyway. A round that cleared blockers is re-reviewed regardless (read via `refix-route`) | `200` |
| `REVIEWER_SLOT_BUDGET` | Total concurrent agent-session budget of the harness runtime, counting the primary session. `0` = unlimited: every reviewer launches up front and persists through fix/re-review cycles. When the reviewer set exceeds the available slots (budget minus the primary minus live dev/QA sessions), review workflows run reviewers in bounded sequential waves, retiring each completed session to release its slot. If the runtime contradicts an unlimited (`0`) budget with a thread-limit spawn failure, review workflows demote to bounded waves automatically and recommend the observed budget. Codex collaboration runtime: MultiAgentV2 defaults to 4 total threads including the primary, configurable via `features.multi_agent_v2.max_concurrent_threads_per_session` in `~/.codex/config.toml` → set the config-declared cap | `0` |

Bot reviews are asynchronous: no orch workflow blocks PR submission on bot-specific signals — emoji reactions, sticky comments, and checklist prose are never parsed as gates. Merges gate on internal review, green CI, zero unresolved review comments (every bot comment replied to and resolved), and a GitHub-native reviewer-gate verdict from any reviewer — human or bot — polled by `approval-wait`. In `approval` mode that verdict is an approval via `reviewDecision`, with a latest-review-per-reviewer fallback when no required-review protection exists; in `review` mode it is a formal review of the current head commit (any state — for reviewers that comment but never approve) — or, with `PR_REVIEW_CHECK` set, a successful trusted review-check on that head (a check-run or a commit status, whichever the bot publishes) in place of a review object — plus zero unresolved threads. If no gate verdict arrives within the review-wait budget (`PR_REVIEW_WAIT_SECS`, default 900 s), the workflow prompts the user to force merge, keep waiting, or stop — unless `PR_REVIEW_ON_TIMEOUT=proceed`, in which case a deadline reached with zero unresolved threads and no reviewer evidence instead proceeds automatically under a recorded reviewer-down override (so a credit-exhausted reviewer never blocks the fleet), while an open thread or a `changes_requested` still blocks. The review gate runs before CI verification, so repos that start CI only after an approval (approval-gated jobs or a merge queue) never deadlock; `ci-wait` keeps an old pre-approval aggregate failure pending while the current-head approved run is active, even if a later review-comment dispatch is an all-skipped no-op, and a run cancelled by a concurrent same-head dispatch never fails the wait on its own — the newest substantive run's or rerun attempt's outcome decides. On always-on repos the post-approval CI verify simply returns quickly.

See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for GitHub auth fallback details and the test runner.

GitHub auth helpers are env-first. If launch-time configuration already provides a resolved `GH_TOKEN`, `GITHUB_TOKEN`, or `GH_BOT_TOKEN`, orch keeps it and does not re-read `op://` references from `.env.local` for GitHub auth. Auth preflight validates selected env tokens with `gh api user`; `gh auth status` is only authoritative for keyring auth when no env token is selected. Service-account setup for the `op` CLI remains local environment configuration.

Git workflow helpers use targeted `origin` operations for PR closure. When a
repo remote is SSH-backed but `gh` auth is valid, `skills/github/scripts/git-https-auth`
adds per-command HTTPS rewrite and `gh auth git-credential` config so Codex and
other non-SSH sessions can fetch, pull, or push without mutating remotes.
Optional secondary remotes are not fetched during merge sync.

## Helper Scripts

Use `skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]` to print the base branch for a worktree. It honors `WORKTREE_DEFAULT_BRANCH`, then `origin/HEAD`, and falls back to `main` — but only for a usable worktree: a missing path or non-directory exits 1 with an error on both arms, and without the override a bare repository or any path outside a git work tree exits 1 too (git resolution has nothing to answer for it). `WORKTREE_DEFAULT_BRANCH` answers from configuration alone, so it accepts any existing directory (callers may resolve from an installed skill directory that is not a repository) but never a missing path. Callers must treat a nonzero exit as "no base resolved", never default it away.

Use `skills/orch/scripts/git-context branch|head|issue-from-branch|repo-root|common-root|timestamp [WORKTREE_PATH]` when workflow guidance needs git-derived values without inline command substitution, pipelines, or `cd && ...` chains.

Use `skills/orch/scripts/base-freshness [WORKTREE_PATH]` to fetch the resolved base branch (through `git-https-auth` when available) and print ahead/behind JSON. Exit 0 means current, exit 4 means the branch is behind `origin/<base>` (rebase via `worktree create <ID> --reuse` before reviewing), exit 1 means freshness could not be verified. The worktree start workflow runs it before the review cycle so a reused worktree never reviews a stale base.

Use `skills/orch/scripts/workflow-state exists --json ISSUE_ID` when a workflow needs structured existence status without relying on shell exit-code capture.

Use `skills/orch/scripts/workflow-state set-git-head ISSUE_ID FIELD [WORKTREE_PATH]` and `set-now ISSUE_ID FIELD` for common state writes that would otherwise require nested `$(git ...)` or `$(date ...)` snippets.

Use `skills/orch/scripts/workflow-state new-round-id ISSUE_ID FIELD` before each dev/QA delegation (implement, fix, or analysis) to mint a unique per-delegation round token (`date +%s%N`-`$RANDOM` — nanosecond timestamp + random suffix), store it, and print it. The dev agent passes the printed token to `dev-return-write --round-id`, and `dev-artifact-check` requires the artifact's internal `round_id` to match — clock-independent completion-artifact identity that replaces the earlier mtime freshness heuristic (vstack#776).

To target a canonical state directory from a worktree, pass the global `skills/orch/scripts/workflow-state --state-dir PATH SUBCOMMAND ...` flag before the subcommand rather than an `ORCH_STATE_DIR=… workflow-state …` env prefix. The env-assignment prefix is rejected under Codex `approval=never` (a flagged command shape); the plain flag is classifier-safe. `--state-dir` takes precedence over the `ORCH_STATE_DIR` environment fallback, which stays supported.

Use `skills/orch/scripts/pr-view-json WORKTREE_PATH --json number,state` when a workflow needs to inspect the current branch's PR. It prints the structured `status=no_pr` JSON with exit code 0 so `submit-pr` can route to PR creation without shell fallback expressions.

Use `skills/orch/scripts/review-init` to initialize standalone review context and print branch, worktree, issue ID, state path, and whether state was created as JSON.

Use `skills/orch/scripts/review-artifact-check WORKTREE_PATH AGENT_NAME DELEGATED_AT_EPOCH` to deterministically validate a reviewer's on-disk JSON artifact (existence, `mtime >=` delegation epoch, `jq -e '.verdict'`). It prints `{ok, path, reason}`; review-pr accepts a reviewer completion only when `ok == true`. `review-artifact-check --file <json_path> [delegated_at_epoch]` validates one explicit artifact (such as an external second-opinion review output); when the optional `delegated_at_epoch` is supplied it applies the same freshness gate, so a stale or misdated file is rejected instead of accepted on existence + verdict alone. Both modes also reject an artifact that self-reports no review was performed (`qa_metadata.review_performed: false`, or a no-scope/no-review `qa_metadata.reason`) with reason `no_review` — a schema-valid "pass" from a reviewer that admits it reviewed nothing never validates. An artifact that declares `qa_metadata` is additionally rejected with reason `incomplete` when its findings are unusable: `blockers[]`/`suggestions[]` missing or not arrays (lost in the write), or a present item omitting a required `review-finding` field — `id`, `title`, `location`, `description`, `recommendation`, `priority` (1–4), `estimate` (1–5), plus `category ∈ {fix,issue}` for suggestions, on which the orchestrator routes. The output then carries an additive `detail` field naming the offending item and field (e.g. `suggestions[0]: missing/invalid category`); the `{ok, path, reason}` fields are unchanged. Artifacts without `qa_metadata` (internal reviewers) are unaffected.

Use `skills/orch/scripts/dev-return-write --worktree PATH --kind implement|fix --issue ID --round-id RID --branch BRANCH --commit SHA --validate STR [--validate-note TEXT] [--qa-label LABEL]... [--bundled] [--no-summary] [--summary TEXT | --summary-file PATH] [--item N DECISION REASONING]...` for the dev agent to write its round-scoped completion artifact deterministically (atomically, well-formed) instead of hand-authoring JSON; it prints the artifact path and exits 2 on invalid input. A read-only analysis round (investigate + recommend, no implementation) uses `--kind analysis` with exactly one of `--summary TEXT` (inline) or `--summary-file PATH` instead — no `--commit`/`--validate` (both rejected; the artifact omits those keys, vstack#952). Canonical schema — fields, kind rules, `items[]` shape: [`schemas/dev-return.md`](./schemas/dev-return.md); validation and round-id internals: [`DEVELOPMENT.md`](./DEVELOPMENT.md).

Use `skills/orch/scripts/dev-artifact-check --worktree WT --issue ISSUE --round-id RID [--expect-items N,N,...]` to deterministically validate a dev agent's round-scoped completion artifact; it prints `{ok, path, reason}` (`valid`/`missing`/`invalid`/`incomplete`). A fresh valid artifact lets `dev-start` § 3 / `dev-fix` accept a completion whose live return never arrived because the validation outlasted the turn (vstack#770) without re-delegation; git/tracker corroboration stays in the orch workflow. Schema: [`schemas/dev-return.md`](./schemas/dev-return.md); gate ordering, type-strict fields, and the `--expect-items`/`--file` modes: [`DEVELOPMENT.md`](./DEVELOPMENT.md).

Use `skills/orch/scripts/queue-wait PR_NUMBER [poll_interval] [max_wait] [--json] [--no-check-probe]` to block until a PR's merge-queue / auto-merge outcome is decided — the merge-pr § 3.2 queue watch as a single command (vstack#819). Each poll reads `gh pr view --json state,mergedAt` plus the GraphQL `isInMergeQueue`/`mergeQueueEntry`/`autoMergeRequest` fields, because `gh pr view --json` exposes no queue-membership field. It prints `{status, verdict, ...}`: `verdict` is `merged` (exit 0), `ejected`, `disarmed`, `closed`, `queued` (deadline reached with the merge still armed — not a failure, and never reported as success), `not_queued` (the merge never armed), or `unknown` on error; exit `1` for all of those and `3` on GitHub auth failure. Its reason to exist is the cross-poll `WAS_QUEUED` memory — whether any earlier poll saw the PR queued or armed — which separate tool calls cannot carry, and without which an ejected PR is indistinguishable from one that was never queued. The failed-required-check half of the disarm verdict is delegated to `ci-wait`, not reimplemented; `--no-check-probe` disables that probe. `poll_interval` must be a positive integer no greater than `max_wait` (a swapped `queue-wait PR 1800 600` is rejected with exit 2 rather than polling once and overshooting), `max_wait` is a hard upper bound on total wait, and `--help` prints the argument contract.

Use `skills/orch/scripts/tracker-for-issue ISSUE_ID` when workflow docs need tracker branching without inline shell conditionals.

Use `skills/orch/scripts/orch-env VAR_NAME DEFAULT` to print the effective value of a vstack `[env]` setting (process env > `vstack.settings.toml` > default) when a workflow step needs a configurable value without inline shell fallbacks. With a numeric default, a non-numeric effective value falls back to the default — e.g. `orch-env CI_FIX_MAX_CYCLES 6` for the ci-fix cycle budget.

## System Dependencies

- `jq`, `bash` 4+, `flock` (util-linux)

## Codex Desktop Threads

For app-visible handoff, use `handoff ... --harness codex-app` from the orch workflow while running inside Codex Desktop. This path uses `codex_app` thread tools, not the Codex CLI.

For multi-issue handoff, `handoff ISSUE_ID ISSUE_ID` defaults to Codex app threads when those tools are exposed. Before creating threads, run `skills/orch/scripts/codex-app-agent-preflight .`. If it reports `ok: true`, continue normally. If it reports a warning, show the message and continue only after the user explicitly accepts the risk that child sessions may fall back to `worker`; stop only on `severity: "error"` or if the user declines. Create one Codex app thread per issue. Start each thread with exactly `$orch start ISSUE_ID` for Linear or `$orch start github OWNER/REPO#N` for GitHub. Target a worktree environment with `startingState: {type: "branch", branchName: "[BASE_BRANCH]"}`, where `BASE_BRANCH` comes from `skills/orch/scripts/resolve-base-branch .`. Do not use `startingState: {type: "working-tree"}` for normal orch handoff; app-created worktrees can otherwise start before ignored generated Codex agent files are visible, forcing generated dev/reviewer agents through `worker` fallback. If the runtime separates thread creation from prompting, call `codex_app.send_message_to_thread` once for the returned thread ID with that same start prompt.

Codex Desktop may create those child sessions as detached app worktrees under `~/.codex/worktrees`. Generated Codex agents must be tracked under `.codex/agents/*.toml` in the saved project branch for app-created worktrees to expose them before subagent discovery; setup hooks and worktree symlinks run too late to affect that discovery. The preflight is a warning gate for missing or ignored agent TOMLs, not a hard launch blocker after user acceptance. The child `start` workflow still runs the normal worktree lifecycle: `session-init --json github OWNER/REPO#N` normalizes the branch to `issue-N`, then the session proceeds through implementation, review, PR submission, CI, and merge offer. A dirty or detached worktree is a hard preflight failure before review or PR submission.

The Codex CLI does not expose these thread tools. Do not automate app-visible handoff with terminal launch helpers, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
