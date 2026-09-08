import type { Context, Tool } from "@earendil-works/pi-ai";

// Local compatibility copy of Pi 0.82.1 constrained-sampling and deferred-tool
// helpers. Pi 0.75 does not expose the canonical subpaths, so static imports
// would break the package's supported baseline. Keep this module aligned with:
// @earendil-works/pi-ai 0.82.1 api/constrained-sampling + utils/deferred-tools.
interface JsonSchemaConstrainedSampling {
	type: "json_schema";
	strict: "prefer" | "require";
}

interface GrammarConstrainedSampling {
	type: "grammar";
	variants: { openai_lark?: string; openai_regex?: string };
}

type ToolWithConstrainedSampling = Tool & {
	constrainedSampling?: false | JsonSchemaConstrainedSampling | GrammarConstrainedSampling;
};

export interface GrammarInputBuffer {
	input: string;
	started: boolean;
	closed: boolean;
}

function inferGrammarInputProperty(tool: ToolWithConstrainedSampling): string {
	const schema = tool.parameters as unknown as { type?: string; required?: unknown[]; properties?: Record<string, { type?: string }> };
	if (schema.type !== "object") throw new Error("grammar constrained sampling requires an object parameter schema");
	if (!Array.isArray(schema.required) || schema.required.length !== 1 || typeof schema.required[0] !== "string") {
		throw new Error("grammar constrained sampling requires exactly one required string property");
	}
	const property = schema.required[0];
	if (schema.properties?.[property]?.type !== "string") throw new Error(`grammar constrained sampling property ${property} must have type string`);
	return property;
}

export function resolveGrammarSampling(tool: Tool, supported: boolean): { format: "lark" | "regex"; definition: string; inputProperty: string } | undefined {
	const constrainedTool = tool as ToolWithConstrainedSampling;
	const config = constrainedTool.constrainedSampling;
	if (!config || config.type !== "grammar" || !supported) return undefined;
	const lark = typeof config.variants.openai_lark === "string" ? config.variants.openai_lark : "";
	const regex = typeof config.variants.openai_regex === "string" ? config.variants.openai_regex : "";
	const hasLark = lark.trim().length > 0;
	const hasRegex = regex.trim().length > 0;
	if (!hasLark && !hasRegex) throw new Error(`Tool "${tool.name}" cannot use grammar constrained sampling: no supported grammar variant was provided.`);
	try {
		return { format: hasLark ? "lark" : "regex", definition: hasLark ? lark : regex, inputProperty: inferGrammarInputProperty(constrainedTool) };
	} catch (error) {
		throw Object.assign(new Error(`grammar_schema=${tool.name}\nTool "${tool.name}" cannot use grammar constrained sampling: ${error instanceof Error ? error.message : String(error)}.`, { cause: error }), { code: "GRAMMAR_SCHEMA", tool: tool.name });
	}
}

export function resolveStrictSampling(tool: Tool, supported: boolean): boolean | undefined {
	const config = (tool as ToolWithConstrainedSampling).constrainedSampling;
	if (!config || config.type !== "json_schema") return undefined;
	if (supported) return true;
	if (config.strict === "require") throw Object.assign(new Error(`strict_sampling=${tool.name}\nTool "${tool.name}" requires JSON-schema constrained sampling, but strict tools are unsupported.`), { code: "STRICT_SAMPLING_UNSUPPORTED", tool: tool.name });
	return undefined;
}

export function createGrammarToolInputProperties(tools: readonly Tool[] | undefined, supported: boolean): ReadonlyMap<string, string> {
	const properties = new Map<string, string>();
	for (const tool of tools ?? []) {
		const grammar = resolveGrammarSampling(tool, supported);
		if (grammar) properties.set(tool.name, grammar.inputProperty);
	}
	return properties;
}

export function getGrammarToolInput(toolName: string, args: Record<string, unknown>, property: string): string {
	const value = args[property];
	if (typeof value !== "string") throw new Error(`Grammar tool call "${toolName}" requires argument "${property}" to be a string.`);
	return value;
}

export function appendGrammarToolInputJsonDelta(buffer: GrammarInputBuffer, property: string, nextInput: string, close: boolean): string | undefined {
	if (buffer.closed) {
		if (close && nextInput === buffer.input) return undefined;
		throw new Error(`grammar tool input for property "${property}" changed after it was closed`);
	}
	if (!nextInput.startsWith(buffer.input)) throw Object.assign(new Error(`grammar tool input for property "${property}" changed non-monotonically`), { code: "GRAMMAR_INPUT_NON_MONOTONIC", property });
	const inputDelta = nextInput.slice(buffer.input.length);
	if (!close && inputDelta.length === 0) return undefined;
	let delta = "";
	if (!buffer.started) {
		delta += `{${JSON.stringify(property)}:"`;
		buffer.started = true;
	}
	delta += JSON.stringify(inputDelta).slice(1, -1);
	buffer.input = nextInput;
	if (close) {
		delta += '"}';
		buffer.closed = true;
	}
	return delta;
}

export function splitDeferredTools(context: Context, enabled: boolean): { immediate: Tool[]; deferred: ReadonlyMap<string, Tool> } {
	const unique = new Map<string, Tool>();
	for (const tool of context.tools ?? []) unique.set(tool.name, tool);
	if (!enabled) return { immediate: [...unique.values()], deferred: new Map() };
	const deferredNames = new Set<string>();
	const usedNames = new Set<string>();
	for (const message of context.messages) {
		if (message.role === "assistant") {
			for (const block of message.content) if (block.type === "toolCall") usedNames.add(block.name);
		} else if (message.role === "toolResult") {
			for (const name of (message as unknown as { addedToolNames?: string[] }).addedToolNames ?? []) if (!usedNames.has(name)) deferredNames.add(name);
		}
	}
	const immediate: Tool[] = [];
	const deferred = new Map<string, Tool>();
	for (const [name, tool] of unique) {
		if (deferredNames.has(name)) deferred.set(name, tool);
		else immediate.push(tool);
	}
	return { immediate, deferred };
}
