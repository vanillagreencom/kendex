import type { ModelLike } from "./capabilities.js";

export interface ModelRegistryLike {
	getAll?: () => unknown;
	getAvailable?: () => unknown;
	find?: (provider: string, id: string) => unknown;
}

export interface ActivationContextLike {
	model?: ModelLike;
	modelRegistry?: ModelRegistryLike;
}

const OPENAI_PROVIDER_PROBES = ["openai-codex", "openai"];
const OPENAI_MODEL_PROBE_IDS = ["gpt-6-astra", "gpt-5.4", "gpt-5.3-codex", "gpt-5.2", "gpt-5.1", "gpt-5", "gpt-4.1", "o4-mini"];

export function isOpenAiLoadedModel(model: ModelLike | undefined): boolean {
	const provider = (model?.provider ?? "").toLowerCase();
	return provider === "openai" || provider === "openai-codex" || provider === "opencode" || provider.startsWith("openai-") || provider.endsWith("-openai") || provider.endsWith("-codex");
}

function registryModels(registry: ModelRegistryLike | undefined): ModelLike[] {
	if (!registry) return [];
	for (const method of [registry.getAll, registry.getAvailable]) {
		if (typeof method !== "function") continue;
		try {
			const value = method.call(registry);
			if (Array.isArray(value)) return value.filter((model): model is ModelLike => Boolean(model) && typeof model === "object");
		} catch {
			// Try the next registry shape.
		}
	}
	return [];
}

export function hasOpenAiModelsLoaded(ctx: ActivationContextLike): boolean {
	if (isOpenAiLoadedModel(ctx.model)) return true;
	const models = registryModels(ctx.modelRegistry);
	if (models.some(isOpenAiLoadedModel)) return true;
	try {
		return OPENAI_PROVIDER_PROBES.some((provider) => OPENAI_MODEL_PROBE_IDS.some((id) => Boolean(ctx.modelRegistry?.find?.(provider, id))));
	} catch {
		return false;
	}
}
