# Repository wiring and consumer refresh

## Repo-side wiring

GitHub rulesets enforce review requirements.

- The organization ruleset holds pull-request approval, stale-approval dismissal, thread resolution, Copilot review, deletion and force-push rules.
- Each repository keeps its required-checks ruleset and merge-queue ruleset.
- A repository keeps no classic branch protection.

Enable Copilot approvals and let them count toward merge requirements. Leave the approval path list blank so every changed file can qualify.

The harness-ci CI template's queue-only default makes the merge-group run the only proof of each head, so it needs the repository's merge-queue ruleset. The default reaches a consumer only through its overseer's adoption, filed in that consumer's tracker. The harness-ci package's references/wiring.md § Per-lane verdicts states the adoption order, and its § The CI template states the rest.

Run the [GitHub platform checks](../../github-repository-settings/references/platform-checks.md) to report the repository's rulesets and CI.

## Central Copilot request workflow

For the organization refresh exception, the organization owner reads and updates the ruleset with their own credential:

- Require `.github/workflows/request-copilot-review.yml` from `vanillagreencom/kendex` through a `workflows` rule.
- Pin `sha` to the merged commit that holds the reviewed workflow, with `ref: refs/heads/main` and kendex's repository ID.
- Replace the `copilot_code_review` rule only after that commit exists.
- Preserve every other rule, condition and the empty bypass list.

Review-gate owns that central workflow in kendex's own `.github/workflows/`, beside `refresh-consumer.yml`. Consumers copy and render none of it.

The workflow decides its request this way:

- The job is skipped with no runner for the exact `kendex/refresh` head authored by `vanillagreen-fleet-lanes[bot]` with account type `Bot`.
- For other non-draft pull requests, the job runs on the repository's `vars.CI_RUNNER_2V` where it resolves, and on `ubuntu-latest` otherwise.
- For a head in the base repository, it requests `copilot-pull-request-reviewer[bot]` through GitHub's REST review-request endpoint, unless the pull request is a proved quick change.
- The job classifies a full-history checkout with `vanillagreencom/kendex/.github/actions/change-class@main`. It skips the request, with a `reason=quick-proof` log line, only where that step's `quick` output is the literal `true`: a trivial change whose every path is an admitted settings file or Markdown of the docs set, under no repository `HARNESS_CI_TRIVIAL_PATHS`, as change-scope's `quick-proof:` record states.
- The classify step continues on error, so a classifier failure leaves the output empty and the request in place.
- A failed request emits a warning and passes. GitHub's approval, stale-approval dismissal and thread-resolution rules still enforce review.
- The workflow still triggers on merge groups, but its job skips there without allocating a runner.

Draft, ready and fork pull requests:

- A draft pull request gets no automatic review request.
- A ready cloud head with no review gets its request through the overseer's existing `awaiting-stale` route, per orch's references/copilot-head-notices.md § Fallback approval.
- Ruleset workflows ignore activity filters, so adding `ready_for_review` does not trigger this workflow.
- A same-repository pull request outside a lane gets its automatic request on its next non-draft push.
- A fork head gets no automatic request on any push, and the `awaiting-stale` route does not serve it. A maintainer requests its Copilot review by hand.

GitHub's ruleset workflow contract:

- GitHub supports a public ruleset workflow in any repository in the organization, including private consumers.
- Ruleset workflows support `pull_request`, `pull_request_target` and `merge_group`. The central workflow runs on `pull_request` and `merge_group`, since from 2026-12-02 GitHub blocks `pull_request_target` in a public repository whose Actions event policy does not allow it.
- It uses the `pull_request` token with `contents: read` for the checkout. It reads the pull-request tree with kendex main's classifier and executes none of it.
- That token is read-only for a fork's pull request, so the request step skips a fork head with a `reason=fork-read-only-token` log line and passes.
- The workflow's `permissions` key raises a Dependabot head's token, so Dependabot heads keep their request.
- Sources: [ruleset workflow visibility](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#using-a-workflow-file), [supported events](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules#supported-ruleset-workflow-events), [Copilot REST requests](https://docs.github.com/en/copilot/how-tos/copilot-on-github/use-copilot-agents/copilot-code-review) and [workflows rule fields](https://docs.github.com/en/rest/orgs/rules#update-an-organization-repository-ruleset).

The report in [github-repository-settings](../../github-repository-settings/references/platform-checks.md) checks the resulting workflow rule. GitHub still applies its native automatic review where a ruleset carries that rule; the github skill's references/automatic-review.md covers routing. Refresh approval follows orch's references/copilot-head-notices.md § Consumer refresh approval.

## Automatic consumer refresh

Before enabling automatic refresh, wire the consumer's CI through harness-ci's references/wiring.md § Consumer refresh CI. A consumer with no required checks and an unprotected default branch needs no consumer CI or `change_class` wiring.

### Schedule and input check

- The shipped caller, `refresh/kendex-refresh.yml` in the kendex release, requests update checks once a day.
- Consumers take this schedule through `refresh/adopt-refresh.sh`. An existing workflow keeps its earlier schedule until adoption.
- GitHub can delay, drop or disable scheduled runs.
- A manual run uses the same path.

A run can hold the refresh group while it waits on its selected environment gate:

- A run still waiting 30 minutes after its last state change holds the refresh group, so the next run's release job force-cancels it before that run's refresh asks for the group.
- On a first-attempt automatic dispatch from the fleet app, an adopted caller can skip the release job when the sender proves no run is waiting.
- For a waiting run, unreadable proof, an older caller, a rerun, or a manual or daily event, the release job must succeed before refresh joins the group.
- If that job's API call fails or times out, refresh stays outside the group.
- The job re-reads each run just before its cancel and skips one no longer waiting. GitHub offers no cancel conditioned on status, so a run released in the instant between that re-read and the cancel can still be cancelled.

Both jobs check the run's inputs:

- The release job checks inputs with the caller's GitHub token at its defining workflow commit, after handling cancellation.
- The refresh job independently checks out its defining workflow commit. It rechecks after its environment and concurrency wait, before installation or token minting.
- The checker compares the kendex main commit, its workflow commit, the stable v1 release tags and the consumer default-branch head with its last current record.

The current record:

- The record lives in the consumer Actions artifact `kendex-refresh-current`. It identifies the run and attempt that produced it.
- Only a successful run that captured the complete input tuple at its start, proves source coverage and ends `refresh-state=current` writes it.
- Source coverage requires the engine to report only the default remote catalog without a revision. Other enabled subscriptions, local paths, any manifest revision override and unknown source evidence keep the full refresh path.
- An incomplete tuple writes no record, so the next run refreshes in full.
- An unchanged tuple skips the refresh job or the remaining refresh steps only when no rolling pull request is open and none merged in the last 24 hours.
- When none is open but one merged in that window, it skips only the render step. The run still installs the release, mints both tokens and answers review threads, and saves no record.
- A record is reused for at most 24 hours, and only while its producing attempt is still the latest attempt of that run.

The run history check:

- The check reads the complete workflow history from 65 days before the record. This covers the 30-day rerun request window plus the 35-day limit for execution, waiting and approval.
- It includes older runs whose rerun was requested before the record but finished after it.
- Every other run updated since the record must have one successful attempt. Its complete job listing must show either a successful `refresh-input-check` with the render step skipped, or a successful `release-input-check` with no other executed job.
- In the latter form, remaining jobs are skipped or omitted. This no-render history preserves the existing record and writes no new one.
- A rerun, a failed, cancelled or timed-out full run, or unknown attempt evidence keeps the full refresh path.
- A newer skipped run cannot hide an earlier full attempt.
- The history reads use separate date ranges to stay below the API search cap. Missing history or a date range that reaches 1,000 runs also runs a full refresh.
- A changed input, a missing or unreadable record, or a failed input or review read also runs the full refresh.
- The caller grants its GitHub token Actions-read and Pull-requests-read access for these checks. Existing callers need adoption to gain these grants. Their unreadable evidence keeps the full refresh path.

### Release and catalog

- The shared workflow checks out the commit its own workflow file names. It installs the stable release tagged on that commit.
- It renders the default catalog from `main` when the source has no declared `rev`.
- Compatible package changes reach the consumer after merge at its next daily run, at the next release request, or at once through an on-demand `workflow_dispatch` start for that repository. Fleet-managed repositories can use `fleet repos kendex-refresh --repo NAME` for the on-demand start.
- When main requires a newer CLI, the existing compatibility refusal selects the release catalog for a retry. The run prints `catalog-held min=X engine=Y` and explains the hold in its pull request or run summary.
- A declared `rev` takes precedence. The existing lock record prevents an older catalog reading.
- A retry that still refuses stops the refresh.
- Renderer, apply, refresh, install, verify, manifest and lock changes, and catalog changes that raise the minimum, wait for their release and the `v1` move.
- The refresh scripts and classifier still run from the release checkout.
- A successful full refresh whose complete staged diff contains only the selected projects' `.kendex-lock.json` records makes no commit or pull request. The next refresh with any non-lock change carries the current locks and content through `kendex/refresh` and its rolling pull request.
- A content-changing refresh that produces a new head publishes it under [§ Publication](#publication), unless the run lands or defers it under [§ Landing a proved render](#landing-a-proved-render).
- A current consumer opens no pull request.

### Publication

`refresh/refresh-consumer.sh` rebuilds the rolling refresh branch from the default branch. It opens or updates its pull request on a new head that the run neither lands nor defers, at any measured class or an unmeasured standard class.

Before publication:

- The script runs the classifier from the same release checkout.
- It refuses held render edits before workflow adoption or publication.
- It preserves workflow edits under the [caller adoption contract](#caller-adoption-contract).

An identical rolling tree retains its exact head and existing arm or hold, reports no new publication, and defers automatic admission even with no open pull request. Only a newly published head follows the merge and arm route:

- The script disarms an armed pull request only before pushing a replacement head, after a fresh lifecycle read. A disarm GitHub refuses stops the run, unless the pull request is queued, merged or closed.
- It waits for GitHub to show the published head.
- If successful branch reads show no rules and no protection, it merges that head directly and reports `refresh-state=merged`. A failed direct merge reports `refresh-error=merge` and exits with the merge status.
- A branch with rules or protection, or a failed branch read, keeps app-token auto-merge.
- A head that stays unseen produces an unarmed warning.
- If GitHub refuses the arm and calls the pull request clean, it merges the pull request directly on the pushed head.
- It confirms that the arm enabled auto-merge, queued or merged the pull request.

The merge queue merges the pull request once the required approval, thread resolution and checks pass. The pull request body names the class, classifier cause and path. An unmeasured standard class uses full review and CI. A failed classifier or missing class line stops publication. Render publication requires measurement.

A run that committed a new head of measured class `render` first tries to land it under [§ Landing a proved render](#landing-a-proved-render):

- A push GitHub takes reports `refresh-state=landed pr=none class=render head=REVISION` and writes the report to the run summary. The run opens no pull request, and closes a rolling pull request GitHub still shows open.
- A push git rejects because the default branch moved reports `refresh-state=deferred reason=base-moved`. The next run renders on the new base.
- A merge queue that holds an entry reports `refresh-state=deferred reason=queued`. The run pushes nothing and opens or updates no pull request. A later run that meets an empty queue tries the landing again.
- A push GitHub refuses keeps the pull request route.
- Any other precondition the run does not meet keeps that route too.
- A retained head never lands.

The verify outcomes:

- A verify whose every failure is a declaration a project's own manifest withholds prints `refresh-verify=held project=ENTRY`. The run publishes the head, a retained one included, as a draft pull request whose body names each finding and its manifest line. It disarms that pull request, prints `refresh-state=held pr=NUMBER class=CLASS head=REVISION` and lands nothing.
- With no content change to publish, that verify failure stands.
- Any other verify failure, an unread verify document included, prints `refresh-error=verify value=STATUS` and exits with verify's status before publication.
- The next run whose verify passes marks a drafted rolling pull request ready before it arms it.

### Landing a proved render

[§ Publication](#publication) states when a run tries the landing push and its `refresh-state=landed` and `refresh-state=deferred` outcomes. The table below states each `refresh-land=` line.

The landing app is one GitHub App that serves this push alone.

- In the vanillagreen organization it is `vanillagreen-kendex-land`, app id 5726115. The organization owns it.
- It holds Contents read and write, Workflows read and write and Metadata read, and no other permission.
- It is installed on the consumer repositories.
- Never make the lanes app, or any other app that opens, arms or merges pull requests, the landing app: its ruleset bypass would then cover the pull requests that app handles.

The landing token:

- The pair is `KENDEX_LAND_APP_ID` / `KENDEX_LAND_APP_PRIVATE_KEY`, placed under the [caller adoption contract](#caller-adoption-contract).
- The shared workflow mints the landing token from that pair for the consumer repository alone, with Contents write and Workflows write alone.
- `refresh-consumer.sh` uses that token for one `git push` of the run's commit to the default branch. Every other call in the run uses the repository token.
- No script opens, arms or merges a pull request with the landing token.
- Contents write is also the permission GitHub's [merge endpoint](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps#repository-permissions-for-contents) requires, so the token's permissions do not prevent a merge. Add no second use of the token.
- `refresh/tests/shared-refresh-workflow.test.sh` and `refresh/tests/refresh-consumer.test.sh` in the kendex repository hold the token's permission and its one use.

What the run lands:

- The run lands only a commit it made itself, and only where the classifier, run from the release checkout, measures that commit as class `render`. change-scope's `change-scope --help` defines that proof, under its `render` class.
- The proof shows that the commit holds what kendex renders. It does not judge package content. kendex's own merge queue proves the content of the kendex catalog before `main` holds it, and the consumer runs no second proof of it. No such proof covers another source.
- The run therefore lands only where every selected project has the source coverage that [§ Schedule and input check](#schedule-and-input-check) requires of a current record: each enabled source is the kendex catalog, `vanillagreencom/kendex`, with no `path` and no `rev`, and no manifest holds a revision override.
- An update in a project with a third-party catalog, a local path, a declared revision or unknown source evidence keeps the rolling pull request, where the consumer reviews it.
- A commit that removes or renames a path against the base the run judged lands only where each such path lies at or below a path the commit's root `.kendex-lock.json` still lists in `emitted.paths`.
  - A removal inside a package the lock still emits lands.
  - A render that drops an emitted position, such as a pruned package or a removed or renamed per-file agent, hook or command, keeps the rolling pull request, which merges under the consumer's own rules.
- A landed commit has no pull request and enters no merge group, so no approval, review thread, pull-request check or merge-group check judges it in the consumer.

After a landing:

- The landed commit is an ordinary push to the default branch. A consumer workflow with a `push` trigger still starts for it.
- With no pull request and no merge group, a landed render skips the lanes that claim a path it changes. The harness-ci package's references/wiring.md § Consumer refresh CI names the run that first executes them.
- To undo a bad package, revert it on kendex `main`. Each consumer's next refresh renders the reverted content.
  - A revert whose render drops no emitted position lands by the same route.
  - A revert that drops a package or a per-file item the bad change added keeps the rolling pull request, and reaches the consumer only when that pull request merges.
- A landed run writes to its run summary what the pull request body carries on the other route: the landed commit, the engine version, the class and classifier line, and the catalog, settings and retired-item reports.

GitHub's rulesets judge the landing push, and the run reads no ruleset first. A ruleset that refuses the push leaves the update on the rolling pull request.

- GitHub's [required workflows rule](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets#targeting-specific-branches-with-your-ruleset-workflow) states: "Applying this rule will block direct pushes because the ruleset workflows run as part of the pull request and merge queue experience." The push therefore passes only where the landing app can bypass that rule too.
- The standard admits one ruleset shape for the app, which the [platform checks](../../github-repository-settings/references/platform-checks.md) report judges in its `standard-bypass-actors` row.
- That shape is a target: the organization owner sets it with their own credential, after the release that ships this route.
- In the target, one organization ruleset holds `pull_request` and `workflows`, with the landing app as its only bypass actor in mode `always`.
- The organization ruleset that holds `deletion` and `non_fast_forward` lists no bypass actor.
- The repository's merge-queue and required-checks rulesets list the landing app.
- Until the owner sets that shape, each ruleset that holds `pull_request`, `workflows`, the merge queue or the required checks and lists no bypass for the landing app refuses the landing push, and the update keeps the rolling pull request. There a deferral on a busy merge queue only delays that pull request.
- In the vanillagreen organization the landing app passes the rulesets: on 2026-11-24 GitHub took a landing push in vgshell, whose run 45449034468 printed `refresh-state=landed pr=none class=render`.

The landing token holds Workflows write because GitHub requires it of an app that edits a file under `.github/workflows` ([GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)). A render that rewrites the adopted caller `.github/workflows/kendex-refresh.yml` therefore lands like any other render. An installation keeps its old permissions until its owner accepts the new ones ([Modifying a GitHub App registration](https://docs.github.com/en/apps/maintaining-github-apps/modifying-a-github-app-registration#changing-the-permissions-of-a-github-app)). Where the landing app or its installation lacks Workflows write, the mint fails, the run prints `refresh-land=unavailable value=token`, and every update keeps the rolling pull request.

A run that committed a new head and kept the pull request route prints one landing line ahead of that route's record. A run that deferred on a busy merge queue prints its line ahead of `refresh-state=deferred reason=queued`.

- The shared workflow passes the script the boolean `KENDEX_LAND_CONFIGURED`: true where the run received either name of the pair, and never a secret value.
- A run that received neither name prints no landing line.
- The run checks the token, the verify, the class, the removed paths, the sources and the merge queue in that order. The line names the first check the run does not meet.

| Line | Cause |
| --- | --- |
| `refresh-land=unavailable value=token` | The run received one name of the pair alone, or the `Mint the landing token` step failed. |
| `refresh-land=skipped value=verify` | The run is held: its verify failed only on declarations a project's own manifest withholds. |
| `refresh-land=skipped value=class` | The classifier answered a class other than `render`. |
| `refresh-land=skipped value=path-removed` | The commit removes or renames a path that no `emitted.paths` entry of its root `.kendex-lock.json` holds at or above it. |
| `refresh-land=unavailable value=lock-read` | The commit removes or renames a path, and the run could not read the emitted paths of its root `.kendex-lock.json`. |
| `refresh-land=skipped value=sources-uncovered` | A selected project does not have the source coverage above. |
| `refresh-land=unavailable value=sources-read` | The run could not read a project's source evidence: the engine's subscription list or a project manifest. |
| `refresh-land=unavailable value=queue-read` | The read of the default branch's merge queue failed. |
| `refresh-land=skipped value=queued` | The merge queue holds an entry. |
| `refresh-land=refused value=STATUS` | The push failed for a cause other than a moved default branch. |
| `refresh-error=land-check value=ANSWER` | The landing check gave an answer that the script does not report. |

- On `value=token`, the `Mint the landing token` step's log holds the mint error.
- On `value=verify`, the head goes to a draft pull request that names each finding.
- On `value=lock-read`, stderr holds the md-refs lock reader's `refresh-lock:` line and its cause.
- On `value=sources-read`, stderr holds what kendex printed, then `refresh-sources=unread value=PROJECT`, then the cause.
- On `value=queued`, the run does not push because a push to that branch makes GitHub rebuild each running merge group. It defers the render with no pull request. Nothing starts another run for it, so the render waits for the next daily or release-dispatched run that meets an empty queue.
- On `refresh-land=refused`, `STATUS` is git's exit status, and stderr holds git's record of the push. The ruleset paragraph above names the refusal this route expects.
- On `refresh-error=land-check`, the run prints the answer to stderr, exits 1 and publishes no head.

The source reader also sets the `sources` step output of a `refresh-state=current` run to `covered`, `uncovered` or `unread`, with the same stderr lines on `unread`. The shared workflow saves the current record only on `covered`.

### Caller adoption contract

Check the account's entitlement before provisioning the environment ([GitHub environment requirements](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)):

- For a private personal-account repository, GitHub Pro provides the required environments, environment secrets and deployment branches.
- A private Organization repository needs GitHub Team or Enterprise.
- Public repositories can use current free plans.

Install the selected GitHub App ([GitHub App installation](https://docs.github.com/en/apps/using-github-apps/installing-a-github-app-from-a-third-party), [installation token limits](https://docs.github.com/en/rest/apps/apps#create-an-installation-access-token-for-an-app), [GitHub App permissions](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/choosing-permissions-for-a-github-app)):

- Install it on the repository owner's personal or organization account.
- Give the installation access to the consumer repository.
- Accept every permission the shared repository-token step requests: Contents, Pull requests and Workflows write; Administration, Metadata, Actions, Environments and repository Secrets read. Organization installations also need organization Secrets read.
- The shared workflow selects that organization request from GitHub's event repository owner type. A User produces no organization grant. A missing or unknown event type retains the request.
- App authorization alone does not install the app.
- A secret-name check proves neither the key's app identity nor the installation's grants. The token action checks the installation when the workflow runs.

Provision the environment the caller selects before adoption:

- It must allow deployments from the default branch only.
- Store a complete `KENDEX_APP_ID` / `KENDEX_APP_PRIVATE_KEY` pair there, or the `FLEET_GH_APP_ID` / `FLEET_GH_APP_PRIVATE_KEY` pair. Free custom credential names are unsupported.
- The shipped caller passes those two fixed pairs and the optional landing pair by the same names. Configure only its `environment` input. The calling job has no environment.

Outside copies of the fixed names:

- Under [GitHub's reusable-workflow contract](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows), the caller must still pass each environment secret by name.
- The called job receives the environment value in preference to a repository or organization value of the same name.
- A name absent from the environment can still receive the caller's outside value.
- Therefore adoption refuses any of the six fixed names in repository Actions secrets and, for Organization owners, organization Actions secrets. This includes the unused pair and individual credentials.
- An outside value must not win pair selection, complete a partial pair or supply the optional issue token.
- Remove these outside copies before adoption.

The token steps:

- The shared repository-token step reads the complete KENDEX pair first, then falls back to the FLEET pair. A partial KENDEX pair cannot combine with a FLEET credential.
- The upstream issue-token step still reads the FLEET pair only. It may fail without stopping refresh when that pair is absent or lacks access to kendex.
- Local checks prove declarations and expression wiring. A hosted run after publication must confirm GitHub's resolution of both environment pairs.

Deprecated caller fields:

- The shared workflow still accepts `app-id-secret-name` and `app-private-key-secret-name` because shipped callers pass them. Both inputs are deprecated and ignored. They select no secret.
- It also accepts the `app-id` and `app-private-key` mapping keys because the same shipped callers pass those aliases beside the FLEET pair. The token steps ignore those aliases.
- Adoption accepts the aliases only when they refer to the FLEET names and the caller also forwards that complete same-name pair.
- One `refresh-warning=legacy-caller-fields` record names these fields and the fixed mapping names that replace them.
- Existing shipped callers remain usable without an edit.

`refresh/adopt-refresh.sh` validates the declaration through `refresh/lib/caller.py`. Its environment and secret-placement judgments live in `scripts/lib/environment.py`.

- It reads the selected environment's branch policy and secret names through GitHub's API. At least one complete fixed pair that the caller forwards must exist there. A FLEET-only caller cannot use a KENDEX-only environment.
- The adopter requires an explicit User or Organization owner from authenticated [repository metadata](https://docs.github.com/en/rest/repos/repos#get-a-repository). Missing, unknown or unreadable owner metadata refuses before file writes.
- For User owners, it reads repository Actions secret names without an organization namespace read. For Organization owners, it also reads organization Actions secret names.
- The applicable reads require repository Secrets read, Environments read and Actions read. Organization owners also require organization Secrets read. Sources: [GitHub secret scopes](https://docs.github.com/en/rest/actions/secrets), [environment reads](https://docs.github.com/en/rest/deployments/environments#list-environments), [deployment branch-policy reads](https://docs.github.com/en/rest/deployments/branch-policies#list-deployment-branch-policies).
- It reads no Dependabot secrets and no other environment: those scopes cannot supply the refresh caller's Actions mappings.
- Every adopter API read uses the explicit GitHub CLI launch contract in that module. It retains authentication, configuration, credential-store, proxy and coupled certificate-file and certificate-selection inputs.
- These checks prove placement at adoption time. The environment owner must keep that placement for later runs.

| Adoption refusal | Cause |
| --- | --- |
| `refresh-error=caller-secrets` | An unmapped, partly mapped or custom-name caller. |
| `refresh-error=environment` | An absent environment, incomplete credential pair, wrong branch policy, outside copy or failed read. |
| `refresh-error=workflow-edited` | An existing workflow whose bytes match no shipped template history. |

- Outside copies use `cause=secrets-outside`.
- Unreadable metadata uses `cause=read` and names the API operation.
- `refresh-error=workflow-edited` stops adoption before any workflow or inventory change.

Adoption accepts an absent workflow, or a validated declaration whose other bytes match shipped template history. Existing declarations survive later adoption from a new release template.

The landing pair, `KENDEX_LAND_APP_ID` / `KENDEX_LAND_APP_PRIVATE_KEY`, is a third fixed pair, and it is optional.

- Store it only in the selected environment.
- The shared workflow mints only the landing token from it, under [§ Landing a proved render](#landing-a-proved-render). The repository-token and issue-token steps never read it.
- A caller that forwards one of its two names stops adoption with `refresh-error=caller-secrets`.
- Its two names are among the six fixed names that adoption refuses outside the environment.
- Adoption does not require the pair in the environment.
- A caller adopted before the pair gains both mappings at its next adoption from a release that ships them, and keeps its environment.
- A run reads the pair only after its caller forwards it.
- An absent pair or a failed mint leaves the landing token empty, and every update keeps the rolling pull request.

### Additional projects

Declare `KENDEX_REFRESH_PROJECTS` in the `[env]` table of the [settings example](../kendex.settings.toml.example). Separate additional project paths with semicolons. Each project directory must contain `kendex.toml`.

- The released refresh runner reads `KENDEX_REFRESH_PROJECTS` once from the fetched default branch's root settings, with the normal settings precedence and selected private env file.
- For example, `KENDEX_REFRESH_PROJECTS = "packaging/jarvis-home;another/project"` selects those projects as well as the root.
- Spaces inside a path stay intact. Entries are trimmed. Empty entries are ignored.
- Nested settings add no projects.

Every selected directory and its `kendex.toml` must resolve inside the checkout.

- Absolute paths, missing directories, missing manifests and links outside the checkout stop the run before project writes.
- Duplicate resolved directories run once.
- The root runs first.
- Each project gets refresh, apply, bot-instructions render and verify. A failure stops publication.
- On a new publication, all project changes enter the same rolling pull request.
- Adoption runs once for the root caller.
- Catalog holds and retired-item reports name their project when extra projects are selected.
- A current record is saved only when source coverage is known for every selected project.

### Adoption and file ownership

`refresh-consumer.sh` reports the exact `kendex --version` output in the rolling pull request body on a new publication, or in `GITHUB_STEP_SUMMARY` when the consumer is current or retains an unchanged head. A failed version read stops publication. `refresh/tests/refresh-consumer.test.sh` in the kendex repository holds these report paths.

Run from the consumer root after installing the skill. Set `KENDEX_RELEASE` to a kendex checkout at the installed release tag:

```bash
"$KENDEX_RELEASE/refresh/adopt-refresh.sh"
kendex verify --scope project
git add -A
```

Commit the workflow and the inventory removal with the installed skill.

- Adoption writes no inventory record for `.github/workflows/kendex-refresh.yml`, and removes any earlier one, including when the release checkout sits inside the consumer.
- The adopter reads `kendex-refresh.yml` beside itself. `--templates-dir DIR` reads `DIR/kendex-refresh.yml` instead.

The [caller adoption contract](#caller-adoption-contract) uses both paths kendex has shipped the caller template from, review-gate's former `templates/` copy and `refresh/kendex-refresh.yml`, in kendex's default-branch ancestry as shipment evidence. The adopter fetches that history from `https://github.com/vanillagreencom/kendex.git` as data only. Consumer history and adoption records supply no replacement permission.

| File safety check | Refresh result |
|---|---|
| Symlink | Stop with `refresh-error=workflow-symlink value=PATH`. |
| Bytes changed during writer adoption | Stop with `refresh-error=workflow-changed value=PATH`. |
| Unshipped replacement | Stop with `refresh-error=template-edited value=PATH`. |
| Replacement changed during writer adoption | Stop with `refresh-error=template-changed value=PATH`. |
| Git history or blob read failure | Stop with `refresh-error=read value=workflow-history`. |

- A symlink stop leaves its target unchanged.
- A `workflow-changed` stop comes before refresh replacement or inventory writes, and preserves the new bytes.
- A `read` stop comes before adoption. It does not classify the workflow as edited.
- `refresh/tests/adopt-refresh.test.sh` in the kendex repository checks historical acceptance, edit preservation, read refusal and concurrent changes.
- `refresh/tests/refresh-consumer.test.sh` in the kendex repository checks that refused workflow or render edits cause no publication.

A held render edit prints `refresh-error=render-edited value=COUNT`, followed by its held records. COUNT is the distinct item count, not the harness-row count.

The committed settings scan runs read-only from the kendex release tree's settings library, with only `PATH` and `HOME` in its environment.

- Only the running refresh script, the kendex release tree, consumes its output.
- A failed extraction stops publication and auto-merge.
- The scan skips comments, other tables and private overrides.
- A clean parse leaves the body unchanged.
- A run that reports current or retains an unchanged head appends the same settings report to its run summary.
- `refresh/tests/refresh-consumer.test.sh` in the kendex repository checks committed settings and no-change summaries.

After the refresh, the run stages it and asks kendex to render `bot-instructions` once, wherever the install put it. The pull request then carries the render the consumer's check demands, and the render removes each file the refreshed package no longer produces.

- No setup record is read or written.
- The render runs with only `PATH`, `HOME` and `KENDEX_UI` in its environment.
- Where it renders nothing, the run prints the render's own output, then a summary line: `refresh-render=skipped package=bot-instructions cause=absent` where the package is not installed, or `refresh-render=skipped package=bot-instructions cause=unconfigured` where the package reports `unconfigured`, which bot-instructions' `schemas/validators.md` § `orphan` defines.
- Any other failure prints `refresh-error=bot-instructions-render value=STATUS`, and stops publication and auto-merge.

The refresh pull request also carries the one-line `schema` edit when the engine's schema is one above the committed value. Any other mismatch stops the run at refresh with `refresh-error=refresh`.

The refresh pull request also adds Retired items: each line refresh printed for an item its catalog retired, keyed by the item's name and that catalog, with the catalog's migration last, so the pull request names what replaces each item the refresh removed. A retired copy whose files were edited is held, and its conflict row stops the run before publication, as any other conflict does.

On a new publication, the refresh pull request also adds Consumer settings, report only: it changes no setting.

- The same parse passes every committed `kendex.settings.toml` `[env]` setting.
- The report names each key `retired-settings.json` lists under `keys`, with the key that replaces it where `successors` names one, and each value it lists under `values` for that key, a shipped default since replaced.
- The section also carries the `setting-unset:` line change-class printed for the pull request, and its `queue-only:` line where the cause is `queue-list-undeclared` or `queue-settings-unreadable`, so an unset `HARNESS_CI_QUEUE_PATHS` is named there. The `queue-only:` line every other verdict prints names no setting and stays out.
- A current consumer runs no classifier and appends the retired rows to its run summary.
- A run that retains an unchanged head includes the classifier's setting notes in that summary.
- A report that fails, such as on an unreadable list, stops publication and auto-merge.
- Removing a retired setting is the consumer's own change.

Commit the shared caller with the installed skill. The release adopter checks the caller against shipped history and removes its earlier inventory record. `kendex verify` compares only workflows that still have an adopted-template record.

Schedule and manual refresh use the [caller adoption contract](#caller-adoption-contract). Adoption excludes `vanillagreencom/kendex`, whose build-bound lock workflow owns its refresh.

Only the default-branch workflow can use the private key.

- It checks out the default branch before minting a repository-scoped app token.
- It rebuilds the rolling branch from that checkout and asks the shared classifier to measure the full diff before pushing.
- It runs review scripts and the classifier from the kendex release checkout. A refresh pull request cannot change the scripts that judge it.

### Automatic review threads

The review scripts prove that each rolling pull request has class `render` before they file, reply to or resolve an automatic review thread. Findings on other classes remain unchanged.

The shared workflow's last two steps request an Issues-write token scoped only to `vanillagreencom/kendex`, then use it to file findings and resolve their threads.

- Each run reads the open rolling pull request and those merged in the last 24 hours.
- After that window no run reads a merged pull request again. A thread that arrives later gets no answer, and an unanswered thread on it gets no filing, no retry and no run failure. A person answers those threads by hand.

Each automatic review thread on a render-proven pull request has one of these outcomes:

- The thread is outdated at the current head: the workflow prints a keyed skip, replies with `Not filed upstream: ` and the reason, and resolves the thread. It files nothing and does not hold the run.
- The thread is live and no single package claims its path (including paths outside the inventory, the lock, the inventory and a Copilot `.github/agents/*.agent.md` render): the workflow prints `upstream-unfiled`, gives no reply and leaves the thread open. It files nothing. Review text about content kendex has not claimed is never published. The consumer must answer the finding through its own pull request or a reply, then resolve the thread by hand.
- The thread is live and `kendex report` routes its one package to `vanillagreencom/kendex` with a package label: the workflow files the finding there for upstream confirmation, replies with the issue, and resolves the thread. The rules for that filing follow this list.
- Other live findings are not filed when `kendex report` routes the package elsewhere, or the token or Issues access is missing. The error line gives the reason.

A filing for a routed thread:

- The report carries the review evidence, rendered path, consumer run and that package label.
- Its title fingerprint hashes the package, the path inside its directory, and the head lines the comment names. The head lines are joined by the comment's wording where that text occurs more than once in the file at head. For a file-level or base-side comment, its wording alone takes the place of the head lines.
- The fingerprint holds no path for a package the lock records under any kind but skill. Such a package is one file whose rendered name and layout differ by harness, a command rendering as a Codex skill tree among them.
- The lookup counts only issues a GitHub App wrote, in every state: GitHub issue search, then, on the run's first miss just before filing, one read of the issues updated in the last hour, plus the run's own filings. The extra read exists because search indexes another consumer's filing from the same schedule late.
- Two consumers that both read before either files can still file twice.
- An open match gains a comment with the thread's text and evidence where its body lacks that evidence.
- A closed match is the answer, linked in the reply with its close reason, and nothing is filed.

Live unfiled findings stay open and fail the run under the thread-resolution rule, until the 24-hour window of a merged pull request ends.

- Report the finding where it belongs and resolve the thread by hand. A resolved not-filed thread no longer fails the run.
- Filing replies and not-filed replies are durable answers. A later run only resolves their threads.
- A reporter failure holds only its own pull request and also fails the run.
- If the token lacks Issues access, the Actions summary supplies filing links for routed findings only. A later run with the token files the finding and resolves the thread, if it starts within that window.
- A pull request the classifier cannot measure keeps its findings unanswered until a later run in that window measures it, and the run adds a warning with the cause.

### Immediate refresh

An organization managed by fleet runs `fleet repos kendex-refresh` when a fix cannot wait for the schedule.

- Fleet owns installation-wide dispatch and sends the `kendex-refresh` event to consumer repositories.
- The consumer's `repository_dispatch` receiver uses the same refresh workflow as scheduled and manual runs.
- Other consumers use their schedule or run their refresh workflow by hand.
