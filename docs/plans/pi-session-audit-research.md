# Findings: Pi lane session audit

Status: instrument only; window not yet opened.

## Research Question

Does Pi with the kendex Pi extensions waste tokens, raise errors, force workarounds or fail more often than Claude Code and Copilot CLI on the same class of item? Which of those costs do our extensions cause, and what is the root cause of each, with file and line?

## Executive Summary

Nothing is measured yet. This round builds the measure script and fixes the method. The 48-hour window opens after the Pi extension audit items land and lane close keeps transcripts (KEN-2343 hold). [I]

The measure script is [pi-session-audit/measure.py](pi-session-audit/measure.py). It runs in two modes. `live` reads one lane sandbox's session stores before close and emits measures 2 and 3 per session. `archive` reads one closed item's kept archive on the control host and emits the inputs to measures 1, 4 and 5. Each run prints one JSON object. `measure.py --help` states the schema. [S]

## Key Findings

No finding yet. The table in § Measure table holds no value until the window closes.

## Method

### Sample

- Pi sample: every Pi lane that closes in the 48 hours after the window opens, across the oversee states on the control VM (kendex, fleet, vg, talk). If that is fewer than 30 lanes, the sample is the first 30 closed Pi lanes. [I]
- Comparison sample: in the same window, the overseer routes at least 8 items to Claude Code and at least 8 to Copilot CLI. [I]
- Model: every harness runs claude-opus-5.5. Pi runs it through the `github-copilot` provider. [I]

### Matching rule

A comparison item matches a Pi item when all four hold:

| Key | Rule | Read from |
|---|---|---|
| Repository | Same repository | oversee lane record `repo` |
| Agent label | Same `agent:*` label | Linear or GitHub issue labels |
| Estimate band | Same band: 1–2 or 3 and up | issue estimate; lane record `tier_inputs.estimate` |
| Model | claude-opus-5.5 on every assistant message; Pi messages also carry provider `github-copilot` | live `sessions[].models` |

A session whose `models` names any other model or provider leaves the sample. The run lists each one and its reason. The fleet Pi settings on this sandbox set `defaultProvider` to `pi-claude`, so a Pi lane enters the sample only when its launch names `github-copilot/claude-opus-5.5` (`~/.fleet/harness/pi/settings.json`). [S]

### Read procedure

An overseer-briefed control-host subagent runs every read, with the script as its input. The script itself writes no file. Its output is one JSON object per lane. A sandbox of another repository has no copy of the script, so the subagent streams it to `python3 -` on stdin and writes nothing into the sandbox.

| Measure | Mode | Where | Command |
|---|---|---|---|
| 1 tokens per merged item | `archive` | control host, `/home/admin/.fleet/archive/<repo>/<item>/` | `measure.py archive --dir DIR --oversee-state <repo>/tmp/workflow-state-oversee.json --brief-tail <repo>/tmp/brief-tail-template.md` |
| 2 context our extensions add | `live` | lane sandbox, before close | `python3 - live --item ITEM`, run through `lane-host-daytona exec --item ITEM` with `measure.py` on its stdin |
| 3 tool calls and errors | `live` | lane sandbox, before close | same run as measure 2 |
| 4 forced workarounds | `archive` | control host | same run as measure 1, plus `fleet_log` rows |
| 5 failures and outcome | `archive` | control host | same run as measure 1, plus `gh pr view N --json state,mergedAt,createdAt` per PR |

The transcript archive leaves the control VM disk at merge (FLT-671). A close keeps `tokens-<sandbox-id>.json` and `tmp-*.tgz` (lane status, `to-overseer.jsonl`, the item workflow state). So measures 2 and 3 come from the live sandbox before close, and measures 1, 4 and 5 come from what a close keeps. [O]

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
- Before each archive, `archive` runs and prints `df -h /`. Under 3 GB free on `/` it stops with exit 3 and prints nothing on stdout (`--min-free-gb`).
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

| Measure | Source |
|---|---|
| Lane stopped, parked or relaunched | lane record `status`, `parked`, `pauses`; `relaunch_rows` |
| PR not merged | lane record without `cycle`; `gh pr view` `state` |
| Wall time, launch to merge | lane record `cycle.stamps.launched` to `cycle.stamps.merged`, less `pauses` |
| Fix rounds | lane record `cycle.rounds.fix`, `cycle.pr_rounds`; item state `pr_comment_iterations`, `fixes` |

### Measure table

Each cell is n / median / p90 per session or per item. Every cell is empty until the window closes.

| Measure | Pi with our extensions | Claude Code | Copilot CLI |
|---|---|---|---|
| 1 input tokens per merged item | | | |
| 1 output tokens per merged item | | | |
| 1 cache read tokens per merged item | | | |
| 1 cache write tokens per merged item | | | |
| 1 total tokens per merged item | | | |
| 2 system-prompt append bytes | | not applicable | not applicable |
| 2 our tool definition bytes | | not applicable | not applicable |
| 2 `custom` and `custom_message` bytes | | not applicable | not applicable |
| 2 tool-result bytes before budget | | not applicable | not applicable |
| 2 tool-result bytes after budget | | not applicable | not applicable |
| 3 tool calls per session | | | |
| 3 extension errors per session | | | |
| 3 model errors per session | | | |
| 3 provider errors per session | | | |
| 3 repository errors per session | | | |
| 3 unclassified errors per session | | | |
| 4 harness-only brief clauses | | | |
| 4 relaunches per item | | | |
| 4 overseer rulings per item | | | |
| 4 harness-defect lane-mail asks per item | | | |
| 4 turns ended with work owed per session | | | |
| 5 lanes stopped, parked or relaunched | | | |
| 5 PRs not merged | | | |
| 5 wall time, launch to merge | | | |
| 5 fix rounds per item | | | |

### Instrument tests

`python3 docs/plans/pi-session-audit/test_measure.py` runs the script on the synthetic fixtures under [pi-session-audit/fixtures](pi-session-audit/fixtures). It also holds `TOOL_OWNERS`, `PACKAGES` and the `customType` owners equal to what it extracts from `pi-extensions/` source. A planted defect turns it red for each of: Claude usage keyed per line, a dropped tool owner, a broken classifier row, a disk check that never stops, and Pi fork copies counted twice.

## Evidence and Sources

- [I] KEN-2343 issue body: sample, measures, read rules, classification classes, Done-when.
- [O] Overseer ruling for this round: what a close keeps (FLT-671) and the control-host rules.
- [S] Repository source at this commit, cited by file and line above.
- [P] The Pi 1.0.1 npm package's Session File Format and Message Types documents (`@earendil-works/pi-coding-agent`): entry types, system messages with `sections`, `toolsAdded`, `toolsRemoved`, `Usage` fields.
- [C] `@github/copilot-sdk` 1.0.16 `dist/generated/session-events.d.ts`: `session.shutdown` `modelMetrics.<model>.usage` (`inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`); `assistant.usage` is `ephemeral` and not written to `events.jsonl`; `tool.execution_complete` `success` and `error.message`; `session.error` `errorType`.
- [L] One local Claude Code transcript pair on this sandbox: a response's usage repeats on each of its content-block lines, so usage is keyed by `message.id`.

## Tradeoffs / Alternatives

- Measures 2 and 3 read the live sandbox before close, because a close does not keep transcripts. A lane that closes before the read has no measure 2 or 3. The run reports it as missing rather than sampled.
- Bytes stand in for tokens wherever a transcript records no per-part token count. The table states bytes in those rows.

## Recommendation / Decision Criteria

None yet. The verdict line (Pi with our extensions vs Claude Code vs Copilot CLI) waits for the table.

## Risks / Unknowns

- The four token-record counts are assumed to be input, output, cache read and cache write, in that order (§ Token-record field meanings assumed).
- The Copilot event shape is read from the SDK 1.0.16 types, not from a real Copilot CLI 1.0.91 session. A session with no `session.shutdown` event reports tokens as "not recorded".
- A Claude Code Stop hook refusal is assumed to reach the transcript as a user message starting `Stop hook feedback`.
- The forced `before_agent_start` system prompts are not in any Pi transcript.
- A relaunch is counted from fleet log text, not from a field.
- A minimized-only tool result has no recorded size before the minimizer.

## Revisit Conditions

- The window opens: KEN-2143 to KEN-2173 are merged, released and in the fleet harness bundle, and lane close keeps transcripts.
- A Pi release changes the session format or the forced-prompt projection (`pi-update` audit).
- The token record writer changes its shape.

## Research Metadata

- Mode: instrument build. No provider query, no Exa search, no sampled lane.
- Script: `docs/plans/pi-session-audit/measure.py`, Python 3.8 or later, standard library only.
- Fixtures and tests: `docs/plans/pi-session-audit/fixtures/`, `docs/plans/pi-session-audit/test_measure.py`.
- Dry run on this sandbox's own Claude Code transcripts (not sample data): 2 sessions read, 0 unreadable.
