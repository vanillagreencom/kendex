# Wiring shapes

Three shapes cover the repositories this package targets. Copy one, keep the repository's own job names and required contexts, and change nothing else.

Every shape passes the event and the endpoints through `env:` rather than interpolating `${{ }}` into the shell — a workflow expression pasted into a command line is an injection surface.

Every shape checks out with `fetch-depth: 0`. The classifier diffs two real commits; a shallow clone holds neither endpoint.

## The endpoint expressions

```yaml
env:
  EVENT: ${{ github.event_name }}
  BASE: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}
  HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
```

An event outside the three answers `false` on its own — an unset `BASE` needs no guard of yours.

Keep each expression on ONE line. A folded scalar (`>-`) whose continuations are indented further than its first line preserves the newlines instead of folding them, and what looks like a wrapped expression is a multi-line one.

`github.event.after` sits AHEAD of `github.sha`, never instead of it. On a branch-deletion push `after` is the all-zero sha while `github.sha` is the default branch tip, so a bare `github.sha` fallback hands the classifier two real commits and a verdict on a diff nobody asked about; the all-zero sha resolves to no commit and answers `false`. `github.sha` stays last, so an event carrying no `after` still resolves a head and fails closed on the event rather than on a missing endpoint.

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
          HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
        run: >-
          .agents/skills/harness-ci/scripts/harness-only
          --event "$EVENT" --base "$BASE" --head "$HEAD"

  test:
    needs: changes
    if: ${{ !cancelled() && !(needs.changes.result == 'success' && needs.changes.outputs.harness_only == 'true') }}
    runs-on: ubuntu-latest
    steps:
      # the repository's existing lane, unchanged
```

**The status function is load-bearing, and the condition names `needs.changes.result` on purpose.** A job-level `if:` carrying no status function keeps the implicit `success()`, so a plain `needs.changes.outputs.harness_only != 'true'` SKIPS the lane whenever the `changes` job fails — a checkout error or an `harness-only` exit 2 would stand the expensive lanes down rather than run them. `!cancelled()` lifts that, and the lane then skips on one condition only: the classifier ran and said `true`.

### When the lane has a SECOND gate

The condition above is complete only where the harness verdict is the lane's ONLY gate. A repo whose lanes also read a path family — `needs.changes.outputs. frontend == 'true'`, a `rust` flag, a `docs` flag — needs a different shape, and the one above silently fails open there:

```yaml
  # WRONG when a family predicate is present
  if: ${{ !cancelled() && needs.changes.outputs.frontend == 'true' && !(needs.changes.result == 'success' && needs.changes.outputs.harness_only == 'true') }}
```

A `changes` job that died publishes NO outputs, so `frontend` reads as an empty string, the `== 'true'` term is false, and the lane skips exactly when nothing classified it. `!cancelled()` cannot lift that — it is the family term failing, not the implicit `success()`.

Lift the family term behind the job's result instead:

```yaml
  # RIGHT: a dead classifier runs the lane, whatever the family says
  if: ${{ !cancelled() && (needs.changes.result != 'success' || (needs.changes.outputs.frontend == 'true' && needs.changes.outputs.harness_only != 'true')) }}
```

Read it as: never on a cancelled run; otherwise run whenever the classification is missing, and skip only when it arrived and cleared the lane. An event term (`github.event_name == 'merge_group'`) stays outside the parentheses — it is a tier decision, not a classification.

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
          HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
        run: >-
          .agents/skills/harness-ci/scripts/harness-only
          --event "$EVENT" --base "$BASE" --head "$HEAD"

      # Cheap whole-tree checks stay unconditional.
      - run: make lint-text

      - name: build and test
        if: steps.classify.outputs.harness_only != 'true'
        run: make build test
```

The job keeps its name, runs on every event, and reports the required context whatever the verdict. No status function is needed here: a STEP-level `if:` is evaluated only after the steps before it succeeded, so a classify step exiting 2 fails the job outright and the gated steps never run.

## Shape 3 — merge queues, where the required context must report

Two rules, both about a check that never appears.

**Classify inside a job, never in `on.<event>.paths`.** A path filter stops the workflow from starting. The required context is never created, and the queue waits on a check nothing will report.

**Keep the job that carries the required name unconditional.** Gate the lanes; let the aggregate run always. A skipped lane is a pass only when the classifier is the reason it skipped.

```yaml
  ci-ok:
    name: CI                      # the ruleset's required context
    needs: [changes, test, build]
    if: always()
    runs-on: ubuntu-latest
    steps:
      - name: the classifier ran and every lane that skipped was told to
        env:
          CHANGES_RESULT: ${{ needs.changes.result }}
          HARNESS_ONLY: ${{ needs.changes.outputs.harness_only }}
          RESULTS: ${{ needs.test.result }} ${{ needs.build.result }}
        run: |
          set -u
          if [ "$CHANGES_RESULT" != "success" ]; then
            echo "changes=$CHANGES_RESULT (required: success)"
            exit 1
          fi
          for result in $RESULTS; do
            case "$result" in
              success) ;;
              skipped)
                if [ "$HARNESS_ONLY" != "true" ]; then
                  echo "a lane skipped on a diff the classifier did not clear"
                  exit 1
                fi
                ;;
              *) echo "lane result: $result"; exit 1 ;;
            esac
          done
```

Both halves close a fail-open. Without `if: always()` a skipped lane skips the aggregate too, and a skipped required context satisfies the ruleset with no lane having run. Without the `CHANGES_RESULT` and `HARNESS_ONLY` checks the aggregate accepts `skipped` from any cause, so a `changes` job that died turns the required context green with nothing built.

Every trigger the ruleset requires the context on must appear under `on:`, `merge_group` included. A required context that a merge group never produces blocks the queue forever.

## Verifying an adoption

Two probe PRs against the adopting repository:

1. **Harness-only** — touch one file under `.agents/`. The heavy lanes report `skipped`, and every required context reports green.
2. **Mixed** — touch one file under `.agents/` and one product file. Every lane runs.

Close both once the checks report.
