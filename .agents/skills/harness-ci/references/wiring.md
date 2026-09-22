# Wiring shapes

Four shapes cover the repositories this package targets. Copy one, keep the repository's own job names and required contexts, and change nothing else.

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

`change-class` answers the wider question: what KIND of change is this diff. It prints `change_class=render|trivial|micro|small|standard` and takes the same event and endpoint flags.

The shape has TWO checkouts, and that is the whole point of it. The verdict decides whether a required lane may be skipped, so the script that produces it comes from the default branch, where the pull request's author cannot change it, and the pull request's tree is what `--repo` points at.

```yaml
  changes:
    name: Classify the diff
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read
    outputs:
      change_class: ${{ steps.classify.outputs.change_class }}
    steps:
      - name: the classifier, from the default branch
        uses: actions/checkout@v4
        with:
          ref: ${{ github.event.repository.default_branch }}
          path: classifier
      - name: the tree under judgement
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          path: subject
      - name: kendex, for the render class
        env:
          # The first release whose `kendex verify --json` prints a version 1
          # document; the render proof reads that document and nothing else.
          # Replace the placeholder with one of the kendex repository's
          # per-main-build pre-release tags, spelled as below, whose
          # `kendex verify --json` prints a version 1 document; copied as it
          # stands, the install fails and this job fails with it.
          KENDEX_VERSION: main-build-<n>-<attempt>-<sha>
        run: curl -fsSL https://kendex.ai/install.sh | sh -s -- --version "$KENDEX_VERSION"
      - name: the source mirror the render proof re-renders from
        run: kendex source refresh
        working-directory: subject
      - id: classify
        env:
          EVENT: ${{ github.event_name }}
          ORCH_SIZE_RENDER_ROOTS: .agents .claude .codex .pi
          # ORCH_SIZE_TEST_PATHS: <globs>
          # Uncomment where this repository's test files live outside orch's
          # default test globs; the classifier reads neither of these two out
          # of the tree it judges.
          BASE: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}
          HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
        run: >-
          classifier/.agents/skills/harness-ci/scripts/change-class
          --repo subject --event "$EVENT" --base "$BASE" --head "$HEAD"
```

Publish `change_class` as the job output in place of `harness_only`, and feed it to `aggregate-needs` as the waiver by naming the authorizing class where the waiver is computed, as `needs.changes.outputs.change_class == 'render'`. `aggregate-needs` keeps its rule unchanged: a skipped job is accepted only against the class that authorized it.

### What each class needs, and what it costs to leave out

`standard` needs nothing and is what every unproven diff answers, so a consumer reading `standard` on every pull request is reading a missing prerequisite, not a judgement about its code.

- **`render` needs a `kendex` on the runner AND a primed source mirror**, which is what the two steps above give it. `kendex verify` re-renders out of the local mirror and never fetches it, so on a runner that has never fetched the source every package reports that where it comes from is unavailable, the proof fails and the answer is `standard`. The priming step fetches the marketplaces the judged tree's own manifest declares into the runner's cache and leaves `subject` exactly as it was committed: it installs nothing and writes no file there. That matters because the classifier refuses a `subject` whose working tree differs from its own HEAD — a step that wrote renders back would have the proof attest to its own repair instead of to the commit it was checked out at. That HEAD is the pull request's merge ref here, since the `subject` checkout names no `ref:`, and the merge-ref checkout is what `kendex verify` weighs, while the changed paths come from a range ending at `--head`; every way those two commits differ costs a package its row, so the difference is conservative rather than exact. The proof reads the document `kendex verify --scope project --json` prints, and nothing else kendex prints: one record per checked item with its state and the positions it occupies, under a `version` the classifier pins. That is why the install step pins a version: a kendex that rejects `--json` answers `standard cause=verify-refused`, one that accepts the flag but prints no such document, or another version of it, answers `standard cause=verify-document-unreadable`, neither fails the job, and the pin is the consumer's own to move once a newer build has been tried against its lanes. **The pin has to name a build whose `kendex verify --json` prints a version 1 document**, which every release up to and including v5.0.1 lacks; on those every diff answers `standard`, the `render` class included. The repository publishes one pre-release per main build, tagged `main-build-<n>-<attempt>-<sha>`, and the installer takes that tag as a version like any other; it then tries a desktop AppImage the tag does not name, which 404s, says so and leaves the command installed. A consumer that will not pay for these steps has no `render` class and keeps publishing `harness_only` beside `change_class` to gate its lanes.
- **`render` reaches only the paths a passing record of that run owns.** Each record carries the positions the engine resolved for it: a file kendex owns whole, a tree it owns whole, or keys inside a shared registry file. A file or tree position owns its path and the paths under it. A keys position owns its path only where the same record says `foreign: unchanged` — kendex's own judgement, made with the base revision the classifier hands `kendex verify --base` off `harness-only`'s `base-rev:` line, that the rest of that file is as the base held it — and answers `standard cause=render-path-partial` otherwise. A changed path no passing position covers answers `standard cause=render-path-unowned`. kendex's own `.kendex-lock.json` and `.kendex-generated.json` are the positions of the `record` and `inventory` records, which pass only where kendex found each file as it would write it, so a refresh is a render and a hand edit to either is not; nothing about the install record is weighed by the classifier itself, because it is a file the pull request's own branch writes. `.gemini/settings.json` is refused ahead of every render as a configuration source: the record kendex prints for it weighs one key of a document whose other keys decide what that harness runs. `DEVELOPMENT.md` § Invariants lists the registry files that refuse the measured classes below the render branch.
- **The proof's cost grows with the installed item count, not with the diff.** `kendex verify --scope project` re-renders every installed item whatever the change touched, which is why the job carries a `timeout-minutes` of its own ahead of every lane.
- **`ORCH_SIZE_RENDER_ROOTS` belongs in the classify step's `env:`**, as above. The classifier fixes its render roots from its own environment and will not read them out of the judged tree, so a consumer whose harness directories differ from `.agents .claude .codex .pi` sets them there; otherwise a source and the render mirroring it are counted twice and the measured classes come out more conservative.
- **`ORCH_SIZE_TEST_PATHS` belongs there too, where the defaults do not fit.** The classifier passes it from its own environment for the same reason, so a consumer whose test files live outside orch's default test globs sets it in that step; otherwise every one of those files is counted as production code and a diff that is mostly tests loses `micro` or `small`. Left unset, orch's defaults apply.
- **`trivial`, `micro` and `small` need the orch package installed beside harness-ci**, since the line count all three are judged on is orch's, as is the path list all three are refused by. Only the ceilings belong to `micro` and `small` alone. Without that sibling those three classes are unreachable and the answer is `standard`. `render` reads nothing of orch's and is the one class a checkout without it can still reach.
- **`--base` must name a commit the `subject` checkout holds**, which `fetch-depth: 0` gives. The classifier measures the range this call names, so nothing depends on what the runner thinks the default branch is called.

**The class is never asserted by the change's author.** The script reads no label, branch name or pull request title, takes no flag that would carry one, and reads no configuration out of the tree it judges.

## Verifying an adoption

Two probe PRs against the adopting repository:

1. **Harness-only** — touch one file under `.agents/`. The heavy lanes report `skipped`, and every required context reports green.
2. **Mixed** — touch one file under `.agents/` and one product file. Every lane runs.

Close both once the checks report.
