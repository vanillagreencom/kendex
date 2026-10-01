// Run with `bun tests/popup-layout.bench.ts [source-root]` from the package.
// Dependency instrumentation delegates to the real Pi Markdown and ANSI wrapper.
// It counts work, not timings from a substituted renderer.
import { mock } from "bun:test";
import { resolve } from "node:path";
import * as tui from "@earendil-works/pi-tui";
import type { Theme } from "@earendil-works/pi-coding-agent";
import type { MonitorDetailEntry } from "../extensions/subagent/types.js";

let markdownLayouts = 0;
let traceWraps = 0;
const markdownRender = tui.Markdown.prototype.render;
tui.Markdown.prototype.render = function (width: number): string[] {
	markdownLayouts++;
	return markdownRender.call(this, width);
};
const wrap = tui.wrapTextWithAnsi;
mock.module("@earendil-works/pi-tui", () => ({
	...tui,
	wrapTextWithAnsi: (text: string, width: number) => {
		if (text.includes("benchmark trace row")) traceWraps++;
		return wrap(text, width);
	},
}));

const sourceRoot = resolve(process.argv[2] ?? "../..");
const runtime = resolve(sourceRoot, "pi-extensions/pi-agents-tmux/extensions/subagent/browser");
const { renderAgentInspector } = await import(resolve(runtime, "agents-tab.ts")) as typeof import("../extensions/subagent/browser/agents-tab.js");
const { renderMonitorDetail } = await import(resolve(runtime, "monitor-task-detail.ts")) as typeof import("../extensions/subagent/browser/monitor-task-detail.js");
const { agent, record, theme, uiState } = await import("./browser-fixture.js");
const steps = 200;
const sourceRows = 1000;
const config = agent("benchmark", false, { systemPrompt: Array.from({ length: sourceRows }, (_, i) => `- **Prompt ${i}**: read the component and keep its public behavior unchanged.`).join("\n") });
const task = record("benchmark", "benchmark-task", "2026-05-14T05:00:00.000Z");
const traces = new Map<string, MonitorDetailEntry>([[task.taskId, { items: [{ label: "Transcript", text: Array.from({ length: sourceRows }, (_, i) => `benchmark trace row ${i}: read the component and keep its public behavior unchanged.`).join("\n"), type: "transcript" }] }]]);

for (const surface of ["prompt", "trace"] as const) {
	const ui = uiState();
	const render = () => surface === "prompt"
		? renderAgentInspector(config, new Map(), ui, 80, 30, theme as unknown as Theme)
		: renderMonitorDetail(task, traces, ui, 80, 30, theme as unknown as Theme);
	render();
	const firstFrame = { markdownLayouts, traceWraps };
	const start = performance.now();
	for (let step = 0; step < steps; step++) {
		ui.inspectorScroll = step + 1;
		render();
	}
	const millisecondsPerStep = (performance.now() - start) / steps;
	console.log(JSON.stringify({ surface, sourceRows, width: 80, steps, afterFirstFrame: { markdownLayouts: markdownLayouts - firstFrame.markdownLayouts, traceWraps: traceWraps - firstFrame.traceWraps }, millisecondsPerStep }));
}
