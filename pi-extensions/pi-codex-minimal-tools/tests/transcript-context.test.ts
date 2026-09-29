import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { zstdDecompressSync } from "node:zlib";
import { normalizeContext } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { buildRequestBody } from "../src/provider-shim.js";
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

	assert.equal(bodies.length, 1, "the shim sent one request");
	assert.match(String(bodies[0].instructions), /^Session prompt/);
	assert.ok(((bodies[0].tools ?? []) as { name?: string }[]).some((entry) => entry.name === "bash"), JSON.stringify(bodies[0].tools));
});
