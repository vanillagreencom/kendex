import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { codexWebSocket, providerWorld, sseResponse, textResponseEvents } from "./helpers/provider.js";

/* The shim replaces Pi's own openai-codex provider, so a real Pi session sends the
 * same two turns once through each: Pi's requests are the expected ones. gpt-6.2-sol
 * takes mid-conversation system messages, `additional_tools` and mid-conversation
 * effort, so the thinking-level change between the turns travels as configuration_update
 * items. Over WebSocket the headers are the handshake's and the body is the sent frame. */

const MODEL_ID = "gpt-6.2-sol";
type Transport = "sse" | "websocket";

/** The headers of each HTTP request or WebSocket handshake, and each request body or sent frame. */
interface CapturedSession {
	headers: Array<Record<string, string>>;
	bodies: Array<Record<string, unknown>>;
}

function codexJwt(): string {
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	return `header.${payload}.signature`;
}

async function sessionRequests(t: TestContext, fixture: ReturnType<typeof providerWorld>, through: "shim" | "pi", transport: Transport): Promise<CapturedSession> {
	const http: CapturedSession = { headers: [], bodies: [] };
	globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
		const raw = init?.body instanceof Uint8Array ? zstdDecompressSync(init.body).toString("utf8") : String(init?.body);
		http.headers.push(Object.fromEntries(new Headers(init?.headers).entries()));
		http.bodies.push(JSON.parse(raw));
		const events = textResponseEvents(`resp_${http.bodies.length}`, `msg_${http.bodies.length}`);
		return sseResponse(events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join(""));
	}) as typeof fetch;
	const socket = codexWebSocket(t);

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
		settingsManager: SettingsManager.inMemory({ compaction: { enabled: false }, transport }),
		tools: ["bash"],
	});
	t.after(() => session.dispose());
	await session.bindExtensions({});
	const codex = session.modelRuntime.getModel("openai-codex", MODEL_ID);
	assert.ok(codex, `Pi's catalog carries no openai-codex ${MODEL_ID}`);
	await session.setModel(codex);
	session.setThinkingLevel("low");
	await session.prompt("hello");
	session.setThinkingLevel("high");
	await session.prompt("again");

	assert.equal(shimCalls, through === "shim" ? 2 : 0, "the shim served exactly the shim's session");
	if (transport === "sse") {
		assert.equal(http.bodies.length, 2, `the ${through} session sent one request per turn`);
		return http;
	}
	assert.equal(http.bodies.length, 0, `the ${through} session stayed on its WebSocket`);
	assert.equal(socket.requests.length, 2, `the ${through} session sent one frame per turn`);
	return { headers: socket.handshakes, bodies: socket.requests };
}

/** The session without the per-session ids, which differ between two sessions. */
function withoutSessionIds({ headers, bodies }: CapturedSession): CapturedSession {
	return {
		headers: headers.map(({ "session-id": _session, "x-client-request-id": _request, ...rest }) => rest),
		bodies: bodies.map(({ prompt_cache_key: _cacheKey, ...fields }) => fields),
	};
}

type InputItem = { type?: string; role?: string; content?: unknown; tools?: Array<{ name?: string }>; reasoning?: { effort?: string } };

for (const transport of ["sse", "websocket"] as const) {
	test(`a Pi session on openai-codex ${MODEL_ID} over ${transport} sends Pi's requests through the shim`, async (t) => {
		const fixture = providerWorld(t);
		// Over WebSocket the shim keeps the session socket for five minutes after a turn; a mocked clock
		// drops that expiry timer with the case.
		t.mock.timers.enable({ apis: ["setTimeout"] });
		writeFileSync(join(fixture.agent, "auth.json"), JSON.stringify({ "openai-codex": { type: "oauth", access: codexJwt(), refresh: "refresh", expires: Date.now() + 3_600_000, accountId: "acct_test" } }));
		const pi = await sessionRequests(t, fixture, "pi", transport);
		const shim = await sessionRequests(t, fixture, "shim", transport);

		for (const { headers: [headers], bodies: [first, second] } of [pi, shim]) {
			const input = first!.input as InputItem[];
			assert.equal(first!.instructions, undefined, "no top-level instructions");
			const prompt = input.find((item) => item.content !== undefined);
			assert.equal(prompt?.role, "developer");
			assert.match(String(prompt?.content), /^Session prompt/);
			assert.equal(first!.tools, undefined, "no top-level tools");
			assert.ok(input.some((item) => item.type === "additional_tools" && item.tools?.some((tool) => tool.name === "bash")), JSON.stringify(input));
			assert.equal(typeof first!.max_output_tokens, "number");
			// Over WebSocket the session header is the handshake's own request id, not the cache key.
			if (transport === "sse") assert.equal(headers!["session-id"], first!.prompt_cache_key);
			else assert.ok(headers!["session-id"]);
			assert.equal(headers!.session_id, undefined);
			assert.match(headers!["user-agent"] ?? "", /^pi\/\d+\.\d+\.\d+ \(/);
			// The second turn carries the new level as the last configuration_update item.
			const updates = (second!.input as InputItem[]).filter((item) => item.type === "configuration_update");
			assert.equal(updates.at(-1)?.reasoning?.effort, "high", JSON.stringify(second!.input));
		}
		assert.deepEqual(withoutSessionIds(shim), withoutSessionIds(pi));
	});
}
