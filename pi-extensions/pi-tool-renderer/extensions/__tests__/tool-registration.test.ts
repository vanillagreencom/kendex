import { expect, test } from "bun:test";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const renderer = join(import.meta.dir, "../..");
const owned = ["read", "grep"];
const replaced = ["bash", "find", "ls", "tool_batch"];

/** An extension loaded before the renderer that owns read and grep from load, as pi-hashline-edit-pro does. */
const ownerSource = `export default function (pi) {
	for (const name of ${JSON.stringify(owned)}) pi.registerTool({
		name, label: name, description: "owner " + name, parameters: { type: "object", properties: {} },
		execute: async () => ({ content: [], details: undefined }),
		renderCall: () => ({ owner: name, part: "call" }),
		renderResult: () => ({ owner: name, part: "result" }),
	});
}
`;

async function startSession() {
	const { cwd, agent, root } = world();
	const owner = join(root, "owner.ts");
	writeFileSync(owner, ownerSource);
	const resourceLoader = new DefaultResourceLoader({
		cwd, agentDir: agent, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
		additionalExtensionPaths: [owner, renderer],
	});
	await resourceLoader.reload();
	const handlerErrors: unknown[] = [];
	const { session } = await createAgentSession({
		cwd, agentDir: agent, resourceLoader, sessionManager: SessionManager.inMemory(cwd),
		settingsManager: SettingsManager.inMemory({ compaction: { enabled: false } }),
	});
	await session.bindExtensions({ onError: (error) => handlerErrors.push(error) });
	return { session, loadErrors: () => resourceLoader.getExtensions().errors, handlerErrors };
}

function expectOwnership(session: Awaited<ReturnType<typeof startSession>>["session"]) {
	const tools = new Map(session.getAllTools().map((tool) => [tool.name, tool]));
	for (const name of owned) {
		const definition = session.getToolDefinition(name) as any;
		expect(definition?.description).toBe(`owner ${name}`);
		expect(definition?.renderCall?.({}, {}, {})).toEqual({ owner: name, part: "call" });
		expect(definition?.renderResult?.({}, {}, {}, {})).toEqual({ owner: name, part: "result" });
	}
	for (const name of replaced) expect(tools.get(name)?.sourceInfo.path).toEndWith(join("extensions", "tool-renderer.ts"));
	expect(session.getActiveToolNames()).toEqual(expect.arrayContaining([...owned, ...replaced]));
}

test("at session_start the renderer leaves a tool another extension registered to it and registers the free ones", async () => {
	const { session, loadErrors, handlerErrors } = await startSession();
	try {
		expect(loadErrors()).toEqual([]);
		expect(handlerErrors).toEqual([]);
		expectOwnership(session);
	} finally {
		session.dispose();
	}
});

test("a second session_start registers nothing twice, and a reload registers every tool again", async () => {
	const { session, loadErrors, handlerErrors } = await startSession();
	try {
		const names = [...owned, ...replaced];
		const before = names.map((name) => session.getToolDefinition(name));
		const active = session.getActiveToolNames();
		await session.extensionRunner.emit({ type: "session_start", reason: "startup" });
		names.forEach((name, index) => expect(session.getToolDefinition(name)).toBe(before[index]));
		expect(session.getActiveToolNames()).toEqual(active);
		await session.reload();
		expect(loadErrors()).toEqual([]);
		expect(handlerErrors).toEqual([]);
		expectOwnership(session);
	} finally {
		session.dispose();
	}
});
