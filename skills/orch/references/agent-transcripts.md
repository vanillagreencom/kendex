# Agent transcripts

Where each harness records a delegated agent's turns, for `round-recover --transcript` in a stalled round ([skill-rules.md § Round Closure](skill-rules.md#round-closure)). `[AGENT_ID]` is the `agent_id` recorded in `child_sessions`. A path with a glob must match exactly one file.

| Harness | Transcript | Record that carries the report |
|---|---|---|
| Claude Code | `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/*/subagents/agent-[AGENT_ID].jsonl`, or the same name one directory below `subagents/` | `.message` with `role` `assistant`, a `text` content block |
| Pi | The child's session file: `transcriptPath` in the `subagent` result's details, or its `Session:` line. A background agent run without `sessionKey` keeps none | `.message` with `role` `assistant`, a `text` content block |
| Codex | `${CODEX_HOME:-~/.codex}/sessions/*/*/*/rollout-*-[AGENT_ID].jsonl`, the spawned agent's own thread | `.payload` with `role` `assistant`, an `output_text` content block |

A harness that keeps no transcript for the agent: run `round-recover` without `--transcript`. The round then has no report.
