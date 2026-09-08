import type { AssistantMessage, AssistantMessageEventStream } from "@earendil-works/pi-ai";
import assert from "node:assert/strict";
import { setImmediate } from "node:timers/promises";
import type { TestContext } from "node:test";
import { registerOpenAICodexCustomProvider } from "../../src/provider-shim.js";
import { environment, noProxyEnvironment, world } from "./world.js";

let providerCwd: string | undefined;

/** Restore transport globals and isolate settings for each provider case. */
export function providerWorld(t: Pick<TestContext, "after">) {
	const fixture = world(t);
	providerCwd = fixture.cwd;
	t.after(() => { providerCwd = undefined; });
	environment(t, { ...noProxyEnvironment, PI_CODING_AGENT_DIR: fixture.agent });
	const fetch = globalThis.fetch;
	t.after(() => { globalThis.fetch = fetch; });
	return fixture;
}

/** Advance the test clock only after pending request promises have settled. */
export async function finishRetries<T>(t: TestContext, pending: Promise<T>): Promise<T> {
	let settled = false;
	const observed = pending.finally(() => { settled = true; });
	for (let step = 0; step < 12 && !settled; step++) {
		await setImmediate();
		if (!settled) t.mock.timers.tick(10_000);
	}
	assert.equal(settled, true, "provider did not settle under the controlled retry clock");
	return observed;
}

function codexJwt(): string {
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	return `header.${payload}.signature`;
}

type Provider = { streamSimple(model: unknown, context: unknown, options: unknown): AssistantMessageEventStream };

function createCodexProvider(): Provider {
	let provider: Provider | undefined;
	const pi = {
		registerProvider(name: string, value: Provider) {
			assert.equal(name, "openai-codex");
			provider = value;
		},
		on() {},
		registerMessageRenderer() {},
	};
	registerOpenAICodexCustomProvider(pi as never, { getCurrentCwd: () => { assert.ok(providerCwd); return providerCwd; } });
	assert.ok(provider);
	return provider;
}

export async function runCodexProvider(
	streamOptions: Record<string, unknown> = {},
	modelOverrides: Record<string, unknown> = {},
	contextOverrides: Record<string, unknown> = {},
): Promise<AssistantMessage> {
	const provider = createCodexProvider();
	const stream = provider.streamSimple(
		{
			provider: "openai-codex",
			api: "openai-codex-responses",
			id: "gpt-6-astra",
			baseUrl: "https://example.test/backend-api",
			headers: {},
			input: ["text"],
			reasoning: false,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
			...modelOverrides,
		},
		{
			systemPrompt: "",
			messages: [{ role: "user", content: "hello" }],
			tools: [],
			...contextOverrides,
		},
		{ apiKey: codexJwt(), transport: "sse", ...streamOptions },
	);
	return stream.result();
}

export function errorResponse(status: number, body: unknown, statusText = "Error"): Response {
	return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, statusText });
}

export const completedEvent = {
	type: "response.completed",
	response: {
		id: "resp_ok",
		status: "completed",
		usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } },
	},
};

export function sseResponse(body: string): Response {
	return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

export function successSseResponse(): Response {
	return sseResponse(`data: ${JSON.stringify(completedEvent)}\n\n`);
}

