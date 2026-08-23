---
name: reviewer
description: "Strict review and QA workflows: reviewer ethos, code-review classification, the finding JSON schema, and the QA-label lifecycle. Load when reviewing a diff, classifying findings, or returning a verdict."
license: MIT
user-invocable: true
dependencies:
  required: [orch]
  optional: [linear]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.0"
tags: [review]
---

# Reviewer

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Shared contract for every review specialist; each agent's domain and probes live in its own agent file. These workflows run orch scripts and do not stand alone.

| Workflow | Purpose |
|----------|---------|
| `workflows/review.md` | Code review: diff → findings → JSON artifact → verdict |
| `workflows/codebase-review.md` | Whole-codebase audit, no diff |
| `workflows/qa-review.md` | QA label-triggered review of one PR |

## Ethos

- Verify before reporting: if the repo contains the caller, config, test, or doc that settles a suspicion, read it. Never file "maybe X handles this" when X is in the repo.
- Never trust a green check you have not seen fail: prove any instrument you rely on (a grep scope, a substitution, a measurement, a test assertion) on a control input that must fail — or, for a substitution, visibly transform — before trusting its pass on the real target. A run that produced zero samples, or whose measuring pipeline exited nonzero, is instrument failure, not a result: declare it in the top-level `measurement_failed` ([`schemas/review-finding.md`](./schemas/review-finding.md)) and never cite its numbers as evidence. A zero RESULT is not a zero sample — `stability: 0/10` is ten measured runs and a finding to report.
- **Report the class, not the instance.** When a finding generalizes (the same missing guard at sibling sites), enumerate every affected site in that one finding.
- Fewer high-conviction findings beat lists of nits.
- Project decisions and architecture docs outrank generic heuristics. Do not contradict or re-litigate the decisions the delegation lists.
- Do not re-verify what deterministic gates already enforce (preflight, size-ratchet, project lint/CI); cite gate output instead of re-deriving it.
- `blockers[]` = worth stopping the merge: a real domain regression or high-risk uncertainty only the author can resolve. `suggestions[]` = actionable now (`fix`) or worth tracking (`issue`). Cosmetic items belong in neither. `pass` means your domain has no verified blocker in scope.

## Output Contract

Findings are a JSON artifact per [`schemas/review-finding.md`](./schemas/review-finding.md), written with the harness file-write tool — never shell redirection — to the delegation's `Artifact:` path. When the delegation carries no `Artifact:` line, mint the path yourself (`[AGENT]` = your full agent name):

```bash
.agents/skills/orch/scripts/review-artifact-check --path [WORKTREE_PATH] [AGENT]
```

**Self-validate before returning** — fix until this prints `"ok": true`:

```bash
.agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] 0
```

Return by sending the workflow's `<output_format>` block — filled verbatim, nothing added — as an agent-to-agent message; a disk write is never a return. Shell commands follow orch SKILL.md § Harness-Safe Shell.

## Re-Review Rounds

Items the delegation lists as resolved are not re-reported. Scope the pass to the fix diff and its blast radius, not a fresh full read; sweep every fixed defect's class before passing.

## Mutation-Stability Pairing

Mutation-validating a test (temporarily breaking the code under test to confirm the test fails, then reverting) proves the test can fail, not that it fails only for the right reason. Plant and revert a mutation inside a single tool call; when that is not possible, run it on a `git archive [SHA]` copy outside the worktree, never in the shared tree. The mutant must be killed under every selection/invocation mode the changed code exposes, not only the default. Every test you mutation-validate also gets repeat runs (default N=10) at elevated parallelism (e.g. `--test-threads` at roughly double the runner's default). Report both numbers in your artifact's `summary`, in this fixed format: `mutation: killed X/X; stability: Y/N at T threads`. That field and `qa_metadata` are the only carriers read as your own measurement; the same citation living only inside a blocker or suggestion is treated as quoted evidence and is not checked. A test that passes mutation but fails any stability run is a concurrency-sensitive finding, never a pass.
