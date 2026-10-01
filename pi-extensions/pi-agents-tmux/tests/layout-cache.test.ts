import assert from "node:assert/strict";
import test, { after, afterEach } from "node:test";
import { Markdown } from "@earendil-works/pi-tui";
import { spyOn } from "bun:test";
import { cachedPopupLayout, clearPopupLayouts } from "../extensions/subagent/browser/layout-cache.js";
import { renderAgentInspector } from "../extensions/subagent/browser/agents-tab.js";
import { renderMonitorDetail } from "../extensions/subagent/browser/monitor-task-detail.js";
import { agent, cleanupTempRuntimes, importRuntimeCopy, record, theme, uiState } from "./browser-fixture.js";

after(cleanupTempRuntimes);
afterEach(clearPopupLayouts);
const themed = theme as unknown as Parameters<typeof cachedPopupLayout>[3];

function reuse(cache: typeof cachedPopupLayout): void {
	let renders = 0;
	const render = () => { renders++; return ["layout"]; };
	for (const [text, width, currentTheme] of [["a", 40, themed], ["a", 40, themed], ["b", 40, themed], ["b", 20, themed], ["b", 20, { ...themed }]] as const) {
		cache("prompt", text, width, currentTheme, render);
	}
	assert.equal(renders, 4);
}

test("layout cache keys include content, width and theme", async () => {
	reuse(cachedPopupLayout);
	const mutant = await importRuntimeCopy("browser/layout-cache.ts", "if (index !== -1) {", "if (index !== -1 && false) {") as typeof import("../extensions/subagent/browser/layout-cache.js");
	assert.throws(() => reuse(mutant.cachedPopupLayout), /5 !== 4/);
});

test("layout entries are bounded by count and bytes and clear on theme invalidation", async () => {
	for (const [name, before, afterText, text, count] of [
		["count", "layouts.length >= 16", "layouts.length >= Infinity", "small", 17],
		["bytes", "bytes + size > MAX_BYTES", "bytes + size > Infinity", "x".repeat(2 * 1024 * 1024), 3],
	] as const) {
		const assertBound = (runtime: typeof import("../extensions/subagent/browser/layout-cache.js")) => {
			runtime.clearPopupLayouts();
			let renders = 0;
			const render = () => { renders++; return ["line"]; };
			for (let i = 0; i < count; i++) runtime.cachedPopupLayout(String(i), text, 40, themed, render);
			runtime.cachedPopupLayout("0", text, 40, themed, render);
			assert.equal(renders, count + 1, name);
			runtime.clearPopupLayouts();
			runtime.cachedPopupLayout("0", text, 40, themed, render);
			assert.equal(renders, count + 2);
		};
		assertBound({ cachedPopupLayout, clearPopupLayouts });
		const mutant = await importRuntimeCopy("browser/layout-cache.ts", before, afterText) as typeof import("../extensions/subagent/browser/layout-cache.js");
		assert.throws(() => assertBound(mutant));
	}
});

test("scrolling a warmed agents inspector does not invoke Markdown again", () => {
	const profile = agent("engineer", false, { systemPrompt: "# Task\n" + "content\n".repeat(100) });
	const ui = uiState();
	const spy = spyOn(Markdown.prototype, "render");
	try {
		renderAgentInspector(profile, new Map(), ui, 60, 30, themed);
		for (let i = 0; i < 30; i++) { ui.inspectorScroll = i; renderAgentInspector(profile, new Map(), ui, 60, 30, themed); }
		assert.equal(spy.mock.calls.length, 1);
	} finally { spy.mockRestore(); }
	const task = record("engineer", "task", "2026-09-30T00:00:00Z");
	const cache = new Map([[task.taskId, { items: [{ label: "Summary", type: "summary" as const, text: "line\n".repeat(100) }] }]]);
	ui.monitorSubtab = 0;
	assert.ok(renderMonitorDetail(task, cache, ui, 60, 30, themed).length <= 30);
});
