# CI and merge rail

Covers: .github/workflows/, skills/harness-ci/, skills/review-gate/, skills/orch/workflows/merge-pr.md, skills/orch/workflows/consumer-train.md

The rail carries one change from a consumer pull request to the default branch, and carries kendex's own releases back out to every consumer. One classifier reads the diff, CI gates its lanes on that verdict, the review gate posts one commit status, and the branch ruleset decides the merge. Every part of it is shipped by kendex and wired by the consumer: kendex renders scripts and settings, the repository owns its workflow files, its required-context names and its ruleset.

```text
  a consumer pull request                     a kendex release
            |                                         |
    +-------+--------+                                v
    v                v                        consumer-train.md
 classify        review-gate-writer.yml       one chore PR per repo
 the diff        runs on its own legs                 |
 harness-only    (dispatch, schedule,          +------+-------+
 one job          merge group)                 v              v
    |                |                   kendex refresh   workflow YAML
    v                v                   renders the      is never
 CI lanes        review-predicate.sh     .agents/ skill   rendered: each
 gated on        reads the classifier    copies and       repo copies the
 the verdict     for the docs waiver     kendex.          writer template
    |                |                   settings.toml    by hand at
    |                |                        |           adoption and on
    |                |                        |           each update
    v                v                        |              |
 aggregate-      "Review gate"                +------+-------+
 needs, the      commit status                       v
 required            |                      the consumer's own
 context             |                      .github/workflows/
    |                |
    +-------+--------+
            v
  the branch ruleset's required contexts
            v
  merge-pr.md: the fast path, or the merge queue
            v
          main
```

## Ownership

| Part | Owner | Reaches a consumer by | Program issue |
| --- | --- | --- | --- |
| The classifier and the aggregate helper | kendex, `skills/harness-ci/scripts/` | `kendex refresh` vendors them under `.agents/` | KEN-1637, KEN-1600 |
| Which jobs read the verdict | the repository | copied once from `harness-ci/references/wiring.md` | KEN-1596 |
| The gate engine and its predicate | kendex, `skills/review-gate/scripts/` | `kendex refresh` | KEN-1638 |
| The gate writer workflow | kendex ships a template; the copy is the repository's | copied verbatim at adoption, re-copied on each template update | none |
| Required-context names, the ruleset, the merge queue | the repository | set in GitHub, never rendered | KEN-1602 |
| `REVIEW_GATE_*` and `ORCH_MERGE_BYPASS` values | the repository | `kendex.settings.toml` | KEN-1638, KEN-1602 |
| The merge route and the consumer train | kendex, `skills/orch/workflows/` | `kendex refresh` | KEN-1601, KEN-1602 |

Today the classifier answers two narrow questions, `harness_only` and `docs_only`. KEN-1637 replaces both with one five-class verdict, and `.github/actions/` joins the `Covers:` line above when KEN-1600 publishes the `change-class` composite action.

## Boundaries

- `harness-ci` writes nothing under `.github/`, so the repository wires the classifying step itself, from one of the three shapes in [../../skills/harness-ci/references/wiring.md](../../skills/harness-ci/references/wiring.md). That the package writes no workflow is stated in [../../skills/harness-ci/SKILL.md](../../skills/harness-ci/SKILL.md) § This package never edits a workflow, and is not mechanically enforced. `skills/harness-ci/tests/wiring-shapes.test.sh` proves only that each shipped shape keeps its expression, ordering and script path.
- The review gate answers review and nothing else: it reads no job result and re-runs nothing. Enforced by `skills/review-gate/scripts/review-predicate-selftest.sh`, which pins the predicate's answers and which the `gate-selftest` job runs ungated on every pull request. That no CI lane is conditioned on the verdict is a wiring rule the repository holds, stated in [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md#recommended-ci-shape--the-fastfull-split) and not mechanically enforced.
- `kendex refresh` renders vendored skill copies and settings. It never syncs workflow YAML, so every file under a consumer's `.github/workflows/` is that repository's own, including its copy of the gate writer. The repository copies that writer verbatim at adoption and re-copies it on every template update, each time as its own pull request, per [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md) § Updating an already-adopted copy (relay/converge split). `skills/review-gate/scripts/validate-workflow.sh` fails a copy that diverges from the current template and names re-copying as the remedy.
- The merge route is chosen in one place, [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md) § 5 step 1, from `ORCH_MERGE_BYPASS`. Not mechanically enforced.

## Invariants

1. Every case the classifier cannot prove answers `false`, which runs every lane. Enforced by `skills/harness-ci/tests/fail-closed.test.sh`. That the class is read from the diff alone follows from the classifier's argument list, an event name and two commit shas, rather than from a test.
2. Every required context reports on every event the ruleset requires it on. The classifying job sits inside the workflow, never in an `on.<event>.paths` filter, and the job carrying the required name runs unconditionally. The shipped shapes are held to that form by `skills/harness-ci/tests/wiring-shapes.test.sh`; that a given repository wired one is not mechanically enforced.
3. `aggregate-needs` accepts a skipped job only where the classifier succeeded, its waiver is `true`, and the job is in the caller's explicit skippable set, so a lane that skipped for any other reason reds the required context. Enforced by `skills/harness-ci/tests/aggregate-needs.test.sh`, which carries a must-fail control for classifier success, dependency success, the waiver and skippable membership.
4. The gate answers one question, whether this exact head was reviewed, and two green checks never stand in for a review. Enforced by `skills/review-gate/scripts/review-predicate-selftest.sh`, which pins the decision table. That the answer reaches the head as a commit status is the writer's half, enforced by `skills/review-gate/tests/review-writer.test.sh`.
5. A waiver of reviewer evidence waives reviewer evidence alone: an objection, an unresolved thread and a suppressed finding still block. Enforced by `skills/review-gate/tests/docs-only-lane.test.sh`, which carries a row for each and a must-fail control for the suppressed-finding branch. That the ruleset's other required contexts are untouched follows from the gate posting only its own status, and is not mechanically enforced.
6. The classifier a merge trusts is the default branch's copy, never the pull request's. Not yet held: CI runs the branch's copy today, and KEN-1637 carries the change. The package's own source repository is the standing exception, because its checker and its candidate are the same commit, per [../../skills/bot-instructions/SKILL.md](../../skills/bot-instructions/SKILL.md) § A pull request changing its own review.

## Decisions

- Classify inside a job, never in `on.<event>.paths`. A path filter stops the workflow from starting, the required context is never created, and a merge queue waits forever on a check nothing will report.
- Fail closed everywhere. An empty diff, an unresolvable endpoint and an absent render inventory all answer `false` and run the full battery.
- The gate is a commit status, not a CI job, so a repository adopts it without changing its CI and without giving the gate a vote on jobs.
- Propagation into a consumer is local, which is kendex's standing rule. The train enters each consumer's own checkout, refreshes it, and commits through that repository's branch, review and merge path.
- In kendex itself the gate's two waiver lanes are off: `REVIEW_GATE_CARRY_FORWARD` is empty and `REVIEW_GATE_RENDER_PATHS` is unset. `REVIEW_GATE_DOCS_ONLY` is `none`, so a documentation diff waives reviewer evidence alone.
- The merge queue is the one merge path. `ORCH_MERGE_BYPASS = "fast-path"` merges a met head directly where the account holds a ruleset bypass; KEN-1602 retires those bypass actors once the per-class queue is measured.
