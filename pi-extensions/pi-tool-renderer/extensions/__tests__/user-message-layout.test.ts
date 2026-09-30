import { expect, test } from "bun:test";
import { getMarkdownTheme } from "@earendil-works/pi-coding-agent";
import { __test, installUserMessageRenderer } from "../tool-renderer/messages.js";
import { useWorld } from "./helpers/world.js";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { clearPackageConfigCache } from "../tool-renderer/package-config.js";

const world = useWorld();

test("user Markdown reuses one layout and invalidates for width, content, themes and host invalidation", () => {
	let highlights = 0;
	let highlightSuffix = "";
	const markdownTheme = { ...getMarkdownTheme(), codeBlockBorder: (text: string) => text, codeBlock: (text: string) => text, highlightCode(code: string) { highlights++; return code.split("\n").map((line) => line + highlightSuffix); } };
	const theme = { fg: (_token: string, text: string) => text };
	const ui = { theme };
	class Message {
		text = "```typescript\nconst first = true;\n```";
		markdownTheme = markdownTheme;
		invalidations = 0;
		invalidate() { this.invalidations++; }
		render(_width = 60) { return ["upstream"]; }
	}
	const handlers = new Map<string, (...args: unknown[]) => void>();
	installUserMessageRenderer({ on: (event: string, handler: (...args: unknown[]) => void) => handlers.set(event, handler) } as never, Message);
	const component = new Message();
	const draw = (width = 60) => component.render(width);
	try {
		handlers.get("session_start")!({}, { cwd: world().cwd, hasUI: true, ui });
		const first = draw();
		const count = highlights;
		expect(first.join("\n")).toContain("first");
		expect(count).toBeGreaterThan(0);
		expect(draw()).toEqual(first);
		expect(highlights).toBe(count);
		draw(40);
		expect(highlights).toBeGreaterThan(count);
		component.text = "```typescript\nconst changed = false;\n```";
		expect(draw().join("\n")).toContain("changed");
		const content = draw();
		const beforeInvalidation = highlights;
		highlightSuffix = " // refreshed";
		component.invalidate();
		expect(component.invalidations).toBe(1);
		expect(content.join("\n")).not.toContain("refreshed");
		expect(draw().join("\n")).toContain("refreshed");
		expect(highlights).toBeGreaterThan(beforeInvalidation);
		const beforeTheme = highlights;
		ui.theme = { fg: (_token: string, text: string) => `\x1b[31m${text}\x1b[39m` };
		expect(draw().join("\n")).toContain("\x1b[31m");
		expect(highlights).toBeGreaterThan(beforeTheme);
		const beforeMarkdownTheme = highlights;
		component.markdownTheme = { ...markdownTheme };
		draw();
		expect(highlights).toBeGreaterThan(beforeMarkdownTheme);
		const beforeSettings = highlights;
		writeFileSync(join(world().agent, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-tool-renderer": { styledCodeBlocks: false } } } } }));
		clearPackageConfigCache();
		draw();
		expect(highlights).toBeGreaterThan(beforeSettings);
		const beforeShutdown = __test.renderRawUserMessageLines(component, 60, ui.theme, world().cwd);
		handlers.get("session_shutdown")!();
		expect(__test.renderRawUserMessageLines(component, 60, ui.theme, world().cwd)).not.toBe(beforeShutdown);
		expect(component.render()).toEqual(["upstream"]);
	} finally {
		handlers.get("session_shutdown")!();
	}
});

test("user layouts bypass oversized content and drop old component layouts at the count bound", () => {
	const theme = { fg: (_token: string, text: string) => text };
	const component = { text: "first", markdownTheme: getMarkdownTheme() };
	const first = __test.renderRawUserMessageLines(component, 80, theme);
	for (let index = 0; index < 256; index++) __test.renderRawUserMessageLines({ text: "next", markdownTheme: component.markdownTheme }, 80, theme);
	expect(__test.renderRawUserMessageLines(component, 80, theme)).not.toBe(first);
	component.text = "a".repeat(64 * 1024 + 1);
	const oversized = __test.renderRawUserMessageLines(component, 80, theme);
	expect(__test.renderRawUserMessageLines(component, 80, theme)).not.toBe(oversized);
});
