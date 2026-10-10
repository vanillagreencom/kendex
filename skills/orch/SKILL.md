---
name: orch
description: "PRIMARY AGENT ONLY. Load to orchestrate a Linear or GitHub work item from preparation through merge."
summary: "Work-item orchestration for Linear or GitHub issues: prepare, delegate implementation, review, submit, merge, hand off, and oversee fleets of sessions."
license: MIT
user-invocable: true
dependencies:
  required: [github, worktree, dev, project-management, decider, reviewer, review-gate]
  optional: [harness-ci, linear, second-opinion, commit-guards]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [automation]
---

# Orchestration

Load `github` and `worktree` before anything else; a Linear work item also needs `linear`. The dev and reviewer skills call orch scripts.

> **MODE SWITCH**: you are the orchestrator. Delegate every implementation, review, and QA task to a specialist sub-agent. Never edit code unless the user explicitly asks, or the item runs the `micro` tier ([workflows/micro.md](workflows/micro.md)), whose runner makes the edit itself.

## The Cycle

Get the issue → dev implements → review and fixes → publish → required CI and review gate → merge. `pr-order --help` owns publication order.

- **Bounded loops.** A fix round addresses blockers only, and the same pass declines or tracks every `fix` suggestion ([workflows/review-pr.md](workflows/review-pr.md) § 4); re-review narrows to the fix diff, the domains it touched, and the class of every defect it fixed ([reviewer/SKILL.md](../reviewer/SKILL.md) § Re-Review Rounds); two consecutive rounds with no new blocker end the review, except at `REVIEW_MAX_CYCLES` 0, where the one fix round ends it with no re-review.
- **No edge-case churn.** A finding that cannot affect real usage is declined with a one-line reason, not fixed, not filed.
- **Review must converge**, by [references/finding-disposition.md](references/finding-disposition.md):
  - Every finding runs its [§ Decision flow](references/finding-disposition.md#decision-flow), Step 0 first, and ends as one of the reply forms that section sets out.
  - A defect class recurring across rounds → its [§ Recurrence](references/finding-disposition.md#recurrence), never patched per comment, for a rule restated in prose or a table as much as for code.
  - A defect in code the issue's Done-when does not need, or a PR whose reviewer or orchestrator chooses a scope cut → a cut round. A round whose only findings are scope or wording asks ends the review: reply, resolve, push nothing, merge through the gate.
- **Ask gates.** Which questions reach the user, and how each one is worded under the mode `ORCH_USER_MODE` names, is [references/communication-modes.md](references/communication-modes.md); nothing outside that file narrows or widens the set. That ask set holds whatever `ORCH_DECISION_MODE` says. Merge asks unless `ORCH_MERGE_AUTONOMY=auto`, which merges without asking only when every merge gate is green. In a lane every ask gate is `lane-mail`, never the harness question tool: [references/skill-rules.md](references/skill-rules.md) § Coordination.
- **Post-PR autonomy.** After a PR exists, `ORCH_DECISION_MODE=auto-recommended` takes and logs the continuing option while a bounded wait, retry, or triage round remains. `ask` presents the listed choice. `workflow-state head-budget take` owns automatic retry spending, starting the count over on a changed head for review-wait only. At a cap, `workflow-state post-pr-stop record` atomically persists the named stop and renders its matching Markdown comment; the workflow posts that file to the PR and returns the stored stop. A nested caller uses `record-if-empty` so a precise upstream stop wins. Every continuing action clears the stop with `workflow-state update`. Initialize the resolved state key before these transitions. `ORCH_MERGE_AUTONOMY` controls merge consent only.
- **The overseer reads results.** It accepts a lane's green suite, validation command, and CI without reproducing them. It gives no separate grant to prepare, commit, push, or merge, and uses no shared validation slot; the one thing it runs itself is a `micro` item ([workflows/micro.md](workflows/micro.md)), whose commit chain is that item's whole validation. On a hosted fleet it runs not even that: Item work stays in lanes, below. A green lane with existing user merge authorization arms auto-merge itself without a grant, then owns its merge wait to a terminal verdict as `workflows/merge-pr.md` requires. It accepts a dev agent's test-only validation-ceiling report and does not extend validation. The overseer never sends model or account instructions to a lane. The lane's model is fixed at launch, and the lane launches no lanes.
- **Item work stays in lanes.** On a hosted fleet the overseer's session does no item work: no worktree, no item branch, no dev, review or fix agent, no validation, build, install or test run. Every round of an item goes to the lane that owns the branch. A hosted fleet is one where `lane-host resolve` prints anything but `local`; the overseer's host is then the control VM, sized for coordination and shared by every overseer. A subagent the overseer runs on the control host (a sweep, a triage verifier, a measurement or a research run) reads there and never writes bulk data: it reads archives as streams, or extracts one archive at a time in its own scratch subdirectory and removes each extraction before the next. Before each extraction it reads the archive's uncompressed size and the volume's free space; when the extraction would leave less than 3 GB free, it extracts nothing, stops and reports to the overseer. It runs no history-wide content read (`git log -S` or `-G`, `--all -p`, or any command that reads every blob), because the checkout may be a partial clone whose lazy fetch fills the disk; a history search uses `gh search code`, the GitHub API, or a lane. It runs no busy wait (no read from `/dev/zero` or `/dev/urandom`, no spin poll), which loads the host every overseer shares: a wait is one bounded background command and its completion notice, an `inotifywait` on a file, or the watch's events. A brief that names a scratch location gives each subagent its own empty subdirectory (`tmp/<run>/<agent-topic>/`), which it alone removes; never a directory the overseer's background jobs read. The overseer puts this rule in every brief it writes for a control-host subagent. Fleet guards read [command blocks](references/control-host-toolchain.conf). Refresh follows the [consumer's owner](references/oversee-events.md). No `--refresh-only` exception.
- **Acceptance is artifact-based.** A round closes on a validated on-disk artifact plus git/tracker state, never on a return message.
- **Rules reload after a rebase.** Before a step that can rebase the branch (`worktree-push`, `worktree create --reuse`, a restack), bind `git -C [WT_PATH] rev-parse --verify HEAD` as `[BOUND_HEAD]`. A step that moves it is followed at once, before any validation, publication or arm, by `git -C [WT_PATH] diff --no-renames --name-only [BOUND_HEAD] HEAD -- <each loaded file's repo path>` and a re-read of each listed file at `[WT_PATH]/<path>`, with the deleted-path rule of [dev SKILL.md § Round Contract](../dev/SKILL.md#round-contract).
- **A lane is quiet.** `ORCH_LANE_OUTPUT` decides what a lane prints and where a filled `<output_format>` block goes: [references/skill-rules.md](references/skill-rules.md) § Lane Output.

## Commands

Route `<command> [args]` to its workflow and follow [Workflow Execution](#workflow-execution).

| Command | Arguments | Workflow | Purpose |
|---------|-----------|----------|---------|
| `start` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/start.md` / `workflows/start-worktree.md` | Prepare one work item; from a worktree, run the full session |
| `start new` | `linear\|github ...` | `workflows/start-new.md` | Create one issue, then start it |
| `micro` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/micro.md` | Few-line tier: edit, commit, PR, arm, merge, with no dev agent and no review cycle |
| `small` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/small.md` | One-subsystem tier: the full session under thin review bounds |
| `handoff` | `linear\|github ...` | `workflows/handoff.md` | Launch independent sessions |
| `plan-issues` | `PLAN_PATH linear\|github` | `workflows/plan-issues.md` | Convert plan items into issues |
| `dev-start` | `[ISSUE_ID]` | `workflows/dev-start.md` | Delegate implementation |
| `dev-fix` | `[ISSUE_ID]` | `workflows/dev-fix.md` | Delegate fix items |
| `ci-fix` | `PR_NUMBER` \| `queue` | `workflows/ci-fix.md` | Analyze and fix CI failures |
| `review` | `[all]` \| `[last N]` \| `[HASH]` | `workflows/review.md` | On-demand review of local changes |
| `review-codebase` | `[PATH]` | `workflows/review-codebase.md` | Whole-codebase fanout, findings only |
| `review-pr` | `[PR_NUMBER]` | `workflows/review-pr.md` | Review cycle with fixes and QA |
| `review-pr-comments` | `PR_NUMBER` \| `BRANCH` | `workflows/review-pr-comments.md` | Triage PR review comments |
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Push, create PR, gates, merge |
| `merge-pr` | `PR_NUMBER` \| `all` | `workflows/merge-pr.md` | Verify conditions and merge |
| `post-summary` | `[ISSUE_ID]` | `workflows/post-summary.md` | Post summary and handoff comments |
| `oversee` | none | `workflows/oversee.md` | Fleet mode: one session per unblocked item, shepherd every PR to merge |

**`start` routing.** `github OWNER/REPO#N` → `TRACKER=github`, `ISSUE_ID=issue-N`, keep `OWNER/REPO` for the API; otherwise Linear unless the id starts with `issue-`. A cwd whose git common dir differs from `.git` is a worktree → `workflows/start-worktree.md`; otherwise `workflows/start.md`.

## Scripts

```bash
.agents/skills/orch/scripts/<script> [args]
```

| Script | Intent |
|--------|--------|
| `workflow-state` | Persistent state read/write/append. See below |
| `git-context` | Git-derived values (branch, head, issue id, roots, timestamps) |
| `pr-view-json` | PR view JSON; `status=no_pr` exits 0 and routes to PR creation, not an error |
| `resolve-base-branch` | Print a worktree's base branch; exits 1 rather than guess |
| `sync-base` | Resolve, fetch, and fast-forward the checkout that owns the base branch; prints the branch name |
| `container-close` | Serialize a Linear container close across linked checkouts; prints `closed`, `deferred` or a rate-limit `held`, with closed diagnostics on stderr |
| `base-freshness` | Gate the review cycle on a current base, or on a clean merge onto a merge-queue base; unverifiable = stale |
| `review-artifact-check` | Validate a reviewer's JSON artifact, the sole reviewer completion condition |
| `dev-return-write` | Write a dev agent's round-scoped completion artifact; never hand-author the JSON |
| `worktree-push` | Push an issue worktree via `worktree push`, reconciling rebased SHAs in workflow state in the same call; `--check-live-round` answers whether a fix round is in flight and pushes nothing |
| `dev-round-write` | Persist a fix round's delegated item set at stamp time; `--cut` records a reviewer or orchestrator scope choice |
| `dev-artifact-check` | Validate a dev round's completion artifact by round id |
| `round-prune` | Consumer-selected Cargo cleanup at round start; [Round Closure](references/skill-rules.md#round-closure) owns its policy and contract |
| `round-recover` | Close a stalled dev round from the idle agent's transcript: write the report as the artifact, or mint one re-delegation's round id |
| `dev-validate-run` | Run configured validation; contract: `--help`. Harness routes: dev SKILL.md § Long-Running Validation |
| `restack-skip` | Say whether a restacked head skips its range re-test: no conflict, or only version fields and changelog entries conflicted, per `--help` |
| `item-tier` | Assign an item's tier, `micro`, `small` or `standard`, from the launch estimate, Expected delta and the shared rules for its Location and changed paths; the widest input wins. Measured branch line counts do not select a tier. `--help` |
| `approval-wait` | Poll the reviewer gate; `--resolve-mode` prints the gate mode: it reads the consumer's `REVIEW_GATE_MODE` from the base checkout first, then native GitHub requirements where that policy permits it |
| `ci-wait` | Block until CI completes on a PR |
| `copilot-wait` | Wait for Copilot work |
| `queue-wait` | Blocking merge-queue / auto-merge waiter and verdict producer |
| `pr-order` | Resolve publication order: `pr-order --help` |
| `orch-env` | Effective value of a kendex `[env]` setting (process env > `.env.local` > `.kendex/settings.toml` > `kendex.settings.toml` > default) |
| `spawn-adapter` | Resolve Codex spawn parameters (`spawn`) and the runtime thread budget (`slots`) |
| `open-terminal` | Terminal handoff; model, effort, and permission flags via `--launch-flags` |
| `pane-write` | The one writer into a tmux pane: pastes a file or presses one key only into a proven pane running the expected process, and refuses an empty target, the caller's own pane, and a missing or shared window |
| `lane-close` | Stop one finished recorded lane's harness by signal, unless a hosted stop answers the item's worktree is gone, close its hosted sandbox (`--merged` for a merged, completed item) and tmux window, remove a finished item's state files on a full close, and update its fleet record. With `--park --pr N`, end a hosted lane's clean merge wait instead: stop the harness and the sandbox with its disk kept and record the lane `parked`, once the checks of [references/oversee-lanes.md § Parking a merge wait](references/oversee-lanes.md#parking-a-merge-wait) admit it |
| `lanes` | Enumerate harness auth lanes; `pick` prints the launch env prefix per `lanes --help`, exit 3 when none qualifies; `context` reports each live lane's context use; `state <item>` prints one lane's state from the pane, by the same judge `oversee-watch` and `open-terminal --wake` ask |
| `lane-host` | Resolve or call the configured host provider; protocol: [schemas/lane-host.md](schemas/lane-host.md). Static SSH reference: `lane-host-ssh --help` |
| `overseer-host` | Resolve or call the runtime the overseer's own session runs in, `ORCH_OVERSEER_HOST`; protocol: [schemas/overseer-host.md](schemas/overseer-host.md). tmux provider: `overseer-host-tmux --help` |
| `oversee` | `launch` opens a fleet's first overseer on the `ORCH_OVERSEER_PREFERENCE` account, from outside tmux with `ORCH_TMUX_SESSION` set, or with `--predecessor` its successor, and refuses `overseer-live` while one runs otherwise; `register` records a hand-opened one. Both write the `overseer` record [schemas/workflow-state.md § Oversee state](schemas/workflow-state.md#oversee-state) states |
| `lane-mail` | The lane-to-overseer mailbox and the owner channel. A lane runs `ask`, `notice`, `wait`, `inbox` and its mailbox monitor `watch`; the overseer runs `send`, `drain`, `pending` and `events`, adding `--root` and `--host` for a lane on another host, and on its own mailbox asks and reports to the owner with `--to owner` and closes an owner ask once with `resolve` |
| `lane-marker` | Write a lane's launch record, the marker under the common git directory and the lane's own mailbox; `open-terminal` and `lane-host create` both call it, and `lane-mail-check` hands a lane its mail only where it stands |
| `reconcile-work-items` | Read-only tracker sweep (parked containers, items stale past `RECONCILE_STALE_HOURS`, Done items with unchecked boxes). Exit 1 on findings |
| `oversee-watch` | Block until the fleet needs the overseer, then print one wake carrying every event the pass found. Also reads the overseer's own session, from its recorded exit status, its session rows and its account, with its pane as the named fallback: `overseer-mark` reports its own account mark reached, and `overseer-dead` and `overseer-walled` relaunch an overseer that ended or whose account is spent, in its window through `oversee-succeed`, where exit 3 says a successor holds it. `--repeat` is started through the orch job runner, `scripts/lib/job-unit.sh`, by [references/waiter-launch.md](references/waiter-launch.md) |
| `oversee-cycle` | Record a merged lane's cycle or report per-class totals; fields, targets and repeated-miss rules: `--help` |
| `oversee-succeed` | Replace an overseer and restart its fleet watch through the orch job runner. Triggers, refusals, check-only mode and launch/recovery flags: `--help`; the turn-end hook and `oversee-watch` use its `--check-marks` answer |
| `overseer-approve` | Approve one exact pull request head as the overseer's GitHub App from the token file `ORCH_OVERSEER_REVIEW_TOKEN_FILE` names, refusing `head-moved` when the live head does not start with the given one: [references/copilot-head-notices.md](references/copilot-head-notices.md), `--help` |

Every script takes `--help` bar `pr-view-json` and `resolve-base-branch`, whose only argument is a path. Waiter and gate semantics, including the `3` exit on hard auth failure and reading the effective gate mode (`approval`, `off`) only through `approval-wait --resolve-mode`: [references/gates.md](references/gates.md). Artifact checks: [references/artifact-checks.md](references/artifact-checks.md). Schemas: `schemas/workflow-state.md` (state file), `schemas/dev-return.md` (dev completion artifact), `schemas/dev-round.md` (fix-round item set), [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) (review/QA findings).

**Multi-PR watching.** Never hand-roll a monitor. When `.agents/skills/review-gate/scripts/pr-watch.sh` exists, run it (oversee: through `oversee-watch`); otherwise per-PR `approval-wait`/`queue-wait`.

**`workflow-state`.** Run it with no arguments for the action reference, and read `workflow-state --help` § Keys for the state-key forms.

**A queued merge is waited out in the lane**: `merge-pr.md` § 5 step 1 uses [Waiter launch](references/waiter-launch.md) and routes the recorded verdict (`queue-wait --help` § Verdicts). The lane stays active until it can finish the post-merge work.

## Configuration

Non-secret settings go in committed `kendex.settings.toml` under `[env]`; `.env.local` holds secrets and personal overrides. Keys: [README.md](README.md) § Setup; review-gate keys in [references/gates.md](references/gates.md); lane keys in `lanes --help` and `open-terminal --help`. System dependencies: `jq`; `bash` 3.2; `python3` 3.8+ for lane-mail, SSH and configured archives; `flock` and `setsid` (util-linux); `timeout` or `gtimeout` (coreutils) for `dev-validate-run`, and `perl` for its `--attached`. Optional: `systemd-run` with a user manager, which the orch job runner's jobs are contained in; a launch with no `--cap` (the fleet watch, the waiters and the succession's helper) also needs it to linger (`loginctl enable-linger`) ([references/job-units.md](references/job-units.md)); `setsid` stays the fallback elsewhere.

---

## Runtime Notes

> If you are running in **Codex**: `approval required by policy, but AskForApproval is set to Never` means an execpolicy rule matched the command, not its shell form. Never retry it, never wait for approval; act per [references/codex-runtime.md](references/codex-runtime.md). Run long waiters through [Waiter launch](references/waiter-launch.md); CI waiting uses `.agents/skills/orch/scripts/ci-wait`. Spawn generated agents through `scripts/spawn-adapter` with `fork_context: false`, then `send_input` a `DELEGATION:`-prefixed `<delegation_format>`.

> If you are running in **OpenCode**: store the `task_id` returned by `functions.task` in workflow state (`child_sessions[agent].agent_id`, `review_agent_ids[reviewer-name]`) and re-delegate with `functions.task(task_id=<stored_id>)`. Spawn fresh only when no ID is stored, one resume attempt failed, or the task is confirmed dead.

> If you are running in **Pi** with `pi-agents-tmux`: delegation is one `subagent` call whose `task` argument is the filled `<delegation_format>` alone. Never prepend role text. Store the returned `taskId` in workflow state. [references/pi-runtime.md](references/pi-runtime.md).

---

## Skill Rules

Judge anything (a finding, proposal, fix, issue candidate, plan, directive or result) first by naming the outcome the work exists to drive, then by how well it drives that outcome; work that serves a mechanism, a check or a habit but not the outcome is changed or dropped.

Delegation, planner launch, lifecycle, round closure, coordination, and lane output: [skill-rules](references/skill-rules.md). A design, an item brief or research on another system is held to the code-quality skill's SKILL.md § Over-Engineering; an overseer's directive, item or fix names the problem's source in the core mechanics or architecture and fixes it there first. A patch, shim, workaround or gate standing in for that fix names why it cannot happen now, and an item that removes it.

### Workflow Execution

- **Sequential sections.** Mark in-progress, execute every sub-section, mark completed, proceed. Never create tasks for sub-sections, never complete a parent before its children, never skip a step on a predicted outcome.
- **Skip-if.** Evaluate "Skip if [condition]" literally; when true, append "(SKIPPED)", mark completed.
- **Nested workflows.** Invoke `⤵`-marked workflows through the harness mechanism, never inlined. Record the return point (`→ § X`) first.
- **Worktree scope.** Work only in this tree and branch. Never write kendex project scope unless a refresh brief authorizes it. The CLI refuses project-scope `refresh`, `apply` without `--plan`, and `updates --apply` in marked lanes unless the refresh lane passes `--lane-refresh`. If `ISSUE_ID` differs from the branch, ask: reuse, abort, or switch.
- **Unsent input is not an instruction.** Text already sitting in the composer when a session reaches its prompt belongs to the harness, not to the user: clear it, act on nothing it says.

#### Harness-Safe Shell

**Run exactly one simple command per tool call with explicit arguments.** Substitutes, and what each Codex launch mode refuses: [references/codex-runtime.md](references/codex-runtime.md). Normalize delegated command lists the same way before they enter a prompt: an env-assignment prefix becomes a precondition check plus the bare command. A finding's location, description, or cause never crosses argv: write it to a file with the harness file-write tool and bind the path (`--items-file`, `append-file`, jq `--slurpfile`).

#### Tracker Resolution

An `ISSUE_ID` starting with `issue-` is GitHub (`TRACKER=github`, issue number `${ISSUE_ID#issue-}`, repo from caller context else `gh repo view --json nameWithOwner`); anything else is Linear. A caller-supplied `tracker` wins; resolve once per workflow into `TRACKER` and `ISSUE_REF` (`#N` for GitHub, the Linear identifier otherwise), the only form a `Closes` line renders. Run **Linear only** / **GitHub only** steps only for that tracker; never run `linear.sh` against a GitHub item.

### State Management

Durable data lives in workflow state through the `workflow-state` CLI only (`set-git-head`/`set-now`, never inline substitution). Location: `<state-dir>/workflow-state-[ID].json`, where `workflow-state --help` § State directory resolves `<state-dir>`.

Other temporary session state, including handoffs, lane status, and reviews, defaults to the repository's `tmp/`, which kendex's managed ignore block covers in every consumer, while `docs/` holds tracked repository content and never receives a kendex ignore rule. A plan or research report is not session state: its durable home is its tracker issue, `agents/planner.md` § Plan Artifacts places its working copy, and it is never committed.

After compaction, resume from the step after the last completed one: read the item's workflow state, or for an overseer use [oversee.md § 1](workflows/oversee.md#1-resolve-the-launch-surface)'s bounded resume reads. Apply [Delegation](references/skill-rules.md#delegation) before re-sending by stored ID. Stall recovery follows [Round Closure](references/skill-rules.md#round-closure). Never repeat completed actions.

### Review Pipeline

Finding schema, routing, disposition and the issue audit pipeline: [references/finding-disposition.md § Review pipeline](references/finding-disposition.md#review-pipeline).
