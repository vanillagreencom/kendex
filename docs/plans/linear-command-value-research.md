# Findings: linear.sh commands against raw GraphQL

## Setup and deviations

KEN-2335, the thin-layer rewrite of `linear.sh`, has not merged. This run measures the live `linear.sh` commands on branch `ken-2336` at commit `1a632318` as the stand-in, with no `cache` or `sync` command. The `linear` skill's last change on that branch is commit `f2522e08`.

Each run is one headless Claude Code session: `claude -p --model claude-opus-5-5 --effort high --output-format stream-json --verbose --no-session-persistence --restricted --tools Bash,Read,Grep,Glob --strict-mcp-config --disable-slash-commands --permission-mode dontAsk --allowedTools Bash Read Grep Glob --max-budget-usd 3`, under a 900-second timeout. The two routes use the same model, effort and task prompt.

| Route | Appended system prompt | Size |
| --- | --- | --- |
| `linear.sh` | The rendered `.agents/skills/linear/SKILL.md`, plus the absolute path of `linear.sh` and one line that forbids `sync` and `cache` | 15,393 bytes |
| Raw GraphQL | The endpoint, the token variable `LINEAR_TOKEN`, the header `Authorization: Bearer $LINEAR_TOKEN`, the schema path, the team key KEN, and "call the API with curl" | 579 bytes |

The schema is Linear's `packages/sdk/src/schema.graphql` at `linear/linear` commit `b37823be308a42f837277671f3ded66d33d92e6c` (1,335,039 bytes).

Each child runs in an empty directory outside the repository, so no `AGENTS.md` or `CLAUDE.md` loads; the init event lists no MCP server, skill or slash command. A `curl` wrapper first on the child's `PATH` logs each call and refuses past the request cap. Both routes reach Linear only through `curl`. With `LINEAR_APP_TOKEN` set, `linear.sh` sends the token and makes no token request (`scripts/lib/auth.sh`, `linear_authorization`).

Deviations from the delegated method:

- **Credential**: the host has `LINEAR_APP_TOKEN`, the kendex application token, and no client pair, so `auth-mint` cannot run. Both routes receive that token through the child's environment only.
- **Network**: the token is a placeholder that the host's proxy substitutes. Each child keeps the proxy and CA variables, or every call fails authentication.
- **`linear.sh` working directory**: `linear.sh` refuses to run outside a git repository. Each `linear.sh` child runs in a fresh `git init` directory that holds a copy of `kendex.settings.toml` and nothing else, so `LINEAR_TEAM` and the create guards load and each run starts with no cache.
- **Raw schema path**: `--restricted` confines the file tools to the working directories. The schema sits in a fixtures directory outside the repository, passed with `--add-dir`.
- **Trace format**: `stream-json` replaces `json`. Its final `result` event carries the same measures, and the stream carries the tool trace.
- **Writes**: the issue body names one throwaway project. The binding brief limits writes to scratch issues titled "KEN-2336 scratch", so this run creates no project.
- **Run counts**: the request cap leaves the `linear.sh` route of four tasks short of five runs. See § Requests and cleanup.

## Tasks and grading

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

## Results by task and route

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

### Context above the fixed overhead

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

## Recommendation

The rule is the owner's: keep a command that is measurably better on context or on first-try success; retire one where raw GraphQL is as good on both. Context below is the per-task cost above the fixed overhead.

### Per command family

- **Issue reads** (`issues get`, `issues children`, `issues bulk-get`, `issues list`): retire. Raw costs less context on both tasks (683 against 1,933 tokens; 1,853 against 4,266), and both routes succeed first try on every run.
- **Issue writes** (`issues create`, `issues add-relation`, `comments create`, `issues activate`, `issues complete`): retire every command except `issues activate`, which stays.
- **Completion check** (`issues validate-completion`): retire, on the condition in § Risks and unknowns.
- **Planning reads** (`projects get`, `cycles list`, `projects list-dependencies`): retire `projects get` and `cycles list`; keep `projects list-dependencies`.

### Per command

| Command | Verdict | Numbers (L against R) |
| --- | --- | --- |
| `issues get` with `issues children` | Retire | 1,933 against 683 tokens; first try 5/5 against 5/5 |
| `issues list` | Retire | 4,266 against 1,853 tokens; first try 2/2 against 5/5; 28 against 1 requests |
| `projects get` | Retire | 2,284 against 550 tokens; first try 5/5 against 5/5 |
| `cycles list` | Retire | 3,841 against 1,928 tokens; first try 1/5 against 0/5, no measurable difference |
| `projects list-dependencies` | Keep | 745 against 5,543 tokens; first try 5/5 against 1/5 |
| `issues create` with `issues add-relation` | Retire | 10,550 against 2,101 tokens; first try 0/2 against 0/5 |
| `comments create` | Retire | 1,218 against 941 tokens read, 490 against 637 written; first try 5/5 against 5/5 |
| `issues activate` | Keep | 2,131 against 4,242 tokens; 411 against 655 output tokens; first try 3/3 against 5/5 |
| `issues complete` | Retire | 2,928 against 1,648 tokens; first try 2/2 against 5/5 |
| `issues validate-completion` | Retire | 2,335 against 762 tokens; first try 5/5 against 5/5 |

## Key findings

### Failure causes

- **Raw route, query complexity**: Linear refuses a query above complexity 10,000 with "Query too complex". The model's first query hit that limit in 5 of 5 create runs, 5 of 5 cycles runs and 4 of 5 project-deps runs. Each time it narrowed the query and then succeeded. The complexity came from nested connections with large page sizes, such as all team labels and states in one query.
- **`linear.sh` route, team key**: `cycles list --team KEN` and `issues create --team KEN` refuse with "Team not found: KEN"; the flag takes the team name, `kendex`. That refusal caused the failed call in 4 of 5 cycles runs and 1 of 2 create runs. The other create run failed on the model's own `jq` filter over `issues get` output, then re-ran the read.
- **`linear.sh` route, dependency direction**: in one project-deps run the model read `projects.sh` to learn which direction `list-dependencies` reports, then answered correctly.

### Request cost

- One `issues activate` call made 8 requests in the lane's own activation of KEN-2336. Every `linear.sh` activate run made 9; the raw runs made 2.
- One `issues validate-completion` call on three issues made 6 requests. The raw runs made 3.
- `issues list --max` pages through every match. Both `linear.sh` list-filter runs also listed every Done issue to cross-check the label filter, at 27 and 28 requests.
- Across 39 task runs the `linear.sh` route made 31 `--help` calls and 25 `teams list` or `auth-check` calls before or beside the task command.
- The raw route read the schema file only in the 5 project-deps runs. In every other raw run the model wrote the queries without it.

## Requests and cleanup

The ledger holds 390 Linear API requests at the time of this report, all as the kendex application. The lane's completion comment on KEN-2336 adds one.

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

## Risks and unknowns

- **Stand-in**: the measured route is today's `linear.sh` and its 15,393-byte skill text. KEN-2335 changes both; its thin layer can change every number in the L rows.
- **Small cells**: four `linear.sh` cells have two or three runs. A first-try count of 0/2 or 3/3 cannot separate the routes.
- **Rule in the prompt**: the validate prompt states the pass rule. `validate-completion` also encodes the bundle and container rules (`issues --help`), which this task did not exercise. Retiring it needs that rule text in the skill the raw route reads.
- **One model**: every run used Claude Opus 5.5 at high effort, which knows Linear's API without the schema. A model with less prior knowledge of Linear can need the schema on every task.
- **Fixed overhead**: the 5,103-token skill text is a per-session cost in this run. A smaller skill after KEN-2335 lowers it.
- **MCP comparison**: the owner's note of 2026-10-01 asks this item to report the per-harness context cost of Linear's MCP tool definitions and whether each harness loads them on demand. The binding brief excludes the MCP route, so this run does not measure it.

## Revisit conditions

- KEN-2335 merges: re-run every L row against the thin layer.
- `--team` accepts the team key, or the raw skill text names the complexity limit: re-run cycles and create.
- A different model or effort becomes the lane default.

## Research metadata

- Runs: 99 (44 `linear.sh`, 55 raw), 2026-10-03, Claude Code 2.1.288.
- Session cost: USD 2.06 for the `linear.sh` route and USD 2.19 for the raw route.
- Linear issue: KEN-2336. Team KEN, id `53d3175c-fcb0-49ce-9f82-286a5b77372e`.
- Per-run traces, prompts, wrapper logs, the request ledger and the grading data stay in the lane's gitignored `tmp/ken-2336-runs/`.
