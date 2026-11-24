export interface NativeOpenAiWebSearchRewriteResult<T = unknown> {
	payload: T;
	rewritten: string[];
}

export interface NativeOpenAiWebSearchOptions {
	externalWebAccess?: boolean;
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function toolName(tool: Record<string, unknown>): string | undefined {
	if (typeof tool.name === "string") return tool.name;
	const nested = isRecord(tool.function) ? tool.function : undefined;
	return typeof nested?.name === "string" ? nested.name : undefined;
}

function rewriteTools(tools: unknown[], externalWebAccess: boolean, rewritten: string[]): unknown[] {
	return tools.map((candidate) => {
		if (!isRecord(candidate)) return candidate;
		const name = toolName(candidate);
		if (name === "web_search") {
			rewritten.push(name);
			return { type: "web_search", external_web_access: externalWebAccess };
		}
		return candidate;
	});
}

/**
 * Pi declares a Responses model's tools in one of two places: top-level
 * `tools`, or, for a model with `supportsAdditionalTools` and
 * `supportsMidConvoSystemMessages`, `additional_tools` input items, the first
 * at the head of `input` and a later one for each tool change (pi-ai
 * `api/openai-responses-shared.js::convertResponsesMessages`, Pi 1.6.0).
 */
export function rewriteNativeOpenAiWebSearch<T>(payload: T, options: NativeOpenAiWebSearchOptions = {}): NativeOpenAiWebSearchRewriteResult<T> {
	if (!isRecord(payload)) return { payload, rewritten: [] };
	const externalWebAccess = options.externalWebAccess ?? true;
	const rewritten: string[] = [];
	const next: Record<string, unknown> = { ...payload };
	if (Array.isArray(payload.tools)) next.tools = rewriteTools(payload.tools, externalWebAccess, rewritten);
	if (Array.isArray(payload.input)) {
		next.input = payload.input.map((item) => {
			if (!isRecord(item) || item.type !== "additional_tools" || !Array.isArray(item.tools)) return item;
			return { ...item, tools: rewriteTools(item.tools, externalWebAccess, rewritten) };
		});
	}
	return { payload: next as T, rewritten };
}
