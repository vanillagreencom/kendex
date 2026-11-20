# Agent transcripts

Read when a stalled round needs `orch-runtime round recover --transcript` ([skill-rules.md § Round Closure](skill-rules.md#round-closure)), or a directive during a round needs confirming ([§ Directive During A Round](skill-rules.md#directive-during-a-round)).

## What the recovery reads

The recovery reads only the turns after the last user turn that carries the round's `Round ID: [ROUND_ID]` line. A user turn is a `.message` or `.payload` whose `role` is `user`, or a record whose `type` is `user_message` and whose `message` is its text. Codex records a delegated prompt in the second form. From those turns the recovery takes the record the table names.

| Harness | Transcript | Record that carries the report |
|---|---|---|
| Claude Code | `agent-[ID].jsonl` in the `subagents/` directory beside the lead's transcript: the lead's transcript path without `.jsonl`, then `/subagents/agent-[ID].jsonl`. For each agent still out at the lane's turn end, the `lane-mail-check` hook prints `attached-agent=[ID] status=[STATUS] output=[PATH]` naming that file | The last `SendMessage` `tool_use` block's `input.message`; with none, the last `text` block of a `.message` whose `role` is `assistant` |
| Pi | A background run: `sessionPath` in the `subagent` result's details. A pane agent: `transcriptPath`, the pane's session file | The last `text` block of a `.message` whose `role` is `assistant` |
| Codex | `${CODEX_HOME:-~/.codex}/sessions/*/*/*/rollout-*-[AGENT_ID].jsonl`, where `[AGENT_ID]` is `child_sessions[agent].agent_id`, the spawned thread id | The last `send_input` `function_call` payload's `message` argument; with none, the last `output_text` block of a `.payload` whose `role` is `assistant` |
| Copilot CLI | Pending. A session records its events in `${COPILOT_HOME:-~/.copilot}/session-state/[SESSION_ID]/events.jsonl`. Where a task-tool subagent's turns land is not measured. The `agentStop` at a custom subagent's end names no transcript of the subagent's own ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)) | Pending |

## No transcript

Where the harness keeps no transcript for the agent, run `orch-runtime round recover` without `--transcript`, and act on its line.

A harness with no transcript, or with a pending row above, confirms no directive. A directive during a round on it is unconfirmed: run `orch-runtime round recover --directive-unconfirmed` ([skill-rules.md § Directive During A Round](skill-rules.md#directive-during-a-round)), never the stall recovery.
