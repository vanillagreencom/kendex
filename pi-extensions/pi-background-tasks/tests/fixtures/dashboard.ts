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
const selectedTask = fakeTask({ id: "bg-2", status: "completed", command: task.command });
const reads = new Map([task, selectedTask].map((value) => {
	let release!: (text: string) => void;
	const output = new Promise<string>((resolve) => { release = resolve; });
	return [value, { output, release, completion: output }];
}));
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
	component.handleInput("down");
	assert.ok(component.render(120).some((line: string) => line.includes("(no output yet)")), "selected task read must remain pending");
	reads.get(selectedTask)!.release("recent output");
	await reads.get(selectedTask)!.completion;
	assert.equal(renders, 2);
	assert.ok(component.render(120).some((line: string) => line.includes("recent output")));
	const beforeStale = renders;
	reads.get(task)!.release("stale prior output");
	await reads.get(task)!.completion;
	const lines = component.render(120);
	assert.ok(lines.some((line: string) => line.includes("recent output")), "late prior read must retain selected output");
	assert.ok(lines.every((line: string) => !line.includes("stale prior output")), "late prior read must not replace selected output");
	assert.equal(renders, beforeStale, "late prior read must not request a render");
	component.handleInput("x");
	component.render(120);
	assert.equal(dashboardHost.commandWraps, 1, "expansion must reuse the complete layout");
	component.render(80);
	assert.equal(dashboardHost.commandWraps, 2);
	selectedTask.command += "different";
	component.render(80);
	assert.equal(dashboardHost.commandWraps, 3);
	component.invalidate();
	component.render(80);
	assert.equal(dashboardHost.commandWraps, 4, "theme invalidation must clear styled lines");
	component.dispose();
	const atDispose = renders;
	await reads.get(selectedTask)!.completion;
	assert.equal(renders, atDispose, "a pending read must not render a disposed modal");
} } } as unknown as ExtensionCommandContext;
await openDashboard(ctx, {
	sortedTasks: () => [task, selectedTask], getTask: (id) => [task, selectedTask].find((value) => value.id === id) ?? null, getTaskOutput: (value) => {
		const read = reads.get(value)!;
		read.completion = (async () => read.output)();
		return read.completion;
	},
	requestStop: () => { throw new Error("unexpected stop"); }, clearFinishedTasks: () => 0, formatTaskListText: () => "",
});
process.stdout.write(JSON.stringify({ commandWraps: dashboardHost.commandWraps, renders }));
