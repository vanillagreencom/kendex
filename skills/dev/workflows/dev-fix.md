# Fix Lifecycle

**The workflow for dev agents receiving review fix delegations.**

---

## 1. Environment Setup

Keep shell commands harness-safe: use one simple command per call with explicit arguments. Avoid inline shell loops, command substitution, heredocs, pipelines used only to pass values, and redirected writes to `tmp/`; Codex may treat those helper shapes as approval-required under `never` approval. For required multi-file reads, read each file directly. For generated Markdown/JSON files, use the harness file-write/edit tool or `apply_patch` instead of shell redirection.

---

## 2. Read Work Item Context

Use tracker context when present. Skip tracker reads for ad-hoc fix delegations.

Linear:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

GitHub:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

Understand prior work, decisions, and handoff notes before evaluating items.

---

## 3. Process Review Items

For each item in `Review items:`:

1. **Evaluate independently** — each item stands alone

2. **Apply if**: related to parent issue, no new risks

3. **Skip if** pattern conflicts with existing architecture, would break other functionality, does not follow your defined rules or conventions.
   - **Before applying** (decider skill): `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` for decisions governing the affected area → if match found, read the full decision file
   - If review item contradicts an active decision, skip with decision reference (e.g., "Skipped — contradicts D010")
   - Expanding scope is OK if it relates to the parent issue/PR

4. **Update architecture docs** if fix changes documented behavior. If it reveals project-specific insights, add to `./vstack.toml` under `[agent-launch-instructions]`, `[agent-additional-instructions]`, or `[skill-instructions]`.

5. **For UI lifecycle/cache fixes**: If you introduce cached/mirrored UI state or change window/event handling, trace all invalidation and event-entry paths before returning. Prefer extending existing listeners over adding parallel subscriptions for the same event family, and add regression coverage for the non-obvious paths you touched.

6. **Note in return** if fix reveals deeper issues or if you skipped items — cite decision ID or rule

7. **Report as Blocked** if stuck on same fix 3+ times

Related improvements OK — unrelated changes should become separate issues.

---

## 4. Validate

```bash
# Run the project's build/test/lint validation command
```

**On failure:**
- **First run**: Use `--fail-fast` to stop early, fix, then `--recheck`
- **Simple + related to your work** → fix it, `--recheck`
- **Complex or unrelated** → still commit your work, note failure in commit message, report in return

### 4.1 Visual QA

**Skip if** the issue does not have the `design` label, or the fix does not touch UI code.

Use visual QA skills to validate that the fix renders correctly. Focus on what the fix changes — not the full checklist.

### 4.2 Commit

```bash
git add -A
git commit -m "[PREFIX]([ISSUE_ID]): [MESSAGE]"
```

| Source | Commit Message |
|--------|----------------|
| `pr-review` | "Address PR review - [brief description]" |
| `qa-review` | "Address QA review - [brief description]" |
| `review` | "Address review - [brief description]" |
| `suggestions` | "Address review suggestions" |

If validation failures exist, append: `[validate: FAILING_CHECK]`

---

## 5. Reflect & Update Documentation

**Skip if** all fixes were one-off issues unlikely to recur (e.g., typo, missing import).

**Trigger**: Any of these during § 3-4:
- Fixed same problem 2+ times (lint, pattern, API usage, test approach)
- Discovered non-obvious gotcha worth remembering
- Spent multiple cycles on something a rule could prevent
- Discovered optimal approaches that differ from documented patterns

**Action**: Update the relevant documentation:

- **Architecture docs** → Update if patterns, APIs, or documented behavior changed.
- **Project config** → Add to `./vstack.toml` (`[skill-instructions]`, `[agent-additional-instructions]`, or `[agent-launch-instructions]`). Run `vstack refresh` to apply.

Criteria: Would this save 5+ minutes in a future session? If yes, update. One surgical addition per lesson. No verbose examples.

**If you can't update directly** (wrong domain, needs discussion): note in § 6 return with type `[process]`.

---

## 6. Return

Send this result to the orchestrator as an agent-to-agent message. **Writing artifacts to disk or posting comments is not a return** — the orchestrator does not poll the filesystem, and turn text is not visible across team boundaries. Send exactly one message with the body below, then go idle.

**Return exactly**:

<output_format>
| # | Decision | Reasoning |
|---|----------|-----------|
| N | Applied/Skipped/Blocked | [EXPLANATION — cite DXXX or rule if Skipped] |

Commits: [SHAS or "none"]
Validate: [pass or "FAILING: check1, check2"]
</output_format>

Report decision and reasoning for each item. Include commit SHAs and validation status.

**Do NOT** push — orchestrator handles after review.
