import { beforeEach, describe, expect, test } from "bun:test";

import { buildSubagentActivity, publishSubagentActivity, type PiActivityEvent } from "../activity.js";

const BROKER_SYMBOL = Symbol.for("vstack.pi.activity");

function installBroker(): PiActivityEvent[] {
	const events: PiActivityEvent[] = [];
	(globalThis as unknown as Record<PropertyKey, unknown>)[BROKER_SYMBOL] = {
		publish(event: PiActivityEvent) { events.push(event); },
	};
	return events;
}

beforeEach(() => {
	delete (globalThis as unknown as Record<PropertyKey, unknown>)[BROKER_SYMBOL];
});

describe("subagent activity", () => {
	test("spawn/queued/started/completed/failed/blocked/needs_completion each publish", () => {
		const events = installBroker();
		publishSubagentActivity("subagents:created", { agent: "rust", paneId: "%11" });
		publishSubagentActivity("subagents:queued", { agent: "rust", taskId: "task-1", task: "do work" });
		publishSubagentActivity("subagents:started", { agent: "rust", taskId: "task-1", status: "running" });
		publishSubagentActivity("subagents:completed", { agent: "rust", taskId: "task-1", status: "completed", summary: "done" });
		publishSubagentActivity("subagents:failed", { agent: "rust", taskId: "task-2", status: "failed", summary: "failed" });
		publishSubagentActivity("subagents:failed", { agent: "rust", taskId: "task-3", status: "blocked", summary: "blocked" });
		publishSubagentActivity("subagents:needs_completion", { agent: "rust", taskId: "task-4", status: "needs_completion", summary: "missing" });
		publishSubagentActivity("subagents:failed", { agent: "rust", status: "failed", reason: "pane-cwd-stale", summary: "stale cwd", cwdPid: "123", expectedCwd: "/new", actualCwdRaw: "/old (deleted)", cwdReason: "deleted" });

		expect(events.map((event) => event.type)).toEqual([
			"agent.spawned",
			"agent.task_queued",
			"agent.task_started",
			"agent.task_completed",
			"agent.task_failed",
			"agent.task_blocked",
			"agent.needs_completion",
			"agent.pane_cwd_stale",
		]);
		expect(events[3]).toMatchObject({ importance: "normal", severity: "success" });
		expect(events[4]).toMatchObject({ importance: "important", severity: "error" });
		expect(events[5]).toMatchObject({ importance: "important", severity: "warning" });
		expect(events[6]?.refs).toMatchObject({ agent: "rust", task_id: "task-4" });
		expect(events[7]).toMatchObject({ importance: "important", severity: "error", summary: "stale cwd" });
		expect(events[7]?.details).toMatchObject({ cwdPid: "123", expectedCwd: "/new", actualCwdRaw: "/old (deleted)", cwdReason: "deleted" });
	});

	test("steered publishes noisy activity", () => {
		const events = installBroker();
		publishSubagentActivity("subagents:steered", { agent: "rust", taskId: "task-1", message: "continue" });
		expect(events[0]).toMatchObject({ importance: "noisy", severity: "info", type: "agent.steered" });
	});

	test("empty_after_compact includes cwdSnapshot details", () => {
		const events = installBroker();
		publishSubagentActivity("subagents:needs_completion", {
			agent: "rust",
			cwdSnapshot: {
				cwd: "/repo",
				dirty: true,
				head: "abc123",
				lastCommit: { subject: "last change" },
				status: " M file.ts",
			},
			reason: "compact-then-empty",
			status: "needs_completion",
			summary: "empty after compact",
			taskId: "task-empty",
		});

		expect(events[0]).toMatchObject({ importance: "important", severity: "warning", type: "agent.empty_after_compact" });
		expect(events[0]?.details?.cwdSnapshot).toEqual({
			cwd: "/repo",
			dirty: true,
			head: "abc123",
			lastCommit: { subject: "last change" },
			status: " M file.ts",
		});
	});

	test("generic needs_completion includes cwdSnapshot details", () => {
		const events = installBroker();
		publishSubagentActivity("subagents:needs_completion", {
			agent: "rust",
			cwdSnapshot: {
				cwd: "/repo",
				dirty: false,
				head: "def456",
				lastCommit: { subject: "finished work" },
				status: "",
			},
			reason: "turn-ended-without-complete-subagent",
			status: "needs_completion",
			summary: "missing completion",
			taskId: "task-needs",
		});

		expect(events[0]).toMatchObject({ importance: "important", severity: "warning", type: "agent.needs_completion" });
		expect(events[0]?.details?.cwdSnapshot).toEqual({
			cwd: "/repo",
			dirty: false,
			head: "def456",
			lastCommit: { subject: "finished work" },
			status: "",
		});
	});

	test("cwdSnapshot details strip controls and escape fences", () => {
		const events = installBroker();
		publishSubagentActivity("subagents:needs_completion", {
			agent: "rust",
			cwdSnapshot: {
				cwd: "/repo\u001b[31m/evil```path",
				dirty: true,
				head: "abc123",
				lastCommit: { subject: "fix \u001b[32m```subject" },
				status: " M file.ts\n```\u001b[0m",
			},
			status: "needs_completion",
			summary: "missing completion",
			taskId: "task-sanitize",
		});

		const snapshot = events[0]?.details?.cwdSnapshot as { cwd: string; lastCommit: { subject: string }; status: string };
		expect(snapshot.cwd).not.toContain("\u001b");
		expect(snapshot.cwd).not.toContain("```");
		expect(snapshot.lastCommit.subject).not.toContain("\u001b");
		expect(snapshot.lastCommit.subject).not.toContain("```");
		expect(snapshot.status).not.toContain("\u001b");
		expect(snapshot.status).not.toContain("```");
	});

	test("builder returns null for unrelated subagent bus events", () => {
		expect(buildSubagentActivity("subagents:ready", { mode: "extension" })).toBeNull();
	});
});
