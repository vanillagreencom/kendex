import { expect, test } from "bun:test";
import {
	chunkConversationText,
	computeBudgetTrigger,
	evaluateTranscriptRisk,
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
	// Each chunk must end at a paragraph break (except possibly the last).
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
