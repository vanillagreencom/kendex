# Micro Workflow

The tier for a change of a few lines whose whole check is the repository's commit chain. One agent reads the item, edits, commits, pushes, opens the pull request and arms it: no dev subagent, no review cycle, no QA cycle, no validation battery. [oversee.md](oversee.md) § Item Tier assigns the tier through `item-tier`. A `small` item runs [small.md](small.md); every other item runs [start.md](start.md).

| Command | Flow |
|---------|------|
| `micro [ISSUE_ID]` | § 1 → § 5 |
| `micro github OWNER/REPO#N` | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |
| `micro directive-[ID]` | the owner's directed change, § Items: § 1 → § 5 in the overseer's own checkout |

## Items

A tracker item reaches this tier through `item-tier` at launch. Its runner is a lane in the item's worktree, or the overseer in the main checkout of a local fleet with no lane free. On a hosted fleet it runs as a lane only: the main-checkout route refuses the control host (§ 1).

An owner-directed small change, a settings line or a few lines of Markdown, has no tracker item. Its key is `directive-[ID]`, `[ID]` the id of the owner's note that directed it ([oversee-events.md § `owner-note`](../references/oversee-events.md#owner-note)). The overseer makes it itself, in its own checkout, on the control host or local: no lane, no internal review. The directive is the acceptance: § 2 step 7 records it on the item's round, and the runtime refuses a close that names no directive. Its checks are the commit chain, run once at the commit, and the repository's required GitHub checks, which protect the merge queue. The repository's own rules stay: its required review and checks, and the paths its settings refuse (§ Escape condition 3).

The line between the overseer making a change and a lane making it is the cost of the check, never the kind of file. A change the commit chain checks in its diff-scoped pass is this tier's. A change whose check needs a build or a test run is not a small change: it takes a lane in its own sandbox, so nothing heavy runs on the control host. A lane is keyed by a tracker item, since its brief, its launch preflight, its `Closes` line, its completion and `lane-close`'s tracker read each read one, so `directive-[ID]` never runs as a lane: the overseer files the change as a tracker item from the directive, as it files an item an `owner-note` asks for ([oversee-events.md § File one item alone](../references/oversee-events.md#file-one-item-alone)), and that item launches under its own key at the tier [oversee.md](oversee.md) § Item Tier assigns it, with neither the directive's branch nor its pull request: a lane re-makes a change of a few lines from the item (§ Escape).

The tier is read once, at the admission that launched the run, and floors the run. A later edit is judged by the paths it touches (§ 4), never re-tiered by class.

`[WT_PATH]` is the running checkout's root throughout. Steps marked **Main checkout only** are the main-checkout route's alone, the directed change included. A lane never waits on the overseer for a step this workflow permits: [skill-rules.md § Coordination](../references/skill-rules.md#coordination), Lane asks.

**Main checkout only.** The run returns that checkout to `[BASE_BRANCH]` before it reports anything: at § 3, at an escape, and at any stop in between. The transfer in § Escape moves the item's branch and any uncommitted edit into its worktree first. The fleet runs its merge handling in that checkout at every merge ([oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds), `merged`), and `sync-base` refuses a tracked-dirty tree. § 5 reports the branch the checkout ends on.

## Budget

§ 1 through § 3 take about 8 minutes in a lane and about 3 in the overseer's own session. From the pull request on, the time is the repository's: its required checks and the review its ruleset requires. A run past the target finishes and reports the overrun in § 5.

## 1. Open The Session

In a lane whose brief names a status file, `tmp/lane-status-[ISSUE_ID].md`, write it before this section's first command, and rewrite it at each step change, holding what the brief names.

**Main checkout only.** Read the lane host before anything else:

```bash
.agents/skills/orch/scripts/lane-host resolve
```

Any answer but `local` refuses the run here, with nothing read, activated or changed; [SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes, holds the rule. The refusal is a tracker item's: a directed change continues on any answer, since § Items admits it on any host. The report's first line is `micro-control-host host=[HOST]`, and its next line is the fix: launch the item as a hosted lane through [oversee.md](oversee.md) § 3 Lane directive, Placement, with its `/orch micro [ISSUE_ID]` brief.

Resolve `TRACKER` and `ISSUE_REF` from `[ISSUE_ID]` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution); a directed change resolves to `TRACKER=none` there, with no `ISSUE_REF`, and its item is the directive's text, which names the file and the change. Then read the main checkout:

```bash
.agents/skills/orch/scripts/git-context common-root .
```

Its output is `[MAIN_REPO_ROOT]`. Read a tracker item. Linear:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID] --with-bundle
```

```bash
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID]
```

A rate-limited activation is held under the linear skill's `patterns/workflow-actions.md` § Quota Holds.

GitHub:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,labels,url
```

A container, a blocked child, or a bundle escapes here (§ Escape condition 1).

**Main checkout only.** Sync the base, whose name the command prints as `[BASE_BRANCH]`, then cut the normalized item branch as `[BRANCH]`, the lowercased item key. That spelling is what the ownership scan in `worktree create` matches, so a later run reads the branch as owning the item:

```bash
.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
```

```bash
git -C [MAIN_REPO_ROOT] checkout -b [BRANCH]
```

In a lane worktree the branch already exists: gate on base freshness through [start-worktree.md](start-worktree.md) § 1 step 7 instead, and stop on its failure.

Read the branch both routes now stand on and initialize the item's workflow state with it. Its output binds `[BRANCH]` on the lane route, where nothing has named the branch yet, and confirms it on the other. `[BRANCH]` is the only name this workflow gives that branch, including § 4's `[PR_BRANCH]`:

```bash
.agents/skills/orch/scripts/git-context branch [WT_PATH]
```

`init` refuses a standing file as `state-exists`, and a restarted item's state file carries its round history, so read existence first:

```bash
.agents/skills/orch/scripts/orch-runtime state exists --item [ISSUE_ID]
```

`exists` false → initialize:

```bash
.agents/skills/orch/scripts/orch-runtime state init --item [ISSUE_ID] --worktree [WT_PATH] --branch "[BRANCH]"
```

`exists` true → keep the state and record where this run stands:

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [ISSUE_ID] /worktree "[WT_PATH]"
.agents/skills/orch/scripts/orch-runtime state set --item [ISSUE_ID] /branch "[BRANCH]"
```

Record this tier after either state route. Direct publication reads it to keep this tier's commit-chain validation:

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [ISSUE_ID] /tier micro
```

## 2. Edit And Commit

1. **Confirm the commit chain is armed**, before any file changes. That chain is this tier's whole validation: the diff-scoped guard rather than `DEV_VALIDATE_CMD`. An unarmed or unreadable answer escapes (§ Escape condition 2). Where the `commit-guards` package is installed this verb answers it and this workflow asks no other; elsewhere the project's own setup instructions name the verb.

   ```bash
   .agents/skills/commit-guards/scripts/install-git-hooks --check --repo [WT_PATH]
   ```

2. **Make the edit** the item's Done-when, or the directive, states. Nothing else enters the diff.

3. **Check each claim the diff states about code**, once. **Skip if** no changed sentence states what a file, script, setting or test does, holds, counts or refuses. Otherwise read each such sentence against the code that defines or implements what it states: the file it names, or the file a search for the setting, script or symbol it names finds. Judge it as [reviewer/SKILL.md](../../reviewer/SKILL.md) § Ethos judges a claim and a number in prose, where a claim no code makes true is false, and fix a false one in this edit. This tier runs no review cycle, so without this step the pull request's review would be the claim's first reader.

4. **Read the changed paths against § Escape condition 3**:

   ```bash
   git -C [WT_PATH] status --porcelain
   ```

   Every path that listing names is in scope, tracked change and untracked addition alike. Commit a path the edit did not make elsewhere, or remove it, before step 5. If a path is in condition 3's class, record escape condition 3 but continue through step 5. A successful commit then escapes. This ordering leaves a local commit that the wider tier continues.

5. **Commit the paths by name**, never `-A`, so the committed set is the one step 4 read. `[PREFIX]` is the Conventional Commits type the change is; the commit-msg hook judges it and the header's length. The repository's changelog rule applies as to any commit, and a refusal from the chain is its answer.

   ```bash
   git -C [WT_PATH] add [PATH]...
   ```

   ```bash
   git -C [WT_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
   ```

   A successful commit with escape condition 3 recorded escapes now. Any other successful commit continues. A repository-rule refusal escapes as condition 4 with the staged edit still present; § Escape transfers that exact state.

6. **Post the completion summary**. **Skip if** `TRACKER` is GitHub, or the item is keyed `directive-[ID]`: the Linear CLI refuses every post for a GitHub item, and a directed change has no tracker item. This tier runs no dev round, so this comment is the item's one Completion Summary, and `container-close` refuses a container whose child has none; a later run of the item at a wider tier finds this comment and updates it in place through its acceptance ([dev-start.md](dev-start.md) § Close The Round's Stages). Write `[WT_PATH]/tmp/completion-summary-[ISSUE_ID].md` under a `## Completion Summary` heading: the commit `git -C [WT_PATH] log -1 --oneline` prints, one line per committed path saying what changed, and the commit chain as what checked it. Post it at once, so it is on the item before any lane lands the change:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file [WT_PATH]/tmp/completion-summary-[ISSUE_ID].md
   ```

   A rate-limited post is held under the linear skill's `patterns/workflow-actions.md` § Quota Holds.

7. **Record the directive as the acceptance.** **Skip if** the item is a tracker item. A directed change's round is closed under the owner's directive before anything is pushed, so the record of who accepted the change stands before the change leaves the checkout. Write `[WT_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "dev"}` and run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WT_PATH]/tmp/orch-op-[ISSUE_ID].json
   ```

   `[ROUND_ID]` is the reply's `.result.report.round_id`. Then write the same file as `{"op": "accept-result", "round_id": "[ROUND_ID]", "outcome": "pass", "authorization": {"by": "owner-directive", "id": "[ID]"}}` and run the same command. The runtime refuses a close on a `directive-[ID]` item that names no directive, or another one, as `authorization-missing`, and a repeat naming another as `authorization-differs`; `orch-runtime state inspect --item [ISSUE_ID]` shows the recorded acceptance. Continue to § 3.

## 3. Push And Open The PR

`ORCH_DELIVERY=push-base` takes [submit-pr.md § 2.1](submit-pr.md#21-base-publication) through the shared entry below, which stops an item with an open post-merge box. It runs this tier's commit hooks and final path check before the base push. A wider tier stops before transport and takes § Escape condition 3. On successful direct delivery, restore the main checkout as below, then go to § 5. Report `[PUSHED_SHA]` and `[BASE]` in place of the PR and merge rows. Skip § 4.

**Run Workflow**: `⤵ workflows/submit-pr.md § 2 steps 1-4 → § 3 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`. That range owns the push and its `sha-reconcile:` routing, and the create. The body is the three lines below rather than step 3's template. No headings and no other section. A directed change's third line is `Directive [ID]`: there is no item to close.

```markdown
[What the change does, in one sentence.]
[What checked it, in one sentence.]
Closes [ISSUE_REF]
```

`[ISSUE_TITLE]` for the create comes from the § 1 read; for a directed change it is the directive's first line. **Main checkout only**, return to the base branch after publication:

```bash
git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]
```

## 4. Arm And Wait

Bind what [merge-pr.md](merge-pr.md) § 1 binds once per run, which its §§ 4-7 consume and this entry skips. `[MAIN_REPO_ROOT]` is § 1's here, and `[ALREADY_MERGED]` is unset. The directory is where every stop in that range renders its comment:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE auto-recommended
```

```bash
mkdir -p [MAIN_REPO_ROOT]/tmp
```

The pull request's recorded base can trail the base branch's tip: the harness-ci skill's `wiring.md` reference, § The endpoint expressions. Read that recorded base and the head through the GitHub skill and bind them as `[BASE_SHA]` and `[HEAD_SHA]`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-view [PR_NUMBER] --json baseRefOid,headRefOid
```

Check the pushed paths through `item-tier`:

```bash
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/item-tier --base [BASE_SHA] --head [HEAD_SHA] --repo [WT_PATH]
```

The accepted answer is `tier=micro`. Over a range the script reads the path rules alone, the class of § Escape condition 3, and never a line count: the tier the admission read stands, and this check proves the pushed paths stayed inside it. A path rule that selects `small` or `standard`, or a command failure, escapes (§ Escape condition 6).

Bind `[REVIEW_BASE_CHECKOUT]` to the consumer base, per [Gate-mode routing](../references/gates.md#gate-mode-routing), and read its mode through [the review call](../references/gates.md#the-review-call), run once from `[MAIN_REPO_ROOT]` with `[MARK_READY]` `false`. The call has no pure read: on `approval` it also settles the pushed head's Copilot request ([Copilot requests](../references/gates.md#copilot-requests)).

Continue only on `approval`. This tier runs no internal review, so the repository's required review is the one review the pull request gets: § 5 step 1's arm leaves it to GitHub, which holds the merge until the approval lands. `off`, a refusal or an `unreadable` reply escapes (§ Escape condition 6). An `off` mode ends the micro route without removing GitHub's approval requirement.

Ask the canonical merge gate for its readiness object before any merge attempt:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --check
```

Its JSON stdout is `[CHECK]`. Require a valid readiness object for an open pull request. A command failure, an unreadable object, or a non-open pull request escapes (§ Escape condition 6). A red required check or a merge conflict never reaches a merge: `pr-merge` refuses both, and § 5 step 1 routes that refusal.

**Run Workflow**: `⤵ workflows/merge-pr.md [PR_NUMBER] § 4-7 → § 5` with `[ISSUE]` as `[ISSUE_ID]`, `[PR_BRANCH]` as `[BRANCH]`, and `[STATE_KEY]` as `[ISSUE_ID]`, binding `[MICRO_ENTRY]` to `true` and `[MICRO_HEAD]` to `[HEAD_SHA]`. The class was checked over that head alone, so the head is what carries it across the handoff: § 5 step 1 refuses a prepared head that is not this one.

Its § 3 is skipped, so nothing waits on a reviewer before § 5 step 1, and only that step's CI wait, ahead of its direct attempt, waits on CI. § 5 step 1 then attempts the prepared head and owns the queue wait to a terminal verdict. Read `ci-classify-refusal --help` for the output and retry contract. A refusal it marks `retry: same-head` is retried on that head by re-entering the step under [merge-attempt.md § Exit routing](../references/merge-attempt.md#exit-routing)'s bound and is not an escape; its limit stop ends the run as a merge-pr verdict. Any other refusal returns to its § 3.2, which reads the `[CHECK]` object only the skipped § 3 produces. That return escapes (§ Escape condition 7).

A `dequeued` verdict routes to that step's late-findings triage. A wording, naming or index finding there or at § 5 step 1's pre-arm [thread read](../references/thread-read.md) is answered by reply, per [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow). A finding that needs a change is judged by the paths the fix touches, never by a new class:

- A fix inside the paths the admission admitted keeps the tier. Make it through § 2 steps 2 to 5 on this branch, push it through § 3's submit-pr range, whose step 2 finds the open pull request, then re-enter this section from its top on the new head: `[HEAD_SHA]` and `[MICRO_HEAD]` rebind, and the only review the new head gets is the repository's own.
- A fix that needs a path outside the admitted set asks the admission for it before any edit. A lane asks through its ask route ([skill-rules.md § Lane asks](../references/skill-rules.md#lane-asks)), since the fleet state is the control host's, and the overseer judges the path against the fleet's holders through `orch-runtime admit`, the admission every launch meets ([oversee.md § 2 Select Work](oversee.md#2-select-work)), which widens the lane's record or refuses; the overseer's own run admits a path the directive's change needs and nothing else. A refused path, or a path condition 3 excludes, escapes (condition 5).

## 5. Return

Output: [Lane Output](../references/skill-rules.md#lane-output). The § 1 control-host refusal is the one return that is not this table: it returns its own two-line report.

<output_format>

### MICRO — [ISSUE_ID]: [TITLE]

| Metric | Value |
|--------|-------|
| PR | #[PR_NUMBER] |
| Merge | [MERGE_SHA] or the merge-pr verdict that stopped it |
| Dev phase | [MINUTES], against the § Budget target for the route |
| Checkout | the branch the main checkout ends on, or `lane` |
| Escaped | no, or the § Escape condition and the handback it names |

</output_format>

## Escape

The tier holds only while the item and its change stay inside it. Each condition below ends the run:

1. § 1 read a container, a blocked child, or a bundle. This tier implements one item's own Done-when and nothing else.
2. The repository's commit chain is not armed, or the answer could not be read.
3. The edit reached a path the shared path rules refuse this tier. The rules are the `path` lines of [change-scope's narrow-change.conf](../../change-scope/references/narrow-change.conf), which `item-tier` reads through `lib/change-class.sh`, the same list `change-scope` classifies a pull request by: the files that gate a merge, run in a commit or turn hook, enforce a guard rule, decide whether validation runs or launch a lane; this workflow, [small.md](small.md), [oversee.md](oversee.md) and `item-tier` itself; the `# [boundary]` group of what change classification reads or runs; the surfaces a harness or a review bot loads on its own; and the lock-format, manifest-parser and render-inventory paths the wider `small` class refuses too. Every `path` line escapes this tier except one a `superseded` line names, kept for an older reader and skipped by this one, so a reader checks a path against every other `path` line. Its `instruction` lines, `AGENTS.md` and `SKILL.md` at any depth, answer `small` where a diff would earn micro, so an edit reaching one escapes too. The repository adds its own refusals through `HARNESS_CI_STANDARD_PATHS` in the main checkout's settings, which `item-tier` floors at `standard`; that declaration is the repository's risk and stays its own. The conf also carries this tier's production ceiling, which `item-tier` selects on for a launch estimate and never for a branch. § 2 step 4 reads the changed paths against this class.
4. The commit chain refuses the commit over a repository rule. A missing changelog fragment and a rejected commit message are this workflow's own to fix and are not escapes.
5. A review finding on the pull request needs a path the admission refused, or a change condition 3 excludes.
6. § 4 cannot prove all three parts of its precheck. Either the `item-tier` answer is not `tier=micro`, or the review call's `mode` is not `approval`, or `pr-merge --check` returns no valid readiness object for an open pull request.
7. merge-pr.md § 5 step 1 returns to its § 3.2: the refusal's cause carries no `retry: same-head` line, a set that holds `ci_pending` and `fetch_error` beside the causes that need a change or a reader. A refusal retried on the same head is not this condition.
8. merge-pr.md § 5 step 1 refuses: the `item-tier` answer it reads over the prepared endpoints is not `tier=micro`, or the gate mode its review call reads is not `approval`, or `[PREPARED_HEAD]` is not `[MICRO_HEAD]`. The endpoints moved between § 4's checks and that step: by a push this run did not make, or by a retarget that changes the class without moving the head. A fix this run pushed re-enters § 4 first (its last paragraph), so it is not this condition.
9. The [review call](../references/gates.md#the-review-call)'s `request` ([Copilot requests](../references/gates.md#copilot-requests)) falls back `cause=no-files` for the pushed head, which then needs an internal review before fallback approval.

The § 1 control-host refusal also ends the run, before any condition above can apply. It is not an escape: the item stays at the `micro` tier and launches as a hosted lane.

Ending the run leaves the branch and its commits where they stand and reports the condition in § 5. **Main checkout only**, use the route below before reporting. It owns the base-branch restore this file opens with.

A directed change carries neither its branch nor its pull request over (§ Items). The overseer files the item through [oversee-events.md § File one item alone](../references/oversee-events.md#file-one-item-alone); the input file's `description` holds the directive's text and, after it in a fenced `diff` block so its lines stay lines, the change as made. The change is `git -C [MAIN_REPO_ROOT] diff [BASE_BRANCH]...[BRANCH]` once a commit stands (conditions 3 and 5 to 9), `git -C [MAIN_REPO_ROOT] diff --cached` for the edit condition 4 leaves staged, and nothing at condition 2, which precedes the edit. Where a pull request exists (conditions 5 to 9), close it, which deletes its branch on GitHub and in the checkout: `env -u GH_REPO -u GITHUB_REPOSITORY gh pr close [PR_NUMBER] --delete-branch`. Otherwise, once the diff stands on the item, return the checkout to `[BASE_BRANCH]` and delete the branch: at condition 4 `git -C [MAIN_REPO_ROOT] reset --hard` first, which drops the staged edit; then `git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]` and `git -C [MAIN_REPO_ROOT] branch -D [BRANCH]`. The filed item launches as a lane through [oversee.md § 3 Lane directive](oversee.md#lane-directive), at the tier § Item Tier there assigns its body, never through the routes below and never on the control host ([SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes). Its lane starts from the item's own key ([start-worktree.md](start-worktree.md) § 1, [small.md](small.md) § 1) and reads `review_floor` under that key alone ([review-pr.md](review-pr.md) § 1), so the directive's run records no floor: a `fallback cause=no-files` on the lane's head is the lane's own condition 9, recorded and relaunched under the item's key.

At condition 9, a tracker item records the promised round as the review floor [review-pr.md](review-pr.md) § 1 passes to `review-depth`, so a micro-class diff still gets a reviewed depth:

```bash
.agents/skills/orch/scripts/orch-runtime state set --item [ISSUE_ID] /review_floor small
```

Then set `[BRIEF]` to `small` and relaunch as `/orch small [ISSUE_ID]`: run one internal review round, then take the fallback approval in [copilot-head-notices.md § Fallback approval](../references/copilot-head-notices.md#fallback-approval) without another Copilot request. For every other condition, the item relaunches at the next class up, as [oversee.md](oversee.md) § Item Tier assigns it from the branch's state; `[BRIEF]` is that assignment's `brief=` word. A directed change takes the paragraph above and none of the routes below. Use the route the checkout leaves a tracker item on:

- **In a lane**, run `/orch [BRIEF] [ISSUE_ID]`. `small` runs [small.md](small.md), and `start` routes a worktree cwd to [start-worktree.md](start-worktree.md) ([start.md](start.md) § 1 step 3). Either session's § 1 resolves the item from the existing branch, and its § 2 implements against it.
- **From the main checkout at condition 1**, no branch was cut: the item takes plain `/orch [BRIEF] [ISSUE_ID]`.
- **From the main checkout at conditions 2 through 4**, the branch is local-only and can be dirty. Transfer it through the worktree owner's guarded path, which restores the main checkout to its default branch and moves staged, unstaged and untracked changes with the branch. Run `/orch [BRIEF] [ISSUE_ID]` from the path it prints:

  ```bash
  .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --transfer [BRANCH]
  ```

- **From the main checkout at conditions 5 through 9**, the branch was pushed. Restore `[BASE_BRANCH]`, then attach the remote branch with `--pr [PR_NUMBER]` when the pull request exists, or `--base [BRANCH]` before it exists. Run `/orch [BRIEF] [ISSUE_ID]` from the path the command prints:

  ```bash
  git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]
  ```

  ```bash
  .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --pr [PR_NUMBER]
  ```

  ```bash
  .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --base [BRANCH]
  ```

A run never continues past its own escape, and never re-enters this workflow for the same item.
