# Wiring shapes

Three shapes cover the repositories this package targets. Copy one, keep the repository's own job names and required contexts, and change nothing else.

Every shape passes the event and the endpoints through `env:` rather than interpolating `${{ }}` into the shell — a workflow expression pasted into a command line is an injection surface.

Every classifier checkout uses `fetch-depth: 0`. The classifier diffs two real commits; a shallow clone holds neither endpoint. An aggregate checkout does not need history.

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

## Docs-only mode

Pass `--mode docs` to produce `docs_only=true|false`. This mode accepts files under `docs/`, files under `changelog.d/`, and root files ending in `.md` or `.markdown`. A file under `skills/`, `agents/`, `hooks/`, or any other path makes the verdict false.

A docs-only adoption changes each applicable verdict site in the selected shape:

1. Add `--mode docs` to the `harness-only` command.
2. Publish `docs_only: ${{ steps.classify.outputs.docs_only }}` from a classifier job.
3. Read `docs_only` in every lane condition.
4. Pass `needs.changes.outputs.docs_only` to `aggregate-needs` as the waiver.

Keep the endpoint expressions unchanged. Do not mix `docs_only` with the `harness_only` output shown in the base shapes.

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
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - name: the classifier ran and every lane that skipped was told to
        env:
          RESULTS: ${{ toJSON(needs) }}
          HARNESS_ONLY: ${{ needs.changes.outputs.harness_only }}
        run: |
          printf '%s\n' "$RESULTS" |
            jq -c 'to_entries | map({job: .key, result: .value.result})'
          .agents/skills/harness-ci/scripts/aggregate-needs \
          --results "$RESULTS" --classifier changes --waiver "$HARNESS_ONLY" \
          --skippable test --skippable build
```

Both halves close a fail-open. Without `if: always()` a skipped lane skips the aggregate too, and a skipped required context satisfies the ruleset with no lane having run. `aggregate-needs` rejects a classifier that did not succeed and any skipped job that a true verdict did not authorize.

Every trigger the ruleset requires the context on must appear under `on:`, `merge_group` included. A required context that a merge group never produces blocks the queue forever.

## Shape 4 — one change class for every reader

`change-class` answers the wider question the same way: what KIND of change is this diff. It prints `change_class=render|trivial|micro|small|standard`, takes the same event and endpoint flags, and hands the range to `harness-only` rather than reading a second one. Copy shape 1 and change the classify step:

```yaml
      - id: classify
        env:
          EVENT: ${{ github.event_name }}
          BASE: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}
          HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
        run: >-
          .agents/skills/harness-ci/scripts/change-class
          --event "$EVENT" --base "$BASE" --head "$HEAD"
```

Publish `change_class` as the job output in place of `harness_only`.

**The class is never asserted by the change's author.** The script reads no label, branch name or pull request title, and takes no flag that would carry one: the author of the diff being judged writes all of them.

**A caller that acts on the verdict without review checks out the DEFAULT BRANCH's copy of the script** and points `--repo` at the pull request's tree. The branch can change this script too.

`aggregate-needs` keeps its rule: a skipped job is accepted only against the class that authorized it. Name that class once per skippable set, where the waiver is computed, as `needs.changes.outputs.change_class == 'render'`.

## Verifying an adoption

Two probe PRs against the adopting repository:

1. **Harness-only** — touch one file under `.agents/`. The heavy lanes report `skipped`, and every required context reports green.
2. **Mixed** — touch one file under `.agents/` and one product file. Every lane runs.

Close both once the checks report.
