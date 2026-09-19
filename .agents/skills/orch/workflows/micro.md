# Micro Workflow

The tier for an item whose whole change is a few lines. One agent reads the item, edits, commits, pushes, opens the pull request and waits the merge out: no dev subagent, no review cycle, no QA cycle, and no full validation battery. [oversee.md](oversee.md) § Item Tier picks the tier; every other item runs [start.md](start.md).

| Command | Flow |
|---------|------|
| `micro [ISSUE_ID]` | § 1 → § 5 |
| `micro github OWNER/REPO#N` | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |

The runner is a lane in the item's worktree, or the overseer in the main checkout with no worktree for the item. `[WT_PATH]` is that checkout's root throughout. Steps marked **Main checkout only** are the second route's alone.

## Budget

§ 1 through § 3 take about 8 minutes in a lane and about 3 in the overseer's own session. A run past that target finishes and reports the overrun in § 5. The tier was wrong for that shape of item, which is a fact for the next sizing rather than a reason to abandon a branch.

## 1. Open The Session

Resolve `TRACKER` and `ISSUE_REF` from `[ISSUE_ID]` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution), then the main checkout:

```bash
.agents/skills/orch/scripts/git-context common-root .
```

Its output is `[MAIN_REPO_ROOT]`. Read the item. Linear:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --with-bundle
```

```bash
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID]
```

GitHub:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,labels,url
```

A container, a blocked child, or a bundle escapes here: this tier implements one item's own Done-when and nothing else.

**Main checkout only.** The checkout returns to the base branch in § 3, because the overseer's own base-checkout work reads that branch: [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds) runs `sync-base`, `post-merge` and [consumer-train.md](consumer-train.md) there at every merge. Sync the base, whose name the command prints as `[BASE_BRANCH]`, then cut the normalized issue branch — the spelling `worktree create --help` § Resolution defines, so that `worktree push` resolves this checkout by it:

```bash
.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
```

```bash
git -C [MAIN_REPO_ROOT] checkout -b [ISSUE_BRANCH]
```

In a lane worktree the branch already exists: gate on base freshness through [start-worktree.md](start-worktree.md) § 1 step 5 instead, and stop on its failure.

Initialize the item's workflow state, whose key every waiter below binds with `--item`:

```bash
.agents/skills/orch/scripts/workflow-state init [ISSUE_ID] --worktree [WT_PATH] --branch [BRANCH]
```

## 2. Edit And Commit

Make the edit the item's Done-when states. Nothing else enters the diff.

The commit runs the project's own commit chain, and that chain is the whole of this tier's validation: the diff-scoped guard rather than `DEV_VALIDATE_CMD`. The repository's changelog rule applies as it does to any commit, and a refusal from the chain is its answer, never something to bypass.

So the chain has to be armed in the repository's Git hooks before the edit, and an unarmed or unmeasurable chain escapes: nothing else in this tier would judge the change. Where the `commit-guards` package is installed, its `install-git-hooks --check` verb answers the question and this workflow asks no other; elsewhere the project's own setup instructions name the verb.

```bash
git -C [WT_PATH] add -A
```

```bash
git -C [WT_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
```

Measure the branch against the allowance that selected the tier:

```bash
.agents/skills/orch/scripts/branch-size-check --worktree [WT_PATH] --issue [ISSUE_ID] --json
```

Verdict `pass` or `allowance_missing` continues to § 3. Verdict `over` escapes. Exit 3 means a malformed `**Expected delta**` line and exit 2 a usage or environment failure; both stop the run and report, and neither is an escape, because nothing was measured.

## 3. Push And Open The PR

```bash
.agents/skills/orch/scripts/worktree-push --worktree [WT_PATH] --issue [ISSUE_ID] --set-upstream
```

Route its exit code and its `sha-reconcile:` line by `worktree-push --help`.

Write the body with the harness file-write tool, never redirection or a heredoc, at `[WT_PATH]/tmp/pr-body-[ISSUE_ID]-[TIMESTAMP].md` (`git-context timestamp compact`), and use that path as `BODY_FILE`. Three lines, no headings and no other section:

```markdown
[What the change does, in one sentence.]
[What checked it, in one sentence.]
Closes [ISSUE_REF]
```

```bash
.agents/skills/github/scripts/github.sh -C [WT_PATH] pr-create --title "[PREFIX]([ISSUE_ID]): [ISSUE_TITLE]" --body-file [BODY_FILE]
```

`[ISSUE_TITLE]` comes from the § 1 read. **Main checkout only**, return to the base branch now that the pull request holds the work, before anything waits on it:

```bash
git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]
```

## 4. Arm And Wait

**Run Workflow**: `⤵ workflows/merge-pr.md [PR_NUMBER] § 4-7 → § 5` with `[ISSUE]` as `[ISSUE_ID]`, `[PR_BRANCH]` as this branch, and `[STATE_KEY]` as `[ISSUE_ID]`.

Its § 3 is skipped, so nothing waits on CI or on a reviewer before the arm: § 5 step 1 attempts the prepared head, arms auto-merge on the `ci_pending` refusal, and owns the queue wait to a terminal verdict. GitHub holds that arm until the repository's own merge gates pass, so the review gate this tier does not wait on still decides whether the pull request lands.

A `dequeued` verdict routes to that step's late-findings triage. A finding there that needs a change § Escape excludes ends this run at the escape instead.

## 5. Return

<output_format>

### MICRO — [ISSUE_ID]: [TITLE]

| Metric | Value |
|--------|-------|
| PR | #[PR_NUMBER] |
| Merge | [MERGE_SHA] or the merge-pr verdict that stopped it |
| Size | [PRODUCTION] production, [TEST] test lines |
| Dev phase | [MINUTES], against the § Budget target for the route |
| Escaped | no, or the § Escape condition and the handback to /orch start [ISSUE_ID] |

</output_format>

## Escape

The tier holds only while the item and its change stay inside it. Each condition below ends the run:

1. § 1 read a container, a blocked child, or a bundle. This tier implements one item's own Done-when and nothing else.
2. The repository's commit chain is not armed, or the answer could not be read.
3. The edit reached a file that gates a merge, runs in a commit or turn hook, enforces a guard rule, or launches a lane. Those files carry the review this tier does not run.
4. The commit chain refuses the commit over a repository rule. A missing changelog fragment and a rejected commit message are this workflow's own to fix and are not escapes.
5. `branch-size-check` reports `over`.
6. A review finding on the pull request needs a change condition 3 or 5 excludes.

Ending the run leaves the branch and its commits where they stand and reports the condition in § 5. **Main checkout only**, return to the base branch first, so nothing holds the item's branch:

```bash
git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]
```

The item then goes to `/orch start [ISSUE_ID]`, which picks that branch up and reviews it. A branch or an open pull request already owns the item, so that run reaches [start.md](start.md) § 4 as the owning session and reuses the branch rather than creating one. A run never continues past its own escape, and never re-enters this workflow for the same item.
