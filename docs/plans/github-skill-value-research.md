# Findings: GitHub skill value

## Research Question

What does the kendex GitHub skill add over plain `gh` and GitHub's official Model Context Protocol (MCP) server on the same pull request work? Which verbs should kendex keep, slim, or drop?

## Executive Summary

Keep CLI plus a smaller GitHub skill. Retain its complete thread reads, shared CI classification, timeline calculation, and D016 merge route. Remove repeated credential probes from the read path. The successful native view returns the same fields and bytes with fewer requests. MCP does not supply an equivalent readiness or timeline result in this sample. [M, S, D]

- The control host executes 255 direct skill calls. `pr-threads` accounts for 182 calls, or 71.4%. The five measured verbs account for 94.5%. Lane execution counts are unmeasured. [C]
- The comparison completes 30 read trials. Each route repeats each workload twice. No trial returns an execution failure or retries its workload request. Missing MCP fields remain partial results, not successful equivalents. [M]
- Claude's connected default session defers definitions and reports 582 tokens for server instructions. Forced eager loading reports 32.4k MCP tool tokens. Copilot reports 14.8k MCP tool tokens after connection. These are the harnesses' context instruments, not billed provider tokens. Codex and Pi definition-token costs remain unmeasured at the boundaries below. [H]
- The final counter is 289 observable outbound requests. It includes the original 46 setup failures, two parent controls, release download, fixture operations, and cleanup. The disposable PR, [#3333](https://github.com/vanillagreencom/kendex/pull/3333), is closed without merge. Its branch is deleted. [M]

The owner requires CLI plus a teaching skill unless the same-task measurement supports MCP replacement. This evidence supports retention of local policy and a smaller read path. It does not support an MCP replacement of that policy. [O, M]

## Key Findings

### Usage and coverage

The census measures executed tool calls, not workflow states or mentions in prose. Its window is `2026-09-27T03:32:02.592Z` through `2026-10-01T01:14:56.507Z`. The cutoff is `2026-10-01T01:30:50Z`. It covers 436 kendex Claude transcripts and eight kendex Codex sessions. All counted calls execute on the control host. [C]

The collector scans 618 transcripts across projects. It reads 36,826 Claude tool records, including 21,987 in kendex, and 392 kendex Codex tool records. It drops 24 identical Claude duplicates by session and tool-call identity. Codex has no duplicate. The source split is 225 Claude overseer calls, four overseer subagent calls, 12 Codex overseer calls, 13 other top-level calls, and one other subagent call. [C]

The archive census streams all 339 archives without extraction or read errors. They hold 347 files across 316 occupied item directories. Another 184 item directories are empty. No lane execution transcript or command log survives. Six smoke transcripts hold no executed tool calls. Lane calls are therefore **unmeasured**, not observed zero. The permanent aggregate preserves the full provenance, windows, source identifiers, exclusions, and prose counts. [C]

Each shell loop counts once because no execution log proves its iterations. Failure counts use the whole command's stored error flag. Pipes can hide failure. Multi-invocation failures, Codex batches, and 12 calls without a stored result cannot supply per-invocation failure counts. Item counts mean distinct PR numbers or thread IDs, not Linear issues. [C]

| Rank | Verb | Overseer | Other control | Total | Share / cumulative | Failed / retry | Items / files |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `pr-threads` | 169 | 13 | 182 | 71.4% / 71.4% | 0 / 0 | 86 / 39 |
| 2 | `pr-merge` | 32 | 0 | 32 | 12.5% / 83.9% | 1 / 1 | 13 / 16 |
| 3 | `ci-classify-refusal` | 11 | 0 | 11 | 4.3% / 88.2% | 0 / 0 | 8 / 5 |
| 4 | `pr-view` | 9 | 1 | 10 | 3.9% / 92.2% | 0 / 0 | 9 / 6 |
| 5 | `pr-timeline` | 6 | 0 | 6 | 2.4% / 94.5% | 0 / 0 | 4 / 3 |
| 6 | `post-reply` | 5 | 0 | 5 | 2.0% / 96.5% | 0 / 0 | 3 / 2 |
| 7 | `resolve-thread` | 4 | 0 | 4 | 1.6% / 98.0% | 0 / 0 | 3 / 2 |
| 8 | `bot-token` | 2 | 0 | 2 | 0.8% / 98.8% | 0 / 0 | 1 / 2 |
| 9 | `pr-data` | 1 | 0 | 1 | 0.4% / 99.2% | 0 / 0 | 1 / 1 |
| 10 | `pr-issue` | 1 | 0 | 1 | 0.4% / 99.6% | 0 / 0 | 1 / 1 |
| 11 | `post-comment` | 1 | 0 | 1 | 0.4% / 100.0% | 0 / 0 | 1 / 1 |
| None | `pr-list-ready` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `pr-list-failing` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `pr-create` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `pr-edit-body` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `pr-cross-check` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `label-add` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `label-remove` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `ci-logs` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `dismiss-review` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `unresolve-thread` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `find-comment` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `edit-comment` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |
| None | `sticky-comment` | 0 | 0 | 0 | 0.0% / 100.0% | 0 / 0 | 0 / 0 |

Every lane column is unmeasured. No recorded failure has exit 75. The 13 zero-call rows mean only that the control host records no direct invocation. [C]

Related consumers remain separate from skill verbs. Prose mentions do not add executions. [C]

| Consumer | Direct calls | Archive prose mentions | Fleet-log mentions |
| --- | --- | --- | --- |
| `pr-watch.sh` | 0 | 50 | 1 |
| `approval-wait` | 0 | 223 | 20 |
| `ci-wait` | 0 | 115 | 23 |
| `queue-wait` | 2 | 551 | 49 |

The wrapper census counts `oversee-cycle` 257 times across 60 files, `oversee-report` 207 times across 59 files, and `sync-base` 192 times across 55 files. Inner calls and GitHub helper calls do not have their own transcript record. Static inspection confirms that `oversee-cycle` calls `pr-timeline` and `oversee-report` calls `pr-list-failing --all`. `sync-base` uses the GitHub authentication helper. Low direct counts cannot establish low wrapper use. [C, W]

Plain `gh` executes 1,605 times in the same kendex transcripts. Its approximate mapping assigns 308 calls to view, 306 to readiness fields, 289 to CI status, 161 to queue state, 107 to CI logs, 83 to PR lists, and 70 to threads. The sidecar preserves every mapping row and its failure/source counts. These are separate calls, not additions to the 255 skill calls. [C]

### Matched workloads

All targets are `vanillagreencom/kendex`. PR #3323 is the merged KEN-2332 docs change. PR #3324 is the merged KEN-2330 change with two resolved, non-outdated threads. Each thread has two comments. PR #3333 is the draft measurement fixture on the same `main` branch. No write targets #3323 or #3324. [M]

The official local MCP release is `v1.12.2`, Linux x86_64. It starts on stdio with the existing lane credential supplied privately in `GITHUB_PERSONAL_ACCESS_TOKEN`. Its selected toolsets are `pull_requests,issues,actions,repos,governance`. Successful `tools/list` returns 47 definitions and 141,380 serialized bytes without a GitHub backend request. Definitions and workload responses are separate costs. [M, G]

The table reports both repetitions in order. Bytes are UTF-8 output bytes: CLI stdout plus stderr, or the complete compact JSON MCP result. Native composites sum every returned intermediate response. No byte-to-token conversion is applied. These are untruncated interface payloads for a model to read, not proof of what each harness retains after its own truncation. Larger valid output is not classified as a failure. [M]

| Workload | Route | Backend requests | Output bytes | Wall seconds | Coverage |
| --- | --- | --- | --- | --- | --- |
| View #3323 | Skill | 7, 7 | 193, 193 | 3.518, 3.201 | Complete selected fields |
| View #3323 | Native | 1, 1 | 193, 193 | 0.471, 0.493 | Identical selected fields |
| View #3323 | Local MCP | 1, 1 | 4,406, 4,406 | 0.693, 0.483 | Same fields in a larger PR result |
| Threads #3324 | Skill | 6, 6 | 3,815, 3,815 | 3.165, 2.939 | Complete thread contract |
| Threads #3324 | Native | 1, 1 | 2,438, 2,438 | 0.469, 0.471 | Same fields and page coverage |
| Threads #3324 | Local MCP | 1, 1 | 3,382, 3,382 | 1.000, 0.425 | Common fields complete; resolver and actor types absent |
| Readiness #3333 | Skill | 12, 12 | 9,098, 9,304 | 5.964, 5.914 | Derived readiness JSON and verdict |
| Readiness #3333 | Native | 5, 5 | 20,747, 20,964 | 2.450, 2.428 | Complete inputs; local policy interpretation needed |
| Readiness #3333 | Local MCP | 7, 7 | 15,295, 15,806 | 3.417, 3.438 | Partial inputs; no equivalent composite |
| Refusal cause #3333 | Skill | 12, 12 | 120, 126 | 5.741, 5.923 | Derived cause and authoritative-run scope |
| Refusal cause #3333 | Native | 5, 5 | 20,733, 20,964 | 2.341, 2.332 | Complete inputs; local policy interpretation needed |
| Refusal cause #3333 | Local MCP | 7, 7 | 15,734, 15,806 | 3.417, 3.368 | Partial inputs; no equivalent composite |
| Timeline #3323 | Skill | 9, 9 | 1,145, 1,145 | 4.851, 5.472 | Derived phase stamps and run-scoped times |
| Timeline #3323 | Native | 5, 5 | 45,965, 45,965 | 3.532, 2.922 | Complete inputs; local calculation needed |
| Timeline #3323 | Local MCP | 7, 7 | 22,382, 22,382 | 3.123, 3.012 | Partial inputs; no equivalent timeline |

The view field set is `number,title,state,headRefOid,baseRefName`. Both CLI outputs are identical. MCP needs local field selection and conversion of `merged=true` to `state=MERGED`. This result does not establish equivalence for `reviewDecision`, `mergeStateStatus`, or an expanded CI view. [M]

Native threads request IDs, resolution/outdated state, resolver login, path, line, comment count, bodies, and author login/type. Both thread collectors follow `pageInfo.endCursor` until `hasNextPage=false`. This sample fits one page. Checks confirm identical IDs, states, counts, and comment bodies across routes. MCP lacks resolver login and actor type in its returned schema. Its result cannot replace the full enriched contract without another source for those fields. [M]

Native readiness reads PR state, head, base, mergeability, review decision, latest reviews, check rollup, effective branch rules, and branch protection. Native timeline reads the skill's exact GraphQL field selection plus every sampled head's status history and head-branch activity. Both retrieve evidence for local interpretation. Neither collector implements an independent replacement for the skill's policy or derived output. [M, S]

MCP readiness uses five tools: PR details, reviews, combined status, check runs, and effective branch rules. Those tools send seven backend requests. They do not return classic protection or the GraphQL review decision used by this task. MCP timeline uses PR details, commits, reviews, status, and checks. That collection lacks branch push activity, armed/queued event times, all-head status history, and merge-group run scope. No elapsed-time or byte comparison treats these partial composites as equivalent successes. [M, G]

The comparison saves 31 correctness checks. They verify selected view equality, thread/comment completeness, closed pages, timeline identity and source stamps, readiness state/mergeability, required CI context, and fixture closure. They do not independently prove every timeline formula or merge policy. All sampled timeline connections fit their first page. Live CI progresses between fixture reads, so those response sizes vary. No multi-page successful retrieval, fleet-wide failure rate, or latency distribution is established. [M]

Native thread queries explicitly return one GraphQL point per repetition. Native timeline queries return four points per repetition. Other queries do not return their cost. Rate-limit headers show shared fleet use and cannot isolate per-query points by subtraction. Those costs remain unknown. The expected `/user` 403 followed by successful `/installation/repositories` is installation-token validation, not a workload failure or retry. [M, S]

### Credentials, counting, and cleanup

The lane's `GH_TOKEN` is a sandbox placeholder. The production proxy replaces it for `github.com` and `api.github.com` with a renewed GitHub App installation token. The original interceptor bypasses that proxy. Its 33 direct API authentication failures and 13 hosted MCP failures are setup evidence, not route reliability. The repaired relay forwards through the original production proxy and trust store. It does not log credentials. [M, O]

Hosted MCP receives the literal placeholder because its host is `api.githubcopilot.com`. Its measured HTTP 400 refusal is `Authorization header is badly formatted`. The fleet holds installation-token credentials, not an owner PAT. No new hosted request follows the owner's ruling. The report does not claim that this experiment tests a correctly supplied hosted user token. [M, O, G]

The relay persists the request counter before forwarding each backend request. Every retry, page, redirect, release asset transfer, and fixture operation counts separately. The final working limit is 295, below the issue's 300 ceiling. No cap refusal occurs. The owner accepts observable outbound counting and excludes hidden hosted fanout. Tool invocations are never substituted for backend counts. [M, O]

| Accounting category | Requests |
| --- | --- |
| Original setup failures and parent controls | 48 |
| Resumed setup, release download, pilots, and fixture creation | 44 |
| Matched read trials | 172 |
| Fixture safety and thread operations | 15 |
| Fixture closure, branch deletion, and closure verification | 3 |
| Harness startup GitHub API requests | 6 |
| Released source audit | 1 |
| Total | 289 |

The fixture branch is `research/ken-2334-measurement-only`. Its head is `4920493d227bd0a5cc66e8402871a7b354e427e7`. The API creates one benign docs file and one draft PR. It also creates a real review thread with the same installation identity. No second actor is needed for these comment-thread operations. That does not supply an independent reviewer for approval tests. Closure verification returns `state=closed`, `merged=false`, and `merged_at=null`, with closure at `2026-10-01T02:04:58Z`. Branch deletion returns HTTP 204. The issue branch stays unchanged. [M]

### Harness session-start cost

These probes launch installed clients in a disposable directory. Claude and Copilot receive only `/context` and `/mcp`. Pi receives only state/statistics RPC commands. No AI work prompt is submitted. The server command log records real client discovery. Copilot's first pre-connection zero is excluded from the connected cost. [H]

| Harness | Installed version | Connected definition cost from its instrument | Loading and boundary |
| --- | --- | --- | --- |
| Claude Code | 2.1.286 | Default: no directly loaded MCP definitions; 582 server-instruction tokens. Eager control: 32.4k MCP tool tokens plus 582 instruction tokens | `/context` lists all 47 tools as available on demand by default. `ENABLE_TOOL_SEARCH=false` loads them eagerly. Both values are Claude's estimated context tokens, not billing usage. |
| Codex | 0.159.3 | Unmeasured | TUI fails before inspection: `account/read failed: workspace routing discovery failed (code -32603)`. The local server config does not repair account bootstrap. No token count is fabricated. |
| Copilot CLI | 1.0.90 | 14.8k MCP tool tokens after local discovery | `/mcp` triggers discovery; the later `/context` supplies this value. The session uses Auto after a model-catalog TLS hostname failure. This configuration loads the connected definitions eagerly. It does not establish behavior for every supported model. |
| Pi | 0.99.2 | Unmeasured per-definition tokens | Local `pi mcp list --json` confirms connection and default `codemode` exposure. `get_session_stats` returns zero message usage, not a definition-token instrument. Installed RPC documentation exposes no per-definition attribution at this boundary. |

Claude documentation describes deferred tool search and explicit eager overrides. Copilot documentation enables on-demand search when supported and worthwhile, with a small-tool exception. Its observed Auto session does not demonstrate that conditional deferral. Installed Pi documentation makes MCP tools indirect by default through `codemode`; direct and deferred exposure are configuration choices. Codex loading behavior is not measured past its bootstrap refusal. None of these facts makes all MCP session overhead zero. [A, H, P]

### Safety contracts and live controls

GitHub applies branch rules to each route and credential. A caller that omits a head guard can act on a newly pushed commit. A caller with bypass rights can bypass more than the queue. Those risks depend on concurrent pushes, branch rules, and token permissions. This fixture does not measure their fleet frequency. [D, G, S]

| Rule | Skill | Native CLI/API | Official local MCP | Live evidence and limit |
| --- | --- | --- | --- | --- |
| Exact head | Requires the verified head through `--match-head-commit`; accepts a prepared `--expected-head` | `gh pr merge --match-head-commit` and REST merge `sha` provide the primitive; caller must supply it | Released `merge_pull_request` has optional `expectedHeadSha` and forwards it as merge `SHA` | Native wrong-head call refuses with `expected head oid does not match` on fixture #3333. MCP wrong-head call refuses HTTP 405 because the PR is draft. The latter does not isolate its head guard. [M, S, G] |
| Required approval | Auto-arm refuses unless a ruleset requires approval | GitHub enforces configured approval rules; native commands do not add the skill's preflight | GitHub enforces the same rules; the merge tool does not implement the skill's preflight | Effective `main` rule requires one approval; fixture review decision is `REVIEW_REQUIRED`. No independent approval/refusal mutation is tested. [M, S] |
| Stale approval dismissal | Auto-arm requires dismissal on push | Server setting, not a native default | Server setting, not an MCP default | Live effective rule sets `dismiss_stale_reviews_on_push=true`. No push after independent approval is tested. [M, S] |
| Thread resolution | Retains thread identity, paging, and mutation-result status; auto-arm requires the server rule | GraphQL resolve/unresolve mutations reach the same thread | `pull_request_review_write` resolves/unresolves by `threadId` | The real fixture thread is resolved by skill, reopened/resolved by native API, and reopened/resolved by MCP. Required-resolution rule is present. No merge past a foreign review thread is attempted. [M, S, G] |
| Queue versus D016 | Reads bypass rights per ruleset, classic protection, accepted method, and queue-only classification under the merge identity | `gh` exposes queue/auto/admin operations but does not choose kendex's D016 route | Released merge tool sends REST merge; no equivalent D016 route or queue composite is measured | Live branch rules include a merge queue. Native wrong-head refusal occurs on auto-merge enrollment. No valid enrollment, bypass, or merge is authorized. [M, D, G] |
| Required versus optional CI | Shared classifier scopes authoritative runs, blocks required failures/missing contexts, and warns on optional failures | Native reads supply the fields; caller must interpret them | Status/check tools retrieve evidence but do not supply the shared classification | Skill and native reads identify required context `CI`. The fixture refuses readiness for missing `CI`. Changing optional failures is not a wrong-result measurement. [M, S] |
| `--admin` | Caller never passes it. The immediate route chooses it only where the queue is all it can bypass. `--auto` never passes it | Manual documents override of unmet requirements and queue bypass | This release's merge schema has no `admin` parameter | Static D016 contract, not a live bypass test. The issue's phrase “never --admin” is not the current skill contract. [D, G, O] |

The skill resolves the fixture thread with five backend requests, 66 output bytes, and 2.560 seconds. Native resolve uses one request, 92 bytes, and 0.839 seconds. MCP resolve uses one request, 74 bytes, and 0.731 seconds. MCP also posts a real thread reply with one backend request. These single mutation samples establish reach and result handling, not a reliability ranking. [M]

## Evidence and Sources

Local evidence is separate from Exa documentary evidence. Every local aggregate cited here is permanent. Raw traces remain scratch. [M]

- [M] [Measurement aggregate](github-skill-value-measurements.json): matched command/tool inputs, both repetitions, request sequence ledger, cost fields, 31 correctness checks, fixture state, and source snapshots.
- [C] The same aggregate's `census` contains the supplied full control-host report and structured tables. The parent collects it read-only on `2026-10-01` around `01:40Z`. This lane does not have the original control-host archives.
- [H] The aggregate's `harness_probes` and `harness_captures` preserve instrument output and exact launch commands. These are local session observations, not Exa token estimates.
- [S] [GitHub skill](../../skills/github/SKILL.md), [auth validation](../../skills/github/scripts/lib/gh-auth.sh), [PR view](../../skills/github/scripts/commands/pr-view.sh), [threads](../../skills/github/scripts/commands/pr-threads.sh), [merge checks](../../skills/github/scripts/commands/pr-merge.sh), [refusal classification](../../skills/github/scripts/commands/ci-classify-refusal.sh), and [timeline](../../skills/github/scripts/commands/pr-timeline.sh). Lower-use decisions below cite their named command's static contract through the skill. No production edit occurs.
- [W] [Cycle wrapper](../../skills/orch/scripts/oversee-cycle), [report wrapper](../../skills/orch/scripts/oversee-report), and [base sync helper](../../skills/orch/scripts/sync-base).
- [D] Active [D016](../decisions/D016-merge-route-reads-bypass.md). Its verification references name the existing route tests. This research does not run them.
- [O] [KEN-2334 and owner rule](https://linear.app/vanillagreen/issue/KEN-2334/research-what-the-github-skill-adds-over-plain-gh-and-githubs-official), read only from cache. The resumed delegation also fixes the proxy/accounting boundary and authorizes the release binary.
- [G] [Official server configuration](https://github.com/github/github-mcp-server/blob/main/docs/server-configuration.md), [remote authentication](https://github.com/github/github-mcp-server/blob/main/docs/host-integration.md), [local release](https://github.com/github/github-mcp-server/releases/tag/v1.12.2), [released PR implementation](https://github.com/github/github-mcp-server/blob/v1.12.2/pkg/github/pullrequests.go), and [native merge flags](https://cli.github.com/manual/gh_pr_merge). Release schema and source audit replace assumptions about proposed merge features.
- [A] [Claude MCP loading](https://code.claude.com/docs/en/mcp), [Copilot tool search](https://docs.github.com/en/copilot/concepts/agents/copilot-cli/tool-search), [Copilot context accounting](https://docs.github.com/en/enterprise-cloud@latest/copilot/concepts/agents/copilot-cli/context-management), and [Codex MCP configuration](https://developers.openai.com/codex/mcp).
- [P] Installed Pi documentation: complete MCP, CLI, and Sessions documentation, with its RPC statistics contract. Public references: [MCP](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md) and [RPC commands](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md). The installed version controls the local finding.
- [F] The aggregate's `final_dispositions` preserves the overseer's final rulings and stub verification. It records the filed [KEN-2401](https://linear.app/vanillagreen/issue/KEN-2401) and [KEN-2402](https://linear.app/vanillagreen/issue/KEN-2402) bindings. The stub verification is separate from this lane's measured workload. No new live trial occurs during report finalization.

The source audit excludes cloud-agent configuration as evidence for Copilot CLI. It excludes old Pi “No MCP” descriptions, namesakes, and proposed-feature token estimates. Exa's resumed search returns an older release and an open PR. Neither establishes v1.12.2 behavior. The downloaded release's actual schema and tagged source establish that behavior. [G, H, P]

### Reproduction

Run CLI reads from the same worktree with the original proxy environment intact. Never print or remove the credential to test an installation token. The sidecar's `matched_trials.inputs` contains the full native GraphQL selections and every composite operation. Its sequence ranges identify backend requests, including native `gh pr checks` fanout. [M]

```bash
.agents/skills/github/scripts/github.sh pr-view 3323 --json number,title,state,headRefOid,baseRefName
gh pr view 3323 --repo vanillagreencom/kendex --json number,title,state,headRefOid,baseRefName
.agents/skills/github/scripts/github.sh pr-threads 3324
.agents/skills/github/scripts/github.sh pr-merge 3333 --check
.agents/skills/github/scripts/github.sh ci-classify-refusal 3333
.agents/skills/github/scripts/github.sh pr-timeline 3323 --repo vanillagreencom/kendex
```

PR #3333 is closed, so its current readiness differs from the saved open-state sample. Reproduction of an open-state comparison needs a newly authorized disposable fixture. Existing PRs remain read-only. [M]

The binary starts with `github-mcp-server stdio --toolsets=pull_requests,issues,actions,repos,governance`. Set its token privately in the child environment. Send protocol `initialize`, `notifications/initialized`, and `tools/list` before `tools/call`. Thread calls use `pull_request_read` with `method=get_review_comments`, `perPage=100`, and the returned cursor. [M, G]

Wall time includes process startup, authentication, network, paging, and output processing. CLI calls execute sequentially. The loopback TLS relay captures the original upstream proxy before configuring child clients. It forwards through that proxy with the original trust store. Child trust combines the original roots and temporary interception certificate. The relay permits no further hosted MCP request. [M]

## Tradeoffs / Alternatives

| Route | Retained function | Cost or limit |
| --- | --- | --- |
| CLI plus slim skill | Complete enriched threads, shared CI diagnosis, derived timeline, safe merge route | Current placeholder-token read path repeats authentication. The 7-request view versus 1-request native view measures that cost. [M, S] |
| Native CLI plus teaching skill | Same selected view and complete thread retrieval with fewer requests | Readiness and timeline still need the local policy/calculation owner. Raw retrieval bytes are not an equivalent automated decision. [M, D] |
| Official local MCP | Authenticated PR reads and actual comment/thread writes | No equivalent policy composites in the selected inventory. Connected definition cost depends on harness and loading configuration. [M, H, G] |
| Hosted MCP | Hosted transport and user-token authentication | Fleet credentials do not reach it through this sandbox proxy. The local comparator cannot establish hosted performance. [M, O, G] |

## Recommendation / Decision Criteria

Keep CLI plus skill as the service route. `Keep` means retain the named behavior. `Slim` means retain its stated unique contract while removing duplicated reads, unsafe completeness assumptions, or native plumbing. These are decisions about scope, not product changes in this research. No verb is dropped solely for a zero direct control-host count. [C, M, O]

| Verb | Decision | Evidence-backed scope |
| --- | --- | --- |
| `pr-data` | Slim | Retain a compact composite. The shared pager already completes the thread list. Files remain limited to 100, PR comments to 50, and comments per thread to 10. [KEN-2402](https://linear.app/vanillagreen/issue/KEN-2402) records those remaining limits. One direct call; lane use unmeasured. [C, S, F] |
| `pr-view` | Slim | Retain bounded structured refusal. Successful output is identical to native view, but 7 requests replace 1 on this credential path. [KEN-2401](https://linear.app/vanillagreen/issue/KEN-2401) records repeated validation. Retain the installation-token fallback and validate once per invocation. [M, S, F] |
| `pr-threads` | Slim | Retain complete paging, thread IDs, resolver and actor types. Native retrieval supplies those fields with 1 request versus 6. Remove repeated validation without changing the returned field contract. The 182 calls make this measured read-path cost material. [C, M, S] |
| `pr-timeline` | Keep | Derives phase and authoritative-run times; refuses capped connections. Native retrieval needs calculation and MCP misses required history. `oversee-cycle` consumes it internally. [M, S, W] |
| `pr-list-ready` | Slim | Retain scoped listing. The list is advisory, not the authoritative merge gate. Its raw-rollup result cannot replace `pr-merge --check`. This difference is not an accepted defect. Zero direct calls do not establish no consumers. [C, S, F] |
| `pr-list-failing` | Keep | Retain the scoped failure-list result consumed by `oversee-report`. That wrapper has 207 recorded invocations, so zero direct verb calls do not justify removal. [C, S, W] |
| `pr-create` | Keep | Retain head/base, committed/pushed-head checks and selected write identity. The API fixture does not test replacement of these preconditions; lane usage is unmeasured. [M, S] |
| `pr-edit-body` | Slim | Retain sanitized body input and write routing. The command delegates the body update to native `gh pr edit`; the native operation is not a separate policy. Five mapped plain-gh calls confirm the primitive is used. [C, S] |
| `pr-merge` | Keep | Retain exact-head binding, auto-arm rule checks, and D016 route. Native primitives and released MCP do not supply this composite choice. [M, D, S] |
| `ci-classify-refusal` | Keep | Retain one cause from one authoritative snapshot. The skill returns 120/126 bytes; native retrieval returns 20,733/20,964 bytes and still needs interpretation. [M, S] |
| `pr-cross-check` | Keep | Retain explicit multi-PR overlap and dependency analysis, distinct from a single-PR merge. No live comparison measures that task; zero direct calls cannot justify removing it. Its build/test mode remains outside this research. [C, S] |
| `pr-issue` | Slim | Retain configurable branch-to-issue extraction. It needs a branch name, not a second remote read when the caller already has PR metadata. One direct call; workflow demand beyond that is unmeasured. [C, S] |
| `label-add` | Keep | Retain live inventory validation and required/optional refusal modes. These are more than an endpoint wrapper. No observed zero-use claim extends to lanes. [C, S] |
| `label-remove` | Slim | Retain sanitized mutation routing and result status. Native label removal supplies the remote operation; the static contract adds no inventory gate here. No write comparison for labels is claimed. [C, S] |
| `ci-logs` | Keep | Retain PR-to-failed-run evidence selection and bounded logs. The plain-gh census records 107 log reads. The wrong diagnosis appears only in setup that bypasses the required proxy. No failed legitimate log task is observed. [C, M, S, F] |
| `bot-token` | Keep | Retain selected-credential/source diagnosis without exposing the token. Installation credentials cannot be diagnosed with `/user` alone. Two direct calls and successful fallback evidence support the distinct contract. [C, M, S] |
| `dismiss-review` | Keep | Retain reviewer selection and aggregate mutation-result status. A native dismissal primitive does not select that set. Independent approval/dismissal behavior remains unmeasured. [C, S] |
| `resolve-thread` | Slim | Retain thread-ID access and failure status. Actual fixture resolution succeeds on all three routes; skill uses 5 requests, native and MCP use 1. Slim repeated validation, not thread identity. [M, S] |
| `unresolve-thread` | Slim | Retain reopened-state validation and mutation status. Native and MCP reopening succeed on the fixture. This is not evidence to remove the result contract or to infer low lane use. [M, S] |
| `post-reply` | Keep | Retain numeric-comment PR scoping and thread-ID routing. Five direct calls are recorded. Actual MCP reply reach does not enforce the skill's numeric-ID caller contract. [C, M, S] |
| `post-comment` | Slim | Retain sanitized text and write-result handling. Native comment creation is the delegated remote primitive. One direct skill call and separate plain-gh comment calls establish use, not a need for duplicated plumbing. [C, S] |
| `find-comment` | Keep | Retain pattern/author lookup as local interpretation of comments. A raw MCP or native comment list is not that result. Direct lane use and completeness beyond the named contract remain unmeasured. [C, S] |
| `edit-comment` | Keep | Retain endpoint selection and unknown-ID refusal. This contract prevents treating a review comment as a PR-level comment. Fixture editing is not tested. [C, S] |
| `sticky-comment` | Keep | Retain verdict/analysis extraction, not just comment retrieval. The census maps review reads separately; it does not establish no consumer for this interpretation. [C, S] |

### Finding dispositions

| Finding | Disposition | Impact and likelihood boundary |
| --- | --- | --- |
| Repeated placeholder-token validation | FILED: [KEN-2401](https://linear.app/vanillagreen/issue/KEN-2401) | Adds requests and latency to every sampled view/thread call on this credential path. Keep the installation-token fallback; validate once per invocation. The overseer's separate stub verification confirms three validation pairs: token selection loses its cache in a subshell, the apply step probes again, and `pr-view` validates after exec. That stub confirms seven requests, six for validation; it is not another measured workload trial. [M, S, F] |
| `pr-data` bounded selections without complete coverage metadata | FILED: [KEN-2402](https://linear.app/vanillagreen/issue/KEN-2402) | The shared pager already completes the thread list. Remaining limits are files 100, PR comments 50, and comments per thread 10. A large PR can omit files or comments while returning success. Live occurrence is unmeasured. [S, F] |
| GraphQL helper retries rejected authentication | DROP as a defect | Original broken-proxy probes retry failed reads twice. Only setup that bypasses the required proxy reaches this failure; no workload failure appears on the successful path. [M, F] |
| `ci-logs` calls an initial auth failure “PR not found” | DROP as a defect | The wrong diagnosis appears only in setup that bypasses the required proxy. No failed legitimate log task is observed. [M, F] |
| Readiness list uses a separate CI judgement | DROP as a defect; retain Slim | The list is advisory, not the authoritative merge gate. The static raw-rollup difference establishes no affected legitimate merge verdict. [S, F] |
| Unknown lane execution counts | DROP any fleet-wide zero-use conclusion | Archives contain no execution records for lanes. Prose and wrapper calls cannot supply missing counts. [C] |
| Complete four-harness definition-token cost claim | DROP as unsupported | Codex account bootstrap refuses. Pi's accessible statistics instrument does not attribute definition tokens. Both costs remain unmeasured, not pending work under KEN-2334. [H, P, F] |
| Issue phrase “never --admin” | FIXED in this report | The active D016 route owns a conditional admin call. Treating the phrase as current behavior would misstate its safety contract. [D, O] |
| Old Pi descriptions, proposed-feature estimates, hosted hidden fanout | DROP from quantitative conclusions | They cannot establish installed behavior or measured client costs. [G, H, P] |

The overseer binds repeated validation to KEN-2401 and the remaining `pr-data` limits to KEN-2402. These are filed findings, not promises of pending fixes under KEN-2334. The parent owns the owed Linear evidence comments and publication. [F, O]

## Risks / Unknowns

- Two repetitions per workload do not establish a fleet reliability or latency distribution. All successful read samples are small enough to close their sampled pages. [M]
- Native readiness and timeline rows measure retrieval, not an independent automatic replacement. MCP rows remain partial where fields or history are absent. [M]
- Approval, stale-approval dismissal, per-token bypass rights, and optional-CI refusal behavior are not isolated mutation controls. Effective rules and static contracts support the stated limits only. [M, D, S]
- Connected token instruments vary by harness. Claude and Copilot values are harness-reported context quantities. No billed model request isolates MCP definition tokens. Pi and Codex remain explicitly unmeasured. [H]
- Native and MCP results can exceed a harness's tool-result display limit. The byte table includes full collector payloads; it does not hide missing data behind a smaller truncated preview. [M, P]
- The local release comparison cannot establish hosted MCP latency, authentication with a user credential, or hidden backend request count. [M, G]

## Revisit Conditions

- Lane execution transcripts become available. Replace unmeasured counts, then reassess low direct-use verbs and wrapper demand. [C]
- A native/MCP collector produces the same complete policy output and safety controls as the retained composites. Compare that output, not raw evidence alone. [M, D]
- Codex reaches a usable account session, or Pi supplies per-definition attribution from its own instrument. Such evidence could support a later token comparison. It is not pending work under KEN-2334. [H, P, F]
- A release or supported-model configuration changes connected tool loading, schema fields, or required-history reach. Repeat the same-workload measurement before changing the CLI default. [M, H, O]

## Research Metadata

- Issue and artifact key: KEN-2334. Branch: `ken-2334`. Measurement revision: `ead8bd34d8f062cc2a070c4193d0f37ed6b3440c`. The measurement changes no production code, ruleset, base checkout, or tracker. Fixture operations never check out or reset the issue branch. [M]
- GitHub CLI: `2.101.0`. Official local MCP: `v1.12.2`. The release download and source audit count as setup. The binary is downloaded under scratch and is not built or installed. [M]
- Exa: two `standard` / `deep-reasoning` queries and one `lite` / `deep-lite` query. They return 39, 20, and 9 sources, with 63 distinct URLs across payloads. Provider synthesis is audited rather than adopted as a local observation. [M]
- Raw provider sidecars remain at `tmp/ken-2334-research/documentary-findings.raw.json`, `harness-documentary-findings.raw.json`, and `resumed-documentary.raw.json`. They are not the sole support for any permanent measured claim. The tracked aggregate holds metadata, census provenance, inputs, and results. [M]
- Exact outbound counter: 289. Working cap: 295. Issue cap: 300. Cap refusals: 0. Hosted attempts remain 13 from original setup. Hidden hosted and provider fanout remain outside the owner's observable boundary. [M, O]
- Publication and tracker updates belong to the parent. This round commits the named docs artifacts only and does not push or create a publication PR. [O]
