import { expect, mock, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

mock.module("@earendil-works/pi-ai", () => ({
	StringEnum: (values: readonly string[], options: Record<string, unknown> = {}) => ({ ...options, enum: values }),
}));

mock.module("@earendil-works/pi-tui", () => ({
	matchesKey: () => false,
	truncateToWidth: (text: string) => text,
	visibleWidth: (text: string) => text.length,
	wrapTextWithAnsi: (text: string) => text.split(/\r?\n/),
}));

mock.module("typebox", () => ({
	Type: {
		Array: (item: unknown) => ({ item, type: "array" }),
		Boolean: (options: Record<string, unknown> = {}) => ({ ...options, type: "boolean" }),
		Number: (options: Record<string, unknown> = {}) => ({ ...options, type: "number" }),
		Object: (properties: Record<string, unknown>) => ({ properties, type: "object" }),
		Optional: (value: unknown) => ({ optional: true, value }),
		String: (options: Record<string, unknown> = {}) => ({ ...options, type: "string" }),
	},
}));

function fakePi() {
	const tools = new Map<string, any>();
	return {
		appended: [] as any[],
		commands: new Map<string, any>(),
		renderers: new Map<string, any>(),
		shortcuts: new Map<string, any>(),
		tools,
		appendEntry(customType: string, data: unknown) { this.appended.push({ customType, data }); },
		on() {},
		registerCommand(name: string, command: any) { this.commands.set(name, command); },
		registerMessageRenderer(name: string, renderer: any) { this.renderers.set(name, renderer); },
		registerShortcut(name: string, shortcut: any) { this.shortcuts.set(name, shortcut); },
		registerTool(tool: any) { tools.set(tool.name, tool); },
	};
}

function failingSidecarEnv(): { base: string; previousPiDir: string | undefined } {
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	const base = mkdtempSync(join(tmpdir(), "pi-task-panel-sidecar-fail-"));
	const fileNotDirectory = join(base, "not-a-directory");
	writeFileSync(fileNotDirectory, "x", "utf8");
	process.env.PI_CODING_AGENT_DIR = fileNotDirectory;
	return { base, previousPiDir };
}

function restorePiDir(previousPiDir: string | undefined): void {
	if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = previousPiDir;
}

function fakeCtx(base: string, notifications: Array<{ message: string; level: string }>) {
	return {
		cwd: base,
		hasUI: false,
		sessionManager: {
			getBranch: () => [],
			getSessionFile: () => join(base, "session.jsonl"),
			getSessionId: () => "sidecar-failure-test",
		},
		ui: {
			notify: (message: string, level: string) => notifications.push({ message, level }),
			setWidget: () => {},
		},
	};
}

test("tasks_write keeps full details.state and warns when oversized sidecar write fails", async () => {
	const { base, previousPiDir } = failingSidecarEnv();

	try {
		const [{ default: taskPanel }, { isTaskPanelToolResultBoundedState }] = await Promise.all([
			import("../extensions/task-panel.js"),
			import("../extensions/tool-result-details.js"),
		]);
		const pi = fakePi();
		taskPanel(pi as any);
		const tasksWrite = pi.tools.get("tasks_write");
		expect(tasksWrite).toBeDefined();

		const notifications: Array<{ message: string; level: string }> = [];
		const ctx = fakeCtx(base, notifications);
		const tasks = Array.from({ length: 200 }, (_value, index) => ({ content: `${"x".repeat(400)} task ${index}` }));
		const result = await tasksWrite.execute("tool-call-1", { action: "replace", tasks }, undefined, undefined, ctx);
		const detailsState = result.details.state;

		expect(isTaskPanelToolResultBoundedState(detailsState)).toBe(false);
		expect(detailsState.tasks).toHaveLength(200);
		expect(notifications.some((note) => note.level === "warning" && note.message.includes("sidecar-write"))).toBe(true);
		expect(notifications.some((note) => note.message.includes("tool-result"))).toBe(false);
	} finally {
		restorePiDir(previousPiDir);
	}
});

test("non-tool task mutations keep full session-entry fallback when oversized sidecar write fails", async () => {
	const { base, previousPiDir } = failingSidecarEnv();

	try {
		const [{ default: taskPanel }, { isTaskPanelToolResultBoundedState }] = await Promise.all([
			import("../extensions/task-panel.js"),
			import("../extensions/tool-result-details.js"),
		]);
		const pi = fakePi();
		taskPanel(pi as any);
		const tasksImport = pi.commands.get("tasks:import");
		expect(tasksImport).toBeDefined();

		const notifications: Array<{ message: string; level: string }> = [];
		const ctx = fakeCtx(base, notifications);
		const importPath = join(base, "tasks.md");
		writeFileSync(importPath, Array.from({ length: 200 }, (_value, index) => `- ${"x".repeat(400)} task ${index}`).join("\n"), "utf8");

		await tasksImport.handler(importPath, ctx);

		const stateEntries = pi.appended.map((entry: any) => entry.data).filter((data: any) => data?.version === 1 || data?.fullSnapshot === false);
		expect(stateEntries).toHaveLength(1);
		expect(isTaskPanelToolResultBoundedState(stateEntries[0])).toBe(false);
		expect(stateEntries[0].tasks).toHaveLength(200);
		expect(notifications.some((note) => note.level === "warning" && note.message.includes("sidecar-write"))).toBe(true);
		expect(notifications.some((note) => note.message.includes("tool-result"))).toBe(false);
	} finally {
		restorePiDir(previousPiDir);
	}
});
