import assert from "node:assert/strict";
import test from "node:test";
import codexMinimalTools from "../src/index.js";
import { environment, world } from "./helpers/world.js";

function fakePi() {
	const handlers: Record<string, Array<(event: unknown, ctx: unknown) => unknown>> = {};
	const tools: Array<{ name: string }> = [];
	let activeTools = ["read", "bash"];
	return {
		activeTools,
		handlers,
		tools,
		registerCommand() {},
		registerProvider() {},
		registerMessageRenderer() {},
		registerTool(tool: { name: string }) { tools.push(tool); },
		on(event: string, handler: (event: unknown, ctx: unknown) => unknown) { (handlers[event] ??= []).push(handler); },
		getActiveTools() { return activeTools; },
		setActiveTools(next: string[]) { activeTools = next; this.activeTools = next; },
	};
}

async function emit(pi: ReturnType<typeof fakePi>, event: string, ctx: unknown): Promise<void> {
	assert.ok(pi.handlers[event], event);
	for (const handler of pi.handlers[event]) await handler({}, ctx);
}

const openai = { provider: "openai-codex", id: "gpt-6-astra", input: ["text", "image"] };
const anthropic = { provider: "anthropic", id: "claude", input: ["text"] };
const packageNames = ["apply_patch", "image_generation", "view_image"];
for (const row of [
	{
		name: "deferred registration then model switch", initial: ["read", "bash"],
		steps: [
			{ event: "session_start", model: anthropic, registry: [anthropic], registered: [], active: ["read", "bash"] },
			{ event: "model_select", model: openai, registry: [openai], registered: packageNames, active: ["read", "bash", "apply_patch", "image_generation"] },
		],
	},
	{
		name: "unsupported active model with OpenAI still registered", initial: ["read", "view_image", "apply_patch", "image_generation"],
		steps: [{ event: "model_select", model: { provider: "claude-bridge", id: "claude-opus-4-7", input: ["text", "image"] }, registry: [openai], registered: packageNames, active: ["read"] }],
	},
]) {
	test(`extension activation: ${row.name}`, async (t) => {
		const { cwd, agent } = world(t);
		environment(t, { PI_CODING_AGENT_DIR: agent });
		const pi = fakePi();
		pi.setActiveTools(row.initial);
		codexMinimalTools(pi as never);
		assert.equal(pi.tools.length, 0);
		for (const step of row.steps) {
			await emit(pi, step.event, { cwd, model: step.model, modelRegistry: { getAll: () => step.registry } });
			assert.deepEqual(pi.tools.map((tool) => tool.name).sort(), [...step.registered].sort());
			assert.deepEqual([...pi.activeTools].sort(), [...step.active].sort());
		}
	});
}
