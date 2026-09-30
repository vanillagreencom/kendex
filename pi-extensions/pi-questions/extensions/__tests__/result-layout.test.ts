import { expect, test } from "bun:test";
import { mockQuestionRuntime } from "./helpers/runtime.js";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../package-config.js";

const wrapped: string[] = [];
mockQuestionRuntime({
	truncateToWidth: (text: string) => text,
	visibleWidth: (text: string) => text.replace(/\x1b\[[\d;]*m/g, "").length,
	wrapTextWithAnsi: (text: string) => { wrapped.push(text); return text.split("\n"); },
});
const { default: questions } = await import("../questions.js");

test("question result normalizes once and reuses layout until width or host invalidation changes", () => {
	const root = mkdtempSync(join(tmpdir(), "question-layout-"));
	const previous = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = root;
	writeFileSync(join(root, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-questions": { enabled: true } } } } }));
	clearPackageConfigCache();
	let argsReads = 0;
	let colors = "";
	let styles = 0;
	const theme = { fg: (_token: string, text: string) => { styles++; return colors + text; }, bold: (text: string) => text };
	let tool: { renderResult: (...args: unknown[]) => { render(width: number): string[]; invalidate(): void } };
	let shutdown: (() => void) | undefined;
	questions({ events: { emit() {} }, on(event: string, handler: () => void) { if (event === "session_shutdown") shutdown = handler; }, registerTool(value: typeof tool) { tool = value; } } as never);
	const context = { get args() { argsReads++; return { header: "Decision", questions: [{ header: "Choice", question: "Which?", options: [{ label: "Keep" }] }] }; } };
	const result = { details: { requestId: "question", answers: [["\x1b[31mKeep\x1b[39m"]] } };
	try {
		const component = tool!.renderResult(result, { expanded: false }, theme, context);
		expect(argsReads).toBe(1);
		const first = component.render(80);
		const count = styles;
		expect(component.render(80)).toBe(first);
		expect(styles).toBe(count);
		expect(wrapped.at(-1)).toBe("\x1b[31mKeep\x1b[39m");
		expect(component.render(40)).not.toBe(first);
		expect(argsReads).toBe(1);
		colors = "new-theme ";
		component.invalidate();
		expect(component.render(40).join("\n")).toContain("new-theme");
		expect(argsReads).toBe(1);
		writeFileSync(join(root, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-questions": { enabled: true, glyphStyle: "ascii" } } } } }));
		clearPackageConfigCache();
		expect(component.render(40).join("\n")).toContain("*");
		const changed = tool!.renderResult({ details: { answers: [["Changed"]] } }, { expanded: true }, theme, context);
		expect(changed.render(80).join("\n")).toContain("Changed");
		const cancelled = tool!.renderResult({ details: { cancelled: true } }, {}, theme, { args: null });
		expect(cancelled.render(80).join("\n")).toContain("cancelled");
		expect(cancelled.render(80)).toBe(cancelled.render(80));
	} finally {
		shutdown?.();
		if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previous;
		clearPackageConfigCache();
		rmSync(root, { recursive: true, force: true });
	}
});
