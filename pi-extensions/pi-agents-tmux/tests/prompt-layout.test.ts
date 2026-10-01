import assert from "node:assert/strict";
import { after, test } from "node:test";
import { spyOn } from "bun:test";
import { Markdown } from "@earendil-works/pi-tui";
import type { Theme } from "@earendil-works/pi-coding-agent";
import { renderAgentInspector } from "../extensions/subagent/browser/agents-tab.js";
import { invalidatePopupLayouts } from "../extensions/subagent/browser/shared.js";
import { agent, assertPromptLayoutReuse, cleanupTempRuntimes, importRuntimeCopy, theme, uiState } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("prompt scrolling reuses Markdown layout", () => assertPromptLayoutReuse(renderAgentInspector));

test("prompt layout changes with content, width, theme and Pi invalidation", () => {
	const config = agent("prompt", false, { systemPrompt: "First prompt" });
	const ui = uiState();
	const palette = { ...theme };
	let width = 80;
	const render = () => renderAgentInspector(config, new Map(), ui, width, 40, palette as unknown as Theme);
	const spy = spyOn(Markdown.prototype, "render");
	try {
		render();
		// Agent edits, terminal resizes and theme reloads are the real producers.
		for (const change of [
			() => { config.systemPrompt = "Changed prompt"; },
			() => { width = 40; },
			() => { palette.fg = (_tone, text) => `\x1b[31m${text}\x1b[0m`; },
			() => { invalidatePopupLayouts(ui); },
		]) {
			const before = spy.mock.calls.length;
			change();
			render();
			render();
			assert.equal(spy.mock.calls.length - before, 1);
		}
		config.systemPrompt = "";
		ui.inspectorScroll = 999;
		const empty = render();
		assert.equal(ui.inspectorScroll, 0);
		assert.ok(empty.join("\n").includes("(empty prompt)"));
	} finally { spy.mockRestore(); }
});

test("main's per-frame Markdown behavior fails the reuse assertion", async () => {
	const runtime = await importRuntimeCopy("browser/agents-tab.ts", `const promptLines = cachedPopupLayout(ui, "prompt", prompt, undefined, width, theme, () => {
		const renderedPrompt = new Markdown(prompt, 0, 0, agentSystemPromptMarkdownTheme(theme)).render(width);
		return renderedPrompt.length > 0 ? renderedPrompt : wrapTextWithAnsi(prompt, width);
	});`, `const renderedPrompt = new Markdown(prompt, 0, 0, agentSystemPromptMarkdownTheme(theme)).render(width);
	const promptLines = renderedPrompt.length > 0 ? renderedPrompt : wrapTextWithAnsi(prompt, width);`) as typeof import("../extensions/subagent/browser/agents-tab.js");
	assert.throws(() => assertPromptLayoutReuse(runtime.renderAgentInspector), { code: "ERR_ASSERTION" });
});
