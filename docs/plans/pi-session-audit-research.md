# Findings: Pi lane session audit

Status: instrument built; no record read yet.

## Research Question

Does Pi with the kendex Pi extensions waste tokens, raise errors, force workarounds or fail more often than Claude Code and Copilot CLI on the same class of item? Which of those costs do our extensions cause, and what is the root cause of each, with file and line?

## Executive Summary

Nothing is measured yet. This round builds the measure script and fixes the method. The sample is the close records the control host already keeps, plus new closes. [R]

The measure script is [pi-session-audit/measure.py](pi-session-audit/measure.py). It runs in three modes. `archive` sweeps every kept close record on the control host and prints one JSON line per item: the inputs to measures 1, 4 and 5. `live` reads one open Pi lane's sandbox before its close and prints measures 2 and 3 per session. `aggregate` turns those lines into the measure table. `measure.py --help` states each schema. [S]

## Key Findings

No finding yet. The table in § Measure table holds no value until the overseer's run returns.

## Method

### Sample

- Close records: every kept close record dated 2026-10-01 or later, across every repository and fleet under `/home/admin/.fleet/archive/<repo>/<item>/`, plus each new close. A close record is a `tokens-<sandbox-id>.json` and a `tmp-*.tgz`. [R]
- Live Pi lanes: measures 2 and 3 need a transcript, and a close keeps none (FLT-671). They are read only from Pi lanes still open, before their close. [R] [O]
- No routing change and no Copilot spend. The overseer routes no item for this audit. [R]

### Comparison

The comparison is whatever harness mix the kept records hold: Claude Code, Pi and Copilot CLI. No harness needs a matched sample. [R]

Where the records allow, `aggregate` also groups the archive measures by repository and estimate band (1–2, 3 and up), in `by_repo_and_band`. The repository is the archive directory's. The band comes from the oversee lane record's `tier_inputs.estimate`. No kept record holds the item's `agent:*` label. The subagent reads it from the tracker when it wants that split. Every session's `models` lists the provider and model of each assistant message, so a reader can see where models differ.

### Reporting rule

- Every figure carries its source and its sample size n. `aggregate` puts `source` on every measure, and `n` and the item count on every cell.
- A measure with fewer than 8 Pi items reads "too small to judge" in every cell. The cell keeps n and drops the median and p90. It is never a finding. `MIN_PI_ITEMS` in `measure.py` holds the 8, and `test_measure.py` fails when it changes.
- Median is the middle value, or the mean of the two middle values for an even n. p90 is the nearest-rank 90th percentile.

### Read procedure

An overseer-briefed control-host subagent runs every read, with the script as its input. It runs `archive` first. The script itself writes no file.

| Step | Mode | Where | Command |
|---|---|---|---|
| 1 | `archive` | control host | `measure.py archive --root /home/admin/.fleet/archive --oversee-state REPO=<repo>/tmp/workflow-state-oversee.json --brief-tail REPO=<repo>/tmp/brief-tail-template.md > items.jsonl`, one `--oversee-state` and one `--brief-tail` per repository |
| 2 | `live` | each open Pi lane's sandbox, before close | `python3 - live --item ITEM --repo REPO > ITEM.live.json`, run through `lane-host-daytona exec --item ITEM` with `measure.py` on its stdin |
| 3 | `aggregate` | control host | `measure.py aggregate items.jsonl *.live.json` |
| 4 | — | control host | `gh pr view N --json state,mergedAt,createdAt` for a PR whose lane record holds no `cycle` |

`archive` takes every directory under the root's repository directories as an item, and prints a line for each item with at least one close record dated on or after `--since` (default 2026-10-01). A record's date is its `at`, else its file's modification time. A directory with no such record, such as `<repo>/oversee/` with its prune archives, prints nothing and is counted in the last stderr line, `measure: archive-done=`. A sandbox of another repository has no copy of the script, so the subagent streams it to `python3 -` on stdin and writes nothing into the sandbox.

`live` reads these stores under `$HOME`:

| Store | Harness | What it holds |
|---|---|---|
| `.pi/agent/sessions/**/*.jsonl` | Pi | lead sessions |
| `.pi/agent/kendex/sessions/**/*.jsonl` | Pi | pi-agents-tmux subagent sessions; a file whose first line is no Pi session header is counted as skipped |
| `.pi/agent/kendex/sessions/*/pi-output-policy/artifacts/` | Pi | full outputs pi-output-policy saved; files and bytes only |
| `.pi/agent/APPEND_SYSTEM.md` | Pi | the installed system-prompt appends, bytes per package |
| `.claude-shared/projects/**/*.jsonl`, `.claude/projects/**/*.jsonl` | Claude Code | lead and `subagents/agent-*.jsonl` transcripts; a file both paths reach is read once |
| `.copilot*/session-state/*/events.jsonl` | Copilot CLI | one event log per session |

### Control-host rules

The script obeys these, and the subagent obeys them for every other read.

- Read an archive as a stream. `archive` lists members with `tar -tzf ARCHIVE` and reads one member at a time with `tar -xzOf ARCHIVE -- MEMBER`. It never extracts an archive. It refuses a member over 16 MiB.
- Before each item, `archive` runs and prints `df -h /`. Under 3 GB free on `/` it stops with exit 3 before that item (`--min-free-gb`). The lines it already printed are complete items.
- Run no `git log -S`, `git log -G`, `git log --all -p` and no other read of every blob in history.
- Write no bulk data. The output carries counts and bytes. It carries text only as excerpts of at most 200 characters: extension-class and unclassified errors, and lane-mail asks.

### Per-session measures

Each `live` session object carries these. Bytes are UTF-8 bytes, the proxy for tokens wherever a transcript records no token count.

| Field | Meaning | Pi source | Claude Code source | Copilot CLI source |
|---|---|---|---|---|
| `tokens` | input, output, cache read, cache write, total; `recorded` and `unrecorded` model calls | assistant `message.usage`, `usage` entries, compaction and branch-summary `usage`, tool-result `usage` | assistant `message.usage`, one per `message.id` | `session.shutdown` `modelMetrics.<model>.usage`, summed over shutdowns; else "not recorded" |
| `models` | assistant messages per `provider/model` | assistant `provider`, `model` | `message.model` | `modelMetrics.<model>.requests.count` |
| `context.sections_bytes` | final system-prompt sections after replaying every system message | system messages, compaction `systemMessage` | not applicable | not applicable |
| `context.system_messages` | system messages in the file; each patches the prompt | same | — | — |
| `context.addendum_by_package` | `addendum` section bytes per `kendex:append-system` package marker | same | — | — |
| `context.tool_definitions` | declared tool bytes (name, description, parameters) per owning package, built-in total | `toolsAdded`, `toolsRemoved` | — | — |
| `context.tools_section_by_package` | bytes of our tools' `- name: snippet` lines in the `tools` section | `tools` section | — | — |
| `context.custom_entries` | count and data bytes per `customType`, with owner | `custom` entries | — | — |
| `context.custom_messages` | count, content bytes and hidden count per `customType`, with owner | `custom_message` entries | — | — |
| `context.nested_agents_md` | text parts and bytes pi-nested-agents-md appended to `read` results | tool-result parts starting `instructions_path=` | — | — |
| `context.output_policy` | results; truncated; minimized only; bytes before and after the budget | tool-result `details.kendexOutputPolicy[0]` | — | — |
| `context.forced_prompt_appends` | always "not recorded" (§ Context sources) | — | — | — |
| `tools.calls`, `tools.results` | tool calls, tool results | `toolCall` blocks, `toolResult` messages | `tool_use`, `tool_result` blocks | `tool.execution_start`, `tool.execution_complete` |
| `tools.errors_by_class` | errors per class (§ Error classification) | `isError` results; assistant `stopReason: "error"` | `is_error` results; `isApiErrorMessage` entries | `success: false`; `session.error` |
| `tools.interrupted` | calls stopped by the lane or person; not errors | — | — | — |
| `owed_turns` | turn ends a Stop hook refused | hidden `kendex-hook` custom messages | user text starting `Stop hook feedback` | "not recorded" |

Pi duplicates: a forked Pi session copies earlier entries. `live` counts an assistant message once per lane, keyed by `responseId`, and a tool result once per `toolCallId`. `duplicate_assistant_messages` reports the copies skipped.

### Token-record field meanings assumed

The overseer verifies each line against a real `tokens-<sandbox-id>.json` before the run. `archive` names the order it applied in `token_field_order_assumed`.

| Field | Assumed meaning |
|---|---|
| `models.<model>[0]` | input tokens not served from cache |
| `models.<model>[1]` | output tokens |
| `models.<model>[2]` | cache read tokens |
| `models.<model>[3]` | cache write (creation) tokens |
| total | the sum of the four; assumes no count includes another |
| `files` | transcript files the record writer read for that harness |
| `unreadable` | of those, files it could not parse |
| `unrecorded` | model calls or files that carried no usage |
| `at` | UTC time the close wrote the record |

A count list of any other length, or with a non-integer, is refused as `token-record-shape` in `errors`, never guessed.

### Context sources

These are the context sources our packages add, read from source at this commit. [S]

| Source | Package | Where | In the transcript |
|---|---|---|---|
| `instructions.md` appended to every session's system prompt through `pi.appendSystem`: 7,420 bytes | pi-agents-tmux | `pi-extensions/pi-agents-tmux/package.json:19`, `scripts/append-system.mjs:66` | yes, `addendum` section |
| same, 3,434 bytes | pi-background-tasks | `pi-extensions/pi-background-tasks/instructions.md` | yes |
| same, 1,676 bytes | pi-questions | `pi-extensions/pi-questions/instructions.md` | yes |
| same, 3,165 bytes; the package registers no tool | pi-session-bridge | `pi-extensions/pi-session-bridge/instructions.md` | yes |
| same, 1,131 bytes | pi-task-panel | `pi-extensions/pi-task-panel/instructions.md` | yes |
| same, 2,073 bytes | pi-web-tools | `pi-extensions/pi-web-tools/instructions.md` | yes |
| tools `subagent`, `delegate_subagent`, `complete_subagent` | pi-agents-tmux | `pi-extensions/pi-agents-tmux/extensions/subagent/index.ts:2008`, `:1882`, `:1286` | yes, `toolsAdded` |
| tools `get_subagent_result`, `wait_for_subagent_idle`, `steer_subagent`, `stop_subagent` | pi-agents-tmux | `pi-extensions/pi-agents-tmux/extensions/subagent/pane-support-tools.ts:75`, `:175`, `:200`, `:387` | yes |
| tools `bg_status`, `bg_task` | pi-background-tasks | `pi-extensions/pi-background-tasks/extensions/registrations.ts:45`, `:83` | yes |
| tool `question` | pi-questions | `pi-extensions/pi-questions/extensions/questions.ts:1027` | yes |
| tool `tasks_write` | pi-task-panel | `pi-extensions/pi-task-panel/extensions/task-panel.ts:1215` | yes |
| tool `tool_batch` | pi-tool-renderer | `pi-extensions/pi-tool-renderer/extensions/tool-renderer/batch.ts:254` | yes |
| `read`, `bash`, `edit`, `write`, `grep`, `find`, `ls` registered again with the built-in's contract and execute; no added bytes | pi-tool-renderer | `pi-extensions/pi-tool-renderer/extensions/tool-renderer.ts:53-61`, `tool-renderer/tools.ts:206-207` | counted as built-in |
| seven web tools; seven alias tools only when `compatibilityTools` is on (default off) | pi-web-tools | `pi-extensions/pi-web-tools/src/index.ts:30-36`, `:43-49`, `:53` | yes |
| `image_generation`, `view_image`, `apply_patch`, only with OpenAI models loaded | pi-codex-minimal-tools | `pi-extensions/pi-codex-minimal-tools/src/index.ts:153-177` | yes |
| `before_agent_start` system prompt: active task line | pi-task-panel | `pi-extensions/pi-task-panel/extensions/task-panel.ts:1290-1296`, `:730-733` | no |
| `before_agent_start` system prompt: project agent list | pi-agents-tmux | `pi-extensions/pi-agents-tmux/extensions/subagent/index.ts:1823-1880` | no |
| hidden task-state message each agent start; earlier copies dropped from context | pi-task-panel | `pi-extensions/pi-task-panel/extensions/task-panel.ts:1278-1296` | yes, `custom_message` |
| Stop hook refusal delivered as a hidden message | pi-hooks | `pi-extensions/pi-hooks/extensions/hooks.ts:362`, `:424` | yes, `custom_message` |
| hook, drift, clippy and lane-mail wake messages | pi-hooks | `pi-extensions/pi-hooks/extensions/hooks.ts:177`, `:222`, `:496`; `lane-mail-wake.ts:87` | yes |
| background task wake messages | pi-background-tasks | `pi-extensions/pi-background-tasks/extensions/wake-events.ts:527-592` | yes |
| nested `AGENTS.md` text appended to `read` results | pi-nested-agents-md | `pi-extensions/pi-nested-agents-md/extensions/nested-agents-md.ts:137-152` | yes |
| tool-result budget | pi-output-policy | `pi-extensions/pi-output-policy/extensions/output-policy.ts:1019-1043` | yes, `details.kendexOutputPolicy` |

A `before_agent_start` handler that returns `systemPrompt` sets Pi's forced prompt. Pi sends it as the request's leading system prompt and keeps the structured sections in the transcript (`runner.js:1147-1149`, `agent-session.js:1277` in the Pi 1.0.1 package). So the two forced appends above never reach the session file. `live` reports them as "not recorded". Their size per request is the template text plus the active task (pi-task-panel) or one line per project agent (pi-agents-tmux).

pi-output-policy budget, per `policyMode` (`output-policy.ts:52-80`). The fleet settings set no mode, so `balanced` applies.

| Mode | Spill threshold | Inline tail | Max text block | Max lines |
|---|---|---|---|---|
| `compat` | 200 KB | 100 KB | 200 KB | 8,000 |
| `balanced` | 48 KB | 16 KB | 24 KB | 400 |
| `compact` | 16 KB | 6 KB | 8 KB | 200 |

Bytes before the budget are `shownBytes + savedBytes` of the result's meta. Bytes after are the result's recorded text. A result the shell minimizer shortened without truncation carries no meta (`output-policy.ts:729-735`). `live` counts it under `minimized_only` with its dropped line count, and its bytes before are not recorded.

### Error classification

One table in `measure.py` (`ERROR_RULES`) classes every error. The first matching row wins. Each row carries a real example the test classifies.

| Order | Rule | Class | Matches |
|---|---|---|---|
| 1 | `interrupted` | not an error | `Operation aborted`, `Command aborted`, a request the person interrupted |
| 2 | `pi-arguments-invalid` | model | `Validation failed for tool` (pi-ai argument validation) |
| 3 | `pi-tool-unknown` | model | `Tool NAME not found` |
| 4 | `pi-arguments-truncated` | model | a call cut off at the output token limit |
| 5 | `claude-tool-use-error` | model | `<tool_use_error>` |
| 6 | `pi-hooks-registry-unreadable` | extension, pi-hooks | `hook-registry-unreadable=` |
| 7 | `our-tool` | extension, the owning package | any error of a tool our packages register (`TOOL_OWNERS`) |
| 8 | `hook-refusal` | repository | a kendex hook's first line `name: key=value`, or `PreToolUse:… hook error` |
| 9 | `command-exit` | repository | `Command exited with code N`, `Exit code N`, `Command timed out after N seconds` |
| 10 | `names-package` | extension, the named package | text naming a pi-extensions package, as `@vanillagreen/pi-…`, `pi-extensions/pi-…` or the bare name |
| 11 | `file-arguments` | model | a built-in file tool's argument error: missing path, edit text not found or not unique, offset past the end |
| 12 | `turn-error` | provider | any other turn-level error: HTTP, stream, rate limit |
| — | `none` | unclassified | nothing above; reported with its excerpt |

Rules 2–5 run before rule 7, so a bad argument to our tool is a model error, as the issue defines it. Rule 9 runs before rule 10, so a failing command whose output names a package, such as a test run inside `pi-extensions/`, is a repository error. A hook refusal of a call to one of our tools falls to rule 7. Its excerpt is in the row, and the reviewer reclassifies it by hand. pi-tool-renderer's pass-through tools are not "our tools" for rule 7.

Every extension-class cost gets a root cause with file and line, and one fix item with a must-fail test. A model, provider or repository cost is listed with its class and files nothing. [I]

### Forced-workaround classification

| Workaround | Counted when | Source |
|---|---|---|
| Harness-only brief clause | a paragraph or bullet of `tmp/brief-tail-template.md` names exactly one harness (Pi, Claude, Copilot, Codex) | `archive` `brief_tail.harness_only` |
| Relaunch | a `fleet_log` row for the item whose text says relaunch | `archive` `oversee.fleet_log.relaunch_rows`; lane record `session_id`, `pauses` |
| Overseer ruling | a `fleet_log` row of kind `ruling` for the item | `archive` `oversee.fleet_log.by_kind.ruling` |
| Lane-mail ask a harness defect caused | an ask in `to-overseer.jsonl`; `terms` lists harness and extension words; the reviewer reads the excerpt and decides | `archive` `lane_mail.asks` |
| Turn ended with work owed | a Stop hook refused the turn end | `live` `owed_turns` |

### Failures and outcome

`archive` puts these in each item's `outcome`, from the oversee lane record. Without a lane record every field is null: the outcome is unknown, never "not merged".

| Field | Source |
|---|---|
| `stopped_parked_or_paused` | lane record `status` is `stopped` or `parked`, or `pauses` is not empty |
| `merged` | lane record `cycle.stamps.merged` is set |
| `wall_secs` | `cycle.stamps.launched` (else `launched_at`) to `cycle.stamps.merged`, less the `pauses` stretches |
| `fix_rounds` | `cycle.rounds.fix` |
| `estimate_band` | `tier_inputs.estimate`: 1–2 or 3+ |

The item's harness is the lane record's `harness`. Without a lane record it is the one harness with tokens in the kept token records. With several such harnesses it is `mixed`, and `aggregate` leaves the item out of every harness cell and counts it in `inputs.mixed_or_unknown_harness`.

### Measure table

`aggregate` fills this table from the `archive` and `live` lines. Each cell is n / items / median / p90, or n / items / "too small to judge" (§ Reporting rule). Every cell is empty until the overseer's run returns. Harness-only brief clauses are counted per repository in each item's `brief_tail`, not per item, and stay out of the table.

| Measure | Unit | Source | Pi with our extensions | Claude Code | Copilot CLI |
|---|---|---|---|---|---|
| 1 input tokens per merged item | item | `tokens-*.json` `models.<model>[0]`, order assumed | | | |
| 1 output tokens per merged item | item | `models.<model>[1]`, order assumed | | | |
| 1 cache read tokens per merged item | item | `models.<model>[2]`, order assumed | | | |
| 1 cache write tokens per merged item | item | `models.<model>[3]`, order assumed | | | |
| 1 total tokens per merged item | item | sum of the four counts | | | |
| 2 system-prompt append bytes | session | Pi `addendum` section, package markers | | not applicable | not applicable |
| 2 our tool definition bytes | session | Pi `toolsAdded` | | not applicable | not applicable |
| 2 custom and custom_message bytes | session | Pi `custom`, `custom_message` entries | | not applicable | not applicable |
| 2 tool-result bytes before budget | session | Pi `details.kendexOutputPolicy` | | not applicable | not applicable |
| 2 tool-result bytes after budget | session | Pi tool-result content | | not applicable | not applicable |
| 3 tool calls per session | session | transcript tool calls | | | |
| 3 extension errors per session | session | transcript errors, `ERROR_RULES` | | | |
| 3 model errors per session | session | same | | | |
| 3 provider errors per session | session | same | | | |
| 3 repository errors per session | session | same | | | |
| 3 unclassified errors per session | session | same | | | |
| 4 relaunches per item | item | `fleet_log` text naming relaunch | | | |
| 4 overseer rulings per item | item | `fleet_log` kind `ruling` | | | |
| 4 candidate harness-defect asks per item | item | `to-overseer.jsonl` asks naming harness words; the reviewer confirms each | | | |
| 4 turns ended with work owed per session | session | Stop hook refusals in the transcript | | | |
| 5 share stopped, parked or paused | item | lane record `status`, `pauses` | | | |
| 5 share not merged | item | lane record `cycle.stamps.merged` | | | |
| 5 wall seconds launch to merge, less pauses | item | lane record `cycle.stamps`, `pauses` | | | |
| 5 fix rounds per merged item | item | lane record `cycle.rounds.fix` | | | |

Live measures come only from open Pi lanes, so their Claude Code and Copilot CLI cells stay empty unless such a lane is open on the same sandbox.

### Instrument tests

`python3 docs/plans/pi-session-audit/test_measure.py` runs the script on the synthetic fixtures under [pi-session-audit/fixtures](pi-session-audit/fixtures). It also holds `TOOL_OWNERS`, `PACKAGES` and the `customType` owners equal to what it extracts from `pi-extensions/` source. A planted defect turns it red for each of: Claude usage keyed per line, a dropped tool owner, a broken classifier row, a disk check that never stops, Pi fork copies counted twice, a Pi item floor of 7, a `--since` filter that keeps everything, and a p90 that takes the maximum.

## Evidence and Sources

- [I] KEN-2343 issue body: sample, measures, read rules, classification classes, Done-when.
- [O] Overseer ruling for this round: what a close keeps (FLT-671) and the control-host rules.
- [R] Owner ruling relayed by the overseer: the sample is the kept close records since 2026-10-01 plus new closes, live reads only on open Pi lanes, no routing change and no Copilot spend, and the reporting rule.
- [S] Repository source at this commit, cited by file and line above.
- [P] The Pi 1.0.1 npm package's Session File Format and Message Types documents (`@earendil-works/pi-coding-agent`): entry types, system messages with `sections`, `toolsAdded`, `toolsRemoved`, `Usage` fields.
- [C] `@github/copilot-sdk` 1.0.16 `dist/generated/session-events.d.ts`: `session.shutdown` `modelMetrics.<model>.usage` (`inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`); `assistant.usage` is `ephemeral` and not written to `events.jsonl`; `tool.execution_complete` `success` and `error.message`; `session.error` `errorType`.
- [L] One local Claude Code transcript pair on this sandbox: a response's usage repeats on each of its content-block lines, so usage is keyed by `message.id`.

## Tradeoffs / Alternatives

- Measures 2 and 3 read the live sandbox before close, because a close does not keep transcripts. A Pi lane that closed before the read has no measure 2 or 3, so those measures cover fewer items than measures 1, 4 and 5.
- The kept records hold the harness mix the fleet ran, not a matched sample. A harness difference in one cell can come from the item mix. `by_repo_and_band` narrows that where the records allow.
- Bytes stand in for tokens wherever a transcript records no per-part token count. The table states bytes in those rows.

## Recommendation / Decision Criteria

None yet. The verdict line (Pi with our extensions vs Claude Code vs Copilot CLI) waits for the table.

## Risks / Unknowns

- The four token-record counts are assumed to be input, output, cache read and cache write, in that order (§ Token-record field meanings assumed).
- The Copilot event shape is read from the SDK 1.0.16 types, not from a real Copilot CLI 1.0.91 session. A session with no `session.shutdown` event reports tokens as "not recorded".
- A Claude Code Stop hook refusal is assumed to reach the transcript as a user message starting `Stop hook feedback`.
- The forced `before_agent_start` system prompts are not in any Pi transcript.
- A relaunch is counted from fleet log text, not from a field.
- A close record with no `at` is dated by its file's modification time.
- The archive's harness names (`claude` in the token record) are assumed to match the lane record's `harness` words.
- Records from before 2026-10-01 are outside the sample, so Pi items may number fewer than 8 for some measures. Those read "too small to judge".
- A minimized-only tool result has no recorded size before the minimizer.

## Revisit Conditions

- Lane close starts keeping transcripts: measures 2 and 3 can then come from closed lanes too.
- A Pi release changes the session format or the forced-prompt projection (`pi-update` audit).
- The token record writer changes its shape.

## Research Metadata

- Mode: instrument build. No provider query, no Exa search, no record or lane read.
- Script: `docs/plans/pi-session-audit/measure.py`, Python 3.8 or later, standard library only.
- Fixtures and tests: `docs/plans/pi-session-audit/fixtures/`, `docs/plans/pi-session-audit/test_measure.py`.
- Dry run on this sandbox's own Claude Code transcripts (not sample data): 2 sessions read, 0 unreadable.
