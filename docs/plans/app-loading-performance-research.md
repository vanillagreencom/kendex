# App loading performance research

The Library takes 20.148 seconds to show complete content on a cold start in this fixture. The Packages table takes 3.597 seconds on return, although its data is already in memory. The Updates backend repeatedly hashes the same source snapshots. Its isolated request falls from 18.835 seconds to a median of 8.019 seconds when one command reuses its validated snapshots.

## Measurement boundary

| Input | Measured setup |
|---|---|
| App and CLI source | `764d51279982bc10417ff2234df1161478bcf86d`, a descendant of `ba2b98ff` |
| Host | Hosted Linux 6.19.14 lane; 4 AMD EPYC virtual CPUs; 7.8 GiB RAM; KVM |
| App | Release Rust build; production Vite bundle; native Tauri/Wry 0.55.1 and WebKitGTK 2.52.6; Xvfb without GPU acceleration |
| Project | Isolated, committed fixture at `a30bcab1cbc02d408a9abceeb5dc5609f245e8cd` |
| Installed catalog | All 61 offered kendex packages, delivered across supported harnesses; 406 scan observations; 400 renderings checked by verify |
| Subscriptions | All 3 marketplaces returned by the community directory; 4 scope subscriptions because kendex also has its default personal subscription |
| Offered rows | 622 across the scope subscriptions, including the same kendex catalog in personal and project scopes |
| Personal data | Isolated HOME and XDG directories; synthetic onboarding record; no signed-in account or saved templates/bookmarks |

| Marketplace | Source commit | Offered packages |
|---|---|---:|
| kendex | `901af3ae0188bdc0f0b39ac7142477cc2e600ee2` | 61 |
| vercel-labs/agent-skills | `063bee94c3f4df8453406c830b0a7df0f2860278` | 9 |
| wshobson/agents | `156b7a5e7a8b93642628a339ee4039c925b34c7f` | 491 |

This is an owner-sized installation pattern, not a measurement of the owner's desktop hardware. Absolute UI times include software rendering. The cache and repeated-read mechanisms are in the shipped code at the recorded source commit.

### Timing definitions

- **Cold:** new app process after Linux page, directory-entry and inode cache eviction. Installed files, source mirrors, materialized snapshots and persistent kendex caches remain. This is not a first-ever download.
- **Warm:** another new app process, immediately after the cold pass, without OS cache eviction. Zustand stores start empty again.
- **Return:** Settings, then the measured destination, in the same app process. This does not generate a window-focus event.
- **Content:** the first animation frame with no skeletons or covering modal and the final row/card count. Text-only views require the measured final text-length threshold. File and marketplace package tabs must be selected. The paged experiment also waits for every catalog result.
- **Settled:** the command and DOM observation after content. The Packages safety queue remains active beyond the 30-second observation window. A censored background queue is not reported as a completed read.
- **Backend:** a Rust command-body timer. The separate Tauri round-trip includes scheduling, serialization and webview work. It is not a network timer.

There is one cold/warm/return triplet per view: 54 valid cases across 18 views. CLI medians use 3 cold/warm pairs. Snapshot-reuse and history-projection comparisons have 3 repeated option reads. These are measured samples, not desktop service-level guarantees.

Native WebDriver controls the actual app. It does not replace the backend with mocked responses. Screenshots confirm the measured destinations. Initial samples covered by onboarding were rejected. The instrument now rejects a covering modal. Native driver startup failures were retried with fresh processes and ports; failed starts contribute no content timing.

The account read reports the fixture's missing desktop credential service. That error is separate from package reads. The installed catalog also produces an unknown-tag notice. Verify reports 400 checked renderings as OK and one subscription-record mismatch for `agents`. These are disclosed fixture conditions, not passing verification or new loading recommendations.

## Screen timings

Seconds from navigation to content. App-process creation and webview startup are recorded separately in the evidence. The Files route includes selecting its real tab as soon as the package page makes it available.

| View | Cold | Warm | Return |
|---|---:|---:|---:|
| Home | 2.572 | 1.531 | 0.020 |
| Library, installed | 20.148 | 18.385 | 0.378 |
| Marketplaces, subscribed | 1.757 | 1.054 | 0.022 |
| Marketplaces, Packages | 7.631 | 6.571 | 3.597 |
| Marketplaces, Community | 1.751 | 0.313 | 0.025 |
| Updates | 18.779 | 17.812 | 0.007 |
| Problems | 0.269 | 0.230 | 0.016 |
| Marketplace, Bundles | 1.387 | 0.301 | 0.018 |
| Installed package, Overview | 2.809 | 1.164 | 0.416 |
| Installed package, Safety | 5.066 | 4.724 | 0.033 |
| Library, Templates, empty | 0.236 | 0.242 | 0.030 |
| Library, Bookmarks, empty | 0.229 | 0.274 | 0.017 |
| Projects | 0.261 | 0.228 | 0.032 |
| Harnesses | 0.101 | 0.074 | 0.013 |
| Bundle members | 0.989 | 0.384 | 0.047 |
| Available package | 0.654 | 0.340 | 0.159 |
| Installed package, Files | 4.036 | 3.799 | 0.663 |
| Marketplace, Packages | 1.451 | 0.815 | 0.250 |

The current app has no separate Audit navigation route. `audit_all` supplies the standing audit, Home attention, Problems and package Safety. Their consumers are included above.

Most stores do keep results across navigation. The premise that every page discards its data is false at this baseline. The visible return and the backend return are also different: Updates shows retained content in 0.007 seconds, then runs another backend read taking 18.446 seconds. Home shows content before its startup work finishes; its cold settle reading is 21.406 seconds.

## Backend and I/O timings

The app does not launch the `kendex` executable for these reads. Tauri calls Rust functions over `kendex-core`. The CLI table measures corresponding public operations, not subprocesses that the screen invokes.

### Native command bodies

Milliseconds. A multiplier means separate calls in that navigation, not one combined response. Catalog totals sum command-body wall times and can overlap; they are not extra seconds to add to the screen table. A dash means no call on return.

| Command and measured consumer | Cold | Warm | Return |
|---|---:|---:|---:|
| `scan_machine`, Home | 158.964 | 87.375 | - |
| `audit_all`, Home | 5842.068 | 4709.796 | - |
| `updates_overview`, Updates | 18691.818 + 18901.850 | 17673.071 + 17926.666 | 18445.704 |
| `library_provenance`, Library | 951.447 | 560.675 | - |
| `marketplaces_overview`, Subscribed | 1654.747 | 958.884 | 725.425 |
| `marketplace_packages`, Packages | 10 calls, 3558.351 total | 10 calls, 4004.162 total | - |
| `community_directory`, Community | 1613.822 | 1.938 | 7.658 |
| `project_changes_scan`, Library | 5836.372 + 4703.069 | 5275.053 + 4302.676 | - |
| `package_files`, Files | 918.412 + 217.326 | 195.543 + 190.352 | 149.541 |
| `package_versions`, Overview | 206.177 + 265.872 | 238.127 + 185.406 | 250.500 |
| `package_meta`, Overview | 1009.065 + 338.677 | 212.517 + 257.438 | 316.991 |
| `get_settings`, Library | 0.141 + 0.041 | 0.134 + 0.173 | - |

The isolated backend run removes concurrent startup rendering from the comparison. It measures `scan_machine` at 105 ms round-trip, `audit_all` at 3844 ms, `library_provenance` at 392 ms, and `editor_inventory` at 243 ms. A cached community directory takes 9 ms; forced HTTP revalidation takes 235 ms; the next cached read takes 10 ms.

### Work inside Updates

One isolated backend body takes 18820.945 ms. These spans are inclusive. Nested rows must not be added together.

| Work | Calls | Total ms |
|---|---:|---:|
| Full source-checkout signatures | 66 | 9431.346 |
| Bind package to source coordinates, including those signatures | 61 | 9567.330 |
| Read up to 200 history records per package | 61 | 4932.987 |
| Resolve installed content commit | 61 | 886.500 |
| Produce the edit-detection plan | 1 | 3266.882 |
| Plan safety scoring, inside that plan | 1 | 1066.792 |
| Re-derive planned declarations | 1 | 142.294 |
| Parse catalog configurations | 128 | 25.427 |

`remote::store::published` verifies a receipt by hashing the complete checkout, then calls `Env::hold_checkout`. `package_ref_for` repeats that read for each package. The checkout contains the repository, not just the selected package. Parsing TOML is not the source of the measured delay.

### CLI operations

Seconds, median of 3 pairs. Input blocks are the Linux child-resource counter, kept in its native unit. Every warm pass reports zero input blocks. It still performs filesystem reads from the OS cache.

| Command | Cold | Warm | Cold input blocks | Exit |
|---|---:|---:|---:|---:|
| `kendex list` | 0.191 | 0.106 | 47136 | 0 |
| `kendex verify --scope all --json` | 4.712 | 3.400 | 359360 | 1 |
| `kendex updates` | 38.717 | 36.913 | 489896 | 0 |
| `kendex marketplace list --json` | 1.470 | 0.415 | 323480 | 0 |
| `kendex show skill orch --files` | 0.929 | 0.186 | 261184 | 0 |
| `kendex show skill orch --readme` | 0.862 | 0.159 | 261200 | 0 |
| `kendex bookmark list` | 0.042 | 0.010 | 40504 | 0 |
| `kendex template list` | 0.044 | 0.007 | 40200 | 0 |
| `kendex versions skill orch` | 1.027 | 0.229 | 350672 | 0 |

Verify's nonzero result is the disclosed subscription-record mismatch. It is not a timing failure. `check` was excluded from this comparison: it is not `audit_all` and starts a detached stale-source refresh. That diagnostic attempt was stopped and excluded from the final timings.

Separate `strace` passes do not supply the wall times above. Their tracing overhead is excluded.

| Operation | `read` calls | `openat` calls | `statx` calls | `getdents64` calls |
|---|---:|---:|---:|---:|
| List | 1160 | 647 | 3257 | 42 |
| Verify | 95299 | 60556 | 212707 | 24308 |
| Updates | 1428783 | 853916 | 1764716 | 263102 |
| Marketplace list | 23511 | 14809 | 32319 | 5734 |
| Show files | 10378 | 6095 | 12023 | 1758 |
| Versions | 10354 | 6028 | 10986 | 1758 |

The traced operations issue no `connect`, `sendto` or `recvfrom` calls. Updates records 4280 `execve` attempts, including 3890 failed PATH lookups; that is not 4280 successfully launched processes. Warm storage removes physical input, but not repeated hashing, parsing, directory traversal or Git work.

## Retention, invalidation and network policy

| Layer | Existing behavior | Measured consequence |
|---|---|---|
| Scan and provenance stores | Module-level Zustand data survives unmount. Scan generations invalidate provenance; overlapping reads have an in-flight/queued owner. | No scan or provenance request on ordinary Library return. |
| Audit store | Keeps its answer for 60000 ms. Writes and window focus force a fresh read. | Cached Safety return is 0.033 seconds; fresh audit still costs seconds. |
| Updates store | Keeps rows, but orders rather than coalesces requests. Startup and the Updates page both ask. The page asks on every mount. | Two native reads at startup and another 18.446-second read on return. |
| Catalog stores | Keep package, bundle, summary and About results by catalog key. Mutation generation invalidates them. Missing entries have no in-flight promise owner. | Four subscription keys cause 10 package-list calls as partial results update the effect. |
| Package detail | Component-local reads are recreated on mount. Editor metadata already has scope-keyed caches. | Files return costs 0.663 seconds and starts 8 requests. |
| Settings and project changes | Fresh settings objects also contain fresh equal project arrays. The root effect watches that reference. Project-change discovery derives a full plan. | Library startup runs two project-change plans despite unchanged project membership. |
| Mirrors and materialized checkouts | Reads use cached, receipt-verified snapshots. Refresh changes the mirror; retained snapshots are pinned for the invocation. | Normal subscribed browsing is offline, but receipt verification repeatedly reads the whole source tree. |
| Community directory | Existing on-disk generation, one-hour TTL, ETag revalidation and stale fallback. | 235 ms forced refresh, then 10 ms cached request. No replacement cache is indicated. |
| Pre-install scores | Persistent score cache verifies content hash, rule-set, discovery, allowance and format versions. UI queues a full preview for every mounted row and keeps only its safety result. | The 622-row table continues this work beyond the 30-second observation, including after navigation away. |

The community response includes package and bundle detail that its marketplace-card list does not draw. The measured cached return is 0.025 seconds. Removing that detail is not a supported explanation for the multi-second local waits. Subscribed repository browsing already avoids network fetches. App release-feed checks are separate startup work, not a source fetch on each package-list navigation.

## Measured defects and fixes

The costs below belong to different paths and overlap. They must not be summed into an overall saving. The TPM audit found an existing snapshot-validation issue and expanded it instead of creating a duplicate.

### CLI snapshot recomputes the report

- **Reach:** run `kendex updates` on the installed project.
- **Before:** 36.913 seconds warm. `updates_cmd::run` computes a report, then `snapshot::record` computes it again.
- **Existing option:** call `snapshot::record_with` with the report already held, as the app does. No new cache or invalidation rule is needed.
- **Measured option:** reuse takes 18.720, 18.591 and 18.472 seconds warm. The median is 18.591 seconds. Exit status, stdout and stderr match baseline in every pass.
- **Fix item:** `KEN-2251`.

### Updates navigation repeats a standing read

- **Reach:** open Updates, leave it, and return without changing the installation.
- **Before:** content returns in 0.007 seconds, but the backend runs for 18.446 seconds. Startup also starts two copies of that read.
- **Measured option:** a retained/coalesced unchanged-fixture response removes the return request. The return observation settles in 0.356 seconds instead of 18.775 seconds. Cold content does not improve.
- **Recommendation:** let the existing startup/rescan owner supply the standing answer. Keep explicit refresh, mutation and focus invalidation. Do not add a second page-owned freshness clock.
- **Fix item:** `KEN-2252`.

### One operation verifies the same snapshots repeatedly

- **Reach:** initial Updates and Library reads with the default catalog installed.
- **Before:** 66 full-tree signatures take 9431.346 ms in an 18.835-second isolated request.
- **Measured option:** operation-scoped reuse reduces signatures to 3. The three requests take 7.901, 8.019 and 8.349 seconds. Their complete JSON responses match baseline. Library cold content improves from 20.148 to 12.483 seconds; return does not improve.
- **Recommendation:** carry already-validated source handles through one read operation under the existing invocation/checkout owner. Preserve receipt verification, sealed reads, materialization-rule checks and retention pins. Revalidate on a new independent operation. Do not memoize trust globally by commit name alone.
- **Alternatives:** a catalog-config cache leaves Updates at 18.388 seconds against 18.309 seconds baseline. A longer-lived Tauri-state cache needs separate invalidation and has no demonstrated extra gain. Neither is selected.
- **Fix item:** `KEN-1859`, expanded rather than duplicated.

### Equal project arrays trigger another full plan

- **Reach:** Library startup loads settings from both startup and editor initialization. Settings publication replaces the equal project list, so the root effect asks for project changes again.
- **Before:** two project-change bodies take 5836.372 and 4703.069 ms on the cold Library path. The project is committed and clean. `generated` calls `plan_apply`; this is not just a Git-status read.
- **Measured option:** keeping the reference for equal project lists removes one startup request and gives 18.989-second cold Library content. Combined with operation-scoped snapshot reuse, content takes 11.043 seconds versus 12.483 seconds for snapshot reuse alone. JSON membership stays unchanged.
- **Recommendation boundary:** preserve reference identity for equal project membership without suppressing explicit focus or write-triggered refresh. Existing `rescanEverything` already requests those refreshes.
- **Fix item:** `KEN-2253`.

### Updates reads complete histories for a head comparison

- **Reach:** each installed package evaluated by Updates.
- **Before:** 61 subtree histories cost 4932.987 ms inside the native sample. The direct Git comparison takes a median of 3831.316 ms for up to 200 records per package.
- **Measured option:** requesting the latest record takes 987.137 ms across the same 61 paths. Latest SHA, date, subject and tags match for every path in all 3 passes.
- **Recommendation:** project only the current/latest facts that Updates displays. Preserve installed-version dates and tags, missing-history errors, first-parent semantics and literal path handling. Keep full histories for the Versions view. The experiment proves the latest projection, not every older-installed-version case.
- **Fix item:** `KEN-2254`.

### Packages mounts and scores rows outside the visible page

- **Reach:** open the Packages tab with every directory marketplace subscribed.
- **Before:** 622 rows; 7.631 seconds cold and 3.597 seconds on return. Safety preview work is still active at the observation limit.
- **Measured option:** 20 mounted rows with shared in-flight catalog requests produces 3.531-second cold content and 0.077-second return. All 622 data rows remain in the store. The intermediate first pages still queue 42 previews, so the prototype is not a complete demand-cancellation implementation.
- **Recommendation:** page the table and bind queued score demand to the rows actually needed. Drop queued work when its row leaves. Preserve whole-result filtering, sorting, selection and totals, plus install-time checks. Coalesce catalog reads in the existing catalog-read owner.
- **Alternatives:** coalescing alone changes 10 catalog calls to 4 and their summed body time from 3558.351 to 1438.904 ms, but does not improve visible content: 7.658 seconds cold. A safety-only command reduces the orch response from 35459 to 1639 UTF-8 bytes, but the paged view gives 3.411-second cold and 0.091-second return readings. No separate safety-endpoint change is selected on those page measurements.
- **Fix item:** `KEN-2255`.

### Package Files discards reusable reads on navigation

- **Reach:** return to the same installed package's Files tab without changing its source or scope.
- **Before:** 0.663-second content, 8 requests, 1.535-second settle.
- **Measured option:** retaining successful package and scope reads on the unchanged fixture gives 0.239-second content, 1 request and 0.578-second settle. Cold content changes from 4.036 to 3.750 seconds.
- **Recommendation:** extend the existing scope/package-keyed store pattern to these reads. Include source revision, scope, kind, name and file identity where each matters. Keep write, source-refresh and focus invalidation, failed-read state and mutation checks. This experiment does not authorize treating a stored result as current after an external edit.
- **Fix item:** `KEN-2256`.

## Platform choices and drops

| Option | Evidence and cost | Disposition |
|---|---|---|
| Keep Zustand results across unmount | Already works for most lists; measured returns of 0.020, 0.022 and 0.025 seconds for Home, Subscribed and Community. | Keep. No app-wide replacement store. |
| Reuse the editor-cache pattern | Scope-keyed caches and shared invalidation already exist. The Files retention experiment improves return to 0.239 seconds. | Use for the targeted Files fix. |
| Stale-while-revalidate | Retained Updates content already appears immediately, but its unnecessary return read still costs 18.446 seconds. Freshness and mutation authority must remain explicit. | Remove redundant demand before adding another refresh policy. |
| Tauri managed state | Tauri owns application-state lifetime, not filesystem freshness. Operation-scoped source reuse already measures 8.019 seconds without persistent trust. | No new application-wide cache in these fixes. |
| Inventory-hash-keyed result cache | Full hashing is itself the measured 9431.346 ms cost. A new cache must not repeat that work just to choose a hit. | No separate result-cache mechanism selected. |
| Persisted read model or database | Would need schema, invalidation and last-known/current rules. No validated timing gain beyond the measured retained-read and operation-reuse options; architecture currently keeps domain state in files. | Drop from this recommendation. |
| More background workers | The existing background queue keeps doing unneeded work after navigation. More concurrency does not reduce that work. | Drop; limit demand instead. |
| Backend pagination | The measured table can keep all 622 rows while drawing 20. A paged backend would also need whole-result search, sort and selection contracts. | Drop for this fixture; use the measured UI paging option. |
| Catalog-config cache | 128 parses cost 25.427 ms; no measured Updates gain. | Drop. |
| Network fetch removal | Subscribed reads are already offline; Community has its own measured TTL cache. | Drop as a loading fix. |
| Cache complete plans across commands | Project ownership, edit detection and advisory reads currently derive independent plans. No timing experiment validates shared-plan freshness. | Drop rather than prescribe an unmeasured cache. |
| Fixture onboarding, driver startup, account service and catalog notices | Onboarding and driver controls were corrected in the measurement harness. Other disclosed conditions are not linked to an identified loading delay. | No product fix filed from these measurement conditions. |

Zustand's documented async actions do not supply a query cache automatically. Its persistence middleware stores values; it does not establish source freshness. TanStack Query supplies query caching and background-refetch policies, but introducing it is unnecessary for the scoped fixes demonstrated here. The existing stores, core APIs, Git projections and browser table state provide the required extension points.

## Filed work

The audit creates 6 fixes and expands KEN-1859. All remain top-level and relate to KEN-2221. The new fixes are in Tech Debt & Bugs. KEN-1859 keeps its CLI & Distribution project, original refresh acceptance and KEN-1775 relation. The issue descriptions carry the detailed controls and measurement procedure.

| Issue | Work | Role / estimate | Measured acceptance |
|---|---|---|---|
| [KEN-2251](https://linear.app/vanillagreen/issue/KEN-2251) | CLI report reuse | `agent:rust` / 1 | Warm median 36.913 s to at most 20 s; 3 primed runs, identical output and one evaluation. |
| [KEN-2252](https://linear.app/vanillagreen/issue/KEN-2252) | Updates request ownership | `agent:generalist` / 1 | Unchanged return: 18.446 s backend work to no request; one startup request; native trace and refresh controls. |
| [KEN-1859](https://linear.app/vanillagreen/issue/KEN-1859) | Validated snapshot reuse | `agent:rust` / 3 | 18.835 s to at most 9 s median; 66 signatures to the 3 unique snapshots; equal JSON and independent-operation revalidation. |
| [KEN-2253](https://linear.app/vanillagreen/issue/KEN-2253) | Stable project membership | `agent:generalist` / 2 | Two startup project scans to one; remove the redundant 4.703 s body; equal/changed settings and explicit rescan controls. |
| [KEN-2254](https://linear.app/vanillagreen/issue/KEN-2254) | History projection | `agent:rust` / 2 | 61-path query median 3.831 s to at most 1.2 s; compare current/latest values and preserve full Versions history. |
| [KEN-2255](https://linear.app/vanillagreen/issue/KEN-2255) | Bounded table and score demand | `agent:generalist` / 3 | Cold/return 7.631/3.597 s to at most 4/0.1 s; keep all data, bound mounted rows, cancel obsolete queue entries and coalesce catalog reads. |
| [KEN-2256](https://linear.app/vanillagreen/issue/KEN-2256) | Files read retention | `agent:generalist` / 2 | Return 0.663 s to at most 0.3 s, settle within 1 s; eliminate repeated reads and test invalidation. |

Rust changes use the Rust specialist. React changes use the available generalist role. Estimates separate the local request-ownership changes from the source-lifetime and table-demand changes. The fleet selects each runtime model at launch from those assignments.

The comparison audit's unrelated cancellation suggestions for KEN-1863 and KEN-2205 are dropped from this execution: they are outside the measured-loading contract. No unrelated tracker issue is canceled.

## Reproduction and evidence

[Measurement evidence archive](https://uploads.linear.app/09589536-0763-447e-a0ed-6d9bf346d4cc/6c0f0330-f4c7-4da5-8c41-ba5d3b8ec3f1/b072c766-5746-4f71-9f8e-cf50e50362bc), attached to KEN-2221 as `tmp/research/app-loading-performance-evidence.tar.gz`. The archive contains 369 files. Validation checks the 54 screen records, referenced artifacts and JSON syntax. No current environment-secret value was found in its text files.

The evidence includes the fixture setup commands, source revisions, temporary instrumentation patches, native WebDriver client, per-frame and per-command results, screenshots, source-validation comparisons, CLI output comparisons and syscall summaries. It excludes the fixture's downloaded source trees and installed binaries. All temporary source edits are removed before the report commit.

Run the attached scripts from the same repository baseline under `tmp/research/`. `run-env.py` owns the isolated HOME/XDG directories and fixture project. The native build uses `cargo build --release -p kendex-app -p kendex-cli --features tauri/custom-protocol` after the production UI build. `ui-timings.py` runs the screen matrix; `hash-calls.py`, `ui-options.py`, `settings-options.py`, `cli-timings.py`, `cli-reuse-timings.py` and `history-timings.py` own their named comparisons. Run them sequentially, without a build or another timing job competing for the host. The saved patches are measurement-only, not proposed production implementations.

### Sources

- Repository contracts: [architecture](../architecture/overview.md), [source store](../architecture/sources.md), [registry](../architecture/registry.md), [engine](../architecture/engine.md).
- Source verification and ownership: `crates/core/src/remote/store.rs::published`, `remote/store/signature.rs::tree_signature`, `Env::hold_checkout`.
- Update work: `crates/core/src/package/updates.rs`, `package/updates/eval.rs`, `package/mod.rs::package_ref_for`, `remote/history.rs`.
- CLI repeat: `crates/cli/src/commands/updates_cmd.rs::run`, `crates/core/src/drift/snapshot.rs::record` and `record_with`.
- UI demand: `ui/src/App.tsx::useStartupLoads`, `stores/updates-standing.ts`, `stores/settings.ts`, `stores/editor-cache.ts`, `stores/marketplaces-catalog-reads.ts`, `stores/preinstall-safety.ts`, `components/marketplaces/packages-tab.tsx`, `packages-table.tsx` and `package-row.tsx`.
- [Zustand async actions and persistence](https://github.com/pmndrs/zustand/blob/main/README.md), [Tauri managed state](https://v2.tauri.app/develop/state-management/), [Tauri native WebDriver](https://v2.tauri.app/develop/tests/webdriver/manual-setup/), [TanStack Query](https://tanstack.com/query/latest).
