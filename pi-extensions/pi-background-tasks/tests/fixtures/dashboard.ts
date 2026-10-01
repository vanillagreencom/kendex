import { mock } from "bun:test";
import assert from "node:assert/strict";
import type { ExtensionCommandContext, Theme } from "@earendil-works/pi-coding-agent";
import { fakeTask } from "./lifecycle.js";

import { dashboardHost } from "./dashboard-host.js";
mock.module("../../extensions/render.js", () => ({
	acquirekendexModalLock: () => () => {}, activePill: (_theme: unknown, text: string) => text,
	inactivePill: (_theme: unknown, text: string) => text, bgStatusIcon: () => "", bgStatusText: () => "done",
	dashboardContentWidth: (width: number) => width, frameDashboard: (lines: string[]) => lines,
	padAnsi: (text: string) => text, splitOutputLines: (text: string) => [text || "(no output yet)"],
}));
const { openDashboard } = await import("../../extensions/dashboard.js");
const task = fakeTask({ status: "completed", command: "cache-me " + "a".repeat(400) });
let release: (text: string) => void = () => { throw new Error("log read not started"); };
const output = new Promise<string>((resolve) => { release = resolve; });
let readCompletion = output;
let renders = 0;
const ctx = { hasUI: true, ui: { custom: async (factory: (tui: unknown, theme: unknown, keys: unknown, done: () => void) => { render(width: number): string[]; handleInput(data: string): void; invalidate(): void; dispose(): void }) => {
	const component = factory({ terminal: { rows: 40 }, requestRender: () => { renders += 1; } }, {
		fg: (_color: string, text: string) => text, bg: (_color: string, text: string) => text, bold: (text: string) => text,
		inverse: (text: string) => text,
	} satisfies Pick<Theme, "fg" | "bg" | "bold" | "inverse">, {}, () => {});
	assert.ok(component.render(120).some((line: string) => line.includes("(no output yet)")), "render must not block on the log");
	assert.equal(dashboardHost.commandWraps, 1);
	component.render(120);
	assert.equal(dashboardHost.commandWraps, 1, "unchanged command must use the cache");
	release("recent output");
	await readCompletion;
	assert.equal(renders, 1);
	assert.ok(component.render(120).some((line: string) => line.includes("recent output")));
	component.handleInput("x");
	component.render(120);
	assert.equal(dashboardHost.commandWraps, 1, "expansion must reuse the complete layout");
	component.render(80);
	assert.equal(dashboardHost.commandWraps, 2);
	task.command += "different";
	component.render(80);
	assert.equal(dashboardHost.commandWraps, 3);
	component.invalidate();
	component.render(80);
	assert.equal(dashboardHost.commandWraps, 4, "theme invalidation must clear styled lines");
	component.dispose();
	const atDispose = renders;
	await readCompletion;
	assert.equal(renders, atDispose, "a pending read must not render a disposed modal");
} } } as unknown as ExtensionCommandContext;
await openDashboard(ctx, {
	sortedTasks: () => [task], getTask: () => task, getTaskOutput: () => {
		readCompletion = (async () => output)();
		return readCompletion;
	},
	requestStop: () => { throw new Error("unexpected stop"); }, clearFinishedTasks: () => 0, formatTaskListText: () => "",
});
process.stdout.write(JSON.stringify({ commandWraps: dashboardHost.commandWraps, renders }));
