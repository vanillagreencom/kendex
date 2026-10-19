# Wiring shapes

Four shapes cover the repositories this package targets. Copy one, keep the repository's own job names and required contexts, and change nothing else. A repository under the organization standard reports the aggregate `CI` context by one of the two routes in [§ The CI context](#the-ci-context).

Every shape passes the event and the endpoints through `env:` rather than interpolating `${{ }}` into the shell — a workflow expression pasted into a command line is an injection surface.

Every classifier checkout uses `fetch-depth: 0`. The classifier diffs two real commits; a shallow clone holds neither endpoint. An aggregate's `guards` checkout does not need history. The CI template's aggregate also checks out `subject`, with full history, on `pull_request` runs only, for the credential scan; the secrets bullet in [§ The CI template](#the-ci-template) states why.

## Action pinning

Review holds these rules when a consumer adopts or changes a workflow:

- GitHub-owned and third-party actions use a full commit SHA with the release version in a trailing comment, such as `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`. A moved tag cannot change the code a pinned job runs. A harmful release still needs a reviewed pin update. Its likelihood depends on the publisher and its account security.
- This organization's own actions use the default-branch ref, such as `vanillagreencom/kendex/.github/actions/change-class@main`. That ref has the same trust as the default-branch checkout. A harmful change needs an incorrect or compromised merge to that branch. The cost is accepting its reviewed updates before the consumer's next refresh.

Enable GitHub's Dependabot `github-actions` ecosystem in the consumer's `.github/dependabot.yml`. Dependabot opens update pull requests for action tags and commit pins. Review those updates under the rules above. Add this entry to an existing `updates` list, or use this file when none exists:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    ignore:
      - dependency-name: "vanillagreencom/kendex*"
```

The kendex refresh route owns kendex's workflow and action refs.

[GitHub's Dependabot options](https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference) define the configuration.

## The endpoint expressions

```yaml
env:
  EVENT: ${{ github.event_name }}
  BASE: ${{ github.event_name == 'pull_request' && format('{0}^1', github.sha) || github.event.merge_group.base_sha || github.event.before }}
  HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
```

An event outside the three answers `false` on its own — an unset `BASE` needs no guard of yours.

A pull request's base end is `github.sha^1`, the first parent of the merge ref the run checked out: the base that merge commit was built on. Never `github.event.pull_request.base.sha`, the field the GitHub API also reports as `baseRefOid`. GitHub does not move that field when the base branch advances, so it can predate the base branch's tip, and a pull request opened before its base gained a `:queue` mark or a setting is then classified against the base without it. `change-class` reads those settings and that declaration off `--base`. The checkout the classifier diffs, the one `--repo` names or the working directory where no `--repo` is passed, must hold the merge ref and its history for git to resolve the expression; the opening rule's `fetch-depth: 0` covers it.

A re-run keeps the original run's `github.sha`, so it reads that run's merge commit and its base again. Only a new merge ref moves the base end: a push to the pull request's branch, which GitHub's Update branch also makes, builds one on the base branch's tip.

`github.sh pr-merge` asks `change-class` again at merge time, at the base branch's tip, and only where the pull request's recorded base is that tip. The run classified against a base between the recorded base and the tip, and a `:queue` mark or a setting can come and go in between, so no read at merge time stands for the run unless the two are one commit. So on a repository that names `HARNESS_CI_PER_PUSH_REASON`, a pull request whose base moved since it opened takes the merge queue, never the admin route.

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
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
      - id: classify
        env:
          EVENT: ${{ github.event_name }}
          BASE: ${{ github.event_name == 'pull_request' && format('{0}^1', github.sha) || github.event.merge_group.base_sha || github.event.before }}
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
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
      - id: classify
        env:
          EVENT: ${{ github.event_name }}
          BASE: ${{ github.event_name == 'pull_request' && format('{0}^1', github.sha) || github.event.merge_group.base_sha || github.event.before }}
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
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event.repository.default_branch }}
          path: guards
          persist-credentials: false
      - name: the classifier ran and every lane that skipped was told to
        working-directory: guards
        env:
          RESULTS: ${{ toJSON(needs) }}
          HARNESS_ONLY: ${{ needs.changes.outputs.harness_only }}
        run: |
          if [ ! -x .agents/skills/harness-ci/scripts/aggregate-needs ]; then
            echo "::error::missing default-branch helper: guards/.agents/skills/harness-ci/scripts/aggregate-needs"
            exit 1
          fi
          printf '%s\n' "$RESULTS" |
            jq -c 'to_entries | map({job: .key, result: .value.result})'
          .agents/skills/harness-ci/scripts/aggregate-needs \
          --results "$RESULTS" --classifier changes --waiver "$HARNESS_ONLY" \
          --skippable test --skippable build
```

Both halves close a fail-open. Without `if: always()` a skipped lane skips the aggregate too, and a skipped required context satisfies the ruleset with no lane having run. `aggregate-needs` rejects a classifier that did not succeed and any skipped job that a true verdict did not authorize.

Run `aggregate-needs` from the default branch on every event, including `pull_request`, `merge_group` and an adopted `push` trigger. A missing default-branch helper fails `CI` with one `::error::` line naming its path. Keep the trusted checkout unconditional. A pull request must not change the helper that judges its own skipped jobs. Land a new `aggregate-needs` flag in the helper on the default branch first. Then add the flag to `ci.yml`. A pull request that changes both fails its own CI because the default-branch helper cannot read the new flag.

Every trigger the ruleset requires the context on must appear under `on:`, `merge_group` included. A required context that a merge group never produces blocks the queue forever.

## Shape 4 — one change class for every reader

`change-class` answers the wider question: what KIND of change is this diff. It prints `change_class=render|trivial|micro|small|standard` and takes the same event and endpoint flags.

Set `HARNESS_CI_STANDARD_PATHS` in the base endpoint's `kendex.settings.toml` or `.kendex/settings.toml` `[env]` table to blank-separated globs for high-risk paths. The second table wins. Before render proof and size classification, a match selects `standard` with `measured=true` and `cause=repository-standard-path path=<p> glob=<g>`. This includes generated files with proved ownership. The globs use the shared exclusion grammar and add to its exclusions. Unset or empty adds none. Caller environment values and edits in the judged head cannot change this setting for their own classification.

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
      BASE: ${{ github.event_name == 'pull_request' && format('{0}^1', github.sha) || github.event.merge_group.base_sha || github.event.before }}
      HEAD: ${{ github.event.pull_request.head.sha || github.event.merge_group.head_sha || github.event.after || github.sha }}
    steps:
      - name: the classifier, from the default branch
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.event.repository.default_branch }}
          path: classifier
      - name: the tree under judgement
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          path: subject
      # Endpoint ownership permits new head-owned paths for prerequisites.
      # The candidate grants no CI skip; change-class still proves render.
      - id: render-reach
        continue-on-error: true
        run: >-
          classifier/.agents/skills/harness-ci/scripts/harness-only
          --mode render-candidate --repo subject --event "$EVENT" --base "$BASE" --head "$HEAD"
      # Neither network step fails this job: without them the render proof is
      # unavailable and the class falls to `standard`. The warning step
      # annotates the run when either did not succeed; a classifier error
      # still fails the job.
      - id: kendex
        name: kendex, for the render class
        if: steps.render-reach.outputs.render_candidate == 'true'
        continue-on-error: true
        env:
          GH_TOKEN: ""
          GITHUB_TOKEN: ${{ github.token }}
        run: classifier/.agents/skills/review-gate/scripts/install-latest.sh
      - id: mirror
        name: the source mirror the render proof re-renders from
        if: steps.render-reach.outputs.render_candidate == 'true'
        continue-on-error: true
        run: kendex source refresh
        working-directory: subject
      - name: warn when the render proof lost a prerequisite
        if: steps.render-reach.outputs.render_candidate == 'true' && (steps.kendex.outcome != 'success' || steps.mirror.outcome != 'success')
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

The classify step can instead call the composite action kendex publishes. It wraps the same shipped `change-class` and classifies nothing itself. It calls the installed `scripts/lib/change-class.sh` for `lanes` and each declared lane's verdict under [§ Per-lane verdicts](#per-lane-verdicts):

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

This step names no `lanes-from` and passes no `queue-only-default`, so it declares no lane and never stands its lanes down. A workflow that declares lanes adds `lanes-from`, [§ Per-lane verdicts](#per-lane-verdicts); one that takes the queue-only default also passes `queue-only-default: true`, as [the CI template](#the-ci-template) does.

- **The classifier is kendex's, at the ref the step names.** The action reads `skills/harness-ci/scripts` out of its own tree, so a fix to the classifier reaches the consumer with no pull request of its own, and the class is never read out of the `classifier` checkout above. Select the ref under [§ Action pinning](#action-pinning).
- **`classifier` names another checkout root to read those scripts from.** kendex's own CI passes its default-branch checkout there, because in kendex the action's tree is the pull request's tree. No input carries a class.
- **Its outputs** are `change_class`; `queue_only`, the value of `change-class`'s `queue-only:` line, which `github.sh pr-merge` asks again before the admin route; `docs_only`, the `--mode docs` verdict for the same diff; `lanes` and `lanes_cause`, below; `lane_verdicts`, one verdict per declared lane, [§ Per-lane verdicts](#per-lane-verdicts); `changed_skills`, `changed_crates` and `changed_workflows`, the blank-separated first path segments under `skills/`, `crates/` and `.github/workflows/`; and `changed_paths`, one changed path per line. Publish the ones the lanes read as job outputs, as with `change_class` above.
- **`lanes` is the action's answer to whether the diff runs the lanes.** When the installed shared producer is available, it is `false` on a `render` unless a declared lane claims a path the render changes, under the render rule in [§ Per-lane verdicts](#per-lane-verdicts). For non-render classes, it is also `false` on `trivial` or `docs_only=true`. On `pull_request` and `push`, with `queue-only-default: true`, it is `false` wherever `change-class`'s per-push line names the queue-only default, under [§ Per-lane verdicts](#per-lane-verdicts). On `schedule` and `workflow_dispatch` it is `true`. It is `true` on every other diff. `lanes_cause` names why: `render`, `trivial`, `docs-only` or `queue-only` where it is `false`; `full-run` on the nightly run; `render-claim` where a declared lane claims a path a render changes; `queue-only-reader-absent` where a render lacks the stand-down's reader; `queue-only-lanes-from-unset` where the default was asked for with no `lanes-from`; or the class otherwise. The classify step also prints both on a `lanes:` line in its log. A workflow gates its lanes on `lanes` and its aggregate's waiver on `lanes == 'false'`, and names no class; one that declares its lanes adds each lane's verdict as [§ Per-lane verdicts](#per-lane-verdicts) sets out. The shared rules live in the installed `scripts/lib/change-class.sh`, read from the selected classifier checkout. A refused step publishes no `lanes`, and the Shape 1 status function then runs every lane.
- **An older classifier can lack the shared lane producer.** The action sets `lanes=true`, `lanes_cause=lane-producer-unavailable` and an empty `lane_verdicts`, regardless of the class or docs verdict.
- **A lane that reads a file in the docs set does not gate on `lanes` or on its own verdict.** The docs set is `harness-only --mode docs`'s: `docs/`, `changelog.d/` and root `.md` or `.markdown` files, and no setting narrows it. A lane such as a build that embeds a Markdown file under `docs/` keeps `needs: changes`, takes `if: ${{ !cancelled() }}` with no `lanes` or verdict term so it runs on every diff, and stays out of every `--skippable` and `--lane`, so a skip of it fails the aggregate. Under the queue-only default it still runs on every pull-request push: keep such a lane short. A declared glob does not lift this: every lane verdict is `false` wherever `lanes` is.
- **The `render` class still needs the install and mirror steps above**, in the same job ahead of the action and behind the same `render-reach` step and `if:` gates. That step reads `harness-only` out of the `classifier` checkout, so a consumer that wants the gate keeps that checkout for it; one that drops both pays the network install on every diff.
- **Every refusal exits 2**, and stderr carries a line starting `change-class-action: wiring-error: cause=`, after anything the wrapped scripts printed, so the step goes red rather than publishing an empty class.

### Per-lane verdicts

A workflow with more than one lane declares, in its default branch's `.github/ci-lanes.conf`, the paths each lane reads. The installed shared producer computes one verdict per lane. These rules need that producer; [§ Through the composite action](#through-the-composite-action) defines the older-classifier result:

```
# <lane>[:queue][:nightly] <glob>...; `#` starts a comment.
check         src/* tests/* Cargo.toml Cargo.lock
tmux          tmux/*
bench:queue   benches/*
mac:nightly   macos/* src/platform/macos/*
```

- **A line is a lane name and one or more globs.** A name is lowercase letters, digits, `_` and `-`, starting with a letter or digit. A lane named on several lines reads every glob they give it. A glob is a shell pattern, as the classifier's own path lists are, so `*` also matches `/`: `src/*` claims every path under `src/`.
- **With the queue-only default the pull request runs no lane; the merge group proves the head.** A repository that does not set `HARNESS_CI_PER_PUSH_REASON` in its base commit's settings reads `queue_only=true` for every change, whichever cause `change-class --help` names for it, and prints `per-push: state=unset`, so `github.sh pr-merge` never takes the admin route. Where the workflow passes `queue-only-default: true`, as the template does, the action then answers `lanes=false` with `lanes_cause=queue-only` on `pull_request` and `push`, and every lane verdict `false`. The aggregate accepts the skips through the waiver on `lanes == 'false'`. The stand-down reads that per-push line, never the cause, so a change to a path on the shipped `queue` list of orch's narrow-change.conf stands down too. A workflow that passes no input, a per-push line reading `set` or `unread`, and a run where `change-class` printed no answer run the lanes as below: a repository that names a reason runs its lanes on every pull-request push and defers only its `:queue` lanes.
  - **The default reaches a workflow only through its own edit.** The action stands lanes down only for a workflow that passes the input, so a `ci.yml` copied before the default keeps its lanes after a catalog refresh delivers the render that reads the setting. The adoption order is: the catalog refresh merged on the default branch, the merging checkout synced, then `queue-only-default: true` added to the copied `ci.yml`.
  - **Refresh the install before the default lands.** `pr-merge` reads `queue_only` through the `change-class` beside the `github.sh` it runs, and a render from before `HARNESS_CI_PER_PUSH_REASON` answers `false` where the base sets `HARNESS_CI_QUEUE_PATHS`. The action stands the lanes down only where the `lanes-from` checkout and the judged head both carry `.agents/skills/harness-ci/scripts/change-class` reading that setting. Where either lacks it, the lanes run with `lanes_cause=queue-only-reader-absent` and one `::warning` naming `lanes-from`, `judged` or both. With no `lanes-from` no default-branch render can be read, so the lanes run with `lanes_cause=queue-only-lanes-from-unset` and one `::warning` asking for the default branch's checkout there.
  - **Sync the merging checkout before the default lands.** No CI run sees the checkout that runs `pr-merge`; in orch that is the main checkout, which `sync-base` keeps current.
- **`:nightly` after the name marks a platform lane**: macOS, Windows, a GPU or a larger runner. On `pull_request`, `merge_group` and `push` it runs only where one of its own globs matches a changed path, the declaration comparison selects it, or the diff's paths could not be read; a path no lane claims does not turn it on. On `schedule` and `workflow_dispatch`, the template's nightly full run on the default branch, it runs across all paths with every other lane. A failed declaration comparison still runs it. Its skip is authorized by its own verdict through the existing `--lane JOB=LANE`, so `aggregate-needs` takes no new flag. A red nightly run reaches the overseer through orch's `oversee-watch`, which reads the latest completed push and scheduled run of `.github/workflows/ci.yml` on `main` beside kendex's `skill-tests.yml`, each event its own incident.
- **`:event-uniform` is accepted and ignored.** It marked a lane for the retired proof reuse. A declaration that still carries it reads as one without it, so drop it at the next edit.
- **`:queue` after the name defers a slow lane from the pull request to the merge group.** Where a marked lane's glob matches a changed path, `change-class` answers `queue_only=true`, read off the declaration the base end [§ The endpoint expressions](#the-endpoint-expressions) names holds; `change-class --help` names the cause it prints, which may be one it reads ahead of the lane. On `pull_request`, the action then answers that lane `false`, its `lane:` line saying `cause=queue-deferred` with the path and glob, so `github.sh pr-merge` takes the merge queue rather than the admin route. The deferral needs that run's `queue_only=true`: where `change-class` answered otherwise, from a base declaration that differs from `lanes-from`'s for example, the lane runs with `cause=queue-unconfirmed`. On `merge_group`, the push to the default branch and every other event the mark changes nothing: the lane runs where its verdict reads `true`. A marked lane that only a path no lane claims turned on runs on the pull request too, since no glob of its own put the change in the queue. The deferred lane's skip is authorized by its own verdict, so the aggregate needs nothing new. A repository whose declaration marks no lane gets no change. Where the whole pull request stands down under the queue-only default, the mark changes nothing; it decides on a repository that names `HARNESS_CI_PER_PUSH_REASON`, whose lanes run on every queue-only change, and in a workflow that passes no `queue-only-default`. `HARNESS_CI_QUEUE_PATHS` stays the input for paths that need the queue but no lane of their own; the mark is the input for a lane the pull request skips.
  - **Refresh the install before the mark lands.** `pr-merge` reads `queue_only` through the `change-class` beside the `github.sh` it runs, and a render from before the mark answers `false` for the lane's paths. CI sees two checkouts a merge can run it from: the default branch, the `lanes-from` checkout, and the pull request's head, which the worktree `submit-pr` runs it in holds. The action defers a lane only where both carry `.agents/skills/harness-ci/scripts/lib/ci-lanes.sh`, the render's reader of the mark. Where either lacks it, the lane runs with `cause=queue-reader-absent` and `tree=lanes-from`, `tree=judged` or both, and one `::warning`. A pull request branched before the refresh runs the lane until it is rebased onto it, and a head that deletes its reader only makes the lane run.
  - **Sync the merging checkout before the mark lands.** No CI run sees the checkout that runs `pr-merge` at merge time; in orch that is the main checkout, which `sync-base` keeps current. It must carry the refresh before a mark reaches the default branch, or it reads a deferred pull request as free to take the admin route.
- **Pass the default branch's checkout as `lanes-from`.** The action refuses a `lanes-from` naming the same checkout as `repo` with exit 2. It uses default-branch claims for every changed path except `.github/ci-lanes.conf`. This base-only trust choice prevents a branch-added claim from taking a path out of a required lane. A new fixture uses an existing default-branch glob when that glob claims it. When the declaration itself changes, the action reads both copies with `ci_lanes_read`: the default-branch checkout and the commit `head` names in `repo`. For that path alone, it selects each lane whose name, claim set, `:queue` mark or `:nightly` mark changed, including lanes present in only one copy. Reordered or repeated globs do not change a claim set. An `:event-uniform` edit alone selects no lane. The action publishes the union of lane names. A declaration change alone never defers a queue lane. When an ordinary path also matches that lane's default-branch glob, it retains normal queue deferral in either path order. A missing, unreadable or malformed copy keeps the all-lanes fallback.
- **A proved render runs the lanes that claim a path it changes.** Render proof shows the rendered files equal their sources; it does not show that the consumer's tests pass against them, nor that consumer code still finds a moved input. The action uses the classifier's resolved diff endpoints with `--no-renames` to read every changed path: modified in place, added or deleted. It checks each against default-branch claims. With rename pairing off, both ends of a move are changed paths, since the renderer records paths and bytes without move identity. A render whose changed paths are all unclaimed keeps `lanes=false`. A match sets `lanes=true` with `lanes_cause=render-claim`. The events a claimed lane then runs on depend on two conditions: the workflow passes `queue-only-default: true`, and the base commit's settings name no `HARNESS_CI_PER_PUSH_REASON`. Where both hold, `pull_request` and `push` stand every lane down under the queue-only default above, and a claimed lane runs in the merge group. Where either fails, a claimed lane runs on `pull_request`, `merge_group` and `push`, and a `:queue` lane defers on `pull_request` only, under the `:queue` rule above. A workflow that declares lanes but passes no input takes the second route with no reason named: the [§ Through the composite action](#through-the-composite-action) step with `lanes-from` added, or a `ci.yml` copied before the default. A claimed lane that runs names `cause=render-claim`, the path and the glob on its `lane:` line. Lanes no match reaches stay `false`.
- **The verdict** is `true` for every lane on the nightly full run, and `false` wherever `lanes` is `false`. A render follows the render rule above. Otherwise, a failed declaration comparison runs every lane before queue deferral. On a pull request with no such failure, a `:queue` lane deferred as above is `false`. A diff whose changed paths could not be read then turns every remaining lane on, `:nightly` lanes included. A `:nightly` lane follows its own rule above. Every remaining lane is `true` where a changed path matches one of its default-branch globs or the declaration comparison selects it, and `false` where neither does. An ordinary changed path outside the docs set that no default-branch lane claims turns every remaining lane on. The declaration path uses its comparison instead of glob matching. A docs-set path no lane claims turns nothing on. The classify step prints one `lane:` line per lane naming the path and glob, or the cause, behind its verdict.
- **An absent or malformed default-branch declaration publishes no verdict**, and the step still succeeds: failing it would redden every pull request, the one repairing the default branch's declaration included. The lanes and the aggregate below then fall back to `lanes` alone, as a workflow with no declaration reads it, which is also what an adopting repository gets until its declaration reaches the default branch. The step prints a `lane-declaration:` line with the state and a `::warning` annotation. A malformed line is a name outside the set above or a lane with no glob; a file naming no lane, or one the step cannot read, is malformed too.
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

### What each class needs, and what it costs to leave out

`standard` needs nothing and is what every unproven diff answers, so a consumer reading `standard` on every pull request is reading a missing prerequisite, not a judgement about its code.

- **`render` needs a `kendex` on the runner AND a primed source mirror**, which is what the two steps above give it. `kendex verify` re-renders out of the local mirror and never fetches it, at the commits the install record names, each of those on the history of the revision the mirror resolves its source to and no older than the commit the base's record names. On a runner that has never fetched the source every package reports that where it comes from is unavailable, the proof fails and the answer is `standard`. The priming step fetches the marketplaces the judged tree's own manifest declares into the runner's cache and installs nothing in `subject`. `kendex verify` weighs a private checkout of `--head` that the classifier makes itself, never `subject`'s working tree, which here sits at the pull request's merge ref because the `subject` checkout names no `ref:`. The proof reads row, position and count evidence only from the document `kendex verify --scope project --json` prints, under a `version` the classifier pins. On a failed call, it also reads stderr for the stable remedy fields `verb=source operation=refresh`. Those fields select `cause=source-mirror-missing`; human prose grants no proof. The shared refresh caller can instead obtain the released-caller ownership proof in [SKILL.md](../SKILL.md). That proof owns only the caller. Other excluded paths still need a supporting verifier. The install step uses review-gate's `install-latest.sh` from the trusted default branch. It selects the stable release on the trusted checkout's refresh caller major-tag commit. A checkout with no refresh caller uses the latest stable release. It fetches the installer at the selected commit. A fixed old build can reject a newer refresh's content or install record. The selected release must support `verify --json` with document version 1 and `verify --at-record`. An unsupported release answers `standard cause=verify-refused` or `standard cause=verify-document-unreadable` and runs product checks. A refresh produced by an unreleased engine needs a compatible release before it can obtain the render waiver. The candidate answer from `harness-only --mode render-candidate` gates only the install and mirror steps and grants no CI skip.

**The class is never asserted by the change's author.** The script reads no label, branch name or pull request title, takes no flag that would carry one, and reads no configuration out of the tree it judges.

## Optional native cache

Use [GitHub's native cache controls](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching) when a lane needs a cache.

- Set `cache-mode` at workflow or job level to the access the job needs: `read` restores only, `write` restores and saves, `write-only` saves only, and `none` disables both. Keep the read-only default for low-trust triggers that run in the default branch's scope.
- Keep native branch scope. A run restores from its own branch or the default branch. A pull request can also restore from its base branch. A pull request's saved cache belongs to its merge ref and is readable only by that pull request's re-runs.
- A compiled-output key includes platform, toolchain, target, profile, and feature or flag identity. A download cache may use wider fallback keys because the package manager verifies what it fetched.
- Keep secrets, credentials, and signed outputs out of caches.
- Read the repository's configured capacity before adding a large key. The default is 10 GB per repository unless its configured limit differs. Entries unused for 7 days expire. At capacity, GitHub removes entries in order of last access, oldest first.
- A cache hit never replaces a build, test, or installer proof.

## The CI context

### Consumer refresh CI

A consumer with no required checks and an unprotected default branch needs no consumer CI or `change_class` wiring before enabling automatic refresh. The shared [`refresh/refresh-consumer.sh`](https://github.com/vanillagreencom/kendex/blob/main/refresh/refresh-consumer.sh) selects direct merge only when GitHub's branch-rules read succeeds with an empty array and its branch read succeeds with `protected=false`. It accepts an unmeasured `standard` class. Failed protection reads keep the auto-merge route.

The CI contract below applies to consumers with product CI. Each publishes `change_class` from its `changes` job and installs the render prerequisites in Shape 4. A class-only Shape 4 consumer skips product jobs when the classifier succeeds and reports `render`. Use a status function in each job condition so a failed classifier cannot skip product checks. Feed `needs.changes.outputs.change_class == 'render'` to `aggregate-needs` as the waiver and list each product job it may skip with `--skippable`. A composite-action or CI-template consumer reads `lanes` and per-lane verdicts under [§ Per-lane verdicts](#per-lane-verdicts), including the rule that runs the lanes claiming a path a render changes.

A non-product guard job skips on `render` only when the render proof covers what it checks, or, in a composite-action or CI-template consumer, when it is a declared lane whose default-branch globs claim no path the render changes. The proof covers the bot instruction files comparison through the trusted sibling `bot-instructions` checker only when `kendex verify --help` advertises `--bot-instructions-from`. Every release since v1.12.2 advertises this option. The CI template selects the stable release on the trusted refresh caller's major-tag commit. A checkout with no refresh caller uses the latest stable release. A consumer may skip its bot-instructions check on `render` when the selected verifier advertises this option. A consumer that pins a verifier older than v1.12.2 keeps that check running. CodeQL and every other guard job that is not a declared lane keep running on `render`: the proof compares rendered files only. A declared lane, such as a launcher or script test, whose globs claim a changed path runs on the events the render bullet of [§ Per-lane verdicts](#per-lane-verdicts) names. The credential scan runs on every pull request, as the secrets bullet in [§ The CI template](#the-ci-template) states.

Keep the classifier and required aggregate unconditional on both `pull_request` and `merge_group`. The classifier's passing render proof is the required evidence for a render-only refresh. A class-only Shape 4 consumer skips product jobs on that class. A composite-action consumer follows the per-lane rule above. A failed or unavailable proof grants no render waiver and keeps the product checks active. A branch name, author or label cannot replace this proof.

Every repository under the organization standard reports one aggregate context named `CI` on both `pull_request` and `merge_group`, green only when every job the repository runs is green. review-gate's `validate-standard.sh` checks both legs as its `standard-ci-context` row. Which contexts the repository's required-checks ruleset requires is the review-gate skill's references/adoption.md § Repo-side wiring. One of two routes gives the repository the `CI` context:

- **The template.** Copy [the CI template](#the-ci-template) and move the repository's lanes into it.
- **The repository's own workflow.** Keep the workflow and its job names, and put `merge_group:` beside `pull_request:` under `on:`. Add Shape 1's `changes` job and give every lane its condition, then add Shape 3's aggregate with `name: CI`, its `needs:` naming every job in the workflow and each gated lane in a `--skippable`. A lane in another workflow moves into this one, because a job waits only on jobs in its own workflow. An aggregate the repository already runs under another name takes the name `CI` rather than running beside a second one.

The order of this change and the ruleset change, and the check that confirms both, are the review-gate skill's references/adoption.md § Repo-side wiring.

## The CI template

[`../templates/ci.yml`](../templates/ci.yml) is the workflow a repository copies to `.github/workflows/ci.yml`. Every repository reports `CI`, per [§ The CI context](#the-ci-context), so the template fixes the names every repository reports: the job carrying `CI`, and the classifying job `Classify the diff`. Keep both names and change the rest to fit.

- **Adopt the package first.** Land `harness-ci` on the default branch before adopting `.github/workflows/ci.yml`. The aggregate needs the default branch's `aggregate-needs` helper on every event, per [§ Shape 3](#shape-3--merge-queues-where-the-required-context-must-report). A pull request that adds both fails `CI` because the default branch has no helper.
- **Every lane goes in this workflow.** A job can wait only on jobs in its own workflow, so a lane left in another workflow is a lane no required context holds. Replace the placeholder `test` job with the repository's lanes, one job each: declare each in `.github/ci-lanes.conf`, marked `:nightly` where it is a platform lane, publish its `lane_<name>` output from the `changes` job, and give it the same `needs:`, and the condition and aggregate arguments [§ Per-lane verdicts](#per-lane-verdicts) sets out. Name each lane in CI's `needs:`. A lane that reads a file in the docs set is the exception: it drops the `lanes` and verdict terms, runs on every diff and stays out of `--skippable` and `--lane`, per [§ Through the composite action](#through-the-composite-action). Copied as it stands, the placeholder fails, and `CI` fails with it.
- **The merge-queue run is the only proof of a head.** The classify step passes `queue-only-default: true`, so on `pull_request` the action stands every lane down on a repository with no `HARNESS_CI_PER_PUSH_REASON`, per [§ Per-lane verdicts](#per-lane-verdicts). A copy that drops the input runs its lanes on every pull request. The pull request run then reports `Classify the diff` and a passing `CI`, which GitHub needs before it admits the pull request to the queue, and no product lane. The merge group runs the lanes its own diff selects. A merge queue can batch several pull requests into one merge group, so the group classifies their combined diff, and a docs-only pull request batched with a code change runs every lane the group calls for. The declaration is read from the `classifier` checkout, the default branch. No line of the template reads the change class.
- **The default needs the merge-queue ruleset.** Without a queue no run proves the head, and `pr-merge` takes the plain route on the stub run. A repository with no merge queue sets `HARNESS_CI_PER_PUSH_REASON = "no merge queue"`, and its pull requests run their lanes.
- **A push to the default branch runs no lane.** The template has no `push` trigger: the queue run already proved the merged head. A repository workflow that adds `push` gets the same stand-down; the opt-back is `HARNESS_CI_PER_PUSH_REASON`, which runs the lanes on both events.
- **The nightly run.** The template's `schedule` trigger runs once a day on the default branch, and `workflow_dispatch` runs the same on demand. The action answers `lanes=true` with `lanes_cause=full-run` and every declared lane `true` there, so a platform lane marked `:nightly` runs across all paths. Mark macOS, Windows, GPU and larger-runner lanes `:nightly`, or `:queue` where they must prove each head. A red nightly run reaches the overseer through orch's `oversee-watch`, per [§ Per-lane verdicts](#per-lane-verdicts).
- **The opt-back.** `HARNESS_CI_PER_PUSH_REASON` in the default branch's settings, the reason as its value, runs the lanes on each pull-request push and push, queue-only changes included, with only `:queue` lanes deferred. It reopens the admin route where `HARNESS_CI_QUEUE_PATHS` and the queue selector allow it. A blank value is refused with one `setting-refused:` line and a warning, and reads as unset. The README's settings table names it.
- **`changes` and `CI` stay separate jobs.** `changes` is the one reader of the opt-back, through `change-class`, and `aggregate-needs` refuses a classifier job that did not succeed, so the aggregate cannot read the answer in the job that produces it. Every lane fans out from `changes`, and `CI` runs under `always()` after every lane. A pull request run is these two jobs.
- **Superseded PR runs cancel.** The workflow groups runs by workflow, event, and pull request number. Only `pull_request` runs cancel an in-progress run in their group. Other events use their own run id, so neither running nor pending runs replace each other under [GitHub's concurrency rules](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency). A release or publication workflow keeps its own serialization and takes no PR cancellation.
- **The render prerequisites are Shape 4's.** The template uses review-gate's `install-latest.sh` from the trusted default branch. It selects the stable release on the refresh caller's major-tag commit. A checkout with no refresh caller uses the latest stable release. The released engine must support the render verifier's document and flags. The network steps and the render-candidate step permit failure in the classifier job. A missing prerequisite prevents the `render` class. Every other class is judged as usual. The install and mirror steps run only for a render candidate, on `pull_request` too: orch's consumer refresh approval reads the measured render class off the pull request run, and the merge group carries the same proof.
- **Every job runs on `vars.CI_RUNNER_2V`, falling back to `ubuntu-latest`.** The organization variable names the shared runner; a repository without it runs on GitHub's hosted runner.
- **CI is Shape 3's aggregate.** It runs under `always()`. Its `guards` checkout supplies the default-branch helper on every event, under [§ Shape 3](#shape-3--merge-queues-where-the-required-context-must-report). `aggregate-needs` accepts a skipped lane only where the classifier succeeded and a verdict stood it down, per [§ Per-lane verdicts](#per-lane-verdicts).
- **The secrets step scans each pull request's commits with default-branch code.** Land commit-guards on the default branch before adopting the template. An adoption pull request that adds both fails the secrets step because the `guards` checkout has no installer or scanner. The `guards` checkout supplies the pinned gitleaks installer and the scanner, including its libraries. The separate `subject` checkout holds the pull request's merge ref and full history, and runs under the secrets step's own condition, `always() && github.event_name == 'pull_request'`: the scan, its only reader, judges each commit of the range `HEAD^1..HEAD` against its parents and refuses a range that reaches a shallow boundary, so the checkout keeps `fetch-depth: 0`, and a `merge_group` run, where the scan is skipped, fetches no `subject` tree. The step runs in `subject` and executes the scripts by their absolute paths in `guards`, so an edit to the pull request's scanner cannot disable the scan. Its `--policy-root` reads the exclusion list and its setting from `guards` too, so a pull request that excludes its own credential is still refused. A scanner without `--policy-root` refuses the flag on every pull request, so a repository that updates its copy of the template first merges the kendex refresh that gives the default branch a commit-guards with the flag. It runs on every pull request, including one the classifier clears. A repository without commit-guards deletes only the secrets step. Keep `guards` for the aggregate helper.

[`tests/ci-template.test.sh`](https://github.com/vanillagreencom/kendex/blob/main/skills/harness-ci/tests/ci-template.test.sh) runs the template's `lanes` step, evaluates its job outputs and conditions per event and action answer, and hands its waiver and aggregate arguments to the real `aggregate-needs`. It also runs the secrets step against a pull request that replaces its scanner and installer with successful exits, excludes every path, and adds a test credential. The trusted scanner still refuses that credential.

## Verifying an adoption

Two probe PRs against the adopting repository:

1. **Skip probe**: choose the probe for the adopted shape.
   - **Class-only Shape 4, with the `render` class**: open a render-only refresh PR. Its diff contains only what `kendex refresh` or `kendex apply` writes. If no refresh is pending, wait for the next consumer refresh PR. Expect `change_class=render`, skipped heavy lanes and every required context green. Do not hand-edit a path kendex renders for this probe.
   - **The composite action or CI template**: use the same render-only refresh, with the shared lane producer available in the selected classifier checkout and no changed path that a default-branch lane claims. Expect `change_class=render`, `lanes=false`, skipped heavy lanes and every required context green. A refresh that changes a claimed path follows [§ Per-lane verdicts](#per-lane-verdicts); it is not a skip probe.
   - **Shapes 1–3, gating on `harness_only` alone**: hand-edit one file under `.agents/`. Expect `harness_only=true`, skipped heavy lanes and every required context green.
2. **Mixed**: combine the first probe's changes with one product-file edit. The product lanes required by that diff run in its merge group; on the pull request they run only where the repository sets `HARNESS_CI_PER_PUSH_REASON`.

Close both once the checks report.
