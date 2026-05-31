# Codebase Review Lifecycle

Whole-codebase review for ad-hoc early-stage audits. No PR, no issue, no diff, no fix delegation.

Review agents audit the same worktree from their specialist perspective and return the standard reviewer JSON.

**Ownership**: You review the specified codebase. Return verdict to orchestrator. No issue tracker state changes.

---

## 1. Establish Scope

Extract from delegation message:
- `Worktree` path
- `Scope` description, if provided
- `Exclusions`, if provided

Default scope: all tracked, non-generated project code files, plus tests, configs, and docs relevant to your review domain. Do not sample or restrict to changed files.

Default exclusions: `.git/`, harness mirrors (`.agents/`, `.claude/`, `.cursor/`, `.codex/`, `.opencode/`, `.pi/`), dependency/vendor dirs (`node_modules/`, `vendor/`), build outputs (`target/`, `dist/`, `build/`, `coverage/`), generated artifacts, binary assets, and lockfiles unless your domain specifically requires them.

Use `git -C [WORKTREE_PATH] ls-files` to enumerate tracked files. Do not use `git diff`; this is not a change review.

If the requested scope is too large to review honestly before context/tool limits, return `action_required` with a blocker describing the coverage gap and the smallest useful split.

---

## 2. Review Codebase

Apply the reviewer skill's General Review Ethos and Reviewer Scope Boundaries. Stay within this agent's domain; do not duplicate another specialist unless your domain adds distinct evidence, impact, or remediation.

Inspect files broadly enough to support every finding. Do not report speculative issues from filenames or search hits alone; read the relevant code before writing the finding.

For whole-codebase audits, findings may be pre-existing. Report only issues that are actionable, material, and worth addressing in an early-stage quality pass.

---

## 3. Classify Findings

Read the linear-orch skill's recommendation-bias patterns if available. Apply its actionability checks to ALL findings before entering `blockers[]` or `suggestions[]`.

**Verdict rules:**
- `action_required`: 1+ items in `blockers[]`
- `pass`: `blockers[]` empty

---

## 4. Return JSON Report

Build JSON per [`../schemas/review-finding.md`](../schemas/review-finding.md). Save to `[WORKTREE_PATH]/tmp/review-[AGENT]-codebase-YYYYMMDD-HHMMSS.json`.

Send this result to the orchestrator as an agent-to-agent message. **Writing the JSON to disk is not a return**.

**Return exactly**:

<output_format>
Verdict: [pass|action_required]
File: [WORKTREE_PATH]/tmp/review-[AGENT]-codebase-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

---

## Constraints

**Do NOT**:
- Modify files
- Modify issue tracker state
- Create commits or push changes
- Call other subagents
- Convert findings into issues

**Orchestrator handles**: fanout, collection, and presentation only.
