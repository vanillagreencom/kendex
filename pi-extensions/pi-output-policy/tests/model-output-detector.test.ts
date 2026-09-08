import { expect, test } from "bun:test";
import { createModelOutputGuardState, inspectModelOutputDelta } from "../extensions/output-policy.ts";

const options = { maxChars: 96_000, maxConsecutiveRepeats: 24, minRepeatBlockChars: 32, minRepeatedChars: 1_536 };
const block = `Repeated substantial block ${"r".repeat(40)}`;
const threshold = { ...options, maxConsecutiveRepeats: 3, minRepeatedChars: block.length * 3 };
const heading = `Repeated report heading ${"h".repeat(48)}`;
const paragraph = "Let me launch it in background and check config dirs after a few seconds.";

test("stream detector input and threshold table", () => {
	const repeated = `${"repeat ".repeat(10)}\n`.repeat(100);
	const cases: Array<{
		name: string; text: string; chunk?: number; reason?: string; count?: number; early?: boolean;
		options?: Parameters<typeof inspectModelOutputDelta>[2]; totalChars?: number;
		state?: { lastBlock: string | undefined; consecutiveRepeats: number; repeatedChars: number };
	}> = [
		{ name: "chunked paragraph", text: `${paragraph}\n</invoke>\n\n`.repeat(40), chunk: 17, reason: "repetition", count: 24, early: true },
		{ name: "varied", text: Array.from({ length: 100 }, (_, i) => `Useful distinct result ${i}: ${"x".repeat(40)}\n`).join("") },
		{ name: "short syntax", text: "</invoke>\n".repeat(100) },
		{ name: "semantic interruption", text: Array.from({ length: 40 }, (_, i) => `${heading}\nvalue ${i}\n`).join(""), chunk: 11, state: { lastBlock: undefined, consecutiveRepeats: 0, repeatedChars: 0 } },
		{ name: "syntax streak", text: `${block}\n\n</invoke>\n\`\`\`ts\n---\n${"-".repeat(80)}\n${block}\n<parameter name="path-to-a-long-tool-argument">\n~~~\n${block}\n`, options: threshold, reason: "repetition" },
		...["``` ts", "~~~ shell session"].map(fence => ({ name: fence, text: `${block}\n${fence}\n${block}\n${fence}\n${block}\n`, options: threshold, reason: "repetition" })),
		...["note: ``` ts", "    ``` ts", "``` ts `invalid`", "OK"].map(line => ({ name: line, text: `${block}\n${block}\n${line}\n${block}\n`, options: threshold, state: { lastBlock: block, consecutiveRepeats: 1, repeatedChars: block.length } })),
		{ name: "below repeat count", text: `${block}\n`.repeat(2), options: threshold },
		{ name: "exact repeat count", text: `${block}\n`.repeat(3), options: threshold, reason: "repetition" },
		{ name: "below repeated chars", text: `${block}\n`.repeat(3), options: { ...threshold, minRepeatedChars: block.length * 3 + 1 } },
		{ name: "below block length", text: `${"a".repeat(31)}\n`.repeat(2), options: { ...options, maxConsecutiveRepeats: 2, minRepeatedChars: 64 } },
		{ name: "exact block length", text: `${"b".repeat(32)}\n`.repeat(2), options: { ...options, maxConsecutiveRepeats: 2, minRepeatedChars: 64 }, reason: "repetition" },
		{ name: "different substantial block", text: `${"b".repeat(32)}\nDifferent substantial block ${"d".repeat(40)}\n${"b".repeat(32)}\n`, options: { ...options, maxConsecutiveRepeats: 2, minRepeatedChars: 64 } },
		{ name: "below character cap", text: "x".repeat(899), options: { ...options, maxChars: 900 } },
		{ name: "exact character cap", text: "x".repeat(900), chunk: 899, options: { ...options, maxChars: 900 }, reason: "max-chars", totalChars: 900 },
		{ name: "character cap disabled", text: "x".repeat(100_000), options: { ...options, maxChars: 0 } },
		{ name: "repetition disabled", text: repeated, options: { ...options, maxChars: 0, repetitionEnabled: false } },
	];
	expect(heading.length * 24).toBeGreaterThanOrEqual(options.minRepeatedChars);
	for (const row of cases) {
		const state = createModelOutputGuardState();
		let detection;
		const chunk = row.chunk ?? row.text.length;
		for (let offset = 0; offset < row.text.length && !detection; offset += chunk) {
			detection = inspectModelOutputDelta(state, row.text.slice(offset, offset + chunk), row.options ?? options);
		}
		expect(detection?.reason, row.name).toBe(row.reason);
		if (row.count !== undefined) expect(detection?.consecutiveRepeats).toBe(row.count);
		if (row.early) expect(detection?.totalChars ?? 0).toBeLessThan(row.text.length);
		if (row.totalChars !== undefined) expect(detection).toEqual({ reason: row.reason, totalChars: row.totalChars });
		if (row.state) expect({ lastBlock: state.lastBlock, consecutiveRepeats: state.consecutiveRepeats, repeatedChars: state.repeatedChars }).toEqual(row.state);
	}
});
