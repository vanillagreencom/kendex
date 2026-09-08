import { expect, spyOn, test } from "bun:test";
import * as codingAgent from "@earendil-works/pi-coding-agent";
import { transcriptRiskState } from "../extensions/qol/transcript-risk.ts";

type Message = Parameters<typeof transcriptRiskState>[0][number];

function messages(text: string, reply: string): Message[] {
	return [
		{ content: [{ text, type: "text" }], role: "user", timestamp: 0 },
		{ content: [{ text: reply, type: "text" }], role: "assistant", timestamp: 0 } as Message,
	];
}

// The preload owns the neutral serializer. These rows exercise the wrapper's
// result and its dependency-error boundary, not Pi's serialization algorithm.
const riskRows = [
	{
		name: "below the character budget",
		messages: messages("hi", "hello"),
		threshold: 1_000_000,
		charFloor: 0,
		serializerError: false,
		expected: { chars: expect.any(Number), charsAboveFloor: true, error: undefined, exceeded: false, messageCount: 2, threshold: 1_000_000 },
	},
	{
		name: "above the character budget",
		messages: messages("x".repeat(50_000), "x".repeat(50_000)),
		threshold: 10_000,
		charFloor: 50_000,
		serializerError: false,
		expected: { chars: expect.any(Number), charsAboveFloor: true, error: undefined, exceeded: true, messageCount: 2, threshold: 10_000 },
	},
	{
		name: "empty messages",
		messages: [],
		threshold: 1000,
		charFloor: 0,
		serializerError: false,
		expected: { chars: 0, charsAboveFloor: false, error: undefined, exceeded: false, messageCount: 0, threshold: 1000 },
	},
	{
		name: "disabled character budget",
		messages: messages("hi", "hello").slice(0, 1),
		threshold: 0,
		charFloor: 0,
		serializerError: false,
		expected: { chars: 0, charsAboveFloor: false, error: undefined, exceeded: false, messageCount: 1, threshold: 0 },
	},
	{
		name: "serializer dependency throws",
		messages: messages("hi", "hello").slice(1),
		threshold: 1000,
		charFloor: 0,
		serializerError: true,
		expected: { chars: 0, charsAboveFloor: false, error: "boom", exceeded: false, messageCount: 1, threshold: 1000 },
	},
];

if (riskRows.length === 0) throw new Error("Transcript risk table is empty");

for (const row of riskRows) {
	test(row.name, () => {
		expect.hasAssertions();
		const serializer = row.serializerError
			? spyOn(codingAgent, "serializeConversation").mockImplementation(() => { throw new Error("boom"); })
			: undefined;
		try {
			const result = transcriptRiskState(row.messages, row.threshold);
			expect({ ...result, error: result.error, charsAboveFloor: result.chars > row.charFloor }).toEqual(row.expected);
		} finally {
			serializer?.mockRestore();
		}
	});
}
