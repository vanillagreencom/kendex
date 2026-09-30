import { expect, test } from "bun:test";
import { mockQuestionRuntime } from "./helpers/runtime.js";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../package-config.js";

const wrapped: string[] = [];
const longAnswer = "First second third fourth fifth sixth seventh eighth";
// Pi's wrapper supplies these rows; the test holds the result renderer's row cap.
const overflowRows = new Map([
	[longAnswer, ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth"]],
	[`Custom: ${longAnswer}`, ["Custom: First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth"]],
]);
mockQuestionRuntime({
	truncateToWidth: (text: string) => text,
	visibleWidth: (text: string) => text.replace(/\x1b\[[\d;]*m/g, "").length,
	wrapTextWithAnsi: (text: string) => { wrapped.push(text); return overflowRows.get(text) ?? text.split("\n"); },
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
		const plainTheme = { fg: (_token: string, text: string) => text, bold: (text: string) => text };
		const overflowContext = { args: { questions: [{ header: "Choice", question: "Which?", customLabel: "Custom", options: [{ label: "Keep" }] }] } };
		for (const row of [
			{ expanded: false, answerStart: 1, expected: ["* Choice: First", "Second", "Third", "Fourth..."] },
			{ expanded: true, answerStart: 5, expected: [" Custom: First", "Second", "Third", "Fourth", "Fifth", "Sixth..."] },
		]) {
			const overflowing = tool!.renderResult({ details: { answers: [[longAnswer]] } }, { expanded: row.expanded }, plainTheme, overflowContext);
			const lines = overflowing.render(40);
			expect(lines.slice(row.answerStart).map((line) => line.trim())).toEqual(row.expected);
			expect(overflowing.render(40)).toBe(lines);
		}
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
