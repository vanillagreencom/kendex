import * as piAi from "@earendil-works/pi-ai";
import { resolveGetModels } from "./pi-ai-compat.js";

type BridgeModelMetadata = {
	id: string;
	name: string;
	reasoning: boolean;
	thinkingLevelMap?: Record<string, string | null>;
	input: ("text" | "image")[];
	contextWindow: number;
	maxTokens: number;
};

// Pi owns model membership, ordering and metadata. Claude Code owns its default
// safety fallback: the bridge sends no fallbackModel override.
export function buildModels(piAiModels: BridgeModelMetadata[]) {
	return piAiModels.map(({ id, name, reasoning, input, contextWindow, maxTokens, thinkingLevelMap }) => ({
		id, name, reasoning, input, contextWindow, maxTokens, thinkingLevelMap,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
	}));
}
const getModels = await resolveGetModels(piAi);
export const MODELS = buildModels(getModels("anthropic"));

export function modelDisplayName(modelId: string): string {
	return MODELS.find((model) => model.id === modelId)?.name ?? modelId;
}
