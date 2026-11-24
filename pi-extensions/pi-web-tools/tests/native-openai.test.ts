import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { rewriteNativeOpenAiWebSearch } from "../src/native-openai.js";
import { clearPackageConfigCache } from "../src/package-config.js";
import { isolateEnvironment, settingsEnvironment, tempDir } from "./fixtures.js";

const NATIVE = { type: "web_search", external_web_access: false };
const searchFunction = { type: "function", name: "web_search", parameters: {} };
const readFunction = { type: "function", name: "read", parameters: {} };
const tools = (...entries: unknown[]) => ({ type: "additional_tools", role: "developer", tools: entries });
const userText = { role: "user", content: [{ type: "input_text", text: "hello" }] };

for (const row of [
	{
		name: "web_search in top-level tools",
		payload: { tools: [searchFunction, readFunction], input: [userText] },
		expected: { tools: [NATIVE, readFunction], input: [userText] },
		rewritten: ["web_search"],
	},
	{
		name: "web_search in the leading additional_tools item",
		payload: { input: [tools(searchFunction, readFunction), userText] },
		expected: { input: [tools(NATIVE, readFunction), userText] },
		rewritten: ["web_search"],
	},
	{
		name: "web_search in a later additional_tools item, for a tool change",
		payload: { input: [tools(readFunction), userText, { role: "developer", content: "update" }, tools(searchFunction)] },
		expected: { input: [tools(readFunction), userText, { role: "developer", content: "update" }, tools(NATIVE)] },
		rewritten: ["web_search"],
	},
	{
		name: "a request with no web_search",
		payload: { tools: [readFunction], input: [tools(readFunction), userText] },
		expected: { tools: [readFunction], input: [tools(readFunction), userText] },
		rewritten: [],
	},
]) {
	test(`the native rewrite of ${row.name} replaces only web_search`, () => {
		const result = rewriteNativeOpenAiWebSearch(row.payload, { externalWebAccess: false });
		assert.deepEqual(result.payload, row.expected);
		assert.deepEqual(result.rewritten, row.rewritten);
	});
}

type Body = { tools?: Record<string, unknown>[]; input?: Record<string, unknown>[] };

/** Every web_search declaration in a Responses request, with where it sits. */
function webSearchDeclarations(body: Body): { at: string; tool: Record<string, unknown> }[] {
	const found = (body.tools ?? []).map((tool) => ({ at: "tools", tool }));
	for (const item of body.input ?? []) {
		if (item.type === "additional_tools") found.push(...(item.tools as Record<string, unknown>[]).map((tool) => ({ at: "additional_tools", tool })));
	}
	return found.filter(({ tool }) => tool.name === "web_search" || tool.type === "web_search");
}

const completed = { type: "response.completed", response: { id: "resp_ok", status: "completed", output: [], usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0 } } } };

/* A real Pi session on Pi's own openai provider, with pi-web-tools set to
 * OpenAI's native search. The request is read where it leaves Pi, after every
 * before_provider_request handler. gpt-4.1 has no additional_tools support,
 * so Pi declares its tools at the top level; gpt-6.2-sol has it and gets every
 * tool in additional_tools input items. */
for (const row of [
	{ model: "gpt-4.1", at: "tools" },
	{ model: "gpt-6.2-sol", at: "additional_tools" },
]) {
	test(`a Pi session on openai ${row.model} sends web_search as the native tool in ${row.at}`, async (t) => {
		isolateEnvironment(t, settingsEnvironment);
		const root = tempDir(t);
		const agent = join(root, "agent");
		const cwd = join(root, "project");
		mkdirSync(agent, { recursive: true });
		mkdirSync(cwd, { recursive: true });
		writeFileSync(join(agent, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": { defaultProvider: "openai-native", openAiExternalWebAccess: false } } } } }));
		process.env.PI_CODING_AGENT_DIR = agent;
		process.env.OPENAI_API_KEY = "test-key";
		clearPackageConfigCache();

		const fetch = globalThis.fetch;
		t.after(() => { globalThis.fetch = fetch; });
		const bodies: Body[] = [];
		globalThis.fetch = (async (_url: RequestInfo | URL, init?: RequestInit) => {
			bodies.push(JSON.parse(String(init?.body)));
			return new Response(`data: ${JSON.stringify(completed)}\n\n`, { status: 200, headers: { "content-type": "text/event-stream" } });
		}) as typeof fetch;

		const resourceLoader = new DefaultResourceLoader({
			cwd,
			agentDir: agent,
			noExtensions: true,
			noSkills: true,
			noPromptTemplates: true,
			noThemes: true,
			noContextFiles: true,
			additionalExtensionPaths: [join(import.meta.dirname, "..", "src", "index.ts")],
		});
		await resourceLoader.reload();
		assert.deepEqual(resourceLoader.getExtensions().errors, []);
		const { session } = await createAgentSession({
			cwd,
			agentDir: agent,
			resourceLoader,
			sessionManager: SessionManager.inMemory(cwd),
			settingsManager: SettingsManager.inMemory({ compaction: { enabled: false } }),
			noTools: "builtin",
		});
		t.after(() => session.dispose());
		await session.bindExtensions({});
		const model = session.modelRuntime.getModel("openai", row.model);
		assert.ok(model, `Pi's catalog carries no openai ${row.model}`);
		await session.setModel(model);
		await session.prompt("hello");

		assert.equal(bodies.length, 1, "the session sent one request");
		assert.deepEqual(webSearchDeclarations(bodies[0]), [{ at: row.at, tool: NATIVE }]);
	});
}
