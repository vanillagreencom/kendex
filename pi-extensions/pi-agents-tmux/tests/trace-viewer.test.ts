import assert from "node:assert/strict";
import test, { after } from "node:test";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import * as viewer from "../extensions/subagent/browser/trace-viewer.js";
import { traceViewerItems } from "../extensions/subagent/browser/monitor-task-detail.js";
import { cleanupTempRuntimes, importRuntimeCopy, record, toneTheme } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("trace viewer derives the stopped header tone from task status", async () => {
	const items = await traceViewerItems(record("scout", "stopped", "2026-05-14T05:00:00Z", { status: "stopped" }));
	let lines: string[] = [];
	const ctx = {
		hasUI: true,
		ui: {
			custom: async (factory: (tui: { terminal: { rows: number }; requestRender(): void }, theme: Theme, kb: undefined, done: () => void) => { render(width: number): string[] }) => {
				lines = factory({ terminal: { rows: 40 }, requestRender() {} }, toneTheme as unknown as Theme, undefined, () => {}).render(180);
			},
		},
	} as unknown as ExtensionContext;
	await viewer.openTraceViewer(ctx, "task", items);
	// The frame places metadata after the tab bar and its blank line. The body
	// also prints status, so only the metadata line can prove the header tone.
	assert.ok(lines[3]?.includes("<warning>stopped</warning>"));
	const mutant = await importRuntimeCopy("browser/trace-viewer.ts", 'taskStatus(item.status).tone', '"error"') as typeof viewer;
	await mutant.openTraceViewer(ctx, "task", items);
	assert.throws(() => assert.ok(lines[3]?.includes("<warning>stopped</warning>")), assert.AssertionError);
});
