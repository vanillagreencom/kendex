import { expect, test } from "bun:test";
import { evaluateTranscriptRisk, type TranscriptRiskInput } from "../extensions/qol/budget-guard.ts";

const cases: { name: string; input: TranscriptRiskInput; exceeded: boolean }[] = [
	{ name: "no characters", input: { chars: 0, messageCount: 5, threshold: 100 }, exceeded: false },
	{ name: "below the threshold", input: { chars: 90, messageCount: 5, threshold: 100 }, exceeded: false },
	{ name: "at the threshold", input: { chars: 100, messageCount: 5, threshold: 100 }, exceeded: true },
	{ name: "above the threshold", input: { chars: 250, messageCount: 5, threshold: 100 }, exceeded: true },
	{ name: "disabled threshold", input: { chars: 1000, messageCount: 5, threshold: 0 }, exceeded: false },
	{ name: "no messages", input: { chars: 1000, messageCount: 0, threshold: 100 }, exceeded: false },
	{ name: "error from the serializer", input: { chars: 0, error: "boom", messageCount: 5, threshold: 100 }, exceeded: false },
];

if (cases.length === 0) throw new Error("risk cases are empty");
for (const row of cases) {
	test(`evaluateTranscriptRisk: ${row.name}`, () => {
		expect(evaluateTranscriptRisk(row.input)).toEqual({ ...row.input, exceeded: row.exceeded });
	});
}
