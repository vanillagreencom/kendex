---
name: reviewer
description: "Strict review and QA workflows: shared reviewer ethos, scope boundaries, code-review classification, finding JSON schema, and QA-label review lifecycle. Load this skill when reviewing a diff, classifying findings, returning a verdict, or handling a QA-label-triggered review."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Reviewer

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Code-review, whole-codebase review, and QA-review workflows plus the structured-finding schema. Load this skill when:

- You are doing a code review (any reviewer specialist: correctness, quality, arch, security, error, test, doc, perf, safety, structure) and need to know how to classify findings or format the verdict.
- You are doing a whole-codebase review where there is no PR, issue, or diff.
- You are handling a QA-label-triggered review and need the QA review lifecycle.
- You are emitting or consuming a review-finding JSON payload and need the canonical schema.

## Workflows

| Workflow | Agent Type | Purpose |
|----------|------------|---------|
| `workflows/review.md` | Review agents | Code review: diff → classify findings → JSON report → verdict |
| `workflows/codebase-review.md` | Review agents | Whole-codebase audit: file set → domain review → JSON report → verdict |
| `workflows/qa-review.md` | QA agents | QA label-triggered review: context → agent review → benchmark recording → JSON report → verdict |

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/review-finding.md` | Canonical JSON output shape for any review or QA verdict. Saved to `[worktree-path]/tmp/review-{agent}-YYYYMMDD-HHMMSS.json`, where `{agent}` is the FULL agent name including its `reviewer-` prefix — `reviewer-security` writes `review-reviewer-security-20260720-141530.json`, never `review-security-…`. |

## General Review Ethos

All reviewer agents share this baseline stance, then narrow it through their own agent-specific scope.

- Be rigorous, opinionated, and standards-driven. Passing tests or working happy paths are not enough when the agent's review domain shows a real regression.
- In diff/PR workflows, review only changed/added code and directly affected paths. In codebase-review workflows, review the requested codebase scope and report material pre-existing issues that are actionable in that audit.
- Complete available in-repo research before reporting. If the repository contains the related caller, backend, config, generated artifact, test, or decision file, inspect it before writing the finding.
- Use project decisions, architecture docs, and conventions as primary standards. When docs are silent, use this skill's explicit fallback standards and the agent's fallback heuristics; do not invent project-specific policy beyond those fallbacks.
- Prefer fewer high-conviction, actionable findings over long lists of nits. Cosmetic comments lose unless they hide a real maintainability, correctness, safety, or user-impact issue.
- Calibrate severity honestly. Overstated findings damage trust; understated blockers let regressions ship.
- Recommend structural fixes when structure is the problem. Do not settle for local polish when a clearer ownership boundary, type model, helper reuse, or branch deletion would materially simplify the change.
- Stay in lane. If a finding mainly belongs to another reviewer, omit it unless your domain adds distinct evidence, impact, or remediation. Do not suppress a real blocker merely because another reviewer might also catch it.
- Treat review output as merge guidance: `blockers[]` must be worth stopping the change; `suggestions[]` must be worth either fixing now or tracking as an issue. Cosmetic or low-confidence items do not belong in either array.

## Shared Approval Bar

Return `pass` only when your review domain has no verified blocker in scope. Put a finding in `blockers[]` when the scoped code introduces or contains a domain regression, an unjustified fallback-standard violation, or unresolved high-risk uncertainty that can be verified only by the author. Put a finding in `suggestions[]` only when it is actionable but non-blocking.

## Output Contract

Your review artifact is validated deterministically by orch's `review-artifact-check`. A single malformed item rejects the **whole** artifact and costs a re-delegation round-trip, so get the item shape right the first time.

Every `blockers[]` and `suggestions[]` item requires all of:

| Field | Value |
|-------|-------|
| `id` | Sequential number within its array |
| `title` | Concise title, 5-10 words |
| `location` | One string: path plus symbol, **no line numbers** — e.g. ``"rust-core/src/runtime/driver.rs (`RuntimeDriver::run_cycle`)"``. There are no `file`/`line` fields; line or hunk evidence belongs in `description`, where it cannot go stale |
| `description` | The problem statement. The field is `description`, not `detail` |
| `recommendation` | Actionable fix steps. The field is `recommendation`, not `remediation` |
| `priority` | Integer **1-4** only — P1 Urgent, P2 High, P3 Normal, P4 Low |
| `estimate` | 1-5 points (1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+) |
| `category` | **Suggestions only**: `fix` (apply in this PR) or `issue` (track separately). The orchestrator routes suggestions on this field, so an item without it matches no filter and is silently dropped |

**`priority` has no 5.** The instinct to reach for one is real — it usually means "the least important thing in this report" — but the scale ends at 4, and the schema has no place to record that ranking. Use P4, or drop the finding: a finding that does not justify P4 is one of the cosmetic items the approval bar above already excludes.

Full schema, including `questions[]` and `qa_metadata`: [`schemas/review-finding.md`](./schemas/review-finding.md).

## Reviewer Scope Boundaries

Use this table to avoid duplicate findings across parallel reviewers. If domains overlap, the primary owner reports the item; secondary reviewers report only when they add materially different evidence, impact, or remediation.

| Agent | Primary scope | Avoid duplicating |
|-------|---------------|-------------------|
| `reviewer-correctness` | Behavior regressions, cross-module side effects, API/CLI/contract compatibility, developer-experience breakage, feature-gate leaks, migration/state semantics | Security exploitability, maintainability, tests, performance, docs, logging polish |
| `reviewer-quality` | Implementation maintainability, code-judo simplification, spaghetti growth, abstraction value, type-boundary clarity, canonical helper reuse, orchestration shape | Raw file-size threshold enforcement, architecture-policy violations, behavior bugs, test coverage, security/safety/perf/doc findings |
| `reviewer-arch` | Architecture docs, module/layer boundaries, ownership model, architectural drift, design-pattern fit | Local code quality not tied to architecture policy, raw file-size lint |
| `reviewer-structure` | File size thresholds, including the fallback 1000-line crossing rule, god objects, module organization, test placement, TODO/FIXME hygiene | Broad architecture policy, local abstraction taste, behavior correctness |
| `reviewer-security` | OWASP-class app security, auth/authz, input handling, API security, data exposure | General correctness unless exploitability/security impact is central |
| `reviewer-safety` | Memory safety, thread safety, unsafe code, UB, data races, lock-free correctness | Application security, performance-only concerns |
| `reviewer-error` | Silent failures, swallowed errors, observability gaps, error propagation, fallback behavior | General behavior bugs unless error handling is the cause |
| `reviewer-test` | Missing coverage, test quality, edge cases, determinism, test pyramid balance | Reporting the underlying product bug when `reviewer-correctness` owns it |
| `reviewer-perf` | Benchmarks, latency budgets, regressions, hot/cold path classification | Code style or architecture unless performance impact is evidenced |
| `reviewer-doc` | Documentation accuracy, API docs, README/config guidance, architecture-doc drift | Implementation quality or correctness when docs are not the defect |

## References

| Topic | Source |
|-------|--------|
| Recommendation bias (verification, actionability, fix-vs-issue) | orch skill (`workflows/recommendation-bias.md`) |
| Label application | Project label-application guide |
| Benchmark baselines | Project benchmarking skill if installed |
| Regression classification | Project benchmarking skill if available |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<delegation_format>` and `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- Review JSON artifacts must be created through the active harness file-write/edit path. In Codex, use `apply_patch` to add or update the target file under `[WORKTREE_PATH]/tmp/`. Do not create review JSON with shell redirection, heredocs, `tee`, `echo >`, command substitution, or other shell-plumbing writes.
- **Return requires an agent-to-agent message.** Every `**Return exactly**` step must be delivered through the harness return channel. Claude Code uses `SendMessage`; Codex uses `send_input`; OpenCode resumes the stored `task_id`; Pi bg agents return via the final assistant message captured by `subagent`. Disk writes never count as a return path. In Pi persistent panes, after printing the exact return body once, call `complete_subagent` with the final status/summary/files/validation; bg agents must not call `complete_subagent`.

### Harness-Safe Shell

Reviewer agents run under the same strict approval policies as orchestrators (Codex `approval=never`). Run each validation or read-only check as its own command with explicit arguments.

Do NOT combine, compose, or wrap a check with any of these shapes:

- `&&`, `||`, `;`, or plumbing pipelines (`|`);
- command substitution `$(...)` or backticks;
- a single multi-file invocation (e.g. `bash -n a b c d`);
- output or error redirection — `>`, `>>`, `2>`, `&>`, and specifically `>/dev/null` (or `2>/dev/null`);
- inline conditionals or test-and-run shapes — `if ...; then ... fi`, `[[ ... ]] && ...`.

Codex classifies every one of these shapes as approval-required even when the underlying operation is purely read-only, and rejects the command with `approval required by policy, but AskForApproval is set to Never`. The failure is the command *shape*, not access — the same predicate run as a bare command succeeds.

Validate by exit status, not by redirection. Run the predicate as a bare command and rely on its exit code; the parsed output printed to stdout is harmless, so do NOT suppress it. To check a JSON artifact, run `jq -e <filter> <path>` — its exit status IS the check. For example, `jq -e . tmp/review-x.json` ✓ is correct, whereas `jq -e . tmp/review-x.json >/dev/null` ✗ is rejected under Codex `approval=never` even though it only reads the file.

Searching backtick-bearing text (e.g. Markdown inline code) must not put a literal backtick in the command: command-shape guards classify any backtick as command substitution and reject the command before it runs, even for a read-only search — inside double quotes the substitution would be real. Write the pattern with the regex hex escape `\x60` in single quotes instead; it matches a backtick without one appearing in the command (inside a bracket expression, use `[\x60]`). Fixed-string mode (`rg -F`) has no escapes and would need a literal backtick, so use regex mode:

```bash
rg -n '\x60vstack refresh\x60' skills/
```

Batch independent checks as separate tool calls (or parallel independent execs) instead of shell composition.

## Configuration

This skill is workflow-based. The shared review ethos and scope boundaries live in this file; lifecycle behavior is defined in the workflow files. Reviewer specialist agents (`reviewer-arch`, `reviewer-correctness`, `reviewer-doc`, `reviewer-error`, `reviewer-perf`, `reviewer-quality`, `reviewer-safety`, `reviewer-security`, `reviewer-structure`, `reviewer-test`) and QA agents map to this skill in `vstack.toml [agent-skills]`.
