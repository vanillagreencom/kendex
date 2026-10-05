# Each repository owns its merges and its refresh

Read before changing CI, the review gate, the merge route or consumer refresh.

## The approach

A change class is derived from the paths a change touches, by the classifier in `skills/harness-ci/scripts/change-class`, and CI selects its jobs from that class. GitHub enforces approval, stale-approval dismissal, thread resolution and the required contexts through rulesets; kendex publishes no review status of its own. The merge route is chosen in one place, `pr-merge` in the github skill, which reads the queue ruleset's bypass and merges past the queue only where the queue is all it would skip. Consumers pull kendex updates in their own GitHub Actions runners through the shared workflow `.github/workflows/refresh-consumer.yml` at a major tag; the kendex app and CLI open no pull request in a consumer.

## Why

A path filter that stops a workflow from starting leaves a required context that never reports and a queue that waits forever, so the class is computed inside a job. A direct merge rebuilds every running queue group, so the route proves the queue empty before it skips it. A consumer's own runner does the refresh, so propagation costs kendex nothing and no kendex credential can reach a consumer.

## Rules

- Do classify inside a job, never in an `on.<event>.paths` filter, and run the job carrying a required name unconditionally. `skills/harness-ci/references/wiring.md` is the wiring; `skills/harness-ci/tests/ci-template.test.sh` holds the template to it.
- Do mark a slow lane `:queue` in the default branch's `.github/ci-lanes.conf` to defer it from a pull request to the merge group; the classifier derives `queue_only` from the `queue` rows of `skills/orch/references/narrow-change.conf`, `HARNESS_CI_QUEUE_PATHS` and each `:queue` lane's globs, read off the base commit's declaration, and `.github/actions/change-class` publishes it beside the class (`skills/harness-ci/references/wiring.md` § Per-lane verdicts).
- Do fail closed: every case the classifier cannot prove answers `false`, which authorizes no skip (`skills/harness-ci/tests/fail-closed.test.sh`).
- Do trust the default branch's classifier, never the pull request's, for the classifier scripts and their measurement settings; the package's own repository is the one exception, because checker and candidate are the same commit. The action wrapper and the `tools/` files `LANE_SOURCES` in `tools/ci-job-set` names still run from the pull request's tree, so review holds them and a change to one runs every lane.
- Do read the merge route from GitHub, per [D016](../decisions/D016-merge-route-reads-bypass.md): `--admin` only where every ruleset answers that the queue is all it would skip, the base queue is empty and the change is not queue-only; `--auto` never passes `--admin`.
- Do let a proof stand down only what a completed run of the same workflow on the same tree recorded, and only the lanes the workflow marks event-uniform (`tools/tests/change-class-proof.test.sh`).
- Do hold shell shards to the selected Linux runner; the macOS skill suites run the full shell roster on `main` pushes and report outside the required contexts.
- Do keep workflow files out of `kendex refresh`: adoption copies a template verbatim and records its hash in `.kendex-generated.json`; a changed copy is not a render.
- Do report a consumer's stale settings in the refresh pull request body and remove none of them: the Consumer settings section names each retired key the consumer still sets and each committed value matching a former shipped default, from the one list `skills/review-gate/retired-settings.json`, plus the classifier's `setting-unset:` line and the `queue-only:` lines whose cause names a setting; a failed report (`refresh-error=settings-report`) stops publication and auto-merge like a failed extraction (`skills/review-gate/tests/refresh-consumer.test.sh`, `refresh-report.test.sh`).
- Do carry the bot-instructions render in the refresh pull request: the refresh run renders where the default branch configures the package, per [repo-effects.md](repo-effects.md), because the consumer's own check judges the pull request with the refreshed package.
- Never replay a consumer refresh in a kendex pull-request check: kendex is public, a check without secrets reads only what kendex commits, and a committed copy of a consumer's inputs would publish private repositories' files.
- Never record the install record on a branch; `main` re-records it after each merge through one rolling pull request, per [D007](../decisions/D007-lock-record-on-main.md).

## The canonical example

The `changes` job of `.github/workflows/skill-tests.yml`: it checks the default branch's classifier out separately, runs it through `.github/actions/change-class`, publishes the class and per-lane verdicts, and every gated job reads them. A new lane reads a verdict from that job and adds its row to `tools/ci-job-set`.

A consumer refresh whose open rolling pull request is queued, merged or closed at run start defers before the refresh. A refused consumer-refresh push defers only after GitHub reports the rolling pull request queued, merged or closed, or a previously observed branch deleted; a push refusal that is GitHub's GH006 merge-queue refusal defers as queued even when that read answers armed or active. Any other refusal of an armed pull request exits 1. A failed or incomplete state read remains a failure. `skills/review-gate/tests/refresh-consumer.test.sh` holds the run-start deferral, the post-refusal ordering and the publication boundary.

## Decisions

One merge path and consumers pulling renders, [D003](../decisions/D003-one-merge-path.md), amended by [D013](../decisions/D013-admin-merge-green-prs.md), [D016](../decisions/D016-merge-route-reads-bypass.md) and [D018](../decisions/D018-platform-review-requirements.md).
