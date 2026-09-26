# CI and merge rail

Covers: .github/workflows/, .github/actions/, skills/harness-ci/, skills/review-gate/, skills/orch/workflows/merge-pr.md, skills/orch/workflows/consumer-train.md, skills/orch/scripts/adopt-writer

The rail carries one change from a consumer pull request to the default branch, and, off a hosted fleet, carries each kendex merge to a shipped catalog path back out to every consumer; on a hosted fleet that route does not run, and the orch `merged` event in [../../skills/orch/references/oversee-events.md](../../skills/orch/references/oversee-events.md) § Event kinds says what the overseer does instead. One classifier reads the diff, CI gates its lanes on that verdict, the review gate posts one commit status, and the branch ruleset decides the merge, which the merge queue makes. kendex renders the scripts and fixes the `CI` context name through its CI workflow template; the repository owns its workflow files and its settings values. Each repository's own rulesets own the required-context names and the merge queue today; organization rulesets that target every repository replace them at KEN-1778, the owner action [D003](../decisions/D003-one-merge-path.md) sequences.

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
 CI lanes        review-predicate.sh     refresh output and     |
 gated on        reads the classifier    re-adopted gate writer |
 the verdict     for the docs waiver     alone, plus a bundle's |
    |                |                   manifest edit when     |
    |                |                   its members moved      |
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
  (the repository's today, the organization's
  at KEN-1778)
            v
  merge-pr.md: the lane arms auto-merge and the
  merge queue merges
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
| The gate writer workflow | kendex ships a template; the copy is the repository's | copied verbatim at adoption; re-installed by `validate-workflow.sh --adopt`, run in the consumer after `kendex refresh` | none |
| The `CI` required-context name | kendex, the same in every repository | the aggregate job's name: `skills/harness-ci/references/wiring.md` § The CI context | KEN-1778 |
| Which contexts are required, the rulesets, the merge queue | the repository's own rulesets today; at KEN-1778, the end state, organization rulesets that target every repository and carry no standing bypass actor | set in GitHub, never rendered; at KEN-1778 set once at the organization level | KEN-1778 |
| `REVIEW_GATE_*` values | the repository | `kendex.settings.toml` | KEN-1638 |
| The merge route: the lane arms auto-merge with the lanes app's installation token | kendex, `skills/orch/workflows/merge-pr.md` | `kendex refresh` | KEN-1777 |
| The consumer train | kendex, `skills/orch/workflows/consumer-train.md` | `kendex refresh` | KEN-1779 |

The classifier answers one five-class verdict, `change_class`, beside the two narrow questions `harness_only` and `docs_only`. `.github/actions/change-class` is the composite action that publishes the class and the changed-path families to a workflow; it wraps the shipped scripts and classifies nothing itself. In this repository `tools/ci-job-set` turns the class and the changed paths, read through `tools/rust-reads`, into one selection per lane of `skill-tests.yml`, and `tools/ci-aggregate` holds each required context to those selections; the `CI` job holds every lane the older aggregators hold, plus `gate-selftest`, Preflight and Markdown, and those aggregators keep the per-repository ruleset's names until that ruleset is retired. A lane reads the same class before it opens a pull request: orch's `dev-validate-run` classifies the worktree through `skills/orch/scripts/lib/change-class.sh`; review-gate's `review-policy` calls the classifier itself for its measured marker, and the `changes` job's action reads the shipped scripts itself from its trusted checkout. `dev-validate-run` exports the class, the docs verdict and the changed paths to `DEV_VALIDATE_CMD`. `tools/guard --full` hands those three to `tools/ci-job-set`, as the `changes` job does. The classifier proves `render` in a private checkout of the range's head, which for `dev-validate-run` is a snapshot commit of the worktree, so a dev-completion run over uncommitted render edits is weighed with those edits. A wrong local class costs a red CI check, since CI classifies the branch again.

## Boundaries

- `harness-ci` writes nothing under `.github/`, so the repository wires the classifying step itself, from one of the four shapes or the CI template in [../../skills/harness-ci/references/wiring.md](../../skills/harness-ci/references/wiring.md). That the package writes no workflow is stated in [../../skills/harness-ci/SKILL.md](../../skills/harness-ci/SKILL.md) § This package never edits a workflow, and is not mechanically enforced. `skills/harness-ci/tests/wiring-shapes.test.sh` proves only that each shipped shape keeps its expression, ordering and script path, and `skills/harness-ci/tests/ci-template.test.sh` that the template's `CI` job needs every other job and that a merge group runs the lanes its pull request ran.
- The review gate answers review and nothing else: it reads no job result and re-runs nothing. Enforced by `skills/review-gate/scripts/review-predicate-selftest.sh`, which pins the predicate's answers and which the `gate-selftest` job runs ungated on every pull request. That no CI lane is conditioned on the verdict is a wiring rule the repository holds, stated in [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md#recommended-ci-shape--the-fastfull-split) and not mechanically enforced.
- `kendex refresh` renders vendored skill copies and settings. It never writes workflow YAML, so every file under a consumer's `.github/workflows/` is written in that repository, including its copy of the gate writer. The repository copies that writer verbatim at adoption. A template update reaches the copy through `skills/review-gate/scripts/validate-workflow.sh --adopt`, run after `kendex refresh`: in the refresh workflow KEN-1779 adds, and until then in `skills/orch/scripts/adopt-writer`. What it writes and what it leaves is [../../skills/review-gate/references/adoption.md](../../skills/review-gate/references/adoption.md) § Updating an already-adopted copy. Without `--adopt` the script fails a copy that diverges from the current template and names that command as the remedy.
- `skills/review-gate/scripts/validate-standard.sh` reports, read-only, whether a repository's GitHub settings match [D003](../decisions/D003-one-merge-path.md), whose step 2 carries the environment rows. `skills/review-gate/standard.json` holds the required contexts, the app, the environment and its secret names; the script fixes the remaining rows. The owner-run `provision-environment.sh` beside it, not the script, creates the environment and its secrets.
- The merge route is chosen in one place, [../../skills/orch/workflows/merge-pr.md](../../skills/orch/workflows/merge-pr.md) § 5 step 1: the lane arms auto-merge on its exact head, on every change class, and waits in `queue-wait` while the merge queue merges it. A force-merge answer takes the same arm. `skills/github/scripts/commands/pr-merge.sh` holds the lane's half: no mode passes `--admin` to GitHub, and it refuses the retired merge settings its `--help` § Retired settings names. Enforced by the merge-queue and retired-settings rows of `skills/github/tests/pr-merge.test.sh`. That no ruleset carries a bypass actor is GitHub configuration the owner holds, not mechanically enforced here.

## Invariants

1. Every case the classifier cannot prove answers `false`, which authorizes no classifier-based skip. Enforced by `skills/harness-ci/tests/fail-closed.test.sh`. A `false` verdict does not mean every lane runs: in the two-gate shape a lane's own path-family predicate still applies. The verdict is not read from the diff alone either. Docs mode reads the changed paths; harness mode also reads `.kendex-generated.json` at both endpoints.
2. Every required context reports on every event the ruleset requires it on. The classifying job sits inside the workflow, never in an `on.<event>.paths` filter, and the job carrying the required name runs unconditionally. Both are repository wiring rules, stated in [../../skills/harness-ci/references/wiring.md](../../skills/harness-ci/references/wiring.md#shape-3--merge-queues-where-the-required-context-must-report) and not mechanically enforced. The snippets `skills/harness-ci/tests/wiring-shapes.test.sh` reads carry no trigger block, so that test checks expression closure, script paths, options, endpoint ordering, lane conditions and indentation only. `skills/harness-ci/tests/ci-template.test.sh` holds the CI template to both triggers and to a `CI` job that runs whatever its needs did.
3. `aggregate-needs` accepts a skipped job only where the classifier succeeded, its waiver is `true`, and the job is in the caller's explicit skippable set, so a lane that skipped for any other reason reds the required context. Enforced by `skills/harness-ci/tests/aggregate-needs.test.sh`, which carries a must-fail control for classifier success, dependency success, the waiver and skippable membership.
4. The gate answers one question, whether this exact head was reviewed, and two green checks never stand in for a review. Enforced by `skills/review-gate/scripts/review-predicate-selftest.sh`, which pins the decision table. That the answer reaches the head as a commit status is the writer's half, enforced by `skills/review-gate/tests/review-writer.test.sh`.
5. The active class policy follows the [review-gate class table](../../skills/review-gate/README.md#class-policy), which states the scope: a `none` row puts the pull request outside the review gate entirely, objections and suppressed findings included. The legacy docs-only and render-only waivers still waive evidence alone, so objections, unresolved threads and suppressed findings block. Required CI contexts, commit guards and merge conflicts remain under their existing owners. Enforced by the class-policy gate suite and `skills/review-gate/tests/docs-only-lane.test.sh`.
6. One component owns the class-to-policy MAPPING for the whole rail: `skills/review-gate/scripts/review-policy`. The CI predicate, orch's gate-mode resolver, orch's micro admission in [../../skills/orch/workflows/micro.md](../../skills/orch/workflows/micro.md) § 4, which reads the owner directly, and `pr-merge`'s review-thread gate all consume its answer and none re-derives it, so a change one of them waives cannot be held by another over the same class. The INPUTS are not shared. The CI writer reads the policy out of the default branch it checks out; every lane consumer reads its own checkout's working tree, which is the same checkout trust the `REVIEW_GATE_MODE` and `PR_REVIEW_GATE` resolution already carries and is item 7's boundary, not this one's. Enforced by `skills/orch/tests/approval_wait_cli.sh`, which carries the waived-class control, the required-review inverse and the unreadable-range refusal, and by the class-policy rows in `skills/github/tests/pr-merge.test.sh`.
7. The classifier a merge trusts, and the settings file its policy is read from, are the default branch's copies, never the pull request's. Held for the classifier scripts: the `changes` job of `skill-tests.yml` reads `skills/harness-ci/scripts` and orch's measurement contract from a separate default-branch checkout, through the action's `classifier` input. The action wrapper, `tools/ci-job-set`, `tools/ci-aggregate` and `tools/rust-reads` still run from the pull request's tree; review holds them, and `tools/ci-job-set` runs every lane for a change to one of them. Not held for that settings file, which every lane consumer reads out of its own checkout; KEN-1637 carries that change too. Not mechanically enforced. The package's own source repository is the standing exception, because its checker and its candidate are the same commit, per [../../skills/bot-instructions/SKILL.md](../../skills/bot-instructions/SKILL.md) § A pull request changing its own review.

## Decisions

- Classify inside a job, never in `on.<event>.paths`. A path filter stops the workflow from starting, the required context is never created, and a merge queue waits forever on a check nothing will report.
- Fail closed everywhere. An empty diff, an unresolvable endpoint and an absent render inventory all answer `false`, which authorizes no skip the verdict would otherwise have allowed.
- The gate is a commit status, not a CI job. Adoption still changes CI: it adds the ungated validate job, and a repository that wants the docs waiver also takes the fast/full split. What stays untouched is that no job is conditioned on the gate's verdict.
- The consumer train is the current propagation path, and [D003](../decisions/D003-one-merge-path.md) replaces it with a workflow each consumer runs. The train refreshes each consumer's own checkout and commits only the refresh output, the re-adopted gate writer and, where a bundle's member list moved, a manifest edit, through that repository's branch, review and merge path. On a hosted fleet the train does not run: the orch `merged` event in [../../skills/orch/references/oversee-events.md](../../skills/orch/references/oversee-events.md) § Event kinds sends each consumer's overseer a note and reports that consumer as not refreshed, until KEN-1779 ships a refresh workflow in each consumer's own Actions.
- In kendex itself `REVIEW_GATE_CARRY_FORWARD` is `docs`: evidence carries across markdown-only deltas, never across a change to an excluded policy path. `REVIEW_GATE_CLASS_POLICY` decides which change classes need evidence, so the legacy `REVIEW_GATE_DOCS_ONLY` and `REVIEW_GATE_RENDER_PATHS` are inert.
- One merge path, per [D003](../decisions/D003-one-merge-path.md): every lane route goes through the merge queue, armed by the lane itself, for the reasons D003 § Rationale gives. The overseer's owner-credential admin merge, the user's `--admin` and `--force` overrides and the `ORCH_MERGE_BYPASS` fast path are retired; `pr-merge --help` § Retired settings states how their settings are refused.
- No standing bypass actor means a pull request that repairs a broken gate engine, which cannot turn its own `Review gate` context green, merges by the break-glass procedure [../../skills/review-gate/SKILL.md](../../skills/review-gate/SKILL.md) § 4. Operations states, never by a standing bypass.
