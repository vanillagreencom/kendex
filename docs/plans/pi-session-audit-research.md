# Findings: Pi lane session audit

## Research Question

Does Pi with the kendex Pi extensions waste tokens, raise errors, force workarounds or fail more often than Claude Code and Copilot CLI on the same class of item? Which of those costs do our extensions cause, and what is the root cause of each, with file and line?

## Executive Summary

Verdict: on the same model (claude-opus-5.5), Pi with our extensions and Claude Code close items with the same overseer rulings, relaunches and fix rounds, and a similar wall time (Pi 64–66 items, Claude Code 145–148). Pi lanes send more lane-mail asks. Pi's token cost on that model is too small to judge (2 items). Copilot CLI led no lane in the sample, so it is not compared. [E]

- The sample is 462 items with a kept close record, across 11 repositories, dated 2026-10-01 or later: one archive line per item. 357 are work items with a known lead harness: Pi 139, Claude Code 164, Codex 54. [E]
- Measure 1 (tokens) rests on 8 merged Pi items, 6 of them on gpt-6.1-sol. Pi's median is 139.8M tokens per item against Claude Code's 57.5M (126 items). The model, not the harness, can explain that gap. Per model, every Pi token cell is too small to judge. [E]
- Measures 2 and 3 (context and tool errors) are not sampled (n=0). No Pi lane was open when the overseer read the fleet, and a close keeps no transcript (FLT-671). § Static context cost gives code-derived figures instead. [O]
- Three extension root causes stand. KEN-2683 covers the two pi-task-panel prompt-cache breaks. KEN-2686 covers a disabled pi-questions that still adds its 1,676-byte instructions to every Pi request. The pi-output-policy finding is dropped. [S]

## Key Findings

- Same model, same outcome. On claude-opus-5.5, Pi and Claude Code both take a median of 2 overseer rulings per item (p90 6 both; n 66 and 148). Their median wall time from launch to merge is 7,866.5 s and 8,722 s (p90 19,989 and 27,030; n 64 and 145). Their median fix rounds are 1 and 1 (n 19 and 29). [E]
- Pi lanes ask more. Per item, Pi sends a median of 1 lane-mail ask on claude-opus-5.5 against Claude Code's 0 (p90 2 both; n 65 and 145). On gpt-6.1-sol, Pi's median is 3 (p90 10, n 72). Pi's median is above Claude Code's in 4 of the 5 judged matched strata. In kendex runtime items estimated 3 or more, the medians are 6 and 1 (n 13 and 15). [E]
- Over the items the ask row counts (Pi 137, Claude Code 159), 162 of Pi's 338 asks report a failing validation receipt, against 34 of Claude Code's 117 (`ask_groups`, rule `ASK_GROUPS` in `measure.py`). These asks name repository checks: test suites, validation bounds, CI. They are repository-class costs. No kept record ties one to a Pi extension. [E]
- Measures 4 and 5 charge an item to its final lead harness. The 9 items that hold Pi tokens under another lead count under Codex (7) or Claude Code (2). One of them (FLT-643) ran Pi on claude-opus-5.5 and sits in that model's Claude Code row. [E]
- Nine items hold Pi tokens under another lead harness: 7 under Codex, 2 under Claude Code. Their Pi token medians are 252.3M and 220.2M, the size of whole lanes. Copilot and Codex tokens under Claude Code leads are 0.5M–4.1M (6 items), the size of a second opinion. [E]
- Pi's token records are sparse. Token records start at 2026-10-02T03:27Z, so 131 of 139 Pi-led items have none. [E]
- No token record is incomplete. No item has `unreadable` or `unrecorded` above 0 for any harness, no count is null, and no model row was refused. [E]

## Results

### Measure-by-harness table

Every cell is n / items / median / p90, or n / items / share for a 0-or-1 measure. A cell with fewer than 8 Pi items in its measure reads "too small to judge". Codex is outside the comparison; its cells give n only. Exact values are in [pi-session-audit-research.evidence.json](pi-session-audit-research.evidence.json), `all`. [E]

| Measure | Unit | Source | Pi with our extensions | Claude Code | Copilot CLI | Codex (n) |
|---|---|---|---|---|---|---|
| 1 input tokens per merged item | item | `tokens-*.json` `[0]`, lead harness only | 8 / 8 / 2,864 / 159,822 | 126 / 126 / 913 / 2,768 | not sampled (n=0) | 36 |
| 1 output tokens per merged item | item | `[1]` | 8 / 8 / 174,342 / 616,508 | 126 / 126 / 186,964 / 566,085 | not sampled (n=0) | 36 |
| 1 cache read tokens per merged item | item | `[2]` | 8 / 8 / 137.1M / 383.4M | 126 / 126 / 55.6M / 145.8M | not sampled (n=0) | 36 |
| 1 cache write tokens per merged item | item | `[3]` | 8 / 8 / 3.46M / 5.86M | 126 / 126 / 1.40M / 4.57M | not sampled (n=0) | 36 |
| 1 total tokens per merged item | item | sum of the four | 8 / 8 / 139.8M / 390.1M | 126 / 126 / 57.5M / 150.3M | not sampled (n=0) | 36 |
| 2 context measures (5 rows) | session | live transcript | not sampled (n=0) | not sampled (n=0) | not sampled (n=0) | — |
| 3 tool calls and errors by class (6 rows) | session | live transcript | not sampled (n=0) | not sampled (n=0) | not sampled (n=0) | — |
| 4 relaunches per item | item | `fleet_log` rows naming relaunch | 139 / 139 / 0 / 1 | 154 / 154 / 0 / 1 | not sampled (n=0) | 54 |
| 4 overseer rulings per item | item | `fleet_log` kind `ruling` | 139 / 139 / 2 / 6 | 154 / 154 / 2 / 6 | not sampled (n=0) | 54 |
| 4 lane-mail asks per item | item | the item's own `to-overseer.jsonl`, one per envelope id | 137 / 137 / 1 / 7 | 159 / 159 / 0 / 2 | not sampled (n=0) | 52 |
| 4 candidate harness-defect asks per item | item | asks naming harness words | 137 / 137 / 0 / 1 | 159 / 159 / 0 / 1 | not sampled (n=0) | 52 |
| 4 turns ended with work owed | session | live transcript | not sampled (n=0) | not sampled (n=0) | not sampled (n=0) | — |
| 5 share stopped, parked or paused | item | lane record `status`, `parked`, `pauses` | 139 / 139 / 1.4% (2) | 154 / 154 / 3.9% (6) | not sampled (n=0) | 54 |
| 5 share not merged | item | lane record `cycle.stamps.merged`; 0 by construction | 137 / 137 / 0.0% (structural) | 151 / 151 / 0.0% (structural) | not sampled (n=0) | 53 |
| 5 wall seconds, launch to merge, less pauses | item | lane record `cycle.stamps`, `pauses` | 137 / 137 / 11,753 / 37,389 | 151 / 151 / 8,455 / 26,953 | not sampled (n=0) | 53 |
| 5 fix rounds per merged item | item | lane record `cycle.rounds.fix` | 56 / 56 / 0 / 2 | 31 / 31 / 1 / 3 | not sampled (n=0) | 31 |

Fix rounds cover fewer items because `cycle.rounds` is null where the lane's state was gone when the cycle was recorded. The kept records cannot show an unmerged item: oversee-cycle writes a lane's `cycle` at merge, so a lane without one reads unknown, and the not-merged share is 0 of every known item. Telling a cycle-less lane's outcome needs `gh pr view` (Read procedure step 5).

Lane-mail rows leave out 9 items whose schema-1 archive line read another item's mailbox (the overseer's, or test scratch mailboxes): Pi 2, Claude Code 5, Codex 2 (`foreign_mailbox_items_by_lead`).

### Model mix

The provider was not held fixed. Every Pi lane ran through the `github-copilot` provider, and Claude Code calls Anthropic directly. Lane records name each lane's model; token records name the model, with the provider for Pi. [E]

| Harness | Lane records: model (items) | Token records: model (records) |
|---|---|---|
| Pi | github-copilot/claude-opus-5.5 (66), github-copilot/gpt-6.1-sol (73) | github-copilot/claude-opus-5.5 (2), github-copilot/gpt-6.1-sol (6) |
| Claude Code | claude-opus-5-5 (148), claude-fable-5-1 (4), fable (2) | claude-opus-5-5 (144), claude-fable-5-1 (7) |
| Codex | gpt-6.1-sol (47), gpt-6-sol (7) | gpt-6.1-sol (42), gpt-6-sol (1) |

### Same model: claude-opus-5.5

`by_model` in the evidence file holds every measure per model. These rows compare Pi and Claude Code on one model. [E]

| Measure | Pi | Claude Code |
|---|---|---|
| 1 total tokens per merged item | 2 items: too small to judge | 119 items: too small to judge |
| 4 relaunches per item | 66 / 66 / 0 / 0 | 148 / 148 / 0 / 1 |
| 4 overseer rulings per item | 66 / 66 / 2 / 6 | 148 / 148 / 2 / 6 |
| 4 lane-mail asks per item | 65 / 65 / 1 / 2 | 145 / 145 / 0 / 2 |
| 5 share stopped, parked or paused | 66 / 66 / 0.0% (0) | 148 / 148 / 4.1% (6) |
| 5 share not merged | 64 / 64 / 0.0% (structural) | 145 / 145 / 0.0% (structural) |
| 5 wall seconds, launch to merge, less pauses | 64 / 64 / 7,866.5 / 19,989 | 145 / 145 / 8,722 / 27,030 |
| 5 fix rounds per merged item | 19 / 19 / 1 / 3 | 29 / 29 / 1 / 3 |

Pi on gpt-6.1-sol has a median wall time of 15,879 s (p90 48,125; n 73) and a median of 3 asks (p90 10; n 72). Codex runs the same model and is outside the comparison.

### Matched strata and unmatched totals

A stratum is one repository, one `agent:*` label and one estimate band (1–2, 3+), read from the tracker for every item (§ Comparison). A stratum is matched when it holds a Pi item and a Claude Code or Copilot CLI item. 11 strata match. A stratum is judged only when it holds at least 8 Pi items. [E]

- Measure 1: three matched strata hold all 8 Pi token items, at most 6 in one. None is judged, so every matched Pi token cell is too small to judge.
- Measures 4 and 5: five strata are judged, except fix rounds, where no stratum reaches 8 Pi items. A Claude Code cell under 8 items, such as kendex rust (2), carries little weight.

| Stratum | Pi asks | Claude Code asks | Pi rulings | Claude Code rulings | Pi wall s | Claude Code wall s |
|---|---|---|---|---|---|---|
| fleet, agent:maintainer, 1–2 | 18: 0 / 1 | 10: 0.5 / 2 | 19: 1 / 6 | 10: 3 / 4 | 19: 5,607 / 13,576 | 10: 3,134 / 12,666 |
| fleet, agent:runtime, 1–2 | 21: 1 / 2 | 15: 0 / 2 | 21: 1 / 4 | 19: 3 / 6 | 19: 5,832 / 19,853 | 19: 6,010 / 18,333 |
| kendex, agent:runtime, 1–2 | 24: 2 / 5 | 46: 0 / 2 | 24: 1 / 5 | 46: 1 / 4 | 24: 15,514.5 / 36,342 | 46: 12,042.5 / 27,030 |
| kendex, agent:runtime, 3+ | 13: 6 / 14 | 15: 1 / 6 | 14: 2 / 5 | 15: 3 / 12 | 14: 24,251.5 / 55,353 | 14: 28,338 / 71,369 |
| kendex, agent:rust, 1–2 | 8: 2.5 / 11 | 2: 0 / 0 | 8: 0 / 3 | 2: 0.5 / 1 | 8: 11,556 / 27,728 | 2: 9,981 / 11,990 |

Each cell is n: median / p90. Unmatched totals, outside every matched stratum: asks Pi 29 items, median 1 / p90 6, against Claude Code 39, median 0 / p90 2; wall time Pi 31, median 5,104 / p90 24,696 s, against Claude Code 30, median 3,308 / p90 9,332 s. The evidence file's `unmatched` holds every measure.

### Static context cost

These figures are static: read from the installed packages and fleet harness settings on this sandbox, not from a lane. They are the context our packages add to each Pi request before the first message. [S]

| Source | Bytes | How measured |
|---|---|---|
| `instructions.md` blocks in `APPEND_SYSTEM.md`: pi-agents-tmux 7,420, pi-background-tasks 3,434, pi-session-bridge 3,165, pi-web-tools 2,073, pi-questions 1,676, pi-task-panel 1,131 | 18,899 | `kendex:append-system` markers in the installed `~/.pi/agent/APPEND_SYSTEM.md`, equal to each package's `instructions.md` |
| 19 active tool definitions from our packages (name, description, parameters): pi-agents-tmux 7 tools 10,792, pi-web-tools 7 tools 7,084, pi-background-tasks 2 tools 2,365, pi-tool-renderer `tool_batch` 1,434, pi-task-panel `tasks_write` 694, pi-codex-minimal-tools `apply_patch` 459 | 22,828 | Pi 1.0.1 SDK `createAgentSession` with the fleet harness settings, then `getAllTools()` and `getActiveToolNames()` |
| Pi's 7 built-ins that pi-tool-renderer registers again with their own contract | 4,746 | same; Pi's cost, not ours |
| `before_agent_start` forced prompts (pi-task-panel active task, pi-agents-tmux project agents) | not measured | not in any transcript or SDK prompt read |

The fleet settings disable pi-questions (`enabled: false`), so no `question` tool is registered. Its 1,676-byte block is still in the prompt (§ Extension root causes, rank 2).

### Extension root causes

Ranked by cost per affected request. [S]

| Rank | Root cause | Where | Cost | Fix item |
|---|---|---|---|---|
| 1 | pi-task-panel returns a forced system prompt that quotes the active task. Each change of active task changes the request's leading prompt, so the next request writes the whole context to the prompt cache again. | `pi-extensions/pi-task-panel/extensions/task-panel.ts:1290-1296`, text from `:730-733` | one cache write of the whole context per active-task change; count unmeasured (measure 2 not sampled) | KEN-2683 |
| 1 | The same package's `context` handler keeps only the newest task-context message. The cache break lands at the previous agent start's task-context message on each agent start; it lands earlier only when the last task completes or `showWorkflowReminder` is off. | `pi-extensions/pi-task-panel/extensions/task-panel.ts:1278-1287` | one cache write from that message on, per agent start; count unmeasured | KEN-2683 (folded: same two handlers, one PR) |
| 2 | A package disabled in its kendex settings keeps its `APPEND_SYSTEM.md` block. kendex writes the block at install without reading the package's `enabled` setting. pi-questions then registers nothing (`questions.ts:994`), but its instructions still tell every Pi request to use a `question` tool that does not exist. | `crates/core/src/pi_ext/mod.rs:405-421`; `pi-extensions/pi-questions/extensions/questions.ts:994` | 1,676 bytes on every Pi request, fleet-wide | KEN-2686 |
| — | pi-output-policy's minimize-only path records no byte meta. | `pi-extensions/pi-output-policy/extensions/output-policy.ts:729-735` | none in tokens | Dropped: the result text already carries the visible `[output-policy:minimized-lines=N]` notice that `measure.py` counts; only the pre-minimizer byte figure is missing, and no user or operator decision depends on it. |

Pi's cache-write median per merged item is 3.46M against Claude Code's 1.40M (8 and 126 items). That fits rank 1 but does not show it: 6 of the 8 Pi items ran another model.

### Costs with another class

These are listed with their class. They file nothing.

| Cost | Class | Evidence |
|---|---|---|
| Pi lanes ask the overseer more; 162 of 338 Pi asks report a failing validation receipt | repository | ask excerpts name test suites, validation bounds and CI; no kept record names a Pi extension |
| Pi on gpt-6.1-sol runs longer (median 15,879 s) and asks more (median 3) than Pi on claude-opus-5.5 | model | `by_model` rows; one harness, two models |
| Pi's measure-1 token medians exceed Claude Code's | model (6 of 8 Pi items on gpt-6.1-sol) and provider (github-copilot against Anthropic), not separable at n=8 | § Model mix |
| Nine items moved off Pi to Codex (7) or Claude Code (2) after Pi spent a median of 252.3M and 220.2M tokens | not attributable from kept records: the fleet log text that says why is not in the archive lines | `tokens_under_another_lead` |

## Method

### Sample

- Close records: every kept close record dated 2026-10-01 or later, across every repository and fleet under `/home/admin/.fleet/archive/<repo>/<item>/`, plus each new close. A close keeps a `tokens-<sandbox-id>.json`, a `tmp-*.tgz`, or both. An item enters the sample when its archive directory holds either one dated on or after `--since`. Of the 462 items, 219 hold both, 188 only a `tmp-*.tgz` (token records start 2026-10-02T03:27Z) and 55 only a token record. [R] [E]
- Live Pi lanes: measures 2 and 3 need a transcript, and a close keeps none (FLT-671). They come only from Pi lanes still open, read before close. At the read none was open in kendex, fleet, vg or talk, and none was routed. [R] [O]
- No routing change and no Copilot spend. [R]
- Excluded: 77 probe keys, such as `proof-02328f9`, `proof-3342777` and `fleet-probe-v23-max`, and 28 tracker items with neither a lane record nor exactly one harness with tokens. `measure.py` owns the rule (`work_item_id`) and reads no environment: a key is a tracker item when it has a tracker id's shape (`ABC-123` in any case, or a GitHub `issue-123`) and, with `--issues`, an entry in the tracker data. A GitHub key names an item only within its repository, so its id is `<repo>/issue-123`; the sample holds none. [E]

### Comparison

The comparison is the harness mix the kept records hold. No harness needs a matched sample. Codex is outside the comparison; its n is listed. [R]

`aggregate` reports three views: all items per lead harness (`all`), per model family (`by_model`), and per matched stratum with the unmatched totals (`matched`, `unmatched`). The stratum key is the archive directory's repository, the item's `agent:*` label and its estimate band. Label and estimate come from the tracker through `--issues`, since no kept record holds them. An estimate of 0 or none, or an item with no or several agent labels, is unmatched. The lane record's `tier_inputs.estimate` is item-tier's estimate of added production lines, not the tracker estimate, so it is not used. [S]

The lead harness is the lane record's `harness`, else the one harness with tokens. A relaunch rewrites that field, so measures 4 and 5 charge a moved item to its final lead: an item that ran Pi and then Codex counts under Codex. An item whose token records hold another harness beside the lead is left out of measure 1 and counted in `mixed_token_items_by_lead` and `tokens_under_another_lead`.

### Reporting rule

- Every figure carries its source and its sample size n. `aggregate` puts `source` on every measure, and n and the item count on every cell.
- A measure, model row or stratum with fewer than 8 Pi items reads "too small to judge" in every cell. The cell keeps n and drops the median and p90. It is never a finding. `MIN_PI_ITEMS` in `measure.py` holds the 8.
- A measure with no input at all reads "not sampled (n=0)".
- Median is the middle value, or the mean of the two middle values for an even n. p90 is the nearest-rank 90th percentile. A 0-or-1 measure reports the share.

### Read procedure

An overseer-briefed control-host subagent runs every read, with the script as its input. The script itself writes no file.

| Step | Mode | Where | Command |
|---|---|---|---|
| 0 | tests | the checkout the script comes from | `python3 docs/plans/pi-session-audit/test_measure.py`; stop on any failure |
| 1 | `archive` | control host | `measure.py archive --root /home/admin/.fleet/archive --oversee-state REPO=<repo>/tmp/workflow-state-oversee.json ... > items.jsonl` |
| 2 | `live` | each open Pi lane's sandbox, before close | `python3 - live --item ITEM --repo REPO`, through `lane-host-daytona exec --item ITEM` with `measure.py` on stdin |
| 3 | tracker read | any checkout | `linear.sh issues bulk-get ID...` for every tracker item, saved as `{item: {estimate, agent}}` |
| 4 | `aggregate` | any checkout | `measure.py aggregate --issues issues.json items.jsonl.gz [live.jsonl]` |
| 5 | outcome | any checkout | `gh pr view N --json state,mergedAt` for a lane with no `cycle` record, where its outcome matters |

`archive` prints one line per item with a token record or a tmp archive dated on or after `--since` (default 2026-10-01): a token record's `at`, else the file's modification time. It prints `df -h /` before each item and stops with exit 3 under 3 GB free; lines already printed are complete. It lists each archive with `tar -tzf` and reads one member at a time with `tar -xzOf ARCHIVE -- MEMBER`, never extracting an archive, and refuses a member over 16 MiB. A close archive can hold the lane mailbox twice (the worktree's and the close-out evidence copy); `archive` and `aggregate` count each envelope id once. A close archive also holds other mailboxes, the overseer's and test scratch ones; `archive` reads only `lane-mail/<item>/to-overseer.jsonl`, and `aggregate` leaves out the asks of a schema-1 line that read another. The subagent runs no `git log -S`, `-G` or `--all -p`, and writes no bulk data.

### Token-record field meanings

The overseer confirmed these from `/opt/fleet/lib/lane_host/tokens.py` lines 8–14 and the KEN-2598 record. [O]

| Field | Meaning |
|---|---|
| `models.<model>[0]` | input tokens; never includes cache reads |
| `models.<model>[1]` | output tokens |
| `models.<model>[2]` | cache read tokens |
| `models.<model>[3]` | cache write tokens; a Codex row can carry null |
| total | the sum of the four |
| `files` | transcript files the read at close found for that harness |
| `unreadable` | files and directories the read could not open |
| `unrecorded` | sessions whose usage record is missing |
| `at` | the control VM's time of the read at close |

Either count above 0 marks that harness's figure for that item incomplete. A null count does too: `archive` keeps the row's known counts, leaves the null as null and names it in the row's `unknown`. `archive` refuses a count list of another length, or with a value neither a whole number nor null, as `token-record-shape`, and `aggregate` marks that harness incomplete as well. An incomplete harness still counts as present, so a side run it hides keeps the item out of measure 1. `incomplete_token_items_by_harness` counts them, and measure 1 leaves an incomplete lead out. Codex rows subtract cached input from input.

### Live measures

`live` reads `.pi/agent/sessions`, `.pi/agent/kendex/sessions` (pi-agents-tmux subagents), `.claude-shared/projects`, `.claude/projects` and `.copilot*/session-state`. Per session it reports token totals. For Pi it also reports the prompt sections after replaying every system message, the `addendum` bytes per package marker, tool definition bytes per owning package, `custom` and `custom_message` bytes per owner, nested `AGENTS.md` parts, and tool-result bytes before and after the pi-output-policy budget. For every harness it reports tool calls, errors by class and Stop-hook refusals. `measure.py --help` holds the schema. The measures are the issue's. [I]

| Harness | What `live` reads | Interface it stands in for, and why that cannot serve |
|---|---|---|
| Pi | session JSONL | none: the format is Pi's documented interface, the package's Session File Format and Message Types documents |
| Claude Code | project transcript JSONL | the Agent SDK's `listSessions`, `getSessionMessages` and `getSubagentMessages`: they need the Node package in the lane sandbox, where `live` runs as stdlib Python on stdin and writes nothing; `getSessionMessages` returns only the parent chain, dropping billed branches, and types each message body, usage included, as `unknown` |
| Copilot CLI | `session-state/<id>/events.jsonl` | the Copilot SDK's `resumeSession(...).getEvents()`: it starts a Copilot CLI process and resumes the session, which a read must not do to a live lane |

A `before_agent_start` handler that returns `systemPrompt` sets a forced prompt Pi sends without recording it, so `live` reports those appends as "not recorded". Copilot CLI usage comes only from `session.shutdown` `modelMetrics`; `assistant.usage` is ephemeral and never reaches `events.jsonl`. [C]

### Error classification

One table in `measure.py` (`ERROR_RULES`) classes every live error. The first matching row wins.

| Order | Rule | Class | Matches |
|---|---|---|---|
| 1 | `interrupted` | not an error | `Operation aborted`, `Command aborted`, a request the person interrupted |
| 2–5 | `pi-arguments-invalid`, `pi-tool-unknown`, `pi-arguments-truncated`, `claude-tool-use-error` | model | argument validation, unknown tool, a call cut at the output limit, `<tool_use_error>` |
| 6 | `pi-hooks-registry-unreadable` | extension, pi-hooks | `hook-registry-unreadable=` |
| 7 | `our-tool` | extension, the owning package | any error of a tool our packages register (`TOOL_OWNERS`) |
| 8 | `hook-refusal` | repository | a kendex hook's first line `name: key=value`, or `PreToolUse:… hook error` |
| 9 | `command-exit` | repository | `Command exited with code N`, `Exit code N`, `Command timed out after N seconds` |
| 10 | `names-package` | extension, the named package | text naming a pi-extensions package |
| 11 | `file-arguments` | model | a built-in file tool's argument error |
| 12 | `turn-error` | provider | any other turn-level error: HTTP, stream, rate limit |
| — | `none` | unclassified | nothing above; reported with its excerpt |

pi-tool-renderer's pass-through `read`, `bash`, `edit`, `write`, `grep`, `find` and `ls` count as Pi built-ins (`tool-renderer.ts:53-61`, `tool-renderer/tools.ts:206-207`).

### Forced workarounds and outcome

| Measure | Counted when | Source |
|---|---|---|
| Relaunch | a `fleet_log` row for the item whose text says relaunch | `oversee.fleet_log.relaunch_rows` |
| Overseer ruling | a `fleet_log` row of kind `ruling` | `oversee.fleet_log.by_kind` |
| Lane-mail ask | an ask envelope in the item's own `to-overseer.jsonl`, once per id | `lane_mail.asks` |
| Ask group | the first `ASK_GROUPS` pattern an ask's excerpt matches: failing receipt or validation, merge or review gate, ruling or choice, else other | `ask_groups` |
| Candidate harness-defect ask | an ask naming harness or extension words; a reviewer confirms each | `lane_mail.asks[].terms` |
| Harness-only brief clause | a clause of `tmp/brief-tail-template.md` naming one harness; per repository | `brief_tail`; none in this sample |
| Stopped, parked or paused | lane `status` `stopped`, a `parked` object, or `pauses` not empty | lane record |
| Not merged | never shown: oversee-cycle writes a lane's `cycle` only at merge, so a merged stamp reads merged and every other lane, one with no lane record or no `cycle` included, reads unknown; the not-merged share is 0 by construction | lane record |
| Wall time | `cycle.stamps.launched` (else `launched_at`) to `merged`, less the pause time inside that window: each `pauses` stretch and a standing `parked`, clipped to the window, overlaps counted once, as oversee-cycle counts its pauses | lane record |
| Fix rounds | `cycle.rounds.fix` | lane record |

### Instrument tests

`python3 docs/plans/pi-session-audit/test_measure.py` runs `measure.py` on the synthetic fixtures under [pi-session-audit/fixtures](pi-session-audit/fixtures) and on schema-1 archive lines built in the test. It holds `TOOL_OWNERS`, `PACKAGES` and the `customType` owners equal to `pi-extensions/` source. No CI lane runs it, so Read procedure step 0 runs it before every read; a package, tool or `customType` added under `pi-extensions/` shows there. A planted defect turns it red for each rule it holds, among them the Pi item floor counted in items, the member cap and streamed reads, incomplete and null token counts, cycle-less and parked lanes, pause clipping, the own-mailbox scope, item identity, the ask groups, the `--since` filter, the p90 rank and mixed-token exclusion.

## Evidence and Sources

- [E] [pi-session-audit-research.evidence.json](pi-session-audit-research.evidence.json): `measure.py aggregate --issues` over the overseer's `archive` run. Input: 462 lines, gzip sha256 `97f59ab3186a26735b713528fc171056cf743870306307428182316577997048`; tracker fields for 384 items, sha256 `8b7d3c172af646c323ca75e936fd9b2b36441a094247424973cc8748bf491e0f`. Neither raw file is committed.
- [R] Owner ruling relayed by the overseer (1791055181): the sample, live reads only on open Pi lanes, no routing and no Copilot spend, the comparison and the reporting rule.
- [O] Overseer facts: what a close keeps (FLT-671), the control-host rules, the token-record meanings, and no Pi lane open at 19:57Z.
- [I] KEN-2343 issue body: the measures, the error classes, Done-when.
- [S] Repository source at this commit, cited by file and line; the static figures from the installed packages and fleet harness settings on this sandbox, Pi 1.0.1.
- [C] `@github/copilot-sdk` 1.0.16 `session-events.d.ts`: the Copilot CLI event shapes `live` reads.

## Tradeoffs / Alternatives

- The kept records hold the harness mix the fleet ran, not a matched sample. Same-model rows and matched strata narrow that; neither holds the provider fixed.
- Measures 2 and 3 waited for live lanes. With none open, the static context figures stand in for measure 2, and measure 3 has no stand-in.

## Recommendation / Decision Criteria

- Fix KEN-2683 first: it is the one extension cost that grows with session length.
- Fix the disabled-package prompt block (rank 2): it costs every Pi request and points the model at a tool that does not exist.
- Hold any choice between Pi and Claude Code on tokens until a Pi token cell on claude-opus-5.5 reaches 8 merged items. Each Pi close since 2026-10-02 adds a token record.

## Risks / Unknowns

- 6 of the 8 Pi token items ran gpt-6.1-sol; token comparisons mix model and harness.
- No transcript was read, so no live error is classified and no extension cost is measured in a lane.
- Relaunches are counted from fleet log text, not a field.
- The candidate harness-defect ask count rests on keywords; most matches name the work item, not the harness.
- The static figures come from this sandbox's installed copy of the fleet harness, which can differ from a lane's.

## Revisit Conditions

- Lane close starts keeping transcripts: measures 2 and 3 can then come from closed lanes.
- A Pi token cell on one model reaches 8 merged items.
- KEN-2683 or the disabled-package fix lands: rerun `aggregate` on the next kept records.

## Research Metadata

- Mode: kept close records plus static code reads. No provider query, no Exa search, no live lane.
- Script: `docs/plans/pi-session-audit/measure.py` (Python 3.8+, standard library), modes `archive`, `live`, `aggregate`.
- Tests: `docs/plans/pi-session-audit/test_measure.py`, 28 tests, run by hand (Read procedure step 0).
- Archive read: the overseer's run, 462 lines, every one exit 0 with no error; `--oversee-state` for fleet, kendex, talk and vg.
