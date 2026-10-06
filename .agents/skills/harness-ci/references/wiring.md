# Wiring shapes

Four shapes cover the repositories this package targets. Copy one, keep the repository's own job names and required contexts, and change nothing else. A repository under the organization standard reports the aggregate `CI` context by one of the two routes in [§ The CI context](#the-ci-context).

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

A merge group's `base_sha` is the base its queue built it on: the default branch's tip for the first entry, and the head of the group ahead of it for an entry queued behind another, which holds that entry's changes before they land. The range is then the entry's own change, and the change-class settings and every other read of `--base` come from a tree that lands with it. The changes ahead of it are classified by their own groups, and the queue merges this group only after theirs pass, rebuilding it without any entry ahead that leaves the queue.

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
    runs-on: ${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}
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
    runs-on: ${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}
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
    runs-on: ${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}
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
    runs-on: ${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}
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
    runs-on: ${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}
    timeout-minutes: 10
    permissions:
      contents: read
    outputs:
      change_class: ${{ steps.classify.outputs.change_class }}
    env:
      # The event and its endpoints, spelled once for every step that reads
      # the range, so no two steps can judge different ones.
      EVENT: ${{ github.event_name }}
      BASE: ${{ github.event.pull_request.base.sha || github.event.merge_group.base_sha || github.event.before }}
      HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
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
      # change-class reads kendex and the mirror only on its render branch,
      # which it takes where harness-only answers harness_only=true. This is
      # that same read, so the two network steps below run only where the
      # render class is reachable.
      - id: render-reach
        run: >-
          classifier/.agents/skills/harness-ci/scripts/harness-only
          --repo subject --event "$EVENT" --base "$BASE" --head "$HEAD"
      # Neither network step fails this job: without them the render proof is
      # unavailable and the class falls to `standard`. The warning step
      # annotates the run when either did not succeed; a classifier error
      # still fails the job.
      - id: kendex
        name: kendex, for the render class
        if: steps.render-reach.outputs.harness_only == 'true'
        continue-on-error: true
        env:
          # The first release whose `kendex verify --json` prints a version 1
          # document; the render proof reads that document and nothing else.
          # Replace the placeholder with one of the kendex repository's
          # per-main-build pre-release tags, spelled as below, whose
          # `kendex verify --json` prints a version 1 document; copied as it
          # stands, the install fails and the `render` class is out of reach.
          KENDEX_VERSION: main-build-<n>-<attempt>-<sha>
        run: curl -fsSL https://kendex.ai/install.sh | sh -s -- --version "$KENDEX_VERSION"
      - id: mirror
        name: the source mirror the render proof re-renders from
        if: steps.render-reach.outputs.harness_only == 'true'
        continue-on-error: true
        run: kendex source refresh
        working-directory: subject
      - name: warn when the render proof lost a prerequisite
        if: steps.render-reach.outputs.harness_only == 'true' && (steps.kendex.outcome != 'success' || steps.mirror.outcome != 'success')
        env:
          KENDEX_OUTCOME: ${{ steps.kendex.outcome }}
          MIRROR_OUTCOME: ${{ steps.mirror.outcome }}
        run: >-
          echo "::warning title=render proof may be unavailable::kendex install $KENDEX_OUTCOME, source refresh $MIRROR_OUTCOME"
      - id: classify
        env:
          ORCH_SIZE_RENDER_ROOTS: .agents .claude .codex .pi
          # ORCH_SIZE_TEST_PATHS: <globs>
          # Test globs outside orch's defaults belong in the default branch's
          # kendex.settings.toml, which a lane's own classifier run reads too;
          # the classifier reads neither of these two out of the tree it
          # judges.
        run: >-
          classifier/.agents/skills/harness-ci/scripts/change-class
          --repo subject --event "$EVENT" --base "$BASE" --head "$HEAD"
```

Publish `change_class` as the job output in place of `harness_only`, and feed it to `aggregate-needs` as the waiver by naming the authorizing class where the waiver is computed, as `needs.changes.outputs.change_class == 'render'`. `aggregate-needs` keeps its rule unchanged: a skipped job is accepted only against the class that authorized it.

### Through the composite action

The classify step can instead call the composite action kendex publishes, which wraps the same shipped `change-class`, classifies nothing itself, and decides `lanes` from the two verdicts and, where a workflow declares its lanes, one verdict per lane from `lanes` and the paths:

```yaml
      - id: classify
        uses: vanillagreencom/kendex/.github/actions/change-class@main
        env:
          # As in the step above: the classifier reads these from its own
          # environment and never out of the tree it judges.
          ORCH_SIZE_RENDER_ROOTS: .agents .claude .codex .pi
          # ORCH_SIZE_TEST_PATHS: <globs>
        with:
          repo: subject
          event: ${{ env.EVENT }}
          base: ${{ env.BASE }}
          head: ${{ env.HEAD }}
```

- **The classifier is kendex's, at the ref the step names.** The action reads `skills/harness-ci/scripts` out of its own tree, so a fix to the classifier reaches the consumer with no pull request of its own, and the class is never read out of the `classifier` checkout above. A repository outside the organization pins a tag in place of `@main`.
- **`classifier` names another checkout root to read those scripts from.** kendex's own CI passes its default-branch checkout there, because in kendex the action's tree is the pull request's tree. No input carries a class.
- **Its outputs** are `change_class`; `queue_only`, the value of `change-class`'s `queue-only:` line, which `github.sh pr-merge` asks again before the admin route; `docs_only`, the `--mode docs` verdict for the same diff; `lanes` and `lanes_cause`, below; `lane_verdicts`, one verdict per declared lane, [§ Per-lane verdicts](#per-lane-verdicts); `changed_skills`, `changed_crates` and `changed_workflows`, the blank-separated first path segments under `skills/`, `crates/` and `.github/workflows/`; `changed_paths`, one changed path per line; and `proof_reuse`, `proof_reason`, `proof_run`, `proof_tree` and `proof_record`, [§ Proof reuse](#proof-reuse). Publish the ones the lanes read as job outputs, as with `change_class` above.
- **`lanes` is the action's answer to whether the diff runs the lanes.** It is `false` on a `render` or `trivial` class, on `docs_only=true` at any class, and where a passing run already tested the tree and covered every lane the diff would run, and `true` on every other diff. `lanes_cause` names why: `render`, `trivial`, `docs-only` or `proof-reused`, or the class where `lanes` is `true`. The classify step also prints both on a `lanes:` line in its log. A workflow gates its lanes on `lanes` and its aggregate's waiver on `lanes == 'false'`, and names no class; one that declares its lanes adds each lane's verdict as [§ Per-lane verdicts](#per-lane-verdicts) sets out. The rule lives in the action, so a change to it reaches every consumer at the ref the step names, with no workflow edit. A refused step publishes no `lanes`, and the Shape 1 status function then runs every lane.
- **A lane that reads a file in the docs set does not gate on `lanes` or on its own verdict.** The docs set is `harness-only --mode docs`'s: `docs/`, `changelog.d/` and root `.md` or `.markdown` files, and no setting narrows it. A lane such as a build that embeds a Markdown file under `docs/` keeps `needs: changes`, takes `if: ${{ !cancelled() }}` with no `lanes` or verdict term so it runs on every diff, and stays out of every `--skippable` and `--lane`, so a skip of it fails the aggregate. A declared glob does not lift this: every lane verdict is `false` wherever `lanes` is.
- **The `render` class still needs the install and mirror steps above**, in the same job ahead of the action and behind the same `render-reach` step and `if:` gates. That step reads `harness-only` out of the `classifier` checkout, so a consumer that wants the gate keeps that checkout for it; one that drops both pays the network install on every diff.
- **Every refusal exits 2**, and stderr carries a line starting `change-class-action: wiring-error: cause=`, after anything the wrapped scripts printed, so the step goes red rather than publishing an empty class.

### Per-lane verdicts

A workflow with more than one lane declares, in its default branch's `.github/ci-lanes.conf`, the paths each lane reads, and the action answers one verdict per lane:

```
# <lane>[:event-uniform][:queue] <glob>...; `#` starts a comment.
check:event-uniform  src/* tests/* Cargo.toml Cargo.lock
tmux                 tmux/*
bench:queue          benches/*
```

- **A line is a lane name and one or more globs.** A name is lowercase letters, digits, `_` and `-`, starting with a letter or digit. A lane named on several lines reads every glob they give it. A glob is a shell pattern, as the classifier's own path lists are, so `*` also matches `/`: `src/*` claims every path under `src/`.
- **`:event-uniform` after the name marks a lane that does the same work on every event**: no job or step of it is gated on `github.event_name`, and no verdict of it reads the event's base, as a range check over `--base` does. A merge group's base is not its pull request's, and a proof record names a tree and no base, so a lane whose verdict reads the base judges on each event a range no other event's run judged. Only a marked lane stands down on another event's proof, [§ Proof reuse](#proof-reuse); an unmarked one runs even where the proving run's record covers it, because the work it does on this event may be work that run never did. A lane named on several lines is marked where any of them marks it, and both marks may follow one name in either order. Any other suffix, or a mark with no name before it, is a malformed name.
- **`:queue` after the name defers a slow lane from the pull request to the merge group.** Where a marked lane's glob matches a changed path, `change-class` answers `queue_only=true`, read off the declaration the pull request's base commit holds; `change-class --help` names the cause it prints, which may be one it reads ahead of the lane. On `pull_request`, the action then answers that lane `false`, its `lane:` line saying `cause=queue-deferred` with the path and glob, so `github.sh pr-merge` takes the merge queue rather than the admin route. The deferral needs that run's `queue_only=true`: where `change-class` answered otherwise, from a base declaration that differs from `lanes-from`'s for example, the lane runs with `cause=queue-unconfirmed`. On `merge_group`, the push to the default branch and every other event the mark changes nothing: the lane runs where its verdict reads `true`. The pull request's record says the lane did not run, so a merge group never stands it down on that run's proof. A marked lane that only a path no lane claims turned on runs on the pull request too, since no glob of its own put the change in the queue. The deferred lane's skip is authorized by its own verdict, so the aggregate needs nothing new. A repository whose declaration marks no lane gets no change. `HARNESS_CI_QUEUE_PATHS` stays the input for paths that need the queue but no lane of their own; the mark is the input for a lane the pull request skips.
  - **Refresh the install before the mark lands.** `pr-merge` reads `queue_only` through the `change-class` beside the `github.sh` it runs, and a render from before the mark answers `false` for the lane's paths. CI sees two checkouts a merge can run it from: the default branch, the `lanes-from` checkout, and the pull request's head, which the worktree `submit-pr` runs it in holds. The action defers a lane only where both carry `.agents/skills/harness-ci/scripts/lib/ci-lanes.sh`, the render's reader of the mark. Where either lacks it, the lane runs with `cause=queue-reader-absent` and `tree=lanes-from`, `tree=judged` or both, and one `::warning`. A pull request branched before the refresh runs the lane until it is rebased onto it, and a head that deletes its reader only makes the lane run.
  - **Sync the merging checkout before the mark lands.** No CI run sees the checkout that runs `pr-merge` at merge time; in orch that is the main checkout, which `sync-base` keeps current. It must carry the refresh before a mark reaches the default branch, or it reads a deferred pull request as free to take the admin route.
  - **Removing or narrowing a mark needs the open pull requests re-run.** `pr-merge` asks `change-class` again at merge time, off the base tip's declaration. A pull request whose CI deferred the lane before the mark went reads `queue_only=false` there and can take the admin route with the lane never run. Re-run CI on each such pull request, or merge it through the queue, before it merges.
- **Pass the default branch's checkout as `lanes-from`.** The action reads the declaration there, never out of `repo`, because the pull request's author could edit its own copy to stand a lane down; it refuses a `lanes-from` naming the same checkout as `repo` with exit 2. A pull request that changes the declaration is therefore judged by the one already merged.
- **The verdict** is `false` wherever `lanes` is `false`. Otherwise, on a pull request, a `:queue` lane deferred as above is `false` first. Every other lane is `true` where a changed path matches one of its globs, and `false` where none does, with two exceptions that turn every lane on: a changed path no lane claims and the docs set does not hold, and a diff whose changed paths could not be read. A docs-set path no lane claims turns nothing on. The classify step prints one `lane:` line per lane naming the path and glob, or the cause, behind its verdict.
- **An absent or malformed declaration publishes no verdict**, and the step still succeeds: failing it would redden every pull request, the one repairing the default branch's declaration included. The lanes and the aggregate below then fall back to `lanes` alone, as a workflow with no declaration reads it, which is also what an adopting repository gets until its declaration reaches the default branch. The step prints a `lane-declaration:` line with the state and a `::warning` annotation. A malformed line is a name outside the set above or a lane with no glob; a file naming no lane, or one the step cannot read, is malformed too.
- **Republish the verdicts as step outputs.** A composite action publishes only the outputs it declares, so `lane_verdicts` arrives as one `lane_<name>=true|false` line per lane. A step after the action appends it to its own `$GITHUB_OUTPUT`, and the job publishes each line under its own name:

  ```yaml
      outputs:
        lanes: ${{ steps.classify.outputs.lanes }}
        lane_check: ${{ steps.lanes.outputs.lane_check }}
      steps:
        # ...the classify step above, with `lanes-from: classifier`
        - id: lanes
          env:
            LANE_VERDICTS: ${{ steps.classify.outputs.lane_verdicts }}
          run: printf '%s\n' "$LANE_VERDICTS" >>"$GITHUB_OUTPUT"
  ```

- **Each lane reads `lanes` and its own verdict, and runs unless either is `false`.** A lane with no verdict, because no declaration was read or the job output misspells its name, is decided by `lanes` alone:

  ```yaml
    check:
      needs: changes
      if: ${{ !cancelled() && (needs.changes.result != 'success' || (needs.changes.outputs.lanes != 'false' && needs.changes.outputs.lane_check != 'false')) }}
  ```

- **The aggregate authorizes each lane's skip by `lanes` or by that lane's own verdict.** Keep `--waiver` on `lanes == 'false'` and each gated job's `--skippable`, and add `--lane JOB=LANE` per gated job; `aggregate-needs` reads the verdict, the classifier job's `lane_<LANE>` output, out of the `--results` it was handed, and accepts the job's skip where the waiver or that verdict stood it down. A job takes one `--lane`, and a second is refused; two jobs that read one lane, a Linux and a macOS leg of one suite, each pass `--lane JOB=LANE` naming that lane.

### Proof reuse

A passing run of the same workflow that already tested the tree this run tests stands down what it covered, so a merge through a queue tests one tree once rather than on the pull request, in the merge group and on the push. The action's `proof` script decides it; the key is the tree, which carries the workflow file, and never a label, a title, a branch name or any other field an author writes. Two events reuse a proof, and each names the run that proved it:

- **A merge group** reuses the `pull_request` run of the pull request its queue branch names, `gh-readonly-queue/<default branch>/pr-<number>-<sha>`: a completed, successful run of this workflow in this repository whose pull request is that number at the head the run tested, and whose record names the group's tree. That run tested the merge commit GitHub built for the pull request, and the group tests the base with the queued entries applied, by whatever merge method the queue uses, so the two trees are equal where the base has not moved and no other entry sits ahead of this one. A group whose tree differs finds no record of it.
- **The merge queue's push to the default branch** reuses the `merge_group` run of the pushed sha, under the rules of hyprtrade's `tools/ci-merge-proof`: a non-forced push whose actor and triggering actor are `github-merge-queue[bot]` and whose `after` is the judged sha, and exactly one completed, successful `merge_group` run of this workflow for that sha, from a `gh-readonly-queue/<default branch>/` branch of this repository.

The pieces:

- **The record.** On `pull_request` and `merge_group` the action uploads the directory holding the record as an artifact named `change-class-proof-<tree>`, so the artifact holds one member, `record`, with `tree`, `workflow`, `event`, `change_class`, `docs_only`, `covers`, the lane lines `covers=lanes` carries, and one `changed_path` line per changed path. `covers` is the action's view of what has passed on the tree in the lanes a declaration names, not a list of the jobs the workflow ran, and the header of `.github/actions/change-class/classify` is its one statement: `all`, `lanes` with a line per lane, or `none`. A run that reads no declaration records `all` only where the workflow passes `covers-all-lanes: true`, as the template does. That input is the adopter's assertion that every lane runs wherever `lanes` is `true` and does the same work on every event, as the `:event-uniform` mark in [§ Per-lane verdicts](#per-lane-verdicts) defines it; a workflow that cannot say so leaves it unset and gets no reuse. Its retention is 30 days, so a pull request that waits longer between its last push and its merge runs its lanes again. Uploading needs no permission.
- **The permission.** The classify step reads the workflow's runs and their artifacts with `github.token`, so the classifying job grants `actions: read` beside `contents: read`, as the template's `changes` job does. Without it the read fails, the step prints one refusal and the lanes run.
- **What stands down.** With no declaration read, `lanes` turns `false` with `lanes_cause=proof-reused` where the record covers all lanes. With a declaration, each lane marked `:event-uniform` whose classified verdict is `true` and which the record covers turns `false`, its `lane:` line saying `cause=proof-reused run=<id>`; where every lane the diff would run turns `false`, `lanes` turns `false` with it. An unmarked lane whose classified verdict is `true` and which the record covers keeps it, its `lane:` line adding `proof-held=not-event-uniform run=<id>`. A lane the proving run skipped, or did not name, keeps its classified verdict, and a `lanes=false` from `render`, `trivial` or `docs-only` stays as it is.
- **Every refusal is one line and the lanes run.** The step prints `proof: reuse=false reason=<key>` with what it saw, and `proof_reason` carries the key: `ineligible-event`, `ineligible-push`, `ineligible-merge-group`, `invalid-input`, `no-github-sha`, `tree-unreadable`, `event-unreadable`, `gh-unavailable`, `unzip-unavailable`, `no-token`, `workflow-api-error`, `malformed-workflow`, `runs-api-error`, `malformed-runs`, `missing-proof`, `ambiguous-proof`, `mismatched-proof`, `artifacts-api-error`, `malformed-artifacts`, `missing-record`, `expired-record`, `record-download-error`, `record-unreadable` or `record-mismatch`. An ineligible event makes no API call. `proof_reuse=true` with `proof_reason=exact-proof` names the run in `proof_run`.
- **A workflow that selects its jobs itself** reads `proof_record`, the proving run's record, and re-derives what that run ran from its `event`, `change_class`, `docs_only` and `changed_path` lines with the same selection it applies to its own diff, standing down each job that run ran and that does the same work on every event, as the `:event-uniform` mark in [§ Per-lane verdicts](#per-lane-verdicts) defines it; a job whose verdict reads the event's base keeps running whatever the record says. The record's `event` line matters where the selection reads the event: a job the selection runs in the merge group alone is one the pull request's run never ran, so it keeps running there. Such a workflow reads no `lanes` and no lane verdict, and leaves `covers-all-lanes` unset: its jobs are not the action's lanes, so a record's `covers` line says nothing about what it ran. The template's lanes gate on `lanes` and their own verdict, so the template needs the permission above and `covers-all-lanes: true`, and, once it declares lanes, a `:event-uniform` mark on each lane that does the same work on every event.

### What each class needs, and what it costs to leave out

`standard` needs nothing and is what every unproven diff answers, so a consumer reading `standard` on every pull request is reading a missing prerequisite, not a judgement about its code.

- **`render` needs a `kendex` on the runner AND a primed source mirror**, which is what the two steps above give it. `kendex verify` re-renders out of the local mirror and never fetches it, at the commits the install record names, each of those on the history of the revision the mirror resolves its source to and no older than the commit the base's record names. On a runner that has never fetched the source every package reports that where it comes from is unavailable, the proof fails and the answer is `standard`. The priming step fetches the marketplaces the judged tree's own manifest declares into the runner's cache and installs nothing in `subject`. `kendex verify` weighs a private checkout of `--head` that the classifier makes itself, never `subject`'s working tree, which here sits at the pull request's merge ref because the `subject` checkout names no `ref:`. The proof reads the document `kendex verify --scope project --json` prints, and nothing else kendex prints: one record per checked item with its state and the positions it occupies, under a `version` the classifier pins. That is why the install step pins a version: a kendex that rejects `--json` answers `standard cause=verify-refused`, one that accepts the flag but prints no such document, or another version of it, answers `standard cause=verify-document-unreadable`, neither fails the job, and the pin is the consumer's own to move once a newer build has been tried against its lanes. **The pin has to name a build whose `kendex verify --json` prints a version 1 document**, which every release up to and including v5.0.1 lacks; on those every diff answers `standard`, the `render` class included. **The pin also has to take `kendex verify --at-record`**, which the classifier always passes so that a refresh the catalog has moved past since its push keeps the `render` class; a build without the flag rejects it and every diff answers `standard cause=verify-refused`. The repository publishes one pre-release per main build, tagged `main-build-<n>-<attempt>-<sha>`, and the installer takes that tag as a version like any other; it then tries a desktop AppImage the tag does not name, which 404s, says so and leaves the command installed. A consumer that will not pay for these steps has no `render` class and keeps publishing `harness_only` beside `change_class` to gate its lanes.
- **`render` reaches only the paths a passing record of that run owns.** Each record carries the positions the engine resolved for it: a file kendex owns whole, a tree it owns whole, or keys inside a shared registry file. A file position owns exactly its path; a tree position owns its path and the paths under it. A keys position owns its path only where the same record says `foreign: unchanged` — kendex's own judgement, made with the base revision the classifier hands `kendex verify --base` off `harness-only`'s `base-rev:` line, that the rest of that file is as the base held it — and answers `standard cause=render-path-partial` otherwise. A surviving path no passing position covers answers `standard cause=render-path-unowned`. Deletion requirements and refusals are in `change-class --help`. kendex's own `.kendex-lock.json` and `.kendex-generated.json` are the positions of the `record` and `inventory` records, which pass only where kendex found each file as it would write it, so a refresh is a render and a hand edit to either is not; nothing about the install record is weighed by the classifier itself, because it is a file the pull request's own branch writes. `.gemini/settings.json` is refused ahead of every render as a configuration source: the record kendex prints for it weighs one key of a document whose other keys decide what that harness runs. [DEVELOPMENT.md § Invariants](https://github.com/vanillagreencom/kendex/blob/main/skills/harness-ci/DEVELOPMENT.md#invariants) lists the registry files that refuse the measured classes below the render branch.
- **On `pull_request` the `render` verdict describes the head commit alone.** The proof weighs `--head`, not the merge of the head with a base that moved since. The merged tree is proved again only on `merge_group`, or on the push to the default branch; a consumer with no merge queue gets no second proof before the merge.
- **The proof's cost grows with the installed item count, not with the diff.** `kendex verify --scope project` re-renders every installed item whatever the change touched, which is why the job carries a `timeout-minutes` of its own ahead of every lane.
- **`ORCH_SIZE_RENDER_ROOTS` belongs in the classify step's `env:`**, as above. The classifier fixes its render roots from its own environment and will not read them out of the judged tree, so a consumer whose harness directories differ from `.agents .claude .codex .pi` sets them there; otherwise a source and the render mirroring it are counted twice and the measured classes come out more conservative.
- **`ORCH_SIZE_TEST_PATHS` belongs in the default branch's settings, where the defaults do not fit.** The classifier reads it from its own environment, else from the `[env]` table of `kendex.settings.toml` or `.kendex/settings.toml` as the commit `--base` names holds them. A lane's own classifier run through `dev-validate-run` carries no classify-step environment, so a glob set only in the step's `env:` reaches CI alone. Without the glob, the classifier counts a test file outside orch's default test globs as production code and places it in a subsystem of its own: a script beside its fixture then loses `micro` or `small`. A step `env:` value outranks the settings file. Left unset in both, orch's defaults apply.
- **`trivial`, `micro` and `small` need the orch package installed beside harness-ci**, since the line count all three need read is orch's, as is the path list all three are refused by; only a plan-only `trivial` holds no ceiling against it. Only the ceilings belong to `micro` and `small` alone. Without that sibling those three classes are unreachable and the answer is `standard`. `render` reads nothing of orch's and is the one class a checkout without it can still reach.
- **`--base` must name a commit the `subject` checkout holds**, which `fetch-depth: 0` gives. The classifier measures the range this call names, so nothing depends on what the runner thinks the default branch is called.

**The class is never asserted by the change's author.** The script reads no label, branch name or pull request title, takes no flag that would carry one, and reads no configuration out of the tree it judges.

## The CI context

Every repository under the organization standard reports one aggregate context named `CI` on both `pull_request` and `merge_group`, green only when every job the repository runs is green. review-gate's `validate-standard.sh` checks both legs as its `standard-ci-context` row. Which contexts the repository's required-checks ruleset requires is the review-gate skill's references/adoption.md § Repo-side wiring. One of two routes gives the repository the `CI` context:

- **The template.** Copy [the CI template](#the-ci-template) and move the repository's lanes into it.
- **The repository's own workflow.** Keep the workflow and its job names, and put `merge_group:` beside `pull_request:` under `on:`. Add Shape 1's `changes` job and give every lane its condition, then add Shape 3's aggregate with `name: CI`, its `needs:` naming every job in the workflow and each gated lane in a `--skippable`. A lane in another workflow moves into this one, because a job waits only on jobs in its own workflow. An aggregate the repository already runs under another name takes the name `CI` rather than running beside a second one.

The order of this change and the ruleset change, and the check that confirms both, are the review-gate skill's references/adoption.md § Repo-side wiring.

## The CI template

[`../templates/ci.yml`](../templates/ci.yml) is the workflow a repository copies to `.github/workflows/ci.yml`. Every repository reports `CI`, per [§ The CI context](#the-ci-context), so the template fixes the names every repository reports: the job carrying `CI`, and the classifying job `Classify the diff`. Keep both names and change the rest to fit.

- **Every lane goes in this workflow.** A job can wait only on jobs in its own workflow, so a lane left in another workflow is a lane no required context holds. Replace the placeholder `test` job with the repository's lanes, one job each: declare each in `.github/ci-lanes.conf`, marked `:event-uniform` where it does the same work on every event, publish its `lane_<name>` output from the `changes` job, and give it the same `needs:`, and the condition and aggregate arguments [§ Per-lane verdicts](#per-lane-verdicts) sets out. Name each lane in CI's `needs:`. A lane that reads a file in the docs set is the exception: it drops the `lanes` and verdict terms, runs on every diff and stays out of `--skippable` and `--lane`, per [§ Through the composite action](#through-the-composite-action). Copied as it stands, the placeholder fails, and `CI` fails with it.
- **Each event runs the lanes its own diff calls for, less the ones a passing run of the same tree already ran.** The template runs on `pull_request` and `merge_group`, the classifier judges each event's own diff, and every gated lane reads the same answers on both, per [§ Per-lane verdicts](#per-lane-verdicts). A merge group whose tree its pull request's run tested stands down what that run covered, per [§ Proof reuse](#proof-reuse), so the template passes `covers-all-lanes: true` for a workflow with no declaration, and each lane the adopter declares carries `:event-uniform` where it does the same work on every event, as [§ Per-lane verdicts](#per-lane-verdicts) defines it. The declaration is read from the `classifier` checkout, the default branch. No line of the template reads the change class. A merge queue can batch several pull requests into one merge group, so the group classifies their combined diff, and a docs-only pull request batched with a code change runs every lane the group calls for.
- **The render prerequisites are Shape 4's.** The template pins a kendex main build and reads its installer at the same sha. Move both together, to a build whose `kendex verify --json` prints a version 1 document. Neither network step fails the job, and neither does the step ahead of them that reads `harness-only` out of the default branch, which the adoption pull request and its merge group do not have yet. Without any of the three the `render` class is out of reach, and every other class is judged as usual.
- **Every job runs on `vars.CI_RUNNER_2V`, falling back to `ubuntu-latest`.** The organization variable names the shared runner; a repository without it runs on GitHub's hosted runner.
- **CI is Shape 3's aggregate.** It runs under `always()`, and `aggregate-needs` accepts a skipped lane only where the classifier succeeded and a verdict stood it down, per [§ Per-lane verdicts](#per-lane-verdicts).
- **The secrets step scans each pull request's commits with default-branch code.** Land commit-guards on the default branch before adopting the template. An adoption pull request that adds both fails the secrets step because the `guards` checkout has no installer or scanner. The `guards` checkout supplies the pinned gitleaks installer and the scanner, including its libraries. The separate `subject` checkout holds the pull request's merge ref and full history. The step runs in `subject` and executes the scripts by their absolute paths in `guards`, so an edit to the pull request's scanner cannot disable the scan. Its `--policy-root` reads the exclusion list and its setting from `guards` too, so a pull request that excludes its own credential is still refused. A scanner without `--policy-root` refuses the flag on every pull request, so a repository that updates its copy of the template first merges the kendex refresh that gives the default branch a commit-guards with the flag. It runs on every pull request, including one the classifier clears. A repository without commit-guards deletes this step and the `guards` checkout.

[`tests/ci-template.test.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/harness-ci/tests/ci-template.test.sh) runs the template's `lanes` step, evaluates its job outputs and conditions per event and action answer, and hands its waiver and aggregate arguments to the real `aggregate-needs`. It also runs the secrets step against a pull request that replaces its scanner and installer with successful exits, excludes every path, and adds a test credential. The trusted scanner still refuses that credential.

## Verifying an adoption

Two probe PRs against the adopting repository:

1. **Harness-only** — touch one file under `.agents/`. The heavy lanes report `skipped`, and every required context reports green.
2. **Mixed** — touch one file under `.agents/` and one product file. Every lane runs.

Close both once the checks report.
