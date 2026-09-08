import type { ResponseStreamEvent } from "openai/resources/responses/responses.js";
import type { AssistantMessage, Model } from "@earendil-works/pi-ai";

export async function* asAsyncIterable(events: unknown[]) {
	for (const event of events) yield event as ResponseStreamEvent;
}

export function createAssistantOutput(): AssistantMessage {
	return {
		role: "assistant", content: [], api: "openai-codex-responses",
		provider: "openai-codex", model: "gpt-6-astra",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
		stopReason: "stop", timestamp: 0,
	};
}

export const model: Model<"openai-codex-responses"> = {
	provider: "openai-codex", api: "openai-codex-responses", id: "gpt-6-astra", name: "GPT-6 Astra",
	baseUrl: "https://example.test/backend-api", input: ["text", "image"], reasoning: true,
	cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 272000, maxTokens: 128000,
};
