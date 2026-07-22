# Fix Lifecycle

**The workflow for dev agents receiving review fix delegations.**

---

## 1. Environment Setup

Keep shell commands harness-safe: use one simple command per call with explicit arguments. Avoid inline shell loops, command substitution, heredocs, pipelines used only to pass values, and redirected writes to `tmp/`; Codex may treat those helper shapes as approval-required under `never` approval. For required multi-file reads, read each file directly. For generated Markdown/JSON files, use the harness file-write/edit tool or `apply_patch` instead of shell redirection. When a fix item requires searching backtick-bearing text (Markdown inline code), never put a literal backtick in the command — write the pattern with the regex hex escape `\x60` in single quotes (vstack#721; canonical rule: reviewer SKILL.md § Harness-Safe Shell).

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
   - **Before applying** (decider skill): `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` for decisions governing the affected area; for decisions linked to the issue, `.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]` (issue lookup is `search --issue` — the CLI has no bare `issue` action) → if match found, read the full decision file
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

**Long-running validation (harness-timeout safety, vstack#770).** A `tools/validate`-class command or full hermetic suite that can exceed the harness tool timeout (~10 min; 15-30 min runs are at risk) must NOT be run as a plain foreground command the turn blocks on — a tool timeout ends the turn mid-checklist, so the completion tail (commit → artifact → return in § 4.2, § 6) is lost and the orchestrator sees only absence and burns its stall ladder. Run it so the turn survives: prefer the harness background/polling mechanism (start in background, poll status/exit code), or set an explicit generous tool timeout for that one command. If such a command IS interrupted by a tool timeout, do NOT end the turn — re-check its actual outcome (still running? exit code? log tail?) and resume the checklist in the SAME turn. Never treat a tool-timeout error on a long command as completion or as license to go idle.

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
| `pr-comments` | "Address PR comments - [brief description]" |
| `qa-review` | "Address QA review - [brief description]" |
| `review` | "Address review - [brief description]" |
| `local-review` | "Address local pre-PR review - [brief description]" |
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

**Before returning — write your completion artifact.** After the § 4.2 commit, run `dev-return-write` to write the durable completion record (named `tmp/dev-return-[ARTIFACT_KEY]-[DEV_ROUND_ID].json`) — do NOT hand-author the JSON (schema + full field reference: [`../../orch/schemas/dev-return.md`](../../orch/schemas/dev-return.md)). Pass one `--item` per review item you were delegated, from the decision table below — the orchestrator checks the artifact covers EXACTLY the delegated item set, so include every item (Applied, Skipped, and Blocked alike). The orchestrator treats this artifact as the durable completion record: if your return message is lost — e.g. a long validation exceeded the harness tool timeout and ended the turn (§ 4, vstack#770) — the orchestrator recovers your completion from this file instead of re-delegating. Run it AFTER the commit so `commit`/`validate` are final:

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind fix --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|"FAILING: check1,check2"] --item [N] [DECISION] [REASONING] [--item ...]
```

`--issue [ARTIFACT_KEY]` is the delegation's `Artifact Key:` line — the **normalized workflow-state key** (`issue-N` for GitHub, `PROJ-123` for Linear), NOT the tracker-native `OWNER/REPO#N`; orch resolves the artifact by that exact key. `--round-id` is the `[DEV_ROUND_ID]` from the `Round ID:` line. One `--item N DECISION REASONING` per delegated review item — `N` is the item's `#[N]` number, `DECISION` ∈ Applied|Skipped|Blocked (mirroring the return table), `REASONING` non-empty plain text (no backticks). `--kind fix` requires at least one `--item` (the writer rejects a fix artifact with none). `--validate` is `pass` or `FAILING: check1,check2`; `--commit` is HEAD after § 4.2 (the prior HEAD if no commit was needed). It is a single sanctioned command (harness-safe — no shell redirection in your command) and prints the artifact path.

Then send the result to the orchestrator as an agent-to-agent message. **Writing artifacts to disk or posting comments is not a return** — the orchestrator does not poll the filesystem, and turn text is not visible across team boundaries. Send exactly one message with the body below, then go idle.

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
