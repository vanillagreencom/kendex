# Findings: linear.sh commands against raw GraphQL

## Research Question

For each `linear.sh` command, does a model do as well calling Linear's official GraphQL API directly, on the context the task costs, first-try success, requests and time? Which commands should kendex keep, and which can retire under the owner's rule? What context do Linear's MCP tool definitions take at session start in each harness?

KEN-2335, the thin-layer rewrite of `linear.sh`, has not merged. This run measures the live `linear.sh` commands on branch `ken-2336` at commit `1a632318` as the stand-in, with no `cache` or `sync` command.

## Executive Summary

Keep `issues activate` and `projects list-dependencies`. Retire `issues get` with `issues children`, `issues list`, `projects get`, `cycles list`, `issues create` with `issues add-relation`, `comments create`, `issues complete` and `issues validate-completion`. No task measured the other commands, and they carry no verdict. [M]

- All 99 runs returned the correct answer. Above its fixed overhead, the raw route cost less context on 8 of 10 tasks; `linear.sh` cost less on `projects list-dependencies` and `issues activate`. [M]
- First-try failures had two causes: Linear's query-complexity limit on the raw route, and `--team` refusing the team key on the `linear.sh` route (KEN-2664). [M]
- One `linear.sh` round cost 78 Linear requests against 23 for the raw route, so four `linear.sh` cells have two or three runs instead of five. [M]
- In Claude Code, the installed linear skill adds 46 tokens at session start and the deferred Linear MCP server adds 1,487. Once used, loading the skill adds 5,362 tokens and loading three Linear MCP tools adds 6,283. Copilot CLI loads all 58 Linear MCP tools at session start, for 30,280 tokens. [M] [S2]
- Each retire line takes effect only through a change that follows owner rule 1790812464. [O]

## Key Findings

### Failure causes

- **Raw route, query complexity**: Linear refuses a query above complexity 10,000 with "Query too complex". The model's first query hit that limit in 5 of 5 create runs, 5 of 5 cycles runs and 4 of 5 project-deps runs. Each time it narrowed the query and then succeeded. The complexity came from nested connections with large page sizes, such as all team labels and states in one query.
- **`linear.sh` route, team key**: `cycles list --team KEN` and `issues create --team KEN` refuse with "Team not found: KEN"; the flag takes the team name, `kendex`. That refusal caused the failed call in 4 of 5 cycles runs and 1 of 2 create runs. KEN-2664 tracks the fix. The other create run failed on the model's own `jq` filter over `issues get` output, then re-ran the read.
- **`linear.sh` route, dependency direction**: in one project-deps run the model read `projects.sh` to learn which direction `list-dependencies` reports, then answered correctly.

### Request cost

- One `issues activate` call made 8 requests in the lane's own activation of KEN-2336. Every `linear.sh` activate run made 9; the raw runs made 2.
- One `issues validate-completion` call on three issues made 6 requests. The raw runs made 3.
- `issues list --max` pages through every match. Both `linear.sh` list-filter runs also listed every Done issue to cross-check the label filter, at 27 and 28 requests.
- Across 39 task runs the `linear.sh` route made 31 `--help` calls and 25 `teams list` or `auth-check` calls before or beside the task command.
- The raw route read the schema file only in the 5 project-deps runs. In every other raw run the model wrote the queries without it.

### Skill against MCP in Claude Code

Claude Code lists an installed skill by name and description, and loads its body only when the Skill tool invokes it. With tool search on, Claude Code loads only MCP tool names at session start and loads a definition when a search selects it [S2]. Each row below compares the two at the same point of use. [M]

| Point of use | Linear skill | Linear MCP server, tool search on |
| --- | --- | --- |
| Session start, nothing used | 46 tokens: 8,590 against 8,544 with neither | 1,487 tokens: 10,031 |
| One task's worth loaded | 5,362 tokens: the skill loaded through the Skill tool, 13,906 | 6,283 tokens: `get_issue`, `list_issues` and `save_issue` loaded through tool search, 14,827 |
| Every definition loaded | 5,362 tokens, the whole skill | 29,256 tokens: all 58 tools, tool search off (§ Evidence and Sources, Linear MCP tool definitions) |

The loaded rows include the tool call that loads the skill or the tools. The task runs instead appended the skill text to the system prompt, at 5,103 tokens per session (§ Evidence and Sources, Context above the fixed overhead). [M]

## Evidence and Sources

### Setup and deviations

Each run is one headless Claude Code session: `claude -p --model claude-opus-5-5 --effort high --output-format stream-json --verbose --no-session-persistence --restricted --tools Bash,Read,Grep,Glob --strict-mcp-config --disable-slash-commands --permission-mode dontAsk --allowedTools Bash Read Grep Glob --max-budget-usd 3`, under a 900-second timeout. The two routes use the same model, effort and task prompt. The `linear` skill's last change on the measured branch is commit `f2522e08`.

| Route | Appended system prompt | Size |
| --- | --- | --- |
| `linear.sh` | The rendered `.agents/skills/linear/SKILL.md`, plus the absolute path of `linear.sh` and one line that forbids `sync` and `cache` | 15,393 bytes |
| Raw GraphQL | The endpoint, the token variable `LINEAR_TOKEN`, the header `Authorization: Bearer $LINEAR_TOKEN`, the schema path, the team key KEN, and "call the API with curl" | 579 bytes |

The schema is Linear's `packages/sdk/src/schema.graphql` at `linear/linear` commit `b37823be308a42f837277671f3ded66d33d92e6c` (1,335,039 bytes).

Each child runs in an empty directory outside the repository, so no `AGENTS.md` or `CLAUDE.md` loads; the init event lists no MCP server, skill or slash command. A `curl` wrapper first on the child's `PATH` logs each call and refuses past the request cap. Both routes reach Linear only through `curl`. With `LINEAR_APP_TOKEN` set, `linear.sh` sends the token and makes no token request (`scripts/lib/auth.sh`, `linear_authorization`).

Deviations from the delegated method:

- **Credential**: the host has `LINEAR_APP_TOKEN`, the kendex application token, and no client pair, so `auth-mint` cannot run. Both routes receive that token through the child's environment only.
- **`linear.sh` working directory**: `linear.sh` refuses to run outside a git repository. Each `linear.sh` child runs in a fresh `git init` directory that holds a copy of `kendex.settings.toml` and nothing else, so `LINEAR_TEAM` and the create guards load and each run starts with no cache.
- **Raw schema path**: `--restricted` confines the file tools to the working directories. The schema sits in a fixtures directory outside the repository, passed with `--add-dir`.
- **Trace format**: `stream-json` replaces `json`. Its final `result` event carries the same measures, and the stream carries the tool trace.
- **Writes**: the issue body names one throwaway project. The binding brief limits writes to scratch issues titled "KEN-2336 scratch", so this run creates no project.
- **Run counts**: the request cap leaves the `linear.sh` route of four tasks short of five runs. See § Evidence and Sources, Requests and cleanup.

### Tasks and grading

| Task | Target | Correct when |
| --- | --- | --- |
| read-children | KEN-572 and its 7 children | Title, state and every child's state match |
| list-filter | KEN issues in Done with label `windows` | The 11 identifiers match |
| project-get | Project "Agent Harness Integrations" | Name, state, lead, dates and team keys match |
| cycles | KEN's 7 cycles | Total, active cycle 5 with its dates, upcoming 6 and 7 |
| project-deps | Project "Trading Panels" | Blocked by Application Shell, Execution Engine, Market Data Bridge; blocks none |
| create | New scratch issue | One issue with the title, Backlog, labels `agent:researcher` and `research`, related to KEN-2616, the description line |
| comment | One scratch issue per run | Exactly one comment with the given body |
| activate | One scratch issue per run, labelled `agent:researcher`, `research` | In Progress, labels `agent:maintainer`, `research` |
| complete | One scratch issue per run | Done, one comment with the summary line, posted before completion |
| validate | KEN-2647 (In Review, summary), KEN-2648 (Done, summary), KEN-2649 (In Review, no summary) | true, false, false; `all_ok` false |

The validate prompt states the rule: an issue passes in In Progress or In Review with a comment containing "Completion Summary" or "Bundle Complete". A script grades each final JSON answer against ground truth read once before and once after the runs; the read-task truth did not change between the two reads. One grading read covers every scratch issue.

First-try success means a correct answer with no failed Linear call. A script flags every tool result of a Linear call that carries an error marker or a tool error; each flag was then reviewed by hand. A `--help` call is not a Linear call.

### Results by task and route

`L` is the `linear.sh` route, `R` the raw route. Each cell is the median, with the range in brackets. Peak context is the largest prompt of any turn: input, cache-creation and cache-read tokens. Total input sums those tokens over all turns. Tool bytes are the bytes of tool output the model read. Time is the session's `duration_ms`.

| Task | Route | Runs | Peak context | Total input | Output tokens | Tool bytes | Turns | Time (s) | Cost (USD) | Requests | Correct | First try |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| baseline | L | 5 | 11230 (11230-11230) | 11230 (11230-11230) | 4 (4-4) | 0 (0-0) | 1 (1-1) | 1.4 (1.3-4.0) | 0.009 (0.009-0.057) | 0 (0-0) | 5/5 | 5/5 |
| baseline | R | 5 | 6127 (6127-6127) | 6127 (6127-6127) | 4 (4-4) | 0 (0-0) | 1 (1-1) | 1.5 (1.2-2.2) | 0.008 (0.008-0.016) | 0 (0-0) | 5/5 | 5/5 |
| read-children | L | 5 | 13163 (12361-13831) | 36856 (23693-37524) | 580 (399-694) | 3359 (1666-4840) | 3 (2-3) | 7.2 (6.1-10.1) | 0.041 (0.028-0.048) | 2 (2-10) | 5/5 | 5/5 |
| read-children | R | 5 | 6810 (6810-6812) | 13039 (13039-13041) | 418 (418-418) | 649 (649-649) | 2 (2-2) | 5.4 (4.2-8.0) | 0.023 (0.023-0.031) | 1 (1-1) | 5/5 | 5/5 |
| list-filter | L | 2 | 15496 (15248-15743) | 82187 (81853-82521) | 1124 (1082-1167) | 6966 (6558-7373) | 6 (6-6) | 40.8 (38.6-43.1) | 0.079 (0.076-0.082) | 28 (27-28) | 2/2 | 2/2 |
| list-filter | R | 5 | 7980 (7362-8099) | 14172 (13554-14291) | 554 (481-750) | 2668 (1129-3274) | 2 (2-2) | 6.2 (5.6-7.8) | 0.034 (0.033-0.044) | 1 (1-1) | 5/5 | 5/5 |
| project-get | L | 5 | 13514 (13510-14183) | 36762 (36758-37431) | 353 (349-429) | 3520 (3520-4847) | 3 (3-3) | 5.9 (5.4-7.5) | 0.039 (0.039-0.046) | 3 (3-5) | 5/5 | 5/5 |
| project-get | R | 5 | 6677 (6663-6681) | 12920 (12906-12924) | 295 (286-304) | 259 (259-259) | 2 (2-2) | 3.9 (3.8-6.7) | 0.019 (0.019-0.028) | 1 (1-1) | 5/5 | 5/5 |
| cycles | L | 5 | 15071 (14495-15537) | 77957 (63544-92715) | 839 (719-1124) | 5191 (4333-5983) | 6 (5-7) | 12.6 (11.2-45.0) | 0.067 (0.060-0.081) | 6 (4-7) | 5/5 | 1/5 |
| cycles | R | 5 | 8055 (7507-9178) | 28569 (20378-29331) | 785 (558-915) | 1784 (1326-3662) | 4 (3-4) | 9.6 (8.7-10.8) | 0.043 (0.032-0.054) | 3 (2-5) | 5/5 | 0/5 |
| project-deps | L | 5 | 11975 (11975-14781) | 23310 (23310-78476) | 407 (355-1054) | 847 (847-5432) | 2 (2-6) | 6.5 (5.7-13.1) | 0.025 (0.024-0.071) | 2 (2-2) | 5/5 | 5/5 |
| project-deps | R | 5 | 11670 (9833-12695) | 63000 (39846-73245) | 2083 (1580-2637) | 6450 (4452-10444) | 8 (6-9) | 20.8 (18.1-28.4) | 0.106 (0.075-0.119) | 4 (3-5) | 5/5 | 1/5 |
| create | L | 2 | 21780 (17470-26091) | 174197 (173177-175217) | 1914 (1352-2476) | 19769 (7742-31796) | 10 (8-12) | 31.8 (21.9-41.6) | 0.162 (0.140-0.184) | 16 (14-17) | 2/2 | 0/2 |
| create | R | 5 | 8228 (8163-8477) | 36344 (36210-37165) | 1200 (1197-1251) | 980 (939-1437) | 5 (5-5) | 15.5 (14.1-24.6) | 0.055 (0.054-0.056) | 4 (4-4) | 5/5 | 0/5 |
| comment | L | 5 | 12448 (11787-12603) | 35747 (23083-36057) | 490 (220-530) | 1803 (487-1804) | 3 (2-3) | 7.7 (4.3-11.3) | 0.033 (0.020-0.035) | 1 (1-1) | 5/5 | 5/5 |
| comment | R | 5 | 7068 (6638-7113) | 19961 (12831-20052) | 637 (318-683) | 273 (174-273) | 3 (2-3) | 8.0 (4.6-11.9) | 0.030 (0.019-0.032) | 2 (1-2) | 5/5 | 5/5 |
| activate | L | 3 | 13361 (13091-13453) | 37725 (37185-37909) | 411 (410-418) | 3919 (3042-4083) | 3 (3-3) | 12.4 (8.2-12.4) | 0.039 (0.037-0.040) | 9 (9-9) | 3/3 | 3/3 |
| activate | R | 5 | 10369 (9959-10389) | 26510 (25636-26546) | 655 (643-677) | 5935 (5173-5935) | 3 (3-3) | 9.2 (8.4-11.3) | 0.058 (0.055-0.058) | 2 (2-2) | 5/5 | 5/5 |
| complete | L | 2 | 14158 (13711-14605) | 58368 (50359-66376) | 620 (540-701) | 5126 (4356-5896) | 4 (4-5) | 13.1 (10.9-15.3) | 0.054 (0.047-0.060) | 9 (9-9) | 2/2 | 2/2 |
| complete | R | 5 | 7775 (7700-8096) | 28445 (28222-36550) | 703 (700-946) | 1246 (1129-1431) | 4 (4-5) | 12.8 (9.5-16.1) | 0.039 (0.038-0.048) | 3 (3-4) | 5/5 | 5/5 |
| validate | L | 5 | 13565 (12341-13727) | 38068 (35618-38394) | 378 (373-438) | 4775 (1335-5050) | 3 (3-3) | 6.9 (6.6-7.5) | 0.040 (0.031-0.041) | 6 (6-6) | 5/5 | 5/5 |
| validate | R | 5 | 6889 (6883-6889) | 13167 (13161-13167) | 299 (297-299) | 623 (623-623) | 2 (2-2) | 4.5 (4.1-7.4) | 0.021 (0.021-0.021) | 3 (3-3) | 5/5 | 5/5 |

Every one of the 99 runs returned the correct answer.

#### Context above the fixed overhead

The appended skill text costs the `linear.sh` route 5,103 tokens in every session: the baseline peak is 11,230 tokens against 6,127. A session pays that once, however many Linear tasks it runs. The per-task cost is the median peak context minus the route's baseline.

| Task | L above baseline | R above baseline | L output | R output |
| --- | --- | --- | --- | --- |
| read-children | 1933 | 683 | 580 | 418 |
| list-filter | 4266 | 1853 | 1124 | 554 |
| project-get | 2284 | 550 | 353 | 295 |
| cycles | 3841 | 1928 | 839 | 785 |
| project-deps | 745 | 5543 | 407 | 2083 |
| create | 10550 | 2101 | 1914 | 1200 |
| comment | 1218 | 941 | 490 | 637 |
| activate | 2131 | 4242 | 411 | 655 |
| complete | 2928 | 1648 | 620 | 703 |
| validate | 2335 | 762 | 378 | 299 |

### Linear MCP tool definitions

This subsection answers owner principle 1790815161 (KEN-2336 comment of 2026-10-01): the context Linear's MCP tool definitions take at session start in each harness, and whether each harness loads them on demand. MCP is not a task route here.

Linear's MCP server is `https://mcp.linear.app/mcp`, over Streamable HTTP, and accepts an OAuth token or API key as `Authorization: Bearer` [S1]. One `initialize` with the kendex application token, which authenticates at `api.linear.app` from this host, returned HTTP 401 `invalid_token` [R]. The lane had no other non-interactive credential for the kendex application and sent no further MCP request.

Linear's docs publish no tool list with schemas. The definitions come from a third-party capture of `tools/list` against `https://mcp.linear.app/mcp`: `fixtures/mcp-tools-list/linear.raw.json` in pome-sh/digital-twins at commit `8f0f08eb198423cb2b1ea984cc8d0c9d4a83abb9` [S5]. Its metadata records a capture on 2026-08-10 under a `read write` grant, 58 tools, and SHA-256 `c737b527fec275abf693f3718db22875bdae0e9c4f207884af6790b0b4e6465a`; the downloaded file matches that hash (82,866 bytes). The kendex application's client-credentials grant also requests `read,write` (`skills/linear/README.md`), so it sees the same tool set if the server has not changed since the capture. The capture holds no `initialize` response, so the figures below exclude Linear's server instructions.

A stdio MCP server (`replay.py`, a short Python script) answers `initialize` and serves the captured `result` to `tools/list` byte for byte; a check compared the served bytes with the file. Each harness ran a fresh non-interactive session with the prompt "Reply with the single word OK.", once without the server and once with it, two runs each. Every pair of runs gave the same count to within 5 tokens. Each session ran in an empty directory outside the repository, isolated as the table lists:

| Harness | Version | Model | Isolation | Token source |
| --- | --- | --- | --- | --- |
| Claude Code | 2.1.288 | `claude-opus-5-5` (this lane's model) | `--restricted --strict-mcp-config`, tools `Bash,Read,Grep,Glob,ToolSearch` | `result` usage: input, cache-creation and cache-read tokens |
| Codex | 0.160.0 | `gpt-6.1-sol`, the session's default under `--ignore-user-config` | `--ignore-user-config --ignore-rules --disable hooks --ephemeral` | `turn.completed` usage: `input_tokens` |
| Copilot CLI | 1.0.91 | `claude-sonnet-5`, the CLI default | fresh `COPILOT_HOME` holding only the login record, `--no-custom-instructions --disable-builtin-mcps` | `--usage-output-file`: `inputTokens` |
| Pi | 1.0.0 | `github-copilot/claude-opus-5.5`; Pi's configured default provider is an extension this isolation turns off | fresh `PI_CODING_AGENT_DIR` holding only the login record, `-ne -e builtin:mcp -e builtin:codemode -e builtin:tool-search`, no skills or context files | `message_end` usage: input, cache-read and cache-write tokens |

Each harness counts tokens with its own model's tokenizer, so the figures compare modes within a harness, not across harnesses.

#### First-turn context

| Harness | Mode | Without MCP | With Linear MCP | Added |
| --- | --- | --- | --- | --- |
| Claude Code | Tool search (default) | 5,684 | 7,171 | 1,487 |
| Claude Code | `ENABLE_TOOL_SEARCH=false`, all tools loaded | 5,777 | 35,033 | 29,256 |
| Codex | Default | 15,393 | 15,395 | 2 |
| Copilot CLI | Default | 20,839 | 51,119 | 30,280 |
| Pi | `codemode` exposure (default) | 2,330 | 3,093 | 763 |
| Pi | `deferred` exposure | 2,330 | 2,660 | 330 |
| Pi | `direct` exposure, all tools declared | 2,330 | 29,737 | 27,407 |

The Claude Code row for all tools loaded compares two sessions without the `ToolSearch` tool, which Claude Code drops when tool search is off. The skill comparison in § Key Findings ran a third Claude Code configuration, two runs per row: a fresh `HOME`, tools `Bash,Read,Grep,Glob,ToolSearch,Skill`, and the rendered linear skill installed through a session-only `--plugin-dir`, the route that lists a skill under `--restricted`.

#### Loading on demand

| Harness | At session start | Source |
| --- | --- | --- |
| Claude Code | On demand by default: "Only tool names and server instructions load at session start". `ENABLE_TOOL_SEARCH=false` loads every tool up front. A session whose tool set leaves out `ToolSearch` also loaded every tool: 35,127 tokens | [Claude Code MCP docs § Scale with MCP tool search](https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search); measured sessions |
| Codex | On demand: the 58 definitions added 2 tokens. A session asked to find the server's tools found all 58 through search and used 67,827 input tokens summed over that turn's model calls | Measured sessions. [Codex MCP docs](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) do not describe deferral; `codex features list` shows `tool_search_always_defer_mcp_tools` as removed with value true |
| Copilot CLI | All at session start; no setting in `copilot --help` or `copilot help config` defers MCP tools | Measured sessions |
| Pi | Set per server. The default `codemode` exposure declares no MCP tool to the model and lists the server in the system prompt; `deferred` declares tools only after `tool_search` loads them; `direct` declares every tool | Pi's MCP guide, § Control tool exposure, shipped in the installed `@earendil-works/pi-coding-agent` package; measured sessions |

### Requests and cleanup

The ledger holds 392 Linear API requests, all as the kendex application: the 390 below, the lane's completion comment on KEN-2336, and the one refused MCP `initialize`. The MCP and skill sessions made no Linear request.

| Use | Requests |
| --- | --- |
| `linear.sh` route, 44 runs | 249 |
| Raw route, 55 runs | 121 |
| Issue read, activation of KEN-2336, comment reads | 11 |
| Target discovery, one refused filter included | 3 |
| Setup: one batch create, one batch of three comments | 2 |
| Ground truth before the runs; grading with ground truth after | 2 |
| Cleanup: one batch cancel, one verifying read | 2 |

The cap leaves these `linear.sh` cells short of five runs, because one round of that route cost 78 requests against 23 for the raw route:

- list-filter: 2 runs (27 and 28 requests each).
- create: 2 runs (14 and 17).
- complete: 2 runs (9 each).
- activate: 3 runs (9 each).

Every other cell has five runs. A driver started each short-cell run only when the requests left covered that task's pilot cost.

Scratch issues, all Canceled in one `issueBatchUpdate` and confirmed by one read: KEN-2616 to KEN-2653 and KEN-2657 to KEN-2659 (41 issues). KEN-2650 to KEN-2653 and KEN-2657 to KEN-2659 are the issues the create runs made.

### Sources

- [M] Measurements sidecar: every run's measures and grade, the per-task summary, the MCP and skill sessions, the request ledger and the scratch issue list.
- [R] Raw sidecar: what each external source returned, excerpted. The Exa request for this report returned HTTP 401 from this host, so no provider search ran; the lane read the sources below directly.
- [S1] Linear Docs, MCP server.
- [S2] Claude Code docs, Scale with MCP tool search.
- [S3] Pi 1.0.0 MCP guide, Control tool exposure, in the installed `@earendil-works/pi-coding-agent` package.
- [S4] Codex docs, MCP. Its MCP text names no deferral of MCP tools.
- [S5] pome-sh/digital-twins, Linear `tools/list` capture and its metadata.
- [O] KEN-2336 owner comments: rule 1790812464 (2026-09-30) and principle 1790815161 (2026-10-01).

## Tradeoffs / Alternatives

- **`linear.sh` commands**: on simple reads the model reads help text and lists teams first, so the command costs more context and more requests: 9 per activate run against 2. A command wins where the raw query is hard to write within Linear's complexity limit (`projects list-dependencies`) or where it composes several writes (`issues activate`). [M]
- **Raw GraphQL with a short prompt**: the 579-byte prompt gives a 6,127-token baseline against 11,230 for the appended skill text. The model wrote most queries without opening the schema. Every raw first-try failure was Linear's query-complexity limit, which a line in the raw skill text can name. [M]
- **Linear MCP server**: in Claude Code, Codex and Pi's default mode the definitions cost little at session start, and each tool a task loads adds its definition. Copilot CLI loads all 58 definitions at session start. The owner ruled MCP out as a task route because it misses required fields, and this run measured no task through it. [M] [O]

## Recommendation / Decision Criteria

The rule is the owner's: keep a command that is measurably better on context or on first-try success; retire one where raw GraphQL is as good on both. Context below is the per-task cost above the fixed overhead.

Each retire line takes effect only through a change that follows owner rule 1790812464: the same change moves every call site, reference and instruction to the new route, and the removed verb prints its replacement and exits nonzero.

The Linear MCP server does not change these verdicts. The owner's rule keeps CLI plus skill unless a measured MCP route wins on the same tasks, and no task here ran through MCP. At session start in Claude Code, the skill's listing line costs 46 tokens against 1,487 for the deferred MCP server; once used, 5,362 against 6,283 for three loaded tools (§ Key Findings, Skill against MCP in Claude Code).

### Per command

| Command | Verdict | Numbers (L against R) |
| --- | --- | --- |
| `issues get` with `issues children` | Retire | 1,933 against 683 tokens; first try 5/5 against 5/5 |
| `issues list` | Retire | 4,266 against 1,853 tokens; first try 2/2 against 5/5; 28 against 1 requests |
| `projects get` | Retire | 2,284 against 550 tokens; first try 5/5 against 5/5 |
| `cycles list` | Retire | 3,841 against 1,928 tokens; first try 1/5 against 0/5, no measurable difference |
| `projects list-dependencies` | Keep | 745 against 5,543 tokens; first try 5/5 against 1/5, and all 4 raw failures were Linear's query-complexity limit |
| `issues create` with `issues add-relation` | Retire | 10,550 against 2,101 tokens; first try 0/2 against 0/5 |
| `comments create` | Retire | 1,218 against 941 tokens read, 490 against 637 written; first try 5/5 against 5/5 |
| `issues activate` | Keep | 2,131 against 4,242 tokens; 411 against 655 output tokens; first try 3/3 against 5/5 |
| `issues complete` | Retire | 2,928 against 1,648 tokens; first try 2/2 against 5/5 |
| `issues validate-completion` | Retire | 2,335 against 762 tokens; first try 5/5 against 5/5 |

### Per command family

Each family line names only the commands a task measured. A command no task measured has no verdict.

- **Issue reads**: retire `issues get`, `issues children` and `issues list`. Raw costs less context on both tasks (683 against 1,933 tokens; 1,853 against 4,266), and both routes succeed first try on every run. Unmeasured: `issues bulk-get`, `issues list-relations`.
- **Issue writes**: retire `issues create`, `issues add-relation`, `comments create` and `issues complete`; keep `issues activate`. Unmeasured: `issues update`, `issues bulk-update`, `issues archive`, `issues trash`, `issues remove-relation`, `issues block`, `issues unblock`, `comments list`, `comments update`, `comments delete`.
- **Completion check**: retire `issues validate-completion`, on the condition in § Risks / Unknowns.
- **Planning reads**: retire `projects get` and `cycles list`; keep `projects list-dependencies`. Unmeasured: `projects list`, `projects list-updates`, `cycles create`, `cycles update`, and every project write.
- **Other families** (`labels`, `project-labels`, `initiatives`, `milestones`, `teams`, `users`, `statuses`, `documents`, `auth-check`, `auth-mint`, `session-status`, and `sync` and `cache`, which KEN-2335 removes): unmeasured.


## Risks / Unknowns

- **Stand-in**: the measured route is today's `linear.sh` and its 15,393-byte skill text. KEN-2335 changes both; its thin layer can change every number in the L rows.
- **Small cells**: four `linear.sh` cells have two or three runs. A first-try count of 0/2 or 3/3 cannot separate the routes.
- **Rule in the prompt**: the validate prompt states the pass rule. `validate-completion` also encodes the bundle and container rules (`issues --help`), which this task did not exercise. Retiring it needs that rule text in the skill the raw route reads.
- **One model**: every run used Claude Opus 5.5 at high effort, which knows Linear's API without the schema. A model with less prior knowledge of Linear can need the schema on every task.
- **Fixed overhead**: the task runs appended the 5,103-token skill text to every session. A harness that loads the skill only when invoked pays 46 tokens for its listing line until then. A smaller skill after KEN-2335 lowers both.
- **MCP tool list**: the MCP figures replay a third-party capture from 2026-08-10, not a `tools/list` this lane read, and exclude Linear's server instructions. A change to Linear's tool set since then changes the figures.
- **MCP on tasks**: no task ran through MCP, so the MCP figures cover session start and tool loading only.

## Revisit Conditions

- KEN-2335 merges: re-run every L row against the thin layer.
- `--team` accepts the team key (KEN-2664): re-run cycles and create on the `linear.sh` route.
- The raw skill text names Linear's query-complexity limit: re-run cycles, create and project-deps on the raw route. The keep verdict on `projects list-dependencies` rests on that limit.
- A different model or effort becomes the lane default.

## Research Metadata

- Runs: 99 (44 `linear.sh`, 55 raw), 2026-10-03, Claude Code 2.1.288. MCP and skill sessions: Claude Code 2.1.288, Codex 0.160.0, Copilot CLI 1.0.91, Pi 1.0.0.
- Session cost: USD 2.06 for the `linear.sh` route and USD 2.19 for the raw route.
- Linear issue: KEN-2336. Team KEN, id `53d3175c-fcb0-49ce-9f82-286a5b77372e`.
- Research mode: measurement. The Exa request returned HTTP 401, so the raw sidecar holds directly read source excerpts and no provider payload.
- Raw metadata sidecar: docs/plans/linear-command-value-research.raw.json
- Measurements sidecar: docs/plans/linear-command-value-research.evidence.json
- Per-run traces, prompts, wrapper logs, the request ledger and the grading data stay in the lane's gitignored `tmp/ken-2336-runs/`; the sidecars carry the sanitized measures.

[M]: linear-command-value-research.evidence.json
[R]: linear-command-value-research.raw.json
[S1]: https://linear.app/docs/mcp
[S2]: https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search
[S3]: https://www.npmjs.com/package/@earendil-works/pi-coding-agent
[S4]: https://learn.chatgpt.com/docs/extend/mcp?surface=cli
[S5]: https://github.com/pome-sh/digital-twins/blob/8f0f08eb198423cb2b1ea984cc8d0c9d4a83abb9/fixtures/mcp-tools-list/linear.meta.json
