# Fix Lifecycle

Read [code-quality](../../code-quality/SKILL.md) before writing or modifying code, including for ad-hoc requests.

The workflow for a dev agent receiving a review-fix delegation. Run it first line to last for one round. Every path is worktree-scoped.

---

## 1. Read Context

Confirm the shell's real working directory is the delegation's `Worktree:` path before any repo-relative command, by the check at the top of [dev-implement.md](./dev-implement.md).

**Skip if** the delegation is ad-hoc: it carries no `Issue:` line, or its `Artifact Key:` is a `pr-N` or `local-` key, which names no issue whatever `Issue:` repeats. In such a round, `[ISSUE_ID]` in the commit header and the proposed-rule path below takes the `Artifact Key:` value. Otherwise read prior work, decisions, and handoff notes before evaluating any item.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh comments list [ISSUE_ID]
```

GitHub: `gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url`

---

## 2. Process Review Items

Evaluate each item in `Review items:` independently.

Before the first edit, read each page that the repository's `AGENTS.md`, and the `AGENTS.md` nearest each path a fix touches, routes for those paths.

An optional `Adds:` line is the complete blank-separated list of protected additions this round may make.

- A blank or tab separates, so a path containing whitespace is read as two paths and cannot be authorized as one.
- One path is `Adds: tools/one-helper.sh`; multiple paths are `Adds: tools/one-helper.sh skills/x/scripts/check`.
- [`../../orch/schemas/dev-round.md` § Protected additions](../../orch/schemas/dev-round.md#protected-additions) is the sole scope definition.
- With no line, add none in that scope.
- If the fix needs another protected file, report that requirement instead of creating it; the orchestrator must authorize the exact path in a fresh round.

An optional `Near-ceiling:` line, one per binary blob, is a `byte-ceiling` record the previous round produced: the path, its bytes, the ceiling in bytes and the percent reached.

- Plan or perform a move to Git LFS, an asset store or generation before the blob grows further.
- If that remedy cannot be applied here, state why in the return.

With no line, no binary blob is known to be within reach of the ceiling.

Decide each item:

- **Apply** when the item relates to the parent issue and adds no new risk. Unrelated changes are Skipped with the reason; the orchestrator files.
- **Skip** when the pattern conflicts with the existing architecture, would break other functionality, or violates your defined rules and conventions.
  - Before applying anything, search the decisions governing the affected area, `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"`, and `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` for those linked to the issue.
  - Read the full file for any match.
  - An item contradicting an active decision is skipped citing it, e.g. "Skipped — contradicts [DECISION_ID]".
- **Decline** an item that cannot affect real usage, with one line of reasoning, and do not file it.
  - Disposition rules are reviewer's [references/finding-disposition.md](../../reviewer/references/finding-disposition.md).
- **Blocked** when the same fix fails three times: report rather than loop.

Before writing a refusal, a validator, a lock, a retry, or a test, read [dev SKILL.md § Engineering Rules](../SKILL.md#engineering-rules).

An item asking for a test takes the fix-round rule there.

Update a principle doc or a decision record when a fix makes a claim in it false; the `docs-writing` skill says what each holds.

For **UI lifecycle or cache fixes**, cached or mirrored UI state, changed window or event handling:

- Trace every invalidation and event-entry path before returning.
- Prefer extending an existing listener over a parallel subscription for the same event family.
- Add regression coverage for the non-obvious paths you touched.

Before a fix returns:

1. Name the finding's defect class: the assumption that failed, not the cited line.
2. Grep for the verb or pattern to find every other site, input form or copy that makes that assumption. Fix each one, or close the class at its generator.
3. Also grep for every other reader of the field, caller of the helper, or surface stating the rule the fix changed, and fix each one.
4. Name the class and the sites swept in the item reasoning.

A fix at one site with its sibling untouched comes back as the next round.

Note anything a fix revealed about deeper problems, and cite the decision ID or rule behind every skip.

### 2.1 Reflect

Follow [dev SKILL.md § Reflect](../SKILL.md#reflect). Complete every repository edit from reflection before validation.

---

## 3. Validate And Commit

The round must pass [orch's base-freshness gate](../../orch/workflows/dev-fix.md#2-delegate) before it is stamped. If that gate is incomplete, return to the orchestrator before validation.

Read `[ROUND_BASE]` from the `base_sha` of `[WORKTREE_PATH]/tmp/dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json` before entering [dev-implement.md § 5. Validate](./dev-implement.md#5-validate).

Follow that section from the worktree root, with two changes:

1. Its `DEV_VALIDATE_CMD` item validates this round's changes only.
   - Start it as `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --base [BASE_SHA] --run-id [RUN_ID]`, `[RUN_ID]` from the reply of the admission that section's admission step runs before every start. `orch-runtime validate start` resolves the mode from the project's declaration for a start that names a base, and records it on the round's admitted `validate` entry, so the start names no `--validate-mode`.
   - A delegation that carries no `Validation admission:` line starts `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --validate-mode range --base [BASE_SHA]` instead, and the entry resolves that request as `orch-runtime validate entry --help` states.
   - Use `[ROUND_BASE]` as `[BASE_SHA]`, and poll it with the `--wait --run-dir` poll [long-running-validation.md](./long-running-validation.md) gives that section's start.
   - The runner decides whether CI covers the change and whether local validation must run.
   - A project whose policy forbids orch's validation runner takes that section's foreground route instead, with the record's line `validate-mode=range` where the project sets `DEV_VALIDATE_RANGE_CMD` and `validate-mode=full` where it does not. That route's commit is the commit command below, with its review label, run before the record's `head=` line; skip that command after validation.
2. Use the Visual QA rule below.

**Visual QA**, **skip if** the issue has no `design` label or the fix touches no UI code. Otherwise confirm what the fix changes renders correctly, not the full checklist.

```bash
git -C [WORKTREE_PATH] add -A
git -C [WORKTREE_PATH] commit -m "[PREFIX]([ISSUE_ID]): [SUMMARY]" -m "[REVIEW_LABEL]"
```

The header is the first `-m` alone: `[PREFIX]` is a Conventional Commits type such as `fix`, `test` or `docs`, and `[SUMMARY]` states the fix. The repository's commit-msg hook (commit-guards where installed) judges that line's shape and length. The review label is the body, the second `-m`:

| Source | Review Label |
|--------|--------------|
| `pr-review` | "Address PR review" |
| `pr-comments` | "Address PR comments" |
| `qa-review` | "Address QA review" |
| `review` | "Address review" |
| `local-review` | "Address local pre-PR review" |
| `suggestions` | "Address review suggestions" |

When validation failures remain, add `[validate: FAILING_CHECK]` to the body as a further `-m`, never to the header.

---

## 4. Reflect

Reflection is complete in § 2.1. Make no repository edit here.

---

## 5. Return

Write the artifact first, per [dev SKILL.md § Round Contract](../SKILL.md#round-contract):

- Write `tmp/fix-summary-[ISSUE_ID].md` with this round's `### Validation Routes` section per [dev-implement.md § 9.1](./dev-implement.md#91-completion-summary-file), for the orchestrator's existing session and merge comments.
- When a fix changed a view the [dev-implement.md § 8](./dev-implement.md#8-record-qa-signals) screenshot rule covers, list that view's screenshot set under a `### Screenshots` heading by [reviewer references/ui-screenshots.md § Screenshots](../../reviewer/references/ui-screenshots.md#screenshots), which says what a later round recaptures and what it carries.
- If the validation list misses a rule, add a `### Proposed Rules` heading with the proposal as one bullet.
- Always append `--summary-file tmp/fix-summary-[ISSUE_ID].md` to the command below.
- Retain each round's section in its artifact before a later fix uses the same filename.

`[BASE_BRANCH]` is what `.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]` reports; `--near-ceiling-base` takes it as `origin/[BASE_BRANCH]` because the local branch may sit behind the remote, and in a fresh clone may not exist at all.

```bash
.agents/skills/orch/scripts/orch-runtime dev-return --text write --worktree [WORKTREE_PATH] --kind fix --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|no-verdict|handed-over|"FAILING: check1,check2"] [--validate-run-dir [RUN_DIR] | --validate-record [FILE]] [--exception-file [FILE]] [--validate-note [TEXT]] [--label [LABEL]]... [--no-labels] --no-summary --summary-file tmp/fix-summary-[ISSUE_ID].md --item [N] [DECISION] [REASONING] [--item ...] --near-ceiling-base origin/[BASE_BRANCH]
```

One `--label` per entry of the delegation's `Labels:` line, or `--no-labels` when it reads `none`; the Apple gate in `orch-runtime dev-return --text write --help` reads them, and [dev-implement.md § 5. Validate](./dev-implement.md#5-validate) names the `mac run test` it holds an Apple item to.

- One `--item N DECISION REASONING` per **delegated** item, Applied, Skipped, and Blocked alike. The artifact must cover exactly the delegated set, `N` being the item's `#[N]` number (value shapes: `orch-runtime dev-return --text write --help`). Keep `REASONING` free of backticks.
- `--commit` is HEAD after the commit, or the prior HEAD when no commit was needed.
- `[RUN_DIR]` is the `run-dir=` value the validation entry printed in this round's § 3.
- The writer binds the run to the round by its tree, whenever and for whichever round it ran: it refuses `run-off-round` a run that did not validate the `--commit` tree, FAILING included, or whose HEAD does not contain the round's `base_sha`, unless the run records that base as the one it compared from, the base has the run's tree, or the rebase map carries the base into the run's HEAD.
- A run directory whose start record has no `tree=` line proves its recorded HEAD's tree only while that HEAD is the worktree's HEAD and `git status --porcelain` reports nothing.
- A `pass` needs that run to have passed, a `no-verdict` a run that recorded that result. Omit the flag when validation failed before any run started or when § 3's foreground route has no completed record after interruption.
- A project whose own policy forbids orch's validation runner and runs its validation entry point in the foreground passes `--validate-record [FILE]` in place of `--validate-run-dir`, `[FILE]` being the record § 3's foreground route wrote.
- `--validate handed-over`, with no run flag, passes a group's committed work to the group after it, which validates: the writer takes it only where the round began with a group that is not the last and the commit moved past the round's base.
- `--exception-file [FILE]` cites, beside a `FAILING` run, the exception `{by, id, excused}` the round began with; the receipt keeps its `FAILING` line.

**Respawned mid-round without the `Review items:` list?**

- Do not reconstruct it from the raw review JSONs and do not guess.
- Read `[WORKTREE_PATH]/tmp/dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json`, whose `items[]` entries each carry the delegated number `n`, the item's full text, and the `reach` the orchestrator recorded, and write one `--item` per entry.
- If that file is missing too, report the gap and write no artifact.

**Return exactly**:

<output_format>
| # | Decision | Reasoning |
|---|----------|-----------|
| N | Applied/Skipped/Blocked | [EXPLANATION — cite DXXX or rule if Skipped] |

Commits: [SHAS or "none"]
Validate: [pass, "no-verdict: [CAUSE]", or "FAILING: check1, check2"]
Proposed rule: [proposal or "none"]
</output_format>
