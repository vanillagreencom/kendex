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

## Skill Dependencies

| Skill | Purpose |
|-------|---------|
| `linear` | Linear issue tracking (CRUD, cache, comments) |
| `github` | PR operations, CI status |
| `worktree` | Git worktree management |
| `project-management` | TPM audit/cycle/roadmap workflows |
| `decider` | Architectural decision documents |

## Setup

1. Install dependency skills: `github`, `worktree`, `decider`, `project-management`; add `linear` for Linear workflows.
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
| `GH_ISSUE_PATTERN` | Issue ID regex for branch names | `[A-Z]+-[0-9]+` |
| `CI_WAIT_NO_CHECKS_GRACE` | Seconds `ci-wait` keeps polling before failing when no CI checks have registered yet (covers approval-gated CI dispatch latency) | `180` |
| `PR_REVIEW_GATE` | Reviewer merge gate mode: `approval` requires a GitHub-native approval verdict; `review` requires a formal review of the current head from a non-author reviewer — any state, for commenting-only review bots that never approve — plus zero unresolved threads; `off` for repos with no review bots/reviewers — submit-pr skips the review wait and merge-pr treats `not_approved` as informational. Explicit config only; never auto-detected | `approval` |
| `PR_APPROVAL_GATE` | Legacy alias, read only when `PR_REVIEW_GATE` is unset: `on` → `approval`, `off` → `off` | `on` |
| `PR_REVIEW_NUDGE_SECS` | Seconds of reviewer silence for the current head before `approval-wait` nudges — once per head SHA, clock restarts on every push; `0` disables | `600` |
| `PR_REVIEW_NUDGE` | PR comment body posted as the nudge (project-configured reviewer trigger, e.g. `@your-bot review`). Empty = fall back to a GitHub-native re-review request to the PR's requested and past reviewers | empty |
| `PR_REVIEW_CHECK` | Exact name of the check the repo's trusted review bot publishes on analyzed heads (e.g. `Devin Review`). When set, `review` mode also accepts a `success` signal of that name on the current head as review evidence — a check-run conclusion or a commit-status context, whichever surface the bot publishes — for bots that submit a review object only when they have findings, whose clean re-analyses would otherwise never satisfy the gate. Matched by name/context only, so name a signal produced by the trusted review bot | empty |
| `PR_REVIEW_ON_TIMEOUT` | Deadline behavior when the reviewer never posts (e.g. credits exhausted): `block` reports `timeout` and the workflow prompts (force/wait/stop); `proceed` reports `proceeded` and records a reviewer-down override so a dead reviewer never stalls the fleet — but only with **zero unresolved threads** (an open thread returns `comments` first, so a real comment is never bypassed), and CI plus the comment-hygiene gate still apply. Fires only when *every* reviewer is silent; a `changes_requested` always blocks | `block` |
| `PR_REVIEW_OUTAGE_CONTEXT` | Makes `proceed` end-to-end on repos whose CI gate independently blocks merges on review evidence. When set to a commit-status context, a `proceed` posts that context as `success` on the head so the repo's CI gate can accept it (add an `outageok` term) and its status re-fire bridge can re-run the gate — see DEVELOPMENT.md "Reviewer-outage recognition". Empty = orch-side-only (no marker). SECURITY: a branch-protection relaxation bounded by the genuine-silence proceed predicate + bot-only status trust; name it only where every status publisher is trusted | empty |
| `CI_FIX_MAX_CYCLES` | Max automated ci-fix cycles per PR submission (`submit-pr`) or merge recovery (`merge-pr`) before the workflow reports the persistent CI failure — failing checks, last error, per-cycle attempts — back to the user | `6` |
| `REVIEWER_SLOT_BUDGET` | Total concurrent agent-session budget of the harness runtime, counting the primary session. `0` = unlimited: every reviewer launches up front and persists through fix/re-review cycles. When the reviewer set exceeds the available slots (budget minus the primary minus live dev/QA sessions), review workflows run reviewers in bounded sequential waves, retiring each completed session to release its slot. If the runtime contradicts an unlimited (`0`) budget with a thread-limit spawn failure, review workflows demote to bounded waves automatically and recommend the observed budget. Codex collaboration runtime: MultiAgentV2 defaults to 4 total threads including the primary, configurable via `features.multi_agent_v2.max_concurrent_threads_per_session` in `~/.codex/config.toml` → set the config-declared cap | `0` |

Bot reviews are asynchronous: no orch workflow blocks PR submission on bot-specific signals — emoji reactions, sticky comments, and checklist prose are never parsed as gates. Merges gate on internal review, green CI, zero unresolved review comments (every bot comment replied to and resolved), and a GitHub-native reviewer-gate verdict from any reviewer — human or bot — polled by `approval-wait`. In `approval` mode that verdict is an approval via `reviewDecision`, with a latest-review-per-reviewer fallback when no required-review protection exists; in `review` mode it is a formal review of the current head commit (any state — for reviewers that comment but never approve) — or, with `PR_REVIEW_CHECK` set, a successful trusted review-check on that head (a check-run or a commit status, whichever the bot publishes) in place of a review object — plus zero unresolved threads. If no gate verdict arrives within 15 minutes, the workflow prompts the user to force merge, keep waiting, or stop — unless `PR_REVIEW_ON_TIMEOUT=proceed`, in which case a deadline reached with zero unresolved threads and no reviewer evidence instead proceeds automatically under a recorded reviewer-down override (so a credit-exhausted reviewer never blocks the fleet), while an open thread or a `changes_requested` still blocks. The review gate runs before CI verification, so repos that start CI only after an approval (approval-gated jobs or a merge queue) never deadlock; `ci-wait` keeps an old pre-approval aggregate failure pending while the current-head approved run is active, even if a later review-comment dispatch is an all-skipped no-op, and a run cancelled by a concurrent same-head dispatch never fails the wait on its own — the newest substantive run's or rerun attempt's outcome decides. On always-on repos the post-approval CI verify simply returns quickly.

See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for GitHub auth fallback details and the test runner.

GitHub auth helpers are env-first. If launch-time configuration already provides a resolved `GH_TOKEN`, `GITHUB_TOKEN`, or `GH_BOT_TOKEN`, orch keeps it and does not re-read `op://` references from `.env.local` for GitHub auth. Auth preflight validates selected env tokens with `gh api user`; `gh auth status` is only authoritative for keyring auth when no env token is selected. Service-account setup for the `op` CLI remains local environment configuration.

Git workflow helpers use targeted `origin` operations for PR closure. When a
repo remote is SSH-backed but `gh` auth is valid, `skills/github/scripts/git-https-auth`
adds per-command HTTPS rewrite and `gh auth git-credential` config so Codex and
other non-SSH sessions can fetch, pull, or push without mutating remotes.
Optional secondary remotes are not fetched during merge sync.

## Helper Scripts

Use `skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]` to print the base branch for a worktree. It honors `WORKTREE_DEFAULT_BRANCH`, then `origin/HEAD`, and falls back to `main`.

Use `skills/orch/scripts/git-context branch|head|issue-from-branch|repo-root|common-root|timestamp [WORKTREE_PATH]` when workflow guidance needs git-derived values without inline command substitution, pipelines, or `cd && ...` chains.

Use `skills/orch/scripts/workflow-state exists --json ISSUE_ID` when a workflow needs structured existence status without relying on shell exit-code capture.

Use `skills/orch/scripts/workflow-state set-git-head ISSUE_ID FIELD [WORKTREE_PATH]` and `set-now ISSUE_ID FIELD` for common state writes that would otherwise require nested `$(git ...)` or `$(date ...)` snippets.

Use `skills/orch/scripts/workflow-state new-round-id ISSUE_ID FIELD` before each dev/QA implement-or-fix delegation to mint a unique per-delegation round token (`date +%s%N`-`$RANDOM` — nanosecond timestamp + random suffix), store it, and print it. The dev agent passes the printed token to `dev-return-write --round-id`, and `dev-artifact-check` requires the artifact's internal `round_id` to match — clock-independent completion-artifact identity that replaces the earlier mtime freshness heuristic (vstack#776).

To target a canonical state directory from a worktree, pass the global `skills/orch/scripts/workflow-state --state-dir PATH SUBCOMMAND ...` flag before the subcommand rather than an `ORCH_STATE_DIR=… workflow-state …` env prefix. The env-assignment prefix is rejected under Codex `approval=never` (a flagged command shape); the plain flag is classifier-safe. `--state-dir` takes precedence over the `ORCH_STATE_DIR` environment fallback, which stays supported.

Use `skills/orch/scripts/pr-view-json WORKTREE_PATH --json number,state` when a workflow needs to inspect the current branch's PR. It prints the structured `status=no_pr` JSON with exit code 0 so `submit-pr` can route to PR creation without shell fallback expressions.

Use `skills/orch/scripts/review-init` to initialize standalone review context and print branch, worktree, issue ID, state path, and whether state was created as JSON.

Use `skills/orch/scripts/review-artifact-check WORKTREE_PATH AGENT_NAME DELEGATED_AT_EPOCH` to deterministically validate a reviewer's on-disk JSON artifact (existence, `mtime >=` delegation epoch, `jq -e '.verdict'`). It prints `{ok, path, reason}`; review-pr accepts a reviewer completion only when `ok == true`. `review-artifact-check --file <json_path> [delegated_at_epoch]` validates one explicit artifact (such as an external second-opinion review output); when the optional `delegated_at_epoch` is supplied it applies the same freshness gate, so a stale or misdated file is rejected instead of accepted on existence + verdict alone. Both modes also reject an artifact that self-reports no review was performed (`qa_metadata.review_performed: false`, or a no-scope/no-review `qa_metadata.reason`) with reason `no_review` — a schema-valid "pass" from a reviewer that admits it reviewed nothing never validates. Artifacts without `qa_metadata` (internal reviewers) are unaffected.

Use `skills/orch/scripts/dev-return-write --worktree PATH --kind implement|fix --issue ID --round-id RID --branch BRANCH --commit SHA --validate STR [--qa-label LABEL]... [--bundled] [--no-summary] [--summary-file PATH] [--item N DECISION REASONING]...` for the dev agent to write its round-scoped completion artifact deterministically (atomically, well-formed) instead of hand-authoring JSON; it prints the artifact path and exits 2 on invalid input. Canonical schema — fields, kind rules, `items[]` shape: [`schemas/dev-return.md`](./schemas/dev-return.md); validation and round-id internals: [`DEVELOPMENT.md`](./DEVELOPMENT.md).

Use `skills/orch/scripts/dev-artifact-check --worktree WT --issue ISSUE --round-id RID [--expect-items N,N,...]` to deterministically validate a dev agent's round-scoped completion artifact; it prints `{ok, path, reason}` (`valid`/`missing`/`invalid`/`incomplete`). A fresh valid artifact lets `dev-start` § 3 / `dev-fix` accept a completion whose live return was lost to a tool timeout (vstack#770) without re-delegation; git/tracker corroboration stays in the orch workflow. Schema: [`schemas/dev-return.md`](./schemas/dev-return.md); gate ordering, type-strict fields, and the `--expect-items`/`--file` modes: [`DEVELOPMENT.md`](./DEVELOPMENT.md).

Use `skills/orch/scripts/tracker-for-issue ISSUE_ID` when workflow docs need tracker branching without inline shell conditionals.

Use `skills/orch/scripts/orch-env VAR_NAME DEFAULT` to print the effective value of a vstack `[env]` setting (process env > `vstack.settings.toml` > default) when a workflow step needs a configurable value without inline shell fallbacks. With a numeric default, a non-numeric effective value falls back to the default — e.g. `orch-env CI_FIX_MAX_CYCLES 6` for the ci-fix cycle budget.

## System Dependencies

- `jq`, `bash` 4+, `flock` (util-linux)

## Codex Desktop Threads

For app-visible handoff, use `handoff ... --harness codex-app` from the orch workflow while running inside Codex Desktop. This path uses `codex_app` thread tools, not the Codex CLI.

For multi-issue handoff, `handoff ISSUE_ID ISSUE_ID` defaults to Codex app threads when those tools are exposed. Before creating threads, run `skills/orch/scripts/codex-app-agent-preflight .`. If it reports `ok: true`, continue normally. If it reports a warning, show the message and continue only after the user explicitly accepts the risk that child sessions may fall back to `worker`; stop only on `severity: "error"` or if the user declines. Create one Codex app thread per issue. Start each thread with exactly `$orch start ISSUE_ID` for Linear or `$orch start github OWNER/REPO#N` for GitHub. Target a worktree environment with `startingState: {type: "branch", branchName: "[BASE_BRANCH]"}`, where `BASE_BRANCH` comes from `skills/orch/scripts/resolve-base-branch .`. Do not use `startingState: {type: "working-tree"}` for normal orch handoff; app-created worktrees can otherwise start before ignored generated Codex agent files are visible, forcing generated dev/reviewer agents through `worker` fallback. If the runtime separates thread creation from prompting, call `codex_app.send_message_to_thread` once for the returned thread ID with that same start prompt.

Codex Desktop may create those child sessions as detached app worktrees under `~/.codex/worktrees`. Generated Codex agents must be tracked under `.codex/agents/*.toml` in the saved project branch for app-created worktrees to expose them before subagent discovery; setup hooks and worktree symlinks run too late to affect that discovery. The preflight is a warning gate for missing or ignored agent TOMLs, not a hard launch blocker after user acceptance. The child `start` workflow still runs the normal worktree lifecycle: `session-init --json github OWNER/REPO#N` normalizes the branch to `issue-N`, then the session proceeds through implementation, review, PR submission, CI, and merge offer. A dirty or detached worktree is a hard preflight failure before review or PR submission.

The Codex CLI does not expose these thread tools. Do not automate app-visible handoff with terminal launch helpers, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
