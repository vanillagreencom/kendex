import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { zstdDecompressSync } from "node:zlib";
import * as piAi from "@earendil-works/pi-ai";
import { normalizeContext } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { buildRequestBody, registerOpenAICodexCustomProvider, type TranscriptReplayHost } from "../src/provider-shim.js";
import { providerWorld, successSseResponse } from "./helpers/provider.js";
import { model } from "./helpers/responses.js";

/* Since Pi 0.86 a provider receives a normalized transcript: the system
 * prompt and the tool declarations sit in `system` messages, and the
 * `systemPrompt` and `tools` fields are gone. A shim that reads those fields
 * sends every request with no instructions and no tools. */

const tool = (name: string) => ({ name, description: `${name} tool`, parameters: { type: "object", properties: {} } });

test("the request carries the prompt and the tools a normalized transcript replays", () => {
	const context = normalizeContext({
		systemPrompt: "Base prompt",
		tools: [tool("first"), tool("second")],
		messages: [
			{ role: "user", content: "one", timestamp: 1 },
			{ role: "system", content: "Later instruction", toolsAdded: [tool("third")], toolsRemoved: [{ name: "first" }], timestamp: 2 },
			{ role: "user", content: "two", timestamp: 3 },
		],
	} as never);
	const body = buildRequestBody(model, context);
	assert.equal(body.instructions, "Base prompt\n\nLater instruction");
	assert.deepEqual((body.tools ?? []).map((entry) => (entry as { name: string }).name), ["second", "third"]);
	assert.deepEqual(body.input.map((item) => (item as { role?: string }).role), ["user", "user"], "no system message reaches the input");
});

function codexJwt(): string {
	const payload = Buffer.from(JSON.stringify({ "https://api.openai.com/auth": { chatgpt_account_id: "acct_test" } })).toString("base64");
	return `header.${payload}.signature`;
}

test("a real Pi session sends its system prompt and tools through the shim", async (t) => {
	const fixture = providerWorld(t);
	writeFileSync(join(fixture.agent, "auth.json"), JSON.stringify({ "openai-codex": { type: "oauth", access: codexJwt(), refresh: "refresh", expires: Date.now() + 3_600_000, accountId: "acct_test" } }));
	const bodies: Record<string, unknown>[] = [];
	globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
		const raw = init?.body instanceof Uint8Array ? zstdDecompressSync(init.body).toString("utf8") : String(init?.body);
		bodies.push(JSON.parse(raw));
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
		additionalExtensionPaths: [join(import.meta.dirname, "..", "src", "index.ts")],
	});
	await resourceLoader.reload();
	const loaded = resourceLoader.getExtensions();
	assert.deepEqual(loaded.errors, []);
	// Pi's built-in openai-codex provider sends the same prompt and tools, so
	// the request alone cannot show the shim served it: count its calls.
	const registration = loaded.runtime.pendingProviderRegistrations.find((entry) => entry.name === "openai-codex");
	const shimStream = registration?.config.streamSimple;
	assert.ok(registration && shimStream, "the package registered no openai-codex provider");
	let shimCalls = 0;
	registration.config.streamSimple = (...args) => {
		shimCalls++;
		return shimStream(...args);
	};
	const { session } = await createAgentSession({
		cwd: fixture.cwd,
		agentDir: fixture.agent,
		resourceLoader,
		sessionManager: SessionManager.inMemory(fixture.cwd),
		settingsManager: SettingsManager.inMemory({ compaction: { enabled: false } }),
		tools: ["bash"],
	});
	t.after(() => session.dispose());
	await session.bindExtensions({});
	const codex = session.modelRuntime.getModel("openai-codex", model.id);
	assert.ok(codex, `Pi's catalog carries no openai-codex ${model.id}`);
	await session.setModel(codex);
	await session.prompt("hello");

	assert.equal(shimCalls, 1, "the shim served the request");
	assert.equal(bodies.length, 1, "the shim sent one request");
	assert.match(String(bodies[0].instructions), /^Session prompt/);
	assert.ok(((bodies[0].tools ?? []) as { name?: string }[]).some((entry) => entry.name === "bash"), JSON.stringify(bodies[0].tools));
});

const { getCurrentSystemPrompt, getCurrentTools } = piAi;
for (const row of [
	{ name: "a Pi 0.86 host", root: { getCurrentSystemPrompt, getCurrentTools }, registered: ["openai-codex"], reason: undefined },
	{ name: "a host below Pi 0.86", root: {}, registered: [], reason: "native_provider_shim=unregistered missing=getCurrentSystemPrompt,getCurrentTools" },
	{ name: "a host with only the prompt helper", root: { getCurrentSystemPrompt }, registered: [], reason: "native_provider_shim=unregistered missing=getCurrentTools" },
] satisfies { name: string; root: TranscriptReplayHost; registered: string[]; reason: string | undefined }[]) {
	test(`the Codex override registers only where Pi replays the transcript: ${row.name}`, () => {
		const registered: string[] = [];
		const pi = { registerProvider: (name: string) => registered.push(name), on() {}, registerMessageRenderer() {} };
		const result = registerOpenAICodexCustomProvider(pi as never, { getCurrentCwd: () => "/", root: row.root });
		assert.deepEqual(registered, row.registered);
		assert.equal(result.kind === "unsupported" ? result.reason.split("\n")[0] : undefined, row.reason);
	});
}
