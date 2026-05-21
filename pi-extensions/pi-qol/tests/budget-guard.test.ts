import { expect, test } from "bun:test";
import {
	chunkConversationText,
	computeBudgetTrigger,
	evaluateTranscriptRisk,
	isBudgetGuardCompaction,
	QOL_BUDGET_GUARD_SENTINEL,
	orchestrateChunkedSummary,
	type SummarizeOutcome,
	type SummarizeRequest,
} from "../extensions/qol/budget-guard.ts";

test("computeBudgetTrigger returns undefined when disabled", () => {
	const trigger = computeBudgetTrigger({
		contextWindow: 200_000,
		enabled: false,
		percentLimit: 85,
		tokenLimit: -1,
		tokens: 195_000,
	});
	expect(trigger).toBeUndefined();
});

test("computeBudgetTrigger fires on percent threshold", () => {
	const trigger = computeBudgetTrigger({
		contextWindow: 200_000,
		enabled: true,
		percentLimit: 85,
		tokenLimit: -1,
		tokens: 180_000,
	});
	expect(trigger).toBeDefined();
	expect(trigger?.reason).toContain("85% budget guard");
	expect(trigger?.key.startsWith("percent:85:")).toBe(true);
	expect(trigger?.percent).toBeCloseTo(90, 0);
});

test("computeBudgetTrigger fires on absolute token limit even without context window", () => {
	const trigger = computeBudgetTrigger({
		enabled: true,
		percentLimit: -1,
		tokenLimit: 150_000,
		tokens: 160_000,
	});
	expect(trigger).toBeDefined();
	expect(trigger?.key.startsWith("tokens:150000:")).toBe(true);
	expect(trigger?.reason).toContain("budget token limit");
});

test("computeBudgetTrigger returns stable key while usage stays in the same bucket", () => {
	const first = computeBudgetTrigger({
		contextWindow: 200_000,
		enabled: true,
		percentLimit: 85,
		tokenLimit: -1,
		tokens: 172_000,
	});
	const second = computeBudgetTrigger({
		contextWindow: 200_000,
		enabled: true,
		percentLimit: 85,
		tokenLimit: -1,
		tokens: 175_000,
	});
	expect(first?.key).toBe(second?.key);
});

test("computeBudgetTrigger advances bucket key when crossing into the next multiple", () => {
	const at1x = computeBudgetTrigger({
		contextWindow: 200_000,
		enabled: true,
		percentLimit: 50,
		tokenLimit: -1,
		tokens: 120_000,
	});
	const at2x = computeBudgetTrigger({
		contextWindow: 200_000,
		enabled: true,
		percentLimit: 50,
		tokenLimit: -1,
		tokens: 220_000,
	});
	expect(at1x?.key).not.toBe(at2x?.key);
});

test("computeBudgetTrigger ignores invalid token counts", () => {
	expect(computeBudgetTrigger({ enabled: true, percentLimit: 85, tokenLimit: -1, tokens: 0 })).toBeUndefined();
	expect(computeBudgetTrigger({ enabled: true, percentLimit: 85, tokenLimit: -1, tokens: Number.NaN })).toBeUndefined();
});

test("isBudgetGuardCompaction detects the sentinel", () => {
	expect(isBudgetGuardCompaction(`${QOL_BUDGET_GUARD_SENTINEL} fired`)).toBe(true);
	expect(isBudgetGuardCompaction("user requested compaction")).toBe(false);
	expect(isBudgetGuardCompaction(undefined)).toBe(false);
});

test("chunkConversationText returns single chunk when under the cap", () => {
	expect(chunkConversationText("short", 200)).toEqual(["short"]);
	expect(chunkConversationText("any text", 0)).toEqual(["any text"]);
});

test("chunkConversationText splits on paragraph boundaries inside the window", () => {
	const blocks = ["msg-a-line1\nmsg-a-line2", "msg-b-line1", "msg-c-line1", "msg-d-line1"];
	const text = blocks.join("\n\n");
	const chunks = chunkConversationText(text, 30);
	expect(chunks.length).toBeGreaterThan(1);
	expect(chunks.join("")).toBe(text);
	for (let i = 0; i < chunks.length - 1; i += 1) {
		expect(chunks[i]?.endsWith("\n\n")).toBe(true);
	}
});

test("chunkConversationText hard-splits when no paragraph break is available in the second half", () => {
	const text = "a".repeat(500);
	const chunks = chunkConversationText(text, 100);
	expect(chunks.length).toBe(5);
	expect(chunks.every((chunk) => chunk.length <= 100)).toBe(true);
	expect(chunks.join("")).toBe(text);
});

test("evaluateTranscriptRisk only flags when above threshold", () => {
	expect(evaluateTranscriptRisk({ chars: 0, messageCount: 5, threshold: 100 })).toEqual({
		chars: 0,
		exceeded: false,
		messageCount: 5,
		threshold: 100,
	});
	const below = evaluateTranscriptRisk({ chars: 90, messageCount: 5, threshold: 100 });
	expect(below.exceeded).toBe(false);
	const exact = evaluateTranscriptRisk({ chars: 100, messageCount: 5, threshold: 100 });
	expect(exact.exceeded).toBe(true);
	const above = evaluateTranscriptRisk({ chars: 250, messageCount: 5, threshold: 100 });
	expect(above.exceeded).toBe(true);
});

test("evaluateTranscriptRisk skips when threshold or message count is zero", () => {
	expect(evaluateTranscriptRisk({ chars: 1000, messageCount: 5, threshold: 0 }).exceeded).toBe(false);
	expect(evaluateTranscriptRisk({ chars: 1000, messageCount: 0, threshold: 100 }).exceeded).toBe(false);
});

test("evaluateTranscriptRisk propagates error state and zeroes chars", () => {
	const errored = evaluateTranscriptRisk({ chars: 0, error: "boom", messageCount: 5, threshold: 100 });
	expect(errored.error).toBe("boom");
	expect(errored.exceeded).toBe(false);
	expect(errored.chars).toBe(0);
});

interface RecordedSummarize { text: string; customInstructions?: string; previousSummary?: string }

function recordingSummarizer(responses: string[]): { summarize: (request: SummarizeRequest) => Promise<SummarizeOutcome>; calls: RecordedSummarize[] } {
	const calls: RecordedSummarize[] = [];
	let cursor = 0;
	const summarize = async (request: SummarizeRequest): Promise<SummarizeOutcome> => {
		calls.push({
			customInstructions: request.customInstructions,
			previousSummary: request.previousSummary,
			text: request.text,
		});
		const summary = responses[cursor] ?? `summary-${cursor + 1}`;
		cursor += 1;
		return { model: "test-model", summary, via: "model" };
	};
	return { calls, summarize };
}

test("orchestrateChunkedSummary fast-paths a single short summary when under cap", async () => {
	const { calls, summarize } = recordingSummarizer(["the one summary"]);
	const result = await orchestrateChunkedSummary({
		customInstructions: "carry decisions",
		maxInputChars: 1_000,
		previousSummary: "prev",
		summarize,
		text: "short text",
	});
	expect(result.summary).toBe("the one summary");
	expect(result.chunkCount).toBe(1);
	expect(result.reduceLevels).toBe(0);
	expect(result.requestCount).toBe(1);
	expect(calls.length).toBe(1);
	expect(calls[0]?.previousSummary).toBe("prev");
	expect(calls[0]?.customInstructions).toBe("carry decisions");
});

test("orchestrateChunkedSummary keeps every summarize request <= maxInputChars", async () => {
	const paragraph = `${"x".repeat(80)}\n\n`;
	const text = paragraph.repeat(60); // ~5040 chars
	const { calls, summarize } = recordingSummarizer([]);
	const cap = 200;
	const result = await orchestrateChunkedSummary({
		maxInputChars: cap,
		previousSummary: "prev",
		summarize,
		text,
	});
	expect(result.chunkCount).toBeGreaterThan(1);
	expect(result.reduceLevels).toBeGreaterThan(0);
	for (const call of calls) {
		expect(call.text.length).toBeLessThanOrEqual(cap);
	}
});

test("orchestrateChunkedSummary tree-reduces when joined partial summaries exceed the cap", async () => {
	const paragraph = `${"y".repeat(60)}\n\n`;
	const text = paragraph.repeat(120);
	// Force partial summaries that themselves overflow when concatenated
	const responses = Array.from({ length: 40 }, (_, idx) => "z".repeat(180) + ` #${idx}`);
	const { calls, summarize } = recordingSummarizer(responses);
	const result = await orchestrateChunkedSummary({
		maxInputChars: 200,
		summarize,
		text,
	});
	expect(result.reduceLevels).toBeGreaterThanOrEqual(2);
	for (const call of calls) {
		expect(call.text.length).toBeLessThanOrEqual(200);
	}
	expect(result.requestCount).toBe(calls.length);
});

test("orchestrateChunkedSummary aborts when signal is already aborted", async () => {
	const { summarize } = recordingSummarizer([]);
	const controller = new AbortController();
	controller.abort();
	await expect(
		orchestrateChunkedSummary({
			maxInputChars: 50,
			signal: controller.signal,
			summarize,
			text: "long ".repeat(200),
		}),
	).rejects.toThrow(/Compaction aborted/);
});

test("orchestrateChunkedSummary throws on empty chunk summary", async () => {
	const text = `${"a".repeat(60)}\n\n`.repeat(8);
	const { summarize } = recordingSummarizer(["", "", ""]);
	await expect(
		orchestrateChunkedSummary({ maxInputChars: 100, summarize, text }),
	).rejects.toThrow(/summary was empty/);
});

test("orchestrateChunkedSummary feeds previousSummary forward across chunks", async () => {
	const text = `${"q".repeat(40)}\n\n`.repeat(8);
	const { calls, summarize } = recordingSummarizer(["one", "two", "three", "four", "five"]);
	await orchestrateChunkedSummary({
		maxInputChars: 80,
		previousSummary: "seed",
		summarize,
		text,
	});
	// First chunk request sees the seed previousSummary; second chunk should
	// see the first chunk's summary string ("one") as previousSummary; final
	// reduce sees the original seed previousSummary.
	expect(calls[0]?.previousSummary).toBe("seed");
	expect(calls[1]?.previousSummary).toBe("one");
	const final = calls[calls.length - 1];
	expect(final?.previousSummary).toBe("seed");
});
