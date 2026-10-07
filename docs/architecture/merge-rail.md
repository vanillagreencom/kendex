# Each repository owns its merges and its refresh

Read before changing CI, the review gate, the merge route or consumer refresh.

## The approach

A change class is derived from the paths a change touches, by the classifier in `skills/harness-ci/scripts/change-class`, and CI selects its jobs from that class. GitHub enforces approval, stale-approval dismissal, thread resolution and the required contexts through rulesets; kendex publishes no review status of its own, per [D018](../decisions/D018-platform-review-requirements.md). The merge route is chosen in one place, `pr-merge` in the github skill, which reads the queue ruleset's bypass and merges past the queue only where the queue is all it would skip, per [D016](../decisions/D016-merge-route-reads-bypass.md). Consumers pull kendex updates in their own GitHub Actions runners, through the shipped `kendex-refresh.yml` template that installs the latest release at run time or through the shared workflow `.github/workflows/refresh-consumer.yml` at a major tag, per [D003](../decisions/D003-one-merge-path.md); the kendex app and CLI open no pull request in a consumer.

## Why

A path filter that stops a workflow from starting leaves a required context that never reports and a queue that waits forever, so the class is computed inside a job. A direct merge rebuilds every running queue group, so the route proves the queue empty before it skips it. A consumer's own runner does the refresh, so propagation costs kendex nothing and no kendex credential can reach a consumer.

## Rules

- Do classify inside a job, never in an `on.<event>.paths` filter, and run the job carrying a required name unconditionally. `skills/harness-ci/references/wiring.md` is the wiring, and `skills/harness-ci/tests/ci-template.test.sh` holds the template to it.
- Do defer a slow lane from a pull request to the merge group by marking it `:queue` in the consumer's default-branch `.github/ci-lanes.conf`; the classifier derives `queue_only` from the `queue` rows of `skills/orch/references/narrow-change.conf`, `HARNESS_CI_QUEUE_PATHS`, each `:queue` lane's globs and the jobs the `HARNESS_CI_QUEUE_SELECTOR` command names, read off the base commit, and `.github/actions/change-class` publishes it beside the class.
- Do fail closed: every case the classifier cannot prove answers `false`, which authorizes no skip; `skills/harness-ci/tests/fail-closed.test.sh` holds it.
- Do trust the default branch's classifier, never the pull request's, for the classifier scripts and their measurement settings; the package's own repository is the one exception, because checker and candidate are the same commit. The action wrapper and the `tools/` files `LANE_SOURCES` in `tools/ci-job-set` names still run from the pull request's tree, so review holds them and a change to one runs every lane.
- Do read the merge route from GitHub: `--admin` only where every ruleset answers that the queue is all it would skip, the base queue is empty and the change is not queue-only; `--auto` never passes `--admin`. A green pull request takes the admin route and a CI, ruleset-input or shared-harness change keeps the queue, per [D013](../decisions/D013-admin-merge-green-prs.md).
- Do let a generic tree proof stand down only what a completed run of the same workflow on the same tree recorded, and only the lanes the workflow marks event-uniform; `tools/tests/change-class-proof.test.sh` holds it. In this repository, a merge group reuses only the macOS selection recorded by a successful pull-request run of the same workflow with the same whitespace-preserving patch id. Never derive past macOS coverage from the current checkout. Ubuntu lanes always test the integrated tree. Missing or changed patch proof stands no macOS leg down.
- Do run the selected macOS shell shards on pull requests. A merge group runs them unless matching patch proof covers them, and `CI` holds each selected leg. A change whose selection names one takes the queue, never the admin route, per [D013](../decisions/D013-admin-merge-green-prs.md): `kendex.settings.toml` names `tools/ci-job-set`'s `queue_macos_shards` as the classifier's queue selector. `main` pushes run macOS cargo tests and the full macOS shell roster outside the required contexts. They catch a macOS failure that appears only when independently passing patches combine, which patch proof cannot exclude.
- Do keep workflow files out of `kendex refresh`: adoption copies a template verbatim and records its hash in `.kendex-generated.json`; a changed copy is not a render.
- Do carry the bot-instructions render in the refresh pull request: the refresh run renders through kendex where the package is installed and configured, per [repo-effects.md](repo-effects.md), because the consumer's own check judges the pull request with the refreshed package.
- Do report a consumer's stale settings in the refresh pull request body and remove none of them, from the one list `skills/review-gate/retired-settings.json`; a failed report stops publication and auto-merge like a failed extraction. `skills/review-gate/tests/refresh-consumer.test.sh` and `refresh-report.test.sh` hold it.
- Never replay a consumer refresh in a kendex pull-request check: kendex is public, a check without secrets reads only what kendex commits, and a committed copy of a consumer's inputs would publish private repositories' files.
- Never record the install record on a branch; `main` re-records it after each merge through one rolling pull request, per [D007](../decisions/D007-lock-record-on-main.md).

## The canonical example

The `changes` job of `.github/workflows/skill-tests.yml`: it checks the default branch's classifier out separately, runs it through `.github/actions/change-class`, publishes the class and per-lane verdicts, and every gated job reads them. A new lane reads a verdict from that job and adds its row to `tools/ci-job-set`.

## Revisit when

The pull-request run runs every merge-group job for the touched paths, so the queue has nothing left to prove, or a served repository cannot use GitHub rulesets or Actions.

## Not governed

What each lane tests: `skills/AGENTS.md` and `tools/AGENTS.md`. How a lane shepherds one pull request through the gate: the orch skill's `workflows/merge-pr.md`.
