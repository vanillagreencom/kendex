# Consumer refresh source design

Each consumer keeps one short `.github/workflows/kendex-refresh.yml` that calls a reusable workflow kept in `vanillagreencom/kendex` at the major tag `v1`. kendex's release job moves `v1` to each stable release. At run time the shared workflow clones the tree `v1` points at, installs that tree's release, and runs the refresh scripts from that tree. No consumer keeps a copy of a refresh script, and a fix to one reaches every consumer at the next release with no hand-made consumer pull request. In the one current consumer this credential can read, 425 of 558 runs failed over 7 days (76.16%). The design removes 77 of those failures: each came from a committed copy older than a released fix, or from a version pin in that copy. Of the other 348, 343 came from defects in released kendex code, and each of those ends at the release that fixes it. The last 5 are GitHub refusals and correct holds, which no release removes.

Design for owner review (KEN-2601), revised to owner direction 1790974850. This PR builds nothing. Measurements, run IDs and the GitHub documentation excerpts: [consumer-refresh-source-design.evidence.json](consumer-refresh-source-design.evidence.json).

## Framing

- **Read**: the KEN-2601 Requirements, the owner ruling on it (note 1790974374) and owner direction 1790974850, [D003](../decisions/D003-one-merge-path.md), [D001](../decisions/D001-portable-lock.md), [D007](../decisions/D007-lock-record-on-main.md), [D018](../decisions/D018-platform-review-requirements.md), [merge-rail.md](../architecture/merge-rail.md), [consumer-render-model.md](consumer-render-model.md), [ken-2416-consumer-refresh.md](ken-2416-consumer-refresh.md), [ken-2416-refresh-runs.md](ken-2416-refresh-runs.md), [github-standard.md](github-standard.md) § Refresh path, [RELEASING.md](../RELEASING.md) § Catalog compatibility, [changelog.d/README.md](../../changelog.d/README.md) § Release standard, the refresh template and scripts under `skills/review-gate/`, `.github/workflows/release.yml`, vsys `main` at `c6c73f5`, and each related issue live.
- **Credential**: the lanes app installation token. It reads public repositories only.
- **GitHub documentation**: both research providers refused their keys in this session. GitHub's own documentation was read from its source repository, `github/docs` at commit `2bd66de8`, through the contents API. Each GitHub behavior below cites the article it comes from; the evidence file holds the excerpts. One behavior has no citation: a called job's `environment:` reads the calling repository's environment. Build A's first acceptance run proves it before anything else lands (see [Build items](#build-items)).
- **Principles document**: not in this repository. The compatibility rule below is the one [changelog.d/README.md](../../changelog.d/README.md) § Release standard states.

## How a refresh runs today

- `templates/kendex-refresh.yml` (92 lines) reaches a consumer by adoption copy. The copy runs the consumer's committed `install-latest.sh`, checks out the consumer's own default branch into a detached worktree, and runs the committed `refresh-consumer.sh` and `refresh-reviews.sh` from it. `refresh-consumer.sh` calls the committed `adopt-refresh.sh`, which calls `validate-standard.sh`, and the committed `change-class`. The adopter reads kendex templates from the render the same run just wrote.
- A change to any of these files reaches a consumer only through a run of the copy it replaces. A defect that stops that run before publication can only be cleared by hand: KEN-2296, KEN-2417 (vsys#126), KEN-2514 and vsys#148 are those hand steps.
- The copies already skew across consumers. The overseer read `refresh-consumer.sh` with the GitHub contents API: 12,987 bytes in drovr, hyprtrade-io and vgs, and 14,192 bytes in vg, fleet, hyprtrade, kendex-web, memsira, talk and vsys. This lane read the two public ones by blob SHA. vgs holds `32afaed5`, the file at v1.5.1. vsys holds `9be9fc56`, the file on `main` since KEN-2498 (`0d95d84f`), which no release carries yet. Two runner versions run in the fleet at once, and neither is chosen by kendex.
- vsys commits 442 files under `.agents/`. Nine are refresh-only: `adopt-refresh.sh`, `dispatch-refresh.sh`, `install-latest.sh`, `refresh-consumer.sh`, `refresh-report.py`, `refresh-reviews.sh`, `lib/review-findings.sh`, `templates/kendex-refresh.yml` and `templates/review-gate-writer.yml`.

## Measured failure rate

Seven days of `kendex-refresh.yml` runs created from `2026-09-25T20:59:16Z` to `2026-10-02T20:59:16Z`, listed with `gh run list --all --limit 1000` and no event, branch or status filter. The cutoff was fixed before counting. Rates follow [ken-2416-refresh-runs.md](ken-2416-refresh-runs.md) § Counts and denominators.

| Consumer | Listed | Completed | Failure | Success | Cancelled | Pending | Listed rate | Completed rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| vsys | 558 | 558 | 425 | 131 | 2 | 0 | 76.16% | 76.16% |
| vgs, vgs-themes, homebrew-kendex, gentoo-overlay | 4 | 3 | 3 | 0 | 0 | 1 | 75.00% | 100.00% |
| Readable total | 562 | 561 | 428 | 131 | 2 | 1 | 76.16% | 76.29% |
| talk, vg, fleet, hyprtrade, hyprtrade-io, drovr, kendex-web, memsira | HTTP 404 | | | | | | Unmeasured | Unmeasured |

- The four single-run repositories are the historical public attempts KEN-2416 names, each run created on 2026-09-27. They are not current consumers.
- The private consumers return HTTP 404 to this credential, so the overseer supplies their rows. KEN-2514 records that hyprtrade, hyprtrade-io, drovr and kendex-web ran v1.2.0 from a pin in their own workflow copy until hand pull requests replaced it.
- In vsys, 1 of the 53 runs created after `2026-10-02T13:00:00Z` failed (1.89%). That one failure is KEN-2557's defect.

## Failure causes

All 425 vsys failures stop in the refresh step, except two in the review-filing step. Each failed log was read and assigned one class.

| Class | Runs | First and last run | Cause | Removed by this design |
| --- | ---: | --- | --- | --- |
| Adopter reads a missing record as a hand edit, before the fix shipped | 153 | 09-29 18:23Z to 09-30 22:23Z | Defect in shipped `adopt-refresh.sh`; fixed by KEN-2278, released in v1.3.0 at 09-30 22:24Z | No |
| Runner refuses to publish a standard-class refresh | 136 | 09-28 04:24Z to 09-29 18:04Z | Defect in shipped `refresh-consumer.sh`; fixed by KEN-2277, released in v1.3.0 | No |
| Leftover `generalist` agent fails refresh or verify, before the fix shipped | 47 | 10-01 07:01Z to 10-01 21:17Z | The catalog renamed agents before a released engine could remove the old renders; fixed by KEN-2438, released in v1.4.0 at 10-01 21:23Z | No |
| Adopter reads a missing record as a hand edit, after the fix shipped | 40 | 09-30 22:35Z to 10-01 05:47Z | vsys ran its committed adopter until the hand pull request vsys#126 (KEN-2417) | Yes |
| Leftover `generalist` agent, engine pinned in the workflow copy | 22 | 10-01 21:35Z to 10-02 02:06Z | vsys's copy installed v1.3.0 from its own pin after v1.4.0 shipped, until the hand pull request vsys#148 | Yes |
| Old runner validates a template the new render deleted | 15 | 10-01 15:31Z to 10-01 19:02Z | The committed runner read `review-gate-writer.yml` from a render KEN-2089 had changed (KEN-2460) | Yes |
| Classifier cannot prove a render retirement | 6 | 10-02 10:55Z to 11:36Z | `change-class` refuses deleted renders; KEN-2552 (Done, unreleased) and KEN-2536 own it | No |
| Push refused by GitHub | 2 | 09-28 02:37Z; 10-02 05:46Z | `stale info`: the lease refused a moved branch, a correct refusal. GH006: the branch was held by the merge queue, and the committed runner predated KEN-2457's deferral, merged 5 minutes later | GH006 case: yes, by the queue read below |
| Review thread held open | 2 | 10-02 04:32Z | `upstream-unfiled`: a correct hold | No |
| Default branch moved during the run | 1 | 10-02 12:47Z | A correct refusal | No |
| Auto-merge disable after the queue took the pull request | 1 | 10-02 16:46Z | KEN-2557 | When queued at run start: yes, by the queue read below |

- Removing the three delivery classes (77 runs) leaves 348 of 558 failures (62.37%) in this sample. The design alone does not reach the 5% target.
- Of those 348, 343 (61.47% of 558) came from five classes of defect kendex shipped: the adopter before its fix (153), the runner's standard-class refusal (136), the leftover agent before its fix (47), the classifier's render retirement (6) and KEN-2557 (1). Under this design each such class ends at the release that fixes it.
- The other 5 are GitHub refusals and correct holds: the two refused pushes, the two held review threads and the moved default branch. No release removes them, and they stay in the denominator.
- In this sample, the adopter and pin episodes ended only with a hand-made vsys pull request. vsys#126 merged at 05:49:18Z on 10-01. The last failure before it, run 36821500115, was created 94 seconds before the merge and ended 46 seconds before it. vsys#148 merged at 02:10:21Z on 10-02. The last failure before it, run 36954117589, was created 3 minutes 26 seconds before the merge and ended 2 minutes 42 seconds before it. A run's end is its `updated_at`.
- **vg, 2026-10-02 at 20:38Z** (1:38 pm Pacific): the overseer reports a GH006 push failure while vg's own rolling pull request sat in the merge queue. vg's copy is the 14,192-byte file, which carries KEN-2457's post-refusal deferral. This credential cannot read vg's log, so why that read did not defer the run is unverified.
- The leftover-agent class passed kendex CI. `tools/catalog-release-check` installs the catalog into a fresh project, which holds no agent from an earlier catalog ([RELEASING.md](../RELEASING.md) § Catalog compatibility). This gap is reported under Discovered work, not built here.

## Design

### The consumer's file

```yaml
name: Refresh kendex
"on":
  repository_dispatch:
    types: [kendex-refresh]
  schedule:
    - cron: "*/30 * * * *"
  workflow_dispatch: {}
concurrency:
  group: kendex-refresh
  cancel-in-progress: false
jobs:
  refresh:
    permissions:
      contents: read
    uses: vanillagreencom/kendex/.github/workflows/refresh-consumer.yml@v1
```

- The triggers and concurrency stay in the caller, because the caller's own triggers start each run. Everything else leaves the file. It passes no secret and no input.
- A job that calls a reusable workflow accepts only `name`, `uses`, `with`, `secrets`, `strategy`, `needs`, `if`, `concurrency`, `permissions` and `cache-mode`. It takes no `environment:` and no `runs-on:` (GitHub Docs, reusing-workflow-configurations.md § Supported keywords).
- `permissions` sits on the calling job, because a called workflow gets the default `GITHUB_TOKEN` permissions when the calling job sets none, and it can only lower what the caller passes (same article, the note under § Supported keywords).
- The concurrency group is a literal. A called workflow reads its caller's name in `github.workflow`, so a group built from that context would match the caller's (same note).
- `uses:` takes no context or expression, and its ref is a SHA, a release tag or a branch name (GitHub Docs, data/reusables/actions/reusable-workflow-calling-syntax.md; owner direction 1790974850). The literal is the major tag `v1`, so the file names no release, and a release reaches every consumer by the tag moving.

### The moving ref: a major tag

- `.github/workflows/release.yml` runs on `v*` tags with `contents: write`. After it publishes a stable release `vX.Y.Z`, one added step moves `vX` to that release's commit and force-pushes the tag with `GITHUB_TOKEN`. A push made with `GITHUB_TOKEN` starts no workflow run (GitHub Docs, data/reusables/actions/actions-do-not-trigger-workflows.md).
- The trigger narrows from `v*` to `v*.*.*` in the same change. Today `v*` also matches `v1`, so a hand move of `v1`, such as a rollback, would start a full release build that fails its version check at publication.
- `main` has branch rulesets only; no ruleset targets tags (`gh api repos/vanillagreencom/kendex/rulesets`). When a tag and a branch share a name, the tag wins (calling-syntax article). No branch is named `v1` today; the only `v`-prefixed branch is `vstack-v1`.
- A tag, not a release branch, because:
  - A tag names one commit. It takes no pushes or merges, and the release job is its only writer.
  - `vX` states the release standard's promise: no breaking change within a major ([changelog.d/README.md](../../changelog.d/README.md) § Release standard).
  - A branch would be a second line of history needing its own protection, and it would still need one name per major.
- **Run-time selection** (KEN-2281): each run clones the tree `v1` points at when the run starts. The tree's release is the stable `v1.Y.Z` tag on the same commit. A `v1` that points at a commit with no such tag fails the run before any install. The workflow file and the scripts come from one commit, except when `v1` moves between GitHub reading the file and the clone; the compatibility contract covers that window.
- **A major release**: v2.0.0 creates `v2`, and `v1` stays at the last 1.x release, so every `@v1` caller keeps running 1.x. The consumer moves when its overseer or maintainer changes `@v1` to `@v2` in one pull request, following the release's `**Breaking:**` changelog entry. The adopter accepts that file, because the `@v2` caller is a shipped template. A major needs the owner's approval, so this is one reviewed edit per consumer per major.
- **A bad release**: the owner points `vX` back at an earlier release's commit. Every consumer's next run uses that release's workflow and scripts together, and no consumer file changes. The safe depth is under [Compatibility contract](#compatibility-contract).

### The shared workflow

`vanillagreencom/kendex/.github/workflows/refresh-consumer.yml` takes `on: workflow_call` and runs one job.

1. Guard: `github.repository != 'vanillagreencom/kendex'` and the default branch only. In a called workflow the `github` context is always the caller's (GitHub Docs, reusing-workflow-configurations.md § `github` context). D007's kendex exclusion is unchanged.
2. Check out the caller's default branch with `persist-credentials: false`.
3. Clone `vanillagreencom/kendex` at `v1` into `$RUNNER_TEMP/kendex` with no credential, the same public read `adopt-refresh.sh` makes today. Read the stable `v1.Y.Z` tag on the cloned commit with `git ls-remote --tags`.
4. Install: run the clone's own `install.sh --version TAG --cli-only` with no token, fail unless `kendex --version` reports TAG, and print `kendex-install: version=TAG commit=SHA`, the report `install-latest.sh` prints. These lines live in the shared workflow. They need no release read and no tag-to-commit lookup, because the clone already resolved the tag.
5. Mint the repository token, then run `refresh/refresh-consumer.sh` from the clone: rebuild the branch, refresh, adopt the caller, verify, classify, push, open or update the pull request, arm `render`, and report.
6. Mint the issue token, then run `refresh/refresh-reviews.sh` from the clone.

- The install, branch, pull request, arm and report steps run from kendex's release tree, called only by this shared workflow. No consumer keeps `refresh-consumer.sh` or `refresh-reviews.sh` after step 4, or `install-latest.sh` after step 6 (see [Deletion list](#deletion-list)). Porting them into the binary is rejected below.
- `refresh/` at the kendex repository root holds `refresh-consumer.sh`, `adopt-refresh.sh`, `refresh-reviews.sh`, `refresh-report.py`, `dispatch-refresh.sh`, `lib/review-findings.sh`, the caller template `kendex-refresh.yml`, and their tests. `refresh/` is outside every catalog root, so no render carries it and `tools/guard` owes it no render.
- `install-latest.sh` stays the one latest-release installer. The shared workflow does not call it. Until step 6 it stays in `skills/review-gate/scripts/`, because the retained writer template calls it there in each consumer that still holds that template (`templates/review-gate-writer.yml` line 648). kendex's `catalog-check.yml`, `skill-tests.yml` and `crates/cli/tests/release_workflow/catalog.rs` also call it. At step 6 it moves to `tools/install-latest`, outside every catalog root, and those callers move with it.
- The scripts take kendex templates from their release tree, never from the consumer render. They read the consumer render only for the settings report's orch libraries, which run under `env -i` with no credential, as today.
- The scripts still call `skills/review-gate/scripts/validate-standard.sh`, `lib/settings.sh` and `skills/harness-ci/scripts/change-class` from the release tree. Those files stay in their packages, because consumers use them outside refresh.

### Tokens and secrets

| Token | Minted by | Repositories | Permissions | Reaches the scripts as | Used for |
| --- | --- | --- | --- | --- | --- |
| Repository token | `actions/create-github-app-token`, step 5 | `owner: ${{ github.repository_owner }}`, `repositories: ${{ github.event.repository.name }}`: the calling repository only | Contents write, Pull requests write, Workflows write; Administration, Metadata, Actions, Environments and Secrets read; organization Secrets read | `GH_TOKEN` in steps 5 and 6 | Push, pull request, arm, the caller update, the adopter's environment check, and resolving review threads |
| Issue token | `actions/create-github-app-token`, step 6, `continue-on-error` | `owner: vanillagreencom`, `repositories: kendex` only | Issues write | `KENDEX_ISSUES_TOKEN` in step 6 only | Filing rendered-file findings upstream ([D003](../decisions/D003-one-merge-path.md) item 2) |
| `GITHUB_TOKEN` | GitHub; a called workflow gets `github.token` automatically | the calling repository | `contents: read`, the calling job's ceiling | `GITHUB_TOKEN` in the clone and install steps | None needed: the clone and install read public data |

- The permissions are today's template's, unchanged. Workflows write stays, because the refresh may rewrite the caller file. `refresh-reviews.sh` already stops exporting `KENDEX_ISSUES_TOKEN` to the classifier, and `refresh-report.py` passes it to the issue API only, as today.
- **Credentials**: the caller passes no secret, neither named nor `secrets: inherit`. The shared job declares `environment: kendex` and reads `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY` from the `kendex` environment. GitHub Docs (reuse-workflows.md, the warning under § Using inputs and secrets) states both halves of this route: a caller cannot pass an environment secret, and a called job that declares `environment` uses that environment's secret.
- Named secrets would have to be repository or organization secrets, because the calling job declares no environment. Any workflow on any branch of the repository can read a repository secret. The environment's default-branch-only deployment policy is what keeps the private key from a branch workflow, so D003 places the key there. `secrets: inherit` passes every organization, repository and environment secret the caller can read (GitHub Docs, workflow-syntax.md § `jobs.<job_id>.secrets.inherit`), more than the run needs.
- The documentation does not name the repository whose `kendex` environment a called job reads. The calling repository is the reading consistent with the documented facts that the `github` context, runner assignment and billing are the caller's (reusing-workflow-configurations.md § How reusable workflows use runners). Build A's first acceptance run proves it. If it fails, the fallback is named secrets from repository secrets. That fallback loses the branch policy and needs the owner's decision.

### Never pushing to a branch the queue holds

- `refresh-consumer.sh` already lists the open rolling pull request before it refreshes. When that list finds one, the run reads its lifecycle once with the read KEN-2557 lifts into one function: `state`, `isInMergeQueue` and `autoMergeRequest`. A queued pull request ends the run as `refresh-state=deferred reason=queued`, with exit 0, before any refresh, push, body update or `--disable-auto`. The pull request merges and the next run refreshes from the new default branch.
- A pull request can enter the queue between that read and the push. The push then fails with GH006, and the existing post-refusal read (KEN-2457) defers. KEN-2557 adds the same read after a refused `--disable-auto`.
- This adds one GraphQL read on a run that finds an open rolling pull request. Two measured runs justify it: vsys 36970384017 and vg's 20:38Z run. KEN-2557's no-pre-flight-read bar answered a different symptom, a defer after a refused call.

### Adoption and the inventory

- The adopter writes the caller from `refresh/kendex-refresh.yml` in its release tree. It accepts the existing file when its bytes equal any template in kendex default-branch history at either template path. This is the KEN-2416 check, extended to the new path, so a hand edit is still refused and kept.
- The adopter removes the caller's `.kendex-generated.json` record, and `kendex verify` no longer compares it. The history check is its equality check.
- A refresh pull request that changes the caller classifies `standard`, so the overseer or a maintainer merges it (KEN-2539). With no version in the file, that happens only when the triggers change.

### Compatibility contract

- The consumer-visible contract is the caller file: the workflow path, the `vX` ref, and the job taking no inputs and no secrets. Within a major, a change keeps the old form working, with one warning naming the new form ([changelog.d/README.md](../../changelog.d/README.md) § Release standard).
- The shared workflow and its scripts are one kendex release. A template change that the release at `v1` cannot serve merges only after a release carries it, the release-first rule [RELEASING.md](../RELEASING.md) § Catalog compatibility states for catalog content.
- **Skew window**: the workflow file can differ from its cloned tree by one release, in either direction, only when `v1` moves during a run's start. So the workflow calls a new script path, variable or input only one release after the scripts accept it. The scripts keep accepting one the workflow no longer passes for one release after that. Build A's test row runs the current workflow's calls against the previous release's `refresh/`, and the previous release's workflow calls against the current `refresh/`.
- **Rollback depth**: pointing `v1` back moves the workflow and scripts together, so the skew window is the only skew. A rollback cannot undo what the bad release wrote into consumers: renders, `.kendex-lock.json`, the inventory and the caller. The release standard makes newer code read older forms, not older code read newer ones. A rollback to an earlier 1.x release is safe when no later release changed a format a consumer commits. Otherwise the fix is a new release, not a rollback.

## Deletion list

Steps are the [Migration order](#migration-order). A row lands in the build of its step: step 4 is Build B, step 6 is Build C.

| Mechanism | Where | Deleted at | Why it is no longer needed |
| --- | --- | --- | --- |
| The 92-line refresh template's steps, including "Preserve default-branch scripts" and its `install-latest.sh` run | `skills/review-gate/templates/kendex-refresh.yml` | Step 4: the template becomes the caller | The shared workflow runs them from the release tree |
| Template rows that require exec from the consumer copy | `skills/review-gate/tests/refresh-workflow.test.sh` | Step 4, with the template they test | Replaced by the controls under Build items |
| Rendered refresh scripts in every consumer | `skills/review-gate/scripts/` and `lib/review-findings.sh`, except `install-latest.sh` | Step 4 | Moved to `refresh/` at step 2 |
| Inventory record and verify equality for the refresh workflow | `.kendex-generated.json` in each consumer; [generated-paths.md](../architecture/generated-paths.md) | Step 4: the first shared-workflow run removes the record; Build B updates the doc | The adopter's history check |
| Rendered template at the old path | `skills/review-gate/templates/kendex-refresh.yml` | Step 6 | Read only by committed adopters older than step 4 |
| KEN-2460 bridge: retained writer template and pre-platform fixtures | `templates/review-gate-writer.yml` (722 lines) and its render; `tests/fixtures/pre-platform/` (881 lines); the bridge row in `refresh-consumer.test.sh` | Step 6 | No pre-KEN-2089 runner runs after step 4 |
| `install-latest.sh` in every consumer render | `skills/review-gate/scripts/install-latest.sh` | Step 6: moves to `tools/install-latest` | Its last consumer-side caller, the retained writer template, goes in the row above |
| Trusted writer removal and the `legacy-writer` warning | `adopt-refresh.sh --retire-writer` | Step 6, once no consumer's run prints `refresh-warning=legacy-writer` | A one-time removal ([D018](../decisions/D018-platform-review-requirements.md)); vsys#159 and hyprtrade PR 692 have run it |
| Per-consumer version pins | each consumer's workflow copy | KEN-2514 is the last; step 4 replaces any shipped pinned copy | The caller names a major tag only |

- **Added**: the shared workflow, which takes the template's steps; one tag-move step and a narrower tag trigger in `release.yml`; one lifecycle read at run start, through KEN-2557's function; the skew-window test row. The caller replaces the 92-line template with 15 lines. The deletions above remove the bridge's 1,603 source lines and one copy of nine files from every consumer. No new installer script is added.
- **Aliases past their window**: none on the refresh path. Two compatibility reads sit inside their stated window, which ends at 2.0: the fallback to pre-1.3.0 `standard.json` values in `skills/review-gate/scripts/lib/standard.sh` (the `RG_STANDARD_EARLIER_*` block), and the advisory rows in `validate-standard.sh`.
- **Not deleted**: `dispatch-refresh.sh` keeps its job and moves to `refresh/`. `install-latest.sh` keeps its job for kendex's own CI. The Consumer refresh check is KEN-2594's deletion, and this design adds no pre-merge consumer check in its place.

## Ruling on open items

| Item | State | Ruling |
| --- | --- | --- |
| KEN-2297 | Canceled | Superseded by this design; its two must-fail controls are under Build items |
| KEN-2355 | Backlog | Unneeded. It moves the refresh scripts into `skills/github-repository-settings/`, a rendered package, which puts the copies back into every consumer. Its `GITHUB_STANDARD_REFRESH` and `GITHUB_STANDARD_DISPATCH` opt-ins answer no measured failure: a repository opts in by holding the caller. Recommend cancel |
| KEN-2376 | Backlog | R47 is met by KEN-2416's edit preservation. R15, R21 and R22 name `review-predicate.sh`, which KEN-2089 deleted. X39 and X40 stay with `dispatch-refresh.sh` |
| KEN-2514 | In Progress | Kept as the last pin bump (owner ruling). Done when drovr passes |
| KEN-2557 | Backlog | Kept, before step 2 (owner ruling). Its one lifecycle function also serves the run-start queue read |
| KEN-2539, KEN-2536, KEN-2310 | Backlog | Kept; each lands before step 2 (owner ruling). KEN-2310's `runs-on` lands in the shared workflow |
| KEN-2363 | Backlog | Kept, narrower: refresh leaves review-gate at step 4, so its retirement table loses the refresh rows |
| KEN-2354 | Backlog | Kept, narrower: its adoption operation no longer manages the refresh workflow |
| KEN-2359 | Backlog | Unaffected |
| KEN-2391 | Backlog | Unaffected: its rows are engine refusals, not delivery |
| KEN-2594 | In Progress | Unaffected, and needed: it removes the Consumer refresh check and its snapshot. If it has not landed by step 6, Build C repoints `.github/workflows/consumer-refresh.yml` line 30 to `tools/install-latest` |

## Decisions

- **D003**: Decision item 2 keeps the adoption-copied workflow, run-time release selection, the rolling pull request, the `kendex` environment and the token scope. It changes three things: where a run's code comes from, the caller naming a major tag, and the inventory record for this one workflow. The [Revisit Outcome (2026-10-02)](../decisions/D003-one-merge-path.md#revisit-outcome-2026-10-02) records them, and says that the writer's `install-latest.sh` route from the 2026-10-01 outcome stays until step 6.
- **D018 and merge-rail.md**: after step 4, the refresh code that runs under the consumer's app token comes from a kendex release, and no consumer pull request reviews it. The controlling party does not change: the released binary that already runs under that token comes from the same release. D018's rule holds as written, because the run still executes no script it refreshed. D018 needs no revisit. [merge-rail.md](../architecture/merge-rail.md) § Decisions states that a consumer's reviewed merge establishes the default-branch scripts that refresh executes; Build B rewrites that sentence.
- **D001**: unchanged. Renders stay committed with the lock. Refresh scripts leave the render because, after step 4, no consumer workflow or CI job runs them.
- **consumer-render-model.md**: owner decision 1790634126 item 5 dropped route 1, which installs kendex in every CI job and commits only the lock. This design adds no install step: the refresh job already installs a release. Every other consumer CI job keeps reading committed renders.

## Migration order

1. **Prerequisites**: KEN-2539, KEN-2557, KEN-2536 and KEN-2310 merge (owner ruling). KEN-2514 completes. Each consumer's overseer confirms one passing run on its current workflow. A consumer that cannot pass is that overseer's drift; no kendex shim is added for it.
2. **Build A**: the shared workflow, `refresh/`, the caller template, the `release.yml` tag-move step and trigger, and the run-start queue read. The old copies under `skills/review-gate/scripts/` and the old-path template stay unchanged, because every consumer still runs its committed copy.
3. **Release**: the owner cuts a release through app-deploy. Its release job creates `v1`.
4. **Build B**: once `v1` exists, `skills/review-gate/templates/kendex-refresh.yml` becomes byte-equal to `refresh/kendex-refresh.yml`, with one test row holding them equal. The old copies except `install-latest.sh` leave `skills/review-gate/scripts/`. Each consumer's next run, still on its committed copy, writes the render without the scripts and adopts the caller in one rolling pull request. Once that pull request merges, the consumer runs the shared workflow.
5. **Observe**: each consumer's first run of the shared workflow starts its 7-day sample. The overseer supplies the private rows.
6. **Build C**: delete the rows marked step 6, after the compatibility window (Owner questions, item 1).

## Target

- Under 5% failed runs over 7 days in every current consumer, counted with the same `gh run list` command from each consumer's step 5 start.
- This sample says the target depends on kendex shipping fewer defects, not on delivery alone. After `2026-10-02T13:00:00Z`, with one defect live, vsys failed 1 of 53 runs. Over the full 7 days, with the classes above live in turn, it failed 76.16%.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| Port the refresh into a `kendex` subcommand | It moves pull-request publication into the CLI, which [overview.md](../architecture/overview.md) § Decisions says opens no pull request in a consumer. It also ports about 800 shell lines, and no measured failure needs that which the shared workflow does not already remove |
| A release branch as the moving ref | See § The moving ref |
| Select the highest stable release from the releases API, apart from the tag | The scripts would run one release ahead of the workflow file from each publication until the tag moves, and withdrawing a bad release would take two steps. Selection would also need a major filter: the releases API lists `v5.0.1` (2026-08-20), a stable release from before v1.0.0 |
| `uses: ...@main` | Runs unreleased code beside the app private key; KEN-2416 rejects it |
| A full release tag in each caller | That is the per-consumer pin the owner ruled out (note 1790974374) |
| `secrets: inherit`, or named repository secrets | See § Tokens and secrets |
| The workflow copied into each consumer and running scripts from the release tree | Still a 90-line copy per consumer, whose every step change travels through the old copy |
| Keep the scripts in `skills/review-gate/scripts/` and skip them in the render | `NOT_RENDERED` in `crates/core/src/source_read.rs` names top-level entries only. Skipping single files needs a new per-file rule in the engine |

## Owner questions

1. **Compatibility window**: KEN-2601 says the old form keeps reading for one minor release. [changelog.d/README.md](../../changelog.d/README.md) § Release standard also says the removal waits for a major release. Which rule holds for the step 6 deletions: the next minor release after every consumer shows step 5, or 2.0?
2. **Fix latency**: today a refresh-script fix reaches a consumer with a working copy one run after it merges on `main`. Under this design it reaches consumers at the next release. kendex shipped 8 stable 1.x releases from v1.0.0 (2026-09-23) to v1.5.1 (2026-10-02); 7 of them, from v1.0.1 (2026-09-26), fall inside the 7-day sample.
3. **KEN-2355**: cancel, per the ruling above.

## Build items

Filed from this design after approval.

- **Build A**:
  - Contents: the shared workflow, `refresh/`, the caller template, and the `release.yml` tag-move step with its `v*.*.*` trigger. The adopter reads its own tree, drops the inventory record and searches both template paths. The run-start queue read. The refresh suites and their CI shard move with the scripts.
  - First acceptance run: `review-gate-sandbox` calls the shared workflow. The run proves that the called job reads the sandbox's `kendex` environment secrets, and that a caller on a non-default branch gets no secret.
  - Must-fail controls:
    - the shared workflow runs a script from the consumer checkout;
    - the installed engine reports a version other than the tag on the cloned commit;
    - `v1` points at a commit with no stable `v1.Y.Z` tag, and the run still installs;
    - a queued rolling pull request still reaches the push;
    - the skew-window row: the current workflow against the previous release's `refresh/`, or the reverse, fails a call.
- **Build B**: make the old-path template equal the caller, remove the old copies except `install-latest.sh`, and update [adoption.md](../../skills/review-gate/references/adoption.md) line 51, [merge-rail.md](../architecture/merge-rail.md) § Decisions, [generated-paths.md](../architecture/generated-paths.md), and the last sentence of [RELEASING.md](../RELEASING.md) § Catalog compatibility, which says the refresh template uses `install-latest.sh`.
- **Build C**: the step 6 deletions, after the owner's answer to question 1. `install-latest.sh` moves to `tools/install-latest` and its suite to `tools/tests/install-latest.test.sh`, the layout [tools/AGENTS.md](../../tools/AGENTS.md) sets. Each caller and statement moves with them: `.github/workflows/catalog-check.yml` (lines 57 and 70), `.github/workflows/skill-tests.yml` line 670, `crates/cli/tests/release_workflow/catalog.rs` (lines 164 and 270), [RELEASING.md](../RELEASING.md) line 21, [review-gate SKILL.md](../../skills/review-gate/SKILL.md) § Scripts line 49, [adoption.md](../../skills/review-gate/references/adoption.md) line 55, the `refresh-workflow.test.sh` writer row, and `.github/workflows/consumer-refresh.yml` line 30 unless KEN-2594 removed it.

## Discovered work

- `tools/catalog-release-check` installs the catalog into a fresh project, so a catalog change that the released engine cannot settle in an existing install passes kendex CI. Reached by 47 vsys failures from 2026-10-01T07:01Z to 21:17Z: the agent rename landed before an engine that removes old agent renders was released.
