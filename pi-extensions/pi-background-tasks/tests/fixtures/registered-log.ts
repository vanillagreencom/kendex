import { mock } from "bun:test";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { RegistrationDeps } from "../../extensions/registrations.js";
import type { BackgroundTaskSnapshot } from "../../extensions/types.js";
import { fakeTask } from "./lifecycle.js";

// Peer mocks stay in this child. Production result, snapshot, and log functions run unchanged.
const unused = () => { throw new Error("registered log fixture reached an unrelated operation"); };
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: readonly string[]) => ({ enum: values }) }));
mock.module("typebox", () => ({ Type: { Object: (value: unknown) => value, Optional: (value: unknown) => value, Number: () => ({}), String: () => ({}), Boolean: () => ({}) } }));
mock.module("@earendil-works/pi-tui", () => ({ matchesKey: unused, truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused }));
const { registerAll } = await import("../../extensions/registrations.js");
const { taskSnapshot } = await import("../../extensions/snapshot.js");

interface InputRow { tool: string; output: string; task: Partial<BackgroundTaskSnapshot> }
interface Tool {
	name: string;
	execute(id: string, params: { action: "log"; id?: string; pid?: number }): Promise<unknown>;
}
const rows: InputRow[] = JSON.parse(await Bun.stdin.text());
const results = [];
for (const row of rows) {
	const task = fakeTask(row.task);
	const calls: unknown[] = [];
	const tools = new Map<string, Tool>();
	const pi = {
		registerTool(tool: Tool) { tools.set(tool.name, tool); },
		registerCommand() {}, registerShortcut() {},
	} as unknown as ExtensionAPI;
	const deps: RegistrationDeps = {
		getActiveCtx: () => ({ cwd: process.cwd() }) as ExtensionContext,
		setActiveCtx: unused,
		rememberSnapshot(value) { calls.push({ rememberSameTask: value === task }); return taskSnapshot(value); },
		sortedTasks: unused, formatTaskListText: unused,
		getTaskOutput(value) { calls.push({ outputSameTask: value === task }); return row.output; },
		resolveTask(id, pid) { calls.push({ id: id ?? null, pid: pid ?? null }); return task; },
		requestStop: unused, spawnTask: unused, clearFinishedTasks: unused,
		armForcedBackground: unused, toggleWidget: unused,
		dashboardDeps: { sortedTasks: unused, getTask: unused, getTaskOutput: unused, requestStop: unused, clearFinishedTasks: unused, formatTaskListText: unused },
		dashboardShortcut: "none", backgroundBashShortcut: "none", widgetToggleShortcut: "none",
	};
	registerAll(pi, deps);
	const tool = tools.get(row.tool);
	if (!tool) throw new Error(`Missing registered tool: ${row.tool}`);
	const result = await tool.execute("log-call", row.tool === "bg_task" ? { action: "log", id: task.id } : { action: "log", pid: task.pid });
	results.push({ result, calls });
}
process.stdout.write(JSON.stringify(results));
