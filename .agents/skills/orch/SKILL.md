---
name: orch
description: "PRIMARY AGENT ONLY. Load to orchestrate a Linear or GitHub work item from preparation through merge."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

Before changing this skill's scripts, runtime or tests, read DEVELOPMENT.md.

For lane or overseer settings in kendex.settings.toml, kendex-local.toml or kendex.toml, the overseer makes one direct commit with only existing light checks and no lane, design review, internal or external review or second opinion; simple JSON/settings use existing fast paths, while executable behavior, test commands and permissions retain their needed checks, and a queue or ruleset conflict is reported at its existing owner without added review rounds.

A worktree created as an orch lane follows the Refresh ownership and committed outputs heading in these orch Project Instructions, including its local-fleet case when no refresh workflow exists. Respect the lane refresh restriction. A lane explicitly launched to refresh runs kendex refresh or kendex apply only with --lane-refresh, as its brief permits. An ordinary worktree follows its own project resolution and retains actionable drift repair details. Use the explicit lane record to distinguish them.

The hosted overseer coordinates from the control VM. Run item implementation, builds, installation, tests and validation in an owned lane. Where the fleet runs a control-host guard, that guard reads control-host-toolchain.conf. It blocks cargo, npm, pnpm, yarn, npx, tsc, vitest, biome, eslint and next; tools/guard, post-merge, and orch's and agent-runtime's setup; orch-runtime validate; and commands from DEV_VALIDATE_CMD or ORCH_POST_MERGE_CMD. This block includes post-merge --refresh-only. The absence of a guard does not permit item builds, installation, tests or validation on the control host. For refresh ownership and synchronization after merge, follow the Refresh ownership and committed outputs heading in these orch Project Instructions. Do not run a blocked command through a wrapper.

### Refresh ownership and committed outputs

Use the repository-declared owner for kendex refresh outputs. Kendex uses its lock-record Actions workflow and rolling kendex/lock pull request. Consumers with automatic refresh use their kendex-refresh Actions workflow and rolling kendex/refresh pull request. When no refresh workflow exists and the fleet is local, the overseer owns refresh in the base checkout. Keep the local-fleet full post-merge route. This local owner is not a hosted control VM. Confirm the execution owner and its output paths before adoption. A hosted consumer without a refresh workflow must confirm an authorized owner outside the control VM. The hosted overseer runs sync-base to receive committed outputs after they merge. It does not run post-merge or post-merge --refresh-only on the control VM. Post-merge does not refresh or verify a base checkout that holds .github/workflows/kendex-refresh.yml; in other base checkouts, it reports refresh changes and keeps them. Preserve unrelated tracked and untracked work. Keep each refresh workflow under its existing owner.

### Validation routing

- Fix rounds keep their delegated round base. Every kendex change is queue-only, per D027: CI holds the full validation record, and the merge waits on the merge-group run. In kendex a red merge-group run re-arms only a new head, even where merge-pr § 5's re-queue rule re-arms the same head on `reach: outside`. Where ci-fix leaves the head unchanged, for a flake or a fault ci-fix § 4 places in another pull request, the lane hands back to the overseer with the failing run.

### Owner messages

- The owner's time zone is Pacific (America/Los_Angeles). Use the time format in `skills/communication/references/messages.md` § Times.
- The owner's night, for `skills/orch/references/communication-modes.md` § Owner asks, is 11 pm to 8 am Pacific.

### Proposals

- A kendex `Proposal:` comment, per `skills/orch/references/skill-rules.md` § Coordination, Tracked issue creation, carries a `Symptom:` line (where, when and what broke) or an `Owner:` line (the owner's note or ask) beside `Reached by:`, at every source and priority. audit-issues § 6 declines one with neither, per the project-management skill's § Intake.

### Consumer refresh review

- This organization's consumers route their kendex refresh pull request to the overseer, never to Copilot, since kendex already reviewed its packages. Each consumer's committed `kendex.settings.toml` `[env]` declares `REVIEW_GATE_REFRESH_REVIEW = "overseer"`, `REVIEW_GATE_REFRESH_BRANCH = "kendex/refresh"` and `REVIEW_GATE_REFRESH_AUTHOR = "vanillagreen-fleet-lanes[bot]"`. A consumer without them gets a Copilot request on that head; add them there through a lane in that repository.

### Cargo round cleanup

At each development round boundary, run the owner-scoped worktree cleanup policy for Cargo output. Use ORCH_ROUND_PRUNE_DISK_PCT as the configured disk threshold. Prune only the owned worktree target directory. If CARGO_TARGET_DIR is elsewhere, report the separate cleanup need and do not delete another owner's output. Between the round-id and delegation-time stamps, write the request `{"op": "prune-round", "field": "dev"}` to a file and run `.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [FILE]`; at or past the mark it exits 1 recording `target-elsewhere` where CARGO_TARGET_DIR is not the worktree's own target directory.

### Pi package publication

When a kendex item's diff changes consumer-facing files under `pi-extensions/<dir>`, the launch read gives the item two Done-when boxes. The branch box requires its PR to raise `pi-extensions/<dir>/package.json` by `skills/commit-guards/CHECKS.md` § Release versions and replace its changelog heading `### Unreleased` with `### <version>`. A diff that only touches what `.pi/prompts/npm-deploy.md` § Skip publish for lists takes neither box.

After merge, the item's lane runs `.pi/prompts/npm-deploy.md` § Publish, tag, refresh, verify steps 1-4 for that package only. Fetch main, use the item's merge commit as `<release>` and the fetched main head as `<head>`, tag `<unscoped-name>-v<version>` at `<release>`, and push that tag alone. Find and watch the `publish-npm` workflow_dispatch run. Retry the same tag only when the failure needs no new version, following step 4. Keep the item in Verifying until its Post-merge box passes. Run this action in the lane, never on the control VM. The orch verification pass reads the workflow run rather than `npm view`: `tools/publish-npm` exits 0 with `published=` or `served=` only after npm serves the version. Use this exact Post-merge box:

- [ ] Post-merge: the publish-npm workflow_dispatch run titled publish-npm <tag> (not a dry_run dispatch) concluded success for this item's version or a later version of the same package; Where: gh api REST repos/vanillagreencom/kendex/actions/workflows/publish-npm.yml/runs, read by the orch verification pass; Why after merge: publish-npm publishes from main only, on a tag of the merged commit (D003); Trigger: merge; Deadline: +24h

### Issue creation

- Before a kendex issue create in `workflows/start-new.md` § 2 or `workflows/plan-issues.md` § 4, read the project-management skill's Project Instructions `### Subsystem parent` in `.agents/skills/project-management/SKILL.md`, and apply it to that create and the steps after it.
<!-- kendex:project-instructions:end -->

# Orchestration

Load `mailbox` for [takeover](workflows/oversee-takeover.md), and `github`, `worktree` and `linear` before their first use. The dev and reviewer skills call orch's scripts.

> **MODE SWITCH**: you are the orchestrator. Delegate every implementation, review and QA task to a specialist sub-agent. Never edit code unless the user explicitly asks, or the item runs the [`micro`](workflows/micro.md) tier, whose runner makes the edit itself.

## The Cycle

Get the issue → dev implements → publication, review and fixes in the order `orch-runtime pr order` answers → required CI and review gate → merge.

- **Bounded loops.** A fix round addresses blockers only, and the same pass declines or tracks every `fix` suggestion ([review-pr](workflows/review-pr.md) § 4). A re-review narrows to the fix diff, the domains it touched and the class of every defect it fixed ([reviewer](../reviewer/SKILL.md) § Re-Review Rounds). Two consecutive rounds with no new blocker end the review. [At The Cap](workflows/review-pr.md#at-the-cap) sets the cap, cap 0 and a fix round's own regression.
- **Finding conduct.** Apply reviewer's [decision flow](../reviewer/references/finding-disposition.md#decision-flow), [recurrence rule](../reviewer/references/finding-disposition.md#recurrence) and [filing bar](../reviewer/references/finding-disposition.md#filing-bar).
- **Scope cuts.** A reviewer or the orchestrator can choose a cut round. A round whose only findings are scope or wording asks ends the review: reply, resolve, push nothing, and merge through the gate.
- **Ask gates.** [communication-modes](references/communication-modes.md) alone decides which questions reach the user. Word them with [communication](../communication/SKILL.md) under the mode `ORCH_USER_MODE` names. That ask set holds whatever `ORCH_DECISION_MODE` says. Merge asks unless `ORCH_MERGE_AUTONOMY=auto`, which merges without asking only when every merge gate is green. In a lane every ask gate is `lane-mail`, never the harness question tool: [skill-rules](references/skill-rules.md) § Coordination.
- **Post-PR autonomy.** After a PR exists, `ORCH_DECISION_MODE=auto-recommended` takes and logs the continuing option while a bounded wait, retry or triage round remains; `ask` presents the listed choice. `orch-runtime state head-budget take` spends one automatic retry (`--kind review-wait` restarts its count on a new head, `--kind ci-fix` counts across heads), and `head-budget reset` starts the count over. At a cap, `orch-runtime state post-pr-stop record` persists the named stop with its rendered Markdown comment; the workflow posts that file to the PR and returns the stored stop. A nested caller uses `post-pr-stop record-if-empty`, so a precise upstream stop stands. Every continuing action lifts the stop with `post-pr-stop clear`. Initialize the item's state before these transitions. `ORCH_MERGE_AUTONOMY` controls merge consent only.
- **The overseer reads results.** It accepts green lane checks and CI without reruns, and grants no prepare, commit, push or merge, and no shared validation slot. Green lanes with the user's merge consent arm auto-merge and own its wait per [merge-pr](workflows/merge-pr.md). A dev test-only validation-ceiling report ends validation. Lanes tick branch boxes with proving artifacts; where a lane cannot, the runtime's close ticks them from the PR body's `## Done-when evidence` section. The overseer ticks post-merge boxes only after reading the proving artifacts at their revision and conditions: test output, a screenshot, a measured figure or a deployed screen. A lane summary is no proof. A container closes when its last child is completed or canceled (a Duplicate child counts as canceled), through `orch-runtime container-close`; an outcome to read lives in its own child. When evidence is due or contradicted, the overseer reads it to narrow, replace or stop the failed intervention; a fix item is not the default. The overseer gives no model or account instructions. Lanes keep their launch models and launch no lanes.
- **Item work stays in lanes.** A fleet is hosted when `orch-runtime host resolve` prints anything but `local`; its overseers share the control VM for coordination. Every tracker item's round goes to its branch's lane: no worktree, item branch, dev, review or fix agent, validation, build, install or test runs on the control host. The one exception is an owner-directed small change, `directive-[ID]` ([micro.md](workflows/micro.md) § Items). A control-host subagent (sweep, triage verifier, measurement or research) reads without bulk writes: it streams archives, or extracts each into its own scratch subdirectory and removes the extraction before the next. Before an extraction it reads the uncompressed size and the volume's free space, and stops and reports to the overseer without extracting where less than 3 GB would remain. It runs no history-wide content read (`git log -S` or `-G`, `--all -p`, or any command that reads every blob), since a lazy fetch in a partial clone can fill the disk; it searches through `gh search code`, the GitHub API or a lane. It runs no busy wait (`/dev/zero`, `/dev/urandom`, spin polls) on the shared host: it waits with one bounded background command and its completion notice, or on watch events. Every control-host subagent brief carries this rule. Its scratch location is an empty subdirectory, `tmp/<run>/<agent-topic>/`, that only that subagent removes and that no background job of the overseer reads. The fleet's guards read [the command blocks](references/control-host-toolchain.conf). Refresh follows the [consumer's owner](references/oversee-events.md); there is no `--refresh-only` exception.
- **Acceptance is artifact-based.** A round closes on a validated on-disk artifact plus git and tracker state, never on a return message.
- **Rules reload after a rebase.** Before a step that can rebase the branch (the `record-push` request, `worktree create --reuse`, a restack), bind `git -C [WT_PATH] rev-parse --verify HEAD` as `[BOUND_HEAD]`. A step that moved it is followed at once, before any validation, publication or arm, by `git -C [WT_PATH] diff --no-renames --name-only [BOUND_HEAD] HEAD -- <each loaded file's repo path>` and a re-read of each listed file at `[WT_PATH]/<path>`, under the deleted-path rule of dev's [Round Contract](../dev/SKILL.md#round-contract).
- **A lane is quiet.** `ORCH_LANE_OUTPUT` decides what a lane prints and where a filled `<output_format>` block goes: [skill-rules](references/skill-rules.md) § Lane Output.

## Commands

Route `<command> [args]` to its workflow and follow [Workflow Execution](#workflow-execution).

| Command | Arguments | Workflow | Purpose |
|---------|-----------|----------|---------|
| `start` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/start.md` / `workflows/start-worktree.md` | Prepare one work item; from a worktree, run the full session |
| `start new` | `linear\|github ...` | `workflows/start-new.md` | Create one issue, then start it |
| `micro` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/micro.md` | Few-line tier: edit, commit, PR, arm and merge, with no dev agent and no review cycle |
| `small` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/small.md` | One-subsystem tier: the full session under thin review bounds |
| `handoff` | `linear\|github ...` | `workflows/handoff.md` | Launch independent sessions |
| `plan-issues` | `PLAN_PATH linear\|github` | `workflows/plan-issues.md` | Convert plan items into issues |
| `dev-start` | `[ISSUE_ID]` | `workflows/dev-start.md` | Delegate implementation |
| `dev-fix` | `[ISSUE_ID]` | `workflows/dev-fix.md` | Delegate fix items |
| `ci-fix` | `[PR_NUMBER]` | `workflows/ci-fix.md` | Analyze and fix a PR's CI failures, a merge-group run's included |
| `review` | `[all]` \| `[last N]` \| `[HASH]` | `workflows/review.md` | On-demand review of local changes |
| `review-codebase` | `[PATH]` | `workflows/review-codebase.md` | Whole-codebase fan-out, findings only |
| `review-pr` | `[PR_NUMBER]` | `workflows/review-pr.md` | Review cycle with fixes and QA |
| `review-pr-comments` | `PR_NUMBER` \| `BRANCH` | `workflows/review-pr-comments.md` | Triage PR review comments |
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Push, create the PR, gates, merge |
| `merge-pr` | `PR_NUMBER` \| `all` | `workflows/merge-pr.md` | Verify the conditions and merge |
| `post-summary` | `[ISSUE_ID]` | `workflows/post-summary.md` | Post the summary and handoff comments |
| `verify` | none | `workflows/verify.md` | Read and complete due verification checks |
| `oversee` | none | `workflows/oversee.md` | Fleet mode: one session per unblocked item, every PR shepherded to merge |

**`start` routing.** `github OWNER/REPO#N` sets `TRACKER=github` and `ISSUE_ID=issue-N`, and keeps `OWNER/REPO` for the API; any other id is Linear unless it starts with `issue-`. A working directory whose git common dir differs from `.git` is a worktree: route it to `workflows/start-worktree.md`; otherwise to `workflows/start.md`.

## Scripts

```bash
.agents/skills/orch/scripts/<script> [args]
```

| Script | Use |
|--------|-----|
| `orch-runtime` | The orch runtime: workflow records, their operations and the fleet watch. `orch-runtime --help` lists its verbs, and each verb's `--help` is its contract. It runs only the binary `setup` built for the sources beside it; otherwise it prints `orch-runtime: setup-required key=<key> run=<path to setup>` on stderr, exits 69 and builds nothing |
| `setup` | Build agent-runtime, then `orch-runtime`, into the user cache, keyed on both crates' sources, then print each duty's readiness on stderr; `setup --detach` starts the builds in the background. `post-merge` ends with it, and a lane's launch runs it for the lane's tree |
| `orch-env` | Print the effective value of a setting: `orch-env NAME DEFAULT` (process environment, then the private env file, then `.kendex/settings.toml` and `kendex.settings.toml`, then the default) |
| `git-context` | Print a git-derived value: branch, head, issue id, repository or common root, timestamp |
| `resolve-base-branch` | Print a worktree's base branch |
| `sync-base` | Resolve, fetch and fast-forward the checkout that owns the base branch, and print the branch name |
| `base-freshness` | Fetch the base branch and report the worktree's ahead and behind counts as JSON, so the review cycle gates on a current base |
| `post-merge` | Run the repository's post-merge steps in its base checkout, stopping at the first failed step |
| `lane-host-ssh` | The static SSH lane-host provider; protocol: [lane-host.md](schemas/lane-host.md) |
| `lane-marker` | Write a lane's launch record before anything writes to the lane |
| `copilot-statusline` | The `statusLine` command a Copilot CLI lane runs: it records the session JSON the CLI hands it on stdin and prints one footer line |

The mailbox skill's `lane-mail` is the lane-to-overseer mailbox and the owner channel. A lane runs `ask`, `notice`, `wait`, `inbox` and its mailbox monitor `watch`. The overseer runs `send`, `drain`, `pending` and `events`, adding `--root` and `--host` for a lane on another host; on its own mailbox it asks and reports to the owner with `--to owner`, and closes an owner ask once with `resolve`.

Every script and every verb takes `--help`, except `resolve-base-branch`, whose one argument is a path, and `copilot-statusline`, which reads the CLI's JSON on stdin. The review gate, the CI and merge-queue waits, and the runtime's `verify-review`, `verify-pr` and `queue-watch`: [gates.md](references/gates.md). Artifact checks: [artifact-checks.md](references/artifact-checks.md). Schemas: `schemas/workflow-state.md` (the state file), `schemas/dev-return.md` (the dev completion artifact), `schemas/dev-round.md` (the fix round's item set), [review-finding.md](../reviewer/schemas/review-finding.md) (review and QA findings).

**Multi-PR watching.** Never hand-roll a monitor: [gates.md § Multi-PR watching](references/gates.md#multi-pr-watching).

**A queued merge is waited out in the lane**: [merge-pr.md § 5](workflows/merge-pr.md#5-execute-the-merge) step 1.

## Configuration

Settings, where each is set and its default: [references/settings.md](references/settings.md); the review-gate keys: [references/gates.md](references/gates.md).

The runtime needs `tmux`, `git`, `setsid` and `gh` on `PATH`, and `setup` needs Cargo; `orch-runtime ready` names any a duty lacks. The scripts need Bash 3.2 or later, `jq`, and Python 3 with `flock` for the SSH host provider. A lingering systemd user manager with `systemd-run` contains the runtime's detached jobs; where the manager does not run a unit, the job runs as a `setsid` group ([job-units](references/job-units.md)).

---

## Runtime Notes

> If you are running in **Codex**: `approval required by policy, but AskForApproval is set to Never` means an execpolicy rule matched the command, not its shell form. Never retry it and never wait for approval; act per [codex-runtime](references/codex-runtime.md). Run long waiters, and the repeated `verify-pr` calls that verify a pull request's CI, through [Waiter launch](references/waiter-launch.md). Spawn generated agents with the parameters `.agents/skills/agent-runtime/scripts/agent-runtime subagent spawn --harness codex [CANONICAL_NAME]` prints, without a full-history fork, with a `DELEGATION:`-prefixed `<delegation_format>`, as [codex-runtime § Spawning Codex collaboration agents](references/codex-runtime.md#spawning-codex-collaboration-agents) states for each surface.

> If you are running in **Pi** with `pi-agents-tmux`: a delegation is one `subagent` call whose `task` argument is the filled `<delegation_format>` alone. Never prepend role text. Store the returned `taskId` in workflow state. [pi-runtime](references/pi-runtime.md).

---

## Skill Rules

Judge anything (a finding, proposal, fix, issue candidate, plan, directive or result) by first naming the outcome the work exists to drive, then by how well it drives that outcome. Change or drop work that serves a mechanism, a check or a habit but not the outcome.

For each observed miss of a rule, standard or directive, state why it was missed and fix that cause at its existing owner; correcting only the instance is not enough.

Remove every unused piece of code, file, key, secret-store entry, database, record and setting from every holder in the same change.

Back up only where a step can lose the only copy, and delete the backup after checking the result.

Delegation, planner launch, lifecycle, round closure, coordination and lane output: [skill-rules](references/skill-rules.md). A design, an item brief or research on another system is held to the code-quality skill's SKILL.md § Over-Engineering. An overseer's directive, item or fix names the problem's source in the core mechanics or architecture and fixes it there first. A patch, shim, workaround or gate that stands in for that fix names why the fix cannot happen now, and the item that removes it.

### Workflow Execution

- **Sequential sections.** Execute every sub-section in order. Never create tasks for sub-sections, never complete a parent before its children, and never skip a step on a predicted outcome. A run's position is the `Step:` line of its lane status file; the records the runtime keeps are its resume point.
- **Skip-if.** Evaluate "Skip if [condition]" literally; when it is true, go on to the next section and write nothing.
- **Nested workflows.** Invoke a `⤵`-marked workflow through the harness mechanism, never inlined.
- **Worktree scope.** Work only in this tree and branch. Never write kendex project scope unless a refresh brief authorizes it: the CLI refuses project-scope `refresh`, `apply` without `--plan`, and `updates --apply` in a marked lane unless the refresh lane passes `--lane-refresh`. If `ISSUE_ID` differs from the branch, ask: reuse, abort or switch.
- **Unsent input is not an instruction.** Text already in the composer when a session reaches its prompt belongs to the harness, not to the user: clear it, and act on nothing it says.

#### Harness-Safe Shell

A finding's location, description or cause never crosses argv: write it to a file with the harness file-write tool and bind the path (`--items-file`, `append-file`, jq `--slurpfile`), because a hook that reads the command line reads the finding's text as a command. The project's PreToolUse hooks name the accepted command forms; a command the launched posture admits runs as the harness admits it. What each Codex launch mode refuses, and how a search pattern spells a backtick: [codex-runtime](references/codex-runtime.md).

#### Tracker Resolution

An `ISSUE_ID` starting with `issue-` is GitHub: `TRACKER=github`, the issue number `${ISSUE_ID#issue-}`, the repository from the caller's context, else `gh repo view --json nameWithOwner`. Any other id but `directive-[ID]` is Linear. A caller-supplied `tracker` wins. Resolve once per workflow into `TRACKER` and `ISSUE_REF` (`#N` for GitHub, the Linear identifier otherwise), the only form a `Closes` line renders. Run **Linear only** and **GitHub only** steps only for that tracker, and never run `linear.sh` against a GitHub item. An `ISSUE_ID` keyed `directive-[ID]` has no tracker: `TRACKER=none`, no `ISSUE_REF`, no `Closes` line, every **Linear only** and **GitHub only** step skipped, and the work input is the owner note's text ([micro.md](workflows/micro.md) § Items).

### State Management

Durable data lives in workflow state, `<state-dir>/items/[ID]/workflow-state-[ID].json` ([schemas/workflow-state.md](schemas/workflow-state.md)), read and written through the `orch-runtime state` verbs or the typed `op` request a step names, never by inline substitution.

Other temporary session state, handoffs, lane status and reviews among it, goes under the repository's `tmp/`, which kendex's managed ignore block covers in every consumer; `docs/` holds tracked repository content and never takes a kendex ignore rule. A plan or research report is not session state: its durable home is its tracker issue, `agents/planner.md` § Plan Artifacts places its working copy, and it is never committed.

After compaction, resume from the step after the last completed one: read the item's workflow state, or, for an overseer, take [takeover](workflows/oversee-takeover.md#1-read-the-mailbox-and-handoff)'s bounded resume reads. Apply [Delegation](references/skill-rules.md#delegation) before re-sending by a stored ID. Stall recovery follows [Stalled round](references/skill-rules.md#stalled-round). Never repeat a completed action.

### Review Pipeline

The finding schema, routing, disposition and the issue audit pipeline: reviewer's [Review pipeline](../reviewer/references/finding-disposition.md#review-pipeline).
