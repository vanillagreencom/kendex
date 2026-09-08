import { expect, test } from "bun:test";
import { orchestrateChunkedSummary, type SummarizeOutcome, type SummarizeRequest } from "../extensions/qol/budget-guard.ts";

interface RecordedSummarize { text: string; customInstructions?: string; previousSummary?: string }

function recordingSummarizer(responses: string[]) {
	const calls: RecordedSummarize[] = [];
	let cursor = 0;
	const summarize = async (request: SummarizeRequest): Promise<SummarizeOutcome> => {
		calls.push({ customInstructions: request.customInstructions, previousSummary: request.previousSummary, text: request.text });
		const summary = responses[cursor] ?? `summary-${cursor + 1}`;
		cursor += 1;
		return { model: "test-model", summary, via: "model" };
	};
	return { calls, summarize };
}

const cases = [
	{
		name: "single short summary keeps the seed and instructions",
		run: async () => {
			const { calls, summarize } = recordingSummarizer(["the one summary"]);
			const result = await orchestrateChunkedSummary({ customInstructions: "carry decisions", maxInputChars: 1_000, previousSummary: "prev", summarize, text: "short text" });
			return { summary: result.summary, chunks: result.chunkCount, levels: result.reduceLevels, requests: result.requestCount, calls: calls.length, seed: calls[0]?.previousSummary, instructions: calls[0]?.customInstructions };
		},
		expected: { summary: "the one summary", chunks: 1, levels: 0, requests: 1, calls: 1, seed: "prev", instructions: "carry decisions" },
	},
	{
		name: "every summarize request fits the input cap",
		run: async () => {
			const { calls, summarize } = recordingSummarizer([]);
			const result = await orchestrateChunkedSummary({ maxInputChars: 200, previousSummary: "prev", summarize, text: `${"x".repeat(80)}\n\n`.repeat(60) });
			return { multipleChunks: result.chunkCount > 1, reduced: result.reduceLevels > 0, oversized: calls.filter(call => call.text.length > 200).map(call => call.text.length) };
		},
		expected: { multipleChunks: true, reduced: true, oversized: [] },
	},
	{
		name: "large partial summaries require repeated reduction",
		run: async () => {
			const responses = Array.from({ length: 40 }, (_, index) => "z".repeat(180) + ` #${index}`);
			const { calls, summarize } = recordingSummarizer(responses);
			const result = await orchestrateChunkedSummary({ maxInputChars: 200, summarize, text: `${"y".repeat(60)}\n\n`.repeat(120) });
			return { repeatedReduction: result.reduceLevels >= 2, oversized: calls.filter(call => call.text.length > 200).map(call => call.text.length), requestsMatch: result.requestCount === calls.length };
		},
		expected: { repeatedReduction: true, oversized: [], requestsMatch: true },
	},
	{
		name: "already aborted signal refuses before a request",
		run: async () => {
			const { calls, summarize } = recordingSummarizer([]);
			const controller = new AbortController();
			controller.abort();
			let failure: unknown;
			try { await orchestrateChunkedSummary({ maxInputChars: 50, signal: controller.signal, summarize, text: "long ".repeat(200) }); }
			catch (error) { failure = error; }
			return { rejected: failure instanceof Error, requests: calls.length };
		},
		expected: { rejected: true, requests: 0 },
	},
	{
		name: "empty chunk summary refuses further requests",
		run: async () => {
			const { calls, summarize } = recordingSummarizer(["", "", ""]);
			let failure: unknown;
			try { await orchestrateChunkedSummary({ maxInputChars: 100, summarize, text: `${"a".repeat(60)}\n\n`.repeat(8) }); }
			catch (error) { failure = error; }
			return { rejected: failure instanceof Error, requests: calls.length };
		},
		expected: { rejected: true, requests: 1 },
	},
	{
		name: "previous summary advances across chunks and seeds final reduction",
		run: async () => {
			const { calls, summarize } = recordingSummarizer(["one", "two", "three", "four", "five"]);
			await orchestrateChunkedSummary({ maxInputChars: 80, previousSummary: "seed", summarize, text: `${"q".repeat(40)}\n\n`.repeat(8) });
			return { first: calls[0]?.previousSummary, second: calls[1]?.previousSummary, final: calls.at(-1)?.previousSummary };
		},
		expected: { first: "seed", second: "one", final: "seed" },
	},
];

if (cases.length === 0) throw new Error("summary cases are empty");
for (const row of cases) {
	test(`orchestrateChunkedSummary: ${row.name}`, async () => {
		expect(await row.run()).toStrictEqual(row.expected);
	});
}
