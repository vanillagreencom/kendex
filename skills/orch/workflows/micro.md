# Micro Workflow

The tier for an item estimated to change a few lines. One agent reads the item, edits, commits, pushes, opens the pull request and waits the merge out: no dev subagent, no review cycle, no QA cycle, and no full validation battery. [oversee.md](oversee.md) § Item Tier picks the tier through `item-tier`, and § 4 checks the changed paths through that script. A `small` item runs [small.md](small.md); every other item runs [start.md](start.md).

| Command | Flow |
|---------|------|
| `micro [ISSUE_ID]` | § 1 → § 5 |
| `micro github OWNER/REPO#N` | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |

The runner is a lane in the item's worktree, or the overseer in the main checkout with no worktree for the item. `[WT_PATH]` is that checkout's root throughout. Steps marked **Main checkout only** are the second route's alone. A lane never waits on the overseer for a step this workflow permits: [skill-rules.md § Coordination](../references/skill-rules.md#coordination), Lane asks.

**Main checkout only.** The run returns that checkout to `[BASE_BRANCH]` before it reports anything: at § 3, at an escape, and at any stop in between. The supported transfer in § Escape moves the item's branch and any uncommitted edit into its worktree first. The fleet runs its merge handling in that checkout at every merge ([oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds), `merged`), and `sync-base` refuses a tracked-dirty tree. § 5 reports the branch the checkout ends on.

## Budget

§ 1 through § 3 take about 8 minutes in a lane and about 3 in the overseer's own session. A run past that target finishes and reports the overrun in § 5.

## 1. Open The Session

In a lane whose brief names a status file, `tmp/lane-status-[ISSUE_ID].md`, write it before this section's first command, and rewrite it at each step change, holding what the brief names.

**Main checkout only.** Read the lane host before anything else:

```bash
.agents/skills/orch/scripts/lane-host resolve
```

Any answer but `local` refuses the run here, with nothing read, activated or changed; [SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes, holds the rule. The report's first line is `micro-control-host host=[HOST]`, and its next line is the fix: launch the item as a hosted lane through [oversee.md](oversee.md) § 3 Lane directive, Placement, with its `/orch micro [ISSUE_ID]` brief.

Resolve `TRACKER` and `ISSUE_REF` from `[ISSUE_ID]` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution), then the main checkout:

```bash
.agents/skills/orch/scripts/git-context common-root .
```

Its output is `[MAIN_REPO_ROOT]`. Read the item. Linear:

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

**Main checkout only.** Sync the base, whose name the command prints as `[BASE_BRANCH]`, then cut the normalized issue branch as `[BRANCH]`, the lowercased issue id. That spelling is what the ownership scan in `worktree create` matches, so a later run reads the branch as owning the item:

```bash
.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
```

```bash
git -C [MAIN_REPO_ROOT] checkout -b [BRANCH]
```

In a lane worktree the branch already exists: gate on base freshness through [start-worktree.md](start-worktree.md) § 1 step 6 instead, and stop on its failure.

Read the branch both routes now stand on and initialize the item's workflow state with it. Its output binds `[BRANCH]` on the lane route, where nothing has named the branch yet, and confirms it on the other. `[BRANCH]` is the only name this workflow gives that branch, including § 4's `[PR_BRANCH]`:

```bash
.agents/skills/orch/scripts/git-context branch [WT_PATH]
```

`init` overwrites, and a restarted item's state file carries its round history, so read existence first:

```bash
.agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
```

`exists` false → initialize:

```bash
.agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --worktree [WT_PATH] --branch "[BRANCH]"
```

`exists` true → keep the state and record where this run stands:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] worktree "[WT_PATH]"
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] branch "[BRANCH]"
```

## 2. Edit And Commit

1. **Confirm the commit chain is armed**, before any file changes. That chain is this tier's whole validation: the diff-scoped guard rather than `DEV_VALIDATE_CMD`. An unarmed or unreadable answer escapes (§ Escape condition 2). Where the `commit-guards` package is installed this verb answers it and this workflow asks no other; elsewhere the project's own setup instructions name the verb.

   ```bash
   .agents/skills/commit-guards/scripts/install-git-hooks --check --repo [WT_PATH]
   ```

2. **Make the edit** the item's Done-when states. Nothing else enters the diff.

3. **Check each claim the diff states about code**, once. **Skip if** no changed sentence states what a file, script, setting or test does, holds, counts or refuses. Otherwise read each such sentence against the file it names, judged as [reviewer/SKILL.md](../../reviewer/SKILL.md) § Ethos judges a claim and a number in prose, and fix a false one in this edit. This tier runs no review cycle, so the pull request's review is the first reader of the claim, and a fix for a finding there moves the head and escapes (§ Escape condition 8).

4. **Read the changed paths against § Escape condition 3**:

   ```bash
   git -C [WT_PATH] status --porcelain
   ```

   Every path that listing names is in scope, tracked change and untracked addition alike. Commit a path the edit did not make elsewhere, or remove it, before step 5. If a path is in condition 3's class, record escape condition 3 but continue through step 5. A successful commit then escapes. This ordering leaves a local commit that the standard workflow can continue.

5. **Commit the paths by name**, never `-A`, so the committed set is the one step 4 read. `[PREFIX]` is the Conventional Commits type the change is; the commit-msg hook judges it and the header's length. The repository's changelog rule applies as to any commit, and a refusal from the chain is its answer.

   ```bash
   git -C [WT_PATH] add [PATH]...
   ```

   ```bash
   git -C [WT_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
   ```

   A successful commit with escape condition 3 recorded escapes now. Any other successful commit continues to § 3. A repository-rule refusal escapes as condition 4 with the staged edit still present; § Escape transfers that exact state.

## 3. Push And Open The PR

**Run Workflow**: `⤵ workflows/submit-pr.md § 2 steps 1-4 → § 3 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`. That range owns the push and its `sha-reconcile:` routing, and the create. The body is the three lines below rather than step 3's template. No headings and no other section.

```markdown
[What the change does, in one sentence.]
[What checked it, in one sentence.]
Closes [ISSUE_REF]
```

`[ISSUE_TITLE]` for the create comes from the § 1 read. **Main checkout only**, return to the base branch now that the pull request holds the work:

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

Read the pull request's exact endpoints through the GitHub skill and bind them as `[BASE_SHA]` and `[HEAD_SHA]`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-view [PR_NUMBER] --json baseRefOid,headRefOid
```

Check the changed paths through `item-tier`:

```bash
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/item-tier --base [BASE_SHA] --head [HEAD_SHA] --repo [WT_PATH]
```

The accepted answer is `tier=micro`. A path rule that selects `small` or `standard`, or a command failure, escapes (§ Escape condition 6). The measured line count cannot change the tier.

Bind `[REVIEW_BASE_CHECKOUT]` to the consumer base and resolve its mode, per [Gate-mode routing](../references/gates.md#gate-mode-routing):

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/approval-wait [PR_NUMBER] --resolve-mode --base-checkout [REVIEW_BASE_CHECKOUT]
```

Continue only on `approval`. This tier runs no internal review, so a GitHub approval is the one review the pull request gets: § 5 step 1's arm leaves it to GitHub, which holds the merge until the approval lands. `off` or a non-zero exit escapes (§ Escape condition 6). An `off` mode ends the micro route without removing GitHub's approval requirement.

Ask the canonical merge gate for its readiness object before any merge attempt:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --check
```

Its JSON stdout is `[CHECK]`. Require a valid readiness object for an open pull request. A command failure, an unreadable object, or a non-open pull request escapes (§ Escape condition 6). A red required check or a merge conflict never reaches a merge: `pr-merge` refuses both, and § 5 step 1 routes that refusal.

**Run Workflow**: `⤵ workflows/merge-pr.md [PR_NUMBER] § 4-7 → § 5` with `[ISSUE]` as `[ISSUE_ID]`, `[PR_BRANCH]` as `[BRANCH]`, and `[STATE_KEY]` as `[ISSUE_ID]`, binding `[MICRO_ENTRY]` to `true` and `[MICRO_HEAD]` to `[HEAD_SHA]`. The class was measured over that head alone, so the head is what carries it across the handoff: § 5 step 1 refuses a prepared head that is not this one.

Its § 3 is skipped, so nothing waits on a reviewer before § 5 step 1, and only that step's CI wait, ahead of its direct attempt, waits on CI. § 5 step 1 then attempts the prepared head and owns the queue wait to a terminal verdict. A refusal `ci-classify-refusal` marks `retry: same-head`, such as GitHub still computing mergeability, is retried on that head by re-entering the step under [merge-attempt.md § Exit routing](../references/merge-attempt.md#exit-routing)'s bound and is not an escape; its limit stop ends the run as a merge-pr verdict. Any other refusal returns to its § 3.2, which reads the `[CHECK]` object only the skipped § 3 produces. That return escapes (§ Escape condition 7).

A `dequeued` verdict routes to that step's late-findings triage. A finding there that needs a change § Escape excludes ends this run at the escape instead. A wording, naming or index finding there or at § 5 step 1's pre-arm [thread read](../references/thread-read.md) is answered by reply, per [finding-disposition.md § Decision flow](../references/finding-disposition.md#decision-flow): a fix push at either moves the head and escapes (§ Escape condition 8).

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
3. The edit reached a file that gates a merge, runs in a commit or turn hook, enforces a guard rule, launches a lane, or sets this tier's own boundary: this workflow, [small.md](small.md), [oversee.md](oversee.md) § Item Tier and the `item-tier` script it runs, `install-git-hooks`, and the shared path rules, whose files are the `# [boundary]` group of [references/narrow-change.conf](../references/narrow-change.conf) under the rule that group states. § 2 step 4 reads the changed paths against this class. [references/narrow-change.conf](../references/narrow-change.conf) holds that class as globs a script can read, together with the lock-format, manifest-parser and render-inventory paths the wider `small` class also refuses; every `path` line there escapes this tier except one a `superseded` line names, which is kept for older readers and skipped as the list's header states, so a reader checks a path against every other `path` line. Its `instruction` lines name the agent instruction files, `AGENTS.md` and `SKILL.md` at any depth: an edit reaching one answers `small` where it would earn micro, so it escapes this tier too. It also carries this tier's production ceiling, which `item-tier` selects on.
4. The commit chain refuses the commit over a repository rule. A missing changelog fragment and a rejected commit message are this workflow's own to fix and are not escapes.
5. A review finding on the pull request needs a change condition 3 excludes.
6. § 4 cannot prove all three parts of its precheck. Either the `item-tier` answer is not `tier=micro`, or `approval-wait --resolve-mode` does not print `approval`, or `pr-merge --check` returns no valid readiness object for an open pull request.
7. merge-pr.md § 5 step 1 returns to its § 3.2: the refusal's cause carries no `retry: same-head` line, a set that holds pending CI and an unreadable GitHub answer beside the causes that need a change or a reader. A refusal retried on the same head is not this condition.
8. merge-pr.md § 5 step 1 refuses: the `item-tier` answer it reads over the prepared endpoints is not `tier=micro`, or the gate mode it resolves is not `approval`, or `[PREPARED_HEAD]` is not `[MICRO_HEAD]`. The endpoints moved between § 4's checks and that step, by a push, or by a retarget that changes the class or moves the pull request onto a base that requires no approval without moving the head.

The § 1 control-host refusal also ends the run, before any condition above can apply. It is not an escape: the item stays at the `micro` tier and launches as a hosted lane.

Ending the run leaves the branch and its commits where they stand and reports the condition in § 5. **Main checkout only**, use the route below before reporting. It owns the base-branch restore this file opens with.

The item then relaunches at the next class up, as [oversee.md](oversee.md) § Item Tier assigns it from the branch's state, by the route the checkout leaves it on. `[BRIEF]` is that assignment's `brief=` word:

- **In a lane**, run `/orch [BRIEF] [ISSUE_ID]`. `small` runs [small.md](small.md), and `start` routes a worktree cwd to [start-worktree.md](start-worktree.md) ([start.md](start.md) § 1 step 3). Either session's § 1 resolves the item from the existing branch, and its § 2 implements against it.
- **From the main checkout at condition 1**, no branch was cut: the item takes plain `/orch [BRIEF] [ISSUE_ID]`.
- **From the main checkout at conditions 2 through 4**, the branch is local-only and can be dirty. Transfer it through the worktree owner's guarded path, which restores the main checkout to its default branch and moves staged, unstaged and untracked changes with the branch. Run `/orch [BRIEF] [ISSUE_ID]` from the path it prints:

  ```bash
  .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --transfer [BRANCH]
  ```

- **From the main checkout at conditions 5 through 8**, the branch was pushed. Restore `[BASE_BRANCH]`, then attach the remote branch with `--pr [PR_NUMBER]` when the pull request exists, or `--base [BRANCH]` before it exists. Run `/orch [BRIEF] [ISSUE_ID]` from the path the command prints:

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
