# Findings: Linear official routes

## Research Question

Which parts of `skills/linear` have a measured advantage over an available official Linear route for issue audits, roadmap and cycle planning, lane start and close, and overseer watch?

## Executive Summary

The measurements do not establish a keep case for any part of `skills/linear` against direct application-actor GraphQL. Recommend retirement of each part under the issue's evidence rule, subject to owner approval. This is absence of a measured deficit, not proof of full workflow parity. Application GraphQL closes the requested data page chains in repeated reads. Official MCP does not return the required fields in several measured workloads. A stale cache cannot establish an advantage over fresh, complete data. [M]

The report covers data retrieval and completeness checks. It does not measure model decisions, actual consumed context, or real lifecycle-close writes. Directive `1790807933-3275829-20258` authorizes these quota-bounded gaps. It permits at most 11 additional local HTTP starts after control evidence arrives. Two complete local cycle repeats use 10. The original all-cell, end-to-end experiment remains unsatisfied. [M]

### Workflow by route

All numbers below come from [M]. Each pair gives the individual repeated samples, not an average. Wall time is milliseconds through data validation. Payload tokens equal raw input plus raw output. They exclude static text. **Consumed model context is unknown in every cell.** HTTP starts and backend GraphQL requests are separate columns because MCP does not expose its backend count.

| Workflow | Route | Wall ms, repeats | Raw payload tokens, repeats | HTTP starts, repeats | Backend GraphQL requests | Completeness and scope |
|---|---|---|---|---|---|---|
| Issue audit | CLI warm cache | 5324.901; 5104.389 | 5128008; 5128008 | 0; 0 | 0; 0 for these reads | Stale: 2280 issues, 6014 comments. Not complete current data. |
| Issue audit | Application GraphQL | 93947.597; 80343.445 | 5239130; 5239130 | 50; 50 | 50; 50 | Closed required page chains: 2281 issues, 6041 comments. Independent issue IDs agree. |
| Issue audit | Official MCP issue-list subset | 23485.651; 17655.908 | 739346; 739306 | 17; 17 | Unknown | 2281 issue IDs agree with GraphQL. Comments and issue relations not fetched. Full audit is quota-gated. |
| Issue audit | Official skills | N/A for equal full audit | Unknown | Not run | Unknown | `stale-labels` audits labels, not the required full backlog and comments. |
| Roadmap planning | CLI warm cache | 4381.430; 4305.660 | 1754250; 1754250 | 0; 0 | 0; 0 for these reads | Stale: 1849 issue rows. No current field-equality proof. |
| Roadmap planning | Application GraphQL | 9309.349; 22730.158 | 2222572; 2222572 | 22; 22 | 22; 22 | Closed requested chains: 1849 issues, project content and dependencies, metadata. No model plan. |
| Roadmap planning | Official MCP | Missing; missing | Missing; missing | Not started | Unknown | Each planned repeat needs up to 15 starts; only 11 control starts remained. No project dependency-read tool. |
| Roadmap planning | Official skills | N/A in inspected inventory | Unknown | Not run | Unknown | No equal roadmap workload in the inspected published skills. |
| Cycle planning | CLI warm cache | 2506.670; 2154.258 | 32450; 32450 | 0; 0 | 0; 0 for these reads | Stale: 21 project issues, 7 cycles. No freshness proof. |
| Cycle planning | Application GraphQL | 1929.321; 1806.217 | 40657; 40657 | 5; 5 | 5; 5 | Closed requested chains: 21 issues, 7 cycles with histories, project dependencies and metadata. No capacity decision. |
| Cycle planning | Official MCP | 3527.257; 3457.887 | 12880; 12880 | 5; 5 | Unknown | Issue and cycle IDs agree. Issue relations, project content and dependencies absent. Default labels are workspace-only. |
| Cycle planning | Official skills | N/A in inspected inventory | Unknown | Not run | Unknown | No equal cycle-planning workload in the inspected published skills. |
| Lane start, read phase | CLI warm cache | 700.591; 727.438 | 1321; 1321 | 0; 0 | 0; 0 for these reads | Stale root bundle. No current lifecycle guarantee. |
| Lane start, read phase | Application GraphQL | 1117.669; 517.621 | 2128; 2128 | 3; 3 | 3; 3 | One root, no parent, children or comments; requested connections closed. |
| Lane start, read phase | Official MCP | 2340.308; 2999.022 | 1892; 1892 | 3; 3 | Unknown | Same root and relation/comment counts. Parent and sort order absent from returned issue. Ancestor safety is not independently established by MCP. |
| Lane start | Official worker skill | Missing full skill clocks | Unknown | Not run as a skill | Unknown | Worker intake uses `get_issue`. The MCP lane cell adds child/comment reads beyond that intake. It is not a worker timing. |
| Lane close | CLI/cache, application GraphQL, MCP, official worker | Missing on every route | Unknown | No close run | Unknown | No summary mutation, state transition, no-op write or completion validation workload measured. Lane-start reads cannot substitute for close. |
| Overseer watch | Current-main live CLI | 1979.541; 2381.872 | 220452; 220452 | 2; 2 | 2; 2 | 25 active, 127 new IDs agree with local GraphQL. Nested continuation proof missing. |
| Overseer watch | Application GraphQL | 1400.046; 2238.867 | 195336; 195336 | 2; 2 | 2; 2 | 25 active, 127 new. Required connections closed. |
| Overseer watch | Official MCP | 3598.305; 2166.339 | 51805; 51805 | 3; 3 | Unknown | 26 active, 127 new. State changes between cuts explain the active count difference. Relations absent. |
| Overseer watch | Official poller skill | N/A for equal watch | Unknown | Not run as a skill | Unknown | A capped, label-filtered Triage queue is not the full active/new watch. |

The separate poller read proxy returns 9 Triage issues. Its samples are 883.964 and 665.315 ms, 2760 payload tokens each, and one HTTP/tool call each. It uses cap 50 and omits the configured label because no poller configuration exists in this workspace. It does not measure the configured skill or the overseer watch. [M]

### Local direct-API controls

These personal-key reads run on the same hosted worktree as the CLI. They help separate local shell/cache behavior from control-host behavior. They do not replace the application actor column. [M]

| Workload | Wall ms | Payload tokens | HTTP/backend requests | Limits |
|---|---|---|---|---|
| Audit, two assembled repeats | Missing; missing | 5220783; 5220783 | 49; 49 | Closed issue/comment chains after separate continuation. 2281 issues, 6037 comments. No continuous clock. |
| Roadmap, two original corrected reads | Missing; missing | 2208421; 2208421 | 21; 21 | 1850 issue rows at an earlier cut. Original canonicalizer fails after retrieval. No complete clock. |
| Cycle, two original corrected reads | Missing; missing | 37154; 37154 | 5; 5 | Data reconstructed after canonicalizer failure. No complete clock. |
| Cycle, final repeats 3 and 4 | 935.934; 983.488 | 37155; 37155 | 5; 5 | Complete requested reads, 21 issues and 7 cycles with histories. Both repeats have equal field hashes. |
| Lane read | Missing; 549.889 | 2128; 2128 | 3; 3 | First clock lost to shared tokenizer input failure. No decision or write phase. |
| Watch | 1038.143; 1677.839 | 192175; 192175 | 2; 2 | 25 active, 127 new. Requested connections closed. |

Local labels contain 47 rows. The application query returns 85. MCP without a team returns 40 workspace labels. A separate MCP `team: KEN` control returns the same 47 workspace-plus-KEN labels as the local API. The remaining 38 labels belong to other teams and were not fetched through MCP. These scopes are not equal complete workspace metadata. [M]

## Key Findings

- Direct GraphQL does not require a cache to retrieve all pages. The application audit returns 2281 distinct issue IDs and 6041 comments in each repeat. The independent paged ID control agrees. The size-2 control returns three IDs over two pages. The issue's historical concern about partial results does not establish a current API failure when the caller follows every cursor. [M] [S2] [S3]
- Repeated direct reads still cost requests. Each application audit costs 50 and each roadmap read costs 22. Cache reads cost none during the measured warm phase, but the saved snapshot is stale. Cache population and refresh costs are missing. No equal fresh workload establishes a net cache saving. [M]
- The measured MCP schema exposes 76 tools. Exactly 41 have literal `annotations.readOnlyHint: true`; 35 have `false`; none omit the field. This rule classifies annotations, not whether every execution of a false-annotated tool changes data. The discovered schema contains no project dependency-read tool. [M]
- MCP issue-list equality is not audit completeness. The measured mapping needs at least 4579 HTTP/tool starts for a full repeat: 17 list calls, 2281 per-issue relation reads, and at least 2281 per-issue comment reads to establish empty threads as well as populated ones. The full run never starts. This is a quota/completeness deficit under that mapping, not measured full-audit latency or proof about hidden backend requests. [M]
- MCP's shorter payloads omit required fields. A smaller response cannot prove a context advantage over complete GraphQL results. Neither client sends its private raw rows into a model; it prints aggregate summaries. Actual context consumption remains unknown. [M]
- Linear publishes official skill files in `linear/linear-solutions`. The inspected skills are label audit, issue worker, triage poller and triage setup. They use MCP tools, not a separate transport. None supplies the issue's complete audit, planning, lifecycle and watch contract as a measured replacement. [S6] [S7] [S8] [S9]

## Evidence and Sources

### Measurement methods

| Method | Exact definition and limit |
|---|---|
| Baseline | CLI and consumer definitions come from main `8d95c78d7bcf144dfab70a2958ea5e5dc6646268`. The frozen client SHA-256 is `f1162c1b8efe4bb5b0ebb21d03d966620c08861ac39bc220c7fe6ad738d74385`. Public queries and workload definitions persist in [M]. |
| Workload consumers | Audit uses `tpm-audit.md`; roadmap uses `tpm-roadmap-plan.md`; cycle uses `tpm-cycle-plan.md`; lane uses `start.md` and `workflow-actions.md`; watch uses `oversee-watch-text.sh`. These define required reads, not measured model reasoning. [C] |
| Audit scope | Team KEN, nonarchived issues, Backlog/Todo/In Progress/In Review/Done/Canceled; all matching issue comments; issue labels and both relation directions; teams, labels, projects and cycles. CLI audit also repeats active-issue/comment reads before its complete comparison read. Payload shapes and repeated prefixes differ. [M] |
| Planning scope | Roadmap excludes Canceled and includes origin context, project content/order and dependencies. Cycle uses the first started project ordered by sort order then UUID. It includes full cycle scope/completion histories, all project issues and both project-dependency directions. The 20 dependency rows are project/direction containers, not 20 distinct edges. Each GraphQL control returns one forward edge and one inverse representation. [M] |
| Lane/watch scope | Lane reads the root and recursively its parents/children plus comments and relations. The observed root has no parent, children or comments. Watch reads In Progress/In Review plus issues created since `2026-09-30T00:00:00Z`. The CLI fetches a rolling day and then applies the same floor. [M] |
| GraphQL clock | Python monotonic time before the first workload read through final canonical aggregate validation. It includes HTTP, parsing, page checks and validation. It excludes the later tokenizer calls. A failed or separately resumed workload has no complete clock. [M] |
| CLI clock | Monotonic time through command execution and aggregate validation. It includes shell process launches, local cache reads, `jq`, and live calls where used. Tokenizer runs after the clock. [M] |
| MCP clock | The control driver records elapsed retrieval/validation time. Its saved `wall_note` names included driver/process work. This is not a full model workflow clock. MCP discovery is separate. [M] |
| Tokenizer | npm `tiktoken` 1.0.22, `cl100k_base`, `encode(text, [], [])`. Count each exact serialized request and raw HTTP reply. For CLI, count command/standard-input text plus standard output and error. Sum input and output; never divide bytes by a constant. Tokenizer tarball SHA-256 is `55c339e756fdb17604f7c7e3eb35d2bcbffe4d960e8096e50285d1cefa51dd90`. [M] |
| Token correction | Original overlapping counts share a temporary input file and are invalid. Offline recounts use unique input files and replace those counts only. They do not repair a missing clock or establish billed/model-consumed usage. [M] |
| Pagination | GraphQL issues/comments/teams/labels use `first: 250`; projects/cycles use 50. Embedded collections start at 10. Open nested collections continue separately at 250. Stop only on false `hasNextPage`; reject missing/repeated cursors and duplicate IDs. Each list chain and relevant nested chain is checked. MCP uses its top-level continuation fields; cycles return seven rows without a pageInfo contract. [M] [S3] |
| Identifier hashes | SHA-256 of sorted IDs or identifiers in compact sorted-key UTF-8 JSON. Canonical field hashes remove pageInfo, sort connection rows by ID, and preserve time-series array order. Field equality is asserted only for compatible shapes and cuts. MCP/GraphQL field hashes are not comparable directly. [M] |
| Request journal | Append a start before each send under a shared lock. Append status/headers on finish. Both journals have unique contiguous sequence numbers and matching finish counts. Count by route/run records, not a global counter delta while another route runs. No new cycle retry is authorized. [M] |
| Final local cycle | Import the unchanged frozen client. Set the local total ceiling to 220 only after journal reconciliation. Override the reservation to five starts for the observed complete cycle workload. If a new continuation needs another start, the run refuses. Two complete repeats finish within the reservation. [M] |
| Persistent evidence | [M] stores sample clocks, token components, counts/hashes, compressed page-check evidence, query definitions, per-run request sequences, setup limits and inventory. The skills sidecar stores the complete public MCP discovery schema. Private responses, private IDs/text, credential values and the cache remain untracked. Aggregate arithmetic survives scratch removal; replay requires authorized current data. |

### Hosts, actors and data cuts

- The local lane uses the personal key for Brad Mahaffey. The control-host authorization supplies application and MCP evidence even though those routes do not run from the lane; the original same-lane condition remains unsatisfied. The control VM uses a supplied OAuth `client_credentials` application token. The GraphQL viewer answers with name `vanillagreen agents`. Its frozen query selects ID/name/email, not actor type. Application classification comes from the supplied token class and app-user attribution, not a returned type field. [M] [S4] [S5]
- MCP uses the same supplied token. No independent MCP viewer query runs. The actor attribution is therefore not independently verified through MCP. [M]
- Local request-start timestamps range from `2026-09-30T21:50:32.722249+00:00` to `2026-09-30T22:44:14.062567+00:00`. Control request-start timestamps range from `2026-09-30T22:26:09.256474+00:00` to `2026-09-30T22:35:00.600478+00:00`. Finish records copy the start timestamp; their `at` field is not response-receipt time. Separate hosts and cuts prevent a transport-only latency claim. [M]
- The cache reports `synced_at: 2026-09-30T13:59:59-07:00` and `reconciled_at: 2026-09-30T13:57:05-07:00`. The experiment isolates a copy of that pre-existing snapshot. Its stored population duration does not measure this experiment's cold cost. [M]
- The cache audit has 2280 issues and 6014 comments. Local live audit has 2281 and 6037. Later application audit has 2281 and 6041. The cache is stale. The comment change between live cuts is not evidence of a transport omission. The roadmap's 1849/1850 differences also use different cuts. [M]
- MCP watch has 26 active issues after one issue changes from Backlog to In Progress at `22:32:48Z`. GraphQL's earlier watch has 25. New-issue counts agree at 127. The active-count difference is a live state change, not a transport defect. [M]

### Request budget and setup

| Account | Exact HTTP starts | Accounting limit |
|---|---|---|
| Local personal GraphQL | 214 | Includes failures, controls, continuations and final cycle clocks. |
| Local current-main CLI | 5 | Includes the failed watch instrument attempt. Cache-only reads contribute none. |
| Local total | 219 | 219 finishes. Ceiling 220 after authorized transfer. One start unused. |
| Control application GraphQL | 177 | Includes viewer and independent controls. |
| Control official MCP | 63 | Includes discovery, one failed driver attempt and team-label control. Backend requests unknown. |
| Control total | 240 | 240 finishes. Finished control allocation; no more sends. |
| Combined measurement | 459 | Exact starts, not an inferred shared rate-window balance. |
| Uninstrumented preparation | Unknown | Conservative allowance 9. Never label it observed spending. |
| Close-out | Not spent in this phase | Keep the 30-start reserve. Parent publishes owed tracker writes. |
| Measurement plus allowances/reserve | 498 | Cap 500. Maximum if the last permitted local start is used is 499. No new allocation. |

Control has no failed HTTP status, retry or actual rate-limit result. Local has six HTTP 400 schema errors and 213 HTTP 200 replies. The schema errors are client experiment failures. The false rate-limit watch stop matches a word in issue text; the corrected instrument checks `errors[].extensions.code`. The MCP cycle driver expects a team key that its tool does not return. Its failed attempt costs one successful HTTP request and stays in the journal. These are not official-route defects. [M]

Local response headers show request limit 2500 and complexity limit 3000000. Control application headers show 5000 and 2000000. The provider's HTML rate page states the 2500 personal-key limit. Its `.md` text says 5000 in a paragraph but retains 2500 in the table. Use the observed header for this experiment, not the conflicting prose. Header balances are per credential/window and are not a cross-host shared budget ledger. [M] [S10]

MCP discovery takes three HTTP starts for initialize, initialized notification and tools/list. It completes with 76 tools, no session header, and protocol `2025-03-26`; its process clock is 1863 ms. The app viewer costs one start. Control tokenizer pack/extract provisioning costs 956 ms, separate from workload clocks. The supplied app token's earlier mint cost, local tokenizer provisioning clock, cache population and live refresh/reconcile costs remain unknown. [M]

### Static payload context

Static values below are tokenizer counts of exact saved text, not observed model consumption. Add them only if the actual host loads that text. No measured host context receipt establishes that every schema or instruction reaches a model. [M]

| Text | Tokens | Coverage |
|---|---|---|
| Local Linear skill | 3374 | Saved skill text; separate from workload payload. No consumed-context receipt. |
| Audit / roadmap / cycle instructions | 8892 / 2110 / 1511 | Consumer files; not another transport's unique overhead. |
| Lane-start / workflow-actions instructions | 1461 / 961 | Consumer files; workflow reasoning excluded. |
| Official stale-labels / worker / poller / setup | 1413 / 1969 / 830 / 702 | Pinned public skill text; skills not executed. |
| All discovered MCP tool entries | 25259 | Name, description, input schema and annotations. This applies only if the host presents all tools. |
| MCP audit / roadmap / cycle subsets | 2796 / 2498 / 1994 | Hypothetical host filtering to the recorded workload subset; not observed host behavior. |
| MCP lane / watch / poller subsets | 1610 / 808 / 808 | Same restriction. Discovery raw output tokens include more than this serialized schema text. |

The multi-million-token audit payload counts are potential costs of supplying those raw data. They are not tokens actually consumed by the model. The clients retain private data and print short aggregate summaries. No comparison treats a full raw backlog on one route and a short summary on another as equal context input. [M]

### Cache origin and current protections

| Concern or protection | What the baseline does | Evidence, impact and limit |
|---|---|---|
| Partial API results | Live `--max` follows cursors. GraphQL documents a default first page of 50. | The app's complete audits and forced paging control show that the official API supports all required pages. A caller that stops at a default page omits backlog rows every time its result exceeds that page. This is caller behavior, not a reason that a cache must exist. [M] [L1] [S3] |
| Repeated retrieval | Cache serves repeated reads without HTTP. Sync updates it. | Warm reads use zero requests. A fresh app audit uses 50 per repeat. The stale snapshot and missing refresh costs prevent an equal fresh saving claim. Repeated uncached full audits spend quota on every run. [M] [L2] |
| Default 75 warning | Cache and live list default to 75 and warn when truncated; live `--max --limit` pages under a 200-page cap with a warning. | Two cache controls each return 75 and warn. Neither is a complete audit. An agent that ignores the warning misses rows when more than 75 match. The full direct GraphQL control closes its chains instead. [M] [L1] |
| `sync --reconcile` | Reconciliation checks cached issue IDs against current API results and removes stale records; sync separately retrieves complete comment threads. | It protects consumers from deleted or archived records that incremental merging can retain. This round runs no sync. It cannot prove reconciliation cost, reliability or present freshness. Direct current reads avoid that saved-copy failure class; their comparison is not a reconciliation test. [L2] [M] |
| Team-target refusal | No configured team means writes refuse before an API call. `auth-check --strict` checks the selected credential and target. | It reduces wrong-tracker writes when a key reaches a different workspace. A local target is not an API permission restriction. Write outcomes and guard timing are unmeasured. No measured official GraphQL deficit supports keeping the Bash check. [L3] [M] |
| Create-time reach checks | Settings can require a non-placeholder `Reached by:` line and a `Symptom:` line for review-born priority-2 items. | It refuses missing evidence before a create call. It does not judge whether the prose is true. Risk occurs when a caller files without the required line. No official-route create control is measured. [L4] [M] |
| Agent-label and label preflight | Configured creates require an agent label; workflow instructions read inventory and build the full final label set, rejecting unknown/group labels and exclusive conflicts. | It prevents configured creates without routing labels and prevents callers from replacing labels with an incomplete set when they follow the workflow. No live create or label write measures equivalence. [L1] [L4] [L5] [M] |

The issue supplies the original cache concerns: partial results and repeated queries. This experiment tests those mechanisms; it does not recover an original benchmark. Commit-bound cache/sync code establishes current behavior, not historical performance or a reproduction of the related sync incidents. [L2] [M]

### Source register and audit

- [M] is the sanitized local/control evidence, not a web-provider finding. It includes failed runs and authorized missing measurements. The raw workspace payloads remain private.
- [S1] documents Streamable HTTP at `https://mcp.linear.app/mcp`, direct bearer authorization, and a `/readonly` endpoint. It does not establish hidden MCP backend GraphQL request counts.
- [S2], [S3] and [S10] describe GraphQL authentication, paging and rate limits. [S4] and [S5] describe client credentials and application attribution. They explain interfaces; they do not supply the measured workload timings.
- [S6] through [S9] are published files in Linear's own repository pinned to `4529f1e807d19e25f3c3889737f5b4bf90c242fe`. They establish instructions, not execution results.
- The standard Exa result list contains 19 sources. The follow-up lite list contains 9. The audit excludes a community issue as an official contract, a proposed pull request as a published interface, a duplicate MCP page as independent evidence, and Linear Agent/Loops pages as external-agent skill proof. OpenAI, JetBrains copies and third-party packages do not establish Linear ownership. The release/CI skill has a different purpose. [R]
- The follow-up Exa brief does not retrieve the pinned triage files. Direct authoritative file reads establish their scope. The worker reads one issue and later comments and moves it to review. The poller reads a capped, configured-label Triage queue, then claims and delegates issues. Setup creates a label and schedule. None of those write/delegation instructions executes in this research. [S7] [S8] [S9]
- An empty decision search for KEN-2319 supplies no existing issue-specific decision. This report requests approval; it does not create an architecture decision record. [M]

## Tradeoffs / Alternatives

| Route | Observed value | Cost or unresolved limit |
|---|---|---|
| Direct application GraphQL | Repeated complete requested data retrieval; observable request/complexity headers; project dependency fields available. [M] | The caller must construct queries and follow all page chains. Model decisions and lifecycle writes remain unmeasured. [S2] [S3] [M] |
| Official MCP | Hosted authenticated tools; issue IDs can match a complete direct list; specific worker intake fits a narrow issue read. [S1] [M] | The measured tools omit required fields. Full audit exceeds this experiment's HTTP budget under the mapped approach. Backend count is unknown. No measured project dependency-read tool. [M] |
| Official skills | Published instructions for specific label and triage workflows. [S6] [S7] [S8] [S9] | They do not define an equal measured replacement for the required workload set. They add instructions over MCP rather than another data route. [M] |
| Existing CLI/cache | Zero HTTP during measured warm cache reads; source-defined local guards and workflow helpers. [M] [L1] [L5] | Snapshot stale, refresh cost missing, live nested completeness unproved. No measured deficit of fresh application GraphQL establishes a keep. [M] |

## Recommendation / Decision Criteria

Recommend direct application-actor GraphQL for the measured retrieval requirements. Recommend retirement of each custom part below under KEN-2319's rule. The reference comparison is the available official GraphQL route, not MCP alone. MCP-specific deficits do not prove that GraphQL is worse. All retirement entries are approval requests, not removal instructions. [M]

**Decision rule**: keep requires an observed official-route deficit on an equal complete workload, or a precisely bounded measured capability the official tool cannot expose. Otherwise recommend retire. A missing comparison is absence of proof, not proven parity. The observed field omissions justify declining MCP as the sole route for these reads; they do not justify keeping custom Bash instead of direct GraphQL. [M]

### Per-part recommendations

The command inventory comes from the measured baseline. Supported verbs below include aliases; refused spellings appear separately. Each row's deficit statement applies to all listed verbs. Read observations do not establish untested mutation or helper parity. [M] [L1] [L2] [L3]

| Part and actual verbs | Recommendation | Official GraphQL deficit and evidence |
|---|---|---|
| `auth-check.sh`: auth-check, strict mode | Retire | None measured. App viewer verifies the supplied actor's identity fields; local target/write-safety equivalence unmeasured. [M] [L3] |
| `cache-query.sh`: issues list/get/bulk-get/children/list-relations/relations/list-comments; projects list/get/list-dependencies/dependencies; comments list/bulk-list; labels list; initiatives list/get; cycles list; attachments list/fetch/stats; cache status | Retire | None measured on equal fresh data. Warm audit, planning and bundle reads are stale. Attachment retrieval, initiatives and cache administration unmeasured. [M] [L2] |
| `comments.sh`: list/create/update/delete | Retire | None measured. Application audits retrieve complete comment chains. Comment mutations unmeasured. MCP's per-parent comment interface is not a GraphQL deficit. [M] |
| `cycles.sh`: list/create/update | Retire | None measured. Complete seven-cycle histories returned in repeated direct reads. Create/update and model assignment decisions unmeasured. [M] |
| `documents.sh`: list/get | Retire | None measured; these verbs are unmeasured. No parity assertion. [M] |
| `initiatives.sh`: list/get/create/update/delete/add-project/remove-project | Retire | None measured; these verbs are unmeasured. No parity assertion. [M] |
| `issues.sh` reads: list/get/bulk-get/children/list-relations/relations | Retire | None measured against complete application reads. Live CLI watch has no nested continuation proof. Other read branches and recursive nonempty bundles remain unmeasured. [M] [L1] |
| `issues.sh` mutations: create/update/bulk-update/archive/trash/delete/add-relation/remove-relation | Retire | None measured; no real mutation comparison. Local validation, attachment and partial-bulk behavior require owner acceptance of this evidence gap. [M] [L1] |
| `issues.sh` lifecycle: activate/block/unblock/complete/validate-completion | Retire | None measured; start/close mutations and summary verification unmeasured. A complete root read does not prove lifecycle parity. [M] [L5] |
| `labels.sh`: list/create/update/delete | Retire | None measured. Actual team-scoped MCP control matches local 47 labels; application API also exposes other-team labels. Definition/assignment writes unmeasured. [M] |
| `milestones.sh`: list/get/create/update/delete | Retire | None measured; these verbs are unmeasured. No parity assertion. [M] |
| `project-labels.sh`: list/create/update/delete | Retire | None measured; these verbs are unmeasured. No parity assertion. [M] |
| `projects.sh`: list/get/create/update/delete/list-dependencies/dependencies/add-dependency/remove-dependency/post-update/list-updates/reorder/set-sort-order | Retire | None measured against application GraphQL. Planning reads include project content/order and both dependency directions. MCP has no dependency-read tool, but direct GraphQL does. Writes, updates and reorder decisions unmeasured. [M] |
| `session-status.sh`: session-status | Retire | None measured; aggregate start-status command unmeasured. Root read is not a session-status benchmark. [M] |
| `statuses.sh`: list/get | Retire | None measured; separate status-tool workload unmeasured. Known-state filters do not establish parity. [M] |
| `sync.sh`: incremental/full/reconcile/if-stale/stats, attachment handling | Retire | None measured on an equal fresh workload. Population/refresh/reconciliation are missing. Stale zero-request reads cannot support keep. [M] [L2] |
| `teams.sh`: list/get | Retire | None measured. Repeated direct metadata reads close the team chain. Separate get branch unmeasured. [M] |
| `users.sh`: list/get/me | Retire | None measured. Viewer attribution works for supplied app token; full user inventory and get branches unmeasured. [M] |
| Cache storage and `lib/cache.sh` | Retire | None measured on equal current results. Saved-copy completeness and maintenance costs remain unresolved. [M] [L2] |
| `lib/auth.sh` | Retire | None measured. Official GraphQL accepts the application token. Local token mint, renewal, expiry and credential-store behavior are source-only, not comparative measurements. KEN-2315 owns credential provisioning. [M] [S4] [L3] |
| Create-time team/reach/agent-label checks and label preflight | Retire | None measured against official GraphQL writes. Their source-defined protections matter when their triggering conditions occur, but no live write control establishes an official deficit. Removing them does not prove the policy can be dropped. [M] [L4] [L5] |
| `patterns/workflow-actions.md` | Retire | None measured. It combines state changes, reasons, hierarchy and label rules; no complete model/write workflow comparison exists. Its obligations remain an owner decision, not a transport performance fact. [M] [L5] |
| Other inventory libraries: attachments/bash-version/cache-dates/common/formatters/issue-validation/kendex-env | Retire with their consumers | None measured as separate capabilities. Formatting/credential/helper/source-policy behavior is not proven equal by read payload counts. [M] |

`issues move`, `issues comment`, `issues view/show` and cache issues `view/show` are refusal/redirect branches, not supported resource operations. Retire those compatibility diagnostics with their consumers; no measured official deficit supports retaining them. Help paths, singular aliases and router formatting likewise have no independent measured keep case. [L1] [M]

## Risks / Unknowns

| Missing evidence or risk | Impact and condition |
|---|---|
| Actual consumed/billed context for every cell | Payload tokenizer counts cannot establish model cost or a context-based keep. Applies to every route. [M] |
| Model reasoning, capacity/eligibility decision clocks and real close/no-op writes | A route can pass data retrieval yet fail planning or lifecycle use. No execution evidence establishes the probability. [M] |
| Full official-skill workflow clocks | Worker/poller tool proxies do not establish skill performance or write safety. Full skill execution remains missing. [M] |
| Local audit/roadmap clocks and first local lane clock | Retrieval errors/resumption prevent equal local timing comparisons. Final cycle repeats repair only cycle clocks. [M] |
| Cache population, incremental/full refresh and reconcile | A saved copy may cost more than direct reads once it must be fresh. Net time/request benefit is unresolved. [M] |
| Full MCP audit and both roadmap repetitions | Full audit never starts; roadmaps are quota-gated. Their clocks/tokens are missing, not zero. Project dependencies are absent in the measured tool schema. [M] |
| MCP backend requests and other-team labels | HTTP/tool totals cannot prove server-side quota use. Team-default label lists cannot prove whole-workspace metadata completeness. [M] |
| Prior token mint and local tokenizer provisioning | Workload clocks exclude those setup costs. A cold deployment comparison remains unresolved. [M] |
| False-complete consumers | A default page or omitted nested continuation can hide required rows. The condition is an ignored continuation/warning. The measured CLI watch lacks nested proof, and MCP subsets omit fields. [M] [L1] |
| Retirement before policy agreement | Write team selection, filing evidence and label rules could disappear with their current implementation. Their source-defined triggers are known; migration outcomes and failure rates are not measured. [L3] [L4] [L5] [M] |
| Concurrent main changes | Current main differs in overseer security-alert credential handling. That is source-only context, not this route benchmark. No security-alert action or focused remeasurement runs. [M] [N] |

## Revisit Conditions

- Owner requires full model/lifecycle or consumed-context evidence before approving retirement. Define equal safe workloads and a new explicit request allocation first. [M]
- A fresh-cache population/refresh comparison establishes a net benefit against equal direct results. Warm stale reads alone do not trigger keep. [M]
- MCP adds project dependency reads, complete required issue fields, or an audit route that avoids per-issue fan-out. Rediscover and test the changed schema before revising the recommendation. [M]
- KEN-2267 or KEN-2315 lands changes to measured routes or consumers. Do a commit-bound focused refresh only after owner approval; never mix new behavior into this baseline. [M]
- Observed quota headers, actors, field scopes or row counts change. Repeat only the affected compatible cuts and retain unknown backend counts unless server evidence supplies them. [M] [S10]

## Research Metadata

- Issue: KEN-2319. Research base: `8d95c78d7bcf144dfab70a2958ea5e5dc6646268`. Report date: `2026-09-30`.
- Final main check after the guarded restack: `1cf7f929919bb857a90fb6cbd2fddaa8fef632ed`. `git diff --name-only 8d95c78d7bcf144dfab70a2958ea5e5dc6646268 origin/main -- skills/linear skills/orch skills/project-management agents commands hooks` shows no Linear route changes. It names overseer security-alert paths changed by KEN-2301 commit `1b1ee939c7175180824fb7e19ba8e428f3bf3695` and a relaunch transcript test changed by KEN-2191 commit `e9625a6a662f8c135becaf2274f7df7f5f242007`. These are source-only notes. KEN-2267 and KEN-2315 have not landed in those measured paths. The measured baseline remains fixed. [M] [N] [N2]
- Exa modes: standard/deep-reasoning and follow-up lite/deep-lite. Returned source counts: 19 and 9. Existing provider payloads remain preserved in [R] and [R2]. No completed broad provider search repeats in the synthesis round.
- Validation scope: report structure, provider metadata, document limits and repository docs-only checks. Structural validation does not validate citation truth or fill missing experimental cells. The completion receipt records actual commands and run paths.
- Local instrument QA preserves all failed rows. Offline controls cover dependency canonicalization, order invariance, concurrent tokenizer vectors, duplicate/cursor refusal and rate-limit code detection. The independent reviewer finds no frozen-client-invalidating defect. Its proposed request-start span does not include the final response and is declined as a workflow clock. [M]
- Artifact coverage: the answer to `1790808880-96092-964` authorizes `docs/plans/AGENTS.md`. It identifies the JSON companions as research artifacts. The revised delegation answering `1790809327-104089-31942` permits repository validation compilation and a guarded restack. It does not permit a new Linear implementation. The measured baseline and samples remain unchanged.
- Control archive SHA-256: `1a4c54be490f7aacf7f87ef912d9cc9db61eddfb4b1f25ee3f67552cff56c624`. Private data are not tracked. No new Linear route, production edit, refresh/apply, tracker write, migration item or retirement runs in this research.

[M]: linear-official-route-research.evidence.json
[R]: linear-official-route-research.raw.json
[R2]: linear-official-route-research.skills.raw.json
[S1]: https://linear.app/docs/mcp
[S2]: https://linear.app/developers/graphql
[S3]: https://linear.app/developers/pagination
[S4]: https://linear.app/developers/oauth-2-0-authentication
[S5]: https://linear.app/developers/oauth-actor-authorization
[S6]: https://github.com/linear/linear-solutions/blob/4529f1e807d19e25f3c3889737f5b4bf90c242fe/Skills/stale-labels/SKILL.md
[S7]: https://github.com/linear/linear-solutions/blob/4529f1e807d19e25f3c3889737f5b4bf90c242fe/Skills/triage-plugin/skills/linear-issue-worker/SKILL.md
[S8]: https://github.com/linear/linear-solutions/blob/4529f1e807d19e25f3c3889737f5b4bf90c242fe/Skills/triage-plugin/skills/linear-triage-poller/SKILL.md
[S9]: https://github.com/linear/linear-solutions/blob/4529f1e807d19e25f3c3889737f5b4bf90c242fe/Skills/triage-plugin/skills/linear-triage-setup/SKILL.md
[S10]: https://linear.app/developers/rate-limiting
[L1]: https://github.com/vanillagreencom/kendex/blob/8d95c78d7bcf144dfab70a2958ea5e5dc6646268/skills/linear/scripts/commands/issues.sh
[L2]: https://github.com/vanillagreencom/kendex/blob/8d95c78d7bcf144dfab70a2958ea5e5dc6646268/skills/linear/scripts/commands/sync.sh
[L3]: https://github.com/vanillagreencom/kendex/tree/8d95c78d7bcf144dfab70a2958ea5e5dc6646268/skills/linear/scripts/lib
[L4]: https://github.com/vanillagreencom/kendex/blob/8d95c78d7bcf144dfab70a2958ea5e5dc6646268/skills/linear/scripts/lib/issue-validation.sh
[L5]: https://github.com/vanillagreencom/kendex/blob/8d95c78d7bcf144dfab70a2958ea5e5dc6646268/skills/linear/patterns/workflow-actions.md
[C]: https://github.com/vanillagreencom/kendex/tree/8d95c78d7bcf144dfab70a2958ea5e5dc6646268/skills
[N]: https://github.com/vanillagreencom/kendex/commit/1b1ee939c7175180824fb7e19ba8e428f3bf3695
[N2]: https://github.com/vanillagreencom/kendex/commit/e9625a6a662f8c135becaf2274f7df7f5f242007

### Owner decision request

Do you approve direct application-actor GraphQL for these retrieval requirements and the per-part retirement recommendations, with the disclosed missing decision, write, freshness and consumed-context evidence? Alternatively, require specific equal-workload measurements before approval. No retirement, migration, build or follow-up issue proceeds without your agreement.
