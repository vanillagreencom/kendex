import { expect, spyOn, test } from "bun:test";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager, ToolExecutionComponent, initTheme, type AgentSession, type ExtensionFactory, type ToolRenderers } from "@earendil-works/pi-coding-agent";
import { ProcessTerminal, Text, TuiMainScreen } from "@earendil-works/pi-tui";
import { cpSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { Type } from "typebox";
import toolRenderer from "../tool-renderer.js";
import { CONFIG_ID } from "../tool-renderer/settings.js";
import { STACK_MAX_ITEMS } from "../tool-renderer/stack.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const builtins = ["read", "bash", "edit", "write", "grep", "find", "ls"];
type Call = { name: string; args: Record<string, unknown> };

async function startSession(options: { factories?: ExtensionFactory[]; calls?: Call[]; tools?: string[]; mutations?: boolean; ui?: boolean } = {}) {
	const { cwd, agent } = world();
	writeFileSync(join(cwd, "fixture.txt"), "first\nsecond\n");
	if (options.mutations) writeFileSync(join(agent, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { renderMutationTools: true } } } } }));
	let requests = 0;
	const model: ExtensionFactory = (pi) => {
		const core = createFauxCore({ api: "renderer-test", provider: "renderer-test", models: [{ id: "scripted", contextWindow: 200_000, maxTokens: 1000 }] });
		core.setResponses([
			...(options.calls ?? []).map((call) => () => { requests++; return fauxAssistantMessage([fauxToolCall(call.name, call.args)], { stopReason: "toolUse" }); }),
			() => { requests++; return fauxAssistantMessage([fauxText("done")]); },
		]);
		pi.registerProvider("renderer-test", { api: core.api as never, baseUrl: "http://renderer-test.invalid", apiKey: "unused", streamSimple: core.streamSimple as never,
			models: [{ id: "scripted", name: "scripted", reasoning: false, input: ["text"], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 200_000, maxTokens: 1000 }] });
	};
	const settingsManager = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
	const resourceLoader = new DefaultResourceLoader({ cwd, agentDir: agent, settingsManager, noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true, noContextFiles: true,
		extensionFactories: [model, ...(options.factories ?? [toolRenderer])] });
	await resourceLoader.reload();
	expect(resourceLoader.getExtensions().errors).toEqual([]);
	const { session } = await createAgentSession({ cwd, agentDir: agent, resourceLoader, settingsManager, sessionManager: SessionManager.inMemory(cwd), ...(options.tools ? { tools: options.tools } : {}) });
	if (options.ui) await session.bindExtensions({ uiContext: { ...session.extensionRunner.createContext().ui } });
	await session.setModel(session.modelRuntime.getModel("renderer-test", "scripted")!);
	return { session, requests: () => requests, loadErrors: () => resourceLoader.getExtensions().errors };
}

function expectImmediateBatch(session: AgentSession) {
	expect(session.getAllTools().map((tool) => tool.name)).toContain("tool_batch");
	expect(session.getActiveToolNames()).toContain("tool_batch");
}

test("embedded sessions have tools and guarded batch immediately without binding or prompting", async () => {
	const { session, requests } = await startSession({ calls: [{ name: "tool_batch", args: { calls: [{ tool: "read", args: { path: "fixture.txt" } }] } }] });
	try {
		expect(requests()).toBe(0);
		expectImmediateBatch(session);
		for (const name of builtins) expect(session.getAllTools().find((tool) => tool.name === name)?.sourceInfo.source).toBe("builtin");
		for (const name of ["grep", "find", "ls"]) expect(session.getActiveToolNames()).not.toContain(name);
		await session.prompt("run batch");
		const result = session.messages.find((message) => message.role === "toolResult" && message.toolName === "tool_batch");
		expect(result?.role === "toolResult" && result.isError).toBe(false);
		expect(JSON.stringify(result)).toContain("first\\nsecond");
	} finally { session.dispose(); }
});

test("immediate-readiness control rejects session_start-only registration", async () => {
	// Plant the old delayed lifetime while exercising the real extension factory.
	const delayed: ExtensionFactory = (pi) => { pi.on("session_start", () => toolRenderer(pi)); };
	const { session, requests } = await startSession({ factories: [delayed] });
	try {
		expect(requests()).toBe(0);
		expect(() => expectImmediateBatch(session)).toThrow();
	} finally { session.dispose(); }
});

for (const order of ["renderer-first", "peer-first"] as const) {
	test(`peer read and grep execution stays with its owner: ${order}`, async () => {
		const executed: string[] = [];
		const peer: ExtensionFactory = (pi) => {
			for (const name of ["read", "grep"]) pi.registerTool({ name, label: name, description: "peer fixture", parameters: Type.Object({}),
				async execute() { executed.push(name); return { content: [{ type: "text", text: `peer-${name}` }], details: { owner: name } }; } });
		};
		const { session, loadErrors } = await startSession({ factories: order === "renderer-first" ? [toolRenderer, peer] : [peer, toolRenderer], calls: [{ name: "read", args: {} }, { name: "grep", args: {} }] });
		try {
			expectImmediateBatch(session);
			await session.prompt("run peer tools");
			expect(executed).toEqual(["read", "grep"]);
			expect(loadErrors()).toEqual([]);
			for (const name of ["read", "grep"]) {
				const result = session.messages.find((message) => message.role === "toolResult" && message.toolName === name);
				expect(result?.role === "toolResult" && result.details).toEqual({ owner: name });
			}
		} finally { session.dispose(); }
	});
}

test("native components invoke compact callbacks without replacing built-in tool definitions", async () => {
	const { session } = await startSession();
	try {
		initTheme("dark");
		const renderers = session.extensionRunner.resolveToolRenderers("read", () => session.getToolDefinition("read"))!;
		expect(renderers.renderShell).toBe("self");
		const call = spyOn(renderers, "renderCall");
		const result = spyOn(renderers, "renderResult");
		const ui = new TuiMainScreen(new ProcessTerminal());
		const component = new ToolExecutionComponent("read", "native-read", { path: "fixture.txt" }, { showImages: false }, renderers, ui, world().cwd);
		component.markExecutionStarted();
		component.setArgsComplete();
		component.updateResult({ content: [{ type: "text", text: "first\nsecond\n" }], isError: false });
		expect(component.render(100).join("\n")).toContain("fixture.txt");
		expect(call).toHaveBeenCalled();
		expect(result).toHaveBeenCalled();
		call.mockRestore(); result.mockRestore();
	} finally { session.dispose(); }
});

for (const order of ["renderer-first", "peer-first"] as const) {
	test(`unrelated names yield and competing drawing follows native order: ${order}`, async () => {
		const peerDrawing: ToolRenderers = { renderCall: () => new Text("peer") };
		const peer: ExtensionFactory = (pi) => { pi.registerToolRenderer((_name, _next) => peerDrawing); };
		const { session } = await startSession({ factories: order === "renderer-first" ? [toolRenderer, peer] : [peer, toolRenderer] });
		try {
			const resolve = (name: string) => session.extensionRunner.resolveToolRenderers(name, () => session.getToolDefinition(name));
			expect(resolve("unrelated-fixture-tool")).toBe(peerDrawing);
			if (order === "peer-first") expect(resolve("read")).toBe(peerDrawing);
			else expect(resolve("read")?.renderShell).toBe("self");
		} finally { session.dispose(); }
	});
}

test("explicit allowlist stays authoritative through bind and reload", async () => {
	const { session } = await startSession({ tools: ["read", "tool_batch"] });
	try {
		for (const transition of [async () => {}, () => session.bindExtensions({}), () => session.reload()]) {
			await transition();
			expect(session.getAllTools().map((tool) => tool.name).sort()).toEqual(["read", "tool_batch"]);
			expect(session.getActiveToolNames().sort()).toEqual(["read", "tool_batch"]);
		}
	} finally { session.dispose(); }
});

test("dynamic built-in selections survive reload and batch retains native defaultActive semantics", async () => {
	const { session } = await startSession();
	try {
		session.setActiveToolsByName(["read", "grep", "bash"]);
		session.setActiveToolsByName(["bash"]);
		await session.bindExtensions({});
		expect(session.getActiveToolNames()).toEqual(["bash"]);
		await session.reload();
		expect(session.getActiveToolNames()).not.toContain("read");
		expect(session.getActiveToolNames()).not.toContain("grep");
		expect(session.getActiveToolNames()).toContain("tool_batch");
	} finally { session.dispose(); }
});

test("native mutation drawing preserves Pi's edit argument preparation and prompt guidance", async () => {
	const { session } = await startSession({ mutations: true, calls: [{ name: "edit", args: { path: "fixture.txt", oldText: "first", newText: "updated" } }] });
	try {
		for (const name of builtins) expect(session.getAllTools().find((tool) => tool.name === name)?.sourceInfo.source).toBe("builtin");
		for (const name of ["read", "bash", "edit", "write"]) expect(session.getToolDefinition(name)?.promptSnippet).toBeDefined();
		await session.prompt("edit file");
		expect(readFileSync(join(world().cwd, "fixture.txt"), "utf8")).toBe("updated\nsecond\n");
		for (const name of ["edit", "write"]) expect(session.extensionRunner.resolveToolRenderers(name, () => session.getToolDefinition(name))?.renderShell).toBe("self");
	} finally { session.dispose(); }
});

function writeCall(toolCallId: string, input: { path: string; content: string }) {
	return { type: "tool_call" as const, toolName: "write" as const, toolCallId, input };
}

function finishWrite(session: AgentSession, toolCallId: string, input: { path: string; content: string }, isError = false) {
	return session.extensionRunner.emitToolResult({ type: "tool_result", toolName: "write", toolCallId, input, content: [], details: undefined, isError });
}

test("native write diffs capture old bytes before execution", async () => {
	const { session } = await startSession({ mutations: true, ui: true, calls: [{ name: "write", args: { path: "fixture.txt", content: "replacement\n" } }] });
	try {
		await session.prompt("write fixture");
		const result = session.messages.find((message) => message.role === "toolResult" && message.toolName === "write");
		expect(result).toMatchObject({ isError: false, details: { kendexDiff: { path: "fixture.txt", additions: 1, removals: 2 } } });
		expect(JSON.stringify(result)).toContain("second");
		expect(readFileSync(join(world().cwd, "fixture.txt"), "utf8")).toBe("replacement\n");
	} finally { session.dispose(); }
});

test("peer write keeps non-record details and structured output", async () => {
	let observed: unknown;
	const peer: ExtensionFactory = (pi) => {
		pi.registerTool({ name: "write", label: "write", description: "peer write", parameters: Type.Object({ path: Type.String(), content: Type.String() }),
			async execute() { return { content: [{ type: "text", text: "peer-result" }], details: "peer-details", structuredContent: { owner: "peer" } }; } });
		pi.on("tool_result", (event) => { observed = { details: event.details, structuredContent: event.structuredContent, content: event.content }; });
	};
	const { session } = await startSession({ mutations: true, ui: true, factories: [toolRenderer, peer], calls: [{ name: "write", args: { path: "fixture.txt", content: "unused\n" } }] });
	try {
		await session.prompt("run peer write");
		expect(observed).toEqual({ details: "peer-details", structuredContent: { owner: "peer" }, content: [{ type: "text", text: "peer-result" }] });
		expect(readFileSync(join(world().cwd, "fixture.txt"), "utf8")).toBe("first\nsecond\n");
	} finally { session.dispose(); }
});

test("write snapshot control rejects guessed old contents in only the write-diff row", () => {
	const copy = join(world().root, "control");
	const original = join(import.meta.dir, "../..");
	cpSync(original, copy, { recursive: true, filter: (path) => !path.includes("node_modules") });
	symlinkSync(join(original, "node_modules"), join(copy, "node_modules"), "dir");
	const path = join(copy, "extensions/tool-renderer/tools.ts");
	const source = readFileSync(path, "utf8");
	const retained = "if (pending.get(event.toolCallId) === record) record.snapshot = snapshot;";
	expect(source.split(retained)).toHaveLength(2);
	const mutant = source.replace(retained, `${retained}\n\t\tif (pending.get(event.toolCallId) === record) record.snapshot = { kind: "absent" };`);
	expect(mutant).not.toBe(source);
	writeFileSync(path, mutant);
	// Transparent child inherits the environment and pinned peers; no automatic package installation.
	const child = spawnSync(process.execPath, ["--no-install", "test", "./extensions/__tests__/tool-registration.test.ts", "--test-name-pattern", "^native write diffs capture old bytes before execution$"], { cwd: copy, encoding: "utf8", timeout: 30_000 });
	expect(child.error).toBeUndefined();
	expect(child.status).toBe(1);
	// This control consumes Bun's per-case verdict, not arbitrary nonzero output.
	expect(child.stderr).toContain("(fail) native write diffs capture old bytes before execution");
	expect(child.stderr).not.toContain("# Unhandled error");
});

test("overlapping write snapshots keep call identity and release on completion", async () => {
	const { session } = await startSession({ mutations: true, ui: true });
	try {
		writeFileSync(join(world().cwd, "left.txt"), "left-old\n");
		writeFileSync(join(world().cwd, "right.txt"), "right-old-1\nright-old-2\n");
		const left = { path: "left.txt", content: "left-new\n" };
		const right = { path: "right.txt", content: "right-new\n" };
		await Promise.all([session.extensionRunner.emitToolCall(writeCall("left", left)), session.extensionRunner.emitToolCall(writeCall("right", right))]);
		const rightResult = await finishWrite(session, "right", right);
		const leftResult = await finishWrite(session, "left", left);
		expect(rightResult).toMatchObject({ details: { kendexDiff: { path: "right.txt", removals: 2 } } });
		expect(leftResult).toMatchObject({ details: { kendexDiff: { path: "left.txt", removals: 1 } } });
		expect(JSON.stringify(rightResult)).toContain("right-old-2");
		expect(JSON.stringify(leftResult)).toContain("left-old");
		expect(await finishWrite(session, "right", right)).toBeUndefined();
		expect(await finishWrite(session, "left", left)).toBeUndefined();
	} finally { session.dispose(); }
});

test("write failures and execution-end refusals release snapshots", async () => {
	const { session } = await startSession({ mutations: true, ui: true });
	try {
		const input = { path: "fixture.txt", content: "new\n" };
		await session.extensionRunner.emitToolCall(writeCall("failed", input));
		expect(await finishWrite(session, "failed", input, true)).toBeUndefined();
		expect(await finishWrite(session, "failed", input)).toBeUndefined();
		await session.extensionRunner.emitToolCall(writeCall("blocked", input));
		await session.extensionRunner.emit({ type: "tool_execution_end", toolName: "write", toolCallId: "blocked", result: {}, isError: true });
		expect(await finishWrite(session, "blocked", input)).toBeUndefined();
		await session.extensionRunner.emitToolCall(writeCall("retargeted", input));
		const retargeted = { ...input, path: "another.txt" };
		expect(await finishWrite(session, "retargeted", retargeted)).toBeUndefined();
	} finally { session.dispose(); }
});

for (const reset of ["agent_end", "session_start", "session_shutdown"] as const) {
	test(`write snapshots release on ${reset}, including reads still in flight`, async () => {
		const { session } = await startSession({ mutations: true, ui: true });
		try {
			const input = { path: "fixture.txt", content: "new\n" };
			const reading = session.extensionRunner.emitToolCall(writeCall("reset", input));
			if (reset === "agent_end") await session.extensionRunner.emit({ type: "agent_end", messages: [] });
			else if (reset === "session_start") await session.extensionRunner.emit({ type: "session_start", reason: "reload" });
			else await session.extensionRunner.emit({ type: "session_shutdown", reason: "reload" });
			await reading;
			expect(await finishWrite(session, "reset", input)).toBeUndefined();
		} finally { session.dispose(); }
	});
}

test("write snapshots stay within the display bound and headless sessions retain none", async () => {
	const input = { path: "fixture.txt", content: "new\n" };
	const headless = await startSession({ mutations: true });
	try {
		await headless.session.extensionRunner.emitToolCall(writeCall("headless", input));
		expect(await finishWrite(headless.session, "headless", input)).toBeUndefined();
	} finally { headless.session.dispose(); }
	const { session } = await startSession({ mutations: true, ui: true });
	try {
		await Promise.all(Array.from({ length: STACK_MAX_ITEMS }, (_, index) => session.extensionRunner.emitToolCall(writeCall(`held-${index}`, input))));
		await session.extensionRunner.emitToolCall(writeCall("past-bound", input));
		expect(await finishWrite(session, "past-bound", input)).toBeUndefined();
		expect(await finishWrite(session, "held-0", input)).toHaveProperty("details.kendexDiff");
		await session.extensionRunner.emitToolCall(writeCall("room-after-result", input));
		expect(await finishWrite(session, "room-after-result", input)).toHaveProperty("details.kendexDiff");
	} finally { session.dispose(); }
});
