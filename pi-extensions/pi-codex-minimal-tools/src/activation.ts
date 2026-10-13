import type { ModelLike } from "./capabilities.js";

export interface ModelRegistryLike {
	getAll?: () => unknown;
	getAvailable?: () => unknown;
}

export interface ActivationContextLike {
	model?: ModelLike;
	modelRegistry?: ModelRegistryLike;
}

export function isOpenAiLoadedModel(model: ModelLike | undefined): boolean {
	const provider = (model?.provider ?? "").toLowerCase();
	return provider === "openai" || provider === "openai-codex" || provider === "opencode" || provider.startsWith("openai-") || provider.endsWith("-openai") || provider.endsWith("-codex");
}

// Pi's registry owns model identities; a local probe list misses new models.
export function registryModels(registry: ModelRegistryLike | undefined): ModelLike[] {
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
	return registryModels(ctx.modelRegistry).some(isOpenAiLoadedModel);
}
