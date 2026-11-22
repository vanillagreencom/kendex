# Micro Workflow

The tier for a change of a few lines. One agent reads the item, edits, commits, pushes, opens the pull request and arms it. No dev subagent, review cycle, QA cycle or validation battery runs. [oversee.md](oversee.md) § Item Tier assigns the tier through `orch-runtime tier`. A `small` item runs [small.md](small.md); every other item runs [start.md](start.md).

| Command | Flow |
|---------|------|
| `micro [ISSUE_ID]` | § 1 → § 5 |
| `micro github OWNER/REPO#N` | normalize to `ISSUE_ID=issue-N`, then § 1 → § 5 |
| `micro directive-[ID]` | the owner's directed change, § Items: § 1 → § 5 in the overseer's own checkout |

## Items

A tracker item reaches this tier at its launch.

- Its runner is a lane in the item's worktree, or the overseer in the main checkout of a local fleet with no lane free.
- On a hosted fleet it runs as a lane only; § 1 refuses the main-checkout route on the control host.

An owner-directed small change, such as a settings line or a few lines of Markdown, has no tracker item.

- Its key is `directive-[ID]`, where `[ID]` is the id of the owner's note that directed it ([oversee-events.md § `owner-note`](../references/oversee-events.md#owner-note)).
- The overseer makes it in its own checkout, on the control host or local, with no lane and no internal review.
- The directive is the acceptance, which § 2 step 7 records on the item's round.
- The repository's own rules still apply: its commit chain, its required review and checks, and the paths § Escape condition 3 refuses.

The cost of the check decides whether the overseer or a lane makes a change, never the kind of file.

- A change the commit chain checks in its diff-scoped pass is this tier's.
- A change whose check needs a build or a test run takes a lane in its own sandbox. A lane is keyed by a tracker item, so `directive-[ID]` never runs as a lane.
  - The overseer files the change as a tracker item from the directive, as it files an item an `owner-note` asks for ([oversee-events.md § File one item alone](../references/oversee-events.md#file-one-item-alone)).
  - That item launches under its own key, at the tier [oversee.md](oversee.md) § Item Tier assigns it, with neither the directive's branch nor its pull request. Its lane makes the change again from the item.

The admission that launched the run reads the tier once, and the tier floors the run. The admission judges a later edit by the paths it touches. § 4 reads the class of the pushed range, its production lines included.

- `[WT_PATH]` is the running checkout's root throughout.
- A step marked **Main checkout only** runs on the main-checkout route alone, the directed change included.
- A lane never waits on the overseer for a step this workflow permits ([skill-rules.md § Lane asks](../references/skill-rules.md#lane-asks)).

**Main checkout only.** The run returns that checkout to `[BASE_BRANCH]` before it reports anything: at § 3, at an escape, and at any stop in between.

- At an escape, the transfer in § Escape first moves the item's branch and any uncommitted edit into its worktree.
- § 5 reports the branch the checkout ends on.

## Budget

- § 1 through § 3 take about 8 minutes in a lane and about 3 in the overseer's own session.
- From the pull request on, the repository sets the time: its required checks and the review its ruleset requires.
- A run past the target finishes and reports the overrun in § 5.

## 1. Open The Session

In a lane whose brief names a status file, `tmp/lane-status-[ISSUE_ID].md`, write it before this section's first command. Rewrite it at each step change with what the brief names.

**Main checkout only.** Read the lane host before anything else:

```bash
.agents/skills/orch/scripts/orch-runtime host resolve
```

For a tracker item, any answer but `local` refuses the run here:

1. Read, activate or change nothing ([SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes).
2. Report `micro-control-host host=[HOST]` as the first line.
3. As the next line, report the fix: launch the item as a hosted lane through [oversee.md](oversee.md) § 3 Lane directive, Placement, with its `/orch micro [ISSUE_ID]` brief.

A directed change continues on any answer.

Resolve `TRACKER` and `ISSUE_REF` from `[ISSUE_ID]` per [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution). A directed change resolves to `TRACKER=none` with no `ISSUE_REF`. Its item is the directive's text, which names the file and the change.

Read the main checkout:

```bash
.agents/skills/orch/scripts/git-context common-root .
```

The output is `[MAIN_REPO_ROOT]`. Read a tracker item. **Linear only**:

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
```

```bash
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID]
```

The linear skill's `patterns/workflow-actions.md` § Quota Holds holds a rate-limited activation.

**GitHub only**:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,labels,url
```

A container, a blocked child or a bundle escapes here (§ Escape condition 1).

**Main checkout only.** Sync the base; the command prints its name as `[BASE_BRANCH]`. Then cut `[BRANCH]`, the item key in lower case:

```bash
.agents/skills/orch/scripts/sync-base [MAIN_REPO_ROOT]
```

```bash
git -C [MAIN_REPO_ROOT] checkout -b [BRANCH]
```

In a lane worktree the branch already exists. Gate on base freshness through [start-worktree.md](start-worktree.md) § 1 step 7 instead, and stop on its failure.

Read the branch both routes now stand on. On the lane route this read binds `[BRANCH]`; on the main-checkout route it confirms it. `[BRANCH]` is this workflow's one name for the branch, merge-pr's `[PR_BRANCH]` included:

```bash
.agents/skills/orch/scripts/git-context branch [WT_PATH]
```

Create the record unless it stands, by [start-worktree.md § 1](start-worktree.md#1-open-the-session) step 6 with `[WT_PATH]` as `[WORKTREE_PATH]`, up to its tier write. Then record this tier in place of `standard`:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-route","tier":"micro"}'
```

## 2. Edit And Commit

1. **Confirm the commit chain**, before any file changes. Read whether the main checkout's committed stage policy runs git hooks:

   ```bash
   .agents/skills/orch/scripts/orch-runtime validate policy --base-checkout [MAIN_REPO_ROOT] --stage git-hooks
   ```

   - `result.answer` `skip`: the repository runs no commit chain, and this step checks nothing more.
   - `run`: the chain is this tier's check, the diff-scoped guard in place of `DEV_VALIDATE_CMD`. Confirm it is armed. Where the `commit-guards` package is installed, this command answers; elsewhere the project's own setup instructions name the command:

   ```bash
   .agents/skills/commit-guards/scripts/install-git-hooks --check --repo [WT_PATH]
   ```

   A refused policy read, or a non-zero exit from the check, escapes (§ Escape condition 2).

2. **Make the edit** the item's Done-when, or the directive, states. Put nothing else in the diff.

3. **Check each claim the diff states about code**, once. **Skip if** no changed sentence states what a file, script, setting or test does, holds, counts or refuses.
   - Read each such sentence against the code that defines or implements what it states: the file it names, or the file a search for the setting, script or symbol it names finds, searched only where [skill-rules.md § File searches](../references/skill-rules.md#file-searches) permits.
   - Judge it as [reviewer/SKILL.md](../../reviewer/SKILL.md) § Ethos judges a claim and a number in prose: a claim no code makes true is false.
   - Fix a false claim in this edit.

4. **Read the changed paths against § Escape condition 3**:

   ```bash
   git -C [WT_PATH] status --porcelain
   ```

   - Every path the listing names is in scope, a tracked change and an untracked addition alike.
   - Before step 5, commit elsewhere, or remove, any path the edit did not make.
   - If a path is in condition 3's class, record escape condition 3 and continue through step 5. The commit then escapes, and the wider tier continues from that local commit.

5. **Commit the paths by name**, never `-A`, so the committed set is the one step 4 read. `[PREFIX]` is the Conventional Commits type of the change. The repository's changelog rule applies as to any commit, and a refusal from the chain is its answer.

   ```bash
   git -C [WT_PATH] add [PATH]...
   ```

   ```bash
   git -C [WT_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
   ```

   - A successful commit with escape condition 3 recorded escapes now.
   - Any other successful commit continues.
   - A refusal over a repository rule escapes as condition 4, with the staged edit still present; § Escape transfers that exact state.

6. **Post the completion summary**. **Skip if** `TRACKER` is GitHub or the item is keyed `directive-[ID]`. This comment is the item's one Completion Summary.
   - Write `[WT_PATH]/tmp/completion-summary-[ISSUE_ID].md` with the harness file tool, under a `## Completion Summary` heading.
   - It holds the commit `git -C [WT_PATH] log -1 --oneline` prints, one line per committed path saying what changed, and what checked it (step 1's answer).
   - Post it at once, before any lane lands the change:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file [WT_PATH]/tmp/completion-summary-[ISSUE_ID].md
   ```

   The linear skill's `patterns/workflow-actions.md` § Quota Holds holds a rate-limited post.

7. **Record the directive as the acceptance.** **Skip if** the item is a tracker item. A directed change's round closes under the owner's directive before anything is pushed.
   1. Write `[WT_PATH]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "begin-round", "kind": "dev"}` and run it:

      ```bash
      .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WT_PATH]/tmp/orch-op-[ISSUE_ID].json
      ```

   2. `[ROUND_ID]` is the reply's `result.report.round_id`. Write the same file as `{"op": "accept-result", "round_id": "[ROUND_ID]", "outcome": "pass", "authorization": {"by": "owner-directive", "id": "[ID]"}}` and run the same command.
   3. Continue to § 3.

## 3. Push And Open The PR

**Run Workflow**: `⤵ workflows/submit-pr.md § 2 steps 1-4 → § 3 tail` with context `worktree`, `lifecycle: "managed"`, `issue_id`.

`ORCH_DELIVERY=push-base` takes [submit-pr.md § 2.1](submit-pr.md#21-base-publication) from that range's entry.

- Its refusal of a wider tier takes § Escape condition 3.
- On a successful direct delivery, restore the main checkout as below and report `[PUSHED_SHA]` and `[BASE]` in place of the pull request and merge rows. Skip § 4 and go to § 5.

On the pull-request route, the body is the three lines below, in place of step 3's template, with no heading and no other section. A directed change has no item to close; its third line is `Directive [ID]`.

```markdown
[What the change does, in one sentence.]
[What checked it, in one sentence.]
Closes [ISSUE_REF]
```

`[ISSUE_TITLE]` for the create comes from the § 1 read. For a directed change it is the directive's first line.

**Main checkout only.** Return to the base branch after publication:

```bash
git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]
```

## 4. Arm And Wait

This entry skips [merge-pr.md](merge-pr.md) § 1 and § 3, so bind here what they bind once per run and its § 4-7 read. `[MAIN_REPO_ROOT]` is § 1's, and `[ALREADY_MERGED]` is unset. Read the decision mode:

```bash
.agents/skills/orch/scripts/orch-env ORCH_DECISION_MODE ask
```

Bind `[ITEM_DIR]` to the folder holding the record path this prints as `result.path`:

```bash
.agents/skills/orch/scripts/orch-runtime state path --item [ISSUE_ID]
```

Through the github skill, read the pull request's recorded base, not the base branch's tip, and its head. Bind them as `[BASE_SHA]` and `[HEAD_SHA]`:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-view [PR_NUMBER] --json baseRefOid,headRefOid
```

Check the pushed range's paths and production lines against the tier:

```bash
[MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime tier --base [BASE_SHA] --head [HEAD_SHA] --repo [WT_PATH]
```

The accepted answer is the line opening `tier=micro`. Any other `tier=` answer, or a refusal at exit 1 or 2, escapes (§ Escape condition 6).

1. Bind `[REVIEW_BASE_CHECKOUT]` to the consumer base per [Gate-mode routing](../references/gates.md#gate-mode-routing).
2. Read the gate mode through [the review call](../references/gates.md#the-review-call), run once from `[MAIN_REPO_ROOT]` with `[MARK_READY]` `false`. The call is not a pure read: under `approval` it also settles the pushed head's Copilot request ([Copilot requests](../references/gates.md#copilot-requests)).
3. Continue only on `approval`. `off`, a refusal or an `unreadable` reply escapes (§ Escape condition 6).

Ask the merge gate for its readiness object before any merge attempt:

```bash
env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/github/scripts/github.sh -C [MAIN_REPO_ROOT] pr-merge [PR_NUMBER] --check
```

Its JSON stdout is `[CHECK]`.

- Require a valid readiness object for an open pull request. A command failure, an unreadable object or a pull request that is not open escapes (§ Escape condition 6).
- A red required check or a merge conflict never reaches a merge: `pr-merge` refuses both, and merge-pr's § 5 step 1 routes that refusal.

**Run Workflow**: `⤵ workflows/merge-pr.md [PR_NUMBER] § 4-7 → § 5` with `[ISSUE]` as `[ISSUE_ID]`, `[PR_BRANCH]` as `[BRANCH]` and `[STATE_KEY]` as `[ISSUE_ID]`.

- Bind `[MICRO_ENTRY]` to `true` and `[MICRO_HEAD]` to `[HEAD_SHA]`; merge-pr's § 5 step 1 refuses a prepared head that is not this one.
- In a lane, merge-pr skips its § 5 steps 3 and 4, and the lane leaves its worktree standing.

This entry skips merge-pr's § 3. `ci-classify-refusal --help` states the refusal's output and retry contract.

- Retry a refusal marked `retry: same-head` on that head by re-entering the step, within [merge-attempt.md § Exit routing](../references/merge-attempt.md#exit-routing)'s bound; it is no escape. Its limit stop ends the run as a merge-pr verdict.
- Any other refusal returns to merge-pr's § 3.2, and that return escapes (§ Escape condition 7).

A `dequeued` verdict routes to that step's late-findings triage.

- Answer a wording, naming or index finding there, or at the step's [thread read](../references/thread-read.md), by reply ([finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow)).
- Judge a finding that needs a change by the paths the fix touches:

  - A fix inside the admitted paths keeps the tier while the range stays within the `micro` ceiling; past it, this section's tier check escapes the run (condition 6).
    1. Make it through § 2 steps 2 to 5 on this branch.
    2. Push it through § 3's submit-pr range, whose step 2 finds the open pull request.
    3. Re-enter this section from its top on the new head: `[HEAD_SHA]` and `[MICRO_HEAD]` bind again, and the new head gets only the repository's own review.
  - A fix that needs a path outside the admitted set asks the admission for it before any edit.
    - A lane asks through its ask route ([skill-rules.md § Lane asks](../references/skill-rules.md#lane-asks)).
    - The overseer judges the path against the fleet's holders through `orch-runtime admit` ([oversee.md § 2 Select Work](oversee.md#2-select-work)). The admission widens the lane's record or refuses.
    - The overseer's own run admits a path the directive's change needs and nothing else.
    - A refused path, or a path condition 3 excludes, escapes (condition 5).

## 5. Return

Output: [Lane Output](../references/skill-rules.md#lane-output). The § 1 control-host refusal is the one return outside this table; it returns its own two lines.

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

1. § 1 read a container, a blocked child or a bundle. This tier implements one item's own Done-when and nothing else.
2. § 2 step 1's policy read refused, or the policy runs `git-hooks` and the commit chain is not armed or its answer could not be read.
3. The edit reached a path the shared path rules refuse this tier: a `path` line of [change-scope's narrow-change.conf](../../change-scope/references/narrow-change.conf).
   - The conf's header states how its lines read: a `path` line a `superseded` line names does not refuse, and an `instruction` line answers `small` where a diff would earn micro.
   - The repository adds its own refusals through `HARNESS_CI_STANDARD_PATHS` in the main checkout's settings, which floor at `standard`.
   - § 2 step 4 reads the changed paths against this class.
4. The commit chain refuses the commit over a repository rule. A missing changelog fragment and a rejected commit message are this workflow's own to fix and are no escape.
5. A review finding on the pull request needs a path the admission refused, or a change condition 3 excludes.
6. § 4 cannot prove all three parts of its precheck: the `orch-runtime tier` answer is not `tier=micro`, or the review call's `mode` is not `approval`, or `pr-merge --check` returns no valid readiness object for an open pull request.
7. merge-pr.md § 5 step 1 returns to its § 3.2: the refusal's cause carries no `retry: same-head` line (`ci-classify-refusal --help`). A refusal retried on the same head is not this condition.
8. merge-pr.md § 5 step 1 refuses: the `orch-runtime tier` answer it reads over the prepared endpoints is not `tier=micro`, or the gate mode its review call reads is not `approval`, or `[PREPARED_HEAD]` is not `[MICRO_HEAD]`. A fix this run pushed re-enters § 4 first, so it is not this condition.
9. The [review call](../references/gates.md#the-review-call)'s `request` ([Copilot requests](../references/gates.md#copilot-requests)) falls back `cause=no-files` for the pushed head.

The § 1 control-host refusal also ends the run, before any condition above can apply. It is no escape: the item stays at the `micro` tier and launches as a hosted lane.

Ending the run leaves the branch and its commits where they stand; § 5 reports the condition. **Main checkout only**, take the route below before reporting. It carries out the base-branch restore § Items requires.

A directed change carries neither its branch nor its pull request over (§ Items). The overseer files the item through [oversee-events.md § File one item alone](../references/oversee-events.md#file-one-item-alone). The input file's `description` holds the directive's text and, after it, the change as made in a fenced `diff` block, so its lines stay lines:

- once a commit stands (conditions 3 and 5 to 9): `git -C [MAIN_REPO_ROOT] diff [BASE_BRANCH]...[BRANCH]`;
- for the edit condition 4 leaves staged: `git -C [MAIN_REPO_ROOT] diff --cached`;
- at condition 2, which comes before the edit: nothing.

Then, for the directed change:

1. Where a pull request exists (conditions 5 to 9), close it, which deletes its branch on GitHub and in the checkout: `env -u GH_REPO -u GITHUB_REPOSITORY gh pr close [PR_NUMBER] --delete-branch`.
2. Otherwise, once the diff stands on the item, return the checkout to `[BASE_BRANCH]` and delete the branch. At condition 4, first run `git -C [MAIN_REPO_ROOT] reset --hard`. Then run `git -C [MAIN_REPO_ROOT] checkout [BASE_BRANCH]` and `git -C [MAIN_REPO_ROOT] branch -D [BRANCH]`.
3. The filed item launches as a lane through [oversee.md § 3 Lane directive](oversee.md#lane-directive), at the tier § Item Tier there assigns its body. It never launches through the routes below, and never on the control host.
4. The directive's run records no `review_floor`.
5. A `fallback cause=no-files` on the filed item's lane head is that lane's own condition 9, recorded and relaunched under the item's key.

At condition 9, a tracker item records the promised round as the review floor [review-pr.md](review-pr.md) § 1 passes to `review-depth`:

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-route","review_floor":"small"}'
```

Then set `[BRIEF]` to `small` and relaunch as `/orch small [ISSUE_ID]`: one internal review round, then the fallback approval of [copilot-head-notices.md § Fallback approval](../references/copilot-head-notices.md#fallback-approval) with no further Copilot request.

At every other condition, the item relaunches at the next class up, as [oversee.md](oversee.md) § Item Tier assigns it from the branch's state. `[BRIEF]` is that answer's `brief=` word.

A directed change takes the directed-change steps above and none of the routes below. For a tracker item, take the route for where the checkout leaves it:

- **In a lane**, run `/orch [BRIEF] [ISSUE_ID]`. `small` runs [small.md](small.md), and `start` routes a worktree cwd to [start-worktree.md](start-worktree.md) ([start.md](start.md) § 1).
- **From the main checkout at condition 1**, no branch was cut. The item takes plain `/orch [BRIEF] [ISSUE_ID]`.
- **From the main checkout at conditions 2 through 4**, the branch is local only and can hold uncommitted changes. Move it through the worktree owner's guarded transfer. Run `/orch [BRIEF] [ISSUE_ID]` from the path it prints:

  ```bash
  .agents/skills/worktree/scripts/worktree create [ISSUE_ID] --transfer [BRANCH]
  ```

- **From the main checkout at conditions 5 through 9**, the branch was pushed. Restore `[BASE_BRANCH]`, then attach the remote branch with `--pr [PR_NUMBER]` where the pull request exists, or `--base [BRANCH]` before it exists. Run `/orch [BRIEF] [ISSUE_ID]` from the path the command prints:

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
