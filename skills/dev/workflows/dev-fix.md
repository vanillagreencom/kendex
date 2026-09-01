# Fix Lifecycle

The workflow for a dev agent receiving a review-fix delegation. Every path is worktree-scoped.

---

## 1. Read Context

Verify possession before reading or writing anything else. **Skip if** the delegation carries no `Worktree Lease:` line.

```bash
.agents/skills/orch/scripts/worktree-claim --worktree [WORKTREE_PATH] --issue [ARTIFACT_KEY] --expect-gen [WORKTREE_LEASE]
```

Any non-zero exit ends the round here: change nothing in the worktree and return the command's stderr verbatim.

**Skip if** the delegation is ad-hoc. Read prior work, decisions, and handoff notes before evaluating any item.

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

GitHub: `gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url`

---

## 2. Process Review Items

Evaluate each item in `Review items:` independently.

An optional `Adds:` line is a JSON array containing the complete list of protected additions this round may make, with the same string boundaries as the additions file. One path is `Adds: ["tools/one path.sh"]`; multiple paths are `Adds: ["tools/one path.sh","skills/x/scripts/check;safe"]`. [`../../orch/schemas/dev-round.md` § Protected additions](../../orch/schemas/dev-round.md#protected-additions) is the sole scope definition. With no line, add none in that scope. If the fix needs another protected file, report that requirement instead of creating it; the orchestrator must authorize the exact path in a fresh round.

- **Apply** when the item relates to the parent issue and adds no new risk. Unrelated changes are Skipped with the reason; the orchestrator files.
- **Skip** when the pattern conflicts with the existing architecture, would break other functionality, or violates your defined rules and conventions. Before applying anything, search the decisions governing the affected area — `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"`, and `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` for those linked to the issue — and read the full file for any match. An item contradicting an active decision is skipped citing it, e.g. "Skipped — contradicts D010".
- **Decline** an item that cannot affect real usage, with one line of reasoning, and do not file it. Disposition rules are orch's [references/finding-disposition.md](../../orch/references/finding-disposition.md).
- **Blocked** when the same fix fails three times — report rather than loop.

Update architecture docs when a fix changes documented behavior. For **UI lifecycle or cache fixes** — cached or mirrored UI state, changed window or event handling — trace every invalidation and event-entry path before returning, prefer extending an existing listener over a parallel subscription for the same event family, and add regression coverage for the non-obvious paths you touched.

Before a fix returns, grep for every other reader of the field, caller of the helper, or surface stating the rule the fix changed, and fix each one; name the sweep in the item reasoning. A fix at one site with its sibling untouched comes back as the next round.

Note anything a fix revealed about deeper problems, and cite the decision ID or rule behind every skip.

---

## 3. Validate And Commit

Run the project's validation command — the one `.agents/skills/orch/scripts/orch-env DEV_VALIDATE_CMD ""` prints (empty → the project's documented build/test/lint command) — from the worktree root; failure handling and the rule for a run that outlasts your turn are in [dev SKILL.md § Validation](../SKILL.md#validation).

**Visual QA** — **skip if** the issue has no `design` label or the fix touches no UI code. Otherwise confirm what the fix changes renders correctly, not the full checklist.

```bash
git add -A
git commit -m "[PREFIX]([ISSUE_ID]): [MESSAGE]"
```

| Source | Commit Message |
|--------|----------------|
| `pr-review` | "Address PR review - [brief description]" |
| `pr-comments` | "Address PR comments - [brief description]" |
| `qa-review` | "Address QA review - [brief description]" |
| `review` | "Address review - [brief description]" |
| `local-review` | "Address local pre-PR review - [brief description]" |
| `suggestions` | "Address review suggestions" |

Append `[validate: FAILING_CHECK]` when validation failures remain.

---

## 4. Reflect

Follow [dev SKILL.md § Reflect](../SKILL.md#reflect).

---

## 5. Return

Write the artifact first, per [dev SKILL.md § Round Contract](../SKILL.md#round-contract):

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind fix --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|"FAILING: check1,check2"] [--validate-note [TEXT]] --item [N] [DECISION] [REASONING] [--item ...]
```

One `--item N DECISION REASONING` per **delegated** item — Applied, Skipped, and Blocked alike; the artifact must cover exactly the delegated set, `N` being the item's `#[N]` number (value shapes: `dev-return-write --help`; keep `REASONING` free of backticks). `--commit` is HEAD after the commit, or the prior HEAD when no commit was needed.

**Respawned mid-round without the `Review items:` list?** Do not reconstruct it from the raw review JSONs and do not guess. Read `[WORKTREE_PATH]/tmp/dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json`, whose `items[]` entries each carry the delegated number `n` and the item's full text, and write one `--item` per entry. If that file is missing too, report the gap and write no artifact.

**A read-only analysis round** has no items to apply: use `--kind analysis` with `--summary '[TEXT]'` (single-quoted plain text, no backticks, an embedded apostrophe spelled `'\''`) or `--summary-file [FILE]`, and return the recommendation in place of the table below.

**Return exactly**:

<output_format>
| # | Decision | Reasoning |
|---|----------|-----------|
| N | Applied/Skipped/Blocked | [EXPLANATION — cite DXXX or rule if Skipped] |

Commits: [SHAS or "none"]
Validate: [pass or "FAILING: check1, check2"]
</output_format>
