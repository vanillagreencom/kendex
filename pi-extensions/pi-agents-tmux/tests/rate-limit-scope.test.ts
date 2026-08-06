import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { STATS_BRIDGE_SYMBOL, STATUSLINE_SYMBOL } from "../extensions/subagent/types.js";

const RATE_LIMIT_MESSAGE_END = {
	message: {
		content: [{ text: "API Error: Server is temporarily limiting requests. Rate limited.", type: "text" }],
		errorMessage: "API Error: Server is temporarily limiting requests. Rate limited.",
		role: "assistant",
		stopReason: "error",
	},
	type: "message_end",
};

const HEALTHY_MESSAGE_END = {
	message: {
		content: [{ text: "Recovered.", type: "text" }],
		role: "assistant",
		stopReason: "stop",
	},
	type: "message_end",
};

function restoreEnv(name: string, value: string | undefined): void {
	if (value === undefined) delete process.env[name];
	else process.env[name] = value;
}

async function runRateLimitScopeCase(childOwnsVisiblePane: boolean): Promise<{
	lifecycleEvents: Array<{ name: string; payload: unknown }>;
	sendCalls: string[];
}> {
	const cwd = mkdtempSync(join(tmpdir(), "rate-limit-scope-"));
	const piUserDir = join(cwd, ".pi-agent-home");
	mkdirSync(piUserDir, { recursive: true });
	const previousEnv = {
		backoffLadder: process.env.VSTACK_RATE_LIMIT_BACKOFF_LADDER,
		childAgent: process.env.PI_SUBAGENT_CHILD_AGENT,
		childPane: process.env.PI_SUBAGENT_CHILD_PANE,
		piDir: process.env.PI_CODING_AGENT_DIR,
		watchdog: process.env.VSTACK_RATE_LIMIT_WATCHDOG,
	};
	const globals = globalThis as unknown as Record<PropertyKey, unknown>;
	const previousStatusline = {
		exists: Object.prototype.hasOwnProperty.call(globals, STATUSLINE_SYMBOL),
		value: globals[STATUSLINE_SYMBOL],
	};
	const previousStats = {
		exists: Object.prototype.hasOwnProperty.call(globals, STATS_BRIDGE_SYMBOL),
		value: globals[STATS_BRIDGE_SYMBOL],
	};
	const handlers = new Map<string, Array<(event: any, ctx: any) => void | Promise<void>>>();
	const lifecycleEvents: Array<{ name: string; payload: unknown }> = [];
	const sendCalls: string[] = [];

	try {
		process.env.PI_SUBAGENT_CHILD_AGENT = "reviewer-test";
		if (childOwnsVisiblePane) process.env.PI_SUBAGENT_CHILD_PANE = "1";
		else delete process.env.PI_SUBAGENT_CHILD_PANE;
		process.env.PI_CODING_AGENT_DIR = piUserDir;
		process.env.VSTACK_RATE_LIMIT_BACKOFF_LADDER = "0.001";
		process.env.VSTACK_RATE_LIMIT_WATCHDOG = "1";

		const bus = new EventEmitter();
		for (const name of ["subagents:rate_limited", "subagents:rate_limit_resolved"]) {
			bus.on(name, (payload) => lifecycleEvents.push({ name, payload }));
		}
		const pi = {
			appendEntry: () => undefined,
			events: bus,
			getActiveTools: () => [],
			getThinkingLevel: () => undefined,
			on: (name: string, handler: (event: any, ctx: any) => void | Promise<void>) => {
				const registered = handlers.get(name) ?? [];
				registered.push(handler);
				handlers.set(name, registered);
			},
			registerCommand: () => undefined,
			registerMessageRenderer: () => undefined,
			registerShortcut: () => undefined,
			registerTool: () => undefined,
			sendMessage: () => undefined,
			sendUserMessage: async (message: string) => {
				sendCalls.push(message);
			},
		} as any;
		const url = new URL("../extensions/subagent/index.ts", import.meta.url);
		url.searchParams.set("t", `${Date.now()}-${Math.random()}`);
		const extension = (await import(url.href)).default;
		extension(pi);

		const ctx = {
			cwd,
			hasUI: false,
			isIdle: () => true,
			model: undefined,
			sessionManager: {
				getBranch: () => [],
				getSessionFile: () => undefined,
				getSessionId: () => "rate-limit-scope-test",
			},
			ui: {
				confirm: async () => true,
				setStatus: () => undefined,
				setTitle: () => undefined,
				setWidget: () => undefined,
			},
		};
		for (const handler of handlers.get("message_end") ?? []) await handler(RATE_LIMIT_MESSAGE_END, ctx);
		for (const handler of handlers.get("agent_end") ?? []) await handler({ type: "agent_end" }, ctx);
		for (const handler of handlers.get("agent_settled") ?? []) await handler({ type: "agent_settled" }, ctx);
		if (childOwnsVisiblePane) {
			for (const handler of handlers.get("message_end") ?? []) await handler(HEALTHY_MESSAGE_END, ctx);
		}
		await new Promise((resolve) => setTimeout(resolve, 10));
	} finally {
		restoreEnv("PI_SUBAGENT_CHILD_AGENT", previousEnv.childAgent);
		restoreEnv("PI_SUBAGENT_CHILD_PANE", previousEnv.childPane);
		restoreEnv("PI_CODING_AGENT_DIR", previousEnv.piDir);
		restoreEnv("VSTACK_RATE_LIMIT_BACKOFF_LADDER", previousEnv.backoffLadder);
		restoreEnv("VSTACK_RATE_LIMIT_WATCHDOG", previousEnv.watchdog);
		if (previousStatusline.exists) globals[STATUSLINE_SYMBOL] = previousStatusline.value;
		else delete globals[STATUSLINE_SYMBOL];
		if (previousStats.exists) globals[STATS_BRIDGE_SYMBOL] = previousStats.value;
		else delete globals[STATS_BRIDGE_SYMBOL];
		rmSync(cwd, { force: true, recursive: true });
	}

	assert.equal(Object.prototype.hasOwnProperty.call(globals, STATUSLINE_SYMBOL), previousStatusline.exists);
	assert.equal(Object.prototype.hasOwnProperty.call(globals, STATS_BRIDGE_SYMBOL), previousStats.exists);
	if (previousStatusline.exists) assert.equal(globals[STATUSLINE_SYMBOL], previousStatusline.value);
	if (previousStats.exists) assert.equal(globals[STATS_BRIDGE_SYMBOL], previousStats.value);
	return { lifecycleEvents, sendCalls };
}

test("bg child rate-limit lifecycle does not schedule pane recovery before settlement", async () => {
	const result = await runRateLimitScopeCase(false);
	assert.deepEqual(result.lifecycleEvents, []);
	assert.deepEqual(result.sendCalls, []);
});

test("visible pane child rate-limit lifecycle schedules and cancels pane recovery", async () => {
	const result = await runRateLimitScopeCase(true);
	assert.deepEqual(result.lifecycleEvents.map((event) => event.name), [
		"subagents:rate_limited",
		"subagents:rate_limit_resolved",
	]);
	assert.deepEqual(result.sendCalls, []);
});
