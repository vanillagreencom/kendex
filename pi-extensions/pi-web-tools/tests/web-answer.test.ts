import assert from "node:assert/strict";
import test from "node:test";
import { createWebAnswerToolDefinition } from "../src/tools/web-answer.js";
import { endWebContentSession } from "../src/storage.js";
import { detailsHold, withStoredText } from "./fixtures.js";

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

test("web_answer execute: details carry the answer and source refs, the source text only in the store", async (t) => {
	endWebContentSession();
	t.after(endWebContentSession);
	t.mock.method(globalThis, "fetch", async () => new Response(JSON.stringify({ answer: "Ghostty is a terminal.", results: [{ title: "Ghostty", url: "https://ghostty.org", text: "source page text" }] })));
	const executed = createWebAnswerToolDefinition({ appendEntry() {} } as any, () => ({ apiKeys: { exa: "k" } }) as any);
	const result = await executed.execute("call", { query }, undefined, undefined, { cwd: process.cwd() } as any);
	const { results, ...rest } = result.details;
	assert.deepEqual({ rest, results: withStoredText(results), detailsText: detailsHold(result.details, "source page text") }, {
		rest: { provider: "exa", answer: "Ghostty is a terminal." },
		results: [{ title: "Ghostty", url: "https://ghostty.org", stored: "source page text" }],
		detailsText: false,
	});
});
