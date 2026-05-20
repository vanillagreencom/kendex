import { exaDeepResearchAvailable, isOpenAiNativeModel, resolveWebProviderCandidates, type ModelLike } from "./provider-selection.js";
import type { WebToolsSettings } from "./settings.js";
import { glyphs } from "./glyphs.js";

export const BASE_TOOL_NAMES = ["web_search", "web_fetch", "get_web_content"] as const;
export const ADVANCED_TOOL_NAMES = ["web_answer", "web_find_similar", "code_search"] as const;
export const RESEARCH_TOOL_NAMES = ["web_research"] as const;
export const COMPATIBILITY_TOOL_NAMES = ["fetch_content", "get_search_content", "web_search_exa", "web_fetch_exa", "web_research_exa", "web_answer_exa", "web_find_similar_exa"] as const;
export const PACKAGE_TOOL_NAMES = [...BASE_TOOL_NAMES, ...ADVANCED_TOOL_NAMES, ...RESEARCH_TOOL_NAMES, ...COMPATIBILITY_TOOL_NAMES] as const;
export type PackageToolName = (typeof PACKAGE_TOOL_NAMES)[number];

export function desiredWebTools(model: ModelLike | undefined, settings: WebToolsSettings): PackageToolName[] {
	if (!settings.enabled) return [];
	const desired: PackageToolName[] = ["web_search", "web_fetch", "get_web_content"];
	if (settings.exaDeepResearchEnabled) desired.push("web_research");
	if (settings.exaAdvancedEnabled) desired.push("web_answer", "web_find_similar", "code_search");
	if (settings.compatibilityTools) desired.push("fetch_content", "get_search_content", "web_search_exa", "web_fetch_exa", "web_research_exa", "web_answer_exa", "web_find_similar_exa");
	if (!settings.apiKeys.exa) {
		for (const exaOnly of ["web_fetch", "web_research", "web_answer", "web_find_similar", "code_search", "fetch_content", "web_fetch_exa", "web_research_exa", "web_answer_exa", "web_find_similar_exa"] as PackageToolName[]) {
			const index = desired.indexOf(exaOnly);
			if (index >= 0) desired.splice(index, 1);
		}
	}
	if (resolveWebProviderCandidates("auto", settings, model).length === 0) {
		const index = desired.indexOf("web_search");
		if (index >= 0) desired.splice(index, 1);
	}
	return desired;
}

export function computeNextActiveTools(currentActive: readonly string[], model: ModelLike | undefined, settings: WebToolsSettings): string[] {
	const current = new Set(currentActive);
	const desired = new Set(desiredWebTools(model, settings));
	for (const tool of PACKAGE_TOOL_NAMES) if (!desired.has(tool) && current.has(tool)) current.delete(tool);
	if (settings.enabled && settings.autoEnable) for (const tool of desired) current.add(tool);
	const activeTools = currentActive.filter((name) => current.has(name));
	for (const name of current) if (!activeTools.includes(name)) activeTools.push(name);
	return activeTools;
}

export function statusLines(model: ModelLike | undefined, settings: WebToolsSettings): string[] {
	return [
		"Web Tools",
		`enabled: ${settings.enabled}`,
		`autoEnable: ${settings.autoEnable}`,
		`defaultProvider: ${settings.defaultProvider}`,
		`enabledProviders: ${settings.enabledProviders.join(",")}`,
		`auto provider order: ${resolveWebProviderCandidates("auto", settings, model).join(` ${glyphs().arrow} `) || "none"}`,
		`OpenAI native available: ${settings.nativeOpenAiWebSearch && isOpenAiNativeModel(model)}`,
		`Exa key: ${settings.apiKeys.exa ? "present" : "not set"}`,
		`Exa deep research: ${exaDeepResearchAvailable(settings) ? "available" : "not available"}`,
	];
}
