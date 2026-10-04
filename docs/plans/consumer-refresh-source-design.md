# Consumer refresh source design

Each consumer keeps one short `.github/workflows/kendex-refresh.yml` that calls a reusable workflow kept in `vanillagreencom/kendex` at the major tag `v1`. The owner moves `v1` to each stable release once it is published, and a tag ruleset lets no one else create, move or delete it. At run time the shared workflow checks out the commit its own file came from, installs the release tagged on that commit, and runs the refresh scripts from that commit. No consumer keeps a copy of a refresh script, and a fix to one reaches every consumer at the next release with no hand-made consumer pull request. In the one current consumer this credential can read, 425 of 558 runs failed over 7 days (76.16%). The design removes 77 of those failures: each came from a committed copy older than a released fix, or from a version pin in that copy. Of the other 348, 344 came from defects in kendex's own code, and each of those ends at the release that fixes it. The last 4 are GitHub refusals and correct holds, which no release removes.

Design for owner review (KEN-2601), revised to owner direction 1790974850. This PR builds nothing. Measurements, run IDs and the GitHub documentation excerpts: [consumer-refresh-source-design.evidence.json](consumer-refresh-source-design.evidence.json).

## Framing

- **Read**: the KEN-2601 Requirements, the owner ruling on it (note 1790974374) and owner direction 1790974850, [D003](../decisions/D003-one-merge-path.md), [D001](../decisions/D001-portable-lock.md), [D007](../decisions/D007-lock-record-on-main.md), [D018](../decisions/D018-platform-review-requirements.md), [merge-rail.md](../architecture/merge-rail.md), [consumer-render-model.md](consumer-render-model.md), [ken-2416-consumer-refresh.md](ken-2416-consumer-refresh.md), [ken-2416-refresh-runs.md](ken-2416-refresh-runs.md), [github-standard.md](github-standard.md) § Refresh path, [RELEASING.md](../RELEASING.md) § Catalog compatibility, [changelog.d/README.md](../../changelog.d/README.md) § Release standard, the refresh template and scripts under `skills/review-gate/`, `.github/workflows/release.yml`, vsys `main` at `c6c73f5`, and each related issue live.
- **Credential**: the lanes app installation token. It reads public repositories only.
- **GitHub documentation**: both research providers refused their keys in this session. GitHub's own documentation was read from its source repository, `github/docs` at commit `2bd66de8`, through the contents API and, for the ruleset articles, through `raw.githubusercontent.com` at the same commit. `actions/checkout` and `actions/create-github-app-token` were read the same way at the commits the refresh template pins. Each GitHub behavior below cites the article it comes from; the evidence file holds the excerpts. One behavior has no citation: a called job's `environment:` reads the calling repository's environment. Build A's first acceptance run proves it before anything else lands (see [Build items](#build-items)).
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
| Push refused: the lease saw a moved branch | 1 | 09-28 02:37Z | `stale info`: a correct refusal | No |
| Push refused: the merge queue held the branch | 1 | 10-02 05:46Z | GH006. The committed runner predated KEN-2457's post-refusal deferral, merged 5 minutes later | No |
| Review thread held open | 2 | 10-02 04:32Z | `upstream-unfiled`: a correct hold | No |
| Default branch moved during the run | 1 | 10-02 12:47Z | A correct refusal | No |
| Auto-merge disable after the queue took the pull request | 1 | 10-02 16:46Z | KEN-2557 | No |

- Removing the three delivery classes (77 runs) leaves 348 of 558 failures (62.37%) in this sample. The design alone does not reach the 5% target.
- Of those 348, 344 (61.65% of 558) came from six classes of defect in kendex's own code: the adopter before its fix (153), the runner's standard-class refusal (136), the leftover agent before its fix (47), the classifier's render retirement (6), the queue-held push before KEN-2457 (1) and KEN-2557 (1). Under this design each such class ends at the release that fixes it.
- The other 4 are GitHub refusals and correct holds: the lease refusal, the two held review threads and the moved default branch. No release removes them, and they stay in the denominator.
- The run-start queue read under [Never pushing to a branch the queue holds](#never-pushing-to-a-branch-the-queue-holds) is a separate change. It is counted as removing no run.
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
    secrets:
      FLEET_GH_APP_ID: ${{ secrets.FLEET_GH_APP_ID }}
      FLEET_GH_APP_PRIVATE_KEY: ${{ secrets.FLEET_GH_APP_PRIVATE_KEY }}
```

- The triggers and concurrency stay in the caller, because the caller's own triggers start each run. Everything else leaves the file. It passes no input, and maps the two app secrets the shared workflow declares, each to its same-named secret (see [Tokens and secrets](#tokens-and-secrets)).
- A job that calls a reusable workflow accepts only `name`, `uses`, `with`, `secrets`, `strategy`, `needs`, `if`, `concurrency`, `permissions` and `cache-mode`. It takes no `environment:` and no `runs-on:` (GitHub Docs, reusing-workflow-configurations.md § Supported keywords).
- `permissions: contents: read` is what the shared workflow's step 2 needs to check out a private caller. It sits on the calling job, because a called workflow gets the default `GITHUB_TOKEN` permissions when the calling job sets none, and it can only lower what the caller passes (same article, the note under § Supported keywords).
- The concurrency group is a literal. A called workflow reads its caller's name in `github.workflow`, so a group built from that context would match the caller's (same note).
- `uses:` takes no context or expression, and its ref is a SHA, a release tag or a branch name (GitHub Docs, data/reusables/actions/reusable-workflow-calling-syntax.md; owner direction 1790974850). The literal is the major tag `v1`, so the file names no release, and a release reaches every consumer by the tag moving.

### The moving ref: a major tag

- **Who moves it**: `.github/workflows/release.yml` publishes a stable release as a draft (`release.yml`, the `action-gh-release` step's `draft:` input), and app-deploy step 4 publishes the draft. That step names no actor, so a lane following the skill can publish. A draft's assets cannot be installed (the comment above that step), so `vX` moves only after publication. Build A adds an owner hand-off to app-deploy step 4: the owner force-pushes `vX` to the published release's commit. A lane that published stops there and reports the tag and its commit to the owner, because the tag ruleset refuses its push. Until the owner moves `vX`, every consumer prints `behind-release` (see A missed move).
- **The tag ruleset**: a kendex tag ruleset targets `v[0-9]` and `v[0-9][0-9]`, the major tags, with Restrict creations, Restrict updates and Restrict deletions, and organization owners as its only bypass actor. Each of those rules lets only a bypass actor create, push to or delete a matching tag (GitHub Docs, available-rules-for-rulesets.md § Restrict creations, § Restrict updates and § Restrict deletions). A target pattern may hold a character set in square brackets (reusables/repositories/rulesets-unsupported-fnmatch-syntax.md), so the targets match `v1` and not `v1.5.1` or `vstack-v1`. The lanes app is not in the bypass list, so no lane token creates, moves or deletes `vX`. Today no ruleset targets tags (`gh api repos/vanillagreencom/kendex/rulesets`), so the owner creates it before `v1` exists.
- **Why not the release job**: the release job ends before publication. The documented bypass list names roles, teams, GitHub Apps and Dependabot, and does not name `GITHUB_TOKEN` (reusables/repositories/rulesets-bypass-step.md). The lanes app cannot be the actor, because every lane holds it. So no release-job token moves `vX` (Owner questions, item 4).
- **Release tags**: `v1.Y.Z` tags stay unprotected, because lanes push them (app-deploy step 3).
- **No branch ruleset**: when a tag and a branch share a name, the tag wins (calling-syntax article), and the ruleset forbids deleting the tag. So a branch named `v1` never selects the code. No branch is named `v1` today; the only `v`-prefixed branch is `vstack-v1`.
- The `release.yml` trigger narrows from `v*` to `v*.*.*`. Today `v*` also matches `v1`, so the owner's push of `v1`, at publication or in a rollback, would start a full release build that fails its version check at publication.
- A tag, not a release branch, because:
  - A tag names one commit. It takes no pushes or merges, and the ruleset lets only the owner move it.
  - `vX` states the release standard's promise: no breaking change within a major ([changelog.d/README.md](../../changelog.d/README.md) § Release standard).
  - A branch would be a second line of history needing its own protection, and it would still need one name per major.
- **Run-time selection** (KEN-2281): each run checks out `job.workflow_sha` of `job.workflow_repository`, "the commit SHA of the workflow file that defines the current job" (GitHub Docs, contexts.md § `job` context, whose example checks out a reusable workflow's own source this way). The workflow file and the scripts always come from one commit, so a move of `vX` during a run changes nothing in that run. The run's release is the one stable `vN.Y.Z` tag on that commit, where `vN` is the tag `job.workflow_ref` names. A commit with no such tag, or more than one, fails the run before any install. This check catches the owner pointing `vX` at an untagged commit or at another major's release. It cannot stop a hostile move, because it lives in the file the moved tag selects; the ruleset stops that.
- **A missed move**: if the owner publishes a release and leaves `vX` behind, every consumer keeps running the older release. The tag read in step 3 lists every tag, so the run also prints `refresh-warning=behind-release tag=TAG newest=NEWER` when a higher stable tag of the same major exists. The line also shows during a release's draft window and until the owner moves `vX` after publication. It clears only when `vX` names the newest stable tag of its major. After a rollback the bad release's tag stays, and a stable tag whose release is never published stays too, so every run in every consumer prints the line until `vX` names the newest stable tag of its major again.
- **A major release**: the owner creates `v2` on publishing v2.0.0, and `v1` stays at the last 1.x release, so every `@v1` caller keeps running 1.x. The consumer moves when its overseer or maintainer changes `@v1` to `@v2` in one pull request, following the release's `**Breaking:**` changelog entry. The adopter accepts that file, because the `@v2` caller is a shipped template. A major needs the owner's approval, so this is one reviewed edit per consumer per major.
- **A bad release**: the owner points `vX` back at an earlier release's commit. Every consumer's next run uses that release's workflow and scripts together, and no consumer file changes. The safe depth is under [Compatibility contract](#compatibility-contract).

### The shared workflow

`vanillagreencom/kendex/.github/workflows/refresh-consumer.yml` takes `on: workflow_call` and runs one job.

1. Guard: `github.repository != 'vanillagreencom/kendex'` and the default branch only. In a called workflow the `github` context is always the caller's (GitHub Docs, reusing-workflow-configurations.md § `github` context). D007's kendex exclusion is unchanged.
2. Check out the caller's default branch with `persist-credentials: false`.
3. Check out `job.workflow_repository` at `job.workflow_sha` into its own path with `actions/checkout` and `persist-credentials: false`, as the documented example does (contexts.md § Example usage of `job` context workflow identity). Read the tags on that commit with `git ls-remote --tags` and no credential, and take the stable tag the [run-time selection](#the-moving-ref-a-major-tag) names.
4. Install: run the checkout's own `install.sh --version TAG --cli-only` with no token, fail unless `kendex --version` reports TAG, and print `kendex-install: version=TAG commit=SHA`, the report `install-latest.sh` prints. These lines live in the shared workflow. They need no release read and no tag-to-commit lookup, because step 3 already resolved the tag.
5. Mint the repository token, then run `refresh/refresh-consumer.sh` from the kendex checkout: rebuild the branch, refresh, adopt the caller, verify, classify, push, open or update the pull request, arm `render`, and report.
6. Mint the issue token, then run `refresh/refresh-reviews.sh` from the kendex checkout.

- The install, branch, pull request, arm and report steps run from kendex's release tree, called only by this shared workflow. No consumer keeps `refresh-consumer.sh` or `refresh-reviews.sh` after step 4, or `install-latest.sh` after step 6 (see [Deletion list](#deletion-list)). Porting them into the binary is rejected below.
- `refresh/` at the kendex repository root holds `refresh-consumer.sh`, `adopt-refresh.sh`, `refresh-reviews.sh`, `refresh-report.py`, `dispatch-refresh.sh`, `lib/review-findings.sh`, the caller template `kendex-refresh.yml`, and their tests. `refresh/` is outside every catalog root, so no render carries it and `tools/guard` owes it no render.
- **Hand runs of the adopter**: after step 4 no consumer holds `adopt-refresh.sh`. A first adoption, or the trusted removal's `--retire-writer` run, runs `refresh/adopt-refresh.sh` from a kendex checkout at the stable tag `vX` names, with the consumer root as the working directory. The adopter takes the repository and its root from the working directory (`gh api 'repos/{owner}/{repo}'` and `git rev-parse --show-toplevel` in today's script) and its templates from its own tree, so it needs no consumer copy.
- `install-latest.sh` stays the one latest-release installer. The shared workflow does not call it. Until step 6 it stays in `skills/review-gate/scripts/`, because the retained writer template calls it there in each consumer that still holds that template (`templates/review-gate-writer.yml` line 648). kendex's `catalog-check.yml`, `skill-tests.yml` and `crates/cli/tests/release_workflow/catalog.rs` also call it. At step 6 it moves to `tools/install-latest`, outside every catalog root, and those callers move with it.
- The scripts take kendex templates from their release tree, never from the consumer render. They read the consumer render only for the settings report's orch libraries, which run under `env -i` with no credential, as today.
- The scripts still call `skills/review-gate/scripts/validate-standard.sh`, `lib/settings.sh` and `skills/harness-ci/scripts/change-class` from the release tree. Those files stay in their packages, because consumers use them outside refresh.

### Tokens and secrets

| Token | Minted by | Repositories | Permissions | Reaches the scripts as | Used for |
| --- | --- | --- | --- | --- | --- |
| Repository token | `actions/create-github-app-token`, step 5 | `owner: ${{ github.repository_owner }}`, `repositories: ${{ github.event.repository.name }}`: the calling repository only | Contents write, Pull requests write, Workflows write; Administration, Metadata, Actions, Environments and Secrets read; organization Secrets read | `GH_TOKEN` in steps 5 and 6 | Push, pull request, arm, the caller update, the adopter's environment check, and resolving review threads |
| Issue token | `actions/create-github-app-token`, step 6, `continue-on-error` | `owner: vanillagreencom`, `repositories: kendex` only | Issues write | `KENDEX_ISSUES_TOKEN` in step 6 only | Filing rendered-file findings upstream ([D003](../decisions/D003-one-merge-path.md) item 2) |
| `GITHUB_TOKEN` | GitHub; a called workflow gets `github.token` automatically | the calling repository | `contents: read`, set on the calling job | `actions/checkout` in steps 2 and 3, whose `token` input defaults to `github.token` (actions/checkout `action.yml` at the template's pinned `3d3c42e5`) | Step 2 reads the caller's default branch, which in 8 of the 10 consumers is a private repository. Step 3 reads public kendex and needs none. The install and refresh steps get no `GITHUB_TOKEN` |

- The permissions are today's template's, unchanged. Workflows write stays, because the refresh may rewrite the caller file. `refresh-reviews.sh` already stops exporting `KENDEX_ISSUES_TOKEN` to the classifier, and `refresh-report.py` passes it to the issue API only, as today.
- **Credentials**: the shared workflow declares `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY` under `on.workflow_call.secrets`, each `required: false`, and the caller maps each to its same-named secret expression, per [D003's 2026-10-04 caller-secrets amendment](../decisions/D003-one-merge-path.md#amendment-2026-10-04-the-callers-secrets), approved by the owner's ruling on ask 1791104990-3321519-1790. The shared job declares `environment: kendex`, and the values come from the calling repository's `kendex` environment. This design first had the caller pass no secret, on GitHub Docs (reuse-workflows.md, the warning under § Using inputs and secrets): a caller cannot pass an environment secret, and a called job that declares `environment` uses that environment's secret. Build A's acceptance runs disproved that route. Run 37187198901, whose caller had no `secrets:` key, read both app secrets empty at the token step. In run 37191124465 both read empty when the names were declared and the caller passed nothing, and in the control; both read set only when the caller also mapped the two names.
- **The private key**: `FLEET_GH_APP_PRIVATE_KEY` is the key of the app both tokens are minted from. With `owner` set and `repositories` empty, `actions/create-github-app-token` mints a token for every repository in that owner's installation (its README at the template's pinned `bcd2ba49`), so the key reaches every repository the app is installed on, not only the caller. The job that holds the key runs the same kinds of input as today's template, among them a kendex release binary, orch libraries from the consumer render, and actions pinned by commit SHA. The one change is where the workflow file and the refresh scripts come from: the kendex commit the owner-protected major tag names, in place of the consumer's reviewed default branch. The design does not otherwise change who can reach the key.
- The named secrets need no repository or organization secret. Run 37191124465's sandbox held the pair only in its `kendex` environment, so the environment's default-branch-only deployment policy still keeps the private key from a branch workflow, and D003 keeps the key there. Any workflow on any branch of the repository can read a repository secret, so this design does not move the key into one. `secrets: inherit` passes every organization, repository and environment secret the caller can read (GitHub Docs, workflow-syntax.md § `jobs.<job_id>.secrets.inherit`), more than the run needs, and GitHub passes inherited secrets only within the caller's organization or enterprise (same section).
- The documentation does not name the repository whose `kendex` environment a called job reads. The values come from the calling repository's. The evidence is indirect, and [D003's caller-secrets amendment](../decisions/D003-one-merge-path.md#amendment-2026-10-04-the-callers-secrets) states it and its limit: vanillagreencom/kendex's own `kendex` environment records no deployment while run 37191124465's jobs ran, and the sandbox's deployment record is unread. That run is a caller in vanillagreencom; a consumer in another organization is not proven on this route.

### Never pushing to a branch the queue holds

- `refresh-consumer.sh` already lists the open rolling pull request before it refreshes. When that list finds one, the run reads its lifecycle once with the read KEN-2557 lifts into one function: `state`, `isInMergeQueue` and `autoMergeRequest`. A queued pull request ends the run as `refresh-state=deferred reason=queued`, with exit 0, before any refresh, push, body update or `--disable-auto`. The pull request merges and the next run refreshes from the new default branch.
- A pull request can enter the queue between that read and the push. GitHub then refuses the push with GH006, and the post-refusal read KEN-2457 added is meant to defer the run. KEN-2557 adds the same read after a refused `--disable-auto`.
- The vg run shows the post-refusal read once did not defer: vg's copy carries KEN-2457's deferral and still failed on GH006. The cause is unknown, because this credential cannot read vg's log. Build A takes that log from vg's overseer before it lands the read, and its must-fail control puts the pull request into the queue between the run-start read and the push.
- This adds one GraphQL read on a run that finds an open rolling pull request. It answers owner direction item 4 and the two measured GH006 runs, vsys 36970384017 and vg's 20:38Z run. Whether either pull request was already queued at run start is unread. KEN-2557's no-pre-flight-read bar answered a different symptom, a defer after a refused call.

### Adoption and the inventory

- The adopter writes the caller from `refresh/kendex-refresh.yml` in its release tree. It accepts the existing file when its bytes equal any template in kendex default-branch history at either template path. This is the KEN-2416 check, extended to the new path, so a hand edit is still refused and kept. Its environment check judges the names the shared workflow declares, because the caller declares no `environment:` (Migration order step 2). It accepts only the shipped template's form: a `secrets:` key on the line under `uses:` mapping exactly those names, in order, each to its same-named secret. It refuses every other form with `refresh-error=caller-secrets`. A caller that maps neither name has its job read the app secrets empty (runs 37187198901 and 37191124465).
- The adopter removes the caller's `.kendex-generated.json` record, and `kendex verify` no longer compares it. The history check is its equality check.
- A refresh pull request that changes the caller classifies `standard`, so the overseer or a maintainer merges it (KEN-2539). With no version in the file, that happens only when the triggers change.

### Compatibility contract

- The consumer-visible contract is the caller file: the workflow path, the `vX` ref, and the job taking no inputs and mapping the two app secrets by name. Within a major, a change keeps the old form working, with one warning naming the new form ([changelog.d/README.md](../../changelog.d/README.md) § Release standard).
- The shared workflow and its scripts are one kendex release. A template change that the release at `v1` cannot serve merges only after a release carries it, the release-first rule [RELEASING.md](../RELEASING.md) § Catalog compatibility states for catalog content.
- **Rollback depth**: pointing `v1` back moves the workflow and scripts together, because each run takes both from the commit its workflow file came from. A rollback cannot undo what the bad release wrote into consumers: renders, `.kendex-lock.json`, the inventory and the caller. The release standard makes newer code read older forms, not older code read newer ones. A rollback to an earlier 1.x release is safe when no later release changed a format a consumer commits. Otherwise the fix is a new release, not a rollback.

## Deletion list

Steps are the [Migration order](#migration-order). A row lands in the build of its step: step 4 is Build B, step 6 is Build C.

| Mechanism | Where | Deleted at | Why it is no longer needed |
| --- | --- | --- | --- |
| The 92-line refresh template's steps, including "Preserve default-branch scripts" and its `install-latest.sh` run | `skills/review-gate/templates/kendex-refresh.yml` | Step 4: the template becomes the caller | The shared workflow runs them from the release tree |
| Template rows that require exec from the consumer copy | `skills/review-gate/tests/refresh-workflow.test.sh` | Step 4, with the template they test | Replaced by the controls under Build items |
| Rendered refresh scripts in every consumer | `skills/review-gate/scripts/` and `lib/review-findings.sh`, except `install-latest.sh` | Step 4 | Moved to `refresh/` at step 2. A hand run of the adopter runs `refresh/adopt-refresh.sh` from a kendex checkout at the release tag ([hand runs](#the-shared-workflow)) |
| Inventory record and verify equality for the refresh workflow | `.kendex-generated.json` in each consumer; [generated-paths.md](../architecture/generated-paths.md) | Step 4: the first shared-workflow run removes the record; Build B updates the doc | The adopter's history check |
| Rendered template at the old path | `skills/review-gate/templates/kendex-refresh.yml` | Step 6 | Read only by committed adopters older than step 4 |
| KEN-2460 bridge: retained writer template and pre-platform fixtures | `templates/review-gate-writer.yml` (722 lines) and its render; `tests/fixtures/pre-platform/` (881 lines); the bridge row in `refresh-consumer.test.sh` | Step 6 | No pre-KEN-2089 runner runs after step 4 |
| `install-latest.sh` in every consumer render | `skills/review-gate/scripts/install-latest.sh` | Step 6: moves to `tools/install-latest` | Its last consumer-side caller, the retained writer template, goes in the row above |
| Trusted writer removal and the `legacy-writer` warning | `adopt-refresh.sh --retire-writer` | Step 6, once no consumer's run prints `refresh-warning=legacy-writer` | A one-time removal ([D018](../decisions/D018-platform-review-requirements.md)); vsys#159 and hyprtrade PR 692 have run it. From step 4 to step 6 the owning lane runs it as `refresh/adopt-refresh.sh --retire-writer` from a kendex checkout at the release tag |
| Per-consumer version pins | each consumer's workflow copy | KEN-2514 is the last; step 4 replaces any shipped pinned copy | The caller names a major tag only |

- **Added**: the shared workflow, which takes the template's steps; one tag ruleset on the major tags; the owner hand-off for the tag move, one line in app-deploy step 4; a narrower tag trigger in `release.yml`; one lifecycle read at run start, through KEN-2557's function; the `behind-release` warning, from the tag read step 3 already makes. The caller replaces the 92-line template with 15 lines. The deletions above remove the bridge's 1,603 source lines and one copy of nine files from every consumer. No new installer script is added.
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
| KEN-2594 | In Review | Unaffected, and needed: it removes the Consumer refresh check and its snapshot. If it has not landed by step 6, Build C repoints `.github/workflows/consumer-refresh.yml` line 30 to `tools/install-latest` |

## Decisions

- **D003**: Decision item 2 keeps the adoption-copied workflow, run-time release selection, the rolling pull request, the `kendex` environment and the token scope. It changes three things: where a run's code comes from, the caller naming a major tag, and the inventory record for this one workflow. The [Revisit Outcome (2026-10-02)](../decisions/D003-one-merge-path.md#revisit-outcome-2026-10-02) records them, and says that the writer's `install-latest.sh` route from the 2026-10-01 outcome stays until step 6.
- **D018 and merge-rail.md**: after step 4, the refresh code that runs under the consumer's app token, and the workflow file that reads the app's private key, come from the commit kendex's `vX` names, and no consumer pull request reviews them ([The private key](#tokens-and-secrets)). D018's rule holds as written, because the run still executes no script it refreshed. Its hand route holds too: the lane runs the reviewed adopter from a kendex release checkout ([hand runs](#the-shared-workflow)). D018 needs no revisit. [merge-rail.md](../architecture/merge-rail.md) § Decisions states that a consumer's reviewed merge establishes the default-branch scripts that refresh executes; Build B rewrites that sentence.
- **D001**: unchanged. Renders stay committed with the lock. Refresh scripts leave the render because, after step 4, no consumer workflow or CI job runs them.
- **consumer-render-model.md**: owner decision 1790634126 item 5 dropped route 1, which installs kendex in every CI job and commits only the lock. This design adds no install step: the refresh job already installs a release. Every other consumer CI job keeps reading committed renders.

## Migration order

1. **Prerequisites**: KEN-2539, KEN-2557, KEN-2536 and KEN-2310 merge (owner ruling). KEN-2514 completes. Each consumer's overseer confirms one passing run on its current workflow. A consumer that cannot pass is that overseer's drift; no kendex shim is added for it.
2. **Build A**: the shared workflow, `refresh/`, the caller template, the `release.yml` trigger, the owner hand-off in app-deploy step 4, and the run-start queue read. The owner creates the tag ruleset. The old-path template and the old copies under `skills/review-gate/scripts/` stay unchanged, because every consumer still runs its committed copy, except `adopt-refresh.sh`, which gains one branch. Today's adopter takes the replacement template's `environment:` line and `secrets.*` names and passes them to `validate-standard.sh --environment-only` (`adopt-refresh.sh` lines 36 to 40 at v1.3.0, lines 33 to 37 at v1.5.1 and on `main`). The caller has neither, so both values are empty, and `validate-standard.sh` refuses them with `standard-setting-missing` before the push. The branch checks a replacement template whose job calls the shared workflow, rather than declaring `environment:` and secrets, against the environment and secret names the shared workflow declares (`kendex`; `FLEET_GH_APP_ID;FLEET_GH_APP_PRIVATE_KEY`), and exports none of the empty values. Each consumer receives it through its normal render rolling pull request.
3. **Release**: a release is cut and published through app-deploy, and the owner creates `v1` at its commit. Build B merges only after each consumer's default branch holds the Build A adopter. The evidence is the blob SHA of `.agents/skills/review-gate/scripts/adopt-refresh.sh` at each consumer's default-branch HEAD, equal to a blob SHA kendex `main` has given `skills/review-gate/scripts/adopt-refresh.sh` since Build A merged. That consumer's overseer reads it where the lane credential cannot read the repository. A passing run is not this evidence: it can be the run that only wrote the Build A adopter into a rolling pull request not yet merged.
4. **Build B**: once `v1` exists, `skills/review-gate/templates/kendex-refresh.yml` becomes byte-equal to `refresh/kendex-refresh.yml`, with one test row holding them equal. The old copies except `install-latest.sh` leave `skills/review-gate/scripts/`. Each consumer's next run, still on its committed copy, whose adopter is Build A's (step 3), writes the render without the scripts and adopts the caller in one rolling pull request. Once that pull request merges, the consumer runs the shared workflow. From here a hand run of the adopter, for a first adoption or trusted removal, runs `refresh/adopt-refresh.sh` from a kendex checkout at the release tag.
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
| `uses: ...@main` | The workflow file and refresh scripts would change with every merge to kendex `main`, with no release; KEN-2416 rejects it |
| The release job moves `vX` with `GITHUB_TOKEN` | The release job publishes a stable release as a draft, which nothing can install, and the documented ruleset bypass list does not name `GITHUB_TOKEN`. See § The moving ref |
| A full release tag in each caller | That is the per-consumer pin the owner ruled out (note 1790974374) |
| `secrets: inherit` | Passes every secret the consumer can read, more than the run needs, and only within the caller's organization or enterprise. See § Tokens and secrets |
| Named secrets from repository or organization secrets | Any branch workflow can read them; the environment's branch policy is what keeps the key. See § Tokens and secrets |
| The workflow copied into each consumer and running scripts from the release tree | Still a 90-line copy per consumer, whose every step change travels through the old copy |
| Keep the scripts in `skills/review-gate/scripts/` and skip them in the render | `NOT_RENDERED` in `crates/core/src/source_read.rs` names top-level entries only. Skipping single files needs a new per-file rule in the engine |

## Owner questions

1. **Compatibility window**: KEN-2601 says the old form keeps reading for one minor release. [changelog.d/README.md](../../changelog.d/README.md) § Release standard also says the removal waits for a major release. Which rule holds for the step 6 deletions: the next minor release after every consumer shows step 5, or 2.0?
2. **Fix latency**: today a refresh-script fix reaches a consumer with a working copy one run after it merges on `main`. Under this design it reaches consumers at the next release. kendex shipped 8 stable 1.x releases from v1.0.0 (2026-09-23) to v1.5.1 (2026-10-02); 7 of them, from v1.0.1 (2026-09-26), fall inside the 7-day sample.
3. **KEN-2355**: cancel, per the ruling above.
4. **Tag mover**: the design has the owner move `vX` by hand at each stable publication, because no documented bypass actor is held by the release job alone: the release job's `GITHUB_TOKEN` is not on the documented list, and the lanes app is every lane's identity. That is one owner step per stable release (8 from 2026-09-23 to 2026-10-02, question 2). The alternative is a release-only GitHub App no lane holds, which adds an app, its private key and a place for the key that no lane can read. Which holds?
5. **A separate key job**: should a later item move the app private key into its own job, which runs no kendex binary and no rendered code? Every step of a job runs on the same runner (GitHub Docs, understand-github-actions.md § Jobs), so today and under this design the key sits on the runner beside both. A minted token does not pass to another job as a plain job output: `actions/create-github-app-token` registers each token it mints as a secret (`lib/main.js` line 48 at `bcd2ba49`), and GitHub redacts a job output that holds a secret (reusables/actions/jobs/section-defining-outputs-for-jobs.md). That split is a design of its own, outside this build.

## Build items

Filed from this design after approval.

- **Build A**:
  - Contents: the shared workflow, `refresh/`, the caller template, the `release.yml` `v*.*.*` trigger, and the owner hand-off in app-deploy step 4: it names the owner as the actor who moves `vX`, and tells a lane to stop after publishing and report the tag and its commit. The adopter reads its own tree, drops the inventory record and searches both template paths. The consumer-side `skills/review-gate/scripts/adopt-refresh.sh` gains the shared-workflow caller branch (Migration order step 2), with one test row holding that branch's environment and secret names equal to the `environment:` and `secrets.*` names `refresh-consumer.yml` declares. The run-start queue read. The refresh suites and their CI shard move with the scripts.
  - First acceptance run: `review-gate-sandbox` calls the shared workflow. The run proves that the called job reads the sandbox's `kendex` environment secrets, and that a caller on a non-default branch gets no secret.
  - Must-fail controls:
    - the shared workflow runs a script from the consumer checkout;
    - the installed engine reports a version other than the tag on the checked-out commit;
    - the workflow's commit carries no stable tag of the ref's major, or two, and the run still installs;
    - a higher stable tag of the same major exists, and the run prints no `refresh-warning=behind-release`;
    - the consumer-side `adopt-refresh.sh` refuses the shared-workflow caller as its replacement template. The v1.5.1 adopter fails this row today, so it is its own control;
    - a queued rolling pull request still reaches the push;
    - the pull request enters the queue between the run-start read and the push, and the run does not end deferred;
    - once the owner has created the ruleset, a lane installation token creates `v2`, force-pushes `v1` or deletes `v1`, and the push succeeds. The in-workflow tag check covers the owner pointing `vX` at the wrong commit only, so this control is the one that tests the ruleset.
- **Build B**: make the old-path template equal the caller, remove the old copies except `install-latest.sh`, and update each statement that step 4 makes false:
  - [review-gate SKILL.md](../../skills/review-gate/SKILL.md): line 33, which sends fresh installs to `scripts/adopt-refresh.sh`, and the § Scripts rows for `adopt-refresh.sh`, `refresh-consumer.sh`, `refresh-reviews.sh` and `dispatch-refresh.sh` (lines 48 and 50 to 52);
  - [review-gate DEVELOPMENT.md](../../skills/review-gate/DEVELOPMENT.md) lines 15 to 29, which name `refresh-consumer.sh`, `refresh-report.py` and the refresh suites that move to `refresh/`;
  - [adoption.md](../../skills/review-gate/references/adoption.md): § Trusted removal, line 34 and step 1 (lines 36 to 43); § Automatic consumer refresh, lines 51, 55 and 57 to 67, which name the adopter's old path, the first-adoption command and the default-branch history check at the old template path;
  - [merge-rail.md](../architecture/merge-rail.md): the consumer refresh workflow row of § Ownership ("each consumer runs its adopted copy"), the § Boundaries sentences on the verbatim copy's inventory record and `kendex verify` equality, and the § Decisions bullet;
  - [generated-paths.md](../architecture/generated-paths.md), and the last sentence of [RELEASING.md](../RELEASING.md) § Catalog compatibility, which says the refresh template uses `install-latest.sh`.
- **Build C**: the step 6 deletions, after the owner's answer to question 1. `install-latest.sh` moves to `tools/install-latest` and its suite to `tools/tests/install-latest.test.sh`, the layout [tools/AGENTS.md](../../tools/AGENTS.md) sets. Each caller and statement moves with them: `.github/workflows/catalog-check.yml` (lines 57 and 70), `.github/workflows/skill-tests.yml` line 670, `crates/cli/tests/release_workflow/catalog.rs` (lines 164 and 270), [RELEASING.md](../RELEASING.md) line 21, [review-gate SKILL.md](../../skills/review-gate/SKILL.md) § Scripts line 49, [adoption.md](../../skills/review-gate/references/adoption.md) line 55, the `refresh-workflow.test.sh` writer row, and `.github/workflows/consumer-refresh.yml` line 30 unless KEN-2594 removed it.

## Discovered work

- `tools/catalog-release-check` installs the catalog into a fresh project, so a catalog change that the released engine cannot settle in an existing install passes kendex CI. Reached by 47 vsys failures from 2026-10-01T07:01Z to 21:17Z: the agent rename landed before an engine that removes old agent renders was released.
