import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { acquireFileLock } from "../extensions/subagent/file-lock.js";
import subagentExtension from "../extensions/subagent/index.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { readTaskRegistry, writeTaskRegistry } from "../extensions/subagent/tasks.js";

function tempRuntime(): string {
	return mkdtempSync(join(tmpdir(), "subagent-lifecycle-event-"));
}

async function waitForTask(runtimeRoot: string, taskId: string) {
	for (let i = 0; i < 20; i += 1) {
		const record = (await readTaskRegistry(runtimeRoot))[taskId];
		if (record?.status === "needs_completion") return record;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	return (await readTaskRegistry(runtimeRoot))[taskId];
}

describe("subagent lifecycle event persistence", () => {
	test("needs_completion events persist cwdSnapshot and diagnostics", async () => {
		const runtimeRoot = tempRuntime();
		try {
			await writeTaskRegistry(runtimeRoot, {
				"task-event": {
					agent: "rust",
					createdAt: "2026-05-20T00:00:00.000Z",
					kind: "oneshot",
					status: "running",
					task: "Do work",
					taskId: "task-event",
				},
			});
			const bus = new EventEmitter();
			const pi = {
				appendEntry: () => undefined,
				events: { emit: bus.emit.bind(bus), on: bus.on.bind(bus) },
				getActiveTools: () => [],
				getThinkingLevel: () => undefined,
				on: () => undefined,
				registerCommand: () => undefined,
				registerMessageRenderer: () => undefined,
				registerShortcut: () => undefined,
				registerTool: () => undefined,
				sendMessage: () => undefined,
				sendUserMessage: async () => undefined,
			} as any;
			subagentExtension(pi);

			bus.emit("subagents:needs_completion", {
				agent: "rust",
				cwdSnapshot: {
					cwd: "/repo\u001b[31m/evil```path",
					dirty: true,
					head: "abc123",
					lastCommit: { subject: "fix \u001b[32m```subject" },
					status: " M file.ts\n```\u001b[0m",
				},
				diagnostics: ["diag \u001b[31m```evil"],
				mode: "oneshot",
				reason: "turn-ended-without-complete-subagent",
				runtimeRoot,
				status: "needs_completion",
				summary: "missing completion",
				taskId: "task-event",
			});

			const record = await waitForTask(runtimeRoot, "task-event");

			expect(record?.status).toBe("needs_completion");
			expect(record?.cwdSnapshot?.cwd).not.toContain("\u001b");
			expect(record?.cwdSnapshot?.cwd).not.toContain("```");
			expect(record?.cwdSnapshot?.lastCommit.subject).not.toContain("\u001b");
			expect(record?.cwdSnapshot?.lastCommit.subject).not.toContain("```");
			expect(record?.diagnostics?.join("\n")).toContain("diag");
			expect(record?.diagnostics?.join("\n")).not.toContain("\u001b");
			expect(record?.diagnostics?.join("\n")).not.toContain("```");
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
		}
	});

	test("session shutdown drains in-flight completion usage persistence", async () => {
		const runtimeRoot = tempRuntime();
		const transcriptPath = join(runtimeRoot, "completion.jsonl");
		let releaseLock: (() => Promise<void>) | undefined;
		try {
			writeFileSync(transcriptPath, JSON.stringify({ event: { type: "message_end", message: { usage: { input: 7, output: 3 } } } }));
			await writeTaskRegistry(runtimeRoot, {
				"task-usage": {
					agent: "rust",
					createdAt: "2026-05-20T00:00:00.000Z",
					kind: "oneshot",
					status: "running",
					task: "Do work",
					taskId: "task-usage",
					transcriptPath,
				},
			});
			releaseLock = await acquireFileLock(taskRegistryPath(runtimeRoot));

			const bus = new EventEmitter();
			const handlers = new Map<string, Array<(event: any, ctx: any) => unknown>>();
			const pi = {
				appendEntry: () => undefined,
				events: { emit: bus.emit.bind(bus), on: bus.on.bind(bus) },
				getActiveTools: () => [],
				getThinkingLevel: () => undefined,
				on: (name: string, handler: (event: any, ctx: any) => unknown) => {
					const registered = handlers.get(name) ?? [];
					registered.push(handler);
					handlers.set(name, registered);
				},
				registerCommand: () => undefined,
				registerMessageRenderer: () => undefined,
				registerShortcut: () => undefined,
				registerTool: () => undefined,
				sendMessage: () => undefined,
				sendUserMessage: async () => undefined,
			} as any;
			subagentExtension(pi);

			bus.emit("subagents:completed", {
				agent: "rust",
				mode: "oneshot",
				runtimeRoot,
				status: "completed",
				taskId: "task-usage",
				transcriptPath,
			});

			const shutdown = handlers.get("session_shutdown")?.[0];
			expect(shutdown).toBeDefined();
			let shutdownSettled = false;
			const shutdownPromise = Promise.resolve(shutdown?.({ reason: "quit" }, {})).then(() => {
				shutdownSettled = true;
			});
			await new Promise((resolve) => setTimeout(resolve, 20));
			expect(shutdownSettled).toBeFalse();

			await releaseLock();
			releaseLock = undefined;
			await shutdownPromise;

			const record = (await readTaskRegistry(runtimeRoot))["task-usage"];
			expect(record?.usage?.input).toBe(7);
			expect(record?.usage?.output).toBe(3);
		} finally {
			await releaseLock?.();
			rmSync(runtimeRoot, { force: true, recursive: true });
		}
	});
});
