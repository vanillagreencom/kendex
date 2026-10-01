import assert from "node:assert/strict";
import { after, test } from "node:test";
import { spyOn } from "bun:test";
import { Markdown } from "@earendil-works/pi-tui";
import * as detail from "../extensions/subagent/browser/monitor-task-detail.js";
import { buildMonitorSessionGroups, monitorTreeRows } from "../extensions/subagent/browser/monitor-tree.js";
import { agentBrowserLayout } from "../extensions/subagent/browser/shared.js";
import { sortedMonitorRecords } from "../extensions/subagent/task-records.js";
import type { TraceViewerItem } from "../extensions/subagent/types.js";
import { agent, cleanupTempRuntimes, importRuntimeCopy, record, theme, uiState } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("popup invalidation clears layout and close discards pending trace loads", async () => {
	// Generate the private component entry only in the disposable test build.
	const runtime = await importRuntimeCopy("browser.ts", "function createAgentsBrowserComponent(", "export function createAgentsBrowserComponent(") as {
		createAgentsBrowserComponent: (...args: unknown[]) => { render(width: number): string[]; invalidate(): void; handleInput(data: string): void };
	};
	const config = agent("browser", false, { systemPrompt: "Browser prompt" });
	const ui = uiState();
	const records = Array.from({ length: 17 }, (_, i) => record("browser", `browser-${i}`, "2026-05-14T05:00:00.000Z"));
	const registry = Object.fromEntries(records.map((task) => [task.taskId, task]));
	const rows = monitorTreeRows(buildMonitorSessionGroups(sortedMonitorRecords(registry)));
	const taskRows = rows.flatMap((row, index) => row.kind === "task" ? [index] : []);
	assert.equal(taskRows.length, 17);
	const completions: Array<(items: TraceViewerItem[]) => void> = [];
	const loader = spyOn(detail, "traceViewerItems").mockImplementation(() => new Promise((resolve) => { completions.push(resolve); }));
	const markdown = spyOn(Markdown.prototype, "render");
	let renders = 0;
	let closed = false;
	const component = runtime.createAgentsBrowserComponent({ agents: [config], projectAgentsDir: undefined }, new Map(), registry, ui, theme,
		() => { renders++; }, () => agentBrowserLayout(50), () => { closed = true; }, () => [], process.cwd());
	try {
		component.render(120);
		component.render(120);
		assert.equal(markdown.mock.calls.length, 1);
		component.invalidate();
		component.render(120);
		assert.equal(markdown.mock.calls.length, 2);
		ui.tab = "monitor";
		for (const index of taskRows) {
			ui.monitorSelected = index;
			component.render(120);
		}
		assert.equal(completions.length, 17);
		const before = renders;
		completions[0]!([{ label: "Summary", text: "Evicted load", type: "summary" }]);
		await Promise.resolve();
		assert.equal(renders, before, "evicted load must not reinsert itself");
		ui.monitorSelected = taskRows[0]!;
		component.render(120);
		assert.equal(completions.length, 18, "evicted task must load again");
		component.handleInput("\x03");
		assert.equal(closed, true);
		for (const complete of completions.slice(1)) complete([]);
		await Promise.resolve();
		assert.equal(renders, before, "loads must not repaint a closed popup");
	} finally {
		if (!closed) component.handleInput("\x03");
		for (const complete of completions) complete([]);
		loader.mockRestore();
		markdown.mockRestore();
	}
});
