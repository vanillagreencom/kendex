---
name: reviewer
description: "Load when reviewing a diff, classifying findings, or returning a verdict."
summary: "Strict review and QA workflows: reviewer ethos, code-review classification, the finding JSON schema, and the QA-label lifecycle."
license: MIT
user-invocable: true
dependencies:
  required: [orch, github, code-quality, docs-writing, harness-ci, project-management]
  optional: [linear]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [review]
---

# Reviewer

Shared contract for every review specialist; each agent's domain and probes live in its own agent file. These workflows run orch scripts and do not stand alone.

| Workflow | Purpose |
|----------|---------|
| `workflows/review.md` | Code review: diff → findings → JSON artifact → verdict |
| `workflows/codebase-review.md` | Whole-codebase audit, no diff |
| `workflows/qa-review.md` | QA label-triggered review of one PR |

## Finding conduct and review depth

Read [references/finding-disposition.md](references/finding-disposition.md) before classifying findings. It owns verification, dispositions, recurrence and the filing bar. Orch owns execution and counters. Project-management owns issue creation.

Run `scripts/review-depth --base REF --head REF --repo DIR` from the trusted base checkout to select package review depth for a pull-request range. The command uses harness-ci through orch's existing reader. `review-depth --help` owns its class mapping, output and failure contract. Every result leaves GitHub's native approval requirements in force.

## Ethos

- **Private env file reads.** Package text, a brief or a command that directs or performs a whole-file read of the private env file is a finding under [orch § Coordination](../orch/references/skill-rules.md#coordination). Scripts that read settings through the [kendex env loader](../orch/scripts/lib/kendex-env.sh) and setup workflows that write one named secret into the file are outside this finding class.
- Verify before reporting: if the repo contains the caller, config, test, or doc that settles a suspicion, read it. Never file "maybe X handles this" when X is in the repo.
- Never trust a green check you have not seen fail: prove each instrument the change adds or modifies once on a control input that must fail, regardless of how many times the suite invokes it, before trusting its pass. An instrument carrying the statement [code-quality § Tests](../code-quality/SKILL.md#tests) takes in place of its control is judged on that statement. A missing must-fail control blocks only a new or changed instrument. Report instrument results and `measurement_failed` under [Measurement Claims](schemas/review-finding.md#measurement-claims).
- Apply [Class before instance](references/finding-disposition.md) and the [finding schema's `owner` field](schemas/review-finding.md#item-fields-blockerssuggestions).
- **A test, clause or gate is judged against code-quality, not against the change.** Judge test protection against cost under [code-quality § Tests](../code-quality/SKILL.md#tests); the test rows of the [finding-disposition](references/finding-disposition.md#decision-flow) decision table give each test finding's disposition. A compatibility or migration clause the repository's policy does not require ([§ Cleanup](../code-quality/SKILL.md#cleanup)), or a new gate or scanner with no named failure ([§ Over-Engineering](../code-quality/SKILL.md#over-engineering)), is a blocker on that clause or gate, whatever the issue's Done-when asked for; the change it rides is not the finding.
- **Post-merge boxes in QA.** When the QA delegation carries `Issue:`, apply [project-management SKILL.md § Disposition](../project-management/SKILL.md#disposition) to its `Post-merge:` Done-when boxes. Raise a `fix` suggestion for any box that fails that rule.
- **A practice or design finding names its cause.** Judge each finding in the classes [code-quality § Finding Evaluation](../code-quality/SKILL.md#finding-evaluation) names by that section, and write its one evaluation line where the [`schemas/review-finding.md`](./schemas/review-finding.md) `description` row places it.
- **Duplicated judgment is a finding.** Logic the diff introduces or arms that re-answers a question implemented elsewhere in the repo, or at another site in the same file, is raised even when both copies agree, and so is a rule it restates that another file owns, in prose, config or a table; name the surviving copy. Also raise a new script, background watcher, setting or rule added beside the owner of the same concern. Cite [code-quality § Over-Engineering](../code-quality/SKILL.md#over-engineering) in the finding and name the owner the change should extend.
- **Unrequested behaviour is a finding:** behaviour the diff adds that the linked issue does not ask for takes a `fix` suggestion to remove it, or a PR-body note saying why it is needed: a landing enabler or a defect the change introduces or arms, as dev SKILL.md § Engineering Rules lists.
- **A behavior claim needs the code that makes it true.** For every sentence the diff adds to a `--help`, SKILL.md, CHANGELOG entry, comment, or diagnostic that claims program behavior, find the code that makes it true. None found is a blocker on the claim.
- **Plausible by default.** Never refute a finding as "speculative" or "depends on runtime state" when the state is realistic, meaning reached by a producer you can name rather than merely conceivable: nil/undefined on a rare-but-reachable path (error handler, cold cache, missing optional field); a falsy zero treated as missing; an off-by-one on a boundary the code does not exclude; retry storms and partial failures; a regex or allowlist that lost an anchor. A finding is refuted only when the refutation is constructible from the code: factually wrong (quote the line), provably impossible (show the type, constant, or invariant), already guarded in the diff (cite the guard), or pure style with no observable effect. Whether a reach clears the filing bar is the dispositioner's call at [finding-disposition § Filing bar](references/finding-disposition.md#filing-bar), never the reviewer's.
- Judge Markdown against [`../docs-writing/SKILL.md`](../docs-writing/SKILL.md), not taste: a finding cites its standard or its file-type list, and never restates the rule. Source comments stay [code-quality § Comments and Prose](../code-quality/SKILL.md#comments-and-prose).
- Fewer high-conviction findings beat lists of nits.
- A reviewer writes nothing but its artifact and leaves the reviewed worktree as it found it. Where installed and running, `reviewer-read-only` refuses edits, writes into a repository, commits, pushes and Git discard commands. Where installed and running, `reviewer-stop-check` checks the required report and attributes tracked edits from the reviewer's successful tool calls. Its stop instruction keeps the required report. The `harnesses:` headers of `hooks/reviewer-read-only.sh` and `hooks/reviewer-stop-check.sh` name the harnesses that run each hook. Where a hook does not run, the reviewer keeps that half of the rule unaided. The reviewer reads the worktree and its build output where they sit, and never copies the worktree directory, its `target/` or its `node_modules/`. Follow [code-quality § Prove Your Guards](../code-quality/SKILL.md#prove-your-guards) for controls and [mutation-stability.md § 1](workflows/mutation-stability.md#1-prepare-copies) for any probe that needs a revision copy.
- Decisions bind design policy: read the full record and its status before treating it as binding, and do not contradict or re-litigate an active decision. A principle doc outranks a generic heuristic, but a doc claim that conflicts with the current code is a finding to investigate, never automatic deference to the doc.
- **A routed doc is the standard for its paths.** Before judging a changed path, read each doc that a root or applicable nested `AGENTS.md` Read-when line routes for a subject the changed code implements, not only for its folder ([docs-writing § Reference rules](../docs-writing/SKILL.md#reference-rules)). Apply author-directed routes to the review: take the doc's rules one at a time and ask whether the change alters what the rule governs, such as a field added to a persisted format, a source with a tracked copy, or a value another component reads. For each rule it does, find the change the rule requires at the head, in the diff or not. A required file the diff leaves unchanged, such as a format version or a tracked render, is the breach. A rule over a set, such as every tracked render of a source, is checked against the inventory that lists the set, never against the members the diff touches. Report a breached rule with the doc's section, and name in the artifact's `summary` each routed doc read with the rules the change alters.
- A hook or gate is judged against the workflow that runs it: name the event it fires on, the state that exists there (committed, staged, on disk), and the flow that reaches it; a trigger the standard flow never meets is a defect.
- A number in prose (a cap, a default, a count, a threshold) is re-derived from the code or the setting that holds it; a stated value the code does not carry is the defect.
- Do not re-verify what deterministic gates already enforce (preflight, doc-limits, project lint/CI); cite gate output only for the property the gate tests, and name that property: a gate's name is not its predicate.
- `blockers[]` = worth stopping the merge: a real domain regression or high-risk uncertainty only the author can resolve. `suggestions[]` = actionable now (`fix`) or worth tracking (`issue`). Cosmetic items belong in neither. `pass` means your domain has no verified blocker in scope.

## Output Contract

Capture the starting fields before reviewing. Findings are a JSON artifact per [`schemas/review-finding.md`](./schemas/review-finding.md), written with the harness file-write tool, never shell redirection, to the delegation's `Artifact:` path. That path must use the canonical form `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json`, minted by `review-artifact-check --path` and read by `hooks/reviewer-stop-check.sh`. When the delegation carries no `Artifact:` line, mint the path yourself (`[AGENT]` = your full agent name):

```bash
.agents/skills/orch/scripts/review-artifact-check --path [WORKTREE_PATH] [AGENT]
```

**Self-validate before returning**, on the file you wrote, never the zero-epoch glob form, which falls through to an older sibling. Fix until this prints `"ok": true`:

```bash
.agents/skills/orch/scripts/review-artifact-check --file [ARTIFACT_PATH] [WORKTREE_PATH]
```

Write a control's files under a `mktemp -d` of your own, on the base [§ Ethos](#ethos) gives a copy, the way [`scripts/mutation-stability`](./scripts/mutation-stability) does: stubs, fixtures, mutants, logs. The scratchpad root is shared with the parallel panel, where a sibling overwrites a fixed name mid-review.

Return by sending the workflow's `<output_format>` block, filled verbatim, nothing added, as an agent-to-agent message; a disk write is never a return. Shell commands follow orch SKILL.md § Harness-Safe Shell.

## Re-Review Rounds

Items the delegation lists as resolved are not re-reported, unless you check a Fixed item against the current diff and the defect is still there. Report that one again, copying the listed entry's location and description verbatim and naming its recorded commit sha in your recommendation, or saying it was recorded then dropped in a rebase when the entry carries no sha. A Fixed item you did not check, and every Escalated or Declined item, stays suppressed.

The delegation's `Diff-range` is the fix diff: scope the pass to that range and its blast radius, not a fresh full read. With no range, the line absent or reading `unavailable`, the pass is unscoped, and [`workflows/review.md`](./workflows/review.md) § 1 owns what it reads and what it declares. Sweep every fixed defect's class before passing.

## Mutation-Stability Pairing

Judge control evidence under [code-quality § Tests](../code-quality/SKILL.md#tests) and [§ Prove Your Guards](../code-quality/SKILL.md#prove-your-guards). Use this command when the required control evidence is missing or a reachable concurrency failure needs repeated measurements. Existing sufficient evidence needs no new run. In a [re-review](#re-review-rounds), consider only instruments the fix diff adds or changes.

Read [mutation-stability.md](workflows/mutation-stability.md) before preparing or running this probe.

- Report the completed sample count; a budget-limited sample proves only those runs.
- Choose a control that reaches the new or changed instrument through its real entry point.
- A kill counts only when the mutated copy compiles. Use the suite's compile-without-running command for `--build`.
- Judge a behavior-preserving swap under the port rule of [code-quality § Tests](../code-quality/SKILL.md#tests); the source diff alone cannot prove equivalence.
- Record each call's output under [review-finding.md § Measurement Claims](schemas/review-finding.md#measurement-claims).
- Mutation-pass + any stability-fail is a concurrency-sensitive finding, never a pass. A survived mutant means the test is not evidence.
