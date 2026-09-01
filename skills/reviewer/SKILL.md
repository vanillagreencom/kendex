---
name: reviewer
description: "Load when reviewing a diff, classifying findings, or returning a verdict."
summary: "Strict review and QA workflows: reviewer ethos, code-review classification, the finding JSON schema, and the QA-label lifecycle."
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
- Never trust a green check you have not seen fail: prove every instrument (grep scope, substitution, measurement, assertion) on a control input that must fail before trusting its pass. Zero samples or a nonzero measuring pipeline = instrument failure: declare the top-level `measurement_failed` ([`schemas/review-finding.md`](./schemas/review-finding.md)), cite no numbers. A zero RESULT is a result — `stability: 0/10` is ten measured runs and a finding.
- **Report the class, not the instance.** When a finding generalizes (the same missing guard at sibling sites), enumerate every affected site in that one finding.
- **Duplicated judgment is a finding.** Logic the diff introduces or arms that re-answers a question implemented elsewhere in the repo is raised even when both copies agree, and so is a rule it restates that another file owns, in prose, config or a table; name the surviving copy.
- **A claim needs the line that makes it true.** For every sentence the diff adds to a `--help`, SKILL.md, CHANGELOG entry, comment, or diagnostic that states an order, a source set, an exit code, or a guarantee, find the code that makes it true. None found is a blocker; the claim is the defect, not the code.
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

Items the delegation lists as resolved are not re-reported, unless you check a Fixed item against the current diff and the defect is still there — report that one again, copying the listed entry's location and description verbatim and naming its recorded commit sha in your recommendation, or saying it was recorded then dropped in a rebase when the entry carries no sha. A Fixed item you did not check, and every Escalated item, stays suppressed.

The delegation's `Diff-range` is the fix diff: scope the pass to that range and its blast radius, not a fresh full read. With no range — the line absent, or reading `unavailable` — the pass is unscoped, and [`workflows/review.md`](./workflows/review.md) § 1 owns what it reads and what it declares. Sweep every fixed defect's class before passing.

## Mutation-Stability Pairing

Mutation proves a test can fail; stability proves it fails only for the
right reason. Run both with one command, on a copy, never in the shared
tree:

```bash
.agents/skills/reviewer/scripts/mutation-stability --worktree [WORKTREE_PATH] --sha [SHA] --test '[TEST_CMD]' --mutate '[MUTATE_CMD]'
```

- Kill the mutant under every selection/invocation mode the changed code
  exposes, not only the default (one call per mode).
- Copy the printed `mutation: … stability: …` line into your artifact's
  `summary`; that field and `qa_metadata` are the only carriers read as
  your own measurement.
- Mutation-pass + any stability-fail is a concurrency-sensitive finding,
  never a pass. A survived mutant means the test is not evidence.
