# Fix Lifecycle

Read [code-quality](../../code-quality/SKILL.md) before writing or modifying code, including for ad-hoc requests.

The workflow for a dev agent receiving a review-fix delegation. Every path is worktree-scoped.

---

## 1. Read Context

Confirm the shell's real working directory is the delegation's `Worktree:` path before any repo-relative command, by the check at the top of [dev-implement.md](./dev-implement.md).

**Skip if** the delegation is ad-hoc: it carries no `Issue:` line, or its `Artifact Key:` is a `pr-N` or `local-` key, which names no issue whatever `Issue:` repeats. In such a round, `[ISSUE_ID]` in the commit header and the proposed-rule path below takes the `Artifact Key:` value. Otherwise read prior work, decisions, and handoff notes before evaluating any item.

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

GitHub: `gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url`

---

## 2. Process Review Items

Evaluate each item in `Review items:` independently.

An optional `Adds:` line is the complete blank-separated list of protected additions this round may make; a blank or tab separates, so a path containing whitespace is read as two paths and cannot be authorized as one. One path is `Adds: tools/one-helper.sh`; multiple paths are `Adds: tools/one-helper.sh skills/x/scripts/check`. [`../../orch/schemas/dev-round.md` § Protected additions](../../orch/schemas/dev-round.md#protected-additions) is the sole scope definition. With no line, add none in that scope. If the fix needs another protected file, report that requirement instead of creating it; the orchestrator must authorize the exact path in a fresh round.

An optional `Near-ceiling:` line, one per file, is a `byte-ceiling` record the previous round produced: the path, its bytes, the ceiling in bytes and the percent of the ceiling reached. That file is within reach of the wall, and this round owns its split — plan or perform it rather than growing the file further, or say in the return why the split cannot be made here. With no line, no file is known to be within reach.

- **Apply** when the item relates to the parent issue and adds no new risk. Unrelated changes are Skipped with the reason; the orchestrator files.
- **Skip** when the pattern conflicts with the existing architecture, would break other functionality, or violates your defined rules and conventions. Before applying anything, search the decisions governing the affected area — `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"`, and `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` for those linked to the issue — and read the full file for any match. An item contradicting an active decision is skipped citing it, e.g. "Skipped — contradicts [DECISION_ID]".
- **Decline** an item that cannot affect real usage, with one line of reasoning, and do not file it. Disposition rules are orch's [references/finding-disposition.md](../../orch/references/finding-disposition.md).
- **Blocked** when the same fix fails three times — report rather than loop.

Before writing a refusal, a validator, a lock, a retry, or a test, read [dev SKILL.md § Engineering Rules](../SKILL.md#engineering-rules).

An item asking for a test takes the fix-round rule there.

Update the architecture docs when a fix changes an invariant, boundary or decision they state; the `docs-writing` skill says what belongs there. For **UI lifecycle or cache fixes** — cached or mirrored UI state, changed window or event handling — trace every invalidation and event-entry path before returning, prefer extending an existing listener over a parallel subscription for the same event family, and add regression coverage for the non-obvious paths you touched.

Before a fix returns, grep for every other reader of the field, caller of the helper, or surface stating the rule the fix changed, and fix each one; name the sweep in the item reasoning. A fix at one site with its sibling untouched comes back as the next round.

Note anything a fix revealed about deeper problems, and cite the decision ID or rule behind every skip.

### 2.1 Reflect

Follow [dev SKILL.md § Reflect](../SKILL.md#reflect). Complete every repository edit from reflection before validation.

---

## 3. Validate And Commit

Follow [dev-implement.md § 5. Validate](./dev-implement.md#5-validate) from the worktree root, with two changes. Its `DEV_VALIDATE_CMD` item validates this round's changes only: start it as `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH] --validate-mode range --base [BASE_SHA]`, where `[BASE_SHA]` is the `base_sha` of `[WORKTREE_PATH]/tmp/dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json`, and poll it the same way. Use the Visual QA rule below.

The run records the mode that ran, `range`, or `full` in a project that sets no `DEV_VALIDATE_RANGE_CMD`, and § 5's `dev-return-write` reads it from the run directory.

**Visual QA** — **skip if** the issue has no `design` label or the fix touches no UI code. Otherwise confirm what the fix changes renders correctly, not the full checklist.

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

If the validation list misses a rule, write `tmp/proposed-rule-[ISSUE_ID].md` with a `### Proposed Rules` heading and the proposal as one bullet. Append `--summary-file tmp/proposed-rule-[ISSUE_ID].md` to the command below. Omit the file and flag when there is no proposal.

`[BASE_BRANCH]` is what `.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]` reports; `--near-ceiling-base` takes it as `origin/[BASE_BRANCH]` because the local branch may sit behind the remote, and in a fresh clone may not exist at all.

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind fix --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|no-verdict|"FAILING: check1,check2"] [--validate-run-dir [RUN_DIR]] [--validate-note [TEXT]] --no-summary [--summary-file tmp/proposed-rule-[ISSUE_ID].md] --item [N] [DECISION] [REASONING] [--item ...] --near-ceiling-base origin/[BASE_BRANCH]
```

One `--item N DECISION REASONING` per **delegated** item — Applied, Skipped, and Blocked alike; the artifact must cover exactly the delegated set, `N` being the item's `#[N]` number (value shapes: `dev-return-write --help`; keep `REASONING` free of backticks). `--commit` is HEAD after the commit, or the prior HEAD when no commit was needed. `[RUN_DIR]` is the `run-dir=` value `dev-validate-run` printed in this round's § 3; the writer refuses a run from an earlier round, one that started at a HEAD without the round's `base_sha`, unless the run records that base as the one a rebase left off the branch, or one that started before the round was delegated. A `pass` needs that run to have passed, a `no-verdict` that run to have been cut off; omit the flag only when validation failed before any run started.

**Respawned mid-round without the `Review items:` list?** Do not reconstruct it from the raw review JSONs and do not guess. Read `[WORKTREE_PATH]/tmp/dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json`, whose `items[]` entries each carry the delegated number `n`, the item's full text, and the `reach` the orchestrator recorded, and write one `--item` per entry. If that file is missing too, report the gap and write no artifact.

**Return exactly**:

<output_format>
| # | Decision | Reasoning |
|---|----------|-----------|
| N | Applied/Skipped/Blocked | [EXPLANATION — cite DXXX or rule if Skipped] |

Commits: [SHAS or "none"]
Validate: [pass, "no-verdict: suite1, suite2", or "FAILING: check1, check2"]
Proposed rule: [proposal or "none"]
</output_format>
