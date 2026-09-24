# Agent transcripts

Where each harness records a delegated agent's turns, for `round-recover --transcript` in a stalled round ([skill-rules.md § Round Closure](skill-rules.md#round-closure)). `round-recover` reads only the turns after the last user turn carrying the round's `Round ID:` line.

| Harness | Transcript | Record that carries the report |
|---|---|---|
| Claude Code | `child_sessions[agent].agent_id` reads `[NAME]@[TEAM]`. The transcript is the newest `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/*/subagents/agent-a[NAME]-*.jsonl` whose `.meta.json` sibling carries `name` `[NAME]` and `teamName` `[TEAM]` | The last `SendMessage` `tool_use` block's `input.message`; with none, the last `text` block of a `.message` whose `role` is `assistant` |
| Pi | A background run: `sessionPath` in the `subagent` result's details. A pane agent: `transcriptPath`, the pane's session file | The last `text` block of a `.message` whose `role` is `assistant` |
| Codex | `${CODEX_HOME:-~/.codex}/sessions/*/*/*/rollout-*-[AGENT_ID].jsonl`, the spawned agent's own thread | The last `send_input` `function_call` payload's `message` argument; with none, the last `output_text` block of a `.payload` whose `role` is `assistant` |

A harness that keeps no transcript for the agent: run `round-recover` without `--transcript`. The round then has no report.
