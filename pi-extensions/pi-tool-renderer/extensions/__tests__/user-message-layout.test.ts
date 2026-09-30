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
	const markdownTheme = { ...getMarkdownTheme(), codeBlockBorder: (text: string) => text, codeBlock: (text: string) => text, highlightCode(code: string) { highlights++; return code.split("\n"); } };
	const theme = { fg: (_token: string, text: string) => text };
	class Message {
		text = "```typescript\nconst first = true;\n```";
		markdownTheme = markdownTheme;
		invalidations = 0;
		invalidate() { this.invalidations++; }
		render() { return ["upstream"]; }
	}
	const handlers = new Map<string, (...args: unknown[]) => void>();
	installUserMessageRenderer({ on: (event: string, handler: (...args: unknown[]) => void) => handlers.set(event, handler) } as never, Message);
	const component = new Message();
	const draw = (width = 60, colors = theme) => __test.renderRawUserMessageLines(component, width, colors)!;
	try {
		const first = draw();
		const count = highlights;
		expect(count).toBeGreaterThan(0);
		expect(draw()).toBe(first);
		expect(highlights).toBe(count);
		expect(draw(40)).not.toBe(first);
		expect(highlights).toBeGreaterThan(count);
		component.text = "```typescript\nconst changed = false;\n```";
		expect(draw().join("\n")).toContain("changed");
		const content = draw();
		component.invalidate();
		expect(component.invalidations).toBe(1);
		expect(draw()).not.toBe(content);
		const beforeTheme = draw();
		expect(draw(60, { fg: (_token: string, text: string) => `\x1b[31m${text}\x1b[39m` })).not.toBe(beforeTheme);
		component.markdownTheme = { ...markdownTheme };
		expect(draw()).not.toBe(beforeTheme);
		const beforeSettings = draw();
		writeFileSync(join(world().agent, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-tool-renderer": { styledCodeBlocks: false } } } } }));
		clearPackageConfigCache();
		expect(draw()).not.toBe(beforeSettings);
		const beforeShutdown = draw();
		handlers.get("session_shutdown")!();
		expect(draw()).not.toBe(beforeShutdown);
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
