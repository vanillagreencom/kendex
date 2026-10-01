# KEN-2416 consumer refresh design

KEN-2416 completes at this PR merge with the measured fleet report and workflow/render edit preservation.

## Framing

- **Goal**: remove false refresh refusals without replacing a real consumer edit or weakening verification, classification, containment, or publication checks.
- **Perspective**: the consumer's next scheduled refresh, the code that starts it, and the owner of each check.
- **Constraints read**: prior live KEN-2416 Requirements and `tmp/brief-plan-KEN-2416.md`; the calling scope ruling; both existing reports; the supplied authoritative inventory; root and package instructions; code-quality, including Over-Engineering and Prove Your Guards; docs-writing; architecture overview, engine and merge-rail; D003 and D007. The calling ruling limits this PR to measurement and edit preservation. Requirement 4 transfers after merge through Proposal to an owner-observed successor.
- **Prior live bindings retained**: KEN-2449, KEN-2438, KEN-2437, KEN-2297, KEN-2376, KEN-2281, KEN-2391, KEN-2277, KEN-2278, KEN-2279, KEN-2296, KEN-2405, KEN-1963, KEN-2239, KEN-2400 and KEN-2332. This evidence round reads their supplied scratch records without a tracker read or write. Prior issue-state labels below are not a new live-state check.
- **Baseline**: the first design uses `b315ac6420fb0027e5a6156648e0a2419a245b56`, which contains `becba596`. Commit `75a4cf49` contains the first preservation implementation. Its validation receipt fails because a disposable test mutant loses execute permission. The fix restores that permission. The runtime completion artifact records final validation; this report is not a validation verdict.
- **Assumptions**: None. The supplied inventory and private histories resolve the earlier access gap. The overseer confirms no local refresh runs outside Actions. No fixture substitutes for a consumer after observation.
- **Planning boundary**: the planner integrates supplied evidence into reports and data reductions only. It executes no proposed controls and changes no production file, test, install record, lockfile or tracker item. The runtime fix commit includes these reports with its final validated contents.

## Before measurement

[Raw runs](ken-2416-refresh-runs.md) owns the interval, denominators, run URLs, individual evidence paths and observation gaps.

| Consumer or sample | Listed | Failure | Listed failure rate |
| --- | ---: | ---: | ---: |
| vsys | 399 | 358 | 89.72% |
| gentoo-overlay | 1 | 1 | 100.00% |
| homebrew-kendex | 1 | 1 | 100.00% |
| vgs-themes | 1 | 1 | 100.00% |
| vgs | 1 | 0 | 0.00%, queued with no conclusion |
| Accessible total | 403 | 361 | 89.58% |
| fleet | 394 | 87 | 22.08% |
| vg | 399 | 276 | 69.17% |
| talk | 143 | 32 | 22.38% |
| hyprtrade | 324 | 246 | 75.93% |
| hyprtrade-io | 389 | 299 | 76.86% |
| drovr | 393 | 285 | 72.52% |
| kendex-web | 408 | 404 | 99.02% |
| Private supplement | 2450 | 1629 | 66.49% |
| Combined fleet total | 2853 | 1990 | 69.75% |
| Current-consumer subtotal | 2849 | 1987 | 69.74% |

The combined completed-run rate is 69.78%: 1990 failures out of 2852 completed runs. The accessible completed-run rate remains 89.80%: 361 out of 402. All 1990 failures have supplied logs and measured classes. All 46 cancellations lack failed-step bytes and remain unclassified as to cause. The queued vgs outcome stays as originally observed. The authoritative inventory separates eight current consumers from four historical public attempts. Memsira and review-gate-sandbox have no refresh workflow and are not consumers. No local refresh runs exist under the overseer's ruling.

## Cause and ownership decisions

| Measured class | Count | Design defect or correct refusal | Existing owner and disposition |
| --- | ---: | --- | --- |
| `publication-class` | 1039 | The old runner uses the render-only auto-merge condition to prohibit publication of a measured standard refresh. A legitimate update cannot reach a reviewer. | `refresh-consumer.sh`. KEN-2277 removes this defect on main in `fb05f185`. Keep its measured-class publication and render-only arm. KEN-2297 owns delivery of the fixed runner. Do not implement another class rule here. |
| `workflow-ownership` | 193 | The old adopter treats missing adoption metadata as proof of a hand edit. The baseline adopter then replaces genuine edits with a warning and accepts consumer history as shipment proof. | `adopt-refresh.sh`. KEN-2278, `e591dfda`, removes the missing-record refusal only in source. KEN-2416 completes exact shipped-byte recognition and preserves real edits. This satisfies only KEN-2376 R47, not its review or dispatch rows. Current HEAD contains this implementation; final proof remains with runtime. |
| `consumer-bootstrap` | 4 | The workflow executes a path in a detached consumer copy. That path is absent. The same dependency makes an installed old runner unable to obtain its own repair. | The refresh workflow template. KEN-2297 owns release execution and bootstrap. KEN-1963 owns initial authorized adoption. No executable or manifest declaration is silently added here. |
| `orphan-agent-record` | 91 | Refresh leaves unneeded generalist or engineer records and renders. Its following verify fails on those records. | `refresh.rs::prepare_scope` and `engine/removal.rs::orphans`. KEN-2438 owns settlement through the existing apply plan. No cleanup command or second removal pass. |
| `retired-agent-declaration` | 54 | The consumer still declares generalist, or engineer and generalist, after the approved catalog rename. Automatic inference would change consumer intent. | Consumer manifest owner; KEN-2400 names and KEN-2332 adoption plan. Drop an automatic alias, rename inference or deletion fix here. |
| `publication-lease` | 7 | The remote rolling head differs at push. `stale info` proves no faulty lease or permanent defect. | `refresh-consumer.sh` publication. Drop a production repair. Keep the explicit lease and the preservation control. |
| `render-edited` | 141 | Core correctly detects vg's Copilot lane-mail-check edit against changed upstream bytes. The baseline runner's automatic discard is an edit-loss defect, not permission supplied by this finding. These logs stop in verify, not at the new runner refusal. | Core edit holds and `refresh-consumer.sh`. KEN-2416 preserves edits before adoption and publication. Extend the existing edit control to the measured Copilot case. Do not force core verify green. |
| `install-record-gap` | 374 | Refresh ends with declared packages absent from the record, even when every checked entry passes. The 355 hook-only cases measure an unsettled hook record. KEN-2449 confirms the required-hook case through the named late kendex-web run. Nineteen skill-containing gaps do not alone establish the same cause. | `refresh.rs::write_scope`, `plan_apply` and the existing dependency closure. Bind the measured required-hook case to KEN-2449 after checking KEN-2405. Its owner audits earlier skill-containing cases through the same plan before claiming coverage. Drop blanket verifier success or a second apply command here. |
| `requested-revision-conflict` | 17 | Fleet requests harness-ci at two revisions for one installed identity. Refusal preserves that identity. Logs do not show which declaration created the conflict or establish an engine defect. | `engine/desired.rs` revision resolution and `engine/holds.rs::hold_rev_conflict`; consumer manifest owner. Drop automatic revision selection. Authorized declaration correction stays with consumer adoption, not this PR. |
| `adoption-verification` | 5 | Inventory layout and both adopted workflow equality checks fail together. The logs do not prove that any workflow bytes are a hand edit. A missing record and an equality mismatch are different findings. | `core/attest.rs`, `verify.rs`, existing `adopt-refresh.sh` and writer adoption. KEN-1963 owns authorized consumer adoption. Drop verifier bypass or unconditional inventory rewriting here. KEN-2416's shipped-byte acceptance does not absorb writer-workflow repair. |
| `repo-effects-unreadable` | 2 | Bot-instructions' installed declaration cannot be read during removal. Treating it as no effects could leave repository hooks calling a deleted package. No supplied declaration bytes establish the underlying parse defect. | `engine/repo_effects.rs::declaration_of` and `unreadable`; the installed package and consumer adoption owners. Drop a fail-open removal change here. Preserve the package until authorized declaration repair. |
| `publication-queue` | 15 | GitHub freezes a rolling branch while its pull request is in the merge queue. The push correctly refuses. The logs do not establish a permanent runner defect or authorize dequeuing another operation. | `refresh-consumer.sh` publication and GitHub's merge queue. Drop queue bypass, automatic dequeue or a new retry owner here. Keep the queued head intact. |
| `default-moved` | 3 | The consumer default branch moves after checkout. Refusal prevents publication from the stale base. | `refresh-consumer.sh` base/fetched-head comparison. Drop a reset or forced publication change here. A later ordinary Actions run gets a fresh base. |
| `remote-read` | 36 | Git reads fail with repository-not-found or HTTP 404 protocol errors. No log proves deletion, an expired token or a persistent credential defect. | Existing `refresh-consumer.sh` Git reads and app credential setup. Drop a new credential fallback or read-failure-as-empty change here. The operator checks access before the normal next run. |
| `environment-read` | 5 | GitHub returns HTTP 500 while the environment validator reads secrets. The validator cannot establish the required environment. | `validate-standard.sh` environment-secrets read, called by adoption. Drop read-failure-as-pass here. The operator restores the existing read; no new setting. |
| `release-download` | 1 | The released command asset download returns HTTP 504. The installer correctly stops without a usable command. | `install-latest.sh` and the released `install.sh` download. Drop a new downloader or unverified release fallback here. KEN-2297 retains the existing installation owner. |
| `publication-service` | 3 | GitHub rejects two pushes with an internal server error and fails one merge GraphQL query. Logs establish service failure, not a permanent publication defect. | Existing `refresh-consumer.sh` publication and `refresh-reviews.sh` merge call. Drop alternate push/merge paths here. Keep leases, normal CI/review and explicit service failure. |

### Baseline source evidence

These statements describe the first design baseline, not the implementation verdict. Commit `75a4cf49` removes the discard pass and adds workflow edit preservation. The runtime completion artifact records proof after restoring the disposable mutant's execute permission.

- `refresh-consumer.sh` now publishes any measured class. It leaves non-render pull requests unarmed. Its `refresh-error=read value=class` still stops an unmeasured result.
- The same runner reads held edits from the CLI's plain conflict and ledger records. It then runs `kendex refresh --scope project --yes --leave --discard-edits`. That is automatic permission to discard a consumer's edits. KEN-2279 adds this in `3ba501b9`. Remove that permission in this branch, rather than turning verify into a warning.
- `adopt-refresh.sh` compares current, vendored and historical template bytes. Its Git history roots can be the consumer's repository. A consumer can commit a changed template and workflow together. Such a commit is not kendex shipment evidence.
- On a non-shipped workflow, the adopter prints `refresh-warning=workflow-edited`, writes the new workflow, and changes the inventory. Its `validate-workflow.sh --adopt` call also precedes the workflow edit decision. Refusal must precede that effectful call.
- The workflow still executes the consumer's `install-latest.sh`, then consumer runners under `$RUNNER_TEMP/refresh-skills/.agents/skills/`. Fixing only the two later exec paths leaves a bootstrap failure when the first helper is absent or broken.
- `install-latest.sh` already owns release selection, tag validation, tag-to-commit resolution and immutable installer download. Its report supplies `version` and `commit`. It removes both GitHub tokens from downloads and installer execution.
- `refresh.rs::prepare_scope` sets `sweep_unneeded: true`, but not `remove_orphans`. `removal.rs` removes only derived-only records or departed harness copies under the sweep option. A formerly requested, now undeclared agent is left. The CLI's current docstring explicitly promises to leave such orphans.
- `removal.rs::edit_holds`, the trash preconditions and `TrashGuard` already protect edits, shared paths and changed bytes. KEN-2438 must reuse these decisions.

### Related issue bindings

These rows retain prior issue evidence. The cause table above distinguishes measured classes from unmeasured cases and warnings.

| Class | Binding | Decision |
| --- | --- | --- |
| Newly required hooks are listed but not installed or recorded | KEN-2449, Backlog; related KEN-2405, In Review | KEN-2405 changes dependency declaration and expansion. KEN-2449 owns the remaining refresh settlement case. The fixture must use a dependency added after the initial install, not only an initial install. No check exemption for a missing required dependency. |
| Engine and catalog accept different feature sets | KEN-2281, Done | `53098d7b` installs the latest stable engine and checks catalog compatibility with that released engine. Do not undo it or add another installer. Consumer adoption and a release carrying the changed scripts still need observation. |
| Pulled renders leave an old Git hook helper armed | KEN-2437, Backlog | The installer owns its helper identity and drift line. Do not put hook installation or body-version detection into refresh-consumer. |
| Exact partial state and host/source failure reporting | KEN-2391, Backlog | Its apply, journal, ignore, renderer and source-reader rows remain there. A refresh can write unrelated managed files before a later refusal. This plan promises preservation of edited files and no publication, not an invented transaction over the whole workflow. |
| Review predicate and dispatch enumeration/retry changes | KEN-2376, Backlog | Only workflow edit preservation overlaps this branch. Leave R15, R21, R22, X39 and X40 with their owners. The supplied inventory resolves the earlier credential gap. That earlier failure is not evidence of a dispatch defect. |
| Desktop-app download HTTP 404 | Installer warning, not a measured refresh failure class | Drop a repair from this scope. Each affected log continues with the installed command and stops later on the missing consumer script. KEN-2281's helper already requests CLI-only installation. |

## Approach

Use the existing adopter for workflow identity, the existing runner for refusal and publication, and the existing engine for installation and removal. Keep the consumer workflow as the only publication route. Keep kendex's D007 source exclusion.

### Workflow identity

- An adoption record is bookkeeping, not proof of an edit.
- Compare workflow bytes exactly with templates committed in kendex's trusted default-branch history. Use the existing template path `skills/review-gate/templates/kendex-refresh.yml`.
- Extend the adopter's existing Git history lookup. Do not add an acceptance service, shipped hash list, second validator, setting or cache.
- The authoritative history must come from `https://github.com/vanillagreencom/kendex.git`, not the consumer's Git history. In the adopter's existing scratch lifetime, fetch the default-branch history into a data-only Git checkout and traverse that fetched commit's ancestry. Execute no code from it. A later release-owned runner can provide the same trusted source checkout, but the equality decision stays in the adopter.
- Include the current trusted template and each historical template blob. A deletion commit supplies no candidate bytes. A history read or blob read failure produces a read refusal, not `workflow-edited` and not acceptance.
- Require the template selected for replacement to be shipped bytes too. A consumer-edited template is not allowed to authorize a consumer-edited workflow.
- A workflow that matches any candidate passes with a matching, missing or stale adoption record. Adoption writes the chosen template and its existing inventory record shape. The recorded `template` remains the consumer-relative `.agents/skills/review-gate/templates/kendex-refresh.yml`; a scratch or release checkout path never enters `.kendex-generated.json`.
- A workflow that matches none of the candidates fails with `refresh-error=workflow-edited value=PATH`. Keep its bytes and existing inventory. Keep symlink refusal. Do not normalize comments, line endings, indentation or shell payload.
- Compare the vsys template cited by KEN-2416 at `f7db7e89` with the current copy in a fixture. A fabricated consumer commit that makes template and workflow equal is not shipment evidence.

### Render edits

- Keep the first ordinary `kendex refresh --scope project --yes --leave` pass.
- Keep the existing conflict and ledger parser. It distinguishes known edit holds from a malformed or different conflict. It already fails closed on an unreadable record or inconsistent count.
- When it proves a held edit, stop with one keyed refusal. Do not run a discard pass, adopt workflows, commit, push, create a pull request, or arm auto-merge.
- Choose `refresh-error=render-edited value=COUNT` as this runner's new refusal. Print the existing held-path detail after that first line. COUNT uses the parser's distinct item count, not harness-row count.
- Do not treat `--yes` as edit replacement consent. Do not change core's explicit `--discard-edits` option for a person who asks for it.
- The ordinary refresh can leave other managed updates on disk. The edited installation stays unchanged. Failure-state wording outside this runner belongs to KEN-2391.

### Rejected alternatives

| Alternative | Reason |
| --- | --- |
| Trust `.kendex-generated.json` alone | A missing row cannot distinguish a shipped copy from an edit. A supplied hash is not shipment proof. |
| Trust a template in consumer history | A consumer can commit both changed copies. That history proves only what the consumer held. |
| Warn and replace edits | It loses consumer work. Disclosure after replacement does not preserve it. |
| Retry refresh with `--discard-edits` | It turns detection into automatic replacement permission. |
| Make verify pass on orphan records or missing required hooks | It hides the mismatch the engine must settle. |
| Add a second refresh or cleanup command | `plan_apply`, dependency expansion and removal already own the work. |
| Execute consumer-vendored runners | An absent or defective runner must repair itself before it can run. |
| Execute mutable catalog-main publication scripts | Credentialled refresh and review execution must use the resolved stable release under KEN-2297. |
| Drop the push lease or force past its failure | The runner would replace a remote head it did not observe. |
| Automatically map removed agent names | The manifest records consumer intent. The approved subscription migration belongs to adoption. |
| Add a collector, watch, dashboard or settings list | The existing GitHub CLI commands and dispatch enumeration suffice for measurement. |

## Implementation plan for this branch

1. **Preserve workflow edits before effects.** Modify `skills/review-gate/scripts/adopt-refresh.sh`. Extend its existing exact-byte history lookup to the authoritative catalog history described above. Finish workflow classification before `validate-workflow.sh --adopt`, workflow replacement or inventory writes. Keep the environment check read-only and ahead of adoption. Put the existing writer-validator invocation after the workflow preflight. Re-read the inventory after writer adoption before merging the refresh record, so no writer record is lost. Recheck the observed workflow bytes and symlink state immediately before replacement. A changed file is refused, not overwritten. Validation: a historical shipped copy with no workflow record adopts; a real edit fails before the writer validator can change tracked data; a concurrent edit between preflight and replacement fails.
2. **Remove automatic render replacement.** Modify `skills/review-gate/scripts/refresh-consumer.sh`. Replace the discard-pass branch with the keyed held-edit refusal. Remove the obsolete overwritten-item body section. Preserve extraction errors, the conflict count check, settings checks, verification, measured-class checks, the push lease and render-only auto-merge. Validation: local-only and upstream-plus-local edits keep their exact bytes; the run stops before adoption and every publication call; an unedited standard-class refresh still publishes unarmed.
3. **Replace the workflow overwrite tests.** Modify `skills/review-gate/tests/adopt-refresh.test.sh` and its existing fixture/assertion helpers. Replace rows that expect an edited workflow to be overwritten. Use a local authoritative catalog fixture with real Git history. Substitute its transport only in a disposable test copy. Include shipped current and historical bytes with missing, matching and stale records. Include a fake consumer-history template, a one-line workflow edit, a symlink, unreadable shipment evidence, a changed target template and an edit introduced before the write. Validation: every refusal checks workflow bytes, inventory bytes and effectful-call absence. Mutants keep the diagnostic text while disabling each independent rule.
4. **Replace the render-discard tests and keep publication controls.** Modify `skills/review-gate/tests/refresh-consumer.test.sh` and its existing helpers. Retain real CLI-backed edit fixtures. Replace automatic-discard expectations with byte preservation and no-publication expectations. Keep malformed-record and count-mismatch controls. Add the remote-head-change lease row using the existing local Git remote. Validation: the edited-file fixture fails on baseline `b315ac64`, because it currently discards the edit; restoring the discard pass in a disposable runner turns the corrected assertion red. A competing remote head remains unchanged after lease refusal. The ordinary measured-standard and unmeasured-class controls still distinguish publication from refusal.
5. **Update the owning documents and renders.** Modify `skills/review-gate/SKILL.md`, `skills/review-gate/references/adoption.md` and `skills/review-gate/DEVELOPMENT.md`. Replace automatic-replacement wording with shipped-byte acceptance and real-edit preservation. Update `docs/architecture/merge-rail.md` to state that authoritative catalog bytes, not consumer history or metadata, license workflow replacement. Replay each shipped source diff into its corresponding `.agents/skills/review-gate/` render. Keep `.kendex-lock.json` as main holds it. Add a consumer-facing fix fragment under `changelog.d/fixed/` using the repository's fragment rules. Validation: descriptions match the new branches and the controls; generated inventory changes only when the change adds or removes a tracked render.
6. **Run the existing validation entry point in the implementation lane.** Use `dev-validate-run` with the project's existing change-based selection. Keep `TMPDIR` and `ORCH_STATE_DIR` unset for long jobs. Run the affected adoption, consumer, workflow and installer suites through their existing entry points. Add no selector or wrapper. Validate the production mutations on disposable copies. Do not refresh or apply in this marked worktree. Validation evidence must state baseline failure, fixed fixture result and mutant result separately. This planning round supplies none of those execution results.
7. **Complete KEN-2416 at this PR merge.** Return the indexed fleet measurement, preservation fixture and mutant proof, and existing-issue dispositions. The full inventory measurement is now supplied. Other implementations stay with KEN-2297, KEN-2438, KEN-2449, KEN-2437 and the explicit drops. After merge, the calling lane routes Requirement 4 through Proposal to an owner-observed successor. Deployment and the consumer after-rate belong to that successor, not this PR's completion gate.

### Files

- **Production files to modify first**: `skills/review-gate/scripts/adopt-refresh.sh`, `skills/review-gate/scripts/refresh-consumer.sh`.
- **Tests and helpers**: `skills/review-gate/tests/adopt-refresh.test.sh`, `skills/review-gate/tests/refresh-consumer.test.sh`, and only the existing `skills/review-gate/tests/lib/` helpers those suites use.
- **Documentation**: `skills/review-gate/SKILL.md`, `skills/review-gate/references/adoption.md`, `skills/review-gate/DEVELOPMENT.md`, `docs/architecture/merge-rail.md`; matching shipped `.agents` renders.
- **New production scripts, settings, dependencies or commands**: none.
- **New implementation files**: one changelog fix fragment. Tests stay in existing suites.
- **Report files written in this round**: the two existing plan paths and per-consumer raw-table companions indexed by `ken-2416-refresh-runs.md`. The split satisfies doc-limits without dropping rows. No measurement code is saved.
- **Critical execution files**: `skills/review-gate/scripts/adopt-refresh.sh`, `skills/review-gate/scripts/refresh-consumer.sh`, `skills/review-gate/tests/adopt-refresh.test.sh`, `skills/review-gate/tests/refresh-consumer.test.sh`, `skills/review-gate/templates/kendex-refresh.yml`.

## Must-fail controls

A planted defect makes its guard refuse. A production mutant that removes that behavior must turn the assertion red. Controls on already-correct code are preservation proof, not evidence of a new fix. Rows for dropped changes are audit instructions for the existing owner. They do not add implementation or test scope to this PR. The KEN-2416 runtime lane executes only the preservation plan and its existing publication controls.

| Class or independent safety rule | Planted defect and required result | Regression or mutant proof | Owning work |
| --- | --- | --- | --- |
| Workflow identity | vsys's exact historical shipped bytes pass without an adoption record; a one-line edit fails and stays in place. A fake consumer-history copy also fails. | Current code overwrites the real edit, so the preservation assertion fails on baseline. Disable history acceptance or edit refusal separately in disposable copies. | KEN-2416; KEN-2376 R47 overlap |
| Unreadable workflow history | Make the authoritative history/blob read fail. Refuse before any tracked write. Do not blame a hand edit. | Ignore that read failure in a copy; the no-write/read-refusal assertion turns red. | KEN-2416 |
| Workflow link or changed precondition | Plant a symlink or change the file after its preflight. Refuse without writing the target. | Disable each refusal separately. The target-preservation assertion turns red. | KEN-2416 |
| Render edit / `render-edited` | Edit a recorded render locally, with and without an upstream change. Include vg's Copilot lane-mail-check case. Preserve exact bytes and refuse before adoption or publication. | Baseline runs the discard pass. Restoring that pass on the fix turns the byte-preservation/no-push assertion red. A verify failure alone does not prove the runner preserves the edit. | KEN-2416 |
| Publication class | Plant a measured standard result. Publish an unarmed pull request. Plant an unmeasured fallback separately; publish nothing. | Restore the old render-only publication stop, or disable the unmeasured guard, separately. Each assertion turns red. The standard fix already exists in source. | KEN-2277, delivery through KEN-2297 |
| Consumer executable dependency | Install no vendored runtime executable in the consumer fixture. A release-owned runner must execute against that consumer. | Route either runtime exec back to the missing consumer path; the run turns red. Today's workflow has that defect. | KEN-2297, initial declarations under KEN-1963 |
| Orphan agent | Install generalist, migrate the manifest to maintainer, then refresh once. Only the owned unedited old agent renders and record leave. Verify passes. | Baseline leaves the old requested record. Restore the old orphan option on the fix; the post-refresh assertion turns red. Add an edited-orphan twin that remains held. | KEN-2438 |
| Retired declaration | Keep an explicit generalist declaration against a catalog with only maintainer. Refuse resolution without altering that declaration. | Current code already enforces this. An alias or silent declaration rewrite must fail the intent-preservation assertion. After the approved consumer manifest migration, normal resolution passes. | KEN-2400 subscription migration and KEN-2332 adoption program |
| Publication lease | Advance the remote rolling head after the runner reads it. The push fails and keeps that head. | Remove the explicit lease in a disposable runner; the competing-head assertion turns red. No measured production repair is proposed. | Existing refresh-consumer publication |
| Install-record gap, measured | Add a required hook after a package's initial install. One refresh installs and records it; verify passes without an extra command. Audit a previously missing skill record separately through the same plan. | A missing record after the refresh makes the assertion fail even if every checked entry passes. Disable fixed settlement in a copy; the row turns red. Keep harness-excluded-package handling distinct from a dependency that should install. | KEN-2449, checked against KEN-2405 |
| Requested-revision conflict | Request harness-ci at two revisions for the same installed identity. Refuse the conflict and preserve installed bytes. | Suppress the existing conflict or choose a revision in a disposable copy; the conflict/byte-preservation assertion must fail. Logs supply no proof of a new engine defect. | Existing desired/holds owner; drop automatic selection |
| Adoption verification | Plant a malformed inventory and mismatching refresh/writer copies. Verify must fail each independent check. Exact shipped refresh bytes pass through authorized adoption without replacing a real edit. | Disable inventory layout, refresh equality and writer equality separately in disposable copies. Each failed-check assertion must turn red. Do not count a single malformed fixture as proof of every rule. | Existing attest/verify/adoption owners; KEN-1963 delivery; drop bypass |
| Repo-effects unreadable | Make an installed departing bot-instructions declaration unreadable. The plan must refuse before removal and retain its package and repository hooks. | Treat unreadable as absent in a disposable copy; retained-package/hook assertions must fail. The actual unreadable bytes are not supplied. | Existing repo-effects owner; drop fail-open removal |
| Publication queue | Simulate GitHub's GH006 rejection for a queued rolling head. Report failure without a fallback push, dequeue or merge. Keep the head. | Add a bypass/dequeue fallback in a disposable runner; the no-fallback and head-preservation assertions must fail. This checks existing protection, not a new queue design. | Existing publication owner; drop bypass |
| Default moved | Advance default after checkout but before the existing fetch comparison. Refuse before refresh and publication. | Disable that comparison in a disposable runner; the no-refresh/no-push assertion must fail. | Existing base comparison; drop stale-base publication |
| Remote read | Fail each Git read with the measured repository-not-found or HTTP 404 response. Publish nothing and never treat a failed rolling-head read as an absent branch. | Continue with an empty head or cached base in a disposable copy; the no-publication assertion must fail. | Existing Git/app credential owner; drop fallback |
| Environment read | Make the existing secret read return HTTP 500. Preserve tracked bytes and stop before adoption/publication. | Treat unreadable secrets as a passing environment in a disposable validator; the no-write/no-push assertion must fail. | Existing validate-standard owner; drop fail-open validation |
| Release download | Return HTTP 504 for the selected command asset. Installation must fail without running refresh under a partial or fallback command. | Ignore the download failure in a disposable installer/workflow fixture; the no-runtime-execution assertion must fail. | Existing installer suite; KEN-2297 delivery; drop new downloader |
| Publication service | Make the push return an internal server error, then test the review merge GraphQL error separately. Neither may report completed publication/merge success or use a bypass. | Suppress each command status independently in disposable existing runners; the explicit-failure/no-fallback assertions must fail. | Existing consumer/reviews suites; drop alternate path |
| Engine/catalog skew, unmeasured here | A catalog fixture declares a feature the selected released engine cannot read. The existing catalog check fails naming that released engine. | Keep KEN-2281's existing control. Do not claim a source test or latest selection alone proves adoption. | KEN-2281 |
| Stale hook helper, unmeasured here | Supply a helper from the previous installer body. The existing installer check reports `helper-outdated`. | A current helper passes; suppressing body-identity comparison turns the old-helper assertion red. | KEN-2437 |

## Scoped successor proposals

These are technical handoffs to existing owners. They are not new tracker issues or a roadmap.

### KEN-2297: release-owned execution and its bootstrap

- Extend `skills/review-gate/templates/kendex-refresh.yml`, `skills/review-gate/scripts/install-latest.sh`, `skills/review-gate/tests/refresh-workflow.test.sh` and `skills/review-gate/tests/install-latest.test.sh`.
- Bootstrap the existing installer helper from a sparse trusted kendex default-branch checkout before minting the consumer app token. The helper gets only the workflow's read-only API token. This makes a missing or broken consumer helper irrelevant to the next run. Do not duplicate its release selection in YAML.
- Extend the helper to publish its already-validated selected `version` and immutable `commit` through GitHub's existing step-output file after successful installation. Keep its current report and token isolation. No new user setting or general installer API is needed.
- Checkout the runtime scripts from that one resolved commit. Use a sparse source checkout containing review-gate scripts, their libraries and templates, plus harness-ci scripts and the required sibling libraries. Derive the required files from actual source/exec calls, not a new dependency table.
- Keep the consumer checkout as the working directory. `refresh-consumer.sh` and `refresh-reviews.sh` use the released source paths through `SCRIPT_DIR`, not consumer `.agents` exec paths. The classifier beside the released package stays its sole class owner.
- The bootstrap helper is reviewed default-branch code without write credentials. The publication and review runners are reviewed release code with their existing scoped tokens. Accept this separation rather than executing publication code from mutable main.
- Keep the authoritative full default-branch template history available for the adopter. Historical proof can include a newer shipped catalog template than the running release. Execute no publication code from that history.
- The current adopter computes template record paths relative to the consumer. Preserve that destination identity when code comes from an external checkout. An external runtime path must not become an inventory template path.
- The absent-consumer-executable fixture and both exec-path mutants prove removal of this dependency. Also plant a different runtime checkout commit from the installed release; the equality assertion must fail.
- Existing old workflows do not gain this wiring merely because kendex main changes. KEN-1963 adoption and the KEN-2296 bootstrap history identify the initial delivery owner. State which blocked consumer still needs authorized workflow adoption. Once this wiring reaches a consumer, the next run receives released runner fixes without hand-copying a runner. Do not claim that property for an unconverted workflow.

### KEN-2438: orphan settlement through the existing plan

- Change refresh's `PlanOptions` choice, not removal's ownership decision or a post-refresh cleanup script.
- Use `engine/removal.rs::orphans`, `edit_holds`, `TrashGuard`, trash preconditions and the same apply transaction that refresh already uses.
- Keep the request narrow enough not to silently broaden Pi package cleanup or another kind's existing policy. KEN-2438 owns the scope decision and the agent-only regression fixture. No agent-name exemption list.
- Update the refresh docstring and covering architecture text together. An unchanged orphan is removed and recorded in the same run. An edited, unreadable or unowned copy remains a conflict. The existing `--yes` covers a shown install-set change, not edit loss.

### KEN-2449: required dependency settlement

- The supplied evidence measures 374 install-record-gap runs: kendex-web 373 and hyprtrade-io 1. Of these, 355 name only hooks. The other 19 contain skills. Five separate adoption-verification runs also report record gaps, but count only under their failed bookkeeping checks.
- First compare KEN-2405's resulting dependency expansion with `refresh.rs::write_scope` and its apply path. Expansion already decides the required closure. Refresh must land the resulting plan, not rebuild a list from check output.
- Audit the earlier skill-containing gaps before claiming they are required-dependency failures. Check requested packages, bundle members, required edges and harness exclusions in the existing plan. The logs alone supply no consumer manifest or catalog bytes for that root-cause decision. This is an audit handoff to the existing owner, not a new implementation in KEN-2416.
- The success criterion is a formerly installed package gaining a required hook, followed by one refresh and a passing check with the hook recorded.
- Keep missing-required-dependency verification. A notice-only workaround would leave an active package without its declared companion.
- Keep KEN-2437's hook-helper arming identity out of this change. Installing a hook dependency and detecting an old clone-local helper are different owners.

### Consumer subscription migration

- Apply the approved `generalist` to `maintainer` and `engineer` to `runtime` manifest changes through each consumer's adoption owner. Preserve source, enabled state, harness choices and local instructions.
- KEN-2400 supplies the approved names. KEN-2332's plan supplies the adoption program. That issue is Done as a plan, not proof that every consumer is migrated.
- The calling lane asks TPM to bind the consumer observations to the existing per-repository adoption items. Do not create a second catalog rename or an engine alias issue.

## Consequences

| Risk and impact | Evidence of likelihood | Mitigation |
| --- | --- | --- |
| Automatic replacement loses a consumer's workflow or render edits. | KEN-2376 reports workflow data loss. Both replacement branches exist on baseline. | Refuse before replacement; assert exact bytes and publication absence. |
| A repaired source runner never reaches a blocked consumer. | 1039 class refusals occur across the combined fleet. Vsys has 193 workflow refusals. Four runs cannot find the consumer runner at all. | KEN-2297 owns steady-state release execution. The calling lane identifies initial adoption blockers without claiming that a source merge deployed them. |
| Authoritative template history needs a Git read. A read outage can stop adoption. | No such cause is measured in this table. The proposed lookup needs that dependency. | Use the existing adopter scratch lifetime; name the read failure and leave tracked files intact. Do not use consumer history as a fallback. No new cache or setting. |
| Historical recognition accidentally accepts a consumer edit. | Current history traversal reads consumer repositories. The fake-history counterexample reaches that branch. | Compare against authoritative default-branch ancestry only. Reject metadata and consumer-history substitutes. |
| Orphan cleanup deletes an edited or shared file. | No deletion failure is measured here. Existing removal code has guards for these cases. | Reuse those guards and add the edited-orphan and shared-path preservation twins under KEN-2438. |
| A reported after-rate falsely implies fleet recovery. | The full before sample is supplied, but no deployed after sample exists. One queued outcome and cancellation causes remain unresolved in the collected data. | Keep the accessible and combined denominators. Record actual consumer delivery before the successor measures its after sample. A fixture pass is not an after-rate. |

**Rollback**: revert the first preservation change through normal review if it blocks an exact shipped fixture. Restore no automatic discard or overwrite as an operational bypass. Correct the authoritative lookup or refusal cause instead. A consumer can keep its last untouched workflow while its adoption owner corrects delivery. Keep leases, verification, source exclusion and scoped tokens throughout rollback.

**TPM handoff needed**: yes, after merge through Proposal, to transfer Requirement 4 to an owner-observed successor and preserve existing-issue bindings. The reason is that deployment and a comparable consumer after-rate occur after this PR completes. KEN-2297, KEN-2438, KEN-2449 and KEN-2437 retain their implementations. KEN-2376 R47 overlaps preservation. The eleven additional measured classes add evidence and owner audit controls, not new repair scope. The calling lane passes the prompt below; this planner invokes no TPM and makes no tracker write.

## After observation

KEN-2478 records an interim observation under the owner's launch ruling. The overseer re-reads the consumers for the final sample. The listed and completed after-rates remain pending. KEN-2416 fixture proof is not a consumer after-rate.

### Method and delivery boundary

- The cutoff is fixed before reduction: `2026-10-01T21:49:05Z`. The diagnostic listing covers created-at times from `2026-10-01T20:31:00Z` through that cutoff, inclusive UTC. It starts at the owner-reported KEN-2416 merge minute, not at sample eligibility.
- The owner reports kendex 1.4.0 published at `2026-10-01T21:23:00Z`, carrying KEN-2460. Publication alone starts no consumer sample.
- Each consumer's sample starts at its first scheduled `kendex-refresh.yml` run after its rolling refresh installs both the deployed workflow and engine. Record that run's creation time as the start. Keep the first deployed run as a separate diagnostic record; do not substitute it for a seven-day sample. Count each run ID once, including scheduled and dispatched runs in the sample interval.
- The overseer is the delivery confirmer. The release and pin facts below come from the owner's launch ruling. Actual workflow adoption, engine source commits and installation times need run evidence. A consumer run's `headSha` is not an engine commit. An installer commit is not an engine commit either.
- This lane uses only `gh run list` and `gh run view` with its supplied credential. It cannot confirm the dispatch owner's current repository inventory. The existing authoritative before inventory supplies the consumer set. The overseer must confirm the current non-archived inventory before the final comparison. Kendex stays excluded. Gentoo-overlay, homebrew-kendex, vgs and vgs-themes remain historical attempts, not current consumers.
- Listings use `--workflow kendex-refresh.yml --all --limit 1000` with the fixed created-at interval and no event, branch, status or conclusion filter. Vsys returns eight rows, below the limit. The other listings return lane-credential HTTP 404, not empty histories. Raise any saturated limit or split its interval before counting it.
- Retrieve `gh run view --log-failed` for every failed or cancelled completed run. Preserve unavailable logs as unclassified. The current raw rows, commands, log results and denominators are in [Counts and denominators](ken-2416-refresh-runs.md#counts-and-denominators).
- At the final observation, use the same seven-day duration as the before sample. Fix the final cutoff before reduction. Preserve all conclusions and report both rates using the definitions in [Counts and denominators](ken-2416-refresh-runs.md#counts-and-denominators). No partial-sample after-rate is reported.
- The overseer confirms no local refresh runs outside Actions. A base refresh, source merge or main-built verification does not enter the consumer denominator. KEN-2297, KEN-2438, KEN-2449 and KEN-2437 keep their implementation scope.

### Consumer delivery and sample starts

All times below are UTC. Pending means this lane cannot verify the fact. The overseer owns delivery confirmation and the inaccessible rows.

| Consumer under vanillagreencom | Owner-reported engine selection | Actual workflow and engine evidence | Installation time and sample start at cutoff |
| --- | --- | --- | --- |
| talk | Latest stable release at run time | Lane-credential 404; workflow and engine commits pending | Both pending; latest-release selection does not prove installation of 1.4.0 |
| vg | Latest stable release at run time | Lane-credential 404; workflow and engine commits pending | Both pending; latest-release selection does not prove installation of 1.4.0 |
| fleet | Pinned v1.3.0 | Lane-credential 404; workflow and engine commits pending | Both pending; reported pin predates 1.4.0 |
| vsys | Pinned v1.3.0 | Scheduled run [36929699090](https://github.com/vanillagreencom/vsys/actions/runs/36929699090) has run head and checkout `7d7e614bc8b7a65ae141940b4fb6c20d19a6cb21`; it executes the runner from that detached checkout. Its install log prints `kendex 1.3.0`. Deployed-workflow adoption and engine source commit remain pending. | Old engine reports installed at `2026-10-01T21:35:47.3972837Z`; version output is at `2026-10-01T21:35:49.8954682Z`. No eligible start is verified: this post-release schedule still uses 1.3.0. Installation time for the deployed pair is pending. |
| hyprtrade | Pinned v1.2.0 | Lane-credential 404; workflow and engine commits pending | Both pending; reported pin predates 1.4.0 |
| kendex-web | Pinned v1.2.0 | Lane-credential 404; workflow and engine commits pending | Both pending; reported pin predates 1.4.0 |
| hyprtrade-io | Pinned v1.2.0 | Lane-credential 404; workflow and engine commits pending | Both pending; reported pin predates 1.4.0 |
| drovr | Pinned v1.2.0 | Lane-credential 404; workflow and engine commits pending | Both pending; reported pin predates 1.4.0 |

Vsys's verified workflow execution still installs a pinned engine and executes a consumer-local runner. Its installer SHA is `f6ad9491a810a9256f04f66f8d083eb9db709602`, not the engine source commit. Evidence is `tmp/waiter.UOARog/vsys-36929699090-full.log`. The run head and checkout identify the consumer revision; they do not prove adoption of the KEN-2416 workflow. No consumer has a verified eligible start in this lane's evidence. The inaccessible consumers remain unknown, not confirmed undeployed.

### First deployed runs, separate from the sample

| Consumer | First verified deployed run and time | Status |
| --- | --- | --- |
| talk | Pending | Overseer must read the lane-credential 404 row |
| vg | Pending | Overseer must read the lane-credential 404 row |
| fleet | Pending | Overseer must confirm delivery beyond the reported v1.3.0 pin |
| vsys | Pending | Post-release schedule 36929699090 still installs 1.3.0; dispatch 36929876600 is not an eligible scheduled start |
| hyprtrade | Pending | Overseer must confirm delivery beyond the reported v1.2.0 pin |
| kendex-web | Pending | Overseer must confirm delivery beyond the reported v1.2.0 pin |
| hyprtrade-io | Pending | Overseer must confirm delivery beyond the reported v1.2.0 pin |
| drovr | Pending | Overseer must confirm delivery beyond the reported v1.2.0 pin |

These pending entries are not zero-run findings. [Interim raw observation](ken-2416-refresh-runs.md#interim-raw-observation) keeps all listed diagnostic runs apart from an eligible after sample. The owner must observe the complete seven-day interval after each confirmed start before supplying the final listed and completed rates.

## TPM handoff prompt

> After KEN-2416 merges, use Proposal with `docs/plans/ken-2416-consumer-refresh.md` and the indexed `docs/plans/ken-2416-refresh-runs.md` to transfer Requirement 4 to an owner-observed successor. KEN-2416 completes at this PR merge with measurement plus workflow/render edit preservation. The before sample is complete under the supplied inventory: 2853 listed runs, 1990 failures, 69.75%; the original accessible sample remains 403/361, 89.58%. Keep release-owned execution and installer bootstrap/output with KEN-2297; orphan settlement with KEN-2438; required dependency settlement with KEN-2449 after checking KEN-2405; helper drift with KEN-2437. KEN-2449's owner audits the 19 skill-containing record gaps before claiming the same root cause. Keep the explicit drops for revision conflicts, unreadable effects, verification mismatches, queue/default movement and service/read/download failures. No new implementation issue is requested for them. Map authorized subscription and workflow adoption through existing consumer items. Record only KEN-2376 R47 overlap. Leave KEN-2391's broader error-state work there. The successor names the owner who confirms actual consumer workflow/runtime delivery, then observes a comparable seven-day Actions sample after deployment. Record the first deployed runs separately. Base refresh and fixture passes are not the after-rate. No local refresh runs exist under the current ruling. No collector, tool, script, watch, setting or duplicate implementation path. The calling lane owns Proposal, tracker writes and evidence attachments.

## Implementer handoff prompt

> Keep implementation limited to the numbered preservation plan in `docs/plans/ken-2416-consumer-refresh.md`. Use the runtime completion artifact for final validation of the preservation code and disposable controls. Include the measurement index and all per-consumer companions as before evidence in the validated fix commit. Preserve real workflow and rendered-file edits. Accept exact current and historical shipped workflow bytes with or without an adoption record. Keep classification, verification, the explicit push lease, environment checks, source exclusion, settings checks and scoped credentials. Prove each independent changed preservation rule through the existing suites. Replay source diffs into tracked renders. Do not refresh or apply here or change `.kendex-lock.json`. Other implementations and owner audit controls stay with their existing issues or explicit drops. Return fixture proof, mutant proof, changed reports/docs and deployment dependencies separately. KEN-2416 completes at this PR merge. Route Requirement 4 after merge through Proposal to the owner-observed successor. Do not claim a consumer after-rate from fixture proof.
