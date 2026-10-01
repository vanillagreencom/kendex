import assert from "node:assert/strict";
import { after, test } from "node:test";
import { spyOn } from "bun:test";
import * as tui from "@earendil-works/pi-tui";
import type { Theme } from "@earendil-works/pi-coding-agent";
import { renderMonitorDetail } from "../extensions/subagent/browser/monitor-task-detail.js";
import type { TraceViewerItem } from "../extensions/subagent/types.js";
import { assertTraceLayoutReuse, cleanupTempRuntimes, importRuntimeCopy, record, theme, uiState } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("trace scrolling reuses wrapping", () => assertTraceLayoutReuse(renderMonitorDetail));

test("trace layout tracks content, width, type, theme, subtab and empty content", () => {
	const task = record("trace", "trace-task", "2026-05-14T05:00:00.000Z");
	const items: TraceViewerItem[] = [{ label: "Summary", text: "Trace first row", type: "summary" }, { label: "Transcript", text: "Trace second row", type: "transcript" }];
	const cache = new Map([[task.taskId, { items }]]);
	const ui = uiState();
	const palette = { ...theme };
	let width = 80;
	const render = () => renderMonitorDetail(task, cache, ui, width, 20, palette as unknown as Theme);
	const spy = spyOn(tui, "wrapTextWithAnsi");
	try {
		render();
		for (const change of [
			() => { items[0]!.text = "Trace changed row"; },
			() => { width = 40; },
			() => { items[0]!.type = "transcript"; },
			() => { palette.fg = (_tone, text) => `\x1b[31m${text}\x1b[0m`; },
			() => { ui.monitorSubtab = 1; },
		]) {
			const before = spy.mock.calls.length;
			change();
			render();
			render();
			assert.equal(spy.mock.calls.length - before, 1);
		}
		items[1]!.text = "";
		ui.inspectorScroll = 999;
		assert.ok(render().join("\n").includes("(empty)"));
		assert.equal(ui.inspectorScroll, 0);
	} finally { spy.mockRestore(); }
});

test("main's per-frame trace behavior fails the reuse assertion", async () => {
	const runtime = await importRuntimeCopy("browser/monitor-task-detail.ts", `const text = item?.text || "(empty)";
	const wrapped = cachedPopupLayout(ui, "trace", text, item?.type, safeWidth, theme,
		() => renderTraceContentLines(text.split(/\\r?\\n/), item?.type, safeWidth, theme));`, `const rawLines = (item?.text || "(empty)").split(/\\r?\\n/);
	const wrapped = renderTraceContentLines(rawLines, item?.type, safeWidth, theme);`) as typeof import("../extensions/subagent/browser/monitor-task-detail.js");
	assert.throws(() => assertTraceLayoutReuse(runtime.renderMonitorDetail), { code: "ERR_ASSERTION" });
});
