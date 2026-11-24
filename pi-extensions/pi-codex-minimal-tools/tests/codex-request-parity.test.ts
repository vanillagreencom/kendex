import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { providerWorld, successSseResponse } from "./helpers/provider.js";

/* The shim replaces Pi's own openai-codex provider, so a real Pi session sends the
 * same turn once through each: Pi's request is the expected one. gpt-6.2-sol takes
 * mid-conversation system messages, `additional_tools` and mid-conversation effort. */

const MODEL_ID = "gpt-6.2-sol";

interface CapturedRequest {
	headers: Record<string, string>;
	body: Record<string, unknown>;
}

function codexJwt(): string {
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	return `header.${payload}.signature`;
}

async function sessionRequest(t: TestContext, fixture: ReturnType<typeof providerWorld>, through: "shim" | "pi"): Promise<CapturedRequest> {
	const requests: CapturedRequest[] = [];
	globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
		const raw = init?.body instanceof Uint8Array ? zstdDecompressSync(init.body).toString("utf8") : String(init?.body);
		requests.push({ headers: Object.fromEntries(new Headers(init?.headers).entries()), body: JSON.parse(raw) });
		return successSseResponse();
	}) as typeof fetch;

	const resourceLoader = new DefaultResourceLoader({
		cwd: fixture.cwd,
		agentDir: fixture.agent,
		noExtensions: true,
		noSkills: true,
		noPromptTemplates: true,
		noThemes: true,
		noContextFiles: true,
		systemPrompt: "Session prompt",
		additionalExtensionPaths: through === "shim" ? [join(import.meta.dirname, "..", "src", "index.ts")] : [],
	});
	await resourceLoader.reload();
	const loaded = resourceLoader.getExtensions();
	assert.deepEqual(loaded.errors, []);
	// Both providers build the same request, so only a call count shows which one served it.
	let shimCalls = 0;
	if (through === "shim") {
		const registration = loaded.runtime.pendingProviderRegistrations.find((entry) => entry.name === "openai-codex");
		const shimStream = registration?.config.streamSimple;
		assert.ok(registration && shimStream, "the package registered no openai-codex provider");
		registration.config.streamSimple = (...args) => {
			shimCalls++;
			return shimStream(...args);
		};
	}
	const { session } = await createAgentSession({
		cwd: fixture.cwd,
		agentDir: fixture.agent,
		resourceLoader,
		sessionManager: SessionManager.inMemory(fixture.cwd),
		settingsManager: SettingsManager.inMemory({ compaction: { enabled: false }, transport: "sse" }),
		tools: ["bash"],
	});
	t.after(() => session.dispose());
	await session.bindExtensions({});
	const codex = session.modelRuntime.getModel("openai-codex", MODEL_ID);
	assert.ok(codex, `Pi's catalog carries no openai-codex ${MODEL_ID}`);
	await session.setModel(codex);
	await session.prompt("hello");

	assert.equal(shimCalls, through === "shim" ? 1 : 0, "the shim served exactly the shim's session");
	assert.equal(requests.length, 1, `the ${through} session sent one request`);
	return requests[0]!;
}

/** The request without the per-session ids, which differ between two sessions. */
function withoutSessionIds({ headers, body }: CapturedRequest): CapturedRequest {
	const { "session-id": _session, "x-client-request-id": _request, ...rest } = headers;
	const { prompt_cache_key: _cacheKey, ...fields } = body;
	return { headers: rest, body: fields };
}

test(`a Pi session on openai-codex ${MODEL_ID} sends Pi's request through the shim`, async (t) => {
	const fixture = providerWorld(t);
	writeFileSync(join(fixture.agent, "auth.json"), JSON.stringify({ "openai-codex": { type: "oauth", access: codexJwt(), refresh: "refresh", expires: Date.now() + 3_600_000, accountId: "acct_test" } }));
	const pi = await sessionRequest(t, fixture, "pi");
	const shim = await sessionRequest(t, fixture, "shim");

	for (const request of [pi, shim]) {
		const input = request.body.input as Array<{ type?: string; role?: string; content?: unknown; tools?: Array<{ name?: string }> }>;
		assert.equal(request.body.instructions, undefined, "no top-level instructions");
		const prompt = input.find((item) => item.content !== undefined);
		assert.equal(prompt?.role, "developer");
		assert.match(String(prompt?.content), /^Session prompt/);
		assert.equal(request.body.tools, undefined, "no top-level tools");
		assert.ok(input.some((item) => item.type === "additional_tools" && item.tools?.some((tool) => tool.name === "bash")), JSON.stringify(input));
		assert.equal(typeof request.body.max_output_tokens, "number");
		assert.equal(request.headers["session-id"], request.body.prompt_cache_key);
		assert.equal(request.headers.session_id, undefined);
		assert.match(request.headers["user-agent"] ?? "", /^pi\/\d+\.\d+\.\d+ \(/);
	}
	assert.deepEqual(withoutSessionIds(shim), withoutSessionIds(pi));
});
