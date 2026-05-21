import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";

const TaskItem = Type.Object({
	agent: Type.String({ description: "Name of the agent to invoke" }),
	task: Type.String({ description: "Task to delegate to the agent" }),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process" })),
	sessionKey: Type.Optional(Type.String({ description: "Optional lane id for resuming a bg (non-pane) agent across calls. Omit for a fresh one-shot lane; same key + agent => same persisted pi session. Ignored for pane agents." })),
});

const ChainItem = Type.Object({
	agent: Type.String({ description: "Name of the agent to invoke" }),
	task: Type.String({ description: "Task with optional {previous} placeholder for prior output" }),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process" })),
	sessionKey: Type.Optional(Type.String({ description: "Optional lane id for resuming a bg (non-pane) agent across calls. Omit for a fresh one-shot lane; same key + agent => same persisted pi session. Ignored for pane agents." })),
});

const AgentScopeSchema = StringEnum(["user", "project", "both"] as const, {
	description: 'Which agent directories to use. Default: "project" (.pi/agents plus .claude/agents compatibility). Use "both" to include user-level agents too.',
	default: "project",
});

export const SubagentParams = Type.Object({
	agent: Type.Optional(Type.String({ description: "Name of the agent to invoke (for single mode)" })),
	task: Type.Optional(Type.String({ description: "Task to delegate (for single mode)" })),
	tasks: Type.Optional(Type.Array(TaskItem, { description: "Array of {agent, task} for parallel execution. Dispatch uses a flat worker pool capped at maxConcurrency; caller does not need to split." })),
	chain: Type.Optional(Type.Array(ChainItem, { description: "Array of {agent, task} for sequential execution" })),
	agentScope: Type.Optional(AgentScopeSchema),
	confirmProjectAgents: Type.Optional(
		Type.Boolean({ description: "Prompt before running project-local agents. Default: false.", default: false }),
	),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process (single mode)" })),
	sessionKey: Type.Optional(
		Type.String({
			description:
				"For bg (non-pane) agents only, single mode. Optional lane id used as the resumed pi session file name; omit for a fresh one-shot lane. Use a stable workflow-scoped id like 'review-issue-123' when you want continuity. Ignored for pane agents (panes already persist via their own session file).",
		}),
	),
	forceSpawn: Type.Optional(
		Type.Boolean({
			description:
				"For pane-mode agents only. When true and a live pane exists, the call errors instead of reusing it. When no live pane exists, the previous session file is archived before launch so the next pane starts fresh. Omit/false resumes or reuses the existing pane session.",
			default: false,
		}),
	),
	resumeSession: Type.Optional(
		Type.String({
			description:
				"For pane-mode agents only. Restore an archived pane session before launching. Use 'latest'/'latest-archived' or an archived session filename/path from sessions/archived. Cannot be combined with forceSpawn.",
		}),
	),
});

export const GetSubagentResultParams = Type.Object({
	taskId: Type.Optional(Type.String({ description: "Persistent pane task ID to retrieve" })),
	agent: Type.Optional(Type.String({ description: "Persistent pane agent name; selects that agent's latest task when taskId is omitted" })),
	wait: Type.Optional(Type.Boolean({ description: "Poll for completion until timeout before returning", default: false })),
	waitFor: Type.Optional(StringEnum(["completion", "idle"] as const, { description: "Wait target when wait=true. completion polls task status; idle waits for pane bridge isIdle=true after an observed busy state and reports never-busy distinctly.", default: "completion" })),
	timeoutMs: Type.Optional(Type.Number({ description: "Maximum wait time when wait=true", default: 30000 })),
	verbose: Type.Optional(Type.Boolean({ description: "Include registry and artifact paths", default: false })),
});

export const WaitForSubagentIdleParams = Type.Object({
	agent: Type.String({ description: "Persistent pane agent name to wait for" }),
	timeoutMs: Type.Optional(Type.Number({ description: "Maximum wait time for isIdle=true after an observed busy state; returns never-busy if pane never leaves idle", default: 30000 })),
});

export const SteerSubagentParams = Type.Object({
	agent: Type.Optional(Type.String({ description: "Persistent pane agent name" })),
	taskId: Type.Optional(Type.String({ description: "Task ID whose agent should be steered" })),
	message: Type.String({ description: "Steering message to send" }),
	deliverAs: Type.Optional(StringEnum(["steer", "send", "follow-up"] as const, { description: "Bridge delivery mode", default: "steer" })),
});

export const StopSubagentParams = Type.Object({
	agent: Type.String({ description: "Persistent pane agent name to stop" }),
});

export const CompleteSubagentParams = Type.Object({
	status: StringEnum(["completed", "blocked", "failed"] as const, { description: "Final task status" }),
	summary: Type.String({ description: "1-3 sentence result summary" }),
	filesChanged: Type.Optional(Type.Array(Type.String(), { description: "Changed files, or empty if none" })),
	validation: Type.Optional(Type.Array(Type.String(), { description: "Validation performed, or empty if none" })),
	notes: Type.Optional(Type.String({ description: "Optional concise notes" })),
});
