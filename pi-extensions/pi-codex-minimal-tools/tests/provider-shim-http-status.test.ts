import assert from "node:assert/strict";
import test, { afterEach } from "node:test";
import { registerOpenAICodexCustomProvider, withHttpStatusPrefix } from "../src/provider-shim.js";

const originalFetch = globalThis.fetch;
const originalSetTimeout = globalThis.setTimeout;

interface FetchFactory {
	(): Response;
}

afterEach(() => {
	globalThis.fetch = originalFetch;
	globalThis.setTimeout = originalSetTimeout;
});

function installImmediateRetryTimers(): void {
	globalThis.setTimeout = ((callback: TimerHandler, _delay?: number, ...args: unknown[]) => {
		queueMicrotask(() => {
			if (typeof callback === "function") {
				callback(...args);
			}
		});
		return 0 as unknown as ReturnType<typeof setTimeout>;
	}) as unknown as typeof setTimeout;
}

function codexJwt(): string {
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	return `header.${payload}.signature`;
}

function createCodexProvider(): any {
	let provider: any;
	const pi = {
		registerProvider(name: string, value: any) {
			assert.equal(name, "openai-codex");
			provider = value;
		},
		on() {},
		registerMessageRenderer() {},
	};
	registerOpenAICodexCustomProvider(pi as any, { getCurrentCwd: () => process.cwd() });
	assert.ok(provider);
	return provider;
}

function mockFetch(factories: FetchFactory[]): () => number {
	let calls = 0;
	globalThis.fetch = (async () => {
		const factory = factories[Math.min(calls, factories.length - 1)];
		calls++;
		return factory();
	}) as typeof fetch;
	return () => calls;
}

async function runCodexProvider(): Promise<any> {
	const provider = createCodexProvider();
	const stream = provider.streamSimple(
		{
			provider: "openai-codex",
			api: "openai-codex-responses",
			id: "gpt-5.5",
			baseUrl: "https://example.test/backend-api",
			headers: {},
			input: ["text"],
			reasoning: false,
			cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		},
		{
			systemPrompt: "",
			messages: [{ role: "user", content: "hello" }],
			tools: [],
		},
		{ apiKey: codexJwt(), transport: "sse" },
	);
	return stream.result();
}

function errorResponse(status: number, body: unknown, statusText = "Error"): Response {
	return new Response(typeof body === "string" ? body : JSON.stringify(body), { status, statusText });
}

function successSseResponse(): Response {
	const event = {
		type: "response.completed",
		response: {
			id: "resp_ok",
			status: "completed",
			usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } },
		},
	};
	return new Response(`data: ${JSON.stringify(event)}\n\n`, { status: 200, headers: { "content-type": "text/event-stream" } });
}

test("withHttpStatusPrefix adds status once", () => {
	assert.equal(withHttpStatusPrefix(503, "Service unavailable"), "HTTP 503: Service unavailable");
	assert.equal(withHttpStatusPrefix(429, "HTTP 429: Too many requests"), "HTTP 429: Too many requests");
	assert.equal(withHttpStatusPrefix(503, "HTTP 503 upstream unavailable"), "HTTP 503 upstream unavailable");
});

test("final HTTP 429 provider failure preserves friendly usage-limit text after status prefix", async () => {
	installImmediateRetryTimers();
	const fetchCalls = mockFetch([
		() => errorResponse(429, { error: { code: "usage_limit_reached", plan_type: "PLUS", message: "Upstream quota body" } }, "Too Many Requests"),
	]);

	const result = await runCodexProvider();

	assert.equal(fetchCalls(), 4);
	assert.equal(result.stopReason, "error");
	assert.equal(result.errorMessage, "HTTP 429: You have hit your ChatGPT usage limit (plus plan).");
});

test("final HTTP 503 provider failure preserves HTTP status prefix", async () => {
	installImmediateRetryTimers();
	const fetchCalls = mockFetch([
		() => errorResponse(503, { error: { code: "server_error", message: "Service unavailable" } }, "Service Unavailable"),
	]);

	const result = await runCodexProvider();

	assert.equal(fetchCalls(), 4);
	assert.equal(result.stopReason, "error");
	assert.equal(result.errorMessage, "HTTP 503: Service unavailable");
});

test("successful SSE retry hides intermediate HTTP failure", async () => {
	installImmediateRetryTimers();
	const fetchCalls = mockFetch([
		() => errorResponse(503, { error: { code: "server_error", message: "Service unavailable" } }, "Service Unavailable"),
		() => successSseResponse(),
	]);

	const result = await runCodexProvider();

	assert.equal(fetchCalls(), 2);
	assert.equal(result.stopReason, "stop");
	assert.equal(result.errorMessage, undefined);
});
