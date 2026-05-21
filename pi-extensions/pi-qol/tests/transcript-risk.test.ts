// Integration-style test against the real pi-coding-agent serializeConversation
// + convertToLlm helpers. The pure threshold math is covered in budget-guard.test.ts;
// this exercises the wiring that converts a branch into a risk verdict and the
// error path when serialization throws.

import { expect, test } from "bun:test";
import { transcriptRiskState } from "../extensions/qol/transcript-risk.ts";

function userMessage(text: string) {
	return { content: [{ text, type: "text" }], role: "user", timestamp: Date.now() } as any;
}

function assistantMessage(text: string) {
	return { content: [{ text, type: "text" }], role: "assistant", timestamp: Date.now() } as any;
}

test("transcriptRiskState returns no warning when below the char budget", () => {
	const messages = [userMessage("hi"), assistantMessage("hello")];
	const result = transcriptRiskState(messages, 1_000_000);
	expect(result.error).toBeUndefined();
	expect(result.chars).toBeGreaterThan(0);
	expect(result.exceeded).toBe(false);
	expect(result.messageCount).toBe(2);
});

test("transcriptRiskState flags when the serialized payload exceeds the budget", () => {
	const big = "x".repeat(50_000);
	const messages = [userMessage(big), assistantMessage(big)];
	const result = transcriptRiskState(messages, 10_000);
	expect(result.error).toBeUndefined();
	expect(result.exceeded).toBe(true);
	expect(result.chars).toBeGreaterThan(50_000);
});

test("transcriptRiskState skips work when threshold is zero or messages empty", () => {
	expect(transcriptRiskState([], 1000).exceeded).toBe(false);
	expect(transcriptRiskState([userMessage("hi")], 0).exceeded).toBe(false);
});

test("transcriptRiskState returns an error state when serialization throws", () => {
	const bad = [{ role: "assistant", content: { type: "weird", get text() { throw new Error("boom"); } } } as any];
	const result = transcriptRiskState(bad, 1000);
	// Either serialization tolerates the weirdness or it throws; in both
	// cases the wrapper must return a defined result rather than throw.
	expect(result.messageCount).toBe(1);
	expect(result.exceeded).toBe(false);
	// If serialization threw, the error field should carry the message;
	// otherwise chars should be >= 0 and the call should still have completed.
	if (result.error !== undefined) {
		expect(typeof result.error).toBe("string");
		expect(result.chars).toBe(0);
	}
});
