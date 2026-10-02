# KEN-2416 refresh runs

The combined fleet before-rate is 69.75%: 1990 failed runs out of 2853 listed runs.

## Interval and observation boundaries

- Created-at interval, inclusive UTC: `2026-09-24T14:14:50Z` through `2026-10-01T14:14:50Z`.
- The observation clock fixes this seven-day interval. The private collection uses the same interval as the original accessible collection.
- This report counts each retained GitHub Actions run ID of `kendex-refresh.yml` once. It does not count attempts as separate runs.
- The accessible JSON records the latest attempt returned by GitHub. The private JSON has no attempt or head SHA fields. Those fields remain unavailable for private rows.
- Conclusions are the values observed during collection, not reconstructed values at the interval's end. Accessible update times range from `2026-09-27T21:20:51Z` through `2026-10-01T14:13:59Z`. Private update times range from `2026-09-27T21:21:44Z` through `2026-10-01T14:14:57Z`. A private run can complete after the created-at boundary and still belong in this sample.
- Combined retained created-at bounds are `2026-09-27T21:20:51Z` through `2026-10-01T14:13:23Z`. Each companion gives its own bounds. An oldest retained run is not proof of a workflow's creation date.
- Every supplied listing is below its 1000-row limit. The accessible listings exhaust their retained history. The private listings exhaust the requested created-at interval. No event, branch, status or conclusion filter removes outcomes. The private command omits `--all`; the authoritative inventory confirms that each private repository queried has a refresh workflow.
- Coverage means retained Actions history under the supplied inventory. Deleted runs and deleted logs cannot be reconstructed with this evidence.
- The supplied inventory has no acquisition timestamp. It establishes the supplied repository scope, not the workflow state throughout the interval.
- Overseer ruling: no local refresh runs exist outside Actions. Local runs therefore add nothing to the denominator. Owner-machine record collection is not an outstanding task.

## Inventory and report index

`tmp/ken-2416-control-evidence.tgz!ken-2416-evidence/INVENTORY.md` and `repos.json` are the authoritative inventory. All 18 repositories are non-archived. The dispatch owner, `skills/review-gate/scripts/dispatch-refresh.sh`, enumerates its app installation and excludes kendex under D007. The prior repository-scoped credential could not establish that scope. The supplied control evidence resolves that access gap.

The inventory has eight current refresh consumers. Four public repositories have retained refresh attempts but no current refresh workflow. Keep those historical rows in the combined denominator. They do not become current consumers. The remaining repositories below have no refresh workflow and no supplied refresh rows.

| Repository under vanillagreencom | Visibility | Current refresh workflow | Observation scope | Listed rows and report |
| --- | --- | --- | --- | --- |
| kendex | public | no | Excluded catalog; lock writer is not consumer refresh | N/A |
| vgs | public | no | Historical refresh attempt; queued at accessible collection | [1 row](ken-2416-refresh-runs-vgs.md) |
| vsys | public | yes | Current consumer; accessible history | [399 rows](ken-2416-refresh-runs-vsys.md) |
| homebrew-kendex | public | no | Historical refresh attempt | [1 row](ken-2416-refresh-runs-homebrew-kendex.md) |
| vgs-themes | public | no | Historical refresh attempt | [1 row](ken-2416-refresh-runs-vgs-themes.md) |
| gentoo-overlay | public | no | Historical refresh attempt | [1 row](ken-2416-refresh-runs-gentoo-overlay.md) |

The other twelve repositories are private. Seven are current consumers whose supplied private histories form the private supplement below; five are not refresh consumers.

Per-repository records were removed from this public repository (KEN-2602).

The earlier HTTP 404 listing results remain in source scratch evidence. They are credential observations, not zero-run findings. The authoritative inventory supersedes their unknown scope. No consumer-list setting or second dispatch inventory is introduced.

## Counts and denominators

- **Listed rate**: `failure / all listed run IDs created in the interval`. Cancelled and queued runs remain in this denominator.
- **Completed rate**: `failure / runs with status completed`. Cancelled runs remain in this denominator. A queued run does not.
- Only the exact conclusion `failure` enters the failure numerator. An empty conclusion means pending, not success.
- **Accessible total** preserves the original measurement. **Private supplement** contains the seven supplied private histories. **Combined fleet total** combines both without changing any original outcome.
- **Current-consumer subtotal** excludes only the four historical public attempts whose current workflows are absent. It is not a replacement for the combined fleet denominator.
- `N/A` means no denominator. The queued vgs row gives a listed rate of 0.00%, not proof of a successful refresh.

| Consumer or sample | Listed | Completed | Failure | Success | Cancelled | Pending | Listed rate | Completed rate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| gentoo-overlay | 1 | 1 | 1 | 0 | 0 | 0 | 100.00% | 100.00% |
| homebrew-kendex | 1 | 1 | 1 | 0 | 0 | 0 | 100.00% | 100.00% |
| vgs | 1 | 0 | 0 | 0 | 0 | 1 | 0.00% | N/A |
| vgs-themes | 1 | 1 | 1 | 0 | 0 | 0 | 100.00% | 100.00% |
| vsys | 399 | 399 | 358 | 40 | 1 | 0 | 89.72% | 89.72% |
| Accessible total | 403 | 402 | 361 | 40 | 1 | 1 | 89.58% | 89.80% |
| Private supplement | 2450 | 2450 | 1629 | 776 | 45 | 0 | 66.49% | 66.49% |
| Combined fleet total | 2853 | 2852 | 1990 | 816 | 46 | 1 | 69.75% | 69.78% |
| Current-consumer subtotal | 2849 | 2849 | 1987 | 816 | 46 | 0 | 69.74% | 69.74% |

Per-repository records were removed from this public repository (KEN-2602).

### Interim after comparison

The before sample remains unchanged. KEN-2478's interim observation has no verified eligible consumer start. The owner accepts this interim record and leaves the final rates to the overseer's seven-day observation. [After observation](ken-2416-consumer-refresh.md#after-observation) owns delivery, per-consumer starts and first deployed runs.

| Sample | Interval | Listed | Completed | Failure | Listed failure rate | Completed failure rate |
| --- | --- | ---: | ---: | ---: | --- | --- |
| Combined fleet before | Seven days ending `2026-10-01T14:14:50Z` | 2853 | 2852 | 1990 | 69.75% | 69.78% |
| Final deployed-consumer after | Seven days from each verified consumer start; start and end times pending | Pending | Pending | Pending | Pending until the seven-day sample completes | Pending until the seven-day sample completes |

The four historical public attempts remain in the recorded before denominator. They do not enter a current-consumer after sample. Kendex remains excluded. Vsys's diagnostic failures below do not establish an after-rate. Lane-credential HTTP 404 supplies no denominator for the inaccessible consumers.

### Interim raw observation

- Fixed cutoff before reduction: `2026-10-01T21:49:05Z`. Diagnostic created-at interval, inclusive UTC: `2026-10-01T20:31:00Z` through that cutoff. The start is the owner-reported KEN-2416 merge minute, not a deployed-consumer sample start.
- Query each current consumer with the command below. All eight requests use the same credential and interval. Only vsys returns rows. Its eight rows are below the 1000-row limit. No listing is saturated. The seven HTTP 404 results are access gaps, not complete empty listings.
- Each row records the latest attempt returned during collection. All vsys rows are attempt 1, on `main`, with `headSha` `7d7e614bc8b7a65ae141940b4fb6c20d19a6cb21`. Their `startedAt` equals `createdAt`. This consumer revision is not an engine commit.
- Observation conclusions come from collection after the cutoff; they are not reconstructed at the cutoff. Every returned row's update time is before the cutoff.
- The owner's release boundary is `2026-10-01T21:23:00Z`. Six listed rows precede it; two follow it. These are diagnostic divisions, not after-sample denominators. No row has verified delivery of both the deployed workflow and engine.
- All eight rows are completed failures. Each failed-log request exits 0 and has nonempty output. There are no listed success, cancelled or pending rows. The logs show obsolete `generalist` records and an unrecorded `skill-load-check` hook at verification. Record both observed refusals; do not infer one root cause or add them as separate failed runs. Existing KEN-2438 and KEN-2449 owners audit their respective implementation classes.

```bash
gh run list --repo vanillagreencom/CONSUMER --workflow kendex-refresh.yml --all --limit 1000 --created '2026-10-01T20:31:00Z..2026-10-01T21:49:05Z' --json databaseId,attempt,createdAt,startedAt,updatedAt,status,conclusion,event,headBranch,headSha,url
gh run view RUN_ID --repo vanillagreencom/vsys --log-failed
gh run view 36929699090 --repo vanillagreencom/vsys --log
```

Scratch evidence is under this worktree's `tmp/waiter.UOARog/`. `CONSUMER-list.log` preserves the listing or HTTP 404 error after its runner line. `CONSUMER-list.exit` preserves its exit code. `vsys-RUN_ID-failed.log` and `.exit` preserve each failed-log request. `vsys-36929699090-full.log` and `.exit` preserve the scheduled run's installation evidence. All requests run through the existing orch job runner with `TMPDIR` and `ORCH_STATE_DIR` unset. No consumer mutation or credential substitution occurs.

| Consumer | Listing result | Listed / completed / failure | Sample status | Raw evidence basename under `tmp/waiter.UOARog/` |
| --- | --- | --- | --- | --- |
| vsys | Eight rows, exit 0 | 8 / 8 / 8 diagnostic only | Post-release schedule still uses 1.3.0; eligible start unverified | `vsys-list.log` |

Per-repository records were removed from this public repository (KEN-2602).

Each raw row below belongs to vsys. Failed-log evidence is the exact basename `vsys-RUN_ID-failed.log` defined above. Event names and observed status/conclusion are retained without filtering.

| Run URL | Created at UTC | Updated at UTC | Event | Observed status / conclusion | Release boundary and eligibility |
| --- | --- | --- | --- | --- | --- |
| [36922218168](https://github.com/vanillagreencom/vsys/actions/runs/36922218168) | 2026-10-01T20:31:37Z | 2026-10-01T20:32:21Z | repository_dispatch | completed / failure | Before release; excluded diagnostic |
| [36922625504](https://github.com/vanillagreencom/vsys/actions/runs/36922625504) | 2026-10-01T20:34:58Z | 2026-10-01T20:35:46Z | repository_dispatch | completed / failure | Before release; excluded diagnostic |
| [36922959420](https://github.com/vanillagreencom/vsys/actions/runs/36922959420) | 2026-10-01T20:37:40Z | 2026-10-01T20:38:19Z | schedule | completed / failure | Before release; excluded diagnostic |
| [36923446010](https://github.com/vanillagreencom/vsys/actions/runs/36923446010) | 2026-10-01T20:41:39Z | 2026-10-01T20:42:20Z | repository_dispatch | completed / failure | Before release; excluded diagnostic |
| [36926018396](https://github.com/vanillagreencom/vsys/actions/runs/36926018396) | 2026-10-01T21:03:13Z | 2026-10-01T21:03:54Z | schedule | completed / failure | Before release; excluded diagnostic |
| [36927699871](https://github.com/vanillagreencom/vsys/actions/runs/36927699871) | 2026-10-01T21:17:46Z | 2026-10-01T21:18:29Z | repository_dispatch | completed / failure | Before release; excluded diagnostic |
| [36929699090](https://github.com/vanillagreencom/vsys/actions/runs/36929699090) | 2026-10-01T21:35:34Z | 2026-10-01T21:36:22Z | schedule | completed / failure | After release; installs 1.3.0; not an eligible start |
| [36929876600](https://github.com/vanillagreencom/vsys/actions/runs/36929876600) | 2026-10-01T21:37:13Z | 2026-10-01T21:38:00Z | repository_dispatch | completed / failure | After release; no verified deployed pair or eligible scheduled start |

The full log for scheduled run 36929699090 exits 0. It explicitly installs v1.3.0 and prints `kendex 1.3.0`. The actual engine source commit remains pending. The before evidence and its classifications below remain separate from this interim observation.

## Failure classes

Each failed run gets one stopping class. Warnings that do not stop the run get no failure count. The original six classes keep their meaning. Eleven additional classes are measured in the supplied private logs. [Consumer refresh design](ken-2416-consumer-refresh.md) owns each class's defect or correct-refusal decision, existing owner, must-fail control and disposition.

| Cause class | Accessible failures | Private failures | Fleet failures | Exact evidence marker | First public representative |
| --- | ---: | ---: | ---: | --- | --- |
| `publication-class` | 136 | 903 | 1039 | `refresh-error=class value=change_class=standard` | [vsys 36377572518](https://github.com/vanillagreencom/vsys/actions/runs/36377572518) |
| `workflow-ownership` | 193 | 0 | 193 | `refresh-error=workflow-edited` | [vsys 36611715215](https://github.com/vanillagreencom/vsys/actions/runs/36611715215) |
| `retired-agent-declaration` | 5 | 49 | 54 | `failed: generalist` or `failed: engineer`: `not found in source 'kendex'` | [vsys 36827947402](https://github.com/vanillagreencom/vsys/actions/runs/36827947402) |
| `orphan-agent-record` | 23 | 68 | 91 | `agent generalist` or `agent engineer`: `left over from an earlier setup; nothing needs it anymore` | [vsys 36838231206](https://github.com/vanillagreencom/vsys/actions/runs/36838231206) |
| `consumer-bootstrap` | 3 | 1 | 4 | consumer worktree `refresh-consumer.sh: No such file or directory`, exit 127 | [gentoo-overlay 36351390143](https://github.com/vanillagreencom/gentoo-overlay/actions/runs/36351390143) |
| `publication-lease` | 1 | 6 | 7 | `HEAD -> kendex/refresh (stale info)` | [vsys 36370535125](https://github.com/vanillagreencom/vsys/actions/runs/36370535125) |
| `render-edited` | 0 | 141 | 141 | Private logs only | None public |
| `install-record-gap` | 0 | 374 | 374 | Private logs only | None public |
| `requested-revision-conflict` | 0 | 17 | 17 | Private logs only | None public |
| `adoption-verification` | 0 | 5 | 5 | Private logs only | None public |
| `repo-effects-unreadable` | 0 | 2 | 2 | Private logs only | None public |
| `publication-queue` | 0 | 15 | 15 | Private logs only | None public |
| `default-moved` | 0 | 3 | 3 | Private logs only | None public |
| `remote-read` | 0 | 36 | 36 | Private logs only | None public |
| `environment-read` | 0 | 5 | 5 | Private logs only | None public |
| `release-download` | 0 | 1 | 1 | Private logs only | None public |
| `publication-service` | 0 | 3 | 3 | Private logs only | None public |
| Total classified failures | 361 | 1629 | 1990 | Every failed run has supplied failed-step bytes | N/A |
| Unclassified failures | 0 | 0 | 0 | None | N/A |

### Per-consumer failure counts

| Consumer | Cause classes and counts | Failure total |
| --- | --- | ---: |
| gentoo-overlay | consumer-bootstrap: 1 | 1 |
| homebrew-kendex | consumer-bootstrap: 1 | 1 |
| vgs | None; queued | 0 |
| vgs-themes | consumer-bootstrap: 1 | 1 |
| vsys | publication-class: 136; workflow-ownership: 193; retired-agent-declaration: 5; orphan-agent-record: 23; publication-lease: 1 | 358 |

Per-repository records were removed from this public repository (KEN-2602).

### Classification boundaries

- The 374 install-record gaps comprise 355 hook-only gaps and 19 gaps containing skills. KEN-2449 explicitly owns the late required-hook case. A record gap alone does not prove that every earlier skill gap has the same root cause.
- All five adoption-verification runs fail the inventory layout check and both workflow equality checks. They also have unrecorded packages. Count each once under adoption-verification because these separate failed checks prevent attributing the stop solely to the record gap. Do not infer a real workflow hand edit from a mismatch alone.
- Thirty-nine retired-declaration runs name generalist only. Fifteen name engineer and generalist. Sixty-seven orphan runs show generalist records. Twenty-four show engineer and generalist records. Counts are runs, not failing harness rows or agent names.
- Remote-read comprises 32 repository-not-found cases and four Git HTTP 404 protocol cases. The logs establish unreadable Git access, not permanent repository deletion, expired credentials or an app-permission defect.
- Publication-service comprises two server-rejected pushes and one GraphQL merge failure. The last belongs to the review step in the same refresh workflow. Both steps remain in the workflow-run denominator.
- The desktop-app HTTP 404 and Pi hook-carrier warnings do not define a failure class. The four bootstrap runs install the command before the missing consumer script stops them. Several record-gap and revision-conflict logs also contain an installer warning that does not stop execution.
- No measured run shows engine/catalog feature skew or a stale hook-helper refusal. Those classes remain unmeasured. Required dependency settlement is now measured through the record gap, not inferred from an unrelated warning.

## Cancellations and pending runs

- All 45 private cancellations have no failed-step bytes. The supplied inventory puts them in its refused-log column. Empty stdout and stderr do not establish their cancellation cause.
- Accessible vsys cancellation 36492981581 also has an empty failed-step log. Its request exits 0. All 46 cancellation causes remain unclassified. None enters the failure numerator.
- Accessible vgs run 36351388231 remains `queued` with an empty conclusion in the original collection. Do not replace its recorded outcome with a later state.

## Raw row codes

Companion reports contain one row per run. Each row keeps its full UTC creation time, run URL, event, observed status/conclusion, class and exact evidence reference. Codes reduce repeated text, not the number of rows.

| Column | Codes and exact meaning |
| --- | --- |
| Event | D: repository_dispatch; M: workflow_dispatch; C: schedule |
| Outcome | F: completed / failure; O: completed / success; X: completed / cancelled; Q: queued / empty conclusion |
| Cause, original classes | P: publication-class; W: workflow-ownership; A: retired-agent-declaration; R: orphan-agent-record; B: consumer-bootstrap; L: publication-lease |
| Cause, additional classes | E: render-edited; I: install-record-gap; C: requested-revision-conflict; V: adoption-verification; D: repo-effects-unreadable; J: publication-queue; M: default-moved; N: remote-read; H: environment-read; T: release-download; S: publication-service |
| Cause, other outcomes | O: success; Q: pending; U: unclassified cancellation cause |
| Evidence | F: exact failed-step log path defined in that companion; X: supplied private cancellation member has no failed-step bytes; L: exact raw listing defined in that companion |

`RUN_ID` is the numeric last component of the row's URL. Thus accessible vsys run 36611715215 / F names `tmp/ken-2416-vsys-36611715215.log`. Accessible cancellation evidence F names its empty retrieved log, not a known cause.

## Evidence collection and retention

Accessible collection:

```bash
gh run list --repo vanillagreencom/CONSUMER --workflow kendex-refresh.yml --all --limit 1000 --json databaseId,attempt,createdAt,updatedAt,status,conclusion,event,headBranch,headSha,url,displayTitle
gh run view RUN_ID --repo vanillagreencom/CONSUMER --log-failed
```

Supplied private collection:

```bash
gh run list --repo vanillagreencom/CONSUMER --workflow kendex-refresh.yml --limit 1000 --created '2026-09-24T14:14:50Z..2026-10-01T14:14:50Z' --json databaseId,conclusion,status,createdAt,updatedAt,headBranch,event,displayTitle,url
gh run view RUN_ID --repo vanillagreencom/CONSUMER --log-failed
```

- Run evidence uses only these two GitHub CLI commands. The inventory does not supply run outcomes.
- Original accessible listings remain `tmp/ken-2416-CONSUMER-runs.{json,err,exit}`. Vsys's final listing is `tmp/ken-2416-vsys-all-runs.{json,err,exit}`. Its earlier listing remains retained.
- Accessible logs remain `tmp/ken-2416-CONSUMER-RUN_ID.log`, with `.err` and `.exit` companions. All 361 failure requests and the cancellation request return exit 0.
- Private listings are archive members `ken-2416-evidence/CONSUMER/runs.json`. Private logs are `ken-2416-evidence/CONSUMER/log-failed-RUN_ID.txt`; stderr is `log-failed-RUN_ID.err`. Every private failure has nonempty failed-step bytes. Success rows use listings only.
- `ARCHIVE!MEMBER` notation names an exact supplied archive member. It is not a path to the temporary extraction. Keep `tmp/ken-2416-control-evidence.tgz` and original scratch evidence when removing the extraction.
- `tmp/ken-2416-runs-in-interval.json` and `tmp/ken-2416-classified-runs.json` preserve the original accessible reductions. `tmp/ken-2416-combined-classified-runs.json` preserves all original row fields plus the private rows, class markers and expanded evidence references. These are data files, not measurement code.
- The supplied archive has 3376 members and 107562863 uncompressed bytes. The extraction rechecks space and member safety. It runs only under `tmp/` and refuses if less than 3 GiB would remain. The space check before extraction reports 18212655104 available bytes. Long work uses the existing orch job runner with `TMPDIR` and `ORCH_STATE_DIR` unset.
- Reduction uses one-off Python over supplied data. No saved collector, tool, script, watcher, setting or measurement dependency is added. Bundled archive code is not executed.
- Live source requirements and prior issue bindings remain in `tmp/ken-2416-issue-live.json`, `tmp/ken-2416-related-live.json` and `tmp/ken-2416-class-bindings-live.json`. The new scope ruling comes from the calling brief.
- Scratch evidence is not a tracked deliverable. The calling lane retains or attaches it. The public consumers' run URLs and observed rows remain in tracked companion reports. The index split satisfies the existing 64 KiB document class without truncating rows or changing its limit.

## Consumer refresh gate

[Consumer refresh](../../.github/workflows/consumer-refresh.yml) is the refresh gate. Its exact required-context name is `Consumer refresh`. [The inventory](../../.github/consumer-refresh-repos.txt) selects the measured current consumers. The job runs on pull requests and merge groups without a private-consumer credential. It runs each snapshot's committed refresh runner and manifest against both the base catalog and the proposed catalog. Git and GitHub publication use disposable repositories and the existing API fixture. A matching keyed baseline refusal reports `baseline-failure`, not a consumer pass. An unknown cause fails because the job cannot establish that the proposed catalog did not introduce it.

[Consumer snapshots](../../.github/workflows/consumer-snapshots.yml) reads committed inputs on main through the lanes app. It reads environment policy and secret names, never secret values. Collection executes no captured consumer code. `tools/lock-record --snapshot` lands the compressed input through the rolling `kendex/consumer-snapshots` pull request. The collector excludes source files that the refresh inputs do not select. The manifest's other private catalogs or external local sources are named collection failures because the secret-free gate cannot reconstruct them.

| Deployment step | Owner | Completion evidence |
| --- | --- | --- |
| Merge collector and gate | This pull request | Both workflows on main |
| Dispatch the collector on main | Orchestrator | Collector run URL and snapshot pull request number |
| Merge the snapshot rolling pull request | Overseer | Complete committed consumer inventory |
| Require `Consumer refresh` on main | Repository owner | Required-context ruleset change; KEN-2462 Done-when completes here |

Before any snapshot file exists, the job runs the passing consumer fixture and the KEN-2089 writer-template-removal control. It prints only `consumer-snapshot=absent` for real consumers and exits successfully. This bootstrap mode ends when any snapshot file exists. Empty, partial or unreadable snapshots then fail. The owner adds the required context only after the first complete snapshot lands. KEN-2462 stays In Review at the collector/gate pull request merge until that ruleset step completes.

The collector uses the existing `kendex` environment's `FLEET_GH_APP_ID` and `FLEET_GH_APP_PRIVATE_KEY`. Its consumer token requests Actions, Contents, Metadata, Environments and Secrets read access. Its separate publication token requests kendex Contents and Pull requests write access. PR and merge-group runs need neither secret. The supplied `tmp/consumer-snapshots-gen78.tgz` is test-only, captured on 2026-09-30 and a day old at handoff. It lacks talk and vg, committed refresh scripts and some recorded render paths. It does not become a production inventory or substitute for the scheduled collector.

`tools/tests/consumer-refresh.test.sh` reuses the review-gate consumer fixtures and pre-platform committed scripts. It runs real kendex against a disposable catalog. Its removal control deletes `skills/review-gate/templates/review-gate-writer.yml` from that catalog and requires the gate to report a regression. `tools/tests/consumer-snapshots.test.sh` checks complete platform collection. `tools/tests/lock-record-snapshot.test.sh` checks snapshot publication through the existing rolling-PR owner.

## Completion and gaps

KEN-2416 completes at this PR merge with the measurement and workflow/render edit preservation. Requirement 4 transfers after merge through Proposal to an owner-observed successor. The successor owns deployment evidence and the comparable consumer after-rate. It does not delay this PR's completion.

No failed run remains unclassified. No private consumer listing or local-run inventory gap remains under the supplied scope. Cancellation causes, private attempt/head SHA fields, exact acquisition timestamps and deleted history remain unavailable. No after deployment sample is supplied. Fixture proof and consumer after-rate remain separate evidence.
