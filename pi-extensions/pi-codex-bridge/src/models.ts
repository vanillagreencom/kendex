import type { Model } from "@earendil-works/pi-ai";
import type { CodexModel } from "./protocol.js";

const PI_CONTEXT_ACCOUNTING_LIMIT = 128_000;
const PI_OUTPUT_ACCOUNTING_LIMIT = 32_000;

export function buildPiModels(models: CodexModel[]): Array<Model<string>> {
	return models
		.filter((model) => !model.hidden)
		.map((model) => {
			const efforts = model.supportedReasoningEfforts
				.map((entry) => entry.reasoningEffort)
				.filter((effort) => effort.length > 0);
			const thinkingLevelMap = Object.fromEntries(efforts.map((effort) => [effort, effort]));
			return {
				id: model.model,
				name: model.displayName,
				api: "codex-app-server",
				provider: "pi-codex",
				baseUrl: "codex-app-server",
				reasoning: efforts.length > 0,
				thinkingLevelMap,
				input: model.inputModalities.includes("image") ? ["text", "image"] : ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: PI_CONTEXT_ACCOUNTING_LIMIT,
				maxTokens: PI_OUTPUT_ACCOUNTING_LIMIT,
			};
		});
}
