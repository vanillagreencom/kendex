import { expect, mock, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
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

for (const entry of ["tool", "command"] as const) {
	test(`${entry} keeps full state when oversized sidecar persistence fails`, async () => {
		const previousPiDir = process.env.PI_CODING_AGENT_DIR;
		const previousDiagnosticLog = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
		const base = mkdtempSync(join(tmpdir(), "pi-task-panel-sidecar-fail-"));
		try {
			const fileNotDirectory = join(base, "not-a-directory");
			writeFileSync(fileNotDirectory, "x", "utf8");
			process.env.PI_CODING_AGENT_DIR = fileNotDirectory;
			process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = join(base, "diagnostics.log");
			const [{ default: taskPanel }, { isTaskPanelToolResultBoundedState }] = await Promise.all([
				import("../extensions/task-panel.js"), import("../extensions/tool-result-details.js"),
			]);
			const pi = fakePi();
			taskPanel(pi as never);
			const notifications: Array<{ message: string; level: string }> = [];
			const ctx = fakeCtx(base, notifications);
			let detailsState;
			if (entry === "tool") {
				const tasksWrite = pi.tools.get("tasks_write");
				expect(tasksWrite).toBeDefined();
				const tasks = Array.from({ length: 200 }, (_value, index) => ({ content: `${"x".repeat(400)} task ${index}` }));
				const result = await tasksWrite.execute("tool-call-1", { action: "replace", tasks }, undefined, undefined, ctx);
				detailsState = result.details.state;
			} else {
				const tasksImport = pi.commands.get("tasks:import");
				expect(tasksImport).toBeDefined();
				const importPath = join(base, "tasks.md");
				writeFileSync(importPath, Array.from({ length: 200 }, (_value, index) => `- ${"x".repeat(400)} task ${index}`).join("\n"), "utf8");
				await tasksImport.handler(importPath, ctx);
				const stateEntries = pi.appended.map((entry) => entry.data).filter((data) => data?.version === 1 || data?.fullSnapshot === false);
				expect(stateEntries).toHaveLength(1);
				detailsState = stateEntries[0];
			}
			expect(isTaskPanelToolResultBoundedState(detailsState)).toBe(false);
			expect(detailsState.tasks).toHaveLength(200);
			expect(notifications.filter((note) => note.level === "warning").map((note) => note.message.split("\n")[0])).toEqual(["persistence_failure=sidecar-write"]);
			expect(notifications.some((note) => note.message.split("\n")[0] === "persistence_failure=tool-result")).toBe(false);
		} finally {
			if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previousPiDir;
			if (previousDiagnosticLog === undefined) delete process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
			else process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = previousDiagnosticLog;
			rmSync(base, { recursive: true, force: true });
		}
	});
}
