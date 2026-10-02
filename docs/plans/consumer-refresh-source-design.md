# Consumer refresh source design

Each consumer's refresh workflow reads the latest stable kendex release's tag at run time, clones that tag's tree, installs that release from the tree's own `install.sh`, and runs the refresh scripts from the tree. The refresh scripts leave every consumer render, so a consumer commits the workflow file and no refresh script. A fix to a refresh script then reaches every consumer at the next release, with no hand-made consumer pull request. In the one readable current consumer, 425 of 558 runs failed over 7 days (76.16%). The design removes 77 of those failures: each came from a committed copy older than a released fix, or from a version pin in that copy. The other 348 came from defects in released kendex code. The design does not remove them; it ends each one at the release that fixes it.

Design for owner review (KEN-2601). This PR builds nothing. Measurements and run IDs: [consumer-refresh-source-design.evidence.json](consumer-refresh-source-design.evidence.json).

## Framing

- **Read**: the KEN-2601 Requirements and the owner ruling on it (note 1790974374), [D003](../decisions/D003-one-merge-path.md), [D001](../decisions/D001-portable-lock.md), [D007](../decisions/D007-lock-record-on-main.md), [D018](../decisions/D018-platform-review-requirements.md), [consumer-render-model.md](consumer-render-model.md), [ken-2416-consumer-refresh.md](ken-2416-consumer-refresh.md), [ken-2416-refresh-runs.md](ken-2416-refresh-runs.md), [github-standard.md](github-standard.md) § Refresh path, [RELEASING.md](../RELEASING.md) § Catalog compatibility, [changelog.d/README.md](../../changelog.d/README.md) § Release standard, the refresh template and scripts under `skills/review-gate/`, vsys `main` at `c6c73f5`, and each related issue live.
- **Credential**: the lanes app installation token. It reads public repositories only.
- **Principles document**: not in this repository. The compatibility rule below is the one [changelog.d/README.md](../../changelog.d/README.md) § Release standard states.

## How a refresh runs today

- `templates/kendex-refresh.yml` reaches a consumer by adoption copy. The copy runs the consumer's committed `install-latest.sh`, checks out the consumer's own default branch into a detached worktree, and runs the committed `refresh-consumer.sh` and `refresh-reviews.sh` from it.
- `refresh-consumer.sh` calls the committed `adopt-refresh.sh`, `validate-standard.sh` and `change-class`. The adopter reads kendex templates from the render the same run just wrote.
- A change to any of these files reaches a consumer only through a run of the copy it replaces. A defect that stops that run before publication can only be cleared by hand: KEN-2296, KEN-2417 (vsys#126), KEN-2514 and vsys#148 are those hand steps.
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
- The private consumers return HTTP 404 to this credential. Their rates are unmeasured here, and KEN-2416's private supplement came from the overseer. KEN-2514 records that hyprtrade, hyprtrade-io, drovr and kendex-web ran v1.2.0 from a pin in their own workflow copy until hand pull requests replaced it.
- In vsys, 1 of the 53 runs created after `2026-10-02T13:00:00Z` failed (1.89%). That one failure is KEN-2557's defect.

## Failure causes

All 425 vsys failures stop in the refresh step, except two in the review-filing step. Each failed log was read and assigned one class.

| Class | Runs | First and last run | Cause | Removed by this design |
| --- | ---: | --- | --- | --- |
| Adopter reads a missing record as a hand edit, before the fix shipped | 153 | 09-29 18:23Z to 09-30 22:23Z | Defect in shipped `adopt-refresh.sh`; fixed by KEN-2278, released in v1.3.0 at 09-30 22:24Z | No |
| Runner refuses to publish a standard-class refresh | 136 | 09-28 04:24Z to 09-29 18:04Z | Defect in shipped `refresh-consumer.sh`; fixed by KEN-2277, released in v1.3.0 | No |
| Leftover `generalist` agent fails refresh or verify, before the fix shipped | 47 | 10-01 07:01Z to 10-01 21:17Z | The catalog renamed agents before a released engine could remove the old renders; fixed by KEN-2438, released in v1.4.0 at 10-01 21:23Z | No |
| Adopter reads a missing record as a hand edit, after the fix shipped | 40 | 09-30 22:35Z to 10-01 05:47Z | vsys ran its committed adopter. The fix reached it through the hand pull request vsys#126 (KEN-2417) | Yes |
| Leftover `generalist` agent, engine pinned in the workflow copy | 22 | 10-01 21:35Z to 10-02 02:06Z | vsys's copy installed v1.3.0 from its own pin after v1.4.0 shipped. The hand pull request vsys#148 moved the pin | Yes |
| Old runner validates a template the new render deleted | 15 | 10-01 15:31Z to 10-01 19:02Z | The committed runner read `review-gate-writer.yml` from a render KEN-2089 had changed (KEN-2460) | Yes |
| Classifier cannot prove a render retirement | 6 | 10-02 10:55Z to 11:36Z | `change-class` refuses deleted renders; KEN-2552 (Done, unreleased) and KEN-2536 own it | No |
| Push to the rolling branch refused | 2 | 09-28, 10-02 | GitHub refused the push, once with GH006 while the branch was queued | No |
| Review thread held open | 2 | 10-02 04:32Z | `upstream-unfiled`: a correct hold | No |
| Default branch moved during the run | 1 | 10-02 12:47Z | A correct refusal | No |
| Auto-merge disable after the queue took the pull request | 1 | 10-02 16:46Z | KEN-2557 | No |

- Removing the three delivery classes leaves 348 of 558 failures (62.37%) in this sample. The design alone does not reach the 5% target.
- The 348 remaining failures came from defects kendex shipped. Under this design each ends at the release that fixes it, with no consumer pull request. In this sample, the two adopter and pin episodes ended only with a hand-made vsys pull request: the last failure before vsys#126 merged ran 9 seconds before the merge, and the last before vsys#148 ran 2 minutes before it.
- The leftover-agent class passed kendex CI. `tools/catalog-release-check` installs the catalog into a fresh project, which holds no agent from an earlier catalog ([RELEASING.md](../RELEASING.md) § Catalog compatibility). This gap is reported under Discovered work, not built here.

## Design

### The workflow

The workflow is the one file a consumer commits for refresh. It names the release tree's entry scripts and nothing from the consumer's own `.agents/`.

```yaml
      # Every script this job runs comes from the latest stable release's tree.
      - name: Fetch the latest kendex release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          tag="$(gh release view --repo vanillagreencom/kendex --json tagName --jq .tagName)"
          git clone --quiet --depth 1 --branch "$tag" https://github.com/vanillagreencom/kendex.git "$RUNNER_TEMP/kendex"
      - name: Install that release
        run: exec "$RUNNER_TEMP/kendex/refresh/install-release.sh"
      # The app token steps stay as they are.
      - name: Refresh and arm the rolling pull request
        run: exec "$RUNNER_TEMP/kendex/refresh/refresh-consumer.sh"
      - name: File rendered-file findings upstream and resolve them
        run: exec "$RUNNER_TEMP/kendex/refresh/refresh-reviews.sh"
```

- `gh release view` with no tag reads the latest release (`gh release view --help`). Release resolution happens once, in this step.
- The clone runs before either app token exists and uses no credential. This is the boundary `install-latest.sh` keeps today.
- The "Preserve default-branch scripts" step goes. The property it held stays: no code from the refreshed tree runs under the app token. The one existing exception also stays: the settings report sources the consumer's rendered orch libraries under `env -i` with no credential.
- The workflow names no version. A consumer that edits it to hold a release owns that edit: the adopter refuses to replace it (`refresh-error=workflow-edited`). That is the consumer's own drift. To withdraw a bad release, the owner marks the previous release latest (`gh release edit --latest`), and every consumer's next run takes the previous release.

### The release tree

- `refresh/` at the kendex repository root holds `refresh-consumer.sh`, `adopt-refresh.sh`, `refresh-reviews.sh`, `refresh-report.py`, `dispatch-refresh.sh`, `install-release.sh`, `lib/review-findings.sh`, `kendex-refresh.yml` and their tests. `refresh/` is outside every catalog root, so no render carries it and `tools/guard` owes it no render.
- `install-release.sh` replaces `install-latest.sh`. It reads the clone's tag, refuses a tag that is not `vX.Y.Z`, and runs the clone's own `install.sh --version TAG --cli-only`, so it downloads no second installer. It then fails unless `kendex --version` reports that tag. kendex's own `catalog-check.yml` and `skill-tests.yml` call it at its new path.
- Refresh scripts take kendex templates from their own release tree, never from the consumer render. The release scripts read the consumer render only for consumer data: the settings report's orch libraries.
- The refresh scripts still call `skills/review-gate/scripts/validate-standard.sh`, `lib/settings.sh` and `skills/harness-ci/scripts/change-class` from the release tree. Those files stay in their packages, because consumers use them outside refresh.

### Adoption and the inventory

- The adopter writes `.github/workflows/kendex-refresh.yml` from `refresh/kendex-refresh.yml` in its release tree. It accepts the existing workflow when its bytes equal any template in kendex default-branch history, at either template path. This is the KEN-2416 check, extended to the new path.
- The adopter removes the workflow's `.kendex-generated.json` record, and `kendex verify` no longer compares this workflow. The adopter's history check is its equality check. A main template can be newer than the latest release, so a recorded copy would fail verify on every run until that release ships.
- A refresh pull request that changes the workflow classifies `standard`, so the overseer or a maintainer merges it (KEN-2539). With no version in the workflow, a template change is a rare event.

### Compatibility contract

- The committed workflow from release N runs with the scripts of a later release M, for one run, before the adopter replaces it. The contract between them is the entry paths under `refresh/` and the environment variables the workflow passes: `GH_TOKEN`, `GH_REPO`, `REFRESH_APP_SLUG` and `KENDEX_ISSUES_TOKEN`.
- A change to that contract keeps the old form working, with one warning naming the new form, for at least one minor release ([changelog.d/README.md](../../changelog.d/README.md) § Release standard). A test row in `refresh/tests/` runs the previous shipped template's exec lines against the current tree.
- A template change on kendex `main` that uses a new entry path or variable merges only after a release carries it. This is the release-first rule [RELEASING.md](../RELEASING.md) § Catalog compatibility already states for catalog content.

## Deletion list

| Mechanism | Where | Deleted at | Why it is no longer needed |
| --- | --- | --- | --- |
| "Preserve default-branch scripts" step | `templates/kendex-refresh.yml` | Step 2 | Scripts come from the release tree |
| Committed `install-latest.sh` run by the workflow | template; `skills/review-gate/scripts/install-latest.sh` | Steps 2 and 4 | `refresh/install-release.sh` from the release tree |
| Rendered refresh scripts in every consumer | `skills/review-gate/scripts/` and `lib/review-findings.sh` | Step 4 | Moved to `refresh/` |
| Inventory record and verify equality for the refresh workflow | `.kendex-generated.json` in each consumer; [generated-paths.md](../architecture/generated-paths.md) | Step 2 | The adopter's history check |
| Rendered template at the old path | `skills/review-gate/templates/kendex-refresh.yml` | Step 6 | Read only by committed adopters older than step 4 |
| KEN-2460 bridge: retained writer template and pre-platform fixtures | `templates/review-gate-writer.yml`; `tests/fixtures/pre-platform/`; the bridge row in `refresh-consumer.test.sh` | Step 6 | No pre-KEN-2089 runner runs after step 4 |
| Trusted writer removal and the `legacy-writer` warning | `adopt-refresh.sh --retire-writer` | Step 6, once no consumer's run prints `refresh-warning=legacy-writer` | A one-time removal ([D018](../decisions/D018-platform-review-requirements.md)); vsys#159 and hyprtrade PR 692 have run it |
| Template rows that require exec from the consumer copy | `skills/review-gate/tests/refresh-workflow.test.sh` | Step 2 | Replaced by the controls under Build items |
| Per-consumer version pins | each consumer's workflow copy | KEN-2514 is the last; step 4 replaces any shipped pinned copy | The workflow names no version |

- **Aliases past their window**: none on the refresh path. The `REVIEW_GATE_STANDARD_*` reads in `validate-standard.sh` are inside their stated window, which ends at 2.0.
- **Not deleted**: `dispatch-refresh.sh` keeps its job and moves to `refresh/`. The settings report keeps its read of the consumer's orch libraries. The Consumer refresh check is KEN-2594's deletion, and this design adds no pre-merge consumer check in its place.

## Ruling on open items

| Item | State | Ruling |
| --- | --- | --- |
| KEN-2297 | Canceled | Superseded by this design; its two must-fail controls are under Build items |
| KEN-2355 | Backlog | Unneeded. It moves the refresh scripts into `skills/github-repository-settings/`, a rendered package, which puts the copies back into every consumer. Its `GITHUB_STANDARD_REFRESH` and `GITHUB_STANDARD_DISPATCH` opt-ins answer no measured failure: a repository opts in by holding the workflow. Recommend cancel |
| KEN-2376 | Backlog | R47 is met by KEN-2416's edit preservation. R15, R21 and R22 name `review-predicate.sh`, which KEN-2089 deleted. X39 and X40 stay with `dispatch-refresh.sh` |
| KEN-2514 | In Progress | Kept as the last pin bump (owner ruling). Done when drovr passes |
| KEN-2539, KEN-2557, KEN-2536, KEN-2310 | Backlog | Kept; each lands before step 2 (owner ruling). A script fix among them reaches consumers at the first release after step 4 |
| KEN-2363 | Backlog | Kept, narrower: refresh leaves review-gate at step 4, so its retirement table loses the refresh rows |
| KEN-2354 | Backlog | Kept, narrower: its adoption operation no longer manages the refresh workflow |
| KEN-2359 | Backlog | Unaffected |
| KEN-2391 | Backlog | Unaffected: its rows are engine refusals, not delivery |
| KEN-2594 | In Progress | Unaffected, and needed: it removes the Consumer refresh check and its snapshot |

## Decisions

- **D003**: Decision item 2 keeps the adoption-copied workflow and run-time release selection. It changes how a run gets its code, and it drops the inventory record for this one workflow. The [Revisit Outcome (2026-10-02)](../decisions/D003-one-merge-path.md#revisit-outcome-2026-10-02) records both.
- **D001**: unchanged. Renders stay committed with the lock. Refresh scripts leave the render because, after step 4, no consumer workflow or CI job runs them.
- **consumer-render-model.md**: owner decision 1790634126 item 5 dropped route 1, which installs kendex in every CI job and commits only the lock. This design adds no install step: the refresh job already installs a release. Every other consumer CI job keeps reading committed renders.

## Migration order

1. **Prerequisites**: KEN-2539, KEN-2557, KEN-2536 and KEN-2310 merge (owner ruling). KEN-2514 completes. Each consumer's overseer confirms one passing run on its current workflow. A consumer that cannot pass is that overseer's drift; no kendex shim is added for it.
2. **Build A**: `refresh/` holds the scripts and `refresh/kendex-refresh.yml` as above. The old copies under `skills/review-gate/scripts/` and the old-path template stay unchanged, because every consumer still runs its committed copy.
3. **Release**: the owner cuts a release that carries `refresh/`, through app-deploy.
4. **Build B**: after that release is latest, `skills/review-gate/templates/kendex-refresh.yml` becomes byte-equal to `refresh/kendex-refresh.yml`, with one test row holding them equal. The old copies leave `skills/review-gate/scripts/`. Each consumer's next run, still on its committed copy, writes the render without the scripts and adopts the new workflow in one rolling pull request. Once that pull request merges, the consumer runs the release tree.
5. **Observe**: each consumer's first run whose log shows the step "Fetch the latest kendex release" starts its 7-day sample. The overseer supplies the private rows.
6. **Build C**: delete the rows marked step 6, after the compatibility window (Owner questions, item 1).

## Target

- Under 5% failed runs over 7 days in every current consumer, counted with the same `gh run list` command from each consumer's step 5 start.
- This sample says the target depends on kendex shipping fewer defects, not on delivery alone. After `2026-10-02T13:00:00Z`, with one defect live, vsys failed 1 of 53 runs. Over the full 7 days, with the classes above live in turn, it failed 76.16%.

## Rejected alternatives

| Alternative | Why rejected |
| --- | --- |
| Port the refresh into a `kendex` subcommand | It moves pull-request publication into the CLI, which [overview.md](../architecture/overview.md) § Decisions says opens no pull request in a consumer, and ports about 800 shell lines with no measured failure the release tree does not already remove |
| A reusable workflow or composite action in kendex, called with `uses:` | The file names its ref: `@main` runs unreleased code beside the app secrets (KEN-2416 rejects this), and a fixed tag is the per-consumer pin |
| Template stays in the render, scripts from the release | A main template newer than the latest release runs with older scripts. That is the KEN-2460 failure in the other direction |
| Pin the consumer's catalog source to the release tag | One commit would supply everything, but consumers would get catalog changes only at a release. That changes the subscription model, and no measured failure asks for it |
| Keep the scripts in `skills/review-gate/scripts/` and skip them in the render | `NOT_RENDERED` in `crates/core/src/source_read.rs` names top-level entries only. Skipping single files needs a new per-file rule in the engine |

## Owner questions

1. **Compatibility window**: KEN-2601 says the old form keeps reading for one minor release. [changelog.d/README.md](../../changelog.d/README.md) § Release standard also says the removal waits for a major release. Which rule holds for the step 6 deletions: the next minor release after every consumer shows step 5, or 2.0?
2. **Fix latency**: today a refresh-script fix reaches a consumer with a working copy one run after it merges on `main`. Under this design it reaches consumers at the next release. The sample holds 7 stable releases from v1.0.0 (2026-09-23) to v1.5.1 (2026-10-02).
3. **KEN-2355**: cancel, per the ruling above.

## Build items

Filed from this design after approval.

- **Build A**: create `refresh/`, `install-release.sh` and the new template. Change the adopter to read its own tree, drop the inventory record and search both template paths. Move the refresh suites and their CI shard. Must-fail controls: the template's exec path names the consumer copy; the installed engine reports a version other than the cloned tag; the previous shipped template's exec lines fail against the tree.
- **Build B**: make the old-path template equal the new one, remove the old copies, and update [adoption.md](../../skills/review-gate/references/adoption.md), [merge-rail.md](../architecture/merge-rail.md) and [generated-paths.md](../architecture/generated-paths.md).
- **Build C**: the step 6 deletions, after the owner's answer to question 1.

## Discovered work

- `tools/catalog-release-check` installs the catalog into a fresh project, so a catalog change that the released engine cannot settle in an existing install passes kendex CI. Reached by 47 vsys failures from 2026-10-01T07:01Z to 21:17Z: the agent rename landed before an engine that removes old agent renders was released.
