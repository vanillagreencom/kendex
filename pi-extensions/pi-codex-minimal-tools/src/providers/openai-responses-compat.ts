import type { Context, SystemMessage, Tool } from "@earendil-works/pi-ai";
import * as piAi from "@earendil-works/pi-ai";

// Local compatibility copy of Pi's constrained-sampling, deferred-tool and
// transcript-tool helpers. Pi 0.75 does not expose the canonical subpaths, and
// Pi below 1.4.0 exports an older `resolveTranscriptTools`, so static imports
// would break the package's supported baseline. Keep this module aligned with
// @earendil-works/pi-ai 1.6.0 api/constrained-sampling, api/openai-responses-shared
// `getResponsesToolSupport` and utils/transcript `resolveTranscriptTools`, and
// 0.82.1 utils/deferred-tools.
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

class UnsupportedStrictJsonSchemaError extends Error {}

const UNSUPPORTED_STRICT_SCHEMA_KEYS = ["$ref", "$defs", "definitions", "allOf", "oneOf", "patternProperties", "dependentSchemas", "dependencies", "unevaluatedProperties", "propertyNames", "contains", "prefixItems", "not", "if", "then", "else"] as const;

type JsonSchemaNode = { [key: string]: unknown; type?: unknown; properties?: Record<string, unknown>; required?: unknown; anyOf?: unknown; items?: unknown; enum?: unknown };

function isSchemaNode(value: unknown): value is JsonSchemaNode {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isStructuredSchema(schema: unknown): boolean {
	if (!isSchemaNode(schema)) return false;
	const types = typeof schema.type === "string" ? [schema.type] : Array.isArray(schema.type) ? schema.type : [];
	return types.includes("object") || types.includes("array") || schema.properties !== undefined || schema.items !== undefined;
}

function schemaAllowsNull(schema: unknown): boolean {
	if (!isSchemaNode(schema)) return false;
	if (schema.type === "null" || (Array.isArray(schema.type) && schema.type.includes("null"))) return true;
	if (schema.const === null || (Array.isArray(schema.enum) && schema.enum.includes(null))) return true;
	return Array.isArray(schema.anyOf) && schema.anyOf.some((variant) => schemaAllowsNull(variant));
}

/** Rewrite one node, in place, into OpenAI's strict subset: every property required, optional ones nullable. */
function makeSchemaNodeStrict(schema: unknown): void {
	if (!isSchemaNode(schema)) throw new UnsupportedStrictJsonSchemaError("boolean schemas are unsupported");
	for (const key of UNSUPPORTED_STRICT_SCHEMA_KEYS) {
		if (schema[key] !== undefined) throw new UnsupportedStrictJsonSchemaError(`${key} schemas are unsupported`);
	}
	// OpenAI strict mode rejects nodes without a type; a bare enum counts as typed, a bare const does not.
	if (schema.type === undefined && schema.anyOf === undefined && schema.enum === undefined) throw new UnsupportedStrictJsonSchemaError("schemas without a type are unsupported");
	if (schema.anyOf !== undefined) {
		if (!Array.isArray(schema.anyOf) || schema.anyOf.length === 0) throw new UnsupportedStrictJsonSchemaError("anyOf must contain at least one schema");
		for (const variant of schema.anyOf) {
			if (isStructuredSchema(variant)) throw new UnsupportedStrictJsonSchemaError("object and array unions are unsupported");
			makeSchemaNodeStrict(variant);
		}
	}
	if (schema.items !== undefined) {
		if (Array.isArray(schema.items)) throw new UnsupportedStrictJsonSchemaError("tuple schemas are unsupported");
		makeSchemaNodeStrict(schema.items);
	}
	const isObjectSchema = schema.type === "object";
	if (schema.properties !== undefined && !isObjectSchema) throw new UnsupportedStrictJsonSchemaError("properties require type object");
	if (!isObjectSchema) return;
	if (schema.additionalProperties !== undefined && schema.additionalProperties !== false) throw new UnsupportedStrictJsonSchemaError("schema-valued or true additionalProperties is unsupported");
	if (schema.properties !== undefined && !isSchemaNode(schema.properties)) throw new UnsupportedStrictJsonSchemaError("object properties must be a schema map");
	if (schema.required !== undefined && (!Array.isArray(schema.required) || schema.required.some((key) => typeof key !== "string"))) throw new UnsupportedStrictJsonSchemaError("object required must be a string array");
	const properties = (schema.properties ?? {}) as Record<string, unknown>;
	const propertyNames = Object.keys(properties);
	const required = new Set(Array.isArray(schema.required) ? (schema.required as string[]) : []);
	if ([...required].some((key) => !propertyNames.includes(key))) throw new UnsupportedStrictJsonSchemaError("required contains an unknown property");
	for (const [key, property] of Object.entries(properties)) {
		makeSchemaNodeStrict(property);
		if (!required.has(key) && !schemaAllowsNull(property)) properties[key] = { anyOf: [property, { type: "null" }] };
	}
	schema.required = propertyNames;
	schema.additionalProperties = false;
}

/** A tool's parameters in OpenAI's strict subset. */
export function makeStrictJsonSchema(schema: Tool["parameters"]): Record<string, unknown> {
	const cloned: unknown = structuredClone(schema);
	if (!isSchemaNode(cloned)) throw new UnsupportedStrictJsonSchemaError("root schema must have type object");
	makeSchemaNodeStrict(cloned);
	if (cloned.type !== "object") throw new UnsupportedStrictJsonSchemaError("root schema must have type object");
	return cloned;
}

/**
 * Whether a JSON-schema tool is sent in strict mode: a "prefer" tool whose schema
 * strict mode cannot take falls back to non-strict, a "require" tool refuses.
 */
export function resolveStrictSampling(tool: Tool, supported: boolean): boolean | undefined {
	const config = (tool as ToolWithConstrainedSampling).constrainedSampling;
	if (!config || config.type !== "json_schema") return undefined;
	let reason = "strict tools are unsupported";
	if (supported) {
		try {
			makeStrictJsonSchema(tool.parameters);
			return true;
		} catch (error) {
			if (!(error instanceof UnsupportedStrictJsonSchemaError)) throw error;
			reason = error.message;
		}
	}
	if (config.strict === "require") throw Object.assign(new Error(`strict_sampling=${tool.name}\nTool "${tool.name}" requires JSON-schema constrained sampling, but ${reason}.`), { code: "STRICT_SAMPLING_UNSUPPORTED", tool: tool.name });
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

/** Append a streamed input delta; returns the matching piece of the JSON arguments text. Linear in the delta. */
export function appendGrammarToolInputJsonDelta(buffer: GrammarInputBuffer, property: string, inputDelta: string): string | undefined {
	if (buffer.closed) throw new Error(`grammar tool input for property "${property}" changed after it was closed`);
	if (inputDelta.length === 0) return undefined;
	buffer.input += inputDelta;
	return grammarInputJsonStart(buffer, property) + JSON.stringify(inputDelta).slice(1, -1);
}

/** Close the input with the provider's complete input, when it sends one; returns the rest of the JSON arguments text. */
export function closeGrammarToolInputJson(buffer: GrammarInputBuffer, property: string, finalInput: string | undefined): string | undefined {
	if (buffer.closed) {
		if (finalInput === undefined || finalInput === buffer.input) return undefined;
		throw new Error(`grammar tool input for property "${property}" changed after it was closed`);
	}
	if (finalInput !== undefined && !finalInput.startsWith(buffer.input)) throw Object.assign(new Error(`grammar tool input for property "${property}" changed non-monotonically`), { code: "GRAMMAR_INPUT_NON_MONOTONIC", property });
	const rest = finalInput === undefined ? "" : finalInput.slice(buffer.input.length);
	if (finalInput !== undefined) buffer.input = finalInput;
	buffer.closed = true;
	return `${grammarInputJsonStart(buffer, property)}${JSON.stringify(rest).slice(1, -1)}"}`;
}

function grammarInputJsonStart(buffer: GrammarInputBuffer, property: string): string {
	if (buffer.started) return "";
	buffer.started = true;
	return `{${JSON.stringify(property)}:"`;
}

/**
 * How the Responses input expresses tool changes. With mid-conversation system
 * messages and `additional_tools`, every tool is declared in input items and a
 * removal is announced as text ("changes"); tool search can only add tools
 * ("additions"); otherwise the top-level list holds the current tools ("none").
 */
export type TranscriptToolSupport = "none" | "additions" | "changes";

export function getResponsesToolSupport(options: { supportsMidConvoSystemMessages?: boolean; supportsAdditionalTools?: boolean; supportsToolSearch?: boolean }): TranscriptToolSupport {
	if (options.supportsMidConvoSystemMessages && options.supportsAdditionalTools) return "changes";
	return options.supportsToolSearch ? "additions" : "none";
}

/** Index of the last system message with a removal or a same-name redeclaration, or -1. */
function lastNonAdditiveToolChange(systemMessages: readonly SystemMessage[]): number {
	const declared = new Set<string>();
	let last = -1;
	for (let index = 0; index < systemMessages.length; index++) {
		const message = systemMessages[index]!;
		if ((message.toolsRemoved?.length ?? 0) > 0) last = index;
		for (const tool of message.toolsAdded ?? []) {
			if (declared.has(tool.name)) last = index;
			declared.add(tool.name);
		}
	}
	return last;
}

/**
 * The top-level tools, and how many leading system messages they already hold;
 * every later system message declares its own tool changes in place.
 */
export function resolveTranscriptTools(messages: Context["messages"], support: TranscriptToolSupport): { requestTools: Tool[]; foldedSystemMessages: number } {
	const systemMessages = messages.filter((message): message is SystemMessage => message.role === "system");
	if (support === "none") return { requestTools: piAi.getCurrentTools(systemMessages), foldedSystemMessages: systemMessages.length };
	if (support === "changes") return { requestTools: [], foldedSystemMessages: 0 };
	const folded = Math.max(messages[0]?.role === "system" ? 1 : 0, lastNonAdditiveToolChange(systemMessages) + 1);
	return { requestTools: piAi.getCurrentTools(systemMessages.slice(0, folded)), foldedSystemMessages: folded };
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
