// Surface: task-state injection through Pi's agent-start and context events.
// Inputs: extensions/task-panel.ts and its imports, tests/lib/fake-pi.ts.
import { expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.ts";

mockPiModules();

type ContextMessage = { customType: string; content: string; display: boolean };
type StartResult = { message?: ContextMessage; systemPrompt?: string } | undefined;
const CONTEXT_TYPE = "kendex-task-panel:context";
const SYSTEM_PROMPT = "The host's unchanged system prompt.";

test("task changes preserve the system prompt and earlier request messages", async () => {
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	const scratch = fileURLToPath(new URL("../../../tmp/", import.meta.url));
	mkdirSync(scratch, { recursive: true });
	const base = mkdtempSync(join(scratch, "task-panel-prompt-cache-"));
	try {
		const agentDir = join(base, "agent");
		mkdirSync(agentDir);
		process.env.PI_CODING_AGENT_DIR = agentDir;
		clearPackageConfigCache();
		const { default: taskPanel } = await import("../extensions/task-panel.js");
		const pi = fakePi();
		taskPanel(pi as never);
		const ctx = fakeCtx(base, "prompt-cache");
		const branch: Array<{ type: string; customType?: string; content?: string }> = [];
		ctx.sessionManager.getBranch = () => branch as never;
		const start = () => pi.handlers.get("before_agent_start")!({ systemPrompt: SYSTEM_PROMPT }, ctx) as StartResult;
		const write = (params: Record<string, unknown>) => pi.tools.get("tasks_write").execute("call", params, undefined, undefined, ctx);
		const messages: Array<ContextMessage | { role: string; content: string }> = [];
		let previousRequest: typeof messages = [];
		const rows = [
			{ name: "empty", change: async () => {}, inject: false },
			{ name: "first active", change: () => write({ action: "replace", tasks: [{ content: "first" }, { content: "second" }] }), inject: true },
			{ name: "unchanged", change: async () => {}, inject: false },
			{ name: "changed active", change: () => write({ action: "start_task", task: "second" }), inject: true },
			{ name: "completed", change: () => write({ action: "replace", tasks: [{ content: "first", status: "completed" }, { content: "second", status: "completed" }] }), inject: true },
			{ name: "completed unchanged", change: async () => {}, inject: false },
			{ name: "reminder off", change: async () => {
				writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-task-panel": { showWorkflowReminder: false } } } } }));
				clearPackageConfigCache();
			}, inject: false },
		];
		for (const row of rows) {
			await row.change();
			messages.push({ role: "user", content: row.name });
			const result = start();
			expect(result?.systemPrompt ?? SYSTEM_PROMPT).toBe(SYSTEM_PROMPT);
			expect(result?.message !== undefined).toBe(row.inject);
			if (result?.message) {
				expect(result.message.customType).toBe(CONTEXT_TYPE);
				expect(result.message.display).toBe(false);
				messages.push(result.message);
				branch.push({ type: "custom_message", customType: result.message.customType, content: result.message.content });
			}
			const transformed = pi.handlers.get("context")?.({ messages }, ctx) as { messages: typeof messages } | undefined;
			const request = transformed?.messages ?? messages;
			expect(request.slice(0, previousRequest.length)).toEqual(previousRequest);
			expect(request).toEqual(messages);
			previousRequest = [...request];
			messages.push({ role: "assistant", content: "answer" });
		}
		// A resumed branch already holding this snapshot needs no duplicate.
		rmSync(join(agentDir, "settings.json"));
		clearPackageConfigCache();
		const resumed = fakePi();
		taskPanel(resumed as never);
		await resumed.tools.get("tasks_write").execute("call", { action: "replace", tasks: [{ content: "first", status: "completed" }, { content: "second", status: "completed" }] }, undefined, undefined, ctx);
		expect(resumed.handlers.get("before_agent_start")!({ systemPrompt: SYSTEM_PROMPT }, ctx)).toBeUndefined();
		await write({ action: "start_task", task: "first" });
		const beforeCompaction = start()?.message;
		expect(beforeCompaction).toBeDefined();
		branch.push({ type: "custom_message", ...beforeCompaction });
		expect(start()).toBeUndefined();
		branch.push({ type: "compaction" });
		expect(start()?.message).toEqual(beforeCompaction);
		branch.length = 0;
		expect(start()?.message).toBeDefined();
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
		clearPackageConfigCache();
		rmSync(base, { recursive: true, force: true });
	}
});
