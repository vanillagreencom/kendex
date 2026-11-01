import { clampThinkingLevel, type Model, type ThinkingLevel, type ThinkingLevelMap } from "@earendil-works/pi-ai";
import type { CodexModel } from "./protocol.js";

export const PROVIDER_ID = "pi-codex";
export const API_ID = "codex-app-server";

const PI_CONTEXT_ACCOUNTING_LIMIT = 128_000;
const PI_OUTPUT_ACCOUNTING_LIMIT = 32_000;
const PI_LEVELS = ["minimal", "low", "medium", "high", "xhigh", "max"] as const;

/** Pi's levels mapped to the efforts this Codex model lists. Pi's `off` is
 * Codex's `none`; a level the model lacks maps to null, which Pi reads as
 * unsupported and does not offer. */
export function thinkingLevelMap(efforts: readonly string[]): ThinkingLevelMap {
	const map: ThinkingLevelMap = { off: efforts.includes("none") ? "none" : null };
	for (const level of PI_LEVELS) map[level] = efforts.includes(level) ? level : null;
	return map;
}

export function buildPiModels(models: readonly CodexModel[]): Array<Model<string>> {
	return models
		.filter((model) => !model.hidden)
		.map((model) => {
			const efforts = model.reasoningEfforts.filter((effort) => effort.length > 0);
			return {
				id: model.model,
				name: model.displayName,
				api: API_ID,
				provider: PROVIDER_ID,
				baseUrl: API_ID,
				reasoning: efforts.length > 0,
				thinkingLevelMap: thinkingLevelMap(efforts),
				input: model.inputModalities.includes("image") ? ["text", "image"] : ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: PI_CONTEXT_ACCOUNTING_LIMIT,
				maxTokens: PI_OUTPUT_ACCOUNTING_LIMIT,
			};
		});
}

/** The Codex effort for Pi's requested level, or null to leave Codex's
 * default. Pi passes no level when thinking is off. */
export function codexEffort(model: Model<string>, level: ThinkingLevel | undefined): string | null {
	if (!model.reasoning) return null;
	const clamped = level === undefined ? "off" : clampThinkingLevel(model, level);
	return model.thinkingLevelMap?.[clamped] ?? null;
}
