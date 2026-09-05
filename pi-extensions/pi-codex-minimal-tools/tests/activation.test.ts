import assert from "node:assert/strict";
import test from "node:test";
import codexMinimalTools from "../src/index.js";
import { hasOpenAiModelsLoaded } from "../src/activation.js";

function fakePi() {
	const handlers: Record<string, Function[]> = {};
	const tools: any[] = [];
	let activeTools = ["read", "bash"];
	return {
		activeTools,
		handlers,
		tools,
		registerCommand() {},
		registerProvider() {},
		registerMessageRenderer() {},
		registerTool(tool: any) { tools.push(tool); },
		on(event: string, handler: Function) { (handlers[event] ??= []).push(handler); },
		getActiveTools() { return activeTools; },
		setActiveTools(next: string[]) { activeTools = next; this.activeTools = next; },
	};
}

async function emit(pi: ReturnType<typeof fakePi>, event: string, ctx: any): Promise<void> {
	for (const handler of pi.handlers[event] ?? []) await handler({}, ctx);
}

test("hasOpenAiModelsLoaded detects active or registry OpenAI models", () => {
	assert.equal(hasOpenAiModelsLoaded({ model: { provider: "anthropic", id: "claude" }, modelRegistry: { getAll: () => [] } }), false);
	assert.equal(hasOpenAiModelsLoaded({ model: { provider: "notopenai", id: "claude" }, modelRegistry: { getAll: () => [] } }), false);
	assert.equal(hasOpenAiModelsLoaded({ model: { provider: "openai-codex", id: "gpt-6-astra" }, modelRegistry: { getAll: () => [] } }), true);
	assert.equal(hasOpenAiModelsLoaded({ modelRegistry: { getAll: () => [{ provider: "openai", id: "gpt-6-astra" }] } }), true);
	assert.equal(hasOpenAiModelsLoaded({ modelRegistry: { find: (provider, id) => provider === "openai" && id === "gpt-5.2" ? { provider, id } : undefined } }), true);
});

test("extension does not register tools until OpenAI models are loaded", async () => {
	const pi = fakePi();
	codexMinimalTools(pi as any);
	assert.equal(pi.tools.length, 0);

	await emit(pi, "session_start", {
		cwd: process.cwd(),
		model: { provider: "anthropic", id: "claude", input: ["text"] },
		modelRegistry: { getAll: () => [{ provider: "anthropic", id: "claude" }] },
	});
	assert.equal(pi.tools.length, 0);
	assert.deepEqual(pi.activeTools, ["read", "bash"]);

	await emit(pi, "model_select", {
		cwd: process.cwd(),
		model: { provider: "openai-codex", id: "gpt-6-astra", input: ["text", "image"] },
		modelRegistry: { getAll: () => [{ provider: "openai-codex", id: "gpt-6-astra" }] },
	});
	assert.equal(pi.tools.length, 3);
	assert.deepEqual(pi.tools.map((tool) => tool.name).sort(), ["apply_patch", "image_generation", "view_image"].sort());
	assert.ok(pi.activeTools.includes("read"));
	assert.ok(pi.activeTools.includes("bash"));
	assert.ok(pi.activeTools.includes("apply_patch"));
});

test("active non-OpenAI models remove package tools even when OpenAI models exist in registry", async () => {
	const pi = fakePi();
	pi.setActiveTools(["read", "view_image", "apply_patch", "image_generation"]);
	codexMinimalTools(pi as any);

	await emit(pi, "model_select", {
		cwd: process.cwd(),
		model: { provider: "claude-bridge", id: "claude-opus-4-7", input: ["text", "image"] },
		modelRegistry: { getAll: () => [{ provider: "openai-codex", id: "gpt-6-astra", input: ["text", "image"] }] },
	});

	assert.deepEqual(pi.activeTools, ["read"]);
});
