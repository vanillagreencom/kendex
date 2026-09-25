# CI and merge rail

Covers: .github/workflows/, .github/actions/, skills/harness-ci/, skills/review-gate/, skills/orch/workflows/merge-pr.md, skills/orch/workflows/consumer-train.md

The rail carries one change from a consumer pull request to the default branch, and, off a hosted fleet, carries each kendex merge to a shipped catalog path back out to every consumer; on a hosted fleet that route does not run, and the orch `merged` event in [../../skills/orch/references/oversee-events.md](../../skills/orch/references/oversee-events.md) § Event kinds says what the overseer does instead. One classifier reads the diff, CI gates its lanes on that verdict, the review gate posts one commit status, and the branch ruleset decides the merge. Every part of it is shipped by kendex and wired by the consumer: kendex renders the scripts, and the repository owns its workflow files, its settings values, its required-context names and its ruleset.

```text
  a consumer pull request                     a kendex merge to a shipped path
            |                                         |
    +-------+--------+                      +---------+---------+
    v                v                      v                   v
 classify        review-gate-writer.yml  consumer-train.md  outside the train,
 the diff        runs on its own legs    one chore PR       the repo's own PR
 harness-only    (dispatch, schedule,    per repo           copies the writer
 one job          merge group)              |               template and sets
    |                |                      v               kendex.settings.toml
    v                v                   it commits the         |
 CI lanes        review-predicate.sh     refresh output         |
 gated on        reads the classifier    alone, plus a          |
 the verdict     for the docs waiver     manifest edit          |
    |                |                   when a bundle's        |
    |                |                   members moved          |
    |                |                      |                   |
    v                v                      +---------+---------+
 aggregate-      "Review gate"                        v
 needs, the      commit status           the consumer's .agents/,
 required            |                   .github/workflows/ and
 context             |                   kendex.settings.toml
    |                |
    +-------+--------+
            v
  the branch ruleset's required contexts
            v
  merge-pr.md: the queue, the fast path, or a user override
            v
          main
```

## Ownership

| Part | Owner | Reaches a consumer by | Program issue |
| --- | --- | --- | --- |
| The classifier and the aggregate helper | kendex, `skills/harness-ci/scripts/` | `kendex refresh` vendors them under `.agents/` | KEN-1637, KEN-1600 |
| The `change-class` composite action | kendex, `.github/actions/change-class/` | referenced from a workflow at `@main` or a pinned tag; no refresh, and it runs kendex's own classifier at that ref | KEN-1596 |
| Which jobs read the verdict | the repository | copied once from `skills/harness-ci/references/wiring.md` | KEN-1596 |
| The gate engine and its predicate | kendex, `skills/review-gate/scripts/` | `kendex refresh` | KEN-1638 |
| The gate writer workflow | kendex ships a template; the copy is the repository's | copied verbatim at adoption; re-installed by `validate-workflow.sh --adopt` in the consumer train's render pull request | none |
| Required-context names, the ruleset, the merge queue | the repository | set in GitHub, never rendered | KEN-1602 |
| `REVIEW_GATE_*` and `ORCH_MERGE_BYPASS` values | the repository | `kendex.settings.toml` | KEN-1638, KEN-1602 |
| The merge route and the consumer train | kendex, `skills/orch/workflows/` | `kendex refresh` | KEN-1601, KEN-1602 |

The classifier answers one five-class verdict, `change_class`, beside the two narrow questions `harness_only` and `docs_only`. `.github/actions/change-class` is the composite action that publishes the class and the changed-path families to a workflow; it wraps the shipped scripts and classifies nothing itself. In this repository `tools/ci-job-set` turns the class into one selection per lane of `skill-tests.yml`, and `tools/ci-aggregate` holds each required context to those selections. A lane reads the same class before it opens a pull request: orch's `dev-validate-run` classifies the worktree through `skills/orch/scripts/lib/change-class.sh`, the classifier reader `pr-merge.sh` also reads its class through; review-gate's `review-policy` calls the classifier itself for its measured marker, and the `changes` job's action reads the shipped scripts itself from its trusted checkout. `dev-validate-run` exports the class, the docs verdict and the changed paths to `DEV_VALIDATE_CMD`. `tools/guard --full` hands those three to `tools/ci-job-set`, as the `changes` job does. The classifier proves `render` only on a clean tree with no arming record, so a dev-completion run over uncommitted render edits validates as `standard`. A wrong local class costs a red CI check, since CI classifies the branch again.

## Boundaries

- `harness-ci` writes nothing under `.github/`, so the repository wires the classifying step itself, from one of the three shapes in [../../skills/harness-ci/references/wiring.md](../../skills/harness-ci/references/wiring.md). That the package writes no workflow is stated in [../../skills/harness-ci/SKILL.md](../../skills/harness-ci/SKILL.md) § This package never edits a workflow, and is not mechanically enforced. `skills/harness-ci/tests/wiring-shapes.test.sh` proves only that each shipped shape keeps its expression, ordering and script path.
- The review gate answers review and nothing else: it reads no job result and re-runs nothing. Enforced by `skills/review-gate/scripts/review-predicate-selftest.sh`, which pins the predicate's answers and which the `gate-selftest` job runs ungated on every pull request. That no CI lane is conditioned on the verdict is a wiring rule the repository holds, stated in [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md#recommended-ci-shape--the-fastfull-split) and not mechanically enforced.
- `kendex refresh` renders vendored skill copies and settings. It never writes workflow YAML, so every file under a consumer's `.github/workflows/` is written in that repository, including its copy of the gate writer. The repository copies that writer verbatim at adoption. On a template update, `skills/review-gate/scripts/validate-workflow.sh --adopt` re-installs the template's bytes over a copy that equals an earlier shipped version and leaves a copy whose code lines were edited untouched, and the consumer train runs it in the render pull request, per [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md) § Updating an already-adopted copy. Without `--adopt` the script fails a copy that diverges from the current template and names that command as the remedy.
- The merge route is chosen in one place, [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md) § 5 step 1, and is one of three. `ORCH_MERGE_BYPASS` selects between the fast path and the queue; an admin merge or a force-merge answer is an explicit user decision that takes the direct attempt and reads no bypass verdict. Not mechanically enforced.

## Invariants

1. Every case the classifier cannot prove answers `false`, which authorizes no classifier-based skip. Enforced by `skills/harness-ci/tests/fail-closed.test.sh`. A `false` verdict does not mean every lane runs: in the two-gate shape a lane's own path-family predicate still applies. The verdict is not read from the diff alone either. Docs mode reads the changed paths; harness mode also reads `.kendex-generated.json` at both endpoints.
2. Every required context reports on every event the ruleset requires it on. The classifying job sits inside the workflow, never in an `on.<event>.paths` filter, and the job carrying the required name runs unconditionally. Both are repository wiring rules, stated in [../../skills/harness-ci/references/wiring.md](../../skills/harness-ci/references/wiring.md#shape-3--merge-queues-where-the-required-context-must-report) and not mechanically enforced. The snippets `skills/harness-ci/tests/wiring-shapes.test.sh` reads carry no trigger block, so that test checks expression closure, script paths, options, endpoint ordering, lane conditions and indentation only.
3. `aggregate-needs` accepts a skipped job only where the classifier succeeded, its waiver is `true`, and the job is in the caller's explicit skippable set, so a lane that skipped for any other reason reds the required context. Enforced by `skills/harness-ci/tests/aggregate-needs.test.sh`, which carries a must-fail control for classifier success, dependency success, the waiver and skippable membership.
4. The gate answers one question, whether this exact head was reviewed, and two green checks never stand in for a review. Enforced by `skills/review-gate/scripts/review-predicate-selftest.sh`, which pins the decision table. That the answer reaches the head as a commit status is the writer's half, enforced by `skills/review-gate/tests/review-writer.test.sh`.
5. The active class policy follows the [review-gate class table](../../skills/review-gate/README.md#class-policy), which states the scope: a `none` row puts the pull request outside the review gate entirely, objections and suppressed findings included. The legacy docs-only and render-only waivers still waive evidence alone, so objections, unresolved threads and suppressed findings block. Required CI contexts, commit guards and merge conflicts remain under their existing owners. Enforced by the class-policy gate suite and `skills/review-gate/tests/docs-only-lane.test.sh`.
6. One component owns the class-to-policy MAPPING for the whole rail: `skills/review-gate/scripts/review-policy`. The CI predicate, orch's gate-mode resolver, orch's micro admission in [../../skills/orch/workflows/micro.md](../../skills/orch/workflows/micro.md) § 4, which reads the owner directly, and `pr-merge`'s review-thread gate all consume its answer and none re-derives it, so a change one of them waives cannot be held by another over the same class. The INPUTS are not shared. The CI writer reads the policy out of the default branch it checks out; every lane consumer reads its own checkout's working tree, which is the same checkout trust the `REVIEW_GATE_MODE` and `PR_REVIEW_GATE` resolution already carries and is item 7's boundary, not this one's. Enforced by `skills/orch/tests/approval_wait_cli.sh`, which carries the waived-class control, the required-review inverse and the unreadable-range refusal, and by the class-policy rows in `skills/github/tests/pr-merge.test.sh`.
7. The classifier a merge trusts, and the settings file its policy is read from, are the default branch's copies, never the pull request's. Held for the classifier scripts: the `changes` job of `skill-tests.yml` reads `skills/harness-ci/scripts` and orch's measurement contract from a separate default-branch checkout, through the action's `classifier` input. The action wrapper, `tools/ci-job-set` and `tools/ci-aggregate` still run from the pull request's tree; review holds them, and `skills/orch/references/narrow-change.conf` refuses the narrow classes to a diff touching `.github/actions/` or `tools/`, so a change to one of them runs every lane. Not held for that settings file, which every lane consumer reads out of its own checkout; KEN-1637 carries that change too. Not mechanically enforced. The package's own source repository is the standing exception, because its checker and its candidate are the same commit, per [../../skills/bot-instructions/SKILL.md](../../skills/bot-instructions/SKILL.md) § A pull request changing its own review.

## Decisions

- Classify inside a job, never in `on.<event>.paths`. A path filter stops the workflow from starting, the required context is never created, and a merge queue waits forever on a check nothing will report.
- Fail closed everywhere. An empty diff, an unresolvable endpoint and an absent render inventory all answer `false`, which authorizes no skip the verdict would otherwise have allowed.
- The gate is a commit status, not a CI job. Adoption still changes CI: it adds the ungated validate job, and a repository that wants the docs waiver also takes the fast/full split. What stays untouched is that no job is conditioned on the gate's verdict.
- The consumer train is the current propagation path, and [D003](../decisions/D003-one-merge-path.md) replaces it with a workflow each consumer runs itself. The train enters each consumer's own checkout, refreshes it, and commits the refresh output and nothing else, beyond a manifest edit where a bundle's member list moved, through that repository's branch, review and merge path. On a hosted fleet the train does not run: the orch `merged` event in [../../skills/orch/references/oversee-events.md](../../skills/orch/references/oversee-events.md) § Event kinds sends each consumer's overseer a note and reports that consumer as not refreshed, until KEN-1779 ships a refresh workflow in each consumer's own Actions.
- In kendex itself the gate's carry-forward and render-only lanes are off: `REVIEW_GATE_CARRY_FORWARD` is empty and `REVIEW_GATE_RENDER_PATHS` takes its empty default. `REVIEW_GATE_DOCS_ONLY` is `none`, so a documentation diff waives reviewer evidence alone.
- The merge queue is one of the three current routes that § Boundaries names; `ORCH_MERGE_BYPASS = "fast-path"` merges a met head directly where the account holds a ruleset bypass. [D003](../decisions/D003-one-merge-path.md) makes the queue the one merge path, and KEN-1777 retires the fast path and those bypass actors.
