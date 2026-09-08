import assert from "node:assert/strict";
import test from "node:test";
import { createWebAnswerToolDefinition } from "../src/tools/web-answer.js";

const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };
const tool = createWebAnswerToolDefinition({} as any, () => ({}) as any);
const query = "What is Ghostty?";
const answer = "Ghostty is a fast terminal emulator. ".repeat(30);
for (const { name, expanded } of [{ name: "compact", expanded: false }, { name: "expanded", expanded: true }]) {
	test(`web_answer renderer: ${name}`, () => {
		const call = tool.renderCall({ query }, theme, {}).render(200).join("\n");
		const text = tool.renderResult({ details: { answer, results: [] } }, { expanded }, theme, { args: { query } }).render(200).join("\n");
		const compact = tool.renderResult({ details: { answer, results: [] } }, {}, theme, { args: { query } }).render(200).join("\n");
		assert.deepEqual({ call: call.includes("Web Answer (Exa) What is Ghostty?"), title: text.includes("Web Answer (Exa) What is Ghostty?"), redundantHeader: /· answer/.test(text.split("\n")[0] ?? ""), content: text.includes("Ghostty is a fast terminal emulator."), redundantLabel: text.includes("answer Ghostty"), hint: compact.includes("ctrl+o"), longer: text.length > compact.length }, { call: true, title: true, redundantHeader: false, content: true, redundantLabel: false, hint: true, longer: expanded });
	});
}
