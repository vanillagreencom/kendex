# KEN-2416 consumer refresh design

KEN-2416 should first preserve hand edits in the existing workflow adoption and consumer refresh owners.

## Framing

- **Goal**: remove false refresh refusals without replacing a real consumer edit or weakening verification, classification, containment, or publication checks.
- **Perspective**: the consumer's next scheduled refresh, the code that starts it, and the owner of each check.
- **Constraints read**: live KEN-2416 Requirements in order; `tmp/brief-plan-KEN-2416.md`; root and package instructions; code-quality, including Over-Engineering and Prove Your Guards; docs-writing; architecture overview, engine and merge-rail; D003 and D007.
- **Live bindings read**: KEN-2449, KEN-2438, KEN-2437, KEN-2297, KEN-2376, KEN-2281, KEN-2391, KEN-2277, KEN-2278, KEN-2279, KEN-2296, KEN-2405, KEN-1963, KEN-2239, KEN-2400 and KEN-2332.
- **Baseline**: `b315ac6420fb0027e5a6156648e0a2419a245b56`. It contains `becba596`. Measurement finishes and the raw report is written before code design starts.
- **Assumptions**: the dispatch owner's complete consumer inventory and the private histories are not available to this credential. No assumption replaces them with a public-only inventory. No assumption treats a fixture as a consumer after observation.
- **Planning boundary**: this round writes reports and scratch data only. Proposed tests below are not executed. No production file, install record or tracker item changes in this round.

## Before measurement

[Raw runs](ken-2416-refresh-runs.md) owns the interval, denominators, run URLs, individual evidence paths and observation gaps.

| Consumer | Listed | Failure | Listed failure rate |
| --- | ---: | ---: | ---: |
| vsys | 399 | 358 | 89.72% |
| gentoo-overlay | 1 | 1 | 100.00% |
| homebrew-kendex | 1 | 1 | 100.00% |
| vgs-themes | 1 | 1 | 100.00% |
| vgs | 1 | 0 | 0.00%, queued with no conclusion |
| Accessible total | 403 | 361 | 89.58% |
| Full dispatch inventory | Unknown | Unknown | Not measured |

The accessible completed-run rate is 89.80%: 361 failures out of 402 completed runs. The remaining run is queued. One completed run is cancelled and has an empty failed-step log. All failure logs are retrieved. No failed run in the readable history needs a guessed class.

## Cause and ownership decisions

| Measured class | Count | Design defect or correct refusal | Existing owner and disposition |
| --- | ---: | --- | --- |
| `publication-class` | 136 | The old runner uses the render-only auto-merge condition to prohibit publication of a measured standard refresh. A legitimate update cannot reach a reviewer. | `refresh-consumer.sh`. KEN-2277 removes this defect on main in `fb05f185`. Keep its measured-class publication and render-only arm. KEN-2297 owns delivery of the fixed runner. Do not implement another class rule here. |
| `workflow-ownership` | 193 | The old adopter treats missing adoption metadata as proof of a hand edit. The current adopter recognizes historical copies, but then replaces a genuine edit with a warning. Its candidate history comes from consumer repositories, which cannot establish what kendex shipped. | `adopt-refresh.sh`. KEN-2278, `e591dfda`, removes the missing-record refusal only in source. KEN-2416 completes exact shipped-byte recognition and restores refusal before replacement. This satisfies only KEN-2376 row R47, not its review or dispatch rows. |
| `consumer-bootstrap` | 3 | The workflow executes a path in a detached copy of the consumer. That path is absent in these runs. The same dependency makes an installed old runner unable to obtain its own repair. | The refresh workflow template. Bind to KEN-2297. Also bind the initial consumer install to KEN-1963. A release checkout removes reliance on a consumer executable, but does not authorize silently adding a manifest or package declaration to a repository. |
| `orphan-agent-record` | 23 | Refresh reconciles dependencies but leaves a formerly requested agent's unneeded record and renders. Its following verify then fails on those same records. | `refresh.rs::prepare_scope` and `engine/removal.rs::orphans`. Bind to KEN-2438, which is In Progress. Do not add a cleanup command or a second removal pass. |
| `retired-agent-declaration` | 5 | The consumer still declares `generalist` after the approved catalog renames it to `maintainer`. Refresh cannot infer permission to change declared intent. This refusal is correct; the subscription migration has not reached this consumer. | Consumer manifest owner. Bind the migration to KEN-2400 and the KEN-2332 adoption plan. Drop an automatic alias, rename inference or deletion fix here: each would change consumer intent without consent. |
| `publication-lease` | 1 | The expected remote branch state does not match the state at push. The log proves `stale info`, not the competing writer or a faulty lease implementation. The explicit lease is already present in the original KEN-1779 runner. | `refresh-consumer.sh` publication. Drop a production repair here: this is a correct protection against replacing an unexpected head, with no measured permanent defect. Keep the lease and add its preservation control to the existing suite. |

### Current source evidence

- `refresh-consumer.sh` now publishes any measured class. It leaves non-render pull requests unarmed. Its `refresh-error=read value=class` still stops an unmeasured result.
- The same runner reads held edits from the CLI's plain conflict and ledger records. It then runs `kendex refresh --scope project --yes --leave --discard-edits`. That is automatic permission to discard a consumer's edits. KEN-2279 adds this in `3ba501b9`. Remove that permission in this branch, rather than turning verify into a warning.
- `adopt-refresh.sh` compares current, vendored and historical template bytes. Its Git history roots can be the consumer's repository. A consumer can commit a changed template and workflow together. Such a commit is not kendex shipment evidence.
- On a non-shipped workflow, the adopter prints `refresh-warning=workflow-edited`, writes the new workflow, and changes the inventory. Its `validate-workflow.sh --adopt` call also precedes the workflow edit decision. Refusal must precede that effectful call.
- The workflow still executes the consumer's `install-latest.sh`, then consumer runners under `$RUNNER_TEMP/refresh-skills/.agents/skills/`. Fixing only the two later exec paths leaves a bootstrap failure when the first helper is absent or broken.
- `install-latest.sh` already owns release selection, tag validation, tag-to-commit resolution and immutable installer download. Its report supplies `version` and `commit`. It removes both GitHub tokens from downloads and installer execution.
- `refresh.rs::prepare_scope` sets `sweep_unneeded: true`, but not `remove_orphans`. `removal.rs` removes only derived-only records or departed harness copies under the sweep option. A formerly requested, now undeclared agent is left. The CLI's current docstring explicitly promises to leave such orphans.
- `removal.rs::edit_holds`, the trash preconditions and `TrashGuard` already protect edits, shared paths and changed bytes. KEN-2438 must reuse these decisions.

### Other reported classes

These rows have live issue evidence, not a measured count in the readable run table.

| Class | Binding | Decision |
| --- | --- | --- |
| Newly required hooks are listed but not installed or recorded | KEN-2449, Backlog; related KEN-2405, In Review | KEN-2405 changes dependency declaration and expansion. KEN-2449 owns the remaining refresh settlement case. The fixture must use a dependency added after the initial install, not only an initial install. No check exemption for a missing required dependency. |
| Engine and catalog accept different feature sets | KEN-2281, Done | `53098d7b` installs the latest stable engine and checks catalog compatibility with that released engine. Do not undo it or add another installer. Consumer adoption and a release carrying the changed scripts still need observation. |
| Pulled renders leave an old Git hook helper armed | KEN-2437, Backlog | The installer owns its helper identity and drift line. Do not put hook installation or body-version detection into refresh-consumer. |
| Exact partial state and host/source failure reporting | KEN-2391, Backlog | Its apply, journal, ignore, renderer and source-reader rows remain there. A refresh can write unrelated managed files before a later refusal. This plan promises preservation of edited files and no publication, not an invented transaction over the whole workflow. |
| Review predicate and dispatch enumeration/retry changes | KEN-2376, Backlog | Only workflow edit preservation overlaps this branch. Leave R15, R21, R22, X39 and X40 with their owners. The lane's inventory permission failure is an observation gap, not evidence of a dispatch defect. |
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
7. **Return the branch as a preservation fix, not completion of KEN-2416.** Supply the two plan paths, the preservation proof, the existing-issue dispositions below and the consumer observation dependencies. The calling lane owns proposal routing, attachments and issue updates. The full inventory measurement, successor changes, deployment and owner after-rate remain completion conditions.

### Files

- **Production files to modify first**: `skills/review-gate/scripts/adopt-refresh.sh`, `skills/review-gate/scripts/refresh-consumer.sh`.
- **Tests and helpers**: `skills/review-gate/tests/adopt-refresh.test.sh`, `skills/review-gate/tests/refresh-consumer.test.sh`, and only the existing `skills/review-gate/tests/lib/` helpers those suites use.
- **Documentation**: `skills/review-gate/SKILL.md`, `skills/review-gate/references/adoption.md`, `skills/review-gate/DEVELOPMENT.md`, `docs/architecture/merge-rail.md`; matching shipped `.agents` renders.
- **New production scripts, settings, dependencies or commands**: none.
- **New files**: one changelog fix fragment. Tests stay in existing suites. The two requested plan artifacts are the only tracked files written by this planning round.
- **Critical execution files**: `skills/review-gate/scripts/adopt-refresh.sh`, `skills/review-gate/scripts/refresh-consumer.sh`, `skills/review-gate/tests/adopt-refresh.test.sh`, `skills/review-gate/tests/refresh-consumer.test.sh`, `skills/review-gate/templates/kendex-refresh.yml`.

## Must-fail controls

A planted defect makes its guard refuse. A production mutant that removes that behavior must turn the assertion red. Controls on already-correct code are preservation proof, not evidence of a new fix.

| Class or independent safety rule | Planted defect and required result | Regression or mutant proof | Owning work |
| --- | --- | --- | --- |
| Workflow identity | vsys's exact historical shipped bytes pass without an adoption record; a one-line edit fails and stays in place. A fake consumer-history copy also fails. | Current code overwrites the real edit, so the preservation assertion fails on baseline. Disable history acceptance or edit refusal separately in disposable copies. | KEN-2416; KEN-2376 R47 overlap |
| Unreadable workflow history | Make the authoritative history/blob read fail. Refuse before any tracked write. Do not blame a hand edit. | Ignore that read failure in a copy; the no-write/read-refusal assertion turns red. | KEN-2416 |
| Workflow link or changed precondition | Plant a symlink or change the file after its preflight. Refuse without writing the target. | Disable each refusal separately. The target-preservation assertion turns red. | KEN-2416 |
| Render edit | Edit a recorded render locally, with and without an upstream change. Preserve it and refuse before publication. | Baseline runs the discard pass. Restoring that pass on the fix turns the byte-preservation/no-push assertion red. | KEN-2416 |
| Publication class | Plant a measured standard result. Publish an unarmed pull request. Plant an unmeasured fallback separately; publish nothing. | Restore the old render-only publication stop, or disable the unmeasured guard, separately. Each assertion turns red. The standard fix already exists in source. | KEN-2277, delivery through KEN-2297 |
| Consumer executable dependency | Install no vendored runtime executable in the consumer fixture. A release-owned runner must execute against that consumer. | Route either runtime exec back to the missing consumer path; the run turns red. Today's workflow has that defect. | KEN-2297, initial declarations under KEN-1963 |
| Orphan agent | Install generalist, migrate the manifest to maintainer, then refresh once. Only the owned unedited old agent renders and record leave. Verify passes. | Baseline leaves the old requested record. Restore the old orphan option on the fix; the post-refresh assertion turns red. Add an edited-orphan twin that remains held. | KEN-2438 |
| Retired declaration | Keep an explicit generalist declaration against a catalog with only maintainer. Refuse resolution without altering that declaration. | Current code already enforces this. An alias or silent declaration rewrite must fail the intent-preservation assertion. After the approved consumer manifest migration, normal resolution passes. | KEN-2400 subscription migration and KEN-2332 adoption program |
| Publication lease | Advance the remote rolling head after the runner reads it. The push fails and keeps that head. | Remove the explicit lease in a disposable runner; the competing-head assertion turns red. No measured production repair is proposed. | Existing refresh-consumer publication |
| Required dependency, unmeasured here | Add a required hook after a skill's initial install. One refresh installs and records the new dependency; check passes. | Baseline fails after refresh if KEN-2405 has not already removed the gap. Disable the fixed settlement behavior in a copy; the row turns red. | KEN-2449, checked against KEN-2405 |
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

- First compare KEN-2405's resulting dependency expansion with `refresh.rs::write_scope` and its apply path. Expansion already decides the required closure. Refresh must land the resulting plan, not rebuild a list from check output.
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
| A repaired source runner never reaches a blocked consumer. | 136 class refusals and 193 workflow refusals occur in vsys. Its workflow executes its own preserved copy. | KEN-2297 owns steady-state release execution. The calling lane identifies initial adoption blockers without claiming that a source merge deployed them. |
| Authoritative template history needs a Git read. A read outage can stop adoption. | No such cause is measured in this table. The proposed lookup needs that dependency. | Use the existing adopter scratch lifetime; name the read failure and leave tracked files intact. Do not use consumer history as a fallback. No new cache or setting. |
| Historical recognition accidentally accepts a consumer edit. | Current history traversal reads consumer repositories. The fake-history counterexample reaches that branch. | Compare against authoritative default-branch ancestry only. Reject metadata and consumer-history substitutes. |
| Orphan cleanup deletes an edited or shared file. | No deletion failure is measured here. Existing removal code has guards for these cases. | Reuse those guards and add the edited-orphan and shared-path preservation twins under KEN-2438. |
| A reported after-rate falsely implies fleet recovery. | Private histories, the full dispatch inventory and local runs are unavailable in this lane. | Report accessible and fleet denominators separately. Keep deployment and observation prerequisites explicit. |

**Rollback**: revert the first preservation change through normal review if it blocks an exact shipped fixture. Restore no automatic discard or overwrite as an operational bypass. Correct the authoritative lookup or refusal cause instead. A consumer can keep its last untouched workflow while its adoption owner corrects delivery. Keep leases, verification, source exclusion and scoped tokens throughout rollback.

**TPM handoff needed**: yes, for existing-issue bindings and deployment/observation ordering, not new implementation scope. KEN-2438 is already In Progress. KEN-2297, KEN-2449 and KEN-2437 have separate owners. KEN-2376 R47 overlaps the preservation work. KEN-2281 and the catalog rename are merged, but consumer delivery is not established. The calling lane passes the prompt below; this planner invokes no TPM and makes no tracker write.

## After observation

- An after-rate cannot be measured before this change is merged, released where needed, and adopted by consumers. This worktree runs no refresh, apply or release.
- The overseer refreshes its base after merge. That is a base-maintenance dependency, not a consumer after sample.
- The release owner supplies a stable release carrying the selected runtime changes. Consumer adoption supplies the template changes. The owner then checks the consumers through their scheduled or dispatched runs.
- Obtain the complete non-archived dispatch-owner inventory with the owner's authorized read credential. Keep kendex excluded. Re-run the same `gh run list --workflow kendex-refresh.yml --all` command per consumer, with an end fixed before data reduction. Raise a saturated listing limit or split the time interval; never treat a capped list as complete.
- For a comparable rate, observe the same seven-day duration after deployment. Also report the first deployed run for immediate diagnosis, but do not call that single run the seven-day after-rate.
- Retrieve `gh run view --log-failed` for every failed or cancelled completed run. Keep unavailable logs unclassified. Record run IDs once, all conclusions, both denominators, per-consumer causes and totals as in the raw report.
- Record which workflow/runtime commit each consumer actually uses. Separate unconverted consumers from deployed consumers in the after table. A new latest release alone does not prove an old workflow runs it.
- Obtain local run records from the consumer machines where they exist. Missing records remain an observation gap, not zero local failures.
- Fixture pass counts, a clean source checkout, a main-built verify result and a merged issue are not the consumer after-rate.

## TPM handoff prompt

> Use `docs/plans/ken-2416-consumer-refresh.md` and `docs/plans/ken-2416-refresh-runs.md` to bind the remaining technical work to existing items. Keep this branch on workflow/render edit preservation and shipped-byte recognition. Bind release-owned execution, including the installer bootstrap and selected-commit output, to KEN-2297. Bind orphan records to the active KEN-2438 lane. Bind newly required dependency settlement to KEN-2449 after checking KEN-2405. Keep helper-body drift in KEN-2437. Record the KEN-2376 R47 overlap without absorbing its review/dispatch rows. Leave KEN-2391's broader error-state work there. Map the approved KEN-2400 subscription migration through existing consumer adoption items from the KEN-2332 program. Obtain the dispatch owner's inventory and missing private run evidence before calling the measurement fleet-wide. Sequence source merge, overseer base refresh, stable release, consumer adoption and owner after observation. No new collector, setting, watcher or duplicate issue. The calling lane owns tracker mutations and attachments.

## Implementer handoff prompt

> Implement only the numbered first-branch plan in `docs/plans/ken-2416-consumer-refresh.md`, against the latest permitted base. Use `docs/plans/ken-2416-refresh-runs.md` as before evidence. Preserve real workflow and rendered-file edits. Accept exact current and historical shipped workflow bytes with or without an adoption record. Keep classification, verification, the explicit push lease, environment checks, source exclusion, settings checks and scoped credentials. Add baseline-failing preservation fixtures and one must-fail control per independent changed rule in the existing suites. Replay source diffs into tracked renders. Do not refresh or apply in this marked worktree or change `.kendex-lock.json`. Return fixture proof, mutant proof, changed docs, existing-issue overlap and deployment blockers separately. Do not claim a consumer after-rate or full KEN-2416 completion.
