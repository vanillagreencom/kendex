import { EventEmitter } from "node:events";
import { mkdtempSync, writeFileSync } from "node:fs";
import { removeSettled } from "./remove-settled.js";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { acquireFileLock } from "../extensions/subagent/file-lock.js";
import subagentExtension from "../extensions/subagent/index.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { sessionRuntimeDir } from "../extensions/subagent/settings.js";
import { readTaskRegistry, updateTaskRegistry, writeTaskRegistry } from "../extensions/subagent/tasks.js";
import { stripAnsi, theme, writeSettings } from "./browser-fixture.js";

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

// Picks the completion poll out of the scheduled intervals; every other interval runs for real.
const COMPLETION_POLL_MS = 1234;

describe("subagent lifecycle event persistence", () => {
	test("the completion poll puts a running child's transcript activity on its dashboard row, and a registry update keeps it", async () => {
		const cwd = mkdtempSync(join(tmpdir(), "subagent-activity-relay-"));
		const envKeys = ["PI_CODING_AGENT_DIR", "PI_SUBAGENT_CHILD_AGENT", "PI_SUBAGENT_CHILD_PANE"] as const;
		const previousEnv = Object.fromEntries(envKeys.map((key) => [key, process.env[key]]));
		const realSetInterval = globalThis.setInterval;
		const stackSymbol = Symbol.for("kendex.pi.mini-dashboard-stack");
		const globals = globalThis as unknown as Record<PropertyKey, unknown>;
		const previousStack = globals[stackSymbol];
		let shutdown: ((event: unknown, ctx: unknown) => unknown) | undefined;
		let component: { render(width: number): string[]; dispose?(): void } | undefined;
		try {
			process.env.PI_CODING_AGENT_DIR = join(cwd, ".pi-agent-home");
			delete process.env.PI_SUBAGENT_CHILD_AGENT;
			delete process.env.PI_SUBAGENT_CHILD_PANE;
			delete globals[stackSymbol];
			writeSettings(cwd, { completionPollMs: COMPLETION_POLL_MS, dashboard: true });
			const runtimeRoot = sessionRuntimeDir("activity-relay-session");
			const transcriptPath = join(cwd, "child.jsonl");
			writeFileSync(transcriptPath, `${JSON.stringify({ event: { type: "tool_execution_start", toolName: "Bash" } })}\n`);
			await writeTaskRegistry(runtimeRoot, {
				"task-activity": { agent: "rust", createdAt: "2026-05-20T00:00:00.000Z", kind: "oneshot", status: "running", task: "initial prompt", taskId: "task-activity", transcriptPath },
			});

			let completionPoll: (() => void) | undefined;
			(globalThis as any).setInterval = (handler: () => void, ms: number) => {
				if (ms !== COMPLETION_POLL_MS) return realSetInterval(handler, ms);
				completionPoll = handler;
				return { unref: () => undefined };
			};
			const bus = new EventEmitter();
			const handlers = new Map<string, (event: unknown, ctx: unknown) => unknown>();
			const pi = {
				appendEntry: () => undefined,
				events: { emit: bus.emit.bind(bus), on: bus.on.bind(bus) },
				getActiveTools: () => [],
				getThinkingLevel: () => undefined,
				on: (name: string, handler: (event: unknown, ctx: unknown) => unknown) => handlers.set(name, handler),
				registerCommand: () => undefined,
				registerMessageRenderer: () => undefined,
				registerShortcut: () => undefined,
				registerTool: () => undefined,
				sendMessage: () => undefined,
				sendUserMessage: async () => undefined,
			} as any;
			subagentExtension(pi);
			let stackFactory: ((tui: unknown, widgetTheme: unknown) => typeof component) | undefined;
			const ctx = {
				cwd,
				hasUI: true,
				isIdle: () => true,
				isProjectTrusted: () => true,
				sessionManager: { getBranch: () => [], getSessionFile: () => undefined, getSessionId: () => "activity-relay-session" },
				ui: {
					confirm: async () => true,
					setStatus: () => undefined,
					setTitle: () => undefined,
					setWidget: (_key: string, factory: typeof stackFactory) => {
						if (factory) stackFactory = factory;
					},
				},
			};
			shutdown = handlers.get("session_shutdown");
			await handlers.get("session_start")?.({}, ctx);
			const render = () => {
				component ??= stackFactory?.({ requestRender: () => undefined, terminal: { rows: 40 } }, theme);
				return stripAnsi(component?.render(200).join("\n") ?? "");
			};
			// Polls until the render holds. A poll still in flight ignores the next tick, so the loop
			// ticks every round; the real wait bounds how long the poll's file reads take.
			const pollUntil = async (holds: (rendered: string) => boolean) => {
				for (let i = 0; i < 100 && !holds(render()); i += 1) {
					completionPoll?.();
					await new Promise((resolve) => setTimeout(resolve, 10));
				}
				return render();
			};

			expect(await pollUntil((rendered) => rendered.includes("tool: Bash"))).toContain("tool: Bash");

			await updateTaskRegistry(runtimeRoot, (records) => {
				records["task-activity"] = { ...records["task-activity"]!, updatedAt: "2026-05-20T00:01:00.000Z", usage: { input: 4321, output: 1, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 1 } };
			});
			expect(completionPoll).toBeDefined();
			const afterUpdate = await pollUntil((rendered) => rendered.includes("\u2191"));
			expect([afterUpdate.includes("\u2191"), afterUpdate.includes("tool: Bash")]).toEqual([true, true]);
		} finally {
			component?.dispose?.();
			globalThis.setInterval = realSetInterval;
			await shutdown?.({ reason: "quit" }, {});
			if (previousStack === undefined) delete globals[stackSymbol];
			else globals[stackSymbol] = previousStack;
			for (const key of envKeys) {
				if (previousEnv[key] === undefined) delete process.env[key];
				else process.env[key] = previousEnv[key];
			}
			await removeSettled(cwd);
		}
	});

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
			await removeSettled(runtimeRoot);
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
			await removeSettled(runtimeRoot);
		}
	});
});
