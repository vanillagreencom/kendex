# Fix Lifecycle

The workflow for a dev agent receiving a review-fix delegation. Every path is worktree-scoped.

---

## 1. Read Context

Verify possession before reading or writing anything else. **Skip if** the delegation carries no `Worktree Lease:` line.

```bash
.agents/skills/orch/scripts/worktree-claim --worktree [WORKTREE_PATH] --issue [ARTIFACT_KEY] --expect-gen [WORKTREE_LEASE]
```

Any non-zero exit ends the round here: change nothing in the worktree and return the command's stderr verbatim.

Use tracker context when present, skipping these reads for an ad-hoc delegation. Understand the prior work, decisions, and handoff notes before evaluating any item.

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

GitHub: `gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url`

---

## 2. Process Review Items

Evaluate each item in `Review items:` independently — each stands alone.

- **Apply** when the item relates to the parent issue and adds no new risk. Expanding scope is fine while it relates to the parent issue or PR; genuinely unrelated changes become separate issues.
- **Skip** when the pattern conflicts with the existing architecture, would break other functionality, or violates your defined rules and conventions. Before applying anything, search the decisions governing the affected area — `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"`, and `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` for those linked to the issue (the CLI has no bare issue action; the lookup is `search --issue`) — and read the full file for any match. An item contradicting an active decision is skipped citing it, e.g. "Skipped — contradicts D010".
- **Decline** an item that cannot affect real usage, with one line of rationale, and do not file it. Disposition rules are orch's [references/finding-disposition.md](../../orch/references/finding-disposition.md).
- **Blocked** when the same fix defeats you three times — report rather than loop.

Update architecture docs when a fix changes documented behavior. For **UI lifecycle or cache fixes** — cached or mirrored UI state, changed window or event handling — trace every invalidation and event-entry path before returning, prefer extending an existing listener over a parallel subscription for the same event family, and add regression coverage for the non-obvious paths you touched.

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

One `--item N DECISION REASONING` per **delegated** item — Applied, Skipped, and Blocked alike, since the orchestrator checks the artifact covers exactly the delegated set and rejects a `fix` artifact with no items. `N` is the item's `#[N]` number, `DECISION` is Applied, Skipped, or Blocked, `REASONING` non-empty plain text with no backticks. `--commit` is HEAD after the commit, or the prior HEAD when no commit was needed.

**Respawned mid-round without the `Review items:` list?** Do not reconstruct it from the raw review JSONs and do not guess — the delegated set was a curated, renumbered subset, and a guessed mapping writes fabricated reasoning into the durable record. The orchestrator persisted the set at delegation: read `[WORKTREE_PATH]/tmp/dev-round-[ARTIFACT_KEY]-[DEV_ROUND_ID].json`, whose `items[]` entries each carry the delegated number `n` and the item's full text, and write one `--item` per entry. If that file is missing too, report the gap instead of writing an artifact you cannot back.

**A read-only analysis round** has no items to apply: use `--kind analysis` with `--summary '[TEXT]'` (single-quoted plain text, no backticks, an embedded apostrophe spelled `'\''`) or `--summary-file [FILE]`, and return the recommendation in place of the table below.

**Return exactly**:

<output_format>
| # | Decision | Reasoning |
|---|----------|-----------|
| N | Applied/Skipped/Blocked | [EXPLANATION — cite DXXX or rule if Skipped] |

Commits: [SHAS or "none"]
Validate: [pass or "FAILING: check1, check2"]
</output_format>
