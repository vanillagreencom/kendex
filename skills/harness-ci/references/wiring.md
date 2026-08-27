# Wiring shapes

Three shapes cover the repositories this package targets. Copy one, keep the
repository's own job names and required contexts, and change nothing else.

Every shape passes the event and the endpoints through `env:` rather than
interpolating `${{ }}` into the shell — a workflow expression pasted into a
command line is an injection surface.

Every shape checks out with `fetch-depth: 0`. The classifier diffs two real
commits; a shallow clone holds neither endpoint.

## The endpoint expressions

```yaml
env:
  EVENT: ${{ github.event_name }}
  BASE: >-
    ${{ github.event.pull_request.base.sha
        || github.event.merge_group.base_sha
        || github.event.before }}
  HEAD: >-
    ${{ github.event.pull_request.head.sha
        || github.event.merge_group.head_sha
        || github.sha }}
```

An event outside the three answers `false` on its own — an unset `BASE` needs
no guard of yours.

## Shape 1 — a `changes` job feeding job-level `if:`

For workflows whose lanes are separate jobs.

```yaml
jobs:
  changes:
    name: Classify the diff
    runs-on: ubuntu-latest
    outputs:
      harness_only: ${{ steps.classify.outputs.harness_only }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: classify
        env:
          EVENT: ${{ github.event_name }}
          BASE: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}
          HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.sha }}
        run: >-
          .agents/skills/harness-ci/scripts/harness-only
          --event "$EVENT" --base "$BASE" --head "$HEAD"

  test:
    needs: changes
    if: needs.changes.outputs.harness_only != 'true'
    runs-on: ubuntu-latest
    steps:
      # the repository's existing lane, unchanged
```

`!= 'true'` and never `== 'false'`: a `changes` job that failed hands
downstream jobs an empty string, and the lane must run on it.

## Shape 2 — a step inside an aggregate job

For workflows that already run one job and gate the expensive tail of it.

```yaml
jobs:
  ci-ok:
    name: CI
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - id: classify
        env:
          EVENT: ${{ github.event_name }}
          BASE: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}
          HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.sha }}
        run: >-
          .agents/skills/harness-ci/scripts/harness-only
          --event "$EVENT" --base "$BASE" --head "$HEAD"

      # Cheap whole-tree checks stay unconditional.
      - run: make lint-text

      - name: build and test
        if: steps.classify.outputs.harness_only != 'true'
        run: make build test
```

The job keeps its name, runs on every event, and reports the required
context whatever the verdict.

## Shape 3 — merge queues, where the required context must report

Two rules, both about a check that never appears.

**Classify inside a job, never in `on.<event>.paths`.** A path filter stops
the workflow from starting. The required context is never created, and the
queue waits on a check nothing will report.

**Keep the job that carries the required name unconditional.** Gate the
lanes; let the aggregate run always and accept a skipped lane as a pass.

```yaml
  ci-ok:
    name: CI                      # the ruleset's required context
    needs: [changes, test, build]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: every lane that ran succeeded
        env:
          RESULTS: ${{ needs.test.result }} ${{ needs.build.result }}
        run: |
          set -u
          for result in $RESULTS; do
            case "$result" in
              success | skipped) ;;
              *) echo "lane result: $result"; exit 1 ;;
            esac
          done
```

`if: always()` is load-bearing. Without it, a skipped lane skips the
aggregate too, and a skipped required context satisfies the ruleset with no
lane having run — the fail-open this shape closes.

Every trigger the ruleset requires the context on must appear under `on:`,
`merge_group` included. A required context that a merge group never produces
blocks the queue forever.

## Verifying an adoption

Two probe PRs against the adopting repository:

1. **Harness-only** — touch one file under `.agents/`. The heavy lanes report
   `skipped`, and every required context reports green.
2. **Mixed** — touch one file under `.agents/` and one product file. Every
   lane runs.

Close both once the checks report.
